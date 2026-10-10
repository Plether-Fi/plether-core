// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {LegacyOrderRouterHarness} from "../../../utils/LegacyOrderRouterHarness.sol";
import {BasePerpTest} from "../../BasePerpTest.sol";
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
    uint256 public refreshAttempts;
    uint256 public successfulRefreshes;
    uint256 public expectedStaleRejections;
    uint256 public expectedDivergenceRejections;
    uint256 public expectedZeroBasketRejections;
    uint256 public expectedOutOfOrderRejections;
    bool internal acceptEthRefunds;

    struct RefreshInput {
        uint256 price;
        uint256 publishTimeA;
        uint256 publishTimeB;
        uint256 overpay;
        bytes expectedRevert;
    }

    error PerpOraclePathHandler__UnexpectedSuccess();
    error PerpOraclePathHandler__UnexpectedRevert(bytes reason);

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
        config.maxExecutionWindowSeconds = router.maxExecutionWindowSeconds();
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
        config.maxExecutionWindowSeconds = router.maxExecutionWindowSeconds();
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
        RefreshInput memory input;
        input.price = bound(priceFuzz, 1, 3e8);
        // Mark refresh relaxes both age and divergence only while frozen, not during a live FAD shoulder.
        // Read configuration and calendar state, never the production freshness-policy implementation.
        uint256 limit =
            engine.isOracleFrozen() ? engine.fadMaxStaleness() : pletherOracle.orderExecutionStalenessLimit();
        uint256 age = bound(ageFuzz, 0, limit + 120);
        uint256 divergence = bound(divergenceFuzz, 0, limit + 120);
        input.publishTimeA = block.timestamp > age ? block.timestamp - age : 0;
        input.publishTimeB = input.publishTimeA > divergence ? input.publishTimeA - divergence : 0;
        input.overpay = bound(overpayFuzz, 0, 0.05 ether);
        input.expectedRevert = _expectedRefreshRevert(input, limit);

        mockPyth.setPrice(feedIds[0], int64(uint64(input.price)), int32(-8), input.publishTimeA);
        mockPyth.setPrice(feedIds[1], int64(uint64(input.price)), int32(-8), input.publishTimeB);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"00";

        uint256 msgValue = mockPyth.mockFee() + input.overpay;
        // Campaign depth must not turn oracle-policy coverage into fixture ETH-exhaustion failures.
        if (address(this).balance < msgValue) {
            vm.deal(address(this), msgValue);
        }
        acceptEthRefunds = !rejectRefund;
        ++refreshAttempts;

        try router.updateMarkPrice{value: msgValue}(updateData) {
            if (input.expectedRevert.length != 0) {
                revert PerpOraclePathHandler__UnexpectedSuccess();
            }

            ++successfulRefreshes;
            uint256 basketPrice = (input.price / 2) * 2;
            ghostExpectedMarkPrice = basketPrice > capPrice ? capPrice : basketPrice;
            ghostExpectedMarkTime = uint64(input.publishTimeB);
            if (rejectRefund && input.overpay > 0) {
                ghostPendingRefundEth += input.overpay;
            } else {
                ghostDirectRefundEth += input.overpay;
            }
        } catch (bytes memory err) {
            // Require the exact error and argument values in validation order, including ABI payload length.
            if (input.expectedRevert.length == 0 || keccak256(err) != keccak256(input.expectedRevert)) {
                revert PerpOraclePathHandler__UnexpectedRevert(err);
            }
            bytes4 selector = _revertSelector(err);
            if (selector == IPletherOracle.PletherOracle__StalePrice.selector) {
                ++expectedStaleRejections;
            } else if (selector == IPletherOracle.PletherOracle__PublishTimeDivergence.selector) {
                ++expectedDivergenceRejections;
            } else if (selector == IPletherOracle.PletherOracle__ZeroBasketPrice.selector) {
                ++expectedZeroBasketRejections;
            } else {
                ++expectedOutOfOrderRejections;
            }
        }
    }

    function _expectedRefreshRevert(
        RefreshInput memory input,
        uint256 limit
    ) internal view returns (bytes memory) {
        // Feed-age validation precedes basket construction; zero basket precedes cached-mark ordering.
        for (uint256 i; i < 2; ++i) {
            uint256 publishTime = i == 0 ? input.publishTimeA : input.publishTimeB;
            if (block.timestamp - publishTime > limit) {
                return abi.encodeWithSelector(
                    IPletherOracle.PletherOracle__StalePrice.selector,
                    IPletherOracle.PriceMode.MarkRefresh,
                    feedIds[i],
                    publishTime,
                    limit,
                    block.timestamp
                );
            }
        }
        if (input.publishTimeA - input.publishTimeB > limit) {
            return abi.encodeWithSelector(
                IPletherOracle.PletherOracle__PublishTimeDivergence.selector,
                IPletherOracle.PriceMode.MarkRefresh,
                input.publishTimeB,
                input.publishTimeA,
                limit
            );
        }
        if ((input.price / 2) * 2 == 0) {
            return abi.encodeWithSelector(IPletherOracle.PletherOracle__ZeroBasketPrice.selector);
        }
        uint64 lastMarkTime = engine.lastMarkTime();
        if (input.publishTimeB < lastMarkTime) {
            return abi.encodeWithSelector(
                IPletherOracle.PletherOracle__PriceOutOfOrder.selector, uint64(input.publishTimeB), lastMarkTime
            );
        }
        return new bytes(0);
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

        seniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC", 0, address(0)
        );
        juniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC", 0, address(0)
        );

        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        mockPyth = new MockPyth();

        mockPyth.setSynchronizeLegacyUniquePrices(true);
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

    function test_RefreshLiveAgeBoundaryAndFeedValidationOrder() public {
        assertFalse(engine.isOracleFrozen());
        uint256 limit = pletherOracle.orderExecutionStalenessLimit();
        handler.refreshMark(1e8, limit, 0, 0, false);
        assertEq(engine.lastMarkTime(), block.timestamp - limit);
        handler.refreshMark(1e8, limit + 1, 0, 0, false);
        handler.refreshMark(1e8, 0, limit + 1, 0, false);
        assertEq(handler.successfulRefreshes(), 1);
        assertEq(handler.expectedStaleRejections(), 2);
        assertEq(handler.expectedDivergenceRejections(), 0, "Component age must fail before divergence");
        _assertAllInvariants();
    }

    function test_RefreshFrozenPolicyAllowsExtendedAgeAndDivergence() public {
        vm.warp(1_772_834_400); // Friday 22:00 UTC: frozen policy begins.
        assertTrue(engine.isOracleFrozen());
        uint256 frozenLimit = engine.fadMaxStaleness();
        uint256 liveLimit = pletherOracle.orderExecutionStalenessLimit();
        handler.refreshMark(1e8, 0, frozenLimit, 0, false);
        assertEq(engine.lastMarkTime(), block.timestamp - frozenLimit);
        handler.refreshMark(1e8, 0, liveLimit + 1, 0, false);
        assertEq(engine.lastMarkTime(), block.timestamp - liveLimit - 1);
        handler.refreshMark(1e8, frozenLimit + 1, 0, 0, false);
        assertEq(handler.successfulRefreshes(), 2);
        assertEq(handler.expectedStaleRejections(), 1);
        _assertAllInvariants();
    }

    function test_RefreshFadShoulderRetainsLiveAgeLimit() public {
        vm.warp(1_772_832_600); // Friday 21:30 UTC: FAD is active before the freeze.
        assertTrue(engine.isFadWindow());
        assertFalse(engine.isOracleFrozen());
        uint256 limit = pletherOracle.orderExecutionStalenessLimit();
        handler.refreshMark(1e8, limit + 1, 0, 0, false);
        handler.refreshMark(1e8, limit, 0, 0, false);
        assertEq(handler.successfulRefreshes(), 1);
        assertEq(handler.expectedStaleRejections(), 1);
        _assertAllInvariants();
    }

    function test_RefreshClassifiesZeroBasketAndOutOfOrderInValidationOrder() public {
        uint256 limit = pletherOracle.orderExecutionStalenessLimit();
        handler.refreshMark(1e8, 0, 0, 0, false);
        handler.refreshMark(1, 1, 0, 0, false); // Zero basket precedes an older cached-mark check.
        handler.refreshMark(1, limit + 1, 0, 0, false); // Stale component precedes zero basket.
        handler.refreshMark(1e8, 1, 0, 0, false);
        handler.refreshMark(1, 0, 0, 0, false);
        assertEq(handler.successfulRefreshes(), 1);
        assertEq(handler.expectedZeroBasketRejections(), 2);
        assertEq(handler.expectedStaleRejections(), 1);
        assertEq(handler.expectedOutOfOrderRejections(), 1);
        _assertAllInvariants();
    }

    function test_RefreshReplenishesFeeFundingAndTracksRefundModes() public {
        vm.deal(address(handler), 0);
        handler.setPythFee(0.1 ether);
        handler.refreshMark(1e8, 0, 0, 0.05 ether, true);
        handler.refreshMark(1e8, 0, 0, 0.05 ether, false);
        handler.refreshMark(1e8, 0, 0, 0.05 ether, true);
        assertEq(handler.ghostPendingRefundEth(), 0.1 ether);
        assertEq(handler.ghostDirectRefundEth(), 0.05 ether);
        assertEq(address(mockPyth).balance, 0.3 ether);
        handler.claimRefund();
        assertEq(handler.ghostPendingRefundEth(), 0);
        assertEq(handler.ghostDirectRefundEth(), 0.15 ether);
        assertEq(handler.successfulRefreshes(), 3);
        _assertAllInvariants();
    }

    function test_RefreshRejectsUnknownMalformedAndWrongArgumentErrors() public {
        uint256 limit = pletherOracle.orderExecutionStalenessLimit();
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"00";
        bytes memory callData = abi.encodeWithSelector(router.updateMarkPrice.selector, updateData);
        bytes[] memory reasons = new bytes[](5);
        reasons[0] = abi.encodeWithSignature("Error(string)", "unexpected dependency failure");
        reasons[1] = abi.encodeWithSignature("Panic(uint256)", uint256(0x11));
        reasons[2] = abi.encodeWithSelector(IPletherOracle.PletherOracle__StalePrice.selector);
        reasons[3] = abi.encodeWithSelector(
            IPletherOracle.PletherOracle__StalePrice.selector,
            IPletherOracle.PriceMode.MarkRefresh,
            FEED_B, // Feed A is the first stale component in this attempt.
            block.timestamp - limit - 1,
            limit,
            block.timestamp
        );
        reasons[4] = abi.encodeWithSelector(IPletherOracle.PletherOracle__ZeroBasketPrice.selector);
        for (uint256 i; i < reasons.length; ++i) {
            vm.mockCallRevert(address(router), callData, reasons[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    PerpOraclePathHandler.PerpOraclePathHandler__UnexpectedRevert.selector, reasons[i]
                )
            );
            handler.refreshMark(1e8, limit + 1, 0, 0, false);
        }
        vm.clearMockedCalls();
        assertEq(handler.expectedStaleRejections(), 0, "Unexpected errors must not count as expected rejection");
    }

    function test_RefreshUnexpectedSuccessIsFatal() public {
        uint256 limit = pletherOracle.orderExecutionStalenessLimit();
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"00";
        vm.mockCall(address(router), abi.encodeWithSelector(router.updateMarkPrice.selector, updateData), bytes(""));
        vm.expectRevert(PerpOraclePathHandler.PerpOraclePathHandler__UnexpectedSuccess.selector);
        handler.refreshMark(1e8, limit + 1, 0, 0, false);
        vm.clearMockedCalls();
    }

    function _assertInvariant_MarkRefreshStateMatchesLastSuccessfulOracleUpdate() internal view {
        assertEq(
            engine.lastMarkPrice(), handler.ghostExpectedMarkPrice(), "engine mark price drifted from last success"
        );
        assertEq(engine.lastMarkTime(), handler.ghostExpectedMarkTime(), "engine mark time drifted from last success");
    }

    function _assertInvariant_OracleTracksOnlyClaimableFailedRefundEth() internal view {
        assertEq(
            router.pletherOracle().claimableEth(address(handler)),
            handler.ghostPendingRefundEth(),
            "oracle claimable ETH must equal failed refund total"
        );
        assertEq(address(routerAdmin).balance, 0, "router admin must not custody oracle refunds");
    }

    function _assertInvariant_OracleStalenessLimitsRemainPositive() internal view {
        assertGt(
            router.pletherOracle().orderExecutionStalenessLimit(),
            0,
            "order execution staleness limit must stay positive"
        );
        assertGt(
            router.pletherOracle().liquidationStalenessLimit(), 0, "liquidation staleness limit must stay positive"
        );
    }

    function invariant_OracleRefreshStateAndRefundCustodyReconcile() public view {
        _assertAllInvariants();
    }

    function _assertAllInvariants() internal view {
        assertEq(
            handler.refreshAttempts(),
            handler.successfulRefreshes() + handler.expectedStaleRejections() + handler.expectedDivergenceRejections()
                + handler.expectedZeroBasketRejections() + handler.expectedOutOfOrderRejections(),
            "Every completed refresh attempt must have an exact classified outcome"
        );
        _assertInvariant_MarkRefreshStateMatchesLastSuccessfulOracleUpdate();
        _assertInvariant_OracleTracksOnlyClaimableFailedRefundEth();
        _assertInvariant_OracleStalenessLimitsRemainPositive();
    }

}
