// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {MockSettlementToken} from "../../../utils/MockSettlementToken.sol";
import {BasePerpInvariantTest} from "../BasePerpInvariantTest.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Persistent settlement campaign: no snapshots or production previews. Constant $1 execution price and zero
/// carry isolate VPI, lifetime clamps, fee ownership, frozen spread, and reserve backing. The mock pool supplies
/// canonical cash depth. Router authorization, Pyth validation, price PnL, and the tranche waterfall are out of scope.
contract PerpVpiFrozenAccountingHandler is Test {

    uint256 internal constant PRICE = 1e8;
    uint256 internal constant INITIAL_TRADER_CASH = 2_000_000e6;
    uint256 internal constant MAX_LOTS = 1000;
    bytes32 internal constant SPREAD_EVENT = keccak256("FrozenCloseSpreadSettled(address,uint256,uint256,uint256)");

    CfdEngine internal immutable engine;
    MarginClearinghouse internal immutable clearinghouse;
    MockSettlementToken internal immutable settlementToken;
    address internal immutable router;
    address internal immutable pool;
    bool public immutable poolFunded;

    uint256[4] public ghostLots;
    int256[4] public ghostVpiAccrued;
    int256[4] public ghostTraderCash;
    uint256[2] public ghostSideLots;
    int256 public ghostPoolCash;
    uint256 public ghostTreasuryCash;
    bool public ghostFrozen;

    uint256 public opens;
    uint256 public partialCloses;
    uint256 public fullCloses;
    uint256 public frozenCloses;
    uint256 public positiveVpiActions;
    uint256 public negativeVpiActions;
    uint256 public lifetimeClampedCloses;
    uint256 public openFeeTopUpActions;
    uint256 public closeFeeTopUpActions;
    uint256 public skippedOpens;
    uint256 public skippedCloses;

    constructor(
        CfdEngine engine_,
        MarginClearinghouse clearinghouse_,
        MockSettlementToken settlementToken_,
        address router_,
        address pool_,
        bool poolFunded_
    ) {
        engine = engine_;
        clearinghouse = clearinghouse_;
        settlementToken = settlementToken_;
        router = router_;
        pool = pool_;
        poolFunded = poolFunded_;
        ghostPoolCash = 1_000_000e6;
        for (uint256 i; i < 4; ++i) {
            address account = actorAt(i);
            settlementToken.mint(account, INITIAL_TRADER_CASH);
            vm.startPrank(account);
            settlementToken.approve(address(clearinghouse), type(uint256).max);
            clearinghouse.deposit(account, INITIAL_TRADER_CASH);
            vm.stopPrank();
            ghostTraderCash[i] = int256(INITIAL_TRADER_CASH);
        }
    }

    function actorAt(
        uint256 index
    ) public pure returns (address) {
        return address(uint160(0xF201 + index));
    }

    function openOrIncrease(
        uint256 actorSeed,
        uint256 lotsSeed
    ) external {
        uint256 i = actorSeed % 4;
        if (ghostFrozen || ghostLots[i] == MAX_LOTS) {
            ++skippedOpens;
            return;
        }
        // At $100 per lot and 9 bps, at least 12 lots are needed to support the $1 minimum liquidation bounty.
        uint256 minimumIncrease = ghostLots[i] < 12 ? 12 - ghostLots[i] : 1;
        uint256 lots = bound(lotsSeed, minimumIncrease, MAX_LOTS - ghostLots[i]);
        int256 vpi = _tradeVpi(i, lots, false);
        uint256 fee = lots * PRICE * 4 / 10_000;
        _process(i, lots, false);
        ghostLots[i] += lots;
        ghostSideLots[i % 2] += lots;
        ghostVpiAccrued[i] += vpi;
        // When stored tranche principal is zero, pool-funded fee top-ups are forgone; when funded, free pool cash
        // covers the portion of the execution fee offset by negative VPI.
        int256 collected = vpi + int256(fee);
        uint256 creditedFee = collected <= 0 ? 0 : uint256(collected) < fee ? uint256(collected) : fee;
        if (poolFunded && creditedFee < fee) {
            creditedFee = fee;
            ++openFeeTopUpActions;
        }
        _bookCash(i, vpi, fee, 0, creditedFee);
        ++opens;
        assertModel();
    }

    function close(
        uint256 actorSeed,
        uint256 lotsSeed
    ) external {
        uint256 i = actorSeed % 4;
        uint256 sizeBefore = ghostLots[i];
        if (sizeBefore == 0) {
            ++skippedCloses;
            return;
        }
        uint256 lots = bound(lotsSeed, 1, sizeBefore);
        int256 proportionalAccrual = ghostVpiAccrued[i] * int256(lots) / int256(sizeBefore);
        int256 vpi = _tradeVpi(i, lots, true);
        if (vpi + proportionalAccrual < 0) {
            vpi = -proportionalAccrual;
            ++lifetimeClampedCloses;
        }
        uint256 fee = lots * PRICE * 4 / 10_000;
        uint256 spread = ghostFrozen ? lots * PRICE * 50 / 10_000 : 0;
        // At zero price PnL, the trader funds the fee from collected non-clawback action cash.
        int256 feeEligible = vpi + int256(fee + spread);
        if (proportionalAccrual < 0) {
            feeEligible += proportionalAccrual;
        }
        uint256 creditedFee = feeEligible <= 0 ? 0 : uint256(feeEligible) < fee ? uint256(feeEligible) : fee;
        // With stored tranche principal, free pool cash covers the close fee offset by any rebate left after spread.
        if (poolFunded && vpi < -int256(spread)) {
            uint256 rebateAfterSpread = uint256(-vpi - int256(spread));
            uint256 topUp = rebateAfterSpread < fee ? rebateAfterSpread : fee;
            if (topUp > 0) {
                creditedFee += topUp;
                ++closeFeeTopUpActions;
            }
        }
        vm.recordLogs();
        _process(i, lots, true);
        _assertSpreadEvent(actorAt(i), spread, vpi, vm.getRecordedLogs());
        ghostLots[i] -= lots;
        ghostSideLots[i % 2] -= lots;
        ghostVpiAccrued[i] -= proportionalAccrual;
        _bookCash(i, vpi, fee, spread, creditedFee);
        if (ghostFrozen) {
            ++frozenCloses;
        }
        if (lots == sizeBefore) {
            ++fullCloses;
        } else {
            ++partialCloses;
        }
        assertModel();
    }

    function enterFrozenWindow() external {
        _advanceToWeekdayNoon(6); // Saturday noon is frozen on both sides of DST changes.
        ghostFrozen = true;
        assertTrue(engine.isOracleFrozen(), "Saturday must be oracle-frozen");
        assertTrue(engine.isFadWindow(), "Saturday must also be FAD");
    }

    function enterLiveWindow() external {
        _advanceToWeekdayNoon(1); // Monday noon is outside the ordinary weekend FAD/frozen windows.
        ghostFrozen = false;
        assertFalse(engine.isOracleFrozen(), "Monday must be live");
        assertFalse(engine.isFadWindow(), "Monday must be outside FAD");
    }

    function _advanceToWeekdayNoon(
        uint256 weekday
    ) internal {
        uint256 today = block.timestamp / 1 days;
        uint256 currentWeekday = (today + 4) % 7;
        uint256 target = (today + (weekday + 7 - currentWeekday) % 7) * 1 days + 12 hours;
        if (target <= block.timestamp) {
            target += 7 days;
        }
        vm.warp(target);
    }

    function _process(
        uint256 i,
        uint256 lots,
        bool isClose
    ) internal {
        CfdTypes.Order memory order = CfdTypes.Order({
            account: actorAt(i),
            sizeDelta: lots * CfdTypes.SIZE_QUANTUM,
            marginDelta: isClose ? 0 : lots * PRICE / 5,
            targetPrice: PRICE,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: CfdTypes.Side(i % 2),
            isClose: isClose
        });
        vm.prank(router);
        engine.processOrderTyped(order, PRICE, uint256(ghostPoolCash), uint64(block.timestamp));
    }

    function _tradeVpi(
        uint256 i,
        uint256 lots,
        bool isClose
    ) internal view returns (int256) {
        uint256 longLots = ghostSideLots[0];
        uint256 shortLots = ghostSideLots[1];
        uint256 beforeSkew = longLots > shortLots ? longLots - shortLots : shortLots - longLots;
        if (i % 2 == 0) {
            longLots = isClose ? longLots - lots : longLots + lots;
        } else {
            shortLots = isClose ? shortLots - lots : shortLots + lots;
        }
        uint256 afterSkew = longLots > shortLots ? longLots - shortLots : shortLots - longLots;
        // k = 0.005 = 1/200, C(S) = floor(S^2 / (400 D)). With this exact rational k, the specified WAD
        // intermediate rounding reduces algebraically to this formula. Do not call CfdMath or production planners.
        (uint256 positiveVpiAssets,) = _ghostVpiTotals();
        uint256 cash = uint256(ghostPoolCash);
        uint256 depth = cash > positiveVpiAssets ? cash - positiveVpiAssets : 0;
        if (depth == 0) {
            return 0;
        }
        uint256 denominator = 400 * depth;
        uint256 preCost = (beforeSkew * PRICE) ** 2 / denominator;
        uint256 postCost = (afterSkew * PRICE) ** 2 / denominator;
        return int256(postCost) - int256(preCost);
    }

    function _bookCash(
        uint256 i,
        int256 vpi,
        uint256 fee,
        uint256 spread,
        uint256 creditedFee
    ) internal {
        ghostTraderCash[i] -= vpi + int256(fee + spread);
        ghostPoolCash += vpi + int256(spread + fee - creditedFee);
        ghostTreasuryCash += creditedFee;
        if (vpi > 0) {
            ++positiveVpiActions;
        }
        if (vpi < 0) {
            ++negativeVpiActions;
        }
    }

    function _assertSpreadEvent(
        address account,
        uint256 spread,
        int256 vpi,
        Vm.Log[] memory logs
    ) internal view {
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(engine.settlementSidecar()) || logs[i].topics[0] != SPREAD_EVENT) {
                continue;
            }
            ++found;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), account, "spread owner");
            (uint256 assessed, uint256 paid, uint256 waived) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            uint256 rebateOffset = vpi < 0 ? uint256(-vpi) : 0;
            uint256 expectedPaid = spread > rebateOffset ? spread - rebateOffset : 0;
            assertEq(assessed, spread, "independent frozen assessment");
            assertEq(paid, expectedPaid, "spread net of signed VPI rebate");
            assertEq(waived, spread - expectedPaid, "spread allocation conservation");
        }
        assertEq(found, spread > 0 ? 1 : 0, "spread event emitted exactly once when assessed");
    }

    function assertModel() public view {
        (uint256 positiveVpiAssets, uint256 negativeVpiAssets) = _ghostVpiTotals();
        assertEq(engine.totalPositiveVpiAccruedAssets(), positiveVpiAssets, "independent gross positive VPI total");
        assertEq(engine.totalNegativeVpiAccruedAssets(), negativeVpiAssets, "independent gross negative VPI total");
        uint256 expectedCustody = ghostTreasuryCash;
        for (uint256 i; i < 4; ++i) {
            address account = actorAt(i);
            (uint256 size,,,,,, int256 accrued) = engine.positions(account);
            assertEq(size, ghostLots[i] * CfdTypes.SIZE_QUANTUM, "persistent size model");
            assertEq(accrued, ghostVpiAccrued[i], "independent lifetime VPI model");
            assertEq(int256(clearinghouse.balanceAssets(account)), ghostTraderCash[i], "independent trader cash model");
            uint256 reserve = ghostVpiAccrued[i] < 0 ? uint256(-ghostVpiAccrued[i]) : 0;
            assertEq(clearinghouse.vpiRebateReserveAssets(account), reserve, "exact lifetime rebate backing");
            assertEq(engine.traderClaimBalanceAssets(account), 0, "zero-price-PnL actions cannot create claims");
            expectedCustody += uint256(ghostTraderCash[i]);
        }
        for (uint256 side; side < 2; ++side) {
            (, uint256 oi,,) = engine.sides(uint8(side));
            assertEq(oi, ghostSideLots[side] * CfdTypes.SIZE_QUANTUM, "independent side size model");
        }
        assertEq(int256(settlementToken.balanceOf(pool)), ghostPoolCash, "VPI and frozen spread belong to LP cash");
        assertEq(
            clearinghouse.balanceAssets(engine.protocolTreasury()),
            ghostTreasuryCash,
            "only execution fees reach treasury"
        );
        assertEq(settlementToken.balanceOf(address(clearinghouse)), expectedCustody, "physical clearinghouse custody");
        assertFalse(engine.degradedMode(), "bounded funded actions remain solvent");
    }

    function _ghostVpiTotals() internal view returns (uint256 positiveAssets, uint256 negativeAssets) {
        for (uint256 i; i < 4; ++i) {
            if (ghostLots[i] == 0) {
                continue;
            }
            int256 accrued = ghostVpiAccrued[i];
            if (accrued >= 0) {
                positiveAssets += uint256(accrued);
            } else {
                negativeAssets += uint256(-(accrued + 1)) + 1;
            }
        }
    }

}

