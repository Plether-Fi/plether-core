// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpInvariantTest} from "../BasePerpInvariantTest.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
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
    MockUSDC internal immutable usdc;
    address internal immutable router;
    address internal immutable pool;

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
    uint256 public skippedOpens;
    uint256 public skippedCloses;

    constructor(
        CfdEngine engine_,
        MarginClearinghouse clearinghouse_,
        MockUSDC usdc_,
        address router_,
        address pool_
    ) {
        engine = engine_;
        clearinghouse = clearinghouse_;
        usdc = usdc_;
        router = router_;
        pool = pool_;
        ghostPoolCash = 1_000_000e6;
        for (uint256 i; i < 4; ++i) {
            address account = actorAt(i);
            usdc.mint(account, INITIAL_TRADER_CASH);
            vm.startPrank(account);
            usdc.approve(address(clearinghouse), type(uint256).max);
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
        _bookCash(i, vpi, fee, 0, fee);
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
        // At zero price PnL, only collected non-clawback action cash is eligible for protocol fees. A net VPI
        // rebate can offset all or part of the assessed fee; nominal fee arithmetic alone is not treasury revenue.
        int256 feeEligible = vpi + int256(fee + spread);
        if (proportionalAccrual < 0) {
            feeEligible += proportionalAccrual;
        }
        uint256 creditedFee = feeEligible <= 0 ? 0 : uint256(feeEligible) < fee ? uint256(feeEligible) : fee;
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
        uint256 denominator = 400 * uint256(ghostPoolCash);
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
        uint256 expectedCustody = ghostTreasuryCash;
        for (uint256 i; i < 4; ++i) {
            address account = actorAt(i);
            (uint256 size,,,,,, int256 accrued) = engine.positions(account);
            assertEq(size, ghostLots[i] * CfdTypes.SIZE_QUANTUM, "persistent size model");
            assertEq(accrued, ghostVpiAccrued[i], "independent lifetime VPI model");
            assertEq(int256(clearinghouse.balanceUsdc(account)), ghostTraderCash[i], "independent trader cash model");
            uint256 reserve = ghostVpiAccrued[i] < 0 ? uint256(-ghostVpiAccrued[i]) : 0;
            assertEq(clearinghouse.vpiRebateReserveUsdc(account), reserve, "exact lifetime rebate backing");
            assertEq(engine.traderClaimBalanceUsdc(account), 0, "zero-price-PnL actions cannot create claims");
            expectedCustody += uint256(ghostTraderCash[i]);
        }
        for (uint256 side; side < 2; ++side) {
            (, uint256 oi,,) = engine.sides(uint8(side));
            assertEq(oi, ghostSideLots[side] * CfdTypes.SIZE_QUANTUM, "independent side size model");
        }
        assertEq(int256(usdc.balanceOf(pool)), ghostPoolCash, "VPI and frozen spread belong to LP cash");
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            ghostTreasuryCash,
            "only execution fees reach treasury"
        );
        assertEq(usdc.balanceOf(address(clearinghouse)), expectedCustody, "physical clearinghouse custody");
        assertFalse(engine.degradedMode(), "bounded funded actions remain solvent");
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

    function setUp() public override {
        super.setUp();
        handler = new PerpVpiFrozenAccountingHandler(engine, clearinghouse, usdc, address(router), address(housePool));
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

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: quick.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: audit.invariant.fail-on-revert = true
    function invariant_PersistentVpiCashAndReserveModel() public view {
        handler.assertModel();
    }

    function test_IndependentCashModelRejectsOneAtomOfUnmodeledPoolCash() public {
        handler.assertModel();
        usdc.mint(address(housePool), 1);
        vm.expectRevert();
        handler.assertModel();
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
