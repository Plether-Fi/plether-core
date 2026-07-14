// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICurvePool} from "@plether/shared/interfaces/ICurvePool.sol";
import {ICurveTwocrypto} from "@plether/spot/interfaces/ICurveTwocrypto.sol";

/// @notice Testnet-only Curve twocrypto stand-in for deployment scripts.
/// @dev Constant-price, reserve-backed pool. The pool address is also the LP token address.
contract MockTwocryptoPool is ERC20, ICurvePool, ICurveTwocrypto {

    using SafeERC20 for IERC20;

    uint256 internal constant USDC_INDEX = 0;
    uint256 internal constant BEAR_INDEX = 1;
    uint256 internal constant USDC_TO_WAD = 1e12;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant CURVE_A = 320_000;
    uint256 internal constant CURVE_GAMMA = 2_000_000_000_000_000;
    uint256 internal constant CURVE_MID_FEE = 4_000_000;
    uint256 internal constant CURVE_OUT_FEE = 20_000_000;
    uint256 internal constant CURVE_FEE_GAMMA = 1_000_000_000_000_000;
    uint256 internal constant CURVE_ALLOWED_EXTRA_PROFIT = 2_000_000_000_000;
    uint256 internal constant CURVE_ADJUSTMENT_STEP = 146_000_000_000_000;
    uint256 internal constant CURVE_MA_TIME = 600;
    uint256 internal constant ADMIN_FEE_VALUE = 5_000_000_000;

    IERC20 public immutable USDC;
    IERC20 public immutable BEAR;
    address public immutable MATH;
    address public immutable admin;
    address public immutable factory;
    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public immutable salt;

    uint256 public immutable initialPrice;
    mapping(address => uint256) public nonces;

    event TokenExchange(
        address indexed buyer,
        uint256 sold_id,
        uint256 tokens_sold,
        uint256 bought_id,
        uint256 tokens_bought,
        uint256 fee,
        uint256 packed_price_scale
    );
    event AddLiquidity(
        address indexed provider,
        uint256[2] token_amounts,
        uint256 fee,
        uint256 token_supply,
        uint256 packed_price_scale
    );
    event RemoveLiquidity(address indexed provider, uint256[2] token_amounts, uint256 token_supply);
    event RemoveLiquidityOne(
        address indexed provider,
        uint256 token_amount,
        uint256 coin_index,
        uint256 coin_amount,
        uint256 approx_fee,
        uint256 packed_price_scale
    );
    event NewParameters(
        uint256 mid_fee,
        uint256 out_fee,
        uint256 fee_gamma,
        uint256 allowed_extra_profit,
        uint256 adjustment_step,
        uint256 ma_time,
        uint256 xcp_ma_time
    );
    event RampAgamma(
        uint256 initial_A,
        uint256 future_A,
        uint256 initial_gamma,
        uint256 future_gamma,
        uint256 initial_time,
        uint256 future_time
    );
    event StopRampA(uint256 current_A, uint256 current_gamma, uint256 time);
    event ClaimAdminFee(address indexed admin, uint256[2] tokens);

    constructor(
        address usdc,
        address bear,
        uint256 priceOracle
    ) ERC20("Mock Curve USDC/plDXY-BEAR", "mockcrvUSDCPDXYBEAR") {
        require(usdc != address(0) && bear != address(0), "zero token");
        require(priceOracle > 0, "zero price");
        USDC = IERC20(usdc);
        BEAR = IERC20(bear);
        MATH = address(0);
        admin = msg.sender;
        factory = msg.sender;
        initialPrice = priceOracle;
        salt = keccak256(abi.encode(block.chainid, usdc, bear, priceOracle));
        DOMAIN_SEPARATOR = keccak256(abi.encode(block.chainid, address(this), salt));
    }

    function version() external pure returns (string memory) {
        return "mock-twocrypto-ng";
    }

    function token() external view returns (address) {
        return address(this);
    }

    function fee_receiver() external pure returns (address) {
        return address(0);
    }

    function coins(
        uint256 i
    ) external view returns (address) {
        return address(_coin(i));
    }

    function balances(
        uint256 i
    ) external view returns (uint256) {
        return _coin(i).balanceOf(address(this));
    }

    function price_oracle() external view override returns (uint256) {
        return initialPrice;
    }

    function xcp_oracle() external view returns (uint256) {
        return get_virtual_price();
    }

    function price_scale() external view returns (uint256) {
        return initialPrice;
    }

    function last_prices() external view returns (uint256) {
        return initialPrice;
    }

    function last_timestamp() external view returns (uint256) {
        return block.timestamp;
    }

    function last_xcp() external view returns (uint256) {
        return get_virtual_price();
    }

    function A() external pure returns (uint256) {
        return CURVE_A;
    }

    function gamma() external pure returns (uint256) {
        return CURVE_GAMMA;
    }

    function mid_fee() external pure returns (uint256) {
        return CURVE_MID_FEE;
    }

    function out_fee() external pure returns (uint256) {
        return CURVE_OUT_FEE;
    }

    function fee_gamma() external pure returns (uint256) {
        return CURVE_FEE_GAMMA;
    }

    function allowed_extra_profit() external pure returns (uint256) {
        return CURVE_ALLOWED_EXTRA_PROFIT;
    }

    function adjustment_step() external pure returns (uint256) {
        return CURVE_ADJUSTMENT_STEP;
    }

    function ma_time() external pure returns (uint256) {
        return CURVE_MA_TIME;
    }

    function xcp_ma_time() external pure returns (uint256) {
        return CURVE_MA_TIME;
    }

    function fee() external pure returns (uint256) {
        return CURVE_MID_FEE;
    }

    function ADMIN_FEE() external pure returns (uint256) {
        return ADMIN_FEE_VALUE;
    }

    function precisions() external pure returns (uint256[2] memory values) {
        values[USDC_INDEX] = USDC_TO_WAD;
        values[BEAR_INDEX] = 1;
    }

    function D() external view returns (uint256) {
        return _reserveValueWad();
    }

    function virtual_price() external view returns (uint256) {
        return get_virtual_price();
    }

    function xcp_profit() external pure returns (uint256) {
        return WAD;
    }

    function xcp_profit_a() external pure returns (uint256) {
        return WAD;
    }

    function packed_rebalancing_params() external pure returns (uint256) {
        return 0;
    }

    function packed_fee_params() external pure returns (uint256) {
        return 0;
    }

    function initial_A_gamma() external pure returns (uint256) {
        return (CURVE_A << 128) | CURVE_GAMMA;
    }

    function initial_A_gamma_time() external view returns (uint256) {
        return block.timestamp;
    }

    function future_A_gamma() external pure returns (uint256) {
        return (CURVE_A << 128) | CURVE_GAMMA;
    }

    function future_A_gamma_time() external view returns (uint256) {
        return block.timestamp;
    }

    function get_dy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view override returns (uint256) {
        return _quote(i, j, dx);
    }

    function get_dx(
        uint256 i,
        uint256 j,
        uint256 dy
    ) external view returns (uint256) {
        _validatePair(i, j);
        if (i == USDC_INDEX) {
            return Math.mulDiv(dy, initialPrice, 1e30);
        }
        return Math.mulDiv(dy, 1e30, initialPrice);
    }

    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy
    ) external payable override returns (uint256 dy) {
        return _exchange(i, j, dx, min_dy, msg.sender);
    }

    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy,
        address receiver
    ) external returns (uint256 dy) {
        return _exchange(i, j, dx, min_dy, receiver);
    }

    function exchange_received(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256 dy) {
        return _exchangeReceived(i, j, dx, min_dy, msg.sender);
    }

    function exchange_received(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy,
        address receiver
    ) external returns (uint256 dy) {
        return _exchangeReceived(i, j, dx, min_dy, receiver);
    }

    function add_liquidity(
        uint256[2] calldata amounts,
        uint256 min_mint_amount
    ) external override returns (uint256 lpMinted) {
        return _addLiquidity(amounts, min_mint_amount, msg.sender);
    }

    function add_liquidity(
        uint256[2] calldata amounts,
        uint256 min_mint_amount,
        address receiver
    ) external returns (uint256 lpMinted) {
        return _addLiquidity(amounts, min_mint_amount, receiver);
    }

    function remove_liquidity_one_coin(
        uint256 token_amount,
        uint256 i,
        uint256 min_amount
    ) external override returns (uint256 amountOut) {
        return _removeLiquidityOneCoin(token_amount, i, min_amount, msg.sender);
    }

    function remove_liquidity_one_coin(
        uint256 token_amount,
        uint256 i,
        uint256 min_amount,
        address receiver
    ) external returns (uint256 amountOut) {
        return _removeLiquidityOneCoin(token_amount, i, min_amount, receiver);
    }

    function remove_liquidity(
        uint256 amount,
        uint256[2] calldata min_amounts
    ) external override returns (uint256[2] memory amounts) {
        return _removeLiquidity(amount, min_amounts, msg.sender);
    }

    function remove_liquidity(
        uint256 amount,
        uint256[2] calldata min_amounts,
        address receiver
    ) external returns (uint256[2] memory amounts) {
        return _removeLiquidity(amount, min_amounts, receiver);
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

    function calc_token_fee(
        uint256[2] calldata,
        uint256[2] calldata
    ) external pure returns (uint256) {
        return 0;
    }

    function fee_calc(
        uint256[2] calldata
    ) external pure returns (uint256) {
        return CURVE_MID_FEE;
    }

    function ramp_A_gamma(
        uint256 future_A,
        uint256 future_gamma,
        uint256 future_time
    ) external {
        emit RampAgamma(CURVE_A, future_A, CURVE_GAMMA, future_gamma, block.timestamp, future_time);
    }

    function stop_ramp_A_gamma() external {
        emit StopRampA(CURVE_A, CURVE_GAMMA, block.timestamp);
    }

    function apply_new_parameters(
        uint256 _new_mid_fee,
        uint256 _new_out_fee,
        uint256 _new_fee_gamma,
        uint256 _new_allowed_extra_profit,
        uint256 _new_adjustment_step,
        uint256 _new_ma_time,
        uint256 _new_xcp_ma_time
    ) external {
        emit NewParameters(
            _new_mid_fee,
            _new_out_fee,
            _new_fee_gamma,
            _new_allowed_extra_profit,
            _new_adjustment_step,
            _new_ma_time,
            _new_xcp_ma_time
        );
    }

    function permit(
        address _owner,
        address _spender,
        uint256 _value,
        uint256 _deadline,
        uint8,
        bytes32,
        bytes32
    ) external returns (bool) {
        require(block.timestamp <= _deadline, "expired");
        nonces[_owner]++;
        _approve(_owner, _spender, _value);
        return true;
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

    function _exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy,
        address receiver
    ) internal returns (uint256 dy) {
        dy = _quote(i, j, dx);
        require(dy >= min_dy, "slippage");

        IERC20 input = _coin(i);
        IERC20 output = _coin(j);
        input.safeTransferFrom(msg.sender, address(this), dx);
        output.safeTransfer(receiver, dy);
        emit TokenExchange(msg.sender, i, dx, j, dy, 0, initialPrice);
    }

    function _exchangeReceived(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy,
        address receiver
    ) internal returns (uint256 dy) {
        dy = _quote(i, j, dx);
        require(dy >= min_dy, "slippage");

        _coin(j).safeTransfer(receiver, dy);
        emit TokenExchange(msg.sender, i, dx, j, dy, 0, initialPrice);
    }

    function _addLiquidity(
        uint256[2] calldata amounts,
        uint256 min_mint_amount,
        address receiver
    ) internal returns (uint256 lpMinted) {
        lpMinted = _lpAmount(amounts[0], amounts[1]);
        require(lpMinted >= min_mint_amount, "slippage");

        if (amounts[USDC_INDEX] > 0) {
            USDC.safeTransferFrom(msg.sender, address(this), amounts[USDC_INDEX]);
        }
        if (amounts[BEAR_INDEX] > 0) {
            BEAR.safeTransferFrom(msg.sender, address(this), amounts[BEAR_INDEX]);
        }

        _mint(receiver, lpMinted);
        emit AddLiquidity(msg.sender, amounts, 0, totalSupply(), initialPrice);
    }

    function _removeLiquidity(
        uint256 amount,
        uint256[2] calldata min_amounts,
        address receiver
    ) internal returns (uint256[2] memory amounts) {
        uint256 supply = totalSupply();
        require(supply > 0, "no supply");

        amounts[USDC_INDEX] = Math.mulDiv(USDC.balanceOf(address(this)), amount, supply);
        amounts[BEAR_INDEX] = Math.mulDiv(BEAR.balanceOf(address(this)), amount, supply);
        require(amounts[USDC_INDEX] >= min_amounts[USDC_INDEX], "usdc slippage");
        require(amounts[BEAR_INDEX] >= min_amounts[BEAR_INDEX], "bear slippage");

        _burn(msg.sender, amount);
        USDC.safeTransfer(receiver, amounts[USDC_INDEX]);
        BEAR.safeTransfer(receiver, amounts[BEAR_INDEX]);
        emit RemoveLiquidity(msg.sender, amounts, totalSupply());
    }

    function _removeLiquidityOneCoin(
        uint256 token_amount,
        uint256 i,
        uint256 min_amount,
        address receiver
    ) internal returns (uint256 amountOut) {
        amountOut = calc_withdraw_one_coin(token_amount, i);
        require(amountOut >= min_amount, "slippage");

        _burn(msg.sender, token_amount);
        _coin(i).safeTransfer(receiver, amountOut);
        emit RemoveLiquidityOne(msg.sender, token_amount, i, amountOut, 0, initialPrice);
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
