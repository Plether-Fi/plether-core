// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IPyth} from "@plether/shared/interfaces/IPyth.sol";

/// @title Plether perps basket oracle interface
/// @notice Builds a capped, mode-aware Pyth basket for perps execution, liquidation, and pool accounting.
/// @dev Basket prices and aggregate confidence use 8 decimals. Payable update functions validate submitted Pyth data
///      and return the resulting snapshot atomically, but do not write the engine's cached mark. Unless noted otherwise,
///      update entrypoints are permissionless and refund ETH above Pyth's fee to the requested recipient, deferring a
///      failed refund for later claim.
interface IPletherOracle {

    /// @notice Action whose freshness and component-timing policy is applied to a basket read.
    enum PriceMode {
        /// @notice Delayed order execution or the corresponding neutral current-basket read.
        OrderExecution,
        /// @notice Refresh of the engine's cached mark, including the policy used for voluntary closes.
        MarkRefresh,
        /// @notice Liquidation price resolution.
        Liquidation,
        /// @notice HousePool reconciliation or withdrawal accounting.
        PoolReconcile
    }

    /// @notice Validated basket price and the policy metadata used to produce it.
    /// @param price Action price in 8-decimal units; specialized execution paths may shift it against an account.
    /// @param markPrice Neutral capped basket price in 8-decimal units, before any action-specific adverse shift.
    /// @param publishTime Earliest component publish time as a Unix timestamp.
    /// @param updateFee Pyth fee quoted for this resolution in wei, or zero for a view read or reused batch cache;
    ///        an unavailable nonreverting historical parse reports the fee even though it is refunded or deferred.
    /// @param maxStaleness Effective maximum component age in seconds for the selected policy.
    /// @param closeOnly Whether current policy prohibits opens and increases; callers enforce this flag.
    /// @param oracleFrozen Whether the frozen-oracle calendar policy was active when the snapshot was built.
    /// @param isFadWindow Whether FAD controls were active when the snapshot was built.
    struct PriceSnapshot {
        uint256 price;
        uint256 markPrice;
        uint64 publishTime;
        uint256 updateFee;
        uint256 maxStaleness;
        bool closeOnly;
        bool oracleFrozen;
        bool isFadWindow;
    }

    /// @notice Oracle and stored-mark constraints selected for one action under current calendar state.
    /// @param closeOnly Whether the regime prohibits opens and increases.
    /// @param requireStoredMark Whether the action requires a nonzero cached engine mark.
    /// @param allowAnyStoredMark Whether a required cached mark may be used without an age limit.
    /// @param maxStaleness Maximum component or mark age in seconds when age is enforced.
    /// @param oracleFrozen Whether frozen-oracle policy is active.
    /// @param isFadWindow Whether FAD controls are active.
    struct PolicySnapshot {
        bool closeOnly;
        bool requireStoredMark;
        bool allowAnyStoredMark;
        uint256 maxStaleness;
        bool oracleFrozen;
        bool isFadWindow;
    }

    /// @notice Complete mutable oracle-policy configuration.
    /// @param orderExecutionStalenessLimit Maximum live order-execution and mark-refresh component age, in seconds.
    /// @param liquidationStalenessLimit Maximum live liquidation component age, in seconds.
    /// @param pythMaxConfidenceRatioBps Maximum accepted per-feed confidence-to-price ratio, in basis points.
    /// @param orderSettlementWindow Post-commit window for a unique historical execution tick, in seconds.
    /// @param maxComponentPublishTimeDivergence Maximum component-time divergence for a historical basket, in seconds.
    /// @param adverseConfidenceMultiplierBps Basis-point multiplier applied to aggregate confidence for adverse pricing.
    struct OracleConfig {
        uint256 orderExecutionStalenessLimit;
        uint256 liquidationStalenessLimit;
        uint256 pythMaxConfidenceRatioBps;
        uint256 orderSettlementWindow;
        uint256 maxComponentPublishTimeDivergence;
        uint256 adverseConfidenceMultiplierBps;
    }

