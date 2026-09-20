#!/usr/bin/env python3
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('local_bundler', ROOT / 'script/local-bundler.py')
bundler = importlib.util.module_from_spec(spec); spec.loader.exec_module(bundler)


def op(**changes):
    value = {'sender':'0x'+'11'*20, 'nonce':'0x0', 'initCode':'0x', 'callData':'0x1234',
             'accountGasLimits':'0x'+'00'*32, 'preVerificationGas':'0x186a0',
             'gasFees':'0x'+'00'*32, 'paymasterAndData':'0x', 'signature':'0x'+'aa'*65}
    value.update(changes); return value


class EncodingTests(unittest.TestCase):
    def test_packed_operation_requires_exact_v09_conventional_fields(self):
        with self.assertRaisesRegex(bundler.BundlerError, 'fields'):
            bundler.packed_op({**op(), 'unknown':'0x'})
        with self.assertRaisesRegex(bundler.BundlerError, 'unsupported'):
            bundler.packed_op(op(initCode='0x01'))

    def test_handle_ops_keeps_packed_tuple_and_distinct_beneficiary(self):
        data = bundler.handle_ops_data(op(), '0x'+'22'*20)
        self.assertTrue(data.startswith('0x'))
        # ABI head: dynamic array begins after the two method arguments.
        self.assertEqual(int(data[10:74], 16), 64)
        self.assertEqual(data[74+24:74+64], '22'*20)

    def test_quantities_and_hex_are_bounded(self):
        with self.assertRaises(bundler.BundlerError): bundler.integer('-1')
        with self.assertRaises(bundler.BundlerError): bundler.norm_hex('0x0')
        with self.assertRaises(bundler.BundlerError): bundler.norm_address('0x1')


class StoreTests(unittest.TestCase):
    def test_intent_is_durable_and_nonce_is_unique_across_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'bundler.sqlite'; h = '0x'+'aa'*32
            store = bundler.Store(path); store.intent(h, '0x'+'11'*20, 7, '{"signed":true}')
            self.assertEqual(store.get(h)[3], 'intent'); store.close()
            resumed = bundler.Store(path)
            self.assertEqual(resumed.by_nonce('0x'+'11'*20, 7)[0], h)
            self.assertEqual(resumed.get(h)[3], 'intent')
            resumed.close()


class ReceiptTests(unittest.TestCase):
    def test_receipt_uses_inner_user_operation_event_not_outer_success(self):
        with tempfile.TemporaryDirectory() as directory:
            h, sender = '0x'+'aa'*32, '0x'+'11'*20
            store = bundler.Store(Path(directory) / 'b.sqlite'); store.intent(h, sender, 3, '{}'); store.sent(h, '0x'+'bb'*32)
            instance = object.__new__(bundler.Bundler); instance.db=store; instance.entry_point='0x'+'ee'*20
            event = {'address':instance.entry_point, 'topics':[bundler.USER_OP_EVENT, h, '0x'+'00'*12+sender[2:], '0x'+'00'*32],
                     'data':'0x'+(3).to_bytes(32,'big').hex()+('00'*31+'00')+(123).to_bytes(32,'big').hex()+(456).to_bytes(32,'big').hex()}
            class Rpc:
                def call(self, method, params):
                    if method == 'eth_getTransactionReceipt': return {'blockNumber':'0x9','blockHash':'0xabc','status':'0x1','logs':[event]}
                    if method == 'eth_getBlockByNumber': return {'hash':'0xabc'}
                    raise AssertionError(method)
            instance.rpc=Rpc()
            receipt=instance.receipt(h)
            self.assertFalse(receipt['success'])
            self.assertEqual(receipt['actualGasCost'], hex(123))
            self.assertEqual(receipt['actualGasUsed'], hex(456))
            store.close()


if __name__ == '__main__': unittest.main()
