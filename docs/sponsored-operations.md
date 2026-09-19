# Local sponsored operations

`sponsor-daemon.py` is a bounded local Anvil operator. It has no private-key option and accepts
only an unlocked loopback Anvil account on chain 31337. It may submit only verified v2 escrow
`fill` and `integrate` calls. It never sends `stop` or `claim`, and it never draws funds from a
request.

```sh
python3 script/sponsor-daemon.py --rpc-url http://127.0.0.1:18545 \
  --sender <unlocked-anvil-account> --state-db .local-demo/sponsor.sqlite \
  --status-port 18789 --budget-wei 1000000000000000000 --max-fill 100000000
```

The daemon authenticates the published v2 factory code hash, source commit, registry, settlement,
vault membership and escrow binding. Its SQLite namespace binds the Anvil genesis hash, earliest
primary `VaultCreated` block hash, factory, source commit, sponsor address and lifetime budget.
Identity is rechecked every scheduler cycle. A mismatch, nonce drift, unknown sent transaction
or reorg pauses rather than retries. One transaction intent is
durable before sending; its maximum gas reserve counts toward the sponsor budget. Actual receipt
fees, including reverted transactions, are charged only to the sponsor ledger.

`GET /v1/status?escrow=0x...&requestId=N` on loopback port 18789 returns the last scheduler
snapshot under `equivaults-sponsor-status/v1`. It is read-only, under 64 KB, and remains available
with a stale heartbeat if RPC later fails. `waiting_market` means a verified on-chain simulation or
admission condition prevented work; `waiting_operator` means RPC or local operator state needs
attention. Recovery remains available to the request owner.

## Operation and recovery

Use a dedicated unlocked account and one database for this operator. Do not run another signer
or another daemon database against the same account. SQLite uses WAL, full synchronous writes
and an exclusive process lock; confirmed fees and in-flight reserves survive restarts. Keep the
database together with its WAL/SHM files when backing up a running process, or stop it first.
SIGINT/SIGTERM stop the loop and close its HTTP listener/database. Restart with the same arguments
and database; changing the budget, account or deployment does not silently reset the ledger.

- At most one transaction is in flight. A known hash without a receipt stays paused and is polled;
  it is never rebroadcast or replaced. Once its canonical receipt appears, work resumes.
- An ambiguous send (including a crash between intent and hash persistence) or a receipt reorg
  latches a durable halt. Do not delete state or reset the nonce to bypass it. Stop the daemon,
  inspect the stored nonce/intent/hash against the local chain, and preserve the ledger. This
  pilot intentionally has no automatic ambiguous-intent repair. For a disposable fresh pilot,
  use an explicitly new deployment, account and database after resolving old pending transactions.
- A fee ceiling, insufficient account balance or exhausted budget pauses before sending. The
  status carries the reason and spent/reserved/budget amounts. Gas estimates above the configured
  cap are rejected, never truncated. The budget is a maximum lifetime spend for this database;
  there is no automatic refill or reimbursement from a vault or request.
- Reverted broadcasts consume their actual sponsor gas and count against
  `--max-failed-attempts` for the same request/version/sequence. Simulation failures consume no
  gas, use `--backoff`, and remain retryable after a market recovers. RPC failure is operator
  uncertainty, not evidence that the market is unavailable.
- Requests and vaults use durable round-robin cursors (`--scan-vaults`, `--scan-requests`).
  Factory event discovery reads at most sixteen 2,000-block windows per cycle until it finds the
  deployment anchor; later cycles check that anchor. The advisory cache holds 128 request states.
  Requests outside the fresh cache have unknown status rather than a false healthy indication.

An integration may leave indivisible personal token residue. The daemon does not close or claim
it for the owner: no admissible tranche means waiting, with stop/claim still available. Already
issued shares remain owned by the investor. The newest confirmed receipt's canonical block hash
also commits to its ancestors, so one cumulative anchor covers previously charged receipts.
This intentionally favors safe pauses over automatic reorg recovery.

## Local verification

Run `python3 -m unittest discover -s test -p '*_test.py'` for ledger, authentication, failure,
fairness and exporter regressions. The paired application's sponsor E2E starts a fresh isolated
deployment, exercises multiple requests with the browser closed, market failure/recovery,
offline stop/claim, restart persistence and a budget that prevents all sends. It stops only its
own processes. No Solidity, ABI or deployment release is changed by the operator.

This is local development infrastructure. Mock routes/oracles, five-asset baskets, configured gas
caps and the finite sponsor budget limit its evidence. It does not establish remote sponsor
availability, production key custody, reimbursement, liquidity or execution guarantees.
