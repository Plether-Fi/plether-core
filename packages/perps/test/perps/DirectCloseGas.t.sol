// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdEnginePlanner} from "@plether/perps/CfdEnginePlanner.sol";
import {CfdEngineSettlementSidecar} from "@plether/perps/CfdEngineSettlementSidecar.sol";
import {CfdOrderPolicyEvaluator} from "@plether/perps/CfdOrderPolicyEvaluator.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {HousePoolRedemptionMathSidecar} from "@plether/perps/HousePoolRedemptionMathSidecar.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderLifecycleBook} from "@plether/perps/OrderLifecycleBook.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderRouterLiquidationBatchSidecar} from "@plether/perps/OrderRouterLiquidationBatchSidecar.sol";
import {OrderRouterV2ExecutionSidecar} from "@plether/perps/OrderRouterV2ExecutionSidecar.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Direct production Router benchmarks; no LegacyOrderRouterHarness is deployed.
///      Requests and oracle data are constructed before measurement. Public lifecycle setup runs in setUp,
///      including commitment for execution fixtures, so measured writes start from committed fixture state.
///      Protocol accounts and storage are explicitly cooled after request construction. Gas is call-level EVM
///      consumption, before transaction refunds, intrinsic/calldata gas, and L1 publication/oracle service fees.
abstract contract DirectCloseGasFixture is Test {

    uint256 internal constant PRICE = 1e8;
    uint256 internal constant SIZE = 10_000e18;
    uint256 internal constant START_TIME = 1_709_532_000;
    address internal constant ACCOUNT = address(0xA11CE);
    address internal constant KEEPER = address(0xB0B);
    bytes32 internal constant FEED = bytes32(uint256(1));

    MockUSDC internal usdc;
    MockPyth internal pyth;
    MarginClearinghouse internal clearinghouse;
    CfdEngine internal engine;
    HousePool internal pool;
    OrderRouter internal router;
    address[] internal measuredAccounts;
    uint64 internal closeOrderId;

    function setUp() public virtual {
        vm.warp(START_TIME);
        usdc = new MockUSDC();
        measuredAccounts.push(address(usdc));
        clearinghouse = new MarginClearinghouse(address(usdc));
        measuredAccounts.push(address(clearinghouse));
        CfdTypes.RiskParams memory risk = CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: 150,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
        engine = new CfdEngine(address(usdc), address(clearinghouse), 2e8, risk, 50);
        measuredAccounts.push(address(engine));
        CfdEnginePlanner planner = new CfdEnginePlanner();
        measuredAccounts.push(address(planner));
        CfdEngineSettlementSidecar settlement = new CfdEngineSettlementSidecar(address(engine));
        measuredAccounts.push(address(settlement));
        CfdEngineAdmin engineAdmin = new CfdEngineAdmin(address(engine), address(this));
        measuredAccounts.push(address(engineAdmin));
        engine.setDependencies(address(planner), address(settlement), address(engineAdmin));
        TerminalNavBookV2 terminalBook = new TerminalNavBookV2(address(engine), uint32(2e8));
        measuredAccounts.push(address(terminalBook));
        engine.setTerminalNavBook(address(terminalBook));
        CfdEngineLens lens = new CfdEngineLens(address(engine));
        measuredAccounts.push(address(lens));
        HousePoolRedemptionMathSidecar poolMath = new HousePoolRedemptionMathSidecar();
        measuredAccounts.push(address(poolMath));
        pool = new HousePool(address(usdc), address(engine), address(poolMath));
        measuredAccounts.push(address(pool));
        TrancheVault senior = new TrancheVault(usdc, address(pool), true, "Senior", "sUSDC", 0, address(0));
        measuredAccounts.push(address(senior));
        TrancheVault junior = new TrancheVault(usdc, address(pool), false, "Junior", "jUSDC", 0, address(0));
        measuredAccounts.push(address(junior));
        pool.setSeniorVault(address(senior));
        pool.setJuniorVault(address(junior));
        engine.setPool(address(pool));
        pyth = new MockPyth();
        measuredAccounts.push(address(pyth));
        bytes32[] memory feeds = _feeds();
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1e18;
        uint256[] memory bases = new uint256[](1);
        bases[0] = PRICE;
        PletherOracle oracle =
            new PletherOracle(address(engine), address(pool), address(pyth), feeds, weights, bases, new bool[](1));
        measuredAccounts.push(address(oracle));
        CfdOrderPolicyEvaluator evaluator = new CfdOrderPolicyEvaluator();
        measuredAccounts.push(address(evaluator));
        OrderRouterV2ExecutionSidecar execution = new OrderRouterV2ExecutionSidecar();
        measuredAccounts.push(address(execution));
        address predictedRouter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        OrderLifecycleBook lifecycle =
            new OrderLifecycleBook(predictedRouter, address(engine), address(clearinghouse), address(pool));
        measuredAccounts.push(address(lifecycle));
        OrderRouterLiquidationBatchSidecar liquidation = new OrderRouterLiquidationBatchSidecar(predictedRouter);
        measuredAccounts.push(address(liquidation));
        router = new OrderRouter(
            address(engine),
            address(lens),
            address(pool),
            address(oracle),
            address(liquidation),
            address(evaluator),
            address(execution),
            address(lifecycle)
        );
        measuredAccounts.push(address(router));
        assertEq(address(router), predictedRouter);
        engine.setOrderRouter(address(router));
        clearinghouse.setEngine(address(engine));
        IHousePool.PoolConfig memory config = IHousePool.PoolConfig({
            seniorRateBps: pool.seniorRateBps(),
            markStalenessLimit: pool.markStalenessLimit(),
            seniorFrozenLpFeeBps: pool.seniorFrozenLpFeeBps(),
            juniorFrozenLpFeeBps: pool.juniorFrozenLpFeeBps(),
            maxSeniorExposureUsdc: type(uint256).max - 1,
            maxSeniorShareBps: 9999
        });
        pool.proposePoolConfig(config);
        vm.warp(pool.poolConfigActivationTime());
        pool.finalizePoolConfig();
        vm.warp(START_TIME);
        usdc.mint(address(this), 1_002_000e6);
        usdc.approve(address(pool), 2000e6);
        pool.initializeSeedPosition(false, 1000e6, address(this));
        pool.initializeSeedPosition(true, 1000e6, address(this));
        pool.activateTrading();
        usdc.approve(address(junior), 1_000_000e6);
        uint256 depositId = junior.requestDeposit(1_000_000e6, address(this), address(this));
        vm.warp(junior.depositEpochStart(depositId));
        pool.settleLpEpoch(0, 0);
        junior.claimDeposit(depositId, 1_000_000e6, address(this), address(this));
        // The opening, reserve, and withdrawal all use public lifecycle entry points.
        usdc.mint(ACCOUNT, 1000e6);
        vm.startPrank(ACCOUNT);
        usdc.approve(address(clearinghouse), 1000e6);
        clearinghouse.deposit(ACCOUNT, 1000e6);
        vm.stopPrank();
        OrderV2Types.OrderRequest memory openRequest = _request(false);
        vm.prank(ACCOUNT);
        uint64 openId = router.commitOrder(openRequest);
        bytes[] memory update = _updateData();
        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(openId, update);
        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Executed));
        uint256 free = clearinghouse.getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc;
        vm.prank(ACCOUNT);
        clearinghouse.withdraw(ACCOUNT, free);
        vm.warp(vm.getBlockTimestamp() + 30);
        assertEq(clearinghouse.getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc, 0);
        measuredAccounts.push(router.admin());
        measuredAccounts.push(address(router.positionProtectionBook()));
    }

    function _closeSize() internal pure virtual returns (uint256) {
        return SIZE;
    }

    function _callerPaid() internal pure virtual returns (bool) {
        return false;
    }

    function _scenario() internal pure virtual returns (string memory) {
        return "standard_full_zero_free";
    }

    function _request(
        bool isClose
    ) internal view returns (OrderV2Types.OrderRequest memory request) {
        request.clientOrderId = keccak256(abi.encode("direct-gas", isClose));
        request.side = CfdTypes.Side.LONG;
        request.sizeDelta = isClose ? _closeSize() : SIZE;
        request.marginDelta = isClose ? 0 : 250e6;
        request.targetPrice = isClose ? type(uint256).max : PRICE;
        request.isClose = isClose;
        request.closeMode =
            isClose && _callerPaid() ? OrderV2Types.CloseMode.CallerPaidFullExit : OrderV2Types.CloseMode.Standard;
        request.bounds = OrderV2Types.ExecutionBounds({
            validUntil: uint64(vm.getBlockTimestamp() + router.maxOrderAge()),
            allowedExecutionModes: 7,
            expectedConfigHash: router.lifecycleBook().currentExecutionConfigHash(),
            maxExecutionBountyUsdc: type(uint256).max,
            maxExecutionNotionalUsdc: type(uint256).max,
            maxGrossAccountDebitUsdc: type(uint256).max,
            maxActionChargeUsdc: type(uint256).max,
            maxExplicitFeesUsdc: type(uint256).max,
            maxPostPositionSize: isClose ? SIZE - _closeSize() : SIZE,
            minPostSettlementBalanceUsdc: 0,
            minPostPositionEquityUsdc: 0,
            maxPostLeverageBps: type(uint32).max
        });
    }

    function _feeds() internal pure returns (bytes32[] memory feeds) {
        feeds = new bytes32[](1);
        feeds[0] = FEED;
    }

    function _updateData() internal returns (bytes[] memory update) {
        uint256 nowTime = vm.getBlockTimestamp() + 1;
        vm.warp(nowTime);
        vm.roll(vm.getBlockNumber() + 1);
        pyth.setAllUniquePrices(_feeds(), int64(uint64(PRICE)), 0, -8, nowTime, nowTime - 1);
        update = new bytes[](1);
        update[0] = abi.encode(PRICE);
    }

    function _coolProtocol() internal {
        for (uint256 i; i < measuredAccounts.length; ++i) {
            vm.cool(measuredAccounts[i]);
        }
    }

    function _assertReservation(
        uint64 id
    ) internal view {
        IMarginClearinghouse.BountyReservation memory reservation =
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id);
        assertEq(uint8(reservation.state), uint8(IMarginClearinghouse.BountyReservationState.Active));
        assertEq(reservation.freeFundedUsdc, 0);
        assertEq(reservation.pledgeFundedUsdc, _callerPaid() ? 0 : router.closeOrderExecutionBountyUsdc());
        assertEq(clearinghouse.getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc, 0);
    }

}

