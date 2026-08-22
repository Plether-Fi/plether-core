# Perps Internal Architecture Map

This page is a compressed operational map of where value lives, who owns it, which contract may mutate it, which accounting view may read it, and which flows move it across protocol domains.

For normative semantics, use [`ACCOUNTING_SPEC.md`](ACCOUNTING_SPEC.md). For system overview, use [`README.md`](README.md). For compact audit policy tables and transaction narratives, use [`PRE_AUDIT_GUIDE.md`](PRE_AUDIT_GUIDE.md).

![Perps internal architecture map](../../assets/diagrams/perps-internal-architecture-map.svg)

## Asset Buckets

| Bucket | Economic owner | Custody / source of truth | May mutate | Read by accounting views |
|--------|----------------|---------------------------|------------|--------------------------|
| Free settlement USDC | Trader account | `MarginClearinghouse.balanceUsdc(accountId)` | `MarginClearinghouse` via user deposit/withdraw, `CfdEngine` settlement paths, `OrderRouter` narrow reservation calls | Close, liquidation, pending-order reservation, withdrawal eligibility |
| Position margin | Trader until settled, then HousePool or counterparty by outcome | `MarginClearinghouse` locked-position bucket plus `pos.margin` mirrors in `CfdEngine` | `CfdEngine` lock/unlock/consume on open, close, liquidation; `OrderRouter` may indirectly source close bounty from active margin | Close, liquidation, solvency reachability, pending-order escrow exclusions |
| Committed order margin | Trader, but reserved for one queued order | `MarginClearinghouse` reservation record keyed by `orderId` | `OrderRouter` commits/cancels/executes through clearinghouse reservation APIs; `CfdEngine` consumes on execution | Pending-order escrow, liquidation reachability, withdrawable trader balance |
| Execution bounty reserve | Trader-funded keeper reserve until paid or forfeited | `MarginClearinghouse` reserved settlement bucket plus `OrderRecord.executionBountyUsdc` | `OrderRouter` reserves at commit and routes payout/refund/forfeiture through engine/clearinghouse calls | Pending-order reservation, liquidation reachability, queue liveness review |
| Canonical pool assets (`accountedAssets`, `totalAssets()`) | Protocol-recognized `HousePool` assets | `HousePool` raw/accounted asset ledger | `HousePool` deposit/synchronized-epoch/accountExcess/sweepExcess plus engine-authorized inflow hooks (`recordProtocolInflow`, `recordClaimantInflow(...)`) | Redemption funding, reconciliation, solvency base cash |
| Excess assets | No economic owner until explicitly assigned | `HousePool.excessAssets()` via `max(rawAssets - accountedAssets, 0)` | `HousePool.accountExcess()` / `sweepExcess()` | Operator review only; excluded from canonical withdrawal, solvency, and NAV until admitted |
| Protocol fees | Protocol / treasury, never LP equity | Treasury account in `MarginClearinghouse`; `MarginClearinghouse.balanceUsdc(CfdEngine.protocolTreasury())` reports that account balance | Trader settlement routes cash-collected fee value directly to treasury margin; settlement top-ups move only the free-cash-funded remainder after senior claims and trader payouts; treasury withdraws through the standard clearinghouse path | Protocol accounting snapshot; not a `HousePool` reserve or protocol fee receivable |
| Trader claim balance | Traders owed realized close proceeds | `CfdEngine.traderClaimBalanceUsdc[accountId]`; cash remains in `HousePool` until paid | `CfdEngine` records on illiquid profitable close and services claims as cash becomes available | Withdrawal reserves, reconciliation, solvency |
| Realized carry revenue | LP-owned trading revenue sourced from trader capital rent | `HousePool` claimant inflow routing plus `CfdEngine` side carry indexes | `CfdEngine` realizes on open/close/add-margin and clearinghouse deposit/withdraw; `HousePool` checkpoints side indexes before pool-asset mutations; realized carry routes ownership via `recordClaimantInflow(...)` | LP revenue, reconciliation, solvency |
| Frozen-close spread revenue | LP-owned stale-price protection collected from voluntary frozen closes | `CfdEngine` close plan plus `HousePool` claimant inflow routing; assessed/paid/waived values are exposed by close preview and `FrozenCloseSpreadSettled` | `CfdEngine` assesses only while `oracleFrozen`; `CfdEngineSettlementSidecar` routes retained, cash-collected, or same-account-claim-recovered value to LPs; terminal uncollectible spread is waived | LP revenue, close audit logs, preview/live reconciliation; never protocol treasury or bad debt |
| Unsettled carry | Protocol-recorded carry debt awaiting later physical collection | `CfdEngine.unsettledCarryUsdc[accountId]` | engine carry-checkpoint paths on basis-changing settlement credits | Account risk/equity, planner previews, audit/operator reads |
| Tranche principal / seeded claim path | Senior then Junior LPs by waterfall | `HousePool` principal state, seed positions, and `TrancheVault` share supply | `HousePool` reconcile, synchronized deposit activation/redemption funding, recap/trading-revenue application, unassigned-asset assignment | Reconciliation and LP epoch views; not trader settlement views |
| Pending LP deposit assets | Request controller until cancellation or activation | Per-controller/per-epoch `TrancheVault` accounting plus vault-held USDC escrow | LP request/cancellation and pool-authorized activation | Excluded from pool assets, tranche NAV, and settlement cash until activated |
| Activated LP deposit shares | Request controller | Vault-held share escrow plus claimable per-controller/per-epoch accounting | `HousePool.settleLpEpoch()` activates; controller or operator claims through `deposit` / `mint` | Already included in outstanding share supply and tranche ownership; cannot be minted or claimed twice |
| Pending LP redemption shares | Request controller until funded | Per-controller/per-epoch `TrancheVault` queue accounting; shares are escrowed by the vault but remain outstanding | LP request and bounded `HousePool.settleLpEpoch()` funding callback | Settlement priority and estimated claim value; not free pool cash |
| Funded LP redemption assets | Request controller | USDC claim escrow in the corresponding `TrancheVault` plus claimable epoch accounting | `HousePool.settleLpEpoch()` funds; controller or operator claims through `withdraw` / `redeem` | Excluded from `HousePool` assets and liabilities after funding; must remain one-for-one claim backed |
| Unassigned assets | No owner yet; explicit governance assignment required | `HousePool.unassignedAssets` | `HousePool` only, through exceptional fallback assignment flows | Reconciliation, deposit gating, and operator review |

