// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {FlashLoanBase} from "./base/FlashLoanBase.sol";
import {ICurvePool} from "./interfaces/ICurvePool.sol";
import {ISyntheticSplitter} from "./interfaces/ISyntheticSplitter.sol";
import {DecimalConstants} from "./libraries/DecimalConstants.sol";

/// @title ZapRouter
/// @custom:security-contact contact@plether.com
/// @notice Efficient router for acquiring plDXY-BULL tokens using flash mints.
/// @dev Flash mints plDXY-BEAR → swaps to USDC via Curve → mints pairs → keeps plDXY-BULL.
///      For plDXY-BEAR, users should swap directly on Curve instead.
contract ZapRouter is FlashLoanBase, Ownable2Step, Pausable, ReentrancyGuard {

    using SafeERC20 for IERC20;

    /// @notice Maximum allowed slippage in basis points (1% = 100 bps).
    uint256 public constant MAX_SLIPPAGE_BPS = 100;

    /// @notice Safety buffer for flash loan repayment calculations (0.5% = 50 bps).
    uint256 public constant SAFETY_BUFFER_BPS = 50;

    /// @notice USDC index in the Curve USDC/plDXY-BEAR pool.
    uint256 public constant USDC_INDEX = 0;

    /// @notice plDXY-BEAR index in the Curve USDC/plDXY-BEAR pool.
    uint256 public constant PLDXY_BEAR_INDEX = 1;

    /// @notice SyntheticSplitter contract for minting/burning pairs.
    ISyntheticSplitter public immutable SPLITTER;

    /// @notice plDXY-BEAR token (flash minted for swaps).
    IERC20 public immutable PLDXY_BEAR;

    /// @notice plDXY-BULL token (output of zap operations).
    IERC20 public immutable PLDXY_BULL;

    /// @notice USDC stablecoin.
    IERC20 public immutable USDC;

    /// @notice Curve pool for USDC/plDXY-BEAR swaps.
    ICurvePool public immutable CURVE_POOL;

    /// @notice Protocol CAP price (8 decimals, oracle format).
    uint256 public immutable CAP;

    /// @notice CAP price scaled for Curve comparison (6 decimals).
    uint256 public immutable CAP_PRICE;

    /// @dev Flash loan action: mint plDXY-BULL.
    uint256 private constant ACTION_MINT = 0;

    /// @dev Flash loan action: burn plDXY-BULL.
    uint256 private constant ACTION_BURN = 1;

    /// @notice Emitted when user acquires plDXY-BULL via zapMint.
    event ZapMint(
        address indexed user, uint256 usdcIn, uint256 tokensOut, uint256 maxSlippageBps, uint256 actualSwapOut
    );

    /// @notice Emitted when user sells plDXY-BULL via zapBurn.
    event ZapBurn(address indexed user, uint256 tokensIn, uint256 usdcOut);

    error ZapRouter__ZeroAddress();
    error ZapRouter__ZeroAmount();
    error ZapRouter__Expired();
    error ZapRouter__SlippageExceedsMax();
    error ZapRouter__SplitterNotActive();
    error ZapRouter__BearPriceAboveCap();
    error ZapRouter__InsufficientOutput();
    error ZapRouter__InvalidCurvePrice();
    error ZapRouter__SolvencyBreach();

    /// @notice Deploys ZapRouter with required protocol dependencies.
    /// @param _splitter SyntheticSplitter contract address.
    /// @param _plDxyBear plDXY-BEAR token address.
    /// @param _plDxyBull plDXY-BULL token address.
    /// @param _usdc USDC token address.
    /// @param _curvePool Curve USDC/plDXY-BEAR pool address.
    constructor(
        address _splitter,
        address _plDxyBear,
        address _plDxyBull,
        address _usdc,
        address _curvePool
    ) Ownable(msg.sender) {
        if (_splitter == address(0)) {
            revert ZapRouter__ZeroAddress();
        }
        if (_plDxyBear == address(0)) {
            revert ZapRouter__ZeroAddress();
        }
        if (_plDxyBull == address(0)) {
            revert ZapRouter__ZeroAddress();
        }
        if (_usdc == address(0)) {
            revert ZapRouter__ZeroAddress();
        }
        if (_curvePool == address(0)) {
            revert ZapRouter__ZeroAddress();
        }

        SPLITTER = ISyntheticSplitter(_splitter);
        PLDXY_BEAR = IERC20(_plDxyBear);
        PLDXY_BULL = IERC20(_plDxyBull);
        USDC = IERC20(_usdc);
        CURVE_POOL = ICurvePool(_curvePool);

        // Cache CAP from Splitter (8 decimals) and derive 6-decimal version for price checks
        CAP = ISyntheticSplitter(_splitter).CAP();
        CAP_PRICE = CAP / 100; // 8 dec -> 6 dec

        // Pre-approve the Splitter to take our USDC
        USDC.safeIncreaseAllowance(_splitter, type(uint256).max);
        // Pre-approve the Curve pool to take plDXY-BEAR (for swapping)
        IERC20(_plDxyBear).safeIncreaseAllowance(_curvePool, type(uint256).max);
        USDC.safeIncreaseAllowance(_curvePool, type(uint256).max);
    }

    /**
     * @notice Buy plDXY-BULL using USDC with flash mint efficiency.
     * @dev For plDXY-BEAR, swap directly on Curve instead.
     * @param usdcAmount The amount of USDC the user is sending.
     * @param minAmountOut Minimum amount of plDXY-BULL tokens to receive.
     * @param maxSlippageBps Maximum slippage tolerance in basis points (e.g., 100 = 1%).
     * Capped at MAX_SLIPPAGE_BPS (1%) to limit MEV extraction.
     * @param deadline Unix timestamp after which the transaction reverts.
     */
    function zapMint(
        uint256 usdcAmount,
        uint256 minAmountOut,
        uint256 maxSlippageBps,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        _zapMintCore(usdcAmount, minAmountOut, maxSlippageBps, deadline);
    }

    /// @notice Buy plDXY-BULL using USDC with a permit signature (gasless approval).
    /// @param usdcAmount The amount of USDC the user is sending.
    /// @param minAmountOut Minimum amount of plDXY-BULL tokens to receive.
    /// @param maxSlippageBps Maximum slippage tolerance in basis points.
    /// @param deadline Unix timestamp after which the permit and transaction revert.
    /// @param v Signature recovery byte.
    /// @param r Signature r component.
    /// @param s Signature s component.
    function zapMintWithPermit(
        uint256 usdcAmount,
        uint256 minAmountOut,
        uint256 maxSlippageBps,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused {
        IERC20Permit(address(USDC)).permit(msg.sender, address(this), usdcAmount, deadline, v, r, s);
        _zapMintCore(usdcAmount, minAmountOut, maxSlippageBps, deadline);
    }

    function _zapMintCore(
        uint256 usdcAmount,
        uint256 minAmountOut,
        uint256 maxSlippageBps,
        uint256 deadline
    ) internal {
        if (usdcAmount == 0) {
            revert ZapRouter__ZeroAmount();
        }
        if (block.timestamp > deadline) {
            revert ZapRouter__Expired();
        }
        if (maxSlippageBps > MAX_SLIPPAGE_BPS) {
            revert ZapRouter__SlippageExceedsMax();
        }
        if (SPLITTER.currentStatus() != ISyntheticSplitter.Status.ACTIVE) {
            revert ZapRouter__SplitterNotActive();
        }

        uint256 priceBear = CURVE_POOL.get_dy(PLDXY_BEAR_INDEX, USDC_INDEX, DecimalConstants.ONE_WAD);
        if (priceBear >= CAP_PRICE) {
            revert ZapRouter__BearPriceAboveCap();
        }

        uint256 priceBull = CAP_PRICE - priceBear;
        uint256 theoreticalFlash = (usdcAmount * DecimalConstants.ONE_WAD) / priceBull;

        uint256 flashAmount = (theoreticalFlash * (10_000 - SAFETY_BUFFER_BPS)) / 10_000;

        uint256 expectedSwapOut = CURVE_POOL.get_dy(PLDXY_BEAR_INDEX, USDC_INDEX, flashAmount);
        uint256 minSwapOut = (expectedSwapOut * (10_000 - maxSlippageBps)) / 10_000;

        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);

        bytes memory data = abi.encode(ACTION_MINT, msg.sender, usdcAmount, minSwapOut, minAmountOut, maxSlippageBps);

        IERC3156FlashLender(address(PLDXY_BEAR)).flashLoan(this, address(PLDXY_BEAR), flashAmount, data);
    }

    // =================================================================
    // ZAP BURN (BULL -> USDC)
    // =================================================================

    /// @notice Sell plDXY-BULL tokens for USDC using flash mint efficiency.
    /// @param bullAmount Amount of plDXY-BULL to sell.
    /// @param minUsdcOut Minimum USDC to receive (slippage protection).
    /// @param deadline Unix timestamp after which the transaction reverts.
    function zapBurn(
        uint256 bullAmount,
        uint256 minUsdcOut,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        _zapBurnCore(bullAmount, minUsdcOut, deadline);
    }

    /// @notice Sell plDXY-BULL tokens for USDC with a permit signature (gasless approval).
    /// @param bullAmount Amount of plDXY-BULL to sell.
    /// @param minUsdcOut Minimum USDC to receive (slippage protection).
    /// @param deadline Unix timestamp after which the transaction reverts.
    /// @param v Signature recovery byte.
    /// @param r Signature r component.
    /// @param s Signature s component.
    function zapBurnWithPermit(
        uint256 bullAmount,
        uint256 minUsdcOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused {
        IERC20Permit(address(PLDXY_BULL)).permit(msg.sender, address(this), bullAmount, deadline, v, r, s);
        _zapBurnCore(bullAmount, minUsdcOut, deadline);
    }

    function _zapBurnCore(
        uint256 bullAmount,
        uint256 minUsdcOut,
        uint256 deadline
    ) internal {
        if (bullAmount == 0) {
            revert ZapRouter__ZeroAmount();
        }
        if (block.timestamp > deadline) {
            revert ZapRouter__Expired();
        }

        PLDXY_BULL.safeTransferFrom(msg.sender, address(this), bullAmount);

        uint256 flashAmount = bullAmount;

        bytes memory data = abi.encode(ACTION_BURN, msg.sender, bullAmount, minUsdcOut);
        IERC3156FlashLender(address(PLDXY_BEAR)).flashLoan(this, address(PLDXY_BEAR), flashAmount, data);
    }

    // =================================================================
    // FLASH LOAN CALLBACK
    // =================================================================

    /// @notice ERC-3156 flash loan callback. Routes to mint or burn handler.
    /// @param initiator Address that initiated the flash loan (must be this contract).
    /// @param amount Amount of plDXY-BEAR borrowed.
    /// @param fee Flash loan fee (always 0 for SyntheticToken).
    /// @param data Encoded operation parameters.
    /// @return CALLBACK_SUCCESS on successful execution.
    function onFlashLoan(
        address initiator,
        address,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        _validateFlashLoan(msg.sender, address(PLDXY_BEAR), initiator);

        // Decode Action Flag First
        uint256 action = abi.decode(data, (uint256));

        if (action == ACTION_MINT) {
            _handleMint(amount, fee, data);
        } else {
            _handleBurn(amount, fee, data);
        }

        return CALLBACK_SUCCESS;
    }

    /// @notice Morpho flash loan callback - not used by ZapRouter.
    /// @dev Always reverts as ZapRouter only uses ERC-3156 flash mints.
    function onMorphoFlashLoan(
        uint256,
        bytes calldata
    ) external pure override {
        revert FlashLoan__InvalidOperation();
    }

    /// @dev Executes mint operation within flash loan callback.
    /// @param loanAmount Amount of plDXY-BEAR borrowed.
    /// @param fee Flash loan fee (always 0).
    /// @param data Encoded mint parameters (action, user, usdcAmount, minSwapOut, minAmountOut, maxSlippageBps).
    function _handleMint(
        uint256 loanAmount,
        uint256 fee,
        bytes calldata data
    ) internal {
        // Decode: (action, user, usdcAmount, minSwapOut, minAmountOut, maxSlippageBps)
        (, address user, uint256 usdcAmount, uint256 minSwapOut, uint256 minAmountOut, uint256 maxSlippageBps) =
            abi.decode(data, (uint256, address, uint256, uint256, uint256, uint256));

        // 1. Swap Borrowed Bear -> USDC via Curve
        uint256 swappedUsdc = CURVE_POOL.exchange(PLDXY_BEAR_INDEX, USDC_INDEX, loanAmount, minSwapOut);

        // Use balance check as source of truth (handles dust/fee-on-transfer edge cases)
        uint256 totalUsdc = USDC.balanceOf(address(this));

        // Calculate mint amount: scale USDC (6 dec) to pairs (18 dec) using CAP
        // Formula: mintAmount = totalUsdc * USDC_TO_TOKEN_SCALE / CAP (inverse of Splitter's usdcNeeded calculation)
        uint256 mintAmount = (totalUsdc * DecimalConstants.USDC_TO_TOKEN_SCALE) / CAP;

        // Note: Splitter is already approved for max in constructor
        SPLITTER.mint(mintAmount);

        // 2. Repay the Flash Loan
        uint256 repayAmount = loanAmount + fee;
        PLDXY_BEAR.safeIncreaseAllowance(msg.sender, repayAmount);

        // 3. Sweep Dust
        // Check if we successfully minted enough to repay (Safety Check)
        uint256 currentBalance = PLDXY_BEAR.balanceOf(address(this));
        if (currentBalance < repayAmount) {
            revert ZapRouter__SolvencyBreach();
        }

        if (currentBalance > repayAmount) {
            uint256 surplus = currentBalance - repayAmount;
            PLDXY_BEAR.safeTransfer(user, surplus);
        }

        // 4. Transfer plDXY-BULL to user and emit event
        uint256 tokensOut = PLDXY_BULL.balanceOf(address(this));
        if (tokensOut < minAmountOut) {
            revert ZapRouter__InsufficientOutput();
        }
        PLDXY_BULL.safeTransfer(user, tokensOut);

        emit ZapMint(user, usdcAmount, tokensOut, maxSlippageBps, swappedUsdc);
    }

    /// @dev Executes burn operation within flash loan callback.
    /// @param loanAmount Amount of plDXY-BEAR borrowed.
    /// @param fee Flash loan fee (always 0).
    /// @param data Encoded burn parameters (action, user, bullAmount, minUsdcOut).
    function _handleBurn(
        uint256 loanAmount,
        uint256 fee,
        bytes calldata data
    ) internal {
        // Decode: (action, user, bullAmount, minUsdcOut)
        (, address user, uint256 bullAmount, uint256 minUsdcOut) =
            abi.decode(data, (uint256, address, uint256, uint256));

        // State: We have `loanAmount` Bear (Borrowed) + `loanAmount` Bull (From User)

        // 1. Combine to Unlock USDC
        // This burns Bull+Bear and sends USDC to this contract
        SPLITTER.burn(loanAmount);

        // 2. Calculate Debt in Bear (Loan + Fee)
        uint256 debtBear = loanAmount + fee;

        // 3. Buy Debt Bear using USDC
        uint256 bearFromOneUsdc = CURVE_POOL.get_dy(USDC_INDEX, PLDXY_BEAR_INDEX, DecimalConstants.ONE_USDC);
        if (bearFromOneUsdc == 0) {
            revert ZapRouter__InvalidCurvePrice();
        }

        // Linear estimate (first approximation)
        uint256 usdcLinear = (debtBear * DecimalConstants.ONE_USDC) / bearFromOneUsdc;

        // Correct for AMM price impact: check actual output at linear estimate
        uint256 actualBearFromLinear = CURVE_POOL.get_dy(USDC_INDEX, PLDXY_BEAR_INDEX, usdcLinear);
        uint256 usdcAdjusted =
            actualBearFromLinear >= debtBear ? usdcLinear : (usdcLinear * debtBear) / actualBearFromLinear;

        // Apply safety buffer for any remaining slippage
        uint256 usdcToSwap = (usdcAdjusted * (10_000 + SAFETY_BUFFER_BPS)) / 10_000;

        // Sanity Check: Do we have enough USDC?
        uint256 totalUsdc = USDC.balanceOf(address(this));
        if (usdcToSwap > totalUsdc) {
            usdcToSwap = totalUsdc; // Cap at max available (hoping it's enough)
        }

        // Execute Swap with MEV protection: require at least debtBear output
        CURVE_POOL.exchange(USDC_INDEX, PLDXY_BEAR_INDEX, usdcToSwap, debtBear);

        // 4. Repay Loan
        PLDXY_BEAR.safeIncreaseAllowance(msg.sender, debtBear);

        // 5. Send remaining USDC to User (The Exit)
        uint256 remainingUsdc = USDC.balanceOf(address(this));
        if (remainingUsdc < minUsdcOut) {
            revert ZapRouter__InsufficientOutput();
        }
        USDC.safeTransfer(user, remainingUsdc);

        // 6. Sweep Dust Bear
        uint256 bearBalance = PLDXY_BEAR.balanceOf(address(this));
        if (bearBalance > debtBear) {
            PLDXY_BEAR.safeTransfer(user, bearBalance - debtBear);
        }

        // 7. Emit event
        emit ZapBurn(user, bullAmount, remainingUsdc);
    }

    // ==========================================
    // VIEW FUNCTIONS (for frontend)
    // ==========================================

    /**
     * @notice Preview the result of a zapMint operation.
     * @param usdcAmount The amount of USDC the user will send.
     * @return flashAmount Amount of plDXY-BEAR to flash mint.
     * @return expectedSwapOut Expected USDC from selling flash-minted plDXY-BEAR.
     * @return totalUSDC Total USDC for minting pairs (user + swap).
     * @return expectedTokensOut Expected plDXY-BULL tokens to receive.
     * @return flashFee Flash mint fee (if any).
     */
    function previewZapMint(
        uint256 usdcAmount
    )
        external
        view
        returns (
            uint256 flashAmount,
            uint256 expectedSwapOut,
            uint256 totalUSDC,
            uint256 expectedTokensOut,
            uint256 flashFee
        )
    {
        uint256 priceBear = CURVE_POOL.get_dy(PLDXY_BEAR_INDEX, USDC_INDEX, DecimalConstants.ONE_WAD);
        if (priceBear >= CAP_PRICE) {
            return (0, 0, 0, 0, 0);
        }

        // Calculate Bull Price
        uint256 priceBull = CAP_PRICE - priceBear;

        // Calculate Dynamic Flash Amount (matches execution logic)
        uint256 theoreticalFlash = (usdcAmount * DecimalConstants.ONE_WAD) / priceBull;
        flashAmount = (theoreticalFlash * (10_000 - SAFETY_BUFFER_BPS)) / 10_000;

        expectedSwapOut = CURVE_POOL.get_dy(PLDXY_BEAR_INDEX, USDC_INDEX, flashAmount);
        totalUSDC = usdcAmount + expectedSwapOut;

        expectedTokensOut = (totalUSDC * DecimalConstants.USDC_TO_TOKEN_SCALE) / CAP;

        flashFee = IERC3156FlashLender(address(PLDXY_BEAR)).flashFee(address(PLDXY_BEAR), flashAmount);
    }

    /**
     * @notice Preview the result of a zapBurn operation.
     * @param bullAmount The amount of plDXY-BULL tokens to sell.
     * @return expectedUsdcFromBurn USDC received from burning pairs via Splitter.
     * @return usdcForBearBuyback USDC needed to buy back plDXY-BEAR for flash loan repayment.
     * @return expectedUsdcOut Net USDC the user will receive.
     * @return flashFee Flash mint fee (if any).
     */
    function previewZapBurn(
        uint256 bullAmount
    )
        external
        view
        returns (uint256 expectedUsdcFromBurn, uint256 usdcForBearBuyback, uint256 expectedUsdcOut, uint256 flashFee)
    {
        if (bullAmount == 0) {
            return (0, 0, 0, 0);
        }

        // Flash borrow amount equals bull amount (1:1 for pair burning)
        uint256 flashAmount = bullAmount;

        // Get flash fee
        flashFee = IERC3156FlashLender(address(PLDXY_BEAR)).flashFee(address(PLDXY_BEAR), flashAmount);

        // USDC from burning pairs: bullAmount tokens at CAP price
        // Formula from Splitter: usdcRefund = (amount * CAP) / USDC_MULTIPLIER
        // Simplified: (bullAmount * CAP) / 1e20 = bullAmount * 2e8 / 1e20 = bullAmount / 5e11
        expectedUsdcFromBurn = (bullAmount * CAP) / DecimalConstants.USDC_TO_TOKEN_SCALE;

        // Calculate USDC needed to buy back BEAR for repayment
        uint256 debtBear = flashAmount + flashFee;

        // Get price: how much BEAR do we get for 1 USDC?
        uint256 bearFromOneUsdc = CURVE_POOL.get_dy(USDC_INDEX, PLDXY_BEAR_INDEX, DecimalConstants.ONE_USDC);
        if (bearFromOneUsdc == 0) {
            return (expectedUsdcFromBurn, 0, 0, flashFee);
        }

        // Linear USDC requirement (first approximation)
        uint256 usdcLinear = (debtBear * DecimalConstants.ONE_USDC) / bearFromOneUsdc;

        // Correct for AMM price impact: check actual output at linear estimate
        uint256 actualBearFromLinear = CURVE_POOL.get_dy(USDC_INDEX, PLDXY_BEAR_INDEX, usdcLinear);
        uint256 usdcAdjusted =
            actualBearFromLinear >= debtBear ? usdcLinear : (usdcLinear * debtBear) / actualBearFromLinear;

        // Apply safety buffer
        usdcForBearBuyback = (usdcAdjusted * (10_000 + SAFETY_BUFFER_BPS)) / 10_000;

        // Net USDC out = burn proceeds - buyback cost
        if (expectedUsdcFromBurn > usdcForBearBuyback) {
            expectedUsdcOut = expectedUsdcFromBurn - usdcForBearBuyback;
        } else {
            expectedUsdcOut = 0;
        }
    }

    // ==========================================
    // ADMIN FUNCTIONS
    // ==========================================

    /// @notice Pause the router. Blocks zapMint and zapBurn.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the router.
    function unpause() external onlyOwner {
        _unpause();
    }

}
