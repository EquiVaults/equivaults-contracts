#!/usr/bin/env bash
# Validate the published integration artifacts as an independent consumer would.
set -euo pipefail
cd "$(dirname "$0")/.."

RPC_URL=""
if [ "$#" -eq 2 ] && [ "$1" = "--rpc-url" ]; then
  RPC_URL="$2"
elif [ "$#" -ne 0 ]; then
  echo "usage: $0 [--rpc-url http://127.0.0.1:8545]" >&2
  exit 2
fi

python3 - "$RPC_URL" <<'PY'
import datetime
import json
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

EXPECTED_ABIS = (
    "AssetRegistry.json", "EntryPoint.json", "EquiVault.json", "IERC20.json", "IPriceOracle.json",
    "ISwapRouter.json", "InvestmentEscrow.json", "InvestmentExecutionAccount.json", "InvestmentExecutionFactory.json", "RebalanceEngine.json", "VaultFactory.json",
)
CORE_ADDRESS_FIELDS = ("registry", "factory", "legacyFactory", "engine", "exampleVault", "legacyExampleVault")
LOCAL_ADDRESS_FIELDS = (
    "admin", "treasury", "manager", "settlementAsset", "tokenA", "tokenB", "primaryOracleA",
    "fallbackOracleA", "primaryOracleB", "fallbackOracleB", "poolA", "poolB",
)
ADDRESS_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
HASH_RE = re.compile(r"^0x[0-9a-fA-F]{64}$")
rpc_url = sys.argv[1]


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
require(manifest.get("protocolVersion") == 2, "manifest protocolVersion must be 2")
require(manifest.get("capabilities", {}).get("progressiveInvestment") == {"enabled": True, "status": "local", "personalPriceLimits": {"enabled": True, "version": 1}, "investorFundedExecution": {"enabled": True, "version": 1, "entryPointVersion": "0.9"}}, "progressive investment and price-limit local capabilities")
require(manifest.get("abiDir") == "abi", "ABI directory must be the published abi/ directory")
require(manifest.get("abiFiles") == list(EXPECTED_ABIS), "manifest ABI list is incomplete or unexpected")

for filename in EXPECTED_ABIS:
    artifact_path = Path("abi") / filename
    require(artifact_path.is_file(), f"missing ABI: {artifact_path}")
    abi = load_json(artifact_path)
    require(isinstance(abi, list) and abi, f"empty or invalid ABI: {artifact_path}")
    require(any(isinstance(entry, dict) and entry.get("type") in {"function", "event", "error"} for entry in abi), f"no consumer-callable entries in ABI: {artifact_path}")
    if filename == "InvestmentEscrow.json":
        functions = {entry.get("name") for entry in abi if entry.get("type") == "function"}
        require({"priceLimitsVersion", "createRequestWithLimits", "getRequestPriceLimits"} <= functions, "missing advertised price-limit interface")

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

    factories = addresses.get("factories")
    require(isinstance(factories, list) and len(factories) == 2, f"invalid factories catalog in {address_file}")
    by_version = {entry.get("protocolVersion"): entry for entry in factories if isinstance(entry, dict)}
    require(set(by_version) == {1, 2}, f"factories catalog must contain v1 and v2 in {address_file}")
    for version, entry in by_version.items():
        require(ADDRESS_RE.fullmatch(entry.get("address", "")) is not None, f"invalid v{version} factory address")
        require(HASH_RE.fullmatch(entry.get("codeHash", "")) is not None, f"invalid v{version} factory codeHash")
        require(isinstance(entry.get("contractsCommit"), str) and COMMIT_RE.fullmatch(entry["contractsCommit"]), f"invalid v{version} contractsCommit")
    require(by_version[2]["address"].lower() == addresses["factory"].lower(), "primary factory must be v2")
    require(by_version[1]["address"].lower() == addresses["legacyFactory"].lower(), "legacy factory must be v1")
    require(by_version[2]["contractsCommit"] == manifest["contractsCommit"], "v2 factory source commit must match manifest")

    if chain_id == "31337":
        require(chain.get("network") == "anvil-local", "chain 31337 must be anvil-local")
        require(addresses.get("rpcUrl") == "http://127.0.0.1:8545", "published local RPC URL must be canonical")
        for field in LOCAL_ADDRESS_FIELDS:
            require(ADDRESS_RE.fullmatch(addresses.get(field, "")) is not None, f"invalid {field} in {address_file}")
        require(isinstance(addresses.get("settlementSymbol"), str) and addresses["settlementSymbol"], "missing settlement symbol")
        decimals = addresses.get("settlementDecimals")
        require(isinstance(decimals, int) and not isinstance(decimals, bool) and 0 <= decimals <= 255, "invalid settlement decimals")

    require(not contains_workstation_path(addresses), f"workstation path leaked in {address_file}")
    if rpc_url:
        parsed = urllib.parse.urlparse(rpc_url)
        require(parsed.scheme in {"http", "https"} and parsed.hostname in {"127.0.0.1", "localhost", "::1"}, "RPC must be loopback")
        request = urllib.request.Request(rpc_url, data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_chainId", "params": []}).encode(), headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=10) as response:
            require(json.loads(response.read()).get("result") == "0x7a69", "RPC must be chainId 31337")
        for entry in factories:
            code = subprocess.check_output(["cast", "code", "--rpc-url", rpc_url, entry["address"]], text=True).strip()
            actual_hash = subprocess.check_output(["cast", "keccak", code], text=True).strip().lower()
            require(actual_hash == entry["codeHash"].lower(), f"on-chain code hash mismatch for v{entry['protocolVersion']} factory")
        escrow = subprocess.check_output(["cast", "call", addresses["exampleVault"], "investmentEscrow()(address)", "--rpc-url", rpc_url], text=True).strip()
        price_limits_version = subprocess.check_output(["cast", "call", escrow, "priceLimitsVersion()(uint256)", "--rpc-url", rpc_url], text=True).strip()
        require(price_limits_version == "1", "deployed escrow does not advertise price-limit version 1")
    print(f"  chain {chain_id}: {address_file} ok")

print(f"artifacts OK: {len(EXPECTED_ABIS)} ABI files, {len(chains)} chain(s), manifest at {manifest['contractsCommit'][:8]}")
PY
