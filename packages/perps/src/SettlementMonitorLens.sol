// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineProtocolLens} from "@plether/perps/CfdEngineProtocolLens.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {SettlementMonitorLensSidecar} from "@plether/perps/SettlementMonitorLensSidecar.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {ISettlementMonitorLens} from "@plether/perps/interfaces/ISettlementMonitorLens.sol";
import {SettlementMonitorViewTypes} from "@plether/perps/interfaces/SettlementMonitorViewTypes.sol";

/// @dev Exact flattened getters intentionally kept local so the ERC-7540 interface id remains unchanged.
interface ISettlementMonitorVaultView {

    function getRequestEpochWindow() external view returns (uint256 nextRequestEpoch, uint256 nextRequestCutoffTime);

    function depositEpochs(
        uint256 epochId
    )
        external
        view
        returns (uint256 assets, uint256 shares, uint256 claimedAssets, uint256 claimedShares, bool finalized);

    function depositEpochQueueState(
        uint256 epochId
    ) external view returns (uint256 previousEpoch, uint256 nextEpoch, bool queued, bool rejected);

    function redeemEpochs(
        uint256 epochId
    )
        external
        view
        returns (
            uint256 shares,
            uint256 fundedShares,
            uint256 fundedAssets,
            uint256 claimedShares,
            uint256 claimedAssets,
            uint256 refundableShares,
            uint256 refundedShares,
            uint256 fundingBasisClaimed,
            uint256 refundBasisClaimed,
            bool refundEnabled
        );

    function redeemEpochQueueState(
        uint256 epochId
    ) external view returns (uint256 previousEpoch, uint256 nextEpoch, bool queued, bool rejected);

    function getMaturedDepositHead(
        uint256 cutoffEpoch
    ) external view returns (uint256 epochId, uint256 assets);

    function getMaturedRedeemHead(
        uint256 cutoffEpoch
    ) external view returns (uint256 epochId, uint256 remainingShares);

    function depositQueueHead() external view returns (uint256);

    function depositQueueTail() external view returns (uint256);

    function redeemQueueHead() external view returns (uint256);

    function redeemQueueTail() external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function pendingDepositEscrowAssets() external view returns (uint256);

    function withdrawalEscrowAssets() external view returns (uint256);

    function pendingRedeemEscrowShares() external view returns (uint256);

    function depositClaimEscrowShares() external view returns (uint256);

}

