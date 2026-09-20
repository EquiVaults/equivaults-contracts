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
            self.assertEqual(db.pending()[0][2], None); db.close()
            reopened=executor.ExecutionStore(path)
            self.assertEqual(reopened.pending()[0][1], '9')
            reopened.close()


class SubmissionTests(unittest.TestCase):
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
