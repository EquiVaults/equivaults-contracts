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
PLANNER_PROBES = 20
BPS_DENOMINATOR = 10_000


class ExecutionStore:
    """Separate account+nonce ledger; an unresolved signed operation is a stop."""
    def __init__(self, path):
        self.path = Path(path); self.path.parent.mkdir(parents=True, exist_ok=True)
        self.lock = open(str(self.path) + '.lock', 'a+')
        try: fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.lock.close(); raise RuntimeError('state_db_locked')
        self.guard = threading.RLock()
        self.db = sqlite3.connect(self.path, check_same_thread=False); self.db.execute('pragma journal_mode=WAL'); self.db.execute('pragma synchronous=FULL')
        self.db.executescript('create table if not exists meta(k text primary key,v text); create table if not exists ops(account text,nonce text,hash text,body text,state text,block text,blockhash text, unique(account,nonce));')
        self.db.commit()
    def value(self, key):
        with self.guard:
            row = self.db.execute('select v from meta where k=?', (key,)).fetchone(); return row[0] if row else None
    def set(self, key, value):
        with self.guard: self.db.execute('insert into meta values(?,?) on conflict(k) do update set v=excluded.v', (key, str(value))); self.db.commit()
    def tracked(self):
        with self.guard: return self.db.execute("select account,nonce,hash,state from ops where state in ('intent','sent','mined')").fetchall()
    def pending(self):
        """Compatibility view used by diagnostics; includes only unresolved intents."""
        with self.guard: return self.db.execute("select account,nonce,hash from ops where state in ('intent','sent')").fetchall()
    def intent(self, account, nonce, body):
        with self.guard: self.db.execute('insert into ops values(?,?,?,?,?,?,?)', (account, str(nonce), None, body, 'intent', None, None)); self.db.commit()
    def sent(self, account, nonce, op_hash):
        with self.guard: self.db.execute('update ops set hash=?,state=? where account=? and nonce=?', (op_hash, 'sent', account, str(nonce))); self.db.commit()
    def settled(self, account, nonce, block, blockhash):
        with self.guard: self.db.execute('update ops set state=?,block=?,blockhash=? where account=? and nonce=?', ('mined', block, blockhash, account, str(nonce))); self.db.commit()
    def close(self):
        with self.guard: self.db.close()
        fcntl.flock(self.lock, fcntl.LOCK_UN); self.lock.close()


