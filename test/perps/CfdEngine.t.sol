// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdMath} from "../../src/perps/CfdMath.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract CfdEngineTest is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function test_OpenPosition_SolvencyCheck() public {
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);

        // maxProfit = 1.2M tokens * $1 entry = $1.2M > vault's $1M balance
        CfdTypes.Order memory tooLarge = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 1_200_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });

        vm.expectRevert(CfdEngine.CfdEngine__VaultSolvencyExceeded.selector);
        vm.prank(address(router));
        engine.processOrder(tooLarge, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));

        CfdTypes.Order memory order = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });

        // Withdraw LP to reduce vault to $50k — solvency check should fail
        vm.warp(block.timestamp + 1 hours); // past deposit cooldown
        juniorVault.withdraw(950_000 * 1e6, address(this), address(this));
        vm.expectRevert(CfdEngine.CfdEngine__VaultSolvencyExceeded.selector);
        vm.prank(address(router));
        engine.processOrder(order, 1e8, 0, uint64(block.timestamp));

        // Re-deposit to allow the trade
        usdc.approve(address(juniorVault), 950_000 * 1e6);
        juniorVault.deposit(950_000 * 1e6, address(this));

        vm.prank(address(router));
        int256 settlement = engine.processOrder(order, 1e8, 200_000 * 1e6, uint64(block.timestamp));
        assertEq(settlement, 0, "processOrder always returns 0");

        (uint256 size, uint256 margin,,,,,,) = engine.positions(accountId);
        assertEq(size, 100_000 * 1e18, "Size mismatch");
        // 100k BULL at $1.00: execFee = $60, VPI = $12.50 → margin = $2000 - $72.50 = $1927.50
        assertEq(margin, 1_927_500_000, "Margin should equal deposit minus VPI and exec fee");
    }

    function test_FundingAccumulation() public {
        uint256 vaultDepth = 1_000_000 * 1e6;

        bytes32 account1 = bytes32(uint256(1));
        bytes32 account2 = bytes32(uint256(2));
        _fundTrader(address(uint160(uint256(account1))), 5000 * 1e6);
        _fundTrader(address(uint160(uint256(account2))), 5000 * 1e6);

        CfdTypes.Order memory retailLong = CfdTypes.Order({
            accountId: account1,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(retailLong, 1e8, vaultDepth, uint64(block.timestamp));

        vm.warp(block.timestamp + 30 days);

        CfdTypes.Order memory mmShort = CfdTypes.Order({
            accountId: account2,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 500 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 2,
            side: CfdTypes.Side.BEAR,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(mmShort, 1e8, vaultDepth, uint64(block.timestamp));

        int256 bullIndex = engine.bullFundingIndex();
        assertTrue(bullIndex < 0, "BULL index should decrease");

        int256 bearIndex = engine.bearFundingIndex();
        assertTrue(bearIndex > 0, "BEAR index should increase");

        (uint256 size,, uint256 entryPrice,, int256 entryFunding, CfdTypes.Side side,,) = engine.positions(account1);

        CfdTypes.Position memory bullPos = CfdTypes.Position({
            size: size,
            margin: 0,
            entryPrice: entryPrice,
            maxProfitUsdc: 0,
            entryFundingIndex: entryFunding,
            side: side,
            lastUpdateTime: 0,
            vpiAccrued: 0
        });

        int256 bullFunding = engine.getPendingFunding(bullPos);
        assertTrue(bullFunding < 0, "Retail BULL should owe massive funding");
    }

    function test_FundingSettlement_SyncsClearinghouse() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);

        // Open BULL $100k at $1.00
        CfdTypes.Order memory openOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(openOrder, 1e8, vaultDepth, uint64(block.timestamp));

        (, uint256 marginAfterOpen,,,,,,) = engine.positions(accountId);
        uint256 lockedAfterOpen = clearinghouse.lockedMarginUsdc(accountId);
        assertEq(lockedAfterOpen, marginAfterOpen, "lockedMargin == pos.margin after open");

        // Warp 30 days — accumulates negative funding for lone BULL
        vm.warp(block.timestamp + 30 days);

        // Increase position — triggers funding settlement in processOrder
        CfdTypes.Order memory addOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 500 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 2,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(addOrder, 1e8, vaultDepth, uint64(block.timestamp));

        (, uint256 marginAfterAdd,,,,,,) = engine.positions(accountId);
        uint256 lockedAfterAdd = clearinghouse.lockedMarginUsdc(accountId);
        assertEq(lockedAfterAdd, marginAfterAdd, "lockedMargin == pos.margin after funding settlement");
    }

    function test_WithdrawFees() public {
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);

        CfdTypes.Order memory order = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(order, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));

        // 100k BULL at $1.00: execFee = notional * 6bps = $100k * 0.0006 = $60
        uint256 fees = engine.accumulatedFeesUsdc();
        assertEq(fees, 60_000_000, "Exec fee should be 6bps of $100k notional");

        address treasury = address(0xBEEF);
        engine.withdrawFees(treasury);

        assertEq(engine.accumulatedFeesUsdc(), 0, "Fees should reset to zero");
        assertEq(usdc.balanceOf(treasury), fees, "Treasury receives exact fee amount");

        vm.expectRevert(CfdEngine.CfdEngine__NoFeesToWithdraw.selector);
        engine.withdrawFees(treasury);
    }

    function test_OpposingPosition_Reverts() public {
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 10_000 * 1e6);

        CfdTypes.Order memory bearOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 1000 * 1e6,
            targetPrice: 0.8e8,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BEAR,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(bearOrder, 0.8e8, 1_000_000 * 1e6, uint64(block.timestamp));

        CfdTypes.Order memory bullOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 1000 * 1e6,
            targetPrice: 0.8e8,
            commitTime: uint64(block.timestamp),
            orderId: 2,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.expectRevert(CfdEngine.CfdEngine__MustCloseOpposingPosition.selector);
        vm.prank(address(router));
        engine.processOrder(bullOrder, 0.8e8, 1_000_000 * 1e6, uint64(block.timestamp));
    }

    function test_FundingSettlement_ExceedsMargin_Reverts() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 1600 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(openOrder, 1e8, vaultDepth, uint64(block.timestamp));

        vm.warp(block.timestamp + 365 days);

        CfdTypes.Order memory addOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 1000 * 1e18,
            marginDelta: 1000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 2,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.expectRevert(CfdEngine.CfdEngine__FundingExceedsMargin.selector);
        vm.prank(address(router));
        engine.processOrder(addOrder, 1e8, vaultDepth, uint64(block.timestamp));
    }

    function test_EntryPriceAveraging() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 10_000 * 1e6);

        // Open 10k tokens at $0.80
        CfdTypes.Order memory first = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 1000 * 1e6,
            targetPrice: 0.8e8,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(first, 0.8e8, vaultDepth, uint64(block.timestamp));

        (,, uint256 entryAfterFirst,,,,,) = engine.positions(accountId);
        assertEq(entryAfterFirst, 0.8e8, "Entry should be $0.80");

        // Add 30k tokens at $1.20 → weighted avg = (10k*0.80 + 30k*1.20) / 40k = $1.10
        CfdTypes.Order memory second = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 30_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1.2e8,
            commitTime: uint64(block.timestamp),
            orderId: 2,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(second, 1.2e8, vaultDepth, uint64(block.timestamp));

        (uint256 totalSize,, uint256 avgEntry,,,,,) = engine.positions(accountId);
        assertEq(totalSize, 40_000 * 1e18, "Total size should be 40k");
        assertEq(avgEntry, 1.1e8, "Weighted avg entry should be $1.10");
    }

    function test_FundingSettlement_OnClose() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(openOrder, 1e8, vaultDepth, uint64(block.timestamp));

        uint256 chBefore = clearinghouse.balances(accountId, address(usdc));

        vm.warp(block.timestamp + 90 days);

        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 0,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 2,
            side: CfdTypes.Side.BULL,
            isClose: true
        });
        vm.prank(address(router));
        engine.processOrder(closeOrder, 1e8, vaultDepth, uint64(block.timestamp));

        uint256 chAfter = clearinghouse.balances(accountId, address(usdc));
        assertLt(chAfter, chBefore, "Funding drain should reduce clearinghouse balance on close");
    }

    function test_SetRiskParams_MakesPositionLiquidatable() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);

        CfdTypes.Order memory order = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(order, 1e8, vaultDepth, uint64(block.timestamp));

        vm.expectRevert(CfdEngine.CfdEngine__PositionIsSolvent.selector);
        vm.prank(address(router));
        engine.liquidatePosition(accountId, 1e8, vaultDepth, uint64(block.timestamp));

        engine.proposeRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0.0005e18,
                maxSkewRatio: 0.4e18,
                kinkSkewRatio: 0.25e18,
                baseApy: 0.15e18,
                maxApy: 3.0e18,
                maintMarginBps: 300,
                fadMarginBps: 500,
                minBountyUsdc: 5 * 1e6,
                bountyBps: 15
            })
        );
        vm.warp(block.timestamp + 48 hours + 1);
        engine.finalizeRiskParams();

        vm.prank(address(router));
        uint256 bounty = engine.liquidatePosition(accountId, 1e8, vaultDepth, uint64(block.timestamp));
        assertTrue(bounty > 0, "Position should be liquidatable after raising maintMarginBps");

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be wiped");
    }

    function test_Unauthorized_Caller_Reverts() public {
        bytes32 accountId = bytes32(uint256(1));
        CfdTypes.Order memory order = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 500 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });

        vm.prank(address(0xDEAD));
        vm.expectRevert(CfdEngine.CfdEngine__Unauthorized.selector);
        engine.processOrder(order, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));

        vm.prank(address(0xDEAD));
        vm.expectRevert(CfdEngine.CfdEngine__Unauthorized.selector);
        engine.liquidatePosition(accountId, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));
    }

    function test_CloseSize_ExceedsPosition_Reverts() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 1000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(openOrder, 1e8, vaultDepth, uint64(block.timestamp));

        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 20_000 * 1e18,
            marginDelta: 0,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 2,
            side: CfdTypes.Side.BULL,
            isClose: true
        });
        vm.expectRevert(CfdEngine.CfdEngine__CloseSizeExceedsPosition.selector);
        vm.prank(address(router));
        engine.processOrder(closeOrder, 1e8, vaultDepth, uint64(block.timestamp));
    }

    function test_MarginDrained_ByFees_Reverts() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);

        CfdTypes.Order memory order = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 50 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.expectRevert(CfdEngine.CfdEngine__MarginDrainedByFees.selector);
        vm.prank(address(router));
        engine.processOrder(order, 1e8, vaultDepth, uint64(block.timestamp));
    }

    function test_C5_CloseSucceeds_WhenFundingExceedsMargin_ButPositionProfitable() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 10_000 * 1e6);

        // Open BULL 100k tokens at $1.00 with $1600 margin (meets 1.5x initial margin)
        CfdTypes.Order memory openOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 1600 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(openOrder, 1e8, vaultDepth, uint64(block.timestamp));

        // Warp 365 days — funding will far exceed margin
        vm.warp(block.timestamp + 365 days);

        // Price dropped to $0.50 → BULL has $50k unrealized profit
        // User should be able to close and receive profit minus funding minus fees
        uint256 chBefore = clearinghouse.balances(accountId, address(usdc));

        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 0,
            targetPrice: 0.5e8,
            commitTime: uint64(block.timestamp),
            orderId: 2,
            side: CfdTypes.Side.BULL,
            isClose: true
        });

        // This should NOT revert — the position is profitable despite funding > margin
        vm.prank(address(router));
        engine.processOrder(closeOrder, 0.5e8, vaultDepth, uint64(block.timestamp));

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be fully closed");

        uint256 chAfter = clearinghouse.balances(accountId, address(usdc));
        assertGt(chAfter, chBefore, "User should net positive after profitable close minus funding");
    }

    function test_C2_InsufficientInitialMargin_Reverts() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 10_000 * 1e6);

        // notional = 100k * $1 = $100k. execFee = $60, VPI ~= $2.50
        // MMR = 1% of $100k = $1000
        // marginDelta = $100 covers fees but leaves pos.margin ~= $37, far below MMR
        // Without initial margin check, this succeeds and creates an instantly-liquidatable position
        CfdTypes.Order memory order = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 100 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });

        vm.expectRevert(CfdEngine.CfdEngine__InsufficientInitialMargin.selector);
        vm.prank(address(router));
        engine.processOrder(order, 1e8, vaultDepth, uint64(block.timestamp));
    }

    function test_H8_CloseAfterBlendedEntry_DoesNotUnderflow() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 10_000 * 1e6);

        // Open BEAR 100k tokens at price $1.00000001 (just above $1.00)
        CfdTypes.Order memory first = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 1600 * 1e6,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BEAR,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(first, 100_000_001, vaultDepth, uint64(block.timestamp));

        // Open BEAR 200k tokens at price $1.00 — blends entry to 100_000_000 (truncated from .33)
        // Sum of individual maxProfits < maxProfit(blended) due to integer truncation
        CfdTypes.Order memory second = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 200_000 * 1e18,
            marginDelta: 3200 * 1e6,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            orderId: 2,
            side: CfdTypes.Side.BEAR,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(second, 100_000_000, vaultDepth, uint64(block.timestamp));

        // Close entire position — must not underflow in _reduceGlobalLiability
        CfdTypes.Order memory close = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 300_000 * 1e18,
            marginDelta: 0,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            orderId: 3,
            side: CfdTypes.Side.BEAR,
            isClose: true
        });
        vm.prank(address(router));
        engine.processOrder(close, 100_000_000, vaultDepth, uint64(block.timestamp));

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be fully closed");
        assertEq(engine.globalBearMaxProfit(), 0, "Global bear max profit should be zero");
    }

    function test_H9_SolvencyDeadlock_CloseAllowedDuringInsolvency() public {
        vm.warp(block.timestamp + 1 hours);
        juniorVault.withdraw(800_000 * 1e6, address(this), address(this));

        uint256 vaultDepth = 200_000 * 1e6;
        bytes32 aliceId = bytes32(uint256(1));
        bytes32 bobId = bytes32(uint256(2));
        _fundTrader(address(uint160(uint256(aliceId))), 50_000 * 1e6);
        _fundTrader(address(uint160(uint256(bobId))), 50_000 * 1e6);

        CfdTypes.Order memory aliceOpen = CfdTypes.Order({
            accountId: aliceId,
            sizeDelta: 200_000 * 1e18,
            marginDelta: 20_000 * 1e6,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(aliceOpen, 1e8, vaultDepth, uint64(block.timestamp));

        CfdTypes.Order memory bobOpen = CfdTypes.Order({
            accountId: bobId,
            sizeDelta: 200_000 * 1e18,
            marginDelta: 20_000 * 1e6,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            orderId: 2,
            side: CfdTypes.Side.BEAR,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(bobOpen, 1e8, vaultDepth, uint64(block.timestamp));

        vm.prank(address(engine));
        pool.payOut(address(0xDEAD), 60_000 * 1e6);

        uint256 maxLiab = engine.globalBullMaxProfit() > engine.globalBearMaxProfit()
            ? engine.globalBullMaxProfit()
            : engine.globalBearMaxProfit();
        assertTrue(usdc.balanceOf(address(pool)) < maxLiab, "Vault should be insolvent");

        CfdTypes.Order memory aliceClose = CfdTypes.Order({
            accountId: aliceId,
            sizeDelta: 200_000 * 1e18,
            marginDelta: 0,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            orderId: 3,
            side: CfdTypes.Side.BULL,
            isClose: true
        });
        vm.prank(address(router));
        engine.processOrder(aliceClose, 1e8, vaultDepth, uint64(block.timestamp));

        (uint256 aliceSize,,,,,,,) = engine.positions(aliceId);
        assertEq(aliceSize, 0, "Close should succeed during insolvency");
    }

    function test_M11_LiquidationSeizesFreeEquity() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 50_000 * 1e6);

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 1600 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(openOrder, 1e8, vaultDepth, uint64(block.timestamp));

        uint256 freeEquityBefore = clearinghouse.getFreeBuyingPowerUsdc(accountId);
        assertTrue(freeEquityBefore > 0, "User should have free equity beyond locked margin");

        uint256 vaultBefore = usdc.balanceOf(address(pool));

        // Price rises to $1.10 — BULL loses $10k, equity = margin (~$1537) - $10k = negative
        vm.prank(address(router));
        engine.liquidatePosition(accountId, 1.1e8, vaultDepth, uint64(block.timestamp));

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be liquidated");

        uint256 freeEquityAfter = clearinghouse.getFreeBuyingPowerUsdc(accountId);
        assertTrue(freeEquityAfter < freeEquityBefore, "Free equity should be reduced to cover bad debt");

        uint256 vaultAfter = usdc.balanceOf(address(pool));
        uint256 totalRecovered = vaultAfter - vaultBefore;
        (, uint256 posMarginStored,,,,,,) = engine.positions(accountId);
        assertTrue(totalRecovered > 0, "Vault should recover more than zero from bad debt liquidation");
    }

    function test_LiquidationWorksWhenVaultInsolvent() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 aliceId = bytes32(uint256(1));
        bytes32 bobId = bytes32(uint256(2));
        _fundTrader(address(uint160(uint256(aliceId))), 50_000 * 1e6);
        _fundTrader(address(uint160(uint256(bobId))), 50_000 * 1e6);

        CfdTypes.Order memory aliceOpen = CfdTypes.Order({
            accountId: aliceId,
            sizeDelta: 200_000 * 1e18,
            marginDelta: 20_000 * 1e6,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(aliceOpen, 1e8, vaultDepth, uint64(block.timestamp));

        CfdTypes.Order memory bobOpen = CfdTypes.Order({
            accountId: bobId,
            sizeDelta: 200_000 * 1e18,
            marginDelta: 20_000 * 1e6,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            orderId: 2,
            side: CfdTypes.Side.BEAR,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(bobOpen, 1e8, vaultDepth, uint64(block.timestamp));

        // Drain vault to simulate insolvency (pool has ~$1M + fees, maxLiab = $200k)
        vm.prank(address(engine));
        pool.payOut(address(0xDEAD), 810_000 * 1e6);

        uint256 maxLiab = engine.globalBullMaxProfit() > engine.globalBearMaxProfit()
            ? engine.globalBullMaxProfit()
            : engine.globalBearMaxProfit();
        assertTrue(usdc.balanceOf(address(pool)) < maxLiab, "Vault should be insolvent");

        // Price rises to $1.10 — BULL loses $20k, deeply underwater
        vm.prank(address(router));
        engine.liquidatePosition(aliceId, 1.1e8, vaultDepth, uint64(block.timestamp));

        (uint256 aliceSize,,,,,,,) = engine.positions(aliceId);
        assertEq(aliceSize, 0, "Liquidation must succeed during insolvency");
    }

    function test_Liquidate_EmptyPosition_Reverts() public {
        bytes32 accountId = bytes32(uint256(1));
        vm.expectRevert(CfdEngine.CfdEngine__NoPositionToLiquidate.selector);
        vm.prank(address(router));
        engine.liquidatePosition(accountId, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));
    }

    function test_LiquidationBounty_CappedByPositionMargin() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1234));
        _fundTrader(address(uint160(uint256(accountId))), 200 * 1e6);

        engine.proposeRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0,
                maxSkewRatio: 0.4e18,
                kinkSkewRatio: 0.25e18,
                baseApy: 0.15e18,
                maxApy: 3.0e18,
                maintMarginBps: 10,
                fadMarginBps: 10,
                minBountyUsdc: 5 * 1e6,
                bountyBps: 100
            })
        );
        vm.warp(block.timestamp + 48 hours + 1);
        engine.finalizeRiskParams();

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 1000 * 1e18,
            marginDelta: 6 * 1e6,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(openOrder, 1e8, vaultDepth, uint64(block.timestamp));

        (, uint256 posMargin,,,,,,) = engine.positions(accountId);

        vm.prank(address(router));
        uint256 bounty = engine.liquidatePosition(accountId, 1.1e8, vaultDepth, uint64(block.timestamp));

        assertEq(bounty, posMargin, "Keeper bounty should not exceed position margin");
    }

    function test_ClearBadDebt_ReducesOutstandingDebt() public {
        bytes32 accountId = bytes32(uint256(0xBADD));
        _fundTrader(address(uint160(uint256(accountId))), 4_000 * 1e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000 * 1e18, 3_000 * 1e6, 1e8);

        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(accountId, 1.2e8, depth, uint64(block.timestamp));

        uint256 badDebt = engine.accumulatedBadDebtUsdc();
        assertGt(badDebt, 0, "Expected liquidation shortfall to create bad debt");

        uint256 clearAmount = badDebt / 2;
        engine.clearBadDebt(clearAmount);
        assertEq(engine.accumulatedBadDebtUsdc(), badDebt - clearAmount, "Bad debt should decrease after clearing");

        vm.expectRevert(CfdEngine.CfdEngine__BadDebtTooLarge.selector);
        engine.clearBadDebt(badDebt + 1);
    }

    function test_CheckWithdraw_UsesPoolMarkStalenessLimit() public {
        pool.proposeMarkStalenessLimit(300);
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizeMarkStalenessLimit();
        assertEq(pool.markStalenessLimit(), 300);

        bytes32 accountId = bytes32(uint256(0x5157));
        _fundTrader(address(uint160(uint256(accountId))), 5_000 * 1e6);
        _open(accountId, CfdTypes.Side.BULL, 20_000 * 1e18, 2_000 * 1e6, 1e8);

        vm.warp(block.timestamp + 180);

        engine.checkWithdraw(accountId);
    }

    function test_VpiDepthManipulation_NeutralizedByStatefulBound() public {
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 50_000 * 1e6);

        uint256 largeDepth = 10_000_000 * 1e6;
        uint256 smallDepth = 100_000 * 1e6;

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 10_000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        uint256 chBeforeOpen = clearinghouse.balances(accountId, address(usdc));
        vm.prank(address(router));
        engine.processOrder(openOrder, 1e8, largeDepth, uint64(block.timestamp));

        (,,,,,,, int256 storedVpi) = engine.positions(accountId);
        assertTrue(storedVpi != 0, "VPI should be tracked");

        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 0,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            orderId: 2,
            side: CfdTypes.Side.BULL,
            isClose: true
        });
        vm.prank(address(router));
        engine.processOrder(closeOrder, 1e8, smallDepth, uint64(block.timestamp));

        uint256 chAfterClose = clearinghouse.balances(accountId, address(usdc));

        // Without fix: close at smallDepth yields massive VPI rebate (attacker profits).
        // With fix: stateful bound caps close rebate to what was paid on open → net VPI = 0.
        // Only exec fees should be deducted. Exec fee = 6bps * $100k * 2 = $120.
        uint256 roundTripCost = chBeforeOpen - chAfterClose;
        uint256 execFeeRoundTrip = 120 * 1e6;
        assertEq(roundTripCost, execFeeRoundTrip, "Round-trip costs only exec fees, no VPI profit");
    }

}

