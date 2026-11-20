// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @dev Engine read surface used by account-action methods externalized from the bytecode-constrained host.
interface ICfdEngineAccountActionView {

    function planningReader() external view returns (address);

    function positions(
        address account
    )
        external
        view
        returns (
            uint256 size,
            uint256 margin,
            uint256 entryPrice,
            uint256 maxProfitAssets,
            CfdTypes.Side side,
            uint64 lastUpdateTime,
            int256 vpiAccrued
        );

    function positionEntryCostAssetAtoms(
        address account
    ) external view returns (uint256);

    function positionCarryState(
        address account
    ) external view returns (uint256 maxProfitAssets, uint256 lastCarryIndex, uint64 lastCarryTimestamp);

    function sides(
        uint256 index
    ) external view returns (uint256 maxProfitAssets, uint256 openInterest, uint256 entryNotional, uint256 totalMargin);

    function currentCarryIndex() external view returns (uint256);

    function planner() external view returns (address);

    function orderRouter() external view returns (address);

    function lastMarkPrice() external view returns (uint256);

    function lastMarkTime() external view returns (uint64);

    function CAP_PRICE() external view returns (uint256);

    function traderClaimBalanceAssets(
        address account
    ) external view returns (uint256);

    function unsettledCarryAssets(
        address account
    ) external view returns (uint256);

    function totalTraderClaimBalanceAssets() external view returns (uint256);

    function totalPositiveVpiAccruedAssets() external view returns (uint256);

    function totalNegativeVpiAccruedAssets() external view returns (uint256);

    function degradedMode() external view returns (bool);

    function isFadWindow() external view returns (bool);

    function isOracleFrozen() external view returns (bool);

    function engineMarkStalenessLimit() external view returns (uint256);

    function fadMaxStaleness() external view returns (uint256);

    function executionFeeBps() external view returns (uint256);

    function frozenCloseSpreadBps() external view returns (uint256);

    function settlementBufferBps() external view returns (uint256);

    function riskParams()
        external
        view
        returns (
            uint256 vpiFactor,
            uint256 maxSkewRatio,
            uint256 maintMarginBps,
            uint256 initMarginBps,
            uint256 fadMarginBps,
            uint256 baseCarryBps,
            uint256 minBountyAssets,
            uint256 bountyBps,
            uint256 keeperShareBps,
            uint256 protocolShareBps
        );

}
