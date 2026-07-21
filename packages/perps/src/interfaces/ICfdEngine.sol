// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

/// @notice Legacy aggregate CFD engine ABI covering execution state and diagnostic preview selectors.
/// @dev No live contract is required to implement this complete aggregate surface: the canonical engine implements
///      stateful selectors, while liquidation preview selectors are implemented by `ICfdEngineLens`.
///      Product-facing consumers should prefer the slim public surfaces in
///      `IPerpsTraderActions`, `IPerpsTraderViews`, `IPerpsLPActions`, `IPerpsLPViews`,
///      `IPerpsKeeper`, `IProtocolViews`, and `IMarginAccount`.
///      Live protocol contracts should prefer smaller role-specific interfaces like `ICfdEngineCore`.
///      Unless stated otherwise, USDC amounts use 6 decimals, prices use 8 decimals, position sizes use 18 decimals,
///      basis-point values use a 10,000 denominator, and timestamps are Unix seconds.
interface ICfdEngine is ICfdEngineTypes {

    /// @notice Margin clearinghouse address used for account margin locking/unlocking
    /// @return Clearinghouse contract address
    function clearinghouse() external view returns (address);

    /// @notice Current order router allowed to execute orders through the engine.
    /// @return Configured router address, or zero before one-time wiring
    function orderRouter() external view returns (address);

    /// @notice Clearinghouse account that receives protocol fee credits.
    /// @return Current protocol treasury account
    function protocolTreasury() external view returns (address);

    /// @notice Settlement token used for fees, margin, and payouts
    /// @return USDC-compatible settlement token
    function USDC() external view returns (IERC20);

    /// @notice Last mark price observed by the engine (8 decimals)
    /// @return Cached engine mark price, or zero before the first mark
    function lastMarkPrice() external view returns (uint256);

    /// @notice Router-facing order execution entrypoint with typed business-rule failures.
    /// @dev Callable only by the configured router. Reverts with `CfdEngine__TypedOrderFailure` for expected order
    ///      invalidations so the router can apply deterministic bounty policy without selector matching. Successful
    ///      execution delegates the planned clearinghouse, HousePool, aggregate-side, and position mutations.
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

    /// @notice Reserves close-order execution bounty from free settlement first, then active position margin.
    /// @dev Callable only by the router. Carry is realized first, and any margin-backed portion must preserve the
    ///      required risk backing for the proportional position slice.
    /// @param account Account committing the close order
    /// @param sizeDelta Position size the close order intends to close (18 decimals)
    /// @param amountUsdc Execution bounty amount to reserve in USDC
    function reserveCloseOrderExecutionBounty(
        address account,
        uint256 sizeDelta,
        uint256 amountUsdc
    ) external;

    /// @notice Moves forfeited reserved execution-bounty reservation into the protocol treasury account.
    /// @dev Callable only by the router. Reclassifies clearinghouse balances without moving ERC20 tokens; zero is a
    ///      no-op.
    /// @param sourceAccount Account whose reserved settlement bounty is forfeited
    /// @param amountUsdc Reserved USDC amount to transfer into the protocol treasury account
    function absorbReservedExecutionBounty(
        address sourceAccount,
        uint256 amountUsdc
    ) external;

    /// @notice Credits a reserved execution bounty into the beneficiary's clearinghouse account.
    /// @dev Callable only by the router. Realizes or checkpoints carry first when the beneficiary has an open position
    ///      so the credit cannot dilute elapsed carry. A strictly newer mark is capped and cached; zero is a no-op.
    /// @param sourceAccount Account whose reserved settlement bounty funds the credit
    /// @param beneficiary Account receiving the clearinghouse settlement credit
    /// @param amountUsdc Reserved USDC amount to reclassify
    /// @param price Router-validated mark price used to checkpoint beneficiary carry when needed (8 decimals)
    /// @param publishTime Oracle publish timestamp associated with `price`
    function creditBounty(
        address sourceAccount,
        address beneficiary,
        uint256 amountUsdc,
        uint256 price,
        uint64 publishTime
    ) external;

    /// @notice Liquidates an undercollateralized position, returns keeper bounty in USDC
    /// @dev Callable only by the configured router. Deletes the full position, settles collateral and any surplus or
    ///      bad debt, credits the keeper internally, and can latch degraded mode after a post-operation shortfall.
    /// @param account          Account holding the position to liquidate
    /// @param currentOraclePrice Mark price from the oracle (8 decimals)
    /// @param poolDepthUsdc     HousePool effective total assets used for planning and settlement checks (6 decimals)
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
    /// @dev Callable only by the configured clearinghouse. Accounts without a position are no-ops.
    /// @param account Account whose open-position carry should be realized if a position exists
    function realizeCarryBeforeMarginChange(
        address account
    ) external;

