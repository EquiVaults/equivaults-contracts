#!/usr/bin/env python3
"""Unit coverage for receipt-derived local address export guards."""
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "script" / "export-addresses.py"
SPEC = importlib.util.spec_from_file_location("export_addresses", MODULE_PATH)
assert SPEC and SPEC.loader
export_addresses = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(export_addresses)


def padded(address: str) -> str:
    return "0x" + "0" * 24 + address[2:].lower()


class VaultReceiptDiscoveryTest(unittest.TestCase):
    settlement = "0x00000000000000000000000000000000000000a1"
    registry = "0x00000000000000000000000000000000000000b2"
    factory_v2 = "0x00000000000000000000000000000000000000c3"
    factory_v1 = "0x00000000000000000000000000000000000000d4"
    actual_vault = "0x00000000000000000000000000000000000000e5"
    simulated_vault = "0x00000000000000000000000000000000000000f6"

    def _rpc(self, factory: str, include_event: bool):
        def fake(_rpc_url, method, params):
            if method == "eth_getTransactionReceipt":
                logs = []
                if include_event:
                    logs.append({
                        "address": factory,
                        "topics": [
                            export_addresses.VAULT_EVENT_TOPIC,
                            padded(self.actual_vault),
                            padded(export_addresses.ANVIL1),
                            padded(self.settlement),
                        ],
                    })
                return {"status": "0x1", "logs": logs}
            if method == "eth_getCode":
                self.assertEqual(params[0].lower(), self.actual_vault.lower())
                return "0x6000"
            if method == "eth_call":
                data = params[0]["data"]
                if data.startswith("0x652b9b41"):
                    return "0x" + "0" * 63 + "1"
                if data == "0x481c6a75":
                    return padded(export_addresses.ANVIL1)
                if data == "0xd3781d58":
                    return padded(self.settlement)
                if data == "0x7b103999":
                    return padded(self.registry)
            raise AssertionError(f"unexpected RPC call {method} {params}")
        return fake

    def test_uses_the_mined_vault_created_event_not_simulated_additional_contract(self):
        with patch.object(export_addresses, "rpc_call", self._rpc(self.factory_v2, True)):
            actual = export_addresses.vault_from_receipts(
                "http://127.0.0.1:18545", self.factory_v2, ["0x" + "1" * 64], self.settlement, self.registry
            )
        self.assertEqual(actual.lower(), self.actual_vault.lower())
        self.assertNotEqual(actual.lower(), self.simulated_vault.lower())

    def test_rejects_a_successful_parent_receipt_without_expected_event(self):
        with patch.object(export_addresses, "rpc_call", self._rpc(self.factory_v2, False)):
            with self.assertRaisesRegex(SystemExit, "VaultCreated"):
                export_addresses.vault_from_receipts(
                    "http://127.0.0.1:18545", self.factory_v2, ["0x" + "2" * 64], self.settlement, self.registry
                )

    def test_accepts_expected_v1_and_v2_factory_emitters(self):
        for factory in (self.factory_v2, self.factory_v1):
            with self.subTest(factory=factory), patch.object(export_addresses, "rpc_call", self._rpc(factory, True)):
                actual = export_addresses.vault_from_receipts(
                    "http://127.0.0.1:18545", factory, ["0x" + "3" * 64], self.settlement, self.registry
                )
                self.assertEqual(actual.lower(), self.actual_vault.lower())


class RuntimeArtifactVerificationTest(unittest.TestCase):
    address = "0x00000000000000000000000000000000000000e5"

    def test_rejects_runtime_that_differs_from_the_compiled_artifact(self):
        artifact = Path("out/InvestmentEscrow.sol/InvestmentEscrow.json")
        expected = __import__("json").loads(artifact.read_text())["deployedBytecode"]["object"]
        self.assertTrue(all(character in "0123456789abcdefx" for character in expected.lower()))
        wrong = "0x61" + expected[4:]

        def fake(_rpc_url, method, _params):
            self.assertEqual(method, "eth_getCode")
            return wrong

        with patch.object(export_addresses, "rpc_call", fake):
            with self.assertRaisesRegex(SystemExit, "differs"):
                export_addresses.verify_compiled_runtime("http://127.0.0.1:18545", "InvestmentEscrow", self.address)

    def test_library_self_address_is_the_deployed_library_address(self):
        contract_name = "RebalanceLib"
        artifact = __import__("json").loads(Path(f"out/{contract_name}.sol/{contract_name}.json").read_text())
        location = artifact["deployedBytecode"]["immutableReferences"]["library_deploy_address"][0]
        expected = artifact["deployedBytecode"]["object"]
        deployed = "0x00000000000000000000000000000000000000e5"
        start = 2 + location["start"] * 2
        end = start + location["length"] * 2
        runtime = expected[:start] + "0" * 24 + deployed[2:] + expected[end:]

        with patch.object(export_addresses, "rpc_call", lambda _url, method, _params: runtime if method == "eth_getCode" else None):
            export_addresses.verify_compiled_runtime("http://127.0.0.1:18545", contract_name, deployed)

        wrong = runtime[:start] + "0" * 24 + "f" * 40 + runtime[end:]
        with patch.object(export_addresses, "rpc_call", lambda _url, method, _params: wrong if method == "eth_getCode" else None):
            with self.assertRaisesRegex(SystemExit, "self-address"):
                export_addresses.verify_compiled_runtime("http://127.0.0.1:18545", contract_name, deployed)


