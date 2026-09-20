#!/usr/bin/env python3
"""A deliberately small, loopback-only ERC-4337 v0.9 laboratory bundler.

It is not an ERC-7562 implementation and must never be exposed outside an
isolated Anvil fixture.  It accepts one already-signed packed UserOperation,
persists the intent, and has a distinct unlocked Anvil sender call EntryPoint.
"""
import argparse
import fcntl
import http.server
import json
import re
import sqlite3
import threading
import urllib.parse
from pathlib import Path

CHAIN_ID = 31337
ZERO = '0x' + '0' * 40
USER_OP_EVENT = '0x49628fd1471006c1482da88028e9ce4dbb080b815c9b0344d39e5a8e6ec1419f'
VAULT_CREATED = '0x32c459f0706c3a07f3800e0e0366fbb8ecffedf431250fdf6a59e9fd5c7f20c4'
ADDR = re.compile(r'0x[0-9a-fA-F]{40}$')
HEX = re.compile(r'0x(?:[0-9a-fA-F]{2})*$')


class BundlerError(RuntimeError):
    pass


def integer(value):
    if isinstance(value, int):
        return value
    if not isinstance(value, str) or not re.fullmatch(r'0x[0-9a-fA-F]+', value):
        raise BundlerError('invalid_quantity')
    return int(value, 16)


def quantity(value):
    if value < 0:
        raise BundlerError('invalid_quantity')
    return hex(value)


def norm_address(value):
    if not isinstance(value, str) or not ADDR.fullmatch(value):
        raise BundlerError('invalid_address')
    return value.lower()


def norm_hex(value, size=None):
    if not isinstance(value, str) or not HEX.fullmatch(value):
        raise BundlerError('invalid_hex')
    value = value.lower()
    if size is not None and len(value) != 2 + size * 2:
        raise BundlerError('invalid_hex_size')
    return value


def word(value):
    return int(value).to_bytes(32, 'big')


def abi_bytes(value):
    raw = bytes.fromhex(norm_hex(value)[2:])
    return word(len(raw)) + raw + b'\0' * ((-len(raw)) % 32)


def selector(signature):
    # eth-utils is intentionally not a dependency of these local fixtures.
    import subprocess
    return bytes.fromhex(subprocess.check_output(['cast', 'sig', signature], text=True, timeout=10).strip()[2:])


def packed_op(op):
    """Normalize conventional v0.9 JSON fields and ABI-encode the tuple."""
    required = {'sender', 'nonce', 'initCode', 'callData', 'accountGasLimits',
                'preVerificationGas', 'gasFees', 'paymasterAndData', 'signature'}
    if set(op) != required:
        raise BundlerError('invalid_user_operation_fields')
    out = {
        'sender': norm_address(op['sender']), 'nonce': integer(op['nonce']),
        'initCode': norm_hex(op['initCode']), 'callData': norm_hex(op['callData']),
        'accountGasLimits': norm_hex(op['accountGasLimits'], 32),
        'preVerificationGas': integer(op['preVerificationGas']),
        'gasFees': norm_hex(op['gasFees'], 32),
        'paymasterAndData': norm_hex(op['paymasterAndData']), 'signature': norm_hex(op['signature']),
    }
    if out['initCode'] != '0x' or out['paymasterAndData'] != '0x' or not out['callData'] or not out['signature']:
        raise BundlerError('unsupported_user_operation')
    dynamic = ('initCode', 'callData', 'paymasterAndData', 'signature')
    values = [bytes.fromhex(out['sender'][2:]).rjust(32, b'\0'), word(out['nonce']), None, None,
              bytes.fromhex(out['accountGasLimits'][2:]), word(out['preVerificationGas']),
              bytes.fromhex(out['gasFees'][2:]), None, None]
    tails = [abi_bytes(out[x]) for x in dynamic]
    offsets = iter((32 * 9 + sum(len(t) for t in tails[:i]) for i in range(4)))
    for index in (2, 3, 7, 8):
        values[index] = word(next(offsets))
    return out, b''.join(values + tails)


