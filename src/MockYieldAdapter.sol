// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockYieldAdapter
 * @notice Simple ERC4626 vault that holds USDC internally (no external yield, for testing).
 */
contract MockYieldAdapter is ERC4626, Ownable {
    using SafeERC20 for IERC20;

    constructor(IERC20 _asset, address _owner) ERC4626(_asset) ERC20("Mock Yield Wrapper", "mUSDC") Ownable(_owner) {}

    // Total assets = USDC balance in this contract (no yield accrual)
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    // Deposit: Just hold the assets, mint shares 1:1
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        // No external call needed – assets already transferred to this via ERC4626 logic
    }

    // Withdraw: Send assets back from local balance
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        super._withdraw(caller, receiver, owner, assets, shares);
        // Assets sent via ERC4626 logic
    }

    // Optional: Rescue stuck tokens (for safety)
    function rescueToken(address token, address to) external onlyOwner {
        if (token == address(asset())) revert("Cannot rescue underlying");
        IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
    }
}
