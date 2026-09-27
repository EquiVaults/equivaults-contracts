#!/usr/bin/env python3
"""Read-only coverage for the simulation fixture namespace contract."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


MODULE_PATH = Path(__file__).resolve().parents[1] / "script" / "simulation_fixture.py"
SPEC = importlib.util.spec_from_file_location("simulation_fixture", MODULE_PATH)
assert SPEC and SPEC.loader
fixture_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture_module)


class FakeDemo:
    def __init__(self, identity):
        self._identity = identity

    def identity(self, factory):
        if factory != self._identity["factory"]:
            raise RuntimeError("wrong factory")
        return self._identity

    def rpc(self, method, _params):
        if method == "eth_getCode":
            return "0x01"
        raise RuntimeError(method)


class ClockDemo(FakeDemo):
    def __init__(self, identity, timestamp):
        super().__init__(identity)
        self.timestamp = timestamp
        self.calls = []

    def rpc(self, method, params=None):
        self.calls.append((method, params))
        if method == "eth_getBlockByNumber":
            return {"timestamp": hex(self.timestamp)}
        if method == "evm_setNextBlockTimestamp":
            self.pending = params[0]
            return None
        if method == "evm_mine":
            self.timestamp = self.pending
            return "0x0"
        return super().rpc(method, params)


class StageDemo(FakeDemo):
    def __init__(self, identity, *, positions=(0, 0, 0), requests=(1, 1, 1), accounts=None):
        super().__init__(identity)
        self.positions = positions
        self.requests = requests
        self.accounts = accounts or ("0x" + "0" * 40,) * 3
        self.base_vault_count = 17
        self.vaults = ["0x" + f"{index + 1:040x}" for index in range(5)]
        self.escrows = ["0x" + f"{index + 11:040x}" for index in range(5)]

    def call(self, address, signature, *args):
        if signature == "vaults(uint256)(address)":
            return self.vaults[args[0] - self.base_vault_count]
        if signature == "investmentEscrow()(address)":
            return self.escrows[self.vaults.index(address)]
        if signature == "balanceOf(address)(uint256)":
            return self.positions[(0, 2, 3).index(self.vaults.index(address))]
        if signature == "nextRequestId()(uint256)":
            return self.requests[(0, 1, 3).index(self.escrows.index(address))]
        if signature == "accounts(address,uint256)(address)":
            return self.accounts[(0, 1, 3).index(self.escrows.index(args[0]))]
        raise AssertionError((address, signature, args))


class IncompleteFixtureDemo(FakeDemo):
    def __init__(self, identity, baseline):
        super().__init__(identity)
        self.baseline = baseline
        self.broadcasts = []

    def guard(self):
        return None

    def load(self):
        return self.baseline

    def call(self, _address, signature, *_args):
        if signature == "vaultCount()(uint256)":
            return str(len(self.baseline["vaults"]) + len(fixture_module.VAULT_SPECS))
        raise AssertionError(signature)

    def logs(self, _address, _signature):
        return [object()] * (len(self.baseline["assets"]) + len(fixture_module.ASSET_SPECS))

    def broadcast(self, *args):
        self.broadcasts.append(args)


class SimulationFixtureTest(unittest.TestCase):
    def setUp(self):
        self.identity = {"chainId": 31337, "factory": "0x" + "11" * 20,
                         "genesisHash": "0x" + "22" * 32, "deploymentBlock": "1",
                         "deploymentBlockHash": "0x" + "33" * 32}

    def test_personas_are_fixed_and_do_not_reuse_technical_accounts(self):
        addresses = {address.lower() for address, *_ in fixture_module.PERSONAS}
        self.assertNotIn(fixture_module.EXECUTOR.lower(), addresses)
        self.assertNotIn(fixture_module.BUNDLER.lower(), addresses)
        self.assertEqual([alias for _, alias, _, _ in fixture_module.PERSONAS], [
            "0xEarlyInvestor", "0xLateInvestor", "0xPatientInvestor", "0xWhaleInvestor",
            "0xMixedInvestor", "0xExitInvestor", "0xBlockedInvestor", "0xNewInvestor",
        ])

    def test_load_rejects_technical_account_as_investor(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "simulation-fixture.json"
            profiles = [{"address": address, "alias": alias, "role": role, "description": description}
                        for address, alias, role, description in fixture_module.PERSONAS]
            profiles[0]["address"] = fixture_module.EXECUTOR
            path.write_text(json.dumps({"schema": fixture_module.SCHEMA, "identity": self.identity,
                                        "marketActor": fixture_module.MARKET_ACTOR,
                                        "profiles": profiles,
                                        "assets": [], "vaults": []}))
            with self.assertRaisesRegex(RuntimeError, "Executor or bundler"):
                fixture_module.Fixture(FakeDemo(self.identity), path).load()

    def test_load_rejects_market_actor_as_a_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "simulation-fixture.json"
            profiles = [{"address": address, "alias": alias, "role": role, "description": description}
                        for address, alias, role, description in fixture_module.PERSONAS]
            profiles[0]["address"] = fixture_module.MARKET_ACTOR
            path.write_text(json.dumps({"schema": fixture_module.SCHEMA, "identity": self.identity,
                                        "marketActor": fixture_module.MARKET_ACTOR, "profiles": profiles,
                                        "assets": [], "vaults": []}))
            with self.assertRaisesRegex(RuntimeError, "Market actor"):
                fixture_module.Fixture(FakeDemo(self.identity), path).load()

    def test_load_is_bound_to_the_demo_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "simulation-fixture.json"
            path.write_text(json.dumps({"schema": fixture_module.SCHEMA, "identity": self.identity,
                                        "marketActor": fixture_module.MARKET_ACTOR,
                                        "profiles": [{"address": fixture_module.PERSONAS[0][0], "alias": "ok",
                                                      "role": "investor", "description": "ok"}],
                                        "assets": [], "vaults": []}))
            other = {**self.identity, "genesisHash": "0x" + "44" * 32}
            with self.assertRaisesRegex(RuntimeError, "another deployment"):
                fixture_module.Fixture(FakeDemo(other), path).load()

    def test_fixture_path_gets_an_adjacent_progress_file(self):
        path = Path(".local-demo") / "simulation-qa" / "fixture.json"
        fixture = fixture_module.Fixture(FakeDemo(self.identity), path)
        self.assertEqual(fixture.progress_path, path.with_name("simulation-fixture.progress.json"))

    def test_prepare_broadcast_clock_mines_a_fresh_head_before_forge(self):
        demo = ClockDemo(self.identity, timestamp=900)
        fixture = fixture_module.Fixture(demo, Path("unused.json"))
        with patch.object(fixture_module.time, "time", return_value=1_000):
            fixture._prepare_broadcast_clock()
        self.assertEqual(demo.timestamp, 1_000)
        self.assertEqual(demo.calls[1:3], [
            ("evm_setNextBlockTimestamp", [1_000]),
            ("evm_mine", None),
        ])

    def test_prepare_broadcast_clock_never_moves_time_backwards(self):
        demo = ClockDemo(self.identity, timestamp=2_000)
        fixture = fixture_module.Fixture(demo, Path("unused.json"))
        with patch.object(fixture_module.time, "time", return_value=1_000):
            fixture._prepare_broadcast_clock()
        self.assertEqual(demo.timestamp, 2_001)

    def test_initialization_stage_is_pristine_only_when_every_slot_is_empty(self):
        baseline = {"factory": "0x" + "cc" * 20, "vaults": [object()] * 17}
        execution = {"factory": "0x" + "aa" * 20}
        pristine = fixture_module.Fixture(StageDemo(self.identity), Path("unused.json"))
        self.assertEqual(pristine._initialization_stage(baseline, execution), "pristine")
        partial = fixture_module.Fixture(StageDemo(self.identity, positions=(1, 0, 0)), Path("unused.json"))
        self.assertEqual(partial._initialization_stage(baseline, execution), "unknown")

    def test_initialization_stage_requires_all_history_before_manifest(self):
        baseline = {"factory": "0x" + "cc" * 20, "vaults": [object()] * 17}
        execution = {"factory": "0x" + "aa" * 20}
        account = "0x" + "bb" * 20
        fixture = fixture_module.Fixture(StageDemo(self.identity, positions=(1, 1, 1), requests=(2, 2, 2),
                                                    accounts=(account, account, account)), Path("unused.json"))
        self.assertEqual(fixture._initialization_stage(baseline, execution), "ready")

    def test_incomplete_extension_never_broadcasts_or_publishes_a_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "simulation-fixture.json"
            baseline = {"factory": self.identity["factory"], "registry": "0x" + "dd" * 20,
                        "settlementAsset": "0x" + "ee" * 20, "vaults": [object()] * 17,
                        "assets": [object()] * 8}
            demo = IncompleteFixtureDemo(self.identity, baseline)
            fixture = fixture_module.Fixture(demo, path)
            fixture.progress_path.write_text(json.dumps({"identity": self.identity,
                                                          "baseVaultCount": 17, "baseAssetCount": 8}))
            fixture._execution_context = lambda _baseline: {"factory": "0x" + "ff" * 20}
            fixture._initialization_stage = lambda _baseline, _execution: "unknown"
            with self.assertRaisesRegex(RuntimeError, "incomplete or uncertain"):
                fixture.ensure()
            self.assertEqual(demo.broadcasts, [])
            self.assertFalse(path.exists())


if __name__ == "__main__":
    unittest.main()