abstract contract DirectCloseCommitGasFixture is DirectCloseGasFixture {

    function test_Gas_DirectCloseCommit() public {
        OrderV2Types.OrderRequest memory request = _request(true);
        _coolProtocol();
        vm.prank(ACCOUNT);
        uint256 beforeGas = gasleft();
        uint64 id = router.commitOrder(request);
        uint256 usedGas = beforeGas - gasleft();
        emit log_named_uint(string.concat("direct_commit_", _scenario()), usedGas);
        _assertReservation(id);
    }

}

abstract contract DirectCloseExecuteGasFixture is DirectCloseGasFixture {

    function setUp() public virtual override {
        super.setUp();
        OrderV2Types.OrderRequest memory request = _request(true);
        vm.prank(ACCOUNT);
        closeOrderId = router.commitOrder(request);
        _assertReservation(closeOrderId);
    }

    function test_Gas_DirectCloseExecute() public {
        bytes[] memory update = _updateData();
        _coolProtocol();
        vm.prank(KEEPER);
        uint256 beforeGas = gasleft();
        OrderV2Types.ExecutionResult memory result = router.executeOrder(closeOrderId, update);
        uint256 usedGas = beforeGas - gasleft();
        emit log_named_uint(string.concat("direct_execute_", _scenario()), usedGas);
        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Executed));
        (uint256 remaining,,,,,,) = engine.positions(ACCOUNT);
        assertEq(remaining, SIZE - _closeSize());
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 0);
        assertEq(router.pendingTerminalExitId(ACCOUNT), 0);
    }

}