## Mutation Boundaries

| Domain | What it may do | What it must not do |
|-------|----------------|---------------------|
| `MarginClearinghouse` | Custody trader settlement USDC, lock/release reserved buckets, settle or seize balances under trusted engine/router calls | Reprice the HousePool, classify LP ownership, or pay arbitrary third parties |
| `OrderRouter` | Convert trader balance into queued committed margin and clearinghouse execution-bounty reservations; advance or unwind order lifecycle | Mutate `HousePool` accounting directly or invent trader/pool economics outside engine-validated outcomes |
| `CfdEngine` | Own core state, planner orchestration, carry realization, and narrow settlement host hooks | Hold funds directly or bypass clearinghouse / `HousePool` custody boundaries |
| `CfdEngineSettlementSidecar` | Execute externalized close/liquidation settlement orchestration through engine-owned host hooks | Own storage or bypass engine authorization boundaries |
| `HousePool` | Maintain canonical pool assets and the LP principal waterfall; atomically reconcile and clear synchronized LP epochs; maintain exceptional excess/unassigned buckets | Inspect raw trader balances, execute order logic, bypass Senior-before-Junior matured-demand priority, or custody protocol fees that moved to treasury margin |
| `TrancheVault` | Custody active shares, delayed-deposit escrow, pending redemption shares, and funded redemption assets; execute only pool-authorized epoch mutations | Independently finalize a delayed deposit epoch, independently fund a redemption, or reprice an already-funded claim |

## Critical Capability Boundaries

- `OrderRouter` is the main external execution boundary: it can drive engine order/liquidation paths and a narrow clearinghouse reservation surface, but it does not have broad clearinghouse settlement authority or `HousePool.payOut(...)` authority.
- `CfdEngineSettlementSidecar` is engine-gated, but any external surface added there is security-critical because it inherits engine settlement authority.
- `MarginClearinghouse` broad settlement paths trust only `engine` and `settlementSidecar`; `orderRouter` is limited to queued-order reservation lifecycle calls.
- `HousePool.payOut(...)` and `HousePool.recordProtocolInflow(...)` trust only `engine` and `settlementSidecar`; protocol fees remain outside `HousePool` in treasury clearinghouse margin.
- Any new helper/sidecar that can reach these caller sets should be treated as a core custody/settlement boundary and reviewed accordingly.

## Accounting Readers

| View | Canonical readers | Buckets intentionally visible |
|------|-------------------|------------------------------|
| Close accounting | `CloseAccountingLib`, close preview/live engine paths | Free settlement, released position margin, realized fees, signed VPI, frozen-close spread assessment/payment/waiver, trader payout, bad debt, trader claim balance fallback |
| Liquidation accounting | `LiquidationAccountingLib`, liquidation preview/live engine paths | Liquidation-reachable trader value, pending-order reserve exclusions, total-charge cap, keeper/protocol/LP allocation, residual payout, bad debt |
| Solvency / redemption-funding cash state | `SolvencyAccountingLib`, degraded-mode checks, protocol accounting snapshot builders | `HousePool.totalAssets()` / net physical assets, bounded max liability, trader claim liabilities, withdrawal reserve, free cash available to synchronized LP settlement |
| Reconciliation / NAV | `HousePoolAccountingLib.buildReconcileSnapshot()` | Net physical assets, unrealized MtM liability only, trader claim liabilities, tranche principal / HWM, unassigned assets |
| Pending-order reservation view | Router + clearinghouse reservation getters, liquidation reachability helpers | Committed order margin, clearinghouse-reserved bounty value, free settlement excluded by active reservations |

