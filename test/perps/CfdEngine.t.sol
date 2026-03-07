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
        usdc.mint(address(this), amount);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, address(usdc), amount);
    }

    function test_OpenPosition_SolvencyCheck() public {
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

        // Withdraw LP to reduce vault to $50k — solvency check should fail
        juniorVault.withdraw(950_000 * 1e6, address(this), address(this));
        vm.expectRevert("CfdEngine: Vault Solvency Capacity Exceeded");
        engine.processOrder(order, 1e8, 0);

        // Re-deposit to allow the trade
        usdc.approve(address(juniorVault), 950_000 * 1e6);
        juniorVault.deposit(950_000 * 1e6, address(this));

        int256 settlement = engine.processOrder(order, 1e8, 200_000 * 1e6);
        assertEq(settlement, 0, "processOrder always returns 0");

        (uint256 size, uint256 margin,,,,) = engine.positions(accountId);
        assertEq(size, 100_000 * 1e18, "Size mismatch");
        assertTrue(margin < 2000 * 1e6, "Margin should be reduced by VPI and fees");
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

        (uint256 size,, uint256 entryPrice, int256 entryFunding, CfdTypes.Side side,) = engine.positions(account1);

        CfdTypes.Position memory bullPos = CfdTypes.Position({
            size: size,
            margin: 0,
            entryPrice: entryPrice,
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

        (, uint256 marginAfterOpen,,,,) = engine.positions(accountId);
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

        (, uint256 marginAfterAdd,,,,) = engine.positions(accountId);
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

        uint256 fees = engine.accumulatedFeesUsdc();
        assertTrue(fees > 0, "Fees should accrue after trade");

        address treasury = address(0xBEEF);
        engine.withdrawFees(treasury);

        assertEq(engine.accumulatedFeesUsdc(), 0, "Fees should reset to zero");
        assertEq(usdc.balanceOf(treasury), fees, "Treasury receives exact fee amount");

        vm.expectRevert("CfdEngine: No fees to withdraw");
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
        vm.expectRevert("CfdEngine: Must explicitly close opposing position first");
        engine.processOrder(bullOrder, 0.8e8, 1_000_000 * 1e6);
    }

    function test_FundingSettlement_PartialMarginDrain() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _depositToClearinghouse(accountId, 5000 * 1e6);

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 500 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        engine.processOrder(openOrder, 1e8, vaultDepth);

        (, uint256 marginAfterOpen,,,,) = engine.positions(accountId);

        // Warp long enough for funding to exceed margin
        vm.warp(block.timestamp + 365 days);

        // Add to position — triggers funding settlement
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
        engine.processOrder(addOrder, 1e8, vaultDepth);

        // Margin should have been drained by funding but not go negative
        (, uint256 marginAfterSettle,,,,) = engine.positions(accountId);
        // The funding loss was larger than original margin, so after settlement
        // pos.margin was capped at 0, then new margin added
        assertTrue(marginAfterSettle < marginAfterOpen + 1000 * 1e6, "Margin should reflect funding drain");
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

        (,, uint256 entryAfterFirst,,,) = engine.positions(accountId);
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

        (uint256 totalSize,, uint256 avgEntry,,,) = engine.positions(accountId);
        assertEq(totalSize, 40_000 * 1e18, "Total size should be 40k");
        assertEq(avgEntry, 1.1e8, "Weighted avg entry should be $1.10");
    }

}
