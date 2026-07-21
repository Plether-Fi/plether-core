// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

/// @notice Core/operator-facing engine surface used by live perps contracts.
/// @dev Unless stated otherwise, USDC amounts use 6 decimals, prices use 8 decimals, position sizes use 18 decimals,
///      basis-point values use a 10,000 denominator, and timestamps are Unix seconds.
interface ICfdEngineCore is ICfdEngineTypes {

    /// @notice Margin clearinghouse used for balances, locked margin, and settlement.
    /// @return Clearinghouse contract address
    function clearinghouse() external view returns (address);

    /// @notice Order router authorized to execute orders and liquidations.
    /// @return Configured router address, or zero before one-time wiring
    function orderRouter() external view returns (address);

    /// @notice HousePool backing trader positions.
    /// @return Configured HousePool address, or zero before one-time wiring
    function pool() external view returns (address);

    /// @notice Clearinghouse account that receives protocol fee credits.
    /// @return Current protocol treasury account
    function protocolTreasury() external view returns (address);

    /// @notice Settlement sidecar authorized to apply planned settlement mutations.
    /// @return Configured settlement-sidecar address, or zero before one-time wiring
    function settlementSidecar() external view returns (address);

    /// @notice Settlement token used for margin, fees, and payouts.
    /// @return USDC-compatible settlement token
    function USDC() external view returns (IERC20);

    /// @notice Last mark price observed by the engine (8 decimals).
    /// @return Cached engine mark price, or zero before the first mark
    function lastMarkPrice() external view returns (uint256);

    /// @notice Returns the engine's active position-risk, VPI, carry, and liquidation-bounty parameters.
    /// @return vpiFactor VPI impact factor, scaled by 1e18
    /// @return maxSkewRatio Maximum side skew divided by pool depth, scaled by 1e18
    /// @return maintMarginBps Normal maintenance-margin ratio in basis points
    /// @return initMarginBps Initial-margin ratio in basis points
    /// @return fadMarginBps Maintenance-margin ratio during FAD in basis points
    /// @return baseCarryBps Annualized base carry rate in basis points
    /// @return minBountyUsdc Minimum liquidation bounty and position-margin floor in USDC
    /// @return bountyBps Variable liquidation-bounty rate in basis points
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

    /// @notice Fixed LP-owned spread charged on oracle-frozen close/reduce notional, in basis points.
    /// @return Frozen close spread in basis points
    function frozenCloseSpreadBps() external view returns (uint256);

    /// @notice Router-facing order execution entrypoint with typed business-rule failures.
    /// @dev Callable only by the configured router. The planner computes a delta and the settlement sidecar applies
    ///      clearinghouse, pool, aggregate-side, and position mutations atomically.
    /// @param order Queued order being executed by the router
    /// @param currentOraclePrice Execution oracle price (8 decimals), clamped to CAP_PRICE
    /// @param poolDepthUsdc HousePool depth used for planning and solvency checks
    /// @param publishTime Execution-price publish time, cached only when it is not older than `lastMarkTime`
    function processOrderTyped(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 poolDepthUsdc,
        uint64 publishTime
    ) external;

    /// @notice Reserves the fixed close-order execution bounty against a proportional slice of an open position.
    /// @dev Callable only by the configured router. Realizes carry first, reserves free settlement then position
    ///      margin, and rejects reservations that would leave the proportional position slice under-backed.
    /// @param account Account committing the close order
    /// @param sizeDelta Position size the close order intends to close
    /// @param amountUsdc Execution bounty amount to reserve
    function reserveCloseOrderExecutionBounty(
        address account,
        uint256 sizeDelta,
        uint256 amountUsdc
    ) external;

    /// @notice Moves forfeited reserved execution-bounty reservation into the protocol treasury account.
    /// @dev Callable only by the router. Reclassifies internal clearinghouse balances without moving ERC20 tokens;
    ///      a zero amount is a no-op.
    /// @param sourceAccount Account whose reserved settlement bounty is forfeited
    /// @param amountUsdc Reserved USDC amount to transfer into the protocol treasury account
    function absorbReservedExecutionBounty(
        address sourceAccount,
        uint256 amountUsdc
    ) external;

    /// @notice Credits a reserved execution bounty into the beneficiary's clearinghouse account.
    /// @dev Callable only by the router. For a beneficiary with an open position, carry is checkpointed before the
    ///      credit changes reachable collateral. A strictly newer mark is capped and cached; zero is a no-op.
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
    /// @return Aggregate senior HousePool payout liability in USDC
    function totalTraderClaimBalanceUsdc() external view returns (uint256);

