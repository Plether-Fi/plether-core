// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AuditConfirmedFindingsFailing_StaleKeeperFee is BasePerpTest {

    MockPyth mockPyth;
    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;
    address alice = address(0xA11CE);
    address keeper = address(0xBEEF);

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
        pool = new HousePool(address(usdc), address(engine));

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router =
            new OrderRouter(address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _fundJunior(address(this), 1_000_000e6);
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 1 ether);
        vm.deal(keeper, 1 ether);
    }

    function test_C1_BatchExecuteShouldRefundUserNotKeeper() public {
        uint256 t0 = 2_000_000_000;
        vm.warp(t0);
        vm.roll(100);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), t0);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), t0);

        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);

        vm.warp(t0 + 61);
        vm.roll(200);
        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), t0 + 61);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), t0 + 61);

        uint256 keeperBalanceBefore = keeper.balance;

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.prank(keeper);
        router.executeOrderBatch(1, updateData);

        assertEq(keeper.balance, keeperBalanceBefore, "Keeper should not profit from expired orders in batch execution");
        assertEq(alice.balance, 1 ether, "User should be refunded keeper fee on expired batch order");
    }

    function test_C1_BatchMixedSuccessOnlyPaysKeeperForSuccessful() public {
        _fundTrader(alice, 50_000e6);

        uint256 t0 = 2_000_000_000;

        vm.warp(t0);
        vm.roll(100);
        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), t0);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), t0);

        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);

        vm.warp(t0 + 10);
        vm.roll(200);
        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), t0 + 10);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), t0 + 10);

        vm.prank(alice);
        router.commitOrder{value: 0.02 ether}(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);

        vm.warp(t0 + 61);
        vm.roll(300);
        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), t0 + 61);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), t0 + 61);

        uint256 aliceBefore = alice.balance;
        uint256 keeperBalanceBefore = keeper.balance;

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.prank(keeper);
        router.executeOrderBatch(2, updateData);

        assertEq(keeper.balance - keeperBalanceBefore, 0.02 ether, "Keeper only paid for the successful order");
        assertEq(alice.balance - aliceBefore, 0.01 ether, "User refunded fee from the expired order");
    }

    function test_C1_StaleSingleExecuteShouldRefundUserNotKeeper() public {
        vm.warp(1000);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1000);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 900);

        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        uint256 keeperBalanceBefore = keeper.balance;

        vm.warp(1001);
        vm.roll(block.number + 1);
        vm.prank(keeper);
        router.executeOrder(1, updateData);

        assertEq(keeper.balance, keeperBalanceBefore, "Keeper should not collect fee when cancelling a stale order");
    }

}

contract AuditConfirmedFindingsFailing_TrancheCooldownGrief is BasePerpTest {

    address alice = address(0xA11CE);
    address attacker = address(0xBAD);

    function test_H1_ThirdPartyDustDepositMustNotResetVictimCooldown() public {
        _fundJunior(alice, 100_000e6);

        vm.warp(block.timestamp + 50 minutes);

        usdc.mint(attacker, 1);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), 1);
        juniorVault.deposit(1, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 11 minutes);
        vm.prank(alice);
        juniorVault.withdraw(100_000e6, alice, alice);

        assertEq(usdc.balanceOf(alice), 100_000e6, "Victim should be able to withdraw after their original cooldown");
    }

}

contract AuditConfirmedFindingsFailing_RiskParams is BasePerpTest {

    function test_M1_ProposeRiskParamsRejectsEqualKinkAndMaxSkew() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.maxSkewRatio = params.kinkSkewRatio;

        vm.expectRevert();
        engine.proposeRiskParams(params);
    }

    function test_M1_ProposeRiskParamsRejectsZeroKinkSkew() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.kinkSkewRatio = 0;

        vm.expectRevert();
        engine.proposeRiskParams(params);
    }

    function test_M1_ProposeRiskParamsRejectsKinkAboveMaxSkew() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.kinkSkewRatio = params.maxSkewRatio + 1;

        vm.expectRevert();
        engine.proposeRiskParams(params);
    }

}