// ==========================================
// CfdEngineFundingTest: funding edge cases (C-01, C-02, C-03)
// ==========================================

contract CfdEngineFundingTest is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.5e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 5_000_000 * 1e6;
    }

    // Regression: C-01 — stale funding index attack blocked by H-03 dust guard
    function test_StaleFundingIndex_DustCloseBlocked() public {
        uint256 depth = 5_000_000 * 1e6;

        bytes32 attackerId = bytes32(uint256(uint160(address(0xA1))));
        _fundTrader(address(0xA1), 500_000 * 1e6);

        bytes32 counterId = bytes32(uint256(uint160(address(0xB1))));
        _fundTrader(address(0xB1), 500_000 * 1e6);
        _open(counterId, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8, depth);

        uint256 minNotional = (uint256(5) * 1e6 * 10_000) / 15 + 1e6;
        uint256 minSize = (minNotional * 1e20) / 1e8;
        _open(attackerId, CfdTypes.Side.BULL, minSize, 50_000 * 1e6, 1e8, depth);

        // H-03: closing to 1 wei now reverts (remaining margin < minBountyUsdc)
        uint256 closeSize = minSize - 1;
        vm.expectRevert(CfdEngine.CfdEngine__DustPosition.selector);
        vm.prank(address(router));
        engine.processOrder(
            CfdTypes.Order({
                accountId: attackerId,
                sizeDelta: closeSize,
                marginDelta: 0,
                targetPrice: 0,
                commitTime: uint64(block.timestamp),
                orderId: 0,
                side: CfdTypes.Side.BULL,
                isClose: true
            }),
            1e8,
            depth,
            uint64(block.timestamp)
        );
    }

    // Regression: C-02 — per-side MtM cap creates phantom profit
    function test_PerSideMtmCap_PhantomProfit() public {
        uint256 depth = 5_000_000 * 1e6;

        bytes32 aliceId = bytes32(uint256(uint160(address(0xA2))));
        _fundTrader(address(0xA2), 100_000 * 1e6);
        _open(aliceId, CfdTypes.Side.BULL, 50_000 * 1e18, 5000 * 1e6, 1.2e8, depth);

        bytes32 bobId = bytes32(uint256(uint160(address(0xB2))));
        _fundTrader(address(0xB2), 100_000 * 1e6);
        _open(bobId, CfdTypes.Side.BULL, 100_000 * 1e18, 5000 * 1e6, 0.8e8, depth);

        vm.prank(address(router));
        engine.updateMarkPrice(1.1e8, uint64(block.timestamp));

        int256 mtm = engine.getVaultMtmAdjustment();

        uint256 totalBullMargin = engine.totalBullMargin();

        assertGe(
            mtm,
            int256(0),
            "C-02: Per-side cap must not create phantom profit by netting bad debt against profitable positions"
        );
    }

    // Regression: C-03 — unrealized MtM profits distributed as withdrawable cash
    function test_UnrealizedGains_DistributedAsWithdrawableCash() public {
        uint256 depth = 5_000_000 * 1e6;

        bytes32 traderId = bytes32(uint256(uint160(address(0x2222))));
        _fundTrader(address(0x2222), 500_000 * 1e6);
        _open(traderId, CfdTypes.Side.BULL, 2_000_000 * 1e18, 200_000 * 1e6, 1e8, depth);

        uint256 juniorBefore = pool.juniorPrincipal();

        vm.prank(address(router));
        engine.updateMarkPrice(1.5e8, uint64(block.timestamp));

        assertGe(engine.getVaultMtmAdjustment(), 0, "Fix: MtM clamped at 0, vault never sees paper profit");

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 juniorAfter = pool.juniorPrincipal();

        assertLe(
            juniorAfter,
            juniorBefore,
            "C-03: Junior principal must not increase from unrealized trader losses (paper MtM)"
        );
    }

}

