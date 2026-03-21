# Perps Internal Architecture Map

This page is a compressed operational map of where value lives, who owns it, which contract may mutate it, which accounting view may read it, and which flows move it across protocol domains.

For normative semantics, use [`ACCOUNTING_SPEC.md`](ACCOUNTING_SPEC.md). For module-level narrative, use [`README.md`](README.md).

![Perps internal architecture map](../../assets/diagrams/perps-internal-architecture-map.svg)

## Asset Buckets

| Bucket | Economic owner | Custody / source of truth | May mutate | Read by accounting views |
|--------|----------------|---------------------------|------------|--------------------------|
| Free settlement USDC | Trader account | `MarginClearinghouse.balanceUsdc(accountId)` | `MarginClearinghouse` via user deposit/withdraw, `CfdEngine` settle/seize paths, `OrderRouter` bounty seizure through clearinghouse auth | Close, liquidation, pending-order escrow, withdrawal eligibility |
| Position margin | Trader account until settled; then vault or counterparty by outcome | `MarginClearinghouse` locked-position bucket plus `pos.margin` mirrors in `CfdEngine` | `CfdEngine` lock/unlock/consume on open, close, liquidation; `OrderRouter` may indirectly source close bounty from active margin | Close, liquidation, solvency reachability, pending-order escrow exclusions |
| Committed order margin | Trader account, but reserved for one queued order | `MarginClearinghouse` reservation record keyed by `orderId` | `OrderRouter` commits/cancels/executes through clearinghouse reservation APIs; `CfdEngine` consumes on execution | Pending-order escrow, liquidation reachability, withdrawable trader balance |
| Router execution-bounty escrow | Trader-funded keeper escrow until paid or forfeited | `OrderRouter` USDC balance and `OrderRecord.reservedExecutionBountyUsdc` | `OrderRouter` seizes at commit, pays/refunds/forfeits on terminal lifecycle events | Pending-order escrow, liquidation reachability, queue liveness review |
| Canonical pool assets (`accountedAssets`, `totalAssets()`) | Protocol-recognized HousePool assets | `HousePool` raw/accounted asset ledger | `HousePool` deposit/withdraw/accountExcess/sweepExcess plus engine-authorized inflow hooks (`recordProtocolInflow`, `recordRecapitalizationInflow`, `recordTradingRevenueInflow`) | Withdrawal, reconciliation, solvency base cash |
| Excess assets | No economic owner until explicitly assigned | `HousePool.excessAssets()` via `max(rawAssets - accountedAssets, 0)` | `HousePool.accountExcess()` / `sweepExcess()` | Operator review only; excluded from canonical withdrawal / solvency / NAV until admitted |
| Protocol fees | Protocol / treasury, never LP equity | `HousePool` cash plus `CfdEngine.accumulatedFeesUsdc` liability tag | `CfdEngine` accrues fees; `HousePool` accounts the cash inflow; owner may withdraw only through fee path | Withdrawal reserves, reconciliation, solvency cash reservation |
| Deferred trader payouts | Traders owed realized close proceeds | Queue state in `CfdEngine.deferredPayoutUsdc` and oldest-first claim queue; cash remains in `HousePool` until paid | `CfdEngine` records on illiquid profitable close and services claims when cash frees up | Withdrawal reserves, reconciliation, solvency |
| Deferred liquidation bounties | Liquidation keepers owed unpaid bounty | Queue state in `CfdEngine` deferred bounty storage; cash remains in `HousePool` until paid | `CfdEngine` records on illiquid liquidation and services claims later | Withdrawal reserves, reconciliation, solvency |
| Tranche principal / seeded claim path | Senior then junior LPs according to waterfall | `HousePool` principal state, seed positions, and `TrancheVault` share supply | `HousePool` reconcile, deposit, withdraw, recap/trading-revenue application, unassigned-asset assignment | Reconciliation and withdrawal views; not trader settlement views |
| Unassigned assets | Nobody yet; explicit governance assignment required | `HousePool.unassignedAssets` | `HousePool` only, through exceptional fallback assignment flows | Reconciliation / deposit gating / operator review |

## Mutation Boundaries

