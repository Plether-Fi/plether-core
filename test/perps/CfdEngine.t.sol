// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockUSDC is ERC20 {

    constructor() ERC20("Mock USDC", "USDC") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

contract CfdEngineTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;

    uint256 constant CAP_PRICE = 2e8;

    function setUp() public {
        vm.warp(1_709_532_000); // Monday 2024-03-04 10:00 UTC (avoids FAD window)
        usdc = new MockUSDC();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
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

        clearinghouse = new MarginClearinghouse();
        clearinghouse.supportAsset(address(usdc), 6, 10_000, address(0));

        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        clearinghouse.setOperator(address(engine), true);
        engine.setOrderRouter(address(this));

        usdc.mint(address(this), 1_000_000 * 1e6);
        usdc.approve(address(juniorVault), type(uint256).max);
        juniorVault.deposit(1_000_000 * 1e6, address(this));
    }

    function _depositToClearinghouse(
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

    function test_OpenPosition_SolvencyCheck() public {
        bytes32 accountId = bytes32(uint256(1));
        _depositToClearinghouse(accountId, 5000 * 1e6);

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
        engine.processOrder(tooLarge, 1e8, 1_000_000 * 1e6);

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
        engine.processOrder(order, 1e8, 0);

        // Re-deposit to allow the trade
        usdc.approve(address(juniorVault), 950_000 * 1e6);
        juniorVault.deposit(950_000 * 1e6, address(this));

        int256 settlement = engine.processOrder(order, 1e8, 200_000 * 1e6);
        assertEq(settlement, 0, "processOrder always returns 0");

        (uint256 size, uint256 margin,,,,,) = engine.positions(accountId);
        assertEq(size, 100_000 * 1e18, "Size mismatch");
        // 100k BULL at $1.00: execFee = $60, VPI = $12.50 → margin = $2000 - $72.50 = $1927.50
        assertEq(margin, 1_927_500_000, "Margin should equal deposit minus VPI and exec fee");
    }

    function test_FundingAccumulation() public {
        uint256 vaultDepth = 1_000_000 * 1e6;

        bytes32 account1 = bytes32(uint256(1));
        bytes32 account2 = bytes32(uint256(2));
        _depositToClearinghouse(account1, 5000 * 1e6);
        _depositToClearinghouse(account2, 5000 * 1e6);

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
        engine.processOrder(retailLong, 1e8, vaultDepth);

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
        engine.processOrder(mmShort, 1e8, vaultDepth);

        int256 bullIndex = engine.bullFundingIndex();
        assertTrue(bullIndex < 0, "BULL index should decrease");

        int256 bearIndex = engine.bearFundingIndex();
        assertTrue(bearIndex > 0, "BEAR index should increase");

        (uint256 size,, uint256 entryPrice,, int256 entryFunding, CfdTypes.Side side,) = engine.positions(account1);

        CfdTypes.Position memory bullPos = CfdTypes.Position({
            size: size,
            margin: 0,
            entryPrice: entryPrice,
            maxProfitUsdc: 0,
            entryFundingIndex: entryFunding,
            side: side,
            lastUpdateTime: 0
        });

        int256 bullFunding = engine.getPendingFunding(bullPos);
        assertTrue(bullFunding < 0, "Retail BULL should owe massive funding");
    }

    function test_FundingSettlement_SyncsClearinghouse() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _depositToClearinghouse(accountId, 5000 * 1e6);

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
        engine.processOrder(openOrder, 1e8, vaultDepth);

        (, uint256 marginAfterOpen,,,,,) = engine.positions(accountId);
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
        engine.processOrder(addOrder, 1e8, vaultDepth);

        (, uint256 marginAfterAdd,,,,,) = engine.positions(accountId);
        uint256 lockedAfterAdd = clearinghouse.lockedMarginUsdc(accountId);
        assertEq(lockedAfterAdd, marginAfterAdd, "lockedMargin == pos.margin after funding settlement");
    }

    function test_WithdrawFees() public {
        bytes32 accountId = bytes32(uint256(1));
        _depositToClearinghouse(accountId, 5000 * 1e6);

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
        engine.processOrder(order, 1e8, 1_000_000 * 1e6);

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
        _depositToClearinghouse(accountId, 10_000 * 1e6);

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
        engine.processOrder(bearOrder, 0.8e8, 1_000_000 * 1e6);

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
        engine.processOrder(bullOrder, 0.8e8, 1_000_000 * 1e6);
    }

    function test_FundingSettlement_ExceedsMargin_Reverts() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _depositToClearinghouse(accountId, 5000 * 1e6);

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
        engine.processOrder(openOrder, 1e8, vaultDepth);

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
        engine.processOrder(addOrder, 1e8, vaultDepth);
    }

    function test_EntryPriceAveraging() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _depositToClearinghouse(accountId, 10_000 * 1e6);

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
        engine.processOrder(first, 0.8e8, vaultDepth);

        (,, uint256 entryAfterFirst,,,,) = engine.positions(accountId);
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
        engine.processOrder(second, 1.2e8, vaultDepth);

        (uint256 totalSize,, uint256 avgEntry,,,,) = engine.positions(accountId);
        assertEq(totalSize, 40_000 * 1e18, "Total size should be 40k");
        assertEq(avgEntry, 1.1e8, "Weighted avg entry should be $1.10");
    }

    function test_FundingSettlement_OnClose() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _depositToClearinghouse(accountId, 5000 * 1e6);

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
        engine.processOrder(openOrder, 1e8, vaultDepth);

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
        engine.processOrder(closeOrder, 1e8, vaultDepth);

        uint256 chAfter = clearinghouse.balances(accountId, address(usdc));
        assertLt(chAfter, chBefore, "Funding drain should reduce clearinghouse balance on close");
    }

    function test_SetRiskParams_MakesPositionLiquidatable() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _depositToClearinghouse(accountId, 5000 * 1e6);

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
        engine.processOrder(order, 1e8, vaultDepth);

        vm.expectRevert(CfdEngine.CfdEngine__PositionIsSolvent.selector);
        engine.liquidatePosition(accountId, 1e8, vaultDepth);

        engine.setRiskParams(
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

        uint256 bounty = engine.liquidatePosition(accountId, 1e8, vaultDepth);
        assertTrue(bounty > 0, "Position should be liquidatable after raising maintMarginBps");

        (uint256 size,,,,,,) = engine.positions(accountId);
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
        engine.processOrder(order, 1e8, 1_000_000 * 1e6);

        vm.prank(address(0xDEAD));
        vm.expectRevert(CfdEngine.CfdEngine__Unauthorized.selector);
        engine.liquidatePosition(accountId, 1e8, 1_000_000 * 1e6);
    }

    function test_CloseSize_ExceedsPosition_Reverts() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _depositToClearinghouse(accountId, 5000 * 1e6);

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
        engine.processOrder(openOrder, 1e8, vaultDepth);

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
        engine.processOrder(closeOrder, 1e8, vaultDepth);
    }

    function test_MarginDrained_ByFees_Reverts() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _depositToClearinghouse(accountId, 5000 * 1e6);

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
        engine.processOrder(order, 1e8, vaultDepth);
    }

    function test_C5_CloseSucceeds_WhenFundingExceedsMargin_ButPositionProfitable() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _depositToClearinghouse(accountId, 10_000 * 1e6);

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
        engine.processOrder(openOrder, 1e8, vaultDepth);

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
        engine.processOrder(closeOrder, 0.5e8, vaultDepth);

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be fully closed");

        uint256 chAfter = clearinghouse.balances(accountId, address(usdc));
        assertGt(chAfter, chBefore, "User should net positive after profitable close minus funding");
    }

    function test_C2_InsufficientInitialMargin_Reverts() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _depositToClearinghouse(accountId, 10_000 * 1e6);

        // notional = 100k * $1 = $100k. execFee = $60, VPI ≈ $2.50
        // MMR = 1% of $100k = $1000
        // marginDelta = $100 covers fees but leaves pos.margin ≈ $37, far below MMR
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
        engine.processOrder(order, 1e8, vaultDepth);
    }

    function test_H8_CloseAfterBlendedEntry_DoesNotUnderflow() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _depositToClearinghouse(accountId, 10_000 * 1e6);

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
        engine.processOrder(first, 100_000_001, vaultDepth);

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
        engine.processOrder(second, 100_000_000, vaultDepth);

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
        engine.processOrder(close, 100_000_000, vaultDepth);

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be fully closed");
        assertEq(engine.globalBearMaxProfit(), 0, "Global bear max profit should be zero");
    }

    function test_H9_SolvencyDeadlock_CloseAllowedDuringInsolvency() public {
        vm.warp(block.timestamp + 1 hours);
        juniorVault.withdraw(800_000 * 1e6, address(this), address(this));

        uint256 vaultDepth = 200_000 * 1e6;
        bytes32 aliceId = bytes32(uint256(1));
        bytes32 bobId = bytes32(uint256(2));
        _depositToClearinghouse(aliceId, 50_000 * 1e6);
        _depositToClearinghouse(bobId, 50_000 * 1e6);

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
        engine.processOrder(aliceOpen, 1e8, vaultDepth);

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
        engine.processOrder(bobOpen, 1e8, vaultDepth);

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
        engine.processOrder(aliceClose, 1e8, vaultDepth);

        (uint256 aliceSize,,,,,,) = engine.positions(aliceId);
        assertEq(aliceSize, 0, "Close should succeed during insolvency");
    }

    function test_M11_LiquidationSeizesFreeEquity() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _depositToClearinghouse(accountId, 50_000 * 1e6);

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
        engine.processOrder(openOrder, 1e8, vaultDepth);

        uint256 freeEquityBefore = clearinghouse.getFreeBuyingPowerUsdc(accountId);
        assertTrue(freeEquityBefore > 0, "User should have free equity beyond locked margin");

        uint256 vaultBefore = usdc.balanceOf(address(pool));

        // Price rises to $1.10 — BULL loses $10k, equity = margin (~$1537) - $10k = negative
        engine.liquidatePosition(accountId, 1.1e8, vaultDepth);

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be liquidated");

        uint256 freeEquityAfter = clearinghouse.getFreeBuyingPowerUsdc(accountId);
        assertTrue(freeEquityAfter < freeEquityBefore, "Free equity should be reduced to cover bad debt");

        uint256 vaultAfter = usdc.balanceOf(address(pool));
        uint256 totalRecovered = vaultAfter - vaultBefore;
        (, uint256 posMarginStored,,,,,) = engine.positions(accountId);
        assertTrue(totalRecovered > 0, "Vault should recover more than zero from bad debt liquidation");
    }

    function test_LiquidationWorksWhenVaultInsolvent() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 aliceId = bytes32(uint256(1));
        bytes32 bobId = bytes32(uint256(2));
        _depositToClearinghouse(aliceId, 50_000 * 1e6);
        _depositToClearinghouse(bobId, 50_000 * 1e6);

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
        engine.processOrder(aliceOpen, 1e8, vaultDepth);

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
        engine.processOrder(bobOpen, 1e8, vaultDepth);

        // Drain vault to simulate insolvency (pool has ~$1M + fees, maxLiab = $200k)
        vm.prank(address(engine));
        pool.payOut(address(0xDEAD), 810_000 * 1e6);

        uint256 maxLiab = engine.globalBullMaxProfit() > engine.globalBearMaxProfit()
            ? engine.globalBullMaxProfit()
            : engine.globalBearMaxProfit();
        assertTrue(usdc.balanceOf(address(pool)) < maxLiab, "Vault should be insolvent");

        // Price rises to $1.10 — BULL loses $20k, deeply underwater
        engine.liquidatePosition(aliceId, 1.1e8, vaultDepth);

        (uint256 aliceSize,,,,,,) = engine.positions(aliceId);
        assertEq(aliceSize, 0, "Liquidation must succeed during insolvency");
    }

    function test_Liquidate_EmptyPosition_Reverts() public {
        bytes32 accountId = bytes32(uint256(1));
        vm.expectRevert(CfdEngine.CfdEngine__NoPositionToLiquidate.selector);
        engine.liquidatePosition(accountId, 1e8, 1_000_000 * 1e6);
    }

}
