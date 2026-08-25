// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderLifecycleBook} from "@plether/perps/OrderLifecycleBook.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderRouterLiquidationBatchSidecar} from "@plether/perps/OrderRouterLiquidationBatchSidecar.sol";
import {PositionProtectionBook} from "@plether/perps/PositionProtectionBook.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPerpsKeeper} from "@plether/perps/interfaces/IPerpsKeeper.sol";
import {IPositionProtectionActions} from "@plether/perps/interfaces/IPositionProtectionActions.sol";
import {IPositionProtectionBook} from "@plether/perps/interfaces/IPositionProtectionBook.sol";
import {IPositionProtectionViews} from "@plether/perps/interfaces/IPositionProtectionViews.sol";
import {PositionProtectionTypes} from "@plether/perps/interfaces/PositionProtectionTypes.sol";
import {Test} from "forge-std/Test.sol";

interface IDelegatedMarkRefresh {

    function updateMarkPrice(
        bytes[] calldata pythUpdateData
    ) external payable;

}

interface ILiquidationBatchSidecarErrors {

    error OrderRouterLiquidationBatchSidecar__OnlyDelegateCall();

}

contract OrderRouterInitcodeSizeTest is Test {

    uint256 internal constant EIP3860_INITCODE_LIMIT = 49_152;

    function test_OrderRouterCreationCodeAndConstructorArgsFitEip3860() public pure {
        assertLe(
            type(OrderRouter).creationCode.length + (8 * 32),
            EIP3860_INITCODE_LIMIT,
            "OrderRouter creation code plus eight static constructor arguments must fit EIP-3860"
        );
        assertLe(
            type(OrderRouterLiquidationBatchSidecar).creationCode.length + 32,
            EIP3860_INITCODE_LIMIT,
            "sidecar creation code plus its static constructor argument must fit EIP-3860"
        );
        assertLe(
            type(OrderLifecycleBook).creationCode.length + (4 * 32),
            EIP3860_INITCODE_LIMIT,
            "OrderLifecycleBook creation code plus four static constructor arguments must fit EIP-3860"
        );
        assertLe(
            type(PositionProtectionBook).creationCode.length + (2 * 32),
            EIP3860_INITCODE_LIMIT,
            "PositionProtectionBook creation code plus two static constructor arguments must fit EIP-3860"
        );
    }

}

contract PositionProtectionLiquidationBatchTest is BasePerpTest {

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
    uint256 internal constant BULL_STOP_LOSS = 110_000_000;
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

        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.positionProtectionCommitsEnabled = true;
        _setRouterConfig(config);
        _refreshMark(MARK_PRICE);
    }

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

        bytes[] memory triggerData = _mockPythUpdateData(BULL_STOP_LOSS);
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

    function test_Batch_SplitComponentBindingAndRuntimeFitsEip170() public view {
        address sidecar = router.liquidationBatchSidecar();
        address book = address(protectionBook);
        assertNotEq(sidecar, book, "keeper sidecar and state-owning protection Book must be separate contracts");
        assertEq(
            OrderRouterLiquidationBatchSidecar(sidecar).ROUTER(), address(router), "sidecar must bind the exact Router"
        );
        assertEq(PositionProtectionBook(book).ROUTER(), address(router), "Book must bind the exact Router");
        assertLe(
            vm.getDeployedCode("OrderRouter.sol:OrderRouter").length,
            EIP170_RUNTIME_CODE_LIMIT,
            "production OrderRouter runtime must fit EIP-170"
        );
        assertGt(sidecar.code.length, 0, "keeper sidecar must be deployed");
        assertLe(sidecar.code.length, EIP170_RUNTIME_CODE_LIMIT, "keeper sidecar runtime must fit EIP-170");
        assertGt(book.code.length, 0, "PositionProtectionBook must be deployed");
        assertLe(book.code.length, EIP170_RUNTIME_CODE_LIMIT, "PositionProtectionBook runtime must fit EIP-170");
    }

    function _openAndProtect(
        address account,
        uint256 marginUsdc
    ) internal returns (uint64 protectionId) {
        _fundTrader(account, 20_000e6);
        _open(account, CfdTypes.Side.BULL, POSITION_SIZE, marginUsdc, MARK_PRICE);

        PositionProtectionTypes.PositionProtectionParams memory params;
        params.stopLossTriggerPrice = BULL_STOP_LOSS;
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
