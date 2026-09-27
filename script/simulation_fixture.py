#!/usr/bin/env python3
"""Create or read the opt-in, idempotent local simulation fixture.

This extends a verified ``local-demo.py seed`` deployment on a dedicated Anvil
chain. It never starts, stops, resets, or writes to a chain until ``ensure`` is
called explicitly. ``load`` is read-only and fails closed on a different demo.
"""
import json
import importlib.util
import os
from pathlib import Path
import time

_LOCAL_DEMO_SPEC = importlib.util.spec_from_file_location("local_demo", Path(__file__).with_name("local-demo.py"))
assert _LOCAL_DEMO_SPEC and _LOCAL_DEMO_SPEC.loader
_LOCAL_DEMO = importlib.util.module_from_spec(_LOCAL_DEMO_SPEC)
_LOCAL_DEMO_SPEC.loader.exec_module(_LOCAL_DEMO)
DEMO_DIRECTORY = _LOCAL_DEMO.DEMO_DIRECTORY
Demo = _LOCAL_DEMO.Demo
require = _LOCAL_DEMO.require


SCHEMA = "equivaults-local-simulation-fixture/v1"
FIXTURE_PATH = DEMO_DIRECTORY / "simulation-fixture.json"
PROGRESS_PATH = DEMO_DIRECTORY / "simulation-fixture.progress.json"
ADMIN = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
MARKET_ACTOR = "0x10000000000000000000000000000000000000f0"
EXECUTOR = "0x976EA74026E726554dB657fA54763abd0C3a0aa9"
BUNDLER = "0x14dC79964da2C08b23698B3D3cc7Ca32193d9955"

PERSONAS = (
    ("0x1000000000000000000000000000000000000001", "0xEarlyInvestor", "investor",
     "Established position before the staged market path."),
    ("0x1000000000000000000000000000000000000002", "0xLateInvestor", "investor",
     "Funded investor; the engine opens the position after the rise."),
    ("0x1000000000000000000000000000000000000003", "0xPatientInvestor", "investor",
     "Open progressive request with personal price limits."),
    ("0x1000000000000000000000000000000000000004", "0xWhaleInvestor", "investor",
     "Large constrained request against the bottleneck route."),
    ("0x1000000000000000000000000000000000000005", "0xMixedInvestor", "investor",
     "Diversified shared-pool position."),
    ("0x1000000000000000000000000000000000000006", "0xExitInvestor", "investor",
     "Has entered and partially withdrawn a volatile position."),
    ("0x1000000000000000000000000000000000000007", "0xBlockedInvestor", "investor",
     "Open request whose below-market personal ceiling blocks fills."),
    ("0x1000000000000000000000000000000000000008", "0xNewInvestor", "investor",
     "Native- and settlement-funded wallet with no investment history."),
)

ASSET_SPECS = (
    ("RALLY", "rally", "Stress Rally asset with a bounded but healthy route."),
    ("BOTTL", "stress", "Deliberately limited single-asset route for constrained demand."),
    ("ILLQ", "stress", "Low-reserve route used by the illiquid basket."),
    ("VOLX", "drawdown", "Volatile asset used for drawdown and partial-exit scenarios."),
    ("SHARE", "stress", "Shared liquidity route used by concurrent vault positions."),
)
VAULT_SPECS = (
    ("Stress Healthy Growth", "healthy", "rally", "Healthy two-asset basket with a shared-pool leg."),
    ("Stress Single Bottleneck", "single-bottleneck", "stress", "Single asset with deliberately limited reserves."),
    ("Stress Illiquid Basket", "illiquid-basket", "stress", "Three-asset basket containing an illiquid route."),
    ("Stress Volatile Focus", "volatile", "drawdown", "Volatile position with a recorded partial withdrawal."),
    ("Stress Shared Pool", "sharedpool-concurrency", "stress", "Shares one route with Healthy Growth for concurrency pressure."),
)


