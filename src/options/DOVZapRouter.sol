// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {FlashLoanBase} from "../base/FlashLoanBase.sol";
import {ICurvePool} from "../interfaces/ICurvePool.sol";
import {ISyntheticSplitter} from "../interfaces/ISyntheticSplitter.sol";
import {DecimalConstants} from "../libraries/DecimalConstants.sol";
import {PletherDOV} from "./PletherDOV.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DOVZapRouter
/// @custom:security-contact contact@plether.com
/// @notice Coordinates USDC→splDXY zaps across BEAR and BULL DOVs.
/// @dev Mints pairs for the overlapping USDC amount (zero slippage), routes excess through Curve or flash mint.
contract DOVZapRouter is FlashLoanBase, ReentrancyGuard, Ownable2Step {

    using SafeERC20 for IERC20;

    struct EpochParams {
        uint256 strike;
        uint256 expiry;
        uint256 maxPremium;
        uint256 minPremium;
        uint256 duration;
    }

    uint256 public constant USDC_INDEX = 0;
    uint256 public constant PLDXY_BEAR_INDEX = 1;
    uint256 public constant SAFETY_BUFFER_BPS = 50;

    ISyntheticSplitter public immutable SPLITTER;
    ICurvePool public immutable CURVE_POOL;
    IERC20 public immutable USDC;
    IERC20 public immutable PLDXY_BEAR;
    IERC20 public immutable PLDXY_BULL;
    IERC4626 public immutable STAKED_BEAR;
    IERC4626 public immutable STAKED_BULL;
    PletherDOV public immutable BEAR_DOV;
    PletherDOV public immutable BULL_DOV;
    uint256 public immutable CAP;
    uint256 public immutable CAP_PRICE;

    error DOVZapRouter__SolvencyBreach();
    error DOVZapRouter__BearPriceAboveCap();

    event CoordinatedZap(uint256 bearUsdc, uint256 bullUsdc, uint256 matchedAmount);

    constructor(
        address _splitter,
        address _curvePool,
        address _usdc,
        address _plDxyBear,
        address _plDxyBull,
        address _stakedBear,
        address _stakedBull,
        address _bearDov,
        address _bullDov
    ) Ownable(msg.sender) {
        SPLITTER = ISyntheticSplitter(_splitter);
        CURVE_POOL = ICurvePool(_curvePool);
        USDC = IERC20(_usdc);
        PLDXY_BEAR = IERC20(_plDxyBear);
        PLDXY_BULL = IERC20(_plDxyBull);
        STAKED_BEAR = IERC4626(_stakedBear);
        STAKED_BULL = IERC4626(_stakedBull);
        BEAR_DOV = PletherDOV(_bearDov);
        BULL_DOV = PletherDOV(_bullDov);
        CAP = ISyntheticSplitter(_splitter).CAP();
        CAP_PRICE = ISyntheticSplitter(_splitter).CAP() / 100;

        IERC20(_usdc).safeIncreaseAllowance(_splitter, type(uint256).max);
        IERC20(_usdc).safeIncreaseAllowance(_curvePool, type(uint256).max);
        IERC20(_plDxyBear).safeIncreaseAllowance(_curvePool, type(uint256).max);
        IERC20(_plDxyBear).safeIncreaseAllowance(_stakedBear, type(uint256).max);
        IERC20(_plDxyBull).safeIncreaseAllowance(_stakedBull, type(uint256).max);
    }

    /// @notice Pulls USDC from both DOVs, mints matched pairs, routes excess, starts epoch auctions.
    function coordinatedZapAndStartEpochs(
        EpochParams calldata bearParams,
        EpochParams calldata bullParams,
        uint256 minSwapOut
    ) external onlyOwner nonReentrant {
        uint256 bearUsdc;
        uint256 bullUsdc;

        if (address(BEAR_DOV) != address(0)) {
            bearUsdc = BEAR_DOV.releaseUsdcForZap();
        }
        if (address(BULL_DOV) != address(0)) {
            bullUsdc = BULL_DOV.releaseUsdcForZap();
        }

        uint256 matched = bearUsdc < bullUsdc ? bearUsdc : bullUsdc;

        if (matched > 0) {
            uint256 mintAmount = (matched * 2 * DecimalConstants.USDC_TO_TOKEN_SCALE) / CAP;
            SPLITTER.mint(mintAmount);
            STAKED_BEAR.deposit(mintAmount, address(BEAR_DOV));
            STAKED_BULL.deposit(mintAmount, address(BULL_DOV));
        }

        uint256 bearExcess = bearUsdc - matched;
        uint256 bullExcess = bullUsdc - matched;

        if (bearExcess > 0) {
            uint256 bearReceived = CURVE_POOL.exchange(USDC_INDEX, PLDXY_BEAR_INDEX, bearExcess, minSwapOut);
            STAKED_BEAR.deposit(bearReceived, address(BEAR_DOV));
        }

        if (bullExcess > 0) {
            _flashZapBull(bullExcess, minSwapOut);
        }

        if (address(BEAR_DOV) != address(0)) {
            BEAR_DOV.startEpochAuction(
                bearParams.strike, bearParams.expiry, bearParams.maxPremium, bearParams.minPremium, bearParams.duration
            );
        }
        if (address(BULL_DOV) != address(0)) {
            BULL_DOV.startEpochAuction(
                bullParams.strike, bullParams.expiry, bullParams.maxPremium, bullParams.minPremium, bullParams.duration
            );
        }

        emit CoordinatedZap(bearUsdc, bullUsdc, matched);
    }

    function _flashZapBull(
        uint256 usdcAmount,
        uint256 minSwapOut
    ) internal {
        uint256 priceBear = CURVE_POOL.get_dy(PLDXY_BEAR_INDEX, USDC_INDEX, DecimalConstants.ONE_WAD);
        if (priceBear >= CAP_PRICE) {
            revert DOVZapRouter__BearPriceAboveCap();
        }

        uint256 priceBull = CAP_PRICE - priceBear;
        uint256 theoreticalFlash = (usdcAmount * DecimalConstants.ONE_WAD) / priceBull;
        uint256 flashAmount = (theoreticalFlash * (10_000 - SAFETY_BUFFER_BPS)) / 10_000;

        bytes memory data = abi.encode(minSwapOut);
        IERC3156FlashLender(address(PLDXY_BEAR)).flashLoan(this, address(PLDXY_BEAR), flashAmount, data);
    }

    function onFlashLoan(
        address initiator,
        address,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        _validateFlashLoan(msg.sender, address(PLDXY_BEAR), initiator);

        uint256 minSwapOut = abi.decode(data, (uint256));

        CURVE_POOL.exchange(PLDXY_BEAR_INDEX, USDC_INDEX, amount, minSwapOut);

        uint256 totalUsdc = USDC.balanceOf(address(this));
        uint256 mintAmount = (totalUsdc * DecimalConstants.USDC_TO_TOKEN_SCALE) / CAP;
        SPLITTER.mint(mintAmount);

        uint256 repayAmount = amount + fee;
        if (PLDXY_BEAR.balanceOf(address(this)) < repayAmount) {
            revert DOVZapRouter__SolvencyBreach();
        }

        uint256 bullBalance = PLDXY_BULL.balanceOf(address(this));
        if (address(BULL_DOV) != address(0)) {
            STAKED_BULL.deposit(bullBalance, address(BULL_DOV));
        }

        uint256 bearSurplus = PLDXY_BEAR.balanceOf(address(this)) - repayAmount;
        if (bearSurplus > 0 && address(BEAR_DOV) != address(0)) {
            STAKED_BEAR.deposit(bearSurplus, address(BEAR_DOV));
        }

        return CALLBACK_SUCCESS;
    }

    function onMorphoFlashLoan(
        uint256,
        bytes calldata
    ) external pure override {
        revert FlashLoan__InvalidOperation();
    }

}
