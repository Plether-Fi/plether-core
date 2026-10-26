# Scan findings — Plether-Fi/plether-core

Critical: 0 · High: 0 · Medium: 1 · Low: 12 · Info: 20 · Total: 33

Finished: 2026-10-15T10:04:48.685007Z


## Checkpoint frequency compounds a configured simple senior coupon

**Severity:** medium · accounting_error

**Claim:**

The configured senior rate is documented as an annualized simple coupon, but every reconcile computes interest on the current `seniorPrincipal` and `paySeniorCoupon` capitalizes paid coupon into that same principal/HWM. Consequently, splitting an elapsed period across more successful checkpoints increases total senior coupon and drains extra junior principal. A senior LP can force hourly successful checkpoints during permissionless settlement regimes (no open positions or frozen-oracle mode) by maintaining a small matured LP epoch item, producing approximately `exp(rate)-1` rather than `rate` annual yield (about 8.33% rather than 8% at the default, and up to ~171.8% rather than 100% at the allowed maximum), at junior LPs' expense.

**Evidence:**

- `packages/perps/src/interfaces/IHousePool.sol:56`

```
/// @param seniorRateBps Annualized simple senior target coupon rate in basis points.
The external accounting specification identifies the configured coupon as simple, not checkpoint-frequency-dependent compound interest.
```

- `packages/perps/src/libraries/HousePoolWaterfallAccountingLib.sol:44`

```
return (seniorPrincipal * seniorRateBps * elapsed) / (BPS * SECONDS_PER_YEAR);
Each interval's coupon uses the then-current senior principal as its base.
```

- `packages/perps/src/libraries/HousePoolWaterfallAccountingLib.sol:64`

```
uint256 couponDue = calculateSeniorCoupon(state.seniorPrincipal, seniorRateBps, elapsed); ... nextState.juniorPrincipal -= couponPaid; ... nextState.seniorPrincipal += remaining; nextState.seniorHighWaterMark += remaining;
Coupon is transferred from juniors and capitalized into principal, so the next checkpoint charges coupon on prior coupon.
```

- `packages/perps/src/HousePool.sol:1509`

```
uint256 couponElapsed = block.timestamp > lastSeniorCouponCheckpointTime ? block.timestamp - lastSeniorCouponCheckpointTime : 0; ... planReconcile(... poolConfig.seniorRateBps, couponElapsed, markFresh); ... lastSeniorCouponCheckpointTime = block.timestamp;
Every successful reconcile resets the elapsed interval, making the cumulative result depend on checkpoint partitioning.
```

- `packages/perps/src/HousePool.sol:773`

```
if (accountingSnapshot.hasOpenPositions && !statusSnapshot.oracleFrozen) { if (msg.sender != ENGINE.orderRouter() ... ) revert; } return _settleLpEpoch(...);
When there are no open positions or the oracle is frozen, any EOA can trigger a successful settlement/reconcile by providing matured queue work.
```

- `packages/perps/src/HousePool.sol:1646`

```
if (config.seniorRateBps > 10_000) { revert HousePool__InvalidSeniorRate(); }
The allowed rate reaches 100% nominal, where checkpoint-induced over-accrual becomes very large.
```

## A close-only-ineligible open at the FIFO head blocks all later risk-reducing closes

**Severity:** low · denial_of_service

**Claim:**

An unprivileged trader can commit an open immediately before a predictable close-only/FAD transition and place it at the global FIFO head. After close-only activates, execution returns `Pending(CloseOnly)` for that open rather than terminalizing, invalidating, or bypassing it. Both single and batch execution are strictly head-ordered, and the batch stops as soon as an item remains pending, so every later close—including liquidation-avoidance and position-protection closes—remains unexecutable until the attacker's opening order passes its execution deadline and is expired. The default window is 60 seconds and is configurable, making the denial especially harmful during the exact stressed periods in which close-only policy is active.

**Evidence:**

- `packages/perps/src/router/OrderLiquidationBatchLogic.sol:306`

```
if (oracle.getOrderExecutionPolicy(false).closeOnly) {
    revert OrderRouter__CloseOnlyWindow();
}
An attacker can commit while policy is still open immediately before a known close-only transition; the commit remains live afterward.
```

- `packages/perps/src/OrderRouterExecutionSidecar.sol:432`

```
if (!order.isClose && request.openExecutionCloseOnly) {
    return _pendingResult(order.orderId, OrderV3Types.PendingReason.CloseOnly);
}
Once policy becomes close-only, the head open is deliberately left pending rather than removed or skipped.
```

- `packages/perps/src/OrderRouterExecutionSidecar.sol:231`

```
while (host.nextExecuteId() != 0 && host.nextExecuteId() <= maxOrderId) {
    uint64 orderId = host.nextExecuteId();
    ...
    try host.executeOrderItemFromSidecar{gas: executionGas}(executionRequest) returns (
        OrderV3Types.ExecutionResult memory executionResult
    ) {
        if (executionResult.status == OrderV3Types.LifecycleStatus.Pending) {
            batchResult.stopReason = executionResult.pendingReason;
            break;
        }
        ++batchResult.terminalCount;
    }
Batch execution cannot continue to a later close after the head open reports `Pending(CloseOnly)`.
```

- `packages/perps/src/OrderRouterExecutionSidecar.sol:130`

```
head = host.nextExecuteId();
...
if (head != orderId) {
    if (madeProgress) {
        _refundEth(host, executor, msg.value);
        return result;
    }
    revert OrderRouter__OrderNotQueueHead();
}
A keeper also cannot directly execute a later close by ID while the attacker's open remains at the global head.
```

- `packages/perps/src/OrderRouterExecutionSidecar.sol:911`

```
if (block.timestamp > pending.timing.executionDeadline) {
    return (IOrderRouterExecutionHost.ItemAction.Expire, true);
}
...
return (IOrderRouterExecutionHost.ItemAction.Execute, false);
The close-only head has no pre-oracle cleanup path before its strict execution deadline; it can block the queue for the whole configured window.
```

- `packages/perps/src/router/OrderExecutionOrchestrator.sol:10`

```
uint256 internal constant DEFAULT_MAX_EXECUTION_WINDOW_SECONDS = 60;
uint256 public maxExecutionWindowSeconds = DEFAULT_MAX_EXECUTION_WINDOW_SECONDS;
The default blocking duration is up to 60 seconds and can be changed through configuration.
```

## Claim-reserved pool cash dilutes carry utilization

**Severity:** low · accounting_error

**Claim:**

The carry denominator uses gross HousePool `totalAssets` even though outstanding trader claims are senior liabilities that make the same cash unavailable for fresh payouts. A deferred profitable close increases `totalTraderClaimBalanceUsdc` without removing physical assets, so it leaves the carry denominator unchanged; the economically equivalent later claim settlement removes cash and raises utilization. Because claims are settled only when their owner calls `settleTraderClaim`, a claimant—potentially coordinating with a second account holding a carry-bearing position—can leave a large serviceable claim outstanding and suppress carry charged to all borrowers. Carry is therefore under-collected whenever claim-reserved cash is material, reducing LP revenue and understating utilization during pool illiquidity.

**Evidence:**

- `packages/perps/src/CfdEngine.sol:836`

```
uint256 physicalAssetsUsdc = pool.totalAssets();
uint256 claimsUsdc = totalTraderClaimBalanceUsdc;
assembly ("memory-safe") {
    if gt(physicalAssetsUsdc, claimsUsdc) { availableCashUsdc := sub(physicalAssetsUsdc, claimsUsdc) }
}
The engine explicitly recognizes that outstanding claims reserve physical pool assets and subtracts them for payout availability.
```

- `packages/perps/src/CfdEngine.sol:1101`

```
function _poolAssetsForCarry() internal view returns (uint256) {
    return address(pool) == address(0) ? 0 : pool.totalAssets();
}
Carry nevertheless uses gross physical assets without subtracting those senior claim liabilities.
```

- `packages/perps/src/libraries/PositionRiskAccountingLib.sol:51`

```
if (poolAssetsUsdc == 0) {
    return UTILIZATION_BPS;
}
utilizationBps = (borrowBaseUsdc * UTILIZATION_BPS) / poolAssetsUsdc;
if (utilizationBps > UTILIZATION_BPS) {
    utilizationBps = UTILIZATION_BPS;
}
A larger gross denominator directly lowers the utilization rate and therefore carry.
```

- `packages/perps/src/CfdEngine.sol:812`

```
if (_canPayFreshPoolPayout(amountUsdc)) {
    _payTraderClaim(account, amountUsdc, positionRemainsOpen);
} else {
    traderClaimBalanceUsdc[account] += amountUsdc;
    totalTraderClaimBalanceUsdc += amountUsdc;
    emit TraderClaimRecorded(account, amountUsdc);
}
When cash is reserved/insufficient, a payout becomes a claim while the physical assets—and thus the carry denominator—remain in the pool.
```

- `packages/perps/src/CfdEngine.sol:556`

```
uint256 claimAmountUsdc = _settleTraderClaimBalance(amount, account, pos.lots > 0);
...
traderClaimBalanceUsdc[account] -= claimAmountUsdc;
totalTraderClaimBalanceUsdc -= claimAmountUsdc;
Claim settlement is owner-initiated, letting a claim holder decide when physical cash finally leaves the pool and the carry denominator falls.
```

## Deferred trader claims inflate open skew capacity and reduce VPI

**Severity:** low · accounting_error

**Claim:**

Open admission and VPI use gross HousePool assets as depth without deducting outstanding senior trader claims. Settling a claim reduces pool assets and claim liabilities by the same amount, so it does not change effective solvency, but it does reduce the depth used by the skew cap and VPI curve. A claimant can therefore defer a serviceable claim and use a second account to execute a skew-increasing open against artificially high gross depth: the order can pass a larger `maxSkewRatio` limit and pay less VPI than the identical order after claim settlement, despite identical net LP assets. This permits underpriced, over-concentrated exposure backed in part by cash already owed to claimants.

**Evidence:**

- `packages/perps/src/CfdOrderPolicyEvaluator.sol:43`

```
AssessmentContext memory context = AssessmentContext(
    engineAddress,
    executor,
    executionPrice,
    IHousePool(engine.pool()).totalAssets(),
    publishTime,
    pending.executionBountyUsdc
);
The committed order's depth is the pool's gross `totalAssets`, with no deduction for engine-level claims.
```

- `packages/perps/src/libraries/CfdEnginePlanLib.sol:469`

```
if (snap.poolAssetsUsdc > 0) {
    uint256 maxSkewUsdc = Math.mulDiv(snap.poolAssetsUsdc, snap.riskParams.maxSkewRatio, CfdMath.WAD);
    if (
        inputs.postSkewUsdc > maxSkewUsdc
            && (inputs.postSkewUsdc >= inputs.preSkewUsdc || orderSideIsPostOpenHeavy)
    ) {
        delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH;
        return;
    }
}
...
inputs.poolDepthUsdc = snap.poolAssetsUsdc;
The same gross depth both expands the maximum admitted skew and reduces the VPI calculated for the open.
```

- `packages/perps/src/CfdMath.sol:133`

