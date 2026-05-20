// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IPyth, PythStructs} from "../interfaces/IPyth.sol";
import {DecimalConstants} from "../libraries/DecimalConstants.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {ICfdEngineCore} from "./interfaces/ICfdEngineCore.sol";
import {IHousePool} from "./interfaces/IHousePool.sol";
import {IPletherOracle} from "./interfaces/IPletherOracle.sol";
import {MarketCalendarLib} from "./libraries/MarketCalendarLib.sol";
import {OracleFreshnessPolicyLib} from "./libraries/OracleFreshnessPolicyLib.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title PletherOracle
/// @notice Mode-aware Pyth basket oracle for the perps router.
/// @dev Owns Pyth updates, basket math, confidence checks, freshness policy, and cap clamping.
///      State-changing callers should use `updatePrice` and pass its snapshot through execution.
///      `getLatestPrice` is view-only and should not be paired with a separate update inside execution flows.
///      Tests and local deployments should use an IPyth-compatible mock contract instead of branching
///      production oracle behavior.
contract PletherOracle is IPletherOracle, ReentrancyGuardTransient {

    struct BasketPrice {
        uint256 price;
        uint256 confidence;
        uint64 publishTime;
        uint256 pythFee;
    }

    ICfdEngineCore public immutable engine;
    IHousePool public immutable housePool;
    IPyth public immutable override pyth;
    address public immutable owner;

    bytes32[] public pythFeedIds;
    uint256[] public quantities;
    uint256[] public basePrices;
    bool[] public inversions;

    uint256 public override orderExecutionStalenessLimit = 60;
    uint256 public override liquidationStalenessLimit = 15;
    uint256 public override pythMaxConfidenceRatioBps = 10_000;
    uint256 public override orderSettlementWindow = 15;
    uint256 public override maxComponentPublishTimeDivergence = 5;
    uint256 public override adverseConfidenceMultiplierBps = 10_000;
    mapping(address => uint256) public override claimableEth;

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
        owner = msg.sender;

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

    function updatePrice(
        address refundRecipient,
        bytes[] calldata pythUpdateData,
        PriceMode mode
    ) external payable override nonReentrant returns (PriceSnapshot memory snapshot) {
        return _updateAndGetSnapshot(refundRecipient, pythUpdateData, mode);
    }

    function updatePrice(
        address refundRecipient,
        bytes[] calldata pythUpdateData
    ) external payable override nonReentrant returns (uint256 latestPrice) {
        return _updateAndGetSnapshot(refundRecipient, pythUpdateData, PriceMode.OrderExecution).price;
    }

    function updateOrderExecutionPrice(
        address refundRecipient,
        bytes[] calldata pythUpdateData,
        OrderExecutionRequest calldata request
    ) external payable override nonReentrant returns (bool ok, PriceSnapshot memory snapshot) {
        return _updateOrderExecutionPrice(refundRecipient, pythUpdateData, request);
    }

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
        snapshot.price = _clampToCap(_adverseOrderPrice(request, snapshot.price, basket.confidence));
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

    function getLatestPrice(
        PriceMode mode
    ) external view override returns (PriceSnapshot memory snapshot) {
        return _getLatestPriceSnapshot(mode);
    }

    function getLatestPrice() external view override returns (uint256 latestPrice) {
        return _getLatestPriceSnapshot(PriceMode.OrderExecution).price;
    }

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

    function getOrderExecutionPolicy(
        bool isClose
    ) external view override returns (PolicySnapshot memory policy) {
        return _policyForOrder(isClose);
    }

    function applyConfig(
        OracleConfig calldata config
    ) external override {
        if (msg.sender != owner && msg.sender != engine.orderRouter()) {
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

    function getUpdateFee(
        bytes[] calldata pythUpdateData
    ) public view override returns (uint256 pythFee) {
        if (pythUpdateData.length == 0) {
            revert PletherOracle__MissingUpdateData();
        }
        return pyth.getUpdateFee(pythUpdateData);
    }

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
        snapshot.price = _clampToCap(_adverseOrderPrice(request, snapshot.price, basket.confidence));
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