// ==========================================
// CfdEngineAuditTest: engine-level audit findings
// ==========================================

contract CfdEngineAuditTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    // Regression: Finding-3
    function test_FundingBadDebt() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(carol, 50_000 * 1e6);

        bytes32 accountId = bytes32(uint256(uint160(carol)));

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        (uint256 sizeAfterOpen,,,,,,,) = engine.positions(accountId);

        vm.warp(block.timestamp + 180 days);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 1000 * 1e18, 500 * 1e6, 1e8, false);
        router.executeOrder(2, empty);

        (uint256 sizeAfterSecond,,,,,,,) = engine.positions(accountId);

        assertEq(sizeAfterSecond, sizeAfterOpen, "Order on underwater position should be cancelled");
    }

    // Regression: Finding-4
    function test_AsyncFundingDoesNotBlockLegitOrders() public {
        _fundJunior(bob, 210_000 * 1e6);

        address dave = address(0x444);
        _fundTrader(carol, 50_000 * 1e6);
        _fundTrader(dave, 200_000 * 1e6);

        vm.prank(dave);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000 * 1e18, 200_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 50_000 * 1e18, 5000 * 1e6, 1e8, false);
        router.executeOrder(2, empty);

        bytes32 carolAccount = bytes32(uint256(uint160(carol)));
        (uint256 sizeBefore,,,,,,,) = engine.positions(carolAccount);

        vm.warp(block.timestamp + 90 days);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        router.executeOrder(3, empty);

        (uint256 sizeAfter,,,,,,,) = engine.positions(carolAccount);

        assertGt(sizeAfter, sizeBefore, "Capped funding receivable covers vault depletion within margin bounds");
        assertLt(engine.getUnrealizedFundingPnl(), 0, "Net payers have negative unrealized funding (vault is owed)");
    }

    // Regression: C-01
    function test_PartialClosePreservesLockedMarginForRemainingPosition() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 22_000 * 1e6);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000 * 1e18, 20_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        (uint256 openSize,,,,,,,) = engine.positions(accountId);
        assertEq(openSize, 200_000 * 1e18);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000 * 1e18, 0, 0, true);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(0.8e8));
        router.executeOrder(2, priceData);

        (uint256 remainingSize,,,,,,,) = engine.positions(accountId);
        assertEq(remainingSize, 100_000 * 1e18, "Half position should remain");

        uint256 balAfter = clearinghouse.balances(accountId, address(usdc));
        uint256 lockedAfter = clearinghouse.lockedMarginUsdc(accountId);
        assertGe(balAfter, lockedAfter, "Physical balance must cover locked margin (zombie prevention)");

        router.executeLiquidation(accountId, priceData);

        (uint256 sizeAfterLiq,,,,,,,) = engine.positions(accountId);
        assertEq(sizeAfterLiq, 0, "Remaining position should be fully liquidated");
    }

    // Regression: M-01
    function test_FinalizeRiskParamsRetroactiveFunding() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(carol, 200_000 * 1e6);

        uint256 T0 = 1_710_000_000;
        uint256 T_PROPOSE = T0 + 30 days;
        uint256 T_FINALIZE = T0 + 30 days + 48 hours + 1;
        uint256 T_ORDER2 = T0 + 33 days;

        vm.warp(T0);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 100_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        int256 indexAfterOpen = engine.bullFundingIndex();

        vm.warp(T_PROPOSE);

        CfdTypes.RiskParams memory newParams = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 3.0e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
        engine.proposeRiskParams(newParams);

        vm.warp(T_FINALIZE);
        engine.finalizeRiskParams();

        vm.warp(T_ORDER2);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 5000 * 1e6, 1e8, false);
        router.executeOrder(2, empty);

        int256 indexAfterSettle = engine.bullFundingIndex();
        int256 indexDrop = indexAfterOpen - indexAfterSettle;

        uint256 totalElapsed = T_ORDER2 - T0;
        uint256 oldAnnRate = 0.06e18;
        int256 maxDrop = int256((oldAnnRate * totalElapsed * 2) / 365 days);

        assertLe(indexDrop, maxDrop, "Funding must not retroactively apply new rate to pre-finalize period");
    }

    // H-02 FIX: free equity withdrawable with open position
    function test_WithdrawFreeEquityWithOpenPosition() public {
        _fundJunior(bob, 500_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertGt(size, 0, "Position should be open");

        uint256 locked = clearinghouse.lockedMarginUsdc(accountId);
        uint256 usdcBal = clearinghouse.balances(accountId, address(usdc));
        uint256 free = usdcBal - locked;
        assertGt(free, 0, "Alice should have free USDC to withdraw");

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        clearinghouse.withdraw(accountId, address(usdc), free);
        assertEq(usdc.balanceOf(alice), balBefore + free, "Free equity withdrawn");
    }

}

