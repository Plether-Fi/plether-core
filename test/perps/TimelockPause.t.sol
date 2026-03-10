// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
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

contract TimelockPauseTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault seniorVault;
    TrancheVault juniorVault;
    OrderRouter router;
    MarginClearinghouse clearinghouse;

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address nonOwner = address(0xBAD);

    receive() external payable {}

    function setUp() public {
        usdc = new MockUSDC();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        clearinghouse = new MarginClearinghouse();

        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        vm.warp(48 hours + 1);
        clearinghouse.finalizeAssetConfig();

        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Senior", "sUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior", "jUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        router = new OrderRouter(
            address(engine),
            address(pool),
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        );

        clearinghouse.proposeWithdrawGuard(address(engine));
        clearinghouse.proposeOperator(address(engine), true);
        vm.warp(96 hours + 2);
        clearinghouse.finalizeWithdrawGuard();
        clearinghouse.finalizeOperator();

        clearinghouse.proposeOperator(address(router), true);
        vm.warp(144 hours + 3);
        clearinghouse.finalizeOperator();

        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        usdc.mint(address(this), 1_000_000 * 1e6);
        usdc.approve(address(juniorVault), type(uint256).max);
        juniorVault.deposit(500_000 * 1e6, address(this));
        usdc.approve(address(seniorVault), type(uint256).max);
        seniorVault.deposit(500_000 * 1e6, address(this));

        usdc.mint(alice, 50_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(bytes32(uint256(uint160(alice))), address(usdc), 50_000 * 1e6);
        vm.deal(alice, 10 ether);
        vm.stopPrank();
    }

    function _currentTimestamp() internal view returns (uint256 ts) {
        assembly {
            ts := timestamp()
        }
    }

    function _warpForward(
        uint256 delta
    ) internal {
        vm.warp(_currentTimestamp() + delta);
    }

    // ==========================================
    // CfdEngine TIMELOCK TESTS
    // ==========================================

    function test_ProposeRiskParams_StoresAndSetsActivationTime() public {
        CfdTypes.RiskParams memory newParams = CfdTypes.RiskParams({
            vpiFactor: 0.001e18,
            maxSkewRatio: 0.5e18,
            kinkSkewRatio: 0.3e18,
            baseApy: 0.2e18,
            maxApy: 4e18,
            maintMarginBps: 200,
            fadMarginBps: 500,
            minBountyUsdc: 10 * 1e6,
            bountyBps: 20
        });

        engine.proposeRiskParams(newParams);
        assertGt(engine.riskParamsActivationTime(), 0);
    }

    function test_FinalizeRiskParams_BeforeTimelock_Reverts() public {
        CfdTypes.RiskParams memory newParams = CfdTypes.RiskParams({
            vpiFactor: 0.001e18,
            maxSkewRatio: 0.5e18,
            kinkSkewRatio: 0.3e18,
            baseApy: 0.2e18,
            maxApy: 4e18,
            maintMarginBps: 200,
            fadMarginBps: 500,
            minBountyUsdc: 10 * 1e6,
            bountyBps: 20
        });

        engine.proposeRiskParams(newParams);

        vm.expectRevert(CfdEngine.CfdEngine__TimelockNotReady.selector);
        engine.finalizeRiskParams();
    }

    function test_FinalizeRiskParams_AfterTimelock_Succeeds() public {
        CfdTypes.RiskParams memory newParams = CfdTypes.RiskParams({
            vpiFactor: 0.001e18,
            maxSkewRatio: 0.5e18,
            kinkSkewRatio: 0.3e18,
            baseApy: 0.2e18,
            maxApy: 4e18,
            maintMarginBps: 200,
            fadMarginBps: 500,
            minBountyUsdc: 10 * 1e6,
            bountyBps: 20
        });

        engine.proposeRiskParams(newParams);
        _warpForward(48 hours + 1);
        engine.finalizeRiskParams();

        (,,,,, uint256 maintMarginBps,,,) = engine.riskParams();
        assertEq(maintMarginBps, 200);
        assertEq(engine.riskParamsActivationTime(), 0);
    }

    function test_FinalizeRiskParams_NoProposal_Reverts() public {
        vm.expectRevert(CfdEngine.CfdEngine__NoProposal.selector);
        engine.finalizeRiskParams();
    }

    function test_CancelRiskParams_ClearsPending() public {
        CfdTypes.RiskParams memory newParams = CfdTypes.RiskParams({
            vpiFactor: 0.001e18,
            maxSkewRatio: 0.5e18,
            kinkSkewRatio: 0.3e18,
            baseApy: 0.2e18,
            maxApy: 4e18,
            maintMarginBps: 200,
            fadMarginBps: 500,
            minBountyUsdc: 10 * 1e6,
            bountyBps: 20
        });

        engine.proposeRiskParams(newParams);
        engine.cancelRiskParamsProposal();
        assertEq(engine.riskParamsActivationTime(), 0);

        vm.expectRevert(CfdEngine.CfdEngine__NoProposal.selector);
        engine.finalizeRiskParams();
    }

    function test_ProposeRiskParams_OnlyOwner() public {
        CfdTypes.RiskParams memory newParams = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        engine.proposeRiskParams(newParams);
    }

    function test_RePropose_OverwritesPendingAndResetsTimer() public {
        CfdTypes.RiskParams memory first = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 200,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        engine.proposeRiskParams(first);
        uint256 firstActivation = engine.riskParamsActivationTime();

        _warpForward(24 hours);

        CfdTypes.RiskParams memory second = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 300,
            fadMarginBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        engine.proposeRiskParams(second);
        uint256 secondActivation = engine.riskParamsActivationTime();

        assertGt(secondActivation, firstActivation);
    }

    // ==========================================
    // HousePool TIMELOCK TESTS
    // ==========================================

    function test_ProposeSeniorRate_TimelockFlow() public {
        pool.proposeSeniorRate(1200);
        assertGt(pool.seniorRateActivationTime(), 0);

        vm.expectRevert(HousePool.HousePool__TimelockNotReady.selector);
        pool.finalizeSeniorRate();

        _warpForward(48 hours + 1);
        pool.finalizeSeniorRate();

        assertEq(pool.seniorRateBps(), 1200);
        assertEq(pool.seniorRateActivationTime(), 0);
    }

    function test_ProposeMarkStalenessLimit_TimelockFlow() public {
        pool.proposeMarkStalenessLimit(60);
        assertGt(pool.markStalenessLimitActivationTime(), 0);

        vm.expectRevert(HousePool.HousePool__TimelockNotReady.selector);
        pool.finalizeMarkStalenessLimit();

        _warpForward(48 hours + 1);
        pool.finalizeMarkStalenessLimit();

        assertEq(pool.markStalenessLimit(), 60);
        assertEq(pool.markStalenessLimitActivationTime(), 0);
    }

    function test_FinalizeSeniorRate_NoProposal_Reverts() public {
        vm.expectRevert(HousePool.HousePool__NoProposal.selector);
        pool.finalizeSeniorRate();
    }

    function test_CancelSeniorRate_ClearsPending() public {
        pool.proposeSeniorRate(1500);
        pool.cancelSeniorRateProposal();
        assertEq(pool.seniorRateActivationTime(), 0);
    }

    // ==========================================
    // OrderRouter TIMELOCK TESTS
    // ==========================================

    function test_ProposeMaxOrderAge_TimelockFlow() public {
        router.proposeMaxOrderAge(600);

        vm.expectRevert(OrderRouter.OrderRouter__TimelockNotReady.selector);
        router.finalizeMaxOrderAge();

        _warpForward(48 hours + 1);
        router.finalizeMaxOrderAge();

        assertEq(router.maxOrderAge(), 600);
        assertEq(router.maxOrderAgeActivationTime(), 0);
    }

    function test_ProposeMinKeeperFee_TimelockFlow() public {
        router.proposeMinKeeperFee(0.001 ether);

        vm.expectRevert(OrderRouter.OrderRouter__TimelockNotReady.selector);
        router.finalizeMinKeeperFee();

        _warpForward(48 hours + 1);
        router.finalizeMinKeeperFee();

        assertEq(router.minKeeperFee(), 0.001 ether);
    }

    function test_FinalizeMaxOrderAge_NoProposal_Reverts() public {
        vm.expectRevert(OrderRouter.OrderRouter__NoProposal.selector);
        router.finalizeMaxOrderAge();
    }

    function test_OrderRouter_OnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        router.proposeMaxOrderAge(600);
    }

    // ==========================================
    // MarginClearinghouse TIMELOCK TESTS
    // ==========================================

    function test_ProposeOperator_TimelockFlow() public {
        address newOp = address(0xCCC);
        clearinghouse.proposeOperator(newOp, true);

        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__TimelockNotReady.selector);
        clearinghouse.finalizeOperator();

        _warpForward(48 hours + 1);
        clearinghouse.finalizeOperator();

        assertTrue(clearinghouse.isProtocolOperator(newOp));
        assertEq(clearinghouse.operatorActivationTime(), 0);
    }

    function test_ProposeWithdrawGuard_TimelockFlow() public {
        address newGuard = address(0xDDD);
        clearinghouse.proposeWithdrawGuard(newGuard);

        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__TimelockNotReady.selector);
        clearinghouse.finalizeWithdrawGuard();

        _warpForward(48 hours + 1);
        clearinghouse.finalizeWithdrawGuard();

        assertEq(address(clearinghouse.withdrawGuard()), newGuard);
    }

    function test_ProposeAssetConfig_TimelockFlow() public {
        address newAsset = address(0xEEE);
        clearinghouse.proposeAssetConfig(newAsset, 18, 9000, address(0));

        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__TimelockNotReady.selector);
        clearinghouse.finalizeAssetConfig();

        _warpForward(48 hours + 1);
        clearinghouse.finalizeAssetConfig();

        (bool supported,,,) = clearinghouse.assetConfigs(newAsset);
        assertTrue(supported);
    }

    function test_ProposeAssetConfig_InvalidLTV_Reverts() public {
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InvalidLTV.selector);
        clearinghouse.proposeAssetConfig(address(0xFFF), 18, 10_001, address(0));
    }

    function test_CancelOperatorProposal_ClearsPending() public {
        clearinghouse.proposeOperator(address(0xCCC), true);
        clearinghouse.cancelOperatorProposal();
        assertEq(clearinghouse.operatorActivationTime(), 0);

        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NoProposal.selector);
        clearinghouse.finalizeOperator();
    }

    // ==========================================
    // PAUSE TESTS — OrderRouter
    // ==========================================

    function test_CommitOrder_RevertsWhenPaused() public {
        router.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
    }

    function test_ExecuteOrder_WorksWhenPaused() public {
        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        router.pause();

        bytes[] memory empty;
        router.executeOrder(1, empty);
        assertEq(router.nextExecuteId(), 2);
    }

    function test_ExecuteLiquidation_WorksWhenPaused() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);

        bytes[] memory empty;
        router.executeOrder(1, empty);

        router.pause();

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(1.98e8);

        router.executeLiquidation(accountId, pythData);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0);
    }

    function test_UpdateMarkPrice_WorksWhenPaused() public {
        router.pause();

        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(1.05e8);
        router.updateMarkPrice(pythData);

        assertEq(engine.lastMarkPrice(), 1.05e8);
    }

    function test_Pause_OnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        router.pause();
    }

    function test_Unpause_RestoresCommitOrder() public {
        router.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        router.unpause();

        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        assertEq(router.nextCommitId(), 2);
    }

    // ==========================================
    // PAUSE TESTS — HousePool
    // ==========================================

    function test_DepositSenior_RevertsWhenHousePoolPaused() public {
        pool.pause();

        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(seniorVault), 10_000 * 1e6);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        seniorVault.deposit(10_000 * 1e6, alice);
        vm.stopPrank();
    }

    function test_DepositJunior_RevertsWhenHousePoolPaused() public {
        pool.pause();

        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(juniorVault), 10_000 * 1e6);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        juniorVault.deposit(10_000 * 1e6, alice);
        vm.stopPrank();
    }

    function test_WithdrawSenior_WorksWhenHousePoolPaused() public {
        _warpForward(1 hours);
        pool.pause();

        uint256 maxW = seniorVault.maxWithdraw(address(this));
        if (maxW > 0) {
            seniorVault.withdraw(maxW, address(this), address(this));
        }
    }

    function test_WithdrawJunior_WorksWhenHousePoolPaused() public {
        _warpForward(1 hours);
        pool.pause();

        uint256 maxW = juniorVault.maxWithdraw(address(this));
        if (maxW > 0) {
            juniorVault.withdraw(maxW, address(this), address(this));
        }
    }

    function test_HousePool_Pause_OnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        pool.pause();
    }

    function test_HousePool_Unpause_RestoresDeposits() public {
        pool.pause();

        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(juniorVault), 10_000 * 1e6);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        juniorVault.deposit(10_000 * 1e6, alice);
        vm.stopPrank();

        pool.unpause();

        vm.prank(alice);
        juniorVault.deposit(10_000 * 1e6, alice);
        assertGt(juniorVault.balanceOf(alice), 0);
    }

}