```
uint256 sqSkewOverDepthWad = (skewWad * skewWad) / depthWad;
...
uint256 costWad = (vpiFactorWad * sqSkewOverDepthWad) / WAD / 2;
Inflating the depth denominator directly lowers the open's skew cost and VPI charge.
```

- `packages/perps/src/CfdEngine.sol:836`

```
uint256 physicalAssetsUsdc = pool.totalAssets();
uint256 claimsUsdc = totalTraderClaimBalanceUsdc;
assembly ("memory-safe") {
    if gt(physicalAssetsUsdc, claimsUsdc) { availableCashUsdc := sub(physicalAssetsUsdc, claimsUsdc) }
}
Elsewhere the engine correctly treats claims as senior reservations against those gross physical assets.
```

- `packages/perps/src/libraries/CfdEnginePlanLib.sol:711`

```
SolvencyAccountingLib.SolvencyState memory currentState = SolvencyAccountingLib.buildSolvencyState(
    snap.poolCashUsdc,
    SolvencyAccountingLib.getMaxLiability(snap.longSide.maxProfitUsdc, snap.shortSide.maxProfitUsdc),
    snap.totalTraderClaimBalanceUsdc
);
Open solvency separately deducts claims, demonstrating that effective capital is unchanged by paying a claim even though the skew/VPI depth changes.
```

## Frequent position checkpoints discard fractional carry

**Severity:** low · accounting_error

**Claim:**

Carry realization floors each position's indexed charge to whole USDC atoms and then advances the position's `lastCarryIndex` even when the computed charge is zero. Because an account owner can call `addMargin` repeatedly with an amount as small as one atom, a trader can checkpoint whenever accrued carry is below one atom; the fractional amount is permanently discarded rather than accumulated. On low-utilization or small-borrow-base positions, repeated one-atom additions can therefore suppress some or all carry that would have become collectible if the index delta had accumulated.

**Evidence:**

- `packages/perps/src/libraries/PositionRiskAccountingLib.sol:106`

```
if (borrowBaseUsdc == 0 || carryIndexDelta == 0) {
    return 0;
}
return (borrowBaseUsdc * carryIndexDelta) / CARRY_INDEX_SCALE;
Each realization independently rounds the account's carry down to a whole 6-decimal USDC atom.
```

- `packages/perps/src/CfdEngine.sol:1356`

```
carryDue += PositionRiskAccountingLib.computeIndexedCarryUsdc(pos.borrowBaseUsdc, endIndex - pos.lastCarryIndex);
pos.lastCarryTimestamp = uint64(block.timestamp);
pos.lastCarryIndex = endIndex;
The full index delta is consumed even when its multiplication rounds to zero, so no fractional remainder survives the checkpoint.
```

- `packages/perps/src/CfdEngine.sol:498`

```
if (amount == 0) {
    revert CfdEngine__PositionTooSmall();
}
...
_realizeCarryFromSettlement(account, pos);
...
clearinghouse.lockPositionMargin(account, amount);
The position owner has a repeatable checkpoint entrypoint with no minimum above one USDC atom; carry is checkpointed before each tiny margin addition.
```

## Live oracle paths allow component skew up to staleness limits instead of the configured divergence limit

**Severity:** low · oracle_manipulation

**Claim:**

Permissionless callers can submit valid Pyth data for only a selected subset of basket feeds and leave other configured feeds at older stored observations. Live mark-refresh, pool-reconcile, frozen-order, and liquidation snapshots do not enforce `maxComponentPublishTimeDivergence`; `_policyPublishTimeDivergence` instead permits skew up to `orderExecutionStalenessLimit` (60 seconds by default), `liquidationStalenessLimit` (15 seconds), or frozen-policy staleness. An attacker can therefore construct a time-mixed basket that would fail the configured 5-second component-skew rule, install it as the engine mark, use it to trigger position protection/LP settlement, or use its side-adjusted value to liquidate accounts. This can cause premature/wrongful liquidations and settlement at a basket that never existed at one coherent observation time.

**Evidence:**

- `packages/perps/src/PletherOracle.sol:61`

```
uint256 public override orderExecutionStalenessLimit = 60; ... uint256 public override liquidationStalenessLimit = 15; ... /// @notice Maximum component publish-time divergence for uniquely parsed historical order baskets ... uint256 public override maxComponentPublishTimeDivergence = 5;
The contract exposes a narrow configured component-skew bound, but documents/uses it only for historical parsing while live-path age limits are materially wider.
```

- `packages/perps/src/PletherOracle.sol:570`

```
function _policyPublishTimeDivergence(PriceMode mode, PolicySnapshot memory policy) internal view returns (uint256) { if (mode != PriceMode.OrderExecution && policy.oracleFrozen) { return policy.maxStaleness; } return _maxPublishTimeDivergence(mode); } ... return mode == PriceMode.Liquidation ? liquidationStalenessLimit : orderExecutionStalenessLimit;
All current/live basket paths choose staleness-derived divergence instead of `maxComponentPublishTimeDivergence`.
```

- `packages/perps/src/PletherOracle.sol:489`

```
pyth.updatePriceFeeds{value: pythFee}(pythUpdateData);
The permissionless caller controls which valid Pyth update messages are supplied; no check requires an update for every configured basket feed.
```

- `packages/perps/src/PletherOracle.sol:621`

```
PythStructs.Price memory p = pyth.getPriceUnsafe(feedId); if (OracleFreshnessPolicyLib.isStale(p.publishTime, maxStaleness, block.timestamp)) { revert ...; } ... basket = _computeBasketPriceFromFeeds(mode, priceFeeds, maxPublishTimeDivergence);
Unupdated legs are read from Pyth storage and accepted whenever individually fresh under the wider age limit; the only cross-feed check receives the same wider divergence value.
```

- `packages/perps/src/PletherOracle.sol:641`

```
if (maxPublishTime > minPublishTime + maxPublishTimeDivergence) { revert PletherOracle__PublishTimeDivergence(...); } ... basket.publishTime = uint64(minPublishTime);
The basket explicitly permits any time mixing up to the caller-selected path's divergence argument and timestamps the mixed result at the oldest leg.
```

- `packages/perps/src/PletherOracle.sol:443`

```
BasketPrice memory basket = _computeLiveBasketPrice(PriceMode.Liquidation, policy.maxStaleness, _policyPublishTimeDivergence(PriceMode.Liquidation, policy)); ... snapshot = _snapshotFromBasket(...);
The manipulated mixed basket directly supplies liquidation mark and side-adverse execution prices.
```

## Observable settlement configuration digest does not commit to FAD override-calendar changes

**Severity:** low · logic_error

**Claim:**

The observable settlement configuration digest hashes fadRunwaySeconds but neither the engine's configured FAD override-day set nor CfdEngineAdmin.activeConfigVersion. Finalizing a calendar replacement can therefore change isFadWindow/isOracleFrozen on configured days—and consequently settlement execution-path and freshness policy—without changing observableConfigDigest. An unprivileged observation consumer that uses the digest to pin settlement semantics cannot distinguish observations made under different active override calendars.

**Evidence:**

- `packages/perps/src/SettlementMonitorLensSidecar.sol:1032`

```
(ok, values[4]) = _readUint(address(ENGINE), bytes4(keccak256("fadRunwaySeconds()")));
...
digest = keccak256(abi.encode(values));
The engine-policy digest includes only the FAD runway scalar; it contains no override-day data or engine-admin configuration version.
```

- `packages/perps/src/SettlementMonitorLensSidecar.sol:978`

```
bytes32 engineDigest = keccak256(
    abi.encode(
        address(ENGINE),
        address(ENGINE_PROTOCOL_LENS),
        address(CLEARINGHOUSE),
        address(TERMINAL_NAV_BOOK),
        address(ENGINE.planner()),
        address(ENGINE.settlementSidecar()),
        ENGINE.admin()
    )
);
The wiring digest commits only to the admin address, not CfdEngineAdmin.activeConfigVersion, so finalizations at the same admin address are invisible unless every changed field is separately hashed.
```

- `packages/perps/src/CfdEngineAdmin.sol:173`

```
function finalizeCalendarConfig() external onlyOwner {
    _requireTimelockReady(calendarConfigActivationTime);
    ICfdEngineAdminHost.EngineCalendarConfig memory config = _pendingCalendarConfig;
    delete _pendingCalendarConfig.fadDayTimestamps;
    calendarConfigActivationTime = 0;
    engine.applyCalendarConfig(config);
    activeConfigVersion += 1;
    emit CalendarConfigFinalized(config);
}
Calendar replacements are real mutable configuration transitions and increment a readily observable version, but that version is not included in the monitor digest.
```

- `packages/perps/src/interfaces/ICfdEngineAdminHost.sol:21`

```
/// @param fadDayTimestamps Unix timestamps whose normalized UTC day numbers are configured as all-day FAD and
///        oracle-frozen overrides...
struct EngineCalendarConfig {
    uint256[] fadDayTimestamps;
    uint256 fadRunwaySeconds;
}
The omitted day set changes both FAD and oracle-frozen policy, which feed settlement classification and freshness behavior.
```

## Ordinary close orders are forced to carry no execution bounty

**Severity:** low · denial_of_service

**Claim:**

An unprivileged trader with a live position can commit an ordinary close order that is appended to the global FIFO, but `_validatedCloseBounty` always returns the router's close bounty and the admin validation requires that value to remain exactly zero. The terminal settlement path only credits an executor when the recorded reservation is nonzero. Consequently every ordinary close can occupy the global FIFO head without funding the keeper who must pay oracle fees and gas to process it; repeated zero-bounty closes can economically stall execution of later users' funded orders, and governance cannot configure a nonzero close incentive through the provided timelocked config path.

**Evidence:**

- `packages/perps/src/router/OrderLiquidationBatchLogic.sol:349`

```
return host.closeOrderExecutionBountyUsdc();
Every public close commit derives its recorded execution bounty solely from this router configuration value.
```

- `packages/perps/src/OrderRouterAdmin.sol:361`

```
config.openOrderExecutionBountyBps == 0 || config.openOrderExecutionBountyBps > 10_000
                || config.minOpenOrderExecutionBountyUsdc == 0 || config.maxOpenOrderExecutionBountyUsdc == 0
                || config.closeOrderExecutionBountyUsdc != 0 || config.positionProtectionTriggerBountyUsdc == 0
Any attempt to configure an ordinary close bounty above zero is rejected, so the zero-bounty policy cannot be remediated through normal configuration.
```

- `packages/perps/src/router/OrderRouterBase.sol:85`

```
closeOrderExecutionBountyUsdc = 0;
The deployed default is zero and the admin constraint keeps it zero.
```

- `packages/perps/src/OrderRouter.sol:300`

```
if (bountyUsdc != 0) {
            settlement.bountyRecipient = bountyRecipient;
            settlement.bountyDisposition = OrderV3Types.BountyDisposition.Paid;
            if (bountyRecipient == order.account) {
                clearinghouse.releaseReservedExecutionBountyToSource(order.account, bountyUsdc);
            } else {
                engine.creditBounty(order.account, bountyRecipient, bountyUsdc, accountingPrice, accountingPublishTime);
            }
        }
The executor receives no credit at all for a zero-bounty close, although it still incurs execution costs.
```

