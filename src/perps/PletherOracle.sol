// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IPyth, PythStructs} from "../interfaces/IPyth.sol";
import {DecimalConstants} from "../libraries/DecimalConstants.sol";
import {ICfdEngineCore} from "./interfaces/ICfdEngineCore.sol";
import {ICfdVault} from "./interfaces/ICfdVault.sol";
import {IPletherOracle} from "./interfaces/IPletherOracle.sol";
import {MarketCalendarLib} from "./libraries/MarketCalendarLib.sol";
import {OracleFreshnessPolicyLib} from "./libraries/OracleFreshnessPolicyLib.sol";

/// @title PletherOracle
/// @notice Mode-aware Pyth basket oracle for the perps router.
/// @dev Owns Pyth updates, basket math, confidence checks, freshness policy, and cap clamping.
///      State-changing callers should use `updateAndGetPrice` and pass its snapshot through execution.
///      `getPrice` is view-only and should not be paired with a separate update inside execution flows.
///      When `pyth == address(0)`, Anvil-only mock mode decodes an optional uint256 price override from
///      `pythUpdateData[0]`; if absent, it falls back to the stored mark or 1e8 for local testing.
contract PletherOracle is IPletherOracle {

    ICfdEngineCore public immutable engine;
    ICfdVault public immutable housePool;
    IPyth public immutable override pyth;
    address public immutable owner;

    bytes32[] public pythFeedIds;
    uint256[] public quantities;
    uint256[] public basePrices;
    bool[] public inversions;

    uint256 public override orderExecutionStalenessLimit = 60;
    uint256 public override liquidationStalenessLimit = 15;
    uint256 public override pythMaxConfidenceRatioBps = 10_000;

    constructor(
        address engine_,
        address housePool_,
        address pyth_,
        bytes32[] memory feedIds_,
        uint256[] memory quantities_,
        uint256[] memory basePrices_,
        bool[] memory inversions_
    ) {
        engine = ICfdEngineCore(engine_);
        housePool = ICfdVault(housePool_);
        pyth = IPyth(pyth_);
        owner = msg.sender;

        if (pyth_ != address(0)) {
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
        }

        pythFeedIds = feedIds_;
        quantities = quantities_;
        basePrices = basePrices_;
        inversions = inversions_;
    }

    function updateAndGetPrice(
        bytes[] calldata pythUpdateData,
        PriceMode mode
    ) external payable override returns (PriceSnapshot memory snapshot) {
        uint256 pythFee = _updatePrice(pythUpdateData);
        snapshot = _getPrice(mode, _mockModePrice(pythUpdateData));
        snapshot.updateFee = pythFee;
    }

    function getPrice(
        PriceMode mode
    ) external view override returns (PriceSnapshot memory snapshot) {
        uint256 fallbackPrice = engine.lastMarkPrice();
        if (fallbackPrice == 0) {
            fallbackPrice = 1e8;
        }
        return _getPrice(mode, fallbackPrice);
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
        orderExecutionStalenessLimit = config.orderExecutionStalenessLimit;
        liquidationStalenessLimit = config.liquidationStalenessLimit;
        pythMaxConfidenceRatioBps = config.pythMaxConfidenceRatioBps;
    }

    function getUpdateFee(
        bytes[] calldata pythUpdateData
    ) public view override returns (uint256 pythFee) {
        if (address(pyth) == address(0)) {
            return 0;
        }
        if (pythUpdateData.length == 0) {
            revert PletherOracle__MissingUpdateData();
        }
        return pyth.getUpdateFee(pythUpdateData);
    }

    function isOracleFrozen() public view override returns (bool) {
        return MarketCalendarLib.isOracleFrozen(block.timestamp, engine.fadDayOverrides(block.timestamp / 86_400));
    }

    function _getPrice(
        PriceMode mode,
        uint256 mockModePrice
    ) internal view returns (PriceSnapshot memory snapshot) {
        PolicySnapshot memory policy = _policyForMode(mode);
        snapshot.maxStaleness = policy.maxStaleness;
        snapshot.closeOnly = policy.closeOnly;
        snapshot.oracleFrozen = policy.oracleFrozen;
        snapshot.isFadWindow = policy.isFadWindow;

        if (address(pyth) == address(0)) {
            if (block.chainid != 31_337) {
                revert PletherOracle__MockModeForbidden(block.chainid);
            }
            snapshot.price = _clampToCap(mockModePrice);
            snapshot.publishTime = uint64(block.timestamp);
            return snapshot;
        }

        uint256 minPublishTime;
        (snapshot.price, minPublishTime) =
            _computeBasketPrice(mode, policy.maxStaleness, _maxPublishTimeDivergence(mode));
        snapshot.price = _clampToCap(snapshot.price);
        snapshot.publishTime = uint64(minPublishTime);

        if (snapshot.publishTime < engine.lastMarkTime()) {
            revert PletherOracle__PriceOutOfOrder(snapshot.publishTime, engine.lastMarkTime());
        }
    }

    function _updatePrice(
        bytes[] calldata pythUpdateData
    ) internal returns (uint256 pythFee) {
        if (address(pyth) == address(0)) {
            if (block.chainid != 31_337) {
                revert PletherOracle__MockModeForbidden(block.chainid);
            }
            _refundExcess(0);
            return 0;
        }

        pythFee = getUpdateFee(pythUpdateData);
        if (msg.value < pythFee) {
            revert PletherOracle__InsufficientFee(msg.value, pythFee);
        }
        pyth.updatePriceFeeds{value: pythFee}(pythUpdateData);
        _refundExcess(pythFee);
    }

    function _mockModePrice(
        bytes[] calldata pythUpdateData
    ) internal view returns (uint256 price) {
        if (address(pyth) != address(0)) {
            return 0;
        }
        if (pythUpdateData.length > 0) {
            price = abi.decode(pythUpdateData[0], (uint256));
        } else {
            price = _storedMarkFallbackPrice();
        }
        if (price == 0) {
            revert PletherOracle__InvalidMockPrice(price);
        }
    }

    function _storedMarkFallbackPrice() internal view returns (uint256 price) {
        price = engine.lastMarkPrice();
        if (price == 0) {
            price = 1e8;
        }
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

    function _computeBasketPrice(
        PriceMode mode,
        uint256 maxStaleness,
        uint256 maxPublishTimeDivergence
    ) internal view returns (uint256 basketPrice, uint256 minPublishTime) {
        minPublishTime = type(uint256).max;
        uint256 maxPublishTime;
        uint256 len = pythFeedIds.length;

        for (uint256 i = 0; i < len; i++) {
            bytes32 feedId = pythFeedIds[i];
            PythStructs.Price memory p = pyth.getPriceUnsafe(feedId);
            if (OracleFreshnessPolicyLib.isStale(p.publishTime, maxStaleness, block.timestamp)) {
                revert PletherOracle__StalePrice(mode, feedId, p.publishTime, maxStaleness, block.timestamp);
            }
            if (p.price <= 0) {
                revert PletherOracle__InvalidPrice(feedId, p.price);
            }
            if (uint256(uint64(p.conf)) * 10_000 > uint256(uint64(p.price)) * pythMaxConfidenceRatioBps) {
                revert PletherOracle__ConfidenceTooWide(feedId, p.conf, p.price, pythMaxConfidenceRatioBps);
            }

            uint256 norm = inversions[i] ? _invertPythPrice(p.price, p.expo) : _normalizePythPrice(p.price, p.expo);
            basketPrice += (norm * quantities[i]) / (basePrices[i] * DecimalConstants.CHAINLINK_TO_TOKEN_SCALE);

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

        if (basketPrice == 0) {
            revert PletherOracle__ZeroBasketPrice();
        }
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
        uint256 pythFee
    ) internal {
        uint256 refund = msg.value - pythFee;
        if (refund == 0) {
            return;
        }
        (bool ok,) = payable(msg.sender).call{value: refund}("");
        if (!ok) {
            revert PletherOracle__RefundFailed(msg.sender, refund);
        }
    }

}
