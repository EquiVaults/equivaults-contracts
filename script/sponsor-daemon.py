#!/usr/bin/env python3
"""Crash-safe, local-only sponsor for verified v2 InvestmentEscrow fill/integrate calls."""
import argparse
import copy
import fcntl
import http.server
import json
import math
import re
import signal
import sqlite3
import subprocess
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path
CHAIN_ID = 31337
STATUS_SCHEMA = 'equivaults-sponsor-status/v1'
VAULT_CREATED = '0x32c459f0706c3a07f3800e0e0366fbb8ecffedf431250fdf6a59e9fd5c7f20c4'

# These are the only ABI shapes used by the local schedulers on their hot path.
# Keep dynamic shapes on cast below: its parser remains the compatibility path for
# every signature or argument representation not covered by this exact encoder.
STATIC_ABI = {
    'protocolVersion()': ('0x2ae9c600', ()),
    'vaultCount()': ('0xa7c6a100', ()),
    'registry()': ('0x7b103999', ()),
    'settlementAsset()': ('0xd3781d58', ()),
    'vaults(uint256)': ('0x8c64ea4a', ('uint256',)),
    'isVault(address)': ('0x652b9b41', ('address',)),
    'investmentEscrow()': ('0xdcbc3bb6', ()),
    'vault()': ('0xfbfa77cf', ()),
    'settlement()': ('0x51160630', ()),
    'nextRequestId()': ('0x6a84a985', ()),
    'getRequest(uint256)': ('0xc58343ef', ('uint256',)),
    'investmentVersion()': ('0xa1e04e29', ()),
    'requestAssets(uint256)': ('0x73303e1f', ('uint256',)),
    'positions(uint256,address)': ('0xe684d718', ('uint256', 'address')),
    'maxFillAmount(uint256,uint256)': ('0xc0f0cc25', ('uint256', 'uint256')),
    'integrate(uint256,uint256)': ('0x55c59be7', ('uint256', 'uint256')),
    'fill(uint256,uint256,uint256,uint256,uint256)': ('0xc2807d6a', ('uint256',) * 5),
    'entryPoint()': ('0xb0d691fe', ()),
    'vaultFactory()': ('0xd8a06f73', ()),
    'policy()': ('0x0505c8c9', ()),
    'owner()': ('0x8da5cb5b', ()),
    'executor()': ('0xc34c08e5', ()),
    'escrow()': ('0xe2fdcc17', ()),
    'requestId()': ('0x006d6cae', ()),
    'attempts()': ('0x5754a042', ()),
    'paused()': ('0x5c975abb', ()),
    'policyEpoch()': ('0xa921d322', ()),
    'getBudget()': ('0x127714c7', ()),
    'accounts(address,uint256)': ('0x87524581', ('address', 'uint256')),
    'getNonce(address,uint192)': ('0x35567e1a', ('address', 'uint192')),
    'executeIntegrate(uint256)': ('0x3aaf8892', ('uint256',)),
    'executeFill(uint256,uint256,uint256,uint256)': ('0xfc75c449', ('uint256',) * 4),
}
_CODE_HASHES = {}

def integer(value):
    return int(value, 16)

def address(value):
    return '0x' + value[-40:].lower()

def now_ms():
    return int(time.time() * 1000)

def _static_calldata(signature, args):
    """Encode only canonical static values; return None for cast compatibility."""
    layout = STATIC_ABI.get(signature)
    if not layout or len(args) != len(layout[1]):
        return None
    selector, types = layout
    words = []
    for value, kind in zip(args, types):
        if kind.startswith('uint'):
            if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value < 2 ** int(kind[4:]):
                return None
            words.append(f'{value:064x}')
        elif kind == 'address':
            if not isinstance(value, str) or not re.fullmatch(r'0x[0-9a-fA-F]{40}', value):
                return None
            words.append(value[2:].lower().rjust(64, '0'))
        else:
            return None
    return selector + ''.join(words)

def calldata(signature, *args):
    encoded = _static_calldata(signature, args)
    if encoded is not None:
        return encoded
    return subprocess.check_output(['cast', 'calldata', signature, *map(str, args)], text=True, timeout=10).strip()

