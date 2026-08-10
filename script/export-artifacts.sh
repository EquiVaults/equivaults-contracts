#!/usr/bin/env bash
# Regenerate the committed integration artifacts for external clients (the frontend):
#   abi/                    - ABI JSONs of the contracts and interfaces a client needs
#   deployments/manifest.json - version manifest (contracts commit, date, artifact list)
# The per-chain addresses (deployments/<chainId>/addresses.json) come from the deploy scripts
# against a live chain (Anvil for local dev), not from this export.
set -euo pipefail
cd "$(dirname "$0")/.."

forge build

rm -rf abi
mkdir -p abi

CONTRACTS="AssetRegistry EquiVault IERC20 IPriceOracle ISwapRouter RebalanceEngine VaultFactory"
for c in $CONTRACTS; do
  src="out/$c.sol/$c.json"
  if [ ! -f "$src" ]; then
    echo "WARN: artifact missing for $c (out/$c.sol/$c.json)" >&2
    continue
  fi
  python3 - "$src" "abi/$c.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
abi = data.get("abi")
if not isinstance(abi, list) or not abi:
    raise SystemExit(f"no ABI array in {sys.argv[1]}")
json.dump(abi, open(sys.argv[2], "w"), indent=2)
print(f"  abi/{sys.argv[2].split('/')[-1]} ({len(abi)} entries)")
PY
done

COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
DATE="$(date +%Y-%m-%d)"
mkdir -p deployments
python3 - "$COMMIT" "$DATE" <<'PY'
import json, os, sys
commit, date = sys.argv[1], sys.argv[2]
abi_files = sorted(f for f in os.listdir("abi") if f.endswith(".json"))
manifest = {
    "schema": "equivaults-integration-artifacts/v1",
    "contractsCommit": commit,
    "generatedAt": date,
    "abiDir": "abi",
    "abiFiles": abi_files,
    "chains": {
        "31337": {
            "addressesFile": "deployments/31337/addresses.json",
            "network": "anvil-local",
            "note": "Regenerate with: anvil --chain-id 31337 && forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 && python3 script/export-addresses.py"
        }
    },
    "note": "Regenerate ABI + manifest after any contract change: ./script/export-artifacts.sh"
}
json.dump(manifest, open("deployments/manifest.json", "w"), indent=2)
print("  deployments/manifest.json (commit %s, %d ABI files)" % (commit, len(abi_files)))
PY

echo "Done: abi/ and deployments/manifest.json updated."
