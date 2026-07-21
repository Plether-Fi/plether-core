// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";

/// @title OrderRouterAdmin
/// @notice Timelocked two-step owner administration for router queue, bounty, oracle, gas, and pause settings.
/// @dev Router and oracle configurations have independent proposal slots and activation clocks. Emergency
///      pausing is immediate and blocks new risk-increasing commits only; execution, close commits, mark refresh,
///      and liquidation remain available. Only the owner may unpause.
contract OrderRouterAdmin is Ownable2Step, Pausable {

    /// @notice Delay between a configuration proposal and its earliest finalization (48 hours).
    uint256 public constant TIMELOCK_DELAY = 48 hours;
    /// @notice Upper bound for live pending orders per account.
    uint256 internal constant MAX_PENDING_ORDERS_LIMIT = 32;
    /// @notice Upper bound for the fixed close-order bounty (6-decimal USDC; $1).
    uint256 internal constant MAX_CLOSE_ORDER_EXECUTION_BOUNTY_USDC = 1_000_000;
    /// @notice Lower bound for minimum engine-call gas.
    uint256 internal constant MIN_ENGINE_GAS_FLOOR = 100_000;
    /// @notice Upper bound for minimum engine-call gas.
    uint256 internal constant MIN_ENGINE_GAS_CAP = 5_000_000;
    /// @notice Upper bound for expired orders pruned in one execution call.
    uint256 internal constant MAX_PRUNE_ORDERS_PER_CALL_LIMIT = 256;
    /// @notice Upper bound for pending order lifetime.
    uint256 internal constant MAX_ORDER_AGE_LIMIT = 1 hours;
    /// @notice Upper bound for the adverse confidence multiplier in basis points (3x).
    uint256 internal constant MAX_CONFIDENCE_MULTIPLIER_BPS = 30_000;

    /// @notice Router host controlled by this admin.
    IOrderRouterAdminHost public immutable router;
    /// @notice Deferred ETH refund balance claimable by each beneficiary, denominated in wei.
    mapping(address => uint256) public claimableEth;
    /// @notice Account allowed to pause alongside the owner; the zero address disables the separate pauser.
    address public pauser;

    IOrderRouterAdminHost.RouterConfig private _pendingRouterConfig;
    /// @notice Earliest Unix timestamp at which the pending router configuration can be finalized, or zero if none.
    uint256 public routerConfigActivationTime;
    IOrderRouterAdminHost.OracleConfig private _pendingOracleConfig;
    /// @notice Earliest Unix timestamp at which the pending oracle configuration can be finalized, or zero if none.
    uint256 public oracleConfigActivationTime;

    /// @notice The pending configuration's activation time has not yet been reached.
    error OrderRouterAdmin__TimelockNotReady();
    /// @notice Finalization was requested without an active proposal.
    error OrderRouterAdmin__NoProposal();
    /// @notice The proposed maximum order age is zero or exceeds the one-hour limit.
    error OrderRouterAdmin__InvalidMaxOrderAge();
    /// @notice A staleness, settlement-window, or component-divergence limit is inconsistent or zero.
    error OrderRouterAdmin__InvalidStalenessLimit();
    /// @notice A confidence ratio or adverse-confidence multiplier exceeds its allowed bound.
    error OrderRouterAdmin__InvalidConfidenceRatio();
    /// @notice An open-notional or execution-bounty setting is zero, inconsistent, or out of bounds.
    error OrderRouterAdmin__InvalidExecutionBounty();
    /// @notice The pending-order limit is zero or greater than 32.
    error OrderRouterAdmin__InvalidPendingOrderLimit();
    /// @notice The minimum engine gas or per-call prune limit is outside its allowed range.
    error OrderRouterAdmin__InvalidGasLimit();
    /// @notice The proposed Plether oracle is the zero address or has no deployed code.
    error OrderRouterAdmin__InvalidOracleConfig();
    /// @notice A caller other than the configured router attempted a router-host-only operation.
    error OrderRouterAdmin__Unauthorized();
    /// @notice A caller other than the owner or configured pauser attempted to pause.
    error OrderRouterAdmin__UnauthorizedPauser();
    /// @notice An ETH claim was disabled by its flag or the caller had no deferred balance.
    error OrderRouterAdmin__NothingToClaim();
    /// @notice Transferring a claimed ETH balance to its beneficiary failed.
    error OrderRouterAdmin__EthTransferFailed();
    /// @notice A positive deferred-refund credit did not equal the ETH attached by the router.
    error OrderRouterAdmin__EthAmountMismatch();

    /// @notice Emitted when a router configuration is staged or replaces an earlier pending proposal.
    /// @param config Validated configuration that was staged.
    /// @param activationTime Earliest Unix timestamp at which `config` may be finalized.
    event RouterConfigProposed(IOrderRouterAdminHost.RouterConfig config, uint256 activationTime);
    /// @notice Emitted after a pending router configuration is applied to the router.
    /// @param config Configuration that was applied.
    event RouterConfigFinalized(IOrderRouterAdminHost.RouterConfig config);
    /// @notice Emitted when the pending router configuration and activation time are cleared.
    event RouterConfigCancelled();
    /// @notice Emitted when an oracle configuration is staged or replaces an earlier pending proposal.
    /// @param config Validated oracle configuration that was staged.
    /// @param activationTime Earliest Unix timestamp at which `config` may be finalized.
    event OracleConfigProposed(IOrderRouterAdminHost.OracleConfig config, uint256 activationTime);
    /// @notice Emitted after a pending oracle configuration is applied to the router.
    /// @param config Oracle configuration that was applied.
    event OracleConfigFinalized(IOrderRouterAdminHost.OracleConfig config);
    /// @notice Emitted when the pending oracle configuration and activation time are cleared.
    event OracleConfigCancelled();
    /// @notice Emitted when the emergency pauser is changed.
    /// @param previousPauser Previously configured pauser.
    /// @param newPauser Newly configured pauser, which may be the zero address.
    event PauserUpdated(address indexed previousPauser, address indexed newPauser);

    /// @notice Creates an admin for a fixed router host and starts two-step ownership at `initialOwner`.
    /// @dev Neither address is validated here. Ownership transfers use `Ownable2Step` proposal and acceptance.
    /// @param router_ Router host that receives finalized configuration and may credit deferred ETH.
    /// @param initialOwner Owner allowed to propose, cancel, finalize, configure the pauser, and unpause.
    constructor(
        address router_,
        address initialOwner
    ) Ownable(initialOwner) {
        router = IOrderRouterAdminHost(router_);
    }

    /// @notice Restricts a function to the immutable router host.
    modifier onlyRouterHost() {
        if (msg.sender != address(router)) {
            revert OrderRouterAdmin__Unauthorized();
        }
        _;
    }

    /// @notice Restricts a function to the owner or current emergency pauser.
    modifier onlyPauserOrOwner() {
        if (msg.sender != owner() && msg.sender != pauser) {
            revert OrderRouterAdmin__UnauthorizedPauser();
        }
        _;
    }

    /// @notice Proposes router queue, bounty, and execution bounds behind the timelock.
    /// @dev Owner only. A valid proposal replaces any pending router proposal and restarts its 48-hour delay.
    ///      Time fields are seconds, monetary fields are 6-decimal USDC, gas fields are gas units, ratios are
    ///      basis points except where the host struct specifies otherwise, and order ids/counts are unscaled.
    /// @param config Router configuration to validate and stage.
    function proposeRouterConfig(
        IOrderRouterAdminHost.RouterConfig calldata config
    ) external onlyOwner {
        _validateRouterConfig(config);
        _pendingRouterConfig = config;
        routerConfigActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit RouterConfigProposed(config, routerConfigActivationTime);
    }

    /// @notice Finalizes the pending router configuration after the timelock expires.
    /// @dev Owner only. Clears the pending slot and calls `router.applyRouterConfig`; a router revert rolls
    ///      back both the clearing and this finalization.
    function finalizeRouterConfig() external onlyOwner {
        _requireTimelockReady(routerConfigActivationTime);
        IOrderRouterAdminHost.RouterConfig memory config = _pendingRouterConfig;
        delete _pendingRouterConfig;
        routerConfigActivationTime = 0;
        router.applyRouterConfig(config);
        emit RouterConfigFinalized(config);
    }

    /// @notice Cancels any pending router configuration.
    /// @dev Owner only. Succeeds and emits even when no proposal exists.
    function cancelRouterConfig() external onlyOwner {
        delete _pendingRouterConfig;
        routerConfigActivationTime = 0;
        emit RouterConfigCancelled();
    }

    /// @notice Proposes the router oracle address behind the timelock.
    /// @dev Owner only. The oracle must have deployed code. A valid proposal replaces any pending oracle
    ///      proposal and restarts its independent 48-hour delay; full engine/pool wiring is checked by the router on finalization.
    /// @param config Oracle-address configuration to validate and stage.
    function proposeOracleConfig(
        IOrderRouterAdminHost.OracleConfig calldata config
    ) external onlyOwner {
        _validateOracleConfig(config);
        _pendingOracleConfig.pletherOracle = config.pletherOracle;
        oracleConfigActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit OracleConfigProposed(config, oracleConfigActivationTime);
    }

    /// @notice Finalizes the pending oracle configuration after the timelock expires.
    /// @dev Owner only. Clears the pending slot and calls `router.applyOracleConfig`; a router revert rolls
    ///      back both the clearing and this finalization.
    function finalizeOracleConfig() external onlyOwner {
        _requireTimelockReady(oracleConfigActivationTime);
        IOrderRouterAdminHost.OracleConfig memory config = _pendingOracleConfig;
        delete _pendingOracleConfig;
        oracleConfigActivationTime = 0;
        router.applyOracleConfig(config);
        emit OracleConfigFinalized(config);
    }

    /// @notice Cancels any pending oracle configuration.
    /// @dev Owner only. Succeeds and emits even when no proposal exists.
    function cancelOracleConfig() external onlyOwner {
        delete _pendingOracleConfig;
        oracleConfigActivationTime = 0;
        emit OracleConfigCancelled();
    }

    /// @notice Returns the pending oracle configuration.
    /// @dev Returns a zero-valued struct when no oracle proposal exists; inspect `oracleConfigActivationTime` to distinguish it.
    /// @return config Pending oracle configuration.
    function getPendingOracleConfig() external view returns (IOrderRouterAdminHost.OracleConfig memory config) {
        config = _pendingOracleConfig;
    }

    /// @notice Returns the pending router configuration.
    /// @dev Returns a zero-valued struct when no router proposal exists; inspect `routerConfigActivationTime` to distinguish it.
    /// @return config Pending router configuration.
    function pendingRouterConfig() external view returns (IOrderRouterAdminHost.RouterConfig memory config) {
        config = _pendingRouterConfig;
    }

    /// @notice Updates the account allowed to pause alongside the owner.
    /// @dev Owner only. Setting the zero address disables the separate emergency pauser.
    /// @param newPauser New emergency pauser account.
    function setPauser(
        address newPauser
    ) external onlyOwner {
        emit PauserUpdated(pauser, newPauser);
        pauser = newPauser;
    }

    /// @notice Activates the emergency gate on new risk-increasing order commits.
    /// @dev Callable by the owner or configured pauser. Close commits, queued-order execution, mark refresh,
    ///      and liquidation are intentionally not blocked by this pause flag.
    function pause() external onlyPauserOrOwner {
        _pause();
    }

    /// @notice Removes the emergency gate on new risk-increasing commits; callable only by owner.
    /// @dev Re-enables commits with respect to this pause flag; other close-only and risk gates still apply.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Records ETH owed to a beneficiary after router-side refund forwarding fails or is deferred.
    /// @dev Callable only by the immutable router. For a positive amount, `msg.value` must match exactly.
    ///      A zero amount is a no-op and returns before checking `msg.value`.
    /// @param beneficiary Account credited with claimable ETH; the zero address is permitted.
    /// @param amount ETH amount to credit in wei.
    function creditClaimableEth(
        address beneficiary,
        uint256 amount
    ) external payable onlyRouterHost {
        if (amount == 0) {
            return;
        }
        if (msg.value != amount) {
            revert OrderRouterAdmin__EthAmountMismatch();
        }
        claimableEth[beneficiary] += amount;
    }

    /// @notice Claims deferred ETH refunds owed to the caller.
    /// @dev Uses checks-effects-interactions: the balance is cleared before transfer and restored if the call reverts.
    /// @param ethBalance Must be true; retained for compatibility with the public claim interface shape.
    function claimBalance(
        bool ethBalance
    ) external {
        if (!ethBalance) {
            revert OrderRouterAdmin__NothingToClaim();
        }
        uint256 amount = claimableEth[msg.sender];
        if (amount == 0) {
            revert OrderRouterAdmin__NothingToClaim();
        }
        claimableEth[msg.sender] = 0;
        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) {
            revert OrderRouterAdmin__EthTransferFailed();
        }
    }

    /// @notice Requires an existing proposal whose activation timestamp has been reached.
    /// @param activationTime Pending proposal activation timestamp, or zero when absent.
    function _requireTimelockReady(
        uint256 activationTime
    ) internal view {
        if (activationTime == 0) {
            revert OrderRouterAdmin__NoProposal();
        }
        if (block.timestamp < activationTime) {
            revert OrderRouterAdmin__TimelockNotReady();
        }
    }

    /// @notice Validates all router configuration bounds and cross-field relationships.
    /// @param config Candidate router configuration.
    function _validateRouterConfig(
        IOrderRouterAdminHost.RouterConfig memory config
    ) internal pure {
        _validateOrderAge(config.maxOrderAge);
        _validateStalenessConfig(config);
        _validateConfidenceConfig(config);
        _validateExecutionBountyConfig(config);
        _validatePendingOrderLimit(config.maxPendingOrders);
        _validateGasConfig(config.minEngineGas, config.maxPruneOrdersPerCall);
    }

    /// @notice Validates a nonzero maximum order age no greater than one hour.
    /// @param maxOrderAge Candidate maximum age in seconds.
    function _validateOrderAge(
        uint256 maxOrderAge
    ) private pure {
        if (maxOrderAge == 0 || maxOrderAge > MAX_ORDER_AGE_LIMIT) {
            revert OrderRouterAdmin__InvalidMaxOrderAge();
        }
    }

    /// @notice Validates nonzero freshness windows and settlement/divergence ordering.
    /// @param config Candidate router configuration.
    function _validateStalenessConfig(
        IOrderRouterAdminHost.RouterConfig memory config
    ) private pure {
        if (
            config.orderExecutionStalenessLimit == 0 || config.liquidationStalenessLimit == 0
                || config.orderSettlementWindow == 0 || config.orderSettlementWindow > config.maxOrderAge
                || config.maxComponentPublishTimeDivergence == 0
                || config.maxComponentPublishTimeDivergence > config.orderSettlementWindow
        ) {
            revert OrderRouterAdmin__InvalidStalenessLimit();
        }
    }

    /// @notice Validates confidence ratio and adverse multiplier basis-point bounds.
    /// @param config Candidate router configuration.
    function _validateConfidenceConfig(
        IOrderRouterAdminHost.RouterConfig memory config
    ) private pure {
        if (
            config.pythMaxConfidenceRatioBps > 10_000
                || config.adverseConfidenceMultiplierBps > MAX_CONFIDENCE_MULTIPLIER_BPS
        ) {
            revert OrderRouterAdmin__InvalidConfidenceRatio();
        }
    }

    /// @notice Validates open-notional and execution-bounty floors, caps, and basis-point rate.
    /// @param config Candidate router configuration; monetary values use 6-decimal USDC.
    function _validateExecutionBountyConfig(
        IOrderRouterAdminHost.RouterConfig memory config
    ) private pure {
        if (config.minOpenNotionalUsdc == 0) {
            revert OrderRouterAdmin__InvalidExecutionBounty();
        }
        if (
            config.openOrderExecutionBountyBps == 0 || config.openOrderExecutionBountyBps > 10_000
                || config.minOpenOrderExecutionBountyUsdc == 0 || config.maxOpenOrderExecutionBountyUsdc == 0
                || config.closeOrderExecutionBountyUsdc == 0
                || config.closeOrderExecutionBountyUsdc > MAX_CLOSE_ORDER_EXECUTION_BOUNTY_USDC
                || config.minOpenOrderExecutionBountyUsdc > config.maxOpenOrderExecutionBountyUsdc
        ) {
            revert OrderRouterAdmin__InvalidExecutionBounty();
        }
    }

    /// @notice Validates a per-account pending-order limit between 1 and 32.
    /// @param maxPendingOrders Candidate unscaled order count.
    function _validatePendingOrderLimit(
        uint256 maxPendingOrders
    ) private pure {
        if (maxPendingOrders == 0 || maxPendingOrders > MAX_PENDING_ORDERS_LIMIT) {
            revert OrderRouterAdmin__InvalidPendingOrderLimit();
        }
    }

    /// @notice Validates the engine-call gas floor and per-call expired-order prune cap.
    /// @param minEngineGas Candidate minimum forwardable engine gas, bounded from 100,000 to 5,000,000.
    /// @param maxPruneOrdersPerCall Candidate prune cap, bounded from 1 to 256.
    function _validateGasConfig(
        uint256 minEngineGas,
        uint256 maxPruneOrdersPerCall
    ) private pure {
        if (minEngineGas < MIN_ENGINE_GAS_FLOOR || minEngineGas > MIN_ENGINE_GAS_CAP) {
            revert OrderRouterAdmin__InvalidGasLimit();
        }
        if (maxPruneOrdersPerCall == 0 || maxPruneOrdersPerCall > MAX_PRUNE_ORDERS_PER_CALL_LIMIT) {
            revert OrderRouterAdmin__InvalidGasLimit();
        }
    }

    /// @notice Validates that the proposed Plether oracle is a nonzero deployed contract.
    /// @param config Candidate oracle-address configuration.
    function _validateOracleConfig(
        IOrderRouterAdminHost.OracleConfig calldata config
    ) internal view {
        if (config.pletherOracle == address(0) || config.pletherOracle.code.length == 0) {
            revert OrderRouterAdmin__InvalidOracleConfig();
        }
    }

}