    /// @notice Inputs that identify and price one delayed order.
    /// @param commitTime Order commit time; live execution requires a unique tick strictly after this timestamp.
    /// @param targetPrice Router-enforced slippage target in 8-decimal units; the oracle does not inspect this field.
    /// @param side Position side used to choose the adverse confidence-shift direction.
    /// @param isClose Whether the order reduces a position; also waives the confidence shift during frozen policy.
    /// @param revertOnHistoricalUnavailable Whether failure to find a unique historical tick reverts instead of
    ///        returning `ok == false`.
    struct OrderExecutionRequest {
        uint64 commitTime;
        uint256 targetPrice;
        CfdTypes.Side side;
        bool isClose;
        bool revertOnHistoricalUnavailable;
    }

    /// @notice Neutral historical basket that a batch caller may offer for a later compatible order.
    /// @dev Callers should pass through a cache returned by `updateBatchOrderExecutionPrice`; fabricated cache contents
    ///      are not independently authenticated by the oracle.
    /// @param hasHistoricalBasket Whether the remaining fields contain a reusable historical basket.
    /// @param minReusableCommitTime Earliest commit time for which the cached tick was originally proven valid.
    /// @param price Neutral, pre-cap basket price in 8-decimal units.
    /// @param confidence Aggregate basket confidence in 8-decimal price units.
    /// @param publishTime Earliest component publish time for the cached basket.
    struct BatchOrderPriceCache {
        bool hasHistoricalBasket;
        uint64 minReusableCommitTime;
        uint256 price;
        uint256 confidence;
        uint64 publishTime;
    }

    /// @notice Thrown when the caller is not the engine's configured order router.
    error PletherOracle__Unauthorized();
    /// @notice Thrown when a caller tries to claim with no deferred ETH refund.
    error PletherOracle__NothingToClaim();
    /// @notice Thrown when sending a deferred ETH refund to its claimant fails.
    error PletherOracle__EthTransferFailed();
    /// @notice Thrown when deployment is attempted with an empty basket.
    error PletherOracle__NoFeeds();
    /// @notice Thrown when basket arrays or parsed feed results have incompatible lengths or ordering.
    /// @param feedIdsLength Number of configured or returned feed ids.
    /// @param quantitiesLength Number of configured weights.
    /// @param basePricesLength Number of configured base prices.
    /// @param inversionsLength Number of configured inversion flags.
    error PletherOracle__ArrayLengthMismatch(
        uint256 feedIdsLength, uint256 quantitiesLength, uint256 basePricesLength, uint256 inversionsLength
    );
    /// @notice Thrown when a configured basket component has a zero normalization base price.
    /// @param index Zero-based component index.
    error PletherOracle__ZeroBasePrice(uint256 index);
    /// @notice Thrown when configured 18-decimal basket weights do not sum exactly to `1e18`.
    /// @param totalWeight Actual sum of the supplied weights.
    error PletherOracle__InvalidTotalWeight(uint256 totalWeight);
    /// @notice Thrown when deployment is attempted with the zero Pyth address.
    error PletherOracle__ZeroPyth();
    /// @notice Thrown when a Pyth fee or update is requested with no update payloads.
    error PletherOracle__MissingUpdateData();
    /// @notice Thrown when `msg.value` does not cover Pyth's quoted fee.
    /// @param provided ETH supplied in wei.
    /// @param required ETH required by Pyth in wei.
    error PletherOracle__InsufficientFee(uint256 provided, uint256 required);
    /// @notice Thrown when a current basket predates the engine's cached mark.
    /// @param publishTime Earliest basket component publish time.
    /// @param lastMarkTime Engine cached-mark publish time.
    error PletherOracle__PriceOutOfOrder(uint64 publishTime, uint64 lastMarkTime);
    /// @notice Thrown when a component is future-dated, too old, or required historical data is unavailable.
    /// @param mode Action policy under which validation failed.
    /// @param feedId Failing Pyth feed id, or zero when no individual historical feed is available.
    /// @param publishTime Component publish time or attempted historical-window endpoint.
    /// @param maxStaleness Maximum permitted age in seconds.
    /// @param currentTimestamp Timestamp used for validation.
    error PletherOracle__StalePrice(
        PriceMode mode, bytes32 feedId, uint256 publishTime, uint256 maxStaleness, uint256 currentTimestamp
    );
    /// @notice Thrown when a Pyth component price is nonpositive.
    /// @param feedId Failing Pyth feed id, or zero for an internal normalization failure.
    /// @param price Raw signed Pyth price.
    error PletherOracle__InvalidPrice(bytes32 feedId, int64 price);
    /// @notice Thrown when a component confidence-to-price ratio exceeds its configured limit.
    /// @param feedId Failing Pyth feed id.
    /// @param confidence Raw unsigned Pyth confidence interval.
    /// @param price Raw signed Pyth price.
    /// @param maxConfidenceBps Maximum permitted confidence ratio in basis points.
    error PletherOracle__ConfidenceTooWide(bytes32 feedId, uint64 confidence, int64 price, uint256 maxConfidenceBps);
    /// @notice Thrown when basket component publish times are too far apart.
    /// @param mode Action policy under which validation failed.
    /// @param minPublishTime Earliest component publish time.
    /// @param maxPublishTime Latest component publish time.
    /// @param maxDivergence Maximum permitted difference in seconds.
    error PletherOracle__PublishTimeDivergence(
        PriceMode mode, uint256 minPublishTime, uint256 maxPublishTime, uint256 maxDivergence
    );
    /// @notice Thrown when weighted basket construction rounds or resolves to zero.
    error PletherOracle__ZeroBasketPrice();
    /// @notice Thrown when configuration contains a zero required window or an excessive component divergence.
    error PletherOracle__InvalidSettlementConfig();

