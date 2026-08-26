// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineProtocolLens} from "@plether/perps/CfdEngineProtocolLens.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {ITerminalNavBookV2} from "@plether/perps/interfaces/ITerminalNavBookV2.sol";
import {SettlementMonitorViewTypes} from "@plether/perps/interfaces/SettlementMonitorViewTypes.sol";

interface ISettlementMonitorSidecarVaultView {

    function maintenanceFeeAprBps() external view returns (uint256);

    function maintenanceFeeRecipient() external view returns (address);

    function pendingDepositEscrowAssets() external view returns (uint256);

    function withdrawalEscrowAssets() external view returns (uint256);

    function pendingRedeemEscrowShares() external view returns (uint256);

    function depositClaimEscrowShares() external view returns (uint256);

    function seedReceiver() external view returns (address);

    function seedShareFloor() external view returns (uint256);

}

/// @dev Size sidecar deployed atomically by SettlementMonitorLens. Its public methods only accept calls from the
///      constructor-bound monitor so no third party can present fabricated queue evidence as an official health result.
///      Bindings are constructor-only storage: this non-proxy contract exposes no setter or delegatecall path.
contract SettlementMonitorLensSidecar {

    uint256 internal constant CONFIG_SCHEMA_VERSION = 4;
    bytes32 internal constant CONFIG_DOMAIN = keccak256("PLETHER_SETTLEMENT_CONFIG_V4");
    uint256 internal constant STATIC_READ_GAS = 500_000;
    uint256 internal constant MAX_STATIC_WORDS = 16;

    address public MONITOR;
    OrderRouter internal ROUTER;
    CfdEngine internal ENGINE;
    HousePool internal HOUSE_POOL;
    CfdEngineProtocolLens internal ENGINE_PROTOCOL_LENS;
    MarginClearinghouse internal CLEARINGHOUSE;
    TerminalNavBookV2 internal TERMINAL_NAV_BOOK;
    TrancheVault internal SENIOR_VAULT;
    TrancheVault internal JUNIOR_VAULT;
    IERC20 internal USDC;
    address internal _BOUND_PLANNER;
    bytes32 internal _BOUND_PLANNER_CODEHASH;

    error SettlementMonitorLensSidecar__OnlyMonitor();

    modifier onlyMonitor() {
        if (msg.sender != MONITOR) {
            revert SettlementMonitorLensSidecar__OnlyMonitor();
        }
        _;
    }

    constructor(
        address router_
    ) {
        MONITOR = msg.sender;
        ROUTER = OrderRouter(router_);
        ENGINE = CfdEngine(address(ROUTER.engine()));
        HOUSE_POOL = HousePool(address(ENGINE.pool()));
        ENGINE_PROTOCOL_LENS = CfdEngineProtocolLens(address(HOUSE_POOL.ENGINE_PROTOCOL_LENS()));
        CLEARINGHOUSE = MarginClearinghouse(address(ENGINE.clearinghouse()));
        TERMINAL_NAV_BOOK = TerminalNavBookV2(address(ENGINE.terminalNavBook()));
        SENIOR_VAULT = TrancheVault(HOUSE_POOL.seniorVault());
        JUNIOR_VAULT = TrancheVault(HOUSE_POOL.juniorVault());
        USDC = IERC20(address(ENGINE.USDC()));
        _BOUND_PLANNER = address(ENGINE.planner());
        _BOUND_PLANNER_CODEHASH = _BOUND_PLANNER.codehash;
    }

    function getSettlementAccounting()
        external
        view
        onlyMonitor
        returns (SettlementMonitorViewTypes.SettlementAccounting memory accounting)
    {
        return _buildSettlementAccounting();
    }

    function getOracleStatus(
        uint256 minimumPublishTime
    ) external view onlyMonitor returns (SettlementMonitorViewTypes.OracleStatus memory oracleStatus) {
        return _buildOracleStatus(minimumPublishTime);
    }

    function getSettlementHealth(
        uint256 queueFaultMask,
        uint256 queueDependencyFailureMask
    ) external view onlyMonitor returns (SettlementMonitorViewTypes.SettlementHealth memory health) {
        return _buildSettlementHealth(queueFaultMask, queueDependencyFailureMask);
    }

    function getObservableConfigDigest() external view onlyMonitor returns (bool available, bytes32 digest) {
        return _buildObservableConfigDigest();
    }

    function _buildSettlementAccounting()
        internal
        view
        returns (SettlementMonitorViewTypes.SettlementAccounting memory accounting)
    {
        address pool = address(HOUSE_POOL);
        bool readOk;
        bool poolReadsOk = true;
        (readOk, accounting.poolRawAssetsUsdc) = _readUint(pool, HousePool.rawAssets.selector);
        poolReadsOk = readOk;
        (readOk, accounting.poolAccountedAssetsUsdc) = _readUint(pool, bytes4(keccak256("accountedAssets()")));
        poolReadsOk = poolReadsOk && readOk;
        (readOk, accounting.poolTotalAssetsUsdc) = _readUint(pool, HousePool.totalAssets.selector);
        poolReadsOk = poolReadsOk && readOk;
        (readOk, accounting.poolExcessAssetsUsdc) = _readUint(pool, HousePool.excessAssets.selector);
        poolReadsOk = poolReadsOk && readOk;
        (readOk, accounting.storedSeniorPrincipalUsdc) = _readUint(pool, bytes4(keccak256("seniorPrincipal()")));
        poolReadsOk = poolReadsOk && readOk;
        (readOk, accounting.storedJuniorPrincipalUsdc) = _readUint(pool, bytes4(keccak256("juniorPrincipal()")));
        poolReadsOk = poolReadsOk && readOk;
        (readOk, accounting.storedSeniorHighWaterMarkUsdc) = _readUint(pool, bytes4(keccak256("seniorHighWaterMark()")));
        poolReadsOk = poolReadsOk && readOk;
        (readOk, accounting.pendingRecapitalizationUsdc) =
            _readUint(pool, bytes4(keccak256("pendingRecapitalizationUsdc()")));
        poolReadsOk = poolReadsOk && readOk;
        (readOk, accounting.pendingTradingRevenueUsdc) =
            _readUint(pool, bytes4(keccak256("pendingTradingRevenueUsdc()")));
        poolReadsOk = poolReadsOk && readOk;
        (readOk, accounting.unassignedAssetsUsdc) = _readUint(pool, bytes4(keccak256("unassignedAssets()")));
        poolReadsOk = poolReadsOk && readOk;
        (readOk, accounting.reservedSeniorDepositAssetsUsdc) =
            _readUint(pool, bytes4(keccak256("reservedSeniorDepositAssetsUsdc()")));
        poolReadsOk = poolReadsOk && readOk;
        (readOk, accounting.storedTerminalDeficitUsdc) = _readUint(pool, bytes4(keccak256("terminalDeficitUsdc()")));
        poolReadsOk = poolReadsOk && readOk;
        (readOk, accounting.lastReconcileTime) = _readUint(pool, bytes4(keccak256("lastReconcileTime()")));
        poolReadsOk = poolReadsOk && readOk;
        (readOk, accounting.lastSeniorCouponCheckpointTime) =
            _readUint(pool, bytes4(keccak256("lastSeniorCouponCheckpointTime()")));
        poolReadsOk = poolReadsOk && readOk;
        if (!poolReadsOk) {
            accounting.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Pool);
        }

        (bool liquidityOk, uint256[16] memory liquidity) =
            _readWords(pool, abi.encodeWithSelector(HousePool.getPoolLiquidityView.selector), 12);
        if (!liquidityOk || liquidity[9] > 1 || liquidity[10] > 1 || liquidity[11] > 1) {
            accounting.dependencyFailureMask |= _dependencyBit(
                SettlementMonitorViewTypes.Dependency.PoolAccountingPreview
            );
        } else {
            accounting.freeUsdc = liquidity[1];
            accounting.withdrawalReservedUsdc = liquidity[2];
            accounting.cachedPreviewTerminalDeficitUsdc = liquidity[8];
        }

        (bool pendingOk, uint256[16] memory pending) =
            _readWords(pool, abi.encodeWithSelector(HousePool.getPendingTrancheState.selector), 4);
        if (!pendingOk) {
            accounting.dependencyFailureMask |= _dependencyBit(
                SettlementMonitorViewTypes.Dependency.PoolAccountingPreview
            );
        } else {
            accounting.cachedPreviewSeniorPrincipalUsdc = pending[0];
            accounting.cachedPreviewJuniorPrincipalUsdc = pending[1];
            accounting.cachedPreviewMaxSeniorWithdrawUsdc = pending[2];
            accounting.cachedPreviewMaxJuniorWithdrawUsdc = pending[3];
            accounting.cachedPreviewAvailable = true;
        }

        (bool terminalOk, uint256[16] memory terminal) =
            _readWords(address(ENGINE), abi.encodeWithSelector(CfdEngine.terminalNavSnapshot.selector), 8);
        if (
            !terminalOk || terminal[0] > type(uint32).max || terminal[1] > type(uint64).max
                || terminal[5] > type(uint64).max || terminal[6] > 1 || terminal[7] > 1
        ) {
            accounting.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Engine);
        } else {
            accounting.terminalMarkPrice = uint32(terminal[0]);
            accounting.terminalMarkTime = uint64(terminal[1]);
            accounting.terminalLpPriceDeltaUsdc = int256(terminal[2]);
            accounting.totalTraderClaimsUsdc = terminal[3];
            accounting.maxDirectionalLiabilityUsdc = terminal[4];
            accounting.terminalBookVersion = uint64(terminal[5]);
            accounting.terminalHasOpenPositions = terminal[6] == 1;
            accounting.terminalDegradedMode = terminal[7] == 1;
            accounting.terminalSnapshotAvailable = true;
        }
    }

    function _buildOracleStatus(
        uint256 minimumPublishTime
    ) internal view returns (SettlementMonitorViewTypes.OracleStatus memory oracleStatus) {
        oracleStatus.oracle = address(ROUTER.pletherOracle());
        if (oracleStatus.oracle == address(0) || oracleStatus.oracle.code.length == 0) {
            oracleStatus.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Oracle);
            return oracleStatus;
        }

        {
            (bool engineOk, address oracleEngine) = _readAddress(oracleStatus.oracle, bytes4(keccak256("engine()")));
            (bool poolOk, address oraclePool) = _readAddress(oracleStatus.oracle, bytes4(keccak256("housePool()")));
            (bool pythOk, address pyth) = _readAddress(oracleStatus.oracle, bytes4(keccak256("pyth()")));
            (bool ratioOk, uint256 maximumRatio) =
                _readUint(oracleStatus.oracle, bytes4(keccak256("basketMaxConfidenceRatioBps()")));
            oracleStatus.pyth = pyth;
            oracleStatus.maximumConfidenceRatioBps = maximumRatio;
            if (
                !engineOk || !poolOk || oracleEngine != address(ENGINE) || oraclePool != address(HOUSE_POOL) || !ratioOk
            ) {
                oracleStatus.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Oracle);
            }
            if (!pythOk || pyth == address(0) || pyth.code.length == 0) {
                oracleStatus.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Pyth);
            }
        }

        uint256[16] memory words;
        {
            bool ok;
            bytes4 failureSelector;
            bytes32 failureHash;
            bool recognizedPolicyFailure;
            (ok, words, failureSelector, failureHash, recognizedPolicyFailure) =
                _readOracleSnapshot(oracleStatus.oracle);
            oracleStatus.failureSelector = failureSelector;
            oracleStatus.failureHash = failureHash;
            if (!ok) {
                if (!recognizedPolicyFailure) {
                    oracleStatus.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Oracle);
                }
                return oracleStatus;
            }
        }

        {
            (
                bool enginePolicyOk,
                bool poolPolicyOk,
                uint256 capPrice,
                uint256 expectedMaxStaleness,
                bool frozen,
                bool fadWindow
            ) = _poolReconcilePolicy();
            if (!enginePolicyOk) {
                oracleStatus.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Engine);
            }
            if (!poolPolicyOk) {
                oracleStatus.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Pool);
            }
            if (!enginePolicyOk || !poolPolicyOk) {
                return oracleStatus;
            }
            if (
                words[0] == 0 || words[1] == 0 || words[0] != words[1] || words[0] > capPrice
                    || words[2] > type(uint64).max || words[2] > block.timestamp
                    || block.timestamp - words[2] > expectedMaxStaleness || words[3] != 0
                    || words[4] != expectedMaxStaleness || words[5] != 0 || words[6] > 1 || words[7] > 1
                    || (words[6] == 1) != frozen || (words[7] == 1) != fadWindow
            ) {
                oracleStatus.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Oracle);
                oracleStatus.failureHash = keccak256(abi.encode(words));
                if (oracleStatus.failureHash == bytes32(0)) {
                    oracleStatus.failureHash = bytes32(uint256(1));
                }
                return oracleStatus;
            }
        }

        oracleStatus.price = words[0];
        oracleStatus.markPrice = words[1];
        oracleStatus.publishTime = uint64(words[2]);
        oracleStatus.maxStaleness = words[4];
        oracleStatus.closeOnly = words[5] == 1;
        oracleStatus.oracleFrozen = words[6] == 1;
        oracleStatus.fadWindow = words[7] == 1;
        oracleStatus.confidence = words[8];
        oracleStatus.readSucceeded = true;
        oracleStatus.policyValid = true;
        oracleStatus.publishTimeMeetsEpochFloor = oracleStatus.publishTime >= minimumPublishTime;
    }

    function _readOracleSnapshot(
        address oracle
    )
        internal
        view
        returns (
            bool ok,
            uint256[16] memory words,
            bytes4 failureSelector,
            bytes32 failureHash,
            bool recognizedPolicyFailure
        )
    {
        bytes4 selector = IPletherOracle.getLatestPoolReconcilePrice.selector;
        uint256 returnSize;
        uint256 failureMode;
        uint256 failureArg1;
        bool callSucceeded;
        assembly ("memory-safe") {
            let input := mload(0x40)
            mstore(input, selector)
            callSucceeded := staticcall(STATIC_READ_GAS, oracle, input, 4, words, 288)
            ok := callSucceeded
            returnSize := returndatasize()
            if iszero(and(ok, eq(returnSize, 288))) {
                ok := 0
                let copySize := returnSize
                if gt(copySize, 256) { copySize := 256 }
                mstore(input, returnSize)
                returndatacopy(add(input, 32), 0, copySize)
                failureHash := keccak256(input, add(32, copySize))
                if iszero(failureHash) { failureHash := 1 }
                if gt(returnSize, 3) { failureSelector := mload(add(input, 32)) }
                if gt(returnSize, 35) { failureMode := mload(add(input, 36)) }
                if gt(returnSize, 67) { failureArg1 := mload(add(input, 68)) }
            }
        }
        if (!ok && !callSucceeded) {
            recognizedPolicyFailure =
                _isRecognizedOraclePolicyFailure(failureSelector, returnSize, failureMode, failureArg1);
        }
    }

    function _isRecognizedOraclePolicyFailure(
        bytes4 selector,
        uint256 returnSize,
        uint256 failureArg0,
        uint256 failureArg1
    ) internal pure returns (bool) {
        if (returnSize == 164) {
            return selector == IPletherOracle.PletherOracle__StalePrice.selector
                && failureArg0 == uint256(IPletherOracle.PriceMode.PoolReconcile);
        }
        if (returnSize == 132) {
            return (selector == IPletherOracle.PletherOracle__BasketConfidenceTooWide.selector
                    || selector == IPletherOracle.PletherOracle__PublishTimeDivergence.selector)
                && failureArg0 == uint256(IPletherOracle.PriceMode.PoolReconcile);
        }
        if (returnSize == 68) {
            if (selector == IPletherOracle.PletherOracle__PriceOutOfOrder.selector) {
                return failureArg0 <= type(uint64).max && failureArg1 <= type(uint64).max;
            }
            if (selector == IPletherOracle.PletherOracle__InvalidPrice.selector) {
                return _isCanonicalInt64(failureArg1);
            }
            return false;
        }
        return returnSize == 4 && selector == IPletherOracle.PletherOracle__ZeroBasketPrice.selector;
    }

    function _isCanonicalInt64(
        uint256 word
    ) internal pure returns (bool canonical) {
        assembly ("memory-safe") {
            canonical := eq(word, signextend(7, word))
        }
    }

    function _poolReconcilePolicy()
        internal
        view
        returns (bool engineOk, bool poolOk, uint256 capPrice, uint256 maxStaleness, bool frozen, bool fadWindow)
    {
        bool readOk;
        uint256 liveAge;
        uint256 frozenAge;
        uint256 poolAge;
        (readOk, capPrice) = _readUint(address(ENGINE), bytes4(keccak256("CAP_PRICE()")));
        engineOk = readOk;
        (readOk, frozen) = _readBool(address(ENGINE), bytes4(keccak256("isOracleFrozen()")));
        engineOk = engineOk && readOk;
        (readOk, fadWindow) = _readBool(address(ENGINE), bytes4(keccak256("isFadWindow()")));
        engineOk = engineOk && readOk;
        (readOk, liveAge) = _readUint(address(ENGINE), bytes4(keccak256("engineMarkStalenessLimit()")));
        engineOk = engineOk && readOk;
        (readOk, frozenAge) = _readUint(address(ENGINE), bytes4(keccak256("fadMaxStaleness()")));
        engineOk = engineOk && readOk;
        (poolOk, poolAge) = _readUint(address(HOUSE_POOL), bytes4(keccak256("markStalenessLimit()")));
        if (!engineOk || !poolOk) {
            return (engineOk, poolOk, 0, 0, false, false);
        }
        maxStaleness = frozen ? frozenAge : (poolAge == 0 || liveAge < poolAge ? liveAge : poolAge);
    }

    function _buildSettlementHealth(
        uint256 queueFaultMask,
        uint256 queueDependencyFailureMask
    ) internal view returns (SettlementMonitorViewTypes.SettlementHealth memory health) {
        health.criticalFaultMask = queueFaultMask;
        health.dependencyFailureMask = queueDependencyFailureMask;
        (uint256 bindingFaults, uint256 bindingFailures) = _validateRuntimeBindings();
        health.criticalFaultMask |= bindingFaults;
        health.dependencyFailureMask |= bindingFailures;
        _populateNavHealth(health);
        _populateCustodyHealth(health);
        _populateSeniorHwmHealth(health);
        if (health.criticalFaultMask != 0) {
            health.state = SettlementMonitorViewTypes.HealthState.Critical;
        } else if (health.dependencyFailureMask != 0) {
            health.state = SettlementMonitorViewTypes.HealthState.Unknown;
        } else {
            health.state = SettlementMonitorViewTypes.HealthState.Healthy;
        }
    }

    function _validateRuntimeBindings() internal view returns (uint256 faults, uint256 failures) {
        uint256 engineComponents = _plannerBindingStatus()
            | _bindingStatus(address(ENGINE), bytes4(keccak256("settlementSidecar()")), bytes4(keccak256("ENGINE()")))
            | _bindingStatus(address(ENGINE), bytes4(keccak256("admin()")), bytes4(keccak256("engine()")));
        uint256 routerComponents =
            _bindingStatus(address(ROUTER), bytes4(keccak256("admin()")), bytes4(keccak256("router()")));
        if ((engineComponents & 1) != 0) {
            failures |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Engine);
        }
        if ((routerComponents & 1) != 0) {
            failures |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Router);
        }
        if ((engineComponents & 2) != 0 || (routerComponents & 2) != 0) {
            faults |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.BindingMismatch);
        }
        if (
            address(ROUTER.engine()) != address(ENGINE) || ENGINE.orderRouter() != address(ROUTER)
                || address(ENGINE.pool()) != address(HOUSE_POOL)
                || address(ENGINE.clearinghouse()) != address(CLEARINGHOUSE)
                || address(ENGINE.terminalNavBook()) != address(TERMINAL_NAV_BOOK)
                || address(ENGINE.USDC()) != address(USDC) || address(HOUSE_POOL.ENGINE()) != address(ENGINE)
                || address(HOUSE_POOL.USDC()) != address(USDC)
                || address(HOUSE_POOL.ENGINE_PROTOCOL_LENS()) != address(ENGINE_PROTOCOL_LENS)
                || HOUSE_POOL.seniorVault() != address(SENIOR_VAULT)
                || HOUSE_POOL.juniorVault() != address(JUNIOR_VAULT) || CLEARINGHOUSE.engine() != address(ENGINE)
                || CLEARINGHOUSE.settlementAsset() != address(USDC) || TERMINAL_NAV_BOOK.ENGINE() != address(ENGINE)
                || address(ENGINE_PROTOCOL_LENS.engineContract()) != address(ENGINE)
                || address(SENIOR_VAULT.POOL()) != address(HOUSE_POOL) || !SENIOR_VAULT.IS_SENIOR()
                || SENIOR_VAULT.asset() != address(USDC) || address(JUNIOR_VAULT.POOL()) != address(HOUSE_POOL)
                || JUNIOR_VAULT.IS_SENIOR() || JUNIOR_VAULT.asset() != address(USDC)
        ) {
            faults |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.BindingMismatch);
        }

        address oracle = address(ROUTER.pletherOracle());
        if (oracle == address(0) || oracle.code.length == 0) {
            failures |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Oracle);
            return (faults, failures);
        }
        (bool engineOk, address oracleEngine) = _readAddress(oracle, bytes4(keccak256("engine()")));
        (bool poolOk, address oraclePool) = _readAddress(oracle, bytes4(keccak256("housePool()")));
        (bool pythOk, address pyth) = _readAddress(oracle, bytes4(keccak256("pyth()")));
        if (!engineOk || !poolOk) {
            failures |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Oracle);
        } else if (oracleEngine != address(ENGINE) || oraclePool != address(HOUSE_POOL)) {
            faults |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.BindingMismatch);
        }
        if (!pythOk || pyth == address(0) || pyth.code.length == 0) {
            failures |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Pyth);
        }
    }

    /// @dev Probes deterministic carry-index and market-calendar operations used by LP settlement. Equal carry
    ///      timestamps preserve the stored index; a same-day override must activate both calendar flags.
    function _plannerBindingStatus() internal view returns (uint256 status) {
        (bool plannerOk, address planner) = _readAddress(address(ENGINE), bytes4(keccak256("planner()")));
        if (!plannerOk) {
            return 1;
        }
        if (planner == address(0) || planner.code.length == 0) {
            return 3;
        }
        if (planner != _BOUND_PLANNER || planner.codehash != _BOUND_PLANNER_CODEHASH) {
            return 2;
        }
        return _plannerSemanticsValid(planner) ? 0 : 2;
    }

    function _plannerSemanticsValid(
        address planner
    ) internal view returns (bool valid) {
        bytes4 carrySelector =
            bytes4(keccak256("computeCurrentCarryIndex(uint256,uint64,uint256,uint256,uint256,uint256)"));
        bytes4 calendarSelector = bytes4(keccak256("marketCalendarStatus(uint256,bool,bool,uint256)"));
        assembly ("memory-safe") {
            let input := mload(0x40)
            mstore(input, carrySelector)
            mstore(add(input, 4), 7)
            mstore(add(input, 36), 11)
            mstore(add(input, 68), 11)
            mstore(add(input, 100), 13)
            mstore(add(input, 132), 17)
            mstore(add(input, 164), 19)
            valid := staticcall(STATIC_READ_GAS, planner, input, 196, input, 32)
            valid := and(valid, and(eq(returndatasize(), 32), eq(mload(input), 7)))
            if valid {
                mstore(input, calendarSelector)
                mstore(add(input, 4), 0)
                mstore(add(input, 36), 1)
                mstore(add(input, 68), 0)
                mstore(add(input, 100), 0)
                valid := staticcall(STATIC_READ_GAS, planner, input, 132, input, 64)
                valid := and(
                    valid,
                    and(eq(returndatasize(), 64), and(eq(mload(input), 1), eq(mload(add(input, 32)), 1)))
                )
            }
        }
    }

    /// @dev Bit 0 marks unavailable component evidence; bit 1 marks a missing, code-less, or mismatched child.
    function _bindingStatus(
        address host,
        bytes4 childSelector,
        bytes4 parentSelector
    ) internal view returns (uint256 status) {
        (bool childOk, address child) = _readAddress(host, childSelector);
        if (!childOk) {
            return 1;
        }
        if (child == address(0) || child.code.length == 0) {
            return 3;
        }
        if (parentSelector == bytes4(0)) {
            return 0;
        }
        (bool parentOk, address parent) = _readAddress(child, parentSelector);
        if (!parentOk) {
            return 1;
        }
        return parent == host ? 0 : 2;
    }

    function _populateNavHealth(
        SettlementMonitorViewTypes.SettlementHealth memory health
    ) internal view {
        uint256[16] memory book;
        uint256[16] memory bull;
        uint256[16] memory bear;
        {
            bool bookOk;
            bool bullOk;
            bool bearOk;
            bool sizeOk;
            bool engineCapOk;
            (bookOk, book) = _readWords(
                address(TERMINAL_NAV_BOOK), abi.encodeWithSelector(ITerminalNavBookV2.bookState.selector), 8
            );
            (bullOk, bull) =
                _readWords(address(ENGINE), abi.encodeWithSelector(bytes4(keccak256("sides(uint256)")), 0), 4);
            (bearOk, bear) =
                _readWords(address(ENGINE), abi.encodeWithSelector(bytes4(keccak256("sides(uint256)")), 1), 4);
            (sizeOk, health.sizeQuantum) =
                _readUint(address(TERMINAL_NAV_BOOK), ITerminalNavBookV2.SIZE_QUANTUM.selector);
            (engineCapOk, health.engineCapPrice) = _readUint(address(ENGINE), bytes4(keccak256("CAP_PRICE()")));
            if (!bookOk || !bullOk || !bearOk || !sizeOk || !engineCapOk) {
                health.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.TerminalNavBook)
                | _dependencyBit(SettlementMonitorViewTypes.Dependency.Engine);
                return;
            }
        }
        if (
            book[0] > type(uint32).max || book[1] > type(uint64).max || book[2] > type(uint64).max
                || book[3] > type(uint112).max || book[4] > type(uint144).max || book[5] > type(uint144).max
        ) {
            health.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.TerminalNavBook);
            return;
        }
        {
            (bool bookCapOk, uint256 bookCapGetter) =
                _readUint(address(TERMINAL_NAV_BOOK), ITerminalNavBookV2.CAP_PRICE.selector);
            if (!bookCapOk) {
                health.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.TerminalNavBook)
                | _dependencyBit(SettlementMonitorViewTypes.Dependency.Engine);
                return;
            }
            if (book[0] != bookCapGetter || book[0] != health.engineCapPrice) {
                health.criticalFaultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.NavCapMismatch);
            }
        }

        health.bookCapPrice = book[0];
        health.bookActiveCurveCount = book[1];
        health.bookTotalLots = book[3];
        health.bookTotalEntryCostUsdcAtoms = book[4];
        health.bookTotalEffectiveCapUsdcAtoms = book[5];
        health.engineBullOpenInterest = bull[1];
        health.engineBearOpenInterest = bear[1];
        health.engineBullEntryNotional = bull[2];
        health.engineBearEntryNotional = bear[2];

        if (health.sizeQuantum == 0) {
            health.criticalFaultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.ArithmeticDomain);
        } else {
            if (bull[1] % health.sizeQuantum != 0 || bear[1] % health.sizeQuantum != 0) {
                health.criticalFaultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.NavLotsMismatch);
            }
            if (bull[2] % health.sizeQuantum != 0 || bear[2] % health.sizeQuantum != 0) {
                health.criticalFaultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.NavEntryBasisMismatch);
            }
        }
        if (
            (bull[1] == 0 && (bull[0] != 0 || bull[2] != 0 || bull[3] != 0))
                || (bear[1] == 0 && (bear[0] != 0 || bear[2] != 0 || bear[3] != 0))
        ) {
            health.criticalFaultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.NavActiveEmptyMismatch);
        }
        uint256 totalOi;
        {
            bool oiOk;
            bool lotsOk;
            bool entryOk;
            bool basisOk;
            uint256 representedOi;
            uint256 totalEntry;
            uint256 representedEntry;
            (oiOk, totalOi) = _safeAdd(bull[1], bear[1]);
            (lotsOk, representedOi) = _safeMul(book[3], health.sizeQuantum);
            (entryOk, totalEntry) = _safeAdd(bull[2], bear[2]);
            (basisOk, representedEntry) = _safeMul(book[4], health.sizeQuantum);
            if (!oiOk || !lotsOk || !entryOk || !basisOk) {
                health.criticalFaultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.ArithmeticDomain);
            } else {
                if (representedOi != totalOi) {
                    health.criticalFaultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.NavLotsMismatch);
                }
                if (representedEntry != totalEntry) {
                    health.criticalFaultMask |= _criticalBit(
                        SettlementMonitorViewTypes.CriticalFault.NavEntryBasisMismatch
                    );
                }
                if ((book[1] == 0) != (totalOi == 0) || book[1] > book[3] || book[2] < book[1]) {
                    health.criticalFaultMask |= _criticalBit(
                        SettlementMonitorViewTypes.CriticalFault.NavActiveEmptyMismatch
                    );
                }
            }
        }

        (bool markOk, uint256 markPrice) = _readUint(address(ENGINE), bytes4(keccak256("lastMarkPrice()")));
        (bool markTimeOk, uint256 markTime) = _readUint(address(ENGINE), bytes4(keccak256("lastMarkTime()")));
        if (!markOk || !markTimeOk) {
            health.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Engine);
        } else {
            if (markPrice > health.engineCapPrice || (totalOi != 0 && (markPrice == 0 || markTime == 0))) {
                health.criticalFaultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.NavMarkDomain);
            }
            if (markTime > block.timestamp) {
                health.criticalFaultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.FutureCachedMark);
            }
            _validateTerminalSnapshotParity(health, book[2], markPrice, markTime, bull[0], bear[0]);
        }
    }

    function _validateTerminalSnapshotParity(
        SettlementMonitorViewTypes.SettlementHealth memory health,
        uint256 bookVersion,
        uint256 markPrice,
        uint256 markTime,
        uint256 bullMaxProfit,
        uint256 bearMaxProfit
    ) internal view {
        (bool terminalOk, uint256[16] memory terminal) =
            _readWords(address(ENGINE), abi.encodeWithSelector(CfdEngine.terminalNavSnapshot.selector), 8);
        (bool claimsOk, uint256 claims) = _readUint(address(ENGINE), bytes4(keccak256("totalTraderClaimBalanceUsdc()")));
        (bool degradedOk, bool degraded) = _readBool(address(ENGINE), bytes4(keccak256("degradedMode()")));
        if (
            !terminalOk || !claimsOk || !degradedOk || terminal[0] > type(uint32).max || terminal[1] > type(uint64).max
                || terminal[5] > type(uint64).max || terminal[6] > 1 || terminal[7] > 1
        ) {
            health.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Engine);
            return;
        }
        uint256 maxLiability = bullMaxProfit > bearMaxProfit ? bullMaxProfit : bearMaxProfit;
        bool expectedOpen = health.engineBullOpenInterest != 0 || health.engineBearOpenInterest != 0;
        if (
            terminal[0] != markPrice || terminal[1] != markTime || terminal[3] != claims || terminal[4] != maxLiability
                || terminal[5] != bookVersion || (terminal[6] == 1) != expectedOpen || (terminal[7] == 1) != degraded
        ) {
            health.criticalFaultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.NavSnapshotMismatch);
        }
    }

    function _populateCustodyHealth(
        SettlementMonitorViewTypes.SettlementHealth memory health
    ) internal view {
        bool rawOk;
        bool accountedOk;
        (rawOk, health.poolRawAssetsUsdc) = _readBalance(address(HOUSE_POOL));
        (accountedOk, health.poolAccountedAssetsUsdc) =
            _readUint(address(HOUSE_POOL), bytes4(keccak256("accountedAssets()")));
        (bool totalOk, uint256 totalAssets) = _readUint(address(HOUSE_POOL), HousePool.totalAssets.selector);
        if (!rawOk || !accountedOk || !totalOk) {
            health.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Pool);
        } else {
            health.poolCustodyDeficitUsdc =
                _saturatingDifference(health.poolAccountedAssetsUsdc, health.poolRawAssetsUsdc);
            health.poolCustodySurplusUsdc =
                _saturatingDifference(health.poolRawAssetsUsdc, health.poolAccountedAssetsUsdc);
            uint256 expectedTotal = health.poolRawAssetsUsdc < health.poolAccountedAssetsUsdc
                ? health.poolRawAssetsUsdc
                : health.poolAccountedAssetsUsdc;
            if (health.poolCustodyDeficitUsdc != 0) {
                health.criticalFaultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.PoolCustodyDeficit);
            }
            if (totalAssets != expectedTotal) {
                health.criticalFaultMask |= _criticalBit(
                    SettlementMonitorViewTypes.CriticalFault.PoolAssetBoundaryMismatch
                );
            }
        }

        (bool seniorPendingOk, uint256 seniorPendingAssets) = _populateVaultCustody(health, address(SENIOR_VAULT), true);
        _populateVaultCustody(health, address(JUNIOR_VAULT), false);
        (bool reservationOk, uint256 reservation) =
            _readUint(address(HOUSE_POOL), bytes4(keccak256("reservedSeniorDepositAssetsUsdc()")));
        if (!reservationOk) {
            health.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Pool);
        } else if (seniorPendingOk && reservation > seniorPendingAssets) {
            health.criticalFaultMask |= _criticalBit(
                SettlementMonitorViewTypes.CriticalFault.SeniorReservationExceedsEscrow
            );
        }
        (bool tradingOk, bool tradingActive) = _readBool(address(HOUSE_POOL), bytes4(keccak256("isTradingActive()")));
        if (!tradingOk) {
            health.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Pool);
        }
        _validateSeedFloor(health, address(SENIOR_VAULT), true, tradingOk && tradingActive);
        _validateSeedFloor(health, address(JUNIOR_VAULT), false, tradingOk && tradingActive);
    }

    function _populateVaultCustody(
        SettlementMonitorViewTypes.SettlementHealth memory health,
        address vault,
        bool isSenior
    ) internal view returns (bool pendingDepositOk, uint256 pendingDepositAssets) {
        bool readsOk;
        bool requirementsOk;
        uint256 requiredAssets;
        uint256 requiredShares;
        {
            bool readOk;
            uint256 withdrawalEscrowAssets;
            (pendingDepositOk, pendingDepositAssets) =
                _readUint(vault, ISettlementMonitorSidecarVaultView.pendingDepositEscrowAssets.selector);
            (readOk, withdrawalEscrowAssets) =
                _readUint(vault, ISettlementMonitorSidecarVaultView.withdrawalEscrowAssets.selector);
            readsOk = pendingDepositOk && readOk;
            (requirementsOk, requiredAssets) = _safeAdd(pendingDepositAssets, withdrawalEscrowAssets);
        }
        {
            bool readOk;
            uint256 pendingRedeemEscrowShares;
            uint256 depositClaimEscrowShares;
            (readOk, pendingRedeemEscrowShares) =
                _readUint(vault, ISettlementMonitorSidecarVaultView.pendingRedeemEscrowShares.selector);
            readsOk = readsOk && readOk;
            (readOk, depositClaimEscrowShares) =
                _readUint(vault, ISettlementMonitorSidecarVaultView.depositClaimEscrowShares.selector);
            readsOk = readsOk && readOk;
            (readOk, requiredShares) = _safeAdd(pendingRedeemEscrowShares, depositClaimEscrowShares);
            requirementsOk = requirementsOk && readOk;
        }
        {
            (bool receiverOk, address receiver) =
                _readAddress(vault, ISettlementMonitorSidecarVaultView.seedReceiver.selector);
            readsOk = readsOk && receiverOk;
            if (receiverOk && receiver == vault) {
                (bool seedFloorOk, uint256 seedFloor) =
                    _readUint(vault, ISettlementMonitorSidecarVaultView.seedShareFloor.selector);
                readsOk = readsOk && seedFloorOk;
                if (seedFloorOk && requirementsOk) {
                    (requirementsOk, requiredShares) = _safeAdd(requiredShares, seedFloor);
                }
            }
        }
        (bool assetsOk, uint256 actualAssets) = _readBalance(vault);
        (bool sharesOk, uint256 actualShares) = _readTokenBalance(vault, vault);
        if (!readsOk) {
            health.dependencyFailureMask |= _dependencyBit(
                isSenior
                    ? SettlementMonitorViewTypes.Dependency.SeniorVault
                    : SettlementMonitorViewTypes.Dependency.JuniorVault
            );
            return (pendingDepositOk, pendingDepositAssets);
        }
        if (!requirementsOk) {
            health.criticalFaultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.ArithmeticDomain);
            return (pendingDepositOk, pendingDepositAssets);
        }
        if (!assetsOk || !sharesOk) {
            health.dependencyFailureMask |= _dependencyBit(
                isSenior
                    ? SettlementMonitorViewTypes.Dependency.SeniorVault
                    : SettlementMonitorViewTypes.Dependency.JuniorVault
            );
            return (pendingDepositOk, pendingDepositAssets);
        }
        if (isSenior) {
            health.seniorRequiredAssetEscrowUsdc = requiredAssets;
            health.seniorActualAssetEscrowUsdc = actualAssets;
            health.seniorRequiredShareEscrow = requiredShares;
            health.seniorActualShareEscrow = actualShares;
            if (actualAssets < requiredAssets) {
                health.criticalFaultMask |= _criticalBit(
                    SettlementMonitorViewTypes.CriticalFault.SeniorAssetEscrowDeficit
                );
            }
            if (actualShares < requiredShares) {
                health.criticalFaultMask |= _criticalBit(
                    SettlementMonitorViewTypes.CriticalFault.SeniorShareEscrowDeficit
                );
            }
        } else {
            health.juniorRequiredAssetEscrowUsdc = requiredAssets;
            health.juniorActualAssetEscrowUsdc = actualAssets;
            health.juniorRequiredShareEscrow = requiredShares;
            health.juniorActualShareEscrow = actualShares;
            if (actualAssets < requiredAssets) {
                health.criticalFaultMask |= _criticalBit(
                    SettlementMonitorViewTypes.CriticalFault.JuniorAssetEscrowDeficit
                );
            }
            if (actualShares < requiredShares) {
                health.criticalFaultMask |= _criticalBit(
                    SettlementMonitorViewTypes.CriticalFault.JuniorShareEscrowDeficit
                );
            }
        }
        return (pendingDepositOk, pendingDepositAssets);
    }

    function _validateSeedFloor(
        SettlementMonitorViewTypes.SettlementHealth memory health,
        address vault,
        bool isSenior,
        bool tradingActive
    ) internal view {
        bool readOk;
        bool vaultReadsOk;
        bool seedFlagOk;
        bool seedInitialized;
        address receiver;
        uint256 floor;
        uint256 totalSupply;
        uint256 balance;
        (readOk, receiver) = _readAddress(vault, ISettlementMonitorSidecarVaultView.seedReceiver.selector);
        vaultReadsOk = readOk;
        (readOk, floor) = _readUint(vault, ISettlementMonitorSidecarVaultView.seedShareFloor.selector);
        vaultReadsOk = vaultReadsOk && readOk;
        (readOk, totalSupply) = _readUint(vault, IERC20.totalSupply.selector);
        vaultReadsOk = vaultReadsOk && readOk;
        (seedFlagOk, seedInitialized) = _readBool(
            address(HOUSE_POOL),
            isSenior ? bytes4(keccak256("seniorSeedInitialized()")) : bytes4(keccak256("juniorSeedInitialized()"))
        );
        if (receiver == address(0)) {
            readOk = true;
            balance = 0;
        } else {
            (readOk, balance) = _readTokenBalance(vault, receiver);
        }
        vaultReadsOk = vaultReadsOk && readOk;
        if (!seedFlagOk) {
            health.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Pool);
        }
        if (!vaultReadsOk) {
            health.dependencyFailureMask |= _dependencyBit(
                isSenior
                    ? SettlementMonitorViewTypes.Dependency.SeniorVault
                    : SettlementMonitorViewTypes.Dependency.JuniorVault
            );
        }
        if (!vaultReadsOk || !seedFlagOk) {
            return;
        }
        bool hasSeedReceiver = receiver != address(0);
        bool hasSeedFloor = floor != 0;
        bool valid = hasSeedReceiver == hasSeedFloor && seedInitialized == hasSeedReceiver;
        if (tradingActive && !seedInitialized) {
            valid = false;
        }
        if (seedInitialized) {
            valid = valid && balance >= floor && totalSupply >= floor;
        }
        if (!valid) {
            health.criticalFaultMask |= _criticalBit(
                isSenior
                    ? SettlementMonitorViewTypes.CriticalFault.SeniorSeedFloor
                    : SettlementMonitorViewTypes.CriticalFault.JuniorSeedFloor
            );
        }
    }

    function _populateSeniorHwmHealth(
        SettlementMonitorViewTypes.SettlementHealth memory health
    ) internal view {
        bool principalOk;
        bool hwmOk;
        (principalOk, health.seniorPrincipalUsdc) =
            _readUint(address(HOUSE_POOL), bytes4(keccak256("seniorPrincipal()")));
        (hwmOk, health.seniorHighWaterMarkUsdc) =
            _readUint(address(HOUSE_POOL), bytes4(keccak256("seniorHighWaterMark()")));
        if (!principalOk || !hwmOk) {
            health.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Pool);
            return;
        }
        health.seniorImpairmentUsdc = _saturatingDifference(health.seniorHighWaterMarkUsdc, health.seniorPrincipalUsdc);
        health.seniorPrincipalAboveHighWaterMarkUsdc =
            _saturatingDifference(health.seniorPrincipalUsdc, health.seniorHighWaterMarkUsdc);
        health.protectedSeniorExposureUsdc = health.seniorPrincipalUsdc > health.seniorHighWaterMarkUsdc
            ? health.seniorPrincipalUsdc
            : health.seniorHighWaterMarkUsdc;
    }

    function _readBalance(
        address account
    ) internal view returns (bool ok, uint256 balance) {
        return _readTokenBalance(address(USDC), account);
    }

    function _readTokenBalance(
        address token,
        address account
    ) internal view returns (bool ok, uint256 balance) {
        uint256[16] memory words;
        (ok, words) = _readWords(token, abi.encodeWithSelector(IERC20.balanceOf.selector, account), 1);
        balance = words[0];
    }

    function _buildObservableConfigDigest() internal view returns (bool available, bytes32 digest) {
        (bool wiringOk, bytes32 wiringDigest) = _wiringConfigDigest();
        (bool epochOk, bytes32 epochDigest) = _epochConfigDigest();
        (bool policyOk, bytes32 policyDigest) = _policyConfigDigest();
        (bool seedOk, bytes32 seedDigest) = _seedConfigDigest();
        available = wiringOk && epochOk && policyOk && seedOk;
        if (!available) {
            return (false, bytes32(0));
        }
        digest = keccak256(
            abi.encode(
                CONFIG_DOMAIN,
                CONFIG_SCHEMA_VERSION,
                block.chainid,
                MONITOR,
                wiringDigest,
                epochDigest,
                policyDigest,
                seedDigest
            )
        );
    }

    function _wiringConfigDigest() internal view returns (bool available, bytes32 digest) {
        (uint256 bindingFaults, uint256 bindingFailures) = _validateRuntimeBindings();
        if (bindingFaults != 0 || bindingFailures != 0) {
            return (false, bytes32(0));
        }
        address oracle = address(ROUTER.pletherOracle());
        if (oracle == address(0) || oracle.code.length == 0) {
            return (false, bytes32(0));
        }
        (bool oracleEngineOk, address oracleEngine) = _readAddress(oracle, bytes4(keccak256("engine()")));
        (bool oraclePoolOk, address oraclePool) = _readAddress(oracle, bytes4(keccak256("housePool()")));
        (bool pythOk, address pyth) = _readAddress(oracle, bytes4(keccak256("pyth()")));
        if (
            !oracleEngineOk || !oraclePoolOk || !pythOk || oracleEngine != address(ENGINE)
                || oraclePool != address(HOUSE_POOL) || pyth == address(0) || pyth.code.length == 0
        ) {
            return (false, bytes32(0));
        }
        bytes32 engineDigest = keccak256(
            abi.encode(
                address(ENGINE),
                address(ENGINE_PROTOCOL_LENS),
                address(CLEARINGHOUSE),
                address(TERMINAL_NAV_BOOK),
                address(ENGINE.planner()),
                address(ENGINE.settlementSidecar()),
                ENGINE.admin()
            )
        );
        bytes32 poolDigest =
            keccak256(abi.encode(address(HOUSE_POOL), address(SENIOR_VAULT), address(JUNIOR_VAULT), address(USDC)));
        bytes32 oracleDigest = keccak256(abi.encode(oracle, oracle.codehash, pyth, pyth.codehash));
        digest = keccak256(abi.encode(address(ROUTER), ROUTER.admin(), engineDigest, poolDigest, oracleDigest));
        available = true;
    }

    function _epochConfigDigest() internal view returns (bool available, bytes32 digest) {
        (bool durationOk, uint256 duration) = _readUint(address(HOUSE_POOL), bytes4(keccak256("LP_EPOCH_DURATION()")));
        (bool phaseCapOk, uint256 phaseCap) =
            _readUint(address(HOUSE_POOL), bytes4(keccak256("MAX_LP_EPOCHS_PER_PHASE()")));
        (bool minimumOk, uint256 minimum) =
            _readUint(address(HOUSE_POOL), bytes4(keccak256("MIN_TRANCHE_DEPOSIT_USDC()")));
        (bool seniorCutoffOk, uint256 seniorCutoff) =
            _readUint(address(SENIOR_VAULT), bytes4(keccak256("LP_REQUEST_CUTOFF_DURATION()")));
        (bool juniorCutoffOk, uint256 juniorCutoff) =
            _readUint(address(JUNIOR_VAULT), bytes4(keccak256("LP_REQUEST_CUTOFF_DURATION()")));
        (bool seniorCooldownOk, uint256 seniorCooldown) =
            _readUint(address(SENIOR_VAULT), bytes4(keccak256("DEPOSIT_COOLDOWN()")));
        (bool juniorCooldownOk, uint256 juniorCooldown) =
            _readUint(address(JUNIOR_VAULT), bytes4(keccak256("DEPOSIT_COOLDOWN()")));
        available = durationOk && phaseCapOk && minimumOk && seniorCutoffOk && juniorCutoffOk && seniorCooldownOk
            && juniorCooldownOk;
        if (!available) {
            return (false, bytes32(0));
        }
        digest = keccak256(
            abi.encode(duration, phaseCap, minimum, seniorCutoff, juniorCutoff, seniorCooldown, juniorCooldown)
        );
    }

    function _policyConfigDigest() internal view returns (bool available, bytes32 digest) {
        (bool engineOk, bytes32 engineDigest) = _enginePolicyConfigDigest();
        (bool oracleOk, bytes32 oracleDigest) = _oraclePolicyConfigDigest(address(ROUTER.pletherOracle()));
        (bool poolOk, bytes32 poolDigest) = _poolPolicyConfigDigest();
        available = engineOk && oracleOk && poolOk;
        if (!available) {
            return (false, bytes32(0));
        }
        digest = keccak256(abi.encode(engineDigest, oracleDigest, poolDigest));
    }

    function _enginePolicyConfigDigest() internal view returns (bool available, bytes32 digest) {
        (bool riskOk, uint256[16] memory risk) =
            _readWords(address(ENGINE), abi.encodeWithSelector(CfdEngine.riskParams.selector), 10);
        (bool engineCapOk, uint256 engineCap) = _readUint(address(ENGINE), bytes4(keccak256("CAP_PRICE()")));
        (bool sizeOk, uint256 sizeQuantum) =
            _readUint(address(TERMINAL_NAV_BOOK), ITerminalNavBookV2.SIZE_QUANTUM.selector);
        (bool liveAgeOk, uint256 liveAge) = _readUint(address(ENGINE), bytes4(keccak256("engineMarkStalenessLimit()")));
        (bool frozenAgeOk, uint256 frozenAge) = _readUint(address(ENGINE), bytes4(keccak256("fadMaxStaleness()")));
        (bool fadRunwayOk, uint256 fadRunway) = _readUint(address(ENGINE), bytes4(keccak256("fadRunwaySeconds()")));
        (bool settlementBufferOk, uint256 settlementBufferBps) =
            _readUint(address(ENGINE), bytes4(keccak256("settlementBufferBps()")));
        available = riskOk && engineCapOk && sizeOk && liveAgeOk && frozenAgeOk && fadRunwayOk && settlementBufferOk;
        if (!available) {
            return (false, bytes32(0));
        }
        digest =
            keccak256(abi.encode(engineCap, sizeQuantum, liveAge, frozenAge, fadRunway, risk[5], settlementBufferBps));
    }

    function _oraclePolicyConfigDigest(
        address oracle
    ) internal view returns (bool available, bytes32 digest) {
        (bool oracleDivergenceOk, uint256 oracleDivergence) =
            _readUint(oracle, bytes4(keccak256("orderExecutionStalenessLimit()")));
        (bool confidenceOk, uint256 confidenceRatio) =
            _readUint(oracle, bytes4(keccak256("basketMaxConfidenceRatioBps()")));
        available = oracleDivergenceOk && confidenceOk;
        if (!available) {
            return (false, bytes32(0));
        }
        digest = keccak256(abi.encode(oracleDivergence, confidenceRatio));
    }

    function _poolPolicyConfigDigest() internal view returns (bool available, bytes32 digest) {
        uint256[7] memory values;
        bool ok;
        (ok, values[0]) = _readUint(address(HOUSE_POOL), HousePool.seniorRateBps.selector);
        if (!ok) {
            return (false, bytes32(0));
        }
        (ok, values[1]) = _readUint(address(HOUSE_POOL), HousePool.markStalenessLimit.selector);
        if (!ok) {
            return (false, bytes32(0));
        }
        (ok, values[2]) = _readUint(address(HOUSE_POOL), HousePool.seniorFrozenLpFeeBps.selector);
        if (!ok) {
            return (false, bytes32(0));
        }
        (ok, values[3]) = _readUint(address(HOUSE_POOL), HousePool.juniorFrozenLpFeeBps.selector);
        if (!ok) {
            return (false, bytes32(0));
        }
        (ok, values[4]) = _readUint(address(HOUSE_POOL), HousePool.maxSeniorExposureUsdc.selector);
        if (!ok) {
            return (false, bytes32(0));
        }
        (ok, values[5]) = _readUint(address(HOUSE_POOL), HousePool.maxSeniorShareBps.selector);
        if (!ok) {
            return (false, bytes32(0));
        }
        (ok, values[6]) =
            _readUint(address(JUNIOR_VAULT), ISettlementMonitorSidecarVaultView.maintenanceFeeAprBps.selector);
        if (!ok) {
            return (false, bytes32(0));
        }
        address maintenanceRecipient;
        (ok, maintenanceRecipient) =
            _readAddress(address(JUNIOR_VAULT), ISettlementMonitorSidecarVaultView.maintenanceFeeRecipient.selector);
        if (!ok) {
            return (false, bytes32(0));
        }

        available = true;
        digest = keccak256(
            abi.encode(
                values[0], values[1], values[2], values[3], values[4], values[5], values[6], maintenanceRecipient
            )
        );
    }

    function _seedConfigDigest() internal view returns (bool available, bytes32 digest) {
        (bool seniorReceiverOk, address seniorReceiver) =
            _readAddress(address(SENIOR_VAULT), ISettlementMonitorSidecarVaultView.seedReceiver.selector);
        (bool seniorFloorOk, uint256 seniorFloor) =
            _readUint(address(SENIOR_VAULT), ISettlementMonitorSidecarVaultView.seedShareFloor.selector);
        (bool juniorReceiverOk, address juniorReceiver) =
            _readAddress(address(JUNIOR_VAULT), ISettlementMonitorSidecarVaultView.seedReceiver.selector);
        (bool juniorFloorOk, uint256 juniorFloor) =
            _readUint(address(JUNIOR_VAULT), ISettlementMonitorSidecarVaultView.seedShareFloor.selector);
        available = seniorReceiverOk && seniorFloorOk && juniorReceiverOk && juniorFloorOk;
        if (!available) {
            return (false, bytes32(0));
        }
        digest = keccak256(abi.encode(seniorReceiver, seniorFloor, juniorReceiver, juniorFloor));
    }

    function _readUint(
        address target,
        bytes4 selector
    ) internal view returns (bool ok, uint256 value) {
        uint256[16] memory words;
        (ok, words) = _readWords(target, abi.encodeWithSelector(selector), 1);
        value = words[0];
    }

    function _readBool(
        address target,
        bytes4 selector
    ) internal view returns (bool ok, bool value) {
        uint256[16] memory words;
        (ok, words) = _readWords(target, abi.encodeWithSelector(selector), 1);
        if (!ok || words[0] > 1) {
            return (false, false);
        }
        value = words[0] == 1;
    }

    function _readAddress(
        address target,
        bytes4 selector
    ) internal view returns (bool ok, address value) {
        uint256[16] memory words;
        (ok, words) = _readWords(target, abi.encodeWithSelector(selector), 1);
        if (!ok || words[0] > type(uint160).max) {
            return (false, address(0));
        }
        value = address(uint160(words[0]));
    }

    function _readWords(
        address target,
        bytes memory input,
        uint256 expectedWords
    ) internal view returns (bool ok, uint256[16] memory words) {
        if (target.code.length == 0 || expectedWords > MAX_STATIC_WORDS) {
            return (false, words);
        }
        uint256 returnSize;
        assembly ("memory-safe") {
            ok := staticcall(STATIC_READ_GAS, target, add(input, 32), mload(input), words, mul(expectedWords, 32))
            returnSize := returndatasize()
        }
        if (!ok || returnSize != expectedWords * 32) {
            assembly ("memory-safe") {
                let end := add(words, 512)
                for { let cursor := words } lt(cursor, end) { cursor := add(cursor, 32) } { mstore(cursor, 0) }
            }
            return (false, words);
        }
    }

    function _safeAdd(
        uint256 a,
        uint256 b
    ) internal pure returns (bool ok, uint256 result) {
        unchecked {
            result = a + b;
            ok = result >= a;
        }
    }

    function _safeMul(
        uint256 a,
        uint256 b
    ) internal pure returns (bool ok, uint256 result) {
        if (a == 0 || b == 0) {
            return (true, 0);
        }
        unchecked {
            result = a * b;
            ok = result / a == b;
        }
    }

    function _saturatingDifference(
        uint256 minuend,
        uint256 subtrahend
    ) internal pure returns (uint256) {
        return minuend > subtrahend ? minuend - subtrahend : 0;
    }

    function _criticalBit(
        SettlementMonitorViewTypes.CriticalFault fault
    ) internal pure returns (uint256) {
        return 1 << uint256(fault);
    }

    function _dependencyBit(
        SettlementMonitorViewTypes.Dependency dependency
    ) internal pure returns (uint256) {
        return 1 << uint256(dependency);
    }

}
