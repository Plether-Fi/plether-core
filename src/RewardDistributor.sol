// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {StakedToken} from "./StakedToken.sol";
import {ZapRouter} from "./ZapRouter.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {ICurvePool} from "./interfaces/ICurvePool.sol";
import {IRewardDistributor} from "./interfaces/IRewardDistributor.sol";
import {ISyntheticSplitter} from "./interfaces/ISyntheticSplitter.sol";
import {DecimalConstants} from "./libraries/DecimalConstants.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
import {PythAdapter} from "./oracles/PythAdapter.sol";

/// @title RewardDistributor
/// @custom:security-contact contact@plether.com
/// @notice Distributes staking rewards based on price discrepancy between oracle and Curve EMA.
/// @dev Receives USDC from SyntheticSplitter.harvestYield() and allocates to StakedToken vaults
/// proportionally based on which token is underperforming relative to theoretical price.
contract RewardDistributor is IRewardDistributor, ReentrancyGuard {

    using SafeERC20 for IERC20;

    /// @notice Discrepancy threshold for 100% allocation (2% = 200 bps).
    uint256 public constant DISCREPANCY_THRESHOLD_BPS = 200;

    /// @notice Minimum time between distributions (1 hour).
    uint256 public constant MIN_DISTRIBUTION_INTERVAL = 1 hours;

    /// @notice Reward for calling distributeRewards (0.1% = 10 bps).
    uint256 public constant CALLER_REWARD_BPS = 10;

    /// @notice USDC index in Curve pool.
    uint256 public constant USDC_INDEX = 0;

    /// @notice plDXY-BEAR index in Curve pool.
    uint256 public constant PLDXY_BEAR_INDEX = 1;

    /// @notice Maximum slippage for Curve swaps (1% = 100 bps).
    uint256 public constant MAX_SWAP_SLIPPAGE_BPS = 100;

    /// @notice Maximum slippage for oracle-based zap estimates (3% = 300 bps).
    /// @dev Wider than MAX_SWAP_SLIPPAGE_BPS because ZapRouter's flash mint loop adds fees.
    uint256 public constant MAX_ORACLE_ZAP_SLIPPAGE_BPS = 300;

    /// @notice Maximum age for oracle price data (24 hours to match Chainlink CHF/CAD heartbeat).
    uint256 public constant ORACLE_TIMEOUT = 24 hours;

    /// @notice SyntheticSplitter contract.
    ISyntheticSplitter public immutable SPLITTER;

    /// @notice USDC stablecoin.
    IERC20 public immutable USDC;

    /// @notice plDXY-BEAR token.
    IERC20 public immutable PLDXY_BEAR;

    /// @notice plDXY-BULL token.
    IERC20 public immutable PLDXY_BULL;

    /// @notice Staked plDXY-BEAR vault.
    StakedToken public immutable STAKED_BEAR;

    /// @notice Staked plDXY-BULL vault.
    StakedToken public immutable STAKED_BULL;

    /// @notice Curve USDC/plDXY-BEAR pool.
    ICurvePool public immutable CURVE_POOL;

    /// @notice ZapRouter for acquiring plDXY-BULL.
    ZapRouter public immutable ZAP_ROUTER;

    /// @notice BasketOracle for theoretical price.
    AggregatorV3Interface public immutable ORACLE;

    /// @notice Optional PythAdapter for SEK/USD price updates (address(0) if not used).
    PythAdapter public immutable PYTH_ADAPTER;

    /// @notice Protocol CAP price (8 decimals).
    uint256 public immutable CAP;

    /// @notice Timestamp of last distribution.
    uint256 public lastDistributionTime;

    /// @notice Deploys RewardDistributor with all required dependencies.
    /// @param _splitter SyntheticSplitter contract address.
    /// @param _usdc USDC token address.
    /// @param _plDxyBear plDXY-BEAR token address.
    /// @param _plDxyBull plDXY-BULL token address.
    /// @param _stakedBear StakedToken vault for BEAR.
    /// @param _stakedBull StakedToken vault for BULL.
    /// @param _curvePool Curve USDC/plDXY-BEAR pool.
    /// @param _zapRouter ZapRouter for BULL acquisition.
    /// @param _oracle BasketOracle for price data.
    /// @param _pythAdapter Optional PythAdapter for SEK/USD updates (address(0) if not used).
    constructor(
        address _splitter,
        address _usdc,
        address _plDxyBear,
        address _plDxyBull,
        address _stakedBear,
        address _stakedBull,
        address _curvePool,
        address _zapRouter,
        address _oracle,
        address _pythAdapter
    ) {
        if (_splitter == address(0)) {
            revert RewardDistributor__ZeroAddress();
        }
        if (_usdc == address(0)) {
            revert RewardDistributor__ZeroAddress();
        }
        if (_plDxyBear == address(0)) {
            revert RewardDistributor__ZeroAddress();
        }
        if (_plDxyBull == address(0)) {
            revert RewardDistributor__ZeroAddress();
        }
        if (_stakedBear == address(0)) {
            revert RewardDistributor__ZeroAddress();
        }
        if (_stakedBull == address(0)) {
            revert RewardDistributor__ZeroAddress();
        }
        if (_curvePool == address(0)) {
            revert RewardDistributor__ZeroAddress();
        }
        if (_zapRouter == address(0)) {
            revert RewardDistributor__ZeroAddress();
        }
        if (_oracle == address(0)) {
            revert RewardDistributor__ZeroAddress();
        }

        SPLITTER = ISyntheticSplitter(_splitter);
        USDC = IERC20(_usdc);
        PLDXY_BEAR = IERC20(_plDxyBear);
        PLDXY_BULL = IERC20(_plDxyBull);
        STAKED_BEAR = StakedToken(_stakedBear);
        STAKED_BULL = StakedToken(_stakedBull);
        CURVE_POOL = ICurvePool(_curvePool);
        ZAP_ROUTER = ZapRouter(_zapRouter);
        ORACLE = AggregatorV3Interface(_oracle);
        PYTH_ADAPTER = PythAdapter(_pythAdapter);

        CAP = ISyntheticSplitter(_splitter).CAP();

        USDC.safeIncreaseAllowance(_splitter, type(uint256).max);
        USDC.safeIncreaseAllowance(_curvePool, type(uint256).max);
        USDC.safeIncreaseAllowance(_zapRouter, type(uint256).max);
        IERC20(_plDxyBear).safeIncreaseAllowance(_stakedBear, type(uint256).max);
        IERC20(_plDxyBull).safeIncreaseAllowance(_stakedBull, type(uint256).max);
    }

    receive() external payable {}

    /// @inheritdoc IRewardDistributor
    function distributeRewards() external nonReentrant returns (uint256 callerReward) {
        return _distributeRewardsInternal();
    }

    /// @dev Internal implementation of reward distribution.
    function _distributeRewardsInternal() internal returns (uint256 callerReward) {
        if (block.timestamp < lastDistributionTime + MIN_DISTRIBUTION_INTERVAL) {
            revert RewardDistributor__DistributionTooSoon();
        }
        if (SPLITTER.currentStatus() != ISyntheticSplitter.Status.ACTIVE) {
            revert RewardDistributor__SplitterNotActive();
        }

        uint256 usdcBalance = USDC.balanceOf(address(this));
        if (usdcBalance == 0) {
            revert RewardDistributor__NoRewards();
        }

        callerReward = (usdcBalance * CALLER_REWARD_BPS) / 10_000;
        uint256 distributableUsdc = usdcBalance - callerReward;

        (uint256 bearPct, uint256 bullPct) = _calculateSplit();
        (uint256 bearAmount, uint256 bullAmount) = _acquireTokens(distributableUsdc, bearPct, bullPct);

        if (bearAmount > 0) {
            STAKED_BEAR.donateYield(bearAmount);
        }
        if (bullAmount > 0) {
            STAKED_BULL.donateYield(bullAmount);
        }

        lastDistributionTime = block.timestamp;
        USDC.safeTransfer(msg.sender, callerReward);

        emit RewardsDistributed(bearAmount, bullAmount, bearPct, bullPct);
    }

    /// @notice Distributes rewards after updating the Pyth oracle price.
    /// @dev Bundles Pyth price update with reward distribution to save gas.
    ///      Caller receives the same reward as distributeRewards().
    /// @param pythUpdateData Price update data from Pyth Hermes API.
    /// @return callerReward Amount of USDC sent to caller as incentive.
    function distributeRewardsWithPriceUpdate(
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant returns (uint256 callerReward) {
        uint256 preBalance = address(this).balance - msg.value;
        if (address(PYTH_ADAPTER) != address(0) && pythUpdateData.length > 0) {
            PYTH_ADAPTER.updatePrice{value: msg.value}(pythUpdateData);
        }
        uint256 refund = address(this).balance - preBalance;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) {
                revert RewardDistributor__RefundFailed();
            }
        }
        return _distributeRewardsInternal();
    }

    /// @inheritdoc IRewardDistributor
    function previewDistribution()
        external
        view
        returns (uint256 bearPct, uint256 bullPct, uint256 usdcBalance, uint256 callerReward)
    {
        usdcBalance = USDC.balanceOf(address(this));
        callerReward = (usdcBalance * CALLER_REWARD_BPS) / 10_000;
        (bearPct, bullPct) = _calculateSplit();
    }

    /// @dev Calculates reward split based on price discrepancy.
    /// @return bearPct Percentage for BEAR stakers (basis points).
    /// @return bullPct Percentage for BULL stakers (basis points).
    function _calculateSplit() internal view returns (uint256 bearPct, uint256 bullPct) {
        (, int256 basketPrice,, uint256 updatedAt,) = ORACLE.latestRoundData();
        OracleLib.checkStaleness(updatedAt, ORACLE_TIMEOUT);
        uint256 theoreticalBear18 = uint256(basketPrice) * DecimalConstants.CHAINLINK_TO_TOKEN_SCALE;

        uint256 spotBear18 = CURVE_POOL.price_oracle();

        uint256 diff = theoreticalBear18 > spotBear18 ? theoreticalBear18 - spotBear18 : spotBear18 - theoreticalBear18;
        uint256 basePrice = theoreticalBear18 > spotBear18 ? theoreticalBear18 : spotBear18;
        uint256 discrepancyBps = (diff * 10_000) / basePrice;

        bool bearUnderperforming = spotBear18 < theoreticalBear18;

        uint256 underperformerPct;
        if (discrepancyBps >= DISCREPANCY_THRESHOLD_BPS) {
            underperformerPct = 10_000;
        } else {
            // Quadratic interpolation: gentler for small discrepancies, aggressive for larger ones
            // Formula: 50% + (discrepancy/threshold)² × 50%
            uint256 ratio = (discrepancyBps * 10_000) / DISCREPANCY_THRESHOLD_BPS;
            underperformerPct = 5000 + (ratio * ratio * 5000) / (10_000 * 10_000);
        }

        if (bearUnderperforming) {
            bearPct = underperformerPct;
            bullPct = 10_000 - underperformerPct;
        } else {
            bullPct = underperformerPct;
            bearPct = 10_000 - underperformerPct;
        }
    }

    /// @dev Acquires tokens using optimal combination of minting and swapping/zapping.
    /// @param totalUsdc Total USDC to convert to tokens.
    /// @param bearPct Target BEAR percentage (basis points).
    /// @param bullPct Target BULL percentage (basis points).
    /// @return bearAmount Amount of plDXY-BEAR acquired.
    /// @return bullAmount Amount of plDXY-BULL acquired.
    function _acquireTokens(
        uint256 totalUsdc,
        uint256 bearPct,
        uint256 bullPct
    ) internal returns (uint256 bearAmount, uint256 bullAmount) {
        (, int256 basketPrice,,,) = ORACLE.latestRoundData();
        uint256 absBasketPrice = uint256(basketPrice);

        if (bearPct >= bullPct) {
            uint256 mintUsdc = (totalUsdc * bullPct * 2) / 10_000;
            uint256 swapUsdc = totalUsdc - mintUsdc;

            if (mintUsdc > 0) {
                uint256 mintAmount = _calculateMintAmount(mintUsdc);
                SPLITTER.mint(mintAmount);
            }

            if (swapUsdc > 0) {
                uint256 oracleExpectedBear = (swapUsdc * 1e20) / absBasketPrice;
                uint256 minOut = (oracleExpectedBear * (10_000 - MAX_SWAP_SLIPPAGE_BPS)) / 10_000;
                CURVE_POOL.exchange(USDC_INDEX, PLDXY_BEAR_INDEX, swapUsdc, minOut);
            }

            bearAmount = PLDXY_BEAR.balanceOf(address(this));
            bullAmount = PLDXY_BULL.balanceOf(address(this));
        } else {
            uint256 mintUsdc = (totalUsdc * bearPct * 2) / 10_000;
            uint256 zapUsdc = totalUsdc - mintUsdc;

            if (mintUsdc > 0) {
                uint256 mintAmount = _calculateMintAmount(mintUsdc);
                SPLITTER.mint(mintAmount);
            }

            if (zapUsdc > 0) {
                uint256 bullPrice = CAP - absBasketPrice;
                uint256 oracleExpectedBull = (zapUsdc * 1e20) / bullPrice;
                uint256 minBull = (oracleExpectedBull * (10_000 - MAX_ORACLE_ZAP_SLIPPAGE_BPS)) / 10_000;
                ZAP_ROUTER.zapMint(zapUsdc, minBull, MAX_SWAP_SLIPPAGE_BPS, block.timestamp);
            }

            bearAmount = PLDXY_BEAR.balanceOf(address(this));
            bullAmount = PLDXY_BULL.balanceOf(address(this));
        }
    }

    /// @dev Converts USDC amount to 18-decimal mint amount.
    /// @param usdcAmount USDC amount (6 decimals).
    /// @return mintAmount Token amount to mint (18 decimals).
    function _calculateMintAmount(
        uint256 usdcAmount
    ) internal view returns (uint256 mintAmount) {
        mintAmount = (usdcAmount * DecimalConstants.USDC_TO_TOKEN_SCALE) / CAP;
    }

}
