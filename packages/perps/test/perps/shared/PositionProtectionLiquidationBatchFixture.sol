// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";

import {IPositionProtectionActions} from "@plether/perps/interfaces/IPositionProtectionActions.sol";
import {IPositionProtectionBook} from "@plether/perps/interfaces/IPositionProtectionBook.sol";
import {IPositionProtectionViews} from "@plether/perps/interfaces/IPositionProtectionViews.sol";
import {PositionProtectionTypes} from "@plether/perps/interfaces/PositionProtectionTypes.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";

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
        uint256 triggerBountyAssets;
        uint256 reservationBountyAssets;
        uint256 reservedSettlementAssets;
        uint256 freeSettlementAssets;
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
    uint256 internal constant HEALTHY_MARGIN_ASSETS = 2000e6;
    uint256 internal constant THIN_MARGIN_ASSETS = 250e6;

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
        uint256 marginAssets
    ) internal returns (uint64 protectionId) {
        _fundTrader(account, 20_000e6);
        _open(account, CfdTypes.Side.LONG, POSITION_SIZE, marginAssets, MARK_PRICE);

        PositionProtectionTypes.PositionProtectionParams memory params;
        params.stopLossTriggerPrice = LONG_STOP_LOSS;
        params.closeLimits = PositionProtectionTypes.CloseFinancialLimits({
            maxExecutionNotionalAssets: type(uint256).max,
            maxGrossAccountDebitAssets: type(uint256).max,
            maxActionChargeAssets: type(uint256).max,
            maxExplicitFeesAssets: type(uint256).max
        });
        vm.prank(account);
        protectionId = protectionActions.createPositionProtection(params);
    }

    function _solventProtectionSnapshot(
        uint64 protectionId
    ) internal view returns (SolventProtectionSnapshot memory snapshot) {
        PositionProtectionTypes.PositionProtectionView memory protection =
            protectionViews.getPositionProtection(protectionId);
        snapshot.triggerBountyAssets = protection.triggerBountyAssets;
        snapshot.reservationBountyAssets = router.getAccountReservations(SOLVENT_ACCOUNT).executionBountyAssets;
        snapshot.reservedSettlementAssets =
        clearinghouse.getLockedMarginBuckets(SOLVENT_ACCOUNT).reservedSettlementAssets;
        snapshot.freeSettlementAssets = _freeSettlementAssets(SOLVENT_ACCOUNT);
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
        assertEq(protection.triggerBountyAssets, beforeSnapshot.triggerBountyAssets, "trigger bounty must roll back");
        assertEq(
            protectionViews.activePositionProtectionId(SOLVENT_ACCOUNT),
            protectionId,
            "caught solvent revert must restore the active protection id"
        );
        IOrderRouterAccounting.AccountReservationView memory reservation =
            router.getAccountReservations(SOLVENT_ACCOUNT);
        assertEq(
            reservation.executionBountyAssets,
            beforeSnapshot.reservationBountyAssets,
            "caught solvent revert must restore reserved settlement"
        );
        assertEq(reservation.pendingOrderCount, 0, "caught solvent revert must preserve the empty order queue");
        assertEq(
            clearinghouse.getLockedMarginBuckets(SOLVENT_ACCOUNT).reservedSettlementAssets,
            beforeSnapshot.reservedSettlementAssets,
            "caught solvent revert must restore the clearinghouse reserve bucket"
        );
        assertEq(
            _freeSettlementAssets(SOLVENT_ACCOUNT),
            beforeSnapshot.freeSettlementAssets,
            "free settlement must be unchanged"
        );
        assertEq(_positionSize(SOLVENT_ACCOUNT), beforeSnapshot.positionSize, "solvent position must be unchanged");
    }

    function _refreshMark(
        uint256 price
    ) internal {
        router.updateMarkPrice(_liveProtectionData(price));
    }

    function _liveProtectionData(
        uint256 price
    ) internal returns (bytes[] memory data) {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        bytes32[] memory ids = _basePythFeedIds();
        MockPyth.FeedUpdate[] memory ticks = new MockPyth.FeedUpdate[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            ticks[i] = MockPyth.FeedUpdate(ids[i], MockPyth.MockPrice(int64(uint64(price)), 0, -8, block.timestamp, 0));
        }
        data = new bytes[](1);
        data[0] = abi.encode(ticks);
    }

    function _withdrawAllFreeSettlement(
        address account
    ) internal {
        uint256 freeSettlementAssets = _freeSettlementAssets(account);
        vm.prank(account);
        clearinghouse.withdraw(account, freeSettlementAssets);
    }

    function _totalProtectionBountyAssets() internal view returns (uint256) {
        return router.positionProtectionTriggerBountyAssets();
    }

    function _positionSize(
        address account
    ) internal view returns (uint256 size) {
        (size,,,,,,) = engine.positions(account);
    }

}
