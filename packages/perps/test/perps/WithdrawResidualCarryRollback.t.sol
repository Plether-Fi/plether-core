// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {ITerminalNavBookV2} from "@plether/perps/interfaces/ITerminalNavBookV2.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";

/// @notice Adversarial regression coverage for withdrawal-time carry realization.
contract WithdrawResidualCarryRollbackTest is BasePerpTest {

    struct CarryState {
        uint256 borrowBaseUsdc;
        uint256 lastCarryIndex;
        uint64 lastCarryTimestamp;
        uint256 sideCarryIndex;
        uint64 sideCarryTimestamp;
        uint256 unsettledCarryUsdc;
    }

    struct CustodyState {
        uint256 settlementBalanceUsdc;
        uint256 pnlPledgeUsdc;
        uint256 liquidationReserveUsdc;
        uint256 orderMarginUsdc;
        uint256 actionReserveUsdc;
        uint256 vpiRebateReserveUsdc;
        uint256 totalLockedUsdc;
        uint256 freeSettlementUsdc;
        uint256 clearinghouseCashUsdc;
        uint256 poolCashUsdc;
        uint256 poolAccountedAssetsUsdc;
        uint256 traderCashUsdc;
    }

    struct RollbackState {
        CarryState carry;
        CustodyState custody;
        bytes32 terminalCurveHash;
        ITerminalNavBookV2.BookState terminalBook;
    }

    function test_AccountLens_FullyFreeFundedCarryDoesNotWorsenPriceHealth() public {
        address trader = address(0xCA770002);
        address account = trader;
        uint256 executionPrice = 1e8;

        _fundTrader(trader, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 50_000e18, 850e6, executionPrice);
        vm.warp(block.timestamp + 3 * 365 days);

        uint256 pendingCarryUsdc = _expectedIndexedCarryUsdc(account);
        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(account);
        MarginClearinghouseAccountingLib.SettlementConsumption memory carryConsumption =
            MarginClearinghouseAccountingLib.planCarryLossConsumption(buckets, pendingCarryUsdc);
        assertGt(pendingCarryUsdc, 0, "setup must accrue carry");
        assertEq(carryConsumption.uncoveredUsdc, 0, "free settlement must fully fund carry");

        CfdTypes.Position memory pos = _position(account);
        uint256 priceCollateralUsdc = pos.margin + engine.traderClaimBalanceUsdc(account);
        uint256 maintenanceBps = _maintenanceMarginBps();
        assertFalse(
            engine.planner()
                .isExactPriceRiskLiquidatable(
                    pos,
                    engine.positionEntryCostUsdcAtoms(account),
                    executionPrice,
                    engine.CAP_PRICE(),
                    priceCollateralUsdc,
                    maintenanceBps
                ),
            "exact price risk must be healthy"
        );
        assertTrue(
            engine.planner()
                .isExactPositionLiquidatableWithCarry(
                    pos,
                    engine.positionEntryCostUsdcAtoms(account),
                    executionPrice,
                    engine.CAP_PRICE(),
                    pendingCarryUsdc,
                    priceCollateralUsdc,
                    maintenanceBps
                ),
            "setup must distinguish the retired carry-in-equity calculation"
        );

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = engineAccountLens.getAccountLedgerSnapshot(account);
        assertFalse(snapshot.liquidatable, "fully funded carry must not make the account liquidatable");
        assertFalse(publicLens.isLiquidatable(account), "public lens must preserve strict carry isolation");
    }

    function test_AccountLens_UncoveredCarryIsIndependentDelinquency() public {
        address trader = address(0xCA770003);
        address account = trader;
        uint256 executionPrice = 1e8;

        _fundTrader(trader, 3500e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 3000e6, executionPrice);
        uint256 withdrawableUsdc = engineAccountLens.getWithdrawableUsdc(account);
        assertGt(withdrawableUsdc, 0, "setup must initially have removable free settlement");
        vm.prank(trader);
        clearinghouse.withdraw(account, withdrawableUsdc);

        vm.warp(block.timestamp + 1 days);
        uint256 pendingCarryUsdc = _expectedIndexedCarryUsdc(account);
        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(account);
        MarginClearinghouseAccountingLib.SettlementConsumption memory carryConsumption =
            MarginClearinghouseAccountingLib.planCarryLossConsumption(buckets, pendingCarryUsdc);
        assertGt(carryConsumption.uncoveredUsdc, 0, "setup must leave carry independently delinquent");

        CfdTypes.Position memory pos = _position(account);
        uint256 priceCollateralUsdc = pos.margin + engine.traderClaimBalanceUsdc(account);
        uint256 maintenanceBps = _maintenanceMarginBps();
        assertFalse(
            engine.planner()
                .isExactPositionLiquidatableWithCarry(
                    pos,
                    engine.positionEntryCostUsdcAtoms(account),
                    executionPrice,
                    engine.CAP_PRICE(),
                    carryConsumption.uncoveredUsdc,
                    priceCollateralUsdc,
                    maintenanceBps
                ),
            "residual must be too small to fail the retired fungible-equity test"
        );

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = engineAccountLens.getAccountLedgerSnapshot(account);
        assertTrue(snapshot.liquidatable, "any uncovered carry must independently mark delinquency");
        assertTrue(publicLens.isLiquidatable(account), "public lens must expose carry delinquency");
        assertEq(engineAccountLens.getWithdrawableUsdc(account), 0, "delinquent carry must block withdrawal");
    }

    function test_WithdrawResidualCarryBlocksAndRollsBackEveryProvisionalMutation() public {
        address account = address(0xCA770001);
        uint256 executionPrice = 1e8;

        // The opening action leaves a healthy isolated PnL pledge plus a small amount of free settlement.
        // Ten years of indexed carry exceeds both the free settlement and the position's risk headroom.
        _fundTrader(account, 3500e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 3000e6, executionPrice);

        {
            vm.warp(block.timestamp + 10 * 365 days);
            engine.checkpointCarryIndexes();
            uint64 refreshedAt = engine.sideCarryTimestamp(uint256(CfdTypes.Side.LONG));
            vm.prank(address(router));
            engine.updateMarkPrice(executionPrice, refreshedAt);
            assertEq(engine.lastMarkPrice(), executionPrice, "setup must keep the intended live mark");
            assertEq(engine.lastMarkTime(), refreshedAt, "setup must refresh mark time after carry accrual");
        }

        CfdTypes.Side positionSide;
        {
            uint256 pendingCarryUsdc = _expectedIndexedCarryUsdc(account);
            IMarginClearinghouse.PnlIsolationBuckets memory buckets = clearinghouse.getPnlIsolationBuckets(account);
            assertGt(pendingCarryUsdc, buckets.freeSettlementUsdc, "setup must leave uncovered carry after realization");
            uint256 residualCarryUsdc = pendingCarryUsdc - buckets.freeSettlementUsdc;

            CfdTypes.Position memory pos = _position(account);
            positionSide = pos.side;
            uint256 reachablePriceCollateralUsdc =
                buckets.pnlPledgeUsdc + engine.traderClaimBalanceUsdc(account) + buckets.vpiRebateReserveUsdc;
            uint256 requiredMarginBps = _withdrawRequiredMarginBps();

            assertFalse(
                engine.planner()
                    .isExactPositionLiquidatableWithCarry(
                        pos,
                        engine.positionEntryCostUsdcAtoms(account),
                        executionPrice,
                        engine.CAP_PRICE(),
                        0,
                        reachablePriceCollateralUsdc,
                        requiredMarginBps
                    ),
                "without residual carry, the exact post-withdraw price-risk state must be healthy"
            );
            assertTrue(
                engine.planner()
                    .isExactPositionLiquidatableWithCarry(
                        pos,
                        engine.positionEntryCostUsdcAtoms(account),
                        executionPrice,
                        engine.CAP_PRICE(),
                        residualCarryUsdc,
                        reachablePriceCollateralUsdc,
                        requiredMarginBps
                    ),
                "the uncollectible residual alone must make the exact position liquidatable"
            );
        }

        RollbackState memory beforeState = _rollbackState(account, positionSide);

        // The clearinghouse checkpoints carry, provisionally debits settlement, and enters the Engine guard.
        // The uncovered carry must reject here; all earlier mutations belong to the same transaction and roll back.
        vm.expectRevert(ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        vm.prank(account);
        clearinghouse.withdraw(account, 1e6);

        _assertCarryStateEq(_carryState(account, positionSide), beforeState.carry);
        _assertCustodyStateEq(_custodyState(account, account), beforeState.custody);
        assertEq(
            terminalNavBook.curveHashOf(account), beforeState.terminalCurveHash, "terminal curve hash must roll back"
        );
        ITerminalNavBookV2.BookState memory terminalBookAfter = terminalNavBook.bookState();
        assertEq(
            terminalBookAfter.bookVersion, beforeState.terminalBook.bookVersion, "terminal book version must roll back"
        );
        assertEq(terminalBookAfter.totalLots, beforeState.terminalBook.totalLots, "terminal book lots must roll back");
        assertEq(
            terminalBookAfter.totalEffectiveCapUsdcAtoms,
            beforeState.terminalBook.totalEffectiveCapUsdcAtoms,
            "terminal collectible cap must roll back"
        );
    }

    function _rollbackState(
        address account,
        CfdTypes.Side side
    ) internal view returns (RollbackState memory state) {
        state.carry = _carryState(account, side);
        state.custody = _custodyState(account, account);
        state.terminalCurveHash = terminalNavBook.curveHashOf(account);
        state.terminalBook = terminalNavBook.bookState();
    }

    function _position(
        address account
    ) internal view returns (CfdTypes.Position memory pos) {
        (pos.size, pos.margin, pos.entryPrice, pos.maxProfitUsdc, pos.side, pos.lastUpdateTime, pos.vpiAccrued) =
            engine.positions(account);
    }

    function _withdrawRequiredMarginBps() internal view returns (uint256 requiredMarginBps) {
        (,, uint256 maintMarginBps, uint256 initMarginBps, uint256 fadMarginBps,,,,,) = engine.riskParams();
        uint256 activeMarginBps = engine.isFadWindow() ? fadMarginBps : maintMarginBps;
        requiredMarginBps = initMarginBps > activeMarginBps ? initMarginBps : activeMarginBps;
    }

    function _maintenanceMarginBps() internal view returns (uint256 maintenanceBps) {
        (,, uint256 maintMarginBps,, uint256 fadMarginBps,,,,,) = engine.riskParams();
        return engine.isFadWindow() ? fadMarginBps : maintMarginBps;
    }

    function _carryState(
        address account,
        CfdTypes.Side side
    ) internal view returns (CarryState memory state) {
        (state.borrowBaseUsdc, state.lastCarryIndex, state.lastCarryTimestamp) = engine.positionCarryState(account);
        uint256 sideIndex = uint256(side);
        state.sideCarryIndex = engine.sideCarryIndex(sideIndex);
        state.sideCarryTimestamp = engine.sideCarryTimestamp(sideIndex);
        state.unsettledCarryUsdc = engine.unsettledCarryUsdc(account);
    }

    function _custodyState(
        address account,
        address trader
    ) internal view returns (CustodyState memory state) {
        IMarginClearinghouse.PnlIsolationBuckets memory buckets = clearinghouse.getPnlIsolationBuckets(account);
        state.settlementBalanceUsdc = buckets.settlementBalanceUsdc;
        state.pnlPledgeUsdc = buckets.pnlPledgeUsdc;
        state.liquidationReserveUsdc = buckets.liquidationReserveUsdc;
        state.orderMarginUsdc = buckets.orderMarginUsdc;
        state.actionReserveUsdc = buckets.actionReserveUsdc;
        state.vpiRebateReserveUsdc = buckets.vpiRebateReserveUsdc;
        state.totalLockedUsdc = buckets.totalLockedUsdc;
        state.freeSettlementUsdc = buckets.freeSettlementUsdc;
        state.clearinghouseCashUsdc = usdc.balanceOf(address(clearinghouse));
        state.poolCashUsdc = pool.rawAssets();
        state.poolAccountedAssetsUsdc = pool.accountedAssets();
        state.traderCashUsdc = usdc.balanceOf(trader);
    }

    function _assertCarryStateEq(
        CarryState memory actual,
        CarryState memory expected
    ) internal pure {
        assertEq(actual.borrowBaseUsdc, expected.borrowBaseUsdc, "position borrow base must roll back");
        assertEq(actual.lastCarryIndex, expected.lastCarryIndex, "position carry index must roll back");
        assertEq(actual.lastCarryTimestamp, expected.lastCarryTimestamp, "position carry timestamp must roll back");
        assertEq(actual.sideCarryIndex, expected.sideCarryIndex, "side carry index must roll back");
        assertEq(actual.sideCarryTimestamp, expected.sideCarryTimestamp, "side carry timestamp must roll back");
        assertEq(actual.unsettledCarryUsdc, expected.unsettledCarryUsdc, "unsettled carry must roll back");
    }

    function _assertCustodyStateEq(
        CustodyState memory actual,
        CustodyState memory expected
    ) internal pure {
        assertEq(actual.settlementBalanceUsdc, expected.settlementBalanceUsdc, "settlement debit must roll back");
        assertEq(actual.pnlPledgeUsdc, expected.pnlPledgeUsdc, "PnL pledge must roll back");
        assertEq(actual.liquidationReserveUsdc, expected.liquidationReserveUsdc, "liquidation reserve must roll back");
        assertEq(actual.orderMarginUsdc, expected.orderMarginUsdc, "order margin must roll back");
        assertEq(actual.actionReserveUsdc, expected.actionReserveUsdc, "action reserve must roll back");
        assertEq(actual.vpiRebateReserveUsdc, expected.vpiRebateReserveUsdc, "VPI reserve must roll back");
        assertEq(actual.totalLockedUsdc, expected.totalLockedUsdc, "total locked settlement must roll back");
        assertEq(actual.freeSettlementUsdc, expected.freeSettlementUsdc, "free settlement must roll back");
        assertEq(actual.clearinghouseCashUsdc, expected.clearinghouseCashUsdc, "clearinghouse cash must roll back");
        assertEq(actual.poolCashUsdc, expected.poolCashUsdc, "pool carry inflow must roll back");
        assertEq(
            actual.poolAccountedAssetsUsdc,
            expected.poolAccountedAssetsUsdc,
            "pool accounted carry inflow must roll back"
        );
        assertEq(actual.traderCashUsdc, expected.traderCashUsdc, "withdrawal transfer must not escape");
    }

}
