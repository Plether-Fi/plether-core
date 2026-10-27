// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {MockSettlementToken} from "../../../utils/MockSettlementToken.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {SolvencyAccountingLib} from "@plether/perps/libraries/SolvencyAccountingLib.sol";

contract MockInvariantHousePool is IHousePool {

    using SafeERC20 for MockSettlementToken;

    MockSettlementToken public immutable settlementToken;
    address public immutable engine;
    bool public lpEpochSettlementPaused;
    uint256 public pendingRecapitalizationAssets;
    uint256 public pendingTradingRevenueAssets;

    constructor(
        address _settlementToken,
        address _engine
    ) {
        settlementToken = MockSettlementToken(_settlementToken);
        engine = _engine;
    }

    function ENGINE() external view returns (address) {
        return engine;
    }

    function seedAssets(
        uint256 amountAssets
    ) external {
        settlementToken.mint(address(this), amountAssets);
    }

    function setAssets(
        uint256 targetAmountAssets
    ) external {
        uint256 currentAssets = settlementToken.balanceOf(address(this));
        if (targetAmountAssets > currentAssets) {
            settlementToken.mint(address(this), targetAmountAssets - currentAssets);
        } else if (currentAssets > targetAmountAssets) {
            settlementToken.burn(address(this), currentAssets - targetAmountAssets);
        }
    }

    function totalAssets() external view returns (uint256) {
        return settlementToken.balanceOf(address(this));
    }

    function getSettlementFreeAssets() external view returns (uint256) {
        ICfdEngineCore host = ICfdEngineCore(engine);
        (uint256 longMaxProfitAssets,,,) = host.sides(0);
        (uint256 shortMaxProfitAssets,,,) = host.sides(1);
        uint256 maxLiabilityAssets =
            longMaxProfitAssets > shortMaxProfitAssets ? longMaxProfitAssets : shortMaxProfitAssets;
        uint256 reservedAssets = maxLiabilityAssets + host.totalTraderClaimBalanceAssets()
            + SolvencyAccountingLib.settlementBufferTargetAssets(maxLiabilityAssets, host.settlementBufferBps())
            + pendingRecapitalizationAssets + pendingTradingRevenueAssets;
        uint256 cashAssets = settlementToken.balanceOf(address(this));
        return cashAssets > reservedAssets ? cashAssets - reservedAssets : 0;
    }

    function currentLpEpoch() external view returns (uint256) {
        return block.timestamp / 1 hours;
    }

    function lpEpochStart(
        uint256 epochId
    ) external pure returns (uint256) {
        return epochId * 1 hours;
    }

    function payOut(
        address recipient,
        uint256 amount
    ) external {
        _requireAuthorized();
        settlementToken.safeTransfer(recipient, amount);
    }

    function recordClaimantInflow(
        uint256 amountAssets,
        IHousePool.ClaimantInflowKind kind,
        IHousePool.ClaimantInflowCashMode
    ) external {
        _requireAuthorized();
        if (kind == IHousePool.ClaimantInflowKind.Recapitalization) {
            pendingRecapitalizationAssets += amountAssets;
        } else {
            pendingTradingRevenueAssets += amountAssets;
        }
    }

    function _requireAuthorized() internal view {
        if (msg.sender != engine && msg.sender != ICfdEngineCore(engine).settlementSidecar()) {
            revert("unauthorized");
        }
    }

    function markStalenessLimit() external pure returns (uint256) {
        return 120;
    }

    function isSeedLifecycleComplete() external pure returns (bool) {
        return true;
    }

    function hasSeedLifecycleStarted() external pure returns (bool) {
        return true;
    }

    function canAcceptOrdinaryDeposits() external pure returns (bool) {
        return true;
    }

    function canIncreaseRisk() external pure returns (bool) {
        return true;
    }

    function isTradingActive() external pure returns (bool) {
        return true;
    }

    function seniorPrincipal() external pure returns (uint256) {
        return 0;
    }

    function juniorPrincipal() external pure returns (uint256) {
        return 0;
    }

    function seniorHighWaterMark() external pure returns (uint256) {
        return 0;
    }

    function maxSeniorExposureAssets() external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxSeniorShareBps() external pure returns (uint256) {
        return 10_000;
    }

    function getSeniorDepositCapacity() external pure returns (uint256) {
        return type(uint256).max;
    }

    function reservedSeniorDepositAssets() external pure returns (uint256) {
        return 0;
    }

    function areSeniorDepositReservationsWithinLimits() external pure returns (bool) {
        return true;
    }

    function unassignedAssets() external pure returns (uint256) {
        return 0;
    }

    function terminalDeficitAssets() external pure returns (uint256) {
        return 0;
    }

    function reserveSeniorDeposit(
        uint256
    ) external pure {}

    function releaseSeniorDepositReservation(
        uint256
    ) external pure {}

    function settleLpEpoch(
        uint256,
        uint256
    ) external view returns (IHousePool.LpEpochSettlementResult memory result) {
        require(!lpEpochSettlementPaused, "LP settlement paused");
        return result;
    }

    function pauseLpEpochSettlement() external {
        require(!lpEpochSettlementPaused, "LP settlement already paused");
        lpEpochSettlementPaused = true;
    }

    function unpauseLpEpochSettlement() external {
        require(lpEpochSettlementPaused, "LP settlement not paused");
        lpEpochSettlementPaused = false;
    }

    function assignUnassignedAssets(
        bool,
        address
    ) external pure {}

    function initializeSeedPosition(
        bool,
        uint256,
        address
    ) external pure {}

    function getMaxSeniorWithdraw() external pure returns (uint256) {
        return 0;
    }

    function getMaxJuniorWithdraw() external pure returns (uint256) {
        return 0;
    }

    function getPendingTrancheState()
        external
        pure
        returns (
            uint256 seniorPrincipalAssets,
            uint256 juniorPrincipalAssets,
            uint256 maxSeniorWithdrawAssets,
            uint256 maxJuniorWithdrawAssets
        )
    {
        return (0, 0, 0, 0);
    }

    function getPendingDepositTrancheState()
        external
        pure
        returns (uint256 seniorPrincipalAssets, uint256 juniorPrincipalAssets)
    {
        return (0, 0);
    }

    function isSeniorImpairedAfterPendingDepositReconcile() external pure returns (bool) {
        return false;
    }

    function reconcile() external pure {}

    function isWithdrawalLive() external view returns (bool) {
        return !lpEpochSettlementPaused;
    }

    function canAcceptTrancheDeposits(
        bool
    ) external pure returns (bool) {
        return true;
    }

    function canSettleDepositEntries() external view returns (bool) {
        return !lpEpochSettlementPaused;
    }

    function isOracleFrozen() external pure returns (bool) {
        return false;
    }

    function frozenLpFeeBps(
        bool
    ) external pure returns (uint256) {
        return 0;
    }

    function minTrancheDepositAssets() external pure returns (uint256) {
        return 1e6;
    }

}