// ==========================================
// MarginCappedMtmTest: per-side margin cap prevents phantom profits
// ==========================================

contract MarginCappedMtmTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_MarginTracking_IncreasesOnOpen() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        assertEq(engine.totalBullMargin(), 0);
        assertEq(engine.totalBearMargin(), 0);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        assertEq(engine.totalBullMargin(), 0, "Bull margin unchanged");
        assertGt(engine.totalBearMargin(), 0, "Bear margin tracked after open");
    }

    function test_MarginTracking_DecreasesOnClose() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        uint256 bearMarginAfterOpen = engine.totalBearMargin();
        assertGt(bearMarginAfterOpen, 0);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 0, 1e8, true);
        router.executeOrder(2, empty);

        assertEq(engine.totalBearMargin(), 0, "Bear margin zero after full close");
    }

    function test_MarginTracking_PartialClose() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        uint256 bearMarginFull = engine.totalBearMargin();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 50_000e18, 0, 1e8, true);
        router.executeOrder(2, empty);

        uint256 bearMarginHalf = engine.totalBearMargin();
        assertLt(bearMarginHalf, bearMarginFull, "Margin decreases on partial close");
        assertGt(bearMarginHalf, 0, "Margin still tracked for remaining position");
    }

    function test_MarginTracking_ZeroAfterLiquidation() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 2000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        assertGt(engine.totalBearMargin(), 0);

        bytes[] memory liqPrice = new bytes[](1);
        liqPrice[0] = abi.encode(uint256(0.5e8));
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        router.executeLiquidation(accountId, liqPrice);

        assertEq(engine.totalBearMargin(), 0, "Bear margin zero after liquidation");
    }

    // Regression: C-02
    function test_PhantomProfitCappedAtMargin() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(0.5e8));
        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 10_000e6, 0.5e8, false);
        router.executeOrder(2, priceData);

        int256 uncappedPnl = engine.getUnrealizedTraderPnl();
        int256 cappedMtm = engine.getVaultMtmAdjustment();

        assertLt(uncappedPnl, -int256(engine.totalBearMargin()), "Uncapped loss exceeds deposited margin");
        assertGe(cappedMtm, -int256(engine.totalBearMargin() + engine.totalBullMargin()), "Capped MtM bounded");
        assertGt(cappedMtm, uncappedPnl, "Capped MtM is less aggressive than uncapped");
    }

    // Regression: C-02
    function test_ReconcileDoesNotInflateBeyondMargin() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        uint256 juniorBefore = pool.juniorPrincipal();

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(0.5e8));
        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 10_000e6, 0.5e8, false);
        router.executeOrder(2, priceData);

        vm.prank(address(juniorVault));
        pool.reconcile();
        uint256 juniorAfter = pool.juniorPrincipal();

        uint256 revenue = juniorAfter > juniorBefore ? juniorAfter - juniorBefore : 0;
        assertLe(
            revenue,
            engine.totalBearMargin() + engine.totalBullMargin(),
            "Recognized revenue must not exceed seizable margin"
        );
    }

    function test_MtmAdjustment_PositiveWhenTradersWinning() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1.2e8));
        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 10_000e6, 1.2e8, false);
        router.executeOrder(2, priceData);

        int256 mtm = engine.getVaultMtmAdjustment();
        assertGt(mtm, 0, "Positive MtM = vault liability when traders are winning (no cap needed)");
    }

    function test_MtmAdjustment_ZeroWithNoPositions() public {
        _fundJunior(bob, 500_000e6);
        assertEq(engine.getVaultMtmAdjustment(), 0, "MtM should be zero with no positions");
    }

}

