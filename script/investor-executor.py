#!/usr/bin/env python3
"""Local-only investor-funded ERC-4337 execution scheduler for Anvil 31337.

This program never sends an Ethereum transaction.  Its only write is a signed
UserOperation sent to the separately configured loopback laboratory bundler.
"""
import argparse
import copy
import fcntl
import importlib.util
import json
import sqlite3
import subprocess
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('sponsor_daemon', ROOT / 'script/sponsor-daemon.py')
sponsor = importlib.util.module_from_spec(spec); spec.loader.exec_module(sponsor)
bundle_spec = importlib.util.spec_from_file_location('local_bundler', ROOT / 'script/local-bundler.py')
bundler = importlib.util.module_from_spec(bundle_spec); bundle_spec.loader.exec_module(bundler)

CHAIN_ID = 31337
VERIFY_GAS, CALL_GAS, PRE_GAS = 200_000, 800_000, 100_000


class ExecutionStore:
    """Separate account+nonce ledger; an unresolved signed operation is a stop."""
    def __init__(self, path):
        self.path = Path(path); self.path.parent.mkdir(parents=True, exist_ok=True)
        self.lock = open(str(self.path) + '.lock', 'a+')
        try: fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.lock.close(); raise RuntimeError('state_db_locked')
        self.db = sqlite3.connect(self.path); self.db.execute('pragma journal_mode=WAL'); self.db.execute('pragma synchronous=FULL')
        self.db.executescript('create table if not exists meta(k text primary key,v text); create table if not exists ops(account text,nonce text,hash text,body text,state text,block text,blockhash text, unique(account,nonce));')
        self.db.commit()
    def value(self, key):
        row = self.db.execute('select v from meta where k=?', (key,)).fetchone(); return row[0] if row else None
    def set(self, key, value): self.db.execute('insert into meta values(?,?) on conflict(k) do update set v=excluded.v', (key, str(value))); self.db.commit()
    def pending(self): return self.db.execute("select account,nonce,hash from ops where state in ('intent','sent')").fetchall()
    def intent(self, account, nonce, body): self.db.execute('insert into ops values(?,?,?,?,?,?,?)', (account, str(nonce), None, body, 'intent', None, None)); self.db.commit()
    def sent(self, nonce, op_hash): self.db.execute('update ops set hash=?,state=? where nonce=?', (op_hash, 'sent', str(nonce))); self.db.commit()
    def settled(self, nonce, block, blockhash): self.db.execute('update ops set state=?,block=?,blockhash=? where nonce=?', ('mined', block, blockhash, str(nonce))); self.db.commit()
    def close(self): self.db.close(); fcntl.flock(self.lock, fcntl.LOCK_UN); self.lock.close()


