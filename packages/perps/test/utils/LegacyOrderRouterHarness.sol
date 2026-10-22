// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {LegacyOrderRequestEncoding} from "./LegacyOrderRequestEncoding.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";

/// @dev Test-only adapter for historical scalar-commit coverage. Production deployments intentionally expose only
///      the bounded V3 commit surface; tests read oracle policy through the production `pletherOracle()` getter.
contract LegacyOrderRouterHarness is OrderRouter {

    /// @dev Foundry test marker: production size limits are checked against OrderRouter itself.
    bool public constant IS_TEST = true;

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

    /// @dev Translates a historical scalar commit into a unique, otherwise-unbounded V3 request.
    ///      The self-delegatecall preserves the original test account as `msg.sender` while entering the
    ///      production V3 `nonReentrant` function exactly once.
    function commitOrder(
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 targetPrice,
        bool isClose
    ) external returns (uint64 orderId) {
        // The immutable Router's monotonic nonzero id supplies a unique test-only client id.
        bytes32 clientOrderId = bytes32(uint256(nextCommitId));
        uint256 translatedTargetPrice = targetPrice;
        if (translatedTargetPrice == 0) {
            translatedTargetPrice = (side == CfdTypes.Side.LONG) == isClose ? type(uint256).max : 1;
        }

        OrderV3Types.OrderRequest memory request = OrderV3Types.OrderRequest({
            clientOrderId: clientOrderId,
            side: side,
            sizeDelta: sizeDelta,
            marginDelta: marginDelta,
            targetPrice: translatedTargetPrice,
            isClose: isClose,
            bounds: OrderV3Types.ExecutionBounds({
                submitBy: uint64(block.timestamp) + uint64(maxExecutionWindowSeconds),
                executionWindowSeconds: uint32(maxExecutionWindowSeconds),
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

        bytes memory payload = LegacyOrderRequestEncoding.encode(request);
        assembly ("memory-safe") {
            let success := delegatecall(gas(), address(), add(payload, 32), mload(payload), 0, 0)
            let output := mload(0x40)
            returndatacopy(output, 0, returndatasize())
            if iszero(success) { revert(output, returndatasize()) }
            if lt(returndatasize(), 32) { revert(0, 0) }
            orderId := mload(output)
            if shr(64, orderId) { revert(0, 0) }
        }
    }

}
