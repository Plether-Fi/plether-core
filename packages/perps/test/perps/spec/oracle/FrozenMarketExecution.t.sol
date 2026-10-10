// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: spec. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/PRE_AUDIT_GUIDE.md#frozen-oracle-close-only-behavior

import {BasePerpTest} from "../../BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {HousePoolRedemptionMathSidecar} from "@plether/perps/HousePoolRedemptionMathSidecar.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";

contract FrozenCloseEligibilityTest is BasePerpTest {

    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    address alice = address(0xA11CE);

    /// @dev Thursday 2024-03-07 12:00 UTC (weekday, no FAD)
    uint256 constant THURSDAY_NOON = 1_709_812_800;
    /// @dev Saturday 2024-03-09 12:00 UTC (oracle frozen)
    uint256 constant SATURDAY_NOON = 1_709_985_600;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));
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

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router = _deployLegacyOrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(
                new PletherOracle(
                    address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2)
                )
            )
        );
        engine.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();

        _fundJunior(address(this), 1_000_000e6);

        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 10 ether);

        vm.warp(THURSDAY_NOON);
    }

    /// @dev spec; source: PRE_AUDIT_GUIDE.md#frozen-oracle-close-only-behavior.
    function test_CloseExecutesDuringOracleFreeze() public {
        address aliceAccount = alice;

        // Open position directly via engine (bypass router oracle timing)
        _open(aliceAccount, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertGt(size, 0, "Position should be open");

        // Warp to Saturday, which is oracle-frozen under the canonical market calendar.
        vm.warp(SATURDAY_NOON);
        mockPyth.setAllPrices(feedIds, int64(1e8), int32(-8), SATURDAY_NOON);

        // Alice commits a close order (commitOrder allows closes even when paused)
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);

        // The frozen close uses the applicable frozen oracle policy and must clear the position.
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";
        router.executeOrder{value: 0.01 ether}(1, updateData);

        (size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "close orders must execute during oracle freeze");
    }

}

contract FrozenLpRedemptionTest is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    /// @dev Friday 2024-03-08 22:30 UTC (oracle frozen, just past FX close)
    uint256 constant FRIDAY_AFTER_CLOSE = 1_709_938_200;

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 500_000e6;
    }

    /// @dev spec; source: PRE_AUDIT_GUIDE.md#frozen-oracle-close-only-behavior.
    function test_FrozenWindowAllowsMatureLpRedemption() public {
        _fundJunior(bob, 100_000e6);

        _fundTrader(alice, 50_000e6);
        address aliceAccount = alice;
        _open(aliceAccount, CfdTypes.Side.LONG, 200_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.warp(FRIDAY_AFTER_CLOSE);

        uint64 fridayPublishTime = uint64(FRIDAY_AFTER_CLOSE - 1800);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, fridayPublishTime);

        uint256 withdrawAmount = 50_000e6;
        uint256 redeemShares = juniorVault.estimateWithdrawShares(withdrawAmount);
        vm.prank(bob);
        uint256 requestId = juniorVault.requestRedeem(redeemShares, bob, bob);

        uint256 saturdayNoon = FRIDAY_AFTER_CLOSE + 14 hours;
        vm.warp(saturdayNoon);

        // The coordinated async exit remains live while frozen, using the frozen mark-age limit.
        _settleLpEpochForTest();
        uint256 claimableShares = juniorVault.claimableRedeemRequest(requestId, bob);
        vm.prank(bob);
        uint256 withdrawnAssets = juniorVault.claimRedeem(requestId, claimableShares, bob, bob);

        assertGt(withdrawnAssets, 0, "LP withdrawal must work during FAD window");
        assertEq(usdc.balanceOf(bob), withdrawnAssets, "funded FAD exit should remain independently claimable");
    }

}

contract ExpiredHeadFrozenQueueTest is BasePerpTest {

    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    address alice = address(0xA11CE);
    address keeper = address(0xBEEF);

    /// @dev Thursday 2024-03-07 12:00 UTC
    uint256 constant THURSDAY_NOON = 1_709_812_800;
    /// @dev Saturday 2024-03-09 12:00 UTC (oracle frozen)
    uint256 constant SATURDAY_NOON = 1_709_985_600;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));
        pool = new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Senior", "sUSDC", 0, address(0));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior", "jUSDC", 0, address(0));
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router = _deployLegacyOrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(
                new PletherOracle(
                    address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2)
                )
            )
        );
        engine.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();
        _fundJunior(address(this), 1_000_000e6);
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 10 ether);
        vm.deal(keeper, 10 ether);

        vm.warp(THURSDAY_NOON);
    }

    /// @dev spec; source: PRE_AUDIT_GUIDE.md#frozen-oracle-close-only-behavior.
    function test_ExpiredOpenIsClearedDuringFrozenWindow() public {
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8, false);

        vm.warp(SATURDAY_NOON);
        mockPyth.setAllPrices(feedIds, int64(1e8), int32(-8), SATURDAY_NOON);

        // The Thursday order has expired before Saturday, so pre-oracle cleanup drains it.
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.deal(keeper, 1 ether);
        vm.prank(keeper);
        (bool ok,) = address(router).call{value: 0.01 ether}(
            abi.encodeWithSelector(router.executeOrder.selector, uint64(1), priceData)
        );

        assertTrue(ok, "Expired open cleanup must succeed during the frozen window");
        assertEq(router.nextExecuteId(), 0, "Expired open must drain the queue to the zero sentinel");
    }

    /// @dev spec; source: PRE_AUDIT_GUIDE.md#frozen-oracle-close-only-behavior.
    function test_ExpiredHeadCanBeClearedBeforeFrozenClose() public {
        address aliceAccount = alice;
        _open(aliceAccount, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        // Bob commits an OPEN order on Thursday (before FAD window)
        address bob = address(0xB0B);
        _fundTrader(bob, 50_000e6);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        router.commitOrder(CfdTypes.Side.LONG, 50_000e18, 10_000e6, 1e8, false);

        vm.warp(SATURDAY_NOON);
        mockPyth.setAllPrices(feedIds, int64(1e8), int32(-8), SATURDAY_NOON);

        // Alice commits a CLOSE order → behind Bob (order 2)
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);

        // Keeper clears expired order 1, then executes the fresh frozen-market close in order 2.
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.deal(keeper, 2 ether);

        vm.prank(keeper);
        (bool ok1,) = address(router).call{value: 0.01 ether}(
            abi.encodeWithSelector(router.executeOrder.selector, uint64(1), priceData)
        );

        vm.prank(keeper);
        (bool ok2,) = address(router).call{value: 0.01 ether}(
            abi.encodeWithSelector(router.executeOrder.selector, uint64(2), priceData)
        );

        assertTrue(ok1, "Expired head cleanup must succeed");
        assertTrue(ok2, "The following frozen close must execute");
        assertEq(router.nextExecuteId(), 0, "Both terminal orders must leave the queue");
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "close order must not be blocked by open order in frozen queue");
    }

}