- `packages/perps/src/router/OrderQueueBook.sol:26`

```
if (tailOrderId == 0) {
            nextExecuteId = orderId;
            globalTailOrderId = orderId;
            return;
        }

        orderRecords[tailOrderId].nextGlobalOrderId = orderId;
The unbountied close is inserted into the same global FIFO whose head gates later processing.
```

## Permissionless frozen-state settlement can apply an unsnapshotted redemption fee

**Severity:** low · logic_error

**Claim:**

A user can request redemption while the oracle is live without committing to a maximum settlement fee, but after the request matures it cannot be cancelled and any unprivileged caller may settle it while `oracleFrozen` is true. That caller causes HousePool to price and burn the victim's queued shares using the configured frozen fee (up to 10%), even if waiting until the live-oracle state would apply zero fee; the net-only principal deduction leaves the withheld value with remaining LPs. A remaining LP can therefore time permissionless settlement during a frozen window to transfer up to the configured fee fraction from matured redeemers to continuing tranche holders.

**Evidence:**

- `packages/perps/src/TrancheVault.sol:602`

```
function requestRedeem(...) ... _transfer(owner, address(this), shares); requestId = _enqueueRedeemRequest(shares, controller);
The request escrows shares but stores no user-supplied maximum fee or minimum assets constraint.
```

- `packages/perps/src/TrancheVault.sol:869`

```
if (currentLpEpoch() >= requestId || epoch.fundedShares != 0 || epoch.fundedAssets != 0 || epoch.refundEnabled) { revert TrancheVault__RedeemCancellationUnavailable(); }
Once the request is mature, its controller cannot cancel to avoid an unfavorable frozen-fee settlement.
```

- `packages/perps/src/HousePool.sol:773`

```
if (accountingSnapshot.hasOpenPositions && !statusSnapshot.oracleFrozen) { if (msg.sender != ENGINE.orderRouter() ... ) revert HousePool__Unauthorized(); } return _settleLpEpoch(...);
The router authorization is deliberately bypassed in the frozen branch, so an arbitrary EOA can choose the frozen settlement timing.
```

- `packages/perps/src/HousePool.sol:1130`

```
if (!oracleFrozen) { return 0; } return isSenior ? poolConfig.seniorFrozenLpFeeBps : poolConfig.juniorFrozenLpFeeBps;
The fee is determined at execution time from oracle state rather than snapshotted or bounded by the redeemer.
```

- `packages/perps/src/HousePool.sol:171`

```
MAX_FROZEN_LP_FEE_BPS = 1000; ... netAssetsForShares(..., feeBps) ... accountedAssets -= seniorPhase.fundedAssets / juniorPhase.fundedAssets
Configuration permits a 10% fee and only the net funded assets are removed from principal/accounted custody, so withheld value remains for continuing LPs.
```

## Protection trigger bounty is paid before a zero-bounty close is executed

**Severity:** low · logic_error

**Claim:**

A permissionless caller can collect the entire position-protection trigger bounty as soon as a trigger is observed and a close attempt is merely queued, while the queued close and every retry carry a zero execution bounty. The caller can abandon the flow after receiving payment; because same-block execution is normally disallowed and later execution requires another oracle-funded transaction, unrelated keepers have no order-specific compensation to finish the close. The protection becomes Triggered (and later Latched on expiry/failure), cannot be cancelled through the pre-trigger cancellation path, and the protected position can remain open through its stop-loss/take-profit threshold and incur further loss or liquidation.

**Evidence:**

- `packages/perps/src/router/OrderLiquidationBatchLogic.sol:584`

```
_registerProtectionTrigger(host, protectionId, linkedOrderId, plan); _queueProtectionAttempt(host, linkedOrderId, plan.account, plan.side, plan.size); engine.creditBounty(plan.account, refundRecipient, plan.triggerBountyUsdc, snapshot.markPrice, snapshot.publishTime);
The trigger bounty is irreversibly credited to the permissionless trigger caller immediately after queue insertion, not after close execution.
```

- `packages/perps/src/router/OrderLiquidationBatchLogic.sol:659`

```
abi.encodeWithSelector(IOrderLiquidationBatchHost.executePositionProtectionTriggerItem.selector, linkedOrderId, account, side, size, 0)
The generated protection close is explicitly queued with zero execution bounty.
```

- `packages/perps/src/OrderRouter.sol:426`

```
clearinghouse.recordBountyReservation(account, IMarginClearinghouse.BountyKind.Order, linkedOrderId, 0); _recordCommittedOrder(CfdTypes.Order({ ... isClose: true }))
Router storage confirms the child close has a zero-valued order bounty reservation.
```

- `packages/perps/src/router/OrderLiquidationBatchLogic.sol:177`

```
msg.sender != address(host.positionProtectionBook()) || account == address(0) || size == 0 || executionBountyUsdc != 0
Every later protection retry is also required to have zero execution bounty.
```

- `packages/perps/src/PositionProtectionBook.sol:297`

```
if (status != PositionProtectionStatus.PendingOpen && status != PositionProtectionStatus.Armed) { revert OrderRouter__ProtectionNotArmed(); }
Official linked implementation only permits cancellation before triggering; a Triggered or Latched protection cannot be cancelled to regain ordinary close control.
```

## Redeem allocation dust returned to the pool is not restored to pool accounting

**Severity:** low · accounting_error

**Claim:**

When an epoch contains multiple controller positions, per-position floor division can leave `assetDust = epoch.fundedAssets - epoch.claimedAssets`. After every position has processed its funding basis, `_maybeProcessRedeemFunding` transfers that USDC dust back to HousePool, but HousePool had already reduced both `accountedAssets` and tranche principal by the entire funded amount and no callback restores either value. The returned USDC therefore becomes unaccounted excess rather than LP-owned principal. An unprivileged LP can trigger and amplify this mismatch by splitting redeem requests among many controller positions in one epoch; the direct loss is bounded to less than one USDC atom per position but persists until a privileged `accountExcess` action and is otherwise sweepable as excess.

**Evidence:**

- `packages/perps/src/HousePool.sol:839`

```
accountedAssets -= seniorPhase.fundedAssets; ... juniorPrincipal -= juniorPhase.fundedAssets; accountedAssets -= juniorPhase.fundedAssets;
The pool removes the full epoch funding amount from accounted custody and tranche principal before claims are allocated among controllers.
```

- `packages/perps/src/TrancheVault.sol:1216`

```
uint256 entitledAssets = entitledShares == 0 ? 0 : Math.mulDiv(position.shares, epoch.fundedAssets, epoch.shares, Math.Rounding.Floor); ... if (epoch.fundingBasisClaimed == epoch.shares) { ... uint256 assetDust = epoch.fundedAssets - epoch.claimedAssets; if (assetDust != 0) { epoch.claimedAssets += assetDust; withdrawalEscrowAssets -= assetDust; IERC20(asset()).safeTransfer(address(POOL), assetDust); } }
Per-position floor allocation creates aggregate asset dust, which is physically sent back to the pool without an accounting callback.
```

- `packages/perps/src/HousePool.sol:540`

```
uint256 raw = rawAssets(); return raw > accountedAssets ? raw - accountedAssets : 0;
USDC returned without incrementing `accountedAssets` is classified as excess and can be swept rather than remaining in LP accounting.
```

## Refundable senior reservations allow temporary capacity denial

**Severity:** low · denial_of_service

**Claim:**

A senior deposit request immediately consumes global senior capacity through `reserveSeniorDeposit`, but the requester may cancel it at any time before its future epoch matures and recover all escrowed USDC with no fee. An unprivileged account can therefore front-run another senior depositor with a capacity-filling request so the victim's request fails its max-capacity check, then cancel and recover the reservation after the victim transaction. Repeating this provides transaction-level or sustained denial of senior deposit admission at only gas and temporary capital cost.

**Evidence:**

- `packages/perps/src/TrancheVault.sol:573`

```
_requireRequestDepositPreflight(assets, controller, owner); if (IS_SENIOR) { POOL.reserveSeniorDeposit(assets); } IERC20(asset()).safeTransferFrom(owner, address(this), assets);
Every senior request reserves shared capacity immediately before escrowing the requester's assets.
```

- `packages/perps/src/HousePool.sol:750`

```
_requireSeniorDepositCapacity(amount, ctx.pendingState.waterfall); reservedSeniorDepositAssetsUsdc += amount;
Reservations directly reduce capacity available to subsequent senior deposit requests.
```

- `packages/perps/src/libraries/HousePoolSeniorCapacityLib.sol:27`

```
uint256 remaining = limit - exposure; return reservedSeniorDepositAssetsUsdc < remaining ? remaining - reservedSeniorDepositAssetsUsdc : 0;
A capacity-filling pending reservation makes every later request report zero capacity.
```

- `packages/perps/src/TrancheVault.sol:821`

```
if (currentLpEpoch() >= requestId && !queueState.rejected && !_projectedTerminalWipe()) { ... revert TrancheVault__DepositEpochAlreadyActive(); } ... if (IS_SENIOR && !queueState.rejected) { POOL.releaseSeniorDepositReservation(assets); } IERC20(asset()).safeTransfer(receiver, assets);
Before maturity (`currentLpEpoch() < requestId`), cancellation is unconditional after controller authorization, releases the full reservation, and refunds all assets.
```

## Stale cached marks can underfund open-order bounties and global FIFO cleanup

**Severity:** low · denial_of_service

**Claim:**

An unprivileged trader can commit open orders while the engine mark is arbitrarily stale. `_validatedOpenBounty` prices both minimum notional and the execution bounty from `engine.lastMarkPrice()` (or a fixed 1e8 fallback), but stale marks only disable predictable-invalid rejection rather than rejecting admission. If the post-commit historical execution price is materially higher than the stale mark, the order can represent a much larger execution workload/notional—or become planner-invalid—while reserving only the bounty computed from the old price. By repeating this across accounts, an attacker can place cheaply funded orders into the shared global FIFO whose oracle update and engine/planner cleanup costs are borne by keepers for an understated bounty, degrading permissionless execution of later users' orders.

**Evidence:**

- `packages/perps/src/router/OrderLiquidationBatchLogic.sol:396`

```
uint256 commitPrice = _commitReferencePrice(engine); ... uint256 notionalUsdc = lots * commitPrice; ... executionBountyUsdc = (notionalUsdc * host.openOrderExecutionBountyBps()) / 10_000;
The admitted notional and reserved keeper bounty are derived entirely from the cached engine mark.
```

- `packages/perps/src/router/OrderLiquidationBatchLogic.sol:409`

```
if (commitMarkTime != 0) { ... if (!OracleFreshnessPolicyLib.isStale(commitMarkTime, policy.maxStaleness, block.timestamp)) { ... if (OrderFailurePolicyLib.isPredictablyInvalidOpen(failureCategory)) { revert ...; } } }
Staleness is used only to skip predictable-invalid filtering; there is no stale-mark admission revert.
```

- `packages/perps/src/router/OrderLiquidationBatchLogic.sol:437`

```
price = engine.lastMarkPrice(); if (price == 0) { price = 1e8; } ... return price > capPrice ? capPrice : price;
Even an uninitialized mark is replaced by a fixed reference rather than requiring a fresh oracle observation.
```

