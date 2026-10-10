// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: accounting. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/ACCOUNTING_SPEC.md#close-settlement

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

contract PartialCloseCommitmentIsolationTest is BasePerpTest {

    address trader = address(0xC106);
    address counterparty = address(0xBEA2);
    address constant KEEPER = address(0xC0FFEE);

    /// @dev accounting; source: ACCOUNTING_SPEC.md#close-settlement.
    function test_PartialCloseWithPendingOrderDoesNotRevert() public {
        address account = trader;
        address counterAccount = counterparty;

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        _open(counterAccount, CfdTypes.Side.SHORT, 100_000e18, 50_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 4000e6, type(uint256).max, false);

        uint256 committedBefore = _remainingCommittedMargin(1);
        assertGt(committedBefore, 0, "Should have committed margin from pending open order");

        uint256 freeSettlement = _freeSettlementUsdc(account);
        assertLt(freeSettlement, 1100e6, "Free settlement should be small after committing margin");

        _close(account, CfdTypes.Side.LONG, 50_000e18, 1.02e8);

        (uint256 sizeAfter,,,,,,) = engine.positions(account);
        assertEq(sizeAfter, 50_000e18, "Partial close should leave half the position");
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#close-settlement.
    function test_PartialCloseLossLeavesQueuedCommittedMarginUntouched() public {
        address account = trader;
        address counterAccount = counterparty;

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        _open(counterAccount, CfdTypes.Side.SHORT, 100_000e18, 50_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 4000e6, type(uint256).max, false);

        uint256 committedBefore = _remainingCommittedMargin(1);
        assertEq(committedBefore, 4000e6, "Committed margin should match order margin delta");
        uint256 pnlPledgeBefore = clearinghouse.pnlPledgeUsdc(account);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 50_000e18, 1.02e8);

        assertTrue(preview.valid, "Dedicated price collateral should fund the partial-close loss");
        assertEq(preview.realizedPnlUsdc, -1000e6, "Fixture should realize a one-thousand USDC price loss");
        assertEq(
            preview.remainingMargin,
            pnlPledgeBefore / 2,
            "The retained half-position should keep its proportional dedicated PnL pledge"
        );
        assertEq(preview.badDebtUsdc, 0, "Any price-loss tail beyond the close slice's cap is a writeoff, not debt");

        _close(account, CfdTypes.Side.LONG, 50_000e18, 1.02e8);

        (uint256 sizeAfter, uint256 marginAfter,,,,,) = engine.positions(account);
        assertEq(sizeAfter, preview.remainingSize, "Live partial close should match the accepted preview");
        assertEq(marginAfter, preview.remainingMargin, "Live PnL pledge should match the accepted preview");
        assertEq(
            _remainingCommittedMargin(1),
            committedBefore,
            "Exact price settlement must not consume a queued order's committed margin"
        );
    }

}

contract WholeLotResidualCloseTest is BasePerpTest {

    address alice = address(0x111);

    /// @dev accounting; source: ACCOUNTING_SPEC.md#close-settlement.
    function test_PartialCloseLeavesLiquidatableExactWholeLotResidual() public {
        _fundTrader(alice, 50_000 * 1e6);
        address aliceAccount = alice;

        // Open 50k tokens at $1.00: notional = $50k
        // The 1.5% initial-margin requirement is $750. The supplied margin also funds the
        // dedicated $50 liquidation reserve and the $20 execution fee.
        uint256 posSize = 50_000 * 1e18;
        _open(aliceAccount, CfdTypes.Side.LONG, posSize, 825 * 1e6, 1e8);

        // Closing every lot but one is quantum-valid. V2 permits the exact residual and
        // preserves its dedicated liquidation reserve so it can still be liquidated.
        uint256 closeSize = posSize - CfdTypes.SIZE_QUANTUM;
        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                account: aliceAccount,
                sizeDelta: closeSize,
                marginDelta: 0,
                targetPrice: 0,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: CfdTypes.Side.LONG,
                isClose: true
            }),
            1e8,
            depth,
            uint64(block.timestamp)
        );

        (uint256 remainingSize, uint256 remainingMargin,,,,,) = engine.positions(aliceAccount);
        assertEq(remainingSize, CfdTypes.SIZE_QUANTUM, "Partial close must leave one canonical whole lot");
        assertLt(remainingMargin, 5e6, "Fixture must retain a small but exact residual pledge");
        assertEq(
            clearinghouse.liquidationReserveUsdc(aliceAccount),
            _riskParams().minBountyUsdc,
            "Residual lot must retain the configured minimum liquidation reserve"
        );
        _assertTerminalCurveMatchesEngine(aliceAccount);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(aliceAccount, 101_000_000);
        assertTrue(preview.liquidatable, "An adverse exact price must make the residual lot liquidatable");

        depth = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(aliceAccount, 101_000_000, depth, uint64(block.timestamp), address(this));
        (remainingSize,,,,,,) = engine.positions(aliceAccount);
        assertEq(remainingSize, 0, "Liquidation must clear the exact residual lot");
        _assertTerminalCurveMatchesEngine(aliceAccount);
    }

}

contract PriceAndActionReservePriorityCloseTest is BasePerpTest {

    address trader = address(0xC10A);

    /// @dev accounting; source: ACCOUNTING_SPEC.md#close-settlement.
    function test_FullCloseUsesReleasedPledgeBeforeQueuedCommittedMargin() public {
        address account = trader;
        _fundTrader(trader, 10_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        uint64 queuedOrderId = router.nextCommitId();
        uint256 committedMarginUsdc = _freeSettlementUsdc(account) - 200_000;
        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, committedMarginUsdc, type(uint256).max, false);

        uint256 committedBefore = router.getAccountReservations(account).committedMarginUsdc;
        assertEq(_freeSettlementUsdc(account), 0, "Setup must shelter all non-bounty free settlement in the queue");
        vm.warp(block.timestamp + 365 days);
        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 1e8);
        assertTrue(preview.valid, "Full close should collect terminal carry from queued committed margin");
        assertEq(preview.realizedPnlUsdc, 0, "Setup must isolate action charges from price PnL");
        assertEq(preview.badDebtUsdc, 0, "Action-charge collection must never create protocol debt");

        _close(account, CfdTypes.Side.LONG, 100_000e18, 1e8);

        assertEq(
            router.getAccountReservations(account).committedMarginUsdc,
            committedBefore,
            "Released pledge covers the charges before queued margin"
        );
        assertEq(_executionBountyReserve(queuedOrderId), 200_000, "Queued execution bounty should remain reserved");
        assertEq(
            router.pendingOrderCounts(account),
            1,
            "Queued successor order itself should remain pending after the live position closes"
        );
    }

}

contract UnderwaterPartialCloseTest is BasePerpTest {

    address trader = address(0xD00D);

    /// @dev accounting; source: ACCOUNTING_SPEC.md#close-settlement.
    function test_UnderwaterPartialCloseMustRevertInsteadOfSocializingLosses() public {
        address account = trader;

        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        uint256 depth = pool.totalAssets();
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
                uint8(CfdEnginePlanTypes.CloseRevertCode.PARTIAL_CLOSE_UNHEALTHY),
                true
            )
        );
        _close(account, CfdTypes.Side.LONG, 99_000e18, 110_000_000, depth);
    }

}
