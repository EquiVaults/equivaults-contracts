"""Observed, deployment-scoped performance for the local simulation laboratory.

Amounts are integers in settlement atomic units. Oracle NAV is not a liquidation
quote. Personal profit excludes native gas and values in-kind recoveries at the
block of recovery; subsequent wallet-token performance is outside this scope.
"""
import calendar
import datetime as dt
import functools
import json
import sqlite3
import subprocess
import threading
from pathlib import Path

E18 = 10**18
ZERO = '0x' + '0' * 40
MAX_ASSET_HISTORY = 1024
MAX_ASSET_HISTORY_DAYS = 366
MAX_RECENT_ASSET_SAMPLES = 128
ASSET_CURSOR = 'asset-observations'
EVENTS = {
    'entered': 'Entered(address,address,uint256,uint256,uint256)',
    'integrated': 'InvestmentIntegrated(address,address,uint256,uint256,uint256,uint256,uint256)',
    'exited': 'Exited(address,address,uint256,uint256,uint256)',
    'created': 'RequestCreated(uint256,address,bytes32,uint256,address[])',
    'claimed': 'PositionClaimed(uint256,address,address,uint256,uint256)',
}


class CanonicalHistoryError(ValueError):
    """The controller must halt mutations until matching history is restored."""


@functools.lru_cache(maxsize=128)
def keccak(text):
    return subprocess.check_output(['cast', 'keccak', text], text=True, timeout=15).strip().lower()


def words(data):
    if not isinstance(data, str) or not data.startswith('0x') or (len(data)-2) % 64:
        raise ValueError('Malformed ABI response')
    return [int(data[i:i+64], 16) for i in range(2, len(data), 64)]


def address(value):
    return '0x' + hex(value)[2:].zfill(40)[-40:]


def argument(value):
    return (value[2:] if isinstance(value, str) else hex(value)[2:]).zfill(64)


def period_start(period, timestamp):
    now = dt.datetime.fromtimestamp(timestamp, dt.timezone.utc)
    if period == 'ALL':
        return None
    if period == 'YTD':
        return int(dt.datetime(now.year, 1, 1, tzinfo=dt.timezone.utc).timestamp())
    if period in ('1D', '7D'):
        return timestamp - (86400 if period == '1D' else 7*86400)
    if period == '1M':
        year, month = (now.year-1, 12) if now.month == 1 else (now.year, now.month-1)
    elif period == '1Y':
        year, month = now.year-1, now.month
    else:
        raise ValueError('Unknown period')
    return int(now.replace(year=year, month=month, day=min(now.day, calendar.monthrange(year, month)[1])).timestamp())


def returns(history, now):
    """No interpolation, annualization, or partial-period substitution."""
    result = {}
    for period in ('1D', '7D', '1M', 'YTD', '1Y', 'ALL'):
        start = period_start(period, now)
        eligible = [p for p in history if int(p['nav']) > 0] if start is None else [p for p in history if p['timestamp'] <= start]
        baseline = (eligible[0] if start is None else eligible[-1]) if eligible else None
        reason = None
        selected = [p for p in history if baseline and p['timestamp'] >= baseline['timestamp']]
        if not baseline or not history or int(baseline['nav']) <= 0:
            reason = 'Insufficient observed history'
        elif any(int(p['nav']) <= 0 for p in selected):
            reason = 'Vault was empty during this period; share history is discontinuous'
        elif start is not None and start-baseline['timestamp'] > 86400:
            reason = 'No observation near period boundary'
        elif any(b['timestamp']-a['timestamp'] > 2*86400 for a, b in zip(selected, selected[1:])):
            reason = 'Observation gap; market path was not recorded'
        elif now-history[-1]['timestamp'] > 86400:
            reason = 'Latest observation is stale'
        bps = None if reason else (int(history[-1]['nav'])-int(baseline['nav']))*10000//int(baseline['nav'])
        result[period] = {'returnBps': bps, 'reason': reason, 'from': baseline['timestamp'] if baseline else None, 'to': now}
    return result


