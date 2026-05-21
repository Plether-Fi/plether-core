// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IPyth} from "../../interfaces/IPyth.sol";
import {CfdTypes} from "../CfdTypes.sol";
import {ICfdEngineCore} from "../interfaces/ICfdEngineCore.sol";
import {ICfdEngineLens} from "../interfaces/ICfdEngineLens.sol";
import {IHousePool} from "../interfaces/IHousePool.sol";
import {IPletherOracle} from "../interfaces/IPletherOracle.sol";
import {OracleFreshnessPolicyLib} from "../libraries/OracleFreshnessPolicyLib.sol";
import {OrderReservationAccounting} from "./OrderReservationAccounting.sol";

abstract contract OrderOracleExecution is OrderReservationAccounting {

    struct RouterExecutionContext {
        bool oracleFrozen;
        bool isFadWindow;
        bool openExecutionCloseOnly;
    }

    struct OracleUpdateResult {
        uint256 executionPrice;
        uint256 markPrice;
        uint64 oraclePublishTime;
        uint256 pythFee;
    }

    IHousePool internal immutable housePool;
    ICfdEngineLens internal immutable engineLens;
    IPletherOracle public pletherOracle;

    constructor(
        address _engine,
        address _engineLens,
        address _housePool,
        address _pletherOracle
    ) OrderReservationAccounting(_engine) {
        if (_engineLens == address(0)) {
            revert OrderRouter__InvalidEngineLens();
        }
        housePool = IHousePool(_housePool);
        engineLens = ICfdEngineLens(_engineLens);
        _setOracleConfig(_pletherOracle);
    }

    function pyth() public view returns (IPyth) {
        return pletherOracle.pyth();
    }

    function orderExecutionStalenessLimit() public view returns (uint256) {
        return pletherOracle.orderExecutionStalenessLimit();
    }

    function liquidationStalenessLimit() public view returns (uint256) {
        return pletherOracle.liquidationStalenessLimit();
    }

    function pythMaxConfidenceRatioBps() public view returns (uint256) {
        return pletherOracle.pythMaxConfidenceRatioBps();
    }

    function orderSettlementWindow() public view returns (uint256) {
        return pletherOracle.orderSettlementWindow();
    }

    function maxComponentPublishTimeDivergence() public view returns (uint256) {
        return pletherOracle.maxComponentPublishTimeDivergence();
    }

    function adverseConfidenceMultiplierBps() public view returns (uint256) {
        return pletherOracle.adverseConfidenceMultiplierBps();
    }

    function _prepareOrderExecutionOracle(
        bytes[] calldata pythUpdateData,
        CfdTypes.Order memory order,
        uint256 pythFeeAlreadySpent
    ) internal returns (OracleUpdateResult memory update, RouterExecutionContext memory executionContext) {
        uint256 pythFee = _checkedPythFee(pythUpdateData, pythFeeAlreadySpent);
        (bool ok, IPletherOracle.PriceSnapshot memory snapshot) = pletherOracle.updateOrderExecutionPrice{
            value: pythFee
        }(
            msg.sender, pythUpdateData, _orderExecutionRequest(order, true)
        );
        if (!ok) {
            _revertOrderExecutionStale();
        }
        update = _toOracleUpdateResult(snapshot);
        executionContext = RouterExecutionContext({
            oracleFrozen: snapshot.oracleFrozen,
            isFadWindow: snapshot.isFadWindow,
            openExecutionCloseOnly: snapshot.closeOnly
        });
        _updateEngineMarkIfCurrent(update);
    }

    function _tryPrepareBatchOrderExecutionOracle(
        bytes[] calldata pythUpdateData,
        CfdTypes.Order memory order,
        uint256 pythFeeAlreadySpent,
        IPletherOracle.BatchOrderPriceCache memory cache
    )
        internal
        returns (
            bool ok,
            OracleUpdateResult memory update,
            RouterExecutionContext memory executionContext,
            IPletherOracle.BatchOrderPriceCache memory nextCache
        )
    {
        uint256 pythFee;
        if (!_canReuseHistoricalBatchBasket(order, cache)) {
            pythFee = _checkedPythFee(pythUpdateData, pythFeeAlreadySpent);
        }
        IPletherOracle.PriceSnapshot memory snapshot;
        (ok, snapshot, nextCache) = pletherOracle.updateBatchOrderExecutionPrice{value: pythFee}(
            msg.sender, pythUpdateData, _orderExecutionRequest(order, false), cache
        );
        if (!ok) {
            update.pythFee = snapshot.updateFee;
            return (false, update, executionContext, nextCache);
        }
        update = _toOracleUpdateResult(snapshot);
        executionContext = RouterExecutionContext({
            oracleFrozen: snapshot.oracleFrozen,
            isFadWindow: snapshot.isFadWindow,
            openExecutionCloseOnly: snapshot.closeOnly
        });
        _updateEngineMarkIfCurrent(update);
    }

    function _prepareMarkRefreshOracle(
        bytes[] calldata pythUpdateData
    ) internal returns (OracleUpdateResult memory update) {
        IPletherOracle.PriceSnapshot memory snapshot =
            _updateAndGetOraclePrice(pythUpdateData, IPletherOracle.PriceMode.MarkRefresh);
        update = _toOracleUpdateResult(snapshot);
        engine.updateMarkPrice(update.markPrice, update.oraclePublishTime);
    }

    function _prepareLiquidationOracle(
        address account,
        bytes[] calldata pythUpdateData
    ) internal returns (OracleUpdateResult memory update) {
        IPletherOracle.PriceSnapshot memory snapshot =
            pletherOracle.updateLiquidationPrice{value: msg.value}(msg.sender, pythUpdateData, account);
        update = _toOracleUpdateResult(snapshot);
        _updateEngineMarkIfCurrent(update);
    }

    function _updateAndGetOraclePrice(
        bytes[] calldata pythUpdateData,
        IPletherOracle.PriceMode mode
    ) internal returns (IPletherOracle.PriceSnapshot memory snapshot) {
        return pletherOracle.updatePrice{value: msg.value}(msg.sender, pythUpdateData, mode);
    }

    function _setOracleConfig(
        address newPletherOracle
    ) internal {
        if (newPletherOracle == address(0) || newPletherOracle.code.length == 0) {
            revert OrderRouter__InvalidPletherOracle();
        }
        IPletherOracle oracle = IPletherOracle(newPletherOracle);
        try oracle.pyth() returns (IPyth pyth_) {
            if (address(pyth_) == address(0)) {
                revert OrderRouter__InvalidPletherOracle();
            }
        } catch {
            revert OrderRouter__InvalidPletherOracle();
        }
        try oracle.engine() returns (ICfdEngineCore oracleEngine) {
            if (address(oracleEngine) != address(engine)) {
                revert OrderRouter__InvalidPletherOracle();
            }
        } catch {
            revert OrderRouter__InvalidPletherOracle();
        }
        try oracle.housePool() returns (IHousePool oracleHousePool) {
            if (address(oracleHousePool) != address(housePool)) {
                revert OrderRouter__InvalidPletherOracle();
            }
        } catch {
            revert OrderRouter__InvalidPletherOracle();
        }
        pletherOracle = oracle;
    }

    function _toOracleUpdateResult(
        IPletherOracle.PriceSnapshot memory snapshot
    ) internal pure returns (OracleUpdateResult memory update) {
        update.executionPrice = snapshot.price;
        update.markPrice = snapshot.markPrice;
        update.oraclePublishTime = snapshot.publishTime;
        update.pythFee = snapshot.updateFee;
    }

    function _checkedPythFee(
        bytes[] calldata pythUpdateData,
        uint256 pythFeeAlreadySpent
    ) internal view returns (uint256 pythFee) {
        pythFee = pletherOracle.getUpdateFee(pythUpdateData);
        if (msg.value < pythFeeAlreadySpent + pythFee) {
            revert IPletherOracle.PletherOracle__InsufficientFee(msg.value, pythFeeAlreadySpent + pythFee);
        }
    }

    function _orderExecutionRequest(
        CfdTypes.Order memory order,
        bool revertOnHistoricalUnavailable
    ) internal pure returns (IPletherOracle.OrderExecutionRequest memory request) {
        request = IPletherOracle.OrderExecutionRequest({
            commitTime: order.commitTime,
            targetPrice: order.targetPrice,
            side: order.side,
            isClose: order.isClose,
            revertOnHistoricalUnavailable: revertOnHistoricalUnavailable
        });
    }

    function _updateEngineMarkIfCurrent(
        OracleUpdateResult memory update
    ) internal {
        if (update.oraclePublishTime >= engine.lastMarkTime()) {
            engine.updateMarkPrice(update.markPrice, update.oraclePublishTime);
        }
    }

    function _canReuseHistoricalBatchBasket(
        CfdTypes.Order memory order,
        IPletherOracle.BatchOrderPriceCache memory cache
    ) internal view returns (bool) {
        if (_isOracleFrozen() || !cache.hasHistoricalBasket) {
            return false;
        }
        uint64 commitTime = order.commitTime;
        if (commitTime < cache.minReusableCommitTime || commitTime >= cache.publishTime) {
            return false;
        }
        if (cache.publishTime > block.timestamp) {
            return false;
        }
        return uint256(cache.publishTime) <= uint256(commitTime) + orderSettlementWindow();
    }

    function _revertOrderExecutionStale() internal view {
        revert IPletherOracle.PletherOracle__StalePrice(
            IPletherOracle.PriceMode.OrderExecution,
            bytes32(0),
            block.timestamp,
            orderExecutionStalenessLimit(),
            block.timestamp
        );
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

        IPletherOracle.PolicySnapshot memory policy = pletherOracle.getOrderExecutionPolicy(false);
        return !OracleFreshnessPolicyLib.isStale(lastMarkTime, policy.maxStaleness, block.timestamp);
    }

    function _isOracleFrozen() internal view returns (bool) {
        return pletherOracle.isOracleFrozen();
    }

    function _isCloseOnlyWindow() internal view returns (bool) {
        return pletherOracle.getOrderExecutionPolicy(false).closeOnly;
    }

}
