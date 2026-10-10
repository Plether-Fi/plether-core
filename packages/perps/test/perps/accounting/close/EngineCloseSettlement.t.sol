// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {CfdEngineTestBase} from "../../shared/CfdEngineTestBase.sol";

contract EngineCloseSettlementTest is CfdEngineTestBase {

    using stdStorage for StdStorage;

    function test_FullClose_AfterFreshMark_DoesNotRevertWhenPoolIlliquid() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address longAccount = address(uint160(1));
        address shortAccount = address(uint160(2));
        _fundTrader(longAccount, 5000 * 1e6);
        _fundTrader(shortAccount, 5000 * 1e6);

        _open(longAccount, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8, poolDepth);
        _open(shortAccount, CfdTypes.Side.SHORT, 10_000e18, 500e6, 1e8, poolDepth);

        uint64 refreshTime = uint64(block.timestamp + 30 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint64 accrualTime = refreshTime + 59;
        vm.warp(accrualTime);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(shortAccount, 10_000e18, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        _closeAt(shortAccount, CfdTypes.Side.SHORT, 10_000e18, 1e8, poolDepth, accrualTime);

        (uint256 size,,,,,,) = engine.positions(shortAccount);
        assertEq(size, 0, "Illiquid profitable close close should still destroy the position");
        assertEq(
            engine.traderClaimBalanceUsdc(shortAccount),
            preview.traderClaimBalanceUsdc,
            "Live close should match preview"
        );
    }

    function test_OracleFrozenFullClose_ClaimRecoveryPaysFeeThenBaseThenSpread() public {
        address account = address(0xAB131A);
        uint256 size = 100_000e18;
        uint256 closePrice = 1.02e8;
        _fundTrader(account, 2000e6);
        _open(account, CfdTypes.Side.LONG, size, 2000e6, 1e8);

        vm.warp(1_709_985_600);
        assertTrue(engine.isOracleFrozen(), "Setup should be in oracle-frozen mode");

        _removePnlPledgeAndSyncTerminalCurve(account);

        ICfdEngineTypes.ClosePreview memory withoutClaim = engineLens.previewClose(account, size, closePrice);
        uint256 assessedFeeUsdc = _engineExecutionFeeUsdc(size, closePrice);
        assertLt(withoutClaim.realizedPnlUsdc, 0, "Setup must realize an isolated trader price loss");
        uint256 priceLossUsdc = uint256(-withoutClaim.realizedPnlUsdc);
        uint256 extraClaimUsdc = assessedFeeUsdc + withoutClaim.frozenSpreadUsdc / 2;

        assertTrue(withoutClaim.valid, "Terminal close should remain valid without physical collateral");
        assertLt(
            withoutClaim.seizedCollateralUsdc,
            priceLossUsdc,
            "Price loss above the PnL pledge should remain a diagnostic writeoff"
        );
        assertEq(withoutClaim.badDebtUsdc, 0, "Uncollectible price loss must not create protocol debt");
        assertEq(withoutClaim.executionFeeUsdc, 0, "No physical value should collect the execution fee");
        assertEq(withoutClaim.frozenSpreadPaidUsdc, 0, "No physical value should collect the spread");
        assertEq(
            withoutClaim.frozenSpreadWaivedUsdc,
            withoutClaim.frozenSpreadUsdc,
            "Without a claim the entire frozen spread should be waivable"
        );

        uint256 traderClaimUsdc = priceLossUsdc + extraClaimUsdc;
        _seedAuthenticatedTraderClaim(account, traderClaimUsdc);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, size, closePrice);
        assertTrue(preview.valid, "Claim-funded terminal frozen close should be valid");
        assertEq(
            preview.existingTraderClaimConsumedUsdc,
            priceLossUsdc,
            "Same-account claim should net only the exact price loss"
        );
        assertEq(
            preview.existingTraderClaimRemainingUsdc,
            extraClaimUsdc,
            "Action charges must not consume claim value left after price-loss netting"
        );
        assertEq(preview.seizedCollateralUsdc, 0, "Claim-first price netting should preserve the isolated PnL pledge");
        assertEq(preview.executionFeeUsdc, 0, "Execution fee must be waived without eligible action collateral");
        assertEq(preview.badDebtUsdc, 0, "Price-loss netting must not create protocol debt");
        assertEq(preview.frozenSpreadPaidUsdc, 0, "Frozen spread must not consume same-account claim value");
        assertEq(
            preview.frozenSpreadWaivedUsdc,
            preview.frozenSpreadUsdc,
            "Frozen spread with no eligible action collateral should be fully waived"
        );
        assertEq(
            preview.frozenSpreadPaidUsdc + preview.frozenSpreadWaivedUsdc,
            preview.frozenSpreadUsdc,
            "Paid and waived spread should conserve the assessment"
        );

        uint256 treasuryBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        uint256 poolAssetsBefore = pool.totalAssets();
        vm.expectEmit(true, false, false, true, address(engine.settlementSidecar()));
        emit FrozenCloseSpreadSettled(
            account, preview.frozenSpreadUsdc, preview.frozenSpreadPaidUsdc, preview.frozenSpreadWaivedUsdc
        );
        _close(account, CfdTypes.Side.LONG, size, closePrice);

        assertEq(
            engine.traderClaimBalanceUsdc(account),
            extraClaimUsdc,
            "Live close should leave action-ineligible claim value untouched"
        );
        assertEq(
            engine.totalTraderClaimBalanceUsdc(),
            extraClaimUsdc,
            "Aggregate claims should fall only by the exact price-loss netting amount"
        );
        assertEq(
            terminalNavBook.curveHashOf(account),
            bytes32(0),
            "Claim-funded terminal close should remove the account's exact terminal-NAV curve"
        );
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            treasuryBefore,
            "Treasury must not recover execution fees from trader claims"
        );
        assertEq(
            pool.totalAssets(),
            poolAssetsBefore,
            "Claim netting and waived action charges must not fabricate pool cash movement"
        );
    }

    function test_CloseSize_ExceedsPosition_Reverts() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        _fundTrader(account, 5000 * 1e6);

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 1000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(openOrder, 1e8, poolDepth, uint64(block.timestamp));

        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 20_000 * 1e18,
            marginDelta: 0,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.LONG,
            isClose: true
        });
        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector, 1, 1, true));
        vm.prank(address(router));
        engine.processOrderTyped(closeOrder, 1e8, poolDepth, uint64(block.timestamp));
    }

    function test_CloseAfterBlendedEntry_DoesNotUnderflow() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        _fundTrader(account, 10_000 * 1e6);

        // Open SHORT 100k tokens at price $1.00000001 (just above $1.00)
        CfdTypes.Order memory first = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.SHORT,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(first, 100_000_001, poolDepth, uint64(block.timestamp));

        // Open SHORT 200k tokens at price $1.00 — blends entry to 100_000_000 (truncated from .33)
        // Sum of individual maxProfits < maxProfit(blended) due to integer truncation
        CfdTypes.Order memory second = CfdTypes.Order({
            account: account,
            sizeDelta: 200_000 * 1e18,
            marginDelta: 3200 * 1e6,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.SHORT,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(second, 100_000_000, poolDepth, uint64(block.timestamp));

        // Close entire position — must not underflow in _reduceGlobalLiability
        CfdTypes.Order memory close = CfdTypes.Order({
            account: account,
            sizeDelta: 300_000 * 1e18,
            marginDelta: 0,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 3,
            side: CfdTypes.Side.SHORT,
            isClose: true
        });
        vm.prank(address(router));
        engine.processOrderTyped(close, 100_000_000, poolDepth, uint64(block.timestamp));

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Position should be fully closed");
        assertEq(_sideMaxProfit(CfdTypes.Side.SHORT), 0, "Global short max profit should be zero");
    }

    function test_SolvencyDeadlock_CloseAllowedDuringInsolvency() public {
        vm.warp(block.timestamp + 1 hours);
        _settleJuniorWithdrawal(address(this), 800_000 * 1e6);

        uint256 poolDepth = 200_000 * 1e6;
        address aliceAccount = address(uint160(1));
        address bobAccount = address(uint160(2));
        _fundTrader(aliceAccount, 50_000 * 1e6);
        _fundTrader(bobAccount, 50_000 * 1e6);

        CfdTypes.Order memory aliceOpen = CfdTypes.Order({
            account: aliceAccount,
            sizeDelta: 200_000 * 1e18,
            marginDelta: 20_000 * 1e6,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(aliceOpen, 1e8, poolDepth, uint64(block.timestamp));

        CfdTypes.Order memory bobOpen = CfdTypes.Order({
            account: bobAccount,
            sizeDelta: 200_000 * 1e18,
            marginDelta: 20_000 * 1e6,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.SHORT,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(bobOpen, 1e8, poolDepth, uint64(block.timestamp));

        vm.prank(address(engine));
        pool.payOut(address(0xDEAD), 60_000 * 1e6);

        uint256 maxLiab = _sideMaxProfit(CfdTypes.Side.LONG) > _sideMaxProfit(CfdTypes.Side.SHORT)
            ? _sideMaxProfit(CfdTypes.Side.LONG)
            : _sideMaxProfit(CfdTypes.Side.SHORT);
        assertTrue(usdc.balanceOf(address(pool)) < maxLiab, "Pool should be insolvent");

        CfdTypes.Order memory aliceClose = CfdTypes.Order({
            account: aliceAccount,
            sizeDelta: 200_000 * 1e18,
            marginDelta: 0,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 3,
            side: CfdTypes.Side.LONG,
            isClose: true
        });
        vm.prank(address(router));
        engine.processOrderTyped(aliceClose, 1e8, poolDepth, uint64(block.timestamp));

        (uint256 aliceSize,,,,,,) = engine.positions(aliceAccount);
        assertEq(aliceSize, 0, "Close should succeed during insolvency");
    }

}

