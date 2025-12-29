// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Minimal Aave V3 Interface
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/**
 * @title YieldAdapter
 * @notice An ERC-4626 compliant wrapper for Aave V3.
 */
contract YieldAdapter is ERC4626, Ownable {
    using SafeERC20 for IERC20;

    IAavePool public immutable AAVE_POOL;
    IERC20 public immutable A_TOKEN; // The Aave receipt token (aUSDC)

    constructor(
        IERC20 _asset, // USDC
        address _aavePool,
        address _aToken,
        address _owner
    )
        ERC4626(_asset)
        ERC20("Yield Wrapper", "yUSDC")
        Ownable(_owner)
    {
        AAVE_POOL = IAavePool(_aavePool);
        A_TOKEN = IERC20(_aToken);

        // Infinite approve Aave to take our USDC
        _asset.safeIncreaseAllowance(_aavePool, type(uint256).max);
    }

    // ==========================================
    // ERC-4626 OVERRIDES
    // ==========================================

    /**
     * @dev Total assets = Balance in Aave (Principal + Interest).
     * This is the "source of truth" for the vault's value.
     */
    function totalAssets() public view override returns (uint256) {
        // aToken balance grows automatically as interest accrues
        return A_TOKEN.balanceOf(address(this));
    }

    /**
     * @dev Hook called after user deposits USDC. We push it to Aave.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        // 1. OpenZeppelin's logic already pulled USDC from 'caller' to 'this'
        super._deposit(caller, receiver, assets, shares);

        // 2. We supply that USDC to Aave
        // 'onBehalfOf' is 'this' because the Wrapper holds the position
        AAVE_POOL.supply(asset(), assets, address(this), 0);
    }

    /**
     * @dev Hook called before user withdraws. We pull from Aave.
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        // 1. Withdraw exact amount from Aave to 'this'
        AAVE_POOL.withdraw(asset(), assets, address(this));

        // 2. OpenZeppelin's logic sends USDC to 'receiver'
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // ==========================================
    // SAFETY
    // ==========================================

    /**
     * @notice Recover tokens stuck in the contract (EXCEPT USDC/aUSDC).
     */
    function rescueToken(address token, address to) external onlyOwner {
        require(token != asset(), "Cannot rescue Underlying");
        require(token != address(A_TOKEN), "Cannot rescue aTokens");

        IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
    }
}
