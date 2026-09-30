# Local simulation controller

`script/simulation.py` is an opt-in controller for a seeded rich local demo on a dedicated Anvil chain. It never starts, stops or resets Anvil. It only accepts the fixture deployment identity recorded in `.local-demo/demo.json` and `.local-demo/simulation-fixture.json`.

Start it explicitly after the fixture and metrics scripts are available:

```sh
python3 script/simulation.py --rpc-url http://127.0.0.1:8546 --serve
```

It binds only to `127.0.0.1:38791`. `GET /state` is read-only. `POST /command` accepts `application/json` only from `http://127.0.0.1:18573`; use `--origin http://127.0.0.1:39573` for an isolated UI. The origin is one exact loopback value, never a wildcard. No Ethereum RPC method or endpoint is relayed. Commands are typed:

```json
{"action":"advance","seconds":3600,"mode":"simulate"}
{"action":"advance","seconds":5184000,"mode":"simulate","scenario":"path"}
{"action":"advance","seconds":7200,"mode":"jump"}
{"action":"market","asset":"0x...","dexChangeBps":10000,"oracleChangeBps":10000,"requestId":"00000000-0000-4000-8000-000000000001"}
{"action":"scenario","name":"drawdown"}
```

`advance` returns `202` with a job and accepts up to 366 days. The controller splits it into one-day on-chain steps; poll `GET /state` for `job`, or send `pause`, `resume` or `cancel` commands. `market` also returns `202` with a one-step job (`mode: "market"`, `seconds: 0`, `completed: 0/1`, `total: 1`, `state` and `error`). Its `requestId` must be a canonical UUID. Repeating the same ID and payload returns the persisted job without submitting another swap; reusing an ID with different values is rejected. Keep the ID when reconciling an uncertain HTTP response. A market job is atomic and does not support pause or cancel. `simulate` applies queued primary/fallback feed updates (the fallback is five minutes behind) and uses the default differentiated path unless another scenario is selected. A `jump` intentionally does not refresh feeds: their on-chain timestamps, and any request deadlines, are allowed to expire. DEX changes are actual swaps from the fixture's isolated impersonated market actor; it is never a demo investor or manager.

Manual market changes accept integer basis points from -9,999 through JavaScript's largest safe integer, subject to nonzero oracle price and pool/uint256 capacity. At least one of DEX and oracle must change. The DEX input is sized against `MockPool`'s constant-product formula, its swap fee and integer rounding to reach the requested relative spot change. The controller mints only the extra synthetic market-actor balance needed for the isolated local swap. An impossible move ends the job with an explicit error. Scenario and daily path bounds remain independent.

The controller holds a lifetime lock scoped to the local RPC port and also serializes each mutation. It persists the deployment/RPC namespace and command intent atomically before a time or market write. After an interrupted mutation, state reports `recoveryRequired`; send `{"action":"acknowledge"}` only after the observed state has been captured, then submit a new command. It preserves vaults and positions and captures metric snapshots before and after a command.

Each `assets[]` entry contains the current pinned `oraclePrice` and pool-spot `dexPrice`, plus `history` and `projection`. `history` is recorded in the deployment-scoped metrics SQLite database only when a capture succeeds; every point carries the observed block timestamp and no earlier prices or missing days are reconstructed. The API returns at most 1,024 real points per asset: first and last observations for each of the last 366 UTC days, plus 128 recent intraday points. `projection` has day 0 through day 90 and applies the same deterministic oracle rate table and current path phase as stepped simulation. It is an oracle-only scenario from the current observed price: it is not DEX, execution, vault-NAV, PnL, or withdrawal forecast.

Local transaction receipt polling uses a ten-second monotonic budget between RPC responses. Each RPC retains its own transport timeout. A missing receipt is an uncertain outcome, with the transaction hash reported for reconciliation; it is not reported as a reverted transaction and is never automatically resubmitted. Reconcile the chain before acknowledging recovery.

A funded executor cycle is disabled by default. With `--run-executor --executor-config path.json`, the controller owns one existing `investor-executor.py` instance and its journal, preserves the status endpoint from the config, and invokes a cycle after each simulated day and every five seconds while idle. The config supplies only documented executor arguments and cannot select an arbitrary command.

## Advance responsiveness

Jobs expose `startTimestamp` and `targetTimestamp` with their completed/total daily
steps. These are planned bounds: the normal Anvil clock still runs during work.
An advance or market change arriving while the mutation lock is held is refused
immediately with `Simulation controller is busy; no advance was accepted.` or
`Simulation controller is busy; no market change was accepted.` Neither is queued
behind an existing step. Only an explicit refusal proves that no command was
accepted; a timeout is not proof of rejection. Poll `GET /state` and retry an
uncertain market request only with its original `requestId`. A persisted active
market job becomes `interrupted` after a controller restart and requires explicit
recovery acknowledgement; the controller never replays it.

The executor encodes known static ABI calls directly, with equivalence tests
against `cast`; other forms retain the `cast` fallback. Runtime bytecode is still
read afresh before its content hash is reused. Metrics reuse a successful capture
only for identical block number/hash/timestamp, manifest and fixture inputs.
Deployment checks still run; errors and new or replaced blocks force reconciliation.
Daily market movements, executor checks and financial accounting are preserved.

