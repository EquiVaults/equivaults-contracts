#!/usr/bin/env python3
"""Local-only rich-demo simulation controller for a dedicated Anvil chain.

It is deliberately not an RPC proxy: the small HTTP surface only exposes the
current simulation snapshot and typed, bounded simulation commands.  It never
accepts a private key or signs a transaction.  Market moves use Anvil's local
impersonation facility and the fixture's dedicated synthetic market actor.
"""
import argparse
import copy
import fcntl
import functools
import hashlib
import http.server
import importlib.util
import json
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid

ROOT = Path(__file__).resolve().parent.parent
DEMO_DIRECTORY = ROOT / ".local-demo"
STATE_SCHEMA = "equivaults-simulation/v1"
TRUSTED_ORIGIN = "http://127.0.0.1:18573"
MAX_BODY_BYTES = 16 * 1024
MAX_ADVANCE_SECONDS = 24 * 60 * 60
MAX_MOVE_BPS = 5_000  # Deterministic path guard, not the manual market bound.
MAX_SAFE_INTEGER = 2 ** 53 - 1
UINT256_MAX = 2 ** 256 - 1
PROJECTION_DAYS = 90
# Stable rich-demo asset order: ETH, BTC, SOL, AVAX, LINK, UNI, AAVE,
# ARB, RALLY, BOTTL, ILLQ, VOLX, SHARE. Rates are daily basis points.
# (description, drift, cycle amplitude, period in days, daily variation)
PATH_PROFILES = (
    ("Gentle uptrend with corrections", 15, 170, 28, 45),
    ("Slow market cycles", 8, 100, 45, 25),
    ("Volatile growth and pullbacks", 25, 400, 18, 180),
    ("Downtrend with recovery rallies", -12, 330, 26, 100),
    ("Sideways cycles", 0, 220, 32, 40),
    ("Decline with countertrend rallies", -25, 250, 22, 90),
    ("Broad recovery cycles", 18, 270, 37, 70),
    ("Volatile decline and rebounds", -18, 480, 20, 160),
    ("Persistent rise", 45, 0, 1, 20),
    ("Persistent decline", -30, 0, 1, 12),
    ("Thin-market shocks and recoveries", 5, 650, 13, 280),
    ("Large swings and sharp reversals", 0, 950, 17, 380),
    ("Moderate shared-market cycles", 12, 190, 30, 65),
)


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot import {path.name}.")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


local_demo = load_module("equivaults_local_demo", ROOT / "script/local-demo.py")
investor_executor = load_module("equivaults_investor_executor", ROOT / "script/investor-executor.py")


def require(value, message):
    if not value:
        raise ValueError(message)


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def address(value):
    require(isinstance(value, str) and len(value) == 42 and value.startswith("0x")
            and all(c in "0123456789abcdefABCDEF" for c in value[2:]), "Invalid address.")
    return value.lower()


def integer(value, name, minimum=None, maximum=None):
    require(isinstance(value, int) and not isinstance(value, bool), f"{name} must be an integer.")
    if minimum is not None:
        require(value >= minimum, f"{name} is below its allowed bound.")
    if maximum is not None:
        require(value <= maximum, f"{name} exceeds its allowed bound.")
    return value


def price_after_bps(price, change_bps):
    value = price * (10_000 + change_bps) // 10_000
    require(0 < value <= UINT256_MAX, "Market change would make the oracle price zero or exceed uint256.")
    return value


def market_change_bps(value, name):
    return integer(value, name, -9_999, MAX_SAFE_INTEGER)