- `packages/perps/src/router/OrderReservationAccounting.sol:113`

```
effects.bountyFromFreeUsdc = bounty; ... clearinghouse.lockReservedSettlement(account, bounty);
Only the stale-price-derived amount is locked for subsequent keeper compensation.
```

- `packages/perps/src/router/OrderCommitHandler.sol:54`

```
_linkGlobalOrder(orderId); ... if (++pendingOrderCounts[account] > maxPendingOrders) { revert ...; }
Each admitted order joins the shared FIFO; the cap is per account and can be multiplied across attacker-controlled accounts.
```

## Current pool depth is applied retroactively to the full carry interval

**Severity:** info · price_manipulation

**Claim:**

CfdEngine._advanceAllCarryIndexes accrues the entire elapsed interval using one instantaneous HousePool.totalAssets() observation, while checkpointCarryIndexes is permissionless. An unprivileged position holder who can temporarily add HousePool liquidity immediately before checkpointing can make computeBorrowUtilizationBps use the inflated denominator for all time since sideCarryTimestamp, then remove that liquidity after the checkpoint. This understates the holder's indexed carry and permanently reduces carry collected on a later close, liquidation, margin change, or claim settlement; the inverse manipulation can overcharge other positions if pool assets can be temporarily reduced.

**Evidence:**

- `packages/perps/src/CfdEngine.sol:1065`

```
function checkpointCarryIndexes() external {
        _advanceAllCarryIndexes(block.timestamp);
    }
Any account can choose the exact instant at which the sampled pool balance is committed into the carry index.
```

- `packages/perps/src/CfdEngine.sol:1069`

```
uint256 poolAssetsUsdc = _poolAssetsForCarry();
        for (uint256 index; index < 2; ++index) {
            if (timestampNow > sideCarryTimestamp[index]) {
                sideCarryIndex[index] = _currentSideCarryIndex(CfdTypes.Side(index), timestampNow, poolAssetsUsdc);
                sideCarryTimestamp[index] = uint64(timestampNow);
            }
        }
A single current pool-assets sample is used when advancing from the old timestamp to the current timestamp.
```

- `packages/perps/src/libraries/PositionRiskAccountingLib.sol:79`

```
index += (baseCarryBps * utilizationBps * CARRY_INDEX_SCALE * (currentTimestamp - previousTimestamp))
            / (CfdMath.SECONDS_PER_YEAR * UTILIZATION_BPS * 10_000);
The utilization computed from the instantaneous sample is multiplied by the whole elapsed duration rather than being time-weighted across pool-asset changes.
```

- `packages/perps/src/libraries/PositionRiskAccountingLib.sol:51`

```
utilizationBps = (borrowBaseUsdc * UTILIZATION_BPS) / poolAssetsUsdc;
Increasing current pool assets directly decreases the utilization and therefore the carry index increment.
```

## Direct expiry omits the accounting mark required to pay a nonzero keeper bounty

**Severity:** info · denial_of_service

**Claim:**

The permissionless `expireOrder(orderId)` path constructs an `ItemRequest` with only order ID, action, and executor, leaving `bountyAccountingPrice` and `bountyAccountingPublishTime` zero. Normal expired orders then call `settleOrderFromSidecar`, which pays their nonzero open-order bounty by calling `engine.creditBounty` with those zero accounting inputs. Other pre-oracle cleanup paths explicitly replace a zero stored mark with `1e8` and pass `engine.lastMarkTime()`, indicating that raw zero is not a valid bounty-accounting observation. As a result, a third-party direct expiry of a normally funded open order can revert in engine bounty accounting; unlike FIFO cleanup, the documented non-head expiry path cannot release that order's committed margin, bounty, and pending-order slot until the account itself expires it (which takes the refund branch) or all earlier FIFO orders permit batch cleanup.

**Evidence:**

- `packages/perps/src/OrderRecoverySidecar.sol:43`

```
IOrderRouterExecutionHost.ItemRequest memory request; request.orderId = orderId; request.action = IOrderRouterExecutionHost.ItemAction.Expire; request.executor = msg.sender; return host.executeOrderItemFromSidecar(request);
The direct expiry request leaves both bounty accounting price and publish time at Solidity's zero defaults.
```

- `packages/perps/src/OrderRecoverySidecar.sol:125`

```
return host.settleOrderFromSidecar(request.orderId, false, reason, request.executor, request.executionPrice, request.bountyAccountingPrice, request.bountyAccountingPublishTime);
The omitted zero values are forwarded unchanged into terminal bounty settlement.
```

- `packages/perps/src/OrderRouter.sol:288`

```
if (bountyRecipient == order.account) { clearinghouse.releaseReservedExecutionBountyToSource(order.account, bountyUsdc); } else { engine.creditBounty(order.account, bountyRecipient, bountyUsdc, accountingPrice, accountingPublishTime); }
Any permissionless caller other than the order account takes the `creditBounty` path with price/time equal to zero.
```

- `packages/perps/src/OrderRouterExecutionSidecar.sol:936`

```
request.bountyAccountingPrice = _bountyAccountingStoredMark(engine_); request.bountyAccountingPublishTime = engine_.lastMarkTime();
FIFO expiry/config cleanup deliberately supplies a valid stored accounting observation, demonstrating the direct path's asymmetry.
```

- `packages/perps/src/OrderRouterExecutionSidecar.sol:1130`

```
price = engine_.lastMarkPrice(); if (price == 0) { price = 1e8; } uint256 capPrice = engine_.CAP_PRICE(); return price > capPrice ? capPrice : price;
The sidecar explicitly prevents a zero accounting price even before an engine mark exists, a safeguard absent from direct expiry.
```

- `packages/perps/src/router/OrderLiquidationBatchLogic.sol:389`

```
executionBountyUsdc = (notionalUsdc * host.openOrderExecutionBountyBps()) / 10_000; ... if (executionBountyUsdc < minimumBountyUsdc) { executionBountyUsdc = minimumBountyUsdc; }
Ordinary open orders normally carry a nonzero configured bounty, so this is not limited to an exotic zero-bounty record.
```

## Failed protection attempts unconditionally pay the bounty instead of retaining it for retry

**Severity:** info · accounting_error

**Claim:**

When a registered position-protection close attempt fails or expires, `_settleTerminalBounty` calls `handleFailedProtectionAttempt` to relatch the protection but then unconditionally removes the order bounty reservation, labels it `Paid`, and credits the terminal caller. There is no branch that returns `RetainedForProtectionRetry`, despite the execution-host contract explicitly defining that outcome for failed protection attempts. A permissionless keeper can wait for a triggered protection order to expire (or process another terminal failure), receive the one reserved execution bounty, and leave the relatched retry created through `commitProtectionCloseAttempt` with the mandated zero execution bounty. Depending on the Book's reservation migration, the unconditional credit can additionally debit value after the handler has moved the original reservation into retained protection funding.

**Evidence:**

- `packages/perps/src/OrderRouter.sol:288`

```
if (!success && lifecycleBook.isProtectionAttempt(order.orderId)) {
    positionProtectionBook.handleFailedProtectionAttempt(order.orderId, order.account, reason, bountyUsdc);
}
// Even an unpaid attempt has an authenticated Active record that must terminalize.
clearinghouse.takeBountyReservation(order.account, IMarginClearinghouse.BountyKind.Order, order.orderId);
settlement.bountyUsdc = bountyUsdc;
if (bountyUsdc != 0) {
    settlement.bountyRecipient = bountyRecipient;
    settlement.bountyDisposition = OrderV3Types.BountyDisposition.Paid;
    ...
    engine.creditBounty(order.account, bountyRecipient, bountyUsdc, accountingPrice, accountingPublishTime);
}
The protection-failure hook is immediately followed by unconditional reservation consumption and caller payment; no retained settlement can be returned.
```

- `packages/perps/src/interfaces/IOrderRouterExecutionHost.sol:66`

```
/// @notice Canonical execution-bounty outcome returned by Router accounting.
/// @dev Protection attempts may retain their bounty in the protection Book instead of paying the terminal caller.
struct BountySettlement {
    uint256 bountyUsdc;
    uint256 bountyRefundedUsdc;
    address bountyRecipient;
    OrderV3Types.BountyDisposition bountyDisposition;
}
The host boundary explicitly requires a possible retained outcome, but the Router implementation always emits `Paid` for every nonzero protection-attempt bounty.
```

- `packages/perps/src/OrderV3Types.sol:78`

```
enum BountyDisposition {
    None,
    Paid,
    Forfeited,
    RefundedToAccount,
    /// @notice The bounty remains reserved for a fresh attempt of the same latched position protection.
    RetainedForProtectionRetry,
    ...
}
The canonical receipt model contains the exact disposition omitted from `_settleTerminalBounty`.
```

- `packages/perps/src/router/OrderLiquidationBatchLogic.sol:168`

```
if (
    msg.sender != address(host.positionProtectionBook()) || account == address(0) || size == 0
        || executionBountyUsdc != 0
) {
    revert OrderRouter__Unauthorized();
}
...
host.lifecycleBook().registerPending(account, orderId, request, executionBountyUsdc);
Fresh retries are required to have a zero order bounty, so paying away rather than retaining the original protection funding leaves subsequent attempts without that keeper incentive.
```

- `packages/perps/src/OrderRecoverySidecar.sol:88`

```
IOrderRouterExecutionHost.BountySettlement memory settled = _settle(host, request, reason);
...
receipt.bountyDisposition = settled.bountyDisposition;
receipt.bountyRecipient = settled.bountyRecipient;
...
if (settled.bountyDisposition == OrderV3Types.BountyDisposition.Paid) {
    receipt.bounty.bountyPaidUsdc = settled.bountyUsdc - settled.bountyRefundedUsdc;
}
Expiry and other non-engine failures faithfully record the Router's unconditional `Paid` result, making the premature payout terminal.
```

## Later mark refresh can make live historical-price orders permanently out of order

**Severity:** info · denial_of_service

**Claim:**

An unprivileged caller can advance the engine mark timestamp through permissionless `updateMarkPrice` after an order's finite historical settlement window but before its longer execution deadline. Subsequent order execution must use a historical Pyth basket published inside `(commitTime, commitTime + orderSettlementWindow]`; when that basket predates `engine.lastMarkTime`, `_updateEngineMark` deliberately skips installing it and `processOrderTyped` can return `CfdEngine__MarkPriceOutOfOrder`, which the router treats as retryable and leaves pending. Because no later basket can satisfy the closed historical window, the order cannot execute and eventually expires; the griefer can then call `expireOrder` and receive the reserved execution bounty. One mark refresh can affect consecutive queued orders whose settlement windows have closed.

**Evidence:**

- `packages/perps/src/router/OrderLiquidationBatchLogic.sol:562`

```
function updateMarkPrice(bytes[] calldata pythUpdateData) external payable {
    _requireDelegateCall();
    ...
    IPletherOracle.PriceSnapshot memory snapshot = host.pletherOracle().updatePrice{value: msg.value}(...);
    ICfdEngineCore engine = host.engine();
    engine.updateMarkPrice(snapshot.markPrice, snapshot.publishTime);
}
The Router exposes this delegated path permissionlessly, so any caller with valid Pyth data and the fee can advance the canonical engine mark.
```

