// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";

/// @dev Test-only adapter for historical scalar-commit coverage. Production deployments intentionally expose only
///      the bounded V2 commit surface; tests read oracle policy through the production `pletherOracle()` getter.
contract LegacyOrderRouterHarness is OrderRouter {

    constructor(
        address engine_,
        address engineLens_,
        address housePool_,
        address pletherOracle_,
        address keeperSidecar_,
        address policyEvaluator_,
        address executionSidecar_,
        address lifecycleBook_
    )
        OrderRouter(
            engine_,
            engineLens_,
            housePool_,
            pletherOracle_,
            keeperSidecar_,
            policyEvaluator_,
            executionSidecar_,
            lifecycleBook_
        )
    {}

    /// @dev Translates a historical scalar commit into a unique, otherwise-unbounded V2 request.
    ///      The self-delegatecall preserves the original test account as `msg.sender` while entering the
    ///      production V2 `nonReentrant` function exactly once.
    function commitOrder(
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 targetPrice,
        bool isClose
    ) external returns (uint64 orderId) {
        uint64 proposedOrderId = nextCommitId;
        bytes32 clientOrderId = keccak256(
            abi.encode("LegacyOrderRouterHarness", block.chainid, address(this), msg.sender, proposedOrderId)
        );
        if (clientOrderId == bytes32(0)) {
            clientOrderId = bytes32(uint256(1));
        }

        uint256 translatedTargetPrice = targetPrice;
        if (translatedTargetPrice == 0) {
            if (isClose) {
                translatedTargetPrice = side == CfdTypes.Side.LONG ? type(uint256).max : 1;
            } else {
                translatedTargetPrice = side == CfdTypes.Side.LONG ? 1 : type(uint256).max;
            }
        }

        OrderV2Types.OrderRequest memory request = OrderV2Types.OrderRequest({
            clientOrderId: clientOrderId,
            side: side,
            sizeDelta: sizeDelta,
            marginDelta: marginDelta,
            targetPrice: translatedTargetPrice,
            isClose: isClose,
            bounds: OrderV2Types.ExecutionBounds({
                validUntil: uint64(block.timestamp) + uint64(maxOrderAge),
                allowedExecutionModes: 7,
                expectedConfigHash: lifecycleBook.currentExecutionConfigHash(),
                maxExecutionBountyUsdc: type(uint256).max,
                maxExecutionNotionalUsdc: type(uint256).max,
                maxGrossAccountDebitUsdc: type(uint256).max,
                maxActionChargeUsdc: type(uint256).max,
                maxExplicitFeesUsdc: type(uint256).max,
                maxPostPositionSize: type(uint256).max,
                minPostSettlementBalanceUsdc: 0,
                minPostPositionEquityUsdc: 0,
                maxPostLeverageBps: type(uint32).max
            })
        });

        (bool success, bytes memory returndata) =
            address(this).delegatecall(abi.encodeCall(OrderRouter.commitOrder, (request)));
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
        orderId = abi.decode(returndata, (uint64));
    }

}
