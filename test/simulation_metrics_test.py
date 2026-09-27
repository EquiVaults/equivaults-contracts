"""Calendar boundaries and accounting invariants of observed simulation metrics."""
import datetime as dt
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('simulation_metrics', Path(__file__).resolve().parents[1]/'script/simulation_metrics.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


def timestamp(value):
    return int(dt.datetime.fromisoformat(value).replace(tzinfo=dt.timezone.utc).timestamp())


class CalendarTest(unittest.TestCase):
    def test_month_and_year_clip_leap_days(self):
        self.assertEqual(m.period_start('1M', timestamp('2024-03-31T12:00:00')), timestamp('2024-02-29T12:00:00'))
        self.assertEqual(m.period_start('1Y', timestamp('2024-02-29T12:00:00')), timestamp('2023-02-28T12:00:00'))
        self.assertEqual(m.period_start('YTD', timestamp('2026-09-21')), timestamp('2026-01-01'))

    def test_missing_history_is_not_zero_or_partial_period(self):
        now = timestamp('2026-09-21')
        history = [{'timestamp': now-86400, 'nav': '100'}, {'timestamp': now, 'nav': '120'}]
        result = m.returns(history, now)
        self.assertEqual(result['1D']['returnBps'], 2000)
        for period in ('7D', '1M', '1Y', 'YTD'):
            self.assertIsNone(result[period]['returnBps'])
        self.assertEqual(result['ALL']['returnBps'], 2000)

    def test_time_jump_does_not_invent_observations(self):
        now = timestamp('2026-09-21')
        result = m.returns([{'timestamp': now-40*86400, 'nav': '100'}, {'timestamp': now, 'nav': '110'}], now)
        self.assertIsNone(result['ALL']['returnBps'])
        self.assertIsNone(result['1M']['returnBps'])

    def test_daily_observations_enable_month_return(self):
        now = timestamp('2026-09-21')
        history = [{'timestamp': now-(40-i)*86400, 'nav': str(100+i)} for i in range(41)]
        result = m.returns(history, now)
        self.assertEqual(result['1M']['from'], timestamp('2026-08-21'))
        self.assertEqual(result['1M']['returnBps'], (140-109)*10000//109)
        self.assertIsNone(result['1Y']['returnBps'])

    def test_empty_vault_breaks_share_series_before_new_deposit(self):
        now = timestamp('2026-09-21')
        history = [{'timestamp': now-86400, 'nav': '200'}, {'timestamp': now-1000, 'nav': '0'}, {'timestamp': now, 'nav': '100'}]
        result = m.returns(history, now)
        self.assertIsNone(result['1D']['returnBps'])
        self.assertIsNone(result['ALL']['returnBps'])
        self.assertIn('discontinuous', result['ALL']['reason'])

    def test_initial_empty_observation_does_not_prevent_tracking(self):
        now = timestamp('2026-09-21')
        result = m.returns([{'timestamp': now-100, 'nav': '0'}, {'timestamp': now, 'nav': '100'}], now)
        self.assertEqual(result['ALL']['returnBps'], 0)


class LedgerTest(unittest.TestCase):
    def test_late_investor_never_inherits_early_profit(self):
        ledger = m.Ledger()
        ledger.apply('entered', 'early', [100, 100, 100])
        ledger.apply('entered', 'late', [200, 200, 100])
        ledger.apply('exited', 'early', [50, 100, 0], 100)
        ledger.apply('exited', 'late', [50, 100, 0], 100)
        self.assertEqual(ledger.account('early'), {'shares': 50, 'cost': 50, 'invested': 100, 'realized': 50})
        self.assertEqual(ledger.account('late')['realized'], 0)

    def test_async_integration_does_not_double_count_capital(self):
        ledger = m.Ledger()
        ledger.apply('created', 'patient', [1000])
        ledger.apply('integrated', 'patient', [200, 180, 180])
        ledger.apply('integrated', 'patient', [300, 310, 310])
        self.assertEqual(ledger.account('patient')['invested'], 1000)
        self.assertEqual(ledger.account('patient')['cost'], 500)

    def test_partial_exit_uses_exact_protocol_floor_cost(self):
        ledger = m.Ledger()
        ledger.apply('entered', 'x', [10, 10, 3])
        ledger.apply('exited', 'x', [1, 5, 0], 5)
        self.assertEqual(ledger.account('x')['cost'], 7)
        ledger.apply('exited', 'x', [2, 4, 0], 4)
        self.assertEqual(ledger.account('x')['cost'], 0)
        self.assertEqual(ledger.account('x')['realized'], -1)

    def test_claimed_tokens_are_recoveries_not_total_losses(self):
        ledger = m.Ledger()
        ledger.apply('created', 'x', [100])
        ledger.apply('claimed', 'x', [50, 40], 45)
        self.assertEqual(ledger.account('x')['realized'], 5)

    def test_missing_share_history_is_unavailable(self):
        with self.assertRaisesRegex(ValueError, 'Incomplete'):
            m.Ledger().apply('exited', 'x', [10, 10, 0], 10)

    def test_virtual_share_nav_does_not_inflate_on_fair_deposit(self):
        assets, shares, incoming = 100000000, 100000000000000, 25000000
        before = (assets+1)*m.E18*10**6//(shares+10**6)
        minted = incoming*(shares+10**6)//(assets+1)
        after = (assets+incoming+1)*m.E18*10**6//(shares+minted+10**6)
        self.assertLessEqual(abs(after-before), 10000)


class NamespaceTest(unittest.TestCase):
    def test_refuses_different_deployment_history(self):
        class Demo:
            def __init__(self, genesis): self.genesis = genesis
            def load(self): return {'chainId': 31337, 'factory': 'factory', 'genesisHash': self.genesis, 'deploymentBlockHash': 'block'}
        with tempfile.TemporaryDirectory() as root:
            path = Path(root)/'history.sqlite'
            metrics = m.Metrics(Demo('a'), path); metrics.close()
            with self.assertRaisesRegex(ValueError, 'deployment mismatch'):
                m.Metrics(Demo('b'), path)


class AssetObservationTest(unittest.TestCase):
    ASSET = '0x' + 'a' * 40

    def demo(self):
        asset = self.ASSET
        class Demo:
            def load(self):
                return {'chainId': 31337, 'factory': 'factory', 'genesisHash': 'genesis', 'deploymentBlockHash': 'anchor',
                        'settlementAsset': 'settlement', 'assets': [{'address': asset, 'primaryOracle': 'oracle', 'pool': 'pool'}], 'vaults': []}
            def rpc(self, method, _params):
                if method == 'eth_getBlockByNumber':
                    return {'number': '0xa', 'hash': 'canonical', 'timestamp': hex(1_000)}
                raise AssertionError(method)
        return Demo()

    def test_asset_history_is_pinned_persistent_and_starts_at_capture(self):
        blocks = []
        class Metrics(m.Metrics):
            def read(self, _target, signature, *_args, block=None):
                blocks.append(block or self.block)
                if signature == 'decimals()': return [6 if _target == 'settlement' else 18]
                if signature == 'getPrice(address,address)': return [2 * m.E18]
                if signature == 'reserveOf(address)': return [200_000_000 if _args[0] == 'settlement' else 100 * 10**18]
                raise AssertionError(signature)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'metrics.sqlite'
            metrics = Metrics(self.demo(), path)
            try:
                self.assertEqual(metrics.asset_report(), {})
                metrics.capture()
                report = metrics.asset_report()[self.ASSET]
                self.assertEqual(report['history'], [{'timestamp': 1_000, 'oraclePrice': str(2 * m.E18), 'dexPrice': str(2 * m.E18)}])
                self.assertEqual(set(blocks), {'0xa'})
            finally:
                metrics.close()
            restarted = m.Metrics(self.demo(), path)
            try:
                self.assertEqual(restarted.asset_report()[self.ASSET]['history'], report['history'])
            finally:
                restarted.close()

    def test_conflicting_same_block_asset_sample_is_canonical_history_error(self):
        class Metrics(m.Metrics):
            def read(self, _target, signature, *_args, block=None):
                if signature == 'decimals()': return [6 if _target == 'settlement' else 18]
                if signature == 'getPrice(address,address)': return [m.E18]
                if signature == 'reserveOf(address)': return [100_000_000 if _args[0] == 'settlement' else 100 * 10**18]
                raise AssertionError(signature)
        with tempfile.TemporaryDirectory() as folder:
            metrics = Metrics(self.demo(), Path(folder) / 'metrics.sqlite')
            try:
                metrics.db.execute('insert into asset_observations values(?,?,?,?,?,?)',
                                   (self.ASSET, 10, 'orphaned', 999, '1', '1'))
                metrics.db.commit()
                with self.assertRaises(m.CanonicalHistoryError):
                    metrics.capture()
            finally:
                metrics.close()

    def test_asset_cursor_detects_reorg_at_a_later_head(self):
        asset = self.ASSET
        class Demo:
            def __init__(self):
                self.head = 10; self.hashes = {10: 'block10', 11: 'block11'}
            def load(self):
                return {'chainId': 31337, 'factory': 'factory', 'genesisHash': 'genesis', 'deploymentBlockHash': 'anchor',
                        'settlementAsset': 'settlement', 'assets': [{'address': asset, 'primaryOracle': 'oracle', 'pool': 'pool'}], 'vaults': []}
            def rpc(self, method, params):
                if method == 'eth_getBlockByNumber':
                    block = self.head if params[0] == 'latest' else int(params[0], 16)
                    return {'number': hex(block), 'hash': self.hashes[block], 'timestamp': hex(1_000 + block)}
                raise AssertionError(method)
        class Metrics(m.Metrics):
            def read(self, _target, signature, *_args, block=None):
                if signature == 'decimals()': return [6 if _target == 'settlement' else 18]
                if signature == 'getPrice(address,address)': return [m.E18]
                if signature == 'reserveOf(address)': return [100_000_000 if _args[0] == 'settlement' else 100 * 10**18]
                raise AssertionError(signature)
        with tempfile.TemporaryDirectory() as folder:
            demo = Demo(); metrics = Metrics(demo, Path(folder) / 'metrics.sqlite')
            try:
                metrics.capture()
                self.assertEqual(metrics.db.execute('select hash from cursors where source=?', (m.ASSET_CURSOR,)).fetchone()[0], 'block10')
                demo.head = 11; demo.hashes[10] = 'orphaned'
                with self.assertRaises(m.CanonicalHistoryError): metrics.capture()
            finally:
                metrics.close()

    def test_asset_history_retains_daily_coverage_after_intraday_activity(self):
        with tempfile.TemporaryDirectory() as folder:
            metrics = m.Metrics(self.demo(), Path(folder) / 'metrics.sqlite')
            try:
                start = 86400 * 20_000
                rows = [(self.ASSET, day + 1, f'h{day}', start + day * 86400, str(day + 1), str(day + 2))
                        for day in range(90)]
                # A busy final day must not evict the preceding simulated days.
                rows += [(self.ASSET, 1_000 + tick, f'i{tick}', start + 89 * 86400 + tick, '100', '101')
                         for tick in range(1_000)]
                metrics.db.executemany('insert into asset_observations values(?,?,?,?,?,?)', rows)
                metrics.db.commit()
                history = metrics.asset_report()[self.ASSET]['history']
                timestamps = {point['timestamp'] for point in history}
                self.assertLessEqual(len(history), m.MAX_ASSET_HISTORY)
                self.assertTrue(all(start + day * 86400 in timestamps for day in range(90)))
                self.assertEqual(history[-1]['timestamp'], start + 89 * 86400 + 999)
            finally:
                metrics.close()



class CaptureTest(unittest.TestCase):
    OWNER = '0x'+'2'*40
    VAULT = '0x'+'1'*40

    def test_capture_uses_exact_exit_right_not_entry_virtual_offsets(self):
        owner, vault = self.OWNER, self.VAULT
        class Demo:
            def load(self):
                return {'chainId':31337,'factory':'factory','genesisHash':'genesis','deploymentBlockHash':'anchor','settlementAsset':'settlement','vaults':[{'address':vault,'name':'Small vault'}]}
            def rpc(self, method, params):
                if method == 'eth_getBlockByNumber': return {'number':'0xa','hash':'block','timestamp':hex(timestamp('2026-09-21'))}
                raise AssertionError(method)
        class Metrics(m.Metrics):
            def read(self, target, signature, *args, block=None):
                return {'decimals()':[6],'totalAssets()':[10],'totalSupply()':[10**6],'investmentEscrow()':[0], 'balanceOf(address)':[10**6],'costBasis(address)':[10], 'quoteExitValue(uint256)':[10]}[signature]
            def ledger(self, vault, escrow):
                result=m.Ledger();result.apply('entered',owner,[10,10,10**6]);return result
        with tempfile.TemporaryDirectory() as folder:
            metrics=Metrics(Demo(),Path(folder)/'metrics.sqlite',{'profiles':[{'address':owner}]})
            try:
                row=metrics.capture()['portfolios'][0]
                self.assertEqual(row['status'],'complete');self.assertEqual(row['currentValue'],'10');self.assertEqual(row['unrealizedPnl'],'0')
            finally: metrics.close()

    def test_reorg_halts_capture_instead_of_publishing_partial_history(self):
        owner,vault=self.OWNER,self.VAULT
        class Demo:
            def load(self): return {'chainId':31337,'factory':'factory','genesisHash':'genesis','deploymentBlockHash':'anchor','settlementAsset':'settlement','vaults':[{'address':vault}]}
            def rpc(self,method,params):
                if method=='eth_getBlockByNumber': return {'number':'0xa','hash':'canonical','timestamp':hex(timestamp('2026-09-21'))}
                raise AssertionError(method)
        class Metrics(m.Metrics):
            def read(self,target,signature,*args,block=None):
                return {'decimals()':[6],'investmentEscrow()':[0]}[signature]
        with tempfile.TemporaryDirectory() as folder:
            metrics=Metrics(Demo(),Path(folder)/'metrics.sqlite',{'profiles':[{'address':owner}]})
            try:
                metrics.db.execute('insert into cursors values(?,?,?)',(vault,1,'orphaned'));metrics.db.commit()
                with self.assertRaises(m.CanonicalHistoryError): metrics.capture()
                self.assertEqual(metrics.report()['observedBlock'],0)
                self.assertEqual(metrics.db.execute('select hash from cursors').fetchone()[0],'orphaned')
            finally: metrics.close()

    def test_capture_detects_empty_supply_between_observations(self):
        owner,vault=self.OWNER,self.VAULT
        now=timestamp('2026-09-21')
        def event(kind, data, block):
            topics=[m.keccak(m.EVENTS[kind]), '0x'+m.argument(owner), '0x'+m.argument(owner)]
            return {'address':vault,'topics':topics,'data':'0x'+''.join(m.argument(n) for n in data),'blockNumber':hex(block),'blockHash':f'block{block}','logIndex':'0x1','transactionHash':f'tx{block}'}
        logs=[event('entered',[100,100,100],1),event('exited',[100,200,0],5),event('entered',[100,100,100],6)]
        class Demo:
            def load(self): return {'chainId':31337,'factory':'factory','genesisHash':'genesis','deploymentBlockHash':'anchor','settlementAsset':'settlement','vaults':[{'address':vault}]}
            def rpc(self,method,params):
                if method=='eth_getBlockByNumber':
                    n=10 if params[0]=='latest' else int(params[0],16)
                    return {'number':hex(n),'hash':f'block{n}','timestamp':hex(now if n==10 else now-100)}
                raise AssertionError(method)
        class Metrics(m.Metrics):
            def read(self,target,signature,*args,block=None):
                return {'decimals()':[6],'totalAssets()':[100],'totalSupply()':[100],'investmentEscrow()':[0], 'balanceOf(address)':[100],'costBasis(address)':[100], 'quoteExitValue(uint256)':[100]}[signature]
            def sync_events(self,source): return logs
            def exit_value(self,vault,log): return 200
        with tempfile.TemporaryDirectory() as folder:
            metrics=Metrics(Demo(),Path(folder)/'metrics.sqlite',{'profiles':[{'address':owner}]})
            try:
                metrics.db.execute('insert into observations values(?,?,?,?,?,?)',(vault,2,'block2',now-86400,str(2*m.E18*10**6),'200'))
                metrics.db.commit()
                report=metrics.capture()
                self.assertIsNone(report['vaults'][0]['periods']['ALL']['returnBps'])
                self.assertEqual(report['portfolios'][0]['realizedPnl'],'100')
                self.assertEqual(report['portfolios'][0]['unrealizedPnl'],'0')
                self.assertEqual(metrics.db.execute('select count(*) from breaks').fetchone()[0],1)
            finally: metrics.close()

class CaptureReuseTest(unittest.TestCase):
    def test_same_head_reuses_only_successful_unchanged_inputs(self):
        class Demo:
            def __init__(self):
                self.head = 10; self.hash = 'block10'; self.loads = 0; self.extra = None
            def load(self):
                self.loads += 1
                return {'chainId': 31337, 'factory': 'factory', 'genesisHash': 'genesis',
                        'deploymentBlockHash': 'anchor', 'settlementAsset': 'settlement',
                        'vaults': [], 'extra': self.extra}
            def rpc(self, method, params):
                if method == 'eth_getBlockByNumber':
                    return {'number': hex(self.head), 'hash': self.hash, 'timestamp': hex(1000+self.head)}
                raise AssertionError(method)
        class Metrics(m.Metrics):
            captures = 0
            def uint(self, *args, **kwargs): return 6
            def capture_assets(self): self.captures += 1
        with tempfile.TemporaryDirectory() as folder:
            demo = Demo(); metrics = Metrics(demo, Path(folder)/'metrics.sqlite')
            try:
                first = metrics.capture(); count = demo.loads
                self.assertEqual(metrics.capture(), first)
                self.assertEqual(metrics.captures, 1)
                self.assertEqual(demo.loads, count+1)  # Deployment still authenticated.
                metrics.update_fixture({'profiles': []})
                metrics.capture(); self.assertEqual(metrics.captures, 2)
                demo.extra = 'new manifest inputs'
                metrics.capture(); self.assertEqual(metrics.captures, 3)
                # Replacing an observed block must fail, even at the same height.
                demo.hash = 'replacement'
                with self.assertRaises(m.CanonicalHistoryError): metrics.capture()
                self.assertEqual(metrics.report()['observedBlock'], 0)
                self.assertIsNone(metrics.capture_key)
                demo.hash = 'block10'
                metrics.capture(); self.assertEqual(metrics.captures, 4)
            finally: metrics.close()

    def test_unavailable_valuation_retries_without_waiting_for_new_block(self):
        owner, vault = '0x'+'1'*40, '0x'+'2'*40
        class Demo:
            def load(self):
                return {'chainId':31337,'factory':'factory','genesisHash':'genesis','deploymentBlockHash':'anchor',
                        'settlementAsset':'settlement','vaults':[{'address':vault}]}
            def rpc(self, method, params):
                return {'number':'0xa','hash':'canonical','timestamp':hex(1000)}
        class Metrics(m.Metrics):
            fail = True
            def read(self, target, signature, *args, block=None):
                if signature == 'totalAssets()' and self.fail: raise ValueError('Temporary RPC failure')
                return {'decimals()':[6],'totalAssets()':[10],'totalSupply()':[10**6],'investmentEscrow()':[0],
                        'balanceOf(address)':[10**6],'costBasis(address)':[10],'quoteExitValue(uint256)':[10]}[signature]
            def ledger(self, *args):
                ledger=m.Ledger();ledger.apply('entered',owner,[10,10,10**6]);return ledger
        with tempfile.TemporaryDirectory() as folder:
            metrics=Metrics(Demo(),Path(folder)/'metrics.sqlite',{'profiles':[{'address':owner}]})
            try:
                self.assertEqual(metrics.capture()['portfolios'][0]['status'],'unavailable')
                metrics.fail=False
                self.assertEqual(metrics.capture()['portfolios'][0]['status'],'complete')
                self.assertEqual(metrics.report()['portfolios'][0]['currentValue'],'10')
            finally: metrics.close()

if __name__ == '__main__': unittest.main()
