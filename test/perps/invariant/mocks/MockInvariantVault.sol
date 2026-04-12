// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ICfdVault} from "../../../../src/perps/interfaces/ICfdVault.sol";
import {MockUSDC} from "../../../mocks/MockUSDC.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockInvariantVault is ICfdVault {

    using SafeERC20 for MockUSDC;

    MockUSDC public immutable usdc;
    address public immutable engine;
    address public orderRouter;
    bool public failRouterPayouts;

    error MockInvariantVault__RouterAlreadySet();
    error MockInvariantVault__ForcedRouterPayoutFailure();

    constructor(
        address _usdc,
        address _engine
    ) {
        usdc = MockUSDC(_usdc);
        engine = _engine;
    }

    function setOrderRouter(
        address _orderRouter
    ) external {
        if (orderRouter != address(0)) {
            revert MockInvariantVault__RouterAlreadySet();
        }
        orderRouter = _orderRouter;
    }

    function setFailRouterPayouts(
        bool shouldFail
    ) external {
        failRouterPayouts = shouldFail;
    }

    function seedAssets(
        uint256 amountUsdc
    ) external {
        usdc.mint(address(this), amountUsdc);
    }

    function setAssets(
        uint256 targetAmountUsdc
    ) external {
        uint256 currentAssets = usdc.balanceOf(address(this));
        if (targetAmountUsdc > currentAssets) {
            usdc.mint(address(this), targetAmountUsdc - currentAssets);
        } else if (currentAssets > targetAmountUsdc) {
            usdc.burn(address(this), currentAssets - targetAmountUsdc);
        }
    }

    function totalAssets() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function payOut(
        address recipient,
        uint256 amount
    ) external {
        if (msg.sender != engine && msg.sender != orderRouter) {
            revert("unauthorized");
        }
        if (msg.sender == orderRouter && failRouterPayouts) {
            revert MockInvariantVault__ForcedRouterPayoutFailure();
        }
        usdc.safeTransfer(recipient, amount);
    }

    function recordProtocolInflow(
        uint256
    ) external view {
        if (msg.sender != engine) {
            revert("unauthorized");
        }
    }

    function recordRecapitalizationInflow(
        uint256
    ) external view {
        if (msg.sender != engine) {
            revert("unauthorized");
        }
    }

    function routeLpValue(
        uint256,
        ICfdVault.LpValueMode
    ) external view {
        if (msg.sender != engine) {
            revert("unauthorized");
        }
    }

    function markStalenessLimit() external pure returns (uint256) {
        return 120;
    }

    function isSeedLifecycleComplete() external pure returns (bool) {
        return true;
    }

    function hasSeedLifecycleStarted() external pure returns (bool) {
        return true;
    }

    function canAcceptOrdinaryDeposits() external pure returns (bool) {
        return true;
    }

    function canIncreaseRisk() external pure returns (bool) {
        return true;
    }

    function isTradingActive() external pure returns (bool) {
        return true;
    }

}