    /// @notice Emitted when an immediate excess-fee refund fails and becomes claimable.
    /// @param recipient Account credited with the deferred refund.
    /// @param amount Deferred ETH amount in wei.
    event EthRefundDeferred(address indexed recipient, uint256 amount);
    /// @notice Emitted when an account claims its deferred ETH refund.
    /// @param recipient Account that received the refund.
    /// @param amount Claimed ETH amount in wei.
    event EthRefundClaimed(address indexed recipient, uint256 amount);

    /// @notice Atomically applies oracle update data and returns the validated price snapshot for `mode`.
    /// @dev Pays Pyth's quoted fee, validates the resulting current neutral basket under the selected freshness,
    ///      confidence, component-timing, and publish-order policy, then caps price at `engine.CAP_PRICE()`. It does not
    ///      update the engine mark. Execution callers should consume this returned snapshot instead of splitting an
    ///      update from a later `getLatestPrice` read. ETH above Pyth's fee is refunded or deferred.
    /// @param refundRecipient Recipient for any ETH left after paying Pyth fees
    /// @param pythUpdateData Pyth price update blobs
    /// @param mode Oracle policy mode to apply
    /// @return snapshot Validated price, mark, publish time, fee, and policy metadata
    function updatePrice(
        address refundRecipient,
        bytes[] calldata pythUpdateData,
        PriceMode mode
    ) external payable returns (PriceSnapshot memory snapshot);

    /// @notice Applies order-execution update data and returns a validated execution price.
    /// @dev Outside frozen-oracle policy, resolves a unique historical basket in
    ///      `(commitTime, min(commitTime + orderSettlementWindow, block.timestamp)]`. Frozen policy instead performs a
    ///      normal Pyth update and validates the current basket with the relaxed age limit. `price` is shifted against
    ///      the requested side by aggregate confidence, except for a frozen voluntary close; `markPrice` stays neutral.
    ///      This function reports but does not enforce close-only policy and ignores `request.targetPrice`. Successful
    ///      calls do not refund overpayment, so callers should supply exactly Pyth's quoted fee. If a nonreverting
    ///      historical parse is unavailable, exactly that fee is refunded or deferred and `ok` is false.
    /// @param refundRecipient Recipient for the Pyth-fee refund when a historical parse is unavailable.
    /// @param pythUpdateData Nonempty Pyth update or unique historical-parse payloads.
    /// @param request Commit, side, close, and unavailable-history inputs; its target price is caller-enforced.
    /// @return ok True when a valid execution snapshot was produced
    /// @return snapshot Validated historical or frozen-mode execution snapshot
    function updateOrderExecutionPrice(
        address refundRecipient,
        bytes[] calldata pythUpdateData,
        OrderExecutionRequest calldata request
    ) external payable returns (bool ok, PriceSnapshot memory snapshot);

