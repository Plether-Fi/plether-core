// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ICurvePool} from "../../src/interfaces/ICurvePool.sol";
import {ICurveTwocrypto} from "../../src/interfaces/ICurveTwocrypto.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Testnet-only Curve twocrypto stand-in for deployment scripts.
/// @dev Constant-price, reserve-backed pool. The pool address is also the LP token address.
contract MockTwocryptoPool is ERC20, ICurvePool, ICurveTwocrypto {

    using SafeERC20 for IERC20;

    uint256 internal constant USDC_INDEX = 0;
    uint256 internal constant BEAR_INDEX = 1;
    uint256 internal constant USDC_TO_WAD = 1e12;
    uint256 internal constant WAD = 1e18;

    IERC20 public immutable USDC;
    IERC20 public immutable BEAR;

    uint256 public immutable initialPrice;

    constructor(
        address usdc,
        address bear,
        uint256 priceOracle
    ) ERC20("Mock Curve USDC/plDXY-BEAR", "mockcrvUSDCPDXYBEAR") {
        require(usdc != address(0) && bear != address(0), "zero token");
        require(priceOracle > 0, "zero price");
        USDC = IERC20(usdc);
        BEAR = IERC20(bear);
        initialPrice = priceOracle;
    }

    function token() external view returns (address) {
        return address(this);
    }

    function price_oracle() external view override returns (uint256) {
        return initialPrice;
    }

    function get_dy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view override returns (uint256) {
        return _quote(i, j, dx);
    }

    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy
    ) external payable override returns (uint256 dy) {
        dy = _quote(i, j, dx);
        require(dy >= min_dy, "slippage");

        IERC20 input = _coin(i);
        IERC20 output = _coin(j);
        input.safeTransferFrom(msg.sender, address(this), dx);
        output.safeTransfer(msg.sender, dy);
    }

    function add_liquidity(
        uint256[2] calldata amounts,
        uint256 min_mint_amount
    ) external override returns (uint256 lpMinted) {
        lpMinted = _lpAmount(amounts[0], amounts[1]);
        require(lpMinted >= min_mint_amount, "slippage");

        if (amounts[USDC_INDEX] > 0) {
            USDC.safeTransferFrom(msg.sender, address(this), amounts[USDC_INDEX]);
        }
        if (amounts[BEAR_INDEX] > 0) {
            BEAR.safeTransferFrom(msg.sender, address(this), amounts[BEAR_INDEX]);
        }

        _mint(msg.sender, lpMinted);
    }

    function remove_liquidity_one_coin(
        uint256 token_amount,
        uint256 i,
        uint256 min_amount
    ) external override returns (uint256 amountOut) {
        amountOut = calc_withdraw_one_coin(token_amount, i);
        require(amountOut >= min_amount, "slippage");

        _burn(msg.sender, token_amount);
        _coin(i).safeTransfer(msg.sender, amountOut);
    }

    function remove_liquidity(
        uint256 amount,
        uint256[2] calldata min_amounts
    ) external override returns (uint256[2] memory amounts) {
        uint256 supply = totalSupply();
        require(supply > 0, "no supply");

        amounts[USDC_INDEX] = Math.mulDiv(USDC.balanceOf(address(this)), amount, supply);
        amounts[BEAR_INDEX] = Math.mulDiv(BEAR.balanceOf(address(this)), amount, supply);
        require(amounts[USDC_INDEX] >= min_amounts[USDC_INDEX], "usdc slippage");
        require(amounts[BEAR_INDEX] >= min_amounts[BEAR_INDEX], "bear slippage");

        _burn(msg.sender, amount);
        USDC.safeTransfer(msg.sender, amounts[USDC_INDEX]);
        BEAR.safeTransfer(msg.sender, amounts[BEAR_INDEX]);
    }

    function get_virtual_price() public view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return WAD;
        }
        return Math.mulDiv(_reserveValueWad(), WAD, supply);
    }

    function lp_price() external view override returns (uint256) {
        return get_virtual_price();
    }

    function calc_token_amount(
        uint256[2] calldata amounts,
        bool
    ) external view override returns (uint256) {
        return _lpAmount(amounts[USDC_INDEX], amounts[BEAR_INDEX]);
    }

    function calc_withdraw_one_coin(
        uint256 token_amount,
        uint256 i
    ) public view override returns (uint256) {
        if (i == USDC_INDEX) {
            return token_amount / USDC_TO_WAD;
        }
        if (i == BEAR_INDEX) {
            return Math.mulDiv(token_amount, WAD, initialPrice);
        }
        revert("invalid coin");
    }

    function _quote(
        uint256 i,
        uint256 j,
        uint256 dx
    ) internal view returns (uint256) {
        _validatePair(i, j);
        if (i == USDC_INDEX) {
            return Math.mulDiv(dx, 1e30, initialPrice);
        }
        return Math.mulDiv(dx, initialPrice, 1e30);
    }

    function _lpAmount(
        uint256 usdcAmount,
        uint256 bearAmount
    ) internal view returns (uint256) {
        return (usdcAmount * USDC_TO_WAD) + Math.mulDiv(bearAmount, initialPrice, WAD);
    }

    function _reserveValueWad() internal view returns (uint256) {
        return
            (USDC.balanceOf(address(this)) * USDC_TO_WAD)
                + Math.mulDiv(BEAR.balanceOf(address(this)), initialPrice, WAD);
    }

    function _coin(
        uint256 i
    ) internal view returns (IERC20) {
        if (i == USDC_INDEX) {
            return USDC;
        }
        if (i == BEAR_INDEX) {
            return BEAR;
        }
        revert("invalid coin");
    }

    function _validatePair(
        uint256 i,
        uint256 j
    ) internal pure {
        require(i < 2 && j < 2 && i != j, "invalid pair");
    }

}