class Ledger:
    """Reconstruct the exact non-transferable share cost allocation."""
    def __init__(self):
        self.accounts = {}

    def account(self, owner):
        return self.accounts.setdefault(owner.lower(), {'shares': 0, 'cost': 0, 'invested': 0, 'realized': 0})

    def apply(self, kind, owner, data, out_value=None):
        row = self.account(owner)
        if kind in ('entered', 'integrated'):
            row['shares'] += data[2]
            row['cost'] += data[0]
            if kind == 'entered':
                row['invested'] += data[0]
        elif kind == 'created':
            row['invested'] += data[0]
        elif kind == 'exited':
            if not row['shares'] or data[0] > row['shares'] or out_value is None:
                raise ValueError('Incomplete exit history')
            cost = row['cost'] * data[0] // row['shares']
            row['shares'] -= data[0]
            row['cost'] -= cost
            row['realized'] += out_value-cost
        elif kind == 'claimed':
            if out_value is None:
                raise ValueError('Recovery valuation unavailable')
            row['realized'] += out_value-data[1]


class Metrics:
    def __init__(self, demo, path, fixture=None):
        self.demo = demo
        self.fixture = fixture or {}
        self.lock = threading.RLock()
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.execute('pragma journal_mode=WAL')
        self.db.executescript('''create table if not exists meta(k text primary key,v text);
        create table if not exists observations(vault text,block integer,hash text,ts integer,nav text,assets text,primary key(vault,block));
        create table if not exists asset_observations(asset text,block integer,hash text,ts integer,oracle text,dex text,primary key(asset,block));
        create index if not exists asset_observations_asset_ts_block on asset_observations(asset,ts,block);
        create table if not exists breaks(vault text,block integer,idx integer,ts integer,primary key(vault,block,idx));
        create table if not exists events(source text,block integer,tx text,idx integer,payload text,primary key(source,tx,idx));
        create table if not exists cursors(source text primary key,block integer,hash text);''')
        manifest = demo.load()
        self.namespace = {k: manifest[k] for k in ('chainId', 'factory', 'genesisHash', 'deploymentBlockHash')}
        old = self.db.execute("select v from meta where k='namespace'").fetchone()
        if old and json.loads(old[0]) != self.namespace:
            self.db.close()
            raise ValueError('Performance history deployment mismatch')
        self.db.execute("insert or ignore into meta values('namespace',?)", (json.dumps(self.namespace, sort_keys=True),))
        self.db.commit()
        self.cached = {'vaults': [], 'portfolios': [], 'observedBlock': 0, 'observedAt': 0}
        self.capture_key = None
        self.read_cache = {}

    def close(self):
        self.db.close()

    def update_fixture(self, fixture):
        with self.lock:
            self.fixture = fixture

    def asset_report(self):
        """Return bounded real samples, retaining daily coverage and recent detail."""
        with self.lock:
            result = {}
            for (asset,) in self.db.execute('select distinct asset from asset_observations'):
                latest = self.db.execute('select ts from asset_observations where asset=? order by block desc limit 1',
                                         (asset,)).fetchone()
                if not latest:
                    continue
                cutoff = latest[0] - (MAX_ASSET_HISTORY_DAYS - 1) * 86400
                # Keep the opening and closing observation of each UTC day. The
                # recent tail preserves intraday moves without evicting old days.
                daily = self.db.execute('''select o.block,o.ts,o.oracle,o.dex from asset_observations o join
                                           (select ts/86400 as day,min(block) as first_block,max(block) as last_block
                                            from asset_observations where asset=? and ts>=? group by ts/86400) d
                                           on o.block=d.first_block or o.block=d.last_block
                                           where o.asset=?''', (asset, cutoff, asset)).fetchall()
                recent = self.db.execute('select block,ts,oracle,dex from asset_observations where asset=? order by block desc limit ?',
                                         (asset, MAX_RECENT_ASSET_SAMPLES)).fetchall()
                samples = {block: {'timestamp': ts, 'oraclePrice': oracle, 'dexPrice': dex} for block, ts, oracle, dex in daily}
                samples.update({block: {'timestamp': ts, 'oraclePrice': oracle, 'dexPrice': dex} for block, ts, oracle, dex in recent})
                samples = [samples[block] for block in sorted(samples)]
                if len(samples) > MAX_ASSET_HISTORY:
                    samples = samples[-MAX_ASSET_HISTORY:]
                if samples:
                    result[asset.lower()] = {'oraclePrice': samples[-1]['oraclePrice'], 'dexPrice': samples[-1]['dexPrice'],
                                     'history': samples}
            return result

    def read(self, target, signature, *args, block=None):
        block = block or self.block
        data = keccak(signature)[:10] + ''.join(argument(v) for v in args)
        key = (target.lower(), data, block)
        if key not in self.read_cache:
            self.read_cache[key] = words(self.demo.rpc('eth_call', [{'to': target, 'data': data}, block]))
        return self.read_cache[key]

    def uint(self, target, signature, *args, block=None):
        return self.read(target, signature, *args, block=block)[0]

    def assets(self, target, signature, *args):
        w = self.read(target, signature, *args)
        offset = w[0]//32
        return [address(v) for v in w[offset+1:offset+1+w[offset]]]

    def value(self, token, quantity, block=None):
        if quantity == 0:
            return 0
        if token.lower() == self.manifest['settlementAsset'].lower():
            return quantity
        block = block or self.block
        price = self.uint(self.manifest['registry'], 'getPrice(address,address)', token, self.manifest['settlementAsset'], block=block)
        decimals = self.uint(token, 'decimals()', block=block)
        return quantity*price*self.settlement_scale//(10**decimals*E18)

    def sync_events(self, source):
        cursor = self.db.execute('select block,hash from cursors where source=?', (source,)).fetchone()
        if cursor:
            block = self.demo.rpc('eth_getBlockByNumber', [hex(cursor[0]), False])
            if not block or block['hash'] != cursor[1] or cursor[0] > self.number:
                raise CanonicalHistoryError('Canonical history changed; restore matching simulation history')
        start = cursor[0]+1 if cursor else 0
        topics = [keccak(s) for s in EVENTS.values()]
        for lower in range(start, self.number+1, 20000):
            logs = self.demo.rpc('eth_getLogs', [{'address': source, 'fromBlock': hex(lower), 'toBlock': hex(min(lower+19999, self.number)), 'topics': [topics]}])
            for log in logs:
                if log.get('removed'):
                    raise CanonicalHistoryError('Removed event')
                self.db.execute('insert or ignore into events values(?,?,?,?,?)', (source, int(log['blockNumber'], 16), log['transactionHash'], int(log['logIndex'], 16), json.dumps(log)))
        self.db.execute('insert into cursors values(?,?,?) on conflict(source) do update set block=excluded.block,hash=excluded.hash', (source, self.number, self.block_hash))
        return [json.loads(row[0]) for row in self.db.execute('select payload from events where source=? order by block,idx', (source,))]

    def exit_value(self, vault, log):
        data = words(log['data'])
        receiver = '0x' + log['topics'][2][-40:]
        receipt = self.demo.rpc('eth_getTransactionReceipt', [log['transactionHash']])
        if not receipt or receipt['blockHash'] != log['blockHash']:
            raise CanonicalHistoryError('Exit receipt is not canonical')
        # Select only transfers before this Exited and after the preceding Exited
        # from this vault in a multicall transaction; avoid counting other exits.
        previous = max((int(e['logIndex'], 16) for e in receipt['logs'] if e['address'].lower() == vault.lower() and e['topics'] and e['topics'][0].lower() == keccak(EVENTS['exited']) and int(e['logIndex'], 16) < int(log['logIndex'], 16)), default=-1)
        value = data[1]
        for transfer in receipt['logs']:
            if not previous < int(transfer['logIndex'], 16) < int(log['logIndex'], 16):
                continue
            t = transfer['topics']
            if len(t) != 3 or t[0].lower() != keccak('Transfer(address,address,uint256)'):
                continue
            if ('0x'+t[1][-40:]).lower() != vault.lower() or ('0x'+t[2][-40:]).lower() != receiver.lower():
                continue
            if transfer['address'].lower() == self.manifest['settlementAsset'].lower():
                continue
            value += self.value(transfer['address'], words(transfer['data'])[0], block=log['blockNumber'])
        return value

    def ledger(self, vault, escrow):
        ledger = Ledger()
        logs = self.sync_events(vault)
        if escrow != ZERO:
            logs += self.sync_events(escrow)
        kinds = {keccak(v): k for k, v in EVENTS.items()}
        logs.sort(key=lambda e: (int(e['blockNumber'], 16), int(e['logIndex'], 16)))
        supply = 0
        for log in logs:
            kind = kinds[log['topics'][0].lower()]
            owner_index = 2 if kind in ('entered', 'created', 'claimed') else 1
            owner = '0x' + log['topics'][owner_index][-40:]
            data = words(log['data'])
            out = self.exit_value(vault, log) if kind == 'exited' else None
            if kind == 'claimed':
                token = '0x' + log['topics'][3][-40:]
                out = self.value(token, data[0], block=log['blockNumber'])
            ledger.apply(kind, owner, data, out)
            if kind in ('entered', 'integrated'):
                supply += data[2]
            elif kind == 'exited':
                supply -= data[0]
                if supply < 0:
                    raise ValueError('Incomplete total share history')
                if supply == 0:
                    block = self.demo.rpc('eth_getBlockByNumber', [log['blockNumber'], False])
                    if not block or block['hash'] != log['blockHash']:
                        raise CanonicalHistoryError('Empty-supply event is not canonical')
                    self.db.execute('insert or ignore into breaks values(?,?,?,?)', (vault, int(log['blockNumber'], 16), int(log['logIndex'], 16), int(block['timestamp'], 16)))
        return ledger

    def capture(self):
        with self.lock:
            try:
                return self._capture()
            except Exception:
                self.db.rollback()
                self.capture_key = None
                self.cached = {'vaults': [], 'portfolios': [], 'observedBlock': 0, 'observedAt': 0}
                raise

    def _capture(self):
        self.read_cache = {}
        self.manifest = self.demo.load()
        if any(self.manifest[k] != v for k, v in self.namespace.items()):
            raise ValueError('Performance deployment changed')
        head = self.demo.rpc('eth_getBlockByNumber', ['latest', False])
        # Reuse only a successfully reconciled observation at the exact same
        # canonical head and with identical deployment/fixture inputs. The
        # deployment authentication above still runs on every capture. A new
        # block (including a same-height replacement) always reconciles again.
        capture_key = (head['number'], head['hash'], head['timestamp'],
                       json.dumps(self.manifest, sort_keys=True),
                       json.dumps(self.fixture, sort_keys=True))
        if capture_key == self.capture_key:
            return self.cached
        self.capture_key = None
        self.block = head['number']; self.number = int(self.block, 16)
        self.block_hash = head['hash']; self.timestamp = int(head['timestamp'], 16)
        self.settlement_scale = 10**self.uint(self.manifest['settlementAsset'], 'decimals()')
        self.validate_asset_cursor()
        self.capture_assets()
        vaults = {v['address'].lower(): v for v in self.manifest['vaults'] + self.fixture.get('vaults', [])}
        profiles = self.fixture.get('profiles', [])
        owners = {p['address'].lower(): p for p in profiles}
        portfolios = {owner: {'address': owner, 'invested': 0, 'currentValue': 0, 'remainingCost': 0, 'unrealizedPnl': 0, 'realizedPnl': 0, 'totalPnl': 0, 'returnBps': None, 'status': 'complete', 'reason': None, 'positions': []} for owner in owners}
        result = []
        for vault, spec in vaults.items():
            affected = set(owners)
            try:
                escrow = address(self.uint(vault, 'investmentEscrow()'))
                ledger = self.ledger(vault, escrow)
                affected = {owner for owner in owners if ledger.account(owner)['invested'] or ledger.account(owner)['shares']}
                total = self.uint(vault, 'totalAssets()')
                supply = self.uint(vault, 'totalSupply()')
                nav = total*E18*10**6//supply if supply else None
                pending = {owner: {'cost': 0, 'value': 0, 'available': 0} for owner in owners}
                if escrow != ZERO:
                    count = self.uint(escrow, 'nextRequestId()')
                    if count > 1001:
                        raise ValueError('Demo request accounting limit exceeded')
                    for request in range(1, count):
                        data = self.read(escrow, 'getRequest(uint256)', request)
                        owner = address(data[0]).lower()
                        if owner not in owners:
                            continue
                        row = pending[owner]; row['available'] += data[5]
                        for token in self.assets(escrow, 'requestAssets(uint256)', request):
                            quantity, cost = self.read(escrow, 'positions(uint256,address)', request, token)
                            row['cost'] += cost; row['value'] += self.value(token, quantity)
                for owner, row in portfolios.items():
                    shares = self.uint(vault, 'balanceOf(address)', owner)
                    cost = self.uint(vault, 'costBasis(address)', owner)
                    account = ledger.account(owner)
                    if account['shares'] != shares or account['cost'] != cost:
                        raise ValueError('Share history does not reconcile with current position')
                    # Exit distributes the actual proportional basket, rounded
                    # separately per token. Entry virtual offsets do not apply.
                    value = self.uint(vault, 'quoteExitValue(uint256)', shares) if shares else 0
                    p = pending[owner]
                    current = value+p['value']+p['available']
                    remaining = cost+p['cost']+p['available']
                    row['invested'] += account['invested']; row['realizedPnl'] += account['realized']
                    row['currentValue'] += current; row['remainingCost'] += remaining
                    if current or remaining or account['invested']:
                        row['positions'].append({'vault': vault, 'name': spec.get('name', vault), 'value': str(current), 'remainingCost': str(remaining), 'unrealizedPnl': str(current-remaining), 'realizedPnl': str(account['realized']), 'available': str(p['available']), 'pendingValue': str(p['value'])})
                # Persist an explicit break when all shares are burned. A later
                # first deposit must never be joined to the former share series.
                self.db.execute('insert or replace into observations values(?,?,?,?,?,?)', (vault, self.number, self.block_hash, self.timestamp, str(nav or 0), str(total)))
                series = [(block, 2**32, ts, n, assets) for block, ts, n, assets in self.db.execute('select block,ts,nav,assets from observations where vault=?', (vault,))]
                # A burn event proves a share-series break, not the vault AUM.
                # Preserve the observed assets field rather than reconstructing
                # historical AUM from NAV and the current share supply.
                series += [(block, idx, ts, '0', None) for block, idx, ts in self.db.execute('select block,idx,ts from breaks where vault=?', (vault,))]
                history = [{'timestamp': ts, 'nav': n, 'totalAssets': assets, 'blockNumber': str(block),
                            **({'navBreakBefore': True} if idx != 2**32 else {})}
                           for block, idx, ts, n, assets in sorted(series)]
                periods = returns(history, self.timestamp)
                if nav is None:
                    periods = {k: {**v, 'returnBps': None, 'reason': 'Vault has no shares'} for k, v in periods.items()}
                result.append({'address': vault, 'name': spec.get('name', vault), 'nav': str(nav) if nav is not None else None, 'totalAssets': str(total), 'periods': periods, 'history': history})
            except CanonicalHistoryError:
                raise
            except Exception as exc:
                # A missing oracle or unsupported history must never become a zero PnL.
                for owner in affected:
                    portfolios[owner]['status'] = 'unavailable'; portfolios[owner]['reason'] = str(exc)
                result.append({'address': vault, 'name': spec.get('name', vault), 'nav': None, 'totalAssets': None, 'periods': {k: {'returnBps': None, 'reason': str(exc), 'from': None, 'to': self.timestamp} for k in ('1D', '7D', '1M', 'YTD', '1Y', 'ALL')}, 'history': []})
        if self.demo.rpc('eth_getBlockByNumber', [self.block, False])['hash'] != self.block_hash:
            raise CanonicalHistoryError('Observation block changed during capture')
        self.db.execute('insert into cursors values(?,?,?) on conflict(source) do update set block=excluded.block,hash=excluded.hash',
                        (ASSET_CURSOR, self.number, self.block_hash))
        for row in portfolios.values():
            row['unrealizedPnl'] = row['currentValue']-row['remainingCost']
            row['totalPnl'] = row['unrealizedPnl']+row['realizedPnl']
            row['returnBps'] = row['totalPnl']*10000//row['invested'] if row['invested'] else None
            for key in ('invested', 'currentValue', 'remainingCost', 'unrealizedPnl', 'realizedPnl', 'totalPnl'):
                row[key] = str(row[key])
        self.db.commit()
        self.cached = {'vaults': result, 'portfolios': list(portfolios.values()), 'observedBlock': self.number, 'observedAt': self.timestamp}
        if all(v['totalAssets'] is not None for v in result) and all(p['status'] == 'complete' for p in portfolios.values()):
            self.capture_key = capture_key
        return self.cached

    def capture_assets(self):
        """Persist oracle and pool spot samples from the same pinned block."""
        settlement = self.manifest['settlementAsset']
        settlement_decimals = self.uint(settlement, 'decimals()')
        assets = {item['address'].lower(): item for item in self.manifest.get('assets', [])}
        assets.update({item['address'].lower(): item for item in self.fixture.get('assets', [])})
        for asset, item in assets.items():
            oracle = self.uint(item['primaryOracle'], 'getPrice(address,address)', item['address'], settlement)
            token_decimals = self.uint(item['address'], 'decimals()')
            reserve_settlement = self.uint(item['pool'], 'reserveOf(address)', settlement)
            reserve_token = self.uint(item['pool'], 'reserveOf(address)', item['address'])
            if oracle <= 0 or reserve_settlement <= 0 or reserve_token <= 0:
                raise ValueError('Asset observation price is unavailable')
            dex = reserve_settlement * 10**token_decimals * E18 // (reserve_token * 10**settlement_decimals)
            existing = self.db.execute('select hash,ts,oracle,dex from asset_observations where asset=? and block=?',
                                       (asset, self.number)).fetchone()
            expected = (self.block_hash, self.timestamp, str(oracle), str(dex))
            if existing and tuple(existing) != expected:
                raise CanonicalHistoryError('Asset observation differs at an existing block')
            self.db.execute('insert or ignore into asset_observations values(?,?,?,?,?,?)',
                            (asset, self.number, *expected))

    def validate_asset_cursor(self):
        cursor = self.db.execute('select block,hash from cursors where source=?', (ASSET_CURSOR,)).fetchone()
        if not cursor:
            return
        block, block_hash = cursor
        canonical = self.demo.rpc('eth_getBlockByNumber', [hex(block), False])
        if not canonical or canonical['hash'] != block_hash or block > self.number:
            raise CanonicalHistoryError('Asset observation history changed; restore matching simulation history')

    def report(self):
        with self.lock:
            return json.loads(json.dumps(self.cached))
