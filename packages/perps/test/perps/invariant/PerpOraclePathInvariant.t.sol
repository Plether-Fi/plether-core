// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {LegacyOrderRouterHarness} from "../../utils/LegacyOrderRouterHarness.sol";
import {BasePerpTest} from "../BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineAccountLens} from "@plether/perps/CfdEngineAccountLens.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdEngineProtocolLens} from "@plether/perps/CfdEngineProtocolLens.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {HousePoolRedemptionMathSidecar} from "@plether/perps/HousePoolRedemptionMathSidecar.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {PerpsPublicLens} from "@plether/perps/PerpsPublicLens.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouter} from "@plether/perps/interfaces/IOrderRouter.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

contract PerpOraclePathHandler is Test {

    MockPyth public immutable mockPyth;
    LegacyOrderRouterHarness public immutable router;
    OrderRouterAdmin public immutable routerAdmin;
    IPletherOracle public immutable pletherOracle;
    CfdEngine public immutable engine;
    address public immutable owner;
    bytes32[] internal feedIds;
    uint256 internal immutable capPrice;

    uint256 public ghostExpectedMarkPrice;
    uint64 public ghostExpectedMarkTime;
    uint256 public ghostPendingRefundEth;
    uint256 public ghostDirectRefundEth;
    bool internal acceptEthRefunds;

    error PerpOraclePathHandler__UnexpectedSuccess();
    error PerpOraclePathHandler__UnexpectedRevert(bytes4 selector);

    constructor(
        MockPyth _mockPyth,
        LegacyOrderRouterHarness _router,
        CfdEngine _engine,
        address _owner,
        bytes32[] memory _feedIds,
        uint256 _capPrice
    ) {
        mockPyth = _mockPyth;
        router = _router;
        routerAdmin = OrderRouterAdmin(_router.admin());
        pletherOracle = _router.pletherOracle();
        engine = _engine;
        owner = _owner;
        feedIds = _feedIds;
        capPrice = _capPrice;
        acceptEthRefunds = true;
    }

    receive() external payable {
        if (!acceptEthRefunds) {
            revert();
        }
    }

    function setPythFee(
        uint256 feeFuzz
    ) external {
        mockPyth.setFee(bound(feeFuzz, 0, 0.1 ether));
    }

    function setOrderExecutionStalenessLimit(
        uint256 limitFuzz
    ) external {
        uint256 limit = bound(limitFuzz, 1, 600);
        vm.startPrank(owner);
        IOrderRouterAdminHost.RouterConfig memory config;
        config.maxOrderAge = router.maxOrderAge();
        config.orderExecutionStalenessLimit = limit;
        config.liquidationStalenessLimit = router.pletherOracle().liquidationStalenessLimit();
        config.basketMaxConfidenceRatioBps = router.pletherOracle().basketMaxConfidenceRatioBps();
        config.orderSettlementWindow = router.pletherOracle().orderSettlementWindow();
        config.maxComponentPublishTimeDivergence = router.pletherOracle().maxComponentPublishTimeDivergence();
        config.adverseConfidenceMultiplierBps = router.pletherOracle().adverseConfidenceMultiplierBps();
        config.minOpenNotionalUsdc = router.minOpenNotionalUsdc();
        config.openOrderExecutionBountyBps = router.openOrderExecutionBountyBps();
        config.minOpenOrderExecutionBountyUsdc = router.minOpenOrderExecutionBountyUsdc();
        config.maxOpenOrderExecutionBountyUsdc = router.maxOpenOrderExecutionBountyUsdc();
        config.closeOrderExecutionBountyUsdc = router.closeOrderExecutionBountyUsdc();
        config.positionProtectionCommitsEnabled = router.positionProtectionCommitsEnabled();
        config.positionProtectionTriggerBountyUsdc = router.positionProtectionTriggerBountyUsdc();
        config.maxPendingOrders = router.maxPendingOrders();
        config.minEngineGas = router.minEngineGas();
        config.maxPruneOrdersPerCall = router.maxPruneOrdersPerCall();
        routerAdmin.proposeRouterConfig(config);
        vm.warp(block.timestamp + 48 hours);
        routerAdmin.finalizeRouterConfig();
        vm.stopPrank();
    }

    function setLiquidationStalenessLimit(
        uint256 limitFuzz
    ) external {
        uint256 limit = bound(limitFuzz, 1, 600);
        vm.startPrank(owner);
        IOrderRouterAdminHost.RouterConfig memory config;
        config.maxOrderAge = router.maxOrderAge();
        config.orderExecutionStalenessLimit = router.pletherOracle().orderExecutionStalenessLimit();
        config.liquidationStalenessLimit = limit;
        config.basketMaxConfidenceRatioBps = router.pletherOracle().basketMaxConfidenceRatioBps();
        config.orderSettlementWindow = router.pletherOracle().orderSettlementWindow();
        config.maxComponentPublishTimeDivergence = router.pletherOracle().maxComponentPublishTimeDivergence();
        config.adverseConfidenceMultiplierBps = router.pletherOracle().adverseConfidenceMultiplierBps();
        config.minOpenNotionalUsdc = router.minOpenNotionalUsdc();
        config.openOrderExecutionBountyBps = router.openOrderExecutionBountyBps();
        config.minOpenOrderExecutionBountyUsdc = router.minOpenOrderExecutionBountyUsdc();
        config.maxOpenOrderExecutionBountyUsdc = router.maxOpenOrderExecutionBountyUsdc();
        config.closeOrderExecutionBountyUsdc = router.closeOrderExecutionBountyUsdc();
        config.positionProtectionCommitsEnabled = router.positionProtectionCommitsEnabled();
        config.positionProtectionTriggerBountyUsdc = router.positionProtectionTriggerBountyUsdc();
        config.maxPendingOrders = router.maxPendingOrders();
        config.minEngineGas = router.minEngineGas();
        config.maxPruneOrdersPerCall = router.maxPruneOrdersPerCall();
        routerAdmin.proposeRouterConfig(config);
        vm.warp(block.timestamp + 48 hours);
        routerAdmin.finalizeRouterConfig();
        vm.stopPrank();
    }

    function warpForward(
        uint256 secondsFuzz
    ) external {
        vm.warp(block.timestamp + bound(secondsFuzz, 1, 3 days));
    }

    function refreshMark(
        uint256 priceFuzz,
        uint256 ageFuzz,
        uint256 divergenceFuzz,
        uint256 overpayFuzz,
        bool rejectRefund
    ) external {
        uint256 price = bound(priceFuzz, 1, 3e8);
        uint256 limit = router.pletherOracle().orderExecutionStalenessLimit();
        uint256 age = bound(ageFuzz, 0, limit + 120);
        uint256 divergence = bound(divergenceFuzz, 0, limit + 120);
        uint256 publishTimeA = block.timestamp > age ? block.timestamp - age : 0;
        uint256 publishTimeB = publishTimeA > divergence ? publishTimeA - divergence : 0;
        uint256 minPublishTime = publishTimeB < publishTimeA ? publishTimeB : publishTimeA;
        uint256 oldestAge = block.timestamp > minPublishTime ? block.timestamp - minPublishTime : 0;

        mockPyth.setPrice(feedIds[0], int64(uint64(price)), int32(-8), publishTimeA);
        mockPyth.setPrice(feedIds[1], int64(uint64(price)), int32(-8), publishTimeB);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"00";

        uint256 fee = mockPyth.mockFee();
        uint256 overpay = bound(overpayFuzz, 0, 0.05 ether);
        uint256 msgValue = fee + overpay;
        bool expectStale = oldestAge > limit || divergence > limit;
        bool expectOutOfOrder = minPublishTime < engine.lastMarkTime();
        acceptEthRefunds = !rejectRefund;

        try router.updateMarkPrice{value: msgValue}(updateData) {
            if (expectStale || expectOutOfOrder) {
                revert PerpOraclePathHandler__UnexpectedSuccess();
            }

            uint256 basketPrice = (price / 2) * 2;
            ghostExpectedMarkPrice = basketPrice > capPrice ? capPrice : basketPrice;
            ghostExpectedMarkTime = uint64(minPublishTime);
            if (rejectRefund && overpay > 0) {
                ghostPendingRefundEth += overpay;
            } else {
                ghostDirectRefundEth += overpay;
            }
        } catch (bytes memory err) {
            bytes4 selector = _revertSelector(err);
            if (expectStale) {
                if (!_isExpectedStaleOracleSelector(selector)) {
                    revert PerpOraclePathHandler__UnexpectedRevert(selector);
                }
                return;
            }
            if (expectOutOfOrder) {
                if (
                    selector != IPletherOracle.PletherOracle__PriceOutOfOrder.selector
                        && selector != ICfdEngineTypes.CfdEngine__MarkPriceOutOfOrder.selector
                ) {
                    revert PerpOraclePathHandler__UnexpectedRevert(selector);
                }
                return;
            }
            revert PerpOraclePathHandler__UnexpectedRevert(selector);
        }
    }

    function claimRefund() external {
        if (ghostPendingRefundEth == 0) {
            return;
        }

        acceptEthRefunds = true;
        uint256 pending = ghostPendingRefundEth;
        uint256 beforeBalance = address(this).balance;
        pletherOracle.claimEthRefund();
        uint256 claimed = address(this).balance - beforeBalance;
        assertEq(claimed, pending, "claim must transfer the full stranded ETH amount");
        ghostPendingRefundEth = 0;
        ghostDirectRefundEth += claimed;
    }

    function _revertSelector(
        bytes memory err
    ) internal pure returns (bytes4 selector) {
        if (err.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(err, 32))
            }
        }
    }

    function _isExpectedStaleOracleSelector(
        bytes4 selector
    ) internal pure returns (bool) {
        return selector == IPletherOracle.PletherOracle__StalePrice.selector
            || selector == IPletherOracle.PletherOracle__PublishTimeDivergence.selector;
    }

}

