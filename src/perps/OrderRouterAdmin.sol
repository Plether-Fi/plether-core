// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IOrderRouterAdminHost} from "./interfaces/IOrderRouterAdminHost.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Timelocked two-step owner-controlled admin for OrderRouter queue, bounty, oracle, and pause configuration.
contract OrderRouterAdmin is Ownable2Step, Pausable {

    uint256 public constant TIMELOCK_DELAY = 48 hours;
    uint256 internal constant MAX_PENDING_ORDERS_LIMIT = 32;
    uint256 internal constant MAX_CLOSE_ORDER_EXECUTION_BOUNTY_USDC = 1_000_000;
    uint256 internal constant MIN_ENGINE_GAS_FLOOR = 100_000;
    uint256 internal constant MIN_ENGINE_GAS_CAP = 5_000_000;
    uint256 internal constant MAX_PRUNE_ORDERS_PER_CALL_LIMIT = 256;
    uint256 internal constant MAX_ORDER_AGE_LIMIT = 1 hours;
    uint256 internal constant MAX_CONFIDENCE_MULTIPLIER_BPS = 30_000;

    IOrderRouterAdminHost public immutable router;
    mapping(address => uint256) public claimableEth;
    address public pauser;

    IOrderRouterAdminHost.RouterConfig private _pendingRouterConfig;
    uint256 public routerConfigActivationTime;
    IOrderRouterAdminHost.OracleConfig private _pendingOracleConfig;
    uint256 public oracleConfigActivationTime;

    error OrderRouterAdmin__TimelockNotReady();
    error OrderRouterAdmin__NoProposal();
    error OrderRouterAdmin__InvalidMaxOrderAge();
    error OrderRouterAdmin__InvalidStalenessLimit();
    error OrderRouterAdmin__InvalidConfidenceRatio();
    error OrderRouterAdmin__InvalidExecutionBounty();
    error OrderRouterAdmin__InvalidPendingOrderLimit();
    error OrderRouterAdmin__InvalidGasLimit();
    error OrderRouterAdmin__InvalidOracleConfig();
    error OrderRouterAdmin__Unauthorized();
    error OrderRouterAdmin__UnauthorizedPauser();
    error OrderRouterAdmin__NothingToClaim();
    error OrderRouterAdmin__EthTransferFailed();
    error OrderRouterAdmin__EthAmountMismatch();

    event RouterConfigProposed(IOrderRouterAdminHost.RouterConfig config, uint256 activationTime);
    event RouterConfigFinalized(IOrderRouterAdminHost.RouterConfig config);
    event RouterConfigCancelled();
    event OracleConfigProposed(IOrderRouterAdminHost.OracleConfig config, uint256 activationTime);
    event OracleConfigFinalized(IOrderRouterAdminHost.OracleConfig config);
    event OracleConfigCancelled();
    event PauserUpdated(address indexed previousPauser, address indexed newPauser);

    /// @param router_ Router host that receives finalized configuration
    /// @param initialOwner Owner allowed to propose, cancel, finalize, and unpause
    constructor(
        address router_,
        address initialOwner
    ) Ownable(initialOwner) {
        router = IOrderRouterAdminHost(router_);
    }

    modifier onlyRouterHost() {
        if (msg.sender != address(router)) {
            revert OrderRouterAdmin__Unauthorized();
        }
        _;
    }

    modifier onlyPauserOrOwner() {
        if (msg.sender != owner() && msg.sender != pauser) {
            revert OrderRouterAdmin__UnauthorizedPauser();
        }
        _;
    }

    /// @notice Proposes router queue, bounty, and execution bounds behind the timelock.
    /// @param config Router configuration to validate and stage
    function proposeRouterConfig(
        IOrderRouterAdminHost.RouterConfig calldata config
    ) external onlyOwner {
        _validateRouterConfig(config);
        _pendingRouterConfig = config;
        routerConfigActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit RouterConfigProposed(config, routerConfigActivationTime);
    }

    /// @notice Finalizes the pending router configuration after the timelock expires.
    function finalizeRouterConfig() external onlyOwner {
        _requireTimelockReady(routerConfigActivationTime);
        IOrderRouterAdminHost.RouterConfig memory config = _pendingRouterConfig;
        delete _pendingRouterConfig;
        routerConfigActivationTime = 0;
        router.applyRouterConfig(config);
        emit RouterConfigFinalized(config);
    }

    /// @notice Cancels any pending router configuration.
    function cancelRouterConfig() external onlyOwner {
        delete _pendingRouterConfig;
        routerConfigActivationTime = 0;
        emit RouterConfigCancelled();
    }

    /// @notice Proposes the router oracle address behind the timelock.
    /// @param config Oracle configuration to validate and stage
    function proposeOracleConfig(
        IOrderRouterAdminHost.OracleConfig calldata config
    ) external onlyOwner {
        _validateOracleConfig(config);
        _pendingOracleConfig.pletherOracle = config.pletherOracle;
        oracleConfigActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit OracleConfigProposed(config, oracleConfigActivationTime);
    }

    /// @notice Finalizes the pending oracle configuration after the timelock expires.
    function finalizeOracleConfig() external onlyOwner {
        _requireTimelockReady(oracleConfigActivationTime);
        IOrderRouterAdminHost.OracleConfig memory config = _pendingOracleConfig;
        delete _pendingOracleConfig;
        oracleConfigActivationTime = 0;
        router.applyOracleConfig(config);
        emit OracleConfigFinalized(config);
    }

    /// @notice Cancels any pending oracle configuration.
    function cancelOracleConfig() external onlyOwner {
        delete _pendingOracleConfig;
        oracleConfigActivationTime = 0;
        emit OracleConfigCancelled();
    }

    /// @notice Returns the pending oracle configuration.
    /// @return config Pending oracle configuration
    function getPendingOracleConfig() external view returns (IOrderRouterAdminHost.OracleConfig memory config) {
        config = _pendingOracleConfig;
    }

    /// @notice Returns the pending router configuration.
    /// @return config Pending router configuration
    function pendingRouterConfig() external view returns (IOrderRouterAdminHost.RouterConfig memory config) {
        config = _pendingRouterConfig;
    }

    /// @notice Updates the account allowed to pause alongside the owner.
    /// @param newPauser New emergency pauser account
    function setPauser(
        address newPauser
    ) external onlyOwner {
        emit PauserUpdated(pauser, newPauser);
        pauser = newPauser;
    }

    /// @notice Pauses router-controlled execution paths; callable by owner or configured pauser.
    function pause() external onlyPauserOrOwner {
        _pause();
    }

    /// @notice Unpauses router-controlled execution paths; callable only by owner.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Records ETH owed to a beneficiary after router-side refund forwarding fails or is deferred.
    /// @param beneficiary Account credited with claimable ETH
    /// @param amount ETH amount credited; must match msg.value
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
    /// @param ethBalance Must be true; retained for compatibility with the public claim interface shape
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

    function _validateOrderAge(
        uint256 maxOrderAge
    ) private pure {
        if (maxOrderAge == 0 || maxOrderAge > MAX_ORDER_AGE_LIMIT) {
            revert OrderRouterAdmin__InvalidMaxOrderAge();
        }
    }

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

    function _validatePendingOrderLimit(
        uint256 maxPendingOrders
    ) private pure {
        if (maxPendingOrders == 0 || maxPendingOrders > MAX_PENDING_ORDERS_LIMIT) {
            revert OrderRouterAdmin__InvalidPendingOrderLimit();
        }
    }

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

    function _validateOracleConfig(
        IOrderRouterAdminHost.OracleConfig calldata config
    ) internal view {
        if (config.pletherOracle == address(0) || config.pletherOracle.code.length == 0) {
            revert OrderRouterAdmin__InvalidOracleConfig();
        }
    }

}
