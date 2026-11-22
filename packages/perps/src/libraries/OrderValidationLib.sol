// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

/// @notice Pure validation helpers for delayed-order router checks.
library OrderValidationLib {

    struct ExecutionDomain {
        uint256 capPrice;
        uint256 executionFeeBps;
        bool vpiDisabled;
        uint256 executionBountyAssets;
    }

    /// @notice Whether the fixed request permits at least one positive execution price within the engine cap.
    /// @dev OPEN execution requires Live mode; this checks only unavoidable contradictions, not future market prices.
    function isRequestFeasible(
        CfdTypes.Side side,
        bool isClose,
        uint256 sizeDelta,
        uint256 targetPrice,
        OrderV3Types.ExecutionBounds memory bounds,
        ExecutionDomain memory domain
    ) internal pure returns (bool) {
        if (!isClose && bounds.allowedExecutionModes & 1 == 0) {
            return false;
        }
        uint256 lots = sizeDelta / CfdTypes.SIZE_QUANTUM;
        // Avoid multiplying an untrusted uint256 lot count outside the engine's numeric domain.
        if (lots == 0 || lots > type(uint112).max || sizeDelta % CfdTypes.SIZE_QUANTUM != 0) {
            return false;
        }
        (uint256 minimumPrice, uint256 maximumPrice) =
            executionPriceRange(side, isClose, sizeDelta, targetPrice, bounds, domain);
        return minimumPrice != 0 && minimumPrice <= maximumPrice
            && (isClose
                || (bounds.maxPostPositionSize >= sizeDelta
                    && bounds.minPostPositionEquityAssets <= uint256(type(int256).max)));
    }

    /// @notice Intersects directional slippage with unavoidable notional, fee, and debit constraints.
    /// @dev The caller validates nonzero aligned size inside uint112 lots before calling this helper.
    function executionPriceRange(
        CfdTypes.Side side,
        bool isClose,
        uint256 sizeDelta,
        uint256 targetPrice,
        OrderV3Types.ExecutionBounds memory bounds,
        ExecutionDomain memory domain
    ) internal pure returns (uint256 minimumPrice, uint256 maximumPrice) {
        bool lowerPriceBound = (side == CfdTypes.Side.LONG) != isClose;
        minimumPrice = lowerPriceBound ? targetPrice : 1;
        maximumPrice = !lowerPriceBound && targetPrice < domain.capPrice ? targetPrice : domain.capPrice;
        uint256 lots = sizeDelta / CfdTypes.SIZE_QUANTUM;
        uint256 notionalPrice = bounds.maxExecutionNotionalAssets / lots;
        if (maximumPrice > notionalPrice) {
            maximumPrice = notionalPrice;
        }
        uint256 feeAllowance = bounds.maxExplicitFeesAssets;
        if (!isClose && bounds.maxGrossAccountDebitAssets < domain.executionBountyAssets) {
            return (minimumPrice, 0);
        }
        if (domain.vpiDisabled) {
            if (feeAllowance > bounds.maxActionChargeAssets) {
                feeAllowance = bounds.maxActionChargeAssets;
            }
            if (!isClose) {
                uint256 debitAllowance = bounds.maxGrossAccountDebitAssets - domain.executionBountyAssets;
                if (feeAllowance > debitAllowance) {
                    feeAllowance = debitAllowance;
                }
            }
        }
        uint256 feePerPrice = lots * domain.executionFeeBps;
        if (feePerPrice != 0 && (maximumPrice * feePerPrice) / 10_000 > feeAllowance) {
            // This branch bounds feeAllowance by the uint112-lot, uint32-price fee domain.
            maximumPrice = (feeAllowance * 10_000 + 9999) / feePerPrice;
        }
    }

    /// @notice Validates size, lot-alignment, and margin constraints common to order commits.
    /// @param sizeDelta Requested position-size delta (18 decimals).
    /// @param marginDelta Requested nonnegative margin amount (6 decimals).
    /// @param isClose Whether the order is a close/reduce order.
    function validateBaseCommit(
        uint256 sizeDelta,
        uint256 marginDelta,
        bool isClose
    ) internal pure {
        if (sizeDelta == 0) {
            revert IOrderRouterErrors.OrderRouter__ZeroSize();
        }
        if (sizeDelta % CfdTypes.SIZE_QUANTUM != 0) {
            revert IOrderRouterErrors.OrderRouter__InvalidSizeQuantum();
        }
        if (isClose && marginDelta > 0) {
            revert IOrderRouterErrors.OrderRouter__CloseWithPositiveMargin();
        }
    }

    /// @notice Validates a close order against the live position remaining after earlier queued closes.
    /// @param queuedSize Live position size remaining after earlier same-side closes (18 decimals).
    /// @param queuedSide Side of the live position.
    /// @param requestedSide Side supplied by the close request.
    /// @param sizeDelta Requested reduction in position size (18 decimals).
    function validateCloseCommit(
        uint256 queuedSize,
        CfdTypes.Side queuedSide,
        CfdTypes.Side requestedSide,
        uint256 sizeDelta
    ) internal pure {
        if (queuedSize == 0) {
            revert IOrderRouterErrors.OrderRouter__NoQueuedPosition();
        }
        if (queuedSide != requestedSide) {
            revert IOrderRouterErrors.OrderRouter__SideMismatch();
        }
        if (sizeDelta > queuedSize) {
            revert IOrderRouterErrors.OrderRouter__SizeExceedsQueued();
        }
    }

    /// @notice Checks execution price against the order's directional target-price boundary.
    /// @dev Production V3 commits require a nonzero target. Close LONG accepts prices at or below the target; close
    ///      SHORT accepts prices at or above it. Open LONG uses the opposite comparison, as does open SHORT.
    /// @param order Order whose side, close flag, and target price define the boundary.
    /// @param executionPrice Proposed execution price (8 decimals).
    /// @return Whether the proposed price satisfies the order boundary.
    function checkSlippage(
        CfdTypes.Order memory order,
        uint256 executionPrice
    ) internal pure returns (bool) {
        if (order.isClose) {
            if (order.side == CfdTypes.Side.LONG) {
                return executionPrice <= order.targetPrice;
            }
            return executionPrice >= order.targetPrice;
        }
        if (order.side == CfdTypes.Side.LONG) {
            return executionPrice >= order.targetPrice;
        }
        return executionPrice <= order.targetPrice;
    }

}
