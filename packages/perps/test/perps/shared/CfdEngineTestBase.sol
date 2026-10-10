// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";

import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";

import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";

import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";
import {LiquidationAccountingLib} from "@plether/perps/libraries/LiquidationAccountingLib.sol";
import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

struct VpiRebateExtractionSnapshot {
    uint256 settlementBeforeOpen;
    uint256 walletBeforeOpen;
    uint256 poolAssetsBeforeOpen;
    uint256 rebateReserveUsdc;
}

contract LiquidationAccountingLibHarness {

    function build(
        uint256 size,
        uint256 oraclePrice,
        uint256 reachableCollateralUsdc,
        int256 equityUsdc,
        uint256 maintMarginBps,
        uint256 minBountyUsdc,
        uint256 bountyBps,
        uint256 keeperShareBps,
        uint256 protocolShareBps,
        uint256 tokenScale
    ) external pure returns (LiquidationAccountingLib.LiquidationState memory) {
        return LiquidationAccountingLib.buildLiquidationState(
            size,
            oraclePrice,
            reachableCollateralUsdc,
            equityUsdc,
            maintMarginBps,
            minBountyUsdc,
            bountyBps,
            keeperShareBps,
            protocolShareBps,
            tokenScale
        );
    }

}

contract CfdEnginePlanLibHarness {

    struct OpenWithExistingVpiParams {
        uint256 settlementBalanceUsdc;
        uint256 positionMarginUsdc;
        uint256 currentSize;
        uint256 currentEntryPrice;
        int256 vpiAccrued;
        uint256 sizeDelta;
        uint256 marginDelta;
        uint256 price;
    }

    function planLiquidation(
        uint256 pnlPledgeUsdc,
        uint256 traderClaimBalanceUsdc,
        uint256 size,
        uint256 entryPrice,
        uint256 oraclePrice
    ) external pure returns (CfdEnginePlanTypes.LiquidationDelta memory delta) {
        CfdEnginePlanTypes.RawSnapshot memory snap;
        uint256 lots = CfdMath.sizeToLots(size);
        uint256 entryCostUsdcAtoms = lots * entryPrice;
        uint256 maxProfitUsdc = CfdMath.calculateExactMaxProfit(lots, entryCostUsdcAtoms, CfdTypes.Side.SHORT, 2e8);
        snap.position = CfdTypes.Position({
            size: size,
            margin: pnlPledgeUsdc,
            entryPrice: entryPrice,
            maxProfitUsdc: maxProfitUsdc,
            side: CfdTypes.Side.SHORT,
            lastUpdateTime: 0,
            lastCarryTimestamp: 0,
            vpiAccrued: 0
        });
        snap.positionEntryCostUsdcAtoms = entryCostUsdcAtoms;
        snap.currentTimestamp = 1;
        snap.lastMarkPrice = oraclePrice;
        snap.lastMarkTime = 1;
        snap.shortSide.maxProfitUsdc = maxProfitUsdc;
        snap.shortSide.openInterest = size;
        snap.shortSide.entryNotional = entryCostUsdcAtoms * CfdMath.USDC_TO_TOKEN_SCALE;
        snap.shortSide.totalMargin = pnlPledgeUsdc;
        snap.poolAssetsUsdc = 1_000_000e6;
        snap.poolCashUsdc = 1;
        snap.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: pnlPledgeUsdc,
            totalLockedMarginUsdc: pnlPledgeUsdc,
            activePositionMarginUsdc: pnlPledgeUsdc,
            otherLockedMarginUsdc: 0,
            freeSettlementUsdc: 0
        });
        snap.lockedBuckets = IMarginClearinghouse.LockedMarginBuckets({
            positionMarginUsdc: pnlPledgeUsdc,
            committedOrderMarginUsdc: 0,
            reservedSettlementUsdc: 0,
            totalLockedMarginUsdc: pnlPledgeUsdc
        });
        snap.totalTraderClaimBalanceUsdc = traderClaimBalanceUsdc;
        snap.traderClaimBalanceForAccount = traderClaimBalanceUsdc;
        snap.capPrice = 2e8;
        snap.riskParams = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
        snap.executionFeeBps = 4;
        snap.frozenCloseSpreadBps = 1000;
        snap.oracleFrozen = true;
        return CfdEnginePlanLib.planLiquidation(snap, oraclePrice, 0);
    }

    function planLiquidationWithUnsettledCarry(
        uint256 pnlPledgeUsdc,
        uint256 freeSettlementUsdc,
        uint256 traderClaimBalanceUsdc,
        uint256 unsettledCarryUsdc,
        uint256 size,
        uint256 entryPrice,
        uint256 oraclePrice
    ) external pure returns (CfdEnginePlanTypes.LiquidationDelta memory delta) {
        CfdEnginePlanTypes.RawSnapshot memory snap;
        uint256 lots = CfdMath.sizeToLots(size);
        uint256 entryCostUsdcAtoms = lots * entryPrice;
        uint256 maxProfitUsdc = CfdMath.calculateExactMaxProfit(lots, entryCostUsdcAtoms, CfdTypes.Side.SHORT, 2e8);
        snap.position = CfdTypes.Position({
            size: size,
            margin: pnlPledgeUsdc,
            entryPrice: entryPrice,
            maxProfitUsdc: maxProfitUsdc,
            side: CfdTypes.Side.SHORT,
            lastUpdateTime: 0,
            lastCarryTimestamp: 1,
            vpiAccrued: 0
        });
        snap.positionEntryCostUsdcAtoms = entryCostUsdcAtoms;
        snap.currentTimestamp = 1;
        snap.lastMarkPrice = oraclePrice;
        snap.lastMarkTime = 1;
        snap.shortSide.maxProfitUsdc = maxProfitUsdc;
        snap.shortSide.openInterest = size;
        snap.shortSide.entryNotional = entryCostUsdcAtoms * CfdMath.USDC_TO_TOKEN_SCALE;
        snap.shortSide.totalMargin = pnlPledgeUsdc;
        snap.poolAssetsUsdc = 1_000_000e6;
        snap.poolCashUsdc = 1;
        snap.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: pnlPledgeUsdc + freeSettlementUsdc,
            totalLockedMarginUsdc: pnlPledgeUsdc,
            activePositionMarginUsdc: pnlPledgeUsdc,
            otherLockedMarginUsdc: 0,
            freeSettlementUsdc: freeSettlementUsdc
        });
        snap.lockedBuckets = IMarginClearinghouse.LockedMarginBuckets({
            positionMarginUsdc: pnlPledgeUsdc,
            committedOrderMarginUsdc: 0,
            reservedSettlementUsdc: 0,
            totalLockedMarginUsdc: pnlPledgeUsdc
        });
        snap.totalTraderClaimBalanceUsdc = traderClaimBalanceUsdc;
        snap.traderClaimBalanceForAccount = traderClaimBalanceUsdc;
        snap.capPrice = 2e8;
        snap.riskParams = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
        snap.unsettledCarryUsdc = unsettledCarryUsdc;
        snap.executionFeeBps = 4;
        return CfdEnginePlanLib.planLiquidation(snap, oraclePrice, 0);
    }

    function planLiquidationWithVpiAccrued(
        uint256 settlementReachableUsdc,
        uint256 traderClaimBalanceUsdc,
        uint256 size,
        uint256 entryPrice,
        uint256 oraclePrice,
        int256 vpiAccrued
    ) external pure returns (CfdEnginePlanTypes.LiquidationDelta memory delta) {
        CfdEnginePlanTypes.RawSnapshot memory snap;
        uint256 entryCostUsdcAtoms = CfdMath.sizeToLots(size) * entryPrice;
        uint256 maxProfitUsdc =
            CfdMath.calculateExactMaxProfit(CfdMath.sizeToLots(size), entryCostUsdcAtoms, CfdTypes.Side.SHORT, 2e8);
        uint256 vpiReserveUsdc = vpiAccrued < 0 ? uint256(-(vpiAccrued + 1)) + 1 : 0;
        snap.position = CfdTypes.Position({
            size: size,
            margin: settlementReachableUsdc,
            entryPrice: entryPrice,
            maxProfitUsdc: maxProfitUsdc,
            side: CfdTypes.Side.SHORT,
            lastUpdateTime: 0,
            lastCarryTimestamp: 0,
            vpiAccrued: vpiAccrued
        });
        snap.positionEntryCostUsdcAtoms = entryCostUsdcAtoms;
        snap.currentTimestamp = 1;
        snap.lastMarkPrice = oraclePrice;
        snap.lastMarkTime = 1;
        snap.shortSide.maxProfitUsdc = maxProfitUsdc;
        snap.shortSide.openInterest = size;
        snap.shortSide.entryNotional = entryCostUsdcAtoms * CfdMath.USDC_TO_TOKEN_SCALE;
        snap.shortSide.totalMargin = settlementReachableUsdc;
        snap.poolAssetsUsdc = 1_000_000e6;
        snap.poolCashUsdc = 1;
        snap.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: settlementReachableUsdc + vpiReserveUsdc,
            totalLockedMarginUsdc: settlementReachableUsdc + vpiReserveUsdc,
            activePositionMarginUsdc: settlementReachableUsdc,
            otherLockedMarginUsdc: vpiReserveUsdc,
            freeSettlementUsdc: 0
        });
        snap.lockedBuckets = IMarginClearinghouse.LockedMarginBuckets({
            positionMarginUsdc: settlementReachableUsdc,
            committedOrderMarginUsdc: 0,
            reservedSettlementUsdc: vpiReserveUsdc,
            totalLockedMarginUsdc: settlementReachableUsdc + vpiReserveUsdc
        });
        snap.actionReserveUsdc = vpiReserveUsdc;
        snap.vpiRebateReserveUsdc = vpiReserveUsdc;
        snap.totalTraderClaimBalanceUsdc = traderClaimBalanceUsdc;
        snap.traderClaimBalanceForAccount = traderClaimBalanceUsdc;
        snap.capPrice = 2e8;
        snap.riskParams = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
        snap.executionFeeBps = 4;
        return CfdEnginePlanLib.planLiquidation(snap, oraclePrice, 0);
    }

    function planOpenWithExistingVpiAccrued(
        OpenWithExistingVpiParams calldata params
    ) external pure returns (CfdEnginePlanTypes.OpenDelta memory delta) {
        CfdEnginePlanTypes.RawSnapshot memory snap;
        uint256 currentLots = CfdMath.sizeToLots(params.currentSize);
        uint256 currentEntryCostUsdcAtoms = currentLots * params.currentEntryPrice;
        uint256 currentMaxProfitUsdc =
            CfdMath.calculateExactMaxProfit(currentLots, currentEntryCostUsdcAtoms, CfdTypes.Side.LONG, 2e8);
        uint256 vpiReserveUsdc = params.vpiAccrued < 0 ? uint256(-(params.vpiAccrued + 1)) + 1 : 0;
        uint256 liquidationReserveUsdc = (currentLots * params.price * 10) / 10_000;
        if (liquidationReserveUsdc < 1e6) {
            liquidationReserveUsdc = 1e6;
        }
        uint256 totalSettlementUsdc = params.settlementBalanceUsdc + vpiReserveUsdc + liquidationReserveUsdc;
        uint256 totalLockedUsdc = params.positionMarginUsdc + vpiReserveUsdc + liquidationReserveUsdc;
        snap.account = address(uint160(0x1234));
        snap.position = CfdTypes.Position({
            size: params.currentSize,
            margin: params.positionMarginUsdc,
            entryPrice: params.currentEntryPrice,
            maxProfitUsdc: currentMaxProfitUsdc,
            side: CfdTypes.Side.LONG,
            lastUpdateTime: 0,
            lastCarryTimestamp: 0,
            vpiAccrued: params.vpiAccrued
        });
        snap.positionEntryCostUsdcAtoms = currentEntryCostUsdcAtoms;
        snap.currentTimestamp = 1;
        snap.lastMarkPrice = params.price;
        snap.lastMarkTime = 1;
        snap.longSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: currentMaxProfitUsdc,
            openInterest: params.currentSize,
            entryNotional: currentEntryCostUsdcAtoms * CfdMath.USDC_TO_TOKEN_SCALE,
            totalMargin: params.positionMarginUsdc,
            borrowBaseUsdc: 0,
            carryIndex: 0
        });
        snap.shortSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: 0, openInterest: 0, entryNotional: 0, totalMargin: 0, borrowBaseUsdc: 0, carryIndex: 0
        });
        snap.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: totalSettlementUsdc,
            totalLockedMarginUsdc: totalLockedUsdc,
            activePositionMarginUsdc: params.positionMarginUsdc,
            otherLockedMarginUsdc: vpiReserveUsdc + liquidationReserveUsdc,
            freeSettlementUsdc: params.settlementBalanceUsdc > params.positionMarginUsdc
                ? params.settlementBalanceUsdc - params.positionMarginUsdc
                : 0
        });
        snap.lockedBuckets = IMarginClearinghouse.LockedMarginBuckets({
            positionMarginUsdc: params.positionMarginUsdc,
            committedOrderMarginUsdc: 0,
            reservedSettlementUsdc: vpiReserveUsdc,
            totalLockedMarginUsdc: totalLockedUsdc
        });
        snap.liquidationReserveUsdc = liquidationReserveUsdc;
        snap.actionReserveUsdc = vpiReserveUsdc;
        snap.vpiRebateReserveUsdc = vpiReserveUsdc;
        snap.capPrice = 2e8;
        snap.riskParams = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
        snap.executionFeeBps = 4;
        snap.poolAssetsUsdc = 1_000_000e6;
        snap.poolCashUsdc = 1_000_000e6;

        return CfdEnginePlanLib.planOpen(
            snap,
            CfdTypes.Order({
                account: snap.account,
                sizeDelta: params.sizeDelta,
                marginDelta: params.marginDelta,
                targetPrice: params.price,
                commitTime: 0,
                commitBlock: 0,
                orderId: 0,
                side: CfdTypes.Side.LONG,
                isClose: false
            }),
            params.price,
            0
        );
    }

}

