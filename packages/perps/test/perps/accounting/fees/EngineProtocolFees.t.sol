// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";

import {ICfdEngineSettlementSidecar} from "@plether/perps/interfaces/ICfdEngineSettlementSidecar.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {CfdEngineTestBase} from "../../shared/CfdEngineTestBase.sol";

contract EngineProtocolFeesTest is CfdEngineTestBase {

    using stdStorage for StdStorage;

    function test_ProtocolFeeTopUp_DoesNotLeapfrogTraderClaims() public {
        address account = address(0xD30F);
        _fundTrader(account, 11_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        uint256 closePrice = 80_000_000;
        uint256 executionFeeAssets = _engineExecutionFeeAssets(100_000e18, closePrice);
        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), poolAssets - executionFeeAssets);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, closePrice);
        assertTrue(preview.valid, "Setup close preview should be valid");
        assertEq(preview.immediatePayoutAssets, 0, "Setup must record the trader payout as a claim");
        assertGt(preview.traderClaimBalanceAssets, 0, "Setup must create a trader claim");
        assertEq(pool.totalAssets(), executionFeeAssets, "Setup leaves only the fee amount physically available");

        uint256 feesBefore = clearinghouse.balanceAssets(engine.protocolTreasury());
        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000e18,
            marginDelta: 0,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: CfdTypes.Side.LONG,
            isClose: true
        });
        uint256 closeDepth = pool.totalAssets();
        vm.prank(address(router));
        engine.processOrderTyped(closeOrder, closePrice, closeDepth, uint64(block.timestamp));

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Close should still destroy the position");
        assertGt(engine.traderClaimBalanceAssets(account), 0, "Trader claim should be recorded");
        assertEq(
            clearinghouse.balanceAssets(engine.protocolTreasury()),
            feesBefore,
            "Fee top-up must not leapfrog trader claims"
        );
    }

    function test_ProtocolFeeTopUp_PreviewPaysTraderWhenOnlyPayoutCashIsFree() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 0;
        _setRiskParams(params);

        address account = address(0xD310);
        _fundTrader(account, 11_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        uint256 closePrice = 80_000_000;
        CfdEngine.ClosePreview memory liquidPreview = engineLens.previewClose(account, 100_000e18, closePrice);
        assertGt(liquidPreview.freshTraderPayoutAssets, 0, "Setup must create a trader payout");
        assertGt(liquidPreview.executionFeeAssets, 0, "Setup must create a protocol fee");

        uint256 poolAssets = pool.totalAssets();
        uint256 drainAmount = poolAssets - liquidPreview.freshTraderPayoutAssets;
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), drainAmount);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, closePrice);
        assertTrue(preview.valid, "Setup close preview should be valid");
        assertEq(pool.totalAssets(), preview.freshTraderPayoutAssets, "Setup leaves exactly trader payout cash");
        assertLt(
            pool.totalAssets(),
            preview.freshTraderPayoutAssets + preview.executionFeeAssets,
            "Setup cannot also fund the protocol fee top-up"
        );
        assertEq(
            preview.immediatePayoutAssets, preview.freshTraderPayoutAssets, "Preview should follow trader payout cash"
        );
        assertEq(preview.traderClaimBalanceAssets, 0, "Preview should not defer when payout cash is free");

        uint256 feesBefore = clearinghouse.balanceAssets(engine.protocolTreasury());
        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(account);
        _close(account, CfdTypes.Side.LONG, 100_000e18, closePrice);

        CloseParityObserved memory observed = _observeCloseParity(account, beforeSnapshot);
        _assertClosePreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
        assertEq(
            clearinghouse.balanceAssets(engine.protocolTreasury()), feesBefore, "Unfunded fee top-up should not accrue"
        );
    }

    function test_OpenFeeTopUp_DoesNotSpendPendingRecapitalization() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 0.0005e18;
        _setRiskParams(params);

        address longAccount = address(0xD311);
        address shortAccount = address(0xD312);
        uint256 size = 100_000e18;
        uint256 reservedRecapitalizationAssets = 1_000_000e6;
        _fundTrader(longAccount, 20_000e6);
        _fundTrader(shortAccount, 20_000e6);
        _open(longAccount, CfdTypes.Side.LONG, size, 10_000e6, 1e8);

        settlementToken.mint(address(pool), reservedRecapitalizationAssets);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            reservedRecapitalizationAssets,
            IHousePool.ClaimantInflowKind.Recapitalization,
            IHousePool.ClaimantInflowCashMode.CashArrived
        );
        uint256 cashToDrainAssets = pool.totalAssets() - reservedRecapitalizationAssets;
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), cashToDrainAssets);
        assertEq(pool.getFreeAssets(), 0, "Recapitalization reserves the remaining cash");

        ICfdEngineTypes.OpenPreview memory preview =
            engineLens.previewOpen(shortAccount, CfdTypes.Side.SHORT, size, 10_000e6, 1e8);
        assertTrue(preview.valid, "Skew-healing open should remain valid");
        assertGt(preview.tradeCostAssets, 0, "Trade cost should fund part of the execution fee");
        assertLt(
            uint256(preview.tradeCostAssets), preview.executionFeeAssets, "Setup requires a pool-funded fee shortfall"
        );

        uint256 treasuryBefore = clearinghouse.balanceAssets(engine.protocolTreasury());
        _open(shortAccount, CfdTypes.Side.SHORT, size, 10_000e6, 1e8);

        assertEq(pool.totalAssets(), reservedRecapitalizationAssets, "Fee top-up must preserve recapitalization cash");
        assertEq(pool.pendingRecapitalizationAssets(), reservedRecapitalizationAssets);
        assertEq(
            clearinghouse.balanceAssets(engine.protocolTreasury()) - treasuryBefore,
            uint256(preview.tradeCostAssets),
            "Only the directly collected trade cost reaches the treasury"
        );
    }

    function test_OpenFeeTopUp_AdmitsTightBufferWithPartiallyFundedFee() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 0.0005e18;
        _setRiskParams(params);

        address longAccount = address(0xD313);
        address shortAccount = address(0xD314);
        uint256 size = 100_000e18;
        _fundTrader(longAccount, 20_000e6);
        _fundTrader(shortAccount, 20_000e6);
        _open(longAccount, CfdTypes.Side.LONG, size, 10_000e6, 1e8);

        CfdTypes.Order memory shortOrder = CfdTypes.Order({
            account: shortAccount,
            sizeDelta: size,
            marginDelta: 10_000e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: CfdTypes.Side.SHORT,
            isClose: false
        });
        ICfdEngineSettlementSidecar sidecar = engine.settlementSidecar();
        uint256 poolDepthAssets = pool.totalAssets();
        vm.prank(address(engine));
        CfdEnginePlanTypes.RawSnapshot memory snap = sidecar.buildRawSnapshot(shortAccount, poolDepthAssets);
        CfdEnginePlanTypes.OpenDelta memory roomy = engine.planner().planOpen(snap, shortOrder, 1e8);
        assertTrue(roomy.valid, "Setup must admit the offsetting open before cash is tightened");
        assertEq(engine.totalTraderClaimBalanceAssets(), 0);

        uint256 freeAfterOpenAssets = 1e6;
        uint256 targetCashAssets = roomy.requiredEffectiveAssetsAfterAssets + freeAfterOpenAssets;
        uint256 cashBefore = pool.totalAssets();
        assertGt(cashBefore, targetCashAssets);
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), cashBefore - targetCashAssets);

        ICfdEngineTypes.OpenPreview memory preview =
            engineLens.previewOpen(shortAccount, CfdTypes.Side.SHORT, size, 10_000e6, 1e8);
        assertTrue(preview.valid, "Affordable top-up should preserve the settlement buffer");
        assertGt(preview.tradeCostAssets, 0);
        assertGt(preview.executionFeeAssets - uint256(preview.tradeCostAssets), freeAfterOpenAssets);

        uint256 treasuryBefore = clearinghouse.balanceAssets(engine.protocolTreasury());
        _open(shortAccount, CfdTypes.Side.SHORT, size, 10_000e6, 1e8);
        assertEq(pool.totalAssets(), targetCashAssets - freeAfterOpenAssets);
        assertEq(pool.getSettlementFreeAssets(), 0, "Top-up must stop at the protected buffer");
        assertEq(
            clearinghouse.balanceAssets(engine.protocolTreasury()) - treasuryBefore,
            uint256(preview.tradeCostAssets) + freeAfterOpenAssets,
            "Treasury receives only direct collection and affordable pool cash"
        );
    }

    function test_ProtocolFees_CreditTreasuryMargin() public {
        address account = address(uint160(1));
        _fundTrader(account, 5000 * 1e6);

        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(order, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));

        // 100k LONG at $1.00: execFee = notional * 4bps = $100k * 0.0004 = $40
        uint256 fees = clearinghouse.balanceAssets(engine.protocolTreasury());
        assertEq(fees, 40_000_000, "Exec fee should be 4bps of $100k notional");

        address treasury = engine.protocolTreasury();
        uint256 treasuryBalanceBefore = settlementToken.balanceOf(treasury);
        uint256 assetsBeforeWithdrawal = pool.totalAssets();
        _withdrawProtocolTreasury(fees);

        assertEq(clearinghouse.balanceAssets(engine.protocolTreasury()), 0, "Fees should reset to zero");
        assertEq(
            settlementToken.balanceOf(treasury) - treasuryBalanceBefore, fees, "Treasury receives exact fee amount"
        );
        assertEq(pool.totalAssets(), assetsBeforeWithdrawal, "Treasury withdrawal should not touch vault assets");
        assertEq(pool.excessAssets(), 0, "Fee inflows should not remain stranded as vault excess");

        vm.prank(treasury);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientBalance.selector);
        clearinghouse.withdraw(treasury, fees);
    }

    function test_SetProtocolTreasury_KeepsExistingBalanceWithOldTreasury() public {
        address oldTreasury = engine.protocolTreasury();
        address newTreasury = address(0xFEE99);

        _fundProtocolTreasury(1e6);
        engine.setProtocolTreasury(newTreasury);

        assertEq(engine.protocolTreasury(), newTreasury, "Treasury should rotate despite the old balance");
        assertEq(clearinghouse.balanceAssets(oldTreasury), 1e6, "Old treasury retains its balance");
        assertEq(clearinghouse.balanceAssets(newTreasury), 0, "New treasury starts empty");

        address account = address(0xFEE9A);
        _fundTrader(account, 5000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);
        assertEq(clearinghouse.balanceAssets(newTreasury), 40e6, "Future fees go to the new treasury");
        assertEq(clearinghouse.balanceAssets(oldTreasury), 1e6, "Old balance stays with the old treasury");

        uint256 oldWalletBalance = settlementToken.balanceOf(oldTreasury);
        vm.prank(oldTreasury);
        clearinghouse.withdraw(oldTreasury, 1e6);
        assertEq(
            settlementToken.balanceOf(oldTreasury), oldWalletBalance + 1e6, "Old treasury can withdraw its balance"
        );
    }

    function test_SetProtocolTreasury_AllowsRotationAfterCurrentTreasuryBalanceIsWithdrawn() public {
        address newTreasury = address(0xFEE98);

        _fundProtocolTreasury(1e6);
        _withdrawProtocolTreasury(1e6);

        engine.setProtocolTreasury(newTreasury);

        assertEq(engine.protocolTreasury(), newTreasury, "Treasury should rotate after the old account is drained");
        assertEq(
            clearinghouse.balanceAssets(engine.protocolTreasury()), 0, "New treasury starts with no reported balance"
        );
    }

    function test_CloseProtocolFeeInflow_IsBoundedByPhysicalCashReceived() public {
        _fundJunior(address(0xB0B), 1_000_000e6);

        address trader = address(0xAB1720);
        address account = trader;
        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        uint256 assetsBeforeClose = pool.totalAssets();
        _close(account, CfdTypes.Side.LONG, 100_000e18, 100_030_000);
        uint256 assetsAfterClose = pool.totalAssets();

        settlementToken.mint(address(pool), 5e6);

        assertEq(
            pool.totalAssets(),
            assetsAfterClose,
            "Unsolicited donations should remain quarantined instead of filling an over-credited fee-accounting gap"
        );
        assertEq(
            pool.excessAssets(),
            5e6,
            "Donation should stay sweepable as excess when protocol inflow is capped by cash received"
        );
    }

    function test_ProtocolTreasuryWithdrawal_DoesNotUseSeniorCashReservation() public {
        address account = address(uint160(0xFEE1));
        _fundTrader(account, 5000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        uint256 fees = clearinghouse.balanceAssets(engine.protocolTreasury());
        address trader = address(0xFEE2);
        stdstore.target(address(engine)).sig("traderClaimBalanceAssets(address)").with_key(trader)
            .checked_write(uint256(25e6));
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceAssets()").checked_write(uint256(25e6));

        uint256 poolAssetsBeforeDrain = pool.totalAssets();
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), poolAssetsBeforeDrain);

        address treasury = engine.protocolTreasury();
        uint256 treasuryBalanceBefore = settlementToken.balanceOf(treasury);
        _withdrawProtocolTreasury(fees);

        assertEq(
            settlementToken.balanceOf(treasury) - treasuryBalanceBefore,
            fees,
            "Treasury withdrawal should use clearinghouse custody"
        );
        assertEq(clearinghouse.balanceAssets(engine.protocolTreasury()), 0, "Treasury balance should be withdrawn");
        assertEq(pool.totalAssets(), 0, "Treasury withdrawal should not require or consume vault cash");
        settlementToken.mint(address(pool), poolAssetsBeforeDrain);
    }

    function test_TreasuryWithdrawal_ThenTraderClaims_DrainsResidualCashWithoutDeadlock() public {
        address trader = address(0xFEA1);
        address traderAccount = trader;

        settlementToken.burn(address(pool), pool.totalAssets());
        settlementToken.mint(address(pool), 100e6);

        _fundProtocolTreasury(60e6);
        stdstore.target(address(engine)).sig("traderClaimBalanceAssets(address)").with_key(traderAccount)
            .checked_write(uint256(40e6));
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceAssets()").checked_write(uint256(40e6));

        address treasury = engine.protocolTreasury();
        uint256 treasuryBalanceBefore = settlementToken.balanceOf(treasury);
        _withdrawProtocolTreasury(60e6);

        assertEq(
            settlementToken.balanceOf(treasury) - treasuryBalanceBefore,
            60e6,
            "Treasury should receive its margin balance"
        );
        assertEq(pool.totalAssets(), 100e6, "Treasury withdrawal should leave vault cash untouched");
        assertEq(
            clearinghouse.balanceAssets(engine.protocolTreasury()), 0, "Treasury balance should be fully withdrawn"
        );

        uint256 traderSettlementBefore = clearinghouse.balanceAssets(traderAccount);
        vm.prank(trader);
        engine.settleTraderClaim(traderAccount);

        assertEq(
            clearinghouse.balanceAssets(traderAccount) - traderSettlementBefore,
            40e6,
            "Trader should receive the first trader claim ahead of remaining protocol fees"
        );
        assertEq(pool.totalAssets(), 60e6, "Trader claim should consume only its reserved pool cash");
        assertEq(
            clearinghouse.balanceAssets(engine.protocolTreasury()),
            0,
            "Servicing trader claims must not affect treasury accounting"
        );
        assertEq(engine.traderClaimBalanceAssets(traderAccount), 0, "Trader claim balance should be fully consumed");
    }

    function test_ProtocolTreasury_AllowsPartialWithdrawal() public {
        address trader = address(0xFEE4A);
        address account = trader;
        _fundTrader(trader, 10_000e6);

        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000e18,
            marginDelta: 2000e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(order, 1e8, 1_000_000e6, uint64(block.timestamp));

        uint256 feesBefore = clearinghouse.balanceAssets(engine.protocolTreasury());
        uint256 partialAmount = feesBefore / 2;

        address treasury = engine.protocolTreasury();
        uint256 treasuryBalanceBefore = settlementToken.balanceOf(treasury);
        _withdrawProtocolTreasury(partialAmount);

        assertEq(
            settlementToken.balanceOf(treasury) - treasuryBalanceBefore,
            partialAmount,
            "Treasury should receive the requested partial fee amount"
        );
        assertEq(
            clearinghouse.balanceAssets(engine.protocolTreasury()),
            feesBefore - partialAmount,
            "Partial fee withdrawal should leave the remainder booked"
        );
    }

}
