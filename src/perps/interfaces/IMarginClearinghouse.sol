// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @notice Cross-margin account system that holds collateral and settles PnL for CFD positions.
interface IMarginClearinghouse {

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
    /// @notice Transfers assets from an account to a recipient (losses, fees, or bad debt)
    function seizeAsset(
        bytes32 accountId,
        address asset,
        uint256 amount,
        address recipient
    ) external;
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

    /// @notice Returns settlement-asset balance reachable during position settlement.
    /// @dev Includes currently free settlement balance plus the specific position margin
    ///      that is expected to be unlocked as part of the settlement flow.
    function getLiquidationReachableUsdc(
        bytes32 accountId,
        uint256 positionMarginUsdc
    ) external view returns (uint256);

}
