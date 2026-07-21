// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";

/// @title CfdEngineSettlementLib
/// @notice Computes collateral collection and payout breakdowns for close and liquidation settlement.
/// @dev All monetary values are 6-decimal USDC. The helpers are pure accounting previews: callers apply the
///      returned debits, payouts, fee credits, and bad debt separately.
library CfdEngineSettlementLib {

    /// @notice Result of collecting an amount owed from a bounded source of collateral.
    /// @param seizedUsdc Collateral collected, equal to `min(availableUsdc, owedUsdc)`.
    /// @param shortfallUsdc Portion of the amount owed that the supplied collateral cannot cover.
    struct DebtCollectionResult {
        uint256 seizedUsdc;
        uint256 shortfallUsdc;
    }

    /// @notice Allocation of a close loss across collateral, execution fees, and base trading loss.
    /// @dev `badDebtUsdc` intentionally excludes uncollected execution fees and frozen-close spread. Those charges
    ///      may contribute to `shortfallUsdc`, but only the uncollected base amount is protocol bad debt.
    /// @param seizedUsdc Account collateral collected toward the total amount owed.
    /// @param shortfallUsdc Total amount owed but not collected, including any uncollected charges.
    /// @param collectedExecFeeUsdc Execution fee contained in seized collateral.
    /// @param retainedExecFeeUsdc Execution fee offset by trader profit outside `owedUsdc` and marked for pool top-up.
    /// @param badDebtUsdc Uncollected base loss after prioritizing collected execution fee; excludes fee and spread.
    struct CloseSettlementResult {
        uint256 seizedUsdc;
        uint256 shortfallUsdc;
        uint256 collectedExecFeeUsdc;
        uint256 retainedExecFeeUsdc;
        uint256 badDebtUsdc;
    }

    /// @notice Settlement deltas required to leave an account at a signed post-liquidation residual.
    /// @param targetBalanceUsdc Desired account balance for a nonnegative residual; zero for a negative residual.
    /// @param seizedUsdc Existing account balance removed from the account.
    /// @param payoutUsdc Fresh value needed when a positive target exceeds the existing account balance.
    /// @param badDebtUsdc Magnitude of a negative residual; existing balance is seized in full in this case.
    struct LiquidationSettlementResult {
        uint256 targetBalanceUsdc;
        uint256 seizedUsdc;
        uint256 payoutUsdc;
        uint256 badDebtUsdc;
    }

    /// @notice Collects as much of an amount owed as the supplied collateral permits.
    /// @param availableUsdc Collateral eligible for collection.
    /// @param owedUsdc Total amount requested from that collateral.
    /// @return result Collected collateral and the uncovered remainder. No rounding is performed.
    function collectSettlementDeficit(
        uint256 availableUsdc,
        uint256 owedUsdc
    ) internal pure returns (DebtCollectionResult memory result) {
        result.seizedUsdc = availableUsdc < owedUsdc ? availableUsdc : owedUsdc;
        result.shortfallUsdc = owedUsdc - result.seizedUsdc;
    }

    /// @notice Splits a close loss into seized collateral, fee recognition, total shortfall, and base bad debt.
    /// @dev `owedUsdc` is the nonnegative magnitude of the net close settlement and can be smaller than the sum of
    ///      `execFeeUsdc` and `frozenSpreadUsdc`. Charges outside that net amount are treated as retained, with the
    ///      execution fee allocated before the frozen spread. Within seized collateral, priority is execution fee,
    ///      base loss, then frozen spread; the frozen spread is never counted as `badDebtUsdc`.
    /// @param availableUsdc Collateral eligible to cover the close loss.
    /// @param owedUsdc Magnitude of the trader's net close obligation, including the portion of charges embedded in it.
    /// @param execFeeUsdc Gross execution fee charged for the close.
    /// @param frozenSpreadUsdc Gross frozen-oracle close spread charged for the close.
    /// @return result Settlement allocation. All min operations are exact; no fractional rounding occurs here.
    function closeSettlementResult(
        uint256 availableUsdc,
        uint256 owedUsdc,
        uint256 execFeeUsdc,
        uint256 frozenSpreadUsdc
    ) internal pure returns (CloseSettlementResult memory result) {
        DebtCollectionResult memory collection = collectSettlementDeficit(availableUsdc, owedUsdc);
        result.seizedUsdc = collection.seizedUsdc;
        result.shortfallUsdc = collection.shortfallUsdc;

        uint256 totalChargesUsdc = execFeeUsdc + frozenSpreadUsdc;
        uint256 retainedChargesUsdc = totalChargesUsdc > owedUsdc ? totalChargesUsdc - owedUsdc : 0;
        result.retainedExecFeeUsdc = execFeeUsdc < retainedChargesUsdc ? execFeeUsdc : retainedChargesUsdc;
        uint256 retainedAfterExecFeeUsdc = retainedChargesUsdc - result.retainedExecFeeUsdc;
        uint256 retainedFrozenSpreadUsdc =
            frozenSpreadUsdc < retainedAfterExecFeeUsdc ? frozenSpreadUsdc : retainedAfterExecFeeUsdc;

        uint256 feeEmbeddedInOwedUsdc = execFeeUsdc - result.retainedExecFeeUsdc;
        result.collectedExecFeeUsdc =
            feeEmbeddedInOwedUsdc < collection.seizedUsdc ? feeEmbeddedInOwedUsdc : collection.seizedUsdc;
        uint256 spreadEmbeddedInOwedUsdc = frozenSpreadUsdc - retainedFrozenSpreadUsdc;
        uint256 baseOwedUsdc = owedUsdc - feeEmbeddedInOwedUsdc - spreadEmbeddedInOwedUsdc;
        uint256 seizedAfterExecFeeUsdc = collection.seizedUsdc - result.collectedExecFeeUsdc;
        uint256 collectedBaseUsdc = baseOwedUsdc < seizedAfterExecFeeUsdc ? baseOwedUsdc : seizedAfterExecFeeUsdc;
        result.badDebtUsdc = baseOwedUsdc - collectedBaseUsdc;
    }

    /// @notice Computes close-loss settlement from terminal clearinghouse buckets while protecting locked margin.
    /// @dev Eligible collateral is capped by `settlementBalanceUsdc - protectedLockedMarginUsdc`, floored at zero.
    ///      The returned result describes value allocation only; the bucket-consumption plan must be applied separately.
    /// @param buckets Clearinghouse balance and lock-bucket snapshot for the account.
    /// @param protectedLockedMarginUsdc Locked balance that must remain unreachable, normally remaining position margin.
    /// @param owedUsdc Magnitude of the trader's net close obligation.
    /// @param execFeeUsdc Gross execution fee charged for the close.
    /// @param frozenSpreadUsdc Gross frozen-oracle close spread charged for the close.
    /// @return result Close settlement based on the amount consumable from terminal buckets.
    function closeSettlementResultForTerminalBuckets(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        uint256 protectedLockedMarginUsdc,
        uint256 owedUsdc,
        uint256 execFeeUsdc,
        uint256 frozenSpreadUsdc
    ) internal pure returns (CloseSettlementResult memory result) {
        MarginClearinghouseAccountingLib.SettlementConsumption memory consumption =
            MarginClearinghouseAccountingLib.planTerminalLossConsumption(buckets, protectedLockedMarginUsdc, owedUsdc);
        result = closeSettlementResult(consumption.totalConsumedUsdc, owedUsdc, execFeeUsdc, frozenSpreadUsdc);
    }

    /// @notice Computes the account seizure or payout required by signed post-liquidation residual equity.
    /// @dev For a nonnegative residual, the account is moved toward `residualUsdc`: excess balance is seized and a
    ///      deficit becomes a fresh payout. For a negative residual, the full balance is seized and the entire
    ///      residual magnitude is reported as bad debt; seizure does not reduce that bad-debt field.
    ///      `type(int256).min` cannot be negated and therefore reverts on the negative path.
    /// @param accountBalanceUsdc Existing settlement balance eligible for liquidation settlement.
    /// @param residualUsdc Desired residual equity after liquidation costs; negative values denote bad debt.
    /// @return result Target balance, seizure, fresh payout, and bad-debt breakdown.
    function liquidationSettlementResult(
        uint256 accountBalanceUsdc,
        int256 residualUsdc
    ) internal pure returns (LiquidationSettlementResult memory result) {
        if (residualUsdc >= 0) {
            result.targetBalanceUsdc = uint256(residualUsdc);
            if (accountBalanceUsdc > result.targetBalanceUsdc) {
                result.seizedUsdc = accountBalanceUsdc - result.targetBalanceUsdc;
            } else if (result.targetBalanceUsdc > accountBalanceUsdc) {
                result.payoutUsdc = result.targetBalanceUsdc - accountBalanceUsdc;
            }
            return result;
        }

        result.seizedUsdc = accountBalanceUsdc;
        result.badDebtUsdc = uint256(-residualUsdc);
    }

}
