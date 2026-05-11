# Perps Internal Architecture Map

This page is a compressed operational map of where value lives, who owns it, which contract may mutate it, which accounting view may read it, and which flows move it across protocol domains.

For normative semantics, use [`ACCOUNTING_SPEC.md`](ACCOUNTING_SPEC.md). For module-level overview, use [`README.md`](README.md). For compact audit policy tables and transaction narratives, use [`PRE_AUDIT_GUIDE.md`](PRE_AUDIT_GUIDE.md).

![Perps internal architecture map](../../assets/diagrams/perps-internal-architecture-map.svg)

## Asset Buckets

| Bucket | Economic owner | Custody / source of truth | May mutate | Read by accounting views |
|--------|----------------|---------------------------|------------|--------------------------|
| Free settlement USDC | Trader account | `MarginClearinghouse.balanceUsdc(accountId)` | `MarginClearinghouse` via user deposit/withdraw, `CfdEngine` settle/seize paths, `OrderRouter` bounty seizure through clearinghouse auth | Close, liquidation, pending-order escrow, withdrawal eligibility |
| Position margin | Trader until settled, then vault or counterparty by outcome | `MarginClearinghouse` locked-position bucket plus `pos.margin` mirrors in `CfdEngine` | `CfdEngine` lock/unlock/consume on open, close, liquidation; `OrderRouter` may indirectly source close bounty from active margin | Close, liquidation, solvency reachability, pending-order escrow exclusions |
| Committed order margin | Trader, but reserved for one queued order | `MarginClearinghouse` reservation record keyed by `orderId` | `OrderRouter` commits/cancels/executes through clearinghouse reservation APIs; `CfdEngine` consumes on execution | Pending-order escrow, liquidation reachability, withdrawable trader balance |
| Execution bounty reserve | Trader-funded keeper reserve until paid or forfeited | `MarginClearinghouse` reserved settlement bucket plus `OrderRecord.executionBountyUsdc` | `OrderRouter` reserves at commit and routes payout/refund/forfeiture through engine/clearinghouse calls | Pending-order escrow, liquidation reachability, queue liveness review |
| Canonical pool assets (`accountedAssets`, `totalAssets()`) | Protocol-recognized `HousePool` assets | `HousePool` raw/accounted asset ledger | `HousePool` deposit/withdraw/accountExcess/sweepExcess plus engine- and settlement-module-authorized inflow hooks (`recordProtocolBackingInflow`, `recordClaimantInflow(...)`) | Withdrawal, reconciliation, solvency base cash |
| Excess assets | No economic owner until explicitly assigned | `HousePool.excessAssets()` via `max(rawAssets - accountedAssets, 0)` | `HousePool.accountExcess()` / `sweepExcess()` | Operator review only; excluded from canonical withdrawal, solvency, and NAV until admitted |
| Protocol fees | Protocol / treasury, never LP equity | Treasury account in `MarginClearinghouse`; `CfdEngine.protocolTreasuryBalanceUsdc()` reports that account balance | Trader settlement routes cash-collected fee value directly to treasury margin; settlement top-ups move only the free-cash-funded remainder after senior claims and trader payouts; treasury withdraws through the standard clearinghouse path | Protocol accounting snapshot; not a `HousePool` reserve or deferred protocol receivable |
| Deferred trader credit | Traders owed realized close proceeds | `CfdEngine.deferredTraderCreditUsdc[accountId]`; cash remains in `HousePool` until paid | `CfdEngine` records on illiquid profitable close and services claims as cash becomes available | Withdrawal reserves, reconciliation, solvency |
| Realized carry revenue | LP-owned trading revenue sourced from trader capital rent | `HousePool` claimant inflow routing plus `CfdEngine` carry realization paths | `CfdEngine` realizes on open/close/add-margin and on clearinghouse deposit/withdraw using the pre-mutation reachable basis; deposits may collect realized carry from post-deposit settlement in the same transaction, while withdraws realize carry before reducing settlement, then routes ownership via `recordClaimantInflow(...)` | LP revenue, reconciliation, solvency |
| Unsettled carry | Protocol-recorded carry debt awaiting later physical collection | `CfdEngine.unsettledCarryUsdc[accountId]` | engine carry-checkpoint paths on basis-changing settlement credits | Account risk/equity, planner previews, audit/operator reads |
| Tranche principal / seeded claim path | Senior then junior LPs by waterfall | `HousePool` principal state, seed positions, and `TrancheVault` share supply | `HousePool` reconcile, deposit, withdraw, recap/trading-revenue application, unassigned-asset assignment | Reconciliation and withdrawal views; not trader settlement views |
| Unassigned assets | No owner yet; explicit governance assignment required | `HousePool.unassignedAssets` | `HousePool` only, through exceptional fallback assignment flows | Reconciliation, deposit gating, and operator review |

## Mutation Boundaries

| Domain | What it may do | What it must not do |
|-------|----------------|---------------------|
| `MarginClearinghouse` | Custody trader settlement USDC, lock/release reserved buckets, settle or seize balances under trusted engine/router calls | Reprice the vault, classify LP ownership, or pay arbitrary third parties |
| `OrderRouter` | Convert trader balance into queued committed margin and clearinghouse-reserved execution bounty value; advance or unwind order lifecycle | Mutate `HousePool` accounting directly, directly custody trader USDC, or invent trader/vault economics outside engine-validated outcomes |
| `CfdEngine` | Own core state, planner orchestration, carry realization, and narrow settlement host hooks | Hold funds directly or bypass clearinghouse / `HousePool` custody boundaries |
| `CfdEngineSettlementModule` | Execute externalized close/liquidation settlement orchestration through engine-owned host hooks | Own storage or bypass engine authorization boundaries |
| `HousePool` | Maintain canonical pool asset ledger, LP principal waterfall, and exceptional excess/unassigned buckets | Inspect raw trader balances, execute order logic, or custody protocol fees that have moved to the treasury clearinghouse account |

