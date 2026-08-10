#!/usr/bin/env bash
# Consumer-side validation of the published integration artifacts, from a clean checkout:
# loads abi/*.json and deployments/*/addresses.json, checks manifest integrity and addresses.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import json, os, re, sys

manifest = json.load(open("deployments/manifest.json"))
assert manifest.get("schema") == "equivaults-integration-artifacts/v1", "manifest schema"
assert re.fullmatch(r"[0-9a-f]{40}", manifest.get("contractsCommit", "")), "contractsCommit must be a 40-hex git hash"

addr_re = re.compile(r"^0x[0-9a-fA-F]{40}$")
count = 0
for f in manifest.get("abiFiles", []):
    p = os.path.join(manifest.get("abiDir", "abi"), f)
    abi = json.load(open(p))
    assert isinstance(abi, list) and len(abi) > 0, f"empty/invalid ABI: {p}"
    assert any(e.get("type") in ("function", "event", "error") for e in abi), f"no callable entries in {p}"
    count += 1

chains = manifest.get("chains", {})
assert chains, "manifest lists no chains"
for chain_id, info in chains.items():
    addr_file = info["addressesFile"]
    data = json.load(open(addr_file))
    assert str(data.get("chainId")) == chain_id, f"chainId mismatch in {addr_file}"
    bad = [k for k, v in data.items() if k.endswith("Address") and not addr_re.fullmatch(v)]
    bad += [k for k, v in data.items() if k in ("registry", "factory", "rebalanceEngine", "exampleVault", "settlementAsset") and not addr_re.fullmatch(v)]
    assert not bad, f"invalid addresses in {addr_file}: {bad}"
    print(f"  chain {chain_id}: {addr_file} ok")

print(f"artifacts OK: {count} ABI files, {len(chains)} chain(s), manifest at {manifest['contractsCommit'][:8]}")
PY
