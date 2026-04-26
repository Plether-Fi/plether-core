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

    function settlementModule() external view returns (address);

    function USDC() external view returns (IERC20);

    function lastMarkPrice() external view returns (uint256);

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
            uint256 minBountyUsdc,
            uint256 bountyBps
        );

    function processOrderTyped(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc,
        uint64 publishTime
    ) external;

    function reserveCloseOrderExecutionBounty(
        address account,
        uint256 sizeDelta,
        uint256 amountUsdc,
        address recipient
    ) external;

    function absorbRouterCancellationFee(
        uint256 amountUsdc
    ) external;

    function recordRouterProtocolFee(
        uint256 amountUsdc
    ) external;

    function creditKeeperExecutionBounty(
        address beneficiary,
        uint256 amountUsdc,
        uint256 price,
        uint64 publishTime
    ) external;

    function accumulatedFeesUsdc() external view returns (uint256);

    function totalDeferredTraderCreditUsdc() external view returns (uint256);

    function totalDeferredKeeperCreditUsdc() external view returns (uint256);

    function liquidatePosition(
        address account,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc,
        uint64 publishTime,
        address keeper
    ) external returns (uint256 keeperBountyUsdc);

    function lastMarkTime() external view returns (uint64);

    function updateMarkPrice(
        uint256 price,
        uint64 publishTime
    ) external;

    function CAP_PRICE() external view returns (uint256);

    function realizeCarryBeforeMarginChange(
        address account,
        uint256 reachableCollateralBasisUsdc
    ) external;

    function checkpointCarryUsingStoredMark(
        address account,
        uint256 reachableCollateralBasisUsdc
    ) external;

    function isFadWindow() external view returns (bool);

    function fadMaxStaleness() external view returns (uint256);

    function engineMarkStalenessLimit() external view returns (uint256);

    function fadDayOverrides(
        uint256 dayNumber
    ) external view returns (bool);

    function isOracleFrozen() external view returns (bool);

    function positions(
        address account
    )
        external
        view
        returns (
            uint256 size,
            uint256 margin,
            uint256 entryPrice,
            uint256 maxProfitUsdc,
            CfdTypes.Side side,
            uint64 lastUpdateTime,
            int256 vpiAccrued
        );

    function degradedMode() external view returns (bool);

    function getProtocolStatus() external view returns (EngineStatusViewTypes.ProtocolStatus memory status);

}
