// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "../CfdTypes.sol";
import {ICfdEngineTypes} from "./ICfdEngineTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Core/operator-facing engine surface used by live perps contracts.
interface ICfdEngineCore is ICfdEngineTypes {

    /// @notice Margin clearinghouse used for balances, locked margin, and settlement.
    function clearinghouse() external view returns (address);

    /// @notice Order router authorized to execute orders and liquidations.
    function orderRouter() external view returns (address);

    /// @notice HousePool backing trader positions.
    function pool() external view returns (address);

    /// @notice Clearinghouse account that receives protocol fee credits.
    function protocolTreasury() external view returns (address);

    /// @notice Settlement sidecar authorized to apply planned settlement mutations.
    function settlementSidecar() external view returns (address);

    /// @notice Settlement token used for margin, fees, and payouts.
    function USDC() external view returns (IERC20);

    /// @notice Last mark price observed by the engine (8 decimals).
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

    /// @notice Router-facing order execution entrypoint with typed business-rule failures.
    /// @param order Queued order being executed by the router
    /// @param currentOraclePrice Execution oracle price (8 decimals), clamped to CAP_PRICE
    /// @param poolDepthUsdc HousePool depth used for planning and solvency checks
    /// @param publishTime Oracle publish timestamp recorded as the latest mark time
    function processOrderTyped(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 poolDepthUsdc,
        uint64 publishTime
    ) external;

    /// @notice Reserves the fixed close-order execution bounty against a proportional slice of an open position.
    /// @param account Account committing the close order
    /// @param sizeDelta Position size the close order intends to close
    /// @param amountUsdc Execution bounty amount to reserve
    function reserveCloseOrderExecutionBounty(
        address account,
        uint256 sizeDelta,
        uint256 amountUsdc
    ) external;

    /// @notice Moves forfeited reserved execution-bounty reservation into the protocol treasury account.
    /// @param sourceAccount Account whose reserved settlement bounty is forfeited
    /// @param amountUsdc Reserved USDC amount to transfer into the protocol treasury account
    function absorbReservedExecutionBounty(
        address sourceAccount,
        uint256 amountUsdc
    ) external;

    /// @notice Credits a reserved execution bounty into the beneficiary's clearinghouse account.
    /// @param sourceAccount Account whose reserved settlement bounty funds the credit
    /// @param beneficiary Account receiving the clearinghouse settlement credit
    /// @param amountUsdc Reserved USDC amount to transfer
    /// @param price Fresh mark price used to checkpoint beneficiary carry when needed
    /// @param publishTime Mark publish timestamp used when checkpointing beneficiary carry
    function creditBounty(
        address sourceAccount,
        address beneficiary,
        uint256 amountUsdc,
        uint256 price,
        uint64 publishTime
    ) external;

    /// @notice Trader claim balance still owed to beneficiaries.
    function totalTraderClaimBalanceUsdc() external view returns (uint256);

    /// @notice Liquidates an undercollateralized position.
    /// @param account Clearinghouse account that owns the position
    /// @param currentOraclePrice Oracle price (8 decimals), clamped to CAP_PRICE
    /// @param poolDepthUsdc HousePool total assets used for planning and settlement checks
    /// @param publishTime Oracle publish timestamp recorded as the latest mark time
    /// @param keeper Keeper that receives any liquidation bounty as clearinghouse credit
    /// @return keeperBountyUsdc Bounty paid to the liquidation keeper
    function liquidatePosition(
        address account,
        uint256 currentOraclePrice,
        uint256 poolDepthUsdc,
        uint64 publishTime,
        address keeper
    ) external returns (uint256 keeperBountyUsdc);

    /// @notice Timestamp of the last mark price update.
    function lastMarkTime() external view returns (uint64);

    /// @notice Pushes a fresh mark price without processing an order.
    /// @param price New mark price (8 decimals)
    /// @param publishTime Oracle publish timestamp for the price update
    function updateMarkPrice(
        uint256 price,
        uint64 publishTime
    ) external;

    /// @notice Protocol cap price (8 decimals). Oracle prices are clamped to this.
    function CAP_PRICE() external view returns (uint256);

    /// @notice Realizes accrued carry before a clearinghouse balance mutation changes the carry basis.
    /// @param account Account whose carry should be realized if a position exists
    function realizeCarryBeforeMarginChange(
        address account
    ) external;

    /// @notice Permissionlessly advances both side carry indexes to the current timestamp.
    function checkpointCarryIndexes() external;

    /// @notice True during weekend FX closure, configured FAD days, or FAD runway.
    function isFadWindow() external view returns (bool);

    /// @notice Maximum oracle staleness allowed while the oracle is frozen.
    function fadMaxStaleness() external view returns (uint256);

    /// @notice Maximum cached engine mark staleness allowed for live-market checks.
    function engineMarkStalenessLimit() external view returns (uint256);

    /// @notice Returns whether a day number is configured as a FAD override.
    /// @param dayNumber Unix day number to inspect
    function fadDayOverrides(
        uint256 dayNumber
    ) external view returns (bool);

    /// @notice True only when FX markets are closed and oracle freshness can be relaxed.
    function isOracleFrozen() external view returns (bool);

    /// @notice Returns the current live position tuple for an account.
    /// @param account Account to inspect
    /// @return size Position size (18 decimals)
    /// @return margin Current active position margin (6 decimals)
    /// @return entryPrice Average entry price (8 decimals)
    /// @return maxProfitUsdc Position maximum profit envelope (6 decimals)
    /// @return side Position side
    /// @return lastUpdateTime Last position mutation timestamp
    /// @return vpiAccrued Net VPI accrued on the position
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

    /// @notice True when the engine has latched degraded mode after insolvency was detected.
    function degradedMode() external view returns (bool);

}
