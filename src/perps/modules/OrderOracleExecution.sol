// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IPyth, PythStructs} from "../../interfaces/IPyth.sol";
import {DecimalConstants} from "../../libraries/DecimalConstants.sol";
import {CfdTypes} from "../CfdTypes.sol";
import {ICfdEngineLens} from "../interfaces/ICfdEngineLens.sol";
import {ICfdVault} from "../interfaces/ICfdVault.sol";
import {IOrderRouterErrors} from "../interfaces/IOrderRouterErrors.sol";
import {MarketCalendarLib} from "../libraries/MarketCalendarLib.sol";
import {OracleFreshnessPolicyLib} from "../libraries/OracleFreshnessPolicyLib.sol";
import {OrderEscrowAccounting} from "./OrderEscrowAccounting.sol";

abstract contract OrderOracleExecution is OrderEscrowAccounting {

    struct RouterExecutionContext {
        bool oracleFrozen;
        bool isFadWindow;
        OracleFreshnessPolicyLib.Policy policy;
    }

    struct OracleUpdateResult {
        uint256 executionPrice;
        uint64 oraclePublishTime;
        uint256 pythFee;
    }

    ICfdVault internal immutable housePool;
    ICfdEngineLens internal immutable engineLens;
    IPyth public pyth;
    bytes32[] public pythFeedIds;
    uint256[] public quantities;
    uint256[] public basePrices;
    bool[] public inversions;

    uint256 public orderExecutionStalenessLimit = 60;
    uint256 public liquidationStalenessLimit = 15;
    uint256 public pythMaxConfidenceRatioBps = 10_000;

    constructor(
        address _engine,
        address _engineLens,
        address _housePool,
        address _pyth,
        bytes32[] memory _feedIds,
        uint256[] memory _quantities,
        uint256[] memory _basePrices,
        bool[] memory _inversions
    ) OrderEscrowAccounting(_engine) {
        if (_engineLens == address(0)) {
            revert IOrderRouterErrors.OrderRouter__OracleValidation(7);
        }
        housePool = ICfdVault(_housePool);
        engineLens = ICfdEngineLens(_engineLens);
        pyth = IPyth(_pyth);

        if (_pyth != address(0)) {
            if (_feedIds.length == 0) {
                revert IOrderRouterErrors.OrderRouter__OracleValidation(0);
            }
            if (
                _feedIds.length != _quantities.length || _feedIds.length != _basePrices.length
                    || _feedIds.length != _inversions.length
            ) {
                revert IOrderRouterErrors.OrderRouter__OracleValidation(1);
            }
            uint256 totalWeight;
            for (uint256 i = 0; i < _basePrices.length; i++) {
                if (_basePrices[i] == 0) {
                    revert IOrderRouterErrors.OrderRouter__OracleValidation(2);
                }
                totalWeight += _quantities[i];
            }
            if (totalWeight != 1e18) {
                revert IOrderRouterErrors.OrderRouter__OracleValidation(3);
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
        context.policy = _executionPolicyForOrder(false, context.oracleFrozen, context.isFadWindow);
    }

    function _prepareOrderExecutionOracle(
        bytes[] calldata pythUpdateData,
        uint256 mockFallbackPrice
    ) internal returns (OracleUpdateResult memory update, RouterExecutionContext memory executionContext) {
        uint256 maxStaleness;
        if (address(pyth) != address(0)) {
            executionContext = _currentRouterExecutionContext();
            maxStaleness = executionContext.policy.maxStaleness;
        }

        (update.executionPrice, update.oraclePublishTime, update.pythFee) =
            _resolveOraclePrice(pythUpdateData, mockFallbackPrice, maxStaleness, orderExecutionStalenessLimit);

        if (address(pyth) != address(0)) {
            if (OracleFreshnessPolicyLib.isStale(
                    update.oraclePublishTime, executionContext.policy.maxStaleness, block.timestamp
                )) {
                revert IOrderRouterErrors.OrderRouter__OracleValidation(10);
            }
        }

        if (update.oraclePublishTime < engine.lastMarkTime()) {
            revert IOrderRouterErrors.OrderRouter__OracleValidation(9);
        }

        uint256 capPrice = engine.CAP_PRICE();
        if (update.executionPrice > capPrice) {
            update.executionPrice = capPrice;
        }

        engine.updateMarkPrice(update.executionPrice, update.oraclePublishTime);
    }

    function _prepareMarkRefreshOracle(
        bytes[] calldata pythUpdateData
    ) internal returns (OracleUpdateResult memory update) {
        uint256 maxStaleness = orderExecutionStalenessLimit;
        if (address(pyth) != address(0)) {
            maxStaleness =
            OracleFreshnessPolicyLib.getPolicy(
                OracleFreshnessPolicyLib.Mode.MarkRefresh,
                _isOracleFrozen(),
                engine.isFadWindow(),
                engine.engineMarkStalenessLimit(),
                housePool.markStalenessLimit(),
                orderExecutionStalenessLimit,
                liquidationStalenessLimit,
                engine.fadMaxStaleness()
            )
            .maxStaleness;
        }

        (update.executionPrice, update.oraclePublishTime, update.pythFee) =
            _resolveOraclePrice(pythUpdateData, 1e8, maxStaleness, orderExecutionStalenessLimit);

        if (address(pyth) != address(0)) {
            OracleFreshnessPolicyLib.Policy memory policy = OracleFreshnessPolicyLib.getPolicy(
                OracleFreshnessPolicyLib.Mode.MarkRefresh,
                _isOracleFrozen(),
                engine.isFadWindow(),
                engine.engineMarkStalenessLimit(),
                housePool.markStalenessLimit(),
                orderExecutionStalenessLimit,
                liquidationStalenessLimit,
                engine.fadMaxStaleness()
            );
            if (OracleFreshnessPolicyLib.isStale(update.oraclePublishTime, policy.maxStaleness, block.timestamp)) {
                revert IOrderRouterErrors.OrderRouter__OracleValidation(10);
            }
        }

        engine.updateMarkPrice(update.executionPrice, update.oraclePublishTime);
    }

    function _prepareLiquidationOracle(
        bytes[] calldata pythUpdateData
    ) internal returns (OracleUpdateResult memory update) {
        uint256 maxStaleness = liquidationStalenessLimit;
        if (address(pyth) != address(0)) {
            maxStaleness =
            OracleFreshnessPolicyLib.getPolicy(
                OracleFreshnessPolicyLib.Mode.Liquidation,
                _isOracleFrozen(),
                engine.isFadWindow(),
                engine.engineMarkStalenessLimit(),
                housePool.markStalenessLimit(),
                orderExecutionStalenessLimit,
                liquidationStalenessLimit,
                engine.fadMaxStaleness()
            )
            .maxStaleness;
        }

        (update.executionPrice, update.oraclePublishTime, update.pythFee) =
            _resolveOraclePrice(pythUpdateData, 1e8, maxStaleness, liquidationStalenessLimit);

        if (address(pyth) != address(0)) {
            OracleFreshnessPolicyLib.Policy memory policy = OracleFreshnessPolicyLib.getPolicy(
                OracleFreshnessPolicyLib.Mode.Liquidation,
                _isOracleFrozen(),
                engine.isFadWindow(),
                engine.engineMarkStalenessLimit(),
                housePool.markStalenessLimit(),
                orderExecutionStalenessLimit,
                liquidationStalenessLimit,
                engine.fadMaxStaleness()
            );
            if (OracleFreshnessPolicyLib.isStale(update.oraclePublishTime, policy.maxStaleness, block.timestamp)) {
                revert IOrderRouterErrors.OrderRouter__OracleValidation(12);
            }
        }
    }

    function _executionPolicyForOrder(
        bool isClose,
        bool oracleFrozen,
        bool isFadWindow
    ) internal view returns (OracleFreshnessPolicyLib.Policy memory) {
        return OracleFreshnessPolicyLib.getPolicy(
            isClose ? OracleFreshnessPolicyLib.Mode.CloseExecution : OracleFreshnessPolicyLib.Mode.OpenExecution,
            oracleFrozen,
            isFadWindow,
            engine.engineMarkStalenessLimit(),
            housePool.markStalenessLimit(),
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
                revert IOrderRouterErrors.OrderRouter__OracleValidation(5);
            }
            pythFee = pyth.getUpdateFee(pythUpdateData);
            if (msg.value < pythFee) {
                revert IOrderRouterErrors.OrderRouter__OracleValidation(6);
            }
            pyth.updatePriceFeeds{value: pythFee}(pythUpdateData);
            uint256 minPublishTime;
            (price, minPublishTime) = _computeBasketPrice(maxStaleness, maxPublishTimeDivergence);
            publishTime = uint64(minPublishTime);
        } else {
            if (block.chainid != 31_337) {
                revert IOrderRouterErrors.OrderRouter__OracleValidation(4);
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
            if (OracleFreshnessPolicyLib.isStale(p.publishTime, maxStaleness, block.timestamp)) {
                revert IOrderRouterErrors.OrderRouter__OracleValidation(10);
            }
            if (p.price <= 0) {
                revert IOrderRouterErrors.OrderRouter__OracleValidation(8);
            }
            if (uint256(uint64(p.conf)) * 10_000 > uint256(uint64(p.price)) * pythMaxConfidenceRatioBps) {
                revert IOrderRouterErrors.OrderRouter__OracleValidation(11);
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
            revert IOrderRouterErrors.OrderRouter__OracleValidation(10);
        }

        if (basketPrice == 0) {
            revert IOrderRouterErrors.OrderRouter__OracleValidation(8);
        }
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

        OracleFreshnessPolicyLib.Policy memory policy =
            _executionPolicyForOrder(false, _isOracleFrozen(), engine.isFadWindow());
        return !OracleFreshnessPolicyLib.isStale(lastMarkTime, policy.maxStaleness, block.timestamp);
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
            revert IOrderRouterErrors.OrderRouter__OracleValidation(8);
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
            revert IOrderRouterErrors.OrderRouter__OracleValidation(8);
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
