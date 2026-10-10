// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPerpsKeeper} from "@plether/perps/interfaces/IPerpsKeeper.sol";

import {PositionProtectionTypes} from "@plether/perps/interfaces/PositionProtectionTypes.sol";

import {
    IDelegatedMarkRefresh,
    ILiquidationBatchSidecarErrors,
    PositionProtectionLiquidationBatchTestFixture
} from "../../shared/PositionProtectionLiquidationBatchFixture.sol";

contract PositionProtectionLiquidationBatchTest is PositionProtectionLiquidationBatchTestFixture {

    function test_Batch_ArmedProtectionTerminalizesAndForfeitsBountiesExactlyOnce() public {
        uint64 protectionId = _openAndProtect(ARMED_ACCOUNT, THIN_MARGIN_USDC);
        _withdrawAllFreeSettlement(ARMED_ACCOUNT);

        uint256 expectedForfeitureUsdc = _totalProtectionBountyUsdc();
        uint256 treasuryBefore = _settlementBalance(engine.protocolTreasury());

        address[] memory accounts = new address[](2);
        accounts[0] = ARMED_ACCOUNT;
        accounts[1] = ARMED_ACCOUNT;
        bytes[] memory updateData = _mockPythUpdateData(DEEP_LIQUIDATION_PRICE);

        vm.prank(LIQUIDATION_KEEPER);
        uint256 nextIndex = IPerpsKeeper(address(router)).executeLiquidationBatch(accounts, updateData);

        PositionProtectionTypes.PositionProtectionView memory protection =
            protectionViews.getPositionProtection(protectionId);
        assertEq(nextIndex, accounts.length, "duplicate must be attempted and skipped after the first liquidation");
        assertEq(
            uint8(protection.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Liquidated),
            "successful batch liquidation must terminalize armed protection"
        );
        assertEq(protection.triggerBountyUsdc, 0, "trigger bounty must be consumed");
        assertEq(protection.executionBountyUsdc, 0, "execution bounty must be consumed");
        assertEq(protectionViews.activePositionProtectionId(ARMED_ACCOUNT), 0, "trade lock must be released");
        assertEq(router.getAccountReservations(ARMED_ACCOUNT).executionBountyUsdc, 0, "reserve must be clear");
        assertEq(
            clearinghouse.getLockedMarginBuckets(ARMED_ACCOUNT).reservedSettlementUsdc,
            0,
            "clearinghouse reserve must be clear"
        );
        assertEq(_positionSize(ARMED_ACCOUNT), 0, "position must be liquidated");
        assertEq(
            _settlementBalance(engine.protocolTreasury()) - treasuryBefore,
            expectedForfeitureUsdc,
            "duplicate batch item must not forfeit protection bounties twice"
        );
    }

    function test_Batch_SolventItemRollsBackBookAndReserveBeforeLaterProtectedSuccess() public {
        uint64 solventProtectionId = _openAndProtect(SOLVENT_ACCOUNT, HEALTHY_MARGIN_USDC);
        uint64 liquidatedProtectionId = _openAndProtect(LATER_LIQUIDATION, THIN_MARGIN_USDC);
        _withdrawAllFreeSettlement(LATER_LIQUIDATION);

        SolventProtectionSnapshot memory solventBefore = _solventProtectionSnapshot(solventProtectionId);
        uint256 treasuryBefore = _settlementBalance(engine.protocolTreasury());

        assertFalse(
            engineLens.previewLiquidation(SOLVENT_ACCOUNT, LIQUIDATION_PRICE).liquidatable,
            "healthy account must enter the caught solvent path"
        );
        assertTrue(
            engineLens.previewLiquidation(LATER_LIQUIDATION, LIQUIDATION_PRICE).liquidatable,
            "later thin account must be liquidatable"
        );

        address[] memory accounts = new address[](2);
        accounts[0] = SOLVENT_ACCOUNT;
        accounts[1] = LATER_LIQUIDATION;
        bytes[] memory updateData = _mockPythUpdateData(LIQUIDATION_PRICE);

        vm.prank(LIQUIDATION_KEEPER);
        uint256 nextIndex = IPerpsKeeper(address(router)).executeLiquidationBatch(accounts, updateData);

        PositionProtectionTypes.PositionProtectionView memory liquidated =
            protectionViews.getPositionProtection(liquidatedProtectionId);

        assertEq(nextIndex, accounts.length, "solvent skip must not stop later processing");
        _assertSolventProtectionUnchanged(solventProtectionId, solventBefore);

        assertEq(
            uint8(liquidated.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Liquidated),
            "later protected item must still terminalize"
        );
        assertEq(_positionSize(LATER_LIQUIDATION), 0, "later protected position must liquidate");
        assertEq(
            _settlementBalance(engine.protocolTreasury()) - treasuryBefore,
            _totalProtectionBountyUsdc(),
            "only the successful item's protection bounties may be forfeited"
        );
    }

    function test_Batch_TriggeredProtectionCleansLinkedCloseAndForfeitsItsBountyExactlyOnce() public {
        uint64 protectionId = _openAndProtect(TRIGGERED_ACCOUNT, HEALTHY_MARGIN_USDC);
        _withdrawAllFreeSettlement(TRIGGERED_ACCOUNT);

        bytes[] memory triggerData = _mockPythUpdateData(LONG_STOP_LOSS);
        vm.prank(TRIGGER_KEEPER);
        uint64 linkedOrderId = protectionActions.triggerPositionProtection(protectionId, triggerData);
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Triggered),
            "setup must trigger protection"
        );

        uint256 treasuryBefore = _settlementBalance(engine.protocolTreasury());
        address[] memory accounts = new address[](2);
        accounts[0] = TRIGGERED_ACCOUNT;
        accounts[1] = TRIGGERED_ACCOUNT;
        bytes[] memory liquidationData = _mockPythUpdateData(DEEP_LIQUIDATION_PRICE);

        vm.prank(LIQUIDATION_KEEPER);
        IPerpsKeeper(address(router)).executeLiquidationBatch(accounts, liquidationData);

        PositionProtectionTypes.PositionProtectionView memory protection =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(protection.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Liquidated),
            "triggered protection must terminalize as liquidated"
        );
        assertEq(protectionViews.activePositionProtectionId(TRIGGERED_ACCOUNT), 0, "trade lock must be released");
        assertEq(
            uint8(_orderRecord(linkedOrderId).status),
            uint8(IOrderRouterAccounting.OrderStatus.Failed),
            "linked close must terminally fail during liquidation cleanup"
        );
        assertEq(_orderRecord(linkedOrderId).executionBountyUsdc, 0, "linked close bounty must be consumed");
        assertEq(router.pendingOrderCounts(TRIGGERED_ACCOUNT), 0, "linked close must be unlinked");
        assertEq(router.pendingCloseSize(TRIGGERED_ACCOUNT), 0, "linked close size must be released");
        assertEq(router.getAccountReservations(TRIGGERED_ACCOUNT).executionBountyUsdc, 0, "reserve must be clear");
        assertEq(
            clearinghouse.getLockedMarginBuckets(TRIGGERED_ACCOUNT).reservedSettlementUsdc,
            0,
            "clearinghouse reserve must be clear"
        );
        assertEq(_positionSize(TRIGGERED_ACCOUNT), 0, "position must be liquidated");
        assertEq(
            _settlementBalance(engine.protocolTreasury()) - treasuryBefore,
            router.closeOrderExecutionBountyUsdc(),
            "duplicate batch item must not forfeit the linked-close bounty twice"
        );
    }

    function test_Batch_DirectCallToSidecarUsesPreservedDelegateRejection() public {
        address[] memory accounts = new address[](1);
        accounts[0] = ARMED_ACCOUNT;
        bytes[] memory updateData = new bytes[](0);
        address sidecar = router.liquidationBatchSidecar();

        vm.expectRevert(ILiquidationBatchSidecarErrors.OrderRouterLiquidationBatchSidecar__OnlyDelegateCall.selector);
        IPerpsKeeper(sidecar).executeLiquidationBatch(accounts, updateData);
    }

    function test_DelegatedMarkRefresh_DirectCallToSidecarRevertsUnauthorized() public {
        bytes[] memory updateData = new bytes[](0);
        address sidecar = router.liquidationBatchSidecar();

        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        IDelegatedMarkRefresh(sidecar).updateMarkPrice(updateData);
    }

    function test_DelegatedLpSettlement_DirectCallToSidecarRevertsUnauthorized() public {
        bytes[] memory updateData = new bytes[](0);
        address sidecar = router.liquidationBatchSidecar();

        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        IPerpsKeeper(sidecar).settleLpEpoch(updateData);
    }

    function test_DelegatedSingleLiquidation_DirectCallToSidecarRevertsUnauthorized() public {
        bytes[] memory updateData = new bytes[](0);
        address sidecar = router.liquidationBatchSidecar();

        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        IPerpsKeeper(sidecar).executeLiquidation(ARMED_ACCOUNT, updateData);
    }

    function test_ProtectionTriggerItem_DirectExternalRouterCallRevertsUnauthorized() public {
        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        router.executePositionProtectionTriggerItem();
    }

}