## Cross-Domain Value Flows

| Flow | From -> To | Initiator | Accounting effect |
|------|------------|-----------|-------------------|
| User funds account | External wallet -> `MarginClearinghouse` free settlement | Trader | Increases trader free cash only |
| Commit open order | Free settlement -> committed margin + reserved bounty bucket | `OrderRouter` via clearinghouse | Moves trader cash into pending-order reservations; no pool effect |
| Commit close order | Free settlement, then active position margin fallback -> reserved bounty bucket | `OrderRouter` via clearinghouse | Reduces immediately reachable trader collateral by a bounded reservation amount |
| Execute open | Committed margin -> live position margin; protocol fee -> treasury clearinghouse account; adverse trading cash -> `HousePool` accounted inflow when realized | `CfdEngine` | Converts pending reservations into live exposure; fee value becomes treasury margin while non-fee trading inflows become canonical pool cash |
| Profitable close | Position margin + free settlement + pool cash -> trader settlement or trader claim balance | `CfdEngine` / `CfdEngineSettlementSidecar` | Realizes trader profit; may create a senior trader claim instead of reverting |
| Losing close / collectible funding / liquidation seizure | Trader reachable balance -> treasury clearinghouse account for protocol fee portion, otherwise `HousePool` accounted inflow | `CfdEngine` | Realized trader loss becomes protocol fee margin or physical pool cash according to settlement semantics |
| Frozen voluntary close spread | Trader profit offset, reachable cash, or same-account claim -> `HousePool` claimant revenue | `CfdEngine` / `CfdEngineSettlementSidecar` | Paid spread becomes LP-owned revenue and never treasury margin; partial closes require full collection, while terminal full closes expose and waive any uncollectible remainder without creating bad debt; liquidation is excluded |
| Liquidation charge | Reachable liquidated-account margin -> keeper clearinghouse account + protocol-treasury clearinghouse account + `HousePool` claimant revenue | `CfdEngine` / `CfdEngineSettlementSidecar` | Allocates the capped charge using timelocked `keeperShareBps` and `protocolShareBps`; both configured shares round down, their sum cannot exceed `10_000`, and LPs get the exact remainder without touching pre-existing pool cash |
| Carry realization | Trader reachable capital on realizing actions -> `HousePool` claimant revenue routing | `CfdEngine` via open/close/add-margin and clearinghouse deposit/withdraw hooks | Time-based LP-capital rent becomes claimant-owned revenue via `recordClaimantInflow(...)` without a separate liquidation settlement path |
| Router forfeiture on liquidation cleanup | Clearinghouse-reserved bounty value -> treasury clearinghouse account | `OrderRouter` -> `CfdEngine.absorbReservedExecutionBounty(...)` | Converts abandoned queued-order reserves into protocol-owned clearinghouse margin |
| LP deposit request / activation | External wallet -> `TrancheVault` escrow -> `HousePool` | LP request, then `HousePool.settleLpEpoch()` | Deposit activation follows both withdrawal phases; Junior activates before Senior; never changes trader balances |
| LP redeem request / funding / claim | LP shares -> `TrancheVault` pending escrow; `HousePool` cash -> vault asset escrow -> receiver | LP request, permissionless pool settlement, then controller/operator claim | Pending shares retain P&L exposure; funded shares burn; claimable assets are irrevocable and leave pool depth at funding |
| Governance recapitalization | External wallet -> `HousePool` canonical cash | Owner-controlled recap path | Restores the senior-first claimant path or lands in `unassignedAssets` if no valid claimant exists |
| Excess assignment / sweep | Raw unsolicited pool cash -> canonical accounting or treasury sweep | `HousePool` owner path | Resolves cash that exists physically but has no admitted economic owner |

## Mental Model

- `MarginClearinghouse` owns trader custody.
- `OrderRouter` owns queued-intent bookkeeping.
- `CfdEngine` owns state transitions and liability classification.
- `HousePool` owns canonical pool cash, LP waterfall accounting, and the sole synchronized epoch coordinator. Vaults
  own pending-share and funded-asset escrow. Protocol fees that cross out of trader custody are owned by the treasury
  clearinghouse account.

When auditing a path, ask four questions in order: who owns the bucket before the action, which contract may mutate it, which accounting view may read it, and whether crossing into a new domain changes owner semantics or only custody semantics.
