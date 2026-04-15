// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IOrderRouterAdminHost} from "./interfaces/IOrderRouterAdminHost.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract OrderRouterAdmin is Ownable, Pausable {

    uint256 public constant TIMELOCK_DELAY = 48 hours;

    IOrderRouterAdminHost public immutable router;
    mapping(address => uint256) public claimableEth;

    uint256 public pendingMaxOrderAge;
    uint256 public maxOrderAgeActivationTime;

    uint256 public pendingOrderExecutionStalenessLimit;
    uint256 public orderExecutionStalenessActivationTime;

    uint256 public pendingLiquidationStalenessLimit;
    uint256 public liquidationStalenessActivationTime;

    uint256 public pendingPythMaxConfidenceRatioBps;
    uint256 public pythMaxConfidenceRatioActivationTime;

    error OrderRouterAdmin__TimelockNotReady();
    error OrderRouterAdmin__NoProposal();
    error OrderRouterAdmin__InvalidStalenessLimit();
    error OrderRouterAdmin__InvalidConfidenceRatio();
    error OrderRouterAdmin__Unauthorized();
    error OrderRouterAdmin__NothingToClaim();
    error OrderRouterAdmin__EthTransferFailed();

    event MaxOrderAgeProposed(uint256 newMaxOrderAge, uint256 activationTime);
    event MaxOrderAgeFinalized(uint256 newMaxOrderAge);
    event OrderExecutionStalenessLimitProposed(uint256 newLimit, uint256 activationTime);
    event OrderExecutionStalenessLimitFinalized(uint256 newLimit);
    event LiquidationStalenessLimitProposed(uint256 newLimit, uint256 activationTime);
    event LiquidationStalenessLimitFinalized(uint256 newLimit);
    event PythMaxConfidenceRatioBpsProposed(uint256 newRatioBps, uint256 activationTime);
    event PythMaxConfidenceRatioBpsFinalized(uint256 newRatioBps);

    constructor(address router_, address initialOwner) Ownable(initialOwner) {
        router = IOrderRouterAdminHost(router_);
    }

    modifier onlyRouterHost() {
        if (msg.sender != address(router)) {
            revert OrderRouterAdmin__Unauthorized();
        }
        _;
    }

    function proposeMaxOrderAge(
        uint256 newMaxOrderAge
    ) external onlyOwner {
        pendingMaxOrderAge = newMaxOrderAge;
        maxOrderAgeActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit MaxOrderAgeProposed(newMaxOrderAge, maxOrderAgeActivationTime);
    }

    function finalizeMaxOrderAge() external onlyOwner {
        _requireTimelockReady(maxOrderAgeActivationTime);
        uint256 nextValue = pendingMaxOrderAge;
        pendingMaxOrderAge = 0;
        maxOrderAgeActivationTime = 0;
        router.setMaxOrderAge(nextValue);
        emit MaxOrderAgeFinalized(nextValue);
    }

    function proposeOrderExecutionStalenessLimit(
        uint256 limit
    ) external onlyOwner {
        if (limit == 0) {
            revert OrderRouterAdmin__InvalidStalenessLimit();
        }
        pendingOrderExecutionStalenessLimit = limit;
        orderExecutionStalenessActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit OrderExecutionStalenessLimitProposed(limit, orderExecutionStalenessActivationTime);
    }

    function finalizeOrderExecutionStalenessLimit() external onlyOwner {
        _requireTimelockReady(orderExecutionStalenessActivationTime);
        uint256 nextValue = pendingOrderExecutionStalenessLimit;
        pendingOrderExecutionStalenessLimit = 0;
        orderExecutionStalenessActivationTime = 0;
        router.setOrderExecutionStalenessLimit(nextValue);
        emit OrderExecutionStalenessLimitFinalized(nextValue);
    }

    function proposeLiquidationStalenessLimit(
        uint256 limit
    ) external onlyOwner {
        if (limit == 0) {
            revert OrderRouterAdmin__InvalidStalenessLimit();
        }
        pendingLiquidationStalenessLimit = limit;
        liquidationStalenessActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit LiquidationStalenessLimitProposed(limit, liquidationStalenessActivationTime);
    }

    function finalizeLiquidationStalenessLimit() external onlyOwner {
        _requireTimelockReady(liquidationStalenessActivationTime);
        uint256 nextValue = pendingLiquidationStalenessLimit;
        pendingLiquidationStalenessLimit = 0;
        liquidationStalenessActivationTime = 0;
        router.setLiquidationStalenessLimit(nextValue);
        emit LiquidationStalenessLimitFinalized(nextValue);
    }

    function proposePythMaxConfidenceRatioBps(
        uint256 ratioBps
    ) external onlyOwner {
        if (ratioBps > 10_000) {
            revert OrderRouterAdmin__InvalidConfidenceRatio();
        }
        pendingPythMaxConfidenceRatioBps = ratioBps;
        pythMaxConfidenceRatioActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit PythMaxConfidenceRatioBpsProposed(ratioBps, pythMaxConfidenceRatioActivationTime);
    }

    function finalizePythMaxConfidenceRatioBps() external onlyOwner {
        _requireTimelockReady(pythMaxConfidenceRatioActivationTime);
        uint256 nextValue = pendingPythMaxConfidenceRatioBps;
        pendingPythMaxConfidenceRatioBps = 0;
        pythMaxConfidenceRatioActivationTime = 0;
        router.setPythMaxConfidenceRatioBps(nextValue);
        emit PythMaxConfidenceRatioBpsFinalized(nextValue);
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
}