A seven-day isolated replay measured 64.14 seconds before and 42.14 seconds after
these optimizations. All seven published financial snapshots matched, including
asset prices, portfolios, NAV and period returns. This is a local measurement,
not a fixed speed or a guarantee for more active requests or longer histories.

## Reproducible market paths

The default path combines per-asset drift, multi-day cycles, keyed daily variation
and occasional bounded shocks. Daily variation is derived from the absolute
scenario day and asset index with a fixed versioned hash; it does not consume
random generator state. Chart refreshes, pause/resume and process restarts cannot
reroll prices. Projection and execution use the same integer function and rounding.
Daily oracle changes are bounded to -20% / +20%; DEX spot prices still result from
actual pool swaps and can diverge from the projected oracle.

| Demo assets | Path character |
| --- | --- |
| ETH, BTC | Gentler cycles, corrections and recoveries |
| SOL, AVAX, UNI, AAVE, ARB | Different cycle lengths, trends and daily volatility |
| LINK | Mostly sideways cycles |
| RALLY | Persistent rise, with a variable daily rate |
| BOTTL | Persistent decline, with a variable daily rate |
| ILLQ, VOLX | Larger swings, sharp drops and rebounds |
| SHARE | Moderate cycles with a small upward drift |

These are synthetic testing profiles, not predictions about real tokens. The
profile order is tied to the existing rich-demo asset order. Updating the path
changes future projections and future simulated steps from current observed prices;
it never rewrites recorded prices, resets investments, or promises a particular
investor return. LateInvestor still attempts entry after day ten, but its entry
is no longer assumed to coincide with every asset's peak.

## Opt-in investor and stress fixture

After `python3 script/local-demo.py seed` has verified a dedicated Anvil demo, create the extension once:

```sh
python3 script/simulation_fixture.py ensure --rpc-url http://127.0.0.1:38545
```

It writes only ignored local state: `.local-demo/simulation-fixture.json` and its durable progress marker. The base `demo.json` catalogue remains its original eight assets and vaults. `show` is read-only:

```sh
python3 script/simulation_fixture.py show --rpc-url http://127.0.0.1:38545
```

The fixture contains eight named, fixed synthetic investor addresses, a separate synthetic `marketActor`, five mock stress assets and five scenario vaults. It creates existing Early/Mixed positions, a recorded partial Exit, and Patient/Whale/Blocked progressive requests with immutable price limits. Late is funded for an engine-stage entry; NewInvestor has native and settlement funds but no investment history. The existing Anvil executor (account 6) and bundler (account 7) remain technical accounts and are never used as simulation investors or as the market actor.

Patient, Whale and Blocked each receive a personal `InvestmentExecutionAccount` funded with `0.32 ETH`: 32 capped attempts at `0.01 ETH` each. The fixture records their addresses and observed EntryPoint budgets in the extension manifest; it does not claim that an operator has executed those requests.

If a broadcast process stops, `ensure` will finalize only an exact, completed on-chain extension. It will refuse an intermediate or uncertain state rather than replaying deployments, mints, entries or requests. Inspect the preserved `SeedSimulationFixture.log` receipts before deciding any recovery action.

## Restoring a stopped local demo

Stop the controller/executor, bundler and app before restoring. Back up the Anvil
snapshot, controller/fixture JSON, and matching SQLite databases including WAL
files. Check database integrity and verify journal block hashes against the loaded
chain before acknowledging interrupted work. Do not combine an old chain dump with
newer journals or replay an uncertain operation.

Use the simulation launcher when restarting Anvil; loading its blocks alone can
reset the next-block clock to wall time and invalidate simulated deadlines:

```sh
python3 script/start-simulation-anvil.py --state /absolute/path/to/anvil-state.json --port 38545
```

This launcher requires an existing snapshot, binds to loopback, preserves the
loaded genesis by using its original timestamp, and checks the loaded chain identity.
It then mines one empty anchor block at the saved head timestamp plus one second
to restore the future clock without changing balances or contract storage. Wait
for `Simulation Anvil ready` before starting dependent services. Passing the saved
head timestamp as Anvil's genesis timestamp instead can create competing genesis
headers across restarts; the launcher rejects such ambiguous snapshots. It periodically
persists the current state, headers and transactions. It does not dump full
historical account states on every checkpoint: those repeated copies made the
rich demo snapshot grow from about 65 MiB to 1.5 GiB. Historical account state
absent from a snapshot cannot be reconstructed; saved headers, receipts and
metric observations remain separately verifiable. Price/PnL history lives in the
matching metrics database, which must be backed up with the chain.

Inspect an interrupted controller before acknowledgement. `GET /state` does not
mutate the chain, but running the controller is not a read-only service: after
acknowledgement its idle loop refreshes oracle timestamps even without
`--run-executor`. With that flag it can also execute existing funded requests.
Acknowledge through its normal API only after checking the restored identity and
financial state; this captures the chain and does not replay the failed command.
Start one bundler and one controller-owned executor, then the explicitly enabled
demo app. Verify subsequent block timestamps remain at or after the saved head.