class Fixture:
    """A simulation namespace bound to one immutable local-demo deployment."""

    def __init__(self, demo, path=FIXTURE_PATH):
        self.demo = demo
        self.path = Path(path)
        self.progress_path = self.path.with_name("simulation-fixture.progress.json")

    def load(self):
        """Read and validate the already-created fixture without writing chain or disk state."""
        require(self.path.exists(), "Simulation fixture missing. Run simulation_fixture.py ensure first.")
        data = json.loads(self.path.read_text())
        require(data.get("schema") == SCHEMA, "Unsupported simulation fixture schema.")
        identity = self.demo.identity(data["identity"]["factory"])
        require(data.get("identity") == identity, "Simulation fixture belongs to another deployment.")
        require(data.get("marketActor", "").lower() == MARKET_ACTOR.lower(), "Unexpected market actor.")
        profiles = data.get("profiles")
        require(isinstance(profiles, list) and len(profiles) >= len(PERSONAS), "Invalid simulation profiles.")
        forbidden = {EXECUTOR.lower(), BUNDLER.lower()}
        for profile in profiles:
            require(isinstance(profile.get("address"), str) and isinstance(profile.get("alias"), str),
                    "Invalid simulation profile.")
            require(profile["role"] not in ("investor", "market") or profile["address"].lower() not in forbidden,
                    "Executor or bundler was reused as investor/market.")
            require(profile["address"].lower() != MARKET_ACTOR.lower(), "Market actor must not be a profile.")
        require(all(self.demo.rpc("eth_getCode", [asset["address"], "latest"]) != "0x"
                    for asset in data.get("assets", [])), "Simulation asset missing on chain.")
        require(all(self.demo.rpc("eth_getCode", [vault["address"], "latest"]) != "0x"
                    for vault in data.get("vaults", [])), "Simulation vault missing on chain.")
        return data

    def ensure(self):
        """Create the extension once, with a durable pre-broadcast marker and finalization gate."""
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.demo.guard()
        if self.path.exists():
            return self.load()
        baseline = self.demo.load()
        execution = self._execution_context(baseline)
        identity = self.demo.identity(baseline["factory"])
        base_vault_count = len(baseline["vaults"])
        base_asset_count = len(baseline["assets"])
        current_vault_count = int(self.demo.call(baseline["factory"], "vaultCount()(uint256)"))
        current_asset_count = len(self.demo.logs(baseline["registry"],
                                                  "AssetRegistered(address,address,address,address,uint48,uint8)"))

        if self.progress_path.exists():
            progress = json.loads(self.progress_path.read_text())
            require(progress.get("identity") == identity, "Simulation progress belongs to another deployment.")
            require(progress.get("baseVaultCount") == base_vault_count and
                    progress.get("baseAssetCount") == base_asset_count, "Simulation baseline changed.")
            # A previously interrupted broadcast is never resumed automatically.
            # Only a fully proven initialized state may be finalized into a local
            # manifest; every other combination preserves receipts for inspection.
            if current_vault_count == base_vault_count + len(VAULT_SPECS) and \
                    current_asset_count == base_asset_count + len(ASSET_SPECS):
                stage = self._initialization_stage(baseline, execution)
                if stage == "ready":
                    return self._write_manifest(baseline)
                raise RuntimeError("Simulation initialization is incomplete or uncertain; inspect receipts before manual repair.")
            raise RuntimeError("Simulation broadcast state is incomplete or uncertain; inspect its receipts before retrying.")

        require(current_vault_count == base_vault_count and current_asset_count == base_asset_count,
                "Demo has extra contracts; refusing to infer simulation progress.")
        progress = {"schema": SCHEMA, "identity": identity, "stage": "broadcasting",
                    "baseVaultCount": base_vault_count, "baseAssetCount": base_asset_count}
        self._atomic_write(self.progress_path, progress)
        self._unlock_actors()
        self._prepare_broadcast_clock()
        self.demo.broadcast("SeedSimulationFixture", self._broadcast_env(baseline, execution), self.path.parent / "fixture.log")
        current_vault_count = int(self.demo.call(baseline["factory"], "vaultCount()(uint256)"))
        current_asset_count = len(self.demo.logs(baseline["registry"],
                                                  "AssetRegistered(address,address,address,address,uint48,uint8)"))
        require(current_vault_count == base_vault_count + len(VAULT_SPECS) and
                current_asset_count == base_asset_count + len(ASSET_SPECS),
                "Simulation broadcast completed with an unexpected state; receipts preserved.")
        return self._write_manifest(baseline)

    def _broadcast_env(self, baseline, execution):
        return {**os.environ, "LOCAL_DEMO": "true", "DEMO_REGISTRY": baseline["registry"],
                "DEMO_FACTORY": baseline["factory"], "DEMO_SETTLEMENT": baseline["settlementAsset"],
                "SIMULATION_BASE_VAULT_COUNT": str(len(baseline["vaults"])),
                "SIMULATION_EXECUTION_FACTORY": execution["factory"], "SIMULATION_EXECUTOR": execution["executor"]}

    def _prepare_broadcast_clock(self):
        """Mine the exact fresh head Forge will simulate, never moving time backwards."""
        latest = int(self.demo.rpc("eth_getBlockByNumber", ["latest", False])["timestamp"], 16)
        target = max(latest + 1, int(time.time()))
        self.demo.rpc("evm_setNextBlockTimestamp", [target])
        self.demo.rpc("evm_mine")
        observed = int(self.demo.rpc("eth_getBlockByNumber", ["latest", False])["timestamp"], 16)
        require(observed >= target, "Anvil did not mine the requested fresh fixture timestamp.")

    def _initialization_stage(self, baseline, execution):
        base = len(baseline["vaults"])
        vaults = [self.demo.call(baseline["factory"], "vaults(uint256)(address)", base + offset) for offset in range(5)]
        escrows = [self.demo.call(vault, "investmentEscrow()(address)") for vault in vaults]
        positions = [int(self.demo.call(vaults[index], "balanceOf(address)(uint256)", owner))
                     for index, owner in ((0, PERSONAS[0][0]), (2, PERSONAS[4][0]), (3, PERSONAS[5][0]))]
        requests = [int(self.demo.call(escrows[index], "nextRequestId()(uint256)"))
                    for index in (0, 1, 3)]
        accounts = [self.demo.call(execution["factory"], "accounts(address,uint256)(address)", escrows[index], 1).lower()
                    for index in (0, 1, 3)]
        zero = "0x" + "0" * 40
        if all(value > 0 for value in positions) and all(value == 2 for value in requests) and all(value != zero for value in accounts):
            return "ready"
        if all(value == 0 for value in positions) and all(value == 1 for value in requests) and all(value == zero for value in accounts):
            return "pristine"
        return "unknown"

    def _unlock_actors(self):
        addresses = [address for address, *_unused in PERSONAS] + [MARKET_ACTOR]
        for address in addresses:
            self.demo.rpc("anvil_impersonateAccount", [address])
            self.demo.rpc("anvil_setBalance", [address, hex(1_000 * 10**18)])

    def _execution_context(self, baseline):
        addresses_path = DEMO_DIRECTORY / "addresses.json"
        require(addresses_path.exists(), "Execution deployment metadata missing.")
        execution = json.loads(addresses_path.read_text()).get("execution", {})
        for key in ("entryPoint", "factory", "executor"):
            require(isinstance(execution.get(key), str), "Execution deployment metadata is incomplete.")
        for key in ("entryPoint", "factory"):
            require(self.demo.rpc("eth_getCode", [execution[key], "latest"]) != "0x", "Execution contract missing on chain.")
        require(self.demo.call(execution["factory"], "vaultFactory()(address)").lower() == baseline["factory"].lower(),
                "Execution factory belongs to another vault demo.")
        require(self.demo.call(execution["factory"], "entryPoint()(address)").lower() == execution["entryPoint"].lower(),
                "Execution factory EntryPoint mismatch.")
        require(execution["executor"].lower() == EXECUTOR.lower(), "Unexpected local execution actor.")
        return {key: execution[key] for key in ("entryPoint", "factory", "executor")}

    def _write_manifest(self, baseline):
        base_asset_count = len(baseline["assets"])
        base_vault_count = len(baseline["vaults"])
        logs = self.demo.logs(baseline["registry"], "AssetRegistered(address,address,address,address,uint48,uint8)")
        addresses = ["0x" + item["topics"][1][-40:] for item in logs[base_asset_count:]]
        require(len(addresses) == len(ASSET_SPECS), "Unexpected simulation asset event count.")
        assets = []
        for address, (symbol, scenario, description) in zip(addresses, ASSET_SPECS, strict=True):
            require(self.demo.call(address, "symbol()(string)") == symbol, "Unexpected simulation token ordering.")
            config = self.demo.call(baseline["registry"],
                                    "assetConfig(address)((address,address,address,uint48,uint8,uint8))", address)
            assets.append({"address": address, "symbol": symbol,
                           "decimals": int(self.demo.call(address, "decimals()(uint8)")),
                           "primaryOracle": config[0], "fallbackOracle": config[1], "pool": config[2],
                           "maxPriceAge": int(config[3]), "scenario": scenario, "description": description})
        vaults = []
        for offset, (name, scenario_key, scenario, description) in enumerate(VAULT_SPECS):
            address = self.demo.call(baseline["factory"], "vaults(uint256)(address)", base_vault_count + offset)
            basket = self.demo.call(address, "basketAssets()(address[])")
            weights = list(map(int, self.demo.call(address, "basketWeightsBps()(uint16[])")))
            require(1 <= len(basket) <= 5 and len(basket) == len(weights) and sum(weights) == 10_000 and min(weights) >= 500,
                    "Invalid simulation basket.")
            vaults.append({"address": address, "name": name, "scenarioKey": scenario_key, "scenario": scenario,
                           "description": description, "manager": self.demo.call(address, "manager()(address)"),
                           "assets": basket, "weightsBps": weights,
                           "investmentEscrow": self.demo.call(address, "investmentEscrow()(address)")})
        profiles = [{"address": address, "alias": alias, "role": role, "description": description}
                    for address, alias, role, description in PERSONAS]
        profiles.append({"address": ADMIN, "alias": "0xAdmin", "role": "admin", "description": "Retains the local registry admin role."})
        accounts = self.demo.rpc("eth_accounts")
        manager_names = {item["address"].lower(): item["name"] for item in baseline.get("managers", [])}
        for account_index, address in enumerate(accounts):
            lowered = address.lower()
            if lowered in {ADMIN.lower(), MARKET_ACTOR.lower()} or lowered in {item["address"].lower() for item in profiles}:
                continue
            if lowered == EXECUTOR.lower():
                profiles.append({"address": address, "alias": "0xExecutor", "role": "executor",
                                 "description": "Reserved for execution; existing demo holdings are preserved."})
            elif lowered == BUNDLER.lower():
                profiles.append({"address": address, "alias": "0xBundler", "role": "bundler",
                                 "description": "Reserved for bundling; existing demo holdings are preserved."})
            elif lowered in manager_names:
                alias = "0xManager" + "".join(part for part in manager_names[lowered].split() if part.isalpha())
                profiles.append({"address": address, "alias": alias, "role": "manager",
                                 "description": manager_names[lowered] + " manages catalog vaults."})
            elif account_index == 2:
                profiles.append({"address": address, "alias": "0xTreasury", "role": "treasury",
                                 "description": "Local protocol treasury account."})
            else:
                profiles.append({"address": address, "alias": f"0xExistingInvestor{account_index}", "role": "investor",
                                 "description": "Existing local-demo investor holdings are preserved."})
        execution = self._execution_context(baseline)
        accounts = []
        for owner, vault_offset in (("0xPatientInvestor", 0), ("0xWhaleInvestor", 1), ("0xBlockedInvestor", 3)):
            escrow = vaults[vault_offset]["investmentEscrow"]
            account = self.demo.call(execution["factory"], "accounts(address,uint256)(address)", escrow, 1)
            require(account.lower() != "0x" + "0" * 40, "Simulation execution account missing.")
            policy = self.demo.call(account, "policy()((uint128,uint128,uint32,uint48,uint256))")
            require(int(policy[2]) == 32 and int(policy[1]) == 10**16, "Unexpected simulation execution policy.")
            accounts.append({"ownerAlias": owner, "address": account, "escrow": escrow, "requestId": 1,
                             "budgetWei": str(self.demo.call(account, "getBudget()(uint256)")), "maxAttempts": 32})
        data = {"schema": SCHEMA, "identity": self.demo.identity(baseline["factory"]), "marketActor": MARKET_ACTOR,
                "note": "Synthetic local simulation fixture. It does not claim historical or future PnL.",
                "profiles": profiles, "assets": assets, "vaults": vaults,
                "execution": {**execution, "accounts": accounts}}
        self._atomic_write(self.path, data)
        self._atomic_write(self.progress_path, {"schema": SCHEMA, "identity": data["identity"], "stage": "ready",
                                                 "baseVaultCount": base_vault_count, "baseAssetCount": base_asset_count})
        return self.load()

    @staticmethod
    def _atomic_write(path, data):
        temporary = Path(path).with_suffix(".tmp")
        temporary.write_text(json.dumps(data, indent=2) + "\n")
        temporary.replace(path)


def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("ensure", "show"))
    parser.add_argument("--rpc-url", default="http://127.0.0.1:38545")
    parser.add_argument("--fixture-path", help="Ignored local fixture manifest path; useful for a disposable QA chain.")
    args = parser.parse_args()
    fixture = Fixture(Demo(args.rpc_url), Path(args.fixture_path) if args.fixture_path else FIXTURE_PATH)
    data = fixture.ensure() if args.action == "ensure" else fixture.load()
    print(json.dumps(data, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, IndexError) as error:
        raise SystemExit(f"simulation-fixture: {error}")
