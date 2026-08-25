// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IPerpsKeeper} from "@plether/perps/interfaces/IPerpsKeeper.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Keeper that uses a test-only mocked getter to simulate a cutoff advance inside the bounded Oracle callback.
contract PauseOnOracleRefundKeeper {

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    OrderRouterAdmin public immutable admin;
    uint64 public immutable callbackCutoff;

    constructor(
        OrderRouterAdmin admin_,
        uint64 callbackCutoff_
    ) {
        admin = admin_;
        callbackCutoff = callbackCutoff_;
    }

    receive() external payable {
        VM.mockCall(address(admin), bytes4(keccak256("riskOffOrderCutoff()")), abi.encode(callbackCutoff));
    }

    function executeSingle(
        address router,
        address account,
        bytes[] calldata updateData
    ) external payable {
        IPerpsKeeper(router).executeLiquidation{value: msg.value}(account, updateData);
    }

    function executeBatch(
        address router,
        address[] calldata accounts,
        bytes[] calldata updateData
    ) external payable returns (uint256 nextIndex) {
        return IPerpsKeeper(router).executeLiquidationBatch{value: msg.value}(accounts, updateData);
    }

}

/// @notice Regression coverage for cutoff changes made during liquidation-oracle ETH refunds.
contract OrderRouterRiskOffRefundCallbackTest is BasePerpTest {

    address internal constant ALICE = address(0xA11CE);
    uint256 internal constant MARK_PRICE = 1e8;
    uint256 internal constant UNSAFE_BULL_PRICE = 1.98e8;
    uint256 internal constant PYTH_FEE = 1 ether;
    uint256 internal constant OVERPAYMENT = 0.25 ether;

    function test_SingleLiquidationHonorsCutoffAdvancedDuringOracleRefund() public {
        (uint64 invalidatedOrderId, PauseOnOracleRefundKeeper keeper) = _setupCallbackLiquidation();
        bytes[] memory updateData = _mockPythUpdateData(UNSAFE_BULL_PRICE);

        vm.deal(address(this), PYTH_FEE + OVERPAYMENT);
        keeper.executeSingle{value: PYTH_FEE + OVERPAYMENT}(address(router), ALICE, updateData);

        _assertCallbackRiskOffOutcome(invalidatedOrderId, keeper);
        assertEq(_positionSize(ALICE), 0, "unsafe position must still liquidate after the refund");
    }

    function test_BatchLiquidationHonorsCutoffAdvancedDuringOracleRefund() public {
        (uint64 invalidatedOrderId, PauseOnOracleRefundKeeper keeper) = _setupCallbackLiquidation();
        bytes[] memory updateData = _mockPythUpdateData(UNSAFE_BULL_PRICE);
        address[] memory accounts = new address[](1);
        accounts[0] = ALICE;

        vm.deal(address(this), PYTH_FEE + OVERPAYMENT);
        uint256 nextIndex = keeper.executeBatch{value: PYTH_FEE + OVERPAYMENT}(address(router), accounts, updateData);

        assertEq(nextIndex, 1, "batch must attempt the callback-paused account");
        _assertCallbackRiskOffOutcome(invalidatedOrderId, keeper);
        assertEq(_positionSize(ALICE), 0, "unsafe position must still liquidate through the batch sidecar");
    }

    function test_SingleExecutionStopsAt64RiskOffRefundsBeforeOracleWork() public {
        uint64[] memory orderIds = new uint64[](65);
        for (uint256 i; i < orderIds.length; ++i) {
            address account = address(uint160(0xC000 + i));
            _fundTrader(account, 2000e6);
            orderIds[i] = router.nextCommitId();
            vm.prank(account);
            router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 1000e6, MARK_PRICE, false);
        }

        routerAdmin.pause();
        uint256 pythCallsBefore = baseMockPyth.updatePriceFeedsCallCount();

        OrderV2Types.ExecutionResult memory result = router.executeOrder(orderIds[64], new bytes[](0));

        assertEq(result.orderId, orderIds[64], "bounded call must identify the pending capped head");
        assertEq(
            uint256(result.status), uint256(OrderV2Types.LifecycleStatus.Pending), "the capped head must remain pending"
        );
        assertEq(
            uint256(result.pendingReason),
            uint256(OrderV2Types.PendingReason.CleanupLimit),
            "the result must expose the cleanup work cap"
        );

        for (uint256 i; i < 64; ++i) {
            OrderV2Types.CompactOutcome memory outcome = router.lifecycleBook().outcome(orderIds[i]);
            assertEq(
                uint256(outcome.status),
                uint256(OrderV2Types.LifecycleStatus.Failed),
                "exactly the first 64 invalidated opens must become terminal"
            );
            assertEq(
                uint256(outcome.reason),
                uint256(OrderV2Types.TerminalReason.RiskOff),
                "each completed cleanup must be classified as risk-off"
            );
        }

        assertEq(router.nextExecuteId(), orderIds[64], "the queue head must remain on order 65");
        assertEq(
            uint256(router.lifecycleBook().lifecycleStatus(orderIds[64])),
            uint256(OrderV2Types.LifecycleStatus.Pending),
            "order 65 must remain resumable"
        );
        assertEq(
            router.lifecycleBook().pendingIntent(orderIds[64]).account,
            address(uint160(0xC000 + 64)),
            "the capped cleanup must preserve the final intent"
        );
        assertEq(
            baseMockPyth.updatePriceFeedsCallCount(),
            pythCallsBefore,
            "the capped single call must return before attempting invalid oracle data"
        );
    }

    function _setupCallbackLiquidation()
        internal
        returns (uint64 invalidatedOrderId, PauseOnOracleRefundKeeper keeper)
    {
        _fundTrader(ALICE, 300_000e6);
        _open(ALICE, CfdTypes.Side.BULL, 100_000e18, 2000e6, MARK_PRICE);

        invalidatedOrderId = router.nextCommitId();
        vm.prank(ALICE);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 2000e6, MARK_PRICE, false);

        assertEq(routerAdmin.riskOffOrderCutoff(), 0, "cutoff must begin below the queued open");
        assertTrue(
            engineLens.isLiquidatableAt(ALICE, UNSAFE_BULL_PRICE, pool.totalAssets()),
            "setup position must be liquidatable at the adverse price"
        );

        keeper = new PauseOnOracleRefundKeeper(routerAdmin, invalidatedOrderId);
        baseMockPyth.setFee(PYTH_FEE);
    }

    function _assertCallbackRiskOffOutcome(
        uint64 invalidatedOrderId,
        PauseOnOracleRefundKeeper keeper
    ) internal view {
        assertEq(address(keeper).balance, OVERPAYMENT, "oracle must complete the bounded excess-ETH callback");
        assertFalse(routerAdmin.paused(), "the test-only cutoff change must not rely on a production pause write");
        assertGe(
            routerAdmin.riskOffOrderCutoff(),
            invalidatedOrderId,
            "callback pause must advance the inclusive cutoff over the queued open"
        );

        OrderV2Types.CompactOutcome memory outcome = router.lifecycleBook().outcome(invalidatedOrderId);
        assertEq(
            uint256(outcome.status), uint256(OrderV2Types.LifecycleStatus.Failed), "invalidated open must be terminal"
        );
        assertEq(
            uint256(outcome.reason),
            uint256(OrderV2Types.TerminalReason.RiskOff),
            "post-refund cutoff must select risk-off before liquidation forfeiture"
        );
        assertGt(outcome.bountyUsdc, 0, "setup must exercise a nonzero execution bounty");
        assertEq(
            uint256(outcome.bountyDisposition),
            uint256(OrderV2Types.BountyDisposition.RefundedToAccount),
            "invalidated bounty must be refunded rather than forfeited"
        );
        assertEq(outcome.bountyRecipient, ALICE, "risk-off bounty must return to its funding account");
        assertEq(outcome.executor, address(keeper), "receipt must retain the external callback keeper");
        assertEq(outcome.executionPrice, 0, "risk-off receipt must not relabel the liquidation price");
        assertEq(
            uint256(clearinghouse.getOrderReservation(invalidatedOrderId).status),
            uint256(IMarginClearinghouse.ReservationStatus.Released),
            "invalidated margin must use the no-carry refund path"
        );
    }

    function _positionSize(
        address account
    ) internal view returns (uint256 size) {
        (size,,,,,,) = engine.positions(account);
    }

}