class Executor:
    def __init__(self, args):
        self.a = args; self.rpc = sponsor.Rpc(args.rpc_url); self.db = ExecutionStore(args.state_db)
        self.status = sponsor.Status(0, args.sender); self.status.base['funding'] = 'investor'
        self.stop = threading.Event(); self.cursor_vault = int(self.db.value('cursor_vault') or 0); self.cursor_request = json.loads(self.db.value('cursor_request') or '{}')
        catalog = json.loads(Path(args.addresses).read_text()); self.catalog = catalog; self.manifest = json.loads(Path(args.manifest).read_text())
        ex = catalog.get('execution') or {}; self.entry_point = bundler.norm_address(ex.get('entryPoint')); self.execution_factory = bundler.norm_address(ex.get('factory'))
        self.entry_hash = bundler.norm_hex(ex.get('entryPointCodeHash'), 32); self.execution_hash = bundler.norm_hex(ex.get('factoryCodeHash'), 32)
        self.factory = bundler.norm_address(catalog['factory']); self.sender = bundler.norm_address(args.sender)
        self.bundler_sender = bundler.norm_address(args.bundler_sender); self.catalog_executor = bundler.norm_address(ex.get('executor'))

    def runtime_hash(self, value): return sponsor.hash_code(self.rpc.call('eth_getCode', [value, 'latest']))
    def call(self, target, signature, block, *values): return self.rpc.read(target, sponsor.calldata(signature, *values), block)
    def uint(self, target, signature, block, *values): return sponsor.integer(self.call(target, signature, block, *values)[:66])
    def addr(self, target, signature, block, *values): return sponsor.address(self.call(target, signature, block, *values))

    def authenticate(self):
        parsed = urllib.parse.urlparse(self.a.bundler_url)
        if parsed.scheme != 'http' or parsed.hostname not in ('127.0.0.1', 'localhost', '::1') or parsed.username or parsed.password: raise sponsor.Pause('bundler_not_loopback')
        if self.sender != self.catalog_executor: raise sponsor.Pause('executor_catalog_binding_failed')
        if self.sender == self.bundler_sender: raise sponsor.Pause('bundler_sender_must_differ_from_executor')
        if sponsor.integer(self.rpc.call('eth_chainId', [])) != CHAIN_ID or 'anvil' not in self.rpc.call('web3_clientVersion', []).lower(): raise sponsor.Pause('anvil_31337_required')
        if self.sender not in [x.lower() for x in self.rpc.call('eth_accounts', [])]: raise sponsor.Pause('sender_not_unlocked')
        if self.runtime_hash(self.entry_point) != self.entry_hash or self.runtime_hash(self.execution_factory) != self.execution_hash: raise sponsor.Pause('execution_runtime_mismatch')
        if self.addr(self.execution_factory, 'entryPoint()', 'latest') != self.entry_point or self.addr(self.execution_factory, 'vaultFactory()', 'latest') != self.factory: raise sponsor.Pause('execution_factory_binding_failed')
        primary = next((x for x in self.catalog.get('factories', []) if x.get('address', '').lower() == self.factory), None)
        if not primary or primary.get('contractsCommit') != self.manifest.get('contractsCommit') or self.runtime_hash(self.factory) != primary.get('codeHash', '').lower(): raise sponsor.Pause('factory_catalog_auth_failed')
        genesis = self.rpc.call('eth_getBlockByNumber', ['0x0', False])
        deployment = self.deployment_anchor()
        expected = {'chainId': CHAIN_ID, 'genesisHash': genesis['hash'], 'entryPoint': self.entry_point,
                    'factory': self.execution_factory, 'entryPointCodeHash': self.entry_hash,
                    'factoryCodeHash': self.execution_hash, 'executor': self.catalog_executor,
                    'bundlerSender': self.bundler_sender,
                    'bundler': 'http://127.0.0.1:' + str(parsed.port), **deployment}
        if self.bundler_rpc('eq_executionContext', []) != expected: raise sponsor.Pause('bundler_identity_mismatch')
        namespace = json.dumps({**expected, 'operator': self.sender, 'bundler': self.a.bundler_url}, sort_keys=True)
        old = self.db.value('namespace')
        if old and old != namespace: raise sponsor.Pause('state_namespace_mismatch')
        self.db.set('namespace', namespace)
        self.status.base.update(factory=self.factory, genesisHash=genesis['hash'], deploymentBlock=str(sponsor.integer(deployment['deploymentBlock'])), deploymentBlockHash=deployment['deploymentBlockHash'], contractsCommit=self.manifest['contractsCommit'])

    def deployment_anchor(self):
        logs = self.rpc.call('eth_getLogs', [{'address': self.factory, 'fromBlock': '0x0', 'toBlock': 'latest', 'topics': [sponsor.VAULT_CREATED]}])
        if not logs: raise sponsor.Pause('primary_entry_missing')
        first = min(logs, key=lambda log: sponsor.integer(log['blockNumber']))
        block = self.rpc.call('eth_getBlockByNumber', [first['blockNumber'], False])
        if not block: raise sponsor.Pause('deployment_anchor_missing')
        return {'deploymentBlock': first['blockNumber'], 'deploymentBlockHash': block['hash']}

    def bundler_rpc(self, method, params):
        try:
            request = urllib.request.Request(self.a.bundler_url, json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(), {'Content-Type':'application/json'})
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=10) as response: reply = json.load(response)
        except Exception as exc: raise sponsor.RpcTransportError('bundler_unavailable') from exc
        if reply.get('error'):
            reason = str(reply['error'].get('message', 'bundler_rejected')) if isinstance(reply['error'], dict) else 'bundler_rejected'
            if reason in ('receipt_reorg_pause', 'unknown_intent_pause'):
                raise sponsor.Pause(reason)
            raise sponsor.RpcTransportError('bundler_rejected')
        return reply['result']

    def reconcile(self):
        if self.db.value('halt'): raise sponsor.Pause(self.db.value('halt'))
        for account, nonce, op_hash, state in self.db.tracked():
            if not op_hash:
                self.db.set('halt', 'unknown_intent_pause'); raise sponsor.Pause('unknown_intent_pause')
            try:
                receipt = self.bundler_rpc('eth_getUserOperationReceipt', [op_hash])
            except sponsor.Pause as error:
                if str(error) == 'receipt_reorg_pause': self.db.set('halt', 'receipt_reorg_pause')
                raise
            if not receipt:
                if state == 'mined':
                    self.db.set('halt', 'receipt_reorg_pause'); raise sponsor.Pause('receipt_reorg_pause')
                raise sponsor.Pause('pending_receipt_pause')
            outer = receipt.get('receipt') or {}
            canonical = self.rpc.call('eth_getBlockByNumber', [outer.get('blockNumber'), False])
            if not canonical or canonical['hash'].lower() != outer.get('blockHash', '').lower():
                self.db.set('halt', 'receipt_reorg_pause'); raise sponsor.Pause('receipt_reorg_pause')
            self.db.settled(account, nonce, outer['blockNumber'], outer['blockHash'])

    def account_info(self, account, tag):
        raw = self.call(account, 'policy()', tag)[2:]
        words = [sponsor.integer('0x' + raw[i:i+64]) for i in range(0, len(raw), 64)]
        if len(words) != 5: raise sponsor.Pause('execution_policy_invalid')
        return {'owner': self.addr(account, 'owner()', tag), 'executor': self.addr(account, 'executor()', tag), 'escrow': self.addr(account, 'escrow()', tag), 'requestId': self.uint(account, 'requestId()', tag), 'entryPoint': self.addr(account, 'entryPoint()', tag), 'attempts': self.uint(account, 'attempts()', tag), 'paused': bool(self.uint(account, 'paused()', tag)), 'epoch': self.uint(account, 'policyEpoch()', tag), 'budget': self.uint(account, 'getBudget()', tag), 'maxFee': words[0], 'maxAttempt': words[1], 'maxAttempts': words[2], 'validUntil': words[3], 'minFill': words[4]}

    def request_item(self, vault, escrow, rid, tag):
        raw = self.call(escrow, 'getRequest(uint256)', tag, rid)[2:]; words = [raw[i:i+64] for i in range(0, len(raw), 64)]
        if len(words) != 10: return None
        return {'vault':vault, 'escrow':escrow, 'requestId':str(rid), 'owner':sponsor.address(words[0]), 'version':'0x'+words[1], 'sequence':str(sponsor.integer('0x'+words[2])), 'closed':sponsor.integer('0x'+words[3]), 'available':sponsor.integer('0x'+words[5]), 'lastTxHash':None}

    def report(self, item, state, reason):
        item.update(state=state, reason=reason, updatedAt=sponsor.now_ms()); self.status.request(item)

    def request_assets(self, escrow, rid, tag):
        """Read the bounded request basket without trusting a local asset catalogue."""
        assets = self.call(escrow, 'requestAssets(uint256)', tag, rid)[2:]
        count = sponsor.integer('0x' + assets[64:128])
        if not 1 <= count <= 5 or len(assets) != (count + 2) * 64:
            raise sponsor.Pause('request_basket_invalid_pause')
        return [sponsor.address(assets[128 + i * 64:192 + i * 64]) for i in range(count)]

    def position(self, escrow, rid, token, tag):
        raw = self.call(escrow, 'positions(uint256,address)', tag, rid, token)[2:]
        if len(raw) != 2 * 64:
            raise sponsor.Pause('request_position_invalid_pause')
        return {'quantity': sponsor.integer('0x' + raw[:64]), 'cost': sponsor.integer('0x' + raw[64:128])}

    def investment_preview(self, vault, quantities, tag):
        raw = self.call(vault, 'previewInvestment(uint256[])', tag, '[' + ','.join(map(str, quantities)) + ']')[2:]
        if len(raw) < 4 * 64:
            return None
        shares, offset, value = sponsor.integer('0x' + raw[:64]), sponsor.integer('0x' + raw[64:128]), sponsor.integer('0x' + raw[128:192])
        start = offset * 2
        if offset % 32 or start + 64 > len(raw):
            return None
        count = sponsor.integer('0x' + raw[start:start + 64]); end = start + (count + 1) * 64
        if end != len(raw):
            return None
        return {'shares': shares, 'amounts': [sponsor.integer('0x' + raw[start + 64 + i * 64:start + 128 + i * 64]) for i in range(count)], 'value': value}

    @staticmethod
    def preview_cost(positions, preview):
        if not preview or len(positions) != len(preview['amounts']):
            return None, False
        total, complete = 0, True
        for position, amount in zip(positions, preview['amounts']):
            if amount > position['quantity']:
                return None, False
            if amount != position['quantity']:
                complete = False
            if amount:
                total += position['cost'] if amount == position['quantity'] else position['cost'] * amount // position['quantity']
        return total, complete

    def pool_quote(self, registry, settlement, token, amount, tag):
        """Return a MockPool quote and curve-only impact, or None when not supported.

        The fee is removed before comparing the constant-product output with its
        marginal price.  Ceil rounding means integer arithmetic cannot understate
        the reported impact.  This deliberately does not claim to quote arbitrary
        registered routers: callers fail closed when this small observable pool
        interface is unavailable.
        """
        cache = getattr(self, '_pool_snapshots', None)
        key = (registry, settlement, token)
        snapshot = cache.get(key) if cache is not None else None
        if snapshot is None:
            raw = self.call(registry, 'assetConfig(address)', tag, token)[2:]
            if len(raw) != 6 * 64:
                return None
            route = sponsor.address(raw[128:192])
            snapshot = {'route': route,
                        'reserveIn': self.uint(route, 'reserveOf(address)', tag, settlement),
                        'reserveOut': self.uint(route, 'reserveOf(address)', tag, token),
                        'feeBps': self.uint(route, 'swapFeeBps()', tag)}
            if cache is not None:
                cache[key] = snapshot
        route, reserve_in, reserve_out, fee_bps = snapshot['route'], snapshot['reserveIn'], snapshot['reserveOut'], snapshot['feeBps']
        if not reserve_in or not reserve_out or fee_bps >= BPS_DENOMINATOR:
            return None
        net = amount * (BPS_DENOMINATOR - fee_bps) // BPS_DENOMINATOR
        if not net:
            return None
        out = reserve_out - reserve_in * reserve_out // (reserve_in + net)
        marginal_numerator = net * reserve_out
        if not out or not marginal_numerator:
            return None
        # Keep the marginal output as an exact rational value. Flooring it before
        # comparison can hide all impact for low-decimal assets.
        impact_numerator = max(marginal_numerator - out * reserve_in, 0) * BPS_DENOMINATOR
        impact = (impact_numerator + marginal_numerator - 1) // marginal_numerator
        return {'amount': amount, 'out': out, 'impactBps': impact, 'route': route}

    @staticmethod
    def _useful_amount(amount, permitted, min_fill):
        # The policy permits its final dust leg, but an adaptive cap must not turn
        # a normally useful leg into a below-minimum fragment.
        return amount > 0 and (amount >= min_fill or amount == permitted)

    def adaptive_cap(self, registry, settlement, token, cap, permitted, min_fill, tag):
        """Largest pool-model candidate within the personal impact limit.

        The search uses at most PLANNER_PROBES model evaluations.  It is a local
        sizing aid only; every returned amount still receives the escrow's pinned
        eth_call and eth_estimateGas checks below.
        """
        maximum = self.pool_quote(registry, settlement, token, cap, tag)
        if maximum is None:
            return None, 'price_impact_unavailable'
        if maximum['impactBps'] <= self.a.max_price_impact_bps and self._useful_amount(cap, permitted, min_fill):
            return maximum, None
        low, high, best = 1, cap, None
        for _ in range(PLANNER_PROBES - 1):
            if low > high:
                break
            amount = (low + high) // 2
            quote = self.pool_quote(registry, settlement, token, amount, tag)
            if quote is None:
                return None, 'price_impact_unavailable'
            if quote['impactBps'] <= self.a.max_price_impact_bps:
                if self._useful_amount(amount, permitted, min_fill):
                    best = quote
                low = amount + 1
            else:
                high = amount - 1
        return (best, None) if best else (None, 'price_impact_exceeded')

    def cap_for_output(self, registry, settlement, token, plan, desired_out, min_fill, tag):
        """Largest useful input whose modelled output does not overshoot a tranche."""
        if desired_out <= 0:
            return None
        if plan['out'] <= desired_out:
            return plan
        low, high, best = 1, plan['amount'], None
        for _ in range(PLANNER_PROBES):
            if low > high:
                break
            amount = (low + high) // 2
            quote = self.pool_quote(registry, settlement, token, amount, tag)
            if quote is None:
                return None
            if quote['out'] <= desired_out:
                if self._useful_amount(amount, plan['permitted'], min_fill):
                    best = {**plan, **quote}
                low = amount + 1
            else:
                high = amount - 1
        return best

    def preflight_fill(self, escrow, rid, index, amount, sequence, deadline, executor, tag):
        data = sponsor.calldata('fill(uint256,uint256,uint256,uint256,uint256)', rid, index, amount, sequence, deadline)
        result = self.rpc.call('eth_call', [{'from': executor, 'to': escrow, 'data': data}, tag])
        return data, sponsor.integer(result[:66]) if result and result != '0x' else 0

    def best_fill(self, item, vault, tokens, positions, limits, tag, block, info):
        """Plan and preflight the largest useful leg without consuming an attempt."""
        # Snapshot only the route data consulted by this one pinned planning pass.
        # A new action obtains a fresh map, so no reserve/fee observation crosses
        # blocks or canonical revalidation.
        self._pool_snapshots = {}
        registry = self.addr(self.factory, 'registry()', tag)
        settlement = self.addr(self.factory, 'settlementAsset()', tag)
        deadline = sponsor.integer(block['timestamp']) + 300
        plans = []
        unavailable = False
        for index, (token, permitted) in enumerate(zip(tokens, limits)):
            cap = min(permitted, item['available'], self.a.max_fill)
            if not self._useful_amount(cap, permitted, info['minFill']):
                continue
            try:
                quote, reason = self.adaptive_cap(registry, settlement, token, cap, permitted, info['minFill'], tag)
            except sponsor.RpcExecutionError:
                unavailable = True
                continue
            if quote is None:
                unavailable = unavailable or reason == 'price_impact_unavailable'
                continue
            plans.append({'index': index, 'permitted': permitted, **quote})

        # Size both legs against one prospective proportional tranche. This avoids
        # spending each independent protocol maximum only to strand the token that
        # overshoots its basket ratio after the later integrate.
        if plans:
            prospective = [position['quantity'] for position in positions]
            for plan in plans:
                prospective[plan['index']] += plan['out']
            try:
                tranche = self.investment_preview(vault, prospective, tag)
            except sponsor.RpcExecutionError:
                tranche = None
            if tranche and len(tranche['amounts']) == len(positions):
                matched = []
                for plan in plans:
                    desired = max(tranche['amounts'][plan['index']] - positions[plan['index']]['quantity'], 0)
                    reduced = self.cap_for_output(registry, settlement, tokens[plan['index']], plan, desired, info['minFill'], tag)
                    if reduced:
                        matched.append(reduced)
                plans = matched

        # One failed market leg is not evidence that another leg lacks liquidity.
        # Try the largest modelled legs first, reducing only that leg after an EVM
        # rejection; transport errors deliberately escape as uncertainty.
        for plan in sorted(plans, key=lambda candidate: candidate['amount'], reverse=True):
            high, amount, probes, accepted = plan['amount'], plan['amount'], 0, None
            while probes < PLANNER_PROBES and self._useful_amount(amount, plan['permitted'], info['minFill']):
                try:
                    data, actual_out = self.preflight_fill(item['escrow'], int(item['requestId']), plan['index'], amount,
                                                            int(item['sequence']), deadline, info['executor'], tag)
                except sponsor.RpcExecutionError:
                    # A rejected quote is free. Keep the next probe within the
                    # useful interval: halving below its floor would skip valid
                    # quotes between minFill and this rejected candidate.
                    high = amount - 1
                    if high < info['minFill']:
                        break
                    amount = max(info['minFill'], high // 2)
                    probes += 1
                    continue
                probes += 1
                quote = self.pool_quote(registry, settlement, tokens[plan['index']], amount, tag)
                # `reserveOf`/`swapFeeBps` is an allowed optimisation only when it
                # predicts the pinned escrow call exactly. A router with merely
                # similarly named getters is treated as unsupported.
                if quote is None or quote['out'] != actual_out or quote['impactBps'] > self.a.max_price_impact_bps:
                    unavailable = True
                    break
                accepted = (amount, data, actual_out, quote)
                break
            if accepted:
                # The failed half above and this successful lower point bound a
                # monotonic on-chain limit. Binary search that interval, still
                # capped across all preflights for this leg.
                low = accepted[0] + 1
                while probes < PLANNER_PROBES and low <= high:
                    mid = (low + high) // 2
                    if not self._useful_amount(mid, plan['permitted'], info['minFill']):
                        low = mid + 1
                        continue
                    try:
                        data, actual_out = self.preflight_fill(item['escrow'], int(item['requestId']), plan['index'], mid,
                                                                int(item['sequence']), deadline, info['executor'], tag)
                    except sponsor.RpcExecutionError:
                        high = mid - 1; probes += 1
                        continue
                    quote = self.pool_quote(registry, settlement, tokens[plan['index']], mid, tag)
                    if quote is None or quote['out'] != actual_out or quote['impactBps'] > self.a.max_price_impact_bps:
                        unavailable = True
                        break
                    accepted = (mid, data, actual_out, quote)
                    low = mid + 1; probes += 1
                amount, data, actual_out, quote = accepted
                item['planning'] = {'action': 'fill', 'index': plan['index'], 'amount': str(amount),
                                    'out': str(actual_out), 'impactBps': quote['impactBps']}
                return sponsor.calldata('executeFill(uint256,uint256,uint256,uint256)', plan['index'], amount,
                                        int(item['sequence']), deadline), data
            # The next plan may be a smaller but independently viable leg.
        item['planning'] = {'action': 'none', 'reason': 'price_impact_unavailable' if unavailable else 'no_useful_fill'}
        return None, None

    def original_action(self, item, tag, block, info):
        rid, sequence, escrow, vault = int(item['requestId']), int(item['sequence']), item['escrow'], item['vault']
        tokens = self.request_assets(escrow, rid, tag); count = len(tokens)
        positions = [self.position(escrow, rid, token, tag) for token in tokens]
        try: preview = self.investment_preview(vault, [position['quantity'] for position in positions], tag)
        except sponsor.RpcExecutionError: preview = None
        preview_cost, complete = self.preview_cost(positions, preview)
        can_integrate = preview and preview['shares'] and preview_cost is not None and (preview_cost >= info['minFill'] or complete)
        remaining = info['maxAttempts'] - info['attempts']
        pending_cost = item['available'] + sum(position['cost'] for position in positions)
        # `best_fill` sizes a coherent basket tranche. Once that tranche meets the
        # account progress floor, integrate it before a residual cash fill can
        # disturb the ratio or strand another personal token remainder.
        if can_integrate:
            data = sponsor.calldata('integrate(uint256,uint256)', rid, sequence); wrapped = sponsor.calldata('executeIntegrate(uint256)', sequence)
            item['planning'] = {'action': 'integrate', 'amount': str(preview_cost), 'out': str(preview['shares']), 'impactBps': 0}
        else:
            if remaining <= 1:
                item['planning'] = {'action': 'none', 'reason': 'reserve_integration_attempt'}
                return None
            if item['available'] < info['minFill'] and pending_cost < info['minFill']:
                # This is recoverable settlement plus positions below the account's
                # progress floor. Do not burn a UserOperation trying to manufacture
                # an unintegrable dust tranche; the owner can stop/claim it.
                item['planning'] = {'action': 'none', 'reason': 'remaining_below_minimum',
                                    'amount': str(pending_cost), 'out': '0', 'impactBps': 0}
                return None
            limits = []
            for index in (range(count) if item['available'] else ()):
                try:
                    limits.append(self.uint(escrow, 'maxFillAmount(uint256,uint256)', tag, rid, index))
                except sponsor.RpcExecutionError:
                    # A stale oracle or closed exposure on one leg does not make a
                    # separately admissible leg illiquid. Transport failures still
                    # escape and pause rather than being classified as liquidity.
                    limits.append(0)
            if not any(limits):
                if can_integrate:
                    data = sponsor.calldata('integrate(uint256,uint256)', rid, sequence); wrapped = sponsor.calldata('executeIntegrate(uint256)', sequence)
                    item['planning'] = {'action': 'integrate', 'amount': str(preview_cost), 'out': str(preview['shares']), 'impactBps': 0}
                else:
                    return None
            else:
                wrapped, data = self.best_fill(item, vault, tokens, positions, limits, tag, block, info)
                if wrapped is None:
                    # Integrating a viable accumulated tranche is safer than waiting
                    # forever on a new fill that cannot meet its impact ceiling.
                    if can_integrate:
                        data = sponsor.calldata('integrate(uint256,uint256)', rid, sequence); wrapped = sponsor.calldata('executeIntegrate(uint256)', sequence)
                        item['planning'] = {'action': 'integrate', 'amount': str(preview_cost), 'out': str(preview['shares']), 'impactBps': 0}
                    else:
                        return None
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
        self.db.sent(info['account'], nonce, op_hash); return op_hash

    def try_request(self, vault, escrow, rid, tag, block):
        item = self.request_item(vault, escrow, rid, tag)
        if not item: return False
        if item['closed']:
            self.report(item, 'stopped' if item['closed'] == 1 else 'closed', None); return False
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
        if wrapped is None: self.report(item, 'no_admissible_action', item.get('planning', {}).get('reason', 'no_admissible_action')); return False
        if wrapped == 'min_fill': self.report(item, 'waiting_operator', 'execution_budget_required'); return False
        canonical = self.rpc.call('eth_getBlockByNumber', [tag, False])
        if not canonical or canonical['hash'].lower() != block['hash'].lower(): raise sponsor.Pause('snapshot_reorg_pause')
        self.submit(item, info, wrapped, tag); self.report(item, 'executing', None); return True

    def cycle(self):
        self.reconcile(); block = self.rpc.call('eth_getBlockByNumber', ['latest', False]); tag = block['number']
        self.status.base['observedAt'] = {'blockNumber':str(sponsor.integer(tag)), 'blockHash':block['hash'], 'timestamp':sponsor.integer(block['timestamp'])}
        count = self.uint(self.factory, 'vaultCount()', tag)
        registry, settlement = self.addr(self.factory, 'registry()', tag), self.addr(self.factory, 'settlementAsset()', tag)
        start_vault = self.cursor_vault
        for step in range(min(count, 16)):
            index = (start_vault + step) % count
            self.cursor_vault = (index + 1) % count
            self.db.set('cursor_vault', self.cursor_vault)
            vault = self.addr(self.factory, 'vaults(uint256)', tag, index)
            if not self.uint(self.factory, 'isVault(address)', tag, vault) or self.uint(vault, 'protocolVersion()', tag) != 2: continue
            if self.addr(vault, 'registry()', tag) != registry or self.addr(vault, 'settlementAsset()', tag) != settlement: continue
            escrow = self.addr(vault, 'investmentEscrow()', tag)
            if self.addr(escrow, 'vault()', tag) != vault or self.uint(escrow, 'protocolVersion()', tag) != 2: continue
            total = self.uint(escrow, 'nextRequestId()', tag) - 1; start = self.cursor_request.get(escrow, 1)
            for offset in range(min(total, 64)):
                rid = (start-1+offset) % max(total,1)+1; self.cursor_request[escrow]=rid%max(total,1)+1
                self.db.set('cursor_request', json.dumps(self.cursor_request))
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
    p=argparse.ArgumentParser(description=__doc__); p.add_argument('--rpc-url',required=True); p.add_argument('--sender',required=True); p.add_argument('--state-db',required=True); p.add_argument('--status-port',type=int,required=True); p.add_argument('--bundler-url',required=True); p.add_argument('--bundler-sender',default='0x14dC79964da2C08b23698b3D3cc7Ca32193d9955'); p.add_argument('--max-fill',type=int,required=True); p.add_argument('--max-price-impact-bps',type=int,default=50); p.add_argument('--interval',type=float,default=.5); p.add_argument('--addresses',default='deployments/31337/addresses.json'); p.add_argument('--manifest',default='deployments/manifest.json'); p.add_argument('--once',action='store_true')
    a=p.parse_args()
    if a.max_fill <= 0 or not 0 <= a.max_price_impact_bps <= BPS_DENOMINATOR or not 1 <= a.status_port <= 65535 or a.interval <= 0: p.error('unsafe bounds')
    daemon=Executor(a)
    if a.once:
        try: daemon.authenticate(); daemon.cycle(); daemon.status.publish()
        finally: daemon.db.close()
    else: daemon.run()

if __name__ == '__main__': main()
