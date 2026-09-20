#!/usr/bin/env python3
"""Export verified local deployment addresses from DeployLocal broadcast receipts.

Run after a successful local broadcast:
  python3 script/export-addresses.py --rpc-url http://127.0.0.1:8545

The RPC URL is deliberately explicit and must point to a loopback Anvil chain (31337). The
exporter cross-checks every creating transaction receipt and hashes runtime code obtained from
that chain; it never treats broadcast simulation addresses as published deployment evidence.
"""
import argparse
import json
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
RUN_FILE = ROOT / "broadcast" / "DeployLocal.s.sol" / "31337" / "run-latest.json"
OUT_FILE = ROOT / "deployments" / "31337" / "addresses.json"
MANIFEST_FILE = ROOT / "deployments" / "manifest.json"
V1_COMMIT = "c2f5605aec16d4121bd2c43354d7effef81cee95"
PUBLISHED_LOCAL_RPC_URL = "http://127.0.0.1:8545"

ANVIL0 = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
ANVIL1 = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
ANVIL2 = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
ADDR_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")
HASH_RE = re.compile(r"^0x[0-9a-fA-F]{64}$")

ORDERED = {
    "MockOracle": ["primaryOracleA", "fallbackOracleA", "primaryOracleB", "fallbackOracleB"],
    "MockPool": ["poolA", "poolB"],
}
TOKEN_KEYS = ["settlementAsset", "tokenA", "tokenB"]
TOKEN_CONTRACTS = {"MockToken", "NamedMockToken"}
SINGLE = {
    "AssetRegistry": "registry",
    "VaultFactory": "factory",
    "LegacyVaultFactory": "legacyFactory",
    "RebalanceEngine": "engine",
    "EntryPoint": "entryPoint",
    "InvestmentExecutionFactory": "executionFactory",
}
VAULT_EVENT_TOPIC = "0x32c459f0706c3a07f3800e0e0366fbb8ecffedf431250fdf6a59e9fd5c7f20c4"

# Python and shell helpers do not affect Foundry compilation. Solidity scripts do: their
# imports are deployment inputs, so include both tracked and newly introduced files here.
PROVENANCE_PATHS = (
    "src",
    ":(glob)script/*.sol",
    ":(glob)script/**/*.sol",
    "test/fixtures/synchronous-v1",
    "test/mocks/Mocks.sol",
    "foundry.toml",
    "lib",
)


def fail(message: str) -> None:
    raise SystemExit(message)


