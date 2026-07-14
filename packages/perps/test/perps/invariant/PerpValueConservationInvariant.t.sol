// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

contract PerpValueConservationHandler is Test {

    MockUSDC internal immutable usdc;
    CfdEngine internal immutable engine;
    MarginClearinghouse internal immutable clearinghouse;
    OrderRouter internal immutable router;
    HousePool internal immutable pool;
    TrancheVault internal immutable juniorVault;
    MockPyth internal immutable mockPyth;

    bytes32 internal constant BASE_PYTH_FEED_A = bytes32(uint256(1));
    bytes32 internal constant BASE_PYTH_FEED_B = bytes32(uint256(2));

    address internal constant FULL_CLOSE_TRADER = address(0xA11CE01);
    address internal constant FULL_CLOSE_COUNTERPARTY = address(0xB0B01);
    address internal constant FAILED_CLOSE_KEEPER = address(0xC0FFEE01);
    address internal constant BULL_TRADER = address(0xB01102);
    address internal constant BEAR_TRADER = address(0xBEA202);
    address internal constant JUNIOR_ATTACKER = address(0xBAD02);
    address internal constant CARRY_TRADER = address(0xCA2203);

    bool public failedCloseExtractedMargin;
    bool public neutralMtmCreatedLpProfit;
    bool public checkpointForgaveHistoricalCarry;
    bool public pendingRevenueDisappeared;

    uint256 public failedCloseKeeperGainUsdc;
    uint256 public neutralMtmLpProfitUsdc;
    uint256 public forgivenCarryUsdc;
    uint256 public disappearedRevenueUsdc;

    constructor(
        MockUSDC usdc_,
        CfdEngine engine_,
        MarginClearinghouse clearinghouse_,
        OrderRouter router_,
        HousePool pool_,
        TrancheVault juniorVault_,
        MockPyth mockPyth_
    ) {
        usdc = usdc_;
        engine = engine_;
        clearinghouse = clearinghouse_;
        router = router_;
        pool = pool_;
        juniorVault = juniorVault_;
        mockPyth = mockPyth_;
    }

    function failedFullCloseCannotExtractMargin(
        uint256 executionPriceFuzz
    ) external {
        uint256 snapshot = vm.snapshotState();
        bool violation;
        uint256 keeperGain;

        _fundTrader(FULL_CLOSE_TRADER, 5000e6);
        _fundTrader(FULL_CLOSE_COUNTERPARTY, 50_000e6);
        _open(FULL_CLOSE_TRADER, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);
        _open(FULL_CLOSE_COUNTERPARTY, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        uint256 executionPrice = bound(executionPriceFuzz, 1.8e8, 1.99e8);
        vm.prank(address(router));
        engine.updateMarkPrice(executionPrice, uint64(block.timestamp));

        (, uint256 marginBefore,,,,,) = engine.positions(FULL_CLOSE_TRADER);
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(FAILED_CLOSE_KEEPER);
        uint256 targetPrice = executionPrice - 1;

        vm.prank(FULL_CLOSE_TRADER);
        (bool committed,) = address(router)
            .call(abi.encodeCall(router.commitOrder, (CfdTypes.Side.BULL, 100_000e18, 0, targetPrice, true)));
        if (committed) {
            bytes[] memory priceData = _mockPythUpdateData(executionPrice);
            vm.prank(FAILED_CLOSE_KEEPER);
            (bool executed,) = address(router).call(abi.encodeCall(router.executeOrder, (uint64(1), priceData)));
            if (executed) {
                (uint256 sizeAfter, uint256 marginAfter,,,,,) = engine.positions(FULL_CLOSE_TRADER);
                keeperGain = clearinghouse.balanceUsdc(FAILED_CLOSE_KEEPER) - keeperSettlementBefore;
                violation = sizeAfter > 0 && (keeperGain > 0 || marginAfter < marginBefore);
            }
        }

        vm.revertToState(snapshot);
        if (violation) {
            failedCloseExtractedMargin = true;
            failedCloseKeeperGainUsdc = keeperGain;
        }
    }

    function neutralMtmCannotCreateLpDepositWithdrawProfit(
        uint256 sizeFuzz,
        uint256 depositFuzz
    ) external {
        uint256 snapshot = vm.snapshotState();
        bool violation;
        uint256 profit;

        uint256 size = bound(sizeFuzz, 50_000e18, 300_000e18);
        uint256 depositAssets = bound(depositFuzz, 10_000e6, 300_000e6);

        _fundTrader(BULL_TRADER, 50_000e6);
        _fundTrader(BEAR_TRADER, 50_000e6);
        _open(BULL_TRADER, CfdTypes.Side.BULL, size, 10_000e6, 1e8);
        _open(BEAR_TRADER, CfdTypes.Side.BEAR, size, 10_000e6, 1e8);

        int256 pnl = _unrealizedTraderPnl();
        if (pnl == 0) {
            usdc.mint(JUNIOR_ATTACKER, depositAssets);
            vm.startPrank(JUNIOR_ATTACKER);
            usdc.approve(address(juniorVault), depositAssets);
            (bool deposited, bytes memory depositReturn) =
                address(juniorVault).call(abi.encodeCall(juniorVault.deposit, (depositAssets, JUNIOR_ATTACKER)));
            vm.stopPrank();

            if (deposited) {
                uint256 shares = abi.decode(depositReturn, (uint256));
                _close(BULL_TRADER, CfdTypes.Side.BULL, size, 1e8);
                _close(BEAR_TRADER, CfdTypes.Side.BEAR, size, 1e8);

                vm.warp(block.timestamp + 1 hours + 1);
                vm.prank(JUNIOR_ATTACKER);
                (bool redeemed,) = address(juniorVault)
                    .call(abi.encodeCall(juniorVault.redeem, (shares, JUNIOR_ATTACKER, JUNIOR_ATTACKER)));
                if (redeemed) {
                    uint256 finalBalance = usdc.balanceOf(JUNIOR_ATTACKER);
                    violation = finalBalance > depositAssets;
                    profit = violation ? finalBalance - depositAssets : 0;
                }
            }
        }

        vm.revertToState(snapshot);
        if (violation) {
            neutralMtmCreatedLpProfit = true;
            neutralMtmLpProfitUsdc = profit;
        }
    }

    function timedCheckpointCannotForgiveHistoricalCarry(
        uint256 elapsedFuzz,
        uint256 checkpointPriceFuzz
    ) external {
        uint256 snapshot = vm.snapshotState();
        bool violation;
        uint256 forgiven;

        _fundTrader(CARRY_TRADER, 150_000e6);
        _open(CARRY_TRADER, CfdTypes.Side.BULL, 200_000e18, 100_000e6, 1e8);

        uint256 balanceBeforeCheckpoint = clearinghouse.balanceUsdc(CARRY_TRADER);
        uint256 elapsed = bound(elapsedFuzz, 7 days, 60 days);
        uint256 checkpointPrice = bound(checkpointPriceFuzz, 0.4e8, 0.7e8);

        vm.warp(block.timestamp + elapsed);
        vm.prank(address(router));
        engine.updateMarkPrice(checkpointPrice, uint64(block.timestamp));
        uint256 minimumHistoricalCarryUsdc = _pendingIndexedCarryUsdc(CARRY_TRADER);

        usdc.mint(CARRY_TRADER, 1);
        vm.startPrank(CARRY_TRADER);
        usdc.approve(address(clearinghouse), 1);
        (bool deposited,) = address(clearinghouse).call(abi.encodeCall(clearinghouse.deposit, (CARRY_TRADER, 1)));
        vm.stopPrank();

        if (deposited) {
            uint256 balanceAfterCheckpoint = clearinghouse.balanceUsdc(CARRY_TRADER);
            uint256 maxAllowedBalance = balanceBeforeCheckpoint + 1 - minimumHistoricalCarryUsdc;
            violation = balanceAfterCheckpoint > maxAllowedBalance;
            forgiven = violation ? balanceAfterCheckpoint - maxAllowedBalance : 0;
        }

        vm.revertToState(snapshot);
        if (violation) {
            checkpointForgaveHistoricalCarry = true;
            forgivenCarryUsdc = forgiven;
        }
    }

    function recapRevenueReconcileCannotDropClaimantValue(
        uint256 recapFuzz,
        uint256 revenueFuzz
    ) external {
        uint256 snapshot = vm.snapshotState();
        bool violation;
        uint256 disappeared;

        usdc.burn(address(pool), pool.rawAssets());
        vm.prank(address(juniorVault));
        (bool wiped,) = address(pool).call(abi.encodeCall(pool.reconcile, ()));

        if (wiped && pool.seniorPrincipal() + pool.juniorPrincipal() == 0) {
            uint256 recapitalizationUsdc = bound(recapFuzz, 1e6, 5000e6);
            uint256 revenueUsdc = bound(revenueFuzz, 1e6, 5000e6);
            usdc.mint(address(pool), recapitalizationUsdc + revenueUsdc);

            vm.startPrank(address(engine));
            pool.recordClaimantInflow(
                recapitalizationUsdc,
                IHousePool.ClaimantInflowKind.Recapitalization,
                IHousePool.ClaimantInflowCashMode.CashArrived
            );
            pool.recordClaimantInflow(
                revenueUsdc, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
            );
            vm.stopPrank();

            uint256 claimantLedgerBefore = _claimantLedgerUsdc();
            vm.prank(address(juniorVault));
            (bool reconciled,) = address(pool).call(abi.encodeCall(pool.reconcile, ()));
            if (reconciled) {
                uint256 claimantLedgerAfter = _claimantLedgerUsdc();
                violation = claimantLedgerAfter < claimantLedgerBefore;
                disappeared = violation ? claimantLedgerBefore - claimantLedgerAfter : 0;
            }
        }

        vm.revertToState(snapshot);
        if (violation) {
            pendingRevenueDisappeared = true;
            disappearedRevenueUsdc = disappeared;
        }
    }

    function _fundTrader(
        address trader,
        uint256 amount
    ) internal {
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(trader, amount);
        vm.stopPrank();
    }

    function _open(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price
    ) internal {
        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                account: account,
                sizeDelta: size,
                marginDelta: margin,
                targetPrice: price,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: side,
                isClose: false
            }),
            price,
            depth,
            uint64(block.timestamp)
        );
    }

    function _close(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 price
    ) internal {
        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                account: account,
                sizeDelta: size,
                marginDelta: 0,
                targetPrice: 0,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: side,
                isClose: true
            }),
            price,
            depth,
            uint64(block.timestamp)
        );
    }

    function _mockPythUpdateData(
        uint256 price
    ) internal returns (bytes[] memory updateData) {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        bytes32[] memory feedIds = new bytes32[](2);
        feedIds[0] = BASE_PYTH_FEED_A;
        feedIds[1] = BASE_PYTH_FEED_B;
        mockPyth.setAllUniquePrices(feedIds, int64(uint64(price)), 0, int32(-8), block.timestamp, block.timestamp - 1);

        updateData = new bytes[](1);
        updateData[0] = abi.encode(price);
    }

    function _unrealizedTraderPnl() internal view returns (int256) {
        uint256 price = engine.lastMarkPrice();
        (uint256 bullMaxProfit, uint256 bullOi, uint256 bullEntryNotional,) = engine.sides(uint8(CfdTypes.Side.BULL));
        bullMaxProfit;
        (uint256 bearMaxProfit, uint256 bearOi, uint256 bearEntryNotional,) = engine.sides(uint8(CfdTypes.Side.BEAR));
        bearMaxProfit;
        int256 bullPnl = (int256(bullEntryNotional) - int256(bullOi * price)) / int256(1e20);
        int256 bearPnl = (int256(bearOi * price) - int256(bearEntryNotional)) / int256(1e20);
        return bullPnl + bearPnl;
    }

    function _claimantLedgerUsdc() internal view returns (uint256) {
        return pool.seniorPrincipal() + pool.juniorPrincipal() + pool.unassignedAssets()
            + pool.pendingRecapitalizationUsdc() + pool.pendingTradingRevenueUsdc();
    }

    function _pendingIndexedCarryUsdc(
        address account
    ) internal view returns (uint256) {
        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(account);
        if (size == 0) {
            return 0;
        }
        (uint256 borrowBaseUsdc, uint256 startIndex,) = engine.positionCarryState(account);
        if (borrowBaseUsdc == 0) {
            return 0;
        }
        uint256 endIndex = _currentSideCarryIndex(side);
        if (endIndex <= startIndex) {
            return 0;
        }
        return PositionRiskAccountingLib.computeIndexedCarryUsdc(borrowBaseUsdc, endIndex - startIndex);
    }

    function _currentSideCarryIndex(
        CfdTypes.Side side
    ) internal view returns (uint256 index) {
        uint256 sideIndex = uint256(side);
        (,,,,, uint256 baseCarryBps,,) = engine.riskParams();
        index = PositionRiskAccountingLib.computeCurrentCarryIndex(
            engine.sideCarryIndex(sideIndex),
            engine.sideCarryTimestamp(sideIndex),
            block.timestamp,
            engine.sideBorrowBaseUsdc(sideIndex),
            pool.totalAssets(),
            baseCarryBps
        );
    }

}

