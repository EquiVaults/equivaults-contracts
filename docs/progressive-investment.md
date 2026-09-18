# Progressive investment protocol (development)

Newly deployed v2 vaults own an immutable `InvestmentEscrow`. Existing deployments are not
upgraded. The published capability is limited to validated local fixtures; it is not production
qualification. All examples below concern standard, non-taxed, non-rebasing ERC-20 tokens.
Registry admission must attest those properties; balance checks cannot make arbitrary tokens safe.

## Ownership and lifecycle

Identify a request by chain, deployment/factory, vault, escrow and request ID. Its owner is
the wallet that calls `createRequest(amount, expectedVersion, deadline)`; receivers cannot be
selected by an executor. An exact settlement transfer credits the request without any oracle
or swap call. Registry deposit admission still applies. Pending settlement and acquisitions
are outside the shared vault NAV. Donations credit no request.

`fill(id, index, amount, sequence, deadline)` buys one asset in the accepted basket using
only its registered route. Exact settlement spending, measured output, a fresh registry oracle
minimum rounded upward from one rational calculation, an exact temporary allowance and the
current version/sequence are enforced. Each leg is also capped at its share of the remaining
acquisition-cost budget (available settlement plus pending historical costs), less the cost
already assigned to that leg. Bootstrap uses target weights; a funded vault uses current
oracle-valued shared weights. `maxFillAmount` exposes that bound, clamped to available cash.
A third party cannot spend the whole request on one leg of a multi-asset basket. The
immutable vault `maxSlippageBps` is a system execution bound, not a personal rule. The route's
reported return value is never used as accounting evidence. A reverting fill rolls back only
that transaction; earlier confirmed purchases remain personal. For a nonempty vault, the
per-leg budget requires fresh prices and open registry status for every basket asset to measure
current composition. An unrelated oracle outage therefore also pauses fills; it never pauses
stop/claim. A route outage remains isolated to attempts using that route. Every successful fill or
integration advances the sequence; stale retries cannot spend again.

`integrate(id, sequence)` admits a complete tranche and mints shares to the owner. Pending
tokens and their acquisition costs remain personal until this transaction succeeds. The
version binds chain, vault, proposal counter, basket, target weights and collective parameters.
A new proposal conservatively freezes existing requests, including after cancellation. A
rebalance changes shared quantities without changing the accepted asset set: integration always
uses current holdings. An executed reallocation changes the version. There is no silent migration.

The owner can call `stop(id)` immediately, including when settlement is zero. It disables
future fills/integration and returns all remaining settlement. Individually retryable
`claim(id, index)` calls return bought tokens without selling them. These paths read no oracle,
route or current configuration and need no keeper. They still require the token itself to
permit transfers and the wallet to pay transaction gas. A request closes only after all its
personal balances are zero. Already minted shares use the normal vault withdrawal API.

## Admission and mint

The basket remains limited to five assets. For positive supply `S`, shared token quantities
`H[i]`, and pending quantities `Q[i]`, select `m = min floor(Q[i] * S / H[i])` over positive
holdings and transfer `ceil(m * H[i] / S)`. Zero-holding legs contribute zero. This preserves
the current exposure composition, rather than moving existing holders toward target weights.
Excess quantities stay personal. A positive supply with zero NAV cannot integrate.

For zero supply, derive a complete target-weight tranche from the limiting available token
value; convert each target allocation to token units with upward rounding. Pre-existing token
donations are included in the pre-contribution NAV and therefore the virtual-offset mint price.
Incomplete or zero-value tranches cannot mint. Total conservative rounding cost, including token valuation floors and share quantization, is capped at
one basis point of the contribution, so coarse token units may require waiting or recovery.
This is a system admission guard, not an investor-selected price constraint.

Read all registry prices and pre-contribution holdings into one snapshot. On exact receipt,
mint no more than `floor(valueReceived * (S + 1e6) / (navBefore + 1))`, preserving the existing
virtual offsets. With positive supply also cap mint at `floor(received[i] * S / H[i])` for every
positive holding. Thus no old holder loses underlying token units per share, even where offsets
are material. A zero mint reverts. Shared settlement dust remains excluded, consistently with
the existing `totalAssets` and `exit` semantics; it cannot be claimed as request capital.

The escrow prorates each token's historical settlement cost over its integrated quantity,
rounding down and assigning the remainder to the last fragment. Only that cost enters the
owner's vault `costBasis`. Refunds create no cost basis; claimed personal tokens retain their
historical cost in `PositionClaimed` for external accounting. Gas is never added to request cost.

## Reconciliation and events

- `deposited = available + spent + refunded` for each request.
- For each token, credited purchases equal pending + integrated + claimed quantities.
- Spent acquisition cost equals pending token cost + integrated cost + claimed token cost.
- `RequestCreated`, `RequestFilled`, `RequestIntegrated`, `RequestStopped`, `PositionClaimed`
  and `RequestClosed` expose the relevant deltas. `InvestmentIntegrated` additionally exposes
  the shared supply/NAV references. Correlate integration logs within the same receipt.

Swap fees and execution loss are already inside measured net output. Do not subtract them a
second time. Oracle-relative execution loss is not a measured decomposition into spread,
price impact and market movement. Direct gas costs come from transaction receipts, paid by
the sender. Indexers must rescan reorg windows and reread request state; pending USDG is not AUM.

## Local sponsor harness

`script/progress-local.py` provides an explicitly local, bounded automation pass.
It first integrates any admissible tranche, otherwise buys the largest on-chain acquisition-cost
deficit, with at most one asset per transaction and a configurable work cap. It re-reads the
sequence each step. Re-running resumes state; it cannot reopen stopped or changed-version
requests. A failing route/oracle ends the pass; it does not create a blind retry or billing loop.

```sh
python3 script/progress-local.py --rpc-url http://127.0.0.1:18545 \
  --escrow <actual-escrow> --request-id 1 --max-fill 50000000000 \
  --max-actions 20 --sender <funded-local-sponsor>
```

Each transaction is confirmed before the next is prepared, so a later route failure cannot
roll back earlier progress. The harness refuses non-loopback endpoints, non-Anvil clients and
chains other than 31337. It contains no private key. Its external unlocked
Anvil sender pays gas; the app neither signs server-side nor reimburses execution. Production
sponsor availability, budget, scheduling, route/oracle qualification and starvation policy remain
deployment gates. Neither a permissionless API nor this local harness guarantees execution,
completion time or final price. Recovery remains independent of the sponsor.
