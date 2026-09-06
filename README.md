# EquiVaults contracts

Non-custodial, non-upgradeable basket vaults with non-transferable shares, explicit
`enter` / `exit` execution constraints, configurable trust modes, and permissionless rebalancing.
This is a development protocol, not an audited production deployment. Yield strategies are
not implemented in V1.

## Verification

Foundry 1.7.1, Solidity 0.8.30, pinned Git submodules, optimizer and via-IR:

```sh
git submodule update --init --recursive
forge build --sizes
forge test --offline --no-match-contract ForkRobinhoodTest
forge test --match-contract ForkRobinhoodTest
FOUNDRY_PROFILE=release forge test --match-contract 'EquiVaultInvariantTest|ProtocolStressInvariantTest'
bash script/check-artifacts.sh
```

The ordinary CI suite is offline after installing the compiler and dependencies.
Fork verification requires `ROBINHOOD_RPC_URL` or the configured public Robinhood endpoint.
It exercises real USDG, but basket tokens, oracles and swap routes remain mocks; it does not
prove production DEX integration or reimbursement of actual L2 transaction costs.

## Local integration

Start a fresh default Anvil instance, then deploy and export actual broadcast receipts:

```sh
anvil --chain-id 31337
# In another terminal:
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 \
  --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --slow
python3 script/export-addresses.py
```

Only the documented Anvil accounts are used; no private key is required.
Clients consume `abi/`, `deployments/manifest.json` and per-chain address files.
`executeReallocation` now requires `(expectedProposalId, deadline, sellMinOuts, buyMinOuts)`;
`executeParameterUpdate` requires `(expectedProposalId, deadline)`. Regenerate and consume the
published ABI before calling either execution path. Existing non-upgradeable deployments retain
the previous signatures and cannot gain this execution-consent protection by changing source.
`script/export-artifacts.sh` refuses uncommitted source so the manifest's commit cannot
misrepresent the compiled contracts. Commit reviewed source before publishing a new manifest.
## Economic and operational limits

- Performance fees sell proportional token slices rounded down. Uncollectable fractional
  token fees are forgiven instead of charging more than the configured share of realized gain.
- Rebalance reimbursement is the minimum of measured gas conversion, the absolute cap,
  available settlement and sell proceeds times the collective slippage tolerance. It cannot
  consume the buy leg of a small vault or grow from settlement donations.
- Registry administrators attest token and route compatibility. Real oracle adapters, liquid
  DEX routes, testnet validation and external audit are required before production use.
- Oracle failure can block withdrawals even when tokens are requested; there is no oracle-free
  emergency exit in the current API.
