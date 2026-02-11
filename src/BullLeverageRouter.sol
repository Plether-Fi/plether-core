// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SyntheticSplitter} from "./SyntheticSplitter.sol";
import {LeverageRouterBase} from "./base/LeverageRouterBase.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {MarketParams} from "./interfaces/IMorpho.sol";
import {ISyntheticSplitter} from "./interfaces/ISyntheticSplitter.sol";
import {DecimalConstants} from "./libraries/DecimalConstants.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/// @title BullLeverageRouter
/// @custom:security-contact contact@plether.com
/// @notice Leverage router for plDXY-BULL positions via Morpho Blue.
/// @dev Uses Morpho flash loans + Splitter minting to acquire plDXY-BULL, then deposits as Morpho collateral.
///      Close operation uses a single plDXY-BEAR flash mint for simplicity and gas efficiency.
///      Uses Morpho's fee-free flash loans for capital efficiency.
///
/// @dev STATE MACHINE - OPEN LEVERAGE:
///      ┌─────────────────────────────────────────────────────────────────────────┐
///      │ openLeverage(principal, leverage)                                       │
///      │   1. Pull USDC from user                                                │
///      │   2. Flash loan additional USDC from Morpho (fee-free)                  │
///      │      └──► onMorphoFlashLoan(OP_OPEN)                                    │
///      │            └──► _executeOpen()                                          │
///      │                  1. Mint plDXY-BEAR + plDXY-BULL pairs via Splitter         │
///      │                  2. Sell plDXY-BEAR on Curve → USDC                       │
///      │                  3. Stake plDXY-BULL → splDXY-BULL                          │
///      │                  4. Deposit splDXY-BULL to Morpho (user's collateral)     │
///      │                  5. Borrow USDC from Morpho to cover flash repayment    │
///      │                  6. Emit LeverageOpened event                           │
///      └─────────────────────────────────────────────────────────────────────────┘
///
/// @dev STATE MACHINE - CLOSE LEVERAGE (Single Flash Mint):
///      ┌─────────────────────────────────────────────────────────────────────────┐
///      │ closeLeverage(debtToRepay, collateralToWithdraw)                        │
///      │   1. Flash mint plDXY-BEAR (collateral + extra for debt repayment)        │
///      │      └──► onFlashLoan(OP_CLOSE)                                         │
///      │            └──► _executeClose()                                         │
///      │                  1. Sell extra plDXY-BEAR on Curve → USDC                 │
///      │                  2. Repay user's Morpho debt with USDC from sale        │
///      │                  3. Withdraw user's splDXY-BULL from Morpho               │
///      │                  4. Unstake splDXY-BULL → plDXY-BULL                        │
///      │                  5. Redeem plDXY-BEAR + plDXY-BULL → USDC                   │
///      │                  6. Buy plDXY-BEAR on Curve to repay flash mint           │
///      │                  7. Transfer remaining USDC to user                     │
///      │                  8. Emit LeverageClosed event                           │
///      └─────────────────────────────────────────────────────────────────────────┘
///
/// @dev STATE MACHINE - ADD COLLATERAL (Morpho Flash Loan):
///      ┌─────────────────────────────────────────────────────────────────────────┐
///      │ addCollateral(usdcAmount)                                               │
///      │   1. Pull USDC from user                                                │
///      │   2. Flash loan USDC from Morpho (F = U × bearPrice / bullPrice)        │
///      │      └──► onMorphoFlashLoan(OP_ADD_COLLATERAL)                          │
///      │            └──► _executeAddCollateral()                                 │
///      │                  1. Mint plDXY-BEAR + plDXY-BULL pairs via Splitter       │
///      │                  2. Sell ALL plDXY-BEAR on Curve → USDC                   │
///      │                  3. Stake plDXY-BULL → splDXY-BULL                         │
///      │                  4. Deposit splDXY-BULL to Morpho (user's collateral)    │
///      │                  5. Repay flash loan from BEAR sale proceeds            │
///      │                  6. Emit CollateralAdded event                          │
///      └─────────────────────────────────────────────────────────────────────────┘
///
contract BullLeverageRouter is LeverageRouterBase {

    using SafeERC20 for IERC20;

    /// @notice Emitted when a leveraged plDXY-BULL position is opened.
    event LeverageOpened(
        address indexed user,
        uint256 principal,
        uint256 leverage,
        uint256 loanAmount,
        uint256 plDxyBullReceived,
        uint256 debtIncurred,
        uint256 maxSlippageBps
    );

    /// @notice Emitted when a leveraged plDXY-BULL position is closed.
    event LeverageClosed(
        address indexed user,
        uint256 debtRepaid,
        uint256 collateralWithdrawn,
        uint256 usdcReturned,
        uint256 maxSlippageBps
    );

    /// @notice Emitted when collateral is added to a position.
    /// @dev Net USDC cost = usdcAmount - usdcReturned (BEAR sale proceeds returned to user).
    event CollateralAdded(
        address indexed user, uint256 usdcAmount, uint256 usdcReturned, uint256 collateralAdded, uint256 maxSlippageBps
    );

    /// @notice Emitted when collateral is removed from a position.
    event CollateralRemoved(
        address indexed user, uint256 collateralWithdrawn, uint256 usdcReturned, uint256 maxSlippageBps
    );

    /// @notice SyntheticSplitter for minting/burning token pairs.
    ISyntheticSplitter public immutable SPLITTER;

    /// @notice plDXY-BULL token (collateral for bull positions).
    IERC20 public immutable PLDXY_BULL;

    /// @notice StakedToken vault for plDXY-BULL (used as Morpho collateral).
    IERC4626 public immutable STAKED_PLDXY_BULL;

    /// @notice Protocol CAP price (8 decimals, oracle format).
    uint256 public immutable CAP;

    /// @notice Oracle for plDXY basket price (returns BEAR price in 8 decimals).
    AggregatorV3Interface public immutable ORACLE;

    /// @notice Chainlink L2 sequencer uptime feed (address(0) on L1).
    AggregatorV3Interface public immutable SEQUENCER_UPTIME_FEED;

    /// @notice Maximum age for a valid oracle price.
    uint256 public constant ORACLE_TIMEOUT = 24 hours;

    /// @notice Grace period after L2 sequencer restarts before accepting prices.
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;

    /// @dev Operation type: remove collateral (flash mint).
    uint8 internal constant OP_REMOVE_COLLATERAL = 3;

    /// @dev Operation type: add collateral (Morpho flash loan).
    uint8 internal constant OP_ADD_COLLATERAL = 4;

    struct OpenParams {
        uint256 targetDebt;
        uint256 loanAmount;
        uint256 tokensToMint;
        uint256 expectedBearSale;
    }

    /// @notice Deploys BullLeverageRouter with Morpho market configuration.
    /// @param _morpho Morpho Blue protocol address.
    /// @param _splitter SyntheticSplitter contract address.
    /// @param _curvePool Curve USDC/plDXY-BEAR pool address.
    /// @param _usdc USDC token address.
    /// @param _plDxyBear plDXY-BEAR token address.
    /// @param _plDxyBull plDXY-BULL token address.
    /// @param _stakedPlDxyBull splDXY-BULL staking vault address.
    /// @param _marketParams Morpho market parameters for splDXY-BULL/USDC.
    /// @param _sequencerUptimeFeed Chainlink L2 sequencer feed (address(0) on L1/testnet).
    constructor(
        address _morpho,
        address _splitter,
        address _curvePool,
        address _usdc,
        address _plDxyBear,
        address _plDxyBull,
        address _stakedPlDxyBull,
        MarketParams memory _marketParams,
        address _sequencerUptimeFeed
    ) LeverageRouterBase(_morpho, _curvePool, _usdc, _plDxyBear) {
        if (_splitter == address(0)) {
            revert LeverageRouterBase__ZeroAddress();
        }
        if (_plDxyBull == address(0)) {
            revert LeverageRouterBase__ZeroAddress();
        }
        if (_stakedPlDxyBull == address(0)) {
            revert LeverageRouterBase__ZeroAddress();
        }

        SPLITTER = ISyntheticSplitter(_splitter);
        PLDXY_BULL = IERC20(_plDxyBull);
        STAKED_PLDXY_BULL = IERC4626(_stakedPlDxyBull);
        marketParams = _marketParams;

        // Cache CAP and ORACLE from Splitter (8 decimals)
        CAP = ISyntheticSplitter(_splitter).CAP();
        ORACLE = AggregatorV3Interface(SyntheticSplitter(_splitter).ORACLE());
        SEQUENCER_UPTIME_FEED = AggregatorV3Interface(_sequencerUptimeFeed);

        // Approvals (One-time)
        // 1. Allow Splitter to take USDC (for minting pairs)
        USDC.safeIncreaseAllowance(_splitter, type(uint256).max);
        // 2. Allow Curve pool to take plDXY-BEAR (for selling during open)
        PLDXY_BEAR.safeIncreaseAllowance(_curvePool, type(uint256).max);
        // 3. Allow Curve pool to take USDC (for buying BEAR during close)
        USDC.safeIncreaseAllowance(_curvePool, type(uint256).max);
        // 4. Allow StakedToken to take plDXY-BULL (for staking)
        PLDXY_BULL.safeIncreaseAllowance(_stakedPlDxyBull, type(uint256).max);
        // 5. Allow Morpho to take splDXY-BULL (for supplying collateral)
        IERC20(_stakedPlDxyBull).safeIncreaseAllowance(_morpho, type(uint256).max);
        // 6. Allow Morpho to take USDC (for repaying debt and flash loan)
        USDC.safeIncreaseAllowance(_morpho, type(uint256).max);
        // 7. Allow Splitter to take plDXY-BEAR (for redeeming pairs during close)
        PLDXY_BEAR.safeIncreaseAllowance(_splitter, type(uint256).max);
        // 8. Allow Splitter to take plDXY-BULL (for redeeming pairs during close)
        PLDXY_BULL.safeIncreaseAllowance(_splitter, type(uint256).max);
        // 9. Allow plDXY-BEAR to take back tokens (Flash Mint Repayment)
        PLDXY_BEAR.safeIncreaseAllowance(_plDxyBear, type(uint256).max);
    }

    /**
     * @notice Open a Leveraged plDXY-BULL Position in one transaction.
     * @dev Mints pairs via Splitter, sells plDXY-BEAR on Curve, deposits plDXY-BULL to Morpho.
     *      Uses fixed debt model (same as BEAR router) - Morpho debt equals principal * (leverage - 1).
     * @param principal Amount of USDC user sends.
     * @param leverage Multiplier (e.g. 3x = 3e18).
     * @param maxSlippageBps Maximum slippage tolerance in basis points (e.g., 50 = 0.5%).
     *        Capped at MAX_SLIPPAGE_BPS (1%) to limit MEV extraction.
     * @param deadline Unix timestamp after which the transaction reverts.
     */
    function openLeverage(
        uint256 principal,
        uint256 leverage,
        uint256 maxSlippageBps,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        _openLeverageCore(principal, leverage, maxSlippageBps, deadline);
    }

    /// @notice Open a leveraged plDXY-BULL position with a USDC permit signature (gasless approval).
    /// @param principal Amount of USDC user sends.
    /// @param leverage Multiplier (e.g. 3x = 3e18).
    /// @param maxSlippageBps Maximum slippage tolerance in basis points.
    /// @param deadline Unix timestamp after which the permit and transaction revert.
    /// @param v Signature recovery byte.
    /// @param r Signature r component.
    /// @param s Signature s component.
    function openLeverageWithPermit(
        uint256 principal,
        uint256 leverage,
        uint256 maxSlippageBps,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused {
        IERC20Permit(address(USDC)).permit(msg.sender, address(this), principal, deadline, v, r, s);
        _openLeverageCore(principal, leverage, maxSlippageBps, deadline);
    }

    function _openLeverageCore(
        uint256 principal,
        uint256 leverage,
        uint256 maxSlippageBps,
        uint256 deadline
    ) internal {
        if (principal == 0) {
            revert LeverageRouterBase__ZeroPrincipal();
        }
        if (block.timestamp > deadline) {
            revert LeverageRouterBase__Expired();
        }
        if (leverage <= DecimalConstants.ONE_WAD) {
            revert LeverageRouterBase__LeverageTooLow();
        }
        if (maxSlippageBps > MAX_SLIPPAGE_BPS) {
            revert LeverageRouterBase__SlippageExceedsMax();
        }
        if (!MORPHO.isAuthorized(msg.sender, address(this))) {
            revert LeverageRouterBase__NotAuthorized();
        }
        if (SPLITTER.currentStatus() != ISyntheticSplitter.Status.ACTIVE) {
            revert LeverageRouterBase__SplitterNotActive();
        }

        OpenParams memory params = _calculateOpenParams(principal, leverage);
        if (params.targetDebt == 0) {
            revert LeverageRouterBase__LeverageTooLow();
        }

        USDC.safeTransferFrom(msg.sender, address(this), principal);

        uint256 minSwapOut = (params.expectedBearSale * (10_000 - maxSlippageBps)) / 10_000;

        bytes memory data = abi.encode(
            OP_OPEN, msg.sender, deadline, principal, leverage, params.targetDebt, maxSlippageBps, minSwapOut
        );

        MORPHO.flashLoan(address(USDC), params.loanAmount, data);
    }

    /**
     * @notice Close a Leveraged plDXY-BULL Position in one transaction.
     * @dev Uses a single plDXY-BEAR flash mint to unwind positions efficiently.
     *      Queries actual debt from Morpho to ensure full repayment even if interest accrued.
     * @param collateralToWithdraw Amount of splDXY-BULL shares to withdraw from Morpho.
     *        NOTE: This is staked token shares, not underlying plDXY-BULL amount.
     *        Use STAKED_PLDXY_BULL.previewRedeem() to convert shares to underlying.
     * @param maxSlippageBps Maximum slippage tolerance in basis points.
     *        Capped at MAX_SLIPPAGE_BPS (1%) to limit MEV extraction.
     * @param deadline Unix timestamp after which the transaction reverts.
     */
    function closeLeverage(
        uint256 collateralToWithdraw,
        uint256 maxSlippageBps,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        if (collateralToWithdraw == 0) {
            revert LeverageRouterBase__ZeroCollateral();
        }
        if (block.timestamp > deadline) {
            revert LeverageRouterBase__Expired();
        }
        if (maxSlippageBps > MAX_SLIPPAGE_BPS) {
            revert LeverageRouterBase__SlippageExceedsMax();
        }
        if (!MORPHO.isAuthorized(msg.sender, address(this))) {
            revert LeverageRouterBase__NotAuthorized();
        }

        // Query actual debt and borrow shares from Morpho
        // We need debtToRepay for calculating BEAR to sell, and borrowShares for Morpho repayment
        // Using shares-based repayment avoids Morpho edge case when repaying exact totalBorrowAssets
        uint256 debtToRepay = _getActualDebt(msg.sender);
        uint256 borrowShares = _getBorrowShares(msg.sender);

        // Convert staked shares to underlying BULL amount (for pair matching)
        uint256 plDxyBullAmount = STAKED_PLDXY_BULL.previewRedeem(collateralToWithdraw);

        // Add buffer for exchange rate drift (protects against yield donation front-running)
        uint256 bufferedBullAmount = plDxyBullAmount + (plDxyBullAmount * EXCHANGE_RATE_BUFFER_BPS / 10_000);

        // Calculate extra BEAR needed to sell for debt repayment
        uint256 extraBearForDebt = 0;
        if (debtToRepay > 0) {
            // Query: how much USDC do we get for 1 BEAR (DecimalConstants.ONE_WAD)?
            uint256 usdcPerBear = CURVE_POOL.get_dy(PLDXY_BEAR_INDEX, USDC_INDEX, DecimalConstants.ONE_WAD);
            if (usdcPerBear == 0) {
                revert LeverageRouterBase__InvalidCurvePrice();
            }

            // Calculate BEAR needed to sell for debtToRepay USDC
            // Formula: (debt * DecimalConstants.ONE_WAD) / usdcPerBear, with slippage buffer
            extraBearForDebt = (debtToRepay * DecimalConstants.ONE_WAD) / usdcPerBear;
            // Add slippage buffer (extra % to ensure we get enough USDC)
            extraBearForDebt = extraBearForDebt + (extraBearForDebt * maxSlippageBps / 10_000);
        }

        // Total BEAR to flash mint: buffered amount for pair redemption + extra for debt
        uint256 flashAmount = bufferedBullAmount + extraBearForDebt;

        // Encode data for callback (includes borrowShares for shares-based Morpho repayment)
        bytes memory data = abi.encode(
            OP_CLOSE,
            msg.sender,
            deadline,
            collateralToWithdraw,
            debtToRepay,
            borrowShares,
            extraBearForDebt,
            maxSlippageBps
        );

        // Single flash mint handles entire close operation
        IERC3156FlashLender(address(PLDXY_BEAR)).flashLoan(this, address(PLDXY_BEAR), flashAmount, data);

        // Event emitted in _executeClose callback
    }

    /**
     * @notice Add collateral to an existing leveraged position.
     * @dev Uses Morpho flash loan so user's USDC input ≈ collateral value added.
     *      Flow: Flash loan USDC → Mint pairs → Sell ALL BEAR to repay flash loan → Keep BULL as collateral.
     *      Formula: flashLoan = userUSDC × bearPrice / bullPrice
     * @param usdcAmount Amount of USDC representing desired collateral value.
     * @param maxSlippageBps Maximum slippage tolerance in basis points.
     *        Capped at MAX_SLIPPAGE_BPS (1%) to limit MEV extraction.
     * @param deadline Unix timestamp after which the transaction reverts.
     */
    function addCollateral(
        uint256 usdcAmount,
        uint256 maxSlippageBps,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        _addCollateralCore(usdcAmount, maxSlippageBps, deadline);
    }

    /// @notice Add collateral with a USDC permit signature (gasless approval).
    /// @param usdcAmount Amount of USDC representing desired collateral value.
    /// @param maxSlippageBps Maximum slippage tolerance in basis points.
    /// @param deadline Unix timestamp after which the permit and transaction revert.
    /// @param v Signature recovery byte.
    /// @param r Signature r component.
    /// @param s Signature s component.
    function addCollateralWithPermit(
        uint256 usdcAmount,
        uint256 maxSlippageBps,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused {
        IERC20Permit(address(USDC)).permit(msg.sender, address(this), usdcAmount, deadline, v, r, s);
        _addCollateralCore(usdcAmount, maxSlippageBps, deadline);
    }

    function _addCollateralCore(
        uint256 usdcAmount,
        uint256 maxSlippageBps,
        uint256 deadline
    ) internal {
        if (usdcAmount == 0) {
            revert LeverageRouterBase__ZeroAmount();
        }
        if (block.timestamp > deadline) {
            revert LeverageRouterBase__Expired();
        }
        if (maxSlippageBps > MAX_SLIPPAGE_BPS) {
            revert LeverageRouterBase__SlippageExceedsMax();
        }
        if (!MORPHO.isAuthorized(msg.sender, address(this))) {
            revert LeverageRouterBase__NotAuthorized();
        }
        if (_getCollateral(msg.sender) == 0) {
            revert LeverageRouterBase__NoPosition();
        }
        if (SPLITTER.currentStatus() != ISyntheticSplitter.Status.ACTIVE) {
            revert LeverageRouterBase__SplitterNotActive();
        }

        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Calculate flash loan amount: F = U × bearPrice / bullPrice
        (uint256 bearPrice, uint256 bullPrice) = _getValidatedOraclePrice();

        // flashLoanAmount = usdcAmount * bearPrice / bullPrice
        // Subtract buffer to ensure BEAR sale proceeds exceed flash loan repayment
        uint256 flashLoanAmount = (usdcAmount * bearPrice) / bullPrice;
        flashLoanAmount = flashLoanAmount - (flashLoanAmount * maxSlippageBps / 10_000);

        // Calculate tokens to mint
        uint256 totalUSDC = usdcAmount + flashLoanAmount;
        uint256 tokensToMint = (totalUSDC * DecimalConstants.USDC_TO_TOKEN_SCALE) / CAP;
        if (tokensToMint == 0) {
            revert LeverageRouterBase__AmountTooSmall();
        }

        // Allow slippage on Curve swap, but callback verifies we have enough to repay
        uint256 minSwapOut = (flashLoanAmount * (10_000 - maxSlippageBps)) / 10_000;

        bytes memory data = abi.encode(OP_ADD_COLLATERAL, msg.sender, deadline, usdcAmount, maxSlippageBps, minSwapOut);

        MORPHO.flashLoan(address(USDC), flashLoanAmount, data);
    }

    /**
     * @notice Remove collateral from an existing leveraged position.
     * @dev Uses flash mint of BEAR to redeem pairs, then buys back BEAR with USDC.
     *      Reverts if the resulting position would be unhealthy.
     * @param collateralToWithdraw Amount of splDXY-BULL shares to withdraw.
     *        NOTE: This is staked token shares, not underlying plDXY-BULL amount.
     * @param maxSlippageBps Maximum slippage tolerance in basis points.
     *        Capped at MAX_SLIPPAGE_BPS (1%) to limit MEV extraction.
     * @param deadline Unix timestamp after which the transaction reverts.
     */
    function removeCollateral(
        uint256 collateralToWithdraw,
        uint256 maxSlippageBps,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        if (collateralToWithdraw == 0) {
            revert LeverageRouterBase__ZeroAmount();
        }
        if (block.timestamp > deadline) {
            revert LeverageRouterBase__Expired();
        }
        if (maxSlippageBps > MAX_SLIPPAGE_BPS) {
            revert LeverageRouterBase__SlippageExceedsMax();
        }
        if (!MORPHO.isAuthorized(msg.sender, address(this))) {
            revert LeverageRouterBase__NotAuthorized();
        }

        uint256 currentCollateral = _getCollateral(msg.sender);
        if (currentCollateral == 0) {
            revert LeverageRouterBase__NoPosition();
        }

        // Calculate BEAR needed to match BULL for pair redemption
        uint256 plDxyBullAmount = STAKED_PLDXY_BULL.previewRedeem(collateralToWithdraw);

        // Add buffer for exchange rate drift
        uint256 bufferedBullAmount = plDxyBullAmount + (plDxyBullAmount * EXCHANGE_RATE_BUFFER_BPS / 10_000);

        // Flash mint BEAR for pair redemption
        bytes memory data = abi.encode(OP_REMOVE_COLLATERAL, msg.sender, deadline, collateralToWithdraw, maxSlippageBps);

        IERC3156FlashLender(address(PLDXY_BEAR)).flashLoan(this, address(PLDXY_BEAR), bufferedBullAmount, data);
    }

    /// @notice Morpho flash loan callback for USDC flash loans (OP_OPEN, OP_ADD_COLLATERAL).
    /// @param amount Amount of USDC borrowed.
    /// @param data Encoded operation parameters.
    function onMorphoFlashLoan(
        uint256 amount,
        bytes calldata data
    ) external override {
        // Validate caller is Morpho
        _validateLender(msg.sender, address(MORPHO));

        uint8 operation = abi.decode(data, (uint8));

        if (operation == OP_OPEN) {
            _executeOpen(amount, data);
        } else if (operation == OP_ADD_COLLATERAL) {
            _executeAddCollateral(amount, data);
        } else {
            revert FlashLoan__InvalidOperation();
        }

        // Flash loan repayment: Morpho will pull tokens via transferFrom.
        // Constructor grants max approval, so no additional approval needed.
    }

    /// @notice ERC-3156 flash loan callback for plDXY-BEAR flash mints.
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

        uint8 operation = abi.decode(data, (uint8));

        if (operation == OP_CLOSE) {
            _executeClose(amount, fee, data);
        } else if (operation == OP_REMOVE_COLLATERAL) {
            _executeRemoveCollateral(amount, fee, data);
        } else {
            revert FlashLoan__InvalidOperation();
        }

        return CALLBACK_SUCCESS;
    }

    /// @dev Executes open leverage operation within Morpho flash loan callback.
    /// @param loanAmount Amount of USDC borrowed from Morpho.
    /// @param data Encoded parameters (op, user, deadline, principal, leverage, targetDebt, maxSlippageBps, minSwapOut).
    function _executeOpen(
        uint256 loanAmount,
        bytes calldata data
    ) private {
        // Decode: (op, user, deadline, principal, leverage, targetDebt, maxSlippageBps, minSwapOut)
        (
            ,
            address user,,
            uint256 principal,
            uint256 leverage,
            uint256 targetDebt,
            uint256 maxSlippageBps,
            uint256 minSwapOut
        ) = abi.decode(data, (uint8, address, uint256, uint256, uint256, uint256, uint256, uint256));

        // 1. Total USDC = Principal + Flash Loan
        uint256 totalUSDC = principal + loanAmount;

        // 2. Mint pairs via Splitter (USDC -> plDXY-BEAR + plDXY-BULL)
        SPLITTER.mint((totalUSDC * DecimalConstants.USDC_TO_TOKEN_SCALE) / CAP);

        // 3. Sell ALL plDXY-BEAR for USDC via Curve
        uint256 plDxyBearBalance = PLDXY_BEAR.balanceOf(address(this));
        CURVE_POOL.exchange(PLDXY_BEAR_INDEX, USDC_INDEX, plDxyBearBalance, minSwapOut);

        // 4. Stake plDXY-BULL to get splDXY-BULL
        uint256 plDxyBullReceived = PLDXY_BULL.balanceOf(address(this));
        uint256 stakedShares = STAKED_PLDXY_BULL.deposit(plDxyBullReceived, address(this));

        // 5. Deposit splDXY-BULL collateral to Morpho on behalf of the USER
        MORPHO.supplyCollateral(marketParams, stakedShares, user, "");

        // 6. Borrow exactly targetDebt from Morpho (fixed debt model, same as BEAR router)
        if (targetDebt > 0) {
            MORPHO.borrow(marketParams, targetDebt, 0, user, address(this));
        }

        // 7. Verify we can repay flash loan and return excess to user
        uint256 usdcBalance = USDC.balanceOf(address(this));
        if (usdcBalance < loanAmount) {
            revert LeverageRouterBase__InsufficientOutput();
        }
        uint256 excess = usdcBalance - loanAmount;
        if (excess > 0) {
            USDC.safeTransfer(user, excess);
        }

        // 8. Emit event for off-chain tracking
        emit LeverageOpened(user, principal, leverage, loanAmount, plDxyBullReceived, targetDebt, maxSlippageBps);
    }

    /// @dev Executes add collateral operation within Morpho flash loan callback.
    /// @param flashLoanAmount Amount of USDC flash loaned.
    /// @param data Encoded parameters (op, user, deadline, usdcAmount, maxSlippageBps, minSwapOut).
    function _executeAddCollateral(
        uint256 flashLoanAmount,
        bytes calldata data
    ) private {
        // Decode: (op, user, deadline, usdcAmount, maxSlippageBps, minSwapOut)
        (, address user,, uint256 usdcAmount, uint256 maxSlippageBps, uint256 minSwapOut) =
            abi.decode(data, (uint8, address, uint256, uint256, uint256, uint256));

        // 1. Total USDC = user's USDC + flash loan
        uint256 totalUSDC = usdcAmount + flashLoanAmount;

        // 2. Mint pairs via Splitter (USDC → BEAR + BULL)
        uint256 tokensToMint = (totalUSDC * DecimalConstants.USDC_TO_TOKEN_SCALE) / CAP;
        SPLITTER.mint(tokensToMint);

        // 3. Sell ALL BEAR for USDC (to repay flash loan)
        uint256 plDxyBearBalance = PLDXY_BEAR.balanceOf(address(this));
        CURVE_POOL.exchange(PLDXY_BEAR_INDEX, USDC_INDEX, plDxyBearBalance, minSwapOut);

        // 4. Stake BULL → splDXY-BULL
        uint256 plDxyBullBalance = PLDXY_BULL.balanceOf(address(this));
        uint256 stakedShares = STAKED_PLDXY_BULL.deposit(plDxyBullBalance, address(this));

        // 5. Deposit splDXY-BULL to Morpho on behalf of user
        MORPHO.supplyCollateral(marketParams, stakedShares, user, "");

        // 6. Verify we can repay flash loan
        uint256 usdcBalance = USDC.balanceOf(address(this));
        if (usdcBalance < flashLoanAmount) {
            revert LeverageRouterBase__InsufficientOutput();
        }

        // 7. Return any excess USDC to user (should be minimal with correct flash loan calculation)
        uint256 excessUsdc = usdcBalance - flashLoanAmount;
        if (excessUsdc > 0) {
            USDC.safeTransfer(user, excessUsdc);
        }

        // 8. Emit event (usdcReturned reflects actual excess, should be near-zero)
        emit CollateralAdded(user, usdcAmount, excessUsdc, stakedShares, maxSlippageBps);
    }

    /// @dev Executes close leverage operation within plDXY-BEAR flash mint callback.
    /// @param flashAmount Amount of plDXY-BEAR flash minted.
    /// @param flashFee Flash mint fee (always 0).
    /// @param data Encoded parameters (op, user, deadline, collateralToWithdraw, debtToRepay, borrowShares, extraBearForDebt, maxSlippageBps).
    function _executeClose(
        uint256 flashAmount,
        uint256 flashFee,
        bytes calldata data
    ) private {
        // Decode: (op, user, deadline, collateralToWithdraw, debtToRepay, borrowShares, extraBearForDebt, maxSlippageBps)
        (
            ,
            address user,,
            uint256 collateralToWithdraw,
            uint256 debtToRepay,
            uint256 borrowShares,
            uint256 extraBearForDebt,
            uint256 maxSlippageBps
        ) = abi.decode(data, (uint8, address, uint256, uint256, uint256, uint256, uint256, uint256));

        // 1. If debt exists, sell extra BEAR for USDC to repay it
        if (debtToRepay > 0 && extraBearForDebt > 0) {
            // Sell extraBearForDebt BEAR → USDC (with slippage protection)
            uint256 minUsdcFromSale = (debtToRepay * (10_000 - maxSlippageBps)) / 10_000;
            uint256 usdcFromSale = CURVE_POOL.exchange(PLDXY_BEAR_INDEX, USDC_INDEX, extraBearForDebt, minUsdcFromSale);
            if (usdcFromSale < debtToRepay) {
                revert LeverageRouterBase__InsufficientOutput();
            }
        }

        // 2. Repay user's debt on Morpho using shares (not assets)
        // Using shares-based repayment avoids Morpho edge case that panics when
        // repaying exactly totalBorrowAssets (full market debt)
        if (borrowShares > 0) {
            MORPHO.repay(marketParams, 0, borrowShares, user, "");
        }

        // 3. Withdraw user's splDXY-BULL collateral from Morpho
        MORPHO.withdrawCollateral(marketParams, collateralToWithdraw, user, address(this));

        // 4. Unstake splDXY-BULL to get plDXY-BULL
        uint256 plDxyBullReceived = STAKED_PLDXY_BULL.redeem(collateralToWithdraw, address(this), address(this));

        // 5. Redeem pairs via Splitter (plDXY-BEAR + plDXY-BULL → USDC)
        // We have exactly plDxyBullReceived BULL, and (flashAmount - extraBearForDebt) BEAR remaining
        SPLITTER.burn(plDxyBullReceived);

        // 6. Buy back ALL flash-minted BEAR to repay flash mint
        uint256 repayAmount = flashAmount + flashFee;

        // Current BEAR balance (from minting pairs)
        uint256 bearBalance = PLDXY_BEAR.balanceOf(address(this));

        // Need to buy: repayAmount - bearBalance
        if (repayAmount > bearBalance) {
            uint256 bearToBuy = repayAmount - bearBalance;

            // Estimate USDC needed using Curve price discovery
            uint256 bearPerUsdc = CURVE_POOL.get_dy(USDC_INDEX, PLDXY_BEAR_INDEX, DecimalConstants.ONE_USDC);
            if (bearPerUsdc == 0) {
                revert LeverageRouterBase__InvalidCurvePrice();
            }

            // Calculate USDC needed with slippage buffer
            uint256 estimatedUsdcNeeded = (bearToBuy * DecimalConstants.ONE_USDC) / bearPerUsdc;
            uint256 maxUsdcToSpend = estimatedUsdcNeeded + (estimatedUsdcNeeded * maxSlippageBps / 10_000);

            // Use available balance, capped at maxUsdcToSpend
            uint256 usdcBalance = USDC.balanceOf(address(this));
            uint256 usdcToSpend = usdcBalance < maxUsdcToSpend ? usdcBalance : maxUsdcToSpend;

            // Verify we have at least the base estimate (without buffer)
            if (usdcBalance < estimatedUsdcNeeded) {
                revert LeverageRouterBase__InsufficientOutput();
            }

            // Swap USDC → BEAR with slippage-tolerant min_dy
            uint256 minBearOut = (bearToBuy * (10_000 - maxSlippageBps)) / 10_000;
            CURVE_POOL.exchange(USDC_INDEX, PLDXY_BEAR_INDEX, usdcToSpend, minBearOut);
        }

        // 7. Transfer remaining USDC to user
        uint256 usdcToReturn = USDC.balanceOf(address(this));
        if (usdcToReturn > 0) {
            USDC.safeTransfer(user, usdcToReturn);
        }

        // 8. Sweep excess BEAR to user (from exchange rate buffer)
        uint256 finalBearBalance = PLDXY_BEAR.balanceOf(address(this));
        if (finalBearBalance > repayAmount) {
            PLDXY_BEAR.safeTransfer(user, finalBearBalance - repayAmount);
        }

        // 9. Emit event for off-chain tracking
        emit LeverageClosed(user, debtToRepay, collateralToWithdraw, usdcToReturn, maxSlippageBps);

        // Flash mint repayment happens automatically when callback returns
        // plDXY-BEAR token will burn repayAmount from this contract
    }

    /// @dev Executes remove collateral operation within plDXY-BEAR flash mint callback.
    /// @param flashAmount Amount of plDXY-BEAR flash minted.
    /// @param flashFee Flash mint fee (always 0).
    /// @param data Encoded parameters (op, user, deadline, collateralToWithdraw, maxSlippageBps).
    function _executeRemoveCollateral(
        uint256 flashAmount,
        uint256 flashFee,
        bytes calldata data
    ) private {
        // Decode: (op, user, deadline, collateralToWithdraw, maxSlippageBps)
        (, address user,, uint256 collateralToWithdraw, uint256 maxSlippageBps) =
            abi.decode(data, (uint8, address, uint256, uint256, uint256));

        // 1. Withdraw splDXY-BULL from Morpho (will revert if unhealthy)
        MORPHO.withdrawCollateral(marketParams, collateralToWithdraw, user, address(this));

        // 2. Unstake splDXY-BULL → plDXY-BULL
        uint256 plDxyBullReceived = STAKED_PLDXY_BULL.redeem(collateralToWithdraw, address(this), address(this));

        // 3. Burn pairs (BEAR + BULL → USDC)
        SPLITTER.burn(plDxyBullReceived);

        // 4. Buy back BEAR to repay flash mint
        uint256 repayAmount = flashAmount + flashFee;
        uint256 bearBalance = PLDXY_BEAR.balanceOf(address(this));

        if (repayAmount > bearBalance) {
            uint256 bearToBuy = repayAmount - bearBalance;

            // Estimate USDC needed using Curve price discovery
            uint256 bearPerUsdc = CURVE_POOL.get_dy(USDC_INDEX, PLDXY_BEAR_INDEX, DecimalConstants.ONE_USDC);
            if (bearPerUsdc == 0) {
                revert LeverageRouterBase__InvalidCurvePrice();
            }

            // Calculate USDC needed with slippage buffer
            uint256 estimatedUsdcNeeded = (bearToBuy * DecimalConstants.ONE_USDC) / bearPerUsdc;
            uint256 maxUsdcToSpend = estimatedUsdcNeeded + (estimatedUsdcNeeded * maxSlippageBps / 10_000);

            uint256 usdcBalance = USDC.balanceOf(address(this));
            uint256 usdcToSpend = usdcBalance < maxUsdcToSpend ? usdcBalance : maxUsdcToSpend;

            if (usdcBalance < estimatedUsdcNeeded) {
                revert LeverageRouterBase__InsufficientOutput();
            }

            // Swap USDC → BEAR with slippage-tolerant min_dy
            uint256 minBearOut = (bearToBuy * (10_000 - maxSlippageBps)) / 10_000;
            CURVE_POOL.exchange(USDC_INDEX, PLDXY_BEAR_INDEX, usdcToSpend, minBearOut);
        }

        // 5. Transfer remaining USDC to user
        uint256 usdcToReturn = USDC.balanceOf(address(this));
        if (usdcToReturn > 0) {
            USDC.safeTransfer(user, usdcToReturn);
        }

        // 6. Sweep excess BEAR to user (from exchange rate buffer)
        uint256 finalBearBalance = PLDXY_BEAR.balanceOf(address(this));
        if (finalBearBalance > repayAmount) {
            PLDXY_BEAR.safeTransfer(user, finalBearBalance - repayAmount);
        }

        // 7. Emit event
        emit CollateralRemoved(user, collateralToWithdraw, usdcToReturn, maxSlippageBps);

        // Flash mint repayment happens automatically when callback returns
    }

    // ==========================================
    // VIEW FUNCTIONS (for frontend)
    // ==========================================

    /**
     * @notice Preview the result of opening a leveraged plDXY-BULL position.
     * @dev BULL leverage requires a larger flash loan than BEAR because minting happens at CAP price,
     *      not market price. The flash loan is repaid by: bearSaleProceeds + morphoBorrow.
     *      Morpho debt still follows the fixed model: principal * (leverage - 1).
     * @param principal Amount of USDC user will send.
     * @param leverage Multiplier (e.g. 2x = 2e18).
     * @return loanAmount Amount of USDC to flash loan.
     * @return totalUSDC Total USDC for minting pairs (principal + loan).
     * @return expectedPlDxyBull Expected plDXY-BULL tokens received.
     * @return expectedDebt Expected Morpho debt (fixed: principal * (leverage - 1)).
     */
    function previewOpenLeverage(
        uint256 principal,
        uint256 leverage
    ) external view returns (uint256 loanAmount, uint256 totalUSDC, uint256 expectedPlDxyBull, uint256 expectedDebt) {
        if (leverage <= DecimalConstants.ONE_WAD) {
            revert LeverageRouterBase__LeverageTooLow();
        }

        OpenParams memory params = _calculateOpenParams(principal, leverage);
        loanAmount = params.loanAmount;
        totalUSDC = principal + loanAmount;
        expectedPlDxyBull = (totalUSDC * DecimalConstants.USDC_TO_TOKEN_SCALE) / CAP;
        expectedDebt = params.targetDebt;
    }

    /**
     * @notice Preview the result of closing a leveraged plDXY-BULL position.
     * @param debtToRepay Amount of USDC debt to repay.
     * @param collateralToWithdraw Amount of plDXY-BULL collateral to withdraw.
     * @return expectedUSDC Expected USDC from redeeming pairs.
     * @return usdcForBearBuyback Expected USDC needed to buy back plDXY-BEAR.
     * @return expectedReturn Expected USDC returned to user after all repayments.
     */
    function previewCloseLeverage(
        uint256 debtToRepay,
        uint256 collateralToWithdraw
    ) external view returns (uint256 expectedUSDC, uint256 usdcForBearBuyback, uint256 expectedReturn) {
        // Convert staked shares to underlying BULL amount
        uint256 plDxyBullAmount = STAKED_PLDXY_BULL.previewRedeem(collateralToWithdraw);

        // Redeeming pairs at CAP: usdc = tokens * CAP / DecimalConstants.USDC_TO_TOKEN_SCALE
        expectedUSDC = (plDxyBullAmount * CAP) / DecimalConstants.USDC_TO_TOKEN_SCALE;

        // Calculate extra BEAR needed to sell for debt repayment (mirrors closeLeverage logic)
        uint256 extraBearForDebt = 0;
        uint256 usdcFromBearSale = 0;
        if (debtToRepay > 0) {
            uint256 usdcPerBear = CURVE_POOL.get_dy(PLDXY_BEAR_INDEX, USDC_INDEX, DecimalConstants.ONE_WAD);
            if (usdcPerBear > 0) {
                // Calculate BEAR needed without slippage buffer (conservative estimate)
                extraBearForDebt = (debtToRepay * DecimalConstants.ONE_WAD) / usdcPerBear;
                // Estimate actual USDC from selling this BEAR
                usdcFromBearSale = CURVE_POOL.get_dy(PLDXY_BEAR_INDEX, USDC_INDEX, extraBearForDebt);
            }
        }

        // Total BEAR to buy back includes exchange rate buffer (mirrors closeLeverage logic)
        uint256 bufferedBullAmount = plDxyBullAmount + (plDxyBullAmount * EXCHANGE_RATE_BUFFER_BPS / 10_000);
        uint256 totalBearToBuyBack = bufferedBullAmount + extraBearForDebt;

        // Calculate USDC needed using get_dy for accurate AMM pricing
        usdcForBearBuyback = _estimateUsdcForBearBuyback(totalBearToBuyBack);

        // Net USDC flow:
        // + expectedUSDC (from burning pairs)
        // + usdcFromBearSale (from selling extra BEAR)
        // - debtToRepay (paid to Morpho)
        // - usdcForBearBuyback (to buy back flash-minted BEAR)
        uint256 totalInflows = expectedUSDC + usdcFromBearSale;
        uint256 totalOutflows = debtToRepay + usdcForBearBuyback;

        expectedReturn = totalInflows > totalOutflows ? totalInflows - totalOutflows : 0;
    }

    /**
     * @notice Preview the result of adding collateral.
     * @dev Uses flash loan so user's USDC input ≈ collateral value added.
     * @param usdcAmount Amount of USDC representing desired collateral value.
     * @return flashLoanAmount Amount of USDC to flash loan.
     * @return totalUSDC Total USDC for minting pairs.
     * @return expectedPlDxyBull Expected plDXY-BULL tokens to receive.
     * @return expectedStakedShares Expected splDXY-BULL shares to receive.
     */
    function previewAddCollateral(
        uint256 usdcAmount
    )
        external
        view
        returns (uint256 flashLoanAmount, uint256 totalUSDC, uint256 expectedPlDxyBull, uint256 expectedStakedShares)
    {
        // Calculate flash loan amount: F = U × bearPrice / bullPrice
        (uint256 bearPrice, uint256 bullPrice) = _getValidatedOraclePrice();

        flashLoanAmount = (usdcAmount * bearPrice) / bullPrice;
        flashLoanAmount = flashLoanAmount - (flashLoanAmount * MAX_SLIPPAGE_BPS / 10_000);

        totalUSDC = usdcAmount + flashLoanAmount;
        expectedPlDxyBull = (totalUSDC * DecimalConstants.USDC_TO_TOKEN_SCALE) / CAP;
        expectedStakedShares = STAKED_PLDXY_BULL.previewDeposit(expectedPlDxyBull);
    }

    /**
     * @notice Preview the result of removing collateral.
     * @param collateralToWithdraw Amount of splDXY-BULL shares to withdraw.
     * @return expectedPlDxyBull Expected plDXY-BULL from unstaking.
     * @return expectedUsdcFromBurn Expected USDC from burning pairs.
     * @return usdcForBearBuyback Expected USDC needed to buy back flash-minted BEAR.
     * @return expectedReturn Expected USDC returned to user.
     */
    function previewRemoveCollateral(
        uint256 collateralToWithdraw
    )
        external
        view
        returns (
            uint256 expectedPlDxyBull,
            uint256 expectedUsdcFromBurn,
            uint256 usdcForBearBuyback,
            uint256 expectedReturn
        )
    {
        expectedPlDxyBull = STAKED_PLDXY_BULL.previewRedeem(collateralToWithdraw);

        // USDC from burning pairs at CAP price
        expectedUsdcFromBurn = (expectedPlDxyBull * CAP) / DecimalConstants.USDC_TO_TOKEN_SCALE;

        // After burning pairs, we have (buffer) BEAR remaining but need to repay (buffer + expectedPlDxyBull).
        // So we need to buy back expectedPlDxyBull BEAR (the amount consumed by burning).
        usdcForBearBuyback = _estimateUsdcForBearBuyback(expectedPlDxyBull);

        expectedReturn = expectedUsdcFromBurn > usdcForBearBuyback ? expectedUsdcFromBurn - usdcForBearBuyback : 0;
    }

    /// @dev Calculates parameters for opening a leveraged position.
    function _calculateOpenParams(
        uint256 principal,
        uint256 leverage
    ) private view returns (OpenParams memory params) {
        params.targetDebt = (principal * (leverage - DecimalConstants.ONE_WAD)) / DecimalConstants.ONE_WAD;

        (, uint256 bullPrice) = _getValidatedOraclePrice();

        uint256 targetCollateralValue = (principal * leverage) / DecimalConstants.ONE_WAD;
        uint256 initialTokens = (targetCollateralValue * DecimalConstants.USDC_TO_TOKEN_SCALE) / bullPrice;

        params.expectedBearSale = CURVE_POOL.get_dy(PLDXY_BEAR_INDEX, USDC_INDEX, initialTokens);
        uint256 initialLoan = params.expectedBearSale + params.targetDebt;

        uint256 totalUSDC = principal + initialLoan;
        params.tokensToMint = (totalUSDC * DecimalConstants.USDC_TO_TOKEN_SCALE) / CAP;

        params.expectedBearSale = CURVE_POOL.get_dy(PLDXY_BEAR_INDEX, USDC_INDEX, params.tokensToMint);
        uint256 bufferedBearSale = (params.expectedBearSale * 9990) / 10_000;
        params.loanAmount = bufferedBearSale + params.targetDebt;
    }

    /// @dev Returns validated oracle prices with staleness, sequencer, and CAP checks.
    function _getValidatedOraclePrice() private view returns (uint256 bearPrice, uint256 bullPrice) {
        bearPrice = OracleLib.getValidatedPrice(ORACLE, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD, ORACLE_TIMEOUT);
        if (bearPrice >= CAP) {
            revert LeverageRouterBase__SplitterNotActive();
        }
        bullPrice = CAP - bearPrice;
    }

    /// @dev Estimates USDC needed to buy BEAR using binary search on Curve.
    /// @param bearAmount Target plDXY-BEAR amount to acquire.
    /// @return Estimated USDC needed (with slippage margin).
    function _estimateUsdcForBearBuyback(
        uint256 bearAmount
    ) private view returns (uint256) {
        if (bearAmount == 0) {
            return 0;
        }

        uint256 bearPerUsdc = CURVE_POOL.get_dy(USDC_INDEX, PLDXY_BEAR_INDEX, DecimalConstants.ONE_USDC);
        if (bearPerUsdc == 0) {
            return (bearAmount * CAP) / DecimalConstants.USDC_TO_TOKEN_SCALE;
        }

        // Binary search for accurate USDC estimate
        uint256 low = (bearAmount * DecimalConstants.ONE_USDC) / bearPerUsdc;
        uint256 high = low + (low / 5); // Start with 20% buffer

        // Ensure high is sufficient
        uint256 bearAtHigh = CURVE_POOL.get_dy(USDC_INDEX, PLDXY_BEAR_INDEX, high);
        while (bearAtHigh < bearAmount && high < type(uint128).max) {
            high = high * 2;
            bearAtHigh = CURVE_POOL.get_dy(USDC_INDEX, PLDXY_BEAR_INDEX, high);
        }

        // Binary search to find minimum USDC
        for (uint256 i = 0; i < 20; i++) {
            uint256 mid = (low + high) / 2;
            uint256 bearOut = CURVE_POOL.get_dy(USDC_INDEX, PLDXY_BEAR_INDEX, mid);
            if (bearOut >= bearAmount) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        return high;
    }

}
