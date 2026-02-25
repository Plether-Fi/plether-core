// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICurvePool} from "../../src/interfaces/ICurvePool.sol";
import {MockToken} from "./MockToken.sol";

contract MockCurvePool is ICurvePool {

    address public token0; // USDC
    address public token1; // plDxyBear
    uint256 public bearPrice = 1e6;
    uint256 public slippageBps;

    constructor(
        address _token0,
        address _token1
    ) {
        token0 = _token0;
        token1 = _token1;
    }

    function setPrice(
        uint256 _price
    ) external {
        bearPrice = _price;
    }

    function setSlippage(
        uint256 _slippageBps
    ) external {
        slippageBps = _slippageBps;
    }

    function get_dy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view override returns (uint256) {
        if (i == 1 && j == 0) {
            return (dx * bearPrice) / 1e18;
        }
        if (i == 0 && j == 1) {
            return (dx * 1e18) / bearPrice;
        }
        return 0;
    }

    function get_dx(
        uint256 i,
        uint256 j,
        uint256 dy
    ) external view returns (uint256) {
        if (i == 1 && j == 0) {
            return (dy * 1e18) / bearPrice;
        }
        if (i == 0 && j == 1) {
            return (dy * bearPrice) / 1e18;
        }
        return 0;
    }

    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy
    ) external payable virtual override returns (uint256 dy) {
        uint256 quotedDy = this.get_dy(i, j, dx);
        dy = slippageBps > 0 ? (quotedDy * (10_000 - slippageBps)) / 10_000 : quotedDy;
        require(dy >= min_dy, "Too little received");

        address tokenIn = i == 0 ? token0 : token1;
        address tokenOut = j == 0 ? token0 : token1;

        MockToken(tokenIn).transferFrom(msg.sender, address(this), dx);
        MockToken(tokenOut).mint(msg.sender, dy);
    }

    function price_oracle() external view override returns (uint256) {
        return bearPrice * 1e12;
    }

}
