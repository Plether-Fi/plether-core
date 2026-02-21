// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title StakedToken
/// @custom:security-contact contact@plether.com
/// @notice ERC4626 vault for staking plDXY-BEAR or plDXY-BULL tokens.
/// @dev Used as Morpho collateral. Exchange rate increases via yield donations.
///      Implements 1000x virtual share offset to prevent inflation attacks.
///      Implements streaming rewards (1-hour linear vest) to prevent reward sniping.
contract StakedToken is ERC4626 {

    using SafeERC20 for IERC20;

    /// @notice Duration over which donated rewards are streamed.
    uint256 public constant STREAM_DURATION = 1 hours;

    uint256 private _trackedBalance;

    /// @notice Current reward streaming rate (tokens per second, scaled by 1e18).
    uint256 public rewardRate;

    /// @notice Timestamp when current reward stream ends.
    uint256 public streamEndTime;

    /// @notice Emitted when yield is donated and streaming begins/extends.
    event YieldDonated(address indexed donor, uint256 amount, uint256 newStreamEndTime);

    /// @notice Creates a new staking vault for a synthetic token.
    /// @param _asset The underlying plDXY token to stake (plDXY-BEAR or plDXY-BULL).
    /// @param _name Vault share name (e.g., "Staked plDXY-BEAR").
    /// @param _symbol Vault share symbol (e.g., "splDXY-BEAR").
    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol
    ) ERC4626(_asset) ERC20(_name, _symbol) {}

    /// @notice Returns total assets including only vested streamed rewards.
    /// @dev Overrides ERC4626 to exclude unvested rewards from share price calculation.
    function totalAssets() public view override returns (uint256) {
        return _trackedBalance - _unvestedRewards();
    }

    /// @notice Donates yield that streams to stakers over STREAM_DURATION.
    /// @dev Rewards vest linearly. New donations extend the stream proportionally to
    ///      the donation size, preventing griefing via zero-amount timer resets.
    /// @param amount The amount of underlying tokens to donate.
    function donateYield(
        uint256 amount
    ) external {
        uint256 remaining = _unvestedRewards();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        _trackedBalance += amount;

        uint256 total = remaining + amount;
        if (total == 0) {
            return;
        }

        uint256 remainingTime = streamEndTime > block.timestamp ? streamEndTime - block.timestamp : 0;
        uint256 newDuration = remainingTime + (STREAM_DURATION * amount) / total;
        if (newDuration > STREAM_DURATION) {
            newDuration = STREAM_DURATION;
        }

        rewardRate = (total * 1e18) / newDuration;
        streamEndTime = block.timestamp + newDuration;

        emit YieldDonated(msg.sender, amount, streamEndTime);
    }

    /// @notice Deposit assets with a permit signature (gasless approval).
    /// @dev Combines EIP-2612 permit with ERC-4626 deposit in a single transaction.
    /// @param assets Amount of underlying tokens to deposit
    /// @param receiver Address to receive the vault shares
    /// @param deadline Permit signature expiration timestamp
    /// @param v Signature recovery byte
    /// @param r Signature r component
    /// @param s Signature s component
    /// @return shares Amount of vault shares minted
    function depositWithPermit(
        uint256 assets,
        address receiver,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 shares) {
        IERC20Permit(asset()).permit(msg.sender, address(this), assets, deadline, v, r, s);
        return deposit(assets, receiver);
    }

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        _trackedBalance += assets;
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        _trackedBalance -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev Calculates unvested rewards from the current stream.
    function _unvestedRewards() internal view returns (uint256) {
        if (block.timestamp >= streamEndTime) {
            return 0;
        }
        uint256 remainingTime = streamEndTime - block.timestamp;
        return (remainingTime * rewardRate) / 1e18;
    }

    /// @dev Virtual share offset (10^3 = 1000x) to prevent inflation attacks.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

}
