// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IPyth} from "../../interfaces/IPyth.sol";

interface IPletherOracle {

    enum PriceMode {
        OrderExecution,
        MarkRefresh,
        Liquidation,
        PoolReconcile
    }

    struct PriceSnapshot {
        uint256 price;
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
    }

    error PletherOracle__Unauthorized();
    error PletherOracle__RefundFailed(address recipient, uint256 amount);
    error PletherOracle__NoFeeds();
    error PletherOracle__ArrayLengthMismatch(
        uint256 feedIdsLength, uint256 quantitiesLength, uint256 basePricesLength, uint256 inversionsLength
    );
    error PletherOracle__ZeroBasePrice(uint256 index);
    error PletherOracle__InvalidTotalWeight(uint256 totalWeight);
    error PletherOracle__MockModeForbidden(uint256 chainId);
    error PletherOracle__InvalidMockPrice(uint256 price);
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

    /// @notice Atomically applies oracle update data and returns the validated price snapshot for `mode`.
    /// @dev This is the only state-changing oracle read path. Execution callers must use this function
    ///      and pass the returned `PriceSnapshot` through downstream logic; do not split update/read
    ///      semantics by updating first and later calling `getPrice`.
    function updateAndGetPrice(
        bytes[] calldata pythUpdateData,
        PriceMode mode
    ) external payable returns (PriceSnapshot memory snapshot);

    /// @notice Returns the current validated oracle price without applying a Pyth update.
    /// @dev View-only path for diagnostics, simulation, and UI reads. State-changing execution paths
    ///      should use `updateAndGetPrice` so the update and read remain one atomic operation.
    function getPrice(
        PriceMode mode
    ) external view returns (PriceSnapshot memory snapshot);

    function getOrderExecutionPolicy(
        bool isClose
    ) external view returns (PolicySnapshot memory policy);

    function applyConfig(
        OracleConfig calldata config
    ) external;

    /// @notice Quotes the ETH fee required to apply `pythUpdateData`.
    function getUpdateFee(
        bytes[] calldata pythUpdateData
    ) external view returns (uint256 pythFee);

    function isOracleFrozen() external view returns (bool);

    function orderExecutionStalenessLimit() external view returns (uint256);

    function liquidationStalenessLimit() external view returns (uint256);

    function pythMaxConfidenceRatioBps() external view returns (uint256);

    function pyth() external view returns (IPyth);

}