    /// @notice Batch variant that can reuse a historical tick already proven unique for later commits.
    /// @dev Reuse is available only outside frozen policy when the cached publish time is after the new commit, within
    ///      its settlement window, no later than the current time, and covered by `minReusableCommitTime`. Reuse pays no
    ///      Pyth fee and does not refund any ETH supplied with the call. Otherwise, fee handling and price construction
    ///      match `updateOrderExecutionPrice`. Only a successful new historical parse extends `nextCache`; a frozen
    ///      current basket is never cached.
    /// @param refundRecipient Recipient for the Pyth-fee refund when a historical parse is unavailable.
    /// @param pythUpdateData Pyth payloads, which may be unused when `cache` is reusable.
    /// @param request Commit, side, close, and unavailable-history inputs; its target price is caller-enforced.
    /// @param cache Historical basket returned by an earlier batch call.
    /// @return ok True when a valid execution snapshot was produced
    /// @return snapshot Validated historical or frozen-mode execution snapshot
    /// @return nextCache Cache to pass to the next batch order
    function updateBatchOrderExecutionPrice(
        address refundRecipient,
        bytes[] calldata pythUpdateData,
        OrderExecutionRequest calldata request,
        BatchOrderPriceCache calldata cache
    ) external payable returns (bool ok, PriceSnapshot memory snapshot, BatchOrderPriceCache memory nextCache);

    /// @notice Applies liquidation update data and returns a price adverse to the liquidated account.
    /// @dev Performs a normal Pyth update, validates the current basket under liquidation policy and against the engine's
    ///      cached-mark time, then shifts price against the account's current position side. An account without a
    ///      position receives the neutral basket. The engine mark is not updated; excess ETH is refunded or deferred.
    /// @param refundRecipient Recipient for any ETH left after paying Pyth fees.
    /// @param pythUpdateData Nonempty Pyth update payloads.
    /// @param account Account whose engine position determines the adverse confidence-shift direction.
    /// @return snapshot Adverse 8-decimal price, neutral mark, earliest publish time, fee, and policy metadata.
    function updateLiquidationPrice(
        address refundRecipient,
        bytes[] calldata pythUpdateData,
        address account
    ) external payable returns (PriceSnapshot memory snapshot);

    /// @notice Applies oracle update data and returns the latest live order-execution basket price.
    /// @dev Equivalent to `updatePrice(refundRecipient, pythUpdateData, PriceMode.OrderExecution).price`. It reads the
    ///      current neutral basket; it neither parses a unique post-commit tick nor applies a side-adverse shift.
    /// @param refundRecipient Recipient for any ETH left after paying Pyth fees.
    /// @param pythUpdateData Nonempty Pyth update payloads.
    /// @return latestPrice Latest validated neutral order-policy basket price in 8-decimal units.
    function updatePrice(
        address refundRecipient,
        bytes[] calldata pythUpdateData
    ) external payable returns (uint256 latestPrice);

    /// @notice Returns the current validated oracle snapshot without applying a Pyth update.
    /// @dev Reads Pyth's current unsafe prices, then enforces the selected age, confidence, component-timing, and
    ///      publish-order policy. Both prices are the neutral capped basket and `updateFee` is zero. The call may revert
    ///      if current feed state is invalid or stale.
    /// @param mode Oracle policy mode to apply.
    /// @return snapshot Validated neutral price, mark, publish time, zero fee, and policy metadata.
    function getLatestPrice(
        PriceMode mode
    ) external view returns (PriceSnapshot memory snapshot);

    /// @notice Returns the latest validated live order-execution basket price without applying a Pyth update.
    /// @dev Equivalent to `getLatestPrice(PriceMode.OrderExecution).price`; it is neither historical nor side-adjusted.
    /// @return latestPrice Latest validated neutral order-policy basket price in 8-decimal units.
    function getLatestPrice() external view returns (uint256 latestPrice);

