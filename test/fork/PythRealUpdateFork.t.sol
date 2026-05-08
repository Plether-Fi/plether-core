// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IPyth, PythStructs} from "../../src/interfaces/IPyth.sol";
import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdEngineAdmin} from "../../src/perps/CfdEngineAdmin.sol";
import {CfdEngineLens} from "../../src/perps/CfdEngineLens.sol";
import {CfdEnginePlanner} from "../../src/perps/CfdEnginePlanner.sol";
import {CfdEngineSettlementModule} from "../../src/perps/CfdEngineSettlementModule.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {IOrderRouterAccounting} from "../../src/perps/interfaces/IOrderRouterAccounting.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Opt-in fork checks for real Hermes update bytes against Ethereum mainnet Pyth.
/// @dev Generate env vars with scripts/fetch-pyth-real-update-fixture.sh before running.
contract PythRealUpdateForkTest is Test {

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant REAL_PYTH = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;
    bytes32 internal constant EUR_USD_FEED_ID = 0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b;
    uint256 internal constant CAP_PRICE = 2e8;

    MarginClearinghouse internal clearinghouse;
    CfdEngine internal engine;
    HousePool internal pool;
    TrancheVault internal seniorVault;
    TrancheVault internal juniorVault;
    OrderRouter internal router;

    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");
    address internal lp = makeAddr("lp");

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
    }

    function test_PythUniqueHistoricalParse_RealHermesBytes_ReturnsRangeBoundTick() public {
        (bytes[] memory updateData, uint64 prevPublishTime, uint64 publishTime) = _realHermesFixture();
        assertLt(prevPublishTime, publishTime, "fixture must cover at least one commit timestamp");

        bytes32[] memory priceIds = _singleFeedIds();
        uint256 fee = IPyth(REAL_PYTH).getUpdateFee(updateData);
        PythStructs.PriceFeed[] memory feeds =
            IPyth(REAL_PYTH).parsePriceFeedUpdatesUnique{value: fee}(updateData, priceIds, publishTime, publishTime);

        assertEq(feeds.length, 1, "one feed returned");
        assertEq(feeds[0].id, EUR_USD_FEED_ID, "feed id");
        assertEq(feeds[0].price.publishTime, publishTime, "range-bound publish time");
        assertGt(feeds[0].price.price, int64(0), "positive price");
        assertGt(feeds[0].price.conf, uint64(0), "confidence returned");
    }

    function test_PythUniqueHistoricalParse_RealHermesBytes_RejectsSkippedEarlierTick() public {
        (bytes[] memory updateData, uint64 prevPublishTime, uint64 publishTime) = _realHermesFixture();
        assertLt(prevPublishTime, publishTime, "fixture must cover at least one commit timestamp");

        bytes32[] memory priceIds = _singleFeedIds();
        uint256 fee = IPyth(REAL_PYTH).getUpdateFee(updateData);

        vm.expectRevert();
        IPyth(REAL_PYTH).parsePriceFeedUpdatesUnique{value: fee}(updateData, priceIds, prevPublishTime, publishTime);
    }

    function test_OrderRouter_ExecutesPostCommitOrder_WithRealHermesBytes() public {
        (bytes[] memory updateData, uint64 prevPublishTime, uint64 publishTime) = _realHermesFixture();
        assertLt(prevPublishTime, publishTime, "fixture must cover at least one commit timestamp");

        // This exercises the live-market historical path. If the fixture is captured during a
        // frozen FX market window, the direct parser tests above still validate Pyth behavior.
        if (_isUtcWeekend(publishTime)) {
            emit log("skipping router execution check for weekend/frozen FX fixture");
            return;
        }

        _deployPerpsWithRealPyth(publishTime);
        _depositToClearinghouse(alice, 10_000e6);

        uint64 commitTime = publishTime - 1;

        vm.warp(commitTime);
        vm.roll(1_000_000);
        uint64 orderId = router.nextCommitId();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 5000e6, 0, false);

        uint256 fee = IPyth(REAL_PYTH).getUpdateFee(updateData);
        vm.deal(keeper, fee);
        vm.warp(publishTime + 1);
        vm.roll(1_000_001);
        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(orderId);
        assertEq(pending.commitTime, commitTime, "fixture publish time should be strictly after the order commit time");
        assertGt(block.number, pending.commitBlock, "execution must happen after the commit block");

        vm.prank(keeper);
        router.executeOrder{value: fee}(orderId, updateData);

        (uint256 size,,,,,,) = engine.positions(alice);
        assertEq(size, 100_000e18, "position opened with real Pyth update bytes");
        assertEq(engine.lastMarkTime(), publishTime, "engine mark time uses the post-commit Pyth tick");
    }

    function _realHermesFixture()
        internal
        view
        returns (bytes[] memory updateData, uint64 prevPublishTime, uint64 publishTime)
    {
        bytes memory rawUpdateData = vm.envBytes("PYTH_REAL_UPDATE_DATA");
        updateData = abi.decode(rawUpdateData, (bytes[]));
        prevPublishTime = uint64(vm.envUint("PYTH_REAL_UPDATE_PREV_PUBLISH_TIME"));
        publishTime = uint64(vm.envUint("PYTH_REAL_UPDATE_PUBLISH_TIME"));
    }

    function _deployPerpsWithRealPyth(
        uint256 setupTime
    ) internal {
        vm.warp(setupTime);

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: 150,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10
        });

        clearinghouse = new MarginClearinghouse(USDC);
        engine = new CfdEngine(USDC, address(clearinghouse), CAP_PRICE, params);
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementModule settlement = new CfdEngineSettlementModule(address(engine));
        CfdEngineAdmin engineAdmin = new CfdEngineAdmin(address(engine), address(this));
        engine.setDependencies(address(planner), address(settlement), address(engineAdmin));

        pool = new HousePool(USDC, address(engine));
        seniorVault = new TrancheVault(IERC20(USDC), address(pool), true, "Senior LP", "senUSDC");
        juniorVault = new TrancheVault(IERC20(USDC), address(pool), false, "Junior LP", "junUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        uint256[] memory weights = new uint256[](1);
        weights[0] = 1e18;
        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = 1e8;
        router = new OrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            REAL_PYTH,
            _singleFeedIds(),
            weights,
            basePrices,
            new bool[](1)
        );

        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));
        clearinghouse.setEngine(address(engine));

        deal(USDC, address(this), 2000e6);
        IERC20(USDC).approve(address(pool), 2000e6);
        pool.initializeSeedPosition(false, 1000e6, address(this));
        pool.initializeSeedPosition(true, 1000e6, address(this));
        pool.activateTrading();

        deal(USDC, lp, 1_000_000e6);
        vm.startPrank(lp);
        IERC20(USDC).approve(address(juniorVault), type(uint256).max);
        juniorVault.deposit(1_000_000e6, lp);
        vm.stopPrank();
    }

    function _depositToClearinghouse(
        address trader,
        uint256 amount
    ) internal {
        deal(USDC, trader, amount);
        vm.startPrank(trader);
        IERC20(USDC).approve(address(clearinghouse), amount);
        clearinghouse.deposit(trader, amount);
        vm.stopPrank();
    }

    function _singleFeedIds() internal pure returns (bytes32[] memory feedIds) {
        feedIds = new bytes32[](1);
        feedIds[0] = EUR_USD_FEED_ID;
    }

    function _isUtcWeekend(
        uint256 timestamp
    ) internal pure returns (bool) {
        // Unix epoch Thursday = day 4. Saturday/Sunday are 6/0.
        uint256 day = ((timestamp / 1 days) + 4) % 7;
        return day == 0 || day == 6;
    }

}
