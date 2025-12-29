// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// Minimal Aave V3 Interface
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

// Aave V3 Rewards Interface
interface IRewardsController {
    function claimRewards(address[] calldata assets, uint256 amount, address to, address reward)
        external
        returns (uint256);

    function getAllUserRewards(address[] calldata assets, address user)
        external
        view
        returns (address[] memory rewardsList, uint256[] memory unclaimedAmounts);
}

/**
 * @title YieldAdapter
 * @notice An ERC-4626 compliant wrapper for Aave V3.
 */
contract YieldAdapter is ERC4626, Ownable {
    using SafeERC20 for IERC20;

    IAavePool public immutable AAVE_POOL;
    IERC20 public immutable A_TOKEN; // The Aave receipt token (aUSDC)
    address public immutable SPLITTER; // Only address allowed to deposit

    IRewardsController public rewardsController;

    error YieldAdapter__OnlySplitter();
    error YieldAdapter__InvalidAddress();

    constructor(
        IERC20 _asset, // USDC
        address _aavePool,
        address _aToken,
        address _owner,
        address _splitter
    )
        ERC4626(_asset)
        ERC20("Yield Wrapper", "yUSDC")
        Ownable(_owner)
    {
        if (_splitter == address(0)) revert YieldAdapter__InvalidAddress();

        AAVE_POOL = IAavePool(_aavePool);
        A_TOKEN = IERC20(_aToken);
        SPLITTER = _splitter;

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
     * @notice Only the Splitter contract can deposit (inflation attack protection)
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (caller != SPLITTER) revert YieldAdapter__OnlySplitter();

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

    // ==========================================
    // REWARDS
    // ==========================================

    /**
     * @notice Set the Aave RewardsController address
     * @param _rewardsController The address of the Aave V3 RewardsController
     */
    function setRewardsController(address _rewardsController) external onlyOwner {
        rewardsController = IRewardsController(_rewardsController);
    }

    /**
     * @notice View pending rewards for this adapter
     * @return rewardsList Array of reward token addresses
     * @return unclaimedAmounts Array of unclaimed amounts
     */
    function getPendingRewards()
        external
        view
        returns (address[] memory rewardsList, uint256[] memory unclaimedAmounts)
    {
        if (address(rewardsController) == address(0)) {
            return (new address[](0), new uint256[](0));
        }

        address[] memory assets = new address[](1);
        assets[0] = address(A_TOKEN);

        return rewardsController.getAllUserRewards(assets, address(this));
    }

    /**
     * @notice Claim Aave rewards and send to specified address
     * @param reward The reward token address to claim
     * @param to The address to receive the rewards
     * @return claimed The amount of rewards claimed
     */
    function claimRewards(address reward, address to) external onlyOwner returns (uint256 claimed) {
        if (address(rewardsController) == address(0)) revert YieldAdapter__InvalidAddress();
        if (to == address(0)) revert YieldAdapter__InvalidAddress();

        address[] memory assets = new address[](1);
        assets[0] = address(A_TOKEN);

        claimed = rewardsController.claimRewards(assets, type(uint256).max, to, reward);
    }
}
