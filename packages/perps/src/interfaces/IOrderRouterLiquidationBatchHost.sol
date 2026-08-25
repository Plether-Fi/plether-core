// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Narrow Router surface used by its immutable liquidation-batch delegate sidecar.
interface IOrderRouterLiquidationBatchHost {

    function admin() external view returns (address);

    function engine() external view returns (address);

    function pletherOracle() external view returns (address);

    function minEngineGas() external view returns (uint256);

    function pendingOrderCounts(
        address account
    ) external view returns (uint256);

    function executeLiquidationBatchItem(
        address account,
        uint256 bullPrice,
        uint256 bearPrice,
        uint256 neutralMarkPrice,
        uint64 publishTime,
        address keeper,
        uint64 riskOffCutoff
    ) external returns (uint256 outcome);

}