contract PerpValueConservationInvariantTest is BasePerpTest {

    PerpValueConservationHandler internal handler;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10
        });
    }

    function setUp() public override {
        super.setUp();

        handler = new PerpValueConservationHandler(usdc, engine, clearinghouse, router, pool, juniorVault, baseMockPyth);

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.failedFullCloseCannotExtractMargin.selector;
        selectors[1] = handler.neutralMtmCannotCreateLpDepositWithdrawProfit.selector;
        selectors[2] = handler.timedCheckpointCannotForgiveHistoricalCarry.selector;
        selectors[3] = handler.recapRevenueReconcileCannotDropClaimantValue.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_FailedExecutionCannotExtractActiveMargin() public view {
        assertFalse(handler.failedCloseExtractedMargin(), "Failed close execution extracted active position margin");
    }

    function invariant_NeutralMtmCannotCreateLpProfit() public view {
        assertFalse(handler.neutralMtmCreatedLpProfit(), "Neutral MTM deposit/withdraw sequence created LP profit");
    }

    function invariant_CarryCheckpointsCannotForgiveHistory() public view {
        assertFalse(handler.checkpointForgaveHistoricalCarry(), "Timed carry checkpoint forgave historical carry");
    }

    function invariant_PendingRevenueCannotDisappear() public view {
        assertFalse(handler.pendingRevenueDisappeared(), "Pending revenue disappeared during recap/reconcile");
    }

}
