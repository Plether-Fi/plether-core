// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IPyth} from "../../interfaces/IPyth.sol";
import {CfdTypes} from "../CfdTypes.sol";
import {ICfdEngineCore} from "./ICfdEngineCore.sol";
import {IHousePool} from "./IHousePool.sol";

/// @notice Mode-aware Pyth basket oracle for perps execution, liquidation, and pool accounting.
interface IPletherOracle {

    enum PriceMode {
        OrderExecution,
        MarkRefresh,
        Liquidation,
        PoolReconcile
    }

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

    struct PolicySnapshot {
        bool closeOnly;
        bool requireStoredMark;
        bool allowAnyStoredMark;
        uint256 maxStaleness;
        bool oracleFrozen;
        bool isFadWindow;
    }

    struct OracleConfig {
        uint256 orderExecutionStalenessLimit;
        uint256 liquidationStalenessLimit;
        uint256 pythMaxConfidenceRatioBps;
        uint256 orderSettlementWindow;
        uint256 maxComponentPublishTimeDivergence;
        uint256 adverseConfidenceMultiplierBps;
    }

    struct OrderExecutionRequest {
        uint64 commitTime;
        uint256 targetPrice;
        CfdTypes.Side side;
        bool isClose;
        bool revertOnHistoricalUnavailable;
    }

    struct BatchOrderPriceCache {
        bool hasHistoricalBasket;
        uint64 minReusableCommitTime;
        uint256 price;
        uint256 confidence;
        uint64 publishTime;
    }

    error PletherOracle__Unauthorized();
    error PletherOracle__NothingToClaim();
    error PletherOracle__EthTransferFailed();
    error PletherOracle__NoFeeds();
    error PletherOracle__ArrayLengthMismatch(
        uint256 feedIdsLength, uint256 quantitiesLength, uint256 basePricesLength, uint256 inversionsLength
    );
    error PletherOracle__ZeroBasePrice(uint256 index);
    error PletherOracle__InvalidTotalWeight(uint256 totalWeight);
    error PletherOracle__ZeroPyth();
    error PletherOracle__MissingUpdateData();
    error PletherOracle__InsufficientFee(uint256 provided, uint256 required);
    error PletherOracle__PriceOutOfOrder(uint64 publishTime, uint64 lastMarkTime);
    error PletherOracle__StalePrice(
        PriceMode mode, bytes32 feedId, uint256 publishTime, uint256 maxStaleness, uint256 currentTimestamp
    );
    error PletherOracle__InvalidPrice(bytes32 feedId, int64 price);
    error PletherOracle__ConfidenceTooWide(bytes32 feedId, uint64 confidence, int64 price, uint256 maxConfidenceBps);
    error PletherOracle__PublishTimeDivergence(
        PriceMode mode, uint256 minPublishTime, uint256 maxPublishTime, uint256 maxDivergence
    );
    error PletherOracle__ZeroBasketPrice();
    error PletherOracle__InvalidSettlementConfig();

    event EthRefundDeferred(address indexed recipient, uint256 amount);
    event EthRefundClaimed(address indexed recipient, uint256 amount);

    /// @notice Atomically applies oracle update data and returns the validated price snapshot for `mode`.
    /// @dev This is the only state-changing oracle read path. Execution callers must use this function
    ///      and pass the returned `PriceSnapshot` through downstream logic; do not split update/read
    ///      semantics by updating first and later calling `getLatestPrice`.
    /// @param refundRecipient Recipient for any ETH left after paying Pyth fees
    /// @param pythUpdateData Pyth price update blobs
    /// @param mode Oracle policy mode to apply
    /// @return snapshot Validated price, mark, publish time, fee, and policy metadata
    function updatePrice(
        address refundRecipient,
        bytes[] calldata pythUpdateData,
        PriceMode mode
    ) external payable returns (PriceSnapshot memory snapshot);

    /// @notice Applies order-execution update data and returns a strictly post-commit historical execution price.
    /// @dev The caller supplies only the Pyth fee for this parse; refunds for unavailable historical
    ///      parses are returned to the caller so the router can keep aggregate fee accounting correct.
    /// @param refundRecipient Recipient for returned ETH when historical parsing is unavailable
    /// @param pythUpdateData Pyth price update blobs
    /// @param request Order execution price constraints
    /// @return ok True when a valid execution snapshot was produced
    /// @return snapshot Validated historical or frozen-mode execution snapshot
    function updateOrderExecutionPrice(
        address refundRecipient,
        bytes[] calldata pythUpdateData,
        OrderExecutionRequest calldata request
    ) external payable returns (bool ok, PriceSnapshot memory snapshot);