- `packages/perps/src/PletherOracle.sol:517`

```
uint64 minPublishTime = request.commitTime + 1;
uint256 settlementDeadline = uint256(request.commitTime) + orderSettlementWindow;
uint64 maxPublishTime = uint64(settlementDeadline < block.timestamp ? settlementDeadline : block.timestamp);
try pyth.parsePriceFeedUpdatesUnique{value: pythFee}(
    pythUpdateData, pythFeedIds, minPublishTime, maxPublishTime
)
Live delayed orders are constrained to a fixed historical interval that stops at `commitTime + orderSettlementWindow`; they cannot choose a later tick after the engine mark has advanced.
```

- `packages/perps/src/OrderRouterExecutionSidecar.sol:1040`

```
ICfdEngineCore engine_ = ICfdEngineCore(host.engine());
if (result.publishTime >= engine_.lastMarkTime()) {
    engine_.updateMarkPrice(result.neutralMarkPrice, result.publishTime);
}
A historical execution basket older than a permissionlessly advanced mark is not installed, yet execution continues using that older basket timestamp.
```

- `packages/perps/src/OrderRouterExecutionSidecar.sol:601`

```
bytes memory engineCall = abi.encodeCall(
    ICfdEngineCore.processOrderTyped,
    (context.order, request.executionPrice, request.poolDepthUsdc, request.oraclePublishTime)
);
The old historical publish time is forwarded to the engine's order-processing boundary.
```

- `packages/perps/src/OrderRouterExecutionSidecar.sol:1280`

```
if (
    innerSelector == ICfdEngineTypes.CfdEngine__MarkPriceOutOfOrder.selector
        || innerSelector == OrderRouter__MarkPriceOutOfOrder.selector
) {
    return OrderV3Types.PendingReason.MarkPriceOutOfOrder;
}
The out-of-order failure is explicitly converted into a pending result rather than terminalizing or recovering the order.
```

- `packages/perps/src/OrderRouter.sol:288`

```
settlement.bountyRecipient = bountyRecipient;
settlement.bountyDisposition = OrderV3Types.BountyDisposition.Paid;
if (bountyRecipient == order.account) {
    clearinghouse.releaseReservedExecutionBountyToSource(order.account, bountyUsdc);
} else {
    engine.creditBounty(order.account, bountyRecipient, bountyUsdc, accountingPrice, accountingPublishTime);
}
When the blocked order later expires, the permissionless expiry caller is used as `bountyRecipient` and can collect the trader-funded bounty.
```

## Lifecycle commitment validation rejects every pledge-funded close bounty

**Severity:** info · denial_of_service

**Claim:**

The close-order admission path delegates bounty sourcing to `engine.reserveCloseOrderExecutionBounty`, whose returned `CloseCommitment` can represent free-funded and pledge-funded portions plus a source position epoch. The Router then records those effects in `OrderLifecycleBook`, but `recordCommitment` requires the entire bounty to be free-funded and unconditionally rejects any nonzero pledge amount or source epoch. Consequently, under the supported nonzero close-bounty configuration, an unprivileged trader whose free settlement is insufficient and whose engine reservation falls back to position pledge cannot commit a risk-reducing close even though the surrounding Router, error, and recovery surfaces explicitly support pledge-funded bounties. The trader can be forced to add free funds or remain exposed and potentially become liquidatable.

**Evidence:**

- `packages/perps/src/router/OrderRouterBase.sol:107`

```
function _reserveCloseExecutionBounty(
    address account,
    uint256 sizeDelta,
    uint256 executionBountyUsdc
) internal override returns (CfdEnginePlanTypes.CloseCommitment memory) {
    return engine.reserveCloseOrderExecutionBounty(account, sizeDelta, executionBountyUsdc);
}
The engine is the canonical component that chooses and returns close-bounty funding effects, including the free/pledge split encoded by `CloseCommitment`.
```

- `packages/perps/src/router/OrderRouterBase.sol:115`

```
function _onOrderCommitted(
    CfdTypes.Order memory order,
    CfdEnginePlanTypes.CloseCommitment memory effects,
    uint64 sourcePositionEpoch
) internal override {
    lifecycleBook.recordCommitment(order.orderId, effects, sourcePositionEpoch);
}
Every successful engine-side reservation must pass the lifecycle validation before the close commit can complete.
```

- `packages/perps/src/OrderLifecycleBook.sol:324`

```
if (
    effects.settlementBeforeUsdc != effects.settlementAfterUsdc + effects.carryCollectedUsdc
        || effects.bountyFromFreeUsdc != pending.executionBountyUsdc || effects.bountyFromPledgeUsdc != 0
        || sourceEpoch != 0
) {
    revert OrderLifecycleBook__InvalidCommitmentEffects();
}
This condition rejects all split or fully pledge-funded bounties, regardless of whether the Engine legitimately reserved them.
```

- `packages/perps/src/router/OrderLiquidationBatchLogic.sol:329`

```
return host.closeOrderExecutionBountyUsdc();
Close orders can carry a configured positive bounty, making the incompatible pledge fallback reachable in normal operation.
```

- `packages/perps/src/interfaces/IOrderRouterErrors.sol:13`

```
/// @notice Pledge-funded bounty must belong to the first pending order of its source position.
error OrderRouter__PledgeBountyRequiresEmptyQueue();
The Router's own public error surface documents pledge-funded close bounties as supported subject to queue ownership, rather than forbidden.
```

- `packages/perps/src/OrderRouter.sol:184`

```
uint256 freeUsdc = lifecycleBook.isProtectionAttempt(orderId)
    ? pending.executionBountyUsdc
    : pending.commitment.bountyFromFreeUsdc;
uint256 pledgeUsdc = pending.commitment.bountyFromPledgeUsdc;
uint64 epoch = lifecycleBook.sourcePositionEpoch(orderId);
recovery = clearinghouse.recoverExpiredBounty(order.account, orderId, freeUsdc, pledgeUsdc, epoch);
Terminal recovery is explicitly implemented for the pledge amount and source epoch that `recordCommitment` makes impossible to store.
```

## Observable settlement configuration digest omits a pool-reconcile oracle policy field

**Severity:** info · logic_error

**Claim:**

SettlementMonitorLensSidecar's observable configuration digest does not commit to IPletherOracle.maxComponentPublishTimeDivergence even though getLatestPoolReconcilePrice enforces that value. Consequently, an oracle configuration change that only alters the allowed component publish-time divergence leaves observableConfigDigest unchanged while changing whether the same feed snapshot is accepted. An unprivileged observer or settlement automation caller that pins observations by this digest can therefore treat materially different oracle-validation policies as the same configuration, undermining configuration-change detection and replay/integrity checks around settlement observations.

**Evidence:**

- `packages/perps/src/SettlementMonitorLensSidecar.sol:1071`

```
function _oraclePolicyConfigDigest(address oracle) internal view returns (bool available, bytes32 digest) {
    (bool oracleDivergenceOk, uint256 oracleDivergence) =
        _readUint(oracle, bytes4(keccak256("orderExecutionStalenessLimit()")));
    (bool confidenceOk, uint256 confidenceRatio) =
        _readUint(oracle, bytes4(keccak256("basketMaxConfidenceRatioBps()")));
    ...
    digest = keccak256(abi.encode(oracleDivergence, confidenceRatio));
}
The oracle-policy sub-digest includes only order-execution staleness and confidence ratio; it does not read or hash maxComponentPublishTimeDivergence.
```

- `packages/perps/src/interfaces/IPletherOracle.sol:320`

```
/// @dev Applies exactly the same freshness, confidence-width, component-timing, and publish-order validation as
///      `getLatestPrice(PriceMode.PoolReconcile)`.
function getLatestPoolReconcilePrice() external view returns (PriceSnapshot memory snapshot, uint256 confidence);
The oracle snapshot consumed by settlement monitoring explicitly enforces component-timing policy.
```

- `packages/perps/src/interfaces/IPletherOracle.sol:87`

```
/// @param maxComponentPublishTimeDivergence Maximum component-time divergence for a historical basket, in seconds.
struct OracleConfig {
    uint256 orderExecutionStalenessLimit;
    uint256 liquidationStalenessLimit;
    uint256 basketMaxConfidenceRatioBps;
    uint256 orderSettlementWindow;
    uint256 maxComponentPublishTimeDivergence;
    uint256 adverseConfidenceMultiplierBps;
}
The omitted component-timing bound is a first-class mutable oracle configuration value.
```

- `packages/perps/src/SettlementMonitorLensSidecar.sol:938`

```
digest = keccak256(
    abi.encode(
        CONFIG_DOMAIN,
        CONFIG_SCHEMA_VERSION,
        block.chainid,
        MONITOR,
        wiringDigest,
        epochDigest,
        policyDigest,
        seedDigest
    )
);
The externally exposed digest relies on the incomplete policyDigest, so no outer layer commits to the omitted oracle field.
```

## Open previews invert long and short liquidation-price search directions

**Severity:** info · logic_error

**Claim:**

For every valid `previewOpen`/`quoteMaxOpen` result, `_findLiquidationPrice` chooses the monotonic search logic for the opposite side. A normal long is liquidatable toward price zero and healthy toward `CAP_PRICE`, but the LONG branch first requires liquidation at the cap and otherwise reports no boundary; conversely, a normal short is liquidatable toward the cap, but the SHORT branch first requires liquidation at zero. Consequently `hasLiquidationPrice` can be false, or the returned threshold can be zero/cap, even though a liquidation threshold exists inside the range. Unprivileged traders and integrations that use the advertised preview boundary can therefore materially misjudge post-open liquidation risk.

**Evidence:**

- `packages/perps/src/CfdEngineLens.sol:298`

```
(preview.hasLiquidationPrice, preview.liquidationPrice) = _findLiquidationPrice(
    projected, delta.newPosEntryCostUsdcAtoms, snap.capPrice, reachableCollateralUsdc, maintenanceBps
);
Every valid open and maximum-open preview exposes the boundary computed by the suspect helper.
```

- `packages/perps/src/CfdEngineLens.sol:497`

```
if (projected.side == CfdTypes.Side.LONG) {
    if (!liquidatableAtCap) {
        return (false, 0);
    }
    if (liquidatableAtZero) {
        return (true, 0);
    }
    ...
}

if (!liquidatableAtZero) {
    return (false, 0);
}
if (liquidatableAtCap) {
    return (true, capPrice);
}
The LONG branch assumes risk increases with price, while the other branch assumes risk decreases with price—the opposite of long and short price PnL monotonicity.
```

- `packages/perps/src/CfdEngineLens.sol:559`

```
return PositionRiskAccountingLib.buildExactPriceRiskState(
    projected, entryCostUsdcAtoms, price, capPrice, reachableCollateralUsdc, maintenanceBps
)
.liquidatable;
The endpoint and binary-search decisions are based directly on exact-price liquidation state, so choosing the wrong directional endpoint changes the returned result rather than merely its presentation.
```

## Open quote pruning underflows when costs reduce existing position margin

**Severity:** info · denial_of_service

**Claim:**