def get_user_op_hash_data(op):
    _, encoded = packed_op(op)
    # A tuple containing dynamic members is itself dynamic: the sole argument
    # head points at the tuple body, which starts after that 32-byte head.
    return '0x' + (selector('getUserOpHash((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes))') + word(32) + encoded).hex()


def handle_ops_data(op, beneficiary):
    _, encoded = packed_op(op)
    # ABI: head(array offset, beneficiary), array length, then an element tuple.
    # The tuple offsets remain relative to the beginning of that tuple.
    body = word(1) + word(32) + encoded
    return '0x' + (selector('handleOps((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)[],address)')
                  + word(64) + bytes.fromhex(norm_address(beneficiary)[2:]).rjust(32, b'\0') + body).hex()


class Rpc:
    def __init__(self, url):
        import urllib.request
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme != 'http' or parsed.hostname not in ('127.0.0.1', 'localhost', '::1') or parsed.username or parsed.password:
            raise BundlerError('rpc_not_loopback')
        self.url, self.id, self.http = url, 0, urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def call(self, method, params):
        import urllib.request
        self.id += 1
        try:
            request = urllib.request.Request(self.url, json.dumps({'jsonrpc': '2.0', 'id': self.id, 'method': method, 'params': params}).encode(), {'Content-Type': 'application/json'})
            with self.http.open(request, timeout=10) as response:
                reply = json.load(response)
        except Exception as exc:
            raise BundlerError('rpc_unavailable') from exc
        if reply.get('error'):
            raise BundlerError('rpc_rejected')
        return reply['result']


class Store:
    def __init__(self, path):
        self.path = Path(path); self.path.parent.mkdir(parents=True, exist_ok=True)
        self.lock = open(str(self.path) + '.lock', 'a+')
        try: fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.lock.close(); raise BundlerError('state_db_locked')
        self.guard = threading.RLock()
        self.db = sqlite3.connect(self.path, check_same_thread=False)
        self.db.execute('pragma journal_mode=WAL'); self.db.execute('pragma synchronous=FULL')
        self.db.executescript('create table if not exists meta(k text primary key,v text); create table if not exists ops(hash text primary key,sender text,nonce text,body text,state text,txhash text,block text,blockhash text, unique(sender,nonce));')
        self.db.commit()

    def value(self, key):
        with self.guard:
            row = self.db.execute('select v from meta where k=?', (key,)).fetchone(); return row[0] if row else None
    def set(self, key, value):
        with self.guard:
            self.db.execute('insert into meta values(?,?) on conflict(k) do update set v=excluded.v', (key, str(value))); self.db.commit()
    def get(self, op_hash):
        with self.guard: return self.db.execute('select sender,nonce,body,state,txhash,block,blockhash from ops where hash=?', (op_hash,)).fetchone()
    def by_nonce(self, sender, nonce):
        with self.guard: return self.db.execute('select hash,body,state from ops where sender=? and nonce=?', (sender, str(nonce))).fetchone()
    def intent(self, op_hash, sender, nonce, body):
        with self.guard:
            self.db.execute('insert into ops values(?,?,?,?,?,?,?,?)', (op_hash, sender, str(nonce), body, 'intent', None, None, None)); self.db.commit()
    def reserve(self, op_hash, sender, nonce, body):
        """Atomically reserve a sender nonce before any external submission."""
        with self.guard:
            present = self.db.execute('select body,state from ops where hash=?', (op_hash,)).fetchone()
            if present:
                if present[0] != body: raise BundlerError('operation_hash_body_mismatch')
                if present[1] == 'intent': raise BundlerError('unknown_intent_pause')
                return False
            if self.db.execute('select 1 from ops where sender=? and nonce=?', (sender, str(nonce))).fetchone(): raise BundlerError('nonce_already_reserved')
            self.db.execute('insert into ops values(?,?,?,?,?,?,?,?)', (op_hash, sender, str(nonce), body, 'intent', None, None, None)); self.db.commit(); return True
    def sent(self, op_hash, txhash):
        with self.guard: self.db.execute('update ops set state=?,txhash=? where hash=?', ('sent', txhash, op_hash)); self.db.commit()
    def receipt(self, op_hash, block, blockhash):
        with self.guard: self.db.execute('update ops set state=?,block=?,blockhash=? where hash=?', ('mined', block, blockhash, op_hash)); self.db.commit()
    def close(self):
        with self.guard: self.db.close()
        fcntl.flock(self.lock, fcntl.LOCK_UN); self.lock.close()