## Critical Capability Boundaries

- `OrderRouter` is the main external execution boundary: it can drive engine order/liquidation paths and a narrow clearinghouse reservation surface, but it does not have broad clearinghouse settlement authority or `HousePool.payOut(...)` authority.
- `CfdEngineSettlementModule` is engine-gated, but any external surface added there is security-critical because it inherits engine settlement authority.
- `MarginClearinghouse` operator paths trust `engine`, `orderRouter`, and `settlementModule` to move trader custody across settlement, escrow, and seizure buckets.
- `HousePool.payOut(...)` trusts `engine` and `settlementModule`; `HousePool.recordProtocolBackingInflow(...)` remains for non-fee pool inflows and does not custody protocol fees in the treasury-margin model.
- Any new helper/module that can reach these caller sets should be treated as a core custody/settlement boundary and reviewed accordingly.

## Accounting Readers

| View | Canonical readers | Buckets intentionally visible |
|------|-------------------|------------------------------|
| Close accounting | `CloseAccountingLib`, close preview/live engine paths | Free settlement, released position margin, realized fees, trader payout, bad debt, deferred trader credit fallback |
| Liquidation accounting | `LiquidationAccountingLib`, liquidation preview/live engine paths | Liquidation-reachable trader value, pending-order reserve exclusions, keeper bounty cap, residual payout, bad debt |
| Solvency / withdrawal cash state | `SolvencyAccountingLib`, degraded-mode checks, protocol accounting snapshot builders | `HousePool.totalAssets()` / net physical assets, bounded max liability, deferred liabilities, withdrawal reserve, free withdrawable cash |
| Reconciliation / NAV | `HousePoolAccountingLib.buildReconcileSnapshot()` | Net physical assets, unrealized MtM liability only, deferred liabilities, tranche principal / HWM, unassigned assets |
| Pending-order reservation view | Router + clearinghouse reservation getters, liquidation reachability helpers | Committed order margin, clearinghouse-reserved bounty value, free settlement excluded by active reservations |

## Cross-Domain Value Flows

| Flow | From -> To | Initiator | Accounting effect |
|------|------------|-----------|-------------------|
| User funds account | External wallet -> `MarginClearinghouse` free settlement | Trader | Increases trader free cash only |
| Commit open order | Free settlement -> committed margin + reserved bounty bucket | `OrderRouter` via clearinghouse | Moves trader cash into pending-order reservations; no vault effect |
| Commit close order | Free settlement, then active position margin fallback -> reserved bounty bucket | `OrderRouter` via clearinghouse | Reduces immediately reachable trader collateral by a bounded reservation amount |
| Execute open | Committed margin -> live position margin; protocol fee -> treasury clearinghouse account; adverse trading cash -> `HousePool` accounted inflow when realized | `CfdEngine` | Converts pending reservations into live exposure; fee value becomes treasury margin while non-fee trading inflows become canonical pool cash |
| Profitable close | Position margin + free settlement + vault cash -> trader settlement or deferred trader credit | `CfdEngine` / `CfdEngineSettlementModule` | Realizes trader claim; may create deferred senior vault liability instead of reverting; protocol fee top-up uses only free cash left after the trader payout |
| Losing close / collectible funding / liquidation seizure | Trader reachable balance -> treasury clearinghouse account for protocol fee portion, otherwise `HousePool` accounted inflow | `CfdEngine` | Realized trader loss becomes protocol fee margin or physical pool cash according to settlement semantics |
| Liquidation bounty | Reachable liquidated-account margin -> keeper clearinghouse account | `CfdEngine` | Pays the keeper from account-backed margin without touching vault cash |
| Carry realization | Trader reachable capital on realizing actions -> `HousePool` claimant revenue routing | `CfdEngine` via open/close/add-margin and clearinghouse deposit/withdraw hooks | Time-based LP-capital rent becomes claimant-owned revenue via `recordClaimantInflow(...)` without a separate liquidation settlement path |
| Router forfeiture on liquidation cleanup | Clearinghouse-reserved bounty value -> treasury clearinghouse account | `OrderRouter` -> `CfdEngine.absorbReservedExecutionBounty(...)` | Converts abandoned queued-order reserves into protocol-owned clearinghouse margin |
| LP deposit / redeem | External wallet <-> `HousePool` / `TrancheVault` | LP through vaults | Changes tranche ownership and principal, never trader balances |
| Governance recapitalization | External wallet -> `HousePool` canonical cash | Owner-controlled recap path | Restores the senior-first claimant path or lands in `unassignedAssets` if no valid claimant exists |
| Excess assignment / sweep | Raw unsolicited pool cash -> canonical accounting or treasury sweep | `HousePool` owner path | Resolves cash that exists physically but has no admitted economic owner |

## Mental Model

- `MarginClearinghouse` owns trader custody.
- `OrderRouter` owns queued-intent bookkeeping.
- `CfdEngine` owns state transitions and liability classification.
- `HousePool` owns canonical pool cash and LP waterfall accounting; protocol fees that cross out of trader custody are owned by the treasury clearinghouse account.

When auditing a path, ask four questions in order: who owns the bucket before the action, which contract may mutate it, which accounting view may read it, and whether crossing into a new domain changes owner semantics or only custody semantics.