/// @title SettlementMonitorLens
/// @notice Standalone, read-only operational and invariant monitor for synchronized LP epoch settlement.
/// @dev This contract never predicts exact HousePool progress and never mutates protocol state. A successful view does
///      not replace simulation of the exact Router call and oracle payload intended for broadcast.
contract SettlementMonitorLens is ISettlementMonitorLens {

    struct StatusReadValidity {
        bool clock;
        bool terminal;
        bool liquidity;
        bool withdrawals;
    }

    struct MaturedEvidenceContext {
        uint256 currentEpoch;
        uint256 dependencyBit;
        uint256 head;
        uint256 maturedEpoch;
        uint256 maturedAmount;
        bool headOk;
        bool maturedGetterOk;
        bool isDeposit;
        bool positive;
    }

    uint256 public constant CONFIG_SCHEMA_VERSION = 2;
    bytes32 public constant OBSERVATION_DOMAIN = keccak256("PLETHER_SETTLEMENT_OBSERVATION_V2");
    uint256 internal constant STATIC_READ_GAS = 500_000;
    uint256 internal constant MAX_STATIC_WORDS = 16;

    uint8 internal constant BINDING_ROUTER = 1;
    uint8 internal constant BINDING_ENGINE = 2;
    uint8 internal constant BINDING_ENGINE_ROUTER = 3;
    uint8 internal constant BINDING_POOL = 4;
    uint8 internal constant BINDING_POOL_ENGINE = 5;
    uint8 internal constant BINDING_PROTOCOL_LENS = 6;
    uint8 internal constant BINDING_PROTOCOL_LENS_ENGINE = 7;
    uint8 internal constant BINDING_CLEARINGHOUSE = 8;
    uint8 internal constant BINDING_BOOK = 9;
    uint8 internal constant BINDING_SENIOR_VAULT = 10;
    uint8 internal constant BINDING_JUNIOR_VAULT = 11;
    uint8 internal constant BINDING_USDC = 12;
    uint8 internal constant BINDING_POOL_USDC = 13;
    uint8 internal constant BINDING_CLEARINGHOUSE_USDC = 14;
    uint8 internal constant BINDING_CLEARINGHOUSE_ENGINE = 15;
    uint8 internal constant BINDING_BOOK_ENGINE = 16;
    uint8 internal constant BINDING_SENIOR_ASSET = 17;
    uint8 internal constant BINDING_JUNIOR_ASSET = 18;
    uint8 internal constant BINDING_ENGINE_DEPENDENCIES = 19;
    uint8 internal constant BINDING_ROUTER_POOL = 20;

    OrderRouter public immutable ROUTER;
    CfdEngine public immutable ENGINE;
    HousePool public immutable HOUSE_POOL;
    CfdEngineProtocolLens public immutable ENGINE_PROTOCOL_LENS;
    MarginClearinghouse public immutable CLEARINGHOUSE;
    TerminalNavBookV2 public immutable TERMINAL_NAV_BOOK;
    TrancheVault public immutable SENIOR_VAULT;
    TrancheVault public immutable JUNIOR_VAULT;
    IERC20 public immutable USDC;
    SettlementMonitorLensSidecar public immutable SIDECAR;

    error SettlementMonitorLens__InvalidDependency(uint8 dependency, address observed);
    error SettlementMonitorLens__BindingMismatch(uint8 dependency, address expected, address observed);
    error SettlementMonitorLens__InvalidObservedEpoch(uint256 observedEpoch);

    constructor(
        address router_
    ) {
        if (router_ == address(0) || router_.code.length == 0) {
            revert SettlementMonitorLens__InvalidDependency(BINDING_ROUTER, router_);
        }
        ROUTER = OrderRouter(router_);

        address engine_ = address(ROUTER.engine());
        _requireCode(BINDING_ENGINE, engine_);
        ENGINE = CfdEngine(engine_);
        if (ENGINE.orderRouter() != router_) {
            revert SettlementMonitorLens__BindingMismatch(BINDING_ENGINE_ROUTER, router_, ENGINE.orderRouter());
        }

        address pool_ = address(ENGINE.pool());
        _requireCode(BINDING_POOL, pool_);
        HOUSE_POOL = HousePool(pool_);
        if (address(HOUSE_POOL.ENGINE()) != engine_) {
            revert SettlementMonitorLens__BindingMismatch(BINDING_POOL_ENGINE, engine_, address(HOUSE_POOL.ENGINE()));
        }
        IPletherOracle routerOracle = ROUTER.pletherOracle();
        address routerPool_ = address(routerOracle.housePool());
        if (routerPool_ != pool_) {
            revert SettlementMonitorLens__BindingMismatch(BINDING_ROUTER_POOL, pool_, routerPool_);
        }

        address engineProtocolLens_ = address(HOUSE_POOL.ENGINE_PROTOCOL_LENS());
        _requireCode(BINDING_PROTOCOL_LENS, engineProtocolLens_);
        ENGINE_PROTOCOL_LENS = CfdEngineProtocolLens(engineProtocolLens_);
        if (address(ENGINE_PROTOCOL_LENS.engineContract()) != engine_) {
            revert SettlementMonitorLens__BindingMismatch(
                BINDING_PROTOCOL_LENS_ENGINE, engine_, address(ENGINE_PROTOCOL_LENS.engineContract())
            );
        }

        address clearinghouse_ = address(ENGINE.clearinghouse());
        _requireCode(BINDING_CLEARINGHOUSE, clearinghouse_);
        CLEARINGHOUSE = MarginClearinghouse(clearinghouse_);

        address book_ = address(ENGINE.terminalNavBook());
        _requireCode(BINDING_BOOK, book_);
        TERMINAL_NAV_BOOK = TerminalNavBookV2(book_);

        address seniorVault_ = HOUSE_POOL.seniorVault();
        address juniorVault_ = HOUSE_POOL.juniorVault();
        _requireCode(BINDING_SENIOR_VAULT, seniorVault_);
        _requireCode(BINDING_JUNIOR_VAULT, juniorVault_);
        SENIOR_VAULT = TrancheVault(seniorVault_);
        JUNIOR_VAULT = TrancheVault(juniorVault_);

        address usdc_ = address(ENGINE.USDC());
        _requireCode(BINDING_USDC, usdc_);
        USDC = IERC20(usdc_);
        _validateStaticBindings(engine_, pool_, clearinghouse_, book_, seniorVault_, juniorVault_, usdc_);
        SIDECAR = new SettlementMonitorLensSidecar(router_);
    }

    function getSettlementStatus(
        uint256 observedEpoch
    ) external view returns (SettlementMonitorViewTypes.SettlementStatus memory status) {
        status = _buildSettlementStatus(observedEpoch);
        if (status.requiredExecutionPath == SettlementMonitorViewTypes.ExecutionPath.AtomicOracleRefresh) {
            SettlementMonitorViewTypes.OracleStatus memory oracle =
                SIDECAR.getOracleStatus(status.clock.minimumAtomicPublishTime);
            _augmentRequiredOracleBlockers(status, oracle);
        }
    }

    function getSettlementHealth() external view returns (SettlementMonitorViewTypes.SettlementHealth memory health) {
        (bool durationOk, uint256 duration) = _readUint(address(HOUSE_POOL), bytes4(keccak256("LP_EPOCH_DURATION()")));
        uint256 observedEpoch = durationOk && duration != 0 ? block.timestamp / duration : 0;
        SettlementMonitorViewTypes.SettlementStatus memory status = _buildSettlementStatus(observedEpoch);
        return
            SIDECAR.getSettlementHealth(status.senior.faultMask | status.junior.faultMask, status.dependencyFailureMask);
    }

    function getPoolReconcileOracleStatus()
        external
        view
        returns (SettlementMonitorViewTypes.OracleStatus memory oracleStatus)
    {
        (bool durationOk, uint256 duration) = _readUint(address(HOUSE_POOL), bytes4(keccak256("LP_EPOCH_DURATION()")));
        uint256 epochFloor = durationOk && duration != 0 ? (block.timestamp / duration) * duration : 0;
        oracleStatus = SIDECAR.getOracleStatus(epochFloor);
        if (!durationOk || duration == 0) {
            oracleStatus.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Pool);
        }
    }

    function getSettlementObservation(
        uint256 observedEpoch
    ) external view returns (SettlementMonitorViewTypes.SettlementObservation memory observation) {
        observation.schemaVersion = CONFIG_SCHEMA_VERSION;
        observation.status = _buildSettlementStatus(observedEpoch);
        observation.accounting = SIDECAR.getSettlementAccounting();
        observation.oracle = SIDECAR.getOracleStatus(observation.status.clock.minimumAtomicPublishTime);
        _augmentRequiredOracleBlockers(observation.status, observation.oracle);
        observation.health = SIDECAR.getSettlementHealth(
            observation.status.senior.faultMask | observation.status.junior.faultMask,
            observation.status.dependencyFailureMask
        );
        (bool configAvailable, bytes32 configDigest) = SIDECAR.getObservableConfigDigest();
        observation.observableConfigDigest = configDigest;

        observation.observationDigest = keccak256(
            abi.encode(
                OBSERVATION_DOMAIN,
                CONFIG_SCHEMA_VERSION,
                block.chainid,
                address(this),
                observedEpoch,
                observation.observableConfigDigest,
                observation.status,
                observation.accounting,
                observation.oracle,
                observation.health
            )
        );
        bool requiredOraclePolicyValid = observation.status.requiredExecutionPath
                != SettlementMonitorViewTypes.ExecutionPath.AtomicOracleRefresh
            || (observation.oracle.policyValid
                && (observation.status.clock.minimumAtomicPublishTime == 0
                    || observation.oracle.publishTimeMeetsEpochFloor));
        observation.observationComplete = configAvailable && observation.status.dependencyFailureMask == 0
            && observation.accounting.dependencyFailureMask == 0 && observation.health.dependencyFailureMask == 0
            && observation.oracle.dependencyFailureMask == 0 && observation.health.criticalFaultMask == 0
            && requiredOraclePolicyValid;
        if (observation.observationComplete) {
            observation.completeObservationDigest = observation.observationDigest;
        }
    }

    function observableConfigDigest() external view returns (bytes32 digest) {
        (, digest) = SIDECAR.getObservableConfigDigest();
    }

    function _buildSettlementStatus(
        uint256 observedEpoch
    ) internal view returns (SettlementMonitorViewTypes.SettlementStatus memory status) {
        uint256 clockFaultMask;
        uint256 clockDependencyMask;
        uint256 clockPathDependencyMask;
        (status.clock, clockFaultMask, clockDependencyMask, clockPathDependencyMask) = _buildEpochClock(observedEpoch);
        uint256 seniorMaturedDependencyMask;
        uint256 juniorMaturedDependencyMask;
        bool seniorHasMaturedWork;
        bool juniorHasMaturedWork;
        bool seniorMaturedEvidenceComplete;
        bool juniorMaturedEvidenceComplete;
        (status.senior, seniorMaturedDependencyMask, seniorHasMaturedWork, seniorMaturedEvidenceComplete) =
            _buildTrancheQueueStatus(address(SENIOR_VAULT), observedEpoch, status.clock.currentEpoch, true);
        (status.junior, juniorMaturedDependencyMask, juniorHasMaturedWork, juniorMaturedEvidenceComplete) =
            _buildTrancheQueueStatus(address(JUNIOR_VAULT), observedEpoch, status.clock.currentEpoch, false);
        status.senior.faultMask |= clockFaultMask;
        status.junior.faultMask |= clockFaultMask;
        status.dependencyFailureMask =
            clockDependencyMask | status.senior.dependencyFailureMask | status.junior.dependencyFailureMask;
        status.hasMaturedWork = seniorHasMaturedWork || juniorHasMaturedWork;
        bool maturedEvidenceComplete = seniorMaturedEvidenceComplete && juniorMaturedEvidenceComplete;
        status.executionPathDependencyMask = clockPathDependencyMask;
        if (!status.hasMaturedWork && !maturedEvidenceComplete) {
            status.executionPathDependencyMask |= seniorMaturedDependencyMask | juniorMaturedDependencyMask;
        }

        StatusReadValidity memory validity;
        validity.clock = status.clock.epochDuration != 0;
        validity = _populateRuntimeStatus(status, validity, status.hasMaturedWork);
        _populateDepositDeferrals(status, validity, seniorMaturedEvidenceComplete, juniorMaturedEvidenceComplete);
        _classifyExecutionPath(status, validity, maturedEvidenceComplete);
        if (status.executionPathDependencyMask != 0) {
            status.operationalBlockerMask |= _operationalBit(
                SettlementMonitorViewTypes.OperationalBlocker.RequiredDependencyUnknown
            );
        }
    }

    function _augmentRequiredOracleBlockers(
        SettlementMonitorViewTypes.SettlementStatus memory status,
        SettlementMonitorViewTypes.OracleStatus memory oracle
    ) internal pure {
        if (status.requiredExecutionPath != SettlementMonitorViewTypes.ExecutionPath.AtomicOracleRefresh) {
            return;
        }
        if (oracle.dependencyFailureMask != 0) {
            status.dependencyFailureMask |= oracle.dependencyFailureMask;
            status.operationalBlockerMask |= _operationalBit(
                SettlementMonitorViewTypes.OperationalBlocker.RequiredDependencyUnknown
            );
            return;
        }
        if (!oracle.policyValid) {
            status.operationalBlockerMask |= _operationalBit(
                SettlementMonitorViewTypes.OperationalBlocker.RequiredOracleInvalid
            );
        }
        if (oracle.readSucceeded && oracle.policyValid && !oracle.publishTimeMeetsEpochFloor) {
            if (status.clock.minimumAtomicPublishTime != 0) {
                status.operationalBlockerMask |= _operationalBit(
                    SettlementMonitorViewTypes.OperationalBlocker.OracleBeforeEpochBoundary
                );
            }
        }
    }

    function _buildEpochClock(
        uint256 observedEpoch
    )
        internal
        view
        returns (
            SettlementMonitorViewTypes.EpochClock memory clock,
            uint256 criticalFaultMask,
            uint256 dependencyFailureMask,
            uint256 executionPathDependencyMask
        )
    {
        clock.observedAt = block.timestamp;
        clock.observedBlock = block.number;
        clock.observedEpoch = observedEpoch;

        (bool durationOk, uint256 duration) = _readUint(address(HOUSE_POOL), bytes4(keccak256("LP_EPOCH_DURATION()")));
        if (!durationOk) {
            dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Pool);
            executionPathDependencyMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Pool);
        }
        if (!durationOk) {
            return (clock, criticalFaultMask, dependencyFailureMask, executionPathDependencyMask);
        }
        if (duration == 0) {
            criticalFaultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.RequestWindowFormula);
            return (clock, criticalFaultMask, dependencyFailureMask, executionPathDependencyMask);
        }

        clock.epochDuration = duration;
        clock.currentEpoch = block.timestamp / duration;
        clock.settlementCutoffEpoch = clock.currentEpoch;

        (bool startOk, uint256 observedStart) = _safeMul(observedEpoch, duration);
        if (!startOk) {
            revert SettlementMonitorLens__InvalidObservedEpoch(observedEpoch);
        }
        clock.observedEpochStart = observedStart;
        clock.secondsUntilMaturity = _saturatingDifference(observedStart, block.timestamp);
        clock.matured = observedEpoch <= clock.currentEpoch;

        (bool cutoffOk, uint256 seniorCutoff) =
            _readUint(address(SENIOR_VAULT), bytes4(keccak256("LP_REQUEST_CUTOFF_DURATION()")));
        (bool juniorCutoffOk, uint256 juniorCutoff) =
            _readUint(address(JUNIOR_VAULT), bytes4(keccak256("LP_REQUEST_CUTOFF_DURATION()")));
        if (!cutoffOk) {
            dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.SeniorVault);
        }
        if (!juniorCutoffOk) {
            dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.JuniorVault);
        }
        if (!cutoffOk || !juniorCutoffOk) {
            return (clock, criticalFaultMask, dependencyFailureMask, executionPathDependencyMask);
        }
        if (seniorCutoff >= duration || juniorCutoff != seniorCutoff) {
            criticalFaultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.RequestWindowFormula);
            return (clock, criticalFaultMask, dependencyFailureMask, executionPathDependencyMask);
        }
        clock.requestCutoffDuration = seniorCutoff;
        if (observedStart >= seniorCutoff) {
            clock.observedEpochRequestCutoff = observedStart - seniorCutoff;
            clock.secondsUntilAdditionsClose = _saturatingDifference(clock.observedEpochRequestCutoff, block.timestamp);
        }

        (uint256 windowFaults, uint256 windowFailures) = _validateRequestEpochWindows(clock, duration, seniorCutoff);
        criticalFaultMask |= windowFaults;
        dependencyFailureMask |= windowFailures;
    }

    function _validateRequestEpochWindows(
        SettlementMonitorViewTypes.EpochClock memory clock,
        uint256 duration,
        uint256 seniorCutoff
    ) internal view returns (uint256 criticalFaultMask, uint256 dependencyFailureMask) {
        (bool seniorWindowOk, uint256 seniorNext, uint256 seniorNextCutoff) =
            _readPair(address(SENIOR_VAULT), ISettlementMonitorVaultView.getRequestEpochWindow.selector, 0, false);
        if (!seniorWindowOk) {
            dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.SeniorVault);
        }
        bool windowValid = true;
        {
            (bool juniorWindowOk, uint256 juniorNext, uint256 juniorNextCutoff) =
                _readPair(address(JUNIOR_VAULT), ISettlementMonitorVaultView.getRequestEpochWindow.selector, 0, false);
            if (!juniorWindowOk) {
                dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.JuniorVault);
            }
            if (!seniorWindowOk || !juniorWindowOk) {
                return (criticalFaultMask, dependencyFailureMask);
            }
            if (seniorNext != juniorNext || seniorNextCutoff != juniorNextCutoff) {
                criticalFaultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.RequestWindowMismatch);
                windowValid = false;
            }
        }
        {
            uint256 imminent = clock.currentEpoch + 1;
            uint256 imminentCutoff = imminent * duration - seniorCutoff;
            uint256 expectedNext = block.timestamp < imminentCutoff ? imminent : imminent + 1;
            uint256 expectedCutoff = expectedNext * duration - seniorCutoff;
            if (seniorNext != expectedNext || seniorNextCutoff != expectedCutoff) {
                criticalFaultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.RequestWindowFormula);
                windowValid = false;
            }
            if (windowValid) {
                clock.additionsClosed = clock.observedEpoch < seniorNext;
                clock.isCurrentRequestTarget = clock.observedEpoch == seniorNext;
                clock.additionsOpenByClock = clock.isCurrentRequestTarget;
            }
        }
    }

    function _buildTrancheQueueStatus(
        address vault,
        uint256 observedEpoch,
        uint256 currentEpoch,
        bool isSenior
    )
        internal
        view
        returns (
            SettlementMonitorViewTypes.TrancheQueueStatus memory queue,
            uint256 maturedDependencyMask,
            bool hasMaturedWork,
            bool maturedEvidenceComplete
        )
    {
        queue.vault = vault;
        uint256 dependencyBit = _dependencyBit(
            isSenior
                ? SettlementMonitorViewTypes.Dependency.SeniorVault
                : SettlementMonitorViewTypes.Dependency.JuniorVault
        );

        bool readOk;
        uint256 failedReadMask;
        (readOk, queue.nextRequestEpoch, queue.nextRequestCutoffTime) =
            _readPair(vault, ISettlementMonitorVaultView.getRequestEpochWindow.selector, 0, false);
        if (!readOk) {
            failedReadMask |= 1;
        }
        (readOk, queue.depositQueueHead) = _readUint(vault, ISettlementMonitorVaultView.depositQueueHead.selector);
        if (!readOk) {
            failedReadMask |= 1 << 1;
        }
        (readOk, queue.depositQueueTail) = _readUint(vault, ISettlementMonitorVaultView.depositQueueTail.selector);
        if (!readOk) {
            failedReadMask |= 1 << 2;
        }
        (readOk, queue.redeemQueueHead) = _readUint(vault, ISettlementMonitorVaultView.redeemQueueHead.selector);
        if (!readOk) {
            failedReadMask |= 1 << 3;
        }
        (readOk, queue.redeemQueueTail) = _readUint(vault, ISettlementMonitorVaultView.redeemQueueTail.selector);
        if (!readOk) {
            failedReadMask |= 1 << 4;
        }
        (readOk, queue.maturedDepositHeadEpoch, queue.maturedDepositHeadAssets) =
            _readPair(vault, ISettlementMonitorVaultView.getMaturedDepositHead.selector, currentEpoch, true);
        if (!readOk) {
            failedReadMask |= 1 << 5;
        }
        (readOk, queue.maturedRedeemHeadEpoch, queue.maturedRedeemHeadShares) =
            _readPair(vault, ISettlementMonitorVaultView.getMaturedRedeemHead.selector, currentEpoch, true);
        if (!readOk) {
            failedReadMask |= 1 << 6;
        }
        (readOk, queue.totalSupply) = _readUint(vault, ISettlementMonitorVaultView.totalSupply.selector);
        if (!readOk) {
            failedReadMask |= 1 << 7;
        }
        (readOk, queue.pendingDepositEscrowAssets) =
            _readUint(vault, ISettlementMonitorVaultView.pendingDepositEscrowAssets.selector);
        if (!readOk) {
            failedReadMask |= 1 << 8;
        }
        (readOk, queue.withdrawalEscrowAssets) =
            _readUint(vault, ISettlementMonitorVaultView.withdrawalEscrowAssets.selector);
        if (!readOk) {
            failedReadMask |= 1 << 9;
        }
        (readOk, queue.pendingRedeemEscrowShares) =
            _readUint(vault, ISettlementMonitorVaultView.pendingRedeemEscrowShares.selector);
        if (!readOk) {
            failedReadMask |= 1 << 10;
        }
        (readOk, queue.depositClaimEscrowShares) =
            _readUint(vault, ISettlementMonitorVaultView.depositClaimEscrowShares.selector);
        if (!readOk) {
            failedReadMask |= 1 << 11;
        }

        if (failedReadMask != 0) {
            queue.dependencyFailureMask |= dependencyBit;
        }
        (maturedDependencyMask, hasMaturedWork, maturedEvidenceComplete) =
            _populateQueueEvidence(queue, vault, observedEpoch, currentEpoch, dependencyBit, failedReadMask);
    }

    function _populateQueueEvidence(
        SettlementMonitorViewTypes.TrancheQueueStatus memory queue,
        address vault,
        uint256 observedEpoch,
        uint256 currentEpoch,
        uint256 dependencyBit,
        uint256 failedReadMask
    ) internal view returns (uint256 maturedDependencyMask, bool hasMaturedWork, bool maturedEvidenceComplete) {
        _populateObservedDeposit(
            queue,
            vault,
            observedEpoch,
            dependencyBit,
            (failedReadMask & (1 << 1)) == 0 && (failedReadMask & (1 << 2)) == 0
        );
        _populateObservedRedeem(
            queue,
            vault,
            observedEpoch,
            dependencyBit,
            (failedReadMask & (1 << 3)) == 0 && (failedReadMask & (1 << 4)) == 0
        );
        _validateQueueEndpoints(
            queue,
            vault,
            dependencyBit,
            (failedReadMask & (1 << 1)) == 0,
            (failedReadMask & (1 << 2)) == 0,
            (failedReadMask & (1 << 3)) == 0,
            (failedReadMask & (1 << 4)) == 0
        );
        {
            (bool evidenceKnown, bool matured) = _validateMaturedEvidence(
                queue,
                vault,
                currentEpoch,
                (failedReadMask & (1 << 1)) == 0,
                (failedReadMask & (1 << 5)) == 0,
                dependencyBit,
                true
            );
            hasMaturedWork = matured;
            maturedEvidenceComplete = evidenceKnown;
        }
        {
            (bool evidenceKnown, bool matured) = _validateMaturedEvidence(
                queue,
                vault,
                currentEpoch,
                (failedReadMask & (1 << 3)) == 0,
                (failedReadMask & (1 << 6)) == 0,
                dependencyBit,
                false
            );
            hasMaturedWork = hasMaturedWork || matured;
            maturedEvidenceComplete = maturedEvidenceComplete && evidenceKnown;
        }
        if ((failedReadMask & (1 << 5)) != 0 || (failedReadMask & (1 << 6)) != 0) {
            maturedDependencyMask = dependencyBit;
        }
    }

    function _populateObservedDeposit(
        SettlementMonitorViewTypes.TrancheQueueStatus memory queue,
        address vault,
        uint256 observedEpoch,
        uint256 dependencyBit,
        bool endpointsReadable
    ) internal view {
        uint256[16] memory epoch;
        uint256[16] memory state;
        {
            bool epochOk;
            bool stateOk;
            (epochOk, epoch) =
                _readWords(vault, abi.encodeCall(ISettlementMonitorVaultView.depositEpochs, (observedEpoch)), 5);
            (stateOk, state) = _readWords(
                vault, abi.encodeCall(ISettlementMonitorVaultView.depositEpochQueueState, (observedEpoch)), 4
            );
            if (!epochOk || !stateOk || epoch[4] > 1 || state[2] > 1 || state[3] > 1) {
                queue.dependencyFailureMask |= dependencyBit;
                return;
            }
        }

        queue.observedDepositAssets = epoch[0];
        queue.observedDepositFinalized = epoch[4] == 1;
        queue.observedDepositQueued = state[2] == 1;
        queue.observedDepositRejected = state[3] == 1;

        {
            bool arithmeticValid = epoch[2] <= epoch[0] && epoch[3] <= epoch[1];
            bool lifecycleValid = !(queue.observedDepositFinalized && queue.observedDepositRejected);
            if (queue.observedDepositQueued) {
                lifecycleValid = lifecycleValid && epoch[0] != 0 && epoch[1] == 0 && epoch[2] == 0 && epoch[3] == 0
                    && !queue.observedDepositFinalized && !queue.observedDepositRejected;
            } else if (state[0] != 0 || state[1] != 0) {
                lifecycleValid = false;
            } else if (
                !queue.observedDepositFinalized && !queue.observedDepositRejected
                    && (epoch[0] != 0 || epoch[1] != 0 || epoch[2] != 0 || epoch[3] != 0)
            ) {
                lifecycleValid = false;
            }
            if (queue.observedDepositFinalized) {
                lifecycleValid = lifecycleValid && epoch[0] != 0 && epoch[1] != 0 && !queue.observedDepositQueued;
            }
            if (queue.observedDepositRejected) {
                lifecycleValid = lifecycleValid && !queue.observedDepositQueued && !queue.observedDepositFinalized
                    && epoch[1] == 0 && epoch[2] == 0 && epoch[3] == 0;
            }
            if (!arithmeticValid || !lifecycleValid) {
                queue.faultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.ObservedEpochState);
                if (!arithmeticValid) {
                    queue.faultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.ArithmeticDomain);
                }
                return;
            }
        }

        if (queue.observedDepositQueued) {
            queue.observedDepositPendingAssets = epoch[0];
        }
        if (queue.observedDepositFinalized) {
            queue.observedDepositClaimableAssets = epoch[0] - epoch[2];
            queue.observedDepositClaimableShares = epoch[1] - epoch[3];
        }
        if (queue.observedDepositRejected) {
            queue.observedDepositRefundableAssets = epoch[0];
        }

        (bool linksReadable, bool linksValid) = _validateObservedNodeLinks(
            vault,
            observedEpoch,
            state[0],
            state[1],
            queue.observedDepositQueued,
            ISettlementMonitorVaultView.depositEpochQueueState.selector
        );
        if (!linksReadable) {
            queue.dependencyFailureMask |= dependencyBit;
        }
        if (linksReadable && !linksValid) {
            queue.faultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.ObservedEpochState);
        }
        if (
            endpointsReadable && queue.observedDepositQueued
                && !_observedNodeWithinEndpoints(
                    observedEpoch, state[0], state[1], queue.depositQueueHead, queue.depositQueueTail
                )
        ) {
            queue.faultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.ObservedEpochState);
        }
    }

    function _populateObservedRedeem(
        SettlementMonitorViewTypes.TrancheQueueStatus memory queue,
        address vault,
        uint256 observedEpoch,
        uint256 dependencyBit,
        bool endpointsReadable
    ) internal view {
        uint256[16] memory epoch;
        uint256[16] memory state;
        {
            bool epochOk;
            bool stateOk;
            (epochOk, epoch) =
                _readWords(vault, abi.encodeCall(ISettlementMonitorVaultView.redeemEpochs, (observedEpoch)), 10);
            (stateOk, state) = _readWords(
                vault, abi.encodeCall(ISettlementMonitorVaultView.redeemEpochQueueState, (observedEpoch)), 4
            );
            if (!epochOk || !stateOk || epoch[9] > 1 || state[2] > 1 || state[3] > 1) {
                queue.dependencyFailureMask |= dependencyBit;
                return;
            }
        }

        queue.observedRedeemShares = epoch[0];
        queue.observedRedeemFundedShares = epoch[1];
        queue.observedRedeemFundedAssets = epoch[2];
        queue.observedRedeemRefundEnabled = epoch[9] == 1;
        queue.observedRedeemQueued = state[2] == 1;

        {
            bool arithmeticValid = epoch[1] <= epoch[0] && epoch[3] <= epoch[1] && epoch[4] <= epoch[2]
                && epoch[6] <= epoch[5] && epoch[7] <= epoch[0] && epoch[8] <= epoch[0];
            bool lifecycleValid = state[3] == 0;
            if (queue.observedRedeemQueued) {
                lifecycleValid =
                    lifecycleValid && epoch[0] > epoch[1] && epoch[7] == 0 && !queue.observedRedeemRefundEnabled;
            } else if (state[0] != 0 || state[1] != 0) {
                lifecycleValid = false;
            }
            if (queue.observedRedeemRefundEnabled) {
                lifecycleValid =
                    lifecycleValid && !queue.observedRedeemQueued && epoch[5] == epoch[0] - epoch[1] && epoch[5] != 0;
            } else if (epoch[5] != 0 || epoch[6] != 0 || epoch[8] != 0) {
                lifecycleValid = false;
            }
            if (!queue.observedRedeemQueued && !queue.observedRedeemRefundEnabled && epoch[0] > epoch[1]) {
                lifecycleValid = false;
            }
            if ((epoch[1] == 0) != (epoch[2] == 0)) {
                lifecycleValid = false;
            }
            if (!arithmeticValid || !lifecycleValid) {
                queue.faultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.ObservedEpochState);
                if (!arithmeticValid) {
                    queue.faultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.ArithmeticDomain);
                }
                return;
            }
        }

        if (queue.observedRedeemQueued) {
            queue.observedRedeemFundableShares = epoch[0] - epoch[1];
        }
        queue.observedRedeemClaimableShares = epoch[1] - epoch[3];
        queue.observedRedeemClaimableAssets = epoch[2] - epoch[4];
        if (queue.observedRedeemRefundEnabled) {
            queue.observedRedeemRefundableShares = epoch[5] - epoch[6];
        }

        (bool linksReadable, bool linksValid) = _validateObservedNodeLinks(
            vault,
            observedEpoch,
            state[0],
            state[1],
            queue.observedRedeemQueued,
            ISettlementMonitorVaultView.redeemEpochQueueState.selector
        );
        if (!linksReadable) {
            queue.dependencyFailureMask |= dependencyBit;
        }
        if (linksReadable && !linksValid) {
            queue.faultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.ObservedEpochState);
        }
        if (
            endpointsReadable && queue.observedRedeemQueued
                && !_observedNodeWithinEndpoints(
                    observedEpoch, state[0], state[1], queue.redeemQueueHead, queue.redeemQueueTail
                )
        ) {
            queue.faultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.ObservedEpochState);
        }
    }

    function _validateQueueEndpoints(
        SettlementMonitorViewTypes.TrancheQueueStatus memory queue,
        address vault,
        uint256 dependencyBit,
        bool depositHeadOk,
        bool depositTailOk,
        bool redeemHeadOk,
        bool redeemTailOk
    ) internal view {
        bool depositReadable = depositHeadOk && depositTailOk;
        bool depositValid;
        if (depositReadable) {
            (depositReadable, depositValid) = _queueEndpointsValid(
                vault,
                queue.depositQueueHead,
                queue.depositQueueTail,
                ISettlementMonitorVaultView.depositEpochQueueState.selector
            );
        }
        bool redeemReadable = redeemHeadOk && redeemTailOk;
        bool redeemValid;
        if (redeemReadable) {
            (redeemReadable, redeemValid) = _queueEndpointsValid(
                vault,
                queue.redeemQueueHead,
                queue.redeemQueueTail,
                ISettlementMonitorVaultView.redeemEpochQueueState.selector
            );
        }
        if (!depositReadable || !redeemReadable) {
            queue.dependencyFailureMask |= dependencyBit;
        }
        if ((depositReadable && !depositValid) || (redeemReadable && !redeemValid)) {
            queue.faultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.QueueEndpoint);
        }
    }

    function _validateMaturedEvidence(
        SettlementMonitorViewTypes.TrancheQueueStatus memory queue,
        address vault,
        uint256 currentEpoch,
        bool headOk,
        bool maturedGetterOk,
        uint256 dependencyBit,
        bool isDeposit
    ) internal view returns (bool evidenceKnown, bool positive) {
        MaturedEvidenceContext memory context = MaturedEvidenceContext({
            currentEpoch: currentEpoch,
            dependencyBit: dependencyBit,
            head: 0,
            maturedEpoch: 0,
            maturedAmount: 0,
            headOk: headOk,
            maturedGetterOk: maturedGetterOk,
            isDeposit: isDeposit,
            positive: false
        });
        return _validateMaturedEvidenceWithContext(queue, vault, context);
    }

    function _validateMaturedEvidenceWithContext(
        SettlementMonitorViewTypes.TrancheQueueStatus memory queue,
        address vault,
        MaturedEvidenceContext memory context
    ) internal view returns (bool evidenceKnown, bool positive) {
        if (!context.maturedGetterOk) {
            queue.dependencyFailureMask |= context.dependencyBit;
            return (false, false);
        }

        context.maturedEpoch = context.isDeposit ? queue.maturedDepositHeadEpoch : queue.maturedRedeemHeadEpoch;
        context.maturedAmount = context.isDeposit ? queue.maturedDepositHeadAssets : queue.maturedRedeemHeadShares;
        if ((context.maturedEpoch == 0) != (context.maturedAmount == 0) || context.maturedEpoch > context.currentEpoch)
        {
            queue.faultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.QueueEndpoint);
            return (false, false);
        }

        positive = context.maturedEpoch != 0;
        context.positive = positive;
        evidenceKnown = true;
        if (!context.headOk) {
            queue.dependencyFailureMask |= context.dependencyBit;
            return (evidenceKnown, positive);
        }

        context.head = context.isDeposit ? queue.depositQueueHead : queue.redeemQueueHead;
        if (context.head == 0) {
            if (positive) {
                queue.faultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.QueueEndpoint);
            }
            return (evidenceKnown, positive);
        }

        (bool payloadReadable, bool payloadValid, bool arithmeticValid) = _validateMaturedHeadPayload(vault, context);
        if (!payloadReadable) {
            queue.dependencyFailureMask |= context.dependencyBit;
            return (evidenceKnown, positive);
        }

        if (!arithmeticValid) {
            queue.faultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.ArithmeticDomain);
        }
        if (!payloadValid) {
            queue.faultMask |= _criticalBit(SettlementMonitorViewTypes.CriticalFault.QueueEndpoint);
        }
        return (evidenceKnown, positive);
    }

    function _validateMaturedHeadPayload(
        address vault,
        MaturedEvidenceContext memory context
    ) internal view returns (bool readable, bool valid, bool arithmeticValid) {
        uint256[16] memory epoch;
        uint256[16] memory state;
        (readable, epoch, state) = _readMaturedHeadState(vault, context.head, context.isDeposit);
        if (!readable) {
            return (false, false, true);
        }

        uint256 expectedAmount;
        (valid, expectedAmount, arithmeticValid) = _maturedHeadPayload(epoch, state, context.isDeposit);
        bool expectedMatured = context.head <= context.currentEpoch;
        bool pairValid = expectedMatured
            ? context.positive && context.maturedEpoch == context.head && context.maturedAmount == expectedAmount
            : !context.positive;
        valid = valid && pairValid;
    }

    function _readMaturedHeadState(
        address vault,
        uint256 head,
        bool isDeposit
    ) internal view returns (bool readable, uint256[16] memory epoch, uint256[16] memory state) {
        bytes4 epochSelector = isDeposit
            ? ISettlementMonitorVaultView.depositEpochs.selector
            : ISettlementMonitorVaultView.redeemEpochs.selector;
        bytes4 stateSelector = isDeposit
            ? ISettlementMonitorVaultView.depositEpochQueueState.selector
            : ISettlementMonitorVaultView.redeemEpochQueueState.selector;
        bool epochOk;
        bool stateOk;
        (epochOk, epoch) = _readWords(vault, abi.encodeWithSelector(epochSelector, head), isDeposit ? 5 : 10);
        (stateOk, state) = _readWords(vault, abi.encodeWithSelector(stateSelector, head), 4);
        readable = epochOk && stateOk && state[2] <= 1 && state[3] <= 1 && (isDeposit ? epoch[4] <= 1 : epoch[9] <= 1);
    }

    function _maturedHeadPayload(
        uint256[16] memory epoch,
        uint256[16] memory state,
        bool isDeposit
    ) internal pure returns (bool payloadValid, uint256 expectedAmount, bool arithmeticValid) {
        payloadValid = state[2] == 1 && state[3] == 0;
        arithmeticValid = true;
        if (isDeposit) {
            payloadValid =
                payloadValid && epoch[4] == 0 && epoch[0] != 0 && epoch[1] == 0 && epoch[2] == 0 && epoch[3] == 0;
            expectedAmount = epoch[0];
            return (payloadValid, expectedAmount, arithmeticValid);
        }

        arithmeticValid = epoch[1] <= epoch[0] && epoch[3] <= epoch[1] && epoch[4] <= epoch[2];
        payloadValid = payloadValid && arithmeticValid && epoch[9] == 0 && epoch[0] > epoch[1]
            && ((epoch[1] == 0) == (epoch[2] == 0)) && epoch[5] == 0 && epoch[6] == 0 && epoch[7] == 0 && epoch[8] == 0;
        expectedAmount = payloadValid ? epoch[0] - epoch[1] : 0;
    }

    function _queueEndpointsValid(
        address vault,
        uint256 head,
        uint256 tail,
        bytes4 selector
    ) internal view returns (bool readable, bool valid) {
        if ((head == 0) != (tail == 0)) {
            return (true, false);
        }
        if (head == 0) {
            return (true, true);
        }
        (bool headOk, uint256[16] memory headState) = _readWords(vault, abi.encodeWithSelector(selector, head), 4);
        (bool tailOk, uint256[16] memory tailState) = _readWords(vault, abi.encodeWithSelector(selector, tail), 4);
        if (!headOk || !tailOk || headState[2] > 1 || headState[3] > 1 || tailState[2] > 1 || tailState[3] > 1) {
            return (false, false);
        }
        bool endpointLinksValid = head == tail
            ? headState[1] == 0 && tailState[0] == 0
            : headState[1] > head && headState[1] <= tail && tailState[0] >= head && tailState[0] < tail;
        valid = headState[2] == 1 && tailState[2] == 1 && headState[0] == 0 && tailState[1] == 0 && headState[3] == 0
            && tailState[3] == 0 && head <= tail && endpointLinksValid;
        return (true, valid);
    }

    function _observedNodeWithinEndpoints(
        uint256 observedEpoch,
        uint256 previousEpoch,
        uint256 nextEpoch,
        uint256 head,
        uint256 tail
    ) internal pure returns (bool) {
        return head != 0 && tail != 0 && observedEpoch >= head && observedEpoch <= tail
            && ((previousEpoch == 0) == (observedEpoch == head)) && ((nextEpoch == 0) == (observedEpoch == tail));
    }

    function _validateObservedNodeLinks(
        address vault,
        uint256 observedEpoch,
        uint256 previousEpoch,
        uint256 nextEpoch,
        bool queued,
        bytes4 selector
    ) internal view returns (bool readable, bool valid) {
        if (!queued) {
            return (true, previousEpoch == 0 && nextEpoch == 0);
        }
        if (previousEpoch >= observedEpoch && previousEpoch != 0) {
            return (true, false);
        }
        if (nextEpoch <= observedEpoch && nextEpoch != 0) {
            return (true, false);
        }
        if (previousEpoch != 0) {
            (bool previousOk, uint256[16] memory previous) =
                _readWords(vault, abi.encodeWithSelector(selector, previousEpoch), 4);
            if (!previousOk || previous[2] > 1 || previous[3] > 1) {
                return (false, false);
            }
            if (previous[2] != 1 || previous[3] != 0 || previous[1] != observedEpoch) {
                return (true, false);
            }
        }
        if (nextEpoch != 0) {
            (bool nextOk, uint256[16] memory next) = _readWords(vault, abi.encodeWithSelector(selector, nextEpoch), 4);
            if (!nextOk || next[2] > 1 || next[3] > 1) {
                return (false, false);
            }
            if (next[2] != 1 || next[3] != 0 || next[0] != observedEpoch) {
                return (true, false);
            }
        }
        return (true, true);
    }

    function _populateRuntimeStatus(
        SettlementMonitorViewTypes.SettlementStatus memory status,
        StatusReadValidity memory validity,
        bool hasMaturedWork
    ) internal view returns (StatusReadValidity memory) {
        _populateTerminalRuntimeStatus(status, validity, hasMaturedWork);
        _populateLiquidityRuntimeStatus(status, validity, hasMaturedWork);
        _populateOperationalRuntimeStatus(status, validity);

        if (status.hasOpenPositions) {
            (bool limitOk, uint256 limit) = status.oracleFrozen
                ? _readUint(address(ENGINE), bytes4(keccak256("fadMaxStaleness()")))
                : _liveMarkAgeLimit();
            if (!limitOk) {
                status.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Engine);
            } else {
                status.applicableMaxMarkAge = limit;
            }
        }
        return validity;
    }

    function _populateTerminalRuntimeStatus(
        SettlementMonitorViewTypes.SettlementStatus memory status,
        StatusReadValidity memory validity,
        bool hasMaturedWork
    ) internal view {
        (bool terminalOk, uint256[16] memory terminal) =
            _readWords(address(ENGINE), abi.encodeWithSelector(CfdEngine.terminalNavSnapshot.selector), 8);
        if (
            !terminalOk || terminal[0] > type(uint32).max || terminal[1] > type(uint64).max
                || terminal[5] > type(uint64).max || terminal[6] > 1 || terminal[7] > 1
        ) {
            status.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Engine);
            if (hasMaturedWork) {
                status.executionPathDependencyMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Engine);
            }
        } else {
            validity.terminal = true;
            status.cachedMarkPrice = terminal[0];
            status.cachedMarkTime = terminal[1];
            status.hasOpenPositions = terminal[6] == 1;
            status.engineDegraded = terminal[7] == 1;
            status.cachedMarkAge = _saturatingDifference(block.timestamp, status.cachedMarkTime);
        }
    }

    function _populateLiquidityRuntimeStatus(
        SettlementMonitorViewTypes.SettlementStatus memory status,
        StatusReadValidity memory validity,
        bool hasMaturedWork
    ) internal view {
        (bool liquidityOk, uint256[16] memory liquidity) =
            _readWords(address(HOUSE_POOL), abi.encodeWithSelector(HousePool.getPoolLiquidityView.selector), 12);
        if (!liquidityOk || liquidity[9] > 1 || liquidity[10] > 1 || liquidity[11] > 1) {
            status.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.PoolAccountingPreview);
            if (hasMaturedWork && validity.terminal && status.hasOpenPositions) {
                status.executionPathDependencyMask |= _dependencyBit(
                    SettlementMonitorViewTypes.Dependency.PoolAccountingPreview
                );
            }
        } else {
            validity.liquidity = true;
            status.freeUsdc = liquidity[1];
            status.cachedPreviewTerminalDeficitUsdc = liquidity[8];
            status.markFresh = liquidity[9] == 1;
            status.oracleFrozen = liquidity[10] == 1;
            status.engineDegraded = status.engineDegraded || liquidity[11] == 1;
        }
    }

    function _populateOperationalRuntimeStatus(
        SettlementMonitorViewTypes.SettlementStatus memory status,
        StatusReadValidity memory validity
    ) internal view {
        (bool fadOk, bool fadWindow) = _readBool(address(ENGINE), CfdEngine.isFadWindow.selector);
        (bool withdrawalsOk, bool withdrawalsLive) = _readBool(address(HOUSE_POOL), HousePool.isWithdrawalLive.selector);
        (bool poolPausedOk, bool poolPaused) = _readBool(address(HOUSE_POOL), bytes4(keccak256("paused()")));
        (bool settlementHoldOk, bool settlementHold) =
            _readBool(address(HOUSE_POOL), bytes4(keccak256("lpEpochSettlementPaused()")));
        address routerAdmin = ROUTER.admin();
        (bool routerPausedOk, bool routerPaused) = _readBool(routerAdmin, bytes4(keccak256("paused()")));
        if (!fadOk) {
            status.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Engine);
        }
        if (!withdrawalsOk || !poolPausedOk || !settlementHoldOk) {
            status.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Pool);
        }
        if (!withdrawalsOk || !settlementHoldOk) {
            status.operationalBlockerMask |= _operationalBit(
                SettlementMonitorViewTypes.OperationalBlocker.RequiredDependencyUnknown
            );
        }
        if (!routerPausedOk) {
            status.dependencyFailureMask |= _dependencyBit(SettlementMonitorViewTypes.Dependency.Router);
        }
        if (fadOk) {
            status.fadWindow = fadWindow;
        }
        if (withdrawalsOk) {
            validity.withdrawals = true;
            status.withdrawalsLive = withdrawalsLive;
        }
        if (poolPausedOk) {
            status.poolPaused = poolPaused;
        }
        if (settlementHoldOk) {
            status.lpEpochSettlementPaused = settlementHold;
            if (settlementHold) {
                status.operationalBlockerMask |= _operationalBit(
                    SettlementMonitorViewTypes.OperationalBlocker.LpEpochSettlementPaused
                );
                uint256 holdDeferral = _deferralBit(SettlementMonitorViewTypes.DepositDeferral.LpEpochSettlementPaused);
                status.seniorDepositDeferralMask |= holdDeferral;
                status.juniorDepositDeferralMask |= holdDeferral;
            }
        } else {
            _markDeferralDependencyUnknown(status, _dependencyBit(SettlementMonitorViewTypes.Dependency.Pool), 3);
        }
        if (routerPausedOk) {
            status.routerAdminPaused = routerPaused;
        }
    }

    function _populateDepositDeferrals(
        SettlementMonitorViewTypes.SettlementStatus memory status,
        StatusReadValidity memory validity,
        bool seniorMaturedEvidenceComplete,
        bool juniorMaturedEvidenceComplete
    ) internal view {
        (bool commonGateOk, bool commonGateOpen) = _populateCommonDepositDeferrals(status, validity);
        _populateTrancheDepositDeferrals(status);
        bool seniorFundingCanChangeGate = !seniorMaturedEvidenceComplete || status.senior.maturedRedeemHeadShares != 0;
        uint256 gateClosedBit = _deferralBit(SettlementMonitorViewTypes.DepositDeferral.ActivationNotConfirmed);
        if (commonGateOk && (!commonGateOpen || seniorFundingCanChangeGate)) {
            status.seniorDepositDeferralMask |= gateClosedBit;
            status.juniorDepositDeferralMask |= gateClosedBit;
        }
        if (!juniorMaturedEvidenceComplete || status.junior.maturedRedeemHeadShares != 0) {
            status.seniorDepositDeferralMask |= gateClosedBit;
        }
    }

    function _populateCommonDepositDeferrals(
        SettlementMonitorViewTypes.SettlementStatus memory status,
        StatusReadValidity memory validity
    ) internal view returns (bool commonGateOk, bool commonGateOpen) {
        uint256 poolDependencyBit = _dependencyBit(SettlementMonitorViewTypes.Dependency.Pool);
        uint256 previewDependencyBit = _dependencyBit(SettlementMonitorViewTypes.Dependency.PoolAccountingPreview);
        uint256 common;

        {
            (bool readOk, uint256[16] memory words) =
                _readWords(address(HOUSE_POOL), abi.encodeCall(HousePool.canSettleDepositEntries, ()), 1);
            commonGateOk = readOk && words[0] <= 1;
            commonGateOpen = commonGateOk && words[0] == 1;
        }
        if (!commonGateOk) {
            _markDeferralDependencyUnknown(status, previewDependencyBit, 3);
        }
        {
            (bool lifecycleOk, bool lifecycleOpen) =
                _readBool(address(HOUSE_POOL), HousePool.canAcceptOrdinaryDeposits.selector);
            if (!lifecycleOk) {
                _markDeferralDependencyUnknown(status, poolDependencyBit, 3);
            } else if (!lifecycleOpen) {
                common |= _deferralBit(SettlementMonitorViewTypes.DepositDeferral.LifecycleInactive);
            }
        }
        {
            (bool unassignedOk, uint256 unassigned) =
                _readUint(address(HOUSE_POOL), bytes4(keccak256("unassignedAssets()")));
            if (!unassignedOk) {
                _markDeferralDependencyUnknown(status, poolDependencyBit, 3);
            } else if (unassigned != 0) {
                common |= _deferralBit(SettlementMonitorViewTypes.DepositDeferral.UnassignedAssets);
            }
        }
        {
            (bool impairedOk, bool seniorImpaired) =
                _readBool(address(HOUSE_POOL), HousePool.isSeniorImpairedAfterPendingDepositReconcile.selector);
            if (!impairedOk) {
                _markDeferralDependencyUnknown(status, previewDependencyBit, 3);
            } else if (seniorImpaired) {
                common |= _deferralBit(SettlementMonitorViewTypes.DepositDeferral.SeniorImpaired);
            }
        }
        if (status.poolPaused) {
            common |= _deferralBit(SettlementMonitorViewTypes.DepositDeferral.PoolPaused);
        }
        if (status.oracleFrozen) {
            common |= _deferralBit(SettlementMonitorViewTypes.DepositDeferral.OracleFrozen);
        }
        if (status.engineDegraded) {
            common |= _deferralBit(SettlementMonitorViewTypes.DepositDeferral.EngineDegraded);
        }
        if (status.cachedPreviewTerminalDeficitUsdc != 0) {
            common |= _deferralBit(SettlementMonitorViewTypes.DepositDeferral.TerminalDeficit);
        }
        if (validity.terminal && validity.liquidity && status.hasOpenPositions && !status.markFresh) {
            common |= _deferralBit(SettlementMonitorViewTypes.DepositDeferral.MarkStale);
        }

        status.seniorDepositDeferralMask |= common;
        status.juniorDepositDeferralMask |= common;
    }

    function _populateTrancheDepositDeferrals(
        SettlementMonitorViewTypes.SettlementStatus memory status
    ) internal view {
        uint256 previewDependencyBit = _dependencyBit(SettlementMonitorViewTypes.Dependency.PoolAccountingPreview);
        (bool projectedPrincipalsOk, uint256 projectedSeniorPrincipal, uint256 projectedJuniorPrincipal) =
            _readPair(address(HOUSE_POOL), HousePool.getPendingDepositTrancheState.selector, 0, false);
        if (!projectedPrincipalsOk) {
            _markDeferralDependencyUnknown(status, previewDependencyBit, 3);
        }

        {
            (bool reservationsOk, bool reservationsWithinLimits) =
                _readBool(address(HOUSE_POOL), HousePool.areSeniorDepositReservationsWithinLimits.selector);
            if (!reservationsOk) {
                _markDeferralDependencyUnknown(status, previewDependencyBit, 1);
            } else if (!reservationsWithinLimits) {
                status.seniorDepositDeferralMask |= _deferralBit(
                    SettlementMonitorViewTypes.DepositDeferral.SeniorCapacityUnavailable
                );
            }
        }

        {
            (bool supplyOk, uint256 supply) =
                _readUint(address(SENIOR_VAULT), ISettlementMonitorVaultView.totalSupply.selector);
            if (!supplyOk) {
                _markDeferralDependencyUnknown(
                    status, _dependencyBit(SettlementMonitorViewTypes.Dependency.SeniorVault), 1
                );
            }
            if (projectedPrincipalsOk && supplyOk && projectedSeniorPrincipal == 0 && supply != 0) {
                status.seniorDepositDeferralMask |= _deferralBit(
                    SettlementMonitorViewTypes.DepositDeferral.ZeroPrincipalWithSupply
                );
            }
        }

        {
            (bool supplyOk, uint256 supply) =
                _readUint(address(JUNIOR_VAULT), ISettlementMonitorVaultView.totalSupply.selector);
            if (!supplyOk) {
                _markDeferralDependencyUnknown(
                    status, _dependencyBit(SettlementMonitorViewTypes.Dependency.JuniorVault), 2
                );
            }
            if (projectedPrincipalsOk && supplyOk && projectedJuniorPrincipal == 0 && supply != 0) {
                status.juniorDepositDeferralMask |= _deferralBit(
                    SettlementMonitorViewTypes.DepositDeferral.ZeroPrincipalWithSupply
                );
            }
        }
    }

    function _markDeferralDependencyUnknown(
        SettlementMonitorViewTypes.SettlementStatus memory status,
        uint256 dependencyBit,
        uint256 trancheMask
    ) internal pure {
        status.dependencyFailureMask |= dependencyBit;
        uint256 unknownBit = _deferralBit(SettlementMonitorViewTypes.DepositDeferral.DependencyUnknown);
        if (trancheMask & 1 != 0) {
            status.seniorDepositDeferralMask |= unknownBit;
        }
        if (trancheMask & 2 != 0) {
            status.juniorDepositDeferralMask |= unknownBit;
        }
    }

    function _classifyExecutionPath(
        SettlementMonitorViewTypes.SettlementStatus memory status,
        StatusReadValidity memory validity,
        bool maturedEvidenceComplete
    ) internal pure {
        if (!validity.clock) {
            status.requiredExecutionPath = SettlementMonitorViewTypes.ExecutionPath.Unknown;
        } else if (!status.hasMaturedWork && maturedEvidenceComplete) {
            status.requiredExecutionPath = SettlementMonitorViewTypes.ExecutionPath.NoMaturedWork;
            status.warningMask |= _warningBit(SettlementMonitorViewTypes.Warning.NoMaturedWork);
        } else if (!status.hasMaturedWork || status.executionPathDependencyMask != 0) {
            status.requiredExecutionPath = SettlementMonitorViewTypes.ExecutionPath.Unknown;
        } else if (status.hasOpenPositions && (!status.oracleFrozen || !status.markFresh)) {
            status.requiredExecutionPath = SettlementMonitorViewTypes.ExecutionPath.AtomicOracleRefresh;
            if (!status.oracleFrozen) {
                status.clock.minimumAtomicPublishTime = status.clock.currentEpoch * status.clock.epochDuration;
            }
        } else {
            status.requiredExecutionPath = SettlementMonitorViewTypes.ExecutionPath.CachedMark;
        }

        if (validity.withdrawals && !status.withdrawalsLive) {
            status.operationalBlockerMask |= _operationalBit(
                SettlementMonitorViewTypes.OperationalBlocker.WithdrawalsNotLive
            );
        }
        if (validity.terminal && validity.liquidity && status.hasOpenPositions && !status.markFresh) {
            status.operationalBlockerMask |= _operationalBit(
                SettlementMonitorViewTypes.OperationalBlocker.CachedMarkStale
            );
        }
        if (status.engineDegraded) {
            status.operationalBlockerMask |= _operationalBit(
                SettlementMonitorViewTypes.OperationalBlocker.EngineDegraded
            );
        }
        if (status.clock.additionsOpenByClock) {
            status.warningMask |= _warningBit(SettlementMonitorViewTypes.Warning.AdditionsStillOpen);
        }
        if (status.poolPaused) {
            status.warningMask |= _warningBit(SettlementMonitorViewTypes.Warning.PoolPaused);
        }
        if (status.routerAdminPaused) {
            status.warningMask |= _warningBit(SettlementMonitorViewTypes.Warning.RouterAdminPaused);
        }
        if (status.oracleFrozen) {
            status.warningMask |= _warningBit(SettlementMonitorViewTypes.Warning.OracleFrozen);
        }
        if (status.cachedPreviewTerminalDeficitUsdc != 0) {
            status.warningMask |= _warningBit(SettlementMonitorViewTypes.Warning.TerminalDeficit);
        }
        if (validity.liquidity && status.freeUsdc == 0) {
            status.warningMask |= _warningBit(SettlementMonitorViewTypes.Warning.NoFreeCash);
        }
        if (status.senior.maturedRedeemHeadShares != 0) {
            status.warningMask |= _warningBit(SettlementMonitorViewTypes.Warning.MaturedSeniorPrecedence);
        }
        if (status.clock.additionsClosed && !status.clock.matured) {
            status.warningMask |= _warningBit(SettlementMonitorViewTypes.Warning.ObservationCanStillShrink);
        }
    }

    function _liveMarkAgeLimit() internal view returns (bool ok, uint256 limit) {
        (bool engineOk, uint256 engineLimit) =
            _readUint(address(ENGINE), bytes4(keccak256("engineMarkStalenessLimit()")));
        (bool poolOk, uint256 poolLimit) = _readUint(address(HOUSE_POOL), HousePool.markStalenessLimit.selector);
        if (!engineOk || !poolOk || engineLimit == 0) {
            return (false, 0);
        }
        if (poolLimit == 0 || engineLimit < poolLimit) {
            return (true, engineLimit);
        }
        return (true, poolLimit);
    }

    function _validateStaticBindings(
        address engine_,
        address pool_,
        address clearinghouse_,
        address book_,
        address seniorVault_,
        address juniorVault_,
        address usdc_
    ) private view {
        if (address(HOUSE_POOL.USDC()) != usdc_) {
            revert SettlementMonitorLens__BindingMismatch(BINDING_POOL_USDC, usdc_, address(HOUSE_POOL.USDC()));
        }
        if (address(CLEARINGHOUSE.settlementAsset()) != usdc_) {
            revert SettlementMonitorLens__BindingMismatch(
                BINDING_CLEARINGHOUSE_USDC, usdc_, address(CLEARINGHOUSE.settlementAsset())
            );
        }
        if (CLEARINGHOUSE.engine() != engine_) {
            revert SettlementMonitorLens__BindingMismatch(BINDING_CLEARINGHOUSE_ENGINE, engine_, CLEARINGHOUSE.engine());
        }
        if (TERMINAL_NAV_BOOK.ENGINE() != engine_) {
            revert SettlementMonitorLens__BindingMismatch(BINDING_BOOK_ENGINE, engine_, TERMINAL_NAV_BOOK.ENGINE());
        }
        if (address(SENIOR_VAULT.POOL()) != pool_ || !SENIOR_VAULT.IS_SENIOR()) {
            revert SettlementMonitorLens__BindingMismatch(BINDING_SENIOR_VAULT, pool_, seniorVault_);
        }
        if (address(JUNIOR_VAULT.POOL()) != pool_ || JUNIOR_VAULT.IS_SENIOR()) {
            revert SettlementMonitorLens__BindingMismatch(BINDING_JUNIOR_VAULT, pool_, juniorVault_);
        }
        if (SENIOR_VAULT.asset() != usdc_) {
            revert SettlementMonitorLens__BindingMismatch(BINDING_SENIOR_ASSET, usdc_, SENIOR_VAULT.asset());
        }
        if (JUNIOR_VAULT.asset() != usdc_) {
            revert SettlementMonitorLens__BindingMismatch(BINDING_JUNIOR_ASSET, usdc_, JUNIOR_VAULT.asset());
        }
        if (address(ENGINE.clearinghouse()) != clearinghouse_ || address(ENGINE.terminalNavBook()) != book_) {
            revert SettlementMonitorLens__BindingMismatch(BINDING_ENGINE_DEPENDENCIES, engine_, address(0));
        }
    }

    function _requireCode(
        uint8 dependency,
        address observed
    ) private view {
        if (observed == address(0) || observed.code.length == 0) {
            revert SettlementMonitorLens__InvalidDependency(dependency, observed);
        }
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
        uint256 word;
        (ok, word) = _readUint(target, selector);
        if (!ok || word > 1) {
            return (false, false);
        }
        return (true, word == 1);
    }

    function _readPair(
        address target,
        bytes4 selector,
        uint256 argument,
        bool hasArgument
    ) internal view returns (bool ok, uint256 first, uint256 second) {
        bytes memory input = hasArgument ? abi.encodeWithSelector(selector, argument) : abi.encodeWithSelector(selector);
        uint256[16] memory words;
        (ok, words) = _readWords(target, input, 2);
        first = words[0];
        second = words[1];
    }

    /// @dev Fixed-output staticcall prevents a broken dependency from forcing unbounded returndata allocation.
    function _readWords(
        address target,
        bytes memory input,
        uint256 wordCount
    ) internal view returns (bool ok, uint256[16] memory words) {
        if (target.code.length == 0 || wordCount == 0 || wordCount > MAX_STATIC_WORDS) {
            return (false, words);
        }
        uint256 outputSize = wordCount * 32;
        assembly ("memory-safe") {
            ok := staticcall(STATIC_READ_GAS, target, add(input, 32), mload(input), words, outputSize)
            ok := and(ok, eq(returndatasize(), outputSize))
        }
        if (!ok) {
            assembly ("memory-safe") {
                let cursor := words
                let end := add(words, 0x200)
                for {} lt(cursor, end) { cursor := add(cursor, 0x20) } { mstore(cursor, 0) }
            }
        }
    }

    function _safeMul(
        uint256 a,
        uint256 b
    ) internal pure returns (bool ok, uint256 product) {
        if (a == 0 || b == 0) {
            return (true, 0);
        }
        unchecked {
            product = a * b;
            ok = product / a == b;
        }
    }

    function _saturatingDifference(
        uint256 greater,
        uint256 smaller
    ) internal pure returns (uint256) {
        return greater > smaller ? greater - smaller : 0;
    }

    function _criticalBit(
        SettlementMonitorViewTypes.CriticalFault fault
    ) internal pure returns (uint256) {
        return uint256(1) << uint256(fault);
    }

    function _dependencyBit(
        SettlementMonitorViewTypes.Dependency dependency
    ) internal pure returns (uint256) {
        return uint256(1) << uint256(dependency);
    }

    function _operationalBit(
        SettlementMonitorViewTypes.OperationalBlocker blocker
    ) internal pure returns (uint256) {
        return uint256(1) << uint256(blocker);
    }

    function _warningBit(
        SettlementMonitorViewTypes.Warning warning
    ) internal pure returns (uint256) {
        return uint256(1) << uint256(warning);
    }

    function _deferralBit(
        SettlementMonitorViewTypes.DepositDeferral deferral
    ) internal pure returns (uint256) {
        return uint256(1) << uint256(deferral);
    }

}