def hash_code(code):
    # Runtime code is read freshly by the caller.  Only the pure hash of identical
    # returned bytes is cached, so no security-relevant chain read crosses blocks.
    key = code.lower() if isinstance(code, str) and re.fullmatch(r'0x[0-9a-fA-F]*', code) else None
    if key is not None and key in _CODE_HASHES:
        return _CODE_HASHES[key]
    digest = subprocess.check_output(['cast', 'keccak', code], text=True, timeout=10).strip().lower()
    if key is not None:
        _CODE_HASHES[key] = digest
    return digest

class Pause(RuntimeError):
    """A controlled public operator reason; never an arbitrary RPC error message."""

class RpcTransportError(RuntimeError):
    """Transport or provider failure, without evidence of an EVM rejection."""

class RpcExecutionError(RuntimeError):
    pass

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RpcTransportError('rpc_redirect_refused')

class Rpc:

    def __init__(self, url):
        self.url = url
        self.id = 0
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def call(self, method, params):
        self.id += 1
        try:
            req = urllib.request.Request(self.url, json.dumps({'jsonrpc': '2.0', 'id': self.id, 'method': method, 'params': params}).encode(), {'Content-Type': 'application/json'})
            with self.http.open(req, timeout=10) as response:
                reply = json.load(response)
        except Exception as error:
            raise RpcTransportError('rpc_transport') from error
        error = reply.get('error')
        if error:
            # This local operator only accepts Anvil. Its explicit EVM revert response
            # must not be confused with JSON-RPC internal/state/method errors.
            if (method in ('eth_call', 'eth_estimateGas') and isinstance(error, dict)
                    and error.get('code') == 3
                    and str(error.get('message', '')).startswith('execution reverted')
                    and isinstance(error.get('data'), str)
                    and re.fullmatch(r'0x(?:[0-9a-fA-F]{2})*', error['data'])):
                raise RpcExecutionError('rpc_execution_rejected')
            raise RpcTransportError('rpc_unavailable')
        return reply['result']

    def read(self, target, data, block):
        return self.call('eth_call', [{'to': target, 'data': data}, block])

    def uint(self, target, signature, block, *args):
        return integer(self.read(target, calldata(signature, *args), block)[:66])

    def address(self, target, signature, block, *args):
        return address(self.read(target, calldata(signature, *args), block))

class Store:

    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.lock = open(str(self.path) + '.lock', 'a+')
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.lock.close()
            raise RuntimeError('state_db_locked')
        self.db = sqlite3.connect(self.path)
        self.db.execute('pragma journal_mode=WAL')
        self.db.execute('pragma synchronous=FULL')
        self.db.executescript('create table if not exists meta(k text primary key,v text);create table if not exists tx(nonce text primary key,hash text,state text,reserved text,spent text,anchor_block text,anchor_hash text,intent text);create table if not exists failures(k text primary key,n integer,next_at integer);')
        self.db.commit()

    def value(self, key):
        row = self.db.execute('select v from meta where k=?', (key,)).fetchone()
        return row[0] if row else None

    def set(self, key, value):
        self.db.execute('insert into meta values(?,?) on conflict(k) do update set v=excluded.v', (key, str(value)))
        self.db.commit()

    def reserve(self, nonce, reserved, intent):
        self.db.execute('insert into tx values(?,?,?,?,?,?,?,?)', (str(nonce), None, 'intent', str(reserved), '0', None, None, json.dumps(intent)))
        self.db.commit()

    def sent(self, nonce, tx_hash):
        self.db.execute('update tx set hash=?,state=? where nonce=?', (tx_hash, 'sent', str(nonce)))
        self.db.commit()

    def settle(self, nonce, spent, state, block, block_hash):
        self.db.execute('update tx set spent=?,state=?,anchor_block=?,anchor_hash=? where nonce=?', (str(spent), state, block, block_hash, str(nonce)))
        self.db.commit()

    def inflight(self):
        return self.db.execute("select nonce,hash,reserved from tx where state in ('intent','sent')").fetchall()

    def reserved(self):
        return sum((int(x[0]) for x in self.db.execute("select reserved from tx where state in ('intent','sent')")))

    def spent(self):
        return sum((int(x[0]) for x in self.db.execute("select spent from tx where state in ('mined','reverted')")))

    def failure(self, key):
        row = self.db.execute('select n from failures where k=?', (key,)).fetchone()
        return row[0] if row else 0

    def fail(self, key, delay):
        n = self.failure(key) + 1
        self.db.execute('insert into failures values(?,?,?) on conflict(k) do update set n=?,next_at=?', (key, n, now_ms() + delay * 1000, n, now_ms() + delay * 1000))
        self.db.commit()
        return n

    def ready(self, key):
        row = self.db.execute('select next_at from failures where k=?', (key,)).fetchone()
        return not row or row[0] <= now_ms()

    def defer(self, key, delay):
        # A simulation consumes no gas and must not exhaust the failed-broadcast cap.
        self.db.execute('insert into failures values(?,0,?) on conflict(k) do update set next_at=excluded.next_at', (key, now_ms() + delay * 1000))
        self.db.commit()

    def close(self):
        self.db.close()
        fcntl.flock(self.lock, fcntl.LOCK_UN)
        self.lock.close()

