import importlib.util
import json
from pathlib import Path
import tempfile
import time
import threading
import unittest
import uuid
from unittest import mock
from http.client import HTTPConnection


ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("simulation", ROOT / "script/simulation.py")
simulation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(simulation)


class FakeController:
    def public_state(self):
        return {"schema": simulation.STATE_SCHEMA, "ok": True}

    def command(self, value):
        return {"received": value}


class SimulationHttpTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        simulation.SimulationHandler.controller = FakeController()
        cls.server = simulation.http.server.ThreadingHTTPServer(("127.0.0.1", 0), simulation.SimulationHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.thread.join()

    def request(self, method, path, headers=None, body=None):
        conn = HTTPConnection("127.0.0.1", self.server.server_port)
        headers = {"Host": f"127.0.0.1:{self.server.server_port}", **(headers or {})}
        conn.request(method, path, body=body, headers=headers)
        response = conn.getresponse()
        content = response.read()
        conn.close()
        return response, json.loads(content) if content else None

    def test_state_is_readonly_and_allows_trusted_origin(self):
        response, body = self.request("GET", "/state", {"Origin": simulation.TRUSTED_ORIGIN})
        self.assertEqual(response.status, 200)
        self.assertEqual(response.getheader("Access-Control-Allow-Origin"), simulation.TRUSTED_ORIGIN)
        self.assertEqual(body["schema"], simulation.STATE_SCHEMA)

    def test_rejects_untrusted_origin_and_host(self):
        response, _ = self.request("GET", "/state", {"Origin": "http://localhost:18573"})
        self.assertEqual(response.status, 403)
        response, _ = self.request("GET", "/state", {"Host": "example.test"})
        self.assertEqual(response.status, 403)

    def test_command_requires_exact_origin_and_json(self):
        response, _ = self.request("POST", "/command", {"Content-Type": "application/json"}, b"{}")
        self.assertEqual(response.status, 403)
        response, _ = self.request("POST", "/command", {"Origin": simulation.TRUSTED_ORIGIN, "Content-Type": "text/plain"}, b"{}")
        self.assertEqual(response.status, 415)
        response, body = self.request("POST", "/command", {"Origin": simulation.TRUSTED_ORIGIN, "Content-Type": "application/json"}, json.dumps({"action": "advance"}))
        self.assertEqual(response.status, 200)
        self.assertEqual(body["received"]["action"], "advance")

    def test_market_command_returns_accepted_job(self):
        controller = object.__new__(simulation.Simulation)
        controller.start_market = mock.Mock(return_value={"accepted": True, "job": {
            "id": "run-1", "mode": "market", "state": "running", "completed": 0,
            "total": 1, "seconds": 0, "error": None}})
        previous = simulation.SimulationHandler.controller
        simulation.SimulationHandler.controller = controller
        try:
            request = {"action": "market", "asset": "0x" + "1" * 40,
                       "dexChangeBps": 10_000, "oracleChangeBps": 10_000,
                       "requestId": str(uuid.uuid4())}
            response, body = self.request("POST", "/command", {"Origin": simulation.TRUSTED_ORIGIN,
                                           "Content-Type": "application/json"}, json.dumps(request))
            self.assertEqual(response.status, 202)
            self.assertEqual(body["job"]["mode"], "market")
            controller.start_market.assert_called_once_with(request)
        finally:
            simulation.SimulationHandler.controller = previous

    def test_command_limits_body_and_preflight(self):
        response, _ = self.request("POST", "/command", {"Origin": simulation.TRUSTED_ORIGIN, "Content-Type": "application/json"}, b"x" * (simulation.MAX_BODY_BYTES + 1))
        self.assertEqual(response.status, 413)
        response, _ = self.request("OPTIONS", "/command", {"Origin": simulation.TRUSTED_ORIGIN})
        self.assertEqual(response.status, 204)

    def test_command_rejects_non_object_json_without_dropping_connection(self):
        for payload in (b"[]", b"null", b"1"):
            response, body = self.request("POST", "/command", {"Origin": simulation.TRUSTED_ORIGIN, "Content-Type": "application/json"}, payload)
            self.assertEqual(response.status, 400)
            self.assertEqual(body["error"], "JSON command object required.")


class SimulationReceiptTest(unittest.TestCase):
    def controller(self, receipts):
        controller = object.__new__(simulation.Simulation)
        controller._estimate = mock.Mock(return_value=("0x1234", "0x186a0"))
        controller.demo = mock.Mock()
        def rpc(method, params):
            if method == "eth_sendTransaction":
                return "0x" + "a" * 64
            self.assertEqual(method, "eth_getTransactionReceipt")
            return next(receipts)
        controller.demo.rpc.side_effect = rpc
        return controller

    def assert_sent_once(self, controller):
        sends = [call for call in controller.demo.rpc.call_args_list if call.args[0] == "eth_sendTransaction"]
        self.assertEqual(len(sends), 1)

    def test_delayed_receipt_is_observed_without_resubmitting(self):
        receipt = {"status": "0x1"}
        controller = self.controller(iter([None] * 30 + [receipt]))
        with mock.patch.object(simulation.time, "sleep"):
            self.assertEqual(controller._send("sender", "target", "signature"), receipt)
        self.assert_sent_once(controller)

    def test_missing_receipt_is_uncertain_and_identifies_transaction(self):
        controller = self.controller(iter([None]))
        with mock.patch.object(simulation.time, "monotonic", side_effect=[0, 11]):
            with self.assertRaisesRegex(ValueError, "receipt is still unavailable: 0x" + "a" * 64):
                controller._send("sender", "target", "signature")
        self.assert_sent_once(controller)

    def test_failed_receipt_is_not_resubmitted(self):
        controller = self.controller(iter([{"status": "0x0"}]))
        with self.assertRaisesRegex(ValueError, "transaction reverted: 0x" + "a" * 64):
            controller._send("sender", "target", "signature")
        self.assert_sent_once(controller)


class SimulationValidationTest(unittest.TestCase):
    def _advance_controller(self):
        bare = object.__new__(simulation.Simulation)
        bare.lock = threading.RLock(); bare.job_lock = threading.RLock(); bare.job = None
        bare.closing = False; bare.recovery_required = False
        bare.state = {"steps": [], "feedQueue": []}
        bare._timestamp = lambda: 1_700_000_000
        bare._write_state = lambda: None
        bare._publish_fast = lambda: None
        return bare

    def _market_request(self, request_id=None, **changes):
        return {"action": "market", "asset": "0x" + "1" * 40,
                "dexChangeBps": changes.get("dex", 10_000),
                "oracleChangeBps": changes.get("oracle", 10_000),
                "requestId": request_id or str(uuid.uuid4())}

    def test_market_spot_sizing_reaches_large_targets_with_pool_fee_and_minimal_input(self):
        reserve = 10 ** 12
        for bps in (10_000, 500_000, -5_000, -9_000, -9_999):
            amount = simulation.market_input_for_spot(reserve, reserve, 30, bps)
            self.assertGreater(amount, 0)

            def result_for(value):
                net = value * 9_970 // 10_000
                output = reserve - reserve * reserve // (reserve + net)
                if bps > 0:
                    return (reserve + value) * reserve * 10_000 >= reserve * (reserve - output) * (10_000 + bps)
                return (reserve - output) * reserve * 10_000 <= reserve * (reserve + value) * (10_000 + bps)

            self.assertTrue(result_for(amount), bps)
            self.assertFalse(result_for(amount - 1), bps)
        with self.assertRaisesRegex(ValueError, "capacity"):
            simulation.market_input_for_spot(reserve, 2, 30, simulation.MAX_SAFE_INTEGER)

    def test_large_dex_move_funds_only_the_synthetic_actor_shortfall(self):
        bare = object.__new__(simulation.Simulation)
        asset = "0x" + "1" * 40
        settlement = "0x" + "2" * 40
        pool = "0x" + "3" * 40
        actor = "0x" + "4" * 40
        bare._assets = lambda _manifest: [{"address": asset, "pool": pool}]
        values = {(pool, "reserveOf(address)(uint256)", settlement): 10 ** 12,
                  (pool, "reserveOf(address)(uint256)", asset): 10 ** 12,
                  (pool, "swapFeeBps()(uint16)"): 30,
                  (settlement, "balanceOf(address)(uint256)", actor): 0,
                  (settlement, "totalSupply()(uint256)"): 10 ** 13}
        bare._call_int = lambda target, signature, *args: values[(target, signature, *args)]
        bare._send = mock.Mock()
        bare._move_dex(actor, {"settlementAsset": settlement}, asset, 10_000)
        amount = simulation.market_input_for_spot(10 ** 12, 10 ** 12, 30, 10_000)
        self.assertEqual(bare._send.call_args_list, [
            mock.call(actor, settlement, "mint(address,uint256)", actor, amount),
            mock.call(actor, pool, "swapExactIn(address,address,uint256,uint256)", settlement, asset, amount, 1)])

    def test_market_validates_structure_before_lock_and_refuses_contention(self):
        bare = self._advance_controller()
        entered = threading.Event(); release = threading.Event()

        def hold_lock():
            with bare.lock:
                entered.set(); release.wait(1)

        holder = threading.Thread(target=hold_lock)
        holder.start(); self.assertTrue(entered.wait(.2))
        try:
            start = time.monotonic()
            with self.assertRaisesRegex(ValueError, "below its allowed bound"):
                bare.start_market(self._market_request(dex=-10_000))
            with self.assertRaisesRegex(ValueError, "exceeds its allowed bound"):
                bare.start_market(self._market_request(dex=simulation.MAX_SAFE_INTEGER + 1))
            with self.assertRaisesRegex(RuntimeError, "no market change was accepted"):
                bare.start_market(self._market_request())
            self.assertLess(time.monotonic() - start, .1)
            self.assertIsNone(bare.job)
        finally:
            release.set(); holder.join()

    def test_market_job_is_durable_responsive_and_deduplicated(self):
        bare = self._advance_controller()
        entered = threading.Event(); release = threading.Event()

        def slow_command(_payload):
            entered.set(); release.wait(1)

        bare.command = slow_command
        request = self._market_request()
        accepted = bare.start_market(request)
        try:
            self.assertTrue(entered.wait(.2))
            self.assertEqual(accepted["job"]["mode"], "market")
            self.assertEqual(accepted["job"]["seconds"], 0)
            self.assertEqual((accepted["job"]["completed"], accepted["job"]["total"]), (0, 1))
            self.assertEqual(bare.start_market(request)["job"]["id"], accepted["job"]["id"])
            with self.assertRaisesRegex(ValueError, "different market change"):
                bare.start_market({**request, "dexChangeBps": 20_000})
            with self.assertRaisesRegex(ValueError, "already active"):
                bare.start_market(self._market_request())
            with self.assertRaisesRegex(ValueError, "already active"):
                bare.start_advance({"action": "advance", "seconds": 1})
            with self.assertRaisesRegex(ValueError, "cannot be paused or cancelled"):
                bare.control_run("cancel")
        finally:
            release.set(); bare.job["thread"].join(1)
        self.assertEqual(bare.state["job"]["state"], "completed")
        self.assertEqual(bare.state["job"]["completed"], 1)
        self.assertEqual(bare.start_market(request)["job"]["state"], "completed")

    def test_market_job_failure_and_restart_interruption_are_persisted_without_replay(self):
        bare = self._advance_controller()
        bare.command = mock.Mock(side_effect=RuntimeError("transport failed"))
        request = self._market_request()
        bare.start_market(request)
        bare.job["thread"].join(1)
        self.assertEqual(bare.state["job"]["state"], "failed")
        self.assertEqual(bare.state["job"]["error"], "transport failed")
        self.assertEqual(bare.start_market(request)["job"]["state"], "failed")
        bare.command.assert_called_once()

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            persisted = {"schema": simulation.STATE_SCHEMA, "steps": [], "feedQueue": [],
                         "job": {"id": "run-1", "mode": "market", "requestId": request["requestId"],
                                 "state": "running", "completed": 0, "total": 1, "seconds": 0, "error": None},
                         "marketRequests": {request["requestId"]: {"request": {
                             "asset": request["asset"], "dexChangeBps": 10_000, "oracleChangeBps": 10_000},
                             "job": {"id": "run-1", "mode": "market", "requestId": request["requestId"],
                                     "state": "running", "completed": 0, "total": 1, "seconds": 0, "error": None}}}}
            path.write_text(json.dumps(persisted))
            old_directory = simulation.DEMO_DIRECTORY
            simulation.DEMO_DIRECTORY = Path(directory)
            try:
                with mock.patch.object(simulation.Simulation, "_load_extensions"), \
                     mock.patch.object(simulation.Simulation, "_authenticate", return_value=({}, {}, "actor")), \
                     mock.patch.object(simulation.Simulation, "_bind_namespace"), \
                     mock.patch.object(simulation.Simulation, "_capture"), \
                     mock.patch.object(simulation.Simulation, "_publish_full"):
                    restored = simulation.Simulation("http://127.0.0.1:8546", state_path=path)
                self.assertTrue(restored.recovery_required)
                self.assertEqual(restored.state["job"]["state"], "interrupted")
                self.assertEqual(restored.start_market(request)["job"]["state"], "interrupted")
                self.assertEqual(json.loads(path.read_text())["marketRequests"][request["requestId"]]["job"]["state"], "interrupted")
                restored.controller_lock.close()
            finally:
                simulation.DEMO_DIRECTORY = old_directory

    def test_advance_acceptance_refuses_mutation_lock_contention_without_queueing(self):
        bare = self._advance_controller()
        entered = threading.Event()
        release = threading.Event()

        def hold_mutation_lock():
            with bare.lock:
                entered.set()
                release.wait(1)

        holder = threading.Thread(target=hold_mutation_lock)
        holder.start(); self.assertTrue(entered.wait(.2))
        started = time.monotonic()
        with self.assertRaisesRegex(RuntimeError, "no advance was accepted"):
            bare.start_advance({"action": "advance", "seconds": 86400, "mode": "simulate"})
        self.assertLess(time.monotonic() - started, .1)
        self.assertIsNone(bare.job)
        release.set(); holder.join()

    def test_advance_acceptance_exposes_bounds_and_rejects_a_duplicate_job(self):
        bare = self._advance_controller()

        class DormantThread:
            def __init__(self, *_args, **_kwargs):
                self.started = False

            def start(self):
                self.started = True

            def is_alive(self):
                return self.started

        with mock.patch.object(simulation.threading, "Thread", DormantThread):
            accepted = bare.start_advance({"action": "advance", "seconds": 2 * 86400, "mode": "simulate"})
            self.assertEqual(accepted["job"]["startTimestamp"], 1_700_000_000)
            self.assertEqual(accepted["job"]["targetTimestamp"], 1_700_172_800)
            with self.assertRaisesRegex(ValueError, "already active"):
                bare.start_advance({"action": "advance", "seconds": 86400, "mode": "simulate"})

    def test_bounded_command_values(self):
        with self.assertRaises(ValueError):
            simulation.integer(True, "seconds", 1, 2)
        self.assertEqual(simulation.price_after_bps(100, -5000), 50)
        with self.assertRaises(ValueError):
            simulation.price_after_bps(1, -10000)

    def test_steady_scenario_has_no_market_moves(self):
        bare = object.__new__(simulation.Simulation)
        bare._assets = lambda _manifest: [{"address": "0x" + "1" * 40}]
        self.assertEqual(bare._scenario_moves("steady", {}), [{"asset": "0x" + "1" * 40, "dexChangeBps": 0, "oracleChangeBps": 0}])

    def test_post_intent_failure_requires_explicit_recovery(self):
        bare = object.__new__(simulation.Simulation)
        bare.lock = threading.RLock(); bare.busy = False; bare.closing = False; bare.last_error = None; bare.recovery_required = False
        bare.published_lock = threading.Lock(); bare.published_state = {"simulation": {}}
        bare.job_lock = threading.RLock(); bare.job = None
        bare.state = {"steps": [], "feedQueue": []}
        bare._authenticate = lambda mutable=False: ({"assets": []}, {}, "0x" + "2" * 40)
        bare._prevalidate = lambda payload, manifest: None
        bare._timestamp = lambda: 100; bare._block = lambda: 7
        bare._write_state = lambda: None; bare._capture = lambda: None
        def interrupted(*_args):
            raise RuntimeError("swap transport failed")
        bare._prepare_actor = interrupted
        old_directory = simulation.DEMO_DIRECTORY
        with tempfile.TemporaryDirectory() as directory:
            simulation.DEMO_DIRECTORY = Path(directory)
            try:
                with self.assertRaisesRegex(RuntimeError, "swap transport failed"):
                    bare.command({"action": "market"})
            finally:
                simulation.DEMO_DIRECTORY = old_directory
        self.assertTrue(bare.recovery_required)
        self.assertEqual(bare.state["operation"]["status"], "inflight")
        self.assertFalse(bare.busy)

    def test_published_state_does_not_wait_for_mutation_lock(self):
        bare = object.__new__(simulation.Simulation)
        bare.lock = threading.RLock(); bare.published_lock = threading.Lock()
        bare.published_state = {"schema": simulation.STATE_SCHEMA, "job": {"state": "running"}}
        entered = threading.Event()
        def hold_mutation():
            with bare.lock:
                entered.set(); time.sleep(.25)
        worker = threading.Thread(target=hold_mutation)
        worker.start(); entered.wait()
        started = time.monotonic()
        state = bare.public_state()
        self.assertLess(time.monotonic() - started, .05)
        self.assertEqual(state["job"]["state"], "running")
        worker.join()

    def test_step_report_contains_executor_progress(self):
        bare = object.__new__(simulation.Simulation)
        bare.lock = threading.RLock(); bare.busy = False; bare.closing = False
        bare.recovery_required = False; bare.last_error = None
        bare.published_lock = threading.Lock(); bare.published_state = {"simulation": {}}
        bare.job_lock = threading.RLock(); bare.job = None
        bare.state = {"steps": [], "feedQueue": []}
        observed = {"chainShares": 0, "capturedShares": 0}
        bare._authenticate = lambda mutable=False: ({}, {}, None)
        bare._prevalidate = lambda *_args: None
        bare._timestamp = lambda: 100; bare._block = lambda: 7
        bare._write_state = lambda: None
        bare._scenario = lambda *_args: {"action": "scenario"}
        def capture():
            observed["capturedShares"] = observed["chainShares"]
        def execute():
            observed["chainShares"] = 10
            return {"state": "running"}
        bare._capture = capture; bare._run_executor_once = execute
        bare._publish_full = lambda *_args: bare.published_state.update(shares=observed["capturedShares"])
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(simulation, "DEMO_DIRECTORY", Path(directory)):
            report = bare.command({"action": "scenario", "name": "steady"})
        self.assertEqual(report["shares"], 10)

    def test_path_only_moves_after_a_complete_simulated_day(self):
        bare = object.__new__(simulation.Simulation)
        bare.state = {"simulationDay": 0}
        bare._path_moves = lambda _manifest, day: [{"day": day}]
        self.assertEqual(bare._path_moves_due({}, 10 * 3600), [])
        self.assertEqual(bare._path_moves_due({}, 14 * 3600), [{"day": 1}])
        self.assertEqual(bare.state["simulationDay"], 1)

    def test_path_projection_composes_the_execution_rate_table_for_ninety_days(self):
        points = simulation.project_path_oracle(10_000, 1_000, 0, 0, 0)
        self.assertEqual(len(points), 91)
        self.assertEqual(points[0], {"timestamp": 1_000, "day": 0, "oraclePrice": "10000"})
        self.assertEqual(points[1]["oraclePrice"], str(simulation.price_after_bps(10_000, simulation.path_oracle_change_bps(1, 0))))
        self.assertEqual(points[-1]["day"], 90)
        self.assertEqual(points[-1]["timestamp"], 1_000 + 90 * simulation.MAX_ADVANCE_SECONDS)

    def test_path_projection_uses_current_manual_baseline_and_fractional_phase(self):
        elapsed = 9 * simulation.MAX_ADVANCE_SECONDS + simulation.MAX_ADVANCE_SECONDS // 2
        points = simulation.project_path_oracle(12_345, 500, elapsed, 9, 0, days=2)
        day_ten = simulation.price_after_bps(12_345, simulation.path_oracle_change_bps(10, 0))
        day_eleven = simulation.price_after_bps(day_ten, simulation.path_oracle_change_bps(11, 0))
        self.assertEqual(points[0]["oraclePrice"], "12345")
        self.assertEqual(points[1]["oraclePrice"], str(day_ten))
        self.assertEqual(points[2]["oraclePrice"], str(day_eleven))

    def test_cyclic_assets_keep_rising_and_falling_after_the_initial_phase(self):
        for start in (1, 25, 121, 500):
            paths = []
            for index in range(13):
                rates = [simulation.path_oracle_change_bps(day, index) for day in range(start, start + 90)]
                self.assertTrue(all(-2000 <= rate <= 2000 for rate in rates))
                self.assertGreater(len(set(rates)), 15)
                if index == 8:
                    self.assertTrue(all(rate > 0 for rate in rates))
                elif index == 9:
                    self.assertTrue(all(rate < 0 for rate in rates))
                else:
                    self.assertGreater(sum(rate > 0 for rate in rates), 10)
                    self.assertGreater(sum(rate < 0 for rate in rates), 10)
                    turns = sum(a * b < 0 for a, b in zip(rates, rates[1:]))
                    self.assertGreaterEqual(turns, 3)
                paths.append(tuple(rates))
            self.assertEqual(len(set(paths)), 13)

    def test_path_varies_volatility_and_has_reproducible_shocks(self):
        stable = [simulation.path_oracle_change_bps(day, 1) for day in range(1, 366)]
        volatile = [simulation.path_oracle_change_bps(day, 11) for day in range(1, 366)]
        self.assertGreater(max(volatile) - min(volatile), 5 * (max(stable) - min(stable)))
        self.assertLess(min(volatile), -1000)
        self.assertGreater(max(volatile), 1000)
        # Reading other assets/dates cannot consume random state and change a run.
        for day in reversed(range(1, 366)):
            simulation.path_oracle_change_bps(day, 5)
            self.assertEqual(simulation.path_oracle_change_bps(day, 11), volatile[day - 1])

    def test_zero_market_day_still_refreshes_feeds_without_an_invalid_market_command(self):
        bare = object.__new__(simulation.Simulation)
        bare.state = {}
        bare.demo = mock.Mock()
        bare._timestamp = lambda: 100
        bare._path_moves_due = lambda *_: [{"asset": "token", "dexChangeBps": 0, "oracleChangeBps": 0}]
        bare._market = mock.Mock(side_effect=AssertionError("No-op must not submit a market command"))
        bare._stage_late_entry = mock.Mock()
        bare._flush_feeds = mock.Mock()
        bare._refresh_feeds = mock.Mock()
        bare._advance({"seconds": 86400, "mode": "simulate"}, {}, "actor")
        bare._market.assert_not_called()
        bare._refresh_feeds.assert_called_once()
        self.assertFalse(bare.state["feedsExpired"])

    def test_projection_matches_daily_execution_moves_and_resumes_without_a_new_seed(self):
        manifest = {"settlementAsset": "settlement"}
        assets = [{"address": str(i), "primaryOracle": str(i), "pool": str(i)} for i in range(13)]
        prices = [10**18 * (i + 1) for i in range(13)]
        projected = [simulation.project_path_oracle(price, 100, 24 * 86400, 24, i) for i, price in enumerate(prices)]
        bare = object.__new__(simulation.Simulation)
        bare._assets = lambda _manifest: assets
        bare._call_int = lambda _target, signature, *_args: 18 if signature.startswith("decimals") else 10**24
        bare._call_pair = lambda target, *_args: (prices[int(target)], 100)
        for offset in range(1, 91):
            moves = bare._path_moves(manifest, 24 + offset)
            for index, move in enumerate(moves):
                prices[index] = simulation.price_after_bps(prices[index], move["oracleChangeBps"])
                self.assertEqual(str(prices[index]), projected[index][offset]["oraclePrice"])
            if offset == 37:
                # A restarted projection begins at the observed current prices and phase.
                for index, current in enumerate(prices):
                    resumed = simulation.project_path_oracle(current, 100 + offset * 86400,
                                                              (24 + offset) * 86400, 24 + offset, index, days=53)
                    self.assertEqual(resumed[-1]["oraclePrice"], projected[index][-1]["oraclePrice"])

    def test_asset_views_use_pinned_observations_and_include_projection(self):
        bare = object.__new__(simulation.Simulation)
        token = "0x" + "1" * 40
        bare.state = {"pathElapsedSeconds": 0, "simulationDay": 0}
        class Metrics:
            def asset_report(self):
                return {token: {"oraclePrice": "100", "dexPrice": "99",
                                "history": [{"timestamp": 10, "oraclePrice": "100", "dexPrice": "99"}]}}
        bare.metrics = Metrics()
        bare._assets = lambda _manifest, _fixture: [{"address": token, "symbol": "ASSET"}]
        assets = bare._asset_views({}, {}, 10)
        self.assertEqual(assets[0]["history"][0]["dexPrice"], "99")
        self.assertEqual(assets[0]["projection"][0], {"timestamp": 10, "day": 0, "oraclePrice": "100"})

    def test_hot_path_calldata_is_static_abi(self):
        encoded = simulation.static_calldata("reserveOf(address)(uint256)", ("0x" + "1" * 40,))
        self.assertEqual(encoded[:10], "0x9fa77b20")
        self.assertTrue(encoded.endswith("1" * 40))

    def test_scalar_read_does_not_spawn_cast_after_selector_cache(self):
        bare = object.__new__(simulation.Simulation)
        class Rpc:
            def rpc(self, method, _params):
                self.method = method
                return "0x" + "0" * 63 + "7"
        bare.demo = Rpc()
        simulation.selector("reserveOf(address)(uint256)")
        with mock.patch.object(simulation.subprocess, "check_output", side_effect=AssertionError("cast must not run")):
            self.assertEqual(bare._call_int("0x" + "2" * 40, "reserveOf(address)(uint256)", "0x" + "1" * 40), 7)
        self.assertEqual(bare.demo.method, "eth_call")

    def test_idle_successful_capture_clears_transient_error_and_publishes_full_snapshot(self):
        bare = object.__new__(simulation.Simulation)
        bare.lock = threading.RLock(); bare.busy = False; bare.recovery_required = False; bare.closing = False; bare.last_error = "timed out"
        bare.job_lock = threading.RLock(); bare.job = None
        bare.executor = object(); bare.last_executor_at = 0; bare.last_refresh_at = time.monotonic()
        bare._executor_tick = lambda: {"state": "running"}; bare._capture = lambda: None
        published = []
        bare._publish_full = lambda: published.append("full")
        bare._publish_fast = lambda: published.append("fast")
        bare.idle_tick()
        self.assertEqual(published, ["full"])
        self.assertIsNone(bare.last_error)

    def test_idle_recovery_halts_without_clearing_error(self):
        bare = object.__new__(simulation.Simulation)
        bare.lock = threading.RLock(); bare.busy = False; bare.recovery_required = True; bare.closing = False
        bare.last_error = "partial mutation"
        bare.job_lock = threading.RLock(); bare.job = None
        bare._capture = lambda: self.fail("recovery must halt idle reconciliation")
        bare.idle_tick()
        self.assertEqual(bare.last_error, "partial mutation")
        self.assertTrue(bare.recovery_required)

    def test_idle_does_not_compete_with_an_active_job(self):
        bare = object.__new__(simulation.Simulation)
        bare.job_lock = threading.RLock()
        bare.job = {"state": "running"}
        bare.lock = threading.RLock()
        bare.idle_tick = simulation.Simulation.idle_tick.__get__(bare)
        bare._authenticate = lambda *args: self.fail("idle must not authenticate during a job")
        bare.idle_tick()


if __name__ == "__main__":
    unittest.main()
