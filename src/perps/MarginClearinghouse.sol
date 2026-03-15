// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IMarginClearinghouse} from "./interfaces/IMarginClearinghouse.sol";
import {IWithdrawGuard} from "./interfaces/IWithdrawGuard.sol";
import {MarginClearinghouseAccountingLib} from "./libraries/MarginClearinghouseAccountingLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MarginClearinghouse
/// @notice USDC-only cross-margin account manager for Plether.
/// @dev Holds settlement balances and locked margin for CFD accounts.
/// @custom:security-contact contact@plether.com
contract MarginClearinghouse is Ownable2Step {

    using SafeERC20 for IERC20;

    mapping(bytes32 => uint256) internal settlementBalances;

    mapping(bytes32 => uint256) public lockedMarginUsdc;
    IWithdrawGuard public withdrawGuard;

    mapping(address => bool) public isProtocolOperator;

    address public immutable settlementAsset;

    uint256 public constant TIMELOCK_DELAY = 48 hours;

    address public pendingOperatorAddress;
    bool public pendingOperatorStatus;
    uint256 public operatorActivationTime;

    address public pendingWithdrawGuard;
    uint256 public withdrawGuardActivationTime;

    error MarginClearinghouse__NotOperator();
    error MarginClearinghouse__NotAccountOwner();
    error MarginClearinghouse__ZeroAmount();
    error MarginClearinghouse__InsufficientBalance();
    error MarginClearinghouse__InsufficientFreeEquity();
    error MarginClearinghouse__InsufficientUsdcForSettlement();
    error MarginClearinghouse__InsufficientAssetToSeize();
    error MarginClearinghouse__InvalidSeizeRecipient();
    error MarginClearinghouse__TimelockNotReady();
    error MarginClearinghouse__NoProposal();

    event Deposit(bytes32 indexed accountId, address indexed asset, uint256 amount);
    event Withdraw(bytes32 indexed accountId, address indexed asset, uint256 amount);
    event MarginLocked(bytes32 indexed accountId, uint256 amountUsdc);
    event MarginUnlocked(bytes32 indexed accountId, uint256 amountUsdc);
    event AssetSeized(bytes32 indexed accountId, address indexed asset, uint256 amount, address recipient);

    modifier onlyOperator() {
        if (!isProtocolOperator[msg.sender]) {
            revert MarginClearinghouse__NotOperator();
        }
        _;
    }

    /// @param _settlementAsset USDC address used for PnL settlement and margin backing
    constructor(
        address _settlementAsset
    ) Ownable(msg.sender) {
        settlementAsset = _settlementAsset;
    }

    // ==========================================
    // CONFIGURATION
    // ==========================================

    /// @notice Proposes granting or revoking operator privileges (48h timelock)
    function proposeOperator(
        address operator,
        bool status
    ) external onlyOwner {
        pendingOperatorAddress = operator;
        pendingOperatorStatus = status;
        operatorActivationTime = block.timestamp + TIMELOCK_DELAY;
    }

    /// @notice Finalizes the pending operator proposal after timelock expires
    function finalizeOperator() external onlyOwner {
        if (operatorActivationTime == 0) {
            revert MarginClearinghouse__NoProposal();
        }
        if (block.timestamp < operatorActivationTime) {
            revert MarginClearinghouse__TimelockNotReady();
        }
        isProtocolOperator[pendingOperatorAddress] = pendingOperatorStatus;
        pendingOperatorAddress = address(0);
        pendingOperatorStatus = false;
        operatorActivationTime = 0;
    }

    /// @notice Cancels the pending operator proposal
    function cancelOperatorProposal() external onlyOwner {
        pendingOperatorAddress = address(0);
        pendingOperatorStatus = false;
        operatorActivationTime = 0;
    }

    /// @notice Proposes a new withdraw guard contract (48h timelock)
    function proposeWithdrawGuard(
        address _guard
    ) external onlyOwner {
        pendingWithdrawGuard = _guard;
        withdrawGuardActivationTime = block.timestamp + TIMELOCK_DELAY;
    }

    /// @notice Finalizes the pending withdraw guard proposal after timelock expires
    function finalizeWithdrawGuard() external onlyOwner {
        if (withdrawGuardActivationTime == 0) {
            revert MarginClearinghouse__NoProposal();
        }
        if (block.timestamp < withdrawGuardActivationTime) {
            revert MarginClearinghouse__TimelockNotReady();
        }
        withdrawGuard = IWithdrawGuard(pendingWithdrawGuard);
        pendingWithdrawGuard = address(0);
        withdrawGuardActivationTime = 0;
    }

    /// @notice Cancels the pending withdraw guard proposal
    function cancelWithdrawGuardProposal() external onlyOwner {
        pendingWithdrawGuard = address(0);
        withdrawGuardActivationTime = 0;
    }

    // ==========================================
    // USER ACTIONS
    // ==========================================

    /// @notice Deposits settlement USDC into the specified margin account.
    /// @param accountId Deterministic account ID derived from msg.sender address
    /// @param amount Token amount to transfer in
    function deposit(
        bytes32 accountId,
        uint256 amount
    ) external {
        if (bytes32(uint256(uint160(msg.sender))) != accountId) {
            revert MarginClearinghouse__NotAccountOwner();
        }
        if (amount == 0) {
            revert MarginClearinghouse__ZeroAmount();
        }

        settlementBalances[accountId] += amount;
        IERC20(settlementAsset).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(accountId, settlementAsset, amount);
    }

    /// @notice Withdraws settlement USDC from a margin account.
    /// @param accountId Deterministic account ID derived from msg.sender address
    /// @param amount USDC amount to withdraw
    function withdraw(
        bytes32 accountId,
        uint256 amount
    ) external {
        if (bytes32(uint256(uint160(msg.sender))) != accountId) {
            revert MarginClearinghouse__NotAccountOwner();
        }
        if (settlementBalances[accountId] < amount) {
            revert MarginClearinghouse__InsufficientBalance();
        }

        settlementBalances[accountId] -= amount;

        if (address(withdrawGuard) != address(0)) {
            withdrawGuard.checkWithdraw(accountId);
        }

        uint256 remainingEquity = getAccountEquityUsdc(accountId);
        if (remainingEquity < lockedMarginUsdc[accountId]) {
            revert MarginClearinghouse__InsufficientFreeEquity();
        }
        if (settlementBalances[accountId] < lockedMarginUsdc[accountId]) {
            revert MarginClearinghouse__InsufficientUsdcForSettlement();
        }

        IERC20(settlementAsset).safeTransfer(msg.sender, amount);
        emit Withdraw(accountId, settlementAsset, amount);
    }

    // ==========================================
    // VALUATION ENGINE
    // ==========================================

    /// @notice Returns the total USD buying power of the account (6 decimals).
    /// @param accountId Account to value
    /// @return totalEquityUsdc Settlement balance in USDC (6 decimals)
    function getAccountEquityUsdc(
        bytes32 accountId
    ) public view returns (uint256 totalEquityUsdc) {
        return settlementBalances[accountId];
    }

    /// @notice Returns strictly unencumbered purchasing power
    /// @param accountId Account to query
    /// @return Equity minus locked margin, floored at zero (6 decimals)
    function getFreeBuyingPowerUsdc(
        bytes32 accountId
    ) public view returns (uint256) {
        uint256 equity = getAccountEquityUsdc(accountId);
        uint256 encumbered = lockedMarginUsdc[accountId];
        return equity > encumbered ? equity - encumbered : 0;
    }

    /// @notice Returns free settlement balance after subtracting locked margin.
    /// @dev This is the physically reachable USDC left after backing active positions.
    ///      It differs from `getFreeBuyingPowerUsdc` by ignoring non-USDC collateral value.
    function getAccountUsdcBuckets(
        bytes32 accountId,
        uint256 activePositionMarginUsdc
    ) public view returns (IMarginClearinghouse.AccountUsdcBuckets memory buckets) {
        buckets = _buildAccountUsdcBuckets(accountId, activePositionMarginUsdc);
    }

    function getFreeSettlementBalanceUsdc(
        bytes32 accountId
    ) public view returns (uint256) {
        return getAccountUsdcBuckets(accountId, 0).freeSettlementUsdc;
    }

    /// @notice Returns settlement balance reachable by a liquidation or other terminal settlement path.
    function getLiquidationReachableUsdc(
        bytes32 accountId,
        uint256 positionMarginUsdc
    ) public view returns (uint256) {
        return MarginClearinghouseAccountingLib.getLiquidationReachableUsdc(
            _buildAccountUsdcBuckets(accountId, positionMarginUsdc)
        );
    }

    /// @notice Returns settlement balance reachable after protecting only an explicitly remaining margin bucket.
    /// @dev This is the canonical helper for terminal settlement paths: full closes and liquidations
    ///      should pass zero protected margin, while partial closes should protect only the residual
    ///      position margin that remains open after settlement.
    function getSettlementReachableUsdc(
        bytes32 accountId,
        uint256 protectedLockedMarginUsdc
    ) public view returns (uint256) {
        return MarginClearinghouseAccountingLib.getSettlementReachableUsdc(
            _buildAccountUsdcBuckets(accountId, 0), protectedLockedMarginUsdc
        );
    }

    // ==========================================
    // PROTOCOL INTEGRATION (OrderRouter / Engine)
    // ==========================================

    /// @notice Locks margin to back a new CFD trade.
    ///         Requires sufficient USDC to back settlement (non-USDC equity alone is insufficient).
    /// @param accountId Account to lock margin on
    /// @param amountUsdc USDC amount to lock (6 decimals)
    function lockMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external onlyOperator {
        _lockMargin(accountId, amountUsdc);
    }

    /// @notice Unlocks margin when a CFD trade closes
    /// @param accountId Account to unlock margin on
    /// @param amountUsdc USDC amount to unlock (6 decimals), clamped to current locked amount
    function unlockMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external onlyOperator {
        _unlockMargin(accountId, amountUsdc);
    }

    /// @notice Adjusts USDC balance to settle funding, PnL, and VPI rebates.
    ///         Positive amounts credit the account; negative amounts debit it.
    /// @param accountId Account to settle
    /// @param amount Signed USDC delta: positive credits, negative debits (6 decimals)
    function settleUsdc(
        bytes32 accountId,
        int256 amount
    ) external onlyOperator {
        if (amount > 0) {
            _creditSettlementUsdc(accountId, uint256(amount));
        } else if (amount < 0) {
            _debitSettlementUsdc(accountId, uint256(-amount));
        }
    }

    /// @notice Credits settlement USDC and locks the same amount as active margin.
    function creditSettlementAndLockMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external onlyOperator {
        if (amountUsdc == 0) {
            return;
        }

        _creditSettlementUsdc(accountId, amountUsdc);
        _lockMargin(accountId, amountUsdc);
    }

    /// @notice Applies an open/increase trade cost by debiting or crediting settlement and updating locked margin.
    function applyOpenCost(
        bytes32 accountId,
        uint256 marginDeltaUsdc,
        int256 tradeCostUsdc,
        address recipient
    ) external onlyOperator returns (int256 netMarginChangeUsdc) {
        if (tradeCostUsdc > 0) {
            uint256 costUsdc = uint256(tradeCostUsdc);
            if (costUsdc > getFreeSettlementBalanceUsdc(accountId)) {
                revert MarginClearinghouse__InsufficientFreeEquity();
            }
            settlementBalances[accountId] -= costUsdc;
            IERC20(settlementAsset).safeTransfer(recipient, costUsdc);
            emit AssetSeized(accountId, settlementAsset, costUsdc, recipient);
        } else if (tradeCostUsdc < 0) {
            _creditSettlementUsdc(accountId, uint256(-tradeCostUsdc));
        }

        netMarginChangeUsdc = int256(marginDeltaUsdc) - tradeCostUsdc;
        if (netMarginChangeUsdc > 0) {
            _lockMargin(accountId, uint256(netMarginChangeUsdc));
        } else if (netMarginChangeUsdc < 0) {
            _unlockMargin(accountId, uint256(-netMarginChangeUsdc));
        }
    }

    /// @notice Consumes a funding loss from free settlement first, then from the active position margin bucket.
    /// @dev Unrelated locked margin remains protected.
    function consumeFundingLoss(
        bytes32 accountId,
        uint256 lockedPositionMarginUsdc,
        uint256 lossUsdc,
        address recipient
    )
        external
        onlyOperator
        returns (uint256 marginConsumedUsdc, uint256 freeSettlementConsumedUsdc, uint256 uncoveredUsdc)
    {
        if (lossUsdc == 0) {
            return (0, 0, 0);
        }

        MarginClearinghouseAccountingLib.SettlementConsumption memory consumption =
            _planFundingLossConsumption(accountId, lockedPositionMarginUsdc, lossUsdc);
        freeSettlementConsumedUsdc = consumption.freeSettlementConsumedUsdc;
        marginConsumedUsdc = consumption.activeMarginConsumedUsdc;
        uncoveredUsdc = consumption.uncoveredUsdc;
        IMarginClearinghouse.AccountUsdcBuckets memory buckets =
            _buildAccountUsdcBuckets(accountId, lockedPositionMarginUsdc);
        MarginClearinghouseAccountingLib.BucketMutation memory mutation =
            MarginClearinghouseAccountingLib.applyFundingLossMutation(buckets, consumption);

        if (mutation.activeMarginUnlockedUsdc > 0) {
            lockedMarginUsdc[accountId] = mutation.resultingLockedMarginUsdc;
            emit MarginUnlocked(accountId, mutation.activeMarginUnlockedUsdc);
        }

        uint256 totalConsumedUsdc = mutation.settlementDebitUsdc;
        if (totalConsumedUsdc == 0) {
            return (marginConsumedUsdc, freeSettlementConsumedUsdc, uncoveredUsdc);
        }

        settlementBalances[accountId] -= totalConsumedUsdc;
        IERC20(settlementAsset).safeTransfer(recipient, totalConsumedUsdc);
        emit AssetSeized(accountId, settlementAsset, totalConsumedUsdc, recipient);
    }

    /// @notice Consumes close-path losses from settlement buckets while preserving any explicitly protected remaining position margin.
    function consumeCloseLoss(
        bytes32 accountId,
        uint256 lossUsdc,
        uint256 protectedLockedMarginUsdc,
        address recipient
    ) external onlyOperator returns (uint256 seizedUsdc, uint256 shortfallUsdc) {
        if (lossUsdc == 0) {
            return (0, 0);
        }

        IMarginClearinghouse.AccountUsdcBuckets memory buckets =
            _buildAccountUsdcBuckets(accountId, protectedLockedMarginUsdc);
        MarginClearinghouseAccountingLib.SettlementConsumption memory consumption =
            MarginClearinghouseAccountingLib.planTerminalLossConsumption(buckets, protectedLockedMarginUsdc, lossUsdc);
        MarginClearinghouseAccountingLib.BucketMutation memory mutation =
            MarginClearinghouseAccountingLib.applyTerminalLossMutation(buckets, protectedLockedMarginUsdc, consumption);
        seizedUsdc = consumption.totalConsumedUsdc;
        shortfallUsdc = consumption.uncoveredUsdc;

        if (seizedUsdc == 0) {
            return (0, shortfallUsdc);
        }

        if (mutation.activeMarginUnlockedUsdc > 0 || mutation.otherLockedMarginUnlockedUsdc > 0) {
            lockedMarginUsdc[accountId] = mutation.resultingLockedMarginUsdc;
            if (mutation.activeMarginUnlockedUsdc > 0) {
                emit MarginUnlocked(accountId, mutation.activeMarginUnlockedUsdc);
            }
            if (mutation.otherLockedMarginUnlockedUsdc > 0) {
                emit MarginUnlocked(accountId, mutation.otherLockedMarginUnlockedUsdc);
            }
        }

        settlementBalances[accountId] -= mutation.settlementDebitUsdc;
        IERC20(settlementAsset).safeTransfer(recipient, mutation.settlementDebitUsdc);
        emit AssetSeized(accountId, settlementAsset, mutation.settlementDebitUsdc, recipient);
    }

    /// @notice Settles liquidation residual against liquidation-reachable collateral.
    /// @dev Releases the specified active position margin bucket but leaves unrelated committed margin untouched.
    function consumeLiquidationResidual(
        bytes32 accountId,
        uint256 lockedPositionMarginUsdc,
        int256 residualUsdc,
        address recipient
    ) external onlyOperator returns (uint256 seizedUsdc, uint256 payoutUsdc, uint256 badDebtUsdc) {
        IMarginClearinghouse.AccountUsdcBuckets memory buckets =
            _buildAccountUsdcBuckets(accountId, lockedPositionMarginUsdc);
        MarginClearinghouseAccountingLib.LiquidationResidualPlan memory plan =
            MarginClearinghouseAccountingLib.planLiquidationResidual(buckets, residualUsdc);
        seizedUsdc = plan.seizedUsdc;
        payoutUsdc = plan.payoutUsdc;
        badDebtUsdc = plan.badDebtUsdc;

        if (lockedPositionMarginUsdc > 0) {
            lockedMarginUsdc[accountId] = plan.mutation.resultingLockedMarginUsdc;
            emit MarginUnlocked(accountId, plan.mutation.activeMarginUnlockedUsdc);
            if (plan.mutation.otherLockedMarginUnlockedUsdc > 0) {
                emit MarginUnlocked(accountId, plan.mutation.otherLockedMarginUnlockedUsdc);
            }
        }

        if (seizedUsdc > 0) {
            settlementBalances[accountId] -= plan.mutation.settlementDebitUsdc;
            IERC20(settlementAsset).safeTransfer(recipient, plan.mutation.settlementDebitUsdc);
            emit AssetSeized(accountId, settlementAsset, plan.mutation.settlementDebitUsdc, recipient);
        }
    }

    function _buildAccountUsdcBuckets(
        bytes32 accountId,
        uint256 activePositionMarginUsdc
    ) internal view returns (IMarginClearinghouse.AccountUsdcBuckets memory buckets) {
        return MarginClearinghouseAccountingLib.buildAccountUsdcBuckets(
            settlementBalances[accountId], lockedMarginUsdc[accountId], activePositionMarginUsdc
        );
    }

    function _planFundingLossConsumption(
        bytes32 accountId,
        uint256 lockedPositionMarginUsdc,
        uint256 lossUsdc
    ) internal view returns (MarginClearinghouseAccountingLib.SettlementConsumption memory consumption) {
        return MarginClearinghouseAccountingLib.planFundingLossConsumption(
            _buildAccountUsdcBuckets(accountId, lockedPositionMarginUsdc), lossUsdc
        );
    }

    function _creditSettlementUsdc(
        bytes32 accountId,
        uint256 amountUsdc
    ) internal {
        settlementBalances[accountId] += amountUsdc;
    }

    function _debitSettlementUsdc(
        bytes32 accountId,
        uint256 amountUsdc
    ) internal {
        if (settlementBalances[accountId] < amountUsdc) {
            revert MarginClearinghouse__InsufficientUsdcForSettlement();
        }
        settlementBalances[accountId] -= amountUsdc;
    }

    function _lockMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) internal {
        if (getFreeBuyingPowerUsdc(accountId) < amountUsdc) {
            revert MarginClearinghouse__InsufficientFreeEquity();
        }
        if (settlementBalances[accountId] < lockedMarginUsdc[accountId] + amountUsdc) {
            revert MarginClearinghouse__InsufficientUsdcForSettlement();
        }
        lockedMarginUsdc[accountId] += amountUsdc;
        emit MarginLocked(accountId, amountUsdc);
    }

    function _unlockMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) internal {
        if (lockedMarginUsdc[accountId] >= amountUsdc) {
            lockedMarginUsdc[accountId] -= amountUsdc;
        } else {
            lockedMarginUsdc[accountId] = 0;
        }
        emit MarginUnlocked(accountId, amountUsdc);
    }

    /// @notice Transfers settlement USDC from an account to the calling operator.
    /// @dev The recipient must equal msg.sender, so operators can only pull seized funds
    ///      into their own contract/account and must forward them explicitly afterward.
    /// @param accountId Account to seize from
    /// @param amount USDC amount to seize
    /// @param recipient Recipient of seized tokens (must equal msg.sender)
    function seizeUsdc(
        bytes32 accountId,
        uint256 amount,
        address recipient
    ) external onlyOperator {
        if (recipient != msg.sender) {
            revert MarginClearinghouse__InvalidSeizeRecipient();
        }
        if (settlementBalances[accountId] < amount) {
            revert MarginClearinghouse__InsufficientAssetToSeize();
        }
        if (amount > getFreeSettlementBalanceUsdc(accountId)) {
            revert MarginClearinghouse__InsufficientAssetToSeize();
        }

        settlementBalances[accountId] -= amount;
        IERC20(settlementAsset).safeTransfer(recipient, amount);

        emit AssetSeized(accountId, settlementAsset, amount, recipient);
    }

    function balanceUsdc(
        bytes32 accountId
    ) external view returns (uint256) {
        return settlementBalances[accountId];
    }

}
