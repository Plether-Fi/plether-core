// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IOrderRouterAdminHost} from "./interfaces/IOrderRouterAdminHost.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract OrderRouterAdmin is Ownable, Pausable {

    uint256 public constant TIMELOCK_DELAY = 48 hours;

    IOrderRouterAdminHost public immutable router;
    mapping(address => uint256) public claimableEth;

    IOrderRouterAdminHost.RouterConfig public pendingRouterConfig;
    uint256 public routerConfigActivationTime;

    error OrderRouterAdmin__TimelockNotReady();
    error OrderRouterAdmin__NoProposal();
    error OrderRouterAdmin__InvalidStalenessLimit();
    error OrderRouterAdmin__InvalidConfidenceRatio();
    error OrderRouterAdmin__Unauthorized();
    error OrderRouterAdmin__NothingToClaim();
    error OrderRouterAdmin__EthTransferFailed();

    event RouterConfigProposed(IOrderRouterAdminHost.RouterConfig config, uint256 activationTime);
    event RouterConfigFinalized(IOrderRouterAdminHost.RouterConfig config);
    event RouterConfigCancelled();

    constructor(address router_, address initialOwner) Ownable(initialOwner) {
        router = IOrderRouterAdminHost(router_);
    }

    modifier onlyRouterHost() {
        if (msg.sender != address(router)) {
            revert OrderRouterAdmin__Unauthorized();
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

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function creditClaimableEth(address beneficiary, uint256 amount) external onlyRouterHost {
        if (amount == 0) {
            return;
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
    }
}
