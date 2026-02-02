// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IMorpho, MarketParams} from "./interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "./libraries/MorphoBalancesLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Morpho Universal Rewards Distributor Interface
interface IUniversalRewardsDistributor {

    function claim(
        address account,
        address reward,
        uint256 claimable,
        bytes32[] calldata proof
    ) external returns (uint256 amount);

}

/// @title MorphoAdapter
/// @notice ERC4626-compliant wrapper for Morpho Blue lending.
/// @dev Interchangeable with other yield adapters. Only accepts deposits from SyntheticSplitter.
contract MorphoAdapter is ERC4626, Ownable2Step {

    using SafeERC20 for IERC20;

    /// @notice Morpho Blue protocol contract.
    IMorpho public immutable MORPHO;

    /// @notice Morpho market parameters for this adapter.
    MarketParams public marketParams;

    /// @notice Computed market ID (keccak256 of marketParams).
    bytes32 public immutable MARKET_ID;

    /// @notice SyntheticSplitter authorized to deposit/withdraw.
    address public immutable SPLITTER;

    /// @notice Universal Rewards Distributor for Morpho incentives.
    address public urd;

    /// @notice Thrown when caller is not the SyntheticSplitter.
    error MorphoAdapter__OnlySplitter();

    /// @notice Thrown when a zero address is provided.
    error MorphoAdapter__InvalidAddress();

    /// @notice Thrown when market loan token doesn't match asset.
    error MorphoAdapter__InvalidMarket();

    /// @notice Thrown when attempting to rescue the underlying asset.
    error MorphoAdapter__CannotRescueUnderlying();

    /// @notice Emitted when URD address is updated.
    event UrdUpdated(address indexed oldUrd, address indexed newUrd);

    /// @notice Deploys adapter with Morpho market configuration.
    /// @param _asset Underlying asset (USDC).
    /// @param _morpho Morpho Blue protocol address.
    /// @param _marketParams Market parameters (must have loanToken == _asset).
    /// @param _owner Admin address for rewards and rescue.
    /// @param _splitter SyntheticSplitter authorized to deposit.
    constructor(
        IERC20 _asset,
        address _morpho,
        MarketParams memory _marketParams,
        address _owner,
        address _splitter
    ) ERC4626(_asset) ERC20("Morpho Yield Wrapper", "myUSDC") Ownable(_owner) {
        if (_splitter == address(0)) {
            revert MorphoAdapter__InvalidAddress();
        }
        if (_morpho == address(0)) {
            revert MorphoAdapter__InvalidAddress();
        }
        if (_marketParams.loanToken != address(_asset)) {
            revert MorphoAdapter__InvalidMarket();
        }

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

    /// @notice Returns total USDC value of this adapter's Morpho position.
    /// @return Total assets including pending (unaccrued) interest.
    function totalAssets() public view override returns (uint256) {
        (uint256 supplyShares,,) = MORPHO.position(MARKET_ID, address(this));
        if (supplyShares == 0) {
            return 0;
        }
        return MorphoBalancesLib.expectedSupplyAssets(MORPHO, marketParams, supplyShares);
    }

    /// @dev Deposits assets to Morpho after ERC4626 share minting.
    /// @param caller Must be SPLITTER.
    /// @param receiver Receiver of vault shares.
    /// @param assets Amount of USDC to deposit.
    /// @param shares Amount of vault shares minted.
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (caller != SPLITTER) {
            revert MorphoAdapter__OnlySplitter();
        }

        // 1. OpenZeppelin's logic already pulled assets from 'caller' to 'this'
        super._deposit(caller, receiver, assets, shares);

        // 2. Supply to Morpho Blue (assets mode, shares = 0)
        MORPHO.supply(marketParams, assets, 0, address(this), "");
    }

    /// @dev Withdraws assets from Morpho before ERC4626 share burning.
    /// @param caller Caller requesting withdrawal.
    /// @param receiver Receiver of withdrawn assets.
    /// @param owner Owner of vault shares being burned.
    /// @param assets Amount of USDC to withdraw.
    /// @param shares Amount of vault shares burned.
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        // 1. Withdraw from Morpho to 'this' (assets mode, shares = 0)
        MORPHO.withdraw(marketParams, assets, 0, address(this), address(this));

        // 2. OpenZeppelin's logic sends assets to 'receiver'
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // ==========================================
    // MORPHO HELPERS
    // ==========================================

    /// @notice Forces Morpho to accrue interest, syncing expected and actual values.
    /// @dev Call before totalAssets() if you need exact values for calculations.
    function accrueInterest() external {
        MORPHO.accrueInterest(marketParams);
    }

    /// @dev Computes market ID from parameters (keccak256 hash).
    /// @param params Market parameters struct.
    /// @return Market identifier used by Morpho.
    function _computeMarketId(
        MarketParams memory params
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }

    // ==========================================
    // SAFETY
    // ==========================================

    /// @notice Recovers stuck tokens (excluding the underlying asset).
    /// @param token Token to rescue.
    /// @param to Recipient address.
    function rescueToken(
        address token,
        address to
    ) external onlyOwner {
        if (token == asset()) {
            revert MorphoAdapter__CannotRescueUnderlying();
        }
        IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
    }

    // ==========================================
    // REWARDS (Universal Rewards Distributor)
    // ==========================================

    /// @notice Sets the Universal Rewards Distributor address.
    /// @param _urd URD contract address (cannot be zero).
    function setUrd(
        address _urd
    ) external onlyOwner {
        if (_urd == address(0)) {
            revert MorphoAdapter__InvalidAddress();
        }
        address oldUrd = urd;
        urd = _urd;
        emit UrdUpdated(oldUrd, _urd);
    }

    /// @notice Claims rewards and transfers to specified address.
    /// @param reward Reward token address.
    /// @param claimable Total claimable amount from merkle tree.
    /// @param proof Merkle proof for claim.
    /// @param to Recipient of claimed rewards.
    /// @return claimed Amount successfully claimed and transferred.
    function claimRewards(
        address reward,
        uint256 claimable,
        bytes32[] calldata proof,
        address to
    ) external onlyOwner returns (uint256 claimed) {
        if (urd == address(0)) {
            revert MorphoAdapter__InvalidAddress();
        }
        if (to == address(0)) {
            revert MorphoAdapter__InvalidAddress();
        }

        // Claim from URD (claims to this contract)
        claimed = IUniversalRewardsDistributor(urd).claim(address(this), reward, claimable, proof);

        // Transfer to recipient
        if (claimed > 0) {
            IERC20(reward).safeTransfer(to, claimed);
        }
    }

    /// @notice Claims rewards to this contract for compounding.
    /// @param reward Reward token address.
    /// @param claimable Total claimable amount from merkle tree.
    /// @param proof Merkle proof for claim.
    /// @return claimed Amount successfully claimed.
    function claimRewardsToSelf(
        address reward,
        uint256 claimable,
        bytes32[] calldata proof
    ) external onlyOwner returns (uint256 claimed) {
        if (urd == address(0)) {
            revert MorphoAdapter__InvalidAddress();
        }

        claimed = IUniversalRewardsDistributor(urd).claim(address(this), reward, claimable, proof);
    }

}