class Status:

    def __init__(self, budget, sender):
        self.lock = threading.Lock()
        self.requests = {}
        self.base = {'schema': STATUS_SCHEMA, 'chainId': 31337, 'factory': None, 'genesisHash': None, 'deploymentBlock': None, 'deploymentBlockHash': None, 'contractsCommit': None, 'heartbeatAt': 0, 'observedAt': None, 'operator': {'state': 'paused', 'reason': 'starting', 'address': sender.lower(), 'spentWei': '0', 'reservedWei': '0', 'budgetWei': str(budget)}}
        self.published = copy.deepcopy(self.base)
        self.published_requests = {}

    def request(self, item):
        with self.lock:
            if item:
                self.requests[item['escrow'].lower(), item['requestId']] = dict(item)
            if len(self.requests) > 128:
                self.requests.pop(next(iter(self.requests)))

    def publish(self):
        # Readers see a completed scheduler snapshot, never a half-written cycle.
        with self.lock:
            self.published = copy.deepcopy(self.base)
            self.published_requests = copy.deepcopy(self.requests)

    def render(self, escrow=None, request_id=None):
        with self.lock:
            out = dict(self.published)
            out['request'] = self.published_requests.get((escrow.lower(), str(request_id))) if escrow and request_id is not None else None
            return json.dumps(out, separators=(',', ':'))

class StatusHandler(http.server.BaseHTTPRequestHandler):
    status = None

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != '/v1/status':
            self.send_error(404)
            return
        q = urllib.parse.parse_qs(parsed.query)
        e = q.get('escrow', [None])[0]
        r = q.get('requestId', [None])[0]
        if (e is None) != (r is None) or (e and (not re.fullmatch(r'0x[0-9a-fA-F]{40}', e) or not re.fullmatch(r'[1-9][0-9]{0,77}', r) or int(r) >= 2**256)):
            self.send_error(400)
            return
        body = self.status.render(e, r).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

