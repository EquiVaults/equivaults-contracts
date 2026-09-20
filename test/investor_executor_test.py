#!/usr/bin/env python3
import importlib.util
import tempfile
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


if __name__ == '__main__': unittest.main()