// ==========================================
// PhantomExecFeeTest: close exec fee must not inflate accumulatedFees
// ==========================================

contract PhantomExecFeeTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    // Regression: phantom exec fee
    function test_PhantomExecFee_InflatesAccumulatedFees() public {
        uint256 lpDeposit = 1_000_000e6;
        usdc.mint(bob, lpDeposit);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), lpDeposit);
        juniorVault.deposit(lpDeposit, bob);
        vm.stopPrank();

        uint256 margin = 1000e6;
        usdc.mint(alice, margin);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), margin);
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        clearinghouse.deposit(accountId, address(usdc), margin);

        uint256 size = 50_000e18;
        router.commitOrder(CfdTypes.Side.BULL, size, margin, 1e8, false);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        router.executeOrder(1, priceData);

        uint256 openFee = engine.accumulatedFeesUsdc();

        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, size, 0, 0, true);

        vm.warp(block.timestamp + 1);
        priceData[0] = abi.encode(uint256(1.5e8));
        router.executeOrder(2, priceData);

        uint256 totalFees = engine.accumulatedFeesUsdc();
        uint256 closeFee = totalFees - openFee;

        assertEq(closeFee, 0, "close exec fee should be 0 when shortfall exceeds fee");
    }

}

// ==========================================
// NegativeFundingFreeUsdcTest: negative funding receivables
// ==========================================

contract NegativeFundingFreeUsdcTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    // Regression: negative funding receivables
    function test_GetFreeUSDC_IgnoresNegativeFunding() public {
        usdc.mint(bob, 1_000_000e6);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), 1_000_000e6);
        juniorVault.deposit(1_000_000e6, bob);
        vm.stopPrank();

        uint256 margin = 100_000e6;
        usdc.mint(alice, margin);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), margin);
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        clearinghouse.deposit(accountId, address(usdc), margin);

        uint256 size = 200_000e18;
        router.commitOrder(CfdTypes.Side.BULL, size, margin, 1e8, false);
        vm.stopPrank();

        _warpForward(1);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        router.executeOrder(1, priceData);

        _warpForward(30 days);

        address carol = address(0x333);
        uint256 carolMargin = 10_000e6;
        usdc.mint(carol, carolMargin);
        vm.startPrank(carol);
        usdc.approve(address(clearinghouse), carolMargin);
        clearinghouse.deposit(bytes32(uint256(uint160(carol))), address(usdc), carolMargin);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, carolMargin, 1e8, false);
        vm.stopPrank();

        _warpForward(1);
        priceData[0] = abi.encode(uint256(1e8));
        router.executeOrder(2, priceData);

        int256 unrealizedFunding = engine.getUnrealizedFundingPnl();
        assertLt(unrealizedFunding, 0, "funding should be negative (house is owed)");

        uint256 freeUsdcNow = pool.getFreeUSDC();

        uint256 bal = usdc.balanceOf(address(pool));
        uint256 maxLiability = engine.globalBullMaxProfit();
        uint256 pendingFees = engine.accumulatedFeesUsdc();
        uint256 reservedWithoutFunding = maxLiability + pendingFees;
        uint256 freeWithoutFunding = bal > reservedWithoutFunding ? bal - reservedWithoutFunding : 0;

        assertEq(
            freeUsdcNow, freeWithoutFunding, "getFreeUSDC must not reduce reserves by illiquid funding receivables"
        );
    }

}

