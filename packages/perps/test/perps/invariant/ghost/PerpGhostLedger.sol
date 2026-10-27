// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

contract PerpGhostLedger {

    struct LiquidationSnapshot {
        bool liquidated;
        uint256 generation;
    }

    address public immutable handler;

    struct WalletFlows {
        uint256 mintedAssets;
        uint256 depositedAssets;
        uint256 withdrawnAssets;
    }

    mapping(address => LiquidationSnapshot) internal liquidationSnapshots;
    mapping(address => uint256) public accountGeneration;
    mapping(address => WalletFlows) internal walletFlows;
    mapping(address => uint256) internal committedMarginAssets;
    uint256 internal totalTrackedCommittedMarginAssets;

    error PerpGhostLedger__Unauthorized();

    constructor(
        address _handler
    ) {
        handler = _handler;
    }

    function recordLiquidation(
        address account
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }

        liquidationSnapshots[account] = LiquidationSnapshot({liquidated: true, generation: accountGeneration[account]});
        accountGeneration[account]++;
    }

    /// @dev Transfer reconciliation only: requested flows never synchronize from observed balances.
    ///      Economic entitlement is checked separately by the fixed-input liquidation lifecycle scenarios.
    function recordMintAndDeposit(
        address account,
        uint256 amountAssets
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }
        walletFlows[account].mintedAssets += amountAssets;
        walletFlows[account].depositedAssets += amountAssets;
    }

    function recordWithdrawal(
        address account,
        uint256 amountAssets
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }
        walletFlows[account].withdrawnAssets += amountAssets;
    }

    function expectedWalletFromSubmittedFlows(
        address account
    ) external view returns (uint256) {
        WalletFlows memory flows = walletFlows[account];
        return flows.mintedAssets + flows.withdrawnAssets - flows.depositedAssets;
    }

    function increaseCommittedMargin(
        address account,
        uint256 amountAssets
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }

        committedMarginAssets[account] += amountAssets;
        totalTrackedCommittedMarginAssets += amountAssets;
    }

    function decreaseCommittedMargin(
        address account,
        uint256 amountAssets
    ) external {
        if (msg.sender != handler) {
            revert PerpGhostLedger__Unauthorized();
        }

        committedMarginAssets[account] -= amountAssets;
        totalTrackedCommittedMarginAssets -= amountAssets;
    }

    function liquidationSnapshot(
        address account
    ) external view returns (LiquidationSnapshot memory) {
        return liquidationSnapshots[account];
    }

    function committedMarginSnapshot(
        address account
    ) external view returns (uint256) {
        return committedMarginAssets[account];
    }

    function totalCommittedMarginSnapshot() external view returns (uint256) {
        return totalTrackedCommittedMarginAssets;
    }

}