def market_input_for_spot(reserve_in, reserve_out, fee_bps, change_bps):
    """Smallest input reaching the requested spot move under MockPool's integer math."""
    require(reserve_in > 0 and reserve_out > 1, "Pool reserves cannot support a market move.")
    require(reserve_in * reserve_out <= UINT256_MAX, "Pool reserves exceed MockPool uint256 arithmetic.")
    require(0 <= fee_bps < 10_000, "Invalid pool swap fee.")
    require(change_bps != 0, "A DEX move must be non-zero.")
    fee_factor = 10_000 - fee_bps
    max_input = min(UINT256_MAX - reserve_in, UINT256_MAX // fee_factor)

    def reached(amount):
        net = amount * fee_factor // 10_000
        if reserve_in + net > UINT256_MAX:
            return False
        amount_out = reserve_out - reserve_in * reserve_out // (reserve_in + net)
        if not 0 < amount_out < reserve_out:
            return False
        new_in, new_out = reserve_in + amount, reserve_out - amount_out
        if change_bps > 0:
            return new_in * reserve_out * 10_000 >= reserve_in * new_out * (10_000 + change_bps)
        return new_out * reserve_in * 10_000 <= reserve_out * new_in * (10_000 + change_bps)

    # Keep the output reserve positive and the uint256 denominator in range.
    max_net = min(UINT256_MAX - reserve_in, reserve_in * (reserve_out - 1))
    upper = min(max_input, ((max_net + 1) * 10_000 - 1) // fee_factor)
    require(upper > 0 and reached(upper), "Requested DEX spot change exceeds pool or uint256 capacity.")
    lower = 0
    while lower + 1 < upper:
        middle = (lower + upper) // 2
        if reached(middle):
            upper = middle
        else:
            lower = middle
    return upper


def path_oracle_change_bps(day, asset_index):
    """Reproducible cycles and shocks shared by execution and projection.

    The daily variation is keyed to the absolute scenario day and asset, never
    process RNG state, wall time, or the number of chart refreshes. Restarting or
    splitting a run therefore cannot change its future path.
    """
    require(isinstance(day, int) and day >= 1, "Path day must be positive.")
    require(isinstance(asset_index, int) and asset_index >= 0, "Asset index must be non-negative.")
    profile = asset_index % len(PATH_PROFILES)
    _, drift, amplitude, period, variation = PATH_PROFILES[profile]
    # Integer triangular cycles vary daily returns smoothly across regimes;
    # independent short-term variation avoids perfectly repeated zigzags.
    phase = ((day + asset_index * 3) % period) * 4000 // period
    wave = phase - 1000 if phase < 2000 else 3000 - phase
    digest = hashlib.blake2s(f"equivaults-path-v2:{asset_index}:{day}".encode()).digest()
    noise = int.from_bytes(digest[:4], "big") % 2001 - 1000
    regime = 0 if profile in (8, 9) else 30 if day <= 10 else -20 if day <= 30 else 0
    shock = 0
    if profile == 10:
        shock = {18: -1600, 19: -600, 27: 1300}.get(day % 57, 0)
    elif profile == 11:
        shock = {9: -1800, 10: -800, 21: 1600}.get(day % 43, 0)
    change = drift + amplitude * wave // 1000 + variation * noise // 1000 + regime + shock
    return max(-2000, min(2000, change))


def project_path_oracle(price, timestamp, elapsed_seconds, completed_day, asset_index, days=PROJECTION_DAYS):
    """Project day endpoints from an observed price without filling prior gaps."""
    require(isinstance(price, int) and price > 0, "Projection requires a positive observed price.")
    require(isinstance(timestamp, int) and timestamp >= 0, "Projection requires a valid timestamp.")
    require(isinstance(elapsed_seconds, int) and elapsed_seconds >= 0, "Path elapsed time is invalid.")
    require(isinstance(completed_day, int) and completed_day >= 0, "Path phase is invalid.")
    require(isinstance(days, int) and 0 <= days <= PROJECTION_DAYS, "Projection horizon is invalid.")
    points = [{"timestamp": timestamp, "day": 0, "oraclePrice": str(price)}]
    phase = completed_day
    for day in range(1, days + 1):
        target_phase = (elapsed_seconds + day * MAX_ADVANCE_SECONDS) // MAX_ADVANCE_SECONDS
        while phase < target_phase:
            phase += 1
            price = price_after_bps(price, path_oracle_change_bps(phase, asset_index))
        points.append({"timestamp": timestamp + day * MAX_ADVANCE_SECONDS, "day": day, "oraclePrice": str(price)})
    return points


def input_signature(signature):
    """Drop ABI return types, including after nested tuple inputs."""
    depth = 0
    for index, character in enumerate(signature):
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return signature[:index + 1]
    raise ValueError("Malformed ABI signature.")


@functools.lru_cache(maxsize=64)
def selector(signature):
    return subprocess.check_output(["cast", "keccak", input_signature(signature)], text=True, timeout=10).strip()[:10]


def static_calldata(signature, arguments):
    """Encode the address/uint subset used by controller hot paths."""
    words = []
    for value in arguments:
        if isinstance(value, int) and not isinstance(value, bool):
            number = value
        elif isinstance(value, str) and len(value) == 42 and value.startswith("0x") and all(c in "0123456789abcdefABCDEF" for c in value[2:]):
            number = int(value[2:], 16)
        elif isinstance(value, str) and value.isdigit():
            number = int(value)
        else:
            return None
        if number < 0 or number >= 2 ** 256:
            return None
        words.append(f"{number:064x}")
    return selector(signature) + "".join(words)


class Simulation:
    """Owns the one local mutation lane and a durable, human-readable state."""

    def __init__(self, rpc_url, state_path=None, fixture_path=None, executor_config=None, run_executor=False, origin=TRUSTED_ORIGIN):
        self.demo = local_demo.Demo(rpc_url)
        parsed_origin = urllib.parse.urlsplit(origin)
        require(parsed_origin.scheme == "http" and parsed_origin.hostname == "127.0.0.1" and parsed_origin.port
                and not parsed_origin.username and not parsed_origin.password and parsed_origin.path in ("", "/")
                and not parsed_origin.query and not parsed_origin.fragment, "Origin must be an explicit 127.0.0.1 HTTP origin.")
        self.trusted_origin = "http://127.0.0.1:" + str(parsed_origin.port)
        self.path = Path(state_path or DEMO_DIRECTORY / "simulation.json")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        rpc_port = urllib.parse.urlsplit(rpc_url).port
        require(rpc_port is not None, "Simulation RPC URL requires an explicit port.")
        self.controller_lock = (DEMO_DIRECTORY / ("simulation-controller-" + str(rpc_port) + ".lock")).open("a")
        try:
            fcntl.flock(self.controller_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            self.controller_lock.close()
            raise RuntimeError("A simulation controller already owns this RPC endpoint.") from error
        self.fixture_path = Path(fixture_path or DEMO_DIRECTORY / "simulation-fixture.json")
        self.executor_config = Path(executor_config) if executor_config else None
        self.run_executor = run_executor
        self.lock = threading.RLock()
        self.published_lock = threading.Lock()
        self.published_state = {"schema": STATE_SCHEMA, "chainId": 31337, "busy": True, "error": None,
                                "profiles": [], "assets": [], "vaults": [], "portfolios": [], "job": None,
                                "simulation": {}}
        self.busy = False
        self.closing = False
        self.last_error = None
        self.metrics = None
        self.fixture_module = None
        self.fixture = None
        self.current_fixture = {}
        self.current_manifest = None
        self.prepared_actor = None
        self.executor = None
        self.executor_server = None
        self.last_executor_at = 0
        self.last_refresh_at = 0
        self.job_lock = threading.RLock()
        self.job = None
        self._load_extensions()
        self.state = self._read_state()
        self.recovery_required = bool(self.state.get("operation", {}).get("status") == "inflight")
        if self.state.get("job", {}).get("state") in ("running", "paused", "cancelling"):
            self.state["job"]["state"] = "interrupted"
            self.recovery_required = True
            request_id = self.state["job"].get("requestId")
            if request_id in self.state.get("marketRequests", {}):
                self.state["marketRequests"][request_id]["job"] = copy.deepcopy(self.state["job"])
            self._write_state()
        self.job = copy.deepcopy(self.state.get("job"))
        manifest, _, _ = self._authenticate()
        self._bind_namespace(manifest)
        self._capture()
        if self.run_executor and not self.recovery_required:
            self.executor = self._open_executor()
            self._executor_tick()
            self._capture()
        self._publish_full()

    def _load_extensions(self):
        fixture_file = ROOT / "script/simulation_fixture.py"
        if fixture_file.exists():
            self.fixture_module = load_module("equivaults_simulation_fixture", fixture_file)
            self.fixture = self.fixture_module.Fixture(self.demo, self.fixture_path)
        metrics_file = ROOT / "script/simulation_metrics.py"
        if metrics_file.exists():
            metrics_module = load_module("equivaults_simulation_metrics", metrics_file)
            self.metrics = metrics_module.Metrics(self.demo, self.path.with_name(self.path.stem + "-metrics.sqlite"), {})

    def _read_state(self):
        if not self.path.exists():
            return {"schema": STATE_SCHEMA, "steps": [], "feedQueue": [], "lastMode": None,
                    "feedsExpired": False, "requestsMayBeExpired": False}
        value = json.loads(self.path.read_text())
        require(value.get("schema") == STATE_SCHEMA, "Unsupported simulation state schema.")
        require(isinstance(value.get("steps", []), list) and isinstance(value.get("feedQueue", []), list),
                "Malformed simulation state.")
        return value

    def _write_state(self):
        self.state["schema"] = STATE_SCHEMA
        atomic_json(self.path, self.state)

    def _fixture(self):
        require(self.fixture is not None, "Simulation fixture module is unavailable.")
        fixture = self.fixture.load()
        require(isinstance(fixture, dict), "Simulation fixture is malformed.")
        return fixture

    def _assets(self, manifest, fixture=None):
        assets = {item["address"].lower(): dict(item) for item in manifest["assets"]}
        for item in (fixture or self.current_fixture).get("assets", []):
            require(isinstance(item, dict), "Malformed fixture asset.")
            item = dict(item); item["address"] = address(item.get("address"))
            required = ("symbol", "pool", "primaryOracle", "fallbackOracle")
            require(all(isinstance(item.get(key), str) and item[key] for key in required), "Malformed fixture asset.")
            assets[item["address"]] = {**assets.get(item["address"], {}), **item}
        return list(assets.values())

    def _authenticate(self, mutable=False):
        # Demo.load commits the manifest to the current factory/genesis/deployment
        # identity.  It is required again directly before every write.
        self.demo.guard()
        manifest = self.demo.load()
        self.current_manifest = manifest
        fixture = self._fixture()
        self.current_fixture = fixture
        if self.metrics:
            self.metrics.update_fixture(fixture)
        identity = fixture.get("identity", {})
        for key in ("chainId", "factory", "genesisHash", "deploymentBlock", "deploymentBlockHash"):
            if key in identity:
                require(str(identity[key]).lower() == str(manifest[key]).lower(), "Fixture deployment identity mismatch.")
        expected_namespace = {"rpcUrl": self.demo.url, **{key: manifest[key] for key in
                              ("chainId", "factory", "genesisHash", "deploymentBlock", "deploymentBlockHash")}}
        if self.state.get("namespace") is not None:
            require(self.state["namespace"] == expected_namespace, "Simulation state belongs to another deployment or RPC endpoint.")
        actor = address(fixture.get("marketActor"))
        if mutable:
            profile_addresses = {address(item.get("address")) for item in fixture.get("profiles", []) if isinstance(item, dict)
                                 and item.get("role") in ("investor", "manager", "admin")}
            require(actor not in profile_addresses, "Market actor must not be a fixture profile.")
        return manifest, fixture, actor

    def _bind_namespace(self, manifest):
        namespace = {"rpcUrl": self.demo.url, **{key: manifest[key] for key in
                     ("chainId", "factory", "genesisHash", "deploymentBlock", "deploymentBlockHash")}}
        previous = self.state.get("namespace")
        require(previous in (None, namespace), "Simulation state belongs to another deployment or RPC endpoint.")
        self.state["namespace"] = namespace
        self._write_state()

    def _timestamp(self):
        return int(self.demo.rpc("eth_getBlockByNumber", ["latest", False])["timestamp"], 16)

    def _block(self):
        return int(self.demo.rpc("eth_blockNumber"), 16)

    def _call_int(self, target, signature, *args):
        raw = self.demo.rpc("eth_call", [{"to": target, "data": self._calldata(signature, args)}, "latest"])
        require(isinstance(raw, str) and len(raw) >= 66, "Malformed scalar contract response.")
        return int(raw[2:66], 16)

    def _call_pair(self, target, signature, *args):
        raw = self.demo.rpc("eth_call", [{"to": target, "data": self._calldata(signature, args)}, "latest"])
        require(isinstance(raw, str) and len(raw) == 130, "Expected a two-value contract response.")
        return int(raw[2:66], 16), int(raw[66:130], 16)

    def _path_elapsed_seconds(self):
        elapsed = self.state.get("pathElapsedSeconds")
        if elapsed is None:
            elapsed = int(self.state.get("simulationDay", 0)) * MAX_ADVANCE_SECONDS
        return int(elapsed)

    def _asset_views(self, manifest, fixture, observed_at):
        require(self.metrics is not None, "Asset observations require the metrics store.")
        observed = self.metrics.asset_report()
        elapsed = self._path_elapsed_seconds()
        completed = int(self.state.get("simulationDay", elapsed // MAX_ADVANCE_SECONDS))
        values = []
        for index, item in enumerate(self._assets(manifest, fixture)):
            token = item["address"].lower()
            sample = observed.get(token)
            require(sample is not None, "Asset observation is unavailable.")
            oracle_price = int(sample["oraclePrice"])
            values.append({"address": token, "symbol": item["symbol"], "oraclePrice": str(oracle_price),
                           "dexPrice": sample["dexPrice"], "history": sample["history"],
                           "scenarioLabel": PATH_PROFILES[index % len(PATH_PROFILES)][0],
                           "projection": project_path_oracle(oracle_price, observed_at, elapsed, completed, index)})
        return values

    def _report(self, manifest=None, fixture=None):
        try:
            manifest, fixture, _ = self._authenticate() if manifest is None else (manifest, fixture, None)
            metrics = self.metrics.report() if self.metrics else {"vaults": [], "portfolios": [],
                                                                   "observedBlock": self._block(), "observedAt": self._timestamp()}
            profiles = fixture.get("profiles", [])
            authorized = [address(item["address"]) for item in profiles if isinstance(item, dict)
                          and item.get("role") == "investor" and isinstance(item.get("address"), str)]
            return {"schema": STATE_SCHEMA, "chainId": 31337, "deploymentId": manifest["genesisHash"] + ":" + manifest["factory"].lower(),
                    "timestamp": self._timestamp(), "busy": self.busy or bool(self._job_view() and self._job_view().get("state") in ("running", "paused", "cancelling")), "error": self.last_error,
                    "profiles": profiles, "assets": self._asset_views(manifest, fixture, metrics["observedAt"]), **metrics,
                    "identity": {key: manifest[key] for key in ("genesisHash", "factory", "deploymentBlock", "deploymentBlockHash")},
                    "authorizedProfiles": authorized,
                    "job": self._job_view(),
                    "simulation": {"lastMode": self.state.get("lastMode"), "feedsExpired": bool(self.state.get("feedsExpired")),
                                   "requestsMayBeExpired": bool(self.state.get("requestsMayBeExpired")), "queuedFeedUpdates": len(self.state.get("feedQueue", [])),
                                   "recoveryRequired": self.recovery_required, "scenarioDay": int(self.state.get("simulationDay", 0))}}
        except Exception as error:
            return {"schema": STATE_SCHEMA, "chainId": 31337, "deploymentId": "unavailable", "timestamp": int(time.time()),
                    "busy": self.busy, "error": str(error), "profiles": [], "assets": [],
                    "identity": None, "authorizedProfiles": [], "vaults": [], "portfolios": [], "observedBlock": 0, "observedAt": 0, "job": self._job_view(), "simulation": {}}

    def public_state(self):
        with self.published_lock:
            return copy.deepcopy(self.published_state)

    def _publish_fast(self):
        job = self._job_view()
        with self.published_lock:
            state = dict(self.published_state)
            state["busy"] = self.busy or bool(job and job.get("state") in ("running", "paused", "cancelling"))
            state["error"] = self.last_error
            state["job"] = job
            simulation = dict(state.get("simulation") or {})
            simulation["recoveryRequired"] = self.recovery_required
            state["simulation"] = simulation
            self.published_state = state

    def _publish_full(self, manifest=None, fixture=None):
        snapshot = self._report(manifest, fixture)
        with self.published_lock:
            self.published_state = snapshot

    def _capture(self):
        if self.metrics:
            self.metrics.capture()

    def _calldata(self, signature, args):
        values = tuple(map(str, args))
        encoded = static_calldata(signature, values)
        if encoded is not None:
            return encoded
        return self._tuple_calldata(signature, values)

    @staticmethod
    @functools.lru_cache(maxsize=64)
    def _tuple_calldata(signature, values):
        """Only dynamic ABI arguments (the late-entry tuple) require cast."""
        return subprocess.check_output(["cast", "calldata", signature, *values], text=True, timeout=10).strip()

    def _estimate(self, sender, target, signature, *args):
        data = self._calldata(signature, args)
        tx = {"from": sender, "to": target, "data": data}
        return data, self.demo.rpc("eth_estimateGas", [tx])

    def _send(self, sender, target, signature, *args):
        # `cast send` waits roughly a second per local transaction. Keep cast
        # only for ABI encoding; Anvil JSON-RPC returns the local receipt quickly.
        data, gas = self._estimate(sender, target, signature, *args)
        tx = {"from": sender, "to": target, "data": data, "gas": gas}
        tx_hash = self.demo.rpc("eth_sendTransaction", [tx])
        receipt = None
        for _ in range(20):
            receipt = self.demo.rpc("eth_getTransactionReceipt", [tx_hash])
            if receipt:
                break
            time.sleep(0.02)
        require(receipt is not None and int(str(receipt["status"]), 0) == 1, "Local simulation transaction reverted.")
        return receipt

    def _prepare_actor(self, actor, manifest):
        # Anvil-only methods are never exposed through HTTP.  A fixed, impersonated
        # address prevents the price mover from being a demo investor or manager.
        if self.prepared_actor == actor:
            return
        self.demo.rpc("anvil_impersonateAccount", [actor])
        self.demo.rpc("anvil_setBalance", [actor, hex(100 * 10 ** 18)])
        for item in self._assets(manifest):
            token = item["address"]
            reserve = self._call_int(item["pool"], "reserveOf(address)(uint256)", token)
            self._send(actor, token, "mint(address,uint256)", actor, max(reserve, 1))
            self._send(actor, token, "approve(address,uint256)", item["pool"], 2 ** 256 - 1)
        settlement = manifest["settlementAsset"]
        settlement_reserves = sum(self._call_int(item["pool"], "reserveOf(address)(uint256)", settlement) for item in self._assets(manifest))
        self._send(actor, settlement, "mint(address,uint256)", actor, max(settlement_reserves, 1))
        for item in self._assets(manifest):
            self._send(actor, settlement, "approve(address,uint256)", item["pool"], 2 ** 256 - 1)
        self.prepared_actor = actor

    def _move_dex(self, actor, manifest, asset, change_bps):
        item = next((candidate for candidate in self._assets(manifest) if candidate["address"].lower() == asset), None)
        require(item is not None, "Unknown fixture asset.")
        pool, settlement, token = item["pool"], manifest["settlementAsset"], item["address"]
        if change_bps == 0:
            return
        asset_in, asset_out = (settlement, token) if change_bps > 0 else (token, settlement)
        reserve_in = self._call_int(pool, "reserveOf(address)(uint256)", asset_in)
        reserve_out = self._call_int(pool, "reserveOf(address)(uint256)", asset_out)
        fee = self._call_int(pool, "swapFeeBps()(uint16)")
        amount = market_input_for_spot(reserve_in, reserve_out, fee, change_bps)
        balance = self._call_int(asset_in, "balanceOf(address)(uint256)", actor)
        if balance < amount:
            supply = self._call_int(asset_in, "totalSupply()(uint256)")
            require(amount - balance <= UINT256_MAX - supply,
                    "Requested DEX spot change exceeds synthetic token uint256 supply.")
            self._send(actor, asset_in, "mint(address,uint256)", actor, amount - balance)
        self._send(actor, pool, "swapExactIn(address,address,uint256,uint256)", asset_in, asset_out, amount, 1)

    def _set_oracle(self, manifest, asset, price, feed):
        item = next(candidate for candidate in self._assets(manifest) if candidate["address"].lower() == asset)
        self._send(local_demo.ADMIN, item[feed], "setPrice(uint256,uint256)", price, self._timestamp())

    def _queue_oracle_move(self, manifest, asset, change_bps, now):
        item = next((candidate for candidate in self._assets(manifest) if candidate["address"].lower() == asset), None)
        require(item is not None, "Unknown fixture asset.")
        current, _ = self._call_pair(item["primaryOracle"], "getPrice(address,address)(uint256,uint256)", item["address"], manifest["settlementAsset"])
        target = price_after_bps(current, change_bps)
        # The primary follows on the next simulated step; fallback deliberately
        # trails by five minutes, preserving an observable source lag.
        self.state["feedQueue"].append({"asset": asset, "price": str(target), "feed": "primaryOracle", "due": now})
        self.state["feedQueue"].append({"asset": asset, "price": str(target), "feed": "fallbackOracle", "due": now + 300})

    def _flush_feeds(self, manifest, now):
        due, waiting = [], []
        for item in self.state.get("feedQueue", []):
            (due if int(item["due"]) <= now else waiting).append(item)
        for item in due:
            self._set_oracle(manifest, item["asset"], int(item["price"]), item["feed"])
        self.state["feedQueue"] = waiting
        if due:
            self.state["feedsExpired"] = False

    def _refresh_feeds(self, manifest, now):
        """Keep unchanged feeds fresh without erasing a queued fallback lag."""
        queued = {(item["asset"], item["feed"]) for item in self.state.get("feedQueue", [])}
        settlement = manifest["settlementAsset"]
        for item in self._assets(manifest):
            token = item["address"].lower()
            for feed in ("primaryOracle", "fallbackOracle"):
                if (token, feed) in queued:
                    continue
                price, _ = self._call_pair(item[feed], "getPrice(address,address)(uint256,uint256)", item["address"], settlement)
                self._set_oracle(manifest, token, price, feed)

    def _scenario_moves(self, name, manifest):
        bps = {"steady": 0, "rally": 250, "drawdown": -250, "stress": -800}.get(name)
        require(bps is not None, "Unknown scenario.")
        return [{"asset": item["address"].lower(), "dexChangeBps": bps,
                 "oracleChangeBps": bps if index % 2 == 0 else bps // 2}
                for index, item in enumerate(self._assets(manifest))]

    def _open_executor(self):
        require(self.executor_config and self.executor_config.exists(), "Executor config is required when executor cycles are enabled.")
        config = json.loads(self.executor_config.read_text())
        permitted = {"sender", "stateDb", "statusPort", "bundlerUrl", "bundlerSender", "maxFill", "maxPriceImpactBps", "addresses", "manifest", "interval"}
        require(set(config).issubset(permitted) and {"sender", "stateDb", "statusPort", "bundlerUrl", "maxFill"} <= set(config),
                "Malformed executor config.")
        catalog = json.loads(Path(config.get("addresses", "deployments/31337/addresses.json")).read_text())
        catalog_execution = catalog.get("execution") or {}
        fixture_execution = self.current_fixture.get("execution") or {}
        require(self.current_manifest is not None and catalog.get("factory", "").lower() == self.current_manifest["factory"].lower(),
                "Executor catalog factory differs from the verified demo.")
        for key in ("entryPoint", "factory", "executor"):
            require(str(catalog_execution.get(key, "")).lower() == str(fixture_execution.get(key, "")).lower(),
                    "Executor catalog differs from the verified fixture.")
        require(config["sender"].lower() == str(fixture_execution.get("executor", "")).lower(),
                "Executor sender differs from the verified fixture.")
        args = argparse.Namespace(
            rpc_url=self.demo.url, sender=config["sender"], state_db=config["stateDb"], status_port=int(config["statusPort"]),
            bundler_url=config["bundlerUrl"], bundler_sender=config.get("bundlerSender", "0x14dC79964da2C08b23698b3D3cc7Ca32193d9955"),
            max_fill=int(config["maxFill"]), interval=float(config.get("interval", 5)),
            max_price_impact_bps=integer(config.get("maxPriceImpactBps", 50), "maxPriceImpactBps", 1, 1000),
            addresses=config.get("addresses", "deployments/31337/addresses.json"), manifest=config.get("manifest", "deployments/manifest.json"), once=False,
        )
        require(args.max_fill > 0 and 1 <= args.status_port <= 65535 and args.interval > 0, "Unsafe executor config.")
        executor = investor_executor.Executor(args)
        self.executor_server = investor_executor.sponsor.start_http(executor.status, args.status_port)
        return executor

    def _executor_tick(self):
        if not self.executor:
            return {"state": "disabled"}
        try:
            self.executor.authenticate(); self.executor.cycle()
            self.executor.status.base["operator"].update(state="running", reason=None, spentWei="0", reservedWei="0", budgetWei="0")
            self.executor.status.base["heartbeatAt"] = investor_executor.sponsor.now_ms()
            self.executor.status.publish()
            return {"state": "running"}
        except investor_executor.sponsor.Pause as error:
            self.executor.status.base["operator"].update(state="paused", reason=str(error), spentWei="0", reservedWei="0", budgetWei="0")
            self.executor.status.publish()
            return {"state": "paused", "reason": str(error)}
        except Exception:
            self.executor.status.base["operator"].update(state="paused", reason="operator_unavailable", spentWei="0", reservedWei="0", budgetWei="0")
            self.executor.status.publish()
            return {"state": "paused", "reason": "operator_unavailable"}

    def _run_executor_once(self):
        require(not self.recovery_required, "Interrupted simulation blocks executor mutations.")
        self.last_executor_at = time.monotonic()
        return self._executor_tick()

    def idle_tick(self):
        """Preserve observable prices while periodically refreshing metrics/execution."""
        job = self._job_view()
        if job and job.get("state") in ("running", "paused", "cancelling"):
            return
        with self.lock:
            if self.busy or self.recovery_required or self.closing:
                return
            now = time.monotonic()
            operation_started = False
            captured = False
            reconciled = False
            try:
                interval = getattr(getattr(self.executor, "a", None), "interval", 5)
                if self.executor and now - self.last_executor_at >= interval:
                    self._executor_tick(); self.last_executor_at = now
                    self._capture(); captured = True
                if now - self.last_refresh_at >= 30:
                    manifest, _, _ = self._authenticate(mutable=True)
                    if not self.state.get("feedsExpired"):
                        self.state["operation"] = {"status": "inflight", "command": {"action": "refresh"},
                                                   "targetStart": self._timestamp(), "targetEnd": None}
                        self._write_state()
                        operation_started = True
                        self._refresh_feeds(manifest, self._timestamp())
                        self.state.pop("operation", None)
                        self._write_state()
                    self._capture(); captured = True; self.last_refresh_at = time.monotonic()
                # Errors reported by an earlier idle cycle are observational. A
                # successful fresh capture reconciles the published financial
                # view, so it is safe to clear only that transient status here.
                # Recovery state is intentionally separate and is never cleared
                # by an idle cycle.
                if captured:
                    self.last_error = None
                    reconciled = True
            except Exception as error:
                self.last_error = str(error)
                if operation_started or error.__class__.__name__ == "CanonicalHistoryError":
                    self.recovery_required = True
                    if not operation_started:
                        self.state["operation"] = {"status": "inflight", "command": {"action": "metrics-reconcile"},
                                                   "targetStart": self._timestamp(), "targetEnd": None}
                        self._write_state()
            finally:
                if reconciled:
                    self._publish_full()
                else:
                    self._publish_fast()

    def close(self):
        self.closing = True
        self._publish_fast()
        job = None
        with self.job_lock:
            if self.job and self.job.get("thread") and self.job["thread"].is_alive():
                if self.job.get("mode") != "market":
                    self.job["cancel"].set(); self.job["paused"].clear(); self.job["state"] = "cancelling"
                job = self.job["thread"]
        if job:
            job.join()
        # Direct POST mutations share this lock. Do not close the underlying
        # databases or release the lifetime lock until their atomic step ended.
        with self.lock:
            if self.executor_server:
                self.executor_server.shutdown(); self.executor_server.server_close()
                self.executor_server = None
            if self.executor:
                self.executor.db.close(); self.executor = None
            if self.metrics:
                self.metrics.close(); self.metrics = None
            if self.controller_lock:
                fcntl.flock(self.controller_lock, fcntl.LOCK_UN)
                self.controller_lock.close(); self.controller_lock = None

    def command(self, payload, execute_executor=True):
        require(isinstance(payload, dict), "JSON command object required.")
        action = payload.get("action")
        require(action in ("advance", "market", "scenario"), "Unsupported command action.")
        with self.lock:
            require(not self.closing, "Simulation controller is shutting down.")
            require(not self.recovery_required, "Interrupted simulation requires acknowledge before another mutation.")
            if self.busy:
                raise RuntimeError("Simulation controller is busy.")
            self.busy = True
            self.last_error = None
            self._publish_fast()
            operation_started = False
            try:
                # A second cross-process lock complements the in-process HTTP lock.
                DEMO_DIRECTORY.mkdir(exist_ok=True)
                with (DEMO_DIRECTORY / "simulation.lock").open("a") as file_lock:
                    try:
                        fcntl.flock(file_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError as error:
                        raise RuntimeError("Another simulation controller owns the mutation lane.") from error
                    manifest, fixture, actor = self._authenticate(mutable=True)
                    self._prevalidate(payload, manifest)
                    start = self._timestamp()
                    target = start + int(payload.get("seconds", 0)) if action == "advance" else None
                    self.state["operation"] = {"status": "inflight", "command": payload, "targetStart": start, "targetEnd": target}
                    self._write_state()
                    operation_started = True
                    self._capture()
                    before = {"timestamp": start, "block": self._block()}
                    needs_actor = (action == "market" or (action == "scenario" and payload["name"] != "steady")
                                   or (action == "advance" and payload.get("mode", "simulate") == "simulate"
                                       and payload.get("scenario", "path") == "path"))
                    if needs_actor:
                        self._prepare_actor(actor, manifest)
                    if action == "market":
                        result = self._market(payload, manifest, actor)
                    elif action == "scenario":
                        result = self._scenario(payload, manifest, actor)
                    else:
                        result = self._advance(payload, manifest, actor)
                    result["before"] = before
                    result["executor"] = self._run_executor_once() if execute_executor else {"state": "deferred"}
                    self._capture()
                    result["after"] = {"timestamp": self._timestamp(), "block": self._block()}
                    self.state["steps"].append(result)
                    self.state["steps"] = self.state["steps"][-128:]
                    self.state.pop("operation", None)
                    self._write_state()
                    self._publish_full(manifest, fixture)
                    return self.public_state()
            except Exception as error:
                self.last_error = str(error)
                if operation_started:
                    self.recovery_required = True
                self._publish_fast()
                raise
            finally:
                self.busy = False
                self._publish_fast()

    def acknowledge_recovery(self):
        with self.lock:
            require(not self.closing, "Simulation controller is shutting down.")
            require(self.recovery_required, "No interrupted simulation requires acknowledgement.")
            # Capture the observed chain before allowing a new relative market path.
            self._authenticate(); self._capture()
            self.state.pop("operation", None)
            if self.state.get("job", {}).get("state") == "interrupted":
                self.state["job"]["state"] = "acknowledged"
            self.recovery_required = False
            self._write_state()
            if self.run_executor and not self.executor:
                self.executor = self._open_executor()
                self._executor_tick(); self._capture()
            self._publish_full()
            return self.public_state()

    def _job_view(self):
        with self.job_lock:
            if not self.job:
                return None
            return {key: value for key, value in self.job.items() if key not in ("thread", "cancel", "paused", "chunks", "payload")}

    def _prevalidate(self, payload, manifest):
        action = payload["action"]
        if action == "advance":
            integer(payload.get("seconds"), "seconds", 1, MAX_ADVANCE_SECONDS)
            require(payload.get("mode", "simulate") in ("simulate", "jump"), "mode must be simulate or jump.")
            require(payload.get("scenario", "path") in ("path", "steady", "rally", "drawdown", "stress"), "Unknown scenario.")
        elif action == "market":
            asset = address(payload.get("asset"))
            require(asset in {item["address"].lower() for item in self._assets(manifest)}, "Unknown fixture asset.")
            dex = market_change_bps(payload.get("dexChangeBps", 0), "dexChangeBps")
            oracle = market_change_bps(payload.get("oracleChangeBps", 0), "oracleChangeBps")
            require(dex or oracle, "A market command needs a non-zero DEX or oracle move.")
        else:
            require(isinstance(payload.get("name"), str) and payload["name"] in ("steady", "rally", "drawdown", "stress"),
                    "Unknown scenario.")

    def start_market(self, payload):
        require(isinstance(payload, dict), "JSON command object required.")
        asset = address(payload.get("asset"))
        dex = market_change_bps(payload.get("dexChangeBps", 0), "dexChangeBps")
        oracle = market_change_bps(payload.get("oracleChangeBps", 0), "oracleChangeBps")
        require(dex or oracle, "A market command needs a non-zero DEX or oracle move.")
        request_id = payload.get("requestId")
        require(isinstance(request_id, str), "requestId must be a UUID.")
        try:
            require(str(uuid.UUID(request_id)) == request_id, "requestId must be a canonical UUID.")
        except (ValueError, AttributeError) as error:
            raise ValueError("requestId must be a canonical UUID.") from error
        request = {"asset": asset, "dexChangeBps": dex, "oracleChangeBps": oracle}
        with self.job_lock:
            prior = self.state.get("marketRequests", {}).get(request_id)
            if prior:
                require(prior["request"] == request, "requestId was already used for a different market change.")
                return {"accepted": True, "job": copy.deepcopy(prior["job"])}
        if not self.lock.acquire(blocking=False):
            raise RuntimeError("Simulation controller is busy; no market change was accepted.")
        try:
            require(not self.closing, "Simulation controller is shutting down.")
            require(not self.recovery_required, "Interrupted simulation requires acknowledge before another mutation.")
            with self.job_lock:
                prior = self.state.get("marketRequests", {}).get(request_id)
                if prior:
                    require(prior["request"] == request, "requestId was already used for a different market change.")
                    return {"accepted": True, "job": copy.deepcopy(prior["job"])}
                require(not self.job or (self.job["state"] not in ("running", "paused", "cancelling")
                        and not (self.job.get("thread") and self.job["thread"].is_alive())),
                        "A simulation run is already active.")
                job = {"id": "run-" + uuid.uuid4().hex, "mode": "market", "asset": asset,
                       "requestId": request_id, "state": "running", "completed": 0, "total": 1,
                       "seconds": 0, "error": None, "payload": {"action": "market", **request}}
                self.job = job
                self.state["job"] = self._job_view()
                self.state.setdefault("marketRequests", {})[request_id] = {"request": request, "job": self._job_view()}
                self._write_state()
                self._publish_fast()
                thread = threading.Thread(target=self._run_market, args=(job,), daemon=True)
                job["thread"] = thread
                thread.start()
                return {"accepted": True, "job": self._job_view()}
        finally:
            self.lock.release()

    def _run_market(self, job):
        try:
            self.command(job["payload"])
            with self.lock:
                with self.job_lock:
                    job["completed"] = 1
                    job["state"] = "completed"
                    self.state["job"] = self._job_view()
                    self.state["marketRequests"][job["requestId"]]["job"] = self._job_view()
                    self._write_state()
                self._publish_fast()
        except Exception as error:
            with self.lock:
                with self.job_lock:
                    job["state"] = "failed"
                    job["error"] = str(error)
                    self.state["job"] = self._job_view()
                    self.state["marketRequests"][job["requestId"]]["job"] = self._job_view()
                    self._write_state()
                self._publish_fast()

    def start_advance(self, payload):
        require(isinstance(payload, dict), "JSON command object required.")
        seconds = integer(payload.get("seconds"), "seconds", 1, 366 * MAX_ADVANCE_SECONDS)
        mode = payload.get("mode", "simulate")
        require(mode in ("simulate", "jump"), "mode must be simulate or jump.")
        scenario = payload.get("scenario", "path")
        require(isinstance(scenario, str) and scenario in ("path", "steady", "rally", "drawdown", "stress"), "Unknown scenario.")
        chunks = [MAX_ADVANCE_SECONDS] * (seconds // MAX_ADVANCE_SECONDS)
        if seconds % MAX_ADVANCE_SECONDS:
            chunks.append(seconds % MAX_ADVANCE_SECONDS)
        # Command acceptance must never wait behind a mutation step.  A client
        # whose short HTTP request times out cannot otherwise know whether an
        # advance was queued and risks submitting a duplicate run.  Refuse
        # contention synchronously; the durable active-job check below covers
        # the interval between completed steps.
        if not self.lock.acquire(blocking=False):
            raise RuntimeError("Simulation controller is busy; no advance was accepted.")
        try:
            require(not self.closing, "Simulation controller is shutting down.")
            require(not self.recovery_required, "Interrupted simulation requires acknowledge before another mutation.")
            with self.job_lock:
                require(not self.job or (self.job["state"] not in ("running", "paused", "cancelling")
                        and not (self.job.get("thread") and self.job["thread"].is_alive())), "A simulation run is already active.")
                job_id = "run-" + str(int(time.time() * 1000))
                start_timestamp = self._timestamp()
                self.job = {"id": job_id, "state": "running", "completed": 0, "total": len(chunks), "seconds": seconds,
                            "startTimestamp": start_timestamp, "targetTimestamp": start_timestamp + seconds,
                            "scenario": scenario, "mode": mode, "chunks": chunks, "error": None, "cancel": threading.Event(), "paused": threading.Event()}
                self.state["job"] = self._job_view()
                self._write_state()
                self._publish_fast()
                thread = threading.Thread(target=self._run_steps, args=(self.job,), daemon=True)
                self.job["thread"] = thread
                thread.start()
                return {"accepted": True, "job": self._job_view()}
        finally:
            self.lock.release()

    def control_run(self, action):
        require(action in ("pause", "resume", "cancel"), "Unsupported run control.")
        # This intentionally does not take the mutation lock: cancelling must be
        # visible while an in-flight step waits on local receipts. The worker
        # persists it at the next command boundary under the normal lock.
        with self.job_lock:
            require(self.job and self.job["state"] in ("running", "paused"), "No active simulation run.")
            require(self.job.get("mode") != "market", "Market changes cannot be paused or cancelled.")
            if action == "pause":
                self.job["paused"].set(); self.job["state"] = "paused"
            elif action == "resume":
                self.job["paused"].clear(); self.job["state"] = "running"
            else:
                self.job["cancel"].set(); self.job["paused"].clear(); self.job["state"] = "cancelling"
            result = {"accepted": True, "job": self._job_view()}
        self._publish_fast()
        return result

    def _run_steps(self, job):
        try:
            while job["completed"] < job["total"]:
                if job["cancel"].is_set():
                    with self.lock:
                        with self.job_lock:
                            job["state"] = "cancelled"; self.state["job"] = self._job_view(); self._write_state()
                        self._publish_fast()
                    return
                while job["paused"].is_set():
                    if job["cancel"].wait(0.2):
                        with self.lock:
                            with self.job_lock:
                                job["state"] = "cancelled"; self.state["job"] = self._job_view(); self._write_state()
                        self._publish_fast()
                        return
                # One market scenario then one bounded day at a time.  The executor
                # is only invited after the clock advance, never concurrently.
                if job["mode"] == "simulate" and job["scenario"] != "path":
                    self.command({"action": "scenario", "name": job["scenario"]}, execute_executor=False)
                self.command({"action": "advance", "seconds": job["chunks"][job["completed"]], "mode": job["mode"], "scenario": job["scenario"]})
                with self.lock:
                    with self.job_lock:
                        job["completed"] += 1
                        self.state["job"] = self._job_view()
                        self._write_state()
                    self._publish_fast()
            with self.lock:
                with self.job_lock:
                    job["state"] = "completed"
                    self.state["job"] = self._job_view(); self._write_state()
                self._publish_fast()
        except Exception as error:
            with self.lock:
                with self.job_lock:
                    job["state"] = "failed"; job["error"] = str(error)
                    self.state["job"] = self._job_view(); self._write_state()
                self._publish_fast()

    def _market(self, payload, manifest, actor):
        asset = address(payload.get("asset"))
        dex = market_change_bps(payload.get("dexChangeBps", 0), "dexChangeBps")
        oracle = market_change_bps(payload.get("oracleChangeBps", 0), "oracleChangeBps")
        require(dex or oracle, "A market command needs a non-zero DEX or oracle move.")
        if dex:
            self._move_dex(actor, manifest, asset, dex)
        if oracle:
            self._queue_oracle_move(manifest, asset, oracle, self._timestamp())
            self._flush_feeds(manifest, self._timestamp())
        self.state["lastMode"] = "market"
        return {"action": "market", "asset": asset, "dexChangeBps": dex, "oracleChangeBps": oracle}

    def _scenario(self, payload, manifest, actor):
        name = payload.get("name")
        require(isinstance(name, str), "scenario name must be a string.")
        moves = self._scenario_moves(name, manifest)
        for move in moves:
            if move["dexChangeBps"] or move["oracleChangeBps"]:
                self._market({"action": "market", **move}, manifest, actor)
        self.state["lastMode"] = "scenario:" + name
        return {"action": "scenario", "name": name, "moves": len(moves)}

    def _advance(self, payload, manifest, actor):
        seconds = integer(payload.get("seconds"), "seconds", 1, MAX_ADVANCE_SECONDS)
        mode = payload.get("mode", "simulate")
        require(mode in ("simulate", "jump"), "mode must be simulate or jump.")
        target = self._timestamp() + seconds
        # Absolute scheduling avoids a relative-time retry silently advancing the
        # clock twice after an interrupt. The durable intent records this target.
        self.demo.rpc("evm_setNextBlockTimestamp", [target])
        self.demo.rpc("evm_mine")
        now = self._timestamp()
        if mode == "jump":
            # No artificial refresh follows a raw jump.  Feeds remain on their
            # old timestamp and request/deadline validity is determined on-chain.
            self.state["feedsExpired"] = True
            self.state["requestsMayBeExpired"] = True
        else:
            if payload.get("scenario", "path") == "path":
                for move in self._path_moves_due(manifest, seconds):
                    if move["dexChangeBps"] or move["oracleChangeBps"]:
                        self._market({"action": "market", **move}, manifest, actor)
                self._stage_late_entry(manifest)
            self._flush_feeds(manifest, now)
            self._refresh_feeds(manifest, now)
            self.state["feedsExpired"] = False
            self.state["requestsMayBeExpired"] = False
        self.state["lastMode"] = mode
        return {"action": "advance", "seconds": seconds, "mode": mode}

    def _stage_late_entry(self, manifest):
        """Open the documented late position once, after ten simulated days."""
        if int(self.state.get("simulationDay", 0)) < 10 or self.state.get("lateEntry", {}).get("completed"):
            return
        fixture_vault = next((item for item in self.current_fixture.get("vaults", []) if item.get("scenarioKey") == "healthy"), None)
        late = next((item.get("address") for item in self.current_fixture.get("profiles", []) if item.get("alias") == "0xLateInvestor"), None)
        require(fixture_vault and late, "Late-entry fixture bindings are missing.")
        vault, late = address(fixture_vault["address"]), address(late)
        # The on-chain share balance is the idempotency guard; a restarted
        # controller cannot create a second position merely by replaying state.
        if self._call_int(vault, "balanceOf(address)(uint256)", late) > 0:
            self.state["lateEntry"] = {"completed": True, "vault": vault, "investor": late, "amount": "300000000"}
            return
        amount = 300_000_000
        self._send(late, manifest["settlementAsset"], "approve(address,uint256)", vault, amount)
        deadline = self._timestamp() + 300
        params = f"({amount},{late},0,[],{deadline},0)"
        try:
            self._estimate(late, vault, "enter((uint256,address,uint256,uint256[],uint256,uint256))", params)
        except RuntimeError as error:
            self.state["lateEntry"] = {"completed": False, "pending": True, "vault": vault, "investor": late,
                                       "amount": str(amount), "reason": "market_inadmissible", "detail": str(error)}
            return
        self._send(late, vault, "enter((uint256,address,uint256,uint256[],uint256,uint256))", params)
        require(self._call_int(vault, "balanceOf(address)(uint256)", late) > 0, "Late entry did not mint shares.")
        self.state["lateEntry"] = {"completed": True, "vault": vault, "investor": late, "amount": str(amount)}

    def _path_moves_due(self, manifest, seconds):
        # Older state stored only completed days. Its safe migration assumes each
        # recorded path day represented one full day, never inventing a partial.
        elapsed = self.state.get("pathElapsedSeconds")
        if elapsed is None:
            elapsed = int(self.state.get("simulationDay", 0)) * MAX_ADVANCE_SECONDS
        elapsed = int(elapsed) + seconds
        target_day = elapsed // MAX_ADVANCE_SECONDS
        completed = int(self.state.get("simulationDay", 0))
        self.state["pathElapsedSeconds"] = elapsed
        moves = []
        while completed < target_day:
            completed += 1
            moves.extend(self._path_moves(manifest, completed))
        self.state["simulationDay"] = completed
        return moves

    def _path_moves(self, manifest, day):
        # Different cycles, daily variations and bounded shocks exercise entries
        # at different prices. Investor returns are outcomes, never assigned.
        assets = self._assets(manifest)
        settlement = manifest["settlementAsset"]
        settlement_decimals = self._call_int(settlement, "decimals()(uint8)")
        moves = []
        for index, item in enumerate(assets):
            oracle_bps = path_oracle_change_bps(day, index)
            oracle, _ = self._call_pair(item["primaryOracle"], "getPrice(address,address)(uint256,uint256)", item["address"], settlement)
            target_oracle = price_after_bps(oracle, oracle_bps)
            token_decimals = self._call_int(item["address"], "decimals()(uint8)")
            reserve_settlement = self._call_int(item["pool"], "reserveOf(address)(uint256)", settlement)
            reserve_token = self._call_int(item["pool"], "reserveOf(address)(uint256)", item["address"])
            current_dex = reserve_settlement * 10 ** token_decimals * 10 ** 18 // (reserve_token * 10 ** settlement_decimals)
            # DEX follows the changed oracle with a small alternating spread. It
            # converges every day instead of accumulating a fake divergence.
            spread = (40, -35, 25, -20)[(day + index) % 4]
            target_dex = target_oracle * (10_000 + spread) // 10_000
            dex_bps = max(-MAX_MOVE_BPS, min(MAX_MOVE_BPS, (target_dex - current_dex) * 10_000 // current_dex))
            moves.append({"asset": item["address"].lower(), "dexChangeBps": dex_bps, "oracleChangeBps": oracle_bps})
        return moves


class SimulationHandler(http.server.BaseHTTPRequestHandler):
    controller = None

    def _host_ok(self):
        return self.headers.get("Host") in ("127.0.0.1:" + str(self.server.server_port), "localhost:" + str(self.server.server_port))

    def _origin_ok(self):
        origin = self.headers.get("Origin")
        return origin in (None, self._trusted_origin())

    def _trusted_origin(self):
        return getattr(self.controller, "trusted_origin", TRUSTED_ORIGIN)

    def _reply(self, status, body=None):
        encoded = b"" if body is None else json.dumps(body, separators=(",", ":")).encode()
        self.send_response(status)
        if self.headers.get("Origin") == self._trusted_origin():
            self.send_header("Access-Control-Allow-Origin", self._trusted_origin())
            self.send_header("Vary", "Origin")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        if encoded:
            self.wfile.write(encoded)

    def do_OPTIONS(self):
        if not self._host_ok() or self.headers.get("Origin") != self._trusted_origin() or self.path != "/command":
            self._reply(403, {"error": "forbidden"}); return
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", self._trusted_origin())
        self.send_header("Access-Control-Allow-Methods", "POST")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Max-Age", "600")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if not self._host_ok() or not self._origin_ok() or self.path != "/state":
            self._reply(403 if self.path == "/state" else 404, {"error": "not_found"}); return
        self._reply(200, self.controller.public_state())

    def do_POST(self):
        if not self._host_ok() or self.headers.get("Origin") != self._trusted_origin() or self.path != "/command":
            self._reply(403, {"error": "forbidden"}); return
        if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json":
            self._reply(415, {"error": "json_content_type_required"}); return
        try:
            size = int(self.headers.get("Content-Length", ""))
        except ValueError:
            size = -1
        if not 0 <= size <= MAX_BODY_BYTES:
            self._reply(413, {"error": "body_too_large"}); return
        try:
            value = json.loads(self.rfile.read(size))
            require(isinstance(value, dict), "JSON command object required.")
            if isinstance(self.controller, Simulation) and value.get("action") == "market":
                self._reply(202, self.controller.start_market(value))
            elif isinstance(self.controller, Simulation) and value.get("action") == "advance":
                self._reply(202, self.controller.start_advance(value))
            elif isinstance(self.controller, Simulation) and value.get("action") in ("pause", "resume", "cancel"):
                self._reply(202, self.controller.control_run(value["action"]))
            elif isinstance(self.controller, Simulation) and value.get("action") == "acknowledge":
                self._reply(200, self.controller.acknowledge_recovery())
            else:
                self._reply(200, self.controller.command(value))
        except (ValueError, RuntimeError, json.JSONDecodeError) as error:
            self._reply(400, {"error": str(error)})

    def log_message(self, *_args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc-url", default="http://127.0.0.1:8546")
    parser.add_argument("--origin", default=TRUSTED_ORIGIN, help="Exact loopback Origin permitted to issue commands.")
    parser.add_argument("--state-path")
    parser.add_argument("--fixture-path")
    parser.add_argument("--executor-config")
    parser.add_argument("--run-executor", action="store_true")
    parser.add_argument("--serve", action="store_true", help="Explicitly enable the localhost HTTP controller.")
    parser.add_argument("--port", type=int, default=38791)
    parser.add_argument("--print-state", action="store_true")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("port must be in range")
    if args.run_executor and not args.executor_config:
        parser.error("--run-executor requires --executor-config")
    if not args.serve and not args.print_state:
        parser.error("choose --serve or --print-state; the controller is opt-in")
    controller = Simulation(args.rpc_url, args.state_path, args.fixture_path, args.executor_config, args.run_executor, args.origin)
    if args.print_state:
        print(json.dumps(controller.public_state(), indent=2))
    if not args.serve:
        controller.close()
        return
    SimulationHandler.controller = controller
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), SimulationHandler)
    stop = threading.Event()
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        while not stop.wait(0.25):
            controller.idle_tick()
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=2)
        controller.close()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError, KeyError) as error:
        sys.exit(f"simulation: {error}")