def rpc_call(rpc_url: str, method: str, params: list[Any]) -> Any:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    request = urllib.request.Request(rpc_url, data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            payload = json.loads(response.read())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        fail(f"RPC {method} failed: {error}")
    if payload.get("error"):
        fail(f"RPC {method} returned {payload['error']}")
    return payload.get("result")


def require_local_anvil(rpc_url: str) -> None:
    parsed = urllib.parse.urlparse(rpc_url)
    if parsed.scheme not in {"http", "https"} or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
        fail("--rpc-url must target a loopback local Anvil endpoint")
    if rpc_call(rpc_url, "eth_chainId", []) != "0x7a69":
        fail("--rpc-url must target local chainId 31337")


def runtime_code_hash(rpc_url: str, address: str) -> str:
    code = rpc_call(rpc_url, "eth_getCode", [address, "latest"])
    if not isinstance(code, str) or code == "0x":
        fail(f"no runtime code at {address}")
    try:
        digest = subprocess.check_output(["cast", "keccak", code], text=True).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        fail(f"could not hash runtime code for {address}: {error}")
    if not HASH_RE.fullmatch(digest):
        fail(f"invalid runtime code hash for {address}: {digest}")
    return digest.lower()


def runtime_code(rpc_url: str, address: str) -> str:
    code = rpc_call(rpc_url, "eth_getCode", [address, "latest"])
    if not isinstance(code, str) or not re.fullmatch(r"0x[0-9a-fA-F]+", code) or code == "0x":
        fail(f"no runtime code at {address}")
    return code.lower()


def is_library_artifact(contract_name: str, artifact: dict[str, Any]) -> bool:
    targets = artifact.get("metadata", {}).get("settings", {}).get("compilationTarget", {})
    if not isinstance(targets, dict) or len(targets) != 1:
        return False
    source_path, target_name = next(iter(targets.items()))
    if target_name != contract_name or not isinstance(source_path, str):
        return False
    source = ROOT / source_path
    return source.is_file() and re.search(rf"^\s*library\s+{re.escape(contract_name)}\b", source.read_text(), re.MULTILINE) is not None


def verify_compiled_runtime(rpc_url: str, contract_name: str, address: str, seen: set[tuple[str, str]] | None = None) -> None:
    """Compare deployed runtime with the source-commit artifact, masking only compiler references."""
    seen = set() if seen is None else seen
    identity = (contract_name, address.lower())
    if identity in seen:
        return
    seen.add(identity)
    artifact_path = ROOT / "out" / f"{contract_name}.sol" / f"{contract_name}.json"
    if not artifact_path.exists():
        fail(f"missing compiled artifact for {contract_name}: {artifact_path}")
    artifact_json = json.loads(artifact_path.read_text())
    artifact = artifact_json.get("deployedBytecode", {})
    expected = artifact.get("object")
    if not isinstance(expected, str) or not expected.startswith("0x"):
        fail(f"invalid deployed bytecode artifact for {contract_name}")
    actual = runtime_code(rpc_url, address)[2:]
    expected = expected[2:].lower()
    if len(expected) != len(actual):
        fail(f"runtime bytecode length differs from compiled {contract_name} artifact at {address}")
    expected_masked = list(expected)
    actual_masked = list(actual)
    references = artifact.get("immutableReferences", {})
    for reference_name, locations in references.items():
        if reference_name == "library_deploy_address" and not is_library_artifact(contract_name, artifact_json):
            fail(f"unexpected library self-address reference in non-library {contract_name}")
        for location in locations:
            start = int(location["start"]) * 2
            end = start + int(location["length"]) * 2
            if reference_name == "library_deploy_address":
                encoded_address = actual[start:end]
                if len(encoded_address) != 64 or encoded_address[:24] != "0" * 24 or encoded_address[-40:] != address[2:].lower():
                    fail(f"library self-address differs from deployed {contract_name} address")
            expected_masked[start:end] = "?" * (end - start)
            actual_masked[start:end] = "?" * (end - start)
    for contracts in artifact.get("linkReferences", {}).values():
        for linked_name, locations in contracts.items():
            for location in locations:
                start = int(location["start"]) * 2
                end = start + int(location["length"]) * 2
                linked_address = "0x" + actual[start:end]
                if not ADDR_RE.fullmatch(linked_address):
                    fail(f"invalid {linked_name} link in deployed {contract_name}")
                verify_compiled_runtime(rpc_url, linked_name, linked_address, seen)
                expected_masked[start:end] = "?" * (end - start)
                actual_masked[start:end] = "?" * (end - start)
    if expected_masked != actual_masked:
        fail(f"runtime bytecode differs from compiled {contract_name} artifact at {address}")


def call_address(rpc_url: str, address: str, selector: str) -> str:
    result = rpc_call(rpc_url, "eth_call", [{"to": address, "data": selector}, "latest"])
    if not isinstance(result, str) or not re.fullmatch(r"0x[0-9a-fA-F]{64}", result):
        fail(f"invalid address result from {address} for {selector}")
    return "0x" + result[-40:]


def call_bool(rpc_url: str, address: str, selector: str) -> bool:
    result = rpc_call(rpc_url, "eth_call", [{"to": address, "data": selector}, "latest"])
    if not isinstance(result, str) or not re.fullmatch(r"0x[0-9a-fA-F]{64}", result):
        fail(f"invalid boolean result from {address} for {selector}")
    return int(result, 16) == 1


def call_uint(rpc_url: str, address: str, selector: str) -> int:
    result = rpc_call(rpc_url, "eth_call", [{"to": address, "data": selector}, "latest"])
    if not isinstance(result, str) or not re.fullmatch(r"0x[0-9a-fA-F]{64}", result):
        fail(f"invalid uint result from {address} for {selector}")
    return int(result, 16)


def verify_vault_identity(rpc_url: str, factory: str, vault: str, manager: str, settlement: str, registry: str) -> None:
    is_vault_data = "0x652b9b41" + "0" * 24 + vault[2:]
    if not call_bool(rpc_url, factory, is_vault_data):
        fail(f"factory does not recognize event vault {vault}")
    if rpc_call(rpc_url, "eth_getCode", [vault, "latest"]) == "0x":
        fail(f"event vault has no runtime code: {vault}")
    if call_address(rpc_url, vault, "0x481c6a75").lower() != manager.lower():
        fail(f"event vault manager differs from expected manager: {vault}")
    if call_address(rpc_url, vault, "0xd3781d58").lower() != settlement.lower():
        fail(f"event vault settlement differs from expected settlement: {vault}")
    if call_address(rpc_url, vault, "0x7b103999").lower() != registry.lower():
        fail(f"event vault registry differs from expected registry: {vault}")


def vault_from_receipts(rpc_url: str, factory: str, transaction_hashes: list[str], settlement: str, registry: str) -> str:
    candidates: set[str] = set()
    for transaction_hash in transaction_hashes:
        receipt = rpc_call(rpc_url, "eth_getTransactionReceipt", [transaction_hash])
        if not isinstance(receipt, dict) or receipt.get("status") != "0x1":
            fail(f"factory call receipt was unsuccessful or missing: {transaction_hash}")
        for log in receipt.get("logs") or []:
            topics = log.get("topics") or []
            if (
                isinstance(log, dict)
                and str(log.get("address", "")).lower() == factory.lower()
                and len(topics) >= 4
                and str(topics[0]).lower() == VAULT_EVENT_TOPIC
                and str(topics[2])[-40:].lower() == ANVIL1[2:].lower()
                and str(topics[3])[-40:].lower() == settlement[2:].lower()
            ):
                candidates.add("0x" + str(topics[1])[-40:])
    if len(candidates) != 1:
        fail(f"expected exactly one VaultCreated event from {factory}, found {len(candidates)}")
    vault = candidates.pop()
    verify_vault_identity(rpc_url, factory, vault, ANVIL1, settlement, registry)
    return vault


def artifact_source_commit() -> str:
    if not MANIFEST_FILE.exists():
        fail(f"missing artifact manifest: {MANIFEST_FILE}")
    manifest = json.loads(MANIFEST_FILE.read_text())
    source_commit = manifest.get("contractsCommit")
    if not isinstance(source_commit, str) or not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        fail("manifest contractsCommit must be a 40-hex source commit")
    try:
        subprocess.run(
            ["git", "rev-parse", "--verify", f"{source_commit}^{{commit}}"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        subprocess.run(
            ["git", "diff", "--quiet", source_commit, "--", *PROVENANCE_PATHS],
            cwd=ROOT,
            check=True,
        )
    except subprocess.CalledProcessError:
        fail(
            "contract sources differ from deployments/manifest.json contractsCommit; "
            "regenerate ABI/manifest from the source commit before exporting addresses"
        )
    untracked = subprocess.check_output(
        [
            "git", "ls-files", "--others", "--exclude-standard", "--",
            *PROVENANCE_PATHS,
        ],
        cwd=ROOT,
        text=True,
    ).splitlines()
    if untracked:
        fail(
            "untracked contract source paths prevent a reproducible address export: "
            f"{', '.join(untracked)}"
        )
    return source_commit


def rebuild_source_artifacts() -> None:
    """Refresh `out/` from the source commit before treating it as provenance evidence."""
    try:
        subprocess.run(["forge", "build", "--force", "--offline"], cwd=ROOT, check=True)
    except subprocess.CalledProcessError as error:
        fail(f"could not rebuild source artifacts for runtime verification: {error}")


def prepare_artifact_verification() -> str:
    source_commit = artifact_source_commit()
    rebuild_source_artifacts()
    return source_commit


def output_file(value: str) -> Path:
    """Resolve an export location while keeping generated local state in this checkout."""
    output = Path(value)
    if not output.is_absolute():
        output = ROOT / output
    output = output.resolve()
    try:
        output.relative_to(ROOT.resolve())
    except ValueError:
        fail("--output must be inside the contracts checkout")
    return output


def catalog_rpc_url(output: Path, rpc_url: str) -> str:
    """Keep the published fixture stable while recording an isolated catalog's real RPC."""
    if output == OUT_FILE.resolve():
        return PUBLISHED_LOCAL_RPC_URL
    return rpc_url


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc-url", required=True, help="Explicit loopback Anvil RPC URL (chainId 31337)")
    parser.add_argument(
        "--output",
        default=str(OUT_FILE.relative_to(ROOT)),
        help="Address catalog output path, relative to this checkout (default: deployments/31337/addresses.json)",
    )
    args = parser.parse_args()
    require_local_anvil(args.rpc_url)
    v2_commit = prepare_artifact_verification()
    out_file = output_file(args.output)

    if not RUN_FILE.exists():
        fail(f"missing broadcast receipts: {RUN_FILE}")
    run = json.loads(RUN_FILE.read_text())
    if str(run.get("chain", "31337")) != "31337":
        fail(f"expected broadcast chain 31337, got {run.get('chain')}")

    disk_receipts = {receipt.get("transactionHash", "").lower(): receipt for receipt in run.get("receipts", [])}
    addresses: dict[str, str] = {}
    origins: dict[str, tuple[str, bool]] = {}
    counters: dict[str, int] = {}
    token_counter = 0
    settlement_symbol = "MOCK"
    factory_calls: dict[str, list[str]] = {"factory": [], "legacyFactory": []}

    def take(name: str, address: str, transaction_hash: str, root_create: bool, arguments: Any = None) -> None:
        nonlocal token_counter, settlement_symbol
        key = None
        if name in TOKEN_CONTRACTS:
            if token_counter == 0 and name == "NamedMockToken":
                if arguments != ["Demo USDG", "USDG", "6"]:
                    fail("unexpected named settlement constructor arguments")
                settlement_symbol = "USDG"
            if token_counter >= len(TOKEN_KEYS):
                fail(f"too many local token deployments ({name})")
            key = TOKEN_KEYS[token_counter]
            token_counter += 1
        elif name in ORDERED:
            index = counters.get(name, 0)
            if index >= len(ORDERED[name]):
                fail(f"too many {name} deployments")
            key = ORDERED[name][index]
            counters[name] = index + 1
        elif name in SINGLE:
            key = SINGLE[name]
        if key is None:
            return
        if key in addresses:
            fail(f"duplicate address key {key}")
        if not ADDR_RE.fullmatch(address):
            fail(f"invalid address for {key}: {address}")
        if not HASH_RE.fullmatch(transaction_hash):
            fail(f"missing transaction hash for {key}")
        addresses[key] = address
        origins[key] = (transaction_hash.lower(), root_create)

    for tx in run.get("transactions", []):
        transaction_hash = tx.get("hash", "")
        if tx.get("transactionType") in {"CREATE", "CREATE2"} and tx.get("contractAddress"):
            take(tx.get("contractName", ""), tx["contractAddress"], transaction_hash, True, tx.get("arguments"))
        if tx.get("transactionType") == "CALL":
            if tx.get("contractName") == "VaultFactory":
                factory_calls["factory"].append(transaction_hash)
            elif tx.get("contractName") == "LegacyVaultFactory":
                factory_calls["legacyFactory"].append(transaction_hash)

    required_groups = [TOKEN_KEYS, *ORDERED.values(), list(SINGLE.values())]
    required = [item for group in required_groups for item in group]
    missing = [key for key in required if key not in addresses]
    if missing:
        fail(f"missing deployed addresses: {missing}")

    for key in required:
        transaction_hash, root_create = origins[key]
        disk_receipt = disk_receipts.get(transaction_hash)
        if not disk_receipt or disk_receipt.get("status") != "0x1":
            fail(f"broadcast receipt was unsuccessful for {key}: {transaction_hash}")
        chain_receipt = rpc_call(args.rpc_url, "eth_getTransactionReceipt", [transaction_hash])
        if not isinstance(chain_receipt, dict) or chain_receipt.get("status") != "0x1":
            fail(f"on-chain receipt was unsuccessful or missing for {key}: {transaction_hash}")
        if root_create and (chain_receipt.get("contractAddress") or "").lower() != addresses[key].lower():
            fail(f"on-chain creation address differs for {key}")

    for key in factory_calls:
        if not factory_calls[key]:
            fail(f"missing {key} createVault call in broadcast")
    addresses["exampleVault"] = vault_from_receipts(
        args.rpc_url, addresses["factory"], factory_calls["factory"], addresses["settlementAsset"], addresses["registry"]
    )
    addresses["legacyExampleVault"] = vault_from_receipts(
        args.rpc_url, addresses["legacyFactory"], factory_calls["legacyFactory"], addresses["settlementAsset"], addresses["registry"]
    )
    required.extend(["exampleVault", "legacyExampleVault"])

    for factory_key, contract_name in (("factory", "VaultFactory"), ("legacyFactory", "LegacyVaultFactory")):
        factory_address = addresses[factory_key]
        if call_address(args.rpc_url, factory_address, "0xd3781d58").lower() != addresses["settlementAsset"].lower():
            fail(f"{factory_key} settlement differs from the exported settlement")
        if call_address(args.rpc_url, factory_address, "0x7b103999").lower() != addresses["registry"].lower():
            fail(f"{factory_key} registry differs from the exported registry")
        verify_compiled_runtime(args.rpc_url, contract_name, factory_address)
    if call_uint(args.rpc_url, addresses["factory"], "0x2ae9c600") != 2:
        fail("v2 factory protocolVersion is not 2")
    if call_uint(args.rpc_url, addresses["exampleVault"], "0x2ae9c600") != 2:
        fail("v2 vault protocolVersion is not 2")
    verify_compiled_runtime(args.rpc_url, "EquiVault", addresses["exampleVault"])
    verify_compiled_runtime(args.rpc_url, "LegacyEquiVault", addresses["legacyExampleVault"])
    escrow_address = call_address(args.rpc_url, addresses["exampleVault"], "0xdcbc3bb6")
    if call_uint(args.rpc_url, escrow_address, "0x2ae9c600") != 2:
        fail("v2 escrow protocolVersion is not 2")
    verify_compiled_runtime(args.rpc_url, "InvestmentEscrow", escrow_address)

    v2_hash = runtime_code_hash(args.rpc_url, addresses["factory"])
    v1_hash = runtime_code_hash(args.rpc_url, addresses["legacyFactory"])
    addresses = {key: addresses[key] for key in required}
    out = {
        "chainId": 31337,
        "rpcUrl": catalog_rpc_url(out_file, args.rpc_url),
        "network": "anvil-local",
        "note": "Local dev environment. Regenerate with an explicit loopback Anvil RPC URL, "
                "then run python3 script/export-addresses.py --rpc-url <rpc-url>.",
        "admin": ANVIL0,
        "treasury": ANVIL2,
        "manager": ANVIL1,
        "settlementSymbol": settlement_symbol,
        "settlementDecimals": 6,
        **addresses,
        "factories": [
            {"address": addresses["factory"], "protocolVersion": 2, "codeHash": v2_hash, "contractsCommit": v2_commit},
            {"address": addresses["legacyFactory"], "protocolVersion": 1, "codeHash": v1_hash, "contractsCommit": V1_COMMIT},
        ],
    }
    for key, contract in (("entryPoint", "EntryPoint"), ("executionFactory", "InvestmentExecutionFactory")):
        verify_compiled_runtime(args.rpc_url, contract, addresses[key])
    out["execution"] = {
        "version": 1, "entryPoint": addresses["entryPoint"], "factory": addresses["executionFactory"],
        "executor": "0x976EA74026E726554dB657fA54763abd0C3a0aa9",
        "entryPointCodeHash": runtime_code_hash(args.rpc_url, addresses["entryPoint"]),
        "factoryCodeHash": runtime_code_hash(args.rpc_url, addresses["executionFactory"]),
    }
    out_file.parent.mkdir(parents=True, exist_ok=True)
    out_file.write_text(json.dumps(out, indent=2) + "\n")
    print(f"wrote {out_file}")
    print(f"  v2 factory={out['factory']} hash={v2_hash}")
    print(f"  v1 factory={out['legacyFactory']} hash={v1_hash}")


if __name__ == "__main__":
    main()
