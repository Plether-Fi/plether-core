// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

contract PerpGhostLedger {

    struct LiquidationSnapshot {
        bool liquidated;
        uint256 walletUsdc;
        uint256 legacyDebtDiagnosticUsdc;
    }

    address public immutable handler;

    mapping(address => LiquidationSnapshot) internal liquidationSnapshots;
    mapping(address => uint256) internal committedMarginUsdc;
    uint256 internal totalTrackedCommittedMarginUsdc;

    error PerpGhostLedger__Unauthorized();

    constructor(
        address _handler
    ) {
        handler = _handler;
    }

    function recordLiquidation(
        address account,
        uint256 walletUsdc,
        uint256 legacyDebtDiagnosticUsdc
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }

        liquidationSnapshots[account] = LiquidationSnapshot({
            liquidated: true, walletUsdc: walletUsdc, legacyDebtDiagnosticUsdc: legacyDebtDiagnosticUsdc
        });
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

    function totalCommittedMarginSnapshot() external view returns (uint256) {
        return totalTrackedCommittedMarginUsdc;
    }

}
