#!/usr/bin/env python3
"""Seed, inspect or refresh a dedicated local Anvil demo (never the shared 8545).

Start an isolated Anvil first. This tool never resets or stops a running chain.
The minimal DeployLocal/E2E flow remains separate from this opt-in rich fixture.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
ADDRESSES = ROOT / "deployments/31337/addresses.json"
MANIFEST = ROOT / "deployments/31337/demo.json"
ADMIN = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
ASSET_EVENT = "AssetRegistered(address,address,address,address,uint48,uint8)"
VAULT_EVENT = "VaultCreated(address,address,address,uint256,uint8,uint256,uint16,uint16,uint16,uint16)"


def require(value, message):
    if not value:
        raise RuntimeError(message)


def run(*args, env=None, timeout=60):
    result = subprocess.run(list(map(str, args)), cwd=ROOT, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"Command failed: {' '.join(map(str, args))}\n{result.stderr}\n{result.stdout}")
    return result.stdout.strip()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        raise RuntimeError("RPC redirects are not allowed.")


class Demo:
    def __init__(self, url):
        parsed = urllib.parse.urlsplit(url)
        require(parsed.scheme == "http" and parsed.hostname == "127.0.0.1"
                and parsed.port not in (None, 8545) and not parsed.username
                and not parsed.password and parsed.path in ("", "/")
                and not parsed.query and not parsed.fragment,
                "Use a dedicated http://127.0.0.1:<port> RPC; shared 8545 is forbidden.")
        self.url = url
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def rpc(self, method, params=None):
        request = urllib.request.Request(self.url, json.dumps({"jsonrpc": "2.0", "id": 1,
            "method": method, "params": params or []}).encode(), {"Content-Type": "application/json"})
        with self.http.open(request, timeout=20) as response:
            data = json.load(response)
        require("error" not in data, f"{method}: {data.get('error')}")
        return data["result"]

    def guard(self):
        require(int(self.rpc("eth_chainId"), 16) == 31337, "Expected chain 31337.")
        require(self.rpc("web3_clientVersion").lower().startswith("anvil/"), "Expected Anvil.")
        require(ADMIN.lower() in [a.lower() for a in self.rpc("eth_accounts")], "Expected unlocked local accounts.")

    def cast(self, *args):
        return json.loads(run("cast", *args, "--rpc-url", self.url, "--json"))

    def call(self, address, signature, *args):
        return self.cast("call", address, signature, *args)[0]

    def logs(self, address, signature):
        topic = run("cast", "keccak", signature)
        return self.rpc("eth_getLogs", [{"address": address, "fromBlock": "0x0", "toBlock": "latest", "topics": [topic]}])

    def identity(self, factory):
        require(self.rpc("eth_getCode", [factory, "latest"]) != "0x", "Factory is not deployed.")
        logs = self.logs(factory, VAULT_EVENT)
        require(logs, "Missing factory deployment event.")
        first = logs[0]
        return {"chainId": 31337, "factory": factory,
                "genesisHash": self.rpc("eth_getBlockByNumber", ["0x0", False])["hash"],
                "deploymentBlock": str(int(first["blockNumber"], 16)),
                "deploymentBlockHash": first["blockHash"]}

    def load(self):
        require(MANIFEST.exists(), "Demo manifest missing. Seed a fresh dedicated chain first.")
        manifest = json.loads(MANIFEST.read_text())
        require(manifest["schema"] == "equivaults-local-demo/v1", "Unsupported demo manifest.")
        for key, value in self.identity(manifest["factory"]).items():
            require(manifest[key] == value, f"Demo deployment mismatch: {key}.")
        return manifest

    def seed(self):
        if MANIFEST.exists():
            manifest = json.loads(MANIFEST.read_text())
            if self.rpc("eth_getCode", [manifest["factory"], "latest"]) != "0x":
                self.load()
                print("Existing demo verified; no duplicate vaults or deposits created.")
                return
        progress_file = ROOT / ".local-demo/progress.json"
        if progress_file.exists():
            progress = json.loads(progress_file.read_text())
            for key, value in self.identity(progress["factory"]).items():
                require(progress[key] == value, f"Seed progress belongs to another deployment: {key}.")
            addresses = json.loads(ADDRESSES.read_text())
            if progress["stage"] == "seeded":
                self.export(addresses)
                self.verify(self.load())
                return
            require(progress["stage"] == "baseline"
                    and int(self.call(progress["factory"], "vaultCount()(uint256)")) == 1
                    and self.rpc("eth_getTransactionCount", [ADMIN, "latest"]) == progress["adminNonce"],
                    "Partial seeding or concurrent chain changes detected; inspect broadcast logs before recovery.")
            self.seed_extension(addresses, progress_file)
            return
        require(int(self.rpc("eth_getTransactionCount", [ADMIN, "latest"]), 16) == 0
                and int(self.rpc("eth_blockNumber"), 16) == 0,
                "Seeding requires a fresh dedicated chain. Partial/foreign state is preserved; inspect broadcast logs before recovery.")
        env = {**os.environ, "LOCAL_DEMO": "true"}
        self.broadcast("DeployLocal", env)
        print(run(sys.executable, "script/export-addresses.py"), flush=True)
        addresses = json.loads(ADDRESSES.read_text())
        progress = {**self.identity(addresses["factory"]), "stage": "baseline",
                    "adminNonce": self.rpc("eth_getTransactionCount", [ADMIN, "latest"])}
        progress_file.write_text(json.dumps(progress) + "\n")
        self.seed_extension(addresses, progress_file)

    def seed_extension(self, addresses, progress_file):
        env = {**os.environ, "LOCAL_DEMO": "true"}
        env.update({"DEMO_REGISTRY": addresses["registry"], "DEMO_FACTORY": addresses["factory"],
                    "DEMO_SETTLEMENT": addresses["settlementAsset"], "DEMO_TOKEN_A": addresses["tokenA"],
                    "DEMO_TOKEN_B": addresses["tokenB"]})
        self.broadcast("SeedLocalDemo", env)
        progress = {**self.identity(addresses["factory"]), "stage": "seeded"}
        progress_file.write_text(json.dumps(progress) + "\n")
        self.export(addresses)
        self.verify(self.load())

    def broadcast(self, name, env):
        print(f"Broadcasting {name} on {self.url} (sequential receipts)...", flush=True)
        # Forge keeps the resumable broadcast receipts on disk. No automatic retry/reset.
        log = ROOT / ".local-demo" / f"{name}.log"
        with log.open("w") as handle:
            result = subprocess.run(["forge", "script", f"script/{name}.s.sol", "--rpc-url", self.url,
                "--broadcast", "--unlocked", "--sender", ADMIN, "--slow"], cwd=ROOT, env=env,
                stdout=handle, stderr=subprocess.STDOUT, timeout=600)
        require(result.returncode == 0, f"{name} failed. Chain preserved; inspect {log}.")

    def export(self, addresses):
        factory, registry = addresses["factory"], addresses["registry"]
        catalog = json.loads((ROOT / "script/demo-vaults.json").read_text())
        assets = []
        for log in self.logs(registry, ASSET_EVENT):
            address = "0x" + log["topics"][1][-40:]
            config = self.call(registry, "assetConfig(address)((address,address,address,uint48,uint8,uint8))", address)
            assets.append({"address": address, "symbol": self.call(address, "symbol()(string)"),
                           "decimals": int(config[5]), "primaryOracle": config[0], "fallbackOracle": config[1],
                           "pool": config[2], "maxPriceAge": int(config[3])})
        count = int(self.call(factory, "vaultCount()(uint256)"))
        require(count == len(catalog["vaults"]), "Vault catalog/count mismatch; no manifest published.")
        vaults = []
        for index, spec in enumerate(catalog["vaults"]):
            address = self.call(factory, "vaults(uint256)(address)", index)
            manager = self.call(address, "manager()(address)")
            vaults.append({**spec, "address": address, "manager": manager})
        accounts = self.rpc("eth_accounts")
        managers = [{"address": accounts[item["accountIndex"]], "name": item["name"],
                     "description": item["description"]} for item in catalog["managers"]]
        manifest = {"schema": "equivaults-local-demo/v1", **self.identity(factory),
                    "registry": registry, "settlementAsset": addresses["settlementAsset"],
                    "note": "Synthetic local fixtures; prices are illustrative, not market data.",
                    "assets": assets, "vaults": vaults, "managers": managers}
        temporary = MANIFEST.with_suffix(".tmp")
        temporary.write_text(json.dumps(manifest, indent=2) + "\n")
        temporary.replace(MANIFEST)
        print(f"Exported {MANIFEST}", flush=True)

    def verify(self, manifest):
        assets = manifest["assets"]
        require(len(assets) == 8 and len({a["address"].lower() for a in assets}) == 8, "Expected eight distinct assets.")
        require(int(self.call(manifest["factory"], "vaultCount()(uint256)")) == len(manifest["vaults"]),
                "Vault count changed; manual additions are preserved, but fixture verification needs a new export.")
        sizes, funded, managers = set(), 0, set()
        for vault in manifest["vaults"]:
            address = vault["address"]
            basket = self.call(address, "basketAssets()(address[])")
            weights = list(map(int, self.call(address, "basketWeightsBps()(uint16[])")))
            require(1 <= len(basket) <= 5 and len(basket) == len(weights) and sum(weights) == 10_000
                    and min(weights) >= 500, "Invalid demo basket.")
            sizes.add(len(basket))
            funded += int(self.call(address, "totalSupply()(uint256)")) > 0
            managers.add(self.call(address, "manager()(address)").lower())
        require({1, 2, 3, 5} <= sizes, "Missing requested basket sizes.")
        require(len(managers) >= 4 and funded >= 8, "Insufficient demo diversity/funded vaults.")
        print(json.dumps({"assets": len(assets), "vaults": len(manifest["vaults"]),
                          "basketSizes": sorted(sizes), "managers": len(managers), "fundedVaults": funded}), flush=True)

    def refresh(self):
        manifest = self.load()
        expected = json.loads((ROOT / "out/Mocks.sol/MockOracle.json").read_text())["deployedBytecode"]["object"].lower()
        updates = []
        for asset in manifest["assets"]:
            config = self.call(manifest["registry"], "assetConfig(address)((address,address,address,uint48,uint8,uint8))", asset["address"])
            for index, key in enumerate(("primaryOracle", "fallbackOracle")):
                oracle = asset[key]
                require(config[index].lower() == oracle.lower(), "Registry feed differs from demo manifest.")
                require(self.rpc("eth_getCode", [oracle, "latest"]).lower() == expected, "Refusing a non-MockOracle runtime.")
                price = int(self.call(oracle, "getPrice(address,address)(uint256,uint256)", asset["address"], manifest["settlementAsset"]))
                require(price > 0, "Refusing to refresh a zero mock price.")
                updates.append((oracle, asset["address"], price))
        require(len({oracle.lower() for oracle, _, _ in updates}) == 16, "Expected sixteen distinct demo oracles.")
        self.rpc("evm_mine")
        for oracle, asset, price in updates:
            require(int(self.call(oracle, "getPrice(address,address)(uint256,uint256)", asset, manifest["settlementAsset"])) == price,
                    "A concurrent writer changed the price; stop it before retrying.")
            timestamp = int(self.rpc("eth_getBlockByNumber", ["latest", False])["timestamp"], 16)
            receipt = self.cast("send", oracle, "setPrice(uint256,uint256)", price, timestamp, "--unlocked", "--from", ADMIN)
            require(int(str(receipt["status"]), 0) == 1, "Oracle refresh reverted.")
            observed = self.cast("call", oracle, "getPrice(address,address)(uint256,uint256)", asset, manifest["settlementAsset"])
            require(list(map(int, observed)) == [price, timestamp], "Oracle verification failed.")
        for asset in manifest["assets"]:
            self.cast("call", manifest["registry"], "getPrice(address,address)(uint256,uint256)", asset["address"], manifest["settlementAsset"])
        print("Refreshed all sixteen demo oracles; prices and positions preserved.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("seed", "verify", "refresh"))
    parser.add_argument("--rpc-url", default="http://127.0.0.1:8546")
    args = parser.parse_args()
    demo = Demo(args.rpc_url)
    directory = ROOT / ".local-demo"
    directory.mkdir(exist_ok=True)
    with (directory / "operation.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        demo.guard()
        if args.action == "seed":
            demo.seed()
        elif args.action == "refresh":
            demo.refresh()
        else:
            demo.verify(demo.load())


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
        sys.exit(f"local-demo: {error}")