contract PerpVpiFrozenAccountingInvariantTest is BasePerpInvariantTest {

    PerpVpiFrozenAccountingHandler internal handler;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.vpiFactor = 0.005e18;
        params.baseCarryBps = 0;
    }

    function _initialHousePoolAssets() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    function setUp() public virtual override {
        super.setUp();
        bool funded = _poolHasStoredPrincipal();
        if (funded) {
            housePool.setJuniorPrincipal(_initialHousePoolAssets());
        }
        handler = new PerpVpiFrozenAccountingHandler(
            engine, clearinghouse, settlementToken, address(router), address(housePool), funded
        );
        handler.openOrIncrease(0, 1000);
        handler.openOrIncrease(1, 500);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.openOrIncrease.selector;
        selectors[1] = handler.close.selector;
        selectors[2] = handler.enterFrozenWindow.selector;
        selectors[3] = handler.enterLiveWindow.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function _poolHasStoredPrincipal() internal pure virtual returns (bool) {
        return false;
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: quick.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: audit.invariant.fail-on-revert = true
    function invariant_PersistentVpiCashAndReserveModel() public view {
        handler.assertModel();
    }

    function test_IndependentCashModelRejectsOneAtomOfUnmodeledPoolCash() public {
        handler.assertModel();
        settlementToken.mint(address(housePool), 1);
        vm.expectRevert();
        handler.assertModel();
    }

    function test_FullClosesRemoveAllDeferredVpiContributions() public {
        handler.close(0, 1000);
        handler.close(1, 500);
        handler.assertModel();
        assertEq(engine.totalPositiveVpiAccruedAssets(), 0, "flat positions release all deferred positive VPI");
        assertEq(engine.totalNegativeVpiAccruedAssets(), 0, "flat positions remove all backed VPI receivables");
    }

    function test_ReachesBothVpiSignsAndFrozenPartialAndFullCloses() public {
        handler.enterFrozenWindow();
        handler.close(0, 250);
        handler.close(1, 500);
        handler.close(0, 750);
        handler.enterLiveWindow();
        handler.openOrIncrease(2, 1000);
        handler.openOrIncrease(3, 1000);
        handler.close(2, 500);
        handler.assertModel();
        assertGt(handler.positiveVpiActions(), 0, "positive VPI must execute");
        assertGt(handler.negativeVpiActions(), 0, "negative VPI must execute");
        assertGt(handler.lifetimeClampedCloses(), 0, "lifetime clamp must execute");
        assertEq(handler.frozenCloses(), 3, "funded frozen settlement must execute");
        assertEq(handler.partialCloses(), 2, "partial closes survive subsequent actions");
        assertEq(handler.fullCloses(), 2, "terminal closes must execute");
        assertEq(handler.opens(), 4, "positions can reopen after thaw");
    }

}

/// @notice Exercises the same persistent VPI/frozen-spread campaign with stored tranche principal so pool-funded
///         protocol-fee top-ups on both negative-VPI opens and rebate-offset closes are verified statefully.
contract PerpVpiFundedPoolAccountingInvariantTest is PerpVpiFrozenAccountingInvariantTest {

    function _poolHasStoredPrincipal() internal pure override returns (bool) {
        return true;
    }

    function test_FundedPoolCloseAndOpenRebatesTopUpProtocolTreasury() public {
        // Actor 0 is LONG 1000 lots (paid positive VPI), Actor 1 is SHORT 500 lots (received negative VPI).
        assertGt(handler.openFeeTopUpActions(), 0, "negative-VPI open must trigger pool-funded fee top-up");
        // Closing Actor 0's LONG reduces skew and earns a VPI rebate that offsets the close fee -> pool tops up fee.
        handler.close(0, 500);
        handler.assertModel();
        assertGt(handler.closeFeeTopUpActions(), 0, "rebate-offset close must trigger pool-funded fee top-up");
    }

}