contract DirectStandardFullCommitGasTest is DirectCloseCommitGasFixture {}

contract DirectStandardFullExecuteGasTest is DirectCloseExecuteGasFixture {}

contract DirectStandardPartialCommitGasTest is DirectCloseCommitGasFixture {

    function _closeSize() internal pure override returns (uint256) {
        return SIZE / 2;
    }

    function _scenario() internal pure override returns (string memory) {
        return "standard_partial_zero_free";
    }

}

contract DirectStandardPartialExecuteGasTest is DirectCloseExecuteGasFixture {

    function _closeSize() internal pure override returns (uint256) {
        return SIZE / 2;
    }

    function _scenario() internal pure override returns (string memory) {
        return "standard_partial_zero_free";
    }

}

contract DirectCallerPaidFullCommitGasTest is DirectCloseCommitGasFixture {

    function _callerPaid() internal pure override returns (bool) {
        return true;
    }

    function _scenario() internal pure override returns (string memory) {
        return "caller_paid_full_zero_free";
    }

}

contract DirectCallerPaidFullExecuteGasTest is DirectCloseExecuteGasFixture {

    function _callerPaid() internal pure override returns (bool) {
        return true;
    }

    function _scenario() internal pure override returns (string memory) {
        return "caller_paid_full_zero_free";
    }

}