class ArtifactPreparationTest(unittest.TestCase):
    def test_rebuilds_after_source_guard_and_before_runtime_artifact_use(self):
        calls = []
        with patch.object(export_addresses, "artifact_source_commit", lambda: calls.append("source") or "a" * 40), patch.object(
            export_addresses, "rebuild_source_artifacts", lambda: calls.append("rebuild")
        ):
            self.assertEqual(export_addresses.prepare_artifact_verification(), "a" * 40)
        self.assertEqual(calls, ["source", "rebuild"])


class ArtifactSourceGuardPathspecTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "src").mkdir()
        (self.root / "script").mkdir()
        (self.root / "test/fixtures/synchronous-v1").mkdir(parents=True)
        (self.root / "test/mocks").mkdir(parents=True)
        (self.root / "lib").mkdir()
        (self.root / "src/EquiVault.sol").write_text("contract EquiVault {}\n")
        (self.root / "script/DeployLocal.s.sol").write_text("contract DeployLocal {}\n")
        (self.root / "script/LocalDemoTokens.sol").write_text("library LocalDemoTokens {}\n")
        (self.root / "script/SeedLocalDemo.s.sol").write_text("contract SeedLocalDemo {}\n")
        (self.root / "foundry.toml").write_text("[profile.default]\n")
        self._git("init", "-q")
        self._git("add", ".")
        self._git("-c", "user.email=test@example.invalid", "-c", "user.name=Test", "commit", "-qm", "source")
        self.commit = self._git("rev-parse", "HEAD").strip()
        manifest = self.root / "deployments/manifest.json"
        manifest.parent.mkdir()
        manifest.write_text(json.dumps({"contractsCommit": self.commit}))
        self.root_patch = patch.object(export_addresses, "ROOT", self.root)
        self.manifest_patch = patch.object(export_addresses, "MANIFEST_FILE", manifest)
        self.root_patch.start()
        self.manifest_patch.start()

    def tearDown(self):
        self.manifest_patch.stop()
        self.root_patch.stop()
        self.temporary.cleanup()

    def _git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True)

    def test_accepts_untracked_python_operator_script(self):
        (self.root / "script/sponsor-daemon.py").write_text("print('operator')\n")
        self.assertEqual(export_addresses.artifact_source_commit(), self.commit)

    def test_rejects_a_changed_solidity_deployment_input(self):
        (self.root / "script/LocalDemoTokens.sol").write_text("library LocalDemoTokens { function changed() external {} }\n")
        with self.assertRaisesRegex(SystemExit, "contract sources differ"):
            export_addresses.artifact_source_commit()

    def test_rejects_a_new_solidity_deployment_input(self):
        (self.root / "script/NewDeployInput.sol").write_text("contract NewDeployInput {}\n")
        with self.assertRaisesRegex(SystemExit, "untracked contract source paths"):
            export_addresses.artifact_source_commit()


class OutputPathTest(unittest.TestCase):
    def test_accepts_the_official_and_local_catalog_paths(self):
        self.assertEqual(export_addresses.output_file("deployments/31337/addresses.json"), export_addresses.OUT_FILE)
        self.assertEqual(
            export_addresses.output_file(".local-demo/addresses.json"),
            export_addresses.ROOT / ".local-demo/addresses.json",
        )

    def test_rejects_an_output_outside_the_checkout(self):
        with self.assertRaisesRegex(SystemExit, "inside the contracts checkout"):
            export_addresses.output_file("/tmp/addresses.json")

    def test_keeps_the_official_rpc_but_records_an_isolated_catalog_rpc(self):
        self.assertEqual(
            export_addresses.catalog_rpc_url(export_addresses.OUT_FILE.resolve(), "http://127.0.0.1:38545"),
            export_addresses.PUBLISHED_LOCAL_RPC_URL,
        )
        self.assertEqual(
            export_addresses.catalog_rpc_url(
                export_addresses.output_file(".local-demo/addresses.json"),
                "http://127.0.0.1:38545",
            ),
            "http://127.0.0.1:38545",
        )


if __name__ == "__main__":
    unittest.main()
