// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "../CfdTypes.sol";
import {ICfdEngineTypes} from "./ICfdEngineTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Stateful CFD trading engine: processes orders and liquidates positions.
/// @dev This remains a rich internal/admin integration interface.
///      Product-facing consumers should prefer the slim public surfaces in
///      `IPerpsTraderActions`, `IPerpsTraderViews`, `IPerpsLPActions`, `IPerpsLPViews`,
///      `IPerpsKeeper`, `IProtocolViews`, and `IMarginAccount`.
///      Live protocol contracts should prefer smaller role-specific interfaces like `ICfdEngineCore`.
interface ICfdEngine is ICfdEngineTypes {

    /// @notice Margin clearinghouse address used for account margin locking/unlocking
    function clearinghouse() external view returns (address);

    /// @notice Current order router allowed to execute orders through the engine.
    function orderRouter() external view returns (address);

    /// @notice Clearinghouse account that receives protocol fee credits.
    function protocolTreasury() external view returns (address);

    /// @notice Settlement token used for fees, margin, and payouts
    function USDC() external view returns (IERC20);

    /// @notice Last mark price observed by the engine (8 decimals)
    function lastMarkPrice() external view returns (uint256);

    /// @notice Router-facing order execution entrypoint with typed business-rule failures.
    /// @dev Reverts with `CfdEngine__TypedOrderFailure` for expected order invalidations so the
    ///      router can apply deterministic failed-order bounty policy without selector matching.
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

    /// @notice Reserves close-order execution bounty from free settlement first, then active position margin.
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
    /// @dev Realizes carry first when the beneficiary account currently has an open position so the
    ///      settlement-balance credit cannot retroactively dilute carry owed over the elapsed interval.
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

    /// @notice Liquidates an undercollateralized position, returns keeper bounty in USDC
    /// @param account          Account holding the position to liquidate
    /// @param currentOraclePrice Mark price from the oracle (8 decimals)
    /// @param poolDepthUsdc     Available pool liquidity (6 decimals)
    /// @param publishTime        Oracle publish timestamp
    /// @param keeper             Keeper credited with any liquidation bounty
    /// @return keeperBountyUsdc  Bounty paid to the liquidation keeper (6 decimals)
    function liquidatePosition(
        address account,
        uint256 currentOraclePrice,
        uint256 poolDepthUsdc,
        uint64 publishTime,
        address keeper
    ) external returns (uint256 keeperBountyUsdc);

    /// @notice Realizes accrued carry against the current reachable collateral before a user-level
    ///         settlement balance mutation changes the carry basis.
    /// @param account Account whose open-position carry should be realized if a position exists
    function realizeCarryBeforeMarginChange(
        address account
    ) external;

    /// @notice Permissionlessly advances both side carry indexes to the current timestamp.
    function checkpointCarryIndexes() external;

    /// @notice Canonical liquidation preview using the pool's current accounted depth.
    /// @param account Account whose position would be tested
    /// @param oraclePrice Oracle price used for the preview
    /// @return preview Liquidation result and bounty data
    function previewLiquidation(
        address account,
        uint256 oraclePrice
    ) external view returns (LiquidationPreview memory preview);

    /// @notice Hypothetical liquidation simulation at a caller-supplied pool depth.
    /// @param account Account whose position would be tested
    /// @param oraclePrice Oracle price used for the simulation
    /// @param poolDepthUsdc Hypothetical HousePool depth
    /// @return preview Liquidation result and bounty data
    function simulateLiquidation(
        address account,
        uint256 oraclePrice,
        uint256 poolDepthUsdc
    ) external view returns (LiquidationPreview memory preview);

    /// @notice Trader claim balance still owed to beneficiaries.
    function totalTraderClaimBalanceUsdc() external view returns (uint256);

    /// @notice Timestamp of the last mark price update
    function lastMarkTime() external view returns (uint64);

    /// @notice Pushes a fresh mark price without processing an order.
    /// @dev This updates the cached mark only; carry is realized on execution and margin-mutating paths.
    /// @param price       New mark price (8 decimals)
    /// @param publishTime Oracle publish timestamp for the price update
    function updateMarkPrice(
        uint256 price,
        uint64 publishTime
    ) external;

    /// @notice Protocol cap price (8 decimals). Oracle prices are clamped to this.
    function CAP_PRICE() external view returns (uint256);

    /// @notice True during weekend FX closure or admin-configured FAD days
    function isFadWindow() external view returns (bool);

    /// @notice Maximum oracle staleness allowed during FAD windows
    function fadMaxStaleness() external view returns (uint256);

    /// @notice True only when FX markets are actually closed and oracle freshness can be relaxed.
    function isOracleFrozen() external view returns (bool);

    /// @notice Returns the current position tuple for an account.
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

    /// @notice Returns the indexed carry basis for a position.
    /// @param account Account to inspect
    /// @return borrowBaseUsdc Position borrow base used for carry utilization
    /// @return lastCarryIndex Side carry index last stored on the position
    /// @return lastCarryTimestamp Timestamp used for the position's last carry checkpoint
    function positionCarryState(
        address account
    ) external view returns (uint256 borrowBaseUsdc, uint256 lastCarryIndex, uint64 lastCarryTimestamp);

    /// @notice True when the engine has latched degraded mode after a close revealed insolvency.
    function degradedMode() external view returns (bool);

    /// @notice Whether a given day number is an admin-configured FAD override
    /// @param dayNumber Unix day number to inspect
    function fadDayOverrides(
        uint256 dayNumber
    ) external view returns (bool);

    /// @notice High-level protocol lifecycle used by external status consumers.
    ///         `Active` means the engine is wired and the HousePool has enabled live risk-taking.
    enum ProtocolPhase {
        Configuring,
        Active,
        Degraded
    }

}
