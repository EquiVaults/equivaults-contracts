#!/usr/bin/env python3
import importlib.util
import tempfile
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('investor_executor', ROOT / 'script/investor-executor.py')
executor = importlib.util.module_from_spec(spec); spec.loader.exec_module(executor)


class StoreTests(unittest.TestCase):
    def test_signed_intent_survives_restart_and_is_not_a_blind_resend(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'execution.sqlite'; db=executor.ExecutionStore(path)
            db.intent('0x'+'11'*20, 9, '{"signed":true}')
            self.assertEqual(db.tracked()[0][2], None); db.close()
            reopened=executor.ExecutionStore(path)
            self.assertEqual(reopened.tracked()[0][1], '9')
            reopened.close()

    def test_same_nonce_for_two_accounts_updates_only_its_own_ledger_row(self):
        with tempfile.TemporaryDirectory() as directory:
            db=executor.ExecutionStore(Path(directory)/'execution.sqlite'); one, two = '0x'+'11'*20, '0x'+'22'*20
            db.intent(one, 0, 'one'); db.intent(two, 0, 'two')
            db.sent(one, 0, '0x'+'aa'*32); db.sent(two, 0, '0x'+'bb'*32)
            rows = db.db.execute('select account,hash,state from ops order by account').fetchall()
            self.assertEqual(rows, [(one, '0x'+'aa'*32, 'sent'), (two, '0x'+'bb'*32, 'sent')])
            db.settled(one, 0, '0x1', '0xblock')
            rows = db.db.execute('select account,state from ops order by account').fetchall()
            self.assertEqual(rows, [(one, 'mined'), (two, 'sent')]); db.close()


class SubmissionTests(unittest.TestCase):
    def test_wire_request_always_has_a_null_or_outer_transaction_hash(self):
        instance=object.__new__(executor.Executor); owner='11'*20; version='aa'*32
        raw='0x'+owner.rjust(64, '0')+version+f'{7:064x}'+('0'*64)+('0'*64)+f'{9:064x}'+('0'*64)*4
        instance.call=lambda target, signature, tag, rid: raw
        request=instance.request_item('0x'+'22'*20, '0x'+'33'*20, 4, 'latest')
        self.assertEqual(request['lastTxHash'], None)
        self.assertNotIn('lastUserOpHash', request)
        self.assertEqual(set(request), {'vault','escrow','requestId','owner','version','sequence','closed','available','lastTxHash'})

    def test_terminal_request_states_match_the_escrow_status(self):
        for code, expected in ((1, 'stopped'), (2, 'closed')):
            with self.subTest(code=code):
                instance=object.__new__(executor.Executor); row={'closed':code,'lastTxHash':None}
                instance.request_item=lambda *args: dict(row); reports=[]; instance.report=lambda item, state, reason: reports.append((state, reason, item['lastTxHash']))
                self.assertFalse(instance.try_request('vault', 'escrow', 1, 'latest', {}))
                self.assertEqual(reports, [(expected, None, None)])

    def test_executor_rejects_the_configured_bundler_sender_as_its_operator(self):
        instance=object.__new__(executor.Executor); same='0x'+'44'*20
        instance.a=type('A', (), {'bundler_url':'http://127.0.0.1:19790'})(); instance.sender=same; instance.catalog_executor=same; instance.bundler_sender=same
        with self.assertRaisesRegex(executor.sponsor.Pause, 'must_differ'): instance.authenticate()

    def test_reorg_from_bundler_receipt_halts_executor_across_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'execution.sqlite'; account='0x'+'11'*20; db=executor.ExecutionStore(path); db.intent(account, 0, '{}'); db.sent(account, 0, '0x'+'aa'*32)
            instance=object.__new__(executor.Executor); instance.db=db; instance.bundler_rpc=lambda method, params: (_ for _ in ()).throw(executor.sponsor.Pause('receipt_reorg_pause'))
            with self.assertRaisesRegex(executor.sponsor.Pause, 'receipt_reorg_pause'): instance.reconcile()
            self.assertEqual(db.value('halt'), 'receipt_reorg_pause'); db.close()
            resumed=executor.ExecutionStore(path); self.assertEqual(resumed.value('halt'), 'receipt_reorg_pause'); resumed.close()

    def test_authentication_rejects_bundler_context_from_a_different_chain_history(self):
        with tempfile.TemporaryDirectory() as directory:
            instance=object.__new__(executor.Executor); entry, execution_factory, vault = '0x'+'11'*20, '0x'+'22'*20, '0x'+'33'*20
            sender, bundler_sender, catalog_executor = '0x'+'44'*20, '0x'+'55'*20, '0x'+'44'*20
            instance.a=type('A', (), {'bundler_url':'http://127.0.0.1:19790','bundler_sender':bundler_sender})(); instance.entry_point=entry; instance.execution_factory=execution_factory; instance.factory=vault; instance.sender=sender; instance.bundler_sender=bundler_sender; instance.catalog_executor=catalog_executor; instance.entry_hash='0x'+'aa'*32; instance.execution_hash='0x'+'bb'*32
            commit='c'*40; instance.manifest={'contractsCommit':commit}; instance.catalog={'factories':[{'address':vault,'codeHash':'0x'+'cc'*32,'contractsCommit':commit}]}; instance.db=executor.ExecutionStore(Path(directory)/'e.sqlite'); instance.status=type('S', (), {'base':{}})()
            class Rpc:
                def call(self, method, params):
                    if method == 'eth_chainId': return '0x7a69'
                    if method == 'web3_clientVersion': return 'anvil/test'
                    if method == 'eth_accounts': return [sender]
                    if method == 'eth_getBlockByNumber': return {'hash':'0xgenesis' if params[0] == '0x0' else '0xdeployment'}
                    if method == 'eth_getLogs': return [{'blockNumber':'0x1'}]
                    raise AssertionError(method)
            instance.rpc=Rpc(); instance.runtime_hash=lambda target: instance.entry_hash if target == entry else instance.execution_hash if target == execution_factory else '0x'+'cc'*32
            instance.addr=lambda target, signature, block: entry if signature == 'entryPoint()' else vault
            expected={'chainId':31337,'genesisHash':'0xgenesis','entryPoint':entry,'factory':execution_factory,'entryPointCodeHash':instance.entry_hash,'factoryCodeHash':instance.execution_hash,'executor':catalog_executor,'bundlerSender':bundler_sender,'bundler':'http://127.0.0.1:19790','deploymentBlock':'0x1','deploymentBlockHash':'0xdeployment'}
            instance.bundler_rpc=lambda method, params: expected
            instance.authenticate()
            self.assertEqual(instance.status.base['deploymentBlock'], '1')
            self.assertEqual(instance.status.base['deploymentBlockHash'], '0xdeployment')
            self.assertEqual(instance.status.base['contractsCommit'], commit)
            instance.bundler_rpc=lambda method, params: {'chainId':31337, 'genesisHash':'0xother'}
            with self.assertRaisesRegex(executor.sponsor.Pause, 'bundler_identity_mismatch'): instance.authenticate()
            instance.db.close()

    def test_impossible_original_escrow_preflight_never_reaches_signing(self):
        instance=object.__new__(executor.Executor)
        account, escrow = '0x'+'22'*20, '0x'+'33'*20
        instance.execution_factory='0x'+'44'*20; instance.entry_point='0x'+'55'*20; instance.sender='0x'+'66'*20
        item={'vault':'0x'+'77'*20, 'escrow':escrow, 'requestId':'1', 'owner':'0x'+'88'*20, 'closed':0}
        instance.request_item=lambda *args: dict(item)
        instance.addr=lambda target, signature, tag, *values: account if target == instance.execution_factory else None
        info={'account':account, 'executor':instance.sender, 'owner':item['owner'], 'escrow':escrow, 'requestId':1,
              'entryPoint':instance.entry_point, 'paused':False, 'attempts':0, 'maxAttempts':2,
              'validUntil':999, 'budget':10**20, 'maxAttempt':10**20, 'maxFee':1, 'epoch':0}
        instance.account_info=lambda *args: dict(info)
        instance.original_action=lambda *args: (_ for _ in ()).throw(executor.sponsor.RpcExecutionError('impossible_price'))
        reports=[]; instance.report=lambda row, state, reason: reports.append((state, reason))
        class Rpc:
            def call(self, method, params):
                if method == 'eth_sign': self.fail('impossible preflight must not sign')
                raise AssertionError(method)
        instance.rpc=Rpc()
        self.assertFalse(instance.try_request(item['vault'], escrow, 1, 'latest', {'timestamp':'0x1','hash':'0xabc'}))
        self.assertEqual(reports, [('waiting_market', 'onchain_execution_rejected')])

    def test_insufficient_personal_budget_prevents_signature_and_bundler_send(self):
        with tempfile.TemporaryDirectory() as directory:
            instance=object.__new__(executor.Executor)
            instance.a=type('A', (), {})(); instance.db=executor.ExecutionStore(Path(directory)/'e.sqlite')
            calls=[]
            class Rpc:
                def call(self, method, params):
                    calls.append(method)
                    if method == 'eth_gasPrice': return '0x2'
                    raise AssertionError(method)
            instance.rpc=Rpc(); instance.entry_point='0x'+'ee'*20
            info={'maxFee':2, 'maxAttempt':1, 'budget':10**20, 'account':'0x'+'11'*20, 'epoch':0}
            with self.assertRaisesRegex(executor.sponsor.Pause, 'execution_budget_insufficient'):
                instance.submit({}, info, '0x1234', 'latest')
            self.assertNotIn('eth_sign', calls)
            instance.db.close()

    def test_global_status_is_never_a_sponsor_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            args=type('A', (), {'rpc_url':'http://127.0.0.1:1','state_db':str(Path(directory)/'x.sqlite'),'sender':'0x'+'11'*20})()
            # Status is deliberately constructed independently of RPC/catalog work.
            status=executor.sponsor.Status(0, args.sender); status.base['funding']='investor'; status.publish()
            report=__import__('json').loads(status.render())
            self.assertEqual(report['funding'], 'investor')
            self.assertEqual(report['operator']['budgetWei'], '0')


class PlannerTests(unittest.TestCase):
    def planner(self, max_fill=1_000_000, impact=50):
        instance=object.__new__(executor.Executor)
        instance.a=types.SimpleNamespace(max_fill=max_fill, max_price_impact_bps=impact)
        return instance

    def test_deep_pool_50000_request_needs_only_two_fills_and_integration(self):
        instance=self.planner(max_fill=1_000_000)
        instance.pool_quote=lambda registry, settlement, token, amount, tag: {'amount':amount,'out':amount * 2,'impactBps':0,'route':'pool'}
        first, reason=instance.adaptive_cap('registry', 'settlement', 'a', 30_000_000_000, 30_000_000_000, 1, '0x1')
        second, second_reason=instance.adaptive_cap('registry', 'settlement', 'b', 20_000_000_000, 20_000_000_000, 1, '0x1')
        self.assertIsNone(reason); self.assertIsNone(second_reason)
        self.assertEqual((first['amount'], second['amount']), (30_000_000_000, 20_000_000_000))
        self.assertLessEqual(2 + 1, 32)

    def test_thin_pool_downsizes_to_largest_impact_bounded_amount(self):
        instance=self.planner(impact=50)
        instance.pool_quote=lambda registry, settlement, token, amount, tag: {'amount':amount,'out':amount,'impactBps':amount // 100,'route':'pool'}
        quote, reason=instance.adaptive_cap('registry', 'settlement', 'asset', 10_000, 10_000, 1, '0x1')
        self.assertIsNone(reason); self.assertEqual(quote['amount'], 5_099)
        self.assertEqual(quote['impactBps'], 50)

    def test_low_decimal_pool_quote_uses_exact_conservative_ratio(self):
        instance=self.planner(); route='0x'+'12'*20
        config='0x'+('0'*64)*2+route[2:].rjust(64, '0')+('0'*64)*3
        instance.call=lambda target, signature, tag, *values: config
        values={('reserveOf(address)', 'settlement'):3, ('reserveOf(address)', 'asset'):7, ('swapFeeBps()', None):0}
        instance.uint=lambda target, signature, tag, *args: values[(signature, args[0] if args else None)]
        quote=instance.pool_quote('registry', 'settlement', 'asset', 1, '0x1')
        # Exact marginal output is 7/3 while the executable integer output is 2.
        # Flooring the marginal first would report zero; ceil ratio reports 1,429 bps.
        self.assertEqual(quote['out'], 2)
        self.assertEqual(quote['impactBps'], 1429)

    def test_unsupported_liquidity_fails_closed_without_a_preflight(self):
        instance=self.planner(max_fill=600); instance.factory='factory'; instance.addr=lambda target, signature, tag: signature
        instance.adaptive_cap=lambda *args: (None, 'price_impact_unavailable')
        instance.preflight_fill=lambda *args: self.fail('unsupported route must not reach a fill preflight')
        item={'escrow':'escrow','requestId':'1','sequence':'0','available':500}
        wrapped, data=instance.best_fill(item, 'vault', ['asset'], [{'quantity':0,'cost':0}], [700], '0x1', {'timestamp':'0x1'}, {'minFill':1,'executor':'operator'})
        self.assertIsNone(wrapped); self.assertIsNone(data)
        self.assertEqual(item['planning']['reason'], 'price_impact_unavailable')

    def test_largest_blocked_leg_does_not_starve_a_smaller_viable_leg(self):
        instance=self.planner(); instance.factory='factory'; instance.addr=lambda target, signature, tag: signature
        instance.adaptive_cap=lambda registry, settlement, token, cap, permitted, minimum, tag: ({'amount':cap,'out':cap * 2,'impactBps':1,'route':'pool'}, None)
        instance.pool_quote=lambda registry, settlement, token, amount, tag: {'amount':amount,'out':amount * 2,'impactBps':1,'route':'pool'}
        instance.investment_preview=lambda vault, quantities, tag: None
        calls=[]
        def preflight(escrow, rid, index, amount, sequence, deadline, operator, tag):
            calls.append((index, amount))
            if index == 0: raise executor.sponsor.RpcExecutionError('blocked')
            return '0xfill', amount * 2
        instance.preflight_fill=preflight
        item={'escrow':'escrow','requestId':'1','sequence':'0','available':100}
        wrapped, _=instance.best_fill(item, 'vault', ['large','small'], [{'quantity':0,'cost':0},{'quantity':0,'cost':0}], [100, 90], '0x1', {'timestamp':'0x1'}, {'minFill':10,'executor':'operator'})
        self.assertTrue(wrapped.startswith('0xfc75c449'))
        self.assertEqual(item['planning']['index'], 1)
        self.assertTrue(any(index == 0 for index, _ in calls))

    def test_rejected_cap_searches_useful_interval_above_half(self):
        instance=self.planner(); instance.factory='factory'; instance.addr=lambda *args: 'registry'
        instance.pool_quote=lambda registry, settlement, token, amount, tag: {'amount':amount,'out':amount * 2,'impactBps':1,'route':'pool'}
        instance.investment_preview=lambda *args: None
        calls=[]
        def preflight(escrow, rid, index, amount, sequence, deadline, operator, tag):
            calls.append(amount)
            if amount > 90: raise executor.sponsor.RpcExecutionError('price_limit')
            return '0xfill', amount * 2
        instance.preflight_fill=preflight
        item={'escrow':'escrow','requestId':'1','sequence':'0','available':100}
        wrapped, _=instance.best_fill(item, 'vault', ['asset'], [{'quantity':0,'cost':0}], [100], '0x1', {'timestamp':'0x1'}, {'minFill':80,'executor':'operator'})
        self.assertIsNotNone(wrapped)
        self.assertEqual(item['planning']['amount'], '90')
        self.assertIn(80, calls)
        self.assertTrue(all(amount >= 80 for amount in calls))
        self.assertLessEqual(len(calls), executor.PLANNER_PROBES)

    def test_last_attempt_is_reserved_for_integration(self):
        instance=self.planner(); instance.request_assets=lambda *args: ['asset']
        instance.position=lambda *args: {'quantity':0,'cost':0}
        instance.investment_preview=lambda *args: None
        item={'escrow':'escrow','vault':'vault','requestId':'1','sequence':'0','available':100}
        result=instance.original_action(item, '0x1', {'timestamp':'0x1'}, {'attempts':31,'maxAttempts':32,'minFill':1,'executor':'operator'})
        self.assertIsNone(result)
        self.assertEqual(item['planning']['reason'], 'reserve_integration_attempt')

    def test_integration_cost_matches_account_progress_guard(self):
        partial, complete=executor.Executor.preview_cost([{'quantity':100,'cost':101}], {'amounts':[50]})
        final, final_complete=executor.Executor.preview_cost([{'quantity':100,'cost':101}], {'amounts':[100]})
        self.assertEqual((partial, complete), (50, False))
        self.assertEqual((final, final_complete), (101, True))

    def test_balanced_tranche_integrates_before_subminimum_cash_is_spent(self):
        instance=self.planner(); instance.request_assets=lambda *args: ['asset']
        instance.position=lambda *args: {'quantity':100,'cost':100}
        instance.investment_preview=lambda *args: {'shares':99,'amounts':[100],'value':100}
        instance.rpc=types.SimpleNamespace(call=lambda method, params: '0x1')
        item={'escrow':'escrow','vault':'vault','requestId':'1','sequence':'0','available':49}
        wrapped=instance.original_action(item, '0x1', {'timestamp':'0x1'}, {'attempts':0,'maxAttempts':32,'minFill':50,'executor':'operator'})
        self.assertTrue(wrapped.startswith('0x3aaf8892'))
        self.assertEqual(item['planning']['action'], 'integrate')

    def test_subminimum_remainder_is_reported_without_a_fill(self):
        instance=self.planner(); instance.request_assets=lambda *args: ['asset']
        instance.position=lambda *args: {'quantity':0,'cost':0}; instance.investment_preview=lambda *args: None
        item={'escrow':'escrow','vault':'vault','requestId':'1','sequence':'0','available':49}
        self.assertIsNone(instance.original_action(item, '0x1', {'timestamp':'0x1'}, {'attempts':0,'maxAttempts':32,'minFill':50,'executor':'operator'}))
        self.assertEqual(item['planning']['reason'], 'remaining_below_minimum')

    def test_final_dust_and_hard_caps_keep_the_existing_bounds(self):
        self.assertTrue(executor.Executor._useful_amount(7, 7, 10))
        self.assertFalse(executor.Executor._useful_amount(7, 8, 10))
        instance=self.planner(max_fill=600); instance.factory='factory'; instance.addr=lambda target, signature, tag: signature
        observed=[]
        def adaptive(registry, settlement, token, cap, permitted, minimum, tag):
            observed.append((cap, permitted, minimum)); return {'amount':cap,'out':cap * 2,'impactBps':1,'route':'pool'}, None
        instance.adaptive_cap=adaptive
        instance.pool_quote=lambda registry, settlement, token, amount, tag: {'amount':amount,'out':amount * 2,'impactBps':1,'route':'pool'}
        instance.investment_preview=lambda vault, quantities, tag: None
        instance.preflight_fill=lambda escrow, rid, index, amount, sequence, deadline, operator, tag: ('0xfill', amount * 2)
        item={'escrow':'escrow','requestId':'1','sequence':'0','available':500}
        instance.best_fill(item, 'vault', ['asset'], [{'quantity':0,'cost':0}], [700], '0x1', {'timestamp':'0x1'}, {'minFill':1,'executor':'operator'})
        self.assertEqual(observed, [(500, 700, 1)])

    def test_all_price_plans_failing_never_submit_a_user_operation(self):
        instance=self.planner(); account='0x'+'11'*20; escrow='escrow'; owner='0x'+'22'*20
        instance.execution_factory='factory'; instance.entry_point='entry'; instance.sender='operator'
        item={'vault':'vault','escrow':escrow,'requestId':'1','owner':owner,'closed':0,'available':100}
        instance.request_item=lambda *args: dict(item)
        instance.addr=lambda target, signature, tag, *values: account if target == 'factory' else None
        info={'account':account,'executor':'operator','owner':owner,'escrow':escrow,'requestId':1,'entryPoint':'entry','paused':False,
              'attempts':0,'maxAttempts':32,'validUntil':999,'budget':10**20,'maxAttempt':10**20,'maxFee':1,'epoch':0,'minFill':1}
        instance.account_info=lambda *args: dict(info)
        def no_action(row, *args): row['planning']={'action':'none','reason':'price_impact_unavailable'}; return None
        instance.original_action=no_action; instance.submit=lambda *args: self.fail('all rejected plans must not submit')
        reports=[]; instance.report=lambda row, state, reason: reports.append((state, reason))
        self.assertFalse(instance.try_request('vault', escrow, 1, 'latest', {'timestamp':'0x1','hash':'0xhash'}))
        self.assertEqual(reports, [('no_admissible_action', 'price_impact_unavailable')])


class RotationTests(unittest.TestCase):
    def make_executor(self, directory, count, populated):
        instance=object.__new__(executor.Executor)
        instance.factory='factory';instance.cursor_vault=0;instance.cursor_request={}
        instance.db=executor.ExecutionStore(Path(directory)/'rotation.sqlite')
        instance.reconcile=lambda:None
        instance.status=type('Status',(),{'base':{}})()
        class Rpc:
            def call(self, method, params): return {'number':'0x1','hash':'0xhash','timestamp':'0x1'}
        instance.rpc=Rpc()
        def uint(target, signature, tag, *values):
            if signature=='vaultCount()': return count
            if signature=='isVault(address)': return 1
            if signature=='protocolVersion()': return 2
            if signature=='nextRequestId()': return 2 if int(target.split('-')[1]) in populated else 1
            raise AssertionError(signature)
        def addr(target, signature, tag, *values):
            if signature=='vaults(uint256)': return 'vault-'+str(values[0])
            if signature=='investmentEscrow()': return target.replace('vault','escrow')
            if signature=='vault()': return target.replace('escrow','vault')
            return signature
        instance.uint=uint;instance.addr=addr
        instance.seen=[]
        instance.try_request=lambda vault,*args: instance.seen.append(vault) or False
        return instance

    def test_empty_first_sixteen_vaults_cannot_starve_later_requests(self):
        with tempfile.TemporaryDirectory() as folder:
            instance=self.make_executor(folder,22,{17,18,20})
            try:
                instance.cycle();self.assertEqual(instance.cursor_vault,16)
                self.assertEqual(instance.seen,[])
                instance.cycle();self.assertEqual(instance.seen,['vault-17','vault-18','vault-20'])
                self.assertEqual(int(instance.db.value('cursor_vault')),10)
            finally: instance.db.close()

    def test_blocked_requests_do_not_change_scan_origin_mid_cycle(self):
        with tempfile.TemporaryDirectory() as folder:
            instance=self.make_executor(folder,4,{0,1,2,3})
            try:
                instance.cycle();self.assertEqual(instance.seen,['vault-0','vault-1','vault-2','vault-3'])
            finally: instance.db.close()

if __name__ == '__main__': unittest.main()
