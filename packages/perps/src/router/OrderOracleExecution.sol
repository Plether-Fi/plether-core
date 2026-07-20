// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {ICfdEngineLens} from "@plether/perps/interfaces/ICfdEngineLens.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {OracleFreshnessPolicyLib} from "@plether/perps/libraries/OracleFreshnessPolicyLib.sol";
import {OrderReservationAccounting} from "@plether/perps/router/OrderReservationAccounting.sol";
import {IPyth} from "@plether/shared/interfaces/IPyth.sol";

/// @title OrderOracleExecution
/// @notice Integrates the router with Plether's mode-aware Pyth oracle and exposes its active policy settings.
abstract contract OrderOracleExecution is OrderReservationAccounting {

    /// @notice Execution-policy flags captured with the price used for an order.
    /// @param oracleFrozen Whether the snapshot used frozen-oracle policy.
    /// @param isFadWindow Whether the snapshot was produced during the FAD calendar window.
    /// @param openExecutionCloseOnly Whether the snapshot policy blocks open/increase execution.
    struct RouterExecutionContext {
        bool oracleFrozen;
        bool isFadWindow;
        bool openExecutionCloseOnly;
    }

    /// @notice Normalized subset of an oracle price snapshot consumed by router handlers.
    /// @param executionPrice Account-adverse or order execution price (8 decimals).
    /// @param markPrice Neutral basket mark sent to the engine (8 decimals).
    /// @param oraclePublishTime Basket publish timestamp.
    /// @param pythFee ETH update fee consumed by the oracle, in wei.
    struct OracleUpdateResult {
        uint256 executionPrice;
        uint256 markPrice;
        uint64 oraclePublishTime;
        uint256 pythFee;
    }

    /// @notice House pool used for execution depth and oracle wiring validation.
    IHousePool internal immutable housePool;
    /// @notice Engine lens used for commit-time open-order preflight classification.
    ICfdEngineLens internal immutable engineLens;
    /// @notice Active Plether oracle used for all router price paths.
    IPletherOracle public pletherOracle;

    /// @notice Binds the router oracle layer to its engine, lens, pool, and initial Plether oracle.
    /// @dev Reverts for a zero engine lens. The oracle is validated for deployed code, nonzero Pyth,
    ///      and exact engine and HousePool wiring; `_housePool` itself is not independently code-checked.
    /// @param _engine Engine used for mark updates and oracle identity validation.
    /// @param _engineLens Engine lens used for open preflight reads.
    /// @param _housePool House pool used for depth and oracle identity validation.
    /// @param _pletherOracle Initial Plether oracle contract.
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

    /// @notice Returns the Pyth contract used by the configured Plether oracle.
    /// @return Active Pyth integration contract.
    function pyth() public view returns (IPyth) {
        return pletherOracle.pyth();
    }

    /// @notice Returns the order-execution staleness limit from the configured Plether oracle.
    /// @return Maximum accepted price age in seconds.
    function orderExecutionStalenessLimit() public view returns (uint256) {
        return pletherOracle.orderExecutionStalenessLimit();
    }

    /// @notice Returns the liquidation staleness limit from the configured Plether oracle.
    /// @return Maximum accepted liquidation-price age in seconds.
    function liquidationStalenessLimit() public view returns (uint256) {
        return pletherOracle.liquidationStalenessLimit();
    }

    /// @notice Returns the max accepted Pyth confidence ratio from the configured Plether oracle.
    /// @return Maximum confidence-to-price ratio in basis points.
    function pythMaxConfidenceRatioBps() public view returns (uint256) {
        return pletherOracle.pythMaxConfidenceRatioBps();
    }

    /// @notice Returns the historical order settlement window from the configured Plether oracle.
    /// @return Maximum seconds after commit in which the historical execution tick may publish.
    function orderSettlementWindow() public view returns (uint256) {
        return pletherOracle.orderSettlementWindow();
    }

    /// @notice Returns max allowed basket component publish-time divergence.
    /// @return Maximum difference between component publish times in seconds.
    function maxComponentPublishTimeDivergence() public view returns (uint256) {
        return pletherOracle.maxComponentPublishTimeDivergence();
    }

    /// @notice Returns the multiplier used for adverse order pricing outside oracle-frozen voluntary closes
    ///         and for all liquidation pricing.
    /// @return Confidence adjustment multiplier in basis points, where 10,000 is 1x.
    function adverseConfidenceMultiplierBps() public view returns (uint256) {
        return pletherOracle.adverseConfidenceMultiplierBps();
    }

    /// @notice Resolves a single order's execution snapshot, policy context, fee, and current engine mark.
    /// @dev Requires a usable historical/frozen snapshot and reverts with the router's canonical stale-price error
    ///      otherwise. The oracle receives only the newly required fee; `pythFeeAlreadySpent` protects aggregate `msg.value`.
    /// @param pythUpdateData Pyth update blobs supplied by the execution caller.
    /// @param order Pending order whose post-commit price is requested.
    /// @param pythFeeAlreadySpent Wei already consumed earlier in the same router call.
    /// @return update Normalized price, publish time, and newly consumed fee.
    /// @return executionContext Policy flags captured with the snapshot.
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

    /// @notice Attempts to resolve a batch order price, reusing a compatible historical basket when possible.
    /// @dev Unlike the single-order path, unavailable history is returned as `ok == false`; `update.pythFee`
    ///      still reports any fee consumed/refunded by the attempt so batch accounting remains exact.
    /// @param pythUpdateData Pyth update blobs supplied by the execution caller.
    /// @param order Current FIFO order.
    /// @param pythFeeAlreadySpent Wei already consumed by earlier batch iterations.
    /// @param cache Historical basket cache returned by the previous iteration.
    /// @return ok Whether a valid execution snapshot was produced.
    /// @return update Normalized snapshot, or only fee information on failure.
    /// @return executionContext Policy flags captured with a successful snapshot.
    /// @return nextCache Cache to pass to the next FIFO order.
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

    /// @notice Applies a mark-refresh update and unconditionally forwards the returned mark to the engine.
    /// @param pythUpdateData Pyth update blobs; the oracle receives the call's full `msg.value`.
    /// @return update Normalized refresh snapshot.
    function _prepareMarkRefreshOracle(
        bytes[] calldata pythUpdateData
    ) internal returns (OracleUpdateResult memory update) {
        IPletherOracle.PriceSnapshot memory snapshot =
            _updateAndGetOraclePrice(pythUpdateData, IPletherOracle.PriceMode.MarkRefresh);
        update = _toOracleUpdateResult(snapshot);
        engine.updateMarkPrice(update.markPrice, update.oraclePublishTime);
    }

    /// @notice Applies an account-adverse liquidation update and advances the engine mark when current.
    /// @param account Account whose side determines the adverse confidence adjustment.
    /// @param pythUpdateData Pyth update blobs; the oracle receives the call's full `msg.value`.
    /// @return update Normalized liquidation snapshot.
    function _prepareLiquidationOracle(
        address account,
        bytes[] calldata pythUpdateData
    ) internal returns (OracleUpdateResult memory update) {
        IPletherOracle.PriceSnapshot memory snapshot =
            pletherOracle.updateLiquidationPrice{value: msg.value}(msg.sender, pythUpdateData, account);
        update = _toOracleUpdateResult(snapshot);
        _updateEngineMarkIfCurrent(update);
    }

    /// @notice Forwards a generic mode-specific update to the Plether oracle with the call's full ETH value.
    /// @param pythUpdateData Pyth update blobs.
    /// @param mode Oracle policy mode to apply.
    /// @return snapshot Validated oracle snapshot.
    function _updateAndGetOraclePrice(
        bytes[] calldata pythUpdateData,
        IPletherOracle.PriceMode mode
    ) internal returns (IPletherOracle.PriceSnapshot memory snapshot) {
        return pletherOracle.updatePrice{value: msg.value}(msg.sender, pythUpdateData, mode);
    }

    /// @notice Validates and installs a Plether oracle wired to this router's engine and HousePool.
    /// @param newPletherOracle Candidate deployed oracle address.
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

    /// @notice Copies the router-relevant fields from a full oracle snapshot.
    /// @param snapshot Full Plether oracle snapshot.
    /// @return update Normalized router result.
    function _toOracleUpdateResult(
        IPletherOracle.PriceSnapshot memory snapshot
    ) internal pure returns (OracleUpdateResult memory update) {
        update.executionPrice = snapshot.price;
        update.markPrice = snapshot.markPrice;
        update.oraclePublishTime = snapshot.publishTime;
        update.pythFee = snapshot.updateFee;
    }

    /// @notice Quotes the Pyth fee and ensures aggregate fee consumption fits within `msg.value`.
    /// @param pythUpdateData Pyth update blobs to quote.
    /// @param pythFeeAlreadySpent Wei already consumed in this router call.
    /// @return pythFee Additional fee required for this update, in wei.
    function _checkedPythFee(
        bytes[] calldata pythUpdateData,
        uint256 pythFeeAlreadySpent
    ) internal view returns (uint256 pythFee) {
        pythFee = pletherOracle.getUpdateFee(pythUpdateData);
        if (msg.value < pythFeeAlreadySpent + pythFee) {
            revert IPletherOracle.PletherOracle__InsufficientFee(msg.value, pythFeeAlreadySpent + pythFee);
        }
    }

    /// @notice Converts a router order into the oracle's execution request shape.
    /// @param order Order supplying commit, limit, side, and close metadata.
    /// @param revertOnHistoricalUnavailable Whether the oracle should revert instead of returning `ok == false`.
    /// @return request Oracle execution request.
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

    /// @notice Advances the engine mark only when the snapshot is not older than the stored mark.
    /// @param update Normalized snapshot carrying mark price and publish time.
    function _updateEngineMarkIfCurrent(
        OracleUpdateResult memory update
    ) internal {
        if (update.oraclePublishTime >= engine.lastMarkTime()) {
            engine.updateMarkPrice(update.markPrice, update.oraclePublishTime);
        }
    }

    /// @notice Tests whether a cached historical basket is valid for a later batch order's commit window.
    /// @dev Cache reuse is disabled in frozen-oracle mode and requires `commitTime < publishTime <=
    ///      commitTime + orderSettlementWindow`, the cache's minimum reusable commit bound, and no future timestamp.
    /// @param order Later FIFO order to price.
    /// @param cache Candidate historical basket cache.
    /// @return Whether the cache satisfies every reuse bound.
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

    /// @notice Reverts with the canonical order-execution stale-price error for the current block time.
    function _revertOrderExecutionStale() internal view {
        revert IPletherOracle.PletherOracle__StalePrice(
            IPletherOracle.PriceMode.OrderExecution,
            bytes32(0),
            block.timestamp,
            orderExecutionStalenessLimit(),
            block.timestamp
        );
    }

    /// @notice Returns a cap-bounded stored mark for commit checks and expired-order cleanup.
    /// @dev Substitutes 1e8 when the stored mark is zero, then clamps to `engine.CAP_PRICE()`; a zero cap yields zero.
    /// @return price Reference price in 8-decimal oracle units.
    function _commitReferencePrice() internal view returns (uint256 price) {
        price = engine.lastMarkPrice();
        if (price == 0) {
            price = 1e8;
        }

        uint256 capPrice = engine.CAP_PRICE();
        return price > capPrice ? capPrice : price;
    }

    /// @notice Returns whether the stored mark is initialized and fresh enough for open preflight rejection.
    /// @return True when the mark is nonzero-timestamped and fresh under the current open-order policy.
    function _canUseCommitMarkForOpenPrefilter() internal view returns (bool) {
        uint64 lastMarkTime = engine.lastMarkTime();
        if (lastMarkTime == 0) {
            return false;
        }

        IPletherOracle.PolicySnapshot memory policy = pletherOracle.getOrderExecutionPolicy(false);
        return !OracleFreshnessPolicyLib.isStale(lastMarkTime, policy.maxStaleness, block.timestamp);
    }

    /// @notice Returns whether the oracle's market-calendar policy is currently frozen.
    /// @return True when frozen-oracle policy is active.
    function _isOracleFrozen() internal view returns (bool) {
        return pletherOracle.isOracleFrozen();
    }

    /// @notice Returns whether the current open-order execution policy is close-only.
    /// @return True when new risk-increasing commits are disallowed by oracle policy.
    function _isCloseOnlyWindow() internal view returns (bool) {
        return pletherOracle.getOrderExecutionPolicy(false).closeOnly;
    }

}
