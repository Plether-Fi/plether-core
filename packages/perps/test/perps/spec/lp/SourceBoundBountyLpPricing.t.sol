// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {SourceBoundBountyFixture} from "../../shared/SourceBoundBountyFixture.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

/// @dev LP entry/exit comparisons with and without a pending unpaid close; no funded close escrow exists.
contract SourceBoundBountyLpPricingTest is SourceBoundBountyFixture {

    struct ExitControl {
        uint256 assets;
        uint256 cash;
        uint256 claims;
        uint256 traderFree;
        uint256 payout;
        OrderV3Types.OrderReceipt receipt;
    }

    address internal constant PRICING_LP = address(0xB01F1);
    uint256 internal constant DEPOSIT = 100_000e6;

    function _lpRequest(
        TrancheVault vault
    ) internal returns (uint256 id) {
        usdc.mint(PRICING_LP, DEPOSIT);
        vm.startPrank(PRICING_LP);
        usdc.approve(address(vault), DEPOSIT);
        id = vault.requestDeposit(DEPOSIT, PRICING_LP, PRICING_LP);
        vm.stopPrank();
    }

    function _lpEntry(
        TrancheVault vault,
        uint256 epoch,
        CfdTypes.Side side,
        uint256 price,
        bool reserve
    ) internal returns (uint256 shares, uint64 order, int256 nav) {
        vm.warp(pool.lpEpochStart(epoch) - 5);
        router.updateMarkPrice(_bountyPriceData(price));
        if (reserve) {
            order = _bountyCommit(BOUNTY_TRADER, side, true, BOUNTY_SIZE, 0);
        }
        nav = engine.terminalNavSnapshot().terminalLpPriceDeltaUsdc;
        vm.warp(pool.lpEpochStart(epoch));
        router.settleLpEpoch(_bountyPriceData(price));
        uint256 assets = vault.claimableDepositRequest(epoch, PRICING_LP);
        assertEq(assets, DEPOSIT, "entire real deposit settles");
        vm.prank(PRICING_LP);
        shares = vault.claimDeposit(epoch, assets, PRICING_LP, PRICING_LP);
        assertGt(shares, 0);
        assertEq(vault.pendingDepositRequest(epoch, PRICING_LP), 0);
        assertEq(vault.claimableDepositRequest(epoch, PRICING_LP), 0);
    }

    function _lpRedeem(
        TrancheVault vault,
        uint256 shares,
        uint256 price
    ) internal returns (uint256 paid) {
        vm.warp(block.timestamp + vault.DEPOSIT_COOLDOWN() + 1);
        router.updateMarkPrice(_bountyPriceData(price));
        vm.prank(PRICING_LP);
        uint256 id = vault.requestRedeem(shares, PRICING_LP, PRICING_LP);
        vm.warp(pool.lpEpochStart(id));
        router.settleLpEpoch(_bountyPriceData(price));
        uint256 claimable = vault.claimableRedeemRequest(id, PRICING_LP);
        assertEq(claimable, shares, "entire round-trip redemption settles");
        uint256 cash = usdc.balanceOf(PRICING_LP);
        vm.prank(PRICING_LP);
        vault.claimRedeem(id, claimable, PRICING_LP, PRICING_LP);
        paid = usdc.balanceOf(PRICING_LP) - cash;
        assertEq(vault.pendingRedeemRequest(id, PRICING_LP), 0);
        assertEq(vault.claimableRedeemRequest(id, PRICING_LP), 0);
        assertEq(vault.balanceOf(PRICING_LP), 0);
    }

    /// @dev regression; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function testFuzz_ReserveRefundCannotChangeRealLpRoundTrip(
        bool senior,
        bool shortSide
    ) public {
        TrancheVault vault = senior ? seniorVault : juniorVault;
        CfdTypes.Side side = shortSide ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
        uint256 price = shortSide ? 80_000_000 : 120_000_000;
        uint256 pledge = _bountyPosition(side);
        uint256 id = _lpRequest(vault);
        uint256 snapshot = vm.snapshotState();
        (uint256 controlShares,, int256 controlNav) = _lpEntry(vault, id, side, price, false);
        vm.warp(pool.lpEpochStart(id) + 61);
        uint256 controlPayout = _lpRedeem(vault, controlShares, price);
        assertTrue(vm.revertToState(snapshot));
        (uint256 shares, uint64 order, int256 nav) = _lpEntry(vault, id, side, price, true);
        assertEq(nav, controlNav, "unpaid close record leaves terminal NAV unchanged");
        assertEq(shares, controlShares, "unpaid close record must not change a real epoch's share price");
        vm.warp(pool.lpEpochStart(id) + 61);
        OrderV3Types.OrderReceipt memory receipt = _bountyExpire(order, BOUNTY_KEEPER);
        assertEq(receipt.bounty.bountyPaidUsdc, 0);
        assertEq(receipt.bounty.bountyRefundedUsdc, router.closeOrderExecutionBountyUsdc());
        assertEq(clearinghouse.pnlPledgeUsdc(BOUNTY_TRADER), pledge);

        assertEq(engine.terminalNavSnapshot().terminalLpPriceDeltaUsdc, controlNav);
        uint256 payout = _lpRedeem(vault, shares, price);
        // Same state and timing imply identical integer rounding, not an arbitrary tolerance.
        assertEq(payout, controlPayout, "unpaid close expiry must produce zero incremental LP payout");
    }

    /// @dev regression; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_HeldDepositEpochSpanningRefundKeepsOriginalEntryPrice() public {
        uint256 pledge = _bountyPosition(CfdTypes.Side.LONG);
        uint256 epoch = _lpRequest(juniorVault);
        vm.warp(pool.lpEpochStart(epoch) - 5);
        router.updateMarkPrice(_bountyPriceData(120_000_000));
        uint256 snapshot = vm.snapshotState();
        // Delay both branches equally so Senior coupon time is not a confounding input.
        vm.warp(pool.lpEpochStart(epoch) + 61);
        router.settleLpEpoch(_bountyPriceData(120_000_000));
        vm.prank(PRICING_LP);
        uint256 controlShares = juniorVault.claimDeposit(epoch, DEPOSIT, PRICING_LP, PRICING_LP);
        assertTrue(vm.revertToState(snapshot));
        uint64 order = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        pool.pauseLpEpochSettlement();
        vm.warp(pool.lpEpochStart(epoch));
        bytes[] memory data = _bountyPriceData(120_000_000);
        vm.expectRevert(IHousePool.HousePool__LpEpochSettlementPaused.selector);
        router.settleLpEpoch(data);
        assertEq(juniorVault.pendingDepositRequest(epoch, PRICING_LP), DEPOSIT);
        assertEq(juniorVault.claimableDepositRequest(epoch, PRICING_LP), 0);
        vm.warp(pool.lpEpochStart(epoch) + 61);
        _bountyExpire(order, BOUNTY_KEEPER);
        assertEq(clearinghouse.pnlPledgeUsdc(BOUNTY_TRADER), pledge);
        pool.unpauseLpEpochSettlement();
        router.settleLpEpoch(_bountyPriceData(120_000_000));
        uint256 assets = juniorVault.claimableDepositRequest(epoch, PRICING_LP);
        assertEq(assets, DEPOSIT);
        vm.prank(PRICING_LP);
        uint256 shares = juniorVault.claimDeposit(epoch, assets, PRICING_LP, PRICING_LP);
        assertEq(shares, controlShares, "held-then-completed epoch keeps the same boundary price");
    }

    /// @dev regression; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_ExistingLpPartiallyFundedRedemptionUnaffectedByRefundablePledge() public {
        _bountyPosition(CfdTypes.Side.LONG);
        vm.warp(block.timestamp + juniorVault.DEPOSIT_COOLDOWN() + 1);
        router.updateMarkPrice(_bountyPriceData(120_000_000));
        uint256 shares = juniorVault.maxRequestRedeem(address(this));
        uint256 epoch = juniorVault.requestRedeem(shares, address(this), address(this));
        vm.warp(pool.lpEpochStart(epoch) - 5);
        router.updateMarkPrice(_bountyPriceData(120_000_000));
        uint256 snapshot = vm.snapshotState();
        vm.warp(pool.lpEpochStart(epoch));
        router.settleLpEpoch(_bountyPriceData(120_000_000));
        uint256 controlClaimable = juniorVault.claimableRedeemRequest(epoch, address(this));
        uint256 controlPending = juniorVault.pendingRedeemRequest(epoch, address(this));
        uint256 controlCash = juniorVault.withdrawalEscrowAssets();
        assertGt(controlClaimable, 0);
        assertGt(controlPending, 0, "withdrawal reserve forces genuinely partial epoch funding");
        assertEq(controlClaimable + controlPending, shares);
        uint256 controlWallet = usdc.balanceOf(address(this));
        juniorVault.claimRedeem(epoch, controlClaimable, address(this), address(this));
        uint256 controlPaid = usdc.balanceOf(address(this)) - controlWallet;
        assertTrue(vm.revertToState(snapshot));
        uint64 order = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        vm.warp(pool.lpEpochStart(epoch));
        router.settleLpEpoch(_bountyPriceData(120_000_000));
        assertEq(juniorVault.claimableRedeemRequest(epoch, address(this)), controlClaimable);
        assertEq(juniorVault.pendingRedeemRequest(epoch, address(this)), controlPending);
        assertEq(juniorVault.withdrawalEscrowAssets(), controlCash);
        _bountyExpire(order, BOUNTY_KEEPER);
        uint256 beforeCash = usdc.balanceOf(address(this));
        juniorVault.claimRedeem(epoch, controlClaimable, address(this), address(this));
        assertEq(usdc.balanceOf(address(this)) - beforeCash, controlPaid);
        assertEq(juniorVault.withdrawalEscrowAssets(), controlCash - controlPaid);
        assertEq(juniorVault.pendingRedeemRequest(epoch, address(this)), controlPending);
    }

    /// @dev regression; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_SuccessRealizesOnlyTheAuthorizedPledgeCostAndSelfMayWithdrawBounty() public {
        uint256 pledge = _bountyPosition(CfdTypes.Side.LONG);
        uint256 expectedFree = _successfulCloseResidual() + router.closeOrderExecutionBountyUsdc();
        router.updateMarkPrice(_bountyPriceData(120_000_000));
        uint256 snapshot = vm.snapshotState();
        // Both branches commit the same unpaid zero-bounty close; compare its pledge and LP cash outcome.
        uint256 bounty = router.closeOrderExecutionBountyUsdc();
        uint64 control = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        OrderV3Types.OrderReceipt memory controlReceipt =
            _bountyExecute(control, 120_000_000, BOUNTY_TRADER, OrderV3Types.LifecycleStatus.Executed);
        uint256 controlPoolCash = usdc.balanceOf(address(pool));
        assertEq(controlReceipt.economics.close.pricePnlPledgeConsumedUsdc, pledge);
        assertTrue(vm.revertToState(snapshot));
        int256 preNav = engine.terminalNavSnapshot().terminalLpPriceDeltaUsdc;
        uint64 order = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        assertEq(engine.terminalNavSnapshot().terminalLpPriceDeltaUsdc, preNav);
        OrderV3Types.OrderReceipt memory receipt =
            _bountyExecute(order, 120_000_000, BOUNTY_TRADER, OrderV3Types.LifecycleStatus.Executed);
        assertEq(receipt.bounty.bountyPaidUsdc, bounty);
        assertEq(receipt.bounty.bountyRefundedUsdc, 0);
        assertEq(receipt.economics.close.pricePnlPledgeConsumedUsdc, pledge - bounty);
        assertEq(controlPoolCash - usdc.balanceOf(address(pool)), bounty, "successful pledge cost is counted once");

        assertEq(clearinghouse.getFreeBuyingPowerUsdc(BOUNTY_TRADER), expectedFree);
        uint256 wallet = usdc.balanceOf(BOUNTY_TRADER);
        vm.prank(BOUNTY_TRADER);
        clearinghouse.withdraw(BOUNTY_TRADER, expectedFree);
        assertEq(usdc.balanceOf(BOUNTY_TRADER) - wallet, expectedFree, "unused terminal reserve after unpaid close");
        assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), 0);
    }

    /// @dev regression; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_LpExitBeforeCommitAndDuringPendingEscrowHaveIdenticalSuccessEconomics() public {
        ExitControl memory expected;
        _bountyPosition(CfdTypes.Side.LONG);
        uint256 expectedFree = _successfulCloseResidual() + router.closeOrderExecutionBountyUsdc();
        vm.warp(block.timestamp + juniorVault.DEPOSIT_COOLDOWN() + 1);
        router.updateMarkPrice(_bountyPriceData(120_000_000));
        uint256 shares = juniorVault.balanceOf(address(this)) / 10;
        uint256 epoch = juniorVault.requestRedeem(shares, address(this), address(this));
        vm.warp(pool.lpEpochStart(epoch) - 5);
        router.updateMarkPrice(_bountyPriceData(120_000_000));
        uint256 snapshot = vm.snapshotState();

        vm.warp(pool.lpEpochStart(epoch));
        router.settleLpEpoch(_bountyPriceData(120_000_000));
        expected.assets = juniorVault.withdrawalEscrowAssets();
        assertEq(juniorVault.claimableRedeemRequest(epoch, address(this)), shares);
        uint64 controlOrder = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        expected.receipt =
            _bountyExecute(controlOrder, 120_000_000, BOUNTY_TRADER, OrderV3Types.LifecycleStatus.Executed);
        expected.cash = usdc.balanceOf(address(pool));
        expected.claims = engine.totalTraderClaimBalanceUsdc();
        expected.traderFree = clearinghouse.getFreeBuyingPowerUsdc(BOUNTY_TRADER);
        uint256 controlLpWallet = usdc.balanceOf(address(this));
        juniorVault.claimRedeem(epoch, shares, address(this), address(this));
        expected.payout = usdc.balanceOf(address(this)) - controlLpWallet;
        assertTrue(vm.revertToState(snapshot));

        uint64 pendingOrder = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        vm.warp(pool.lpEpochStart(epoch));
        router.settleLpEpoch(_bountyPriceData(120_000_000));
        assertEq(juniorVault.withdrawalEscrowAssets(), expected.assets, "pending escrow cannot enlarge LP exit");
        assertEq(juniorVault.claimableRedeemRequest(epoch, address(this)), shares);
        OrderV3Types.OrderReceipt memory pending =
            _bountyExecute(pendingOrder, 120_000_000, BOUNTY_TRADER, OrderV3Types.LifecycleStatus.Executed);
        assertEq(usdc.balanceOf(address(pool)), expected.cash, "same success leaves identical LP cash");
        assertEq(engine.totalTraderClaimBalanceUsdc(), expected.claims);
        assertEq(
            pending.economics.close.priceLossWrittenOffUsdc, expected.receipt.economics.close.priceLossWrittenOffUsdc
        );
        assertEq(
            pending.economics.close.pricePnlPledgeConsumedUsdc,
            expected.receipt.economics.close.pricePnlPledgeConsumedUsdc
        );
        assertEq(clearinghouse.getFreeBuyingPowerUsdc(BOUNTY_TRADER), expected.traderFree);
        assertEq(expected.traderFree, expectedFree);
        uint256 lpCash = usdc.balanceOf(address(this));
        juniorVault.claimRedeem(epoch, shares, address(this), address(this));
        assertEq(usdc.balanceOf(address(this)) - lpCash, expected.payout);
    }

    function _successfulCloseResidual() internal view returns (uint256) {
        // At $1.20, the underwater full close consumes all price pledge. The separate
        // liquidation reserve releases to free settlement, then pays the 4-bps action fee.
        uint256 notional = (BOUNTY_SIZE * 120_000_000) / 1e20;
        uint256 fee = (notional * engine.executionFeeBps()) / 10_000;
        return clearinghouse.liquidationReserveUsdc(BOUNTY_TRADER) - fee;
    }

}