CfdEngineOpenQuoter._maxAffordableMargin unconditionally computes resultingPositionMarginUsdc - snapshot.position.margin, although the canonical planner explicitly handles resulting margin at or below the old margin by treating newly available pledge as zero. For a same-side increase whose positive VPI/fees consume more margin than the order adds, an otherwise representable planner outcome can therefore make quote() panic during pruning instead of returning a maximum size and limiting reason, denying the account's open-quote path.

**Evidence:**

- `packages/perps/src/CfdEngineOpenQuoter.sol:306`

```
uint256 maxNewPledge = cost.resultingPositionMarginUsdc - ctx.snap.position.margin;
The subtraction is checked and panics whenever the open-cost result is below the pre-open position margin.
```

- `packages/perps/src/libraries/CfdEnginePlanLib.sol:544`

```
uint256 newPledgeAvailableUsdc = openCostPlan.resultingPositionMarginUsdc > snap.position.margin ? openCostPlan.resultingPositionMarginUsdc - snap.position.margin : 0;
The authoritative planner recognizes resulting margin may not exceed old margin and safely maps that case to zero new pledge.
```

- `packages/perps/src/CfdEngineOpenQuoter.sol:237`

```
if (!_mayMeetMarginRequirements(ctx, low, minVpi, maxVpi)) { return false; }
The unsafe affordability calculation is reached in the search/pruning path before quote can return a diagnostic delta.
```

- `packages/perps/src/CfdEngineOpenQuoter.sol:64`

```
return _quote(raw, probe);
There is no catch or typed fallback around the internal pruning panic.
```

## Order execution accepts oracle updates older than the engine's cached mark

**Severity:** info · oracle_manipulation

**Claim:**

CfdEngine._processOrder does not reject publishTime values below lastMarkTime, even though liquidation and explicit mark refresh do. The planners ignore publishTime, and settlementApplyCarryAndMark merely declines to update the cache for a non-newer mark while the open/close still settles at the supplied price. An unprivileged self-executing trader can therefore retain a still-fresh, post-commit signed oracle update, wait until another transaction installs a newer adverse mark, and execute an open at the older favorable price. For example, after a newer lower mark is cached, opening LONG at an older higher post-commit price creates immediate mark-to-market profit that can subsequently be closed against the HousePool. This bypasses global oracle monotonicity and can transfer pool assets to stale-price arbitrageurs.

**Evidence:**

- `packages/perps/src/CfdEngine.sol:743`

```
function _processOrder(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 poolDepthUsdc,
        uint64 publishTime
    ) internal {
        CfdEnginePlanTypes.RawSnapshot memory snap = settlementSidecar.buildRawSnapshot(order.account, poolDepthUsdc);

        if (order.isClose) {
            CfdEnginePlanTypes.CloseDelta memory delta = planner.planClose(snap, order, currentOraclePrice, publishTime);
...
        } else {
            CfdEnginePlanTypes.OpenDelta memory delta = planner.planOpen(snap, order, currentOraclePrice, publishTime);
The order path plans and settles the supplied oracle value without comparing publishTime to lastMarkTime.
```

- `packages/perps/src/libraries/CfdEnginePlanLib.sol:287`

```
uint256 price = executionPrice > snap.capPrice ? snap.capPrice : executionPrice;
...
        publishTime;
Open planning uses the stale price economically and explicitly discards publishTime.
```

- `packages/perps/src/CfdEngine.sol:1110`

```
function settlementApplyCarryAndMark(
        uint256 newMarkPrice,
        uint64 newMarkTime
    ) external onlySettlementSidecar {
        if (newMarkTime <= lastMarkTime) {
            return;
        }
        _applyCarryAndMark(newMarkPrice, newMarkTime);
    }
A stale execution does not revert; only the cached-mark update is skipped, so settlement can proceed at a price older than the retained global mark.
```

- `packages/perps/src/CfdEngine.sol:998`

```
if (publishTime < lastMarkTime) {
            revert CfdEngine__MarkPriceOutOfOrder();
        }
The sibling liquidation path enforces the missing global monotonicity check, demonstrating the asymmetric validation.
```

- `packages/perps/src/interfaces/ICfdEngine.sol:53`

```
/// @param publishTime Router-validated execution publish time; the Engine caches the execution price only when strictly newer
Router validation and cache monotonicity are distinct: a signed update can satisfy freshness/post-commit validation while still predating an already accepted engine mark.
```

## Partial redemption claims can be classified as queue corruption

**Severity:** info · logic_error

**Claim:**

`SettlementMonitorLens` treats a redemption epoch that remains queued (`shares > fundedShares`) as valid only while `fundingBasisClaimed == 0`, even though the same branch permits nonzero `claimedShares`/`claimedAssets` and the public LP API exposes already-funded portions as immediately claimable. If a large matured redemption is only partially funded and its controller claims that funded portion before the remainder is funded, the vault can legitimately retain the epoch in the queue with a nonzero funding-claim basis. `_populateObservedRedeem` and `_maturedHeadPayload` then set `ObservedEpochState`/`QueueEndpoint` critical faults, propagating `HealthState.Critical`. An unprivileged LP can therefore make settlement monitoring report structural corruption for a valid partial-funding lifecycle, potentially causing false incident response or automated settlement containment.

**Evidence:**

- `packages/perps/src/SettlementMonitorLens.sol:743`

```
if (queue.observedRedeemQueued) {
    lifecycleValid =
        lifecycleValid && epoch[0] > epoch[1] && epoch[7] == 0 && !queue.observedRedeemRefundEnabled;
}
A partially funded epoch remains queued because total shares exceed funded shares, but the monitor additionally requires the aggregate funding claim basis to remain zero.
```

- `packages/perps/src/SettlementMonitorLens.sol:959`

```
payloadValid = payloadValid && arithmeticValid && epoch[9] == 0 && epoch[0] > epoch[1]
    && ((epoch[1] == 0) == (epoch[2] == 0)) && epoch[5] == 0 && epoch[6] == 0 && epoch[7] == 0 && epoch[8] == 0;
The same zero-basis assumption is applied to the matured FIFO head; violating it is converted into a QueueEndpoint critical fault.
```

- `packages/perps/src/SettlementMonitorLens.sol:35`

```
returns (
    uint256 shares,
    uint256 fundedShares,
    uint256 fundedAssets,
    uint256 claimedShares,
    uint256 claimedAssets,
    uint256 refundableShares,
    uint256 refundedShares,
    uint256 fundingBasisClaimed,
    uint256 refundBasisClaimed,
    bool refundEnabled
);
The vault ABI explicitly tracks funded and claimed values independently while an epoch can still have unfunded shares.
```

- `packages/perps/src/interfaces/PerpsViewTypes.sol:167`

```
/// @param claimableRedeemShares Funded redemption shares available to claim.
/// @param claimableRedeemAssets Exact funded USDC available to claim.
The product-facing semantics expose the funded portion as claimable rather than requiring the entire redemption epoch to finish funding.
```

- `packages/perps/src/SettlementMonitorLensSidecar.sol:407`

```
if (health.criticalFaultMask != 0) {
    health.state = SettlementMonitorViewTypes.HealthState.Critical;
}
The false queue fault is surfaced as globally critical settlement health.
```

## Pool payouts are credited at nominal value without verifying settlement-token receipt

**Severity:** info · accounting_error

**Claim:**

When a user close earns an action rebate, CfdEngineSettlementSidecar pays `actionRebatePaidUsdc` from the HousePool and then credits the clearinghouse account by that same nominal amount through `settleUsdc`, but neither step measures how many settlement tokens the clearinghouse actually received. If the configured settlement asset deducts fees or otherwise delivers less than the requested payout, an unprivileged trader can obtain an internal balance larger than the new custody backing and withdraw the difference from settlement tokens backing other accounts. The same unchecked nominal-credit pattern exists for negative-cost open rebates and protocol-fee top-ups; this is distinct from the self-deposit receipt mismatch because the undercollateralized credit is produced by a HousePool-to-clearinghouse payout during settlement.

**Evidence:**

- `packages/perps/src/CfdEngineSettlementSidecar.sol:599`

```
if (delta.actionRebatePaidUsdc > 0) {
    IHousePool(host.pool()).payOut(address(clearinghouse), delta.actionRebatePaidUsdc);
    clearinghouse.settleUsdc(delta.account, int256(delta.actionRebatePaidUsdc));
}
The exact requested pool payout is credited to the trader, with no clearinghouse balance-before/balance-after measurement between payout and credit.
```

- `packages/perps/src/MarginClearinghouse.sol:979`

```
function settleUsdc(address account, int256 amount) external onlyOperator {
    if (amount > 0) {
        _creditSettlementUsdc(account, uint256(amount));
    } else if (amount < 0) {
        _debitSettlementUsdc(account, uint256(-amount));
    }
}
A positive settlement delta only increases the internal ledger; it does not establish that matching tokens arrived in custody.
```

- `packages/perps/src/CfdEngineSettlementSidecar.sol:430`

```
if (delta.poolRebatePayoutUsdc > 0) {
    IHousePool(host.pool()).payOut(host.clearinghouse(), delta.poolRebatePayoutUsdc);
}

(int256 netMarginChange, uint256 protocolFeeCreditedUsdc) = clearinghouse.applyOpenCost(
Open rebates likewise transfer a nominal pool amount before a separate accounting call, without checking the received token delta.
```

- `packages/perps/src/MarginClearinghouse.sol:348`

```
uint256 balanceBefore = asset.balanceOf(address(this));
asset.safeTransferFrom(msg.sender, address(this), amount);
uint256 balanceAfter = asset.balanceOf(address(this));
uint256 received = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
if (received != amount) {
    revert MarginClearinghouse__UnexpectedTransferAmount(amount, received);
}
The contract already demonstrates the required exact-receipt invariant on `depositFor`; settlement payout paths omit the equivalent check.
```

## Protection can match a later position with the same side and size

**Severity:** info · logic_error

**Claim:**

An armed protection is identified only by account, side, and size, not CfdEngine.positionEpoch or any other position-instance identifier. afterOrderTerminal ignores ordinary close order IDs because they are neither a protected parent nor linked attempt, so an armed record is not terminalized when its original position is voluntarily closed. If the account later opens a new position with the same side and size while the record remains active, _positionMatches accepts the new position and any caller can trigger the old thresholds, queueing an unintended full close and taking the old trigger bounty.

**Evidence:**

- `packages/perps/src/CfdEngine.sol:112`

```
mapping(address => uint64) public positionEpoch;
The engine exposes a position-instance epoch, but the protection record and matching interface do not capture it.
```

- `packages/perps/src/PositionProtectionBook.sol:925`

```
function _positionMatches(
        StoredProtection storage protection
    ) private view returns (bool matches) {
        (uint256 size,,,, CfdTypes.Side side,,) = ENGINE.positions(protection.account);
        return size != 0 && size == protection.size && side == protection.side;
    }
A later position is treated as the protected one whenever only its side and size coincide.
```

- `packages/perps/src/PositionProtectionBook.sol:523`

```
protectionId = _attemptProtectionIds[orderId];
        if (protectionId == 0) {
            return;
        }
An ordinary voluntary close is not a parent or linked protection attempt, so its terminal callback leaves the armed protection active.
```

