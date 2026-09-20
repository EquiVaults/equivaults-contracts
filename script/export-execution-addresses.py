#!/usr/bin/env python3
"""Attach a receipt-verified local execution deployment to an existing vault catalog."""
import argparse
import importlib.util
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("address_export", ROOT / "script/export-addresses.py")
export = importlib.util.module_from_spec(spec)
spec.loader.exec_module(export)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rpc-url', required=True)
    parser.add_argument('--catalog', required=True)
    parser.add_argument('--executor', required=True)
    args = parser.parse_args()
    export.require_local_anvil(args.rpc_url)
    if not export.ADDR_RE.fullmatch(args.executor) or int(args.executor, 16) == 0:
        parser.error('A nonzero local operator address is required.')
    source = export.prepare_artifact_verification()
    path = export.output_file(args.catalog)
    catalog = json.loads(path.read_text())
    if catalog.get('chainId') != 31337:
        parser.error('Existing catalog must be Anvil 31337.')
    export.verify_compiled_runtime(args.rpc_url, 'VaultFactory', catalog['factory'])
    run = json.loads((ROOT / 'broadcast/DeployExecutionLocal.s.sol/31337/run-latest.json').read_text())
    contracts = {}
    for tx in run.get('transactions', []):
        name = tx.get('contractName')
        if name not in ('EntryPoint', 'InvestmentExecutionFactory') or tx.get('transactionType') not in ('CREATE', 'CREATE2'):
            continue
        if name in contracts:
            parser.error(f'Duplicate deployment: {name}')
        receipt = export.rpc_call(args.rpc_url, 'eth_getTransactionReceipt', [tx['hash']])
        if not receipt or receipt['status'] != '0x1' or receipt['contractAddress'].lower() != tx['contractAddress'].lower():
            parser.error(f'Unverified creation: {name}')
        contracts[name] = tx['contractAddress']
        export.verify_compiled_runtime(args.rpc_url, name, tx['contractAddress'])
    if set(contracts) != {'EntryPoint', 'InvestmentExecutionFactory'}:
        parser.error('Expected exactly one EntryPoint and execution factory deployment.')
    factory = contracts['InvestmentExecutionFactory']
    for method, expected in [('entryPoint()', contracts['EntryPoint']), ('vaultFactory()', catalog['factory'])]:
        selector = subprocess.check_output(['cast', 'sig', method], text=True).strip()
        if export.call_address(args.rpc_url, factory, selector).lower() != expected.lower():
            parser.error(f'Execution factory {method} binding mismatch.')
    catalog['execution'] = {
        'version': 1, 'entryPoint': contracts['EntryPoint'], 'factory': factory,
        'executor': args.executor,
        'entryPointCodeHash': export.runtime_code_hash(args.rpc_url, contracts['EntryPoint']),
        'factoryCodeHash': export.runtime_code_hash(args.rpc_url, factory),
    }
    primary = next(item for item in catalog['factories'] if item['address'].lower() == catalog['factory'].lower())
    if primary['codeHash'].lower() != export.runtime_code_hash(args.rpc_url, catalog['factory']):
        parser.error('Existing primary factory code changed.')
    primary['contractsCommit'] = source
    # Atomically replace only after all receipts, compiled runtimes and bindings agree.
    temporary = path.with_suffix('.json.tmp')
    temporary.write_text(json.dumps(catalog, indent=2) + '\n')
    temporary.replace(path)
    print(f'Updated execution deployment in {path}')


if __name__ == '__main__':
    main()