abstract contract CfdEngineTestBase is BasePerpTest {

    event FrozenCloseSpreadSettled(address indexed account, uint256 assessedUsdc, uint256 paidUsdc, uint256 waivedUsdc);
    event PriceLossWrittenOff(address indexed account, uint256 amountUsdc);
    event ClaimantInflowAccounted(
        address indexed caller,
        IHousePool.ClaimantInflowKind kind,
        IHousePool.ClaimantInflowCashMode cashMode,
        uint256 amountUsdc
    );

    using stdStorage for StdStorage;

    function _seedAuthenticatedTraderClaim(
        address account,
        uint256 claimUsdc
    ) internal {
        bytes32 oldCurveHash = terminalNavBook.curveHashOf(account);
        uint256 oldAccountClaimUsdc = engine.traderClaimBalanceUsdc(account);
        uint256 oldTotalClaimUsdc = engine.totalTraderClaimBalanceUsdc();
        stdstore.target(address(engine)).sig("traderClaimBalanceUsdc(address)").with_key(account)
            .checked_write(claimUsdc);
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceUsdc()")
            .checked_write(oldTotalClaimUsdc - oldAccountClaimUsdc + claimUsdc);
        vm.prank(address(engine));
        terminalNavBook.syncFromEngine(account, oldCurveHash);
        vm.prank(address(engine));
        terminalNavBook.authenticateEngineState(account);
    }

    function _assertTerminalCurveAuthenticated(
        address account
    ) internal {
        vm.prank(address(engine));
        terminalNavBook.authenticateEngineState(account);
    }

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 1000e6;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 1000e6;
    }

    function _maxLiabilityAfterClose(
        CfdTypes.Side side,
        uint256 maxProfitReductionUsdc
    ) internal view returns (uint256) {
        uint256 longMaxProfit = _sideMaxProfit(CfdTypes.Side.LONG);
        uint256 shortMaxProfit = _sideMaxProfit(CfdTypes.Side.SHORT);
        if (side == CfdTypes.Side.LONG) {
            longMaxProfit -= maxProfitReductionUsdc;
        } else {
            shortMaxProfit -= maxProfitReductionUsdc;
        }
        return longMaxProfit > shortMaxProfit ? longMaxProfit : shortMaxProfit;
    }

    function _expectedIndexedCarry(
        address account
    ) internal view returns (uint256) {
        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(account);
        if (size == 0) {
            return 0;
        }
        (uint256 borrowBaseUsdc, uint256 startIndex,) = engine.positionCarryState(account);
        uint256 endIndex = _currentSideCarryIndex(side);
        if (endIndex <= startIndex) {
            return 0;
        }
        return PositionRiskAccountingLib.computeIndexedCarryUsdc(borrowBaseUsdc, endIndex - startIndex);
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _setFadMaxStaleness(
        uint256 val
    ) internal {
        ICfdEngineAdminHost.EngineFreshnessConfig memory config = _engineFreshnessConfig();
        config.fadMaxStaleness = val;
        _setFreshnessConfig(config);
    }

    function _nextSaturdayNoon() internal view returns (uint256 timestamp) {
        uint256 currentDay = ((block.timestamp / 1 days) + 4) % 7;
        uint256 startOfDay = block.timestamp - (block.timestamp % 1 days);
        uint256 deltaDays = 6 - currentDay;
        timestamp = startOfDay + deltaDays * 1 days + 12 hours;
        if (timestamp <= block.timestamp) {
            timestamp += 7 days;
        }
    }

    function _settleJuniorDepositFromBalance(
        address owner,
        uint256 assets
    ) internal returns (uint256 shares) {
        vm.prank(owner);
        uint256 requestId = juniorVault.requestDeposit(assets, owner, owner);

        vm.warp(pool.lpEpochStart(requestId));
        uint256 markPrice = engine.lastMarkPrice();
        vm.prank(address(router));
        engine.updateMarkPrice(markPrice == 0 ? 1e8 : markPrice, uint64(block.timestamp));
        _settleLpEpochForTest();

        uint256 claimableAssets = juniorVault.claimableDepositRequest(requestId, owner);
        vm.prank(owner);
        shares = juniorVault.claimDeposit(requestId, claimableAssets, owner, owner);
    }

    function _settleJuniorWithdrawal(
        address owner,
        uint256 assets
    ) internal returns (uint256 claimedAssets) {
        uint256 shares = juniorVault.estimateWithdrawShares(assets);
        vm.prank(owner);
        uint256 requestId = juniorVault.requestRedeem(shares, owner, owner);

        vm.warp(pool.lpEpochStart(requestId));
        uint256 markPrice = engine.lastMarkPrice();
        vm.prank(address(router));
        engine.updateMarkPrice(markPrice == 0 ? 1e8 : markPrice, uint64(block.timestamp));
        _settleLpEpochForTest();

        uint256 claimableShares = juniorVault.claimableRedeemRequest(requestId, owner);
        vm.prank(owner);
        claimedAssets = juniorVault.claimRedeem(requestId, claimableShares, owner, owner);
    }

    function _removePnlPledgeAndSyncTerminalCurve(
        address account
    ) internal {
        bytes32 oldCurveHash = terminalNavBook.curveHashOf(account);
        IMarginClearinghouse.LockedMarginBuckets memory lockedBefore = clearinghouse.getLockedMarginBuckets(account);
        uint256 nonPnlLockedUsdc = lockedBefore.totalLockedMarginUsdc - lockedBefore.positionMarginUsdc;
        stdstore.target(address(clearinghouse)).sig("balanceUsdc(address)").with_key(account)
            .checked_write(nonPnlLockedUsdc);
        bytes32 positionMarginSlot = keccak256(abi.encode(account, uint256(3)));
        vm.store(address(clearinghouse), positionMarginSlot, bytes32(uint256(0)));
        vm.prank(address(engine));
        terminalNavBook.syncFromEngine(account, oldCurveHash);

        IMarginClearinghouse.LockedMarginBuckets memory locked = clearinghouse.getLockedMarginBuckets(account);
        assertEq(locked.positionMarginUsdc, 0, "Test must reduce reachable collateral below the terminal close fee");
        assertEq(
            clearinghouse.balanceUsdc(account),
            locked.totalLockedMarginUsdc,
            "Synthetic shortfall must preserve backing for every non-PnL locked bucket"
        );
    }

    function _positivePart(
        int256 value
    ) internal pure returns (uint256) {
        return value > 0 ? uint256(value) : 0;
    }

    function _processUnderfundedFeeClose(
        address account,
        uint256 poolDepth,
        uint64 refreshTime
    ) internal {
        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 5000e18,
            marginDelta: 0,
            targetPrice: 0,
            commitTime: refreshTime,
            commitBlock: uint64(block.number),
            orderId: 0,
            side: CfdTypes.Side.SHORT,
            isClose: true
        });
        vm.prank(address(router));
        engine.processOrderTyped(order, 1e8, poolDepth, refreshTime);
    }

    function _negativePart(
        int256 value
    ) internal pure returns (uint256) {
        return value < 0 ? uint256(-value) : 0;
    }

}

contract VpiMockUSDC6 is ERC20 {

    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}