    /// @notice Batch variant that can reuse a historical tick already proven unique for later commits.
    /// @param refundRecipient Recipient for returned ETH when historical parsing is unavailable
    /// @param pythUpdateData Pyth price update blobs
    /// @param request Order execution price constraints
    /// @param cache Reusable historical basket cache from an earlier order in the batch
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
    /// @param refundRecipient Recipient for any ETH left after paying Pyth fees
    /// @param pythUpdateData Pyth price update blobs
    /// @param account Account being liquidated; its side determines adverse confidence adjustment
    /// @return snapshot Validated liquidation snapshot
    function updateLiquidationPrice(
        address refundRecipient,
        bytes[] calldata pythUpdateData,
        address account
    ) external payable returns (PriceSnapshot memory snapshot);

    /// @notice Applies oracle update data and returns the latest live order-execution basket price.
    /// @param refundRecipient Recipient for any ETH left after paying Pyth fees
    /// @param pythUpdateData Pyth price update blobs
    /// @return latestPrice Latest validated live order-execution price
    function updatePrice(
        address refundRecipient,
        bytes[] calldata pythUpdateData
    ) external payable returns (uint256 latestPrice);

    /// @notice Returns the current validated oracle snapshot without applying a Pyth update.
    /// @dev View-only path for diagnostics, simulation, and UI reads. State-changing execution paths
    ///      should use `updatePrice` so the update and read remain one atomic operation.
    /// @param mode Oracle policy mode to apply
    /// @return snapshot Validated price, mark, publish time, and policy metadata
    function getLatestPrice(
        PriceMode mode
    ) external view returns (PriceSnapshot memory snapshot);

    /// @notice Returns the latest validated live order-execution basket price without applying a Pyth update.
    /// @return latestPrice Latest validated live order-execution price
    function getLatestPrice() external view returns (uint256 latestPrice);

    /// @notice Claims any deferred ETH refund owed to the caller.
    function claimEthRefund() external;

    /// @notice Returns deferred ETH refund balance for an account.
    /// @param account Account to inspect
    /// @return amount Claimable ETH amount
    function claimableEth(
        address account
    ) external view returns (uint256 amount);

    /// @notice Returns the order-execution oracle policy for open or close commits.
    /// @param isClose True for close orders, false for open/increase orders
    /// @return policy Effective policy snapshot
    function getOrderExecutionPolicy(
        bool isClose
    ) external view returns (PolicySnapshot memory policy);

    /// @notice Applies oracle policy configuration from the configured router.
    /// @param config Oracle policy configuration to apply
    function applyConfig(
        OracleConfig calldata config
    ) external;

    /// @notice Quotes the ETH fee required to apply `pythUpdateData`.
    /// @param pythUpdateData Pyth price update blobs
    /// @return pythFee ETH fee required by Pyth
    function getUpdateFee(
        bytes[] calldata pythUpdateData
    ) external view returns (uint256 pythFee);

    /// @notice Returns whether the market calendar allows frozen-oracle policy.
    function isOracleFrozen() external view returns (bool);

    /// @notice Returns the live/frozen staleness limit for order execution.
    function orderExecutionStalenessLimit() external view returns (uint256);

    /// @notice Returns the live/frozen staleness limit for liquidation.
    function liquidationStalenessLimit() external view returns (uint256);

    /// @notice Returns the max accepted Pyth confidence ratio in basis points.
    function pythMaxConfidenceRatioBps() external view returns (uint256);

    /// @notice Returns the post-commit settlement window for historical order execution.
    function orderSettlementWindow() external view returns (uint256);

    /// @notice Returns max allowed publish-time divergence across basket components.
    function maxComponentPublishTimeDivergence() external view returns (uint256);

    /// @notice Returns confidence multiplier used for adverse execution/liquidation pricing.
    function adverseConfidenceMultiplierBps() external view returns (uint256);

    /// @notice Returns the engine used for cap, side, and calendar state.
    function engine() external view returns (ICfdEngineCore);

    /// @notice Returns the HousePool used for pool-side freshness policy.
    function housePool() external view returns (IHousePool);

    /// @notice Returns the Pyth contract used for price updates and historical parsing.
    function pyth() external view returns (IPyth);

}
