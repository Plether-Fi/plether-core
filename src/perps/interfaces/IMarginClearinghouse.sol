// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @notice Cross-margin account system that holds collateral and settles PnL for CFD positions.
interface IMarginClearinghouse {

    struct AccountUsdcBuckets {
        uint256 settlementBalanceUsdc;
        uint256 reservedSettlementUsdc;
        uint256 totalLockedMarginUsdc;
        uint256 activePositionMarginUsdc;
        uint256 otherLockedMarginUsdc;
        uint256 freeSettlementUsdc;
    }

    /// @notice Returns the balance of an asset for an account
    function balances(
        bytes32 accountId,
        address asset
    ) external view returns (uint256);
    /// @notice Returns the locked USDC margin for an account
    function lockedMarginUsdc(
        bytes32 accountId
    ) external view returns (uint256);
    /// @notice Locks margin to back a new CFD position
    function lockMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external;
    /// @notice Unlocks margin when a CFD position closes
    function unlockMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external;
    /// @notice Adjusts USDC balance for funding, PnL, or rebates (+credit, -debit)
    function settleUsdc(
        bytes32 accountId,
        address usdc,
        int256 amount
    ) external;
    /// @notice Reserves settlement USDC in place without transferring custody
    function reserveSettlementUsdc(
        bytes32 accountId,
        uint256 amountUsdc
    ) external;
    /// @notice Releases previously reserved settlement USDC
    function releaseReservedSettlementUsdc(
        bytes32 accountId,
        uint256 amountUsdc
    ) external;
    /// @notice Pays reserved settlement USDC to the calling operator
    function payReservedSettlementUsdc(
        bytes32 accountId,
        uint256 amountUsdc,
        address recipient
    ) external;
    /// @notice Credits settlement USDC and locks the same amount as active margin.
    function creditSettlementAndLockMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external;
    /// @notice Applies an open/increase trade cost by debiting or crediting settlement and updating locked margin.
    function applyOpenCost(
        bytes32 accountId,
        uint256 marginDeltaUsdc,
        int256 tradeCostUsdc,
        address recipient
    ) external returns (int256 netMarginChangeUsdc);
    /// @notice Consumes funding loss from free settlement plus the active position margin bucket.
    function consumeFundingLoss(
        bytes32 accountId,
        uint256 lockedPositionMarginUsdc,
        uint256 lossUsdc,
        address recipient
    ) external returns (uint256 marginConsumedUsdc, uint256 freeSettlementConsumedUsdc, uint256 uncoveredUsdc);
    /// @notice Consumes close-path losses from settlement buckets while preserving the remaining live position margin and reserved escrow.
    function consumeCloseLoss(
        bytes32 accountId,
        uint256 lossUsdc,
        uint256 protectedLockedMarginUsdc,
        address recipient
    ) external returns (uint256 seizedUsdc, uint256 shortfallUsdc);
    /// @notice Settles liquidation residual against liquidation-reachable collateral while preserving reserved escrow.
    function consumeLiquidationResidual(
        bytes32 accountId,
        uint256 lockedPositionMarginUsdc,
        int256 residualUsdc,
        address recipient
    )
        external
        returns (uint256 seizedUsdc, uint256 payoutUsdc, uint256 badDebtUsdc);
    /// @notice Transfers assets from an account to a recipient (losses, fees, or bad debt)
    function seizeAsset(
        bytes32 accountId,
        address asset,
        uint256 amount,
        address recipient
    ) external;
    /// @notice Returns reserved settlement USDC tracked in clearinghouse custody
    function reservedSettlementUsdc(
        bytes32 accountId
    ) external view returns (uint256);
    /// @notice Returns the explicit USDC bucket split for an account.
    /// @dev `activePositionMarginUsdc` is the margin bucket currently backing the live position being reasoned about.
    function getAccountUsdcBuckets(
        bytes32 accountId,
        uint256 activePositionMarginUsdc
    ) external view returns (AccountUsdcBuckets memory buckets);
    /// @notice Returns total USD buying power of an account with LTV haircuts (6 decimals)
    function getAccountEquityUsdc(
        bytes32 accountId
    ) external view returns (uint256);

    /// @notice Returns strictly free buying power after subtracting locked margin (6 decimals)
    function getFreeBuyingPowerUsdc(
        bytes32 accountId
    ) external view returns (uint256);

    /// @notice Returns free settlement-asset balance after subtracting locked margin (6 decimals)
    function getFreeSettlementBalanceUsdc(
        bytes32 accountId
    ) external view returns (uint256);

    /// @notice Returns settlement-asset balance reachable during liquidation or other terminal settlement.
    /// @dev Protects only reserved settlement escrow; same-account committed margin remains reachable.
    function getLiquidationReachableUsdc(
        bytes32 accountId,
        uint256 positionMarginUsdc
    ) external view returns (uint256);

    /// @notice Returns settlement-asset balance reachable for a terminal or partial settlement path.
    /// @dev Protects only the explicitly supplied remaining locked margin bucket and treats all
    ///      other settlement-asset balance as reachable for loss collection.
    function getSettlementReachableUsdc(
        bytes32 accountId,
        uint256 protectedLockedMarginUsdc
    ) external view returns (uint256);

}
