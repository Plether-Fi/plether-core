// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ICfdEngine {

    function globalBullMaxProfit() external view returns (uint256);
    function globalBearMaxProfit() external view returns (uint256);
    function globalMargin() external view returns (uint256);

}

/// @title CfdVault
/// @notice The House Pool. Holds all USDC and strictly protects trader solvency.
contract CfdVault is ERC4626 {

    using SafeERC20 for IERC20;

    ICfdEngine public engine;
    address public orderRouter;

    modifier onlyRouter() {
        require(msg.sender == orderRouter, "CfdVault: Unauthorized");
        _;
    }

    constructor(
        IERC20 _usdc,
        address _engine
    ) ERC4626(_usdc) ERC20("Plether House Pool", "cfdUSDC") {
        engine = ICfdEngine(_engine);
    }

    function setOrderRouter(
        address _router
    ) external {
        require(orderRouter == address(0), "CfdVault: Router already set");
        orderRouter = _router;
    }

    // ==========================================
    // ROUTING FUNCTIONS
    // ==========================================

    /// @notice Router sends trader margin and execution fees to the House
    function routeToVault(
        uint256 amountUsdc
    ) external onlyRouter {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amountUsdc);
    }

    /// @notice Router pulls payouts and freed margin to return to the trader
    function routeToTrader(
        address trader,
        uint256 amountUsdc
    ) external onlyRouter {
        IERC20(asset()).safeTransfer(trader, amountUsdc);
    }

    // ==========================================
    // THE O(1) WITHDRAWAL FIREWALL
    // ==========================================

    /// @notice Calculates strictly unencumbered capital available for LP withdrawal
    function getFreeUSDC() public view returns (uint256) {
        uint256 totalUsdc = totalAssets();

        uint256 bullMax = engine.globalBullMaxProfit();
        uint256 bearMax = engine.globalBearMaxProfit();
        uint256 maxLiability = bullMax > bearMax ? bullMax : bearMax;

        // Total locked capital is Active Margin + Max Liability
        uint256 lockedCapital = engine.globalMargin() + maxLiability;

        if (totalUsdc <= lockedCapital) {
            return 0; // 100% Utilization lock
        }
        return totalUsdc - lockedCapital;
    }

    function maxWithdraw(
        address owner
    ) public view override returns (uint256) {
        uint256 maxStandard = super.maxWithdraw(owner);
        uint256 freeUsdc = getFreeUSDC();
        return maxStandard < freeUsdc ? maxStandard : freeUsdc;
    }

    function maxRedeem(
        address owner
    ) public view override returns (uint256) {
        uint256 maxShares = super.maxRedeem(owner);
        uint256 freeUsdc = getFreeUSDC();
        uint256 freeShares = previewWithdraw(freeUsdc);
        return maxShares < freeShares ? maxShares : freeShares;
    }

}
