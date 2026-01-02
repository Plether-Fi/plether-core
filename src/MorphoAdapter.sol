// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IMorpho, MarketParams} from "./interfaces/IMorpho.sol";

// Morpho Universal Rewards Distributor Interface
interface IUniversalRewardsDistributor {
    function claim(address account, address reward, uint256 claimable, bytes32[] calldata proof)
        external
        returns (uint256 amount);
}

/**
 * @title MorphoAdapter
 * @notice An ERC-4626 compliant wrapper for Morpho Blue.
 * @dev Interchangeable with YieldAdapter (Aave) - same interface for SyntheticSplitter
 */
contract MorphoAdapter is ERC4626, Ownable {
    using SafeERC20 for IERC20;

    IMorpho public immutable MORPHO;
    MarketParams public marketParams;
    bytes32 public immutable MARKET_ID;
    address public immutable SPLITTER;

    // Rewards
    address public urd; // Universal Rewards Distributor

    error MorphoAdapter__OnlySplitter();
    error MorphoAdapter__InvalidAddress();
    error MorphoAdapter__InvalidMarket();

    constructor(IERC20 _asset, address _morpho, MarketParams memory _marketParams, address _owner, address _splitter)
        ERC4626(_asset)
        ERC20("Morpho Yield Wrapper", "myUSDC")
        Ownable(_owner)
    {
        if (_splitter == address(0)) revert MorphoAdapter__InvalidAddress();
        if (_morpho == address(0)) revert MorphoAdapter__InvalidAddress();
        if (_marketParams.loanToken != address(_asset)) revert MorphoAdapter__InvalidMarket();

        MORPHO = IMorpho(_morpho);
        marketParams = _marketParams;
        MARKET_ID = _computeMarketId(_marketParams);
        SPLITTER = _splitter;

        // Infinite approve Morpho to take our asset
        _asset.safeIncreaseAllowance(_morpho, type(uint256).max);
    }

    // ==========================================
    // ERC-4626 OVERRIDES
    // ==========================================

    /**
     * @dev Total assets = our supply position in Morpho Blue
     */
    function totalAssets() public view override returns (uint256) {
        (uint256 supplyShares,,) = MORPHO.position(MARKET_ID, address(this));
        if (supplyShares == 0) return 0;
        return _convertMorphoSharesToAssets(supplyShares);
    }

    /**
     * @dev Hook called after user deposits. Only SPLITTER can deposit.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (caller != SPLITTER) revert MorphoAdapter__OnlySplitter();

        // 1. OpenZeppelin's logic already pulled assets from 'caller' to 'this'
        super._deposit(caller, receiver, assets, shares);

        // 2. Supply to Morpho Blue (assets mode, shares = 0)
        MORPHO.supply(marketParams, assets, 0, address(this), "");
    }

    /**
     * @dev Hook called before user withdraws. Pull from Morpho.
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        // 1. Withdraw from Morpho to 'this' (assets mode, shares = 0)
        MORPHO.withdraw(marketParams, assets, 0, address(this), address(this));

        // 2. OpenZeppelin's logic sends assets to 'receiver'
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // ==========================================
    // MORPHO HELPERS
    // ==========================================

    /**
     * @dev Compute market ID from MarketParams (keccak256 hash)
     */
    function _computeMarketId(MarketParams memory params) internal pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }

    /**
     * @dev Convert Morpho supply shares to assets
     */
    function _convertMorphoSharesToAssets(uint256 shares) internal view returns (uint256) {
        (uint128 totalSupplyAssets, uint128 totalSupplyShares,,,,) = MORPHO.market(MARKET_ID);

        if (totalSupplyShares == 0) return shares;
        return (shares * uint256(totalSupplyAssets)) / uint256(totalSupplyShares);
    }

    // ==========================================
    // SAFETY
    // ==========================================

    /**
     * @notice Recover tokens stuck in the contract (EXCEPT the underlying asset).
     */
    function rescueToken(address token, address to) external onlyOwner {
        require(token != asset(), "Cannot rescue Underlying");
        IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
    }

    // ==========================================
    // REWARDS (Universal Rewards Distributor)
    // ==========================================

    /**
     * @notice Set the Universal Rewards Distributor address
     * @param _urd The URD contract address
     */
    function setUrd(address _urd) external onlyOwner {
        require(_urd != address(0), "URD cannot be zero address");
        urd = _urd;
    }

    /**
     * @notice Claim rewards from Morpho's Universal Rewards Distributor
     * @param reward The reward token address
     * @param claimable The total claimable amount (from merkle tree)
     * @param proof The merkle proof
     * @param to The address to receive the rewards
     * @return claimed The amount claimed
     */
    function claimRewards(address reward, uint256 claimable, bytes32[] calldata proof, address to)
        external
        onlyOwner
        returns (uint256 claimed)
    {
        if (urd == address(0)) revert MorphoAdapter__InvalidAddress();
        if (to == address(0)) revert MorphoAdapter__InvalidAddress();

        // Claim from URD (claims to this contract)
        claimed = IUniversalRewardsDistributor(urd).claim(address(this), reward, claimable, proof);

        // Transfer to recipient
        if (claimed > 0) {
            IERC20(reward).safeTransfer(to, claimed);
        }
    }

    /**
     * @notice Claim rewards directly to this contract (for compounding or manual handling)
     * @param reward The reward token address
     * @param claimable The total claimable amount (from merkle tree)
     * @param proof The merkle proof
     * @return claimed The amount claimed
     */
    function claimRewardsToSelf(address reward, uint256 claimable, bytes32[] calldata proof)
        external
        onlyOwner
        returns (uint256 claimed)
    {
        if (urd == address(0)) revert MorphoAdapter__InvalidAddress();

        claimed = IUniversalRewardsDistributor(urd).claim(address(this), reward, claimable, proof);
    }
}