- `packages/perps/src/PositionProtectionBook.sol:451`

```
_requireMatchingPosition(protection);
        if (IPositionProtectionRouterHost(ROUTER).pendingOrderCounts(protection.account) != 0) {
            revert OrderRouter__PendingOrdersExist();
        }

        leg = _triggeredLeg(protection, markPrice);
Once the stale record matches the new side/size, the old thresholds are accepted for permissionless activation.
```

- `packages/perps/src/PositionProtectionBook.sol:316`

```
function triggerPositionProtection(
        uint64 protectionId,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant returns (uint64 linkedOrderId) {
Any external caller can activate a matching stale record and become the trigger executor.
```

## Self-deposit paths credit nominal rather than received settlement tokens

**Severity:** info · accounting_error

**Claim:**

`deposit` and `depositMargin` route through `_deposit`, which credits the caller by the requested `amount` without measuring the clearinghouse's actual token balance increase. If the immutable settlement token deducts a transfer fee or otherwise returns success after delivering less than requested, an unprivileged depositor receives an undercollateralized internal balance and can withdraw the nominal credit against pooled custody, shifting the shortfall to other margin accounts. This is inconsistent with `depositFor`, which explicitly enforces an exact balance delta.

**Evidence:**

- `packages/perps/src/MarginClearinghouse.sol:399`

```
IERC20(settlementAsset).safeTransferFrom(owner, address(this), amount);

settlementBalances[account] += amount;
The credited amount is the user-supplied nominal amount; no before/after balance check establishes that this many settlement tokens arrived.
```

- `packages/perps/src/MarginClearinghouse.sol:349`

```
uint256 balanceBefore = asset.balanceOf(address(this));
asset.safeTransferFrom(msg.sender, address(this), amount);
uint256 balanceAfter = asset.balanceOf(address(this));
uint256 received = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
if (received != amount) {
    revert MarginClearinghouse__UnexpectedTransferAmount(amount, received);
}
The sibling deposit path recognizes and rejects inexact receipts, demonstrating the missing invariant on self-deposits.
```

- `packages/perps/src/MarginClearinghouse.sol:284`

```
constructor(
    address _settlementAsset
) Ownable(msg.sender) {
    settlementAsset = _settlementAsset;
}
The clearinghouse does not enforce token code or transfer semantics at deployment, so the exact-receipt property is not guaranteed locally.
```

- `packages/perps/src/MarginClearinghouse.sol:443`

```
IERC20(settlementAsset).safeTransfer(owner, amount);
Withdrawals pay the nominal ledger balance, allowing an overcredited depositor to consume tokens deposited by other accounts.
```

## Settlement health reads side state with a mismatched selector width

**Severity:** info · logic_error

**Claim:**

`SettlementMonitorLensSidecar._populateNavHealth` manually calls `sides(uint256)`, while both typed engine consumers in scope invoke the canonical getter with a `uint8` side key. Because ABI selectors include parameter widths, an engine getter declared as `sides(uint8)` will not dispatch the sidecar's `sides(uint256)` selector. Both long and short static reads then fail on every health query, causing `_populateNavHealth` to set Engine and TerminalNavBook dependency failures and return. As a result `getSettlementHealth` remains `Unknown` and composite observations cannot become complete even when protocol state is healthy.

**Evidence:**

- `packages/perps/src/SettlementMonitorLensSidecar.sol:556`

```
(longOk, long) =
    _readWords(address(ENGINE), abi.encodeWithSelector(bytes4(keccak256("sides(uint256)")), 0), 4);
(shortOk, short) =
    _readWords(address(ENGINE), abi.encodeWithSelector(bytes4(keccak256("sides(uint256)")), 1), 4);
The sidecar hard-codes the ABI signature with a uint256 key.
```

- `packages/perps/src/CfdEngineLens.sol:629`

```
(long.maxProfitUsdc, long.openInterest, long.entryNotional, long.totalMargin) =
    engineContract.sides(uint8(CfdTypes.Side.LONG));
(short.maxProfitUsdc, short.openInterest, short.entryNotional, short.totalMargin) =
    engineContract.sides(uint8(CfdTypes.Side.SHORT));
The canonical typed lens explicitly uses uint8 for the same getter, indicating the generated getter's actual key width.
```

- `packages/perps/src/CfdEngineProtocolLens.sol:149`

```
(state.maxProfitUsdc, state.openInterest, state.entryNotional, state.totalMargin) =
    engineContract.sides(uint8(side));
A second independent typed consumer uses uint8, reinforcing that the manually constructed uint256 signature is inconsistent.
```

- `packages/perps/src/SettlementMonitorLensSidecar.sol:563`

```
if (!bookOk || !longOk || !shortOk || !sizeOk || !engineCapOk) {
    health.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.TerminalNavBook)
    | _dependencyBit(SettlementMonitorViewTypes.Dependency.Engine);
    return;
}
A selector miss is promoted into persistent dependency failures and aborts NAV health validation.
```

- `packages/perps/src/SettlementMonitorLensSidecar.sol:409`

```
} else if (health.dependencyFailureMask != 0) {
    health.state = SettlementMonitorViewTypes.HealthState.Unknown;
}
The failed side reads prevent a Healthy result.
```

## Settlement oracle monitoring rejects valid close-only snapshots

**Severity:** info · logic_error

**Claim:**

`SettlementMonitorLensSidecar._buildOracleStatus` classifies every PoolReconcile snapshot with `closeOnly == true` as an Oracle dependency failure, even though `IPletherOracle.PriceSnapshot.closeOnly` is a valid policy result indicating that opens/increases are prohibited. This also makes the later `oracleStatus.closeOnly` assignment unreachable with a true value. During a designed close-only regime (for example calendar-driven FAD/oracle-frozen operation), a successfully validated pool-reconcile price can therefore be reported as an unavailable dependency; required atomic settlement status gains `RequiredDependencyUnknown`, and `getSettlementObservation` cannot be complete despite a valid oracle result.

**Evidence:**

- `packages/perps/src/interfaces/IPletherOracle.sol:36`

```
/// @param closeOnly Whether current policy prohibits opens and increases; callers enforce this flag.
...
bool closeOnly;
The oracle interface defines `closeOnly` as legitimate policy metadata rather than an invalid snapshot encoding.
```

- `packages/perps/src/SettlementMonitorLensSidecar.sol:265`

```
if (
    words[0] == 0 || words[1] == 0 || words[0] != words[1] || words[0] > capPrice
        || words[2] > type(uint64).max || words[2] > block.timestamp
        || block.timestamp - words[2] > expectedMaxStaleness || words[3] != 0
        || words[4] != expectedMaxStaleness || words[5] != 0 || words[6] > 1 || words[7] > 1
        || (words[6] == 1) != frozen || (words[7] == 1) != fadWindow
) {
    oracleStatus.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Oracle);
    ...
    return oracleStatus;
}
Word 5 is the ABI-encoded `closeOnly` boolean, and any true value is unconditionally rejected despite otherwise valid boolean encoding.
```

- `packages/perps/src/SettlementMonitorLensSidecar.sol:282`

```
oracleStatus.closeOnly = words[5] == 1;
...
oracleStatus.readSucceeded = true;
oracleStatus.policyValid = true;
Because the prior condition rejects word 5 unless zero, this advertised output can never report a successful close-only policy state.
```

- `packages/perps/src/SettlementMonitorLens.sol:330`

```
if (oracle.dependencyFailureMask != 0) {
    status.dependencyFailureMask |= oracle.dependencyFailureMask;
    status.operationalBlockerMask |= _operationalBit(
        SettlementMonitorViewTypes.OperationalBlocker.RequiredDependencyUnknown
    );
    return;
}
For an atomic-refresh settlement path, the false oracle failure is promoted into a required operational blocker.
```

- `packages/perps/src/SettlementMonitorLens.sol:273`

```
observation.observationComplete = configAvailable && observation.status.dependencyFailureMask == 0
    && observation.accounting.dependencyFailureMask == 0 && observation.health.dependencyFailureMask == 0
    && observation.oracle.dependencyFailureMask == 0 && observation.health.criticalFaultMask == 0
    && requiredOraclePolicyValid;
The false dependency failure prevents complete monitoring observations.
```

## State-driven VPI increases are classified as user-invalid margin failures

**Severity:** info · logic_error

**Claim:**

An open can be valid when committed and later fail with MARGIN_DRAINED_BY_FEES solely because other accounts change global side skew or pool depth, increasing its VPI charge before execution. planOpen uses the resulting state-dependent tradeCostUsdc in planOpenCostApplication, but getExecutionFailurePolicyCategory classifies every MARGIN_DRAINED_BY_FEES result as UserInvalid rather than ProtocolStateInvalidated. An unprivileged account can therefore move skew ahead of a tightly funded victim order and cause the victim's execution to enter the router's user-fault failure lifecycle, potentially forfeiting/absorbing the victim's reserved execution bounty even though the invalidation came from protocol-wide market state rather than the victim changing inputs or collateral.

**Evidence:**

- `packages/perps/src/libraries/CfdEnginePlanLib.sol:467`

```
(inputs.postSkewUsdc, orderSideIsPostOpenHeavy) =
            _postOpenSkewUsdc(snap.longSide, snap.shortSide, order.side, order.sizeDelta, delta.price);
...
        (valid, delta.openState, rawLiquidationRequirementUsdc) = OpenAccountingLib.tryBuildOpenState(inputs);
Open economics, including VPI, are recalculated from current global long/short open interest and current pool depth at execution.
```

- `packages/perps/src/libraries/OpenAccountingLib.sol:127`

```
(valid, state.vpiUsdc) = CfdMath.tryCalculateVPI(
            inputs.preSkewUsdc, inputs.postSkewUsdc, inputs.poolDepthUsdc, inputs.riskParams.vpiFactor
        );
...
        state.tradeCostUsdc = state.vpiUsdc + int256(state.executionFeeUsdc);
A third party's skew/depth change directly changes the victim's trade cost without any victim-controlled state change.
```

- `packages/perps/src/libraries/CfdEnginePlanLib.sol:359`

```
MarginClearinghouseAccountingLib.OpenCostPlan memory openCostPlan =
                MarginClearinghouseAccountingLib.planOpenCostApplication(
                    openCostBuckets, delta.marginDeltaUsdc, delta.tradeCostUsdc
                );
            if (openCostPlan.insufficientFreeEquity || openCostPlan.insufficientPositionMargin) {
                delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES;
                return delta;
            }
The state-dependent VPI cost is folded into the same failure code used for account collateral depletion.
```

- `packages/perps/src/libraries/CfdEnginePlanLib.sol:117`

```
if (
            code == CfdEnginePlanTypes.OpenRevertCode.DEGRADED_MODE
                || code == CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH
                || code == CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED
                || code == CfdEnginePlanTypes.OpenRevertCode.NUMERIC_DOMAIN_EXCEEDED
        ) {
            return CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated;
        }

        return CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid;
MARGIN_DRAINED_BY_FEES falls through to UserInvalid even when its immediate cause is global VPI movement.
```

- `packages/perps/src/CfdEngine.sol:442`