    /// @notice Claims the caller's full deferred ETH refund.
    /// @dev Reverts if the caller has no refund or if the nonreentrant ETH transfer fails; a failed transfer restores the
    ///      claimable balance.
    function claimEthRefund() external;

    /// @notice Returns deferred ETH refund balance for an account.
    /// @param account Account to inspect.
    /// @return amount Claimable ETH amount in wei.
    function claimableEth(
        address account
    ) external view returns (uint256 amount);

    /// @notice Returns the order-execution oracle policy for open or close commits.
    /// @dev Opens and increases select `OrderExecution`; closes select `MarkRefresh`. The snapshot reports current engine,
    ///      HousePool, and calendar state without reading or updating Pyth.
    /// @param isClose True for close orders, false for open or increase orders.
    /// @return policy Effective policy snapshot.
    function getOrderExecutionPolicy(
        bool isClose
    ) external view returns (PolicySnapshot memory policy);

    /// @notice Applies oracle policy configuration from the configured router.
    /// @dev Callable only by `engine.orderRouter()`. Both staleness limits, the settlement window, and component
    ///      divergence must be nonzero, and divergence cannot exceed the settlement window. Ratio and multiplier fields
    ///      may be zero. This replaces all mutable policy fields without updating Pyth or engine price state.
    /// @param config Complete replacement oracle-policy configuration.
    function applyConfig(
        OracleConfig calldata config
    ) external;

    /// @notice Quotes the ETH fee required to apply `pythUpdateData`.
    /// @dev Reverts for an empty update-data array.
    /// @param pythUpdateData Nonempty Pyth price-update blobs.
    /// @return pythFee ETH fee required by Pyth, in wei.
    function getUpdateFee(
        bytes[] calldata pythUpdateData
    ) external view returns (uint256 pythFee);

    /// @notice Returns whether the market calendar allows frozen-oracle policy.
    /// @dev The recurring window is Friday 22:00 UTC through Sunday 20:59:59 UTC. An engine override freezes its entire
    ///      UTC day; the FAD runway does not extend this window.
    /// @return Whether frozen-oracle policy is active at the current timestamp.
    function isOracleFrozen() external view returns (bool);

    /// @notice Returns the configured live order-execution and mark-refresh component-age limit.
    /// @dev Frozen-oracle policy uses `engine.fadMaxStaleness()` instead of this value.
    /// @return Configured live maximum component age in seconds.
    function orderExecutionStalenessLimit() external view returns (uint256);

    /// @notice Returns the configured live liquidation component-age limit.
    /// @dev Frozen-oracle policy uses `engine.fadMaxStaleness()` instead of this value.
    /// @return Configured live maximum liquidation component age in seconds.
    function liquidationStalenessLimit() external view returns (uint256);

    /// @notice Returns the max accepted Pyth confidence ratio in basis points.
    /// @return Maximum confidence-to-price ratio in basis points.
    function pythMaxConfidenceRatioBps() external view returns (uint256);

    /// @notice Returns the post-commit settlement window for historical order execution.
    /// @return Historical execution window in seconds.
    function orderSettlementWindow() external view returns (uint256);

    /// @notice Returns max allowed publish-time divergence across basket components.
    /// @dev This configured value applies to unique historical order baskets; current-basket reads derive their
    ///      divergence limit from the applicable live staleness configuration.
    /// @return Historical basket component-time divergence limit in seconds.
    function maxComponentPublishTimeDivergence() external view returns (uint256);

    /// @notice Returns the multiplier used for adverse order pricing outside oracle-frozen voluntary closes
    ///         and for all liquidation pricing.
    /// @return Aggregate-confidence multiplier in basis points.
    function adverseConfidenceMultiplierBps() external view returns (uint256);

    /// @notice Returns the engine used for cap, side, and calendar state.
    /// @return Configured perps engine.
    function engine() external view returns (ICfdEngineCore);

    /// @notice Returns the HousePool used for pool-side freshness policy.
    /// @return Configured HousePool.
    function housePool() external view returns (IHousePool);

    /// @notice Returns the Pyth contract used for price updates and historical parsing.
    /// @return Configured Pyth endpoint.
    function pyth() external view returns (IPyth);

}
