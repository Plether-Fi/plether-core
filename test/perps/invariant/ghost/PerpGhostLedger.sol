// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

contract PerpGhostLedger {

    struct LiquidationSnapshot {
        bool liquidated;
        uint256 walletUsdc;
        uint256 badDebtUsdc;
    }

    address public immutable handler;

    mapping(address => LiquidationSnapshot) internal liquidationSnapshots;
    mapping(address => uint256) internal committedMarginUsdc;
    mapping(address => uint256) internal traderClaimBalanceUsdc;
    mapping(address => uint256) internal keeperClaimBalanceUsdc;
    uint256 internal totalTrackedCommittedMarginUsdc;
    uint256 internal totalTrackedTraderClaimUsdc;
    uint256 internal totalTrackedKeeperClaimUsdc;

    error PerpGhostLedger__Unauthorized();

    constructor(
        address _handler
    ) {
        handler = _handler;
    }

    function recordLiquidation(
        address account,
        uint256 walletUsdc,
        uint256 badDebtUsdc
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }

        liquidationSnapshots[account] =
            LiquidationSnapshot({liquidated: true, walletUsdc: walletUsdc, badDebtUsdc: badDebtUsdc});
    }

    function increaseCommittedMargin(
        address account,
        uint256 amountUsdc
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }

        committedMarginUsdc[account] += amountUsdc;
        totalTrackedCommittedMarginUsdc += amountUsdc;
    }

    function decreaseCommittedMargin(
        address account,
        uint256 amountUsdc
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }

        committedMarginUsdc[account] -= amountUsdc;
        totalTrackedCommittedMarginUsdc -= amountUsdc;
    }

    function increaseKeeperClaim(
        address clearer,
        uint256 amountUsdc
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }

        keeperClaimBalanceUsdc[clearer] += amountUsdc;
        totalTrackedKeeperClaimUsdc += amountUsdc;
    }

    function decreaseKeeperClaim(
        address clearer,
        uint256 amountUsdc
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }

        keeperClaimBalanceUsdc[clearer] -= amountUsdc;
        totalTrackedKeeperClaimUsdc -= amountUsdc;
    }

    function increaseTraderClaim(
        address account,
        uint256 amountUsdc
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }

        traderClaimBalanceUsdc[account] += amountUsdc;
        totalTrackedTraderClaimUsdc += amountUsdc;
    }

    function decreaseTraderClaim(
        address account,
        uint256 amountUsdc
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }

        traderClaimBalanceUsdc[account] -= amountUsdc;
        totalTrackedTraderClaimUsdc -= amountUsdc;
    }

    function liquidationSnapshot(
        address account
    ) external view returns (LiquidationSnapshot memory) {
        return liquidationSnapshots[account];
    }

    function committedMarginSnapshot(
        address account
    ) external view returns (uint256) {
        return committedMarginUsdc[account];
    }

    function keeperClaimSnapshot(
        address clearer
    ) external view returns (uint256) {
        return keeperClaimBalanceUsdc[clearer];
    }

    function traderClaimSnapshot(
        address account
    ) external view returns (uint256) {
        return traderClaimBalanceUsdc[account];
    }

    function totalCommittedMarginSnapshot() external view returns (uint256) {
        return totalTrackedCommittedMarginUsdc;
    }

    function totalTraderClaimSnapshot() external view returns (uint256) {
        return totalTrackedTraderClaimUsdc;
    }

    function totalKeeperClaimSnapshot() external view returns (uint256) {
        return totalTrackedKeeperClaimUsdc;
    }

}
