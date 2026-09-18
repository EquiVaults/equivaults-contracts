# Local v2 publication and v1 coexistence

This runbook publishes one self-contained Anvil fixture for development integration. It never
migrates an existing vault or position. The current v2 factory creates hybrid vaults with an
`InvestmentEscrow`; the separately deployed v1 `LegacyVaultFactory` creates synchronous vaults
from the recorded historical source. Both use the same local registry and mock tokens, while
all vault shares, balances and request positions remain isolated by contract address.

## Publish a reproducible fixture

Use a dedicated local Anvil namespace. Do not reset or reuse an Anvil instance that holds a
fixture whose positions matter. A reset creates a new chain history even when deterministic addresses repeat; create a new
fixture and verify its address catalog and creation-block identity before using cached history.

1. Commit the reviewed contract source, including the v1 fixture and deploy scripts.
2. From that source commit, generate the ABI and manifest. This command refuses a dirty source
   tree. It records the source commit in `deployments/manifest.json`.

   ```sh
   ./script/export-artifacts.sh
   ```

3. Start a fresh loopback Anvil with chain ID 31337, then broadcast the local deployment. Keep
   `--slow`: it avoids nonce-gap hangs during the many local deployment transactions.

   ```sh
   anvil --chain-id 31337
   forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 \
     --broadcast --unlocked \
     --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --slow
   ```

4. Export addresses through the exact local RPC endpoint used for validation, then verify the
   published consumer view. The endpoint is a command-line input so validation may use a dedicated
   local port. The published `rpcUrl` remains the stable default `http://127.0.0.1:8545`.

   ```sh
   python3 script/export-addresses.py --rpc-url http://127.0.0.1:8545
   bash script/check-artifacts.sh --rpc-url http://127.0.0.1:8545
   ```

   The exporter requires loopback chain ID 31337. It rebuilds the source artifacts, rejects a
   source/manifest mismatch, validates successful receipts, derives each example vault from the
   mined `VaultCreated` event, checks factory/vault bindings, and compares deployed runtime and
   linked libraries with the rebuilt artifacts. It records a real runtime hash for each factory.

5. Review and commit the generated `abi/`, manifest and `deployments/31337/addresses.json` as the
   artifact commit. The v2 factory catalog entry must use the same `contractsCommit` as the
   manifest. Do not run the exporter after editing source without restarting at step 1.

## Coexistence and recovery

`addresses.factory` is always the v2 factory. `addresses.factories` lists both factories with a
protocol version, runtime code hash and source commit; `legacyExampleVault` is the v1 example.
The v1 factory intentionally has no `protocolVersion()` getter, so discovery uses the published
code hash and recorded historical commit. v2 factory, vault and escrow expose `protocolVersion() == 2`.

There is no upgrade or migration path. A v1 holder exits through that vault's synchronous `exit`
flow. A v2 request is recoverable through its owner `stop` and per-token `claim` operations even
when current oracle, route or admission reads fail; those operations do not recover a v1 position.
Resetting a chain destroys its live state unless a separate snapshot was retained. Its new
namespace must never be confused with the old history, even when addresses repeat. Retain any
required prior catalog and chain snapshot before deliberately resetting local state.

## Scope and limits

The manifest marks progressive investment as enabled with status `local`. It is not a production
capability or an authorization to operate a sponsor. The fixture uses mock ERC-20s, mock oracles
and mock constant-product routes. It proves no real-token behavior, route liquidity, oracle
quality, external execution availability or production gas reimbursement.

Vault baskets remain limited to five assets. Measured runtime sizes for this fixture are:

| Contract | Runtime bytes |
| --- | ---: |
| VaultFactory v2 | 2,356 |
| EquiVault v2 | 19,073 |
| InvestmentEscrow v2 | 12,082 |
| LegacyVaultFactory v1 | 22,629 |
| LegacyEquiVault v1 | 17,288 |

All are below the EIP-170 runtime limit of 24,576 bytes. Re-measure after any compiler, optimizer,
library or source change; prior sizes do not prove later deployability.

The local five-leg integration scenario measured five fills at 929,420 gas total and integration
at 635,578 gas, excluding transaction intrinsic gas and using mocks. These figures are regression
evidence for this fixture, not a production gas quote or a guarantee of sponsor capacity.