contract AuditConfirmedFindingsFailing_FundingReserve is BasePerpTest {

    address bullTrader = address(0xB011);
    address bearTrader = address(0xBEA2);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 1e18,
            maxApy: 5e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_C2_GetFreeUsdcMustReserveCappedFundingLiability() public {
        _fundJunior(address(this), 1_000_000e6);

        _fundTrader(bullTrader, 20_000e6);
        _fundTrader(bearTrader, 100_000e6);

        bytes32 bullId = bytes32(uint256(uint160(bullTrader)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));

        _open(bullId, CfdTypes.Side.BULL, 400_000e18, 10_000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        vm.warp(block.timestamp + 180 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        (
            uint256 bullSize,
            uint256 bullMargin,
            uint256 bullEntryPrice,,
            int256 bullEntryFunding,
            CfdTypes.Side bullSide,,
        ) = engine.positions(bullId);
        (
            uint256 bearSize,
            uint256 bearMargin,
            uint256 bearEntryPrice,,
            int256 bearEntryFunding,
            CfdTypes.Side bearSide,,
        ) = engine.positions(bearId);

        CfdTypes.Position memory bullPos = CfdTypes.Position({
            size: bullSize,
            margin: bullMargin,
            entryPrice: bullEntryPrice,
            maxProfitUsdc: 0,
            entryFundingIndex: bullEntryFunding,
            side: bullSide,
            lastUpdateTime: 0,
            vpiAccrued: 0
        });
        CfdTypes.Position memory bearPos = CfdTypes.Position({
            size: bearSize,
            margin: bearMargin,
            entryPrice: bearEntryPrice,
            maxProfitUsdc: 0,
            entryFundingIndex: bearEntryFunding,
            side: bearSide,
            lastUpdateTime: 0,
            vpiAccrued: 0
        });

        int256 bullFunding = engine.getPendingFunding(bullPos);
        int256 bearFunding = engine.getPendingFunding(bearPos);
        assertLt(bullFunding, -int256(bullMargin), "Setup must make bull funding debt exceed backing margin");
        assertGt(bearFunding, 0, "Setup must leave the bear side owed funding");

        int256 cappedFunding = -int256(bullMargin) + bearFunding;
        assertGt(cappedFunding, 0, "Capped net funding should expose reserve deficit");

        uint256 bal = usdc.balanceOf(address(pool));
        uint256 maxLiability = engine.globalBullMaxProfit();
        uint256 pendingFees = engine.accumulatedFeesUsdc();
        uint256 expectedReserved = maxLiability + pendingFees + uint256(cappedFunding);
        uint256 expectedFree = bal > expectedReserved ? bal - expectedReserved : 0;

        assertEq(
            pool.getFreeUSDC(),
            expectedFree,
            "Free USDC should reserve capped funding liabilities, not uncapped net funding"
        );
    }

}

contract AuditConfirmedFindingsFailing_EntryNotionalRounding is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 0,
            bountyBps: 15
        });
    }

    function test_H2_ScalingLargePositionWithDustIncreaseMustNotUnderflow() public {
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 10_000e6);

        vm.startPrank(address(router));
        engine.processOrder(
            CfdTypes.Order({
                accountId: accountId,
                sizeDelta: 1000e18,
                marginDelta: 2000e6,
                targetPrice: 150_000_001,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 1,
                side: CfdTypes.Side.BULL,
                isClose: false
            }),
            150_000_001,
            pool.totalAssets(),
            uint64(block.timestamp)
        );

        engine.processOrder(
            CfdTypes.Order({
                accountId: accountId,
                sizeDelta: 1,
                marginDelta: 0,
                targetPrice: 150_000_000,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 2,
                side: CfdTypes.Side.BULL,
                isClose: false
            }),
            150_000_000,
            pool.totalAssets(),
            uint64(block.timestamp)
        );
        vm.stopPrank();

        (uint256 sizeAfter,,,,,,,) = engine.positions(accountId);
        assertEq(sizeAfter, 1000e18 + 1, "Dust increase should succeed without arithmetic underflow");
    }

}
