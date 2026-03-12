// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library CfdEngineSettlementLib {

    struct DebtCollectionResult {
        uint256 seizedUsdc;
        uint256 shortfallUsdc;
    }

    struct CloseSettlementResult {
        uint256 seizedUsdc;
        uint256 shortfallUsdc;
        uint256 actualFeeUsdc;
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
        uint256 execFeeUsdc
    ) internal pure returns (CloseSettlementResult memory result) {
        DebtCollectionResult memory collection = collectSettlementDeficit(availableUsdc, owedUsdc);
        result.seizedUsdc = collection.seizedUsdc;
        result.shortfallUsdc = collection.shortfallUsdc;
        result.actualFeeUsdc = execFeeUsdc > collection.shortfallUsdc ? execFeeUsdc - collection.shortfallUsdc : 0;
        result.badDebtUsdc = collection.shortfallUsdc > execFeeUsdc ? collection.shortfallUsdc - execFeeUsdc : 0;
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
