// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEngine} from "@plether/perps/CfdEngine.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";

import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {CfdEngineTestBase} from "../../shared/CfdEngineTestBase.sol";

contract EngineProtocolFeesTest is CfdEngineTestBase {

    using stdStorage for StdStorage;

    function test_ProtocolFeeTopUp_DoesNotLeapfrogTraderClaims() public {
        address account = address(0xD30F);
        _fundTrader(account, 11_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        uint256 closePrice = 80_000_000;
        uint256 executionFeeUsdc = _engineExecutionFeeUsdc(100_000e18, closePrice);
        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - executionFeeUsdc);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, closePrice);
        assertTrue(preview.valid, "Setup close preview should be valid");
        assertEq(preview.immediatePayoutUsdc, 0, "Setup must record the trader payout as a claim");
        assertGt(preview.traderClaimBalanceUsdc, 0, "Setup must create a trader claim");
        assertEq(pool.totalAssets(), executionFeeUsdc, "Setup leaves only the fee amount physically available");

        uint256 feesBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
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
        assertGt(engine.traderClaimBalanceUsdc(account), 0, "Trader claim should be recorded");
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
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
        assertGt(liquidPreview.freshTraderPayoutUsdc, 0, "Setup must create a trader payout");
        assertGt(liquidPreview.executionFeeUsdc, 0, "Setup must create a protocol fee");

        uint256 poolAssets = pool.totalAssets();
        uint256 drainAmount = poolAssets - liquidPreview.freshTraderPayoutUsdc;
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), drainAmount);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, closePrice);
        assertTrue(preview.valid, "Setup close preview should be valid");
        assertEq(pool.totalAssets(), preview.freshTraderPayoutUsdc, "Setup leaves exactly trader payout cash");
        assertLt(
            pool.totalAssets(),
            preview.freshTraderPayoutUsdc + preview.executionFeeUsdc,
            "Setup cannot also fund the protocol fee top-up"
        );
        assertEq(preview.immediatePayoutUsdc, preview.freshTraderPayoutUsdc, "Preview should follow trader payout cash");
        assertEq(preview.traderClaimBalanceUsdc, 0, "Preview should not defer when payout cash is free");

        uint256 feesBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(account);
        _close(account, CfdTypes.Side.LONG, 100_000e18, closePrice);

        CloseParityObserved memory observed = _observeCloseParity(account, beforeSnapshot);
        _assertClosePreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()), feesBefore, "Unfunded fee top-up should not accrue"
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
        uint256 fees = clearinghouse.balanceUsdc(engine.protocolTreasury());
        assertEq(fees, 40_000_000, "Exec fee should be 4bps of $100k notional");

        address treasury = engine.protocolTreasury();
        uint256 treasuryBalanceBefore = usdc.balanceOf(treasury);
        uint256 assetsBeforeWithdrawal = pool.totalAssets();
        _withdrawProtocolTreasury(fees);

        assertEq(clearinghouse.balanceUsdc(engine.protocolTreasury()), 0, "Fees should reset to zero");
        assertEq(usdc.balanceOf(treasury) - treasuryBalanceBefore, fees, "Treasury receives exact fee amount");
        assertEq(pool.totalAssets(), assetsBeforeWithdrawal, "Treasury withdrawal should not touch vault assets");
        assertEq(pool.excessAssets(), 0, "Fee inflows should not remain stranded as vault excess");

        vm.prank(treasury);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientBalance.selector);
        clearinghouse.withdraw(treasury, fees);
    }

    function test_SetProtocolTreasury_RevertsWhenCurrentTreasuryHasBalance() public {
        address oldTreasury = engine.protocolTreasury();
        address newTreasury = address(0xFEE99);

        _fundProtocolTreasury(1e6);

        vm.expectRevert(ICfdEngineTypes.CfdEngine__ProtocolTreasuryBalanceNotEmpty.selector);
        engine.setProtocolTreasury(newTreasury);

        assertEq(engine.protocolTreasury(), oldTreasury, "Treasury should not rotate while old balance remains");
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            1e6,
            "Existing treasury balance should remain reported"
        );
    }

    function test_SetProtocolTreasury_AllowsRotationAfterCurrentTreasuryBalanceIsWithdrawn() public {
        address newTreasury = address(0xFEE98);

        _fundProtocolTreasury(1e6);
        _withdrawProtocolTreasury(1e6);

        engine.setProtocolTreasury(newTreasury);

        assertEq(engine.protocolTreasury(), newTreasury, "Treasury should rotate after the old account is drained");
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()), 0, "New treasury starts with no reported balance"
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

        usdc.mint(address(pool), 5e6);

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

        uint256 fees = clearinghouse.balanceUsdc(engine.protocolTreasury());
        address trader = address(0xFEE2);
        stdstore.target(address(engine)).sig("traderClaimBalanceUsdc(address)").with_key(trader)
            .checked_write(uint256(25e6));
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceUsdc()").checked_write(uint256(25e6));

        uint256 poolAssetsBeforeDrain = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssetsBeforeDrain);

        address treasury = engine.protocolTreasury();
        uint256 treasuryBalanceBefore = usdc.balanceOf(treasury);
        _withdrawProtocolTreasury(fees);

        assertEq(
            usdc.balanceOf(treasury) - treasuryBalanceBefore,
            fees,
            "Treasury withdrawal should use clearinghouse custody"
        );
        assertEq(clearinghouse.balanceUsdc(engine.protocolTreasury()), 0, "Treasury balance should be withdrawn");
        assertEq(pool.totalAssets(), 0, "Treasury withdrawal should not require or consume vault cash");
        usdc.mint(address(pool), poolAssetsBeforeDrain);
    }

    function test_TreasuryWithdrawal_ThenTraderClaims_DrainsResidualCashWithoutDeadlock() public {
        address trader = address(0xFEA1);
        address traderAccount = trader;

        usdc.burn(address(pool), pool.totalAssets());
        usdc.mint(address(pool), 100e6);

        _fundProtocolTreasury(60e6);
        stdstore.target(address(engine)).sig("traderClaimBalanceUsdc(address)").with_key(traderAccount)
            .checked_write(uint256(40e6));
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceUsdc()").checked_write(uint256(40e6));

        address treasury = engine.protocolTreasury();
        uint256 treasuryBalanceBefore = usdc.balanceOf(treasury);
        _withdrawProtocolTreasury(60e6);

        assertEq(usdc.balanceOf(treasury) - treasuryBalanceBefore, 60e6, "Treasury should receive its margin balance");
        assertEq(pool.totalAssets(), 100e6, "Treasury withdrawal should leave vault cash untouched");
        assertEq(clearinghouse.balanceUsdc(engine.protocolTreasury()), 0, "Treasury balance should be fully withdrawn");

        uint256 traderSettlementBefore = clearinghouse.balanceUsdc(traderAccount);
        vm.prank(trader);
        engine.settleTraderClaim(traderAccount);

        assertEq(
            clearinghouse.balanceUsdc(traderAccount) - traderSettlementBefore,
            40e6,
            "Trader should receive the first trader claim ahead of remaining protocol fees"
        );
        assertEq(pool.totalAssets(), 60e6, "Trader claim should consume only its reserved pool cash");
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            0,
            "Servicing trader claims must not affect treasury accounting"
        );
        assertEq(engine.traderClaimBalanceUsdc(traderAccount), 0, "Trader claim balance should be fully consumed");
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

        uint256 feesBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        uint256 partialAmount = feesBefore / 2;

        address treasury = engine.protocolTreasury();
        uint256 treasuryBalanceBefore = usdc.balanceOf(treasury);
        _withdrawProtocolTreasury(partialAmount);

        assertEq(
            usdc.balanceOf(treasury) - treasuryBalanceBefore,
            partialAmount,
            "Treasury should receive the requested partial fee amount"
        );
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            feesBefore - partialAmount,
            "Partial fee withdrawal should leave the remainder booked"
        );
    }

}

