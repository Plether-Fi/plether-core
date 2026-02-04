// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IMintable {

    function mint(
        address to,
        uint256 amount
    ) external;

}

/**
 * @title MockYieldAdapter
 * @notice Simple ERC4626 vault that holds USDC internally (no external yield, for testing).
 * @dev Mirrors production adapter interface with SPLITTER restriction
 */
contract MockYieldAdapter is ERC4626, Ownable {

    using SafeERC20 for IERC20;

    address public immutable SPLITTER;

    error MockYieldAdapter__OnlySplitter();

    constructor(
        IERC20 _asset,
        address _owner,
        address _splitter
    ) ERC4626(_asset) ERC20("Mock Yield Wrapper", "mUSDC") Ownable(_owner) {
        SPLITTER = _splitter;
    }

    // Total assets = USDC balance in this contract (no yield accrual)
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    // Deposit: Just hold the assets, mint shares 1:1
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (caller != SPLITTER) {
            revert MockYieldAdapter__OnlySplitter();
        }
        super._deposit(caller, receiver, assets, shares);
        // No external call needed – assets already transferred to this via ERC4626 logic
    }

    // Withdraw: Send assets back from local balance
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        super._withdraw(caller, receiver, owner, assets, shares);
        // Assets sent via ERC4626 logic
    }

    // Optional: Rescue stuck tokens (for safety)
    function rescueToken(
        address token,
        address to
    ) external onlyOwner {
        if (token == address(asset())) {
            revert("Cannot rescue underlying");
        }
        IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
    }

    /// @notice Simulate 1% yield by minting additional USDC to the adapter
    /// @dev Only works with MockUSDC that has a public mint function
    function generateYield() external {
        uint256 currentAssets = totalAssets();
        uint256 yieldAmount = currentAssets / 100; // 1% yield
        IMintable(asset()).mint(address(this), yieldAmount);
    }

}