| Domain | What it may do | What it must not do |
|-------|----------------|---------------------|
| `MarginClearinghouse` | Custody trader settlement USDC, lock/release reserved buckets, settle or seize balances under trusted engine/router calls | Reprice the vault, classify LP ownership, or pay arbitrary third parties |
| `OrderRouter` | Turn trader balance into queued committed margin and execution-bounty escrow; advance or unwind order lifecycle | Mutate HousePool accounting directly or invent trader/vault economics outside engine-validated outcomes |
| `CfdEngine` | Decide trade/liquidation outcomes, fees, bad debt, deferred liabilities, and which clearinghouse / HousePool mutation to invoke | Hold funds directly or bypass clearinghouse / HousePool custody boundaries |
| `HousePool` | Maintain canonical pool asset ledger, LP principal waterfall, fee segregation, and exceptional excess/unassigned buckets | Inspect raw trader balances or execute order logic |

## Accounting Readers

| View | Canonical readers | Buckets intentionally visible |
|------|-------------------|------------------------------|
| Close accounting | `CloseAccountingLib`, close preview/live engine paths | Free settlement, released position margin, realized fees, trader payout, bad debt, deferred trader payout fallback |
| Liquidation accounting | `LiquidationAccountingLib`, liquidation preview/live engine paths | Liquidation-reachable trader value, router escrow exclusions, keeper bounty cap, residual payout, bad debt |
| Solvency accounting | `SolvencyAccountingLib`, degraded-mode checks, fee-withdraw gate | `HousePool.totalAssets()` / net physical assets, bounded max liability, capped solvency funding, deferred liabilities, protocol fees |
| Withdrawal accounting | `WithdrawalAccountingLib`, `HousePool.getFreeUSDC()`, tranche `maxWithdraw` / `maxRedeem` | Net physical assets, max liability, positive funding liability only, deferred liabilities, protocol fees |
| Reconciliation / NAV | `HousePoolAccountingLib.buildReconcileSnapshot()` | Net physical assets, unrealized MtM liability only, protocol fees, deferred liabilities, tranche principal / HWM, unassigned assets |
| Pending-order escrow view | Router + clearinghouse escrow getters, liquidation reachability helpers | Committed order margin, router bounty escrow, free settlement excluded by active reservations |

## Cross-Domain Value Flows

| Flow | From -> To | Initiator | Accounting effect |
|------|------------|-----------|-------------------|
| User funds account | External wallet -> `MarginClearinghouse` free settlement | Trader | Increases trader free cash only |
| Commit open order | Free settlement -> committed margin + router bounty escrow | `OrderRouter` via clearinghouse | Moves trader cash into pending-order escrow; no vault effect |
| Commit close order | Free settlement, then active position margin fallback -> router bounty escrow | `OrderRouter` via clearinghouse | Shrinks immediately reachable trader collateral by bounded escrow amount |
| Execute open | Committed margin -> live position margin; fees / adverse cash -> `HousePool` accounted inflow when realized | `CfdEngine` | Converts pending escrow into live exposure; protocol/trading inflows become canonical pool cash through HousePool hooks |
| Profitable close | Position margin + free settlement + vault cash -> trader settlement or deferred trader payout | `CfdEngine` | Realizes trader claim; may create deferred senior vault liability instead of reverting |
| Losing close / collectible funding / liquidation seizure | Trader reachable balance -> `HousePool` accounted inflow | `CfdEngine` | Realized trader loss becomes physical pool cash, then routes as protocol fee, trading revenue, or recapitalization by source semantics |
| Liquidation bounty | Reachable trader value first, otherwise vault cash or deferred bounty queue | `CfdEngine` | Pays or records keeper claim without overstating reachable collateral |
| Router forfeiture on liquidation cleanup | Router bounty escrow -> `HousePool` protocol-owned cash | `OrderRouter` / `CfdEngine` fee-record path | Converts abandoned queued-order escrow into accounted protocol fee revenue |
| LP deposit / redeem | External wallet <-> `HousePool` / `TrancheVault` | LP through vaults | Changes tranche ownership and principal, never trader balances |
| Governance recapitalization | External wallet -> `HousePool` canonical cash | Owner-controlled recap path | Restores senior-first claimant path or lands in `unassignedAssets` if no valid claimant exists |
| Excess assignment / sweep | Raw unsolicited pool cash -> canonical accounting or treasury sweep | `HousePool` owner path | Resolves cash that exists physically but has no admitted economic owner |

## Mental Model

- `MarginClearinghouse` owns trader custody.
- `OrderRouter` owns queued-intent escrow.
- `CfdEngine` owns state transitions and liability classification.
- `HousePool` owns canonical pool cash, LP waterfall accounting, and all protocol-wide asset ownership routing once value crosses out of trader custody.

When auditing a path, ask four questions in order: who owns the bucket before the action, which contract is allowed to mutate that bucket, which accounting view is allowed to read it, and whether the value crossing into a new domain changes owner semantics or only custody semantics.
