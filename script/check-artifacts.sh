#!/usr/bin/env bash
# Validate the published integration artifacts as an independent consumer would.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import datetime
import json
import re
from pathlib import Path

EXPECTED_ABIS = (
    "AssetRegistry.json",
    "EquiVault.json",
    "IERC20.json",
    "IPriceOracle.json",
    "ISwapRouter.json",
    "RebalanceEngine.json",
    "VaultFactory.json",
)
CORE_ADDRESS_FIELDS = ("registry", "factory", "engine", "exampleVault")
LOCAL_ADDRESS_FIELDS = (
    "admin",
    "treasury",
    "manager",
    "settlementAsset",
    "tokenA",
    "tokenB",
    "primaryOracleA",
    "fallbackOracleA",
    "primaryOracleB",
    "fallbackOracleB",
    "poolA",
    "poolB",
)
ADDRESS_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")


def load_json(path: Path):
    with path.open(encoding="utf-8") as source:
        return json.load(source)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def contains_workstation_path(value) -> bool:
    if isinstance(value, str):
        return "/home/" in value
    if isinstance(value, dict):
        return any(contains_workstation_path(item) for item in value.values())
    if isinstance(value, list):
        return any(contains_workstation_path(item) for item in value)
    return False


manifest = load_json(Path("deployments/manifest.json"))
require(isinstance(manifest, dict), "manifest must be an object")
require(manifest.get("schema") == "equivaults-integration-artifacts/v1", "manifest schema")
require(not contains_workstation_path(manifest), "workstation path leaked in manifest")
require(isinstance(manifest.get("contractsCommit"), str) and COMMIT_RE.fullmatch(manifest["contractsCommit"]), "contractsCommit must be a 40-hex git hash")
require(isinstance(manifest.get("generatedAt"), str), "generatedAt must be an ISO date")
datetime.date.fromisoformat(manifest["generatedAt"])
require(manifest.get("abiDir") == "abi", "ABI directory must be the published abi/ directory")
require(manifest.get("abiFiles") == list(EXPECTED_ABIS), "manifest ABI list is incomplete or unexpected")

for filename in EXPECTED_ABIS:
    artifact_path = Path("abi") / filename
    require(artifact_path.is_file(), f"missing ABI: {artifact_path}")
    abi = load_json(artifact_path)
    require(isinstance(abi, list) and abi, f"empty or invalid ABI: {artifact_path}")
    require(
        any(isinstance(entry, dict) and entry.get("type") in {"function", "event", "error"} for entry in abi),
        f"no consumer-callable entries in ABI: {artifact_path}",
    )

chains = manifest.get("chains")
require(isinstance(chains, dict) and chains, "manifest lists no chains")
for chain_id, chain in chains.items():
    require(isinstance(chain_id, str) and chain_id.isdecimal(), f"invalid chain ID: {chain_id!r}")
    require(isinstance(chain, dict), f"invalid chain entry: {chain_id}")
    expected_address_file = f"deployments/{chain_id}/addresses.json"
    require(chain.get("addressesFile") == expected_address_file, f"unexpected addresses file for chain {chain_id}")
    require(isinstance(chain.get("network"), str) and chain["network"], f"missing network name for chain {chain_id}")

    address_file = Path(expected_address_file)
    require(address_file.is_file(), f"missing addresses file: {address_file}")
    addresses = load_json(address_file)
    require(isinstance(addresses, dict), f"addresses must be an object: {address_file}")
    require(addresses.get("chainId") == int(chain_id), f"chainId mismatch in {address_file}")
    for field in CORE_ADDRESS_FIELDS:
        require(ADDRESS_RE.fullmatch(addresses.get(field, "")) is not None, f"invalid {field} in {address_file}")

    if chain_id == "31337":
        require(chain.get("network") == "anvil-local", "chain 31337 must be anvil-local")
        require(addresses.get("rpcUrl") == "http://127.0.0.1:8545", "unexpected local RPC URL")
        for field in LOCAL_ADDRESS_FIELDS:
            require(ADDRESS_RE.fullmatch(addresses.get(field, "")) is not None, f"invalid {field} in {address_file}")
        require(isinstance(addresses.get("settlementSymbol"), str) and addresses["settlementSymbol"], "missing settlement symbol")
        decimals = addresses.get("settlementDecimals")
        require(isinstance(decimals, int) and not isinstance(decimals, bool) and 0 <= decimals <= 255, "invalid settlement decimals")

    require(not contains_workstation_path(addresses), f"workstation path leaked in {address_file}")
    print(f"  chain {chain_id}: {address_file} ok")

print(f"artifacts OK: {len(EXPECTED_ABIS)} ABI files, {len(chains)} chain(s), manifest at {manifest['contractsCommit'][:8]}")
PY