    /// @notice Permissionlessly advances both side carry indexes to the current timestamp.
    /// @dev Uses effective HousePool depth capped by raw token custody, and does not realize carry against individual
    ///      accounts or update the oracle mark.
    function checkpointCarryIndexes() external;

    /// @notice Canonical liquidation preview using the pool's current custody-capped effective assets.
    /// @dev Implemented by the diagnostic engine lens, not by the canonical stateful `CfdEngine` deployment.
    /// @param account Account whose position would be tested
    /// @param oraclePrice Oracle price used for the preview, clamped to `CAP_PRICE` (8 decimals)
    /// @return preview Liquidation economics and projected post-operation solvency
    function previewLiquidation(
        address account,
        uint256 oraclePrice
    ) external view returns (LiquidationPreview memory preview);

    /// @notice Hypothetical liquidation simulation at a caller-supplied pool depth.
    /// @dev Implemented by the diagnostic engine lens, not by the canonical stateful `CfdEngine` deployment.
    /// @param account Account whose position would be tested
    /// @param oraclePrice Oracle price used for the simulation, clamped to `CAP_PRICE` (8 decimals)
    /// @param poolDepthUsdc Hypothetical HousePool depth in USDC
    /// @return preview Liquidation economics and projected post-operation solvency
    function simulateLiquidation(
        address account,
        uint256 oraclePrice,
        uint256 poolDepthUsdc
    ) external view returns (LiquidationPreview memory preview);

    /// @notice Trader claim balance still owed to beneficiaries.
    /// @return Aggregate senior HousePool payout liability in USDC
    function totalTraderClaimBalanceUsdc() external view returns (uint256);

    /// @notice Timestamp of the last mark price update
    /// @return Oracle publish timestamp associated with `lastMarkPrice`
    function lastMarkTime() external view returns (uint64);

    /// @notice Pushes a fresh mark price without processing an order.
    /// @dev Callable only by the router. Caps the price, rejects an older publish time, advances side indexes, and
    ///      updates the cached mark; account-level carry is realized on execution and margin-mutating paths.
    /// @param price       New mark price (8 decimals)
    /// @param publishTime Oracle publish timestamp for the price update
    function updateMarkPrice(
        uint256 price,
        uint64 publishTime
    ) external;

    /// @notice Protocol cap price (8 decimals). Oracle prices are clamped to this.
    /// @return Maximum supported oracle price
    function CAP_PRICE() external view returns (uint256);

    /// @notice Returns whether recurring FAD, an override day, or the configured pre-override runway is active.
    /// @dev The recurring window is Friday 19:00 UTC through Sunday 21:59:59 UTC. This window starts before and ends
    ///      after the narrower frozen-oracle interval.
    /// @return Whether FAD maintenance and risk-increase restrictions are active
    function isFadWindow() external view returns (bool);

    /// @notice Maximum oracle staleness allowed while the oracle is frozen.
    /// @return Frozen-market mark age limit in seconds
    function fadMaxStaleness() external view returns (uint256);

    /// @notice Returns whether the recurring frozen interval or a configured all-day override is active.
    /// @dev The recurring interval is Friday 22:00 UTC through Sunday 20:59:59 UTC.
    /// @return Whether frozen-oracle policy is active
    function isOracleFrozen() external view returns (bool);

    /// @notice Returns the current position tuple for an account.
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

    /// @notice Returns the indexed carry basis for a position.
    /// @param account Account to inspect
    /// @return borrowBaseUsdc Position LP borrow base used for carry utilization, in USDC
    /// @return lastCarryIndex Side carry index last stored on the position, scaled by 1e18
    /// @return lastCarryTimestamp Unix timestamp through which position carry was last checkpointed
    function positionCarryState(
        address account
    ) external view returns (uint256 borrowBaseUsdc, uint256 lastCarryIndex, uint64 lastCarryTimestamp);

    /// @notice True when a close or liquidation has latched degraded mode after revealing adjusted insolvency.
    /// @return Whether risk-increasing actions are disabled by the insolvency latch
    function degradedMode() external view returns (bool);

    /// @notice Whether a given day number is an admin-configured FAD override
    /// @param dayNumber Unix day number to inspect
    /// @return Whether the entire day is configured as FAD and oracle-frozen
    function fadDayOverrides(
        uint256 dayNumber
    ) external view returns (bool);

    /// @notice High-level protocol lifecycle used by external status consumers.
    /// @dev `Active` means required engine wiring exists and the HousePool has enabled live risk-taking.
    enum ProtocolPhase {
        /// @notice Dependencies or pool seed/trading lifecycle are not yet ready for live risk.
        Configuring,
        /// @notice Required dependencies are wired and the HousePool permits live risk.
        Active,
        /// @notice The engine has latched adjusted insolvency and disabled risk increases.
        Degraded
    }

}