    /// @notice Liquidates an undercollateralized position.
    /// @dev Callable only by the router. Settlement deletes the full position, routes losses or surplus, credits the
    ///      keeper internally, and can latch degraded mode if post-operation adjusted solvency is negative.
    /// @param account Clearinghouse account that owns the position
    /// @param currentOraclePrice Oracle price (8 decimals), clamped to CAP_PRICE
    /// @param poolDepthUsdc HousePool total assets used for planning and settlement checks
    /// @param publishTime Oracle publish timestamp; must not predate `lastMarkTime` and is cached only when strictly newer
    /// @param keeper Keeper that receives any liquidation bounty as clearinghouse credit
    /// @return keeperBountyUsdc Bounty credited to the liquidation keeper in USDC
    function liquidatePosition(
        address account,
        uint256 currentOraclePrice,
        uint256 poolDepthUsdc,
        uint64 publishTime,
        address keeper
    ) external returns (uint256 keeperBountyUsdc);

    /// @notice Timestamp of the last mark price update.
    /// @return Oracle publish timestamp associated with `lastMarkPrice`
    function lastMarkTime() external view returns (uint64);

    /// @notice Pushes a fresh mark price without processing an order.
    /// @dev Callable only by the router. Caps the price at `CAP_PRICE`, rejects an older publish time, advances carry
    ///      indexes, and updates the cached mark without realizing account-level carry.
    /// @param price New mark price (8 decimals)
    /// @param publishTime Oracle publish timestamp for the price update
    function updateMarkPrice(
        uint256 price,
        uint64 publishTime
    ) external;

    /// @notice Protocol cap price (8 decimals). Oracle prices are clamped to this.
    /// @return Maximum supported oracle price
    function CAP_PRICE() external view returns (uint256);

    /// @notice Realizes accrued carry before a clearinghouse balance mutation changes the carry basis.
    /// @dev Callable only by the configured clearinghouse. Accounts without an open position are no-ops.
    /// @param account Account whose carry should be realized if a position exists
    function realizeCarryBeforeMarginChange(
        address account
    ) external;

    /// @notice Permissionlessly advances both side carry indexes to the current timestamp.
    /// @dev Uses effective HousePool depth capped by raw token custody, and does not realize carry against individual
    ///      accounts or update the oracle mark.
    function checkpointCarryIndexes() external;

    /// @notice Returns whether recurring FAD, an override day, or the configured pre-override runway is active.
    /// @dev The recurring window is Friday 19:00 UTC through Sunday 21:59:59 UTC. This window starts before and ends
    ///      after the narrower frozen-oracle interval.
    /// @return Whether FAD maintenance and risk-increase restrictions are active
    function isFadWindow() external view returns (bool);

    /// @notice Maximum oracle staleness allowed while the oracle is frozen.
    /// @return Frozen-market mark age limit in seconds
    function fadMaxStaleness() external view returns (uint256);

    /// @notice Maximum cached engine mark staleness allowed for live-market checks.
    /// @dev Some live checks use the smaller nonzero value of this bound and the HousePool bound.
    /// @return Engine live-mark age component in seconds
    function engineMarkStalenessLimit() external view returns (uint256);

    /// @notice Returns whether a day number is configured as a FAD override.
    /// @param dayNumber Unix day number to inspect
    /// @return Whether the entire day is configured as FAD and oracle-frozen
    function fadDayOverrides(
        uint256 dayNumber
    ) external view returns (bool);

    /// @notice Returns whether the recurring frozen interval or a configured all-day override is active.
    /// @dev The recurring interval is Friday 22:00 UTC through Sunday 20:59:59 UTC.
    /// @return Whether frozen-oracle policy is active
    function isOracleFrozen() external view returns (bool);

    /// @notice Returns the current live position tuple for an account.
    /// @param account Account to inspect
    /// @return size Position size (18 decimals)
    /// @return margin Current active position margin (6 decimals)
    /// @return entryPrice Average entry price (8 decimals)
    /// @return maxProfitUsdc Position maximum profit envelope (6 decimals)
    /// @return side Position side
    /// @return lastUpdateTime Last position mutation timestamp
    /// @return vpiAccrued Lifetime signed VPI in USDC; positive is charged and negative is rebated
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

    /// @notice True when a close or liquidation has latched degraded mode after revealing adjusted insolvency.
    /// @return Whether risk-increasing actions are disabled by the insolvency latch
    function degradedMode() external view returns (bool);

}
