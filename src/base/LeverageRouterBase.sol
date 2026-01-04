// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ICurvePool} from "../interfaces/ICurvePool.sol";
import {IMorpho, MarketParams} from "../interfaces/IMorpho.sol";
import {FlashLoanBase} from "./FlashLoanBase.sol";

/// @title LeverageRouterBase
/// @notice Abstract base contract for leverage routers with shared validation and admin logic.
/// @dev Provides common constants, immutables, modifiers, and admin functions for
///      LeverageRouter (DXY-BEAR) and BullLeverageRouter (DXY-BULL).
abstract contract LeverageRouterBase is FlashLoanBase, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ==========================================
    // CONSTANTS
    // ==========================================

    /// @notice Maximum slippage in basis points (1% = 100 bps)
    /// @dev Caps MEV extraction on Curve swaps
    uint256 public constant MAX_SLIPPAGE_BPS = 100;

    /// @notice USDC index in Curve USDC/DXY-BEAR pool
    uint256 public constant USDC_INDEX = 0;

    /// @notice DXY-BEAR index in Curve USDC/DXY-BEAR pool
    uint256 public constant DXY_BEAR_INDEX = 1;

    /// @notice Operation type: Open leverage position
    uint8 internal constant OP_OPEN = 1;

    /// @notice Operation type: Close leverage position
    uint8 internal constant OP_CLOSE = 2;

    // ==========================================
    // IMMUTABLES
    // ==========================================

    /// @notice Morpho Blue lending protocol
    IMorpho public immutable MORPHO;

    /// @notice Curve pool for USDC/DXY-BEAR swaps
    ICurvePool public immutable CURVE_POOL;

    /// @notice USDC stablecoin
    IERC20 public immutable USDC;

    /// @notice DXY-BEAR token (underlying for Bear positions, swap token for Bull positions)
    IERC20 public immutable DXY_BEAR;

    // ==========================================
    // STORAGE
    // ==========================================

    /// @notice Morpho market parameters (collateral token, loan token, oracle, IRM, LLTV)
    MarketParams public marketParams;

    // ==========================================
    // ERRORS
    // ==========================================

    error LeverageRouterBase__ZeroAddress();

    // ==========================================
    // CONSTRUCTOR
    // ==========================================

    constructor(address _morpho, address _curvePool, address _usdc, address _dxyBear) Ownable(msg.sender) {
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
