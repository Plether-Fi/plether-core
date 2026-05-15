// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IPyth} from "../../interfaces/IPyth.sol";
import {PletherOracle} from "../PletherOracle.sol";
import {ICfdEngineLens} from "../interfaces/ICfdEngineLens.sol";
import {IHousePool} from "../interfaces/IHousePool.sol";
import {IPletherOracle} from "../interfaces/IPletherOracle.sol";
import {OracleFreshnessPolicyLib} from "../libraries/OracleFreshnessPolicyLib.sol";
import {OrderEscrowAccounting} from "./OrderEscrowAccounting.sol";

abstract contract OrderOracleExecution is OrderEscrowAccounting {

    struct RouterExecutionContext {
        bool oracleFrozen;
        bool isFadWindow;
        bool openExecutionCloseOnly;
    }

    struct OracleUpdateResult {
        uint256 executionPrice;
        uint64 oraclePublishTime;
    }

    IHousePool internal immutable housePool;
    ICfdEngineLens internal immutable engineLens;
    IPletherOracle public pletherOracle;

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
            revert OrderRouter__InvalidEngineLens();
        }
        housePool = IHousePool(_housePool);
        engineLens = ICfdEngineLens(_engineLens);
        _setOracleConfig(_engine, _housePool, _pyth, _feedIds, _quantities, _basePrices, _inversions);
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

    function _prepareOrderExecutionOracle(
        bytes[] calldata pythUpdateData
    ) internal returns (OracleUpdateResult memory update, RouterExecutionContext memory executionContext) {
        return _prepareOrderExecutionOracle(pythUpdateData, IPletherOracle.PriceMode.OrderExecution);
    }

    function _prepareOrderExecutionOracle(
        bytes[] calldata pythUpdateData,
        IPletherOracle.PriceMode mode
    ) internal returns (OracleUpdateResult memory update, RouterExecutionContext memory executionContext) {
        IPletherOracle.PriceSnapshot memory snapshot = _updateAndGetOraclePrice(pythUpdateData, mode);
        IPletherOracle.PolicySnapshot memory executionPolicy = pletherOracle.getOrderExecutionPolicy(false);
        update = _toOracleUpdateResult(snapshot);
        executionContext = RouterExecutionContext({
            oracleFrozen: snapshot.oracleFrozen,
            isFadWindow: snapshot.isFadWindow,
            openExecutionCloseOnly: executionPolicy.closeOnly
        });
        engine.updateMarkPrice(update.executionPrice, update.oraclePublishTime);
    }

    function _prepareMarkRefreshOracle(
        bytes[] calldata pythUpdateData
    ) internal returns (OracleUpdateResult memory update) {
        IPletherOracle.PriceSnapshot memory snapshot =
            _updateAndGetOraclePrice(pythUpdateData, IPletherOracle.PriceMode.MarkRefresh);
        update = _toOracleUpdateResult(snapshot);
        engine.updateMarkPrice(update.executionPrice, update.oraclePublishTime);
    }

    function _prepareLiquidationOracle(
        bytes[] calldata pythUpdateData
    ) internal returns (OracleUpdateResult memory update) {
        IPletherOracle.PriceSnapshot memory snapshot =
            _updateAndGetOraclePrice(pythUpdateData, IPletherOracle.PriceMode.Liquidation);
        update = _toOracleUpdateResult(snapshot);
    }

    function _updateAndGetOraclePrice(
        bytes[] calldata pythUpdateData,
        IPletherOracle.PriceMode mode
    ) internal returns (IPletherOracle.PriceSnapshot memory snapshot) {
        return pletherOracle.updatePrice{value: msg.value}(msg.sender, pythUpdateData, mode);
    }

    function _setOracleConfig(
        address newPyth,
        bytes32[] memory newFeedIds,
        uint256[] memory newQuantities,
        uint256[] memory newBasePrices,
        bool[] memory newInversions
    ) internal {
        _setOracleConfig(
            address(engine), address(housePool), newPyth, newFeedIds, newQuantities, newBasePrices, newInversions
        );
    }

    function _setOracleConfig(
        address engine_,
        address housePool_,
        address newPyth,
        bytes32[] memory newFeedIds,
        uint256[] memory newQuantities,
        uint256[] memory newBasePrices,
        bool[] memory newInversions
    ) internal {
        pletherOracle =
            new PletherOracle(engine_, housePool_, newPyth, newFeedIds, newQuantities, newBasePrices, newInversions);
    }

    function _toOracleUpdateResult(
        IPletherOracle.PriceSnapshot memory snapshot
    ) internal pure returns (OracleUpdateResult memory update) {
        update.executionPrice = snapshot.price;
        update.oraclePublishTime = snapshot.publishTime;
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
