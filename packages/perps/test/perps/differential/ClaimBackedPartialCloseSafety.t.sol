// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";

/// @notice A real deferred claim must not cause a partial close to erase the remainder's liquidation buffer.
contract ClaimBackedPartialCloseSafetyTest is BasePerpTest {

    address private constant ACCOUNT = address(0xAD34);
    address private constant KEEPER = address(0xBEEF);
    uint256 private constant SIZE = 100 * CfdTypes.SIZE_QUANTUM;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.maintMarginBps = 10;
        params.initMarginBps = 20;
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        // Enough utilization for one second of carry to exceed the old one-atom health buffer.
        return 40_000e6;
    }

    function setUp() public override {
        super.setUp();
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.basketMaxConfidenceRatioBps = 10;
        config.adverseConfidenceMultiplierBps = 2500;
        _setRouterConfig(config);
        // The timelock finishes on Thursday. Start the histories the following Monday.
        vm.warp(SETUP_TIMESTAMP + 7 days);
        vm.roll(vm.getBlockNumber() + 1);
        _createClaim();
    }

    function test_LiveClaimFundedPartialCloseSurvivesNextTickAtSamePrice() public {
        uint256 price = 125_000_000;
        _open(ACCOUNT, CfdTypes.Side.LONG, SIZE, 600e6, 110_000_000);
        _acceptMark(price);
        assertFalse(engine.isFadWindow());
        assertFalse(engineLens.isLiquidatableAt(ACCOUNT, price, pool.totalAssets()));

        _closeHalf(false, price);
        _assertRetainedBuffer(price, 10);

        // A zero-confidence tick adds carry but has no price movement or confidence adjustment.
        bytes[] memory updateData = _mockPythUpdateData(price);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__PositionIsSolvent.selector);
        vm.prank(KEEPER);
        router.executeLiquidation(ACCOUNT, updateData);
        (uint256 size,,,,,,) = engine.positions(ACCOUNT);
        assertEq(size, SIZE / 2);
    }

    function test_FrozenClaimFundedPartialCloseSurvivesLiquidationShiftAtSameMark() public {
        // Friday 20:20 UTC remains live before the recurring FX close.
        vm.warp(SETUP_TIMESTAMP + 11 days + 10 hours + 20 minutes);
        vm.roll(vm.getBlockNumber() + 1);
        _open(ACCOUNT, CfdTypes.Side.LONG, SIZE, 600e6, 110_000_000);
        uint256 price = 121_500_000;
        _acceptMark(price);

        vm.warp(SETUP_TIMESTAMP + 12 days + 2 hours);
        vm.roll(vm.getBlockNumber() + 1);
        assertTrue(engine.isOracleFrozen());
        assertTrue(engine.isFadWindow());
        uint256 shiftedPrice = price + price * 10 / 10_000 * 2500 / 10_000;
        assertFalse(engineLens.isLiquidatableAt(ACCOUNT, shiftedPrice, pool.totalAssets()));

        _closeHalf(true, price);
        _assertRetainedBuffer(shiftedPrice, 300);

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__PositionIsSolvent.selector);
        vm.prank(KEEPER);
        router.executeLiquidation(ACCOUNT, new bytes[](0));
        (uint256 size,,,,,,) = engine.positions(ACCOUNT);
        assertEq(size, SIZE / 2);
        assertEq(engine.lastMarkPrice(), price, "frozen liquidation uses the unchanged cached mark");
    }

    function _closeHalf(
        bool frozen,
        uint256 price
    ) private {
        uint256 claimBefore = engine.traderClaimBalanceAssets(ACCOUNT);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(CfdTypes.Side.LONG, SIZE / 2, 0, 0, true);
        bytes[] memory updateData;
        if (frozen) {
            vm.warp(vm.getBlockTimestamp() + 1);
            vm.roll(vm.getBlockNumber() + 1);
            updateData = new bytes[](0);
        } else {
            updateData = _mockPythUpdateData(price);
        }
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(id, updateData);
        assertEq(uint8(result.terminalReason), uint8(OrderV3Types.TerminalReason.Executed));
        assertLt(engine.traderClaimBalanceAssets(ACCOUNT), claimBefore, "the claim pays the closed loss");
    }

    function _assertRetainedBuffer(
        uint256 liquidationPrice,
        uint256 maintenanceBps
    ) private view {
        (uint256 size, uint256 pledge,,,,,) = engine.positions(ACCOUNT);
        uint256 lots = size / CfdTypes.SIZE_QUANTUM;
        uint256 loss = lots * liquidationPrice - engine.positionEntryCostAssetAtoms(ACCOUNT);
        uint256 equity = pledge + engine.traderClaimBalanceAssets(ACCOUNT) - loss;
        uint256 maintenance = lots * liquidationPrice * maintenanceBps / 10_000;
        assertGt(equity, maintenance + 1e6, "the close retains a meaningful buffer above liquidation");
        assertFalse(engineLens.isLiquidatableAt(ACCOUNT, liquidationPrice, pool.totalAssets()));
    }

    function _acceptMark(
        uint256 price
    ) private {
        router.updateMarkPrice(_mockPythUpdateData(price));
        assertEq(engine.lastMarkPrice(), price);
    }

    function _createClaim() private {
        _fundTrader(ACCOUNT, 20_000e6);
        _open(ACCOUNT, CfdTypes.Side.LONG, SIZE, 1000e6, 120_000_000);
        uint256 cash = settlementToken.balanceOf(address(pool));
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), cash);
        _close(ACCOUNT, CfdTypes.Side.LONG, SIZE, 110_000_000);
        assertEq(engine.traderClaimBalanceAssets(ACCOUNT), 995_600_000);
        settlementToken.mint(address(pool), cash);
        if (engine.degradedMode()) {
            engine.clearDegradedMode();
        }
    }

}
