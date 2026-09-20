#!/usr/bin/env python3
import importlib.util
import json
import tempfile
import threading
import urllib.request
import unittest
from unittest.mock import patch
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

    def test_get_user_op_hash_uses_dynamic_tuple_head(self):
        data = bundler.get_user_op_hash_data(op())
        # Function selector then ABI head offset to the dynamic PackedUserOperation.
        self.assertEqual(int(data[10:74], 16), 32)
        self.assertEqual(data[74+24:74+64], '11'*20)

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

    def test_threaded_http_receipt_can_use_the_durable_sqlite_store(self):
        with tempfile.TemporaryDirectory() as directory:
            store = bundler.Store(Path(directory) / 'thread.sqlite')
            h = '0x' + 'aa' * 32
            class Fixture:
                entry_point = '0x' + 'ee' * 20
                db = store
                def receipt(self, op_hash):
                    self.db.get(op_hash)
                    return None
            bundler.Handler.bundler = Fixture()
            server = bundler.http.server.ThreadingHTTPServer(('127.0.0.1', 0), bundler.Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            try:
                request = urllib.request.Request('http://127.0.0.1:%s' % server.server_port,
                    json.dumps({'jsonrpc':'2.0','id':1,'method':'eth_getUserOperationReceipt','params':[h]}).encode(),
                    {'Content-Type':'application/json'})
                with urllib.request.urlopen(request, timeout=3) as response:
                    self.assertIsNone(json.load(response)['result'])
            finally:
                server.shutdown(); server.server_close(); thread.join(timeout=3); store.close()

    def test_authenticated_namespace_binds_genesis_and_published_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            entry, factory, vault, operator = ('0x'+'11'*20, '0x'+'22'*20, '0x'+'33'*20, '0x'+'44'*20)
            h1, h2 = '0x'+'aa'*32, '0x'+'bb'*32
            addresses = Path(directory)/'addresses.json'; addresses.write_text(json.dumps({'factory':vault, 'execution':{'entryPoint':entry, 'factory':factory, 'executor':operator, 'entryPointCodeHash':h1, 'factoryCodeHash':h2}}))
            args=type('A', (), {'rpc_url':'http://127.0.0.1:1','state_db':str(Path(directory)/'b.sqlite'),'sender':'0x'+'55'*20,'addresses':str(addresses),'port':19790})()
            instance=bundler.Bundler(args)
            class Rpc:
                genesis='0xgenesis'
                def call(self, method, params):
                    if method == 'eth_chainId': return '0x7a69'
                    if method == 'web3_clientVersion': return 'anvil/test'
                    if method == 'eth_accounts': return [args.sender]
                    if method == 'eth_getBlockByNumber': return {'hash':self.genesis if params[0] == '0x0' else '0xdeployment'}
                    if method == 'eth_getLogs': return [{'blockNumber':'0x1'}]
                    if method == 'eth_call': return '0x'+'00'*12+(entry if params[0]['data'].endswith(bundler.selector('entryPoint()').hex()) else vault)[2:]
                    raise AssertionError(method)
            instance.rpc=Rpc()
            with patch.object(instance, 'runtime_hash', side_effect=lambda target: h1 if target == entry else h2):
                instance.authenticate()
                instance.rpc.genesis='0xchanged'
                with self.assertRaisesRegex(bundler.BundlerError, 'state_namespace_mismatch'): instance.authenticate()
            instance.db.close()

    def test_bundler_rejects_the_execution_operator_as_its_funding_sender(self):
        with tempfile.TemporaryDirectory() as directory:
            entry, factory, vault, operator = ('0x'+'11'*20, '0x'+'22'*20, '0x'+'33'*20, '0x'+'44'*20)
            addresses = Path(directory)/'addresses.json'; addresses.write_text(json.dumps({'factory':vault, 'execution':{'entryPoint':entry, 'factory':factory, 'executor':operator, 'entryPointCodeHash':'0x'+'aa'*32, 'factoryCodeHash':'0x'+'bb'*32}}))
            args=type('A', (), {'rpc_url':'http://127.0.0.1:1','state_db':str(Path(directory)/'b.sqlite'),'sender':operator,'addresses':str(addresses),'port':19790})()
            instance=bundler.Bundler(args)
            class Rpc:
                def call(self, method, params):
                    if method == 'eth_chainId': return '0x7a69'
                    if method == 'web3_clientVersion': return 'anvil/test'
                    if method == 'eth_accounts': return [operator]
                    raise AssertionError(method)
            instance.rpc=Rpc()
            with self.assertRaisesRegex(bundler.BundlerError, 'must_differ'): instance.authenticate()
            instance.db.close()

    def test_concurrent_http_submissions_reserve_one_external_transaction(self):
        with tempfile.TemporaryDirectory() as directory:
            store=bundler.Store(Path(directory)/'concurrent.sqlite'); h='0x'+'aa'*32; sent=[]; gate=threading.Lock()
            instance=object.__new__(bundler.Bundler); instance.db=store; instance.entry_point='0x'+'ee'*20; instance.sender='0x'+'ff'*20
            instance.authenticate=lambda: None; instance.validate=lambda item: (item, '0x1234', '0x100')
            class Rpc:
                def call(self, method, params):
                    if method == 'eth_call': return h
                    if method == 'eth_sendTransaction':
                        with gate: sent.append(params[0])
                        return '0x'+'bb'*32
                    raise AssertionError(method)
            instance.rpc=Rpc(); bundler.Handler.bundler=instance
            server=bundler.http.server.ThreadingHTTPServer(('127.0.0.1', 0), bundler.Handler); serve=threading.Thread(target=server.serve_forever, daemon=True); serve.start()
            payload=json.dumps({'jsonrpc':'2.0','id':1,'method':'eth_sendUserOperation','params':[op(), instance.entry_point]}).encode()
            def submit():
                request=urllib.request.Request('http://127.0.0.1:%s' % server.server_port, payload, {'Content-Type':'application/json'})
                with urllib.request.urlopen(request, timeout=3): pass
            first=threading.Thread(target=submit); second=threading.Thread(target=submit); first.start(); second.start(); first.join(3); second.join(3)
            try: self.assertEqual(len(sent), 1)
            finally: server.shutdown(); server.server_close(); serve.join(3); store.close()


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

    def test_confirmed_receipt_disappearance_is_a_reorg_halt(self):
        with tempfile.TemporaryDirectory() as directory:
            h, sender = '0x'+'aa'*32, '0x'+'11'*20
            store = bundler.Store(Path(directory) / 'b.sqlite'); store.intent(h, sender, 3, '{}'); store.sent(h, '0x'+'bb'*32); store.receipt(h, '0x9', '0xabc')
            instance = object.__new__(bundler.Bundler); instance.db=store; instance.entry_point='0x'+'ee'*20
            class Rpc:
                def call(self, method, params):
                    if method == 'eth_getBlockByNumber': return {'hash':'0xabc'}
                    if method == 'eth_getTransactionReceipt': return None
                    raise AssertionError(method)
            instance.rpc=Rpc()
            with self.assertRaisesRegex(bundler.BundlerError, 'receipt_reorg_pause'): instance.receipt(h)
            store.close()


if __name__ == '__main__': unittest.main()