def start_http(status, port):
    StatusHandler.status = status
    server = http.server.ThreadingHTTPServer(('127.0.0.1', port), StatusHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server

class Sponsor:

    def __init__(self, args):
        self.a = args
        self.rpc = Rpc(args.rpc_url)
        self.db = Store(args.state_db)
        self.status = Status(args.budget_wei, args.sender)
        self.stop = threading.Event()
        self.cursor_vault = int(self.db.value('cursor_vault') or 0)
        self.cursor_request = json.loads(self.db.value('cursor_request') or '{}')
        self.discovery_from = 0

    def pause(self, reason):
        op = self.status.base['operator']
        op.update(state='paused', reason=reason, spentWei=str(self.db.spent()), reservedWei=str(self.db.reserved()))

    def halt(self, reason):
        # Reorgs and ambiguous sends require operator investigation, including after restart.
        self.db.set('halt', reason)
        raise Pause(reason)

    def authenticate(self):
        url = urllib.parse.urlparse(self.a.rpc_url)
        if url.scheme != 'http' or url.hostname not in ('127.0.0.1', 'localhost', '::1') or url.username or url.password:
            raise Pause('rpc_not_loopback')
        if integer(self.rpc.call('eth_chainId', [])) != CHAIN_ID or 'anvil' not in self.rpc.call('web3_clientVersion', []).lower():
            raise Pause('anvil_31337_required')
        if self.a.sender.lower() not in [x.lower() for x in self.rpc.call('eth_accounts', [])]:
            raise Pause('sender_not_unlocked')
        catalog = json.loads(Path(self.a.addresses).read_text())
        manifest = json.loads(Path(self.a.manifest).read_text())
        entry = next((x for x in catalog['factories'] if x['protocolVersion'] == 2))
        factory = catalog['factory']
        if entry['address'].lower() != factory.lower() or entry['contractsCommit'] != manifest['contractsCommit'] or hash_code(self.rpc.call('eth_getCode', [factory, 'latest'])) != entry['codeHash'].lower():
            raise Pause('factory_catalog_auth_failed')
        block = self.rpc.call('eth_getBlockByNumber', ['latest', False])
        tag = block['number']
        if self.rpc.uint(factory, 'protocolVersion()', tag) != 2:
            raise Pause('factory_version_failed')
        anchor = self.db.value('deployment_number')
        logs = []
        if anchor is not None:
            logs = self.rpc.call('eth_getLogs', [{'address': factory, 'fromBlock': anchor, 'toBlock': anchor, 'topics': [VAULT_CREATED]}])
        else:
            # Bound discovery as well as request scanning; continue on the next cycle
            # if this factory first appeared far into a local chain's history.
            for _ in range(16):
                end = min(integer(tag), self.discovery_from + 1999)
                if self.discovery_from > end:
                    self.discovery_from = 0
                    break
                logs = self.rpc.call('eth_getLogs', [{'address': factory, 'fromBlock': hex(self.discovery_from), 'toBlock': hex(end), 'topics': [VAULT_CREATED]}])
                self.discovery_from = end + 1
                if logs:
                    break
        if not logs:
            raise Pause('primary_entry_missing')
        first = min(logs, key=lambda x: integer(x['blockNumber']))
        genesis = self.rpc.call('eth_getBlockByNumber', ['0x0', False])
        deployment = self.rpc.call('eth_getBlockByNumber', [first['blockNumber'], False])
        namespace = {'genesis': genesis['hash'], 'deployment': deployment['hash'], 'factory': factory.lower(), 'chain': 31337, 'commit': manifest['contractsCommit'], 'sender': self.a.sender.lower(), 'budget': str(self.a.budget_wei)}
        old = self.db.value('namespace')
        if old and old != json.dumps(namespace, sort_keys=True):
            raise Pause('state_namespace_mismatch')
        self.db.set('namespace', json.dumps(namespace, sort_keys=True))
        self.db.set('deployment_number', first['blockNumber'])
        self.factory = factory
        self.status.base.update(factory=factory, genesisHash=genesis['hash'], deploymentBlock=str(integer(first['blockNumber'])), deploymentBlockHash=deployment['hash'], contractsCommit=manifest['contractsCommit'])

    def reconcile(self):
        if self.db.value('halt'):
            raise Pause(self.db.value('halt'))
        # The latest confirmed block's hash commits to every earlier ancestor.
        # Checking this cumulative anchor keeps RPC work constant as the ledger grows.
        anchor = self.db.db.execute('select anchor_block,anchor_hash from tx where anchor_block is not null order by length(anchor_block) desc,anchor_block desc limit 1').fetchone()
        def check_anchor():
            if not anchor:
                return
            number, expected = anchor
            block = self.rpc.call('eth_getBlockByNumber', [number, False])
            if not block or block['hash'].lower() != expected.lower():
                self.halt('receipt_reorg_pause')
        check_anchor()
        for nonce, tx_hash, reserved in self.db.inflight():
            if not tx_hash:
                self.halt('unknown_intent_pause')
            receipt = self.rpc.call('eth_getTransactionReceipt', [tx_hash])
            if not receipt:
                raise Pause('pending_receipt_pause')
            canonical = self.rpc.call('eth_getBlockByNumber', [receipt['blockNumber'], False])
            if not canonical or canonical['hash'].lower() != receipt['blockHash'].lower():
                self.halt('receipt_reorg_pause')
            check_anchor()
            spent = integer(receipt['gasUsed']) * integer(receipt['effectiveGasPrice'])
            if spent > int(reserved):
                self.halt('receipt_cost_invalid_pause')
            state = 'mined' if integer(receipt['status']) else 'reverted'
            # The charge and failed-attempt counter are one crash-atomic commit.
            intent = json.loads(self.db.db.execute('select intent from tx where nonce=?', (nonce,)).fetchone()[0])
            with self.db.db:
                self.db.db.execute('update tx set spent=?,state=?,anchor_block=?,anchor_hash=? where nonce=?', (str(spent), state, receipt['blockNumber'], receipt['blockHash'], nonce))
                if state == 'reverted' and intent.get('key'):
                    self.db.db.execute('insert into failures values(?,1,?) on conflict(k) do update set n=n+1,next_at=excluded.next_at', (intent['key'], now_ms() + self.a.backoff * 1000))

    def send(self, target, data, intent):
        if self.db.inflight():
            raise Pause('inflight_pause')
        pending = integer(self.rpc.call('eth_getTransactionCount', [self.a.sender, 'pending']))
        latest = integer(self.rpc.call('eth_getTransactionCount', [self.a.sender, 'latest']))
        if pending != latest:
            raise Pause('nonce_drift_pause')
        live_price = integer(self.rpc.call('eth_gasPrice', []))
        if live_price > self.a.max_gas_price:
            raise Pause('gas_price_cap_pause')
        try:
            estimate = integer(self.rpc.call('eth_estimateGas', [{'from': self.a.sender, 'to': target, 'data': data}]))
        except RpcExecutionError:
            raise RpcExecutionError('simulation_rejected')
        gas = estimate + self.a.gas_buffer
        if gas > self.a.max_gas:
            raise Pause('gas_cap_pause')
        reserve = gas * live_price
        balance = integer(self.rpc.call('eth_getBalance', [self.a.sender, 'latest']))
        if balance < self.db.reserved() + reserve:
            raise Pause('sponsor_balance_pause')
        if self.db.spent() + self.db.reserved() + reserve > self.a.budget_wei:
            raise Pause('budget_pause')
        try:
            self.rpc.call('eth_call', [{'from': self.a.sender, 'to': target, 'data': data, 'gas': hex(gas)}, 'latest'])
        except RpcExecutionError:
            raise RpcExecutionError('simulation_rejected')
        self.db.reserve(pending, reserve, intent)
        try:
            tx_hash = self.rpc.call('eth_sendTransaction', [{'from': self.a.sender, 'to': target, 'data': data, 'gas': hex(gas), 'gasPrice': hex(live_price), 'nonce': hex(pending)}])
        except (RpcTransportError, RpcExecutionError):
            self.halt('unknown_intent_pause')
        self.db.sent(pending, tx_hash)
        return tx_hash

    def cycle(self):
        block = self.rpc.call('eth_getBlockByNumber', ['latest', False])
        tag = block['number']
        self.status.base['observedAt'] = {'blockNumber': str(integer(tag)), 'blockHash': block['hash'], 'timestamp': integer(block['timestamp'])}
        self.reconcile()
        count = self.rpc.uint(self.factory, 'vaultCount()', tag)
        if not count:
            return
        factory_registry = self.rpc.address(self.factory, 'registry()', tag)
        factory_settlement = self.rpc.address(self.factory, 'settlementAsset()', tag)
        first_vault = self.cursor_vault
        for step in range(min(count, self.a.scan_vaults)):
            if self.stop.is_set():
                return
            index = (first_vault + step) % count
            vault = self.rpc.address(self.factory, 'vaults(uint256)', tag, index)
            if not self.rpc.uint(self.factory, 'isVault(address)', tag, vault) or self.rpc.uint(vault, 'protocolVersion()', tag) != 2 or self.rpc.call('eth_getCode', [vault, tag]) == '0x':
                continue
            if self.rpc.address(vault, 'registry()', tag) != factory_registry or self.rpc.address(vault, 'settlementAsset()', tag) != factory_settlement:
                continue
            escrow = self.rpc.address(vault, 'investmentEscrow()', tag)
            if self.rpc.address(escrow, 'vault()', tag) != vault or self.rpc.address(escrow, 'registry()', tag) != factory_registry or self.rpc.address(escrow, 'settlement()', tag) != factory_settlement or (self.rpc.uint(escrow, 'protocolVersion()', tag) != 2):
                continue
            total = self.rpc.uint(escrow, 'nextRequestId()', tag) - 1
            start = self.cursor_request.get(escrow, 1)
            for offset in range(min(total, self.a.scan_requests)):
                if self.stop.is_set():
                    return
                rid = (start - 1 + offset) % max(total, 1) + 1
                # Advance durably before any possible send/pause, keeping restarts fair.
                self.cursor_vault = (index + 1) % count
                self.cursor_request[escrow] = rid % max(total, 1) + 1
                self.db.set('cursor_vault', self.cursor_vault)
                self.db.set('cursor_request', json.dumps(self.cursor_request))
                if self.try_request(vault, escrow, rid, tag, block):
                    return
            self.cursor_request[escrow] = (start - 1 + self.a.scan_requests) % max(total, 1) + 1
        self.cursor_vault = (first_vault + min(count, self.a.scan_vaults)) % count
        self.db.set('cursor_vault', self.cursor_vault)
        self.db.set('cursor_request', json.dumps(self.cursor_request))

    def try_request(self, vault, escrow, rid, tag, block):
        raw = self.rpc.read(escrow, calldata('getRequest(uint256)', rid), tag)[2:]
        words = [raw[i:i + 64] for i in range(0, len(raw), 64)]
        if len(words) != 10:
            return False
        owner = address(words[0])
        version = '0x' + words[1]
        seq = integer('0x' + words[2])
        state = integer('0x' + words[3])
        available = integer('0x' + words[5])
        key = f'{escrow}:{rid}:{version}:{seq}'
        item = {'vault': vault, 'escrow': escrow, 'requestId': str(rid), 'owner': owner, 'version': version, 'sequence': str(seq), 'state': 'queued', 'reason': None, 'lastTxHash': None, 'updatedAt': now_ms()}
        self.status.request(item)
        if state:
            item.update(state='stopped' if state == 1 else 'closed')
            self.status.request(item)
            return False
        if version != self.rpc.read(vault, calldata('investmentVersion()'), tag):
            item.update(state='recovery_required', reason='version_changed')
            self.status.request(item)
            return False
        if self.db.failure(key) >= self.a.max_failed_attempts:
            item.update(state='waiting_operator', reason='failed_attempt_limit')
            self.status.request(item)
            return False
        if not self.db.ready(key):
            item.update(state='waiting_market', reason='simulation_backoff')
            self.status.request(item)
            return False
        try:
            assets = self.rpc.read(escrow, calldata('requestAssets(uint256)', rid), tag)[2:]
            n = integer('0x' + assets[64:128])
            if not 1 <= n <= 5 or len(assets) != (n + 2) * 64:
                raise Pause('request_basket_invalid_pause')
            tokens = [address(assets[128 + i * 64:192 + i * 64]) for i in range(n)]
            pending = [integer(self.rpc.read(escrow, calldata('positions(uint256,address)', rid, t), tag)[:66]) for t in tokens]
            try:
                preview = integer(self.rpc.read(vault, calldata('previewInvestment(uint256[])', '[' + ','.join(map(str, pending)) + ']'), tag)[:66])
            except RpcExecutionError:
                preview = 0  # An incomplete basket may still accept another fill.
            if preview:
                data = calldata('integrate(uint256,uint256)', rid, seq)
            else:
                # No settlement means no purchase, independent of route health. The
                # unsuccessful preview above only establishes no current integration;
                # it does not establish a market cause or permanent impossibility.
                limits = [self.rpc.uint(escrow, 'maxFillAmount(uint256,uint256)', tag, rid, i) for i in range(n)] if available else []
                amount = min(max(limits, default=0), available, self.a.max_fill)
                if not amount:
                    item.update(state='no_admissible_action', reason='no_admissible_action')
                    self.status.request(item)
                    return False
                data = calldata('fill(uint256,uint256,uint256,uint256,uint256)', rid, limits.index(max(limits)), amount, seq, integer(block['timestamp']) + 300)
            item['state'] = 'executing'
            canonical = self.rpc.call('eth_getBlockByNumber', [tag, False])
            if not canonical or canonical['hash'].lower() != block['hash'].lower():
                raise Pause('snapshot_reorg_pause')
            item['lastTxHash'] = self.send(escrow, data, {**item, 'key': key})
            self.status.request(item)
            return True
        except RpcExecutionError:
            item.update(state='waiting_market', reason='onchain_execution_rejected')
            self.db.defer(key, self.a.backoff)
            self.status.request(item)
            return False
        except RpcTransportError:
            item.update(state='waiting_operator', reason='rpc_unavailable')
            self.status.request(item)
            raise
        except Pause as error:
            item.update(state='waiting_operator', reason=str(error))
            self.status.request(item)
            raise

    def run(self):
        server = start_http(self.status, self.a.status_port)
        try:
            while not self.stop.is_set():
                try:
                    # Reauthenticate before every cycle and before reconciling old state.
                    self.authenticate()
                    self.cycle()
                    self.status.base['operator'].update(state='running', reason=None, spentWei=str(self.db.spent()), reservedWei=str(self.db.reserved()))
                    self.status.base['heartbeatAt'] = now_ms()
                except Pause as error:
                    self.pause(str(error))
                    if self.status.base['observedAt']:
                        self.status.base['heartbeatAt'] = now_ms()
                except Exception:
                    # RPC/config uncertainty cannot refresh a successful heartbeat.
                    self.pause('operator_unavailable')
                self.status.publish()
                self.stop.wait(self.a.interval)
        finally:
            server.shutdown()
            server.server_close()
            self.db.close()

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--rpc-url', required=True)
    p.add_argument('--sender', required=True)
    p.add_argument('--state-db', required=True)
    p.add_argument('--status-port', type=int, default=18789)
    p.add_argument('--budget-wei', type=int, required=True)
    p.add_argument('--max-fill', type=int, required=True)
    p.add_argument('--interval', type=float, default=2)
    p.add_argument('--addresses', default='deployments/31337/addresses.json')
    p.add_argument('--manifest', default='deployments/manifest.json')
    p.add_argument('--max-gas', type=int, default=3000000)
    p.add_argument('--max-gas-price', type=int, default=2000000000)
    p.add_argument('--gas-buffer', type=int, default=50000)
    p.add_argument('--scan-vaults', type=int, default=16)
    p.add_argument('--scan-requests', type=int, default=64)
    p.add_argument('--max-failed-attempts', type=int, default=5)
    p.add_argument('--backoff', type=int, default=5)
    a = p.parse_args()
    if min(a.budget_wei, a.max_fill, a.max_gas, a.max_gas_price, a.scan_vaults, a.scan_requests, a.max_failed_attempts, a.backoff) <= 0 or a.gas_buffer < 0 or not math.isfinite(a.interval) or a.interval <= 0 or (not 1 <= a.status_port <= 65535) or not re.fullmatch(r'0x[0-9a-fA-F]{40}', a.sender) or a.scan_vaults > 64 or a.scan_requests > 128:
        p.error('unsafe bounds')
    sponsor = Sponsor(a)
    signal.signal(signal.SIGTERM, lambda *_: sponsor.stop.set())
    signal.signal(signal.SIGINT, lambda *_: sponsor.stop.set())
    sponsor.run()
if __name__ == '__main__':
    main()
