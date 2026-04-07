// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEnginePlanTypes} from "../CfdEnginePlanTypes.sol";
import {CfdTypes} from "../CfdTypes.sol";
import {EngineStatusViewTypes} from "./EngineStatusViewTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Core/operator-facing engine surface used by live perps contracts.
interface ICfdEngineCore {

    error CfdEngine__TypedOrderFailure(
        CfdEnginePlanTypes.ExecutionFailurePolicyCategory failureCategory, uint8 failureCode, bool isClose
    );
    error CfdEngine__MarkPriceOutOfOrder();

    function clearinghouse() external view returns (address);

    function orderRouter() external view returns (address);

    function USDC() external view returns (IERC20);

    function lastMarkPrice() external view returns (uint256);

    function processOrderTyped(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc,
        uint64 publishTime
    ) external;

    function previewOpenRevertCode(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (uint8 code);

    function previewOpenFailurePolicyCategory(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (CfdEnginePlanTypes.OpenFailurePolicyCategory category);

    function recordDeferredClearerBounty(address keeper, uint256 amountUsdc) external;

    function reserveCloseOrderExecutionBounty(bytes32 accountId, uint256 amountUsdc, address recipient) external;

    function absorbRouterCancellationFee(uint256 amountUsdc) external;

    function recordRouterProtocolFee(uint256 amountUsdc) external;

    function accumulatedFeesUsdc() external view returns (uint256);

    function totalDeferredPayoutUsdc() external view returns (uint256);

    function totalDeferredClearerBountyUsdc() external view returns (uint256);

    function liquidatePosition(
        bytes32 accountId,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc,
        uint64 publishTime
    ) external returns (uint256 keeperBountyUsdc);

    function lastMarkTime() external view returns (uint64);

    function updateMarkPrice(uint256 price, uint64 publishTime) external;

    function CAP_PRICE() external view returns (uint256);

    function isFadWindow() external view returns (bool);

    function fadMaxStaleness() external view returns (uint256);

    function fadDayOverrides(uint256 dayNumber) external view returns (bool);

    function isOracleFrozen() external view returns (bool);

    function hasOpenPosition(bytes32 accountId) external view returns (bool);

    function getPositionSize(bytes32 accountId) external view returns (uint256);

    function getPositionSide(bytes32 accountId) external view returns (CfdTypes.Side);

    function degradedMode() external view returns (bool);

    function getProtocolStatus() external view returns (EngineStatusViewTypes.ProtocolStatus memory status);
}
