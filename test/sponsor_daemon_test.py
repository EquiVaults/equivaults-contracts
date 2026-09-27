import importlib.util, json, subprocess, tempfile, unittest
from pathlib import Path
from io import BytesIO
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('sponsor', Path(__file__).parents[1] / 'script/sponsor-daemon.py')
sponsor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sponsor)


class CalldataEncodingTests(unittest.TestCase):
    def test_static_hot_path_does_not_spawn_cast(self):
        with patch.object(sponsor.subprocess, 'check_output', side_effect=AssertionError('cast must not run')):
            self.assertEqual(
                sponsor.calldata('integrate(uint256,uint256)', 1, 2),
                '0x55c59be7' + f'{1:064x}{2:064x}',
            )

    def test_static_hot_path_encodings_match_cast(self):
        address = '0x1234567890abcdef1234567890ABCDEF12345678'
        for signature, (_, kinds) in sponsor.STATIC_ABI.items():
            with self.subTest(signature=signature):
                values = tuple(address if kind == 'address' else 2 ** int(kind[4:]) - 1 for kind in kinds)
                expected = subprocess.check_output(['cast', 'calldata', signature, *map(str, values)], text=True, timeout=10).strip()
                self.assertEqual(sponsor.calldata(signature, *values), expected)

    def test_noncanonical_static_values_and_dynamic_abi_fall_back_to_cast(self):
        cases = (
            ('integrate(uint256,uint256)', ('1', 2)),
            ('integrate(uint256,uint256)', (2 ** 256, 2)),
            ('positions(uint256,address)', (1, 'not-an-address')),
            ('previewInvestment(uint256[])', ('[1,2]',)),
        )
        for signature, values in cases:
            with self.subTest(signature=signature, values=values), patch.object(sponsor.subprocess, 'check_output', return_value='0xfallback\n') as encoded:
                self.assertEqual(sponsor.calldata(signature, *values), '0xfallback')
                self.assertEqual(encoded.call_args.args[0], ['cast', 'calldata', signature, *map(str, values)])

    def test_runtime_hash_cache_is_keyed_by_returned_code_content(self):
        sponsor._CODE_HASHES.clear()
        with patch.object(sponsor.subprocess, 'check_output', return_value='0xhash\n') as hashed:
            self.assertEqual(sponsor.hash_code('0xAbCd'), '0xhash')
            self.assertEqual(sponsor.hash_code('0xabcd'), '0xhash')
            self.assertEqual(hashed.call_count, 1)
            self.assertEqual(sponsor.hash_code('0xdead'), '0xhash')
            self.assertEqual(hashed.call_count, 2)
        sponsor._CODE_HASHES.clear()

