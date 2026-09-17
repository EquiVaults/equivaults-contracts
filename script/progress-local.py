#!/usr/bin/env python3
"""Bounded Anvil sponsor: commit each successful purchase before preparing the next."""
import argparse
import json
import subprocess
import time
import urllib.parse
import urllib.request


class Rpc:
    def __init__(self, url):
        self.url = url
        self.counter = 0

    def call(self, method, params):
        self.counter += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self.counter, "method": method, "params": params}).encode()
        request = urllib.request.Request(self.url, body, {"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=15) as response:
            result = json.load(response)
        if "error" in result:
            raise RuntimeError(f"{method}: {result['error']}")
        return result["result"]

    def read(self, address, signature, *args):
        result = self.call("eth_call", [{"to": address, "data": calldata(signature, *args)}, "latest"])
        raw = result.removeprefix("0x")
        if len(raw) % 64:
            raise RuntimeError("Malformed ABI result")
        return [raw[i:i + 64] for i in range(0, len(raw), 64)]

    def send(self, sender, address, signature, *args):
        tx = self.call("eth_sendTransaction", [{"from": sender, "to": address,
                       "data": calldata(signature, *args), "gas": hex(3_000_000)}])
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            receipt = self.call("eth_getTransactionReceipt", [tx])
            if receipt:
                if int(receipt["status"], 16) != 1:
                    raise RuntimeError(f"Transaction reverted; do not retry blindly: {tx}")
                print(json.dumps({"transaction": tx, "action": signature.split("(")[0],
                                  "gasUsed": int(receipt["gasUsed"], 16)}), flush=True)
                return
            time.sleep(0.1)
        raise RuntimeError(f"Receipt uncertain; reread before retrying: {tx}")


def calldata(signature, *args):
    # Argument-vector execution only; no shell, keys, or arbitrary transaction recipients.
    return subprocess.check_output(["cast", "calldata", signature, *map(str, args)], text=True).strip()


def address(word):
    return "0x" + word[-40:]


def run(args):
    parsed = urllib.parse.urlparse(args.rpc_url)
    if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
        raise ValueError("This harness only accepts a loopback HTTP Anvil endpoint")
    if not 1 <= args.max_actions <= 100 or args.max_fill <= 0 or args.request_id <= 0:
        raise ValueError("Invalid bounded work parameters")
    rpc = Rpc(args.rpc_url)
    if int(rpc.call("eth_chainId", []), 16) != 31337 or "anvil" not in rpc.call("web3_clientVersion", []).lower():
        raise ValueError("Local Anvil chain 31337 required")
    if args.sender.lower() not in [a.lower() for a in rpc.call("eth_accounts", [])]:
        raise ValueError("Sponsor must be an unlocked local Anvil account")
    vault = address(rpc.read(args.escrow, "vault()")[0])
    if address(rpc.read(vault, "investmentEscrow()")[0]).lower() != args.escrow.lower():
        raise ValueError("Escrow is not the vault's canonical compartment")
    for _ in range(args.max_actions):
        request = rpc.read(args.escrow, "getRequest(uint256)", args.request_id)
        if len(request) != 10:
            raise ValueError("Unsupported request ABI")
        if int(request[3], 16) != 0:
            print("Request stopped or closed; no further work")
            return
        if request[1] != rpc.read(vault, "investmentVersion()")[0]:
            print("Configuration changed; owner recovery remains available")
            return
        sequence, available = int(request[2], 16), int(request[5], 16)
        encoded_assets = rpc.read(args.escrow, "requestAssets(uint256)", args.request_id)
        count = int(encoded_assets[1], 16)
        if not 1 <= count <= 5 or len(encoded_assets) != count + 2:
            raise ValueError("Unsupported request basket")
        assets = [address(word) for word in encoded_assets[2:]]
        pending = [int(rpc.read(args.escrow, "positions(uint256,address)", args.request_id, token)[0], 16)
                   for token in assets]
        try:
            preview = rpc.read(vault, "previewInvestment(uint256[])", "[" + ",".join(map(str, pending)) + "]")
        except RuntimeError:
            preview = []  # Incomplete/dust/paused: never interpret this as successful integration.
        if preview and int(preview[0], 16) > 0:
            rpc.send(args.sender, args.escrow, "integrate(uint256,uint256)", args.request_id, sequence)
            continue
        if available == 0:
            print("Personal acquisitions await integration or owner recovery")
            return
        limits = [int(rpc.read(args.escrow, "maxFillAmount(uint256,uint256)", args.request_id, i)[0], 16)
                  for i in range(count)]
        index = max(range(count), key=limits.__getitem__)
        amount = min(limits[index], available, args.max_fill)
        if amount == 0:
            print("No admissible fill; owner recovery remains available")
            return
        block = rpc.call("eth_getBlockByNumber", ["latest", False])
        deadline = int(block["timestamp"], 16) + 300
        rpc.send(args.sender, args.escrow, "fill(uint256,uint256,uint256,uint256,uint256)",
                 args.request_id, index, amount, sequence, deadline)
    print("Work cap reached; a later pass resumes confirmed state")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--escrow", required=True)
    parser.add_argument("--sender", required=True)
    parser.add_argument("--request-id", type=int, required=True)
    parser.add_argument("--max-fill", type=int, required=True, help="Settlement atomic units per purchase")
    parser.add_argument("--max-actions", type=int, default=20)
    try:
        run(parser.parse_args())
    except (RuntimeError, ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Progress paused: {error}\nConfirmed earlier transactions remain committed.\n")
