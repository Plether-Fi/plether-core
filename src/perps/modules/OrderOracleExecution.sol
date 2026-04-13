// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IPyth, PythStructs} from "../../interfaces/IPyth.sol";
import {DecimalConstants} from "../../libraries/DecimalConstants.sol";
import {CfdTypes} from "../CfdTypes.sol";
import {ICfdEngineLens} from "../interfaces/ICfdEngineLens.sol";
import {ICfdVault} from "../interfaces/ICfdVault.sol";
import {MarketCalendarLib} from "../libraries/MarketCalendarLib.sol";
import {OrderOraclePolicyLib} from "../libraries/OrderOraclePolicyLib.sol";
import {OrderEscrowAccounting} from "./OrderEscrowAccounting.sol";

abstract contract OrderOracleExecution is OrderEscrowAccounting {

    struct RouterExecutionContext {
        bool oracleFrozen;
        bool isFadWindow;
        OrderOraclePolicyLib.OracleExecutionPolicy policy;
    }

    ICfdVault internal immutable vault;
    ICfdEngineLens internal immutable engineLens;
    IPyth public pyth;
    bytes32[] public pythFeedIds;
    uint256[] public quantities;
    uint256[] public basePrices;
    bool[] public inversions;

    uint256 public orderExecutionStalenessLimit = 60;
    uint256 public pendingOrderExecutionStalenessLimit;
    uint256 public orderExecutionStalenessActivationTime;
    uint256 public liquidationStalenessLimit = 15;
    uint256 public pendingLiquidationStalenessLimit;
    uint256 public liquidationStalenessActivationTime;

    function _revertZeroAddress() internal pure virtual;
    function _revertEmptyFeeds() internal pure virtual;
    function _revertLengthMismatch() internal pure virtual;
    function _revertInvalidBasePrice() internal pure virtual;
    function _revertInvalidWeights() internal pure virtual;
    function _revertMissingPythUpdateData() internal pure virtual;
    function _revertInsufficientPythFee() internal pure virtual;
    function _revertMockModeDisabled() internal pure virtual;
    function _revertOraclePriceTooStale() internal pure virtual;
    function _revertOraclePriceNegative() internal pure virtual;

    constructor(
        address _engine,
        address _engineLens,
        address _vault,
        address _pyth,
        bytes32[] memory _feedIds,
        uint256[] memory _quantities,
        uint256[] memory _basePrices,
        bool[] memory _inversions
    ) OrderEscrowAccounting(_engine) {
        if (_engineLens == address(0)) {
            _revertZeroAddress();
        }
        vault = ICfdVault(_vault);
        engineLens = ICfdEngineLens(_engineLens);
        pyth = IPyth(_pyth);

        if (_pyth != address(0)) {
            if (_feedIds.length == 0) {
                _revertEmptyFeeds();
            }
            if (
                _feedIds.length != _quantities.length || _feedIds.length != _basePrices.length
                    || _feedIds.length != _inversions.length
            ) {
                _revertLengthMismatch();
            }
            uint256 totalWeight;
            for (uint256 i = 0; i < _basePrices.length; i++) {
                if (_basePrices[i] == 0) {
                    _revertInvalidBasePrice();
                }
                totalWeight += _quantities[i];
            }
            if (totalWeight != 1e18) {
                _revertInvalidWeights();
            }
        }

        pythFeedIds = _feedIds;
        quantities = _quantities;
        basePrices = _basePrices;
        inversions = _inversions;
    }

    function _currentRouterExecutionContext() internal view returns (RouterExecutionContext memory context) {
        context.oracleFrozen = _isOracleFrozen();
        context.isFadWindow = engine.isFadWindow();
        context.policy = OrderOraclePolicyLib.getOracleExecutionPolicy(
            OrderOraclePolicyLib.OracleAction.OrderExecution,
            context.oracleFrozen,
            context.isFadWindow,
            orderExecutionStalenessLimit,
            liquidationStalenessLimit,
            engine.fadMaxStaleness()
        );
    }

    function _resolveOraclePrice(
        bytes[] calldata pythUpdateData,
        uint256 mockFallbackPrice,
        uint256 maxStaleness,
        uint256 maxPublishTimeDivergence
    ) internal returns (uint256 price, uint64 publishTime, uint256 pythFee) {
        if (address(pyth) != address(0)) {
            if (pythUpdateData.length == 0) {
                _revertMissingPythUpdateData();
            }
            pythFee = pyth.getUpdateFee(pythUpdateData);
            if (msg.value < pythFee) {
                _revertInsufficientPythFee();
            }
            pyth.updatePriceFeeds{value: pythFee}(pythUpdateData);
            uint256 minPublishTime;
            (price, minPublishTime) = _computeBasketPrice(maxStaleness, maxPublishTimeDivergence);
            publishTime = uint64(minPublishTime);
        } else {
            if (block.chainid != 31_337) {
                _revertMockModeDisabled();
            }
            if (pythUpdateData.length > 0) {
                price = abi.decode(pythUpdateData[0], (uint256));
            } else {
                price = mockFallbackPrice;
            }
            publishTime = uint64(block.timestamp);
        }
    }

    function _computeBasketPrice(
        uint256 maxStaleness,
        uint256 maxPublishTimeDivergence
    ) internal view returns (uint256 basketPrice, uint256 minPublishTime) {
        minPublishTime = type(uint256).max;
        uint256 maxPublishTime;
        uint256 len = pythFeedIds.length;

        for (uint256 i = 0; i < len; i++) {
            PythStructs.Price memory p = pyth.getPriceUnsafe(pythFeedIds[i]);
            if (OrderOraclePolicyLib.isStale(uint64(p.publishTime), maxStaleness, block.timestamp)) {
                _revertOraclePriceTooStale();
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
            _revertOraclePriceTooStale();
        }

        if (basketPrice == 0) {
            _revertOraclePriceNegative();
        }
    }

    function _checkSlippage(
        CfdTypes.Order memory order,
        uint256 executionPrice
    ) internal pure returns (bool) {
        if (order.targetPrice == 0) {
            return true;
        }
        if (order.isClose) {
            if (order.side == CfdTypes.Side.BULL) {
                return executionPrice <= order.targetPrice;
            }
            return executionPrice >= order.targetPrice;
        }
        if (order.side == CfdTypes.Side.BULL) {
            return executionPrice >= order.targetPrice;
        }
        return executionPrice <= order.targetPrice;
    }

    function _commitReferencePrice() internal view returns (uint256 price) {
        price = engine.lastMarkPrice();
        if (price == 0) {
            price = 1e8;
        }

        uint256 capPrice = engine.CAP_PRICE();
        return price > capPrice ? capPrice : price;
    }

    function _canUseCommitMarkForOpenPrefilter() internal view returns (bool) {
        uint64 lastMarkTime = engine.lastMarkTime();
        if (lastMarkTime == 0) {
            return false;
        }

        OrderOraclePolicyLib.OracleExecutionPolicy memory policy = OrderOraclePolicyLib.getOracleExecutionPolicy(
            OrderOraclePolicyLib.OracleAction.OrderExecution,
            _isOracleFrozen(),
            engine.isFadWindow(),
            orderExecutionStalenessLimit,
            liquidationStalenessLimit,
            engine.fadMaxStaleness()
        );
        return !OrderOraclePolicyLib.isStale(lastMarkTime, policy.maxStaleness, block.timestamp);
    }

    function _isOracleFrozen() internal view returns (bool) {
        return MarketCalendarLib.isOracleFrozen(block.timestamp, engine.fadDayOverrides(block.timestamp / 86_400));
    }

    function _isCloseOnlyWindow() internal view returns (bool) {
        return _isOracleFrozen() || engine.isFadWindow();
    }

    function _invertPythPrice(
        int64 price,
        int32 expo
    ) internal pure returns (uint256) {
        if (price <= 0) {
            _revertOraclePriceNegative();
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
            _revertOraclePriceNegative();
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

}
