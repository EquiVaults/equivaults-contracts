# Observed simulation performance

The local controller records canonical block number/hash and timestamp alongside
oracle-valued assets per outstanding vault share. It does not substitute DEX
quotes or aggregate TVL growth for investment returns. New capital mints shares;
it is not a performance gain. The display is denominated in the vault settlement
asset, not USD or native gas currency by assumption.

`1M` and `1Y` are calendar rolling periods in UTC, with end-of-month/leap-day
clipping. `YTD` starts January 1 UTC. `1D`/`7D` are rolling elapsed days. `ALL`
means **since tracking**, which may begin after vault creation. No annualization
or partial-period substitution is performed. A fully emptied vault ends its share
series, including an exit/re-entry between two captures; periods crossing it are
unavailable, and charts must break at the explicit zero-NAV marker. An absent baseline, a boundary
sample more than one day away, or a gap exceeding two days makes the period
unavailable. Daily simulation snapshots supply the required observations;
a raw time jump deliberately does not invent a market history.

Personal accounting reconstructs `Entered`, `InvestmentIntegrated`, `Exited`,
`RequestCreated`, and `PositionClaimed`. It reconciles exact integer share and
cost allocation with the current chain, including the protocol's rounding on
partial withdrawals. Request creation counts capital once; integration moves
cost to vault shares without counting a second contribution.

- Current value: exact `quoteExitValue` oracle value of vault shares and pending escrow tokens, plus
  unspent escrow settlement. Test funds sitting in the wallet are excluded.
- Remaining cost: on-chain vault cost basis, pending acquisition cost and
  unspent escrow principal.
- Unrealized PnL: current value minus remaining cost.
- Realized PnL: actual exit proceeds less allocated share cost, plus in-kind
  recovery value at the recovery block less recovered acquisition cost.
- Cumulative return: total realized plus unrealized PnL divided by cumulative
  contributed capital. This is not an annualized or time-weighted personal rate.

Native gas is excluded. Realized exit proceeds include actual swap/performance
fees; future exit fees and price impact are not deducted from indicative current
value. Recovered tokens leave the investment scope at recovery; subsequent wallet
holdings or sales are not tracked. No personal per-token allocation is invented.
Missing receipts, oracle valuations or reconciliation evidence produce explicit
unavailability. Values from unaffected wallets can remain available.

History is bound to the demo chain/genesis/factory/deployment anchor. A canonical
cursor mismatch is a recovery error, never an automatic rewrite. Restore the
matching chain and data backup together; do not reuse the SQLite file after
resetting a chain. This development integration does not claim production-grade
indexer availability or distant DEX qualification.
