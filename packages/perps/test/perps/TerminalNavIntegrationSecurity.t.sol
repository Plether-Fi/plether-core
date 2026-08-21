// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {ITerminalNavBookV2} from "@plether/perps/interfaces/ITerminalNavBookV2.sol";

/// @notice Cross-contract security regressions for the authenticated terminal NAV and synchronized LP pricing paths.
contract TerminalNavIntegrationSecurityTest is BasePerpTest {

    address private constant TRADER = address(0x7E4D3E);
    address private constant DEPOSITOR = address(0xD3F0517);

    uint256 private constant POSITION_SIZE = 100_000e18;
    uint256 private constant HALF_POSITION_SIZE = POSITION_SIZE / 2;
    uint256 private constant ENTRY_PRICE = 1e8;
    uint32 private constant MARK_PRICE = 80_000_000;

    struct CurveObservation {
        ITerminalNavBookV2.CurveRecord curve;
        bytes32 curveHash;
        uint64 bookVersion;
        int256 valueAtZero;
        int256 valueAtMark;
        int256 valueAtCap;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: 150,
            fadMarginBps: 300,
            baseCarryBps: 0,
            minBountyUsdc: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function test_AuthenticatedTerminalSnapshotMatchesBookAndFixedMarkFullClose() public {
        _openWinningBullPosition();
        _refreshMark(MARK_PRICE);

        ICfdEngineTypes.TerminalNavSnapshot memory snapshot = engine.terminalNavSnapshot();
        ITerminalNavBookV2.BookState memory bookState = terminalNavBook.bookState();
        int256 directBookValue = terminalNavBook.terminalLpPriceDeltaUsdcAtoms(snapshot.markPrice);

        assertEq(snapshot.markPrice, MARK_PRICE, "snapshot must authenticate the fixed close mark");
        assertEq(snapshot.markTime, block.timestamp, "snapshot must authenticate the mark publish time");
        assertEq(snapshot.bookVersion, bookState.bookVersion, "snapshot must authenticate the exact book version");
        assertEq(snapshot.terminalLpPriceDeltaUsdc, directBookValue, "Engine snapshot must equal its bound book");
        assertEq(snapshot.terminalLpPriceDeltaUsdc, -int256(20_000e6), "book must preserve exact marked price PnL");
        assertTrue(snapshot.hasOpenPositions, "open book must be reported by the authenticated snapshot");

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(TRADER, POSITION_SIZE, MARK_PRICE);
        assertTrue(preview.valid, "fixed-mark full close must be valid");
        assertEq(
            snapshot.terminalLpPriceDeltaUsdc,
            -preview.realizedPnlUsdc,
            "terminal LP delta must be the inverse of the actual close price PnL"
        );

        CloseParitySnapshot memory beforeClose = _captureCloseParitySnapshot(TRADER);
        _close(TRADER, CfdTypes.Side.BULL, POSITION_SIZE, MARK_PRICE);
        CloseParityObserved memory observed = _observeCloseParity(TRADER, beforeClose);
        _assertClosePreviewMatchesObserved(preview, observed, beforeClose.protocol.degradedMode);

        ICfdEngineTypes.TerminalNavSnapshot memory afterClose = engine.terminalNavSnapshot();
        ITerminalNavBookV2.BookState memory afterBookState = terminalNavBook.bookState();
        assertFalse(afterClose.hasOpenPositions, "full close must remove the final live curve");
        assertEq(afterClose.terminalLpPriceDeltaUsdc, 0, "closed price PnL must not survive as unrealized NAV");
        assertEq(terminalNavBook.curveHashOf(TRADER), bytes32(0), "closed account curve must be removed");
        assertEq(afterBookState.activeCurveCount, 0, "book must contain no active curves after the full close");
        assertEq(afterBookState.totalLots, 0, "book lots must return to zero after the full close");
        assertEq(afterBookState.totalEntryCostUsdcAtoms, 0, "book basis must return to zero after the full close");
    }

    function test_PartialCloseCashPayoutAndDeferredClaimPreserveCurveThroughClaimSettlement() public {
        _openWinningBullPosition();
        _refreshMark(MARK_PRICE);
        uint256 branchPoint = vm.snapshotState();

        ICfdEngineTypes.ClosePreview memory liquidPreview =
            engineLens.previewClose(TRADER, HALF_POSITION_SIZE, MARK_PRICE);
        assertTrue(liquidPreview.valid, "liquid partial close must be valid");
        assertGt(liquidPreview.immediatePayoutUsdc, 0, "liquid branch must pay fresh price gain immediately");
        assertEq(liquidPreview.traderClaimBalanceUsdc, 0, "liquid branch must not leave a trader claim");
        _close(TRADER, CfdTypes.Side.BULL, HALF_POSITION_SIZE, MARK_PRICE);

        CurveObservation memory liquidCurve = _observeCurve(TRADER);
        uint256 liquidPledge = clearinghouse.pnlPledgeUsdc(TRADER);
        uint256 liquidClaim = engine.traderClaimBalanceUsdc(TRADER);
        assertEq(liquidCurve.valueAtMark, -int256(10_000e6), "remaining half must retain exact marked price PnL");

        vm.revertToState(branchPoint);

        uint256 removedPoolCash = usdc.balanceOf(address(pool));
        usdc.burn(address(pool), removedPoolCash);
        ICfdEngineTypes.ClosePreview memory deferredPreview =
            engineLens.previewClose(TRADER, HALF_POSITION_SIZE, MARK_PRICE);
        assertTrue(deferredPreview.valid, "illiquid partial close must remain valid");
        assertEq(deferredPreview.immediatePayoutUsdc, 0, "illiquid branch must not manufacture cash payout");
        assertEq(
            deferredPreview.freshTraderPayoutUsdc,
            liquidPreview.freshTraderPayoutUsdc,
            "cash availability must not change the fresh price-gain entitlement"
        );
        _close(TRADER, CfdTypes.Side.BULL, HALF_POSITION_SIZE, MARK_PRICE);

        CurveObservation memory deferredCurve = _observeCurve(TRADER);
        uint256 deferredPledge = clearinghouse.pnlPledgeUsdc(TRADER);
        uint256 deferredClaim = engine.traderClaimBalanceUsdc(TRADER);
        assertEq(
            deferredClaim,
            deferredPreview.freshTraderPayoutUsdc,
            "unfunded fresh payout must become exactly one senior trader claim"
        );
        assertEq(
            liquidPledge + liquidClaim,
            deferredPledge + deferredClaim,
            "payout-to-pledge and payout-to-claim paths must preserve the same collectible cap"
        );
        _assertSameCurve(liquidCurve, deferredCurve, "partial payout mode must not change the remaining terminal curve");

        usdc.mint(address(pool), removedPoolCash);
        bytes32 hashBeforeClaimSettlement = terminalNavBook.curveHashOf(TRADER);
        uint64 versionBeforeClaimSettlement = terminalNavBook.bookState().bookVersion;
        uint256 pledgeBeforeClaimSettlement = clearinghouse.pnlPledgeUsdc(TRADER);

        vm.prank(TRADER);
        engine.settleTraderClaim(TRADER);

        CurveObservation memory settledCurve = _observeCurve(TRADER);
        assertEq(engine.traderClaimBalanceUsdc(TRADER), 0, "claim settlement must consume the recorded liability");
        assertEq(
            clearinghouse.pnlPledgeUsdc(TRADER),
            pledgeBeforeClaimSettlement + deferredClaim,
            "paid claim on a live position must become PnL pledge"
        );
        assertEq(
            settledCurve.curveHash, hashBeforeClaimSettlement, "claim-to-pledge migration must preserve curve hash"
        );
        assertEq(
            settledCurve.bookVersion,
            versionBeforeClaimSettlement,
            "canonically identical claim settlement must not mutate the book version"
        );
        _assertSameCurve(deferredCurve, settledCurve, "claim consumption must preserve terminal accounting continuity");
    }

    function test_LiveClaimSettlementSynchronizesMarginAndBorrowCachesAndAllowsClose() public {
        uint256 settledClaimUsdc = _settleDeferredClaimOnLivePosition();

        (uint256 remainingSize,, uint256 remainingEntryPrice, uint256 remainingMaxProfitUsdc,,,) =
            engine.positions(TRADER);
        uint256 livePledgeUsdc = clearinghouse.pnlPledgeUsdc(TRADER);
        uint256 expectedBorrowBaseUsdc =
            remainingMaxProfitUsdc > livePledgeUsdc ? remainingMaxProfitUsdc - livePledgeUsdc : 0;
        (uint256 positionBorrowBaseUsdc,,) = engine.positionCarryState(TRADER);

        assertGt(settledClaimUsdc, 0, "setup must service a nonzero deferred claim");
        assertEq(remainingSize, HALF_POSITION_SIZE, "claim settlement must leave the live position open");
        assertEq(remainingEntryPrice, ENTRY_PRICE, "claim settlement must not change the remaining entry price");
        assertEq(
            _sideTotalMargin(CfdTypes.Side.BULL),
            livePledgeUsdc,
            "side total margin must include claim value converted into live PnL pledge"
        );
        assertEq(
            positionBorrowBaseUsdc,
            expectedBorrowBaseUsdc,
            "position borrow base must be recomputed from the increased live PnL pledge"
        );
        assertEq(
            engine.sideBorrowBaseUsdc(uint256(CfdTypes.Side.BULL)),
            expectedBorrowBaseUsdc,
            "single-position side borrow base must match its recomputed position borrow base"
        );

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(TRADER, remainingSize, MARK_PRICE);
        assertTrue(preview.valid, "cache-synchronized live position must remain closable");
        _close(TRADER, CfdTypes.Side.BULL, remainingSize, MARK_PRICE);

        (uint256 sizeAfter,,,,,,) = engine.positions(TRADER);
        assertEq(sizeAfter, 0, "full close after claim settlement must remove the position");
        assertEq(_sideTotalMargin(CfdTypes.Side.BULL), 0, "full close must clear side margin");
        assertEq(engine.sideBorrowBaseUsdc(uint256(CfdTypes.Side.BULL)), 0, "full close must clear side borrow base");
    }

    function test_LiveClaimSettlementSynchronizesCachesAndAllowsLiquidation() public {
        _settleDeferredClaimOnLivePosition();

        uint256 liquidationPrice = CAP_PRICE;
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(TRADER, liquidationPrice);
        assertTrue(preview.liquidatable, "setup must make the post-settlement live position liquidatable at the cap");

        uint256 poolDepthUsdc = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(TRADER, liquidationPrice, poolDepthUsdc, uint64(block.timestamp), address(this));

        (uint256 sizeAfter,,,,,,) = engine.positions(TRADER);
        assertEq(sizeAfter, 0, "liquidation after claim settlement must remove the position");
        assertEq(_sideTotalMargin(CfdTypes.Side.BULL), 0, "liquidation must clear side margin without underflow");
        assertEq(
            engine.sideBorrowBaseUsdc(uint256(CfdTypes.Side.BULL)),
            0,
            "liquidation must clear side borrow base without underflow"
        );
    }

    function test_JuniorDepositAndRedeemUseIdenticalSignedNavWithLiveUnrealizedPnl() public {
        _finishJuniorCooldown(address(this));
        _openWinningBullPosition();
        _refreshMark(MARK_PRICE);

        ICfdEngineTypes.TerminalNavSnapshot memory initialSnapshot = engine.terminalNavSnapshot();
        assertLt(initialSnapshot.terminalLpPriceDeltaUsdc, 0, "setup requires a live trader-profit liability");

        uint256 depositAssets = 25_000e6;
        uint256 depositId = _requestJuniorDeposit(DEPOSITOR, depositAssets);

        _warpToEpoch(pool.currentLpEpoch() + 1);
        _refreshMark(MARK_PRICE);
        uint256 redeemShares = juniorVault.maxRequestRedeem(address(this)) / 10;
        assertGt(redeemShares, 0, "incumbent must have redeemable Junior shares");
        uint256 redeemId = juniorVault.requestRedeem(redeemShares, address(this), address(this));
        assertEq(depositId, redeemId, "deposit and redeem must mature in one synchronized settlement");

        _warpToEpoch(depositId);
        _refreshMark(MARK_PRICE);
        ICfdEngineTypes.TerminalNavSnapshot memory pricingSnapshot = engine.terminalNavSnapshot();
        (uint256 withdrawalSeniorNav, uint256 withdrawalJuniorNav,,) = pool.getPendingTrancheState();
        (uint256 depositSeniorNav, uint256 depositJuniorNav) = pool.getPendingDepositTrancheState();
        assertEq(depositSeniorNav, withdrawalSeniorNav, "Senior projection must share the canonical signed state");
        assertEq(depositJuniorNav, withdrawalJuniorNav, "Junior entry and exit must expose one signed NAV");

        uint256 pricingSupply = juniorVault.totalSupply();
        uint256 expectedRedeemAssets = juniorVault.estimateRedeemAssets(redeemShares);
        uint256 postRedeemPricingAssets = withdrawalJuniorNav - expectedRedeemAssets;
        uint256 postRedeemPricingSupply = pricingSupply - redeemShares;
        uint256 expectedDepositShares =
            juniorVault.quoteDepositFromState(depositAssets, postRedeemPricingAssets, postRedeemPricingSupply, 0);

        IHousePool.LpEpochSettlementResult memory result = pool.settleLpEpoch();
        assertEq(result.juniorFundedShares, redeemShares, "synchronized exit must fund the quoted shares exactly");
        assertEq(
            result.juniorFundedAssets,
            expectedRedeemAssets,
            "actual Junior redemption must use the canonical signed NAV"
        );
        assertEq(result.juniorDepositAssets, depositAssets, "synchronized entry must accept the queued asset basis");
        assertEq(
            result.juniorDepositShares,
            expectedDepositShares,
            "actual Junior mint must use the same post-redemption signed NAV"
        );
        assertEq(
            juniorVault.claimableDepositRequest(depositId, DEPOSITOR),
            depositAssets,
            "priced deposit assets must become claimable"
        );

        ICfdEngineTypes.TerminalNavSnapshot memory afterSettlement = engine.terminalNavSnapshot();
        assertEq(
            afterSettlement.terminalLpPriceDeltaUsdc,
            pricingSnapshot.terminalLpPriceDeltaUsdc,
            "LP queue settlement must not mutate the live position's terminal delta"
        );
        assertEq(
            afterSettlement.bookVersion,
            pricingSnapshot.bookVersion,
            "LP queue settlement must consume, not mutate, the authenticated terminal book"
        );
    }

    function test_EngineRejectsStaleCurveInsteadOfHealingUnsynchronizedPnlPledge() public {
        _openWinningBullPosition();
        bytes32 committedHash = terminalNavBook.curveHashOf(TRADER);
        uint256 pledgeBefore = clearinghouse.pnlPledgeUsdc(TRADER);

        // Model a cross-contract accounting defect: the clearinghouse cap changes without the Engine book mutation.
        vm.prank(address(engine));
        clearinghouse.creditPnlPledge(TRADER, 1);

        assertEq(clearinghouse.pnlPledgeUsdc(TRADER), pledgeBefore + 1, "setup must diverge semantic cap state");
        assertEq(terminalNavBook.curveHashOf(TRADER), committedHash, "setup must leave the stale commitment untouched");

        vm.expectPartialRevert(ICfdEngineTypes.CfdEngine__TerminalNavBookHashMismatch.selector);
        vm.prank(TRADER);
        engine.addMargin(TRADER, 1);

        assertEq(terminalNavBook.curveHashOf(TRADER), committedHash, "failed mutation must not heal a stale curve");
    }

    function test_EngineRejectsUnexpectedCurveForAccountWithoutPosition() public {
        vm.prank(address(engine));
        terminalNavBook.setCurve(
            DEPOSITOR,
            bytes32(0),
            ITerminalNavBookV2.CurveInput({
                lots: 1, entryCostUsdcAtoms: 1, collectibleCapUsdcAtoms: 1, side: CfdTypes.Side.BULL
            })
        );
        assertTrue(terminalNavBook.curveHashOf(DEPOSITOR) != bytes32(0), "setup must create an orphan curve");

        vm.expectPartialRevert(ICfdEngineTypes.CfdEngine__TerminalNavBookHashMismatch.selector);
        vm.prank(DEPOSITOR);
        engine.settleTraderClaim(DEPOSITOR);
    }

    function _openWinningBullPosition() private {
        _fundTrader(TRADER, 60_000e6);
        _open(TRADER, CfdTypes.Side.BULL, POSITION_SIZE, 40_000e6, ENTRY_PRICE);
    }

    function _settleDeferredClaimOnLivePosition() private returns (uint256 claimAmountUsdc) {
        _openWinningBullPosition();
        _refreshMark(MARK_PRICE);

        uint256 removedPoolCash = usdc.balanceOf(address(pool));
        usdc.burn(address(pool), removedPoolCash);
        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(TRADER, HALF_POSITION_SIZE, MARK_PRICE);
        assertTrue(preview.valid, "illiquid partial-close setup must be valid");
        assertGt(preview.freshTraderPayoutUsdc, 0, "setup must create a fresh trader entitlement");
        assertEq(preview.immediatePayoutUsdc, 0, "empty pool must defer the fresh payout");

        _close(TRADER, CfdTypes.Side.BULL, HALF_POSITION_SIZE, MARK_PRICE);
        claimAmountUsdc = engine.traderClaimBalanceUsdc(TRADER);
        assertEq(claimAmountUsdc, preview.freshTraderPayoutUsdc, "fresh payout must become the deferred claim");

        usdc.mint(address(pool), removedPoolCash);
        vm.prank(TRADER);
        engine.settleTraderClaim(TRADER);
        assertEq(engine.traderClaimBalanceUsdc(TRADER), 0, "claim settlement must consume the deferred liability");
    }

    function _refreshMark(
        uint32 markPrice
    ) private {
        vm.prank(address(router));
        engine.updateMarkPrice(markPrice, uint64(block.timestamp));
    }

    function _observeCurve(
        address account
    ) private view returns (CurveObservation memory observed) {
        observed.curve = terminalNavBook.curveOf(account);
        observed.curveHash = terminalNavBook.curveHashOf(account);
        observed.bookVersion = terminalNavBook.bookState().bookVersion;
        observed.valueAtZero = terminalNavBook.terminalLpPriceDeltaUsdcAtoms(0);
        observed.valueAtMark = terminalNavBook.terminalLpPriceDeltaUsdcAtoms(MARK_PRICE);
        observed.valueAtCap = terminalNavBook.terminalLpPriceDeltaUsdcAtoms(uint32(CAP_PRICE));
    }

    function _assertSameCurve(
        CurveObservation memory expected,
        CurveObservation memory actual,
        string memory reason
    ) private pure {
        assertEq(actual.curve.lots, expected.curve.lots, reason);
        assertEq(actual.curve.entryCostUsdcAtoms, expected.curve.entryCostUsdcAtoms, reason);
        assertEq(actual.curve.effectiveCapUsdcAtoms, expected.curve.effectiveCapUsdcAtoms, reason);
        assertEq(uint8(actual.curve.side), uint8(expected.curve.side), reason);
        assertEq(actual.curveHash, expected.curveHash, reason);
        assertEq(actual.valueAtZero, expected.valueAtZero, reason);
        assertEq(actual.valueAtMark, expected.valueAtMark, reason);
        assertEq(actual.valueAtCap, expected.valueAtCap, reason);
    }

    function _requestJuniorDeposit(
        address depositor,
        uint256 assets
    ) private returns (uint256 requestId) {
        usdc.mint(depositor, assets);
        vm.startPrank(depositor);
        usdc.approve(address(juniorVault), assets);
        requestId = juniorVault.requestDeposit(assets, depositor, depositor);
        vm.stopPrank();
    }

    function _warpToEpoch(
        uint256 epochId
    ) private {
        uint256 start = pool.lpEpochStart(epochId);
        if (block.timestamp < start) {
            vm.warp(start);
        }
    }

    function _finishJuniorCooldown(
        address owner
    ) private {
        uint256 unlockTime = juniorVault.lastDepositTime(owner) + juniorVault.DEPOSIT_COOLDOWN();
        if (block.timestamp < unlockTime) {
            vm.warp(unlockTime);
        }
        _refreshMark(uint32(engine.lastMarkPrice() == 0 ? ENTRY_PRICE : engine.lastMarkPrice()));
    }

}
