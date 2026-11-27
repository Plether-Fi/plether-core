// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IPositionProtectionActions} from "@plether/perps/interfaces/IPositionProtectionActions.sol";
import {IPositionProtectionViews} from "@plether/perps/interfaces/IPositionProtectionViews.sol";
import {PositionProtectionTypes} from "@plether/perps/interfaces/PositionProtectionTypes.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract DegradedStopLossVpiTest is BasePerpTest {

    using stdStorage for StdStorage;

    address private constant VICTIM = address(0x71C7);
    address private constant COUNTERPARTY = address(0xA2);
    address private constant KEEPER = address(0x4EE9);
    uint256 private constant CLOSE_PRICE = 1.6e8;
    uint256 private constant SIZE = 300 * CfdTypes.SIZE_QUANTUM;
    uint256 private constant DEPTH = 72e6;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.vpiFactor = 0.01e18;
    }

    function test_KeeperStopLossExecutesAtTinyPositiveDepthInDegradedMode() public {
        baseMockPyth.setSynchronizeLegacyUniquePrices(false);
        router.updateMarkPrice(_priceUpdate(1e8));
        _fundTrader(VICTIM, 85_005e6);
        _fundTrader(COUNTERPARTY, 18_000e6);
        _open(VICTIM, CfdTypes.Side.LONG, SIZE, 35_000e6, 1e8);
        _open(COUNTERPARTY, CfdTypes.Side.SHORT, SIZE, 18_000e6, 1e8);

        IPositionProtectionActions protection = IPositionProtectionActions(address(router.positionProtectionBook()));
        PositionProtectionTypes.PositionProtectionParams memory params;
        params.stopLossTriggerPrice = 1.55e8;
        params.closeLimits = PositionProtectionTypes.CloseFinancialLimits({
            maxExecutionNotionalAssets: type(uint256).max,
            maxGrossAccountDebitAssets: type(uint256).max,
            maxActionChargeAssets: 1000e6,
            maxExplicitFeesAssets: type(uint256).max
        });
        vm.prank(VICTIM);
        uint64 protectionId = protection.createPositionProtection(params);

        // Model a cash-drained pool while keeping the position and protection live.
        settlementToken.burn(address(pool), pool.totalAssets() - DEPTH);
        stdstore.target(address(engine)).sig("degradedMode()").checked_write(true);
        assertEq(pool.totalAssets() - engine.totalTraderClaimBalanceAssets(), DEPTH);
        assertTrue(engine.degradedMode());
        assertGt(clearinghouse.balanceAssets(VICTIM), 80_000e6);

        bytes[] memory triggerData = _priceUpdate(CLOSE_PRICE);
        vm.prank(KEEPER);
        uint64 orderId = protection.triggerPositionProtection(protectionId, triggerData);

        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(orderId, _priceUpdate(CLOSE_PRICE));
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        assertEq(
            uint8(IPositionProtectionViews(address(protection)).getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Executed)
        );
        (uint256 remainingSize,,,,,,) = engine.positions(VICTIM);
        assertEq(remainingSize, 0, "stop-loss closes the position");
        assertGt(clearinghouse.balanceAssets(VICTIM), 60_000e6, "close preserves the remaining balance");
    }

    function _priceUpdate(
        uint256 price
    ) private returns (bytes[] memory data) {
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 publication = vm.getBlockTimestamp();
        MockPyth.FeedUpdate[] memory ticks = new MockPyth.FeedUpdate[](2);
        for (uint256 i; i < ticks.length; ++i) {
            ticks[i] = MockPyth.FeedUpdate(
                bytes32(i + 1), MockPyth.MockPrice(int64(int256(price)), 0, -8, publication, publication - 1)
            );
        }
        data = new bytes[](1);
        data[0] = abi.encode(ticks);
    }

}
