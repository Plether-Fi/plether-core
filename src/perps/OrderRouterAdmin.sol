// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IOrderRouterAdminHost} from "./interfaces/IOrderRouterAdminHost.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract OrderRouterAdmin is Ownable, Pausable {

    uint256 public constant TIMELOCK_DELAY = 48 hours;
    uint256 internal constant MAX_PENDING_ORDERS_LIMIT = 32;
    uint256 internal constant MAX_CLOSE_ORDER_EXECUTION_BOUNTY_USDC = 1_000_000;
    uint256 internal constant MIN_ENGINE_GAS_FLOOR = 100_000;
    uint256 internal constant MIN_ENGINE_GAS_CAP = 5_000_000;
    uint256 internal constant MAX_PRUNE_ORDERS_PER_CALL_LIMIT = 256;

    IOrderRouterAdminHost public immutable router;
    mapping(address => uint256) public claimableEth;
    address public pauser;

    IOrderRouterAdminHost.RouterConfig public pendingRouterConfig;
    uint256 public routerConfigActivationTime;

    error OrderRouterAdmin__TimelockNotReady();
    error OrderRouterAdmin__NoProposal();
    error OrderRouterAdmin__InvalidStalenessLimit();
    error OrderRouterAdmin__InvalidConfidenceRatio();
    error OrderRouterAdmin__InvalidExecutionBounty();
    error OrderRouterAdmin__InvalidPendingOrderLimit();
    error OrderRouterAdmin__InvalidGasLimit();
    error OrderRouterAdmin__Unauthorized();
    error OrderRouterAdmin__UnauthorizedPauser();
    error OrderRouterAdmin__NothingToClaim();
    error OrderRouterAdmin__EthTransferFailed();
    error OrderRouterAdmin__EthAmountMismatch();

    event RouterConfigProposed(IOrderRouterAdminHost.RouterConfig config, uint256 activationTime);
    event RouterConfigFinalized(IOrderRouterAdminHost.RouterConfig config);
    event RouterConfigCancelled();
    event PauserUpdated(address indexed previousPauser, address indexed newPauser);

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

    function proposeRouterConfig(
        IOrderRouterAdminHost.RouterConfig calldata config
    ) external onlyOwner {
        _validateRouterConfig(config);
        pendingRouterConfig = config;
        routerConfigActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit RouterConfigProposed(config, routerConfigActivationTime);
    }

    function finalizeRouterConfig() external onlyOwner {
        _requireTimelockReady(routerConfigActivationTime);
        IOrderRouterAdminHost.RouterConfig memory config = pendingRouterConfig;
        delete pendingRouterConfig;
        routerConfigActivationTime = 0;
        router.applyRouterConfig(config);
        emit RouterConfigFinalized(config);
    }

    function cancelRouterConfig() external onlyOwner {
        delete pendingRouterConfig;
        routerConfigActivationTime = 0;
        emit RouterConfigCancelled();
    }

    function setPauser(
        address newPauser
    ) external onlyOwner {
        emit PauserUpdated(pauser, newPauser);
        pauser = newPauser;
    }

    function pause() external onlyPauserOrOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

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
        if (config.orderExecutionStalenessLimit == 0 || config.liquidationStalenessLimit == 0) {
            revert OrderRouterAdmin__InvalidStalenessLimit();
        }
        if (config.pythMaxConfidenceRatioBps > 10_000) {
            revert OrderRouterAdmin__InvalidConfidenceRatio();
        }
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
        if (config.maxPendingOrders == 0 || config.maxPendingOrders > MAX_PENDING_ORDERS_LIMIT) {
            revert OrderRouterAdmin__InvalidPendingOrderLimit();
        }
        if (
            config.minEngineGas < MIN_ENGINE_GAS_FLOOR || config.minEngineGas > MIN_ENGINE_GAS_CAP
                || config.maxPruneOrdersPerCall == 0 || config.maxPruneOrdersPerCall > MAX_PRUNE_ORDERS_PER_CALL_LIMIT
        ) {
            revert OrderRouterAdmin__InvalidGasLimit();
        }
    }

}
