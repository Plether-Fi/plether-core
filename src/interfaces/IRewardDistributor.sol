// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @title IRewardDistributor
/// @notice Interface for the RewardDistributor contract that allocates staking rewards
/// based on price discrepancy between oracle and Curve pool.
interface IRewardDistributor {

    /// @notice Emitted when rewards are distributed to staking vaults.
    /// @param bearAmount Amount of plDXY-BEAR donated to StakedBear.
    /// @param bullAmount Amount of plDXY-BULL donated to StakedBull.
    /// @param invarUsdcAmount Amount of USDC donated to InvarCoin.
    /// @param bearPct Percentage of rewards allocated to BEAR stakers (basis points).
    /// @param bullPct Percentage of rewards allocated to BULL stakers (basis points).
    event RewardsDistributed(
        uint256 bearAmount, uint256 bullAmount, uint256 invarUsdcAmount, uint256 bearPct, uint256 bullPct
    );

    /// @notice Thrown when distribution is attempted before cooldown expires.
    error RewardDistributor__DistributionTooSoon();

    /// @notice Thrown when there are no rewards to distribute.
    error RewardDistributor__NoRewards();

    /// @notice Thrown when the SyntheticSplitter is not in ACTIVE status.
    error RewardDistributor__SplitterNotActive();

    /// @notice Thrown when a constructor parameter is zero address.
    error RewardDistributor__ZeroAddress();

    /// @notice Thrown when ETH refund to caller fails.
    error RewardDistributor__RefundFailed();

    /// @notice Thrown when oracle returns zero or negative price.
    error RewardDistributor__InvalidPrice();

    /// @notice Permissionless function to distribute accumulated USDC rewards.
    /// @dev Calculates price discrepancy, acquires tokens, and donates to vaults.
    /// @return callerReward Amount of USDC sent to caller as incentive.
    function distributeRewards() external returns (uint256 callerReward);

    /// @notice Distributes rewards after updating the Pyth oracle price.
    /// @dev Bundles Pyth price update with reward distribution. Pass empty array if no update needed.
    /// @param pythUpdateData Price update data from Pyth Hermes API.
    /// @return callerReward Amount of USDC sent to caller as incentive.
    function distributeRewardsWithPriceUpdate(
        bytes[] calldata pythUpdateData
    ) external payable returns (uint256 callerReward);

    /// @notice Preview the distribution without executing.
    /// @return bearPct Expected percentage to BEAR stakers (basis points).
    /// @return bullPct Expected percentage to BULL stakers (basis points).
    /// @return usdcBalance Current USDC balance available for distribution.
    /// @return callerReward Expected caller reward.
    function previewDistribution()
        external
        view
        returns (uint256 bearPct, uint256 bullPct, uint256 usdcBalance, uint256 callerReward);

}
