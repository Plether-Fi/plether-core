// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";

library CfdEngineSettlementLib {

    struct DebtCollectionResult {
        uint256 seizedUsdc;
        uint256 shortfallUsdc;
    }

    struct CloseSettlementResult {
        uint256 seizedUsdc;
        uint256 shortfallUsdc;
        uint256 collectedExecFeeUsdc;
        uint256 retainedExecFeeUsdc;
        uint256 badDebtUsdc;
    }

    struct LiquidationSettlementResult {
        uint256 targetBalanceUsdc;
        uint256 seizedUsdc;
        uint256 payoutUsdc;
        uint256 badDebtUsdc;
    }

    function collectSettlementDeficit(
        uint256 availableUsdc,
        uint256 owedUsdc
    ) internal pure returns (DebtCollectionResult memory result) {
        result.seizedUsdc = availableUsdc < owedUsdc ? availableUsdc : owedUsdc;
        result.shortfallUsdc = owedUsdc - result.seizedUsdc;
    }

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
