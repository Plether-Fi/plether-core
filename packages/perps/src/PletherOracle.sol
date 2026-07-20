// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MarketCalendarLib} from "@plether/perps/libraries/MarketCalendarLib.sol";
import {OracleFreshnessPolicyLib} from "@plether/perps/libraries/OracleFreshnessPolicyLib.sol";
import {IPyth, PythStructs} from "@plether/shared/interfaces/IPyth.sol";
import {DecimalConstants} from "@plether/shared/libraries/DecimalConstants.sol";

/// @title PletherOracle
/// @notice Builds the Plether perps basket from Pyth feeds under action-specific freshness and execution policies.
/// @dev Basket prices and confidence amounts use 8 decimals. This contract pays for submitted Pyth updates, validates
///      feed price/confidence/freshness and component timing, applies side-adverse confidence shifts where required,
///      and caps returned prices at the engine's `CAP_PRICE`. Feed ids, weights, bases, inversion flags, the engine,
///      the HousePool, and Pyth endpoint cannot be changed after deployment; policy limits can be changed only by the
///      engine-reported order router. State-changing execution should consume the snapshot returned by the applicable
///      update entrypoint instead of splitting update and view calls. Anyone may call the payable update entrypoints.
/// @custom:security-contact contact@plether.com
contract PletherOracle is IPletherOracle, ReentrancyGuardTransient {

    /// @notice Internal aggregate of a validated set of basket component prices.
    /// @param price Weighted basket price in 8-decimal units
    /// @param confidence Sum of weighted component confidence contributions in 8-decimal price units
    /// @param publishTime Earliest component publish time as a Unix timestamp
    /// @param pythFee ETH fee paid to Pyth in wei, or zero when no Pyth call was required
    struct BasketPrice {
        uint256 price;
        uint256 confidence;
        uint64 publishTime;
        uint256 pythFee;
    }

    /// @notice Engine queried for cap price, mark state, account positions, calendar state, and router authorization.
    ICfdEngineCore public immutable engine;

    /// @notice HousePool queried for its mark-staleness limit when building pool-reconciliation policy.
    IHousePool public immutable housePool;

    /// @notice Pyth endpoint used for current-feed updates, unsafe reads, and unique historical parsing.
    IPyth public immutable override pyth;

    /// @notice Pyth feed id at each basket component index.
    bytes32[] public pythFeedIds;

    /// @notice 18-decimal basket weight at each component index; all stored weights sum to `1e18`.
    uint256[] public quantities;

    /// @notice 8-decimal base price used to normalize each basket component.
    uint256[] public basePrices;

    /// @notice Whether the component at each index is inverted before base-price normalization.
    bool[] public inversions;

    /// @notice Maximum live order-execution and mark-refresh component age, in seconds.
    /// @dev Also bounds component publish-time divergence for current live order and mark baskets. Frozen-oracle
    ///      policy instead uses the engine's `fadMaxStaleness` for age validation.
    uint256 public override orderExecutionStalenessLimit = 60;

    /// @notice Maximum live liquidation component age, in seconds.
    /// @dev Also bounds component publish-time divergence for current live liquidation baskets. Frozen-oracle policy
    ///      instead uses the engine's `fadMaxStaleness` for age validation.
    uint256 public override liquidationStalenessLimit = 15;

    /// @notice Maximum accepted per-feed confidence-to-price ratio, in basis points.
    uint256 public override pythMaxConfidenceRatioBps = 10;

    /// @notice Post-commit window searched for a unique historical order-execution tick, in seconds.
    uint256 public override orderSettlementWindow = 15;

    /// @notice Maximum component publish-time divergence for uniquely parsed historical order baskets, in seconds.
    uint256 public override maxComponentPublishTimeDivergence = 5;

    /// @notice Basis-point multiplier applied to aggregate basket confidence for side-adverse execution pricing.
    /// @dev The default `2000` applies 20% of the confidence amount. Frozen-oracle voluntary closes waive this shift;
    ///      liquidation and other order pricing retain it.
    uint256 public override adverseConfidenceMultiplierBps = 2000;

    /// @notice Deferred ETH refund balance, in wei, for each recipient whose direct refund transfer failed.
    mapping(address => uint256) public override claimableEth;

    /// @notice Deploys an immutable Pyth basket configuration.
    /// @dev Requires a nonzero Pyth address, at least one feed, equal array lengths, nonzero base prices, and weights
    ///      summing exactly to `1e18`. The engine and HousePool addresses are stored without zero-address, code, or
    ///      interface validation. Individual feed ids and weights may be zero.
    /// @param engine_ Engine used for cap, mark, position-side, calendar, and router-authorization state
    /// @param housePool_ HousePool used for pool-reconciliation freshness policy
    /// @param pyth_ Nonzero Pyth contract used for update and historical-parse calls
    /// @param feedIds_ Ordered Pyth feed ids included in the basket
    /// @param quantities_ Ordered 18-decimal basket weights; must sum exactly to `1e18`
    /// @param basePrices_ Ordered nonzero component base prices in 8-decimal units
    /// @param inversions_ Ordered flags selecting inverse-price normalization for each component
    constructor(
        address engine_,
        address housePool_,
        address pyth_,
        bytes32[] memory feedIds_,
        uint256[] memory quantities_,
        uint256[] memory basePrices_,
        bool[] memory inversions_
    ) {
        if (pyth_ == address(0)) {
            revert PletherOracle__ZeroPyth();
        }

        engine = ICfdEngineCore(engine_);
        housePool = IHousePool(housePool_);
        pyth = IPyth(pyth_);

        if (feedIds_.length == 0) {
            revert PletherOracle__NoFeeds();
        }
        if (
            feedIds_.length != quantities_.length || feedIds_.length != basePrices_.length
                || feedIds_.length != inversions_.length
        ) {
            revert PletherOracle__ArrayLengthMismatch(
                feedIds_.length, quantities_.length, basePrices_.length, inversions_.length
            );
        }

        uint256 totalWeight;
        for (uint256 i = 0; i < basePrices_.length; i++) {
            if (basePrices_[i] == 0) {
                revert PletherOracle__ZeroBasePrice(i);
            }
            totalWeight += quantities_[i];
        }
        if (totalWeight != 1e18) {
            revert PletherOracle__InvalidTotalWeight(totalWeight);
        }

        pythFeedIds = feedIds_;
        quantities = quantities_;
        basePrices = basePrices_;
        inversions = inversions_;
    }

    /// @notice Pays for Pyth update data and returns the validated current basket snapshot for a policy mode.
    /// @dev Requires nonempty update data and at least Pyth's quoted fee in `msg.value`. Reads all configured feeds
    ///      after updating Pyth, validates the selected mode's age and publish-time-divergence policy, rejects a basket
    ///      older than the engine mark, and clamps price and mark price to `CAP_PRICE`. It does not update the engine
    ///      mark. ETH above the Pyth fee is sent to `refundRecipient` or recorded in `claimableEth` if that call fails.
    /// @param refundRecipient Recipient of `msg.value` remaining after the Pyth fee
    /// @param pythUpdateData Nonempty Pyth update payloads passed to `updatePriceFeeds`
    /// @param mode Policy selecting freshness and component-divergence limits
    /// @return snapshot Current 8-decimal price/mark, earliest publish time, fee in wei, and policy metadata
    function updatePrice(
        address refundRecipient,
        bytes[] calldata pythUpdateData,
        PriceMode mode
    ) external payable override nonReentrant returns (PriceSnapshot memory snapshot) {
        return _updateAndGetSnapshot(refundRecipient, pythUpdateData, mode);
    }

    /// @notice Pays for Pyth update data and returns the validated current order-policy basket price.
    /// @dev Equivalent to the mode-aware overload with `PriceMode.OrderExecution`. This reads the current feed state;
    ///      it does not perform the unique post-commit historical parsing used by delayed orders and does not apply a
    ///      side-adverse confidence shift. The result is capped at `CAP_PRICE`. Excess ETH is refunded or deferred.
    /// @param refundRecipient Recipient of `msg.value` remaining after the Pyth fee
    /// @param pythUpdateData Nonempty Pyth update payloads passed to `updatePriceFeeds`
    /// @return latestPrice Validated current basket price in 8-decimal units
    function updatePrice(
        address refundRecipient,
        bytes[] calldata pythUpdateData
    ) external payable override nonReentrant returns (uint256 latestPrice) {
        return _updateAndGetSnapshot(refundRecipient, pythUpdateData, PriceMode.OrderExecution).price;
    }

    /// @notice Resolves and returns the price used for one delayed order execution.
    /// @dev In live and FAD-only markets, pays for Pyth's unique historical parse over
    ///      `(request.commitTime, request.commitTime + orderSettlementWindow]`, capped at `block.timestamp`. During an
    ///      oracle-frozen window, pays for a normal Pyth update and uses the validated current basket instead. The base
    ///      basket is capped and then shifted against the requested side using aggregate confidence, except that a
    ///      frozen-oracle voluntary close is left unshifted. This function reports `closeOnly` but does not enforce it,
    ///      and does not use `request.targetPrice`; the router enforces policy and slippage. Send exactly the quoted Pyth
    ///      fee: successful execution does not refund overpayment. If historical parsing fails and
    ///      `revertOnHistoricalUnavailable` is false, the Pyth-fee amount is refunded or deferred and `ok` is false.
    /// @param refundRecipient Recipient of the Pyth-fee refund when a nonreverting historical parse is unavailable
    /// @param pythUpdateData Nonempty Pyth update or unique historical-parse payloads
    /// @param request Commit timestamp, caller-enforced target, side, close flag, and unavailable-history behavior
    /// @return ok Whether a valid execution snapshot was produced
    /// @return snapshot Side-adjusted 8-decimal execution price, neutral mark, publish time, fee, and policy metadata
    function updateOrderExecutionPrice(
        address refundRecipient,
        bytes[] calldata pythUpdateData,
        OrderExecutionRequest calldata request
    ) external payable override nonReentrant returns (bool ok, PriceSnapshot memory snapshot) {
        return _updateOrderExecutionPrice(refundRecipient, pythUpdateData, request);
    }

    /// @notice Resolves one delayed-order price and optionally reuses a proven historical basket from the batch cache.
    /// @dev Cache reuse is available only outside oracle-frozen policy when the cached tick is after this commit, not in
    ///      the future, within this commit's settlement window, and covered by the cache's minimum commit time. A reused
    ///      basket pays no Pyth fee and leaves the supplied cache unchanged; any ETH sent with a reused cache remains
    ///      in this contract and is not refunded or credited. Otherwise this follows
    ///      `updateOrderExecutionPrice`, including its confidence shift, exact-fee expectation, caller-enforced
    ///      close-only/slippage policy, and unavailable-history refund behavior. A new historical parse extends the
    ///      returned cache; frozen baskets are never cached.
    /// @param refundRecipient Recipient of the Pyth-fee refund when a nonreverting historical parse is unavailable
    /// @param pythUpdateData Pyth payloads, which may be unused when `cache` is reusable
    /// @param request Commit timestamp, caller-enforced target, side, close flag, and unavailable-history behavior
    /// @param cache Previously proven historical basket and the earliest commit it covers
    /// @return ok Whether a valid execution snapshot was produced
    /// @return snapshot Side-adjusted 8-decimal execution price, neutral mark, publish time, fee, and policy metadata
    /// @return nextCache Cache for the next order; updated only after a new successful historical parse
    function updateBatchOrderExecutionPrice(
        address refundRecipient,
        bytes[] calldata pythUpdateData,
        OrderExecutionRequest calldata request,
        BatchOrderPriceCache calldata cache
    )
        external
        payable
        override
        nonReentrant
        returns (bool ok, PriceSnapshot memory snapshot, BatchOrderPriceCache memory nextCache)
    {
        nextCache = cache;
        PolicySnapshot memory policy = _policyForMode(PriceMode.OrderExecution);

        BasketPrice memory basket;
        bool reusedBasket;
        if (!policy.oracleFrozen && _canReuseHistoricalBatchBasket(request.commitTime, cache)) {
            basket = BasketPrice({
                price: cache.price, confidence: cache.confidence, publishTime: cache.publishTime, pythFee: 0
            });
            reusedBasket = true;
        } else {
            (basket, ok) = _resolveOrderExecutionBasket(refundRecipient, pythUpdateData, request, policy);
            if (!ok) {
                snapshot.updateFee = basket.pythFee;
                return (false, snapshot, nextCache);
            }
        }

        snapshot = _snapshotFromBasket(PriceMode.OrderExecution, basket, policy, false);
        snapshot.price = _orderExecutionPrice(request, snapshot.price, basket.confidence, policy.oracleFrozen);
        if (!policy.oracleFrozen && !reusedBasket) {
            nextCache = BatchOrderPriceCache({
                hasHistoricalBasket: true,
                minReusableCommitTime: request.commitTime,
                price: basket.price,
                confidence: basket.confidence,
                publishTime: basket.publishTime
            });
        }
        ok = true;
    }

    /// @notice Pays for a Pyth update and returns a validated price adverse to the liquidated account's position.
    /// @dev Uses liquidation freshness policy and the minimum component publish time, rejects an out-of-order basket,
    ///      shifts the price upward for a BULL position and downward for a BEAR position by the configured fraction of
    ///      aggregate confidence, then caps it at `CAP_PRICE`. An account with no position receives the neutral basket.
    ///      The function does not update the engine mark. Excess ETH is refunded to `refundRecipient` or deferred.
    /// @param refundRecipient Recipient of `msg.value` remaining after the Pyth fee
    /// @param pythUpdateData Nonempty Pyth update payloads passed to `updatePriceFeeds`
    /// @param account Account whose current engine position determines the adverse direction
    /// @return snapshot Adverse 8-decimal price, neutral mark, earliest publish time, fee, and policy metadata
    function updateLiquidationPrice(
        address refundRecipient,
        bytes[] calldata pythUpdateData,
        address account
    ) external payable override nonReentrant returns (PriceSnapshot memory snapshot) {
        uint256 pythFee = _updatePythPrice(pythUpdateData);
        PolicySnapshot memory policy = _policyForMode(PriceMode.Liquidation);
        BasketPrice memory basket = _computeLiveBasketPrice(
            PriceMode.Liquidation, policy.maxStaleness, _policyPublishTimeDivergence(PriceMode.Liquidation, policy)
        );
        snapshot = _snapshotFromBasket(PriceMode.Liquidation, basket, policy, true);
        snapshot.price = _clampToCap(_adverseLiquidationPrice(account, snapshot.price, basket.confidence));
        snapshot.updateFee = pythFee;
        _refundExcess(refundRecipient, pythFee);
    }

    /// @notice Returns the validated current basket snapshot for a policy mode without updating Pyth.
    /// @dev Reads Pyth's unsafe current prices, then enforces per-component age, confidence width, component publish-time
    ///      divergence, and ordering against the engine's last mark time. Price and mark price are neutral basket values
    ///      capped at `CAP_PRICE`; `updateFee` is zero. This view may revert when current feed state is invalid or stale.
    /// @param mode Policy selecting freshness and component-divergence limits
    /// @return snapshot Current 8-decimal price/mark, earliest publish time, zero fee, and policy metadata
    function getLatestPrice(
        PriceMode mode
    ) external view override returns (PriceSnapshot memory snapshot) {
        return _getLatestPriceSnapshot(mode);
    }

    /// @notice Returns the validated current order-policy basket price without updating Pyth.
    /// @dev Equivalent to `getLatestPrice(PriceMode.OrderExecution).price`. It returns a neutral current basket rather
    ///      than a unique post-commit or side-adverse execution price and may revert on invalid or stale feed state.
    /// @return latestPrice Current basket price in 8-decimal units, capped at `CAP_PRICE`
    function getLatestPrice() external view override returns (uint256 latestPrice) {
        return _getLatestPriceSnapshot(PriceMode.OrderExecution).price;
    }

    /// @notice Sends the caller its full deferred ETH refund balance.
    /// @dev Uses checks-effects-interactions and is nonreentrant. Reverts when the caller has no claim or when the ETH
    ///      transfer fails; a failed claim leaves the balance claimable.
    function claimEthRefund() external override nonReentrant {
        uint256 amount = claimableEth[msg.sender];
        if (amount == 0) {
            revert PletherOracle__NothingToClaim();
        }
        claimableEth[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) {
            claimableEth[msg.sender] = amount;
            revert PletherOracle__EthTransferFailed();
        }
        emit EthRefundClaimed(msg.sender, amount);
    }

    /// @notice Returns the effective policy the router should use for an open/increase or close order.
    /// @dev Open/increase requests use `OrderExecution` policy. Close requests use `MarkRefresh` policy, so their
    ///      policy does not inherit the open path's `closeOnly` flag. The snapshot reflects current calendar, engine,
    ///      and HousePool state and does not read or update Pyth prices.
    /// @param isClose True to select close/mark-refresh policy; false to select open/order-execution policy
    /// @return policy Close-only/stored-mark flags, maximum age in seconds, and current FAD/frozen status
    function getOrderExecutionPolicy(
        bool isClose
    ) external view override returns (PolicySnapshot memory policy) {
        return _policyForOrder(isClose);
    }

    /// @notice Replaces the mutable oracle policy limits with router-finalized configuration.
    /// @dev Callable only by `engine.orderRouter()`. Both staleness limits, the settlement window, and component
    ///      divergence must be nonzero, and divergence cannot exceed the settlement window. Confidence-ratio and
    ///      adverse-confidence values may be zero. The staleness/window/divergence fields use seconds; ratio and
    ///      multiplier fields use basis points. No Pyth or engine price state is updated.
    /// @param config Complete replacement policy configuration
    function applyConfig(
        OracleConfig calldata config
    ) external override {
        if (msg.sender != engine.orderRouter()) {
            revert PletherOracle__Unauthorized();
        }
        if (
            config.orderExecutionStalenessLimit == 0 || config.liquidationStalenessLimit == 0
                || config.orderSettlementWindow == 0 || config.maxComponentPublishTimeDivergence == 0
                || config.maxComponentPublishTimeDivergence > config.orderSettlementWindow
        ) {
            revert PletherOracle__InvalidSettlementConfig();
        }
        orderExecutionStalenessLimit = config.orderExecutionStalenessLimit;
        liquidationStalenessLimit = config.liquidationStalenessLimit;
        pythMaxConfidenceRatioBps = config.pythMaxConfidenceRatioBps;
        orderSettlementWindow = config.orderSettlementWindow;
        maxComponentPublishTimeDivergence = config.maxComponentPublishTimeDivergence;
        adverseConfidenceMultiplierBps = config.adverseConfidenceMultiplierBps;
    }

    /// @notice Returns the ETH fee Pyth quotes for a nonempty update-data array.
    /// @dev Reverts instead of returning a quote for an empty array. The result is denominated in wei.
    /// @param pythUpdateData Nonempty Pyth update payloads to quote
    /// @return pythFee Fee required by the configured Pyth endpoint, in wei
    function getUpdateFee(
        bytes[] calldata pythUpdateData
    ) public view override returns (uint256 pythFee) {
        if (pythUpdateData.length == 0) {
            revert PletherOracle__MissingUpdateData();
        }
        return pyth.getUpdateFee(pythUpdateData);
    }

    /// @notice Returns whether the market calendar currently enables frozen-oracle policy.
    /// @dev Uses `block.timestamp` and the engine's override for the current UTC day. The normal frozen interval is
    ///      Friday at 22:00 UTC until Sunday at 21:00 UTC (exclusive); a current-day override freezes the full day.
    /// @return Whether frozen-oracle policy is active at the current timestamp
    function isOracleFrozen() public view override returns (bool) {
        return MarketCalendarLib.isOracleFrozen(block.timestamp, engine.fadDayOverrides(block.timestamp / 86_400));
    }

    function _updateAndGetSnapshot(
        address refundRecipient,
        bytes[] calldata pythUpdateData,
        PriceMode mode
    ) internal returns (PriceSnapshot memory snapshot) {
        uint256 pythFee = _updatePythPrice(pythUpdateData);
        snapshot = _getLatestPriceSnapshot(mode);
        snapshot.updateFee = pythFee;
        _refundExcess(refundRecipient, pythFee);
    }

    function _updateOrderExecutionPrice(
        address refundRecipient,
        bytes[] calldata pythUpdateData,
        OrderExecutionRequest calldata request
    ) internal returns (bool ok, PriceSnapshot memory snapshot) {
        PolicySnapshot memory policy = _policyForMode(PriceMode.OrderExecution);
        BasketPrice memory basket;
        (basket, ok) = _resolveOrderExecutionBasket(refundRecipient, pythUpdateData, request, policy);
        if (!ok) {
            snapshot.updateFee = basket.pythFee;
            return (false, snapshot);
        }
        snapshot = _snapshotFromBasket(PriceMode.OrderExecution, basket, policy, false);
        snapshot.price = _orderExecutionPrice(request, snapshot.price, basket.confidence, policy.oracleFrozen);
        ok = true;
    }

    function _getLatestPriceSnapshot(
        PriceMode mode
    ) internal view returns (PriceSnapshot memory snapshot) {
        PolicySnapshot memory policy = _policyForMode(mode);
        BasketPrice memory basket =
            _computeLiveBasketPrice(mode, policy.maxStaleness, _policyPublishTimeDivergence(mode, policy));
        snapshot = _snapshotFromBasket(mode, basket, policy, true);
    }

    function _updatePythPrice(
        bytes[] calldata pythUpdateData
    ) internal returns (uint256 pythFee) {
        pythFee = getUpdateFee(pythUpdateData);
        if (msg.value < pythFee) {
            revert PletherOracle__InsufficientFee(msg.value, pythFee);
        }
        pyth.updatePriceFeeds{value: pythFee}(pythUpdateData);
    }

    function _resolveOrderExecutionBasket(
        address refundRecipient,
        bytes[] calldata pythUpdateData,
        OrderExecutionRequest calldata request,
        PolicySnapshot memory policy
    ) internal returns (BasketPrice memory basket, bool ok) {
        if (!policy.oracleFrozen) {
            return _resolveHistoricalOrderBasket(refundRecipient, pythUpdateData, request);
        }

        uint256 pythFee = _updatePythPrice(pythUpdateData);
        basket = _computeLiveBasketPrice(
            PriceMode.OrderExecution, policy.maxStaleness, _maxPublishTimeDivergence(PriceMode.OrderExecution)
        );
        basket.pythFee = pythFee;
        ok = true;
    }

    function _resolveHistoricalOrderBasket(
        address refundRecipient,
        bytes[] calldata pythUpdateData,
        OrderExecutionRequest calldata request
    ) internal returns (BasketPrice memory basket, bool ok) {
        uint256 pythFee = getUpdateFee(pythUpdateData);
        if (msg.value < pythFee) {
            revert PletherOracle__InsufficientFee(msg.value, pythFee);
        }

        uint64 minPublishTime = request.commitTime + 1;
        uint256 settlementDeadline = uint256(request.commitTime) + orderSettlementWindow;
        uint64 maxPublishTime = uint64(settlementDeadline < block.timestamp ? settlementDeadline : block.timestamp);
        try pyth.parsePriceFeedUpdatesUnique{value: pythFee}(
            pythUpdateData, pythFeedIds, minPublishTime, maxPublishTime
        ) returns (
            PythStructs.PriceFeed[] memory parsedFeeds
        ) {
            basket = _computeBasketPriceFromFeeds(
                PriceMode.OrderExecution, parsedFeeds, maxComponentPublishTimeDivergence
            );
            basket.pythFee = pythFee;
            ok = true;
        } catch {
            if (request.revertOnHistoricalUnavailable) {
                revert PletherOracle__StalePrice(
                    PriceMode.OrderExecution, bytes32(0), maxPublishTime, orderExecutionStalenessLimit, block.timestamp
                );
            }
            basket.pythFee = pythFee;
            _refundValue(payable(refundRecipient), pythFee);
        }
    }

    function _policyPublishTimeDivergence(
        PriceMode mode,
        PolicySnapshot memory policy
    ) internal view returns (uint256) {
        if (mode != PriceMode.OrderExecution && policy.oracleFrozen) {
            return policy.maxStaleness;
        }
        return _maxPublishTimeDivergence(mode);
    }

    function _policyForOrder(
        bool isClose
    ) internal view returns (PolicySnapshot memory policy) {
        return _policyForMode(isClose ? PriceMode.MarkRefresh : PriceMode.OrderExecution);
    }

    function _policyForMode(
        PriceMode mode
    ) internal view returns (PolicySnapshot memory policy) {
        bool oracleFrozen = isOracleFrozen();
        bool isFad = engine.isFadWindow();
        OracleFreshnessPolicyLib.Mode freshnessMode;
        if (mode == PriceMode.OrderExecution) {
            freshnessMode = OracleFreshnessPolicyLib.Mode.OpenExecution;
        } else if (mode == PriceMode.MarkRefresh) {
            freshnessMode = OracleFreshnessPolicyLib.Mode.MarkRefresh;
        } else if (mode == PriceMode.Liquidation) {
            freshnessMode = OracleFreshnessPolicyLib.Mode.Liquidation;
        } else {
            freshnessMode = OracleFreshnessPolicyLib.Mode.PoolReconcile;
        }

        OracleFreshnessPolicyLib.Policy memory freshness = OracleFreshnessPolicyLib.getPolicy(
            freshnessMode,
            oracleFrozen,
            isFad,
            engine.engineMarkStalenessLimit(),
            housePool.markStalenessLimit(),
            orderExecutionStalenessLimit,
            liquidationStalenessLimit,
            engine.fadMaxStaleness()
        );

        policy.closeOnly = freshness.closeOnly;
        policy.requireStoredMark = freshness.requireStoredMark;
        policy.allowAnyStoredMark = freshness.allowAnyStoredMark;
        policy.maxStaleness = freshness.maxStaleness;
        policy.oracleFrozen = oracleFrozen;
        policy.isFadWindow = isFad;
    }

    function _computeLiveBasketPrice(
        PriceMode mode,
        uint256 maxStaleness,
        uint256 maxPublishTimeDivergence
    ) internal view returns (BasketPrice memory basket) {
        PythStructs.PriceFeed[] memory priceFeeds = new PythStructs.PriceFeed[](pythFeedIds.length);
        uint256 len = pythFeedIds.length;

        for (uint256 i = 0; i < len; i++) {
            bytes32 feedId = pythFeedIds[i];
            PythStructs.Price memory p = pyth.getPriceUnsafe(feedId);
            if (OracleFreshnessPolicyLib.isStale(p.publishTime, maxStaleness, block.timestamp)) {
                revert PletherOracle__StalePrice(mode, feedId, p.publishTime, maxStaleness, block.timestamp);
            }
            priceFeeds[i] = PythStructs.PriceFeed({id: feedId, price: p, emaPrice: p});
        }

        basket = _computeBasketPriceFromFeeds(mode, priceFeeds, maxPublishTimeDivergence);
    }

    function _computeBasketPriceFromFeeds(
        PriceMode mode,
        PythStructs.PriceFeed[] memory priceFeeds,
        uint256 maxPublishTimeDivergence
    ) internal view returns (BasketPrice memory basket) {
        if (priceFeeds.length != pythFeedIds.length) {
            revert PletherOracle__ArrayLengthMismatch(
                priceFeeds.length, quantities.length, basePrices.length, inversions.length
            );
        }
        uint256 minPublishTime = type(uint256).max;
        uint256 maxPublishTime;
        uint256 len = pythFeedIds.length;

        for (uint256 i = 0; i < len; i++) {
            bytes32 feedId = pythFeedIds[i];
            if (priceFeeds[i].id != feedId) {
                revert PletherOracle__ArrayLengthMismatch(
                    priceFeeds.length, quantities.length, basePrices.length, inversions.length
                );
            }
            PythStructs.Price memory p = priceFeeds[i].price;
            if (p.price <= 0) {
                revert PletherOracle__InvalidPrice(feedId, p.price);
            }
            if (uint256(uint64(p.conf)) * 10_000 > uint256(uint64(p.price)) * pythMaxConfidenceRatioBps) {
                revert PletherOracle__ConfidenceTooWide(feedId, p.conf, p.price, pythMaxConfidenceRatioBps);
            }

            uint256 norm = inversions[i] ? _invertPythPrice(p.price, p.expo) : _normalizePythPrice(p.price, p.expo);
            uint256 weightedPrice = (norm * quantities[i]) / (basePrices[i] * DecimalConstants.CHAINLINK_TO_TOKEN_SCALE);
            basket.price += weightedPrice;
            basket.confidence += (weightedPrice * uint256(uint64(p.conf))) / uint256(uint64(p.price));

            if (p.publishTime < minPublishTime) {
                minPublishTime = p.publishTime;
            }
            if (p.publishTime > maxPublishTime) {
                maxPublishTime = p.publishTime;
            }
        }

        if (maxPublishTime > minPublishTime + maxPublishTimeDivergence) {
            revert PletherOracle__PublishTimeDivergence(mode, minPublishTime, maxPublishTime, maxPublishTimeDivergence);
        }

        if (basket.price == 0) {
            revert PletherOracle__ZeroBasketPrice();
        }
        basket.publishTime = uint64(minPublishTime);
    }

    function _snapshotFromBasket(
        PriceMode mode,
        BasketPrice memory basket,
        PolicySnapshot memory policy,
        bool enforcePublishOrder
    ) internal view returns (PriceSnapshot memory snapshot) {
        snapshot.maxStaleness = policy.maxStaleness;
        snapshot.closeOnly = policy.closeOnly;
        snapshot.oracleFrozen = policy.oracleFrozen;
        snapshot.isFadWindow = policy.isFadWindow;
        snapshot.price = _clampToCap(basket.price);
        snapshot.markPrice = snapshot.price;
        snapshot.publishTime = basket.publishTime;
        snapshot.updateFee = basket.pythFee;

        if (enforcePublishOrder && snapshot.publishTime < engine.lastMarkTime()) {
            revert PletherOracle__PriceOutOfOrder(snapshot.publishTime, engine.lastMarkTime());
        }
        mode;
    }

    function _adverseOrderPrice(
        OrderExecutionRequest calldata request,
        uint256 price,
        uint256 confidence
    ) internal view returns (uint256) {
        uint256 shift = (confidence * adverseConfidenceMultiplierBps) / 10_000;
        if (shift == 0) {
            return price;
        }

        bool adverseUp = request.side == CfdTypes.Side.BEAR ? !request.isClose : request.isClose;
        return adverseUp ? price + shift : price > shift ? price - shift : 0;
    }

    function _orderExecutionPrice(
        OrderExecutionRequest calldata request,
        uint256 price,
        uint256 confidence,
        bool oracleFrozen
    ) internal view returns (uint256) {
        // The fixed frozen-close spread replaces the Pyth adverse-confidence shift for voluntary
        // close/reduce execution while the oracle is frozen. Confidence-width validation still
        // applies when the basket is built, and opens (if called directly) retain the adverse shift.
        if (oracleFrozen && request.isClose) {
            return price;
        }
        return _clampToCap(_adverseOrderPrice(request, price, confidence));
    }

    function _adverseLiquidationPrice(
        address account,
        uint256 price,
        uint256 confidence
    ) internal view returns (uint256) {
        uint256 shift = (confidence * adverseConfidenceMultiplierBps) / 10_000;
        if (shift == 0) {
            return price;
        }

        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(account);
        if (size == 0) {
            return price;
        }
        return side == CfdTypes.Side.BULL ? price + shift : price > shift ? price - shift : 0;
    }

    function _canReuseHistoricalBatchBasket(
        uint64 commitTime,
        BatchOrderPriceCache calldata cache
    ) internal view returns (bool) {
        if (!cache.hasHistoricalBasket) {
            return false;
        }
        if (commitTime < cache.minReusableCommitTime || commitTime >= cache.publishTime) {
            return false;
        }
        if (cache.publishTime > block.timestamp) {
            return false;
        }
        return uint256(cache.publishTime) <= uint256(commitTime) + orderSettlementWindow;
    }

    function _maxPublishTimeDivergence(
        PriceMode mode
    ) internal view returns (uint256) {
        return mode == PriceMode.Liquidation ? liquidationStalenessLimit : orderExecutionStalenessLimit;
    }

    function _clampToCap(
        uint256 price
    ) internal view returns (uint256) {
        uint256 capPrice = engine.CAP_PRICE();
        return price > capPrice ? capPrice : price;
    }

    function _invertPythPrice(
        int64 price,
        int32 expo
    ) internal pure returns (uint256) {
        if (price <= 0) {
            revert PletherOracle__InvalidPrice(bytes32(0), price);
        }
        uint256 positivePrice = uint256(uint64(price));
        uint256 scaledPrecision = 10 ** uint256(uint32(26 - expo));
        uint256 scaledInverse = (scaledPrecision + (positivePrice / 2)) / positivePrice;
        return scaledInverse / 1e18;
    }

    function _normalizePythPrice(
        int64 price,
        int32 expo
    ) internal pure returns (uint256) {
        if (price <= 0) {
            revert PletherOracle__InvalidPrice(bytes32(0), price);
        }
        uint256 rawPrice = uint256(uint64(price));

        if (expo == -8) {
            return rawPrice;
        }
        if (expo > -8) {
            return rawPrice * (10 ** uint256(uint32(expo + 8)));
        }
        return rawPrice / (10 ** uint256(uint32(-8 - expo)));
    }

    function _refundExcess(
        address refundRecipient,
        uint256 pythFee
    ) internal {
        uint256 refund = msg.value - pythFee;
        if (refund == 0) {
            return;
        }
        (bool ok,) = payable(refundRecipient).call{value: refund}("");
        if (ok) {
            return;
        }
        claimableEth[refundRecipient] += refund;
        emit EthRefundDeferred(refundRecipient, refund);
    }

    function _refundValue(
        address payable refundRecipient,
        uint256 amount
    ) internal {
        if (amount == 0) {
            return;
        }
        (bool ok,) = refundRecipient.call{value: amount}("");
        if (ok) {
            return;
        }
        claimableEth[refundRecipient] += amount;
        emit EthRefundDeferred(refundRecipient, amount);
    }

    }
