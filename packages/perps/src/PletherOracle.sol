// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {OracleConfidencePolicyLib} from "@plether/perps/libraries/OracleConfidencePolicyLib.sol";
import {OracleFreshnessPolicyLib} from "@plether/perps/libraries/OracleFreshnessPolicyLib.sol";
import {IPyth, PythStructs} from "@plether/shared/interfaces/IPyth.sol";
import {DecimalConstants} from "@plether/shared/libraries/DecimalConstants.sol";

/// @title PletherOracle
/// @notice Builds the Plether perps basket from Pyth feeds under action-specific freshness and execution policies.
/// @dev Basket prices and confidence amounts use 8 decimals. Live current updates parse signed complete baskets, validate
///      feed prices/freshness, aggregate confidence, and component timing; applies side-adverse confidence shifts,
///      and caps returned prices at the engine's `CAP_PRICE`. Feed ids, weights, bases, inversion flags, the engine,
///      the HousePool, and Pyth endpoint cannot be changed after deployment; policy limits can be changed only by the
///      engine-reported order router. State-changing execution should consume the snapshot returned by the applicable
///      update entrypoint instead of splitting update and view calls. Current updates are Router-only; historical
///      order resolution remains permissionless.
/// @custom:security-contact contact@plether.com
contract PletherOracle is IPletherOracle, ReentrancyGuardTransient {

    /// @dev Keeps an untrusted refund recipient from consuming the Oracle's post-call accounting gas.
    uint256 internal constant ETH_REFUND_GAS = 30_000;
    /// @dev Limits signed live-basket updates even when an action permits an older cached mark.
    uint256 public constant LIVE_TICK_LOOKBACK = 15;

    /// @notice Internal aggregate of a validated set of basket component prices.
    /// @param price Weighted basket price in 8-decimal units
    /// @param confidence Sum of weighted component confidence contributions in 8-decimal price units
    /// @param publishTime Newest component publish time as a Unix timestamp
    /// @param oldestPublishTime Oldest component publish time as a Unix timestamp
    /// @param pythFee Funding allocated to Pyth operations in wei, also recorded when unavailable history refunds or
    ///        defers it; zero for cache reuse
    struct BasketPrice {
        uint256 price;
        uint256 confidence;
        uint64 publishTime;
        uint64 oldestPublishTime;
        uint256 pythFee;
    }

    /// @notice Engine queried for cap price, mark state, account positions, calendar state, and router authorization.
    ICfdEngineCore public immutable engine;

    /// @notice HousePool queried for its mark-staleness limit when building pool-reconciliation policy.
    IHousePool public immutable housePool;

    /// @notice Pyth endpoint used for signed current-tick parsing and historical parsing/storage synchronization.
    IPyth public immutable override pyth;

    /// @notice Pyth feed id at each basket component index.
    bytes32[] public pythFeedIds;

    /// @notice 18-decimal basket weight at each component index; all stored weights sum to `1e18`.
    uint256[] public quantities;

    /// @notice 8-decimal base price used to normalize each basket component.
    uint256[] public basePrices;

    /// @notice Whether the component at each index is inverted before base-price normalization.
    bool[] public inversions;

    /// @dev The accepted live basket is independent of Pyth's mutable latest-price storage.
    PythStructs.Price[] private _acceptedPrices;
    BasketPrice private _acceptedBasket;
    bool public hasAcceptedBasket;

    /// @notice Maximum live order-execution and mark-refresh component age, in seconds.
    /// @dev Also bounds component publish-time divergence for current live order, mark, and PoolReconcile baskets.
    ///      PoolReconcile component age instead uses the effective Engine/HousePool mark-age limit. Frozen-oracle
    ///      policy uses the engine's `fadMaxStaleness` for age validation and does not compare component times.
    uint256 public override orderExecutionStalenessLimit = 60;

    /// @notice Maximum live liquidation component age, in seconds.
    /// @dev Also bounds component publish-time divergence for current live liquidation baskets. Frozen-oracle policy
    ///      instead uses the engine's `fadMaxStaleness` for age validation.
    uint256 public override liquidationStalenessLimit = 15;

    /// @notice Maximum accepted aggregate basket confidence-to-price ratio, in basis points.
    uint256 public override basketMaxConfidenceRatioBps = 10;

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
    /// @dev Requires deployed code at the nonzero Pyth address, at least one feed, equal array lengths, nonzero base
    ///      prices, and nonzero weights summing exactly to `1e18`. The engine and HousePool addresses are stored without
    ///      zero-address, code, or interface validation. Feed ids must be unique and nonzero.
    /// @param engine_ Engine used for cap, mark, position-side, calendar, and router-authorization state
    /// @param housePool_ HousePool used for pool-reconciliation freshness policy
    /// @param pyth_ Nonzero Pyth contract used for update and historical-parse calls
    /// @param feedIds_ Ordered Pyth feed ids included in the basket
    /// @param quantities_ Ordered nonzero 18-decimal basket weights; must sum exactly to `1e18`
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
        if (pyth_.code.length == 0) {
            revert PletherOracle__InvalidPyth();
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
            if (feedIds_[i] == bytes32(0)) {
                revert PletherOracle__InvalidFeedId(feedIds_[i]);
            }
            for (uint256 j; j < i; ++j) {
                if (feedIds_[j] == feedIds_[i]) {
                    revert PletherOracle__InvalidFeedId(feedIds_[i]);
                }
            }
            if (basePrices_[i] == 0) {
                revert PletherOracle__ZeroBasePrice(i);
            }
            if (quantities_[i] == 0) {
                revert PletherOracle__ZeroWeight(i);
            }
            totalWeight += quantities_[i];
            _acceptedPrices.push();
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
    /// @dev Router-only. A nonempty live payload supplies a signed price for every configured feed within the bounded
    ///      live window. Empty data replays the accepted basket. Frozen policy replays the Engine mark.
    ///      Validates the selected mode's age and publish-time-divergence policy, rejects a basket
    ///      older than the engine mark, and clamps price and mark price to `CAP_PRICE`. It does not update the engine
    ///      mark. ETH above the Pyth fee is sent to `refundRecipient` or recorded in `claimableEth` if that call fails.
    /// @param refundRecipient Recipient of `msg.value` remaining after the Pyth fee
    /// @param pythUpdateData Signed Pyth payloads, or empty for replay
    /// @param mode Policy selecting freshness and component-divergence limits
    /// @return snapshot Current 8-decimal price/mark, newest publish time, fee in wei, and policy metadata
    function updatePrice(
        address refundRecipient,
        bytes[] calldata pythUpdateData,
        PriceMode mode
    ) external payable override nonReentrant returns (PriceSnapshot memory snapshot) {
        return _updateAndGetSnapshot(refundRecipient, pythUpdateData, mode);
    }

    /// @notice Pays for Pyth update data and returns the validated current order-policy basket price.
    /// @dev Equivalent to the mode-aware overload with `PriceMode.OrderExecution`. This reads the accepted current basket;
    ///      it does not perform the unique post-commit historical parsing used by delayed orders and does not apply a
    ///      side-adverse confidence shift. The result is capped at `CAP_PRICE`. Excess ETH is refunded or deferred.
    /// @param refundRecipient Recipient of `msg.value` remaining after the Pyth fee
    /// @param pythUpdateData Signed Pyth payloads, or empty for replay
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
    ///      oracle-frozen window, replays the Engine mark at zero fee instead. History
    ///      additionally pays for a stored-feed update of the same payload, then verifies component coverage. The base
    ///      basket is capped and then shifted against the requested side using aggregate confidence, except that a
    ///      frozen-oracle voluntary close is left unshifted. This function reports `closeOnly` but does not enforce it,
    ///      and does not use `request.targetPrice`; the router enforces policy and slippage. Send exactly
    ///      `getOrderExecutionFee`: successful historical execution does not refund overpayment; frozen execution does.
    ///      If historical parsing fails and
    ///      `revertOnHistoricalUnavailable` is false, the full execution funding is refunded or deferred and `ok` is false.
    ///      Synchronization failures revert and are never treated as unavailable history.
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
    ///      basket first verifies all stored feeds cover its timestamp, pays no Pyth fee, and leaves the cache unchanged;
    ///      caller-supplied cache prices are not authenticated. Any ETH sent with a reused cache remains
    ///      in this contract and is not refunded or credited. Otherwise this follows
    ///      `updateOrderExecutionPrice`, including its confidence shift, exact-fee expectation, caller-enforced
    ///      close-only/slippage policy, and unavailable-history refund behavior. A new historical parse and
    ///      successful stored-feed synchronization extend the returned cache; frozen baskets are never cached.
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
            // Cache contents are caller-supplied; independently prove storage coverage, not price authenticity.
            for (uint256 i; i < pythFeedIds.length; ++i) {
                _requireStoredFeedCoverage(pythFeedIds[i], cache.publishTime);
            }
            basket = BasketPrice({
                price: cache.price,
                confidence: cache.confidence,
                publishTime: cache.publishTime,
                oldestPublishTime: cache.oldestPublishTime,
                pythFee: 0
            });
            reusedBasket = true;
        } else {
            (basket, ok) = _resolveOrderExecutionBasket(refundRecipient, pythUpdateData, request, policy);
            if (!ok) {
                snapshot.updateFee = basket.pythFee;
                return (false, snapshot, nextCache);
            }
        }

        snapshot = _snapshotFromBasket(basket, policy, false);
        snapshot.price = _orderExecutionPrice(request, snapshot.price, basket.confidence, policy.oracleFrozen);
        if (policy.oracleFrozen) {
            _refundExcess(refundRecipient, 0);
        }
        if (!policy.oracleFrozen && !reusedBasket) {
            nextCache = BatchOrderPriceCache({
                hasHistoricalBasket: true,
                minReusableCommitTime: request.commitTime,
                price: basket.price,
                confidence: basket.confidence,
                publishTime: basket.publishTime,
                oldestPublishTime: basket.oldestPublishTime
            });
        }
        ok = true;
    }

    /// @notice Resolves one signed current basket or frozen Engine mark for liquidation across many accounts.
    /// @dev Uses the same freshness, confidence, publish-time, mark-ordering, adverse-shift, and cap semantics as
    ///      `updateLiquidationPrice`, but computes both side-specific prices without reading any account position.
    ///      The function does not update the engine mark. Excess ETH is refunded to `refundRecipient` or deferred.
    /// @param refundRecipient Recipient of `msg.value` remaining after the Pyth fee
    /// @param pythUpdateData Signed Pyth payloads, or empty for replay
    /// @return snapshot LONG-adverse, SHORT-adverse, and neutral prices with the shared publish time and update fee
    function updateLiquidationBatchPrice(
        address refundRecipient,
        bytes[] calldata pythUpdateData
    ) external payable override nonReentrant returns (LiquidationBatchSnapshot memory snapshot) {
        (PriceSnapshot memory neutralSnapshot, uint256 rawPrice, uint256 confidence) =
            _updateLiquidationSnapshot(pythUpdateData);
        uint256 shift = _liquidationConfidenceShift(confidence);
        snapshot = LiquidationBatchSnapshot({
            longPrice: _clampToCap(_directionalLiquidationPriceFromShift(CfdTypes.Side.LONG, rawPrice, shift)),
            shortPrice: _clampToCap(_directionalLiquidationPriceFromShift(CfdTypes.Side.SHORT, rawPrice, shift)),
            markPrice: neutralSnapshot.markPrice,
            publishTime: neutralSnapshot.publishTime,
            updateFee: neutralSnapshot.updateFee
        });
        _refundExcess(refundRecipient, neutralSnapshot.updateFee);
    }

    /// @notice Resolves a current basket or frozen Engine mark adverse to the liquidated account's position.
    /// @dev Uses liquidation freshness policy and the newest component publish time, rejects an out-of-order basket,
    ///      shifts the price upward for a LONG position and downward for a SHORT position by the configured fraction of
    ///      aggregate confidence, then caps it at `CAP_PRICE`. An account with no position receives the neutral basket.
    ///      The function does not update the engine mark. Excess ETH is refunded to `refundRecipient` or deferred.
    /// @param refundRecipient Recipient of `msg.value` remaining after the Pyth fee
    /// @param pythUpdateData Signed Pyth payloads, or empty for replay
    /// @param account Account whose current engine position determines the adverse direction
    /// @return snapshot Adverse 8-decimal price, neutral mark, newest publish time, fee, and policy metadata
    function updateLiquidationPrice(
        address refundRecipient,
        bytes[] calldata pythUpdateData,
        address account
    ) external payable override nonReentrant returns (PriceSnapshot memory snapshot) {
        uint256 rawPrice;
        uint256 confidence;
        (snapshot, rawPrice, confidence) = _updateLiquidationSnapshot(pythUpdateData);
        snapshot.price = _clampToCap(_adverseLiquidationPrice(account, rawPrice, confidence));
        _refundExcess(refundRecipient, snapshot.updateFee);
    }

    /// @notice Returns the validated current basket snapshot for a policy mode without updating Pyth.
    /// @dev Reads the accepted live cache or frozen Engine mark, then enforces age, aggregate basket confidence width,
    ///      component publish-time divergence, and ordering against the engine's last mark time. Price and mark price are
    ///      neutral basket values capped at `CAP_PRICE`; `updateFee` is zero. This view may revert when accepted state
    ///      is invalid or stale.
    /// @param mode Policy selecting freshness and component-divergence limits
    /// @return snapshot Current 8-decimal price/mark, newest publish time, zero fee, and policy metadata
    function getLatestPrice(
        PriceMode mode
    ) external view override returns (PriceSnapshot memory snapshot) {
        return _getLatestPriceSnapshot(mode);
    }

    /// @notice Returns the validated current PoolReconcile basket and its aggregate confidence without updating Pyth.
    /// @dev Uses the same single basket computation and validation path as `getLatestPrice(PriceMode.PoolReconcile)`;
    ///      confidence is returned in 8-decimal basket-price units before any cap is applied to the neutral mark.
    /// @return snapshot Current neutral PoolReconcile snapshot with zero update fee
    /// @return confidence Aggregate basket confidence in 8-decimal price units
    function getLatestPoolReconcilePrice()
        external
        view
        override
        returns (PriceSnapshot memory snapshot, uint256 confidence)
    {
        return _getLatestPriceSnapshotWithConfidence(PriceMode.PoolReconcile);
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
        uint256 amount = _claimEthRefund(payable(msg.sender));
        emit EthRefundClaimed(msg.sender, amount);
    }

    /// @inheritdoc IPletherOracle
    function claimEthRefundTo(
        address payable recipient
    ) external override nonReentrant {
        uint256 amount = _claimEthRefund(recipient);
        emit EthRefundClaimedTo(msg.sender, recipient, amount);
    }

    function _claimEthRefund(
        address payable recipient
    ) private returns (uint256 amount) {
        if (recipient == address(0)) {
            revert PletherOracle__InvalidRefundRecipient();
        }
        amount = claimableEth[msg.sender];
        if (amount == 0) {
            revert PletherOracle__NothingToClaim();
        }
        claimableEth[msg.sender] = 0;
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) {
            revert PletherOracle__EthTransferFailed();
        }
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
    ///      adverse-confidence values may be zero; their product must be below 100,000,000, with individual bounds
    ///      of 10,000 and 30,000 respectively. The staleness/window/divergence fields use seconds; ratio and
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
        if (!OracleConfidencePolicyLib.isValidConfig(
                config.basketMaxConfidenceRatioBps, config.adverseConfidenceMultiplierBps
            )) {
            revert PletherOracle__InvalidConfidenceConfig();
        }
        orderExecutionStalenessLimit = config.orderExecutionStalenessLimit;
        liquidationStalenessLimit = config.liquidationStalenessLimit;
        basketMaxConfidenceRatioBps = config.basketMaxConfidenceRatioBps;
        orderSettlementWindow = config.orderSettlementWindow;
        maxComponentPublishTimeDivergence = config.maxComponentPublishTimeDivergence;
        adverseConfidenceMultiplierBps = config.adverseConfidenceMultiplierBps;
    }

    /// @notice Returns the ETH fee for a current signed update, or zero for empty/frozen replay.
    /// @param pythUpdateData Signed Pyth payloads to quote
    /// @return pythFee Fee required by the configured Pyth endpoint, in wei
    function getUpdateFee(
        bytes[] calldata pythUpdateData
    ) public view override returns (uint256 pythFee) {
        if (pythUpdateData.length == 0 || isOracleFrozen()) {
            return 0;
        }
        return pyth.getUpdateFee(pythUpdateData);
    }

    function getAcceptedBasketMark()
        external
        view
        override
        returns (bool accepted, uint256 markPrice, uint64 publishTime)
    {
        accepted = hasAcceptedBasket;
        if (accepted) {
            markPrice = _clampToCap(_acceptedBasket.price);
            publishTime = _acceptedBasket.publishTime;
        }
    }

    function getAcceptedFeedPublishTimes() external view override returns (uint256[] memory publishTimes) {
        uint256 len = _acceptedPrices.length;
        publishTimes = new uint256[](len);
        if (!hasAcceptedBasket) {
            return publishTimes;
        }
        for (uint256 i; i < len; ++i) {
            publishTimes[i] = _acceptedPrices[i].publishTime;
        }
    }

    /// @inheritdoc IPletherOracle
    function getOrderExecutionFee(
        bytes[] calldata pythUpdateData
    ) public view override returns (uint256) {
        if (isOracleFrozen()) {
            return 0;
        }
        if (pythUpdateData.length == 0) {
            revert PletherOracle__MissingUpdateData();
        }
        return 2 * pyth.getUpdateFee(pythUpdateData);
    }

    /// @notice Returns whether the market calendar currently enables frozen-oracle policy.
    /// @dev Delegates to the engine's canonical calendar status. The normal frozen interval follows Pyth FX hours from
    ///      Friday 17:00 New York time until Sunday 17:00 New York time (exclusive), including US daylight-saving
    ///      transitions; a current-day override freezes the full UTC day.
    /// @return Whether frozen-oracle policy is active at the current timestamp
    function isOracleFrozen() public view override returns (bool) {
        return engine.isOracleFrozen();
    }

    function _updateAndGetSnapshot(
        address refundRecipient,
        bytes[] calldata pythUpdateData,
        PriceMode mode
    ) internal returns (PriceSnapshot memory snapshot) {
        if (msg.sender != engine.orderRouter()) {
            revert PletherOracle__Unauthorized();
        }
        PolicySnapshot memory policy = _policyForMode(mode);
        BasketPrice memory basket = _resolveCurrentBasket(pythUpdateData, mode, policy);
        snapshot = _snapshotFromBasket(basket, policy, true);
        _refundExcess(refundRecipient, basket.pythFee);
    }

    /// @dev Retains the pre-cap price for adverse liquidation shifts while keeping the neutral snapshot capped.
    function _updateLiquidationSnapshot(
        bytes[] calldata pythUpdateData
    ) internal returns (PriceSnapshot memory snapshot, uint256 rawPrice, uint256 confidence) {
        if (msg.sender != engine.orderRouter()) {
            revert PletherOracle__Unauthorized();
        }
        PolicySnapshot memory policy = _policyForMode(PriceMode.Liquidation);
        BasketPrice memory basket = _resolveCurrentBasket(pythUpdateData, PriceMode.Liquidation, policy);
        snapshot = _snapshotFromBasket(basket, policy, true);
        rawPrice = basket.price;
        confidence = basket.confidence;
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
        snapshot = _snapshotFromBasket(basket, policy, false);
        snapshot.price = _orderExecutionPrice(request, snapshot.price, basket.confidence, policy.oracleFrozen);
        if (policy.oracleFrozen) {
            _refundExcess(refundRecipient, 0);
        }
        ok = true;
    }

    function _getLatestPriceSnapshot(
        PriceMode mode
    ) internal view returns (PriceSnapshot memory snapshot) {
        (snapshot,) = _getLatestPriceSnapshotWithConfidence(mode);
    }

    function _getLatestPriceSnapshotWithConfidence(
        PriceMode mode
    ) internal view returns (PriceSnapshot memory snapshot, uint256 confidence) {
        PolicySnapshot memory policy = _policyForMode(mode);
        BasketPrice memory basket = policy.oracleFrozen
            ? _frozenBasket(mode, policy.maxStaleness)
            : _acceptedLiveBasket(mode, policy.maxStaleness, _policyPublishTimeDivergence(mode, policy));
        snapshot = _snapshotFromBasket(basket, policy, true);
        confidence = basket.confidence;
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

        basket = _frozenBasket(PriceMode.OrderExecution, policy.maxStaleness);
        ok = true;
    }

    function _resolveHistoricalOrderBasket(
        address refundRecipient,
        bytes[] calldata pythUpdateData,
        OrderExecutionRequest calldata request
    ) internal returns (BasketPrice memory basket, bool ok) {
        if (pythUpdateData.length == 0) {
            revert PletherOracle__MissingUpdateData();
        }
        uint256 pythFee = pyth.getUpdateFee(pythUpdateData);
        uint256 executionFunding = 2 * pythFee;
        if (msg.value < executionFunding) {
            revert PletherOracle__InsufficientFee(msg.value, executionFunding);
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
            // Reverts in the success body are NOT caught by the historical-parse catch below.
            // Keep the parsed basket as the pricing source even if storage already contains newer prices.
            pyth.updatePriceFeeds{value: pythFee}(pythUpdateData);
            for (uint256 i; i < parsedFeeds.length; ++i) {
                _requireStoredFeedCoverage(parsedFeeds[i].id, parsedFeeds[i].price.publishTime);
            }
            basket.pythFee = executionFunding;
            ok = true;
        } catch (bytes memory reason) {
            if (reason.length != 4 || bytes4(reason) != IPyth.PriceFeedNotFoundWithinRange.selector) {
                revert PletherOracle__HistoricalParserFailure(bytes4(reason), reason.length);
            }
            if (request.revertOnHistoricalUnavailable) {
                revert PletherOracle__StalePrice(
                    PriceMode.OrderExecution, bytes32(0), maxPublishTime, orderExecutionStalenessLimit, block.timestamp
                );
            }
            // The reverted parser consumed no ETH; the storage update was never attempted.
            // Report forwarded funding so the Router does not refund this allocation a second time.
            basket.pythFee = executionFunding;
            _refundValue(payable(refundRecipient), executionFunding);
        }
    }

    function _requireStoredFeedCoverage(
        bytes32 feedId,
        uint256 requiredPublishTime
    ) internal view {
        uint256 storedPublishTime = pyth.getPriceUnsafe(feedId).publishTime;
        if (storedPublishTime < requiredPublishTime) {
            revert PletherOracle__StoredFeedBehind(feedId, storedPublishTime, requiredPublishTime);
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

    function _acceptedLiveBasket(
        PriceMode mode,
        uint256 maxStaleness,
        uint256 maxPublishTimeDivergence
    ) internal view returns (BasketPrice memory basket) {
        if (!hasAcceptedBasket) {
            revert PletherOracle__NoAcceptedBasket();
        }
        PythStructs.PriceFeed[] memory priceFeeds = new PythStructs.PriceFeed[](pythFeedIds.length);
        uint256 len = pythFeedIds.length;

        for (uint256 i = 0; i < len; i++) {
            bytes32 feedId = pythFeedIds[i];
            PythStructs.Price memory p = _acceptedPrices[i];
            if (OracleFreshnessPolicyLib.isStale(p.publishTime, maxStaleness, block.timestamp)) {
                revert PletherOracle__StalePrice(mode, feedId, p.publishTime, maxStaleness, block.timestamp);
            }
            priceFeeds[i] = PythStructs.PriceFeed({id: feedId, price: p, emaPrice: p});
        }

        basket = _computeBasketPriceFromFeeds(mode, priceFeeds, maxPublishTimeDivergence);
    }

    function _frozenBasket(
        PriceMode mode,
        uint256 maxStaleness
    ) internal view returns (BasketPrice memory basket) {
        basket.price = engine.lastMarkPrice();
        basket.publishTime = engine.lastMarkTime();
        if (basket.price == 0 || basket.publishTime == 0) {
            revert PletherOracle__NoAcceptedBasket();
        }
        if (OracleFreshnessPolicyLib.isStale(basket.publishTime, maxStaleness, block.timestamp)) {
            revert PletherOracle__StalePrice(mode, bytes32(0), basket.publishTime, maxStaleness, block.timestamp);
        }
        // Liquidations receive a deterministic, conservative confidence shift while Pyth is closed.
        basket.confidence = basket.price * basketMaxConfidenceRatioBps / 10_000;
    }

    /// @dev Every state-changing caller is nonReentrant. During the Pyth call, views can only see the previous
    ///      complete accepted basket; after the call, all accepted-basket writes occur without another external call.
    // slither-disable-start reentrancy-eth
    // slither-disable-start cyclomatic-complexity
    function _resolveCurrentBasket(
        bytes[] calldata pythUpdateData,
        PriceMode mode,
        PolicySnapshot memory policy
    ) internal returns (BasketPrice memory basket) {
        if (policy.oracleFrozen) {
            return _frozenBasket(mode, policy.maxStaleness);
        }
        uint256 divergence = _policyPublishTimeDivergence(mode, policy);
        if (pythUpdateData.length == 0) {
            return _acceptedLiveBasket(mode, policy.maxStaleness, divergence);
        }

        uint256 liveWindow = policy.maxStaleness < LIVE_TICK_LOOKBACK ? policy.maxStaleness : LIVE_TICK_LOOKBACK;
        uint256 cutoff = block.timestamp > liveWindow ? block.timestamp - liveWindow : 1;
        uint256 len = pythFeedIds.length;
        uint256 pythFee = pyth.getUpdateFee(pythUpdateData);
        if (msg.value < pythFee) {
            revert PletherOracle__InsufficientFee(msg.value, pythFee);
        }
        PythStructs.PriceFeed[] memory feeds = pyth.parsePriceFeedUpdates{value: pythFee}(
            pythUpdateData, pythFeedIds, uint64(cutoff), uint64(block.timestamp)
        );
        if (feeds.length != len) {
            revert PletherOracle__ArrayLengthMismatch(feeds.length, len, len, len);
        }

        for (uint256 i; i < len; ++i) {
            uint256 feedTime = feeds[i].price.publishTime;
            if (hasAcceptedBasket && feedTime < _acceptedPrices[i].publishTime) {
                revert PletherOracle__FeedTimeOutOfOrder(pythFeedIds[i], feedTime, _acceptedPrices[i].publishTime);
            }
            if (OracleFreshnessPolicyLib.isStale(feedTime, policy.maxStaleness, block.timestamp)) {
                revert PletherOracle__StalePrice(mode, pythFeedIds[i], feedTime, policy.maxStaleness, block.timestamp);
            }
        }
        basket = _computeBasketPriceFromFeeds(mode, feeds, divergence);
        if (hasAcceptedBasket && basket.publishTime < _acceptedBasket.publishTime) {
            revert PletherOracle__PriceOutOfOrder(basket.publishTime, _acceptedBasket.publishTime);
        }
        if (
            hasAcceptedBasket && basket.publishTime == _acceptedBasket.publishTime
                && basket.price != _acceptedBasket.price
        ) {
            revert PletherOracle__EqualTimeMarkMismatch(basket.publishTime, basket.price, _acceptedBasket.price);
        }
        for (uint256 i; i < len; ++i) {
            _acceptedPrices[i] = feeds[i].price;
        }
        _acceptedBasket = basket;
        hasAcceptedBasket = true;
        basket.pythFee = pythFee;
    }
    // slither-disable-end cyclomatic-complexity
    // slither-disable-end reentrancy-eth

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
            bool inverted = inversions[i];
            uint256 norm = inverted ? _invertPythPrice(p.price, p.expo) : _normalizePythPrice(p.price, p.expo);
            uint256 denominator = basePrices[i] * DecimalConstants.CHAINLINK_TO_TOKEN_SCALE;
            uint256 weightedPrice = (norm * quantities[i]) / denominator;
            basket.price += weightedPrice;
            if (inverted) {
                uint256 rawPrice = uint256(uint64(p.price));
                if (uint256(p.conf) >= rawPrice) {
                    revert PletherOracle__InvalidInverseConfidence(feedId, p.price, p.conf);
                }
                // Inversion is nonlinear: the upper basket endpoint comes from the lower raw Pyth endpoint.
                uint256 upperNorm = _invertPythPrice(int64(uint64(rawPrice - uint256(p.conf))), p.expo);
                uint256 upperWeightedPrice = (upperNorm * quantities[i]) / denominator;
                basket.confidence += upperWeightedPrice - weightedPrice;
            } else {
                basket.confidence += (weightedPrice * uint256(p.conf)) / uint256(uint64(p.price));
            }

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
        if (mode == PriceMode.PoolReconcile) {
            uint256 epochStart = block.timestamp - (block.timestamp % 1 hours);
            if (minPublishTime < epochStart) {
                revert PletherOracle__PoolEpochComponentTooOld(minPublishTime, epochStart);
            }
        }

        if (basket.price == 0) {
            revert PletherOracle__ZeroBasketPrice();
        }
        if (basket.confidence * 10_000 > basket.price * basketMaxConfidenceRatioBps) {
            revert PletherOracle__BasketConfidenceTooWide(
                mode, basket.confidence, basket.price, basketMaxConfidenceRatioBps
            );
        }
        basket.publishTime = uint64(maxPublishTime);
        basket.oldestPublishTime = uint64(minPublishTime);
    }

    function _snapshotFromBasket(
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

        if (enforcePublishOrder) {
            uint64 markTime = engine.lastMarkTime();
            if (snapshot.publishTime < markTime) {
                revert PletherOracle__PriceOutOfOrder(snapshot.publishTime, markTime);
            }
            if (snapshot.publishTime == markTime && engine.lastMarkPrice() != snapshot.markPrice) {
                revert PletherOracle__EqualTimeMarkMismatch(
                    snapshot.publishTime, snapshot.markPrice, engine.lastMarkPrice()
                );
            }
        }
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

        bool adverseUp = request.side == CfdTypes.Side.SHORT ? !request.isClose : request.isClose;
        if (adverseUp) {
            return price + shift;
        }
        if (shift >= price) {
            revert PletherOracle__ZeroExecutionPrice();
        }
        return price - shift;
    }

    function _orderExecutionPrice(
        OrderExecutionRequest calldata request,
        uint256 price,
        uint256 confidence,
        bool oracleFrozen
    ) internal view returns (uint256) {
        if (price == 0) {
            revert PletherOracle__ZeroExecutionPrice();
        }
        // The fixed frozen-close spread replaces the Pyth adverse-confidence shift for voluntary
        // close/reduce execution while the oracle is frozen. Basket confidence-width validation still
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
        uint256 shift = _liquidationConfidenceShift(confidence);
        if (shift == 0) {
            return price;
        }

        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(account);
        if (size == 0) {
            return price;
        }
        return _directionalLiquidationPriceFromShift(side, price, shift);
    }

    function _liquidationConfidenceShift(
        uint256 confidence
    ) internal view returns (uint256) {
        return (confidence * adverseConfidenceMultiplierBps) / 10_000;
    }

    function _directionalLiquidationPriceFromShift(
        CfdTypes.Side side,
        uint256 price,
        uint256 shift
    ) internal pure returns (uint256) {
        return side == CfdTypes.Side.LONG ? price + shift : price > shift ? price - shift : 0;
    }

    function _canReuseHistoricalBatchBasket(
        uint64 commitTime,
        BatchOrderPriceCache calldata cache
    ) internal view returns (bool) {
        if (!cache.hasHistoricalBasket) {
            return false;
        }
        if (
            commitTime < cache.minReusableCommitTime || commitTime >= cache.oldestPublishTime
                || commitTime >= cache.publishTime
        ) {
            return false;
        }
        if (cache.publishTime > block.timestamp) {
            return false;
        }
        return uint256(cache.publishTime) <= uint256(commitTime) + orderSettlementWindow;
    }

    /// @dev Live PoolReconcile uses the order divergence limit independently of its Engine/HousePool age limit.
    ///      Historical order parsing uses `maxComponentPublishTimeDivergence` instead.
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
        (bool ok,) = payable(refundRecipient).call{value: refund, gas: ETH_REFUND_GAS}("");
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
        (bool ok,) = refundRecipient.call{value: amount, gas: ETH_REFUND_GAS}("");
        if (ok) {
            return;
        }
        claimableEth[refundRecipient] += amount;
        emit EthRefundDeferred(refundRecipient, amount);
    }

    }
