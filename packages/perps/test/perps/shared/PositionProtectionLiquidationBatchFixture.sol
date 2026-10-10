// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";

import {IPositionProtectionActions} from "@plether/perps/interfaces/IPositionProtectionActions.sol";
import {IPositionProtectionBook} from "@plether/perps/interfaces/IPositionProtectionBook.sol";
import {IPositionProtectionViews} from "@plether/perps/interfaces/IPositionProtectionViews.sol";
import {PositionProtectionTypes} from "@plether/perps/interfaces/PositionProtectionTypes.sol";

interface IDelegatedMarkRefresh {

    function updateMarkPrice(
        bytes[] calldata pythUpdateData
    ) external payable;

}

interface ILiquidationBatchSidecarErrors {

    error OrderRouterLiquidationBatchSidecar__OnlyDelegateCall();

}

abstract contract PositionProtectionLiquidationBatchTestFixture is BasePerpTest {

    struct SolventProtectionSnapshot {
        uint256 triggerBountyUsdc;
        uint256 executionBountyUsdc;
        uint256 reservationBountyUsdc;
        uint256 reservedSettlementUsdc;
        uint256 freeSettlementUsdc;
        uint256 positionSize;
    }

    uint256 internal constant EIP170_RUNTIME_CODE_LIMIT = 24_576;
    IPositionProtectionBook internal protectionBook;
    IPositionProtectionActions internal protectionActions;
    IPositionProtectionViews internal protectionViews;

    uint256 internal constant MARK_PRICE = 100_000_000;
    uint256 internal constant LIQUIDATION_PRICE = 102_000_000;
    uint256 internal constant DEEP_LIQUIDATION_PRICE = 150_000_000;
    uint256 internal constant LONG_STOP_LOSS = 110_000_000;
    uint256 internal constant POSITION_SIZE = 10_000e18;
    uint256 internal constant HEALTHY_MARGIN_USDC = 2000e6;
    uint256 internal constant THIN_MARGIN_USDC = 250e6;

    address internal constant ARMED_ACCOUNT = address(0xB47C1001);
    address internal constant SOLVENT_ACCOUNT = address(0xB47C1002);
    address internal constant LATER_LIQUIDATION = address(0xB47C1003);
    address internal constant TRIGGERED_ACCOUNT = address(0xB47C1004);
    address internal constant TRIGGER_KEEPER = address(0xB47C7106);
    address internal constant LIQUIDATION_KEEPER = address(0xB47CB0B0);

    function setUp() public override {
        super.setUp();

        protectionBook = router.positionProtectionBook();
        protectionActions = IPositionProtectionActions(address(protectionBook));
        protectionViews = IPositionProtectionViews(address(protectionBook));

        _refreshMark(MARK_PRICE);
    }

    function _openAndProtect(
        address account,
        uint256 marginUsdc
    ) internal returns (uint64 protectionId) {
        _fundTrader(account, 20_000e6);
        _open(account, CfdTypes.Side.LONG, POSITION_SIZE, marginUsdc, MARK_PRICE);

        PositionProtectionTypes.PositionProtectionParams memory params;
        params.stopLossTriggerPrice = LONG_STOP_LOSS;
        vm.prank(account);
        protectionId = protectionActions.createPositionProtection(params);
    }

    function _solventProtectionSnapshot(
        uint64 protectionId
    ) internal view returns (SolventProtectionSnapshot memory snapshot) {
        PositionProtectionTypes.PositionProtectionView memory protection =
            protectionViews.getPositionProtection(protectionId);
        snapshot.triggerBountyUsdc = protection.triggerBountyUsdc;
        snapshot.executionBountyUsdc = protection.executionBountyUsdc;
        snapshot.reservationBountyUsdc = router.getAccountReservations(SOLVENT_ACCOUNT).executionBountyUsdc;
        snapshot.reservedSettlementUsdc = clearinghouse.getLockedMarginBuckets(SOLVENT_ACCOUNT).reservedSettlementUsdc;
        snapshot.freeSettlementUsdc = _freeSettlementUsdc(SOLVENT_ACCOUNT);
        snapshot.positionSize = _positionSize(SOLVENT_ACCOUNT);
    }

    function _assertSolventProtectionUnchanged(
        uint64 protectionId,
        SolventProtectionSnapshot memory beforeSnapshot
    ) internal view {
        PositionProtectionTypes.PositionProtectionView memory protection =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(protection.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Armed),
            "caught solvent revert must restore Book status"
        );
        assertEq(protection.triggerBountyUsdc, beforeSnapshot.triggerBountyUsdc, "trigger bounty must roll back");
        assertEq(protection.executionBountyUsdc, beforeSnapshot.executionBountyUsdc, "execution bounty must roll back");
        assertEq(
            protectionViews.activePositionProtectionId(SOLVENT_ACCOUNT),
            protectionId,
            "caught solvent revert must restore the active protection id"
        );
        IOrderRouterAccounting.AccountReservationView memory reservation =
            router.getAccountReservations(SOLVENT_ACCOUNT);
        assertEq(
            reservation.executionBountyUsdc,
            beforeSnapshot.reservationBountyUsdc,
            "caught solvent revert must restore reserved settlement"
        );
        assertEq(reservation.pendingOrderCount, 0, "caught solvent revert must preserve the empty order queue");
        assertEq(
            clearinghouse.getLockedMarginBuckets(SOLVENT_ACCOUNT).reservedSettlementUsdc,
            beforeSnapshot.reservedSettlementUsdc,
            "caught solvent revert must restore the clearinghouse reserve bucket"
        );
        assertEq(
            _freeSettlementUsdc(SOLVENT_ACCOUNT), beforeSnapshot.freeSettlementUsdc, "free settlement must be unchanged"
        );
        assertEq(_positionSize(SOLVENT_ACCOUNT), beforeSnapshot.positionSize, "solvent position must be unchanged");
    }

    function _refreshMark(
        uint256 price
    ) internal {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = abi.encode(price);
        router.updateMarkPrice(updateData);
    }

    function _withdrawAllFreeSettlement(
        address account
    ) internal {
        uint256 freeSettlementUsdc = _freeSettlementUsdc(account);
        vm.prank(account);
        clearinghouse.withdraw(account, freeSettlementUsdc);
    }

    function _totalProtectionBountyUsdc() internal view returns (uint256) {
        return router.positionProtectionTriggerBountyUsdc() + router.closeOrderExecutionBountyUsdc();
    }

    function _positionSize(
        address account
    ) internal view returns (uint256 size) {
        (size,,,,,,) = engine.positions(account);
    }

}
