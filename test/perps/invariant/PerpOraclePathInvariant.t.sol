// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../src/perps/CfdEngine.sol";
import {CfdEngineAccountLens} from "../../../src/perps/CfdEngineAccountLens.sol";
import {CfdEngineLens} from "../../../src/perps/CfdEngineLens.sol";
import {CfdEngineProtocolLens} from "../../../src/perps/CfdEngineProtocolLens.sol";
import {CfdTypes} from "../../../src/perps/CfdTypes.sol";
import {HousePool} from "../../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../../src/perps/MarginClearinghouse.sol";
import {OrderRouterAdmin} from "../../../src/perps/OrderRouterAdmin.sol";
import {OrderRouter} from "../../../src/perps/OrderRouter.sol";
import {PerpsPublicLens} from "../../../src/perps/PerpsPublicLens.sol";
import {TrancheVault} from "../../../src/perps/TrancheVault.sol";
import {IOrderRouterAdminHost} from "../../../src/perps/interfaces/IOrderRouterAdminHost.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {MockPyth} from "../../mocks/MockPyth.sol";
import {BasePerpTest} from "../BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract PerpOraclePathHandler is Test {

    MockPyth public immutable mockPyth;
    OrderRouter public immutable router;
    OrderRouterAdmin public immutable routerAdmin;
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
        OrderRouter _router,
        CfdEngine _engine,
        address _owner,
        bytes32[] memory _feedIds,
        uint256 _capPrice
    ) {
        mockPyth = _mockPyth;
        router = _router;
        routerAdmin = OrderRouterAdmin(_router.admin());
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
        IOrderRouterAdminHost.RouterConfig memory config = IOrderRouterAdminHost.RouterConfig({
            maxOrderAge: router.maxOrderAge(),
            orderExecutionStalenessLimit: limit,
            liquidationStalenessLimit: router.liquidationStalenessLimit(),
            pythMaxConfidenceRatioBps: router.pythMaxConfidenceRatioBps()
        });
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
        IOrderRouterAdminHost.RouterConfig memory config = IOrderRouterAdminHost.RouterConfig({
            maxOrderAge: router.maxOrderAge(),
            orderExecutionStalenessLimit: router.orderExecutionStalenessLimit(),
            liquidationStalenessLimit: limit,
            pythMaxConfidenceRatioBps: router.pythMaxConfidenceRatioBps()
        });
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
        uint256 limit = router.orderExecutionStalenessLimit();
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
                if (selector != OrderRouter.OrderRouter__OracleValidation.selector) {
                    revert PerpOraclePathHandler__UnexpectedRevert(selector);
                }
                return;
            }
            if (expectOutOfOrder) {
                if (selector != CfdEngine.CfdEngine__MarkPriceOutOfOrder.selector) {
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
        routerAdmin.claimBalance(true);
        uint256 claimed = address(this).balance - beforeBalance;
        assertEq(claimed, pending, "claim must transfer the full stranded ETH amount");
        ghostPendingRefundEth = 0;
        ghostDirectRefundEth += claimed;
    }

    function _revertSelector(
        bytes memory err
    ) internal pure returns (bytes4 selector) {
        if (err.length >= 4) {
            assembly {
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
        engineAccountLens = new CfdEngineAccountLens(address(engine));
        engineLens = new CfdEngineLens(address(engine));
        engineProtocolLens = new CfdEngineProtocolLens(address(engine));
        pool = new HousePool(address(usdc), address(engine));

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");

        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        mockPyth = new MockPyth();
        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);
        inversions.push(false);
        inversions.push(false);

        router = new OrderRouter(
            address(engine),
            address(engineLens),
            address(pool),
            address(mockPyth),
            feedIds,
            weights,
            bases,
            inversions
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));
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
        assertEq(engine.lastMarkPrice(), handler.ghostExpectedMarkPrice(), "engine mark price drifted from last success");
        assertEq(engine.lastMarkTime(), handler.ghostExpectedMarkTime(), "engine mark time drifted from last success");
    }

    function invariant_RouterCustodiesOnlyTrackedStrandedRefundEth() public view {
        assertEq(address(router).balance, handler.ghostPendingRefundEth(), "router ETH balance must equal stranded refunds");
    }

    function invariant_OracleStalenessLimitsRemainPositive() public view {
        assertGt(router.orderExecutionStalenessLimit(), 0, "order execution staleness limit must stay positive");
        assertGt(router.liquidationStalenessLimit(), 0, "liquidation staleness limit must stay positive");
    }
}
