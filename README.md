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
`cancelReallocation` and `cancelParameterUpdate` each require `(expectedProposalId)`.
Only the manager can cancel. A missing, replaced or already processed proposal is rejected
without deleting a replacement. Cancellation has no deadline and never applies pending changes.
This is a breaking ABI change: old non-upgradeable vaults retain their previous cancellation
semantics and must not be treated as ID-guarded instances.
`script/export-artifacts.sh` refuses uncommitted source so the manifest's commit cannot
misrepresent the compiled contracts. Commit reviewed source before publishing a new manifest.

If local script execution stalls while resolving external Sourcify source labels, add
`--offline` to `forge script` after the pinned compiler and dependencies are installed.
This skips external source discovery, not the explicit Anvil RPC, broadcast or EIP-170 checks.

### Rich local demo fixture

The default command above remains the small deterministic fixture used by existing integration
tests. For a fresh, opt-in Anvil demo with on-chain `ETH`, `BTC`, `SOL`, `AVAX`, `LINK`, `UNI`,
`AAVE` and `ARB` tickers, start a dedicated Anvil on port 8546 and use the guarded lifecycle:

```sh
anvil --chain-id 31337 --port 8546
python3 script/local-demo.py seed --rpc-url http://127.0.0.1:8546
```

The lifecycle runs `LOCAL_DEMO=true` for the baseline deployment, exports its receipt addresses,
then invokes the one-shot seeder. Use `script/local-demo.py` for both initial setup and restarts:
its operation lock, deployment journal and admin nonce checks refuse partial prior broadcasts.
The underlying `SeedLocalDemo` script checks baseline addresses and factory vault count, but
cannot detect every interrupted asset-seeding phase on its own. Do not rerun it directly after
an interruption; inspect the journal and broadcast receipts through the guarded lifecycle.

The CLI requires a dedicated Anvil chain 31337 and canonical unlocked accounts; the seeder
requires a `LOCAL_DEMO` baseline with exactly one factory vault. Neither resets a chain.
The stable fixture order, names, managers and illustrative
fixed prices are in `script/demo-vaults.json`. The prices are test data, not market quotations.
Each vault contains one to five assets because `EquiVault.MAX_BASKET_SIZE` remains five; the eight
assets are a shared local catalogue for varied baskets.

The fixture creates 17 vaults with seven managers, 13 funded positions, four empty vaults,
all three trust modes and two pending parameter proposals. Its synthetic token decimals vary
(BTC: 8, SOL: 9, other basket tokens: 18); settlement is the local 6-decimal `USDG` token
(on-chain name `Demo USDG`). This is a local test token, not the official token deployment.
The default minimal fixture continues to use `MOCK`.
The generated, ignored `deployments/31337/demo.json` binds actual token/vault addresses and
manager profiles to the chain genesis and deployment block. The app's `demo:metadata` command
consumes this manifest to publish names through its signed metadata API.

```sh
python3 script/local-demo.py verify --rpc-url http://127.0.0.1:8546
python3 script/local-demo.py refresh --rpc-url http://127.0.0.1:8546
```

Repeated `seed` calls validate the existing deployment and preserve positions without creating
duplicates. `verify` checks the original fixture counts; manually added vaults can make that
diagnostic fail without preventing safe restarts. `refresh` verifies the deployment, registry
feeds and compiled mock runtimes, then updates all 16 oracle timestamps while preserving prices.
Oracle freshness remains one hour; repeat refresh during long sessions. The CLI itself does
not run a background timer. Operations use a local lock and refuse unknown partial deployments;
inspect `.local-demo/progress.json` and broadcast receipts rather than resetting an existing chain.
Use Anvil state persistence, including `--preserve-historical-states`, to retain positions and
the deployment binding across process restarts. No private key is required.

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
