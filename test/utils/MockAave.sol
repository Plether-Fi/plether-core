// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// 1. Mock aToken (Must link to underlying USDC)
contract MockAToken is ERC20 {

    address public underlyingAsset;

    constructor(
        string memory name,
        string memory symbol,
        address _underlying
    ) ERC20(name, symbol) {
        underlyingAsset = _underlying;
    }

    // Required by your YieldAdapter constructor sanity check
    function UNDERLYING_ASSET_ADDRESS() external view returns (address) {
        return underlyingAsset;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function burn(
        address from,
        uint256 amount
    ) external {
        _burn(from, amount);
    }

}

// 2. Standard Mock Token (for USDC)
contract MockERC20 is ERC20 {

    constructor(
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

// 3. Mock Aave Pool
contract MockPool {

    MockERC20 public usdc;
    MockAToken public aUsdc;

    constructor(
        address _usdc,
        address _aUsdc
    ) {
        usdc = MockERC20(_usdc);
        aUsdc = MockAToken(_aUsdc);
    }

    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16
    ) external {
        require(asset == address(usdc), "Wrong Asset");
        // Take USDC from the user (Adapter)
        usdc.transferFrom(msg.sender, address(this), amount);
        // Give aTokens to the 'onBehalfOf' (Adapter)
        aUsdc.mint(onBehalfOf, amount);
    }

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256) {
        require(asset == address(usdc), "Wrong Asset");
        // In reality, Aave burns the aToken. We simulate that here.
        // The Adapter holds the aTokens, so we burn from msg.sender (Adapter)
        aUsdc.burn(msg.sender, amount);

        // Return the underlying USDC
        usdc.transfer(to, amount);
        return amount;
    }

}