class Executor:
    def __init__(self, args):
        self.a = args; self.rpc = sponsor.Rpc(args.rpc_url); self.db = ExecutionStore(args.state_db)
        self.status = sponsor.Status(0, args.sender); self.status.base['funding'] = 'investor'
        self.stop = threading.Event(); self.cursor_vault = int(self.db.value('cursor_vault') or 0); self.cursor_request = json.loads(self.db.value('cursor_request') or '{}')
        catalog = json.loads(Path(args.addresses).read_text()); self.catalog = catalog
        ex = catalog.get('execution') or {}; self.entry_point = bundler.norm_address(ex.get('entryPoint')); self.execution_factory = bundler.norm_address(ex.get('factory'))
        self.entry_hash = bundler.norm_hex(ex.get('entryPointCodeHash'), 32); self.execution_hash = bundler.norm_hex(ex.get('factoryCodeHash'), 32)
        self.factory = bundler.norm_address(catalog['factory']); self.sender = bundler.norm_address(args.sender)

    def runtime_hash(self, value): return subprocess.check_output(['cast', 'keccak', self.rpc.call('eth_getCode', [value, 'latest'])], text=True, timeout=10).strip().lower()
    def call(self, target, signature, block, *values): return self.rpc.read(target, sponsor.calldata(signature, *values), block)
    def uint(self, target, signature, block, *values): return sponsor.integer(self.call(target, signature, block, *values)[:66])
    def addr(self, target, signature, block, *values): return sponsor.address(self.call(target, signature, block, *values))

    def authenticate(self):
        parsed = urllib.parse.urlparse(self.a.bundler_url)
        if parsed.scheme != 'http' or parsed.hostname not in ('127.0.0.1', 'localhost', '::1') or parsed.username or parsed.password: raise sponsor.Pause('bundler_not_loopback')
        if sponsor.integer(self.rpc.call('eth_chainId', [])) != CHAIN_ID or 'anvil' not in self.rpc.call('web3_clientVersion', []).lower(): raise sponsor.Pause('anvil_31337_required')
        if self.sender not in [x.lower() for x in self.rpc.call('eth_accounts', [])]: raise sponsor.Pause('sender_not_unlocked')
        if self.runtime_hash(self.entry_point) != self.entry_hash or self.runtime_hash(self.execution_factory) != self.execution_hash: raise sponsor.Pause('execution_runtime_mismatch')
        if self.addr(self.execution_factory, 'entryPoint()', 'latest') != self.entry_point or self.addr(self.execution_factory, 'vaultFactory()', 'latest') != self.factory: raise sponsor.Pause('execution_factory_binding_failed')
        primary = next((x for x in self.catalog.get('factories', []) if x.get('address', '').lower() == self.factory), None)
        if not primary or self.runtime_hash(self.factory) != primary.get('codeHash', '').lower(): raise sponsor.Pause('factory_catalog_auth_failed')
        genesis = self.rpc.call('eth_getBlockByNumber', ['0x0', False])
        namespace = json.dumps({'chain': CHAIN_ID, 'genesis': genesis['hash'], 'factory': self.factory, 'entryPoint': self.entry_point, 'executionFactory': self.execution_factory, 'operator': self.sender, 'bundler': self.a.bundler_url}, sort_keys=True)
        old = self.db.value('namespace')
        if old and old != namespace: raise sponsor.Pause('state_namespace_mismatch')
        self.db.set('namespace', namespace)
        self.status.base.update(factory=self.factory, genesisHash=genesis['hash'])

    def bundler_rpc(self, method, params):
        try:
            request = urllib.request.Request(self.a.bundler_url, json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(), {'Content-Type':'application/json'})
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=10) as response: reply = json.load(response)
        except Exception as exc: raise sponsor.RpcTransportError('bundler_unavailable') from exc
        if reply.get('error'): raise sponsor.RpcTransportError('bundler_rejected')
        return reply['result']

    def reconcile(self):
        if self.db.value('halt'): raise sponsor.Pause(self.db.value('halt'))
        for account, nonce, op_hash in self.db.pending():
            if not op_hash:
                self.db.set('halt', 'unknown_intent_pause'); raise sponsor.Pause('unknown_intent_pause')
            receipt = self.bundler_rpc('eth_getUserOperationReceipt', [op_hash])
            if not receipt: raise sponsor.Pause('pending_receipt_pause')
            outer = receipt.get('receipt') or {}
            canonical = self.rpc.call('eth_getBlockByNumber', [outer.get('blockNumber'), False])
            if not canonical or canonical['hash'].lower() != outer.get('blockHash', '').lower():
                self.db.set('halt', 'receipt_reorg_pause'); raise sponsor.Pause('receipt_reorg_pause')
            self.db.settled(nonce, outer['blockNumber'], outer['blockHash'])

    def account_info(self, account, tag):
        raw = self.call(account, 'policy()', tag)[2:]
        words = [sponsor.integer('0x' + raw[i:i+64]) for i in range(0, len(raw), 64)]
        if len(words) != 5: raise sponsor.Pause('execution_policy_invalid')
        return {'owner': self.addr(account, 'owner()', tag), 'executor': self.addr(account, 'executor()', tag), 'escrow': self.addr(account, 'escrow()', tag), 'requestId': self.uint(account, 'requestId()', tag), 'entryPoint': self.addr(account, 'entryPoint()', tag), 'attempts': self.uint(account, 'attempts()', tag), 'paused': bool(self.uint(account, 'paused()', tag)), 'epoch': self.uint(account, 'policyEpoch()', tag), 'budget': self.uint(account, 'getBudget()', tag), 'maxFee': words[0], 'maxAttempt': words[1], 'maxAttempts': words[2], 'validUntil': words[3], 'minFill': words[4]}

    def request_item(self, vault, escrow, rid, tag):
        raw = self.call(escrow, 'getRequest(uint256)', tag, rid)[2:]; words = [raw[i:i+64] for i in range(0, len(raw), 64)]
        if len(words) != 10: return None
        return {'vault':vault, 'escrow':escrow, 'requestId':str(rid), 'owner':sponsor.address(words[0]), 'version':'0x'+words[1], 'sequence':str(sponsor.integer('0x'+words[2])), 'closed':sponsor.integer('0x'+words[3]), 'available':sponsor.integer('0x'+words[5])}

    def report(self, item, state, reason):
        item.update(state=state, reason=reason, updatedAt=sponsor.now_ms()); self.status.request(item)

    def original_action(self, item, tag, block, info):
        rid, sequence, escrow, vault = int(item['requestId']), int(item['sequence']), item['escrow'], item['vault']
        assets = self.call(escrow, 'requestAssets(uint256)', tag, rid)[2:]; count = sponsor.integer('0x'+assets[64:128])
        if not 1 <= count <= 5 or len(assets) != (count + 2)*64: raise sponsor.Pause('request_basket_invalid_pause')
        tokens = [sponsor.address(assets[128+i*64:192+i*64]) for i in range(count)]
        positions = [self.uint(escrow, 'positions(uint256,address)', tag, rid, token) for token in tokens]
        try: preview = sponsor.integer(self.call(vault, 'previewInvestment(uint256[])', tag, '[' + ','.join(map(str, positions)) + ']')[:66])
        except sponsor.RpcExecutionError: preview = 0
        if preview:
            data = sponsor.calldata('integrate(uint256,uint256)', rid, sequence); wrapped = sponsor.calldata('executeIntegrate(uint256)', sequence)
        else:
            limits = [self.uint(escrow, 'maxFillAmount(uint256,uint256)', tag, rid, i) for i in range(count)] if item['available'] else []
            permitted = max(limits, default=0); amount = min(permitted, item['available'], self.a.max_fill)
            if not amount: return None
            # A final permitted dust leg is explicitly allowed by the account; otherwise
            # the personal minimum prevents executable-but-useless fragmentation.
            if amount < info['minFill'] and amount != permitted: return 'min_fill'
            index = limits.index(permitted); deadline = sponsor.integer(block['timestamp']) + 300
            data = sponsor.calldata('fill(uint256,uint256,uint256,uint256,uint256)', rid, index, amount, sequence, deadline)
            wrapped = sponsor.calldata('executeFill(uint256,uint256,uint256,uint256)', index, amount, sequence, deadline)
        # The original escrow call is the free preflight.  No signature or local
        # intent exists before both call and estimate succeed.
        self.rpc.call('eth_call', [{'from':info['executor'], 'to':escrow, 'data':data}, tag])
        self.rpc.call('eth_estimateGas', [{'from':info['executor'], 'to':escrow, 'data':data}])
        return wrapped

    def submit(self, item, info, wrapped, tag):
        live = sponsor.integer(self.rpc.call('eth_gasPrice', [])); fee = min(live, info['maxFee'])
        units = VERIFY_GAS + CALL_GAS + PRE_GAS
        if fee == 0 or units * fee > info['maxAttempt'] or info['budget'] < units * fee: raise sponsor.Pause('execution_budget_insufficient')
        nonce = self.uint(self.entry_point, 'getNonce(address,uint192)', tag, info['account'], info['epoch'])
        op = {'sender': info['account'], 'nonce': bundler.quantity(nonce), 'initCode':'0x', 'callData':wrapped, 'accountGasLimits':'0x'+(VERIFY_GAS.to_bytes(16,'big')+CALL_GAS.to_bytes(16,'big')).hex(), 'preVerificationGas':bundler.quantity(PRE_GAS), 'gasFees':'0x'+(fee.to_bytes(16,'big')+fee.to_bytes(16,'big')).hex(), 'paymasterAndData':'0x', 'signature':'0x'}
        hash_data = bundler.get_user_op_hash_data(op); op_hash = bundler.norm_hex(self.rpc.call('eth_call', [{'to':self.entry_point,'data':hash_data}, tag]), 32)
        signature = bundler.norm_hex(self.rpc.call('eth_sign', [self.sender, op_hash]))
        op['signature'] = signature; body = json.dumps(op, sort_keys=True, separators=(',', ':'))
        self.db.intent(info['account'], nonce, body)
        try: result = self.bundler_rpc('eth_sendUserOperation', [op, self.entry_point])
        except Exception as exc:
            self.db.set('halt', 'unknown_intent_pause'); raise sponsor.Pause('unknown_intent_pause') from exc
        if bundler.norm_hex(result, 32) != op_hash:
            self.db.set('halt', 'userop_hash_mismatch_pause'); raise sponsor.Pause('userop_hash_mismatch_pause')
        self.db.sent(nonce, op_hash); return op_hash

    def try_request(self, vault, escrow, rid, tag, block):
        item = self.request_item(vault, escrow, rid, tag)
        if not item: return False
        if item['closed']:
            self.report(item, 'closed', None); return False
        account = self.addr(self.execution_factory, 'accounts(address,uint256)', tag, escrow, rid)
        if account == '0x'+'0'*40:
            self.report(item, 'waiting_operator', 'execution_budget_required'); return False
        item['account'] = account
        try: info = self.account_info(account, tag); info['account'] = account
        except Exception:
            self.report(item, 'waiting_operator', 'execution_budget_required'); return False
        if info['executor'] != self.sender or info['owner'] != item['owner'] or info['escrow'] != escrow or info['requestId'] != rid or info['entryPoint'] != self.entry_point:
            self.report(item, 'waiting_operator', 'execution_budget_required'); return False
        if info['paused']: self.report(item, 'waiting_operator', 'execution_account_paused'); return False
        if info['attempts'] >= info['maxAttempts']: self.report(item, 'waiting_operator', 'execution_attempt_limit'); return False
        if sponsor.integer(block['timestamp']) >= info['validUntil']: self.report(item, 'waiting_operator', 'execution_authorization_expired'); return False
        if info['budget'] < min(info['maxAttempt'], (VERIFY_GAS+CALL_GAS+PRE_GAS)*info['maxFee']): self.report(item, 'waiting_operator', 'execution_budget_insufficient'); return False
        try: wrapped = self.original_action(item, tag, block, info)
        except sponsor.RpcExecutionError:
            self.report(item, 'waiting_market', 'onchain_execution_rejected'); return False
        if wrapped is None: self.report(item, 'no_admissible_action', 'no_admissible_action'); return False
        if wrapped == 'min_fill': self.report(item, 'waiting_operator', 'execution_budget_required'); return False
        canonical = self.rpc.call('eth_getBlockByNumber', [tag, False])
        if not canonical or canonical['hash'].lower() != block['hash'].lower(): raise sponsor.Pause('snapshot_reorg_pause')
        item['lastUserOpHash'] = self.submit(item, info, wrapped, tag); self.report(item, 'executing', None); return True

    def cycle(self):
        self.reconcile(); block = self.rpc.call('eth_getBlockByNumber', ['latest', False]); tag = block['number']
        self.status.base['observedAt'] = {'blockNumber':str(sponsor.integer(tag)), 'blockHash':block['hash'], 'timestamp':sponsor.integer(block['timestamp'])}
        count = self.uint(self.factory, 'vaultCount()', tag)
        registry, settlement = self.addr(self.factory, 'registry()', tag), self.addr(self.factory, 'settlementAsset()', tag)
        for step in range(min(count, 16)):
            index = (self.cursor_vault + step) % count; vault = self.addr(self.factory, 'vaults(uint256)', tag, index)
            if not self.uint(self.factory, 'isVault(address)', tag, vault) or self.uint(vault, 'protocolVersion()', tag) != 2: continue
            if self.addr(vault, 'registry()', tag) != registry or self.addr(vault, 'settlementAsset()', tag) != settlement: continue
            escrow = self.addr(vault, 'investmentEscrow()', tag)
            if self.addr(escrow, 'vault()', tag) != vault or self.uint(escrow, 'protocolVersion()', tag) != 2: continue
            total = self.uint(escrow, 'nextRequestId()', tag) - 1; start = self.cursor_request.get(escrow, 1)
            for offset in range(min(total, 64)):
                rid = (start-1+offset) % max(total,1)+1; self.cursor_vault=(index+1)%count; self.cursor_request[escrow]=rid%max(total,1)+1
                self.db.set('cursor_vault', self.cursor_vault); self.db.set('cursor_request', json.dumps(self.cursor_request))
                if self.try_request(vault, escrow, rid, tag, block): return

    def run(self):
        server = sponsor.start_http(self.status, self.a.status_port)
        try:
            while not self.stop.is_set():
                try:
                    self.authenticate(); self.cycle(); self.status.base['operator'].update(state='running', reason=None, spentWei='0', reservedWei='0', budgetWei='0'); self.status.base['heartbeatAt']=sponsor.now_ms()
                except sponsor.Pause as exc: self.status.base['operator'].update(state='paused', reason=str(exc), spentWei='0', reservedWei='0', budgetWei='0')
                except Exception: self.status.base['operator'].update(state='paused', reason='operator_unavailable', spentWei='0', reservedWei='0', budgetWei='0')
                self.status.publish(); self.stop.wait(self.a.interval)
        finally: server.shutdown(); server.server_close(); self.db.close()


def main():
    p=argparse.ArgumentParser(description=__doc__); p.add_argument('--rpc-url',required=True); p.add_argument('--sender',required=True); p.add_argument('--state-db',required=True); p.add_argument('--status-port',type=int,required=True); p.add_argument('--bundler-url',required=True); p.add_argument('--max-fill',type=int,required=True); p.add_argument('--interval',type=float,default=.5); p.add_argument('--addresses',default='deployments/31337/addresses.json'); p.add_argument('--manifest',default='deployments/manifest.json'); p.add_argument('--once',action='store_true')
    a=p.parse_args()
    if a.max_fill <= 0 or not 1 <= a.status_port <= 65535 or a.interval <= 0: p.error('unsafe bounds')
    daemon=Executor(a)
    if a.once:
        try: daemon.authenticate(); daemon.cycle(); daemon.status.publish()
        finally: daemon.db.close()
    else: daemon.run()

if __name__ == '__main__': main()