// ==========================================
// VpiDepthTest: VPI depth manipulation attacks
// ==========================================

contract VpiDepthTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.01e18,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    // Regression: C-02a
    function test_MinorityVpiRebateCannotExceedPaidCharges() public {
        _fundJunior(bob, 1_000_000 * 1e6);

        _fundTrader(carol, 50_000 * 1e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000 * 1e18, 40_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        _fundTrader(alice, 50_000 * 1e6);
        bytes32 aliceAccount = bytes32(uint256(uint160(alice)));
        uint256 aliceBalBefore = clearinghouse.balances(aliceAccount, address(usdc));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        router.executeOrder(2, empty);

        _fundJunior(bob, 9_000_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 0, 0, true);
        bytes[] memory closePrice = new bytes[](1);
        closePrice[0] = abi.encode(uint256(1e8));
        router.executeOrder(3, closePrice);

        uint256 aliceBalAfter = clearinghouse.balances(aliceAccount, address(usdc));

        assertLe(aliceBalAfter, aliceBalBefore, "Minority VPI depth attack must not be profitable");
    }

    // Regression: C-02b
    function test_SizeAdditionCannotBypassVpiBound() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        bytes32 aliceAccount = bytes32(uint256(uint160(alice)));
        uint256 aliceBalBefore = clearinghouse.balances(aliceAccount, address(usdc));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 5000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        _fundJunior(bob, 9_000_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        router.executeOrder(2, empty);

        vm.warp(block.timestamp + 2 hours);
        bytes[] memory freshPrice = new bytes[](1);
        freshPrice[0] = abi.encode(uint256(1e8));
        router.updateMarkPrice(freshPrice);
        vm.startPrank(bob);
        uint256 withdrawable = juniorVault.maxWithdraw(bob);
        if (withdrawable > 0) {
            juniorVault.withdraw(withdrawable, bob, bob);
        }
        vm.stopPrank();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 110_000 * 1e18, 0, 0, true);
        bytes[] memory closePrice = new bytes[](1);
        closePrice[0] = abi.encode(uint256(1e8));
        router.executeOrder(3, closePrice);

        uint256 aliceBalAfter = clearinghouse.balances(aliceAccount, address(usdc));

        assertLe(aliceBalAfter, aliceBalBefore, "Size addition VPI bypass must not be profitable");
    }

}

