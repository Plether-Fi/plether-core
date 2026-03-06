// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {Test, console} from "forge-std/Test.sol";

contract CfdEngineTest is Test {

    CfdEngine engine;
    uint256 constant CAP_PRICE = 2e8; // $2.00

    function setUp() public {
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

        engine = new CfdEngine(CAP_PRICE, params);

        // Mock the OrderRouter to be this test contract
        engine.setOrderRouter(address(this));
    }

    function test_OpenPosition_SolvencyCheck() public {
        CfdTypes.Order memory order = CfdTypes.Order({
            accountId: bytes32(uint256(1)),
            sizeDelta: 100_000 * 1e18, // 100k Size
            marginDelta: 2000 * 1e6, // $2k margin
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });

        // Try to open 100k BULL with only $50k in the vault
        // Max theoretical liability is $100k. It MUST REVERT.
        vm.expectRevert("CfdEngine: Vault Solvency Capacity Exceeded");
        engine.processOrder(order, 1e8, 50_000 * 1e6);

        // With $200k in the vault, it safely succeeds
        int256 settlement = engine.processOrder(order, 1e8, 200_000 * 1e6);

        // User pays margin, so settlement must be < 0
        assertEq(settlement, -int256(2000 * 1e6), "Settlement should pull exact margin");

        (uint256 size, uint256 margin,,,,) = engine.positions(bytes32(uint256(1)));
        assertEq(size, 100_000 * 1e18, "Size mismatch");
        assertTrue(margin < 2000 * 1e6, "Margin should be reduced by VPI and fees");
    }

    function test_FundingAccumulation() public {
        uint256 vaultDepth = 1_000_000 * 1e6; // $1M vault

        // 1. Retail opens massive BULL position (Creates SKEW)
        CfdTypes.Order memory retailLong = CfdTypes.Order({
            accountId: bytes32(uint256(1)),
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        engine.processOrder(retailLong, 1e8, vaultDepth);

        // 2. Fast forward 30 days
        vm.warp(block.timestamp + 30 days);

        // 3. Market Maker opens BEAR position to trigger the lazy funding update
        CfdTypes.Order memory mmShort = CfdTypes.Order({
            accountId: bytes32(uint256(2)),
            sizeDelta: 10_000 * 1e18,
            marginDelta: 500 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            orderId: 2,
            side: CfdTypes.Side.BEAR,
            isClose: false
        });
        engine.processOrder(mmShort, 1e8, vaultDepth);

        // BULL index should be NEGATIVE (they paid for creating the skew)
        int256 bullIndex = engine.bullFundingIndex();
        assertTrue(bullIndex < 0, "BULL index should decrease");

        // BEAR index should be POSITIVE (they received a subsidy for healing the skew)
        int256 bearIndex = engine.bearFundingIndex();
        assertTrue(bearIndex > 0, "BEAR index should increase");

        // Check BULL pending funding PnL
        (uint256 size,, uint256 entryPrice, int256 entryFunding, CfdTypes.Side side,) =
            engine.positions(bytes32(uint256(1)));

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

}
