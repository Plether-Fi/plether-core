// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

// Historical V2 intent / V3 receipt tuples from the pre-change checkout. Never substitute current tuples.
library LegacyCloseTypes {

    enum ExecutionMode {
        None,
        Live,
        Fad,
        Frozen
    }

    struct ExecutionBounds {
        uint64 validUntil;
        uint8 allowedExecutionModes;
        bytes32 expectedConfigHash;
        uint256 maxExecutionBountyUsdc;
        uint256 maxExecutionNotionalUsdc;
        uint256 maxGrossAccountDebitUsdc;
        uint256 maxActionChargeUsdc;
        uint256 maxExplicitFeesUsdc;
        uint256 maxPostPositionSize;
        uint256 minPostSettlementBalanceUsdc;
        uint256 minPostPositionEquityUsdc;
        uint32 maxPostLeverageBps;
    }

    struct OrderRequest {
        bytes32 clientOrderId;
        CfdTypes.Side side;
        uint256 sizeDelta;
        uint256 marginDelta;
        uint256 targetPrice;
        bool isClose;
        ExecutionBounds bounds;
    }

    struct ExecutionAssessment {
        ExecutionMode mode;
        uint256 executionNotionalUsdc;
        uint256 grossAccountDebitUsdc;
        uint256 actionChargeAssessedUsdc;
        uint256 actionChargeCollectedUsdc;
        uint256 explicitFeesUsdc;
        uint256 preSettlementBalanceUsdc;
        uint256 postSettlementBalanceUsdc;
        int256 realizedPnlUsdc;
        int256 vpiUsdc;
        uint256 carryUsdc;
        uint256 executionFeeUsdc;
        uint256 frozenSpreadUsdc;
        uint256 preTraderClaimUsdc;
        uint256 postTraderClaimUsdc;
        uint256 postPositionSize;
        uint256 postPositionMarginUsdc;
        int256 postPositionEquityUsdc;
        uint256 postLeverageBps;
    }

}

interface ILegacyClosePreview {

    struct SponsoredClosePreview {
        uint256 subsidyUsdc;
        uint256 depositCarryUsdc;
        uint256 commitmentCarryUsdc;
        uint256 executionBountyUsdc;
        LegacyCloseTypes.ExecutionAssessment assessment;
    }
    function validateSponsoredClose(
        address engine,
        LegacyCloseTypes.OrderRequest calldata request,
        uint256 subsidy
    ) external view;
    function previewSponsoredClose(
        address engine,
        address account,
        LegacyCloseTypes.OrderRequest calldata request,
        address executor,
        uint256 price,
        uint64 publishTime
    ) external view returns (SponsoredClosePreview memory);

}

interface ILegacyCloseRouter {

    function commitOrder(
        LegacyCloseTypes.OrderRequest calldata request
    ) external returns (uint64);

}

interface ILegacyClosePolicy {

    function assessOrder(
        address engine,
        CfdTypes.Order calldata order,
        address executor,
        uint256 price,
        uint256 depth,
        uint64 publishTime,
        LegacyCloseTypes.ExecutionBounds calldata bounds,
        uint256 bounty
    ) external view returns (LegacyCloseTypes.ExecutionAssessment memory);

}