// ==========================================
// VpiChunkingTest: H-01 linear VPI chunking tests
// ==========================================

contract VpiMockUSDC6 is ERC20 {

    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

contract VpiChunkingTest is Test {

    VpiMockUSDC6 usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;

    uint256 constant CAP_PRICE = 2e8;
    uint256 constant DEPTH = 5_000_000 * 1e6;

    function setUp() public {
        usdc = new VpiMockUSDC6();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0.001e18,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "juniorUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        engine.setOrderRouter(address(this));

        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        clearinghouse.proposeWithdrawGuard(address(engine));
        vm.warp(48 hours + 2);
        clearinghouse.finalizeAssetConfig();
        clearinghouse.finalizeWithdrawGuard();

        clearinghouse.proposeOperator(address(engine), true);
        vm.warp(96 hours + 3);
        clearinghouse.finalizeOperator();

        vm.warp(1_709_532_000);

        usdc.mint(address(this), 10_000_000 * 1e6);
        usdc.approve(address(juniorVault), type(uint256).max);
        juniorVault.deposit(5_000_000 * 1e6, address(this));
    }

    function _deposit(
        bytes32 accountId,
        uint256 amount
    ) internal {
        address user = address(uint160(uint256(accountId)));
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, address(usdc), amount);
        vm.stopPrank();
    }

    function _open(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 depth
    ) internal {
        engine.processOrder(
            CfdTypes.Order({
                accountId: accountId,
                sizeDelta: size,
                marginDelta: margin,
                targetPrice: price,
                commitTime: uint64(block.timestamp),
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
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 size,
        uint256 price,
        uint256 depth
    ) internal {
        engine.processOrder(
            CfdTypes.Order({
                accountId: accountId,
                sizeDelta: size,
                marginDelta: 0,
                targetPrice: 0,
                commitTime: uint64(block.timestamp),
                orderId: 0,
                side: side,
                isClose: true
            }),
            price,
            depth,
            uint64(block.timestamp)
        );
    }

    // Regression: H-01 — MM rebate zeroed by bidirectional clamp (design tradeoff)
    function test_MM_RebateZeroed_DesignTradeoff() public {
        bytes32 bearSkewerId = bytes32(uint256(uint160(address(0x51))));
        _deposit(bearSkewerId, 500_000 * 1e6);
        _open(bearSkewerId, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        bytes32 mmId = bytes32(uint256(uint160(address(0x111))));
        _deposit(mmId, 500_000 * 1e6);
        _open(mmId, CfdTypes.Side.BULL, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        (,,,,,,, int256 vpiAfterOpen) = engine.positions(mmId);
        assertLt(vpiAfterOpen, 0, "MM earned VPI rebate on open (healed skew)");

        bytes32 bullFlipperId = bytes32(uint256(uint160(address(0x52))));
        _deposit(bullFlipperId, 500_000 * 1e6);
        _open(bullFlipperId, CfdTypes.Side.BULL, 1_000_000 * 1e18, 100_000 * 1e6, 1e8, DEPTH);

        (uint256 mmSize,,,,,,,) = engine.positions(mmId);
        _close(mmId, CfdTypes.Side.BULL, mmSize, 1e8, DEPTH);
        uint256 mmUsdcAfter = clearinghouse.balances(mmId, address(usdc));

        uint256 totalDeposited = 500_000 * 1e6;
        uint256 approxExecFees = (500_000 * 1e6 * 6 / 10_000) * 2;
        uint256 breakeven = totalDeposited - approxExecFees;

        assertEq(
            mmUsdcAfter,
            breakeven,
            "H-01 tradeoff: MM nets $0 VPI (open rebate clawed back on close to prevent depth attack)"
        );
    }

    // Regression: H-01 — linear VPI chunking bounded error
    function test_PartialClose_LinearChunking_BoundedError() public {
        bytes32 skewerId = bytes32(uint256(uint160(address(0x52))));
        _deposit(skewerId, 500_000 * 1e6);
        _open(skewerId, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        bytes32 aliceId = bytes32(uint256(uint160(address(0xA1))));
        _deposit(aliceId, 500_000 * 1e6);
        _open(aliceId, CfdTypes.Side.BULL, 400_000 * 1e18, 100_000 * 1e6, 1e8, DEPTH);

        uint256 aliceBefore = clearinghouse.balances(aliceId, address(usdc));
        _close(aliceId, CfdTypes.Side.BULL, 400_000 * 1e18, 1e8, DEPTH);
        uint256 aliceAfter = clearinghouse.balances(aliceId, address(usdc));
        int256 aliceNet = int256(aliceAfter) - int256(aliceBefore);

        _close(skewerId, CfdTypes.Side.BEAR, 500_000 * 1e18, 1e8, DEPTH);
        _open(skewerId, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        bytes32 bobId = bytes32(uint256(uint160(address(0xB1))));
        _deposit(bobId, 500_000 * 1e6);
        _open(bobId, CfdTypes.Side.BULL, 400_000 * 1e18, 100_000 * 1e6, 1e8, DEPTH);

        uint256 bobBefore = clearinghouse.balances(bobId, address(usdc));
        _close(bobId, CfdTypes.Side.BULL, 200_000 * 1e18, 1e8, DEPTH);
        _close(bobId, CfdTypes.Side.BULL, 200_000 * 1e18, 1e8, DEPTH);
        uint256 bobAfter = clearinghouse.balances(bobId, address(usdc));
        int256 bobNet = int256(bobAfter) - int256(bobBefore);

        int256 diff = aliceNet > bobNet ? aliceNet - bobNet : bobNet - aliceNet;
        uint256 tolerance = 5 * 1e6;

        assertLe(uint256(diff), tolerance, "H-01: Linear chunking error must stay within bounded tolerance");
    }

}
