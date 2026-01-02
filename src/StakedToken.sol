// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title StakedToken
 * @notice An ERC-4626 Vault that auto-compounds yield.
 * @dev Exchange rate increases as yield is donated to the vault.
 *      Uses virtual shares offset to protect against inflation attacks.
 */
contract StakedToken is ERC4626 {
    using SafeERC20 for IERC20;

    constructor(IERC20 _asset, string memory _name, string memory _symbol) ERC4626(_asset) ERC20(_name, _symbol) {}

    /**
     * @notice Allows anyone to inject yield into the vault.
     * @dev Increases the share price for all stakers immediately.
     * @param amount The amount of underlying tokens to donate
     */
    function donateYield(uint256 amount) external {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        // ERC-4626 automatically recognizes this balance increase.
        // totalAssets() goes UP. totalSupply() stays SAME.
        // Result: Price goes UP.
    }

    /**
     * @dev Offset for virtual shares to protect against inflation attacks.
     * With offset of 3, attacker needs 1000x more capital to steal same amount.
     * See: https://docs.openzeppelin.com/contracts/5.x/erc4626#inflation-attack
     */
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }
}