class StoreTests(unittest.TestCase):

    def test_restart_revert_and_reserve(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 's.db'
            db = sponsor.Store(p)
            db.reserve(1, 99, {'x': 1})
            db.sent(1, '0x' + '1' * 64)
            db.close()
            db = sponsor.Store(p)
            self.assertEqual(db.inflight()[0][1], '0x' + '1' * 64)
            db.settle(1, 23, 'reverted', '0x2', '0xabc')
            self.assertEqual(db.spent(), 23)
            self.assertEqual(db.reserved(), 0)
            db.close()

    def test_lock_and_failure_backoff(self):
        with tempfile.TemporaryDirectory() as d:
            db = sponsor.Store(Path(d) / 's.db')
            self.assertEqual(db.fail('x', 10), 1)
            self.assertFalse(db.ready('x'))
            with self.assertRaises(RuntimeError):
                sponsor.Store(Path(d) / 's.db')
            db.close()

class ReconcileTests(unittest.TestCase):

    def make(self, d):
        a = type('A', (), {'rpc_url': 'http://127.0.0.1:18545', 'sender': '0x0000000000000000000000000000000000000001', 'state_db': str(Path(d) / 's.db'), 'budget_wei': 100, 'status_port': 18789})()
        return sponsor.Sponsor(a)

    def test_unknown_intent_and_orphan_canonical_pause(self):
        with tempfile.TemporaryDirectory() as d:
            s = self.make(d)
            s.db.reserve(1, 1, {})
            s.rpc.call = lambda *x: None
            try:
                with self.assertRaisesRegex(RuntimeError, 'unknown_intent'):
                    s.reconcile()
            finally:
                s.db.close()

    def test_confirmed_receipt_reorg_halts_persistently_after_restart(self):
        with tempfile.TemporaryDirectory() as d:
            s = self.make(d)
            s.db.reserve(1, 99, {})
            s.db.sent(1, '0x' + '1' * 64)

            def canonical(method, params):
                if method == 'eth_getTransactionReceipt':
                    return {'status': '0x1', 'blockNumber': '0x2', 'blockHash': '0xgood', 'gasUsed': '0x1', 'effectiveGasPrice': '0x1'}
                if method == 'eth_getBlockByNumber':
                    return {'hash': '0xgood'}
                raise AssertionError(method)

            s.rpc.call = canonical
            s.reconcile()
            self.assertEqual(s.db.spent(), 1)

            def reorged(method, params):
                if method == 'eth_getBlockByNumber':
                    return {'hash': '0xreorged'}
                raise AssertionError(method)

            s.rpc.call = reorged
            try:
                with self.assertRaisesRegex(sponsor.Pause, 'receipt_reorg_pause'):
                    s.reconcile()
                self.assertEqual(s.db.value('halt'), 'receipt_reorg_pause')
            finally:
                s.db.close()

            restarted = self.make(d)
            restarted.rpc.call = reorged
            try:
                with self.assertRaisesRegex(sponsor.Pause, 'receipt_reorg_pause'):
                    restarted.reconcile()
            finally:
                restarted.db.close()

    def test_large_confirmed_ledger_checks_only_latest_anchor(self):
        with tempfile.TemporaryDirectory() as d:
            s = self.make(d)
            latest_number = hex(1000)
            with s.db.db:
                for nonce in range(1000):
                    s.db.db.execute(
                        'insert into tx values(?,?,?,?,?,?,?,?)',
                        (str(nonce), '0x' + f'{nonce:064x}', 'mined', '1', '1', hex(nonce + 1), '0xlatest', '{}'),
                    )
            block_calls = []

            def canonical(method, params):
                self.assertEqual(method, 'eth_getBlockByNumber')
                block_calls.append(params)
                return {'hash': '0xlatest'}

            s.rpc.call = canonical
            try:
                s.reconcile()
                self.assertEqual(block_calls, [[latest_number, False]])

                block_calls.clear()
                def reorged(method, params):
                    self.assertEqual(method, 'eth_getBlockByNumber')
                    block_calls.append(params)
                    return {'hash': '0xreorged'}

                s.rpc.call = reorged
                with self.assertRaisesRegex(sponsor.Pause, 'receipt_reorg_pause'):
                    s.reconcile()
                self.assertEqual(block_calls, [[latest_number, False]])
                self.assertEqual(s.db.value('halt'), 'receipt_reorg_pause')
            finally:
                s.db.close()
        with tempfile.TemporaryDirectory() as d:
            s = self.make(d)
            s.db.reserve(1, 1, {})
            s.db.sent(1, '0x' + '1' * 64)
            s.rpc.call = lambda m, p: {'status': '0x1', 'blockNumber': '0x2', 'blockHash': '0xold', 'gasUsed': '0x1', 'effectiveGasPrice': '0x1'} if m == 'eth_getTransactionReceipt' else {'hash': '0xnew'}
            try:
                with self.assertRaisesRegex(RuntimeError, 'reorg'):
                    s.reconcile()
            finally:
                s.db.close()

class StatusTests(unittest.TestCase):

    def test_query_is_scoped_and_bounded(self):
        st = sponsor.Status(1, '0x0000000000000000000000000000000000000001')
        st.request({'escrow': '0x0000000000000000000000000000000000000002', 'requestId': '1'})
        st.publish()
        self.assertIsNone(json.loads(st.render())['request'])
        self.assertEqual(json.loads(st.render('0x0000000000000000000000000000000000000002', '1'))['request']['requestId'], '1')
        self.assertLess(len(st.render()), 65536)

class FakeRpc:
    factory = '0x00000000000000000000000000000000000000f1'
    vault = '0x00000000000000000000000000000000000000a1'
    escrow = '0x00000000000000000000000000000000000000e1'
    registry = '0x00000000000000000000000000000000000000b1'
    settlement = '0x00000000000000000000000000000000000000c1'

    def __init__(self):
        self.sent = []
        self.receipt_calls = 0
        self.pending_hash = None
        self.nonce = 0

    def uint(self, target, signature, block, *args):
        if signature == 'vaultCount()':
            return 1
        if signature == 'isVault(address)':
            return 1
        if signature == 'protocolVersion()':
            return 2
        if signature == 'nextRequestId()':
            return 71
        if signature == 'maxFillAmount(uint256,uint256)':
            return 10
        raise AssertionError(signature)

    def address(self, target, signature, block, *args):
        return {(self.factory, 'vaults(uint256)'): self.vault, (self.factory, 'registry()'): self.registry, (self.factory, 'settlementAsset()'): self.settlement, (self.vault, 'registry()'): self.registry, (self.vault, 'settlementAsset()'): self.settlement, (self.vault, 'investmentEscrow()'): self.escrow, (self.escrow, 'vault()'): self.vault, (self.escrow, 'registry()'): self.registry, (self.escrow, 'settlement()'): self.settlement}[target, signature]

    def read(self, target, data, block):
        if target == self.escrow and data.startswith('0xc58343ef'):
            words = ['0' * 64 for _ in range(10)]
            words[5] = f'{10:064x}'
            return '0x' + ''.join(words)
        if target == self.escrow and data.startswith('0x') and (len(data) == 74):
            return '0x' + f'{32:064x}{2:064x}{209:064x}{210:064x}'
        if target == self.escrow:
            return '0x' + '0' * 128
        if target == self.vault and len(data) == 10:
            return '0x' + '0' * 64
        if target == self.vault:
            return '0x' + '0' * 128
        raise AssertionError((target, data))

    def call(self, method, params):
        if method == 'eth_getBlockByNumber':
            return {'number': params[0] if params[0] != 'latest' else '0x10', 'hash': '0xmine' if params[0] == '0x11' else '0xblock', 'timestamp': '0x20'}
        if method == 'eth_getCode':
            return '0x6000'
        if method == 'eth_getTransactionCount':
            return hex(self.nonce)
        if method == 'eth_gasPrice':
            return '0x2'
        if method == 'eth_estimateGas':
            return '0x10'
        if method == 'eth_getBalance':
            return '0x100000'
        if method == 'eth_call':
            return '0x'
        if method == 'eth_sendTransaction':
            self.sent.append(params[0])
            self.pending_hash = '0x' + 'a' * 64
            return self.pending_hash
        if method == 'eth_getTransactionReceipt':
            self.receipt_calls += 1
            return {'status': '0x1', 'blockNumber': '0x11', 'blockHash': '0xmine', 'gasUsed': '0x3', 'effectiveGasPrice': '0x2'}
        raise AssertionError(method)

class CycleTests(unittest.TestCase):

    def args(self, directory):
        return type('Args', (), {'rpc_url': 'http://127.0.0.1:18545', 'sender': '0x0000000000000000000000000000000000000001', 'state_db': str(Path(directory) / 'state.sqlite'), 'budget_wei': 10 ** 9, 'status_port': 18789, 'max_fill': 10, 'max_gas': 100, 'max_gas_price': 10, 'gas_buffer': 1, 'scan_vaults': 1, 'scan_requests': 1, 'max_failed_attempts': 5, 'backoff': 1})()

    def test_round_robin_past_page_and_reconcile_before_next_send(self):
        with tempfile.TemporaryDirectory() as directory:
            daemon = sponsor.Sponsor(self.args(directory))
            fake = FakeRpc()
            daemon.rpc = fake
            daemon.factory = fake.factory
            daemon.cursor_request[fake.escrow] = 65
            daemon.cycle()
            self.assertEqual(len(fake.sent), 1)
            self.assertEqual(daemon.cursor_request[fake.escrow], 66)
            fake.pending_hash = None
            fake.nonce = 1
            daemon.cycle()
            self.assertGreaterEqual(fake.receipt_calls, 1)
            self.assertEqual(len(fake.sent), 2)
            self.assertEqual(len(daemon.db.inflight()), 1)
            self.assertEqual(daemon.db.spent(), 6)
            daemon.db.close()

    def test_budget_fee_cap_and_low_balance_prevent_send(self):
        with tempfile.TemporaryDirectory() as directory:
            daemon = sponsor.Sponsor(self.args(directory))
            fake = FakeRpc()
            daemon.rpc = fake
            daemon.a.max_gas_price = 1
            with self.assertRaisesRegex(RuntimeError, 'gas_price_cap'):
                daemon.send(fake.escrow, '0x00', {})
            daemon.a.max_gas_price = 10
            fake.call = lambda method, params: '0x0' if method == 'eth_getTransactionCount' else '0x2' if method == 'eth_gasPrice' else '0x10' if method == 'eth_estimateGas' else '0x0' if method == 'eth_getBalance' else '0x'
            with self.assertRaisesRegex(RuntimeError, 'sponsor_balance'):
                daemon.send(fake.escrow, '0x00', {})
            daemon.db.close()

    def test_escrow_version_mismatch_and_gas_or_budget_bounds_do_not_send(self):
        with tempfile.TemporaryDirectory() as directory:
            daemon = sponsor.Sponsor(self.args(directory))
            fake = FakeRpc()
            daemon.rpc = fake
            daemon.factory = fake.factory
            original_uint = fake.uint
            original_address = fake.address

            def mismatched_binding(target, signature, block, *args):
                if target == fake.escrow and signature == 'vault()':
                    return '0x00000000000000000000000000000000000000ff'
                return original_address(target, signature, block, *args)
            fake.address = mismatched_binding
            daemon.cycle()
            self.assertEqual(fake.sent, [])
            fake.address = original_address

            def mismatched_version(target, signature, block, *args):
                if target == fake.escrow and signature == 'protocolVersion()':
                    return 1
                return original_uint(target, signature, block, *args)
            fake.uint = mismatched_version
            daemon.cycle()
            self.assertEqual(fake.sent, [])
            fake.uint = original_uint
            daemon.a.max_gas = 16
            with self.assertRaisesRegex(RuntimeError, 'gas_cap_pause'):
                daemon.send(fake.escrow, '0x00', {})
            self.assertEqual(fake.sent, [])
            daemon.a.max_gas = 100
            daemon.a.budget_wei = -1
            with self.assertRaisesRegex(RuntimeError, 'budget_pause'):
                daemon.send(fake.escrow, '0x00', {})
            self.assertEqual(fake.sent, [])
            daemon.db.close()

    def test_pending_receipt_does_not_resend_and_then_confirms(self):
        with tempfile.TemporaryDirectory() as directory:
            daemon = sponsor.Sponsor(self.args(directory))
            fake = FakeRpc()
            daemon.rpc = fake
            daemon.send(fake.escrow, '0x00', {'key': 'known-pending'})
            sent_before_pending = len(fake.sent)
            original_call = fake.call

            def pending_receipt(method, params):
                if method == 'eth_getTransactionReceipt':
                    fake.receipt_calls += 1
                    return None
                return original_call(method, params)

            fake.call = pending_receipt
            try:
                with self.assertRaisesRegex(sponsor.Pause, 'pending_receipt_pause'):
                    daemon.reconcile()
                self.assertEqual(len(fake.sent), sent_before_pending)
            finally:
                fake.call = original_call

            daemon.reconcile()
            self.assertEqual(len(fake.sent), sent_before_pending)
            self.assertEqual(daemon.db.spent(), 6)
            daemon.db.close()

    def test_lost_send_response_keeps_durable_intent_and_never_retries(self):
        with tempfile.TemporaryDirectory() as directory:
            args = self.args(directory)
            daemon = sponsor.Sponsor(args)
            fake = FakeRpc()
            attempts = []
            original_call = fake.call

            def lost_response(method, params):
                if method == 'eth_sendTransaction':
                    attempts.append(params[0])
                    raise sponsor.RpcTransportError('response_lost')
                return original_call(method, params)

            fake.call = lost_response
            daemon.rpc = fake
            try:
                with self.assertRaisesRegex(sponsor.Pause, 'unknown_intent_pause'):
                    daemon.send(fake.escrow, '0x00', {'key': 'lost-send'})
                self.assertEqual(len(attempts), 1)
                nonce, tx_hash, reserved = daemon.db.inflight()[0]
                self.assertEqual((nonce, tx_hash), ('0', None))
                self.assertGreater(int(reserved), 0)
            finally:
                daemon.db.close()

            restarted = sponsor.Sponsor(args)
            restarted.rpc = FakeRpc()
            try:
                with self.assertRaisesRegex(sponsor.Pause, 'unknown_intent_pause'):
                    restarted.reconcile()
                self.assertEqual(len(restarted.rpc.sent), 0)
            finally:
                restarted.db.close()

    def test_preview_revert_falls_back_to_a_real_fill(self):
        with tempfile.TemporaryDirectory() as directory:
            daemon = sponsor.Sponsor(self.args(directory))
            fake = FakeRpc()
            daemon.rpc = fake
            original_read = fake.read

            def preview_reverts(target, data, block):
                if target == fake.vault and len(data) != 10:
                    raise sponsor.RpcExecutionError('preview_unavailable')
                return original_read(target, data, block)

            fake.read = preview_reverts
            try:
                self.assertTrue(daemon.try_request(fake.vault, fake.escrow, 1, '0x10', {'timestamp': '0x20', 'hash': '0xblock'}))
                self.assertEqual(len(fake.sent), 1)
            finally:
                daemon.db.close()

    def test_residual_assets_are_not_diagnosed_as_market_wait_and_can_resume(self):
        for preview_reverts in (False, True):
            with self.subTest(preview_reverts=preview_reverts), tempfile.TemporaryDirectory() as directory:
                daemon = sponsor.Sponsor(self.args(directory))
                fake = FakeRpc()
                daemon.rpc = fake
                original_read, original_uint = fake.read, fake.uint
                integrable = False

                def residual_read(target, data, block):
                    if target == fake.escrow and data.startswith('0xc58343ef'):
                        words = [original_read(target, data, block)[2:][i:i+64] for i in range(0, 640, 64)]
                        words[5] = '0' * 64  # No unspent settlement.
                        return '0x' + ''.join(words)
                    if target == fake.escrow and len(data) > 74:
                        return '0x' + f'{5:064x}{2:064x}'  # Personal token residue.
                    if target == fake.vault and len(data) != 10:
                        if integrable:
                            return '0x' + f'{1:064x}'
                        if preview_reverts:
                            raise sponsor.RpcExecutionError('tranche_rejected')
                    return original_read(target, data, block)

                def no_pointless_fill_read(target, signature, block, *args):
                    if signature == 'maxFillAmount(uint256,uint256)':
                        self.fail('No settlement: route health cannot enable a purchase')
                    return original_uint(target, signature, block, *args)

                fake.read, fake.uint = residual_read, no_pointless_fill_read
                try:
                    self.assertFalse(daemon.try_request(fake.vault, fake.escrow, 1, '0x10', {'timestamp': '0x20', 'hash': '0xblock'}))
                    item = daemon.status.requests[fake.escrow, '1']
                    self.assertEqual((item['state'], item['reason']), ('no_admissible_action', 'no_admissible_action'))
                    self.assertEqual(fake.sent, [])
                    self.assertEqual((daemon.db.spent(), daemon.db.reserved()), (0, 0))
                    # The diagnosis is temporary, not a terminal state or automatic recovery.
                    integrable = True
                    self.assertTrue(daemon.try_request(fake.vault, fake.escrow, 1, '0x10', {'timestamp': '0x20', 'hash': '0xblock'}))
                    self.assertEqual(fake.sent[0]['data'], sponsor.calldata('integrate(uint256,uint256)', 1, 0))
                finally:
                    daemon.db.close()

    def test_zero_fill_bounds_do_not_imply_a_market_cause(self):
        with tempfile.TemporaryDirectory() as directory:
            daemon = sponsor.Sponsor(self.args(directory))
            fake = FakeRpc()
            daemon.rpc = fake
            original = fake.uint
            fake.uint = lambda target, signature, block, *args: 0 if signature == 'maxFillAmount(uint256,uint256)' else original(target, signature, block, *args)
            try:
                self.assertFalse(daemon.try_request(fake.vault, fake.escrow, 1, '0x10', {'timestamp': '0x20', 'hash': '0xblock'}))
                self.assertEqual(daemon.status.requests[fake.escrow, '1']['state'], 'no_admissible_action')
                self.assertEqual(fake.sent, [])
            finally:
                daemon.db.close()

    def test_unreadable_preview_is_operator_uncertainty_not_a_residual_diagnosis(self):
        with tempfile.TemporaryDirectory() as directory:
            daemon = sponsor.Sponsor(self.args(directory))
            fake = FakeRpc()
            daemon.rpc = fake
            original = fake.read
            def unreadable(target, data, block):
                if target == fake.vault and len(data) != 10:
                    raise sponsor.RpcTransportError('rpc_transport')
                return original(target, data, block)
            fake.read = unreadable
            try:
                with self.assertRaises(sponsor.RpcTransportError):
                    daemon.try_request(fake.vault, fake.escrow, 1, '0x10', {'timestamp': '0x20', 'hash': '0xblock'})
                self.assertEqual(daemon.status.requests[fake.escrow, '1']['state'], 'waiting_operator')
                self.assertEqual(fake.sent, [])
            finally:
                daemon.db.close()

    def test_json_rpc_provider_errors_are_not_evm_rejections_or_residual_evidence(self):
        errors = [
            {'code': -32603, 'message': 'internal error'},
            {'code': -32000, 'message': 'historical state unavailable'},
            {'code': 3, 'message': 'execution reverted', 'data': 'malformed'},
            {'code': 3, 'message': 'execution reverted', 'data': '0x'},
        ]
        for error in errors:
            with self.subTest(error=error), tempfile.TemporaryDirectory() as directory:
                daemon = sponsor.Sponsor(self.args(directory))
                fake = FakeRpc()
                daemon.rpc = fake
                original = fake.read
                transport = sponsor.Rpc(daemon.a.rpc_url)
                def read(target, data, block):
                    if target == fake.escrow and data.startswith('0xc58343ef'):
                        raw = original(target, data, block)[2:]
                        return '0x' + raw[:5*64] + '0'*64 + raw[6*64:]
                    if target == fake.vault and len(data) != 10:
                        # Exercise actual JSON-RPC decoding, not a preclassified exception.
                        return transport.read(target, data, block)
                    return original(target, data, block)
                fake.read = read
                try:
                    with patch.object(transport.http, 'open', return_value=BytesIO(json.dumps({'jsonrpc': '2.0', 'id': 1, 'error': error}).encode())):
                        if error.get('data') == '0x':
                            self.assertFalse(daemon.try_request(fake.vault, fake.escrow, 1, '0x10', {'timestamp': '0x20', 'hash': '0xblock'}))
                            expected = 'no_admissible_action'
                        else:
                            with self.assertRaises(sponsor.RpcTransportError):
                                daemon.try_request(fake.vault, fake.escrow, 1, '0x10', {'timestamp': '0x20', 'hash': '0xblock'})
                            expected = 'waiting_operator'
                        self.assertEqual(daemon.status.requests[fake.escrow, '1']['state'], expected)
                        self.assertEqual(fake.sent, [])
                        self.assertEqual(daemon.db.reserved(), 0)
                finally:
                    daemon.db.close()

    def test_snapshot_reorg_before_send_prevents_write(self):
        with tempfile.TemporaryDirectory() as directory:
            daemon = sponsor.Sponsor(self.args(directory))
            fake = FakeRpc()
            daemon.rpc = fake
            original_call = fake.call

            def reorged_snapshot(method, params):
                if method == 'eth_getBlockByNumber' and params[0] == '0x10':
                    return {'number': '0x10', 'hash': '0xreorged', 'timestamp': '0x20'}
                return original_call(method, params)

            fake.call = reorged_snapshot
            try:
                with self.assertRaisesRegex(sponsor.Pause, 'snapshot_reorg_pause'):
                    daemon.try_request(fake.vault, fake.escrow, 1, '0x10', {'hash': '0xblock', 'timestamp': '0x20'})
                self.assertEqual(fake.sent, [])
            finally:
                daemon.db.close()

    def test_simulation_rejection_for_one_request_does_not_starve_next_request(self):
        with tempfile.TemporaryDirectory() as directory:
            daemon = sponsor.Sponsor(self.args(directory))
            daemon.a.scan_requests = 2
            fake = FakeRpc()
            daemon.rpc = fake
            daemon.factory = fake.factory
            original_uint = fake.uint

            def first_request_rejects(target, signature, block, *args):
                if signature == 'maxFillAmount(uint256,uint256)' and args[0] == 1:
                    raise sponsor.RpcExecutionError('route_unavailable')
                return original_uint(target, signature, block, *args)

            fake.uint = first_request_rejects
            try:
                daemon.cycle()
                self.assertEqual(len(fake.sent), 1)
                rejected = daemon.status.requests[(fake.escrow, '1')]
                self.assertEqual(rejected['state'], 'waiting_market')
                self.assertEqual(rejected['reason'], 'onchain_execution_rejected')
                self.assertEqual(daemon.db.spent(), 0)
                self.assertEqual(daemon.db.failure(f"{fake.escrow}:1:0x{'0' * 64}:0"), 0)
            finally:
                daemon.db.close()

    def test_repeated_simulations_do_not_consume_broadcast_failure_cap(self):
        with tempfile.TemporaryDirectory() as directory:
            daemon = sponsor.Sponsor(self.args(directory))
            daemon.a.backoff = 0
            fake = FakeRpc()
            daemon.rpc = fake
            original_call = fake.call

            def rejected_estimate(method, params):
                if method == 'eth_estimateGas':
                    raise sponsor.RpcExecutionError('estimate_rejected')
                return original_call(method, params)

            fake.call = rejected_estimate
            version = '0x' + '0' * 64
            key = f'{fake.escrow}:1:{version}:0'
            try:
                for _ in range(7):
                    self.assertFalse(daemon.try_request(fake.vault, fake.escrow, 1, '0x10', {'timestamp': '0x20', 'hash': '0xblock'}))
                self.assertEqual(daemon.db.failure(key), 0)
                self.assertEqual(fake.sent, [])
            finally:
                daemon.db.close()

    def test_reverted_broadcasts_charge_budget_and_reach_failure_cap(self):
        with tempfile.TemporaryDirectory() as directory:
            daemon = sponsor.Sponsor(self.args(directory))
            daemon.a.backoff = 0
            daemon.a.max_failed_attempts = 2
            fake = FakeRpc()
            daemon.rpc = fake
            original_call = fake.call

            def reverted_receipt(method, params):
                if method == 'eth_getTransactionReceipt':
                    fake.receipt_calls += 1
                    return {'status': '0x0', 'blockNumber': '0x11', 'blockHash': '0xmine', 'gasUsed': '0x3', 'effectiveGasPrice': '0x2'}
                return original_call(method, params)

            fake.call = reverted_receipt
            version = '0x' + '0' * 64
            key = f'{fake.escrow}:1:{version}:0'
            try:
                for nonce in (1, 2):
                    self.assertTrue(daemon.try_request(fake.vault, fake.escrow, 1, '0x10', {'timestamp': '0x20', 'hash': '0xblock'}))
                    fake.nonce = nonce
                    daemon.reconcile()
                self.assertEqual(daemon.db.spent(), 12)
                self.assertEqual(daemon.db.failure(key), 2)
                self.assertFalse(daemon.try_request(fake.vault, fake.escrow, 1, '0x10', {'timestamp': '0x20', 'hash': '0xblock'}))
                self.assertEqual(len(fake.sent), 2)
            finally:
                daemon.db.close()

    def test_scheduler_cursors_survive_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            args = self.args(directory)
            daemon = sponsor.Sponsor(args)
            fake = FakeRpc()
            daemon.rpc = fake
            daemon.factory = fake.factory
            daemon.cursor_request[fake.escrow] = 65
            try:
                daemon.cycle()
                self.assertEqual(daemon.cursor_request[fake.escrow], 66)
            finally:
                daemon.db.close()

            restarted = sponsor.Sponsor(args)
            try:
                self.assertEqual(restarted.cursor_vault, 0)
                self.assertEqual(restarted.cursor_request[fake.escrow], 66)
            finally:
                restarted.db.close()

class AuthRpc:
    factory = '0x00000000000000000000000000000000000000f1'
    sender = '0x0000000000000000000000000000000000000001'

    def __init__(self, chain='0x7a69', client='anvil/v0.2.0', genesis='0xgenesis'):
        self.chain = chain
        self.client = client
        self.genesis = genesis

    def call(self, method, params):
        if method == 'eth_chainId':
            return self.chain
        if method == 'web3_clientVersion':
            return self.client
        if method == 'eth_accounts':
            return [self.sender]
        if method == 'eth_getCode':
            return '0x6000'
        if method == 'eth_getBlockByNumber':
            tag = params[0]
            if tag == '0x0':
                return {'number': '0x0', 'hash': self.genesis, 'timestamp': '0x1'}
            if tag == '0x5':
                return {'number': '0x5', 'hash': '0xdeployment', 'timestamp': '0x2'}
            return {'number': '0x6', 'hash': '0xlatest', 'timestamp': '0x3'}
        if method == 'eth_getLogs':
            return [{'blockNumber': '0x5', 'topics': [sponsor.VAULT_CREATED]}]
        raise AssertionError(method)

    def uint(self, target, signature, block, *args):
        self.last_uint = (target, signature, block)
        if target == self.factory and signature == 'protocolVersion()':
            return 2
        raise AssertionError((target, signature))

class AuthenticationTests(unittest.TestCase):
    code_hash = '0x' + 'a' * 64
    commit = 'b' * 40

    def args(self, directory, budget=100):
        addresses = Path(directory) / 'addresses.json'
        manifest = Path(directory) / 'manifest.json'
        addresses.write_text(json.dumps({'factory': AuthRpc.factory, 'factories': [{'address': AuthRpc.factory, 'protocolVersion': 2, 'codeHash': self.code_hash, 'contractsCommit': self.commit}]}))
        manifest.write_text(json.dumps({'contractsCommit': self.commit}))
        return type('Args', (), {'rpc_url': 'http://127.0.0.1:18545', 'sender': AuthRpc.sender, 'state_db': str(Path(directory) / 'state.sqlite'), 'budget_wei': budget, 'status_port': 18789, 'addresses': str(addresses), 'manifest': str(manifest)})()

    def authenticate(self, args, rpc):
        daemon = sponsor.Sponsor(args)
        daemon.rpc = rpc
        return daemon

    def test_rejects_wrong_chain_or_non_anvil_client(self):
        with tempfile.TemporaryDirectory() as directory:
            args = self.args(directory)
            daemon = self.authenticate(args, AuthRpc(chain='0x1'))
            try:
                with self.assertRaisesRegex(RuntimeError, 'anvil_31337_required'):
                    daemon.authenticate()
            finally:
                daemon.db.close()
        with tempfile.TemporaryDirectory() as directory:
            args = self.args(directory)
            daemon = self.authenticate(args, AuthRpc(client='geth/v1.0'))
            try:
                with self.assertRaisesRegex(RuntimeError, 'anvil_31337_required'):
                    daemon.authenticate()
            finally:
                daemon.db.close()

    def test_rejects_factory_catalog_and_runtime_code_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            args = self.args(directory)
            catalog = json.loads(Path(args.addresses).read_text())
            catalog['factories'][0]['address'] = '0x00000000000000000000000000000000000000f2'
            Path(args.addresses).write_text(json.dumps(catalog))
            daemon = self.authenticate(args, AuthRpc())
            try:
                with self.assertRaisesRegex(RuntimeError, 'factory_catalog_auth_failed'):
                    daemon.authenticate()
            finally:
                daemon.db.close()
        with tempfile.TemporaryDirectory() as directory:
            args = self.args(directory)
            daemon = self.authenticate(args, AuthRpc())
            try:
                with patch.object(sponsor, 'hash_code', return_value='0x' + '0' * 64):
                    with self.assertRaisesRegex(RuntimeError, 'factory_catalog_auth_failed'):
                        daemon.authenticate()
            finally:
                daemon.db.close()

    def test_persisted_namespace_binds_chain_history_and_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            args = self.args(directory, budget=100)
            daemon = self.authenticate(args, AuthRpc())
            try:
                with patch.object(sponsor, 'hash_code', return_value=self.code_hash):
                    daemon.authenticate()
            finally:
                daemon.db.close()
            changed_history = self.authenticate(args, AuthRpc(genesis='0xreset'))
            try:
                with patch.object(sponsor, 'hash_code', return_value=self.code_hash):
                    with self.assertRaisesRegex(RuntimeError, 'state_namespace_mismatch'):
                        changed_history.authenticate()
            finally:
                changed_history.db.close()
            changed_budget = self.args(directory, budget=101)
            changed_budget_daemon = self.authenticate(changed_budget, AuthRpc())
            try:
                with patch.object(sponsor, 'hash_code', return_value=self.code_hash):
                    with self.assertRaisesRegex(RuntimeError, 'state_namespace_mismatch'):
                        changed_budget_daemon.authenticate()
            finally:
                changed_budget_daemon.db.close()
if __name__ == '__main__':
    unittest.main()
