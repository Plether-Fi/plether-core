// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

contract PerpGhostLedger {

    struct LiquidationSnapshot {
        bool liquidated;
        uint256 walletUsdc;
        uint256 badDebtUsdc;
    }

    address public immutable handler;

    mapping(bytes32 => LiquidationSnapshot) internal liquidationSnapshots;
    mapping(bytes32 => uint256) internal committedMarginUsdc;
    mapping(bytes32 => uint256) internal deferredTraderPayoutUsdc;
    mapping(address => uint256) internal deferredKeeperCreditUsdc;
    uint256 internal totalTrackedCommittedMarginUsdc;
    uint256 internal totalTrackedDeferredTraderPayoutUsdc;
    uint256 internal totalTrackedDeferredKeeperCreditUsdc;

    error PerpGhostLedger__Unauthorized();

    constructor(
        address _handler
    ) {
        handler = _handler;
    }

    function recordLiquidation(
        bytes32 accountId,
        uint256 walletUsdc,
        uint256 badDebtUsdc
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }

        liquidationSnapshots[accountId] =
            LiquidationSnapshot({liquidated: true, walletUsdc: walletUsdc, badDebtUsdc: badDebtUsdc});
    }

    function increaseCommittedMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }

        committedMarginUsdc[accountId] += amountUsdc;
        totalTrackedCommittedMarginUsdc += amountUsdc;
    }

    function decreaseCommittedMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }

        committedMarginUsdc[accountId] -= amountUsdc;
        totalTrackedCommittedMarginUsdc -= amountUsdc;
    }

    function increaseDeferredKeeperCredit(
        address clearer,
        uint256 amountUsdc
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }

        deferredKeeperCreditUsdc[clearer] += amountUsdc;
        totalTrackedDeferredKeeperCreditUsdc += amountUsdc;
    }

    function decreaseDeferredKeeperCredit(
        address clearer,
        uint256 amountUsdc
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }

        deferredKeeperCreditUsdc[clearer] -= amountUsdc;
        totalTrackedDeferredKeeperCreditUsdc -= amountUsdc;
    }

    function increaseDeferredTraderPayout(
        bytes32 accountId,
        uint256 amountUsdc
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }

        deferredTraderPayoutUsdc[accountId] += amountUsdc;
        totalTrackedDeferredTraderPayoutUsdc += amountUsdc;
    }

    function decreaseDeferredTraderPayout(
        bytes32 accountId,
        uint256 amountUsdc
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }

        deferredTraderPayoutUsdc[accountId] -= amountUsdc;
        totalTrackedDeferredTraderPayoutUsdc -= amountUsdc;
    }

    function liquidationSnapshot(
        bytes32 accountId
    ) external view returns (LiquidationSnapshot memory) {
        return liquidationSnapshots[accountId];
    }

    function committedMarginSnapshot(
        bytes32 accountId
    ) external view returns (uint256) {
        return committedMarginUsdc[accountId];
    }

    function deferredKeeperCreditSnapshot(
        address clearer
    ) external view returns (uint256) {
        return deferredKeeperCreditUsdc[clearer];
    }

    function deferredTraderPayoutSnapshot(
        bytes32 accountId
    ) external view returns (uint256) {
        return deferredTraderPayoutUsdc[accountId];
    }

    function totalCommittedMarginSnapshot() external view returns (uint256) {
        return totalTrackedCommittedMarginUsdc;
    }

    function totalDeferredTraderPayoutSnapshot() external view returns (uint256) {
        return totalTrackedDeferredTraderPayoutUsdc;
    }

    function totalDeferredKeeperCreditSnapshot() external view returns (uint256) {
        return totalTrackedDeferredKeeperCreditUsdc;
    }

}