```
/// @notice Transfers a forfeited reserved execution bounty into the protocol treasury clearinghouse account.
...
        clearinghouse.transferReservedSettlement(sourceAccount, treasury, amountUsdc);
The engine exposes the downstream value-transfer path for forfeited user bounties, making failure classification economically consequential.
```

## Temporary pool liquidity can reduce a skew-increasing close charge

**Severity:** info · price_manipulation

**Claim:**

Close VPI is computed from a single execution-time poolAssetsUsdc denominator. For a close that increases absolute side skew, vpiDeltaUsdc is positive and therefore collected as an action charge. An unprivileged trader who can temporarily supply HousePool liquidity before executing that close can inflate pool depth, reduce the positive VPI charge, and remove the liquidity afterward. Because the close reduces position exposure and maximum-liability accounting, the temporary liquidity need not remain committed merely to support the closed exposure, allowing the trader to bypass the intended skew cost.

**Evidence:**

- `packages/perps/src/libraries/CfdEnginePlanLib.sol:1228`

```
return CloseAccountingLib.buildCloseState(
            CloseAccountingLib.CloseInputs({
                ...
                poolDepthUsdc: snap.poolAssetsUsdc,
                vpiFactor: snap.riskParams.vpiFactor,
The close uses the one current pool-assets snapshot directly as VPI depth.
```

- `packages/perps/src/CfdMath.sol:114`

```
uint256 sqSkewOverDepthWad = (skewWad * skewWad) / depthWad;
...
uint256 costWad = (vpiFactorWad * sqSkewOverDepthWad) / WAD / 2;
Increasing the spot depth denominator lowers both skew costs and the positive cost difference charged for a skew-increasing close.
```

- `packages/perps/src/libraries/CloseAccountingLib.sol:82`

```
state.vpiDeltaUsdc =
            CfdMath.calculateVPI(inputs.preSkewUsdc, inputs.postSkewUsdc, inputs.poolDepthUsdc, inputs.vpiFactor);
The sampled depth determines the trader's assessed close VPI.
```

- `packages/perps/src/libraries/CfdEnginePlanLib.sol:957`

```
int256 actionNetUsdc = cs.vpiDeltaUsdc
            + int256(cs.executionFeeUsdc + cs.frozenSpreadUsdc + delta.pendingCarryUsdc - delta.realizedCarryUsdc);
        ...
        if (actionNetUsdc > 0) {
            delta.actionChargeAssessedUsdc = uint256(actionNetUsdc);
A reduced positive VPI directly reduces the action charge collected from the trader.
```

## Temporary pool-liquidity reduction can amplify a skew-reducing close rebate

**Severity:** info · price_manipulation

**Claim:**

A trader who can temporarily reduce HousePool `totalAssets` around execution of a skew-reducing close can increase the magnitude of the close's negative VPI, because both pre- and post-close skew costs divide by the execution-time pool depth. When the position has positive accrued VPI, the lifetime clamp permits a rebate up to the proportional accrued amount, and the close planner pays the resulting action rebate from free pool cash. Thus an unprivileged LP/trader can withdraw liquidity immediately before executing its close and restore it afterward to reclaim more previously paid price impact than the unmanipulated curve permits, causing an excessive LP-funded rebate. This is directionally distinct from reducing a skew-increasing close charge: here lowering depth magnifies a negative VPI rebate.

**Evidence:**

- `packages/perps/src/CfdOrderPolicyEvaluator.sol:43`

```
AssessmentContext memory context = AssessmentContext(
    engineAddress,
    executor,
    executionPrice,
    IHousePool(engine.pool()).totalAssets(),
    publishTime,
    pending.executionBountyUsdc
);
Committed-order assessment takes the current, transaction-time HousePool assets as the depth input rather than a time-weighted or commitment-time value.
```

- `packages/perps/src/libraries/CfdEnginePlanLib.sol:1237`

```
uint256 preSkewUsdc = _absSkewUsdc(snap.longSide, snap.shortSide, price);
uint256 postSkewUsdc = _skewUsdc(postLongOi, postShortOi, price);
return CloseAccountingLib.buildCloseState(
    CloseAccountingLib.CloseInputs({
        ...
        poolDepthUsdc: snap.poolAssetsUsdc,
        vpiFactor: snap.riskParams.vpiFactor,
The close's VPI is calculated from current pool depth for both skew states.
```

- `packages/perps/src/CfdMath.sol:133`

```
uint256 sqSkewOverDepthWad = (skewWad * skewWad) / depthWad;
...
uint256 costWad = (vpiFactorWad * sqSkewOverDepthWad) / WAD / 2;
Reducing depth increases each skew cost and therefore magnifies the negative cost difference for a skew-reducing close.
```

- `packages/perps/src/libraries/CloseAccountingLib.sol:103`

```
state.vpiDeltaUsdc =
    CfdMath.calculateVPI(inputs.preSkewUsdc, inputs.postSkewUsdc, inputs.poolDepthUsdc, inputs.vpiFactor);
if (state.proportionalAccrualUsdc + state.vpiDeltaUsdc < 0) {
    state.vpiDeltaUsdc = -state.proportionalAccrualUsdc;
}
The only rebate cap is proportional lifetime VPI; positive accrued VPI can therefore be reclaimed at a rate selected through current depth.
```

- `packages/perps/src/libraries/CfdEnginePlanLib.sol:931`

```
if (delta.actionRebateUsdc > 0) {
    delta.actionRebatePaidUsdc =
        delta.actionRebateUsdc < freePoolCashUsdc ? delta.actionRebateUsdc : freePoolCashUsdc;
    delta.actionRebateWaivedUsdc = delta.actionRebateUsdc - delta.actionRebatePaidUsdc;
    poolCashAfterCollectionsUsdc -= delta.actionRebatePaidUsdc;
}
A manipulated negative VPI becomes an actual pool-funded action rebate whenever free cash is available.
```

## Unbounded per-account order queue can make liquidation exceed the block gas limit

**Severity:** info · denial_of_service

**Claim:**

An unprivileged trader can append an unbounded number of pending orders to its own account because `_commitOrder` has no per-account count limit, even though `pendingOrderCounts` and a `TooManyPendingOrders` error exist. Liquidation synchronously validates, takes the bounty for, deletes, and finalizes every account order in multiple linear loops. By maintaining enough live orders that this work exceeds the block gas limit, an underwater trader can make both single-account liquidation and the corresponding batch item unexecutable; the batch explicitly budgets 600,000 gas per pending order and stops before attempting an oversized item. This can delay liquidation while losses grow and may leave protocol bad debt.

**Evidence:**

- `packages/perps/src/router/OrderLiquidationBatchLogic.sol:203`

```
_validateFreshRequest(host, account, request, enforceProtectionLock); ... orderId = host.nextCommitId(); ... _queueCommittedOrder(host, account, orderId, request, executionBountyUsdc);
The admission path queues each fresh user order without checking `pendingOrderCounts[account]` or imposing a queue-length cap.
```

- `packages/perps/src/router/OrderReservationAccounting.sol:50`

```
mapping(address => uint256) public pendingOrderCounts;
The router tracks the exact per-account pending count, so the omitted bound could have been enforced at admission.
```

- `packages/perps/src/interfaces/IOrderRouterErrors.sol:122`

```
error OrderRouter__TooManyPendingOrders();
A dedicated cap error is declared but has no use anywhere in the scoped source, corroborating the missing admission check.
```

- `packages/perps/src/router/OrderBountyAccounting.sol:15`

```
for (uint64 cursor = accountHeadOrderId[account]; cursor != 0; cursor = orderRecords[cursor].nextAccountOrderId) { lifecycleBook.validateBountyFunding(cursor); ++orderCount; } ... for (uint64 orderId = accountHeadOrderId[account]; orderId != 0; orderId = orderRecords[orderId].nextAccountOrderId) { ... clearinghouse.takeBountyReservation(...); ... }
Liquidation performs two unbounded passes over all pending account orders before calling the engine.
```

- `packages/perps/src/router/OrderLiquidationHandler.sol:93`

```
for (uint256 i = 0; i < orderCount; ++i) { ... clearinghouse.releaseOrderReservationForTerminalCleanup(orderId); ... _deleteOrder(orderId, ...); ... _recordSettledTerminalReceipt(receiptInput); }
After engine liquidation, the router performs another expensive unbounded pass that includes external accounting and lifecycle calls per order.
```

- `packages/perps/src/router/OrderLiquidationBatchLogic.sol:727`

```
uint256 itemGas = engineGas + LIQUIDATION_BATCH_ROUTER_GAS + (host.pendingOrderCounts(account) * LIQUIDATION_BATCH_GAS_PER_ORDER); ... if (remainingGas <= itemGas + LIQUIDATION_BATCH_TAIL_GAS) { emit LiquidationBatchStopped(nextIndex); return nextIndex; }
The batch path acknowledges linear 600k-per-order cost and refuses to attempt accounts whose requested item gas exceeds remaining transaction gas.
```

## Uncapped slippage check can admit a LONG open below its target price

**Severity:** info · validation_bypass

**Claim:**

For an open LONG whose user-supplied targetPrice exceeds CAP_PRICE, a raw oracle price at or above targetPrice satisfies OrderValidationLib.checkSlippage, but CfdEnginePlanLib.planOpen subsequently clamps that same execution price to snap.capPrice and settlement uses the clamped delta.price. No scoped commit validation requires targetPrice <= CAP_PRICE and processOrderTyped does not re-check the target against delta.price. Thus an unprivileged user order can execute at a price strictly below its declared minimum LONG-open target, violating the order's slippage bound and exposing the account to an execution it did not authorize. The analogous cap-side mismatch should also be checked for SHORT closes in the sibling flow.

**Evidence:**

- `packages/perps/src/libraries/OrderValidationLib.sol:67`

```
if (order.side == CfdTypes.Side.LONG) {
            return executionPrice >= order.targetPrice;
        }
        return executionPrice <= order.targetPrice;
The open-LONG limit is checked against the raw executionPrice supplied to the router-side validation, with no CAP_PRICE normalization.
```

- `packages/perps/src/libraries/OrderValidationLib.sol:25`

```
if (isClose && marginDelta > 0) {
            revert IOrderRouterErrors.OrderRouter__CloseWithPositiveMargin();
        }
The scoped common commit validation checks size and close margin only; it does not bound targetPrice by the engine cap.
```

- `packages/perps/src/libraries/CfdEnginePlanLib.sol:287`

```
uint256 price = executionPrice > snap.capPrice ? snap.capPrice : executionPrice;
...
        delta.price = price;
The planner changes an above-cap raw execution price to CAP_PRICE, so the settled price can differ from the one used by the slippage comparison.
```

- `packages/perps/src/CfdEngine.sol:754`

```
CfdEnginePlanTypes.OpenDelta memory delta = planner.planOpen(snap, order, currentOraclePrice, publishTime);
            _revertIfOpenInvalidTyped(delta.revertCode);
            _applyOpen(delta, publishTime);
The engine accepts the capped plan and applies it without comparing delta.price to order.targetPrice.
```

- `packages/perps/src/CfdEngine.sol:1263`

```
settlementSidecar.executeOpen(delta, currentPosition, publishTime);
Settlement consumes the delta containing the capped price.
```
