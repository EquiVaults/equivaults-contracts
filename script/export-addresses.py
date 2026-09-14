#!/usr/bin/env python3
"""Export deployments/31337/addresses.json from the DeployLocal broadcast receipts.

Run after `forge script script/DeployLocal.s.sol --broadcast --slow` (chainId 31337):
  python3 script/export-addresses.py

Why not vm.writeJson inside the script: with --broadcast, forge re-executes the recorded
transactions from the sender EOA, so the real deployed addresses (receipts) differ from the
simulation-only ones the script would compute. Parsing run-latest.json guarantees the file
matches the actual chain state.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUN_FILE = ROOT / "broadcast" / "DeployLocal.s.sol" / "31337" / "run-latest.json"
OUT_FILE = ROOT / "deployments" / "31337" / "addresses.json"

# Canonical Anvil default accounts, mirroring DeployLocal.s.sol.
ANVIL0 = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"  # broadcaster / registry admin
ANVIL1 = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"  # vault manager
ANVIL2 = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"  # treasury

ADDR_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")

# contractName -> ordered occurrences -> address key (MockOracle/MockPool appear several times;
# the DeployLocal.s.sol deployment order fixes the mapping). Tokens are handled separately so the
# opt-in LOCAL_DEMO NamedMockToken metadata class exports the same tokenA/tokenB address keys.
ORDERED = {
    "MockOracle": ["primaryOracleA", "fallbackOracleA", "primaryOracleB", "fallbackOracleB"],
    "MockPool": ["poolA", "poolB"],
}
TOKEN_KEYS = ["settlementAsset", "tokenA", "tokenB"]
TOKEN_CONTRACTS = {"MockToken", "NamedMockToken"}
SINGLE = {
    "AssetRegistry": "registry",
    "VaultFactory": "factory",
    "RebalanceEngine": "engine",
    "EquiVault": "exampleVault",  # appears only in the createVault tx additionalContracts
}


def main() -> None:
    if not RUN_FILE.exists():
        sys.exit(f"missing broadcast receipts: {RUN_FILE}\n"
                 "run: anvil --chain-id 31337 && forge script script/DeployLocal.s.sol "
                 "--rpc-url http://127.0.0.1:8545 --broadcast --unlocked --sender "
                 "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --slow")

    run = json.loads(RUN_FILE.read_text())
    chain_id = str(run.get("chain", "31337"))
    if chain_id != "31337":
        sys.exit(f"expected chain 31337, got {chain_id}")

    addresses: dict[str, str] = {}
    counters: dict[str, int] = {}
    token_counter = 0
    settlement_symbol = "MOCK"

    def take(name: str, addr: str, arguments=None) -> None:
        nonlocal token_counter, settlement_symbol
        key = None
        if name in TOKEN_CONTRACTS:
            if token_counter == 0 and name == "NamedMockToken":
                if arguments != ["Demo USDG", "USDG", "6"]:
                    sys.exit("unexpected named settlement constructor arguments")
                settlement_symbol = "USDG"
            if token_counter >= len(TOKEN_KEYS):
                sys.exit(f"too many local token deployments ({name})")
            key = TOKEN_KEYS[token_counter]
            token_counter += 1
        elif name in ORDERED:
            i = counters.get(name, 0)
            if i >= len(ORDERED[name]):
                sys.exit(f"too many {name} deployments")
            key = ORDERED[name][i]
            counters[name] = i + 1
        elif name in SINGLE:
            key = SINGLE[name]
        if key is not None:
            if key in addresses:
                sys.exit(f"duplicate address key {key}")
            addresses[key] = addr

    for tx in run["transactions"]:
        if tx.get("transactionType") in ("CREATE", "CREATE2") and tx.get("contractAddress"):
            take(tx["contractName"], tx["contractAddress"], tx.get("arguments"))
        for extra in tx.get("additionalContracts") or []:
            if extra.get("transactionType") == "CREATE" and extra.get("address"):
                take(extra["contractName"], extra["address"])

    required = [TOKEN_KEYS] + list(ORDERED.values()) + [v for v in SINGLE.values()]
    required = [k for group in required for k in (group if isinstance(group, list) else [group])]
    missing = [k for k in required if k not in addresses]
    if missing:
        sys.exit(f"missing deployed addresses: {missing}")

    for key, addr in addresses.items():
        if not ADDR_RE.fullmatch(addr):
            sys.exit(f"invalid address for {key}: {addr}")

    addresses = {k: addresses[k] for k in required}  # stable key order
    out = {
        "chainId": 31337,
        "rpcUrl": "http://127.0.0.1:8545",
        "network": "anvil-local",
        "note": "Local dev environment. Regenerate with: anvil --chain-id 31337 && "
                "forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 "
                "--broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 "
                "--slow && python3 script/export-addresses.py",
        "admin": ANVIL0,
        "treasury": ANVIL2,
        "manager": ANVIL1,
        "settlementSymbol": settlement_symbol,
        "settlementDecimals": 6,
        **addresses,
    }
    OUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    OUT_FILE.write_text(json.dumps(out, indent=2) + "\n")
    print(f"wrote {OUT_FILE}")
    print(f"  factory={out['factory']} registry={out['registry']} vault={out['exampleVault']}")


if __name__ == "__main__":
    main()