contract PerpOraclePathInvariantTest is BasePerpTest {

    MockPyth internal mockPyth;
    PerpOraclePathHandler internal handler;
    bytes32[] internal feedIds;
    uint256[] internal weights;
    uint256[] internal bases;
    bool[] internal inversions;

    bytes32 internal constant FEED_A = bytes32(uint256(1));
    bytes32 internal constant FEED_B = bytes32(uint256(2));

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        usdc = new MockUSDC();
        clearinghouse = new MarginClearinghouse(address(usdc));

        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));
        engineAccountLens = new CfdEngineAccountLens(address(engine));
        engineLens = new CfdEngineLens(address(engine));
        engineProtocolLens = new CfdEngineProtocolLens(address(engine));
        pool = new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC", 0, address(0));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC", 0, address(0));

        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        mockPyth = new MockPyth();
        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);
        inversions.push(false);
        inversions.push(false);

        pletherOracle =
            new PletherOracle(address(engine), address(pool), address(mockPyth), feedIds, weights, bases, inversions);
        router = _deployLegacyOrderRouter(address(engine), address(engineLens), address(pool), address(pletherOracle));
        _syncRouterAdmin();
        engine.setOrderRouter(address(router));
        publicLens = new PerpsPublicLens(address(engineAccountLens), address(engine), address(router), address(pool));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();

        handler = new PerpOraclePathHandler(mockPyth, router, engine, address(this), feedIds, CAP_PRICE);
        vm.deal(address(handler), 10 ether);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.setPythFee.selector;
        selectors[1] = handler.setOrderExecutionStalenessLimit.selector;
        selectors[2] = handler.setLiquidationStalenessLimit.selector;
        selectors[3] = handler.warpForward.selector;
        selectors[4] = handler.refreshMark.selector;
        selectors[5] = handler.claimRefund.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_MarkRefreshStateMatchesLastSuccessfulOracleUpdate() public view {
        assertEq(
            engine.lastMarkPrice(), handler.ghostExpectedMarkPrice(), "engine mark price drifted from last success"
        );
        assertEq(engine.lastMarkTime(), handler.ghostExpectedMarkTime(), "engine mark time drifted from last success");
    }

    function invariant_OracleTracksOnlyClaimableFailedRefundEth() public view {
        assertEq(
            router.pletherOracle().claimableEth(address(handler)),
            handler.ghostPendingRefundEth(),
            "oracle claimable ETH must equal failed refund total"
        );
        assertEq(address(routerAdmin).balance, 0, "router admin must not custody oracle refunds");
    }

    function invariant_OracleStalenessLimitsRemainPositive() public view {
        assertGt(
            router.pletherOracle().orderExecutionStalenessLimit(),
            0,
            "order execution staleness limit must stay positive"
        );
        assertGt(
            router.pletherOracle().liquidationStalenessLimit(), 0, "liquidation staleness limit must stay positive"
        );
    }

}
