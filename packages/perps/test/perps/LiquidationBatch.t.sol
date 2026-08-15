// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPerpsKeeper} from "@plether/perps/interfaces/IPerpsKeeper.sol";
import {Vm} from "forge-std/Vm.sol";

contract LiquidationBatchTest is BasePerpTest {

    uint256 internal constant EIP170_RUNTIME_CODE_LIMIT = 24_576;
    uint256 internal constant LIQUIDATION_PRICE = 102_000_000;
    uint256 internal constant NEUTRAL_PRICE = 100_000_000;
    uint256 internal constant BULL_ADVERSE_PRICE = 100_020_000;
    uint256 internal constant BEAR_ADVERSE_PRICE = 99_980_000;
    uint256 internal constant SATURDAY_NOON = 1_710_021_600;

    address internal constant ELIGIBLE_ONE = address(0xBA7C0001);
    address internal constant SOLVENT = address(0xBA7C0002);
    address internal constant NO_POSITION = address(0xBA7C0003);
    address internal constant ELIGIBLE_TWO = address(0xBA7C0004);
    address internal constant KEEPER = address(0xBA7CB0B0);

    bytes32 internal constant POSITION_LIQUIDATED_TOPIC =
        keccak256("PositionLiquidated(address,uint8,uint256,uint256,uint256)");

    function test_Batch_OrderRouterRuntimeFitsEip170() public view {
        assertLe(
            address(router).code.length, EIP170_RUNTIME_CODE_LIMIT, "batch entrypoint must keep OrderRouter deployable"
        );
    }

    function test_Batch_MixedEligibilitySkipsIndependentlyAndPaysExactBountySum() public {
        _fundAndOpenThinBull(ELIGIBLE_ONE);
        _fundAndOpenThinBull(ELIGIBLE_TWO);

        _fundTrader(SOLVENT, 2000e6);
        _open(SOLVENT, CfdTypes.Side.BULL, 10_000e18, 250e6, NEUTRAL_PRICE);

        _fundTrader(NO_POSITION, 1000e6);
        uint64 solventOrderId = _queueOpen(SOLVENT, 200e6);
        uint64 noPositionOrderId = _queueOpen(NO_POSITION, 500e6);

        IOrderRouterAccounting.AccountReservationView memory solventReservationBefore =
            router.getAccountReservations(SOLVENT);
        IOrderRouterAccounting.AccountReservationView memory noPositionReservationBefore =
            router.getAccountReservations(NO_POSITION);
        uint256 solventSettlementBefore = _settlementBalance(SOLVENT);
        uint256 noPositionSettlementBefore = _settlementBalance(NO_POSITION);
        (uint256 solventSizeBefore,,,,,,) = engine.positions(SOLVENT);

        ICfdEngineTypes.LiquidationPreview memory firstPreview =
            engineLens.previewLiquidation(ELIGIBLE_ONE, LIQUIDATION_PRICE);
        ICfdEngineTypes.LiquidationPreview memory secondPreview =
            engineLens.previewLiquidation(ELIGIBLE_TWO, LIQUIDATION_PRICE);
        assertTrue(firstPreview.liquidatable, "first setup account must be liquidatable");
        assertTrue(secondPreview.liquidatable, "second setup account must be liquidatable");
        assertFalse(
            engineLens.previewLiquidation(SOLVENT, LIQUIDATION_PRICE).liquidatable,
            "solvent setup account must be skipped"
        );

        address[] memory accounts = new address[](5);
        accounts[0] = ELIGIBLE_ONE;
        accounts[1] = SOLVENT;
        accounts[2] = NO_POSITION;
        accounts[3] = ELIGIBLE_ONE;
        accounts[4] = ELIGIBLE_TWO;

        bytes[] memory updateData = _mockPythUpdateData(LIQUIDATION_PRICE);
        uint256 pythCallsBefore = baseMockPyth.updatePriceFeedsCallCount();
        uint256 keeperSettlementBefore = _settlementBalance(KEEPER);
        uint256 routerSettlementBefore = _settlementBalance(address(router));

        vm.prank(KEEPER);
        IPerpsKeeper(address(router)).executeLiquidationBatch(accounts, updateData);

        assertEq(
            baseMockPyth.updatePriceFeedsCallCount() - pythCallsBefore, 1, "the batch must update Pyth exactly once"
        );
        assertEq(_positionSize(ELIGIBLE_ONE), 0, "first eligible account must liquidate");
        assertEq(_positionSize(ELIGIBLE_TWO), 0, "later eligible account must survive earlier skips");
        assertEq(_positionSize(SOLVENT), solventSizeBefore, "solvent account position must remain unchanged");

        assertEq(
            _settlementBalance(KEEPER) - keeperSettlementBefore,
            firstPreview.keeperBountyUsdc + secondPreview.keeperBountyUsdc,
            "keeper must receive exactly one bounty per successful unique account"
        );
        assertEq(
            _settlementBalance(address(router)),
            routerSettlementBefore,
            "self-call isolation must not credit liquidation bounty to the router"
        );

        _assertReservationUnchanged(SOLVENT, solventReservationBefore);
        _assertReservationUnchanged(NO_POSITION, noPositionReservationBefore);
        assertEq(_settlementBalance(SOLVENT), solventSettlementBefore, "solvent settlement must remain unchanged");
        assertEq(
            _settlementBalance(NO_POSITION), noPositionSettlementBefore, "no-position settlement must remain unchanged"
        );
        assertEq(
            uint256(_orderRecord(solventOrderId).status),
            uint256(IOrderRouterAccounting.OrderStatus.Pending),
            "solvent account order must remain pending"
        );
        assertEq(
            uint256(_orderRecord(noPositionOrderId).status),
            uint256(IOrderRouterAccounting.OrderStatus.Pending),
            "no-position account order must remain pending"
        );
    }

    function test_Batch_SuccessForfeitsQueuedBountyAndClearsOrders() public {
        address account = address(0xBA7CB017);
        _fundAndOpenThinBull(account);

        uint64 orderId = router.nextCommitId();
        vm.startPrank(account);
        for (uint256 i = 0; i < 5; i++) {
            router.commitOrder(CfdTypes.Side.BULL, 2000e18, 0, 0, true);
        }
        vm.stopPrank();

        uint256 forfeitedBountyUsdc = router.getAccountReservations(account).executionBountyUsdc;
        uint256 treasuryBefore = _settlementBalance(engine.protocolTreasury());
        uint256 keeperBefore = _settlementBalance(KEEPER);
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, LIQUIDATION_PRICE);
        assertTrue(preview.liquidatable, "queued-order account must be liquidatable");

        address[] memory accounts = new address[](1);
        accounts[0] = account;
        bytes[] memory updateData = _mockPythUpdateData(LIQUIDATION_PRICE);

        vm.prank(KEEPER);
        uint256 nextIndex = IPerpsKeeper(address(router)).executeLiquidationBatch(accounts, updateData);

        assertEq(nextIndex, 1, "successful batch must consume the account");
        assertEq(_positionSize(account), 0, "successful batch must clear the position");
        assertEq(router.pendingOrderCounts(account), 0, "successful batch must clear queued orders");
        assertEq(
            uint256(_orderRecord(orderId).status),
            uint256(IOrderRouterAccounting.OrderStatus.Failed),
            "liquidation must terminally fail the queued order"
        );
        assertEq(
            _settlementBalance(engine.protocolTreasury()) - treasuryBefore,
            forfeitedBountyUsdc,
            "queued execution bounty must be forfeited to protocol treasury"
        );
        assertEq(
            _settlementBalance(KEEPER) - keeperBefore,
            preview.keeperBountyUsdc,
            "liquidation bounty must still be credited to the original keeper"
        );
    }

    function test_Batch_MaxPendingOrdersLiquidatesWithinItemGasBudget() public {
        uint256 maxPendingOrders = 32;
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxPendingOrders = maxPendingOrders;
        _setRouterConfig(config);

        address account = address(0xBA7C0032);
        _fundTrader(account, 270e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 200e6, NEUTRAL_PRICE);

        uint64 firstOrderId = router.nextCommitId();
        vm.startPrank(account);
        for (uint256 i = 0; i < maxPendingOrders; i++) {
            router.commitOrder(CfdTypes.Side.BULL, 100e18, 2e6, type(uint256).max, false);
        }
        vm.stopPrank();

        IOrderRouterAccounting.AccountReservationView memory reservationBefore = router.getAccountReservations(account);
        assertEq(reservationBefore.pendingOrderCount, maxPendingOrders, "setup must reach the configured order cap");
        assertEq(reservationBefore.committedMarginUsdc, 64e6, "setup must reserve every order's committed margin");
        assertGt(reservationBefore.executionBountyUsdc, 0, "setup must reserve execution bounties");

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, LIQUIDATION_PRICE);
        assertTrue(preview.liquidatable, "maximum-order setup account must be liquidatable");

        address[] memory accounts = new address[](1);
        accounts[0] = account;
        bytes[] memory updateData = _mockPythUpdateData(LIQUIDATION_PRICE);
        uint256 treasuryBefore = _settlementBalance(engine.protocolTreasury());
        uint256 keeperBefore = _settlementBalance(KEEPER);
        uint256 pythCallsBefore = baseMockPyth.updatePriceFeedsCallCount();

        vm.prank(KEEPER);
        uint256 nextIndex = IPerpsKeeper(address(router)).executeLiquidationBatch(accounts, updateData);

        assertEq(nextIndex, 1, "maximum-order item must complete within its calculated gas cap");
        assertEq(_positionSize(account), 0, "maximum-order account must liquidate");
        assertEq(router.pendingOrderCounts(account), 0, "all live orders must be removed");
        assertEq(router.accountHeadOrderId(account), 0, "account queue head must be clear");

        IOrderRouterAccounting.AccountReservationView memory reservationAfter = router.getAccountReservations(account);
        assertEq(reservationAfter.committedMarginUsdc, 0, "committed margin reservation must be clear");
        assertEq(reservationAfter.executionBountyUsdc, 0, "execution bounty reservation must be clear");
        assertEq(reservationAfter.pendingOrderCount, 0, "pending order reservation count must be clear");

        for (uint256 i = 0; i < maxPendingOrders; i++) {
            uint64 orderId = firstOrderId + uint64(i);
            assertEq(
                uint256(_orderRecord(orderId).status),
                uint256(IOrderRouterAccounting.OrderStatus.Failed),
                "every queued order must terminally fail"
            );
            assertEq(_remainingCommittedMargin(orderId), 0, "every committed margin reservation must be released");
            assertEq(_orderRecord(orderId).executionBountyUsdc, 0, "every execution bounty must be cleared");
        }
        assertEq(
            _settlementBalance(engine.protocolTreasury()) - treasuryBefore,
            reservationBefore.executionBountyUsdc,
            "all queued bounties must be forfeited to protocol treasury"
        );
        assertEq(
            _settlementBalance(KEEPER) - keeperBefore,
            preview.keeperBountyUsdc,
            "keeper must receive the liquidation bounty"
        );
        assertEq(
            baseMockPyth.updatePriceFeedsCallCount() - pythCallsBefore,
            1,
            "maximum-order liquidation must still share one Pyth update"
        );
    }

    function test_Batch_UnexpectedPerAccountRevertDoesNotRollBackLaterSuccess() public {
        address failingAccount = address(0xBA7CFA11);
        address succeedingAccount = address(0xBA7C600D);
        _fundAndOpenThinBull(failingAccount);
        _fundAndOpenThinBull(succeedingAccount);

        ICfdEngineTypes.LiquidationPreview memory succeedingPreview =
            engineLens.previewLiquidation(succeedingAccount, LIQUIDATION_PRICE);
        assertTrue(succeedingPreview.liquidatable, "success setup account must be liquidatable");

        vm.mockCallRevert(
            address(engine),
            abi.encodeWithSelector(engine.liquidatePosition.selector, failingAccount),
            abi.encodeWithSignature("Error(string)", "forced per-account failure")
        );

        address[] memory accounts = new address[](2);
        accounts[0] = failingAccount;
        accounts[1] = succeedingAccount;
        bytes[] memory updateData = _mockPythUpdateData(LIQUIDATION_PRICE);
        uint256 keeperSettlementBefore = _settlementBalance(KEEPER);
        uint256 pythCallsBefore = baseMockPyth.updatePriceFeedsCallCount();

        vm.prank(KEEPER);
        IPerpsKeeper(address(router)).executeLiquidationBatch(accounts, updateData);

        assertEq(_positionSize(failingAccount), 10_000e18, "failed item must roll back only its own state");
        assertEq(_positionSize(succeedingAccount), 0, "later item must still succeed");
        assertEq(
            _settlementBalance(KEEPER) - keeperSettlementBefore,
            succeedingPreview.keeperBountyUsdc,
            "failed item must not pay a bounty"
        );
        assertEq(
            baseMockPyth.updatePriceFeedsCallCount() - pythCallsBefore,
            1,
            "per-account failure must not trigger another Pyth update"
        );
    }

    function test_Batch_EmptyItemRevertPreservesEarlierSuccessAndReturnsCurrentCursor() public {
        address firstAccount = address(0xBA7CE000);
        address failingAccount = address(0xBA7CE001);
        address laterAccount = address(0xBA7CE002);
        _fundAndOpenThinBull(firstAccount);
        _fundAndOpenThinBull(failingAccount);
        _fundAndOpenThinBull(laterAccount);

        ICfdEngineTypes.LiquidationPreview memory firstPreview =
            engineLens.previewLiquidation(firstAccount, LIQUIDATION_PRICE);
        assertTrue(firstPreview.liquidatable, "first setup account must be liquidatable");

        vm.mockCallRevert(
            address(engine), abi.encodeWithSelector(engine.liquidatePosition.selector, failingAccount), bytes("")
        );

        address[] memory accounts = new address[](3);
        accounts[0] = firstAccount;
        accounts[1] = failingAccount;
        accounts[2] = laterAccount;
        bytes[] memory updateData = _mockPythUpdateData(LIQUIDATION_PRICE);
        uint256 keeperSettlementBefore = _settlementBalance(KEEPER);
        uint256 pythCallsBefore = baseMockPyth.updatePriceFeedsCallCount();

        vm.prank(KEEPER);
        uint256 nextIndex = IPerpsKeeper(address(router)).executeLiquidationBatch(accounts, updateData);

        assertEq(nextIndex, 1, "empty revert may be OOG and must leave the current index unattempted");
        assertEq(_positionSize(firstAccount), 0, "success before an empty revert must remain committed");
        assertEq(_positionSize(failingAccount), 10_000e18, "empty-revert account state must roll back");
        assertEq(_positionSize(laterAccount), 10_000e18, "later account must remain unattempted");
        assertEq(
            _settlementBalance(KEEPER) - keeperSettlementBefore,
            firstPreview.keeperBountyUsdc,
            "only the earlier successful item may pay a bounty"
        );
        assertEq(
            baseMockPyth.updatePriceFeedsCallCount() - pythCallsBefore,
            1,
            "empty item revert must not roll back or repeat the shared oracle update"
        );
    }

    function test_Batch_BullAndBearUseDirectionalAdversePricesButStoreNeutralMark() public {
        address bull = address(0xBA7CB011);
        address bear = address(0xBA7CBEA2);

        _fundTrader(bull, 2100e6);
        _fundTrader(bear, 2100e6);
        _open(bull, CfdTypes.Side.BULL, 100_000e18, 2000e6, NEUTRAL_PRICE);
        _open(bear, CfdTypes.Side.BEAR, 100_000e18, 2000e6, NEUTRAL_PRICE);

        vm.warp(SATURDAY_NOON);
        assertTrue(engine.isOracleFrozen(), "setup must use the frozen FAD oracle policy");

        baseMockPyth.setAllPrices(
            _basePythFeedIds(), int64(uint64(NEUTRAL_PRICE)), uint64(100_000), int32(-8), block.timestamp
        );
        assertTrue(
            engineLens.previewLiquidation(bull, BULL_ADVERSE_PRICE).liquidatable, "FAD bull setup must be liquidatable"
        );
        assertTrue(
            engineLens.previewLiquidation(bear, BEAR_ADVERSE_PRICE).liquidatable, "FAD bear setup must be liquidatable"
        );

        address[] memory accounts = new address[](2);
        accounts[0] = bull;
        accounts[1] = bear;
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"00";
        uint256 pythCallsBefore = baseMockPyth.updatePriceFeedsCallCount();

        vm.recordLogs();
        vm.prank(KEEPER);
        IPerpsKeeper(address(router)).executeLiquidationBatch(accounts, updateData);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool foundBull, CfdTypes.Side bullSide, uint256 bullPrice) = _liquidationEvent(logs, bull);
        (bool foundBear, CfdTypes.Side bearSide, uint256 bearPrice) = _liquidationEvent(logs, bear);

        assertTrue(foundBull, "bull liquidation event must be emitted");
        assertTrue(foundBear, "bear liquidation event must be emitted");
        assertEq(uint256(bullSide), uint256(CfdTypes.Side.BULL), "bull event side");
        assertEq(uint256(bearSide), uint256(CfdTypes.Side.BEAR), "bear event side");
        assertEq(bullPrice, BULL_ADVERSE_PRICE, "bull must execute above the neutral basket");
        assertEq(bearPrice, BEAR_ADVERSE_PRICE, "bear must execute below the neutral basket");
        assertEq(engine.lastMarkPrice(), NEUTRAL_PRICE, "global mark must remain the neutral basket price");
        assertEq(engine.lastMarkTime(), SATURDAY_NOON, "global mark must use the shared publish time");
        assertEq(
            baseMockPyth.updatePriceFeedsCallCount() - pythCallsBefore,
            1,
            "both directional prices must come from one Pyth update"
        );
    }

    function test_Batch_EmptyAccountsRevertsBeforePythUpdate() public {
        address[] memory accounts = new address[](0);
        bytes[] memory updateData = new bytes[](0);
        uint256 pythCallsBefore = baseMockPyth.updatePriceFeedsCallCount();

        vm.expectRevert();
        IPerpsKeeper(address(router)).executeLiquidationBatch(accounts, updateData);

        assertEq(
            baseMockPyth.updatePriceFeedsCallCount(), pythCallsBefore, "empty batch must reject before oracle work"
        );
    }

    function test_Batch_MoreThan256AccountsRevertsBeforePythUpdate() public {
        address[] memory accounts = new address[](257);
        bytes[] memory updateData = new bytes[](0);
        uint256 pythCallsBefore = baseMockPyth.updatePriceFeedsCallCount();

        vm.expectRevert();
        IPerpsKeeper(address(router)).executeLiquidationBatch(accounts, updateData);

        assertEq(
            baseMockPyth.updatePriceFeedsCallCount(), pythCallsBefore, "oversized batch must reject before oracle work"
        );
    }

    function test_Batch_LowGasReturnsSameUnattemptedIndex() public {
        address unattemptedAccount = address(0xBA7C10A6);
        _fundTrader(unattemptedAccount, 2000e6);
        for (uint256 i = 0; i < 5; i++) {
            _queueOpen(unattemptedAccount, 200e6);
        }

        IOrderRouterAccounting.AccountReservationView memory reservationBefore =
            router.getAccountReservations(unattemptedAccount);
        address[] memory accounts = new address[](1);
        accounts[0] = unattemptedAccount;
        bytes[] memory updateData = _mockPythUpdateData(NEUTRAL_PRICE);
        uint256 pythCallsBefore = baseMockPyth.updatePriceFeedsCallCount();

        vm.prank(KEEPER);
        uint256 nextIndex = IPerpsKeeper(address(router)).executeLiquidationBatch{gas: 1_200_000}(accounts, updateData);

        assertEq(nextIndex, 0, "gas-starved item must remain the first unattempted index");
        assertEq(_positionSize(unattemptedAccount), 0, "unattempted account position state must remain unchanged");
        _assertReservationUnchanged(unattemptedAccount, reservationBefore);
        assertEq(
            baseMockPyth.updatePriceFeedsCallCount() - pythCallsBefore,
            1,
            "shared oracle update must complete before the clean low-gas stop"
        );
    }

    function test_BatchItem_DirectCallRevertsUnauthorized() public {
        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        router.executeLiquidationBatchItem(ELIGIBLE_ONE, NEUTRAL_PRICE, NEUTRAL_PRICE, uint64(block.timestamp), KEEPER);
    }

    function _fundAndOpenThinBull(
        address account
    ) internal {
        _fundTrader(account, 300e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 250e6, NEUTRAL_PRICE);
    }

    function _queueOpen(
        address account,
        uint256 marginUsdc
    ) internal returns (uint64 orderId) {
        orderId = router.nextCommitId();
        vm.prank(account);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, marginUsdc, type(uint256).max, false);
    }

    function _positionSize(
        address account
    ) internal view returns (uint256 size) {
        (size,,,,,,) = engine.positions(account);
    }

    function _assertReservationUnchanged(
        address account,
        IOrderRouterAccounting.AccountReservationView memory expected
    ) internal view {
        IOrderRouterAccounting.AccountReservationView memory actual = router.getAccountReservations(account);
        assertEq(actual.committedMarginUsdc, expected.committedMarginUsdc, "committed margin reservation changed");
        assertEq(actual.executionBountyUsdc, expected.executionBountyUsdc, "execution bounty reservation changed");
        assertEq(actual.pendingOrderCount, expected.pendingOrderCount, "pending order count changed");
    }

    function _liquidationEvent(
        Vm.Log[] memory logs,
        address account
    ) internal view returns (bool found, CfdTypes.Side side, uint256 executionPrice) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter != address(engine) || logs[i].topics.length < 2
                    || logs[i].topics[0] != POSITION_LIQUIDATED_TOPIC
            ) {
                continue;
            }
            address eventAccount = address(uint160(uint256(logs[i].topics[1])));
            if (eventAccount != account) {
                continue;
            }

            uint256 size;
            uint256 keeperBounty;
            (side, size, executionPrice, keeperBounty) =
                abi.decode(logs[i].data, (CfdTypes.Side, uint256, uint256, uint256));
            size;
            keeperBounty;
            return (true, side, executionPrice);
        }
    }

}
