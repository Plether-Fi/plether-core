// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

contract PerpGhostLedger {

    struct LiquidationSnapshot {
        bool liquidated;
        uint256 generation;
        uint256 legacyDebtDiagnosticUsdc;
    }

    address public immutable handler;

    struct WalletFlows {
        uint256 mintedUsdc;
        uint256 depositedUsdc;
        uint256 withdrawnUsdc;
    }

    mapping(address => LiquidationSnapshot) internal liquidationSnapshots;
    mapping(address => uint256) public accountGeneration;
    mapping(address => uint256) public liquidationDebtDiagnosticTotal;
    mapping(address => WalletFlows) internal walletFlows;
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
        uint256 legacyDebtDiagnosticUsdc
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }

        liquidationSnapshots[account] = LiquidationSnapshot({
            liquidated: true, generation: accountGeneration[account], legacyDebtDiagnosticUsdc: legacyDebtDiagnosticUsdc
        });
        liquidationDebtDiagnosticTotal[account] += legacyDebtDiagnosticUsdc;
        accountGeneration[account]++;
    }

    /// @dev Transfer reconciliation only: requested flows never synchronize from observed balances.
    ///      Economic entitlement is checked separately by the fixed-input liquidation lifecycle scenarios.
    function recordMintAndDeposit(
        address account,
        uint256 amountUsdc
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }
        walletFlows[account].mintedUsdc += amountUsdc;
        walletFlows[account].depositedUsdc += amountUsdc;
    }

    function recordWithdrawal(
        address account,
        uint256 amountUsdc
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }
        walletFlows[account].withdrawnUsdc += amountUsdc;
    }

    function expectedWalletFromSubmittedFlows(
        address account
    ) external view returns (uint256) {
        WalletFlows memory flows = walletFlows[account];
        return flows.mintedUsdc + flows.withdrawnUsdc - flows.depositedUsdc;
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
