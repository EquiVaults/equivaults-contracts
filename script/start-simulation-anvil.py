#!/usr/bin/env python3
"""Resume a local simulation without resetting its future block clock."""
import argparse
import json
from pathlib import Path
import signal
import socket
import subprocess
import time
import urllib.request


def command(state, port):
    path = Path(state).resolve(strict=True)
    snapshot = json.loads(path.read_text())
    timestamp = snapshot["block"]["timestamp"]
    timestamp = int(timestamp, 16) if isinstance(timestamp, str) else int(timestamp)
    genesis = [block for block in snapshot["blocks"] if int(block["header"]["number"], 16) == 0]
    if len(genesis) != 1:
        raise ValueError("Snapshot must contain exactly one verified genesis block; restore a matching checkpoint")
    genesis_time = int(genesis[0]["header"]["timestamp"], 16)
    first = [block for block in snapshot["blocks"] if int(block["header"]["number"], 16) == 1]
    if len(first) != 1:
        raise ValueError("A deployed simulation checkpoint with a unique first block is required")
    if timestamp < 0 or not 1024 <= port <= 65535:
        raise ValueError("Invalid snapshot timestamp or local port")
    # Preserve the original genesis at startup. Using the future head here adds a
    # competing genesis to later dumps and can change identity on the next reload.
    argv = ["anvil", "--host", "127.0.0.1", "--port", str(port),
            "--chain-id", "31337", "--state", str(path), "--timestamp", str(genesis_time),
            "--state-interval", "30", "--silent"]
    return argv, timestamp, snapshot["best_block_number"], first[0]["header"]["parentHash"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", required=True, help="Existing, backed-up Anvil JSON snapshot")
    parser.add_argument("--port", required=True, type=int)
    args = parser.parse_args()
    argv, timestamp, saved_number, genesis_hash = command(args.state, args.port)
    with socket.socket() as probe:
        probe.settimeout(1)
        if probe.connect_ex(("127.0.0.1", args.port)) == 0:
            parser.error("The selected local port is already occupied")
    def rpc(method, params):
        request = urllib.request.Request(f"http://127.0.0.1:{args.port}",
            json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
            {"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=3) as response:
            result = json.load(response)
        if "error" in result:
            raise RuntimeError(result["error"])
        return result["result"]

    child = subprocess.Popen(argv)
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, lambda *_: child.terminate())
    try:
        for attempt in range(200):
            if child.poll() is not None:
                raise RuntimeError("Anvil exited before readiness")
            try:
                head = rpc("eth_getBlockByNumber", ["latest", False])
                break
            except OSError:
                if attempt == 199:
                    raise RuntimeError("Anvil readiness timed out") from None
                time.sleep(.1)
        if int(head["number"], 16) != saved_number or int(head["timestamp"], 16) != timestamp:
            raise RuntimeError("Loaded head differs from the saved checkpoint")
        if rpc("eth_getBlockByNumber", ["0x0", False])["hash"].lower() != genesis_hash.lower():
            raise RuntimeError("Loaded genesis differs from the checkpoint chain")
        # Establish the simulated clock before other services may send a trade.
        # The single empty anchor block changes no balances or contract storage.
        rpc("evm_setNextBlockTimestamp", [timestamp + 1])
        rpc("evm_mine", [])
        anchored = rpc("eth_getBlockByNumber", ["latest", False])
        if (int(anchored["timestamp"], 16) < timestamp + 1
                or int(anchored["number"], 16) != saved_number + 1
                or anchored["parentHash"] != head["hash"]
                or anchored["transactions"]):
            raise RuntimeError("Restored simulation clock did not advance")
        print("Simulation Anvil ready at block " + anchored["number"], flush=True)
        raise SystemExit(child.wait())
    finally:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=15)


if __name__ == "__main__":
    main()
