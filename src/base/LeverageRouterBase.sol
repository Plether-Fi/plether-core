// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ICurvePool} from "../interfaces/ICurvePool.sol";
import {IMorpho, MarketParams} from "../interfaces/IMorpho.sol";
import {FlashLoanBase} from "./FlashLoanBase.sol";

/// @title LeverageRouterBase
/// @notice Abstract base for leverage routers with shared validation and admin logic.
/// @dev Common infrastructure for LeverageRouter (DXY-BEAR) and BullLeverageRouter (DXY-BULL).
abstract contract LeverageRouterBase is FlashLoanBase, Ownable, Pausable, ReentrancyGuard {

    using SafeERC20 for IERC20;

    /// @notice Maximum slippage in basis points (1% = 100 bps).
    uint256 public constant MAX_SLIPPAGE_BPS = 100;

    /// @notice USDC index in Curve USDC/DXY-BEAR pool.
    uint256 public constant USDC_INDEX = 0;

    /// @notice DXY-BEAR index in Curve USDC/DXY-BEAR pool.
    uint256 public constant DXY_BEAR_INDEX = 1;

    /// @dev Operation type: open leverage position.
    uint8 internal constant OP_OPEN = 1;

    /// @dev Operation type: close leverage position.
    uint8 internal constant OP_CLOSE = 2;

    /// @notice Morpho Blue lending protocol.
    IMorpho public immutable MORPHO;

    /// @notice Curve pool for USDC/DXY-BEAR swaps.
    ICurvePool public immutable CURVE_POOL;

    /// @notice USDC stablecoin.
    IERC20 public immutable USDC;

    /// @notice DXY-BEAR token.
    IERC20 public immutable DXY_BEAR;

    /// @notice Morpho market configuration.
    MarketParams public marketParams;

    /// @notice Thrown when zero address provided.
    error LeverageRouterBase__ZeroAddress();

    /// @notice Thrown when principal is zero.
    error LeverageRouterBase__ZeroPrincipal();

    /// @notice Thrown when collateral is zero.
    error LeverageRouterBase__ZeroCollateral();

    /// @notice Thrown when deadline has passed.
    error LeverageRouterBase__Expired();

    /// @notice Thrown when leverage multiplier <= 1x.
    error LeverageRouterBase__LeverageTooLow();

    /// @notice Thrown when slippage exceeds MAX_SLIPPAGE_BPS.
    error LeverageRouterBase__SlippageExceedsMax();

    /// @notice Thrown when user hasn't authorized router in Morpho.
    error LeverageRouterBase__NotAuthorized();

    /// @notice Thrown when swap output is insufficient.
    error LeverageRouterBase__InsufficientOutput();

    /// @notice Thrown when Curve price query returns zero.
    error LeverageRouterBase__InvalidCurvePrice();

    /// @notice Thrown when Splitter is not active.
    error LeverageRouterBase__SplitterNotActive();

    /// @notice Initializes base router with core dependencies.
    /// @param _morpho Morpho Blue protocol address.
    /// @param _curvePool Curve USDC/DXY-BEAR pool address.
    /// @param _usdc USDC token address.
    /// @param _dxyBear DXY-BEAR token address.
    constructor(
        address _morpho,
        address _curvePool,
        address _usdc,
        address _dxyBear
    ) Ownable(msg.sender) {
        if (_morpho == address(0)) revert LeverageRouterBase__ZeroAddress();
        if (_curvePool == address(0)) revert LeverageRouterBase__ZeroAddress();
        if (_usdc == address(0)) revert LeverageRouterBase__ZeroAddress();
        if (_dxyBear == address(0)) revert LeverageRouterBase__ZeroAddress();

        MORPHO = IMorpho(_morpho);
        CURVE_POOL = ICurvePool(_curvePool);
        USDC = IERC20(_usdc);
        DXY_BEAR = IERC20(_dxyBear);
    }

    // ==========================================
    // ADMIN FUNCTIONS
    // ==========================================

    /// @notice Pause the router. Blocks openLeverage and closeLeverage.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the router.
    function unpause() external onlyOwner {
        _unpause();
    }

}
