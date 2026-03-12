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

contract AuditCurrentFindingsFailing is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function test_C3_RealizedBadDebtShouldNotBeDoubleCounted() public {
        address winner = address(0xAAA1);
        address loser = address(0xBBB1);
        bytes32 winnerId = bytes32(uint256(uint160(winner)));
        bytes32 loserId = bytes32(uint256(uint160(loser)));

        _fundTrader(winner, 200_000e6);
        _fundTrader(loser, 2000e6);

        _open(winnerId, CfdTypes.Side.BULL, 100_000e18, 100_000e6, 1.5e8);
        _open(loserId, CfdTypes.Side.BULL, 100_000e18, 1000e6, 0.5e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(loserId, 1e8, depth, uint64(block.timestamp));

        uint256 price = engine.lastMarkPrice();
        int256 bullPnl = (int256(engine.globalBullEntryNotional()) - int256(engine.bullOI() * price)) / int256(1e20);
        int256 bearPnl = (int256(engine.bearOI() * price) - int256(engine.globalBearEntryNotional())) / int256(1e20);

        int256 expectedMtm = 0;
        if (bullPnl > 0) {
            expectedMtm += bullPnl;
        }
        if (bearPnl > 0) {
            expectedMtm += bearPnl;
        }

        assertEq(engine.getVaultMtmAdjustment(), expectedMtm, "Realized bad debt should already be priced into MtM");
    }

    function test_H1_UpdateMarkPriceMustRejectOlderPublishTime() public {
        vm.prank(address(router));
        engine.updateMarkPrice(1.1e8, uint64(block.timestamp));

        vm.prank(address(router));
        vm.expectRevert(CfdEngine.CfdEngine__MarkPriceOutOfOrder.selector);
        engine.updateMarkPrice(1.0e8, uint64(block.timestamp - 30));
    }

    function test_H2_SeniorHighWaterMarkMustSurviveFullWipeout() public {
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 100_000e6);

        uint256 total = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), total);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertGt(pool.seniorHighWaterMark(), 0, "Senior recovery rights should survive wipeout");
    }

}

contract AuditCurrentFindingsFailing_BountyCap is BasePerpTest {

    bytes32 internal constant ACCOUNT_ID = bytes32(uint256(1234));

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 10,
            fadMarginBps: 1000,
            minBountyUsdc: 1e6,
            bountyBps: 1000
        });
    }

    function test_M2_KeeperBountyShouldUsePositiveEquityNotPositionMargin() public {
        address trader = address(uint160(uint256(ACCOUNT_ID)));
        _fundTrader(trader, 100e6);

        _open(ACCOUNT_ID, CfdTypes.Side.BULL, 100e18, 6e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(ACCOUNT_ID, address(usdc), 94e6);

        vm.warp(1_709_971_200); // Saturday during FAD
        uint256 depth = pool.totalAssets();

        vm.prank(address(router));
        uint256 bounty = engine.liquidatePosition(ACCOUNT_ID, 1.01e8, depth, uint64(block.timestamp));

        assertEq(bounty, 4_940_000, "Keeper bounty should be capped by positive equity, not initial margin");
    }

}

contract AuditCurrentFindingsVerifiedInvalid is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function test_C2_ZeroSizeMarginUpdateRejectedAtCommit() public {
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert();
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 0, 500e6, 1e8, false);
    }

    function test_M1_WipedTrancheCanBeRecapitalized() public {
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 100_000e6);

        uint256 total = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), total);

        vm.prank(address(juniorVault));
        pool.reconcile();

        address recapLp = address(0xCAFE);
        usdc.mint(recapLp, 10_000e6);

        vm.startPrank(recapLp);
        usdc.approve(address(seniorVault), type(uint256).max);
        seniorVault.deposit(10_000e6, recapLp);
        vm.stopPrank();

        assertGt(pool.seniorPrincipal(), 0, "Wiped tranche should accept recapitalization");
    }

}

contract AuditCurrentFindingsVerifiedInvalid_Mev is BasePerpTest {

    MockPyth mockPyth;
    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;
    address alice = address(0xA11CE);

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
        vm.deal(alice, 10 ether);
    }

    function test_C1_FreshPriceAfterCommitIsAllowed() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1006);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 1006);

        vm.warp(1006);
        vm.roll(block.number + 1);
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";
        router.executeOrder(1, updateData);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertGt(size, 0, "Fresh price after commit should execute");
    }

}

contract AuditCurrentFindingsFuturePublishSafety is BasePerpTest {

    address alice = address(0xA11CE);

    function test_FutureLastMarkTime_DoesNotBreakWithdrawGuardOrReconcile() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        _fundSenior(address(0xBEEF), 100_000e6);
        _fundTrader(alice, 50_000e6);
        _open(aliceId, CfdTypes.Side.BULL, 20_000e18, 5000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp + 5));

        engine.checkWithdraw(aliceId);

        vm.prank(address(juniorVault));
        pool.reconcile();
    }

}
