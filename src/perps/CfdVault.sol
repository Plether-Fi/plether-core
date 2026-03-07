// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ICfdEngine} from "./ICfdEngine.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CfdVault
/// @notice The House Pool. Holds all USDC and strictly protects trader solvency.
contract CfdVault is ERC4626, Ownable2Step {

    using SafeERC20 for IERC20;

    ICfdEngine public engine;
    address public orderRouter;

    constructor(
        IERC20 _usdc,
        address _engine
    ) ERC4626(_usdc) ERC20("Plether House Pool", "cfdUSDC") Ownable(msg.sender) {
        engine = ICfdEngine(_engine);
    }

    function setOrderRouter(
        address _router
    ) external onlyOwner {
        require(orderRouter == address(0), "CfdVault: Router already set");
        orderRouter = _router;
    }

    // ==========================================
    // SETTLEMENT
    // ==========================================

    function payOut(
        address recipient,
        uint256 amount
    ) external {
        require(msg.sender == address(engine) || msg.sender == orderRouter, "CfdVault: Unauthorized");
        IERC20(asset()).safeTransfer(recipient, amount);
    }

    // ==========================================
    // THE O(1) WITHDRAWAL FIREWALL
    // ==========================================

    function getFreeUSDC() public view returns (uint256) {
        uint256 totalUsdc = totalAssets();

        uint256 bullMax = engine.globalBullMaxProfit();
        uint256 bearMax = engine.globalBearMaxProfit();
        uint256 maxLiability = bullMax > bearMax ? bullMax : bearMax;

        if (totalUsdc <= maxLiability) {
            return 0;
        }
        return totalUsdc - maxLiability;
    }

    function maxWithdraw(
        address _owner
    ) public view override returns (uint256) {
        uint256 maxStandard = super.maxWithdraw(_owner);
        uint256 freeUsdc = getFreeUSDC();
        return maxStandard < freeUsdc ? maxStandard : freeUsdc;
    }

    function maxRedeem(
        address _owner
    ) public view override returns (uint256) {
        uint256 maxShares = super.maxRedeem(_owner);
        uint256 freeUsdc = getFreeUSDC();
        uint256 freeShares = previewWithdraw(freeUsdc);
        return maxShares < freeShares ? maxShares : freeShares;
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address _owner
    ) public override returns (uint256) {
        require(assets <= maxWithdraw(_owner), "CfdVault: Exceeds max withdraw");
        return super.withdraw(assets, receiver, _owner);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address _owner
    ) public override returns (uint256) {
        require(shares <= maxRedeem(_owner), "CfdVault: Exceeds max redeem");
        return super.redeem(shares, receiver, _owner);
    }

}
