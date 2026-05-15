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
    mapping(address => uint256) internal deferredTraderCreditUsdc;
    mapping(address => uint256) internal deferredKeeperCreditUsdc;
    uint256 internal totalTrackedCommittedMarginUsdc;
    uint256 internal totalTrackedDeferredTraderCreditUsdc;
    uint256 internal totalTrackedDeferredKeeperCreditUsdc;

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

    function increaseDeferredTraderCredit(
        address account,
        uint256 amountUsdc
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }

        deferredTraderCreditUsdc[account] += amountUsdc;
        totalTrackedDeferredTraderCreditUsdc += amountUsdc;
    }

    function decreaseDeferredTraderCredit(
        address account,
        uint256 amountUsdc
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }

        deferredTraderCreditUsdc[account] -= amountUsdc;
        totalTrackedDeferredTraderCreditUsdc -= amountUsdc;
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

    function deferredKeeperCreditSnapshot(
        address clearer
    ) external view returns (uint256) {
        return deferredKeeperCreditUsdc[clearer];
    }

    function deferredTraderCreditSnapshot(
        address account
    ) external view returns (uint256) {
        return deferredTraderCreditUsdc[account];
    }

    function totalCommittedMarginSnapshot() external view returns (uint256) {
        return totalTrackedCommittedMarginUsdc;
    }

    function totalDeferredTraderCreditSnapshot() external view returns (uint256) {
        return totalTrackedDeferredTraderCreditUsdc;
    }

    function totalDeferredKeeperCreditSnapshot() external view returns (uint256) {
        return totalTrackedDeferredKeeperCreditUsdc;
    }

}
