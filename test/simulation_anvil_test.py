"""Real Anvil restart regression: restored time, identity and balances."""
import json
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("anvil"), "Anvil is required")
class SimulationAnvilTest(unittest.TestCase):
    def test_resume_future_clock_and_financial_state(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]

            def rpc(method, params):
                request = urllib.request.Request(f"http://127.0.0.1:{port}",
                    json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
                    {"Content-Type": "application/json"})
                with urllib.request.urlopen(request, timeout=3) as response:
                    result = json.load(response)
                self.assertNotIn("error", result)
                return result["result"]

            def start(argv, after_block=None):
                process = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                self.addCleanup(lambda: stop(process))
                for _ in range(100):
                    if process.poll() is not None:
                        self.fail("Anvil exited before readiness")
                    try:
                        rpc("eth_chainId", [])
                        if after_block is None or int(rpc("eth_blockNumber", []), 16) > after_block:
                            return process
                        time.sleep(.05)
                    except OSError:
                        time.sleep(.05)
                self.fail("Anvil readiness timed out")

            def stop(process):
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=15)

            initial = start(["anvil", "--host", "127.0.0.1", "--port", str(port),
                             "--state", str(state), "--silent"])
            account = rpc("eth_accounts", [])[0]
            balance = 123 * 10**18
            rpc("anvil_setBalance", [account, hex(balance)])
            contract = "0x1000000000000000000000000000000000000001"
            # A minimal counter runtime increments storage slot zero on a call.
            rpc("anvil_setCode", [contract, "0x60005460010160005500"])
            rpc("anvil_setStorageAt", [contract, "0x" + "00" * 32, "0x" + "00" * 31 + "29"])
            rpc("evm_increaseTime", [90 * 86400])
            rpc("evm_mine", [])
            genesis = rpc("eth_getBlockByNumber", ["0x0", False])["hash"]
            head = rpc("eth_getBlockByNumber", ["latest", False])
            stop(initial)
            for cycle in range(3):
                saved = json.loads(state.read_text())
                self.assertEqual(sum(int(b["header"]["number"], 16) == 0 for b in saved["blocks"]), 1)
                resumed = start([sys.executable, str(ROOT / "script/start-simulation-anvil.py"),
                                 "--state", str(state), "--port", str(port)],
                                after_block=int(head["number"], 16))
                self.assertEqual(rpc("eth_getBlockByNumber", ["0x0", False])["hash"], genesis)
                self.assertEqual(rpc("eth_getBlockByNumber", [head["number"], False])["hash"], head["hash"])
                anchored = rpc("eth_getBlockByNumber", ["latest", False])
                self.assertEqual(int(anchored["number"], 16), int(head["number"], 16) + 1)
                self.assertEqual(anchored["transactions"], [])
                previous = int(head["timestamp"], 16)
                self.assertGreater(int(anchored["timestamp"], 16), previous)
                previous = int(anchored["timestamp"], 16)
                for _ in range(2):
                    rpc("evm_mine", [])
                    current = int(rpc("eth_getBlockByNumber", ["latest", False])["timestamp"], 16)
                    self.assertGreaterEqual(current, previous)
                    previous = current
                self.assertEqual(int(rpc("eth_getBalance", [account, "latest"]), 16), balance)
                self.assertEqual(int(rpc("eth_getStorageAt", [contract, "0x0", "latest"]), 16), 41 + cycle)
                tx = rpc("eth_sendTransaction", [{"from": account, "to": contract, "gas": "0x186a0"}])
                receipt = rpc("eth_getTransactionReceipt", [tx])
                self.assertEqual(receipt["status"], "0x1")
                self.assertEqual(int(rpc("eth_getStorageAt", [contract, "0x0", "latest"]), 16), 42 + cycle)
                self.assertGreaterEqual(int(rpc("eth_getBlockByNumber", [receipt["blockNumber"], False])["timestamp"], 16), previous)
                balance = int(rpc("eth_getBalance", [account, "latest"]), 16)
                head = rpc("eth_getBlockByNumber", ["latest", False])
                stop(resumed)
            saved = json.loads(state.read_text())
            self.assertEqual(sum(int(b["header"]["number"], 16) == 0 for b in saved["blocks"]), 1)



if __name__ == "__main__":
    unittest.main()
