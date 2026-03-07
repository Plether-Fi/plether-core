// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

interface IMarginClearinghouse {

    function lockMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external;
    function unlockMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external;
    function settleUsdc(
        bytes32 accountId,
        address usdc,
        int256 amount
    ) external;
    function seizeAsset(
        bytes32 accountId,
        address asset,
        uint256 amount,
        address recipient
    ) external;
    function getAccountEquityUsdc(
        bytes32 accountId
    ) external view returns (uint256);

}