class Bundler:
    def __init__(self, args):
        self.a, self.rpc, self.db = args, Rpc(args.rpc_url), Store(args.state_db)
        self.sender = norm_address(args.sender)
        catalog = json.loads(Path(args.addresses).read_text())
        execution = catalog.get('execution') or {}
        self.entry_point = norm_address(execution.get('entryPoint'))
        self.factory = norm_address(execution.get('factory'))
        self.vault_factory = norm_address(catalog['factory'])
        self.executor = norm_address(execution.get('executor'))
        self.entry_hash = norm_hex(execution.get('entryPointCodeHash'), 32)
        self.factory_hash = norm_hex(execution.get('factoryCodeHash'), 32)

    def runtime_hash(self, target):
        import subprocess
        return subprocess.check_output(['cast', 'keccak', self.rpc.call('eth_getCode', [target, 'latest'])], text=True, timeout=10).strip().lower()

    def authenticate(self):
        if integer(self.rpc.call('eth_chainId', [])) != CHAIN_ID or 'anvil' not in self.rpc.call('web3_clientVersion', []).lower(): raise BundlerError('anvil_31337_required')
        if self.sender not in [x.lower() for x in self.rpc.call('eth_accounts', [])]: raise BundlerError('sender_not_unlocked')
        if self.sender == self.executor: raise BundlerError('bundler_sender_must_differ_from_executor')
        if self.runtime_hash(self.entry_point) != self.entry_hash or self.runtime_hash(self.factory) != self.factory_hash: raise BundlerError('published_runtime_mismatch')
        if norm_address('0x' + self.rpc.call('eth_call', [{'to': self.factory, 'data': '0x' + selector('entryPoint()').hex()}, 'latest'])[-40:]) != self.entry_point or norm_address('0x' + self.rpc.call('eth_call', [{'to': self.factory, 'data': '0x' + selector('vaultFactory()').hex()}, 'latest'])[-40:]) != self.vault_factory: raise BundlerError('factory_binding_failed')
        genesis = self.rpc.call('eth_getBlockByNumber', ['0x0', False])
        deployment = self.deployment_anchor()
        namespace = json.dumps(self.context(genesis['hash'], deployment), sort_keys=True)
        old = self.db.value('namespace')
        if old and old != namespace: raise BundlerError('state_namespace_mismatch')
        self.db.set('namespace', namespace)
        self.db.set('genesis', genesis['hash'])
        self.db.set('deployment', json.dumps(deployment, sort_keys=True))

    def deployment_anchor(self):
        logs = self.rpc.call('eth_getLogs', [{'address': self.vault_factory, 'fromBlock': '0x0', 'toBlock': 'latest', 'topics': [VAULT_CREATED]}])
        if not logs: raise BundlerError('primary_entry_missing')
        first = min(logs, key=lambda log: integer(log['blockNumber']))
        block = self.rpc.call('eth_getBlockByNumber', [first['blockNumber'], False])
        if not block: raise BundlerError('deployment_anchor_missing')
        return {'deploymentBlock': first['blockNumber'], 'deploymentBlockHash': block['hash']}

    def context(self, genesis_hash, deployment=None):
        deployment = deployment or json.loads(self.db.value('deployment'))
        return {'chainId': CHAIN_ID, 'genesisHash': genesis_hash, 'entryPoint': self.entry_point,
                'factory': self.factory, 'entryPointCodeHash': self.entry_hash,
                'factoryCodeHash': self.factory_hash, 'executor': self.executor,
                'bundlerSender': self.sender, 'bundler': 'http://127.0.0.1:' + str(self.a.port), **deployment}

    def validate(self, op):
        op, _ = packed_op(op)
        verification, call = integer(op['accountGasLimits']) >> 128, integer(op['accountGasLimits']) & ((1 << 128) - 1)
        if not (100_000 <= verification <= 500_000 and 100_000 <= call <= 1_000_000 and 25_000 <= op['preVerificationGas'] <= 300_000): raise BundlerError('gas_bounds')
        account = op['sender']
        if self.rpc.call('eth_getCode', [account, 'latest']) == '0x': raise BundlerError('account_not_deployed')
        # Account immutable bindings: entryPoint(), escrow(), executor(). The latter must be nonzero.
        ep = norm_address('0x' + self.rpc.call('eth_call', [{'to': account, 'data': '0x' + selector('entryPoint()').hex()}, 'latest'])[-40:])
        escrow = norm_address('0x' + self.rpc.call('eth_call', [{'to': account, 'data': '0x' + selector('escrow()').hex()}, 'latest'])[-40:])
        executor = norm_address('0x' + self.rpc.call('eth_call', [{'to': account, 'data': '0x' + selector('executor()').hex()}, 'latest'])[-40:])
        request_id = integer(self.rpc.call('eth_call', [{'to': account, 'data': '0x' + selector('requestId()').hex()}, 'latest']))
        factory_data = selector('accounts(address,uint256)') + bytes.fromhex(escrow[2:]).rjust(32, b'\0') + word(request_id)
        mapped = norm_address('0x' + self.rpc.call('eth_call', [{'to': self.factory, 'data': '0x' + factory_data.hex()}, 'latest'])[-40:])
        if ep != self.entry_point or mapped != account or executor != self.executor: raise BundlerError('account_binding_failed')
        max_fee = integer(op['gasFees']) & ((1 << 128) - 1)
        prefund = (verification + call + op['preVerificationGas']) * max_fee
        budget = integer(self.rpc.call('eth_call', [{'to': account, 'data': '0x' + selector('getBudget()').hex()}, 'latest']))
        if budget < prefund: raise BundlerError('prefund_insufficient')
        # A full dry run happens before the external transaction.  EntryPoint normally
        # reverts simulation endpoints, so estimate handleOps is the portable local gate.
        data = handle_ops_data(op, self.sender)
        self.rpc.call('eth_call', [{'from': self.sender, 'to': self.entry_point, 'data': data}, 'latest'])
        gas = self.rpc.call('eth_estimateGas', [{'from': self.sender, 'to': self.entry_point, 'data': data}])
        return op, data, gas

    def submit(self, op):
        self.authenticate(); op, data, gas = self.validate(op)
        hash_data = get_user_op_hash_data(op)
        op_hash = norm_hex(self.rpc.call('eth_call', [{'to': self.entry_point, 'data': hash_data}, 'latest']), 32)
        body = json.dumps(op, sort_keys=True, separators=(',', ':'))
        if not self.db.reserve(op_hash, op['sender'], op['nonce'], body): return op_hash
        try: txhash = self.rpc.call('eth_sendTransaction', [{'from': self.sender, 'to': self.entry_point, 'data': data, 'gas': gas}])
        except Exception as exc: raise BundlerError('unknown_intent_pause') from exc
        self.db.sent(op_hash, norm_hex(txhash, 32)); return op_hash

    def receipt(self, op_hash):
        op_hash = norm_hex(op_hash, 32); row = self.db.get(op_hash)
        if not row: return None
        sender, nonce, _body, state, txhash, block, blockhash = row
        if state == 'intent': raise BundlerError('unknown_intent_pause')
        if state == 'mined':
            canonical = self.rpc.call('eth_getBlockByNumber', [block, False])
            if not canonical or canonical['hash'].lower() != blockhash.lower(): raise BundlerError('receipt_reorg_pause')
        receipt = self.rpc.call('eth_getTransactionReceipt', [txhash])
        if not receipt:
            if state == 'mined': raise BundlerError('receipt_reorg_pause')
            return None
        canonical = self.rpc.call('eth_getBlockByNumber', [receipt['blockNumber'], False])
        if not canonical or canonical['hash'].lower() != receipt['blockHash'].lower(): raise BundlerError('receipt_reorg_pause')
        # UserOperationEvent topic0 is intentionally checked by hash in addition to
        # sender/nonce.  We reconstruct success/cost from inner EntryPoint event,
        # never from outer handleOps status or gas use.
        events = [log for log in receipt.get('logs', []) if log.get('address', '').lower() == self.entry_point and log.get('topics', []) and log['topics'][0].lower() == USER_OP_EVENT]
        matched = [log for log in events if len(log['topics']) >= 3 and norm_hex(log['topics'][1], 32) == op_hash and norm_address('0x' + log['topics'][2][-40:]) == sender]
        if len(matched) != 1: raise BundlerError('user_operation_event_missing')
        data = norm_hex(matched[0]['data'])[2:]
        if len(data) < 256 or int(data[:64], 16) != int(nonce): raise BundlerError('user_operation_event_invalid')
        success, actual_gas_cost, actual_gas_used = int(data[64:128], 16) != 0, int(data[128:192], 16), int(data[192:256], 16)
        self.db.receipt(op_hash, receipt['blockNumber'], receipt['blockHash'])
        return {'userOpHash': op_hash, 'sender': sender, 'nonce': quantity(int(nonce)), 'success': success, 'actualGasCost': quantity(actual_gas_cost), 'actualGasUsed': quantity(actual_gas_used), 'receipt': receipt}


class Handler(http.server.BaseHTTPRequestHandler):
    bundler = None
    def respond(self, ident, result=None, error=None):
        body = {'jsonrpc': '2.0', 'id': ident}
        if error: body['error'] = {'code': -32602, 'message': str(error)}
        else: body['result'] = result
        raw = json.dumps(body, separators=(',', ':')).encode(); self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
    def do_POST(self):
        try:
            request = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0')))); method, params = request['method'], request.get('params', [])
            if method == 'eth_supportedEntryPoints': result = [self.bundler.entry_point]
            elif method == 'eth_chainId': result = hex(CHAIN_ID)
            elif method == 'eq_executionContext':
                self.bundler.authenticate(); result = self.bundler.context(self.bundler.db.value('genesis'))
            elif method == 'eth_sendUserOperation':
                if len(params) != 2 or norm_address(params[1]) != self.bundler.entry_point: raise BundlerError('entrypoint_mismatch')
                result = self.bundler.submit(params[0])
            elif method == 'eth_getUserOperationReceipt': result = self.bundler.receipt(params[0]) if len(params) == 1 else (_ for _ in ()).throw(BundlerError('invalid_params'))
            else: raise BundlerError('method_not_supported')
            self.respond(request.get('id'), result=result)
        except Exception as exc: self.respond(request.get('id') if 'request' in locals() else None, error=exc)
    def log_message(self, *args): pass


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rpc-url', required=True); p.add_argument('--sender', required=True); p.add_argument('--state-db', required=True); p.add_argument('--port', type=int, required=True); p.add_argument('--addresses', default='deployments/31337/addresses.json'); p.add_argument('--manifest', default='deployments/manifest.json')
    a = p.parse_args()
    if not 1 <= a.port <= 65535: p.error('unsafe port')
    bundler = Bundler(a); bundler.authenticate(); Handler.bundler = bundler
    server = http.server.ThreadingHTTPServer(('127.0.0.1', a.port), Handler)
    try: server.serve_forever()
    finally: server.server_close(); bundler.db.close()

if __name__ == '__main__': main()
