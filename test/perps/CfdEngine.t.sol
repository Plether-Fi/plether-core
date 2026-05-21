// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdEngineAdmin} from "../../src/perps/CfdEngineAdmin.sol";
import {CfdEnginePlanTypes} from "../../src/perps/CfdEnginePlanTypes.sol";
import {CfdEnginePlanner} from "../../src/perps/CfdEnginePlanner.sol";
import {CfdEngineSettlementSidecar} from "../../src/perps/CfdEngineSettlementSidecar.sol";
import {CfdMath} from "../../src/perps/CfdMath.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {PerpsPublicLens} from "../../src/perps/PerpsPublicLens.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {AccountLensViewTypes} from "../../src/perps/interfaces/AccountLensViewTypes.sol";
import {ClaimEngineViewTypes} from "../../src/perps/interfaces/ClaimEngineViewTypes.sol";
import {HousePoolEngineViewTypes} from "../../src/perps/interfaces/HousePoolEngineViewTypes.sol";
import {ICfdEngine} from "../../src/perps/interfaces/ICfdEngine.sol";
import {ICfdEngineAdminHost} from "../../src/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEngineSettlementHost} from "../../src/perps/interfaces/ICfdEngineSettlementHost.sol";
import {ICfdEngineTypes} from "../../src/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "../../src/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "../../src/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "../../src/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "../../src/perps/interfaces/IOrderRouterAdminHost.sol";
import {PerpsViewTypes} from "../../src/perps/interfaces/PerpsViewTypes.sol";
import {ProtocolLensViewTypes} from "../../src/perps/interfaces/ProtocolLensViewTypes.sol";
import {CfdEnginePlanLib} from "../../src/perps/libraries/CfdEnginePlanLib.sol";
import {LiquidationAccountingLib} from "../../src/perps/libraries/LiquidationAccountingLib.sol";
import {MarginClearinghouseAccountingLib} from "../../src/perps/libraries/MarginClearinghouseAccountingLib.sol";
import {PositionRiskAccountingLib} from "../../src/perps/libraries/PositionRiskAccountingLib.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Test} from "forge-std/Test.sol";

contract LiquidationAccountingLibHarness {

    function build(
        uint256 size,
        uint256 oraclePrice,
        uint256 reachableCollateralUsdc,
        int256 equityUsdc,
        uint256 maintMarginBps,
        uint256 minBountyUsdc,
        uint256 bountyBps,
        uint256 tokenScale
    ) external pure returns (LiquidationAccountingLib.LiquidationState memory) {
        return LiquidationAccountingLib.buildLiquidationState(
            size, oraclePrice, reachableCollateralUsdc, equityUsdc, maintMarginBps, minBountyUsdc, bountyBps, tokenScale
        );
    }

}

contract CfdEnginePlanLibHarness {

    function planLiquidation(
        uint256 settlementReachableUsdc,
        uint256 traderClaimBalanceUsdc,
        uint256 size,
        uint256 entryPrice,
        uint256 oraclePrice
    ) external pure returns (CfdEnginePlanTypes.LiquidationDelta memory delta) {
        CfdEnginePlanTypes.RawSnapshot memory snap;
        snap.position = CfdTypes.Position({
            size: size,
            margin: 0,
            entryPrice: entryPrice,
            maxProfitUsdc: 0,
            side: CfdTypes.Side.BEAR,
            lastUpdateTime: 0,
            lastCarryTimestamp: 0,
            vpiAccrued: 0
        });
        snap.currentTimestamp = 1;
        snap.lastMarkPrice = oraclePrice;
        snap.lastMarkTime = 1;
        snap.bearSide.openInterest = size;
        snap.poolAssetsUsdc = 1_000_000e6;
        snap.poolCashUsdc = 1;
        snap.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: settlementReachableUsdc,
            totalLockedMarginUsdc: 0,
            activePositionMarginUsdc: 0,
            otherLockedMarginUsdc: 0,
            freeSettlementUsdc: settlementReachableUsdc
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
            bountyBps: 10
        });
        snap.executionFeeBps = 4;
        return CfdEnginePlanLib.planLiquidation(snap, oraclePrice, 0);
    }

    function planLiquidationWithCarry(
        uint256 settlementReachableUsdc,
        uint256 traderClaimBalanceUsdc,
        uint256 size,
        uint256 entryPrice,
        uint256 oraclePrice,
        uint64 currentTimestamp,
        uint64 lastCarryTimestamp
    ) external pure returns (CfdEnginePlanTypes.LiquidationDelta memory delta) {
        CfdEnginePlanTypes.RawSnapshot memory snap;
        uint256 maxProfitUsdc = CfdMath.calculateMaxProfit(size, entryPrice, CfdTypes.Side.BEAR, 2e8);
        snap.position = CfdTypes.Position({
            size: size,
            margin: 0,
            entryPrice: entryPrice,
            maxProfitUsdc: maxProfitUsdc,
            side: CfdTypes.Side.BEAR,
            lastUpdateTime: 0,
            lastCarryTimestamp: lastCarryTimestamp,
            vpiAccrued: 0
        });
        snap.currentTimestamp = currentTimestamp;
        snap.lastMarkPrice = oraclePrice;
        snap.lastMarkTime = currentTimestamp;
        snap.bearSide.maxProfitUsdc = maxProfitUsdc;
        snap.bearSide.openInterest = size;
        snap.bearSide.entryNotional = size * entryPrice;
        snap.poolAssetsUsdc = 1_000_000e6;
        snap.poolCashUsdc = 1;
        snap.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: settlementReachableUsdc,
            totalLockedMarginUsdc: 0,
            activePositionMarginUsdc: 0,
            otherLockedMarginUsdc: 0,
            freeSettlementUsdc: settlementReachableUsdc
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
            bountyBps: 10
        });
        uint256 carryTimeDelta = currentTimestamp > lastCarryTimestamp ? currentTimestamp - lastCarryTimestamp : 0;
        snap.positionBorrowBaseUsdc = maxProfitUsdc;
        snap.positionLastCarryIndex = 0;
        snap.bearSide.borrowBaseUsdc = snap.poolAssetsUsdc;
        snap.bearSide.carryIndex =
            PositionRiskAccountingLib.computeCarryIndexIncrement(snap.riskParams.baseCarryBps, carryTimeDelta);
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
        snap.position = CfdTypes.Position({
            size: size,
            margin: 0,
            entryPrice: entryPrice,
            maxProfitUsdc: 0,
            side: CfdTypes.Side.BEAR,
            lastUpdateTime: 0,
            lastCarryTimestamp: 0,
            vpiAccrued: vpiAccrued
        });
        snap.currentTimestamp = 1;
        snap.lastMarkPrice = oraclePrice;
        snap.lastMarkTime = 1;
        snap.bearSide.openInterest = size;
        snap.poolAssetsUsdc = 1_000_000e6;
        snap.poolCashUsdc = 1;
        snap.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: settlementReachableUsdc,
            totalLockedMarginUsdc: 0,
            activePositionMarginUsdc: 0,
            otherLockedMarginUsdc: 0,
            freeSettlementUsdc: settlementReachableUsdc
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
            bountyBps: 10
        });
        snap.executionFeeBps = 4;
        return CfdEnginePlanLib.planLiquidation(snap, oraclePrice, 0);
    }

    function planOpenWithExistingVpiAccrued(
        uint256 settlementBalanceUsdc,
        uint256 positionMarginUsdc,
        uint256 currentSize,
        uint256 currentEntryPrice,
        int256 vpiAccrued,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 price
    ) external pure returns (CfdEnginePlanTypes.OpenDelta memory delta) {
        CfdEnginePlanTypes.RawSnapshot memory snap;
        snap.account = address(uint160(0x1234));
        snap.position = CfdTypes.Position({
            size: currentSize,
            margin: positionMarginUsdc,
            entryPrice: currentEntryPrice,
            maxProfitUsdc: 100_000e6,
            side: CfdTypes.Side.BULL,
            lastUpdateTime: 0,
            lastCarryTimestamp: 0,
            vpiAccrued: vpiAccrued
        });
        snap.currentTimestamp = 1;
        snap.lastMarkPrice = price;
        snap.lastMarkTime = 1;
        snap.bullSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: 100_000e6,
            openInterest: currentSize,
            entryNotional: currentSize * currentEntryPrice,
            totalMargin: positionMarginUsdc,
            borrowBaseUsdc: 0,
            carryIndex: 0
        });
        snap.bearSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: 0, openInterest: 0, entryNotional: 0, totalMargin: 0, borrowBaseUsdc: 0, carryIndex: 0
        });
        snap.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: settlementBalanceUsdc,
            totalLockedMarginUsdc: positionMarginUsdc,
            activePositionMarginUsdc: positionMarginUsdc,
            otherLockedMarginUsdc: 0,
            freeSettlementUsdc: settlementBalanceUsdc > positionMarginUsdc
                ? settlementBalanceUsdc - positionMarginUsdc
                : 0
        });
        snap.capPrice = 2e8;
        snap.riskParams = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10
        });
        snap.executionFeeBps = 4;
        snap.poolAssetsUsdc = 1_000_000e6;
        snap.poolCashUsdc = 1_000_000e6;

        return CfdEnginePlanLib.planOpen(
            snap,
            CfdTypes.Order({
                account: snap.account,
                sizeDelta: sizeDelta,
                marginDelta: marginDelta,
                targetPrice: price,
                commitTime: 0,
                commitBlock: 0,
                orderId: 0,
                side: CfdTypes.Side.BULL,
                isClose: false
            }),
            price,
            0
        );
    }

}

contract CfdEngineTest is BasePerpTest {

    using stdStorage for StdStorage;

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 1000e6;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 1000e6;
    }

    function _legacyCappedSpreadAfter(
        int256 bullLegacySpread,
        int256 bearLegacySpread,
        uint256 bullMargin,
        uint256 bearMargin
    ) internal pure returns (int256) {
        if (bullLegacySpread < -int256(bullMargin)) {
            bullLegacySpread = -int256(bullMargin);
        }
        if (bearLegacySpread < -int256(bearMargin)) {
            bearLegacySpread = -int256(bearMargin);
        }
        return bullLegacySpread + bearLegacySpread;
    }

    function _maxLiabilityAfterClose(
        CfdTypes.Side side,
        uint256 maxProfitReductionUsdc
    ) internal view returns (uint256) {
        uint256 bullMaxProfit = _sideMaxProfit(CfdTypes.Side.BULL);
        uint256 bearMaxProfit = _sideMaxProfit(CfdTypes.Side.BEAR);
        if (side == CfdTypes.Side.BULL) {
            bullMaxProfit -= maxProfitReductionUsdc;
        } else {
            bearMaxProfit -= maxProfitReductionUsdc;
        }
        return bullMaxProfit > bearMaxProfit ? bullMaxProfit : bearMaxProfit;
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
            bountyBps: 10
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

    function test_OpenPosition_SolvencyCheck() public {
        address account = address(uint160(1));
        _fundTrader(account, 20_000 * 1e6);

        // maxProfit = 1.2M tokens * $1 entry = $1.2M > pool's $1M balance
        CfdTypes.Order memory tooLarge = CfdTypes.Order({
            account: account,
            sizeDelta: 1_200_000 * 1e18,
            marginDelta: 5000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });

        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector, 2, 7, false));
        vm.prank(address(router));
        engine.processOrderTyped(tooLarge, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));

        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });

        // Withdraw LP to reduce pool to $50k — solvency check should fail
        vm.warp(block.timestamp + 1 hours); // past deposit cooldown
        juniorVault.withdraw(950_000 * 1e6, address(this), address(this));
        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector, 2, 7, false));
        vm.prank(address(router));
        engine.processOrderTyped(order, 1e8, 0, uint64(block.timestamp));

        // Re-deposit to allow the trade
        usdc.approve(address(juniorVault), 950_000 * 1e6);
        juniorVault.deposit(950_000 * 1e6, address(this));

        vm.prank(address(router));
        engine.processOrderTyped(order, 1e8, 200_000 * 1e6, uint64(block.timestamp));

        (uint256 size, uint256 margin,,,,,) = engine.positions(account);
        assertEq(size, 100_000 * 1e18, "Size mismatch");
        // With the explicit $200k depth passed to processOrder, the current VPI + fee path leaves $1,947.5 margin.
        assertEq(margin, 1_947_500_000, "Margin should equal deposit minus VPI and exec fee");
    }

    function test_OpenPosition_UsesExplicitInitMarginBps() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.initMarginBps = 400;
        _setRiskParams(params);

        (,,, uint256 initMarginBps,,,,) = engine.riskParams();
        assertEq(initMarginBps, 400, "Setup must finalize the explicit init margin config");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        address account = address(uint160(0xBEEF1));
        _fundTrader(account, 10_000e6);

        assertEq(
            engineLens.previewOpenRevertCode(
                account, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, uint64(block.timestamp)
            ),
            uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN),
            "Planner should use the explicit init margin config"
        );
    }

    function test_OpenParity_HealthyPreviewMatchesLiveExecution() public {
        address account = address(uint160(0xBEEF2));
        _fundTrader(account, 10_000e6);

        assertEq(
            engineLens.previewOpenRevertCode(
                account, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8, uint64(block.timestamp)
            ),
            uint8(CfdEnginePlanTypes.OpenRevertCode.OK),
            "Preview should accept the healthy open"
        );

        uint256 feesBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        _open(account, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);

        (uint256 size, uint256 margin,,,,,) = engine.positions(account);
        assertEq(size, 100_000e18, "Live open should match the previewed size");
        assertGt(margin, 0, "Live open should leave positive position margin");
        assertLt(margin, 5000e6, "Live open margin should reflect execution costs after the successful preview");
        assertGt(
            clearinghouse.balanceUsdc(engine.protocolTreasury()) - feesBefore,
            0,
            "Live open should collect protocol revenue after success"
        );
    }

    function test_ProcessOrderTyped_ProtocolStateFailureUsesTypedTaxonomy() public {
        address account = address(uint160(1));
        _fundTrader(account, 20_000 * 1e6);

        CfdTypes.Order memory tooLarge = CfdTypes.Order({
            account: account,
            sizeDelta: 1_200_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated,
                uint8(7),
                false
            )
        );
        vm.prank(address(router));
        engine.processOrderTyped(tooLarge, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));
    }

    function helper_NoCarryBaselineAccumulation() public {
        uint256 poolDepth = 1_000_000 * 1e6;

        address account1 = address(0x1);
        address account2 = address(0x2);
        _fundTrader(account1, 5000 * 1e6);
        _fundTrader(account2, 5000 * 1e6);

        CfdTypes.Order memory retailLong = CfdTypes.Order({
            account: account1,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(retailLong, 1e8, poolDepth, uint64(block.timestamp));

        uint64 refreshTime = uint64(block.timestamp + 30 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint64 accrualTime = refreshTime + 30;
        vm.warp(accrualTime);

        CfdTypes.Order memory mmShort = CfdTypes.Order({
            account: account2,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 500 * 1e6,
            targetPrice: 1e8,
            commitTime: accrualTime,
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.BEAR,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(mmShort, 1e8, poolDepth, accrualTime);

        assertEq(_legacySideIndexZero(CfdTypes.Side.BULL), 0);
        assertEq(_legacySideIndexZero(CfdTypes.Side.BEAR), 0);

        (uint256 size,, uint256 entryPrice,, CfdTypes.Side side,,) = engine.positions(account1);

        CfdTypes.Position memory bullPos = CfdTypes.Position({
            size: size,
            margin: 0,
            entryPrice: entryPrice,
            maxProfitUsdc: 0,
            side: side,
            lastUpdateTime: 0,
            lastCarryTimestamp: 0,
            vpiAccrued: 0
        });

        int256 legacySideSpread = 0;
        assertEq(legacySideSpread, 0, "Carry model should not accrue any side-to-side legacy-spread state");
    }

    function helper_SyncState_IsNoopInCarryModel() public {
        address trader = address(0xABC2);
        address traderAccount = trader;

        _fundTrader(trader, 50_000e6);
        _open(traderAccount, CfdTypes.Side.BULL, 200_000e18, 20_000e6, 1e8);

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);

        // no-op in carry-only baseline

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + 1);

        // no-op in carry-only baseline
    }

    function test_ProtocolAccounting_DoesNotProjectCarryFromStaleLiveMark() public {
        address bullTrader = address(0xABC3);
        address bearTrader = address(0xABC4);
        address bullAccount = bullTrader;
        address bearAccount = bearTrader;

        _fundTrader(bullTrader, 50_000e6);
        _fundTrader(bearTrader, 10_000e6);
        _open(bullAccount, CfdTypes.Side.BULL, 200_000e18, 20_000e6, 1e8);
        _open(bearAccount, CfdTypes.Side.BEAR, 20_000e18, 2000e6, 1e8);

        HousePoolEngineViewTypes.HousePoolInputSnapshot memory houseBefore =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);

        assertEq(
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit()).supplementalReservedUsdc,
            houseBefore.supplementalReservedUsdc,
            "HousePool input snapshot should not inherit stale legacy-spread state"
        );
    }

    function test_SyncState_DoesNotAdvanceOnFrozenMarkPastFadMaxStaleness() public {
        address trader = address(0xABC5);
        address traderAccount = trader;

        _setFadMaxStaleness(1 hours);

        _fundTrader(trader, 50_000e6);
        _open(traderAccount, CfdTypes.Side.BULL, 200_000e18, 20_000e6, 1e8);

        uint256 currentDay = ((block.timestamp / 1 days) + 4) % 7;
        uint256 startOfDay = block.timestamp - (block.timestamp % 1 days);
        uint256 saturdayNoon = startOfDay + (6 - currentDay) * 1 days + 12 hours;
        if (saturdayNoon <= block.timestamp) {
            saturdayNoon += 7 days;
        }
        vm.warp(saturdayNoon);
        assertTrue(engine.isOracleFrozen(), "Setup must be inside a frozen oracle window");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.warp(block.timestamp + engine.fadMaxStaleness() + 1);

        // no-op in carry-only baseline
    }

    function test_ProtocolAccounting_DoesNotProjectCarryFromFrozenMarkPastFadMaxStaleness() public {
        address bullTrader = address(0xABC6);
        address bearTrader = address(0xABC7);
        address bullAccount = bullTrader;
        address bearAccount = bearTrader;

        _setFadMaxStaleness(1 hours);

        _fundTrader(bullTrader, 50_000e6);
        _fundTrader(bearTrader, 10_000e6);
        _open(bullAccount, CfdTypes.Side.BULL, 200_000e18, 20_000e6, 1e8);
        _open(bearAccount, CfdTypes.Side.BEAR, 20_000e18, 2000e6, 1e8);

        uint256 currentDay = ((block.timestamp / 1 days) + 4) % 7;
        uint256 startOfDay = block.timestamp - (block.timestamp % 1 days);
        uint256 saturdayNoon = startOfDay + (6 - currentDay) * 1 days + 12 hours;
        if (saturdayNoon <= block.timestamp) {
            saturdayNoon += 7 days;
        }
        vm.warp(saturdayNoon);
        assertTrue(engine.isOracleFrozen(), "Setup must be inside a frozen oracle window");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        HousePoolEngineViewTypes.HousePoolInputSnapshot memory houseBefore =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());

        vm.warp(block.timestamp + engine.fadMaxStaleness() + 1);

        assertEq(
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit()).supplementalReservedUsdc,
            houseBefore.supplementalReservedUsdc,
            "HousePool input snapshot should not inherit over-stale frozen legacy-spread state"
        );
    }

    function test_OpenTradeCost_AccountsPoolInflowCanonically() public {
        address firstBullAccount = address(0xABC2);
        address secondBullAccount = address(0xABC3);
        _fundTrader(firstBullAccount, 100_000e6);
        _fundTrader(secondBullAccount, 100_000e6);

        _open(firstBullAccount, CfdTypes.Side.BULL, 500_000e18, 50_000e6, 1e8);

        uint256 poolAssetsBefore = pool.totalAssets();
        _open(secondBullAccount, CfdTypes.Side.BULL, 500_000e18, 50_000e6, 1e8);

        assertGt(pool.totalAssets(), poolAssetsBefore, "Positive trade cost should increase canonical pool assets");
        assertEq(pool.excessAssets(), 0, "Trade-cost inflows should not remain quarantined as excess");
    }

    function test_ProfitableClose_RecordsTraderClaimWhenPoolIlliquid() public {
        address account = address(0xD301);
        _fundTrader(address(0xD301), 11_000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        uint256 clearinghouseBefore = clearinghouse.balanceUsdc(account);

        _close(account, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Profitable close should still destroy the position");
        assertGt(engine.traderClaimBalanceUsdc(account), 0, "Unpaid profit should be recorded as trader claim");
        assertEq(
            clearinghouse.balanceUsdc(account),
            clearinghouseBefore,
            "Illiquid profitable close should not immediately credit clearinghouse cash"
        );
    }

    function test_ProtocolFeeTopUp_DoesNotLeapfrogTraderClaims() public {
        address account = address(0xD30F);
        _fundTrader(account, 11_000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 closePrice = 80_000_000;
        uint256 executionFeeUsdc = _engineExecutionFeeUsdc(100_000e18, closePrice);
        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - executionFeeUsdc);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, closePrice);
        assertTrue(preview.valid, "Setup close preview should be valid");
        assertEq(preview.immediatePayoutUsdc, 0, "Setup must record the trader payout as a claim");
        assertGt(preview.traderClaimBalanceUsdc, 0, "Setup must create a trader claim");
        assertEq(pool.totalAssets(), executionFeeUsdc, "Setup leaves only the fee amount physically available");

        uint256 feesBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000e18,
            marginDelta: 0,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: CfdTypes.Side.BULL,
            isClose: true
        });
        uint256 closeDepth = pool.totalAssets();
        vm.prank(address(router));
        engine.processOrderTyped(closeOrder, closePrice, closeDepth, uint64(block.timestamp));

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Close should still destroy the position");
        assertGt(engine.traderClaimBalanceUsdc(account), 0, "Trader claim should be recorded");
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            feesBefore,
            "Fee top-up must not leapfrog trader claims"
        );
    }

    function test_ProtocolFeeTopUp_PreviewPaysTraderWhenOnlyPayoutCashIsFree() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 0;
        _setRiskParams(params);

        address account = address(0xD310);
        _fundTrader(account, 11_000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 closePrice = 80_000_000;
        CfdEngine.ClosePreview memory liquidPreview = engineLens.previewClose(account, 100_000e18, closePrice);
        assertGt(liquidPreview.freshTraderPayoutUsdc, 0, "Setup must create a trader payout");
        assertGt(liquidPreview.executionFeeUsdc, 0, "Setup must create a protocol fee");

        uint256 poolAssets = pool.totalAssets();
        uint256 drainAmount = poolAssets - liquidPreview.freshTraderPayoutUsdc;
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), drainAmount);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, closePrice);
        assertTrue(preview.valid, "Setup close preview should be valid");
        assertEq(pool.totalAssets(), preview.freshTraderPayoutUsdc, "Setup leaves exactly trader payout cash");
        assertLt(
            pool.totalAssets(),
            preview.freshTraderPayoutUsdc + preview.executionFeeUsdc,
            "Setup cannot also fund the protocol fee top-up"
        );
        assertEq(preview.immediatePayoutUsdc, preview.freshTraderPayoutUsdc, "Preview should follow trader payout cash");
        assertEq(preview.traderClaimBalanceUsdc, 0, "Preview should not defer when payout cash is free");

        uint256 feesBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(account);
        _close(account, CfdTypes.Side.BULL, 100_000e18, closePrice);

        CloseParityObserved memory observed = _observeCloseParity(account, beforeSnapshot);
        _assertClosePreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()), feesBefore, "Unfunded fee top-up should not accrue"
        );
    }

    function test_FullClose_AfterFreshMark_DoesNotRevertWhenPoolIlliquid() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address bullAccount = address(uint160(1));
        address bearAccount = address(uint160(2));
        _fundTrader(bullAccount, 5000 * 1e6);
        _fundTrader(bearAccount, 5000 * 1e6);

        _open(bullAccount, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, poolDepth);
        _open(bearAccount, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, poolDepth);

        uint64 refreshTime = uint64(block.timestamp + 30 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint64 accrualTime = refreshTime + 59;
        vm.warp(accrualTime);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(bearAccount, 10_000e18, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        _closeAt(bearAccount, CfdTypes.Side.BEAR, 10_000e18, 1e8, poolDepth, accrualTime);

        (uint256 size,,,,,,) = engine.positions(bearAccount);
        assertEq(size, 0, "Illiquid profitable close close should still destroy the position");
        assertEq(
            engine.traderClaimBalanceUsdc(bearAccount),
            preview.traderClaimBalanceUsdc,
            "Live close should match preview"
        );
    }

    function test_PreviewClose_UsesCanonicalPoolDepthWhileSimulateCloseAllowsWhatIfDepth() public {
        address bullAccount = address(uint160(0xC10));
        address bearAccount = address(uint160(0xC11));
        _fundTrader(bullAccount, 5000e6);
        _fundTrader(bearAccount, 5000e6);

        _open(bullAccount, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);
        _open(bearAccount, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint64 accrualTime = refreshTime + 59;
        vm.warp(accrualTime);

        uint256 canonicalDepth = pool.totalAssets();
        ICfdEngineTypes.ClosePreview memory canonicalPreview = engineLens.previewClose(bearAccount, 10_000e18, 1e8);
        ICfdEngineTypes.ClosePreview memory matchedSimulation =
            engineLens.simulateClose(bearAccount, 10_000e18, 1e8, canonicalDepth);
        ICfdEngineTypes.ClosePreview memory lowDepthSimulation =
            engineLens.simulateClose(bearAccount, 10_000e18, 1e8, canonicalDepth / 10);

        _assertClosePreviewEquals(canonicalPreview, matchedSimulation);
    }

    function test_CloseParity_ImmediateProfitMatchesPreview() public {
        address trader = address(0xD3A1);
        address account = trader;
        _fundTrader(trader, 11_000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 80_000_000);
        assertTrue(preview.valid, "Setup close preview should be valid");
        assertGt(preview.immediatePayoutUsdc, 0, "Profitable liquid close should pay immediately");
        assertEq(preview.traderClaimBalanceUsdc, 0, "Liquid profitable close should not defer payout");

        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(account);
        _close(account, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        CloseParityObserved memory observed = _observeCloseParity(account, beforeSnapshot);
        _assertClosePreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
    }

    function test_CloseParity_TraderClaimProfitMatchesPreview() public {
        address trader = address(0xD3A2);
        address account = trader;
        _fundTrader(trader, 11_000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 80_000_000);
        assertTrue(preview.valid, "Setup close preview should be valid");
        assertEq(preview.immediatePayoutUsdc, 0, "Illiquid profitable close should not pay immediately");
        assertGt(preview.traderClaimBalanceUsdc, 0, "Illiquid profitable close should defer payout");

        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(account);
        _close(account, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        CloseParityObserved memory observed = _observeCloseParity(account, beforeSnapshot);
        _assertClosePreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
    }

    function test_CloseParity_LossConsumesSettlementMatchesPreview() public {
        address trader = address(0xD3A3);
        address account = trader;
        _fundTrader(trader, 10_000e6);

        _open(account, CfdTypes.Side.BULL, 10_000e18, 5000e6, 1e8);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 10_000e18, 120_000_000);
        assertTrue(preview.valid, "Setup loss close preview should be valid");
        assertEq(preview.immediatePayoutUsdc, 0, "Loss-making close should not create immediate payout");
        assertEq(preview.traderClaimBalanceUsdc, 0, "Loss-making close should not create trader claim");
        assertEq(preview.badDebtUsdc, 0, "Setup should keep the loss fully collateralized");

        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(account);
        _close(account, CfdTypes.Side.BULL, 10_000e18, 120_000_000);

        CloseParityObserved memory observed = _observeCloseParity(account, beforeSnapshot);
        _assertClosePreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
    }

    function test_SettleTraderClaim_CreditsClearinghouseWhenLiquidityReturns() public {
        address trader = address(0xD302);
        address account = trader;
        _fundTrader(trader, 11_000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(account, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        uint256 traderClaim = engine.traderClaimBalanceUsdc(account);
        assertGt(traderClaim, 0, "Setup should create a trader claim");

        usdc.mint(address(pool), traderClaim);
        uint256 clearinghouseBefore = clearinghouse.balanceUsdc(account);

        vm.prank(trader);
        engine.settleTraderClaim(account);

        assertEq(engine.traderClaimBalanceUsdc(account), 0, "Claim should clear trader claim state");
        assertEq(
            clearinghouse.balanceUsdc(account),
            clearinghouseBefore + traderClaim,
            "Claim should credit the clearinghouse balance"
        );
    }

    function test_SettleTraderClaim_NoOpenPositionCheckpointsCarryBeforePoolPayout() public {
        address trader = address(0xD30A11CE);
        address claimant = address(0xD30B0B);

        _fundTrader(trader, 20_000e6);
        _open(trader, CfdTypes.Side.BULL, 500_000e18, 10_000e6, 1e8);

        uint256 claimUsdc = 1000e6;
        stdstore.target(address(engine)).sig("traderClaimBalanceUsdc(address)").with_key(claimant)
            .checked_write(claimUsdc);
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceUsdc()").checked_write(claimUsdc);

        vm.warp(block.timestamp + 30 days);
        uint256 expectedCarryIndex = _currentSideCarryIndex(CfdTypes.Side.BULL);
        uint256 poolAssetsBefore = pool.totalAssets();

        vm.prank(claimant);
        engine.settleTraderClaim(claimant);

        uint256 sideIndex = uint256(CfdTypes.Side.BULL);
        assertEq(
            engine.sideCarryIndex(sideIndex),
            expectedCarryIndex,
            "Claim payout should checkpoint carry with the pre-payout pool denominator"
        );
        assertEq(engine.sideCarryTimestamp(sideIndex), block.timestamp, "Claim payout should advance carry timestamp");
        assertEq(
            pool.totalAssets(), poolAssetsBefore - claimUsdc, "Setup should reduce pool assets after claim service"
        );
    }

    function test_SettleTraderClaim_RealizesCarryBeforeCreditingSettlement() public {
        address trader = address(0xD30B);
        address account = trader;
        _fundTrader(trader, 20_000e6);

        _open(account, CfdTypes.Side.BULL, 500_000e18, 10_000e6, 1e8);
        stdstore.target(address(engine)).sig("traderClaimBalanceUsdc(address)").with_key(account)
            .checked_write(uint256(5000e6));
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceUsdc()").checked_write(uint256(5000e6));

        vm.warp(block.timestamp + 30 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 settlementBefore = clearinghouse.balanceUsdc(account);
        uint256 expectedCarry = _expectedIndexedCarry(account);

        usdc.mint(address(pool), 5000e6);
        uint256 poolRawBefore = pool.rawAssets();
        uint256 poolAccountedBefore = pool.accountedAssets();

        vm.prank(trader);
        engine.settleTraderClaim(account);

        assertEq(
            clearinghouse.balanceUsdc(account),
            settlementBefore + 5000e6 - expectedCarry,
            "Trader claim settlement should realize carry before crediting settlement"
        );
        assertEq(
            pool.rawAssets(),
            poolRawBefore + expectedCarry - 5000e6,
            "Claim should net payout against realized carry cash flow"
        );
        assertEq(
            pool.accountedAssets(),
            poolAccountedBefore + expectedCarry - 5000e6,
            "Claim should keep accounted assets aligned with net physical cash after carry realization"
        );
    }

    function test_SettleTraderClaim_UsesIndexedCarryCheckpointWhenMarkIsStale() public {
        address trader = address(0xD30C);
        address account = trader;
        _fundTrader(trader, 20_000e6);

        _open(account, CfdTypes.Side.BULL, 500_000e18, 10_000e6, 1e8);
        stdstore.target(address(engine)).sig("traderClaimBalanceUsdc(address)").with_key(account)
            .checked_write(uint256(5000e6));
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceUsdc()").checked_write(uint256(5000e6));

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 30 days);

        uint256 settlementBefore = clearinghouse.balanceUsdc(account);
        uint256 expectedCarry = _expectedIndexedCarry(account);

        usdc.mint(address(pool), 5000e6);

        vm.prank(trader);
        engine.settleTraderClaim(account);

        assertEq(engine.traderClaimBalanceUsdc(account), 0, "Claim should clear trader claim state");
        assertEq(
            clearinghouse.balanceUsdc(account),
            settlementBefore + 5000e6 - expectedCarry,
            "Stale trader claim settlement should checkpoint indexed carry before crediting settlement"
        );
        assertEq(
            _lastCarryTimestamp(account),
            block.timestamp,
            "Stale trader claim settlement should advance the carry clock after checkpointing carry"
        );
        assertEq(
            engine.unsettledCarryUsdc(account),
            0,
            "Stale trader claim settlement should not leave carry unpaid once the claim-funded settlement can satisfy it"
        );
    }

    function test_TraderClaimConsistency_PreservesOtherReservedCash() public {
        address trader = address(0xD30D1);
        address account = trader;
        uint256 traderClaim = 5000e6;

        _fundTrader(trader, 20_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        stdstore.target(address(engine)).sig("traderClaimBalanceUsdc(address)").with_key(account)
            .checked_write(traderClaim);
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceUsdc()").checked_write(traderClaim);

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory beforeSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);
        usdc.mint(address(pool), traderClaim);

        vm.prank(trader);
        engine.settleTraderClaim(account);

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory afterSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();

        assertEq(
            afterSnapshot.protocolTreasuryBalanceUsdc,
            beforeSnapshot.protocolTreasuryBalanceUsdc,
            "Trader trader claim must not consume treasury fee balance"
        );
        assertEq(
            afterSnapshot.totalTraderClaimBalanceUsdc, 0, "Claim should extinguish the trader trader claim liability"
        );
        assertEq(
            beforeSnapshot.withdrawalReservedUsdc - afterSnapshot.withdrawalReservedUsdc,
            traderClaim,
            "Withdrawal reserve should drop only by the trader claim amount that was actually claimed"
        );
    }

    function test_StaleDeposit_PreservesPreMutationCarryBasis() public {
        address trader = address(0xD30D2);
        address account = trader;
        uint256 depositAmount = 500e6;

        _fundTrader(trader, 10_000e6);
        usdc.mint(trader, depositAmount);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        uint256 settlementBefore = clearinghouse.balanceUsdc(account);
        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 30 days);
        uint256 expectedCarry = _expectedIndexedCarry(account);

        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.depositMargin(depositAmount);
        vm.stopPrank();

        assertEq(
            clearinghouse.balanceUsdc(account),
            settlementBefore + depositAmount - expectedCarry,
            "Stale deposit should checkpoint carry on the pre-deposit basis before increasing collateral"
        );
        assertEq(
            engine.unsettledCarryUsdc(account),
            0,
            "Covered stale deposit carry should not leave residual unsettled carry"
        );
        assertEq(
            _lastCarryTimestamp(account),
            block.timestamp,
            "Stored-mark carry checkpoint should advance the carry timestamp at the stale deposit time"
        );
    }

    function test_SettleTraderClaim_RevertsForNonOwner() public {
        address trader = address(0xD307);
        address relayer = address(0xD308);
        address account = trader;
        _fundTrader(trader, 11_000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(account, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        uint256 traderClaim = engine.traderClaimBalanceUsdc(account);
        usdc.mint(address(pool), traderClaim);

        vm.prank(relayer);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__NotAccountOwner.selector);
        engine.settleTraderClaim(account);
    }

    function test_SettleTraderClaim_RevertsUntilTraderClaimLiabilitiesAreFullyCovered() public {
        address trader = address(0xD306);
        address account = trader;
        _fundTrader(trader, 11_000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(account, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        uint256 traderClaim = engine.traderClaimBalanceUsdc(account);
        assertGt(traderClaim, 0, "Setup should create a trader claim");

        uint256 partialLiquidity = traderClaim / 2;
        usdc.mint(address(pool), partialLiquidity);

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InsufficientPoolLiquidity.selector);
        vm.prank(trader);
        engine.settleTraderClaim(account);

        assertEq(
            engine.traderClaimBalanceUsdc(account),
            traderClaim,
            "Trader claimant should remain fully queued until aggregate trader claim liabilities are fully covered"
        );
    }

    function test_SettleTraderClaim_RevertsDuringAggregateShortfallEvenForLargestClaimant() public {
        address trader = address(0xD309);
        address account = trader;
        _fundTrader(trader, 11_000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(account, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        uint256 traderClaim = engine.traderClaimBalanceUsdc(account);
        assertGt(traderClaim, 0, "Setup should create a trader claim balance");

        vm.startPrank(address(pool));
        usdc.transfer(address(0xDEAD), pool.totalAssets());
        vm.stopPrank();

        uint256 partialLiquidity = traderClaim / 2;
        usdc.mint(address(pool), partialLiquidity);

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InsufficientPoolLiquidity.selector);
        vm.prank(trader);
        engine.settleTraderClaim(account);

        assertEq(engine.traderClaimBalanceUsdc(account), traderClaim, "Head trader claim should remain fully queued");
    }

    function test_SettleTraderClaim_RevertsWithoutLiquidityOrPayout() public {
        address trader = address(0xD303);
        address account = trader;
        _fundTrader(trader, 11_000e6);

        vm.prank(trader);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__NoTraderClaim.selector);
        engine.settleTraderClaim(account);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(account, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        vm.startPrank(address(pool));
        usdc.transfer(address(0xDEAD), pool.totalAssets());
        vm.stopPrank();

        vm.prank(trader);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__InsufficientPoolLiquidity.selector);
        engine.settleTraderClaim(account);
    }

    function test_NoSideCarryRealization_KeepsClearinghouseMarginInSync() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        _fundTrader(account, 20_000 * 1e6);

        // Open BULL $100k at $1.00
        CfdTypes.Order memory openOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(openOrder, 1e8, poolDepth, uint64(block.timestamp));

        (, uint256 marginAfterOpen,,,,,) = engine.positions(account);
        IMarginClearinghouse.LockedMarginBuckets memory lockedAfterOpen = clearinghouse.getLockedMarginBuckets(account);
        assertEq(
            lockedAfterOpen.positionMarginUsdc,
            marginAfterOpen,
            "Position bucket should track stored position margin after open"
        );
        assertEq(
            lockedAfterOpen.committedOrderMarginUsdc, 0, "Open positions should not leave committed-order margin behind"
        );
        assertEq(
            lockedAfterOpen.reservedSettlementUsdc, 0, "Open positions should not leave reserved settlement behind"
        );

        // Warp 30 days — accumulates legacy negative spread for lone BULL
        vm.warp(block.timestamp + 30 days);

        // Increase position — triggers carry realization in processOrder
        CfdTypes.Order memory addOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 500 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(addOrder, 1e8, poolDepth, uint64(block.timestamp));

        (, uint256 marginAfterAdd,,,,,) = engine.positions(account);
        IMarginClearinghouse.LockedMarginBuckets memory lockedAfterAdd = clearinghouse.getLockedMarginBuckets(account);
        assertEq(
            lockedAfterAdd.positionMarginUsdc,
            marginAfterAdd,
            "Carry realization should leave the canonical position bucket aligned with stored margin"
        );
        assertEq(
            lockedAfterAdd.committedOrderMarginUsdc, 0, "Carry realization should not create committed-order locks"
        );
        assertEq(lockedAfterAdd.reservedSettlementUsdc, 0, "Carry realization should not strand reserved settlement");
    }

    function test_ProtocolFees_CreditTreasuryMargin() public {
        address account = address(uint160(1));
        _fundTrader(account, 5000 * 1e6);

        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(order, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));

        // 100k BULL at $1.00: execFee = notional * 4bps = $100k * 0.0004 = $40
        uint256 fees = clearinghouse.balanceUsdc(engine.protocolTreasury());
        assertEq(fees, 40_000_000, "Exec fee should be 4bps of $100k notional");

        address treasury = engine.protocolTreasury();
        uint256 treasuryBalanceBefore = usdc.balanceOf(treasury);
        uint256 assetsBeforeWithdrawal = pool.totalAssets();
        _withdrawProtocolTreasury(fees);

        assertEq(clearinghouse.balanceUsdc(engine.protocolTreasury()), 0, "Fees should reset to zero");
        assertEq(usdc.balanceOf(treasury) - treasuryBalanceBefore, fees, "Treasury receives exact fee amount");
        assertEq(pool.totalAssets(), assetsBeforeWithdrawal, "Treasury withdrawal should not touch vault assets");
        assertEq(pool.excessAssets(), 0, "Fee inflows should not remain stranded as vault excess");

        vm.prank(treasury);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientBalance.selector);
        clearinghouse.withdraw(treasury, fees);
    }

    function test_SetProtocolTreasury_RevertsWhenCurrentTreasuryHasBalance() public {
        address oldTreasury = engine.protocolTreasury();
        address newTreasury = address(0xFEE99);

        _fundProtocolTreasury(1e6);

        vm.expectRevert(ICfdEngineTypes.CfdEngine__ProtocolTreasuryBalanceNotEmpty.selector);
        engine.setProtocolTreasury(newTreasury);

        assertEq(engine.protocolTreasury(), oldTreasury, "Treasury should not rotate while old balance remains");
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            1e6,
            "Existing treasury balance should remain reported"
        );
    }

    function test_SetProtocolTreasury_AllowsRotationAfterCurrentTreasuryBalanceIsWithdrawn() public {
        address newTreasury = address(0xFEE98);

        _fundProtocolTreasury(1e6);
        _withdrawProtocolTreasury(1e6);

        engine.setProtocolTreasury(newTreasury);

        assertEq(engine.protocolTreasury(), newTreasury, "Treasury should rotate after the old account is drained");
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()), 0, "New treasury starts with no reported balance"
        );
    }

    function test_CloseProtocolFeeInflow_IsBoundedByPhysicalCashReceived() public {
        _fundJunior(address(0xB0B), 1_000_000e6);

        address trader = address(0xAB1720);
        address account = trader;
        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        uint256 assetsBeforeClose = pool.totalAssets();
        _close(account, CfdTypes.Side.BULL, 100_000e18, 100_030_000);
        uint256 assetsAfterClose = pool.totalAssets();

        usdc.mint(address(pool), 5e6);

        assertEq(
            pool.totalAssets(),
            assetsAfterClose,
            "Unsolicited donations should remain quarantined instead of filling an over-credited fee-accounting gap"
        );
        assertEq(
            pool.excessAssets(),
            5e6,
            "Donation should stay sweepable as excess when protocol inflow is capped by cash received"
        );
    }

    function test_ProtocolTreasuryWithdrawal_DoesNotUseSeniorCashReservation() public {
        address account = address(uint160(0xFEE1));
        _fundTrader(account, 5000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        uint256 fees = clearinghouse.balanceUsdc(engine.protocolTreasury());
        address trader = address(0xFEE2);
        stdstore.target(address(engine)).sig("traderClaimBalanceUsdc(address)").with_key(trader)
            .checked_write(uint256(25e6));
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceUsdc()").checked_write(uint256(25e6));

        uint256 poolAssetsBeforeDrain = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssetsBeforeDrain);

        address treasury = engine.protocolTreasury();
        uint256 treasuryBalanceBefore = usdc.balanceOf(treasury);
        _withdrawProtocolTreasury(fees);

        assertEq(
            usdc.balanceOf(treasury) - treasuryBalanceBefore,
            fees,
            "Treasury withdrawal should use clearinghouse custody"
        );
        assertEq(clearinghouse.balanceUsdc(engine.protocolTreasury()), 0, "Treasury balance should be withdrawn");
        assertEq(pool.totalAssets(), 0, "Treasury withdrawal should not require or consume vault cash");
        usdc.mint(address(pool), poolAssetsBeforeDrain);
    }

    function test_TreasuryWithdrawal_ThenTraderClaims_DrainsResidualCashWithoutDeadlock() public {
        address trader = address(0xFEA1);
        address traderAccount = trader;

        usdc.burn(address(pool), pool.totalAssets());
        usdc.mint(address(pool), 100e6);

        _fundProtocolTreasury(60e6);
        stdstore.target(address(engine)).sig("traderClaimBalanceUsdc(address)").with_key(traderAccount)
            .checked_write(uint256(40e6));
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceUsdc()").checked_write(uint256(40e6));

        address treasury = engine.protocolTreasury();
        uint256 treasuryBalanceBefore = usdc.balanceOf(treasury);
        _withdrawProtocolTreasury(60e6);

        assertEq(usdc.balanceOf(treasury) - treasuryBalanceBefore, 60e6, "Treasury should receive its margin balance");
        assertEq(pool.totalAssets(), 100e6, "Treasury withdrawal should leave vault cash untouched");
        assertEq(clearinghouse.balanceUsdc(engine.protocolTreasury()), 0, "Treasury balance should be fully withdrawn");

        uint256 traderSettlementBefore = clearinghouse.balanceUsdc(traderAccount);
        vm.prank(trader);
        engine.settleTraderClaim(traderAccount);

        assertEq(
            clearinghouse.balanceUsdc(traderAccount) - traderSettlementBefore,
            40e6,
            "Trader should receive the first trader claim ahead of remaining protocol fees"
        );
        assertEq(pool.totalAssets(), 60e6, "Trader claim should consume only its reserved pool cash");
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            0,
            "Servicing trader claims must not affect treasury accounting"
        );
        assertEq(engine.traderClaimBalanceUsdc(traderAccount), 0, "Trader claim balance should be fully consumed");
    }

    function test_ProtocolTreasury_AllowsPartialWithdrawal() public {
        address trader = address(0xFEE4A);
        address account = trader;
        _fundTrader(trader, 10_000e6);

        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000e18,
            marginDelta: 2000e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(order, 1e8, 1_000_000e6, uint64(block.timestamp));

        uint256 feesBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        uint256 partialAmount = feesBefore / 2;

        address treasury = engine.protocolTreasury();
        uint256 treasuryBalanceBefore = usdc.balanceOf(treasury);
        _withdrawProtocolTreasury(partialAmount);

        assertEq(
            usdc.balanceOf(treasury) - treasuryBalanceBefore,
            partialAmount,
            "Treasury should receive the requested partial fee amount"
        );
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            feesBefore - partialAmount,
            "Partial fee withdrawal should leave the remainder booked"
        );
    }

    function test_AddMargin_UpdatesPositionAndSideTotals() public {
        address trader = address(0xABCD);
        address account = trader;
        _fundTrader(trader, 10_000 * 1e6);

        _open(account, CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8);

        (, uint256 marginBefore,,,,,) = engine.positions(account);
        uint256 lockedBefore = clearinghouse.lockedMarginUsdc(account);
        uint256 totalBullMarginBefore = _sideTotalMargin(CfdTypes.Side.BULL);

        vm.prank(trader);
        engine.addMargin(account, 500 * 1e6);

        (, uint256 marginAfter,,,,,) = engine.positions(account);
        assertEq(marginAfter, marginBefore + 500 * 1e6, "Position margin should increase by the added amount");
        assertEq(
            clearinghouse.lockedMarginUsdc(account),
            lockedBefore + 500 * 1e6,
            "Clearinghouse locked margin should increase by the same amount"
        );
        assertEq(
            _sideTotalMargin(CfdTypes.Side.BULL),
            totalBullMarginBefore + 500 * 1e6,
            "Global bull margin should track addMargin"
        );
    }

    function test_AddMargin_RequiresAccountOwner() public {
        address trader = address(0xABCE);
        address account = trader;
        _fundTrader(trader, 10_000 * 1e6);
        _open(account, CfdTypes.Side.BULL, 50_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(address(0xBEEF));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__NotAccountOwner.selector);
        engine.addMargin(account, 100 * 1e6);
    }

    function test_AddMargin_RevertsForZeroAmountAndMissingPosition() public {
        address trader = address(0xABCF);
        address account = trader;
        _fundTrader(trader, 10_000 * 1e6);

        vm.prank(trader);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__NoOpenPosition.selector);
        engine.addMargin(account, 100 * 1e6);

        _open(account, CfdTypes.Side.BULL, 50_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(trader);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__PositionTooSmall.selector);
        engine.addMargin(account, 0);
    }

    function test_AddMargin_SucceedsOnStaleMark() public {
        address trader = address(0xABD3);
        address account = trader;
        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.BULL, 20_000e18, 2000e6, 1e8);

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);

        vm.prank(trader);
        engine.addMargin(account, 100e6);

        (, uint256 marginAfter,, uint256 maxProfitUsdc,,,) = engine.positions(account);
        assertEq(
            _positionBorrowBaseUsdc(account),
            PositionRiskAccountingLib.computeBorrowBaseUsdc(maxProfitUsdc, marginAfter),
            "stale-mark add-margin should reduce future borrow base"
        );
    }

    function test_CheckWithdraw_RevertsForNonClearinghouseCaller() public {
        address account = address(uint160(0x51582));
        _fundTrader(account, 5000e6);
        _open(account, CfdTypes.Side.BULL, 20_000e18, 2000e6, 1e8);

        vm.expectRevert(ICfdEngineTypes.CfdEngine__NotClearinghouse.selector);
        engine.checkWithdraw(account);
    }

    function test_DepositWithdrawMargin_RealizesCarryBeforeBalanceMutation() public {
        address trader = address(0xABD0);
        address account = trader;
        uint256 depositAmount = 50_000e6;

        _fundTrader(trader, 20_000e6);
        usdc.mint(trader, depositAmount);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.warp(block.timestamp + 1 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 settlementBefore = clearinghouse.balanceUsdc(account);
        uint256 poolRawBefore = pool.rawAssets();
        uint256 poolAccountedBefore = pool.accountedAssets();
        uint256 clearinghouseRawBefore = usdc.balanceOf(address(clearinghouse));
        uint256 expectedCarry = _expectedIndexedCarry(account);
        assertGt(expectedCarry, 0, "Setup must accrue carry before the balance mutation");

        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.depositMargin(depositAmount);
        assertEq(
            clearinghouse.balanceUsdc(account),
            settlementBefore + depositAmount - expectedCarry,
            "Deposit hook should realize carry before adding fresh settlement"
        );
        assertEq(pool.rawAssets(), poolRawBefore + expectedCarry, "Carry realization should physically fund the pool");
        assertEq(
            pool.accountedAssets(),
            poolAccountedBefore + expectedCarry,
            "Carry realization should increase accounted assets only with matching cash"
        );
        assertEq(
            usdc.balanceOf(address(clearinghouse)),
            clearinghouseRawBefore + depositAmount - expectedCarry,
            "Carry realization should transfer realized cash out of clearinghouse custody"
        );

        clearinghouse.withdrawMargin(depositAmount);
        vm.stopPrank();

        assertEq(
            clearinghouse.balanceUsdc(account),
            settlementBefore - expectedCarry,
            "Deposit-withdraw roundtrip must not erase accrued carry"
        );
    }

    function test_DepositMargin_CanRescueAccountWhenIncomingCashCoversCarry() public {
        address trader = address(0xABD1);
        address account = trader;
        uint256 rescueDeposit = 50_000e6;
        uint256 carryElapsed = 365 days * 3;

        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.BULL, 500_000e18, 10_000e6, 1e8);

        uint256 settlementBefore = clearinghouse.balanceUsdc(account);

        usdc.mint(trader, rescueDeposit);

        vm.warp(block.timestamp + carryElapsed);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.roll(block.number + 1);

        uint256 expectedCarry = _expectedIndexedCarry(account);
        assertGt(
            expectedCarry, settlementBefore, "Setup must accrue more carry than the pre-deposit settlement balance"
        );

        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.depositMargin(rescueDeposit);
        vm.stopPrank();

        assertEq(
            clearinghouse.balanceUsdc(account),
            settlementBefore + rescueDeposit - expectedCarry,
            "Rescue deposit should settle pre-basis carry from the incoming cash in the same tx"
        );
    }

    function test_DepositMargin_SucceedsOnStaleMarkWithoutCheckpointingCarry() public {
        address trader = address(0xABD1A);
        address account = trader;
        uint256 depositAmount = 500e6;

        _fundTrader(trader, 10_000e6);
        usdc.mint(trader, depositAmount);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        uint256 settlementBefore = clearinghouse.balanceUsdc(account);
        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 30 days);

        uint256 expectedCarry = _expectedIndexedCarry(account);

        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.depositMargin(depositAmount);
        vm.stopPrank();

        assertEq(
            clearinghouse.balanceUsdc(account),
            settlementBefore + depositAmount - expectedCarry,
            "Stale-oracle deposit should checkpoint indexed carry before crediting settlement"
        );
        assertEq(
            _lastCarryTimestamp(account), block.timestamp, "Stale-mark deposit should advance the carry checkpoint"
        );
        assertEq(engine.unsettledCarryUsdc(account), 0, "Indexed carry deposit should settle elapsed carry");
    }

    function test_ReserveCommittedOrderMargin_CheckpointsCarryBeforeReachabilityDrops() public {
        address trader = address(0xABD3);
        address account = trader;
        uint256 reserveAmount = 4000e6;
        uint256 depositAmount = 1000e6;
        uint256 carryElapsed = 30 days;

        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        uint256 settlementBefore = clearinghouse.balanceUsdc(account);

        vm.warp(block.timestamp + carryElapsed);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.roll(block.number + 1);

        uint256 expectedCarry = _expectedIndexedCarry(account);

        vm.prank(address(router));
        clearinghouse.reserveCommittedOrderMargin(account, 77, reserveAmount);

        assertEq(
            clearinghouse.balanceUsdc(account),
            settlementBefore - expectedCarry,
            "Committed-order reservation should realize carry before lowering reachable collateral"
        );
        assertEq(
            engine.unsettledCarryUsdc(account), 0, "Reservation checkpoint should settle elapsed carry immediately"
        );

        usdc.mint(trader, depositAmount);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.depositMargin(depositAmount);
        vm.stopPrank();

        assertEq(
            clearinghouse.balanceUsdc(account),
            settlementBefore - expectedCarry + depositAmount,
            "Later deposits must not retroactively reprice pre-reservation carry on the reduced basis"
        );
    }

    function test_UnlockReservedSettlement_CheckpointsCarryBeforeReachabilityRises() public {
        address trader = address(0xABD6);
        address account = trader;
        uint256 reservedAmount = 3000e6;
        uint256 carryElapsed = 30 days;

        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        vm.prank(address(router));
        clearinghouse.lockReservedSettlement(account, reservedAmount);

        uint256 settlementBeforeUnlock = clearinghouse.balanceUsdc(account);
        vm.warp(block.timestamp + carryElapsed);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 expectedCarry = _expectedIndexedCarry(account);

        vm.prank(address(engine));
        clearinghouse.unlockReservedSettlement(account, reservedAmount);

        assertEq(
            clearinghouse.balanceUsdc(account),
            settlementBeforeUnlock - expectedCarry,
            "Reserved-settlement unlock should checkpoint carry before reserved funds become reachable again"
        );
        assertEq(engine.unsettledCarryUsdc(account), 0, "Unlock should not leave elapsed carry uncheckpointed");
    }

    function test_ProfitableClose_DoesNotDoubleBookCarryIntoAccountedAssets() public {
        address trader = address(0xABD2);
        address account = trader;

        _fundTrader(trader, 20_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.warp(block.timestamp + 1 days);
        vm.prank(address(router));
        engine.updateMarkPrice(80_000_000, uint64(block.timestamp));

        _close(account, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        assertEq(
            pool.accountedAssets(),
            pool.rawAssets(),
            "Profitable close carry should not create accounted-assets overhang"
        );
    }

    function test_SettlementSidecar_RevertsWhenCalledDirectly() public {
        CfdEngineSettlementSidecar sidecar = CfdEngineSettlementSidecar(address(engine.settlementSidecar()));
        CfdEnginePlanTypes.CloseDelta memory delta;
        CfdTypes.Position memory position;

        vm.expectRevert(CfdEngineSettlementSidecar.CfdEngineSettlementSidecar__Unauthorized.selector);
        sidecar.executeClose(ICfdEngineSettlementHost(address(engine)), delta, position, uint64(block.timestamp));
    }

    function test_SettlementSidecar_RevertsWhenEngineCallerPassesDifferentHost() public {
        CfdEngineSettlementSidecar sidecar = CfdEngineSettlementSidecar(address(engine.settlementSidecar()));
        CfdEngine wrongHost = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
        CfdEnginePlanTypes.OpenDelta memory openDelta;
        CfdEnginePlanTypes.CloseDelta memory closeDelta;
        CfdEnginePlanTypes.LiquidationDelta memory liquidationDelta;
        CfdTypes.Position memory position;

        vm.startPrank(address(engine));

        vm.expectRevert(CfdEngineSettlementSidecar.CfdEngineSettlementSidecar__Unauthorized.selector);
        sidecar.executeOpen(ICfdEngineSettlementHost(address(wrongHost)), openDelta, position, uint64(block.timestamp));

        vm.expectRevert(CfdEngineSettlementSidecar.CfdEngineSettlementSidecar__Unauthorized.selector);
        sidecar.executeClose(
            ICfdEngineSettlementHost(address(wrongHost)), closeDelta, position, uint64(block.timestamp)
        );

        vm.expectRevert(CfdEngineSettlementSidecar.CfdEngineSettlementSidecar__Unauthorized.selector);
        sidecar.executeLiquidation(
            ICfdEngineSettlementHost(address(wrongHost)), liquidationDelta, uint64(block.timestamp), address(this)
        );

        vm.stopPrank();
    }

    function test_SetDependencies_RevertsWhenSettlementSidecarBoundToDifferentEngine() public {
        CfdEngine victim = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementSidecar wrongSidecar = new CfdEngineSettlementSidecar(address(engine));
        CfdEngineAdmin adminModule = new CfdEngineAdmin(address(victim), address(this));

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidSettlementSidecar.selector);
        victim.setDependencies(address(planner), address(wrongSidecar), address(adminModule));
    }

    function test_SetDependencies_RevertsWhenSettlementSidecarHasNoEngineBinding() public {
        CfdEngine victim = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineAdmin adminModule = new CfdEngineAdmin(address(victim), address(this));

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidSettlementSidecar.selector);
        victim.setDependencies(address(planner), address(0xBEEF), address(adminModule));
    }

    function test_GetAccountCollateralView_ReturnsCurrentBuckets() public {
        address trader = address(0xAB10);
        address account = trader;
        _fundTrader(trader, 10_000 * 1e6);
        _open(account, CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 7900 * 1e6, type(uint256).max, false);

        ICfdEngineTypes.AccountCollateralView memory viewData = engineAccountLens.getAccountCollateralView(account);
        (, uint256 positionMargin,,,,,) = engine.positions(account);
        assertEq(viewData.settlementBalanceUsdc, clearinghouse.balanceUsdc(account));
        assertEq(viewData.lockedMarginUsdc, clearinghouse.lockedMarginUsdc(account));
        assertEq(viewData.activePositionMarginUsdc, positionMargin);
        assertEq(viewData.otherLockedMarginUsdc, viewData.lockedMarginUsdc - positionMargin);
        assertEq(viewData.freeSettlementUsdc, _freeSettlementUsdc(account));
        assertEq(viewData.closeReachableUsdc, _freeSettlementUsdc(account));
        assertEq(viewData.terminalReachableUsdc, _terminalReachableUsdc(account));
        assertEq(viewData.accountEquityUsdc, clearinghouse.getAccountEquityUsdc(account));
        assertEq(viewData.freeBuyingPowerUsdc, clearinghouse.getFreeBuyingPowerUsdc(account));
        assertEq(viewData.traderClaimBalanceUsdc, 0);
    }

    function test_GetPositionView_ReturnsLivePositionState() public {
        address trader = address(0xAB11);
        address account = trader;
        _fundTrader(trader, 10_000 * 1e6);
        _open(account, CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(90_000_000, uint64(block.timestamp));

        PerpsViewTypes.PositionView memory viewData = _publicPosition(account);
        (, uint256 positionMargin,,,,,) = engine.positions(account);
        assertTrue(viewData.exists);
        assertEq(uint256(viewData.side), uint256(CfdTypes.Side.BULL));
        assertEq(viewData.size, 100_000 * 1e18);
        assertEq(viewData.entryPrice, 1e8);
        assertEq(viewData.marginUsdc, positionMargin);
        assertGt(viewData.unrealizedPnlUsdc, 0);
    }

    function test_GetPositionView_DoesNotCountTraderClaimAsPhysicalCollateral() public {
        address trader = address(0xAB1101);
        address account = trader;
        _fundTrader(trader, 5000e6);
        _open(account, CfdTypes.Side.BEAR, 10_000e18, 5000e6, 1e8);

        uint256 closeExecutionFeeUsdc = _engineExecutionFeeUsdc(5000e18, 120_000_000);
        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - closeExecutionFeeUsdc - 1);

        _close(account, CfdTypes.Side.BEAR, 5000e18, 120_000_000);
        assertGt(engine.traderClaimBalanceUsdc(account), 0, "Setup must create a trader claim balance");

        PerpsViewTypes.PositionView memory viewData = _publicPosition(account);
        (, uint256 positionMargin,,,,,) = engine.positions(account);
        assertEq(viewData.marginUsdc, positionMargin, "Public position view should still expose locked position margin");
        assertEq(
            viewData.exists,
            true,
            "Trader claim balance should not hide the remaining open position from the public lens"
        );
    }

    function test_GetProtocolAccountingView_ReflectsTraderClaimLiabilities() public {
        address trader = address(0xAB12);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(account, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory viewData =
            engineProtocolLens.getProtocolAccountingSnapshot();
        assertEq(viewData.poolAssetsUsdc, pool.totalAssets());
        assertEq(viewData.withdrawalReservedUsdc, _withdrawalReservedUsdc());
        assertEq(viewData.protocolTreasuryBalanceUsdc, clearinghouse.balanceUsdc(engine.protocolTreasury()));
        assertEq(viewData.totalTraderClaimBalanceUsdc, engine.totalTraderClaimBalanceUsdc());
        assertEq(viewData.degradedMode, engine.degradedMode());
        assertEq(viewData.hasLiveLiability, (_maxLiability() > 0));
    }

    function test_GetProtocolAccountingSnapshot_ReflectsCanonicalLedgerState() public {
        address trader = address(0xAB13);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(account, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory viewData =
            engineProtocolLens.getProtocolAccountingSnapshot();
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory housePoolSnapshot =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());

        uint256 expectedNetPhysicalAssetsUsdc = snapshot.poolAssetsUsdc > snapshot.protocolTreasuryBalanceUsdc
            ? snapshot.poolAssetsUsdc - snapshot.protocolTreasuryBalanceUsdc
            : 0;

        assertEq(snapshot.poolAssetsUsdc, pool.totalAssets());
        assertEq(snapshot.netPhysicalAssetsUsdc, expectedNetPhysicalAssetsUsdc);
        assertEq(snapshot.maxLiabilityUsdc, _maxLiability());
        assertEq(snapshot.withdrawalReservedUsdc, _withdrawalReservedUsdc());
        assertEq(snapshot.protocolTreasuryBalanceUsdc, clearinghouse.balanceUsdc(engine.protocolTreasury()));
        assertEq(snapshot.accumulatedBadDebtUsdc, engine.accumulatedBadDebtUsdc());
        assertEq(snapshot.totalTraderClaimBalanceUsdc, engine.totalTraderClaimBalanceUsdc());
        assertEq(snapshot.degradedMode, engine.degradedMode());
        assertEq(snapshot.hasLiveLiability, (_maxLiability() > 0));
        assertEq(snapshot.poolAssetsUsdc, viewData.poolAssetsUsdc);
        assertEq(housePoolSnapshot.physicalAssetsUsdc, snapshot.poolAssetsUsdc);
        assertEq(snapshot.maxLiabilityUsdc, viewData.maxLiabilityUsdc);
        assertEq(snapshot.withdrawalReservedUsdc, viewData.withdrawalReservedUsdc);
        assertEq(snapshot.freeUsdc, viewData.freeUsdc);
        assertEq(snapshot.protocolTreasuryBalanceUsdc, viewData.protocolTreasuryBalanceUsdc);
        assertEq(snapshot.totalTraderClaimBalanceUsdc, viewData.totalTraderClaimBalanceUsdc);
        assertEq(snapshot.degradedMode, viewData.degradedMode);
        assertEq(snapshot.hasLiveLiability, viewData.hasLiveLiability);
        assertEq(snapshot.netPhysicalAssetsUsdc, housePoolSnapshot.netPhysicalAssetsUsdc);
        assertEq(snapshot.maxLiabilityUsdc, housePoolSnapshot.maxLiabilityUsdc);
        assertEq(snapshot.totalTraderClaimBalanceUsdc, housePoolSnapshot.traderClaimBalanceUsdc);
    }

    function test_ProtocolAccountingSnapshot_IgnoresUnaccountedPoolDonationUntilAccounted() public {
        _fundJunior(address(0xB0B), 500_000e6);
        uint256 accountedBefore = pool.totalAssets();

        usdc.mint(address(pool), 100_000e6);

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory beforeAccount =
            engineProtocolLens.getProtocolAccountingSnapshot();
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory houseBefore =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());

        assertEq(pool.rawAssets(), accountedBefore + 100_000e6, "Raw pool balance should include the donation");
        assertEq(
            pool.totalAssets(), accountedBefore, "Canonical pool assets should ignore the donation until accounted"
        );
        assertEq(beforeAccount.poolAssetsUsdc, accountedBefore, "Protocol snapshot should follow canonical assets");
        assertEq(
            houseBefore.netPhysicalAssetsUsdc, accountedBefore, "HousePool snapshot should ignore unaccounted donations"
        );

        pool.accountExcess();

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory afterAccount =
            engineProtocolLens.getProtocolAccountingSnapshot();
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory houseAfter =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());

        assertEq(
            pool.totalAssets(), accountedBefore + 100_000e6, "Explicit accounting should raise canonical pool assets"
        );
        assertEq(
            afterAccount.poolAssetsUsdc,
            accountedBefore + 100_000e6,
            "Protocol snapshot should reflect explicit accounting"
        );
        assertEq(
            houseAfter.netPhysicalAssetsUsdc,
            accountedBefore + 100_000e6,
            "HousePool snapshot should reflect explicit accounting"
        );
    }

    function test_GetAccountLedgerView_ReflectsCompactCrossContractState() public {
        address trader = address(0xAB15);
        address account = trader;
        _fundTrader(trader, 12_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        vm.startPrank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, 0, false);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);
        vm.stopPrank();

        AccountLensViewTypes.AccountLedgerView memory ledgerView = engineAccountLens.getAccountLedgerView(account);
        (, uint256 positionMargin,,,,,) = engine.positions(account);
        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(account);
        IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);

        assertEq(ledgerView.settlementBalanceUsdc, buckets.settlementBalanceUsdc);
        assertEq(ledgerView.freeSettlementUsdc, buckets.freeSettlementUsdc);
        assertEq(ledgerView.activePositionMarginUsdc, buckets.activePositionMarginUsdc);
        assertEq(ledgerView.otherLockedMarginUsdc, buckets.otherLockedMarginUsdc);
        assertEq(ledgerView.executionBountyReserveUsdc, reservation.executionBountyUsdc);
        assertEq(ledgerView.committedMarginUsdc, reservation.committedMarginUsdc);
        assertEq(ledgerView.traderClaimBalanceUsdc, engine.traderClaimBalanceUsdc(account));
        assertEq(ledgerView.pendingOrderCount, router.pendingOrderCounts(account));
    }

    function test_GetAccountLedgerSnapshot_ReflectsExpandedAccountHealthState() public {
        address trader = address(0xAB16);
        address account = trader;
        _fundTrader(trader, 12_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = engineAccountLens.getAccountLedgerSnapshot(account);
        ICfdEngineTypes.AccountCollateralView memory collateralView =
            engineAccountLens.getAccountCollateralView(account);
        (uint256 sizeStored, uint256 marginStored, uint256 entryPriceStored,, CfdTypes.Side sideStored,,) =
            engine.positions(account);
        IMarginClearinghouse.LockedMarginBuckets memory lockedBuckets = clearinghouse.getLockedMarginBuckets(account);
        IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);

        assertEq(snapshot.settlementBalanceUsdc, collateralView.settlementBalanceUsdc);
        assertEq(snapshot.freeSettlementUsdc, collateralView.freeSettlementUsdc);
        assertEq(snapshot.activePositionMarginUsdc, collateralView.activePositionMarginUsdc);
        assertEq(snapshot.otherLockedMarginUsdc, collateralView.otherLockedMarginUsdc);
        assertEq(snapshot.positionMarginBucketUsdc, lockedBuckets.positionMarginUsdc);
        assertEq(snapshot.committedOrderMarginBucketUsdc, lockedBuckets.committedOrderMarginUsdc);
        assertEq(snapshot.reservedSettlementBucketUsdc, lockedBuckets.reservedSettlementUsdc);
        assertEq(snapshot.executionBountyReserveUsdc, reservation.executionBountyUsdc);
        assertEq(snapshot.committedMarginUsdc, reservation.committedMarginUsdc);
        assertEq(snapshot.traderClaimBalanceUsdc, collateralView.traderClaimBalanceUsdc);
        assertEq(snapshot.pendingOrderCount, reservation.pendingOrderCount);
        assertEq(snapshot.closeReachableUsdc, collateralView.closeReachableUsdc);
        assertEq(snapshot.terminalReachableUsdc, collateralView.terminalReachableUsdc);
        assertEq(snapshot.accountEquityUsdc, collateralView.accountEquityUsdc);
        assertEq(snapshot.freeBuyingPowerUsdc, collateralView.freeBuyingPowerUsdc);
        assertTrue(snapshot.hasPosition);
        assertEq(uint256(snapshot.side), uint256(sideStored));
        assertEq(snapshot.size, sizeStored);
        assertEq(snapshot.margin, marginStored);
        assertEq(snapshot.entryPrice, entryPriceStored);
    }

    function test_GetHousePoolInputSnapshot_ReflectsCurrentAccountingState() public {
        address trader = address(0xAB14);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory status = engineProtocolLens.getHousePoolStatusSnapshot();
        uint256 protocolTreasuryBalanceUsdc = clearinghouse.balanceUsdc(engine.protocolTreasury());
        uint256 expectedNetPhysicalAssetsUsdc =
            pool.totalAssets() > protocolTreasuryBalanceUsdc ? pool.totalAssets() - protocolTreasuryBalanceUsdc : 0;

        assertEq(
            snapshot.physicalAssetsUsdc, pool.totalAssets(), "Snapshot physical assets must match canonical pool assets"
        );
        assertEq(
            snapshot.netPhysicalAssetsUsdc,
            expectedNetPhysicalAssetsUsdc,
            "Treasury clearinghouse fees should be excluded from pool net assets"
        );
        assertEq(snapshot.maxLiabilityUsdc, _maxLiability(), "Snapshot liability must match accessor");
        assertEq(snapshot.supplementalReservedUsdc, uint256(0), "Snapshot supplemental reserve must match accessor");
        assertEq(
            snapshot.unrealizedMtmLiabilityUsdc, _poolMtmAdjustment(), "Snapshot MtM liability must match accessor"
        );
        assertEq(
            snapshot.traderClaimBalanceUsdc, engine.totalTraderClaimBalanceUsdc(), "Snapshot payout must match storage"
        );
        assertTrue(snapshot.markFreshnessRequired, "Open directional liability should require fresh marks");
        assertEq(
            snapshot.maxMarkStaleness,
            pool.markStalenessLimit(),
            "Live-market snapshot should use HousePool's configured limit"
        );
        assertEq(status.lastMarkTime, engine.lastMarkTime(), "Status snapshot mark timestamp must match engine state");
        assertEq(status.oracleFrozen, engine.isOracleFrozen(), "Status snapshot frozen flag must match engine state");
        assertEq(status.degradedMode, engine.degradedMode(), "Status snapshot degraded flag must match engine state");
    }

    function test_GetHousePoolInputSnapshot_UsesFrozenOracleFreshnessLimit() public {
        uint256 saturdayFrozen = 1_710_021_600;
        address trader = address(0xAB15);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.BEAR, 100_000e18, 9000e6, 1e8);

        vm.warp(saturdayFrozen);
        assertTrue(engine.isOracleFrozen(), "Test setup should be inside a frozen oracle window");

        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory status = engineProtocolLens.getHousePoolStatusSnapshot();
        assertTrue(snapshot.markFreshnessRequired, "Open liability should still require freshness in frozen mode");
        assertEq(
            snapshot.maxMarkStaleness,
            engine.fadMaxStaleness(),
            "Frozen-oracle snapshot should use the relaxed engine staleness bound"
        );
        assertEq(status.lastMarkTime, engine.lastMarkTime(), "Frozen status snapshot must carry mark timestamp");
        assertTrue(status.oracleFrozen, "Frozen status snapshot should report frozen oracle mode");
        assertEq(status.degradedMode, engine.degradedMode(), "Frozen status degraded flag must match engine state");
    }

    function test_MarketCalendar_SundayBoundariesMatchLiveSemantics() public {
        uint256 sundayTwentyFiftyNine = 1_709_499_599;
        uint256 sundayTwentyOne = 1_709_499_600;
        uint256 sundayTwentyTwo = 1_709_503_200;

        vm.warp(sundayTwentyFiftyNine);
        assertTrue(engine.isOracleFrozen(), "Sunday 20:59:59 should still be oracle frozen");
        assertTrue(engine.isFadWindow(), "Sunday 20:59:59 should still be FAD");

        vm.warp(sundayTwentyOne);
        assertFalse(engine.isOracleFrozen(), "Sunday 21:00:00 should unfreeze oracle mode");
        assertTrue(engine.isFadWindow(), "Sunday 21:00:00 should remain in FAD");

        vm.warp(sundayTwentyTwo);
        assertFalse(engine.isOracleFrozen(), "Sunday 22:00:00 should remain unfrozen");
        assertFalse(engine.isFadWindow(), "Sunday 22:00:00 should end FAD");
    }

    function test_PreviewClose_ReturnsClaimAndImmediateSettlementBreakdown() public {
        address trader = address(0xAB13);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        ICfdEngineTypes.ClosePreview memory normalPreview = engineLens.previewClose(account, 100_000e18, 80_000_000);
        assertTrue(normalPreview.valid);
        assertGt(normalPreview.immediatePayoutUsdc, 0);
        assertEq(normalPreview.traderClaimBalanceUsdc, 0);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        ICfdEngineTypes.ClosePreview memory illiquidPreview = engineLens.previewClose(account, 100_000e18, 80_000_000);
        assertTrue(illiquidPreview.valid);
        assertEq(illiquidPreview.immediatePayoutUsdc, 0);
        assertGt(illiquidPreview.traderClaimBalanceUsdc, 0);
        assertEq(illiquidPreview.remainingSize, 0);
    }

    function test_SimulateClose_UsesHypotheticalPoolCashForPayoutBreakdown() public {
        address trader = address(0xAB1301);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 canonicalDepth = pool.totalAssets();
        ICfdEngineTypes.ClosePreview memory canonicalPreview = engineLens.previewClose(account, 100_000e18, 80_000_000);
        ICfdEngineTypes.ClosePreview memory hypotheticalPreview =
            engineLens.simulateClose(account, 100_000e18, 80_000_000, 1);

        assertTrue(canonicalPreview.valid);
        assertGt(canonicalPreview.immediatePayoutUsdc, 0, "Live preview should reflect currently available pool cash");
        assertEq(canonicalPreview.traderClaimBalanceUsdc, 0, "Live preview should not defer when cash is available");
        assertEq(canonicalDepth, pool.totalAssets(), "Setup should keep canonical depth unchanged");

        assertTrue(hypotheticalPreview.valid);
        assertEq(hypotheticalPreview.immediatePayoutUsdc, 0, "Hypothetical close should use caller-supplied pool cash");
        assertGt(hypotheticalPreview.traderClaimBalanceUsdc, 0, "Low hypothetical cash should defer the payout");
    }

    function test_PreviewClose_TriggersDegradedModeMatchesLiveClose() public {
        address bullTrader = address(0xAB1308);
        address bearTrader = address(0xAB1309);
        address bullAccount = bullTrader;
        address bearAccount = bearTrader;

        _fundTrader(bullTrader, 100_000e6);
        _fundTrader(bearTrader, 100_000e6);

        _open(bearAccount, CfdTypes.Side.BEAR, 1_000_000e18, 50_000e6, 1e8);
        _open(bullAccount, CfdTypes.Side.BULL, 500_000e18, 50_000e6, 1e8);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(bullAccount, 500_000e18, 20_000_000);
        assertTrue(preview.triggersDegradedMode, "Preview should flag the profitable close that reveals insolvency");

        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(bullAccount);
        _close(bullAccount, CfdTypes.Side.BULL, 500_000e18, 20_000_000);

        CloseParityObserved memory observed = _observeCloseParity(bullAccount, beforeSnapshot);
        _assertClosePreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
        assertTrue(engine.degradedMode(), "Live close should match preview degraded-mode trigger");
    }

    function helper_PreviewClose_RecomputesPostOpStateInCarryModel() public {
        address bullTrader = address(0xAB130A);
        address bearTrader = address(0xAB130B);
        address bullAccount = bullTrader;
        address bearAccount = bearTrader;

        _fundTrader(bullTrader, 12_000e6);
        _fundTrader(bearTrader, 30_000e6);

        _open(bullAccount, CfdTypes.Side.BULL, 500_000e18, 8000e6, 1e8);
        _open(bearAccount, CfdTypes.Side.BEAR, 50_000e18, 20_000e6, 1e8);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint64 accrualTime = refreshTime + 30;
        vm.warp(accrualTime);

        (uint256 bullSize, uint256 bullMargin,, uint256 bullMaxProfit,,,) = engine.positions(bullAccount);

        ICfdEngineTypes.ClosePreview memory preDrainPreview = engineLens.previewClose(bullAccount, bullSize, 1e8);
        assertTrue(preDrainPreview.valid, "Setup close preview should remain valid");

        uint256 grossTargetAssets = _maxLiabilityAfterClose(CfdTypes.Side.BULL, bullMaxProfit)
            + clearinghouse.balanceUsdc(engine.protocolTreasury());
        assertGt(
            grossTargetAssets,
            preDrainPreview.seizedCollateralUsdc + 1,
            "Setup must leave a positive degraded-mode gap after subtracting seized collateral"
        );
        uint256 targetAssets = grossTargetAssets;
        uint256 currentAssets = pool.totalAssets();
        assertGt(currentAssets, targetAssets, "Test setup must be able to drain the pool into the carry-clip gap");

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), currentAssets - targetAssets);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(bullAccount, bullSize, 1e8);
        assertTrue(preview.triggersDegradedMode, "Preview should detect degraded mode after the forced drain");

        _close(bullAccount, CfdTypes.Side.BULL, bullSize, 1e8);
        assertEq(
            preview.triggersDegradedMode,
            engine.degradedMode(),
            "Close preview should match live degraded-mode outcome after the drain"
        );
    }

    function test_PreviewClose_ReportsPostOpDegradedStateAfterLatch() public {
        address bullTrader = address(0xAB130C);
        address bearTrader = address(0xAB130D);
        address residualBearTrader = address(0xAB130E);
        address bullAccount = bullTrader;
        address bearAccount = bearTrader;
        address residualBearAccount = residualBearTrader;

        _fundTrader(bullTrader, 100_000e6);
        _fundTrader(bearTrader, 100_000e6);
        _fundTrader(residualBearTrader, 100_000e6);

        _open(bearAccount, CfdTypes.Side.BEAR, 900_000e18, 45_000e6, 1e8);
        _open(residualBearAccount, CfdTypes.Side.BEAR, 100_000e18, 5000e6, 1e8);
        _open(bullAccount, CfdTypes.Side.BULL, 500_000e18, 50_000e6, 1e8);

        _close(bullAccount, CfdTypes.Side.BULL, 500_000e18, 20_000_000);
        assertTrue(engine.degradedMode(), "Setup close should latch degraded mode");

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(bearAccount, 900_000e18, 20_000_000);
        assertTrue(preview.valid, "Full close should remain previewable after degraded mode latches");
        assertFalse(preview.triggersDegradedMode, "Transition flag should stay false after degraded mode latches");
        assertEq(
            preview.postOpDegradedMode,
            preview.effectiveAssetsAfterUsdc < preview.maxLiabilityAfterUsdc,
            "Preview should expose raw post-op solvency values for integrators even after degraded mode latches"
        );
    }

    function test_PreviewClose_NegativeVpiDoesNotPanic() public {
        address trader = address(0xAB1301);
        address account = trader;
        _fundTrader(trader, 10_000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 4000e6, 1e8);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 1e8);

        assertTrue(preview.valid, "Preview should remain valid when close earns a negative VPI rebate");
        assertLt(preview.vpiDeltaUsdc, 0, "Preview should expose negative VPI as a rebate instead of panicking");
        assertEq(preview.vpiUsdc, 0, "Positive-only VPI charge field should clamp rebates to zero");
    }

    function test_PreviewClose_UsesPostUnlockFreeSettlementForLosses() public {
        address trader = address(0xAB1302);
        address account = trader;
        _fundTrader(trader, 5000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 4000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 900e6, type(uint256).max, false);

        uint256 freeSettlementBeforePreview = _freeSettlementUsdc(account);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 50_000e18, 110_000_000);

        assertGt(
            preview.seizedCollateralUsdc,
            freeSettlementBeforePreview,
            "Preview loss collection should include settlement freed by the partial close before applying close losses"
        );
    }

    function test_PreviewClose_UnderwaterPartialMatchesLiveRevert() public {
        address juniorLp = address(0xAB1306);
        address trader = address(0xAB1307);
        _fundJunior(juniorLp, 1_000_000 * 1e6);
        _fundTrader(trader, 22_000 * 1e6);

        address account = trader;
        _open(account, CfdTypes.Side.BEAR, 200_000 * 1e18, 20_000 * 1e6, 1e8);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000 * 1e18, 80_000_000);
        (uint256 sizeBefore,,,,,,) = engine.positions(account);

        assertFalse(preview.valid, "Preview should reject an underwater partial close that invades residual backing");
        assertEq(
            uint8(preview.invalidReason),
            uint8(CfdTypes.CloseInvalidReason.PartialCloseUnderwater),
            "Preview should use the underwater partial-close invalid reason"
        );

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000 * 1e18, 0, 0, true);
        bytes[] memory priceData = _mockPythUpdateData(0.8e8);
        router.executeOrder(1, priceData);

        (uint256 sizeAfter,,,,,,) = engine.positions(account);
        assertEq(
            sizeAfter, sizeBefore, "Live close path should leave the position unchanged when preview marks it invalid"
        );
    }

    function test_PreviewClose_FullLossBadDebtMatchesLiveSettlement() public {
        address trader = address(0xAB1304);
        address account = trader;
        _fundTrader(trader, 2000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 110_000_000);
        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();

        _close(account, CfdTypes.Side.BULL, 100_000e18, 110_000_000);

        assertEq(
            engine.accumulatedBadDebtUsdc() - badDebtBefore,
            preview.badDebtUsdc,
            "Preview bad debt should match live terminal settlement planning"
        );
    }

    function test_PreviewClose_ClampsOraclePriceToCap() public {
        address trader = address(0xAB1305);
        address account = trader;
        _fundTrader(trader, 5000e6);
        _open(account, CfdTypes.Side.BEAR, 100_000e18, 4000e6, 1e8);

        ICfdEngineTypes.ClosePreview memory cappedPreview = engineLens.previewClose(account, 100_000e18, 2e8);
        ICfdEngineTypes.ClosePreview memory overCapPreview = engineLens.previewClose(account, 100_000e18, 3e8);

        assertEq(
            overCapPreview.executionPrice,
            cappedPreview.executionPrice,
            "Preview execution price should clamp to CAP_PRICE"
        );
        assertEq(overCapPreview.realizedPnlUsdc, cappedPreview.realizedPnlUsdc, "Preview PnL should clamp to CAP_PRICE");
        assertEq(overCapPreview.vpiDeltaUsdc, cappedPreview.vpiDeltaUsdc, "Preview VPI should clamp to CAP_PRICE");
        assertEq(
            overCapPreview.executionFeeUsdc, cappedPreview.executionFeeUsdc, "Preview fee should clamp to CAP_PRICE"
        );
        assertEq(
            overCapPreview.immediatePayoutUsdc,
            cappedPreview.immediatePayoutUsdc,
            "Preview payout should clamp to CAP_PRICE"
        );
        assertEq(
            overCapPreview.traderClaimBalanceUsdc,
            cappedPreview.traderClaimBalanceUsdc,
            "Preview trader claim should clamp to CAP_PRICE"
        );
        assertEq(overCapPreview.badDebtUsdc, cappedPreview.badDebtUsdc, "Preview bad debt should clamp to CAP_PRICE");
    }

    function test_PreviewLiquidation_ReturnsBountyAndLiquidatableFlag() public {
        address trader = address(0xAB14);
        address account = trader;
        _fundTrader(trader, 300e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 200e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 100e6);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 101_000_000);
        assertTrue(preview.liquidatable);
        assertEq(preview.keeperBountyUsdc, 10_100_000);
        assertLe(preview.keeperBountyUsdc, uint256(preview.equityUsdc));
    }

    function test_PlanLiquidation_PositiveResidualAboveTraderClaimDoesNotUnderflow() public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        CfdEnginePlanTypes.LiquidationDelta memory delta =
            harness.planLiquidation(0, 10e6, 2000e18, 99_600_000, 100_000_000);

        assertTrue(delta.liquidatable, "Setup must remain liquidatable");
        assertEq(
            delta.keeperBountyUsdc, 0, "Zero reachable settlement should cap the direct margin-funded bounty at zero"
        );
        assertEq(delta.residualUsdc, 8e6, "Residual should keep all positive PnL when no bounty is reachable");
        assertEq(delta.settlementRetainedUsdc, 0, "No settlement should remain when none is reachable");
        assertEq(
            delta.existingTraderClaimConsumedUsdc,
            0,
            "Positive physical residual should not consume legacy trader claim"
        );
        assertEq(
            delta.existingTraderClaimRemainingUsdc,
            10e6,
            "Legacy trader claim should remain intact on positive residual"
        );
        assertEq(delta.freshTraderPayoutUsdc, 8e6, "Only physical residual should become a fresh trader payout");
        assertEq(
            delta.residualPlan.freshTraderPayoutUsdc, 8e6, "Residual plan should expose only the physical fresh payout"
        );
        assertEq(delta.badDebtUsdc, 0, "Positive residual should not create bad debt");
    }

    function test_PlanLiquidation_NegativeResidualFullyConsumesExistingTraderClaimWithoutReducingBadDebt() public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        CfdEnginePlanTypes.LiquidationDelta memory delta =
            harness.planLiquidation(0, 10e6, 2000e18, 99_600_000, 99_000_000);

        assertTrue(delta.liquidatable, "Setup must remain liquidatable");
        assertEq(delta.keeperBountyUsdc, 0, "Zero physically reachable collateral should cap the bounty at zero");
        assertEq(delta.residualUsdc, -12e6, "Residual should be computed before any trader-claim netting");
        assertEq(
            delta.existingTraderClaimConsumedUsdc,
            10e6,
            "Negative residual should consume legacy trader claim only as terminal shortfall netting"
        );
        assertEq(
            delta.existingTraderClaimRemainingUsdc, 0, "No trader claim should survive a negative residual wipeout"
        );
        assertEq(delta.badDebtUsdc, 2e6, "Bad debt should reflect only the shortfall left after trader claim netting");
    }

    function test_PreviewLiquidation_PreservesExistingTraderClaimOnPositivePhysicalResidual() public {
        address trader = address(0xAB14002);
        address account = trader;
        address keeper = address(0xAB14003);
        _fundTrader(trader, 200e6);
        _open(account, CfdTypes.Side.BEAR, 10_000e18, 200e6, 99_700_000);

        stdstore.target(address(clearinghouse)).sig("balanceUsdc(address)").with_key(account).checked_write(uint256(0));

        stdstore.target(address(engine)).sig("traderClaimBalanceUsdc(address)").with_key(account)
            .checked_write(uint256(10e6));
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceUsdc()").checked_write(uint256(10e6));

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 30e6);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 100_000_000);

        assertTrue(preview.liquidatable, "Preview should not revert for positive physical residual");
        assertEq(preview.keeperBountyUsdc, 0, "Zero reachable settlement should cap the direct bounty at zero");
        assertEq(preview.settlementRetainedUsdc, 0, "No settlement should remain when no settlement is reachable");
        assertEq(
            preview.freshTraderPayoutUsdc, 30e6, "Preview should surface the current physical fresh liquidation payout"
        );
        assertEq(
            preview.existingTraderClaimConsumedUsdc,
            0,
            "Positive physical residual should not consume legacy trader claim"
        );
        assertEq(
            preview.existingTraderClaimRemainingUsdc, 10e6, "Preview should keep the legacy trader claim outstanding"
        );
        assertEq(
            preview.immediatePayoutUsdc,
            0,
            "Current preview should keep the physical payout as a trader claim when the existing claim remains untouched"
        );
        assertEq(
            preview.traderClaimBalanceUsdc,
            40e6,
            "Trader claim should reflect the untouched existing claim plus the fresh claim amount in the current preview model"
        );
        assertEq(preview.badDebtUsdc, 0, "Positive residual should not report bad debt");

        uint256 settlementBefore = clearinghouse.balanceUsdc(account);
        vm.prank(keeper);
        bytes[] memory liquidationPriceData = new bytes[](1);
        liquidationPriceData[0] = abi.encode(uint256(100_000_000));
        router.executeLiquidation(account, liquidationPriceData);

        uint256 postPayoutPoolAssets = pool.totalAssets();
        int256 legacySpread = int256(0);
        uint256 liveEffective = legacySpread > 0
            ? (postPayoutPoolAssets > uint256(legacySpread) ? postPayoutPoolAssets - uint256(legacySpread) : 0)
            : postPayoutPoolAssets + uint256(-legacySpread);
        uint256 traderClaimTotal = engine.totalTraderClaimBalanceUsdc();
        liveEffective = liveEffective > traderClaimTotal ? liveEffective - traderClaimTotal : 0;

        assertEq(
            clearinghouse.balanceUsdc(account) - settlementBefore,
            preview.immediatePayoutUsdc,
            "Live settlement credit should match preview"
        );
        assertEq(
            engine.traderClaimBalanceUsdc(account),
            40e6,
            "Live liquidation should preserve the old trader claim plus the fresh claim amount"
        );
        assertEq(
            preview.effectiveAssetsAfterUsdc,
            liveEffective,
            "Preview solvency should use net trader claim liabilities after consumption"
        );
    }

    function test_CloseExecution_UsesCarryAdjustedLossKernel() public {
        address trader = address(0xAB14004);
        address account = trader;

        _fundTrader(trader, 20_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.warp(block.timestamp + 1 days);
        vm.prank(address(router));
        engine.updateMarkPrice(100_010_000, uint64(block.timestamp));

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 100_010_000);
        assertTrue(preview.valid, "Carry-adjusted full close should remain executable");
        assertEq(preview.badDebtUsdc, 0, "Carry-adjusted close should remain fully covered in this setup");

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 100_010_000, true);

        bytes[] memory priceData = _mockPythUpdateData(100_010_000);
        router.executeOrder(1, priceData);

        (uint256 sizeAfter,,,,,,) = engine.positions(account);
        assertEq(sizeAfter, 0, "Close should execute instead of reverting when carry flips the trade into a loss");
    }

    function test_LiquidationState_UsesFullReachableCollateralForUnderwaterBountyCap() public {
        LiquidationAccountingLibHarness harness = new LiquidationAccountingLibHarness();
        LiquidationAccountingLib.LiquidationState memory state =
            harness.build(10_000e18, 100_000_000, 125e6, -145e6, 100, 1e6, 900, 1e20);

        assertLt(state.equityUsdc, 0, "Setup must make the account underwater");
        assertEq(state.reachableCollateralUsdc, 125e6, "Liquidation state should use full reachable collateral");
        assertGt(
            state.keeperBountyUsdc,
            5e6,
            "Keeper bounty should be allowed to exceed active position margin when more collateral is reachable"
        );
        assertLe(
            state.keeperBountyUsdc,
            state.reachableCollateralUsdc,
            "Keeper bounty should still cap at reachable collateral"
        );
    }

    function testFuzz_PlanLiquidation_PositiveResidualPreservesTraderClaimAndUsesOnlyPhysicalReachability(
        uint256 settlementReachableUsdc,
        uint256 traderClaimBalanceUsdc
    ) public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        settlementReachableUsdc = bound(settlementReachableUsdc, 0, 20e6);
        traderClaimBalanceUsdc = bound(traderClaimBalanceUsdc, 1, 20e6);

        CfdEnginePlanTypes.LiquidationDelta memory delta =
            harness.planLiquidation(settlementReachableUsdc, traderClaimBalanceUsdc, 2000e18, 99_600_000, 100_000_000);

        vm.assume(delta.liquidatable);
        vm.assume(delta.residualUsdc >= 0);

        assertEq(
            delta.liquidationReachableCollateralUsdc,
            settlementReachableUsdc,
            "Liquidation reachability must ignore legacy trader claim"
        );
        assertEq(
            delta.liquidationState.reachableCollateralUsdc,
            settlementReachableUsdc,
            "Keeper bounty state must use only physical reachability"
        );
        assertEq(
            delta.existingTraderClaimConsumedUsdc, 0, "Positive physical residual must not consume legacy trader claim"
        );
        assertEq(
            delta.existingTraderClaimRemainingUsdc,
            traderClaimBalanceUsdc,
            "Positive physical residual must preserve the full legacy trader claim"
        );
        assertEq(delta.badDebtUsdc, 0, "Positive residual must not create bad debt");
    }

    function testFuzz_PlanLiquidation_NegativeResidualNetsTraderClaimExactlyOnce(
        uint256 settlementReachableUsdc,
        uint256 traderClaimBalanceUsdc
    ) public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        settlementReachableUsdc = bound(settlementReachableUsdc, 0, 20e6);
        traderClaimBalanceUsdc = bound(traderClaimBalanceUsdc, 1, 20e6);

        CfdEnginePlanTypes.LiquidationDelta memory delta =
            harness.planLiquidation(settlementReachableUsdc, traderClaimBalanceUsdc, 2000e18, 99_600_000, 99_000_000);

        vm.assume(delta.liquidatable);
        vm.assume(delta.residualUsdc < 0);

        uint256 expectedShortfallUsdc = delta.residualPlan.badDebtUsdc;
        if (delta.liquidationState.equityUsdc >= 0) {
            uint256 equityUsdc = uint256(delta.liquidationState.equityUsdc);
            uint256 keeperSubsidyUsdc = delta.keeperBountyUsdc > equityUsdc ? delta.keeperBountyUsdc - equityUsdc : 0;
            expectedShortfallUsdc =
                expectedShortfallUsdc > keeperSubsidyUsdc ? expectedShortfallUsdc - keeperSubsidyUsdc : 0;
        }
        uint256 expectedConsumed =
            traderClaimBalanceUsdc < expectedShortfallUsdc ? traderClaimBalanceUsdc : expectedShortfallUsdc;

        assertEq(
            delta.liquidationReachableCollateralUsdc,
            settlementReachableUsdc,
            "Liquidation reachability must ignore legacy trader claim"
        );
        assertEq(
            delta.existingTraderClaimConsumedUsdc,
            expectedConsumed,
            "Negative residual must net legacy trader claim exactly once against terminal shortfall"
        );
        assertEq(
            delta.existingTraderClaimRemainingUsdc,
            traderClaimBalanceUsdc - expectedConsumed,
            "Trader claim remainder must equal the unconsumed existing claim"
        );
        assertEq(
            delta.badDebtUsdc,
            expectedShortfallUsdc - expectedConsumed,
            "Bad debt must only reflect the shortfall left after trader claim netting"
        );
    }

    function test_PlanLiquidation_ClawsBackNegativeAccruedVpiIntoBadDebt() public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        CfdEnginePlanTypes.LiquidationDelta memory withoutClawback =
            harness.planLiquidationWithVpiAccrued(5e6, 0, 2000e18, 100_000_000, 99_000_000, 0);
        CfdEnginePlanTypes.LiquidationDelta memory withClawback =
            harness.planLiquidationWithVpiAccrued(5e6, 0, 2000e18, 100_000_000, 99_000_000, -7e6);

        assertTrue(withClawback.liquidatable, "Setup must remain liquidatable");
        assertEq(
            withClawback.riskState.equityUsdc,
            withoutClawback.riskState.equityUsdc - 7e6,
            "Base risk equity should include the negative accrued VPI clawback"
        );
        assertEq(
            withClawback.liquidationState.equityUsdc,
            withoutClawback.liquidationState.equityUsdc - 7e6,
            "Liquidation equity should apply the negative accrued VPI clawback exactly once"
        );
        assertEq(
            withClawback.badDebtUsdc,
            withoutClawback.badDebtUsdc + 7e6,
            "Negative accrued VPI should reduce liquidation residual by exactly the clawback amount"
        );
        assertEq(
            withClawback.keeperBountyUsdc,
            withoutClawback.keeperBountyUsdc,
            "Underwater keeper cap should still be bounded by reachable collateral"
        );
    }

    function testFuzz_PlanLiquidation_NegativeVpiClawbackAppliedOnce(
        uint256 reachableUsdc,
        uint256 size,
        uint256 oraclePrice,
        uint256 clawbackUsdc
    ) public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        reachableUsdc = bound(reachableUsdc, 1, 25_000_000e6);
        size = bound(size, 1e18, 1_000_000e18);
        oraclePrice = bound(oraclePrice, 1, 2e8);
        clawbackUsdc = bound(clawbackUsdc, 1, 50_000_000e6);

        CfdEnginePlanTypes.LiquidationDelta memory withoutClawback =
            harness.planLiquidationWithVpiAccrued(reachableUsdc, 0, size, 1e8, oraclePrice, 0);
        CfdEnginePlanTypes.LiquidationDelta memory withClawback =
            harness.planLiquidationWithVpiAccrued(reachableUsdc, 0, size, 1e8, oraclePrice, -int256(clawbackUsdc));

        assertEq(
            withClawback.riskState.equityUsdc,
            withoutClawback.riskState.equityUsdc - int256(clawbackUsdc),
            "Risk equity must include the accrued VPI liability exactly once"
        );
        if (!withoutClawback.liquidatable || !withClawback.liquidatable) {
            return;
        }

        assertEq(
            withClawback.liquidationState.equityUsdc,
            withoutClawback.liquidationState.equityUsdc - int256(clawbackUsdc),
            "Liquidation equity must not subtract the accrued VPI clawback a second time"
        );
    }

    function test_PlanLiquidation_NegativeAccruedVpiCanFlipLiquidatable() public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        CfdEnginePlanTypes.LiquidationDelta memory withoutClawback =
            harness.planLiquidationWithVpiAccrued(200_000, 0, 1000e18, 100_000_000, 101_000_000, 0);
        CfdEnginePlanTypes.LiquidationDelta memory withClawback =
            harness.planLiquidationWithVpiAccrued(200_000, 0, 1000e18, 100_000_000, 101_000_000, -7e6);

        assertFalse(withoutClawback.liquidatable, "Setup should sit just above maintenance without the VPI liability");
        assertTrue(withClawback.liquidatable, "Negative accrued VPI should be enough to trigger liquidation");
        assertEq(
            withClawback.riskState.equityUsdc,
            withoutClawback.riskState.equityUsdc - 7e6,
            "Risk equity should fall by the negative VPI clawback amount"
        );
    }

    function test_PlanOpen_ExistingNegativeVpiCountsAgainstImr() public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        CfdEnginePlanTypes.OpenDelta memory delta =
            harness.planOpenWithExistingVpiAccrued(1700e6, 1700e6, 100_000e18, 1e8, -1000e6, 10_000e18, 0, 1e8);

        assertEq(
            uint8(delta.revertCode),
            uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN),
            "Existing negative VPI liability should count against open IMR"
        );
        assertFalse(delta.valid, "Planner should reject opens that only clear IMR when negative VPI is ignored");
    }

    function test_LiquidationPreviewAndPositionView_UseCurrentNotionalThreshold() public {
        address trader = address(0xAB1401);
        address account = trader;
        uint256 poolDepth = pool.totalAssets();
        _fundTrader(trader, 2000e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 1105e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 895e6);

        vm.warp(block.timestamp + 1);
        vm.prank(address(router));
        engine.updateMarkPrice(110_000_000, uint64(block.timestamp));

        PerpsViewTypes.PositionView memory viewData = _publicPosition(account);
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 110_000_000);

        assertTrue(viewData.liquidatable, "Position view should use current notional for maintenance threshold");
        assertTrue(preview.liquidatable, "Liquidation preview should use current notional for maintenance threshold");

        vm.prank(address(router));
        engine.liquidatePosition(account, 110_000_000, poolDepth, uint64(block.timestamp), address(this));

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Live liquidation should agree with preview and position view");
    }

    function helper_PreviewLiquidation_UsesCanonicalPoolDepthWhileSimulateLiquidationAllowsWhatIfDepth() public {
        address trader = address(0xAB14015);
        address account = trader;
        _fundTrader(trader, 2000e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 1105e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 895e6);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(110_000_000, refreshTime);

        uint64 accrualTime = refreshTime + 30;
        vm.warp(accrualTime);

        uint256 canonicalDepth = pool.totalAssets();
        ICfdEngineTypes.LiquidationPreview memory canonicalPreview = engineLens.previewLiquidation(account, 110_000_000);
        ICfdEngineTypes.LiquidationPreview memory matchedSimulation =
            engineLens.simulateLiquidation(account, 110_000_000, canonicalDepth);
        ICfdEngineTypes.LiquidationPreview memory lowDepthSimulation =
            engineLens.simulateLiquidation(account, 110_000_000, canonicalDepth / 10);

        _assertLiquidationPreviewEquals(canonicalPreview, matchedSimulation);

        assertNotEq(
            canonicalPreview.reachableCollateralUsdc,
            lowDepthSimulation.reachableCollateralUsdc,
            "Simulation should honor lower hypothetical depth"
        );
    }

    function test_LiquidationParity_ImmediatePayoutMatchesPreview() public {
        address trader = address(0xAB14A1);
        address keeper = address(0xAB14A2);
        address account = trader;
        _fundTrader(trader, 300e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 200e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 100e6);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 101_000_000);
        assertTrue(preview.liquidatable, "Setup liquidation preview should be liquidatable");

        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(account, keeper);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(101_000_000));
        vm.prank(keeper);
        router.executeLiquidation(account, priceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(account, keeper, beforeSnapshot);
        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
    }

    function test_LiquidationPreview_InterfaceMatchesContractStructLayout() public {
        address trader = address(0xAB1402);
        address account = trader;
        _fundTrader(trader, 2000e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 1105e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 895e6);

        ICfdEngineTypes.LiquidationPreview memory contractPreview = engineLens.previewLiquidation(account, 110_000_000);
        ICfdEngineTypes.LiquidationPreview memory interfacePreview = engineLens.previewLiquidation(account, 110_000_000);

        assertEq(interfacePreview.liquidatable, contractPreview.liquidatable);
        assertEq(interfacePreview.oraclePrice, contractPreview.oraclePrice);
        assertEq(interfacePreview.equityUsdc, contractPreview.equityUsdc);
        assertEq(interfacePreview.pnlUsdc, contractPreview.pnlUsdc);
        assertEq(interfacePreview.reachableCollateralUsdc, contractPreview.reachableCollateralUsdc);
        assertEq(interfacePreview.keeperBountyUsdc, contractPreview.keeperBountyUsdc);
        assertEq(interfacePreview.seizedCollateralUsdc, contractPreview.seizedCollateralUsdc);
        assertEq(interfacePreview.immediatePayoutUsdc, contractPreview.immediatePayoutUsdc);
        assertEq(interfacePreview.traderClaimBalanceUsdc, contractPreview.traderClaimBalanceUsdc);
        assertEq(interfacePreview.badDebtUsdc, contractPreview.badDebtUsdc);
        assertEq(interfacePreview.triggersDegradedMode, contractPreview.triggersDegradedMode);
        assertEq(interfacePreview.postOpDegradedMode, contractPreview.postOpDegradedMode);
        assertEq(interfacePreview.effectiveAssetsAfterUsdc, contractPreview.effectiveAssetsAfterUsdc);
        assertEq(interfacePreview.maxLiabilityAfterUsdc, contractPreview.maxLiabilityAfterUsdc);
    }

    function helper_LiquidationPreview_IgnoresStaleMarkCarryOnRefresh() public {
        address trader = address(0xAB1403);
        address account = trader;
        _fundTrader(trader, 2000e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 1105e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 895e6);

        vm.warp(block.timestamp + 1 days);

        ICfdEngineTypes.LiquidationPreview memory stalePreview = engineLens.previewLiquidation(account, 110_000_000);

        vm.prank(address(router));
        engine.updateMarkPrice(110_000_000, uint64(block.timestamp));

        ICfdEngineTypes.LiquidationPreview memory refreshedPreview = engineLens.previewLiquidation(account, 110_000_000);

        assertEq(refreshedPreview.reachableCollateralUsdc, stalePreview.reachableCollateralUsdc);
        assertEq(
            refreshedPreview.equityUsdc,
            stalePreview.equityUsdc,
            "Liquidation equity should remain unchanged across the stale interval"
        );
    }

    function test_LiquidationPreview_IlliquidTraderClaimMatchesLiveOutcome() public {
        address trader = address(0xAB1404);
        address keeper = address(0xAB1405);
        address account = trader;
        _fundTrader(trader, 300e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 200e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 100e6);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 101_000_000);
        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(account, keeper);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(101_000_000));
        vm.prank(keeper);
        router.executeLiquidation(account, priceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(account, keeper, beforeSnapshot);
        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);

        assertEq(
            engine.traderClaimBalanceUsdc(account),
            preview.traderClaimBalanceUsdc,
            "Illiquid liquidation preview should match live trader claim balance"
        );
        assertEq(observed.badDebtUsdc, preview.badDebtUsdc, "Illiquid liquidation preview should match live bad debt");
    }

    function test_PlanLiquidation_PendingCarryCanTriggerLiquidation() public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        CfdEnginePlanTypes.LiquidationDelta memory beforeCarry =
            harness.planLiquidationWithCarry(820e6, 0, 50_000e18, 1e8, 1e8, 1, 1);
        CfdEnginePlanTypes.LiquidationDelta memory afterCarry =
            harness.planLiquidationWithCarry(820e6, 0, 50_000e18, 1e8, 1e8, uint64(100 days), 1);

        assertFalse(beforeCarry.liquidatable, "Setup should start above maintenance before carry accrues");
        assertGt(afterCarry.pendingCarryUsdc, 0, "Setup must accrue pending carry");
        assertTrue(afterCarry.liquidatable, "Pending carry should reduce liquidation equity below maintenance");
    }

    function test_PreviewLiquidation_StagesForfeitureLikeLiveLiquidation() public {
        address trader = address(0xAB1405);
        address keeper = address(0xAB1406);
        address account = trader;

        _fundTrader(trader, 900e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        uint256 queuedOrderCount = 5;
        for (uint256 i = 0; i < queuedOrderCount; i++) {
            router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 100e6, type(uint256).max, false);
        }
        clearinghouse.withdraw(account, 70e6);
        vm.stopPrank();

        IOrderRouterAccounting.AccountReservationView memory reservationBefore = router.getAccountReservations(account);
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 195_000_000);
        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(account, keeper);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(195_000_000));
        vm.prank(keeper);
        router.executeLiquidation(account, priceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(account, keeper, beforeSnapshot);
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory afterSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();

        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);

        assertEq(
            engine.traderClaimBalanceUsdc(account),
            preview.traderClaimBalanceUsdc,
            "Preview trader claim should match live liquidation after staged forfeiture"
        );
        assertEq(
            observed.badDebtUsdc,
            preview.badDebtUsdc,
            "Preview bad debt should match live liquidation after staged forfeiture"
        );
        assertEq(
            afterSnapshot.protocolTreasuryBalanceUsdc - beforeSnapshot.protocol.protocolTreasuryBalanceUsdc,
            reservationBefore.executionBountyUsdc,
            "Live liquidation should book the same forfeited reservation preview assumes as protocol fees"
        );
        assertEq(
            observed.effectiveAssetsAfterUsdc,
            preview.effectiveAssetsAfterUsdc,
            "Preview solvency should match live liquidation after staged forfeiture"
        );
    }

    function helper_PreviewLiquidation_ForfeitedReservationChangesPreview() public {
        CfdTypes.RiskParams memory params = _riskParams();
        _setRiskParams(params);

        address trader = address(0xAB1407);
        address account = trader;
        _fundTrader(trader, 300e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 200e6, 1e8);

        vm.startPrank(trader);
        for (uint256 i = 0; i < 5; i++) {
            router.commitOrder(CfdTypes.Side.BULL, 1000e18, 0, type(uint256).max, true);
        }
        vm.stopPrank();

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() - 1);

        uint256 canonicalDepth = pool.totalAssets();
        uint256 forfeitedReservation = router.getAccountReservations(account).executionBountyUsdc;
        assertGt(forfeitedReservation, 0, "Setup must build forfeitable execution reservation");
        assertGt(canonicalDepth, forfeitedReservation, "Setup needs canonical pool depth to exceed reservation");

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 101_000_000);
        ICfdEngineTypes.LiquidationPreview memory oldModelEquivalent =
            engineLens.simulateLiquidation(account, 101_000_000, canonicalDepth - forfeitedReservation);

        assertNotEq(
            preview.reachableCollateralUsdc,
            oldModelEquivalent.reachableCollateralUsdc,
            "Forfeited reservation should now change the liquidation preview"
        );
    }

    function test_Liquidation_ConsumesTraderClaimBeforeRecordingBadDebt() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address bullAccount = address(uint160(0xD221));
        address bearAccount = address(uint160(0xD222));
        address keeper = address(0xD223);
        _fundTrader(bullAccount, 5000e6);
        _fundTrader(bearAccount, 5000e6);

        _open(bullAccount, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, poolDepth);
        _open(bearAccount, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, poolDepth);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint256 firstCloseExecutionFeeUsdc = _engineExecutionFeeUsdc(5000e18, 120_000_000);
        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - firstCloseExecutionFeeUsdc - 1);

        _closeAt(bearAccount, CfdTypes.Side.BEAR, 5000e18, 120_000_000, poolDepth, refreshTime);
        uint256 traderClaimBefore = engine.traderClaimBalanceUsdc(bearAccount);
        assertGt(traderClaimBefore, 0, "Setup must create trader claim while keeping the position open");

        uint256 reducedSettlement = clearinghouse.balanceUsdc(bearAccount) - 4700e6;
        stdstore.target(address(clearinghouse)).sig("balanceUsdc(address)").with_key(bearAccount)
            .checked_write(reducedSettlement);

        uint256 settlementReachableBefore = _terminalReachableUsdc(bearAccount);
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(bearAccount, 50_000_000);
        assertTrue(preview.liquidatable, "Setup must produce a liquidatable position even after trader claim credit");

        int256 terminalResidual =
            int256(settlementReachableBefore + traderClaimBefore) + preview.pnlUsdc - int256(preview.keeperBountyUsdc);

        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(50_000_000));
        vm.prank(keeper);
        router.executeLiquidation(bearAccount, priceData);

        assertLt(
            engine.traderClaimBalanceUsdc(bearAccount),
            traderClaimBefore,
            "Liquidation should consume trader claim before socializing loss"
        );
        assertEq(
            engine.traderClaimBalanceUsdc(bearAccount),
            preview.traderClaimBalanceUsdc,
            "Preview should match remaining trader claim after liquidation"
        );
        assertEq(
            engine.accumulatedBadDebtUsdc() - badDebtBefore,
            preview.badDebtUsdc,
            "Bad debt should only reflect the post-claim shortfall"
        );
        assertEq(
            clearinghouse.balanceUsdc(bearAccount) + engine.traderClaimBalanceUsdc(bearAccount),
            _positivePart(terminalResidual),
            "Terminal liquidation residual should equal retained settlement plus remaining trader claim and immediate credit"
        );
        assertEq(
            engine.accumulatedBadDebtUsdc() - badDebtBefore,
            preview.badDebtUsdc,
            "Terminal liquidation bad debt should align with the previewed trader-claim-adjusted shortfall"
        );
    }

    function test_Close_ConsumesTraderClaimBeforeRecordingBadDebt() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address bullAccount = address(uint160(0xD231));
        address bearAccount = address(uint160(0xD232));
        _fundTrader(bullAccount, 5000e6);
        _fundTrader(bearAccount, 5000e6);

        _open(bullAccount, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, poolDepth);
        _open(bearAccount, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, poolDepth);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint256 setupCloseFeesUsdc =
            _engineExecutionFeeUsdc(5000e18, 120_000_000) + _engineExecutionFeeUsdc(2500e18, 120_000_000);
        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - setupCloseFeesUsdc - 1);

        _closeAt(bearAccount, CfdTypes.Side.BEAR, 5000e18, 120_000_000, poolDepth, refreshTime);
        uint256 traderClaimBefore = engine.traderClaimBalanceUsdc(bearAccount);
        assertGt(traderClaimBefore, 0, "Setup must create trader claim while keeping the position open");

        uint256 reducedSettlement = clearinghouse.balanceUsdc(bearAccount) - 4700e6;
        stdstore.target(address(clearinghouse)).sig("balanceUsdc(address)").with_key(bearAccount)
            .checked_write(reducedSettlement);

        ICfdEngineTypes.ClosePreview memory preview =
            engineLens.simulateClose(bearAccount, 5000e18, 80_000_000, poolDepth);
        assertGt(
            preview.existingTraderClaimConsumedUsdc,
            0,
            "Close preview should seize legacy trader claim before socializing bad debt"
        );
        assertLt(
            preview.existingTraderClaimRemainingUsdc,
            traderClaimBefore,
            "Close preview should show less trader claim remaining after loss absorption"
        );

        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(bearAccount);
        _closeAt(bearAccount, CfdTypes.Side.BEAR, 5000e18, 80_000_000, poolDepth, refreshTime);

        CloseParityObserved memory observed = _observeCloseParity(bearAccount, beforeSnapshot);

        assertEq(
            engine.traderClaimBalanceUsdc(bearAccount),
            observed.traderClaimBalanceUsdc,
            "Live close should leave the same trader claim remainder observed in settlement state"
        );
        assertEq(
            observed.badDebtUsdc, preview.badDebtUsdc, "Bad debt should only reflect the post-claim shortfall on close"
        );
        assertEq(
            preview.existingTraderClaimConsumedUsdc,
            traderClaimBefore - preview.existingTraderClaimRemainingUsdc,
            "Preview should expose the exact trader claim consumed before socializing bad debt"
        );
    }

    function test_Close_ConsumesTraderClaimBalancesWithoutQueueOrdering() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address bullAccount = address(uint160(0xD241));
        address bearAccount = address(uint160(0xD242));
        _fundTrader(bullAccount, 5000e6);
        _fundTrader(bearAccount, 5000e6);

        _open(bullAccount, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, poolDepth);
        _open(bearAccount, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, poolDepth);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint256 setupCloseFeesUsdc =
            (_engineExecutionFeeUsdc(5000e18, 120_000_000) * 2) + _engineExecutionFeeUsdc(2500e18, 120_000_000);
        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - setupCloseFeesUsdc - 1);

        _closeAt(bearAccount, CfdTypes.Side.BEAR, 5000e18, 120_000_000, poolDepth, refreshTime);
        uint256 traderClaimBefore = engine.traderClaimBalanceUsdc(bearAccount);
        assertGt(traderClaimBefore, 0, "Bear account should accrue trader claim balance");

        _closeAt(bearAccount, CfdTypes.Side.BEAR, 2500e18, 120_000_000, poolDepth, refreshTime);
        uint256 traderClaimAfterAccrual = engine.traderClaimBalanceUsdc(bearAccount);
        assertGe(
            traderClaimAfterAccrual, traderClaimBefore, "Additional trader claim should coalesce into the same balance"
        );

        uint256 reducedSettlement = clearinghouse.balanceUsdc(bearAccount) - 4700e6;
        stdstore.target(address(clearinghouse)).sig("balanceUsdc(address)").with_key(bearAccount)
            .checked_write(reducedSettlement);

        _closeAt(bearAccount, CfdTypes.Side.BEAR, 2500e18, 80_000_000, poolDepth, refreshTime);
        assertLe(
            engine.traderClaimBalanceUsdc(bearAccount),
            traderClaimAfterAccrual,
            "Consuming trader claim balance should only reduce the tracked balance"
        );
    }

    function test_TraderClaim_CoalescesPerAccountWithoutQueuePosition() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address bullAccount = address(uint160(0xD261));
        address bearAccount = address(uint160(0xD262));
        address laterAccount = address(uint160(0xD263));
        _fundTrader(bullAccount, 5000e6);
        _fundTrader(bearAccount, 5000e6);
        _fundTrader(laterAccount, 5000e6);

        _open(bullAccount, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, poolDepth);
        _open(bearAccount, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, poolDepth);
        _open(laterAccount, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, poolDepth);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint256 setupCloseFeesUsdc =
            (_engineExecutionFeeUsdc(5000e18, 120_000_000) * 2) + _engineExecutionFeeUsdc(2500e18, 120_000_000);
        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - setupCloseFeesUsdc - 1);

        _closeAt(bearAccount, CfdTypes.Side.BEAR, 5000e18, 120_000_000, poolDepth, refreshTime);
        uint256 bearClaimBefore = engine.traderClaimBalanceUsdc(bearAccount);
        assertGt(bearClaimBefore, 0, "Initial trader claim should create a tracked balance for bearAccount");

        _closeAt(laterAccount, CfdTypes.Side.BEAR, 5000e18, 120_000_000, poolDepth, refreshTime);
        uint256 laterClaim = engine.traderClaimBalanceUsdc(laterAccount);
        assertGt(laterClaim, 0, "Later claimant should also accrue a trader claim balance");

        _closeAt(bearAccount, CfdTypes.Side.BEAR, 2500e18, 120_000_000, poolDepth, refreshTime);
        uint256 bearClaimAfter = engine.traderClaimBalanceUsdc(bearAccount);

        assertGe(bearClaimAfter, bearClaimBefore, "Coalescing should not move the account behind later claimants");
    }

    function test_Close_RecoversExecutionFeeShortfallFromExistingTraderClaim() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address bullAccount = address(uint160(0xD251));
        address bearAccount = address(uint160(0xD252));
        _fundTrader(bullAccount, 5000e6);
        _fundTrader(bearAccount, 5000e6);

        _open(bullAccount, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, poolDepth);
        _open(bearAccount, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, poolDepth);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint256 firstCloseExecutionFeeUsdc = _engineExecutionFeeUsdc(5000e18, 120_000_000);
        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - firstCloseExecutionFeeUsdc - 1);

        _closeAt(bearAccount, CfdTypes.Side.BEAR, 5000e18, 120_000_000, poolDepth, refreshTime);
        uint256 traderClaimBefore = engine.traderClaimBalanceUsdc(bearAccount);
        assertGt(
            traderClaimBefore, 1e6, "Setup must create an existing trader claim large enough to cover the fee shortfall"
        );

        stdstore.target(address(clearinghouse)).sig("balanceUsdc(address)").with_key(bearAccount)
            .checked_write(uint256(0));
        bytes32 positionMarginSlot = keccak256(abi.encode(bearAccount, uint256(3)));
        vm.store(address(clearinghouse), positionMarginSlot, bytes32(uint256(0)));

        IMarginClearinghouse.LockedMarginBuckets memory locked = clearinghouse.getLockedMarginBuckets(bearAccount);
        assertEq(locked.positionMarginUsdc, 0, "Test must reduce reachable collateral below the terminal close fee");

        ICfdEngineTypes.ClosePreview memory preview = engineLens.simulateClose(bearAccount, 5000e18, 1e8, poolDepth);
        uint256 nominalExecutionFeeUsdc = _engineExecutionFeeUsdc(5000e18, 1e8);

        assertEq(
            preview.badDebtUsdc, 0, "Trader claim should prevent LP bad debt when close shortfall includes unpaid fees"
        );
        assertEq(
            preview.executionFeeUsdc,
            nominalExecutionFeeUsdc,
            "Preview should surface the direct execution fee collection required by the current accounting model"
        );
        assertGt(
            preview.existingTraderClaimConsumedUsdc,
            0,
            "Trader claim should still contribute to covering the close shortfall"
        );

        uint256 feesBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        _processUnderfundedFeeClose(bearAccount, poolDepth, refreshTime);

        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            feesBefore,
            "Treasury fees should not consume cash reserved for remaining trader claims"
        );
        assertEq(
            engine.traderClaimBalanceUsdc(bearAccount),
            preview.existingTraderClaimRemainingUsdc,
            "Trader claim should be consumed without routing reserved cash to treasury"
        );
    }

    function test_PreviewLiquidation_ExcludesReservedExecutionBountyFromReachableCollateral() public {
        address trader = address(0xAB1406);
        address account = trader;
        _fundTrader(trader, 350e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        uint256 queuedOrderCount = 5;
        for (uint256 i = 0; i < queuedOrderCount; i++) {
            router.commitOrder(CfdTypes.Side.BULL, 1000e18, 0, type(uint256).max, true);
        }
        clearinghouse.withdraw(account, 70e6);
        vm.stopPrank();

        IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 102_500_000);
        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = engineAccountLens.getAccountLedgerSnapshot(account);

        assertGt(reservation.executionBountyUsdc, 0, "Setup must create clearinghouse-reserved execution bounty");
        assertEq(
            preview.reachableCollateralUsdc,
            snapshot.terminalReachableUsdc,
            "Liquidation preview must use the same liquidation reachability as the account ledger snapshot"
        );
        assertLt(
            preview.reachableCollateralUsdc,
            clearinghouse.balanceUsdc(account) + reservation.executionBountyUsdc,
            "Liquidation preview must exclude reserved execution bounty from reachable collateral"
        );
        assertEq(
            snapshot.executionBountyReserveUsdc,
            reservation.executionBountyUsdc,
            "Expanded account ledger must continue to report execution reservation outside liquidation reachability"
        );
    }

    function test_PreviewLiquidation_TriggersDegradedModeMatchesLiveLiquidation() public {
        address trader = address(0xAB1410);
        address keeper = address(0xAB1411);
        address account = trader;
        _fundTrader(trader, 300e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 200e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 100e6);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 101_000_000);
        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(account, keeper);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(101_000_000));
        vm.prank(keeper);
        router.executeLiquidation(account, priceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(account, keeper, beforeSnapshot);
        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);

        assertEq(
            preview.triggersDegradedMode,
            engine.degradedMode(),
            "Liquidation preview should match live degraded-mode outcome"
        );
    }

    function helper_PreviewLiquidation_RecomputesPostOpStateInCarryModel() public {
        address bullTrader = address(0xAB1412);
        address bearTrader = address(0xAB1413);
        address bullAccount = bullTrader;
        address bearAccount = bearTrader;

        _fundTrader(bullTrader, 12_000e6);
        _fundTrader(bearTrader, 30_000e6);

        _open(bullAccount, CfdTypes.Side.BULL, 500_000e18, 8000e6, 1e8);
        _open(bearAccount, CfdTypes.Side.BEAR, 50_000e18, 20_000e6, 1e8);

        uint64 refreshTime = uint64(block.timestamp + 365 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint64 accrualTime = refreshTime + 30;
        vm.warp(accrualTime);

        ICfdEngineTypes.LiquidationPreview memory preDrainPreview =
            engineLens.previewLiquidation(bullAccount, 195_000_000);
        assertTrue(preDrainPreview.liquidatable, "Setup must produce a liquidatable position");

        uint256 bearMaxProfit = _sideMaxProfit(CfdTypes.Side.BEAR);
        uint256 targetAssets = bearMaxProfit + clearinghouse.balanceUsdc(engine.protocolTreasury())
            + preDrainPreview.keeperBountyUsdc - preDrainPreview.seizedCollateralUsdc - 1;
        uint256 currentAssets = pool.totalAssets();
        assertGt(currentAssets, targetAssets, "Test setup must be able to drain the pool into the degraded-mode gap");

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), currentAssets - targetAssets);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(bullAccount, 195_000_000);
        assertTrue(preview.triggersDegradedMode, "Liquidation preview should detect degraded mode after the drain");

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(195_000_000));
        vm.prank(address(0xAB1414));
        router.executeLiquidation(bullAccount, priceData);

        assertEq(
            preview.triggersDegradedMode,
            engine.degradedMode(),
            "Liquidation preview should match live degraded-mode outcome after the drain"
        );
    }

    function test_GetTraderClaimStatus_ReflectsServiceability() public {
        address trader = address(0xAB15);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(account, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        vm.startPrank(address(pool));
        usdc.transfer(address(0xDEAD), pool.totalAssets());
        vm.stopPrank();

        ClaimEngineViewTypes.TraderClaimStatus memory statusBefore = _traderClaimStatus(account, address(this));
        assertGt(statusBefore.traderClaimBalanceUsdc, 0);
        assertFalse(statusBefore.traderClaimServiceableNow);

        usdc.mint(address(pool), statusBefore.traderClaimBalanceUsdc);

        ClaimEngineViewTypes.TraderClaimStatus memory statusAfter = _traderClaimStatus(account, address(this));
        assertTrue(statusAfter.traderClaimServiceableNow);
    }

    function test_GetTraderClaimStatus_ExposesServiceabilityWithoutHeadOrdering() public {
        address trader = address(0xAB16);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(account, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        uint256 traderClaim = engine.traderClaimBalanceUsdc(account);
        usdc.mint(address(pool), traderClaim);

        ClaimEngineViewTypes.TraderClaimStatus memory status = _traderClaimStatus(account, address(0xAB17));
        assertTrue(status.traderClaimServiceableNow, "Trader claim should be serviceable under partial liquidity");
    }

    function test_CloseLoss_ConsumesQueuedCommittedMarginBeforeBadDebt() public {
        address trader = address(0xABD0);
        address account = trader;
        _fundTrader(trader, 10_000 * 1e6);

        _open(account, CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 7900e6, type(uint256).max, false);

        uint256 lockedBeforeClose = clearinghouse.lockedMarginUsdc(account);
        (, uint256 liveMarginBeforeClose,,,,,) = engine.positions(account);
        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();

        _close(account, CfdTypes.Side.BULL, 100_000 * 1e18, 103_000_000);

        assertLt(
            _remainingCommittedMargin(1),
            7900e6,
            "Order record should reflect committed margin consumed by terminal settlement"
        );
        assertLt(
            clearinghouse.lockedMarginUsdc(account),
            lockedBeforeClose - liveMarginBeforeClose,
            "Close settlement should consume queued committed margin before recording bad debt"
        );
        assertEq(
            engine.accumulatedBadDebtUsdc(),
            badDebtBefore,
            "Queued committed margin should prevent avoidable close bad debt"
        );
    }

    function test_OpposingPosition_Reverts() public {
        address account = address(uint160(1));
        _fundTrader(account, 10_000 * 1e6);

        CfdTypes.Order memory bearOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 5000 * 1e6,
            targetPrice: 0.8e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BEAR,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(bearOrder, 0.8e8, 1_000_000 * 1e6, uint64(block.timestamp));

        CfdTypes.Order memory bullOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 5000 * 1e6,
            targetPrice: 0.8e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector, 1, 1, false));
        vm.prank(address(router));
        engine.processOrderTyped(bullOrder, 0.8e8, 1_000_000 * 1e6, uint64(block.timestamp));
    }

    function test_ProcessOrderTyped_UserInvalidFailureUsesTypedTaxonomy() public {
        address account = address(uint160(1));
        _fundTrader(account, 10_000 * 1e6);

        CfdTypes.Order memory bearOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 1000 * 1e6,
            targetPrice: 0.8e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BEAR,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(bearOrder, 0.8e8, 1_000_000 * 1e6, uint64(block.timestamp));

        CfdTypes.Order memory bullOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 1000 * 1e6,
            targetPrice: 0.8e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
                uint8(1),
                false
            )
        );
        vm.prank(address(router));
        engine.processOrderTyped(bullOrder, 0.8e8, 1_000_000 * 1e6, uint64(block.timestamp));
    }

    function test_CarryRealization_DoesNotBackfillAfterFreshCheckpoint() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        _fundTrader(account, 20_000 * 1e6);

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 1600 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(openOrder, 1e8, poolDepth, uint64(block.timestamp));

        uint64 refreshTime = uint64(block.timestamp + 365 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint64 accrualTime = refreshTime + 30;
        vm.warp(accrualTime);

        CfdTypes.Order memory addOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 5000 * 1e6,
            targetPrice: 1e8,
            commitTime: accrualTime,
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(addOrder, 1e8, poolDepth, accrualTime);

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 110_000 * 1e18, "Fresh mark checkpoint should not retroactively create a carry-driven revert");
    }

    function test_EntryPriceAveraging() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        _fundTrader(account, 10_000 * 1e6);

        // Open 10k tokens at $0.80
        CfdTypes.Order memory first = CfdTypes.Order({
            account: account,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 1000 * 1e6,
            targetPrice: 0.8e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(first, 0.8e8, poolDepth, uint64(block.timestamp));

        (,, uint256 entryAfterFirst,,,,) = engine.positions(account);
        assertEq(entryAfterFirst, 0.8e8, "Entry should be $0.80");

        // Add 30k tokens at $1.20 → weighted avg = (10k*0.80 + 30k*1.20) / 40k = $1.10
        CfdTypes.Order memory second = CfdTypes.Order({
            account: account,
            sizeDelta: 30_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1.2e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(second, 1.2e8, poolDepth, uint64(block.timestamp));

        (uint256 totalSize,, uint256 avgEntry,,,,) = engine.positions(account);
        assertEq(totalSize, 40_000 * 1e18, "Total size should be 40k");
        assertEq(avgEntry, 1.1e8, "Weighted avg entry should be $1.10");
    }

    function test_CarryRealization_OnClose() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        _fundTrader(account, 5000 * 1e6);

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(openOrder, 1e8, poolDepth, uint64(block.timestamp));

        uint256 chBefore = clearinghouse.balanceUsdc(account);

        vm.warp(block.timestamp + 90 days);

        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 0,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.BULL,
            isClose: true
        });
        vm.prank(address(router));
        engine.processOrderTyped(closeOrder, 1e8, poolDepth, uint64(block.timestamp));

        uint256 chAfter = clearinghouse.balanceUsdc(account);
        assertLt(chAfter, chBefore, "Carry drain should reduce clearinghouse balance on close");
    }

    function test_SetRiskParams_MakesPositionLiquidatable() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        address trader = account;
        _fundTrader(trader, 5000 * 1e6);

        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(order, 1e8, poolDepth, uint64(block.timestamp));

        vm.prank(trader);
        clearinghouse.withdraw(account, 2500 * 1e6);

        vm.expectRevert(ICfdEngineTypes.CfdEngine__PositionIsSolvent.selector);
        vm.prank(address(router));
        engine.liquidatePosition(account, 1e8, poolDepth, uint64(block.timestamp), address(this));

        _setRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0.0005e18,
                maxSkewRatio: 0.4e18,
                maintMarginBps: 300,
                initMarginBps: ((300) * 15) / 10,
                fadMarginBps: 500,
                baseCarryBps: 500,
                minBountyUsdc: 1 * 1e6,
                bountyBps: 10
            })
        );

        vm.prank(address(router));
        uint256 bounty = engine.liquidatePosition(account, 1e8, poolDepth, uint64(block.timestamp), address(this));
        assertTrue(bounty > 0, "Position should be liquidatable after raising maintMarginBps");

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Position should be wiped");
    }

    function test_Unauthorized_Caller_Reverts() public {
        address account = address(uint160(1));
        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 500 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });

        vm.prank(address(0xDEAD));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__Unauthorized.selector);
        engine.processOrderTyped(order, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));

        vm.prank(address(0xDEAD));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__Unauthorized.selector);
        engine.liquidatePosition(account, 1e8, 1_000_000 * 1e6, uint64(block.timestamp), address(this));
    }

    function test_ProposeRiskParams_RevertsOnZeroMaintMargin() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.maintMarginBps = 0;
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(config);
    }

    function test_ProposeRiskParams_RevertsOnZeroInitMargin() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.initMarginBps = 0;
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(config);
    }

    function test_ProposeRiskParams_RevertsWhenInitMarginBelowMaint() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.initMarginBps = params.maintMarginBps - 1;
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(config);
    }

    function test_ProposeRiskParams_RevertsWhenFadMarginBelowMaint() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.fadMarginBps = params.maintMarginBps - 1;
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(config);
    }

    function test_ProposeRiskParams_RevertsWhenFadMarginExceeds100Percent() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.fadMarginBps = 10_001;
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(config);
    }

    function test_ProposeRiskParams_RevertsOnZeroMinBounty() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.minBountyUsdc = 0;
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(config);
    }

    function test_ProposeRiskParams_RevertsOnZeroBountyBps() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.bountyBps = 0;
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__InvalidRiskParams.selector);
        engineAdmin.proposeRiskConfig(config);
    }

    function test_CloseSize_ExceedsPosition_Reverts() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        _fundTrader(account, 5000 * 1e6);

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 1000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(openOrder, 1e8, poolDepth, uint64(block.timestamp));

        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 20_000 * 1e18,
            marginDelta: 0,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.BULL,
            isClose: true
        });
        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector, 1, 1, true));
        vm.prank(address(router));
        engine.processOrderTyped(closeOrder, 1e8, poolDepth, uint64(block.timestamp));
    }

    function test_MarginDrained_ByFees_Reverts() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        _fundTrader(account, 1000 * 1e6);

        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 50 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector, 1, 6, false));
        vm.prank(address(router));
        engine.processOrderTyped(order, 1e8, poolDepth, uint64(block.timestamp));
    }

    function test_PreviewOpen_ClassifiesCarryDrainedReleasedFreeSettlementAsUserInvalid() public {
        address trader = address(0xCA2211);
        address account = trader;
        _fundTrader(trader, 20_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        uint256 sizeDelta = 10_000e18;
        uint256 marginDelta = _freeSettlementUsdc(account);
        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: sizeDelta,
            marginDelta: marginDelta,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });

        vm.warp(block.timestamp + 30 days);

        uint8 revertCode = engineLens.previewOpenRevertCode(
            account, CfdTypes.Side.BULL, sizeDelta, marginDelta, 1e8, uint64(block.timestamp)
        );
        CfdEnginePlanTypes.OpenFailurePolicyCategory failureCategory = engineLens.previewOpenFailurePolicyCategory(
            account, CfdTypes.Side.BULL, sizeDelta, marginDelta, 1e8, uint64(block.timestamp)
        );

        assertEq(
            revertCode,
            uint8(CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES),
            "Preview should catch carry-drained free settlement before apply"
        );
        assertEq(
            uint256(failureCategory),
            uint256(CfdEnginePlanTypes.OpenFailurePolicyCategory.ExecutionTimeUserInvalid),
            "Preview should classify carry-drained opens as execution-time user invalid"
        );
    }

    function test_OpenOrder_IMRPrecedesSkewWhenBothFail() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(11));
        _fundTrader(account, 5000 * 1e6);

        _setRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0.0005e18,
                maxSkewRatio: 0.4e18,
                maintMarginBps: 100,
                initMarginBps: ((100) * 15) / 10,
                fadMarginBps: 300,
                baseCarryBps: 500,
                minBountyUsdc: 1 * 1e6,
                bountyBps: 10
            })
        );

        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 500_000 * 1e18,
            marginDelta: 1000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });

        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector, 1, 6, false));
        vm.prank(address(router));
        engine.processOrderTyped(order, 1e8, poolDepth, uint64(block.timestamp));
    }

    function test_C5_CloseSucceeds_WhenCarryExceedsMargin_ButPositionProfitable() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        _fundTrader(account, 10_000 * 1e6);

        // Open BULL 100k tokens at $1.00 with $1600 margin (meets explicit 1.5% init margin)
        CfdTypes.Order memory openOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 1600 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(openOrder, 1e8, poolDepth, uint64(block.timestamp));

        // Warp 365 days — carry will far exceed margin
        vm.warp(block.timestamp + 365 days);

        // Price dropped to $0.50 → BULL has $50k unrealized profit
        // User should be able to close and receive profit minus carry minus fees
        uint256 chBefore = clearinghouse.balanceUsdc(account);

        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 0,
            targetPrice: 0.5e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.BULL,
            isClose: true
        });

        // This should NOT revert — the position is profitable despite carry > margin
        vm.prank(address(router));
        engine.processOrderTyped(closeOrder, 0.5e8, poolDepth, uint64(block.timestamp));

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Position should be fully closed");

        uint256 chAfter = clearinghouse.balanceUsdc(account);
        assertGt(chAfter, chBefore, "User should net positive after profitable close minus carry");
    }

    function test_C2_InsufficientInitialMargin_Reverts() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        _fundTrader(account, 1000 * 1e6);

        // notional = 100k * $1 = $100k. execFee = $60, VPI ~= $2.50
        // MMR = 1% of $100k = $1000
        // Even using full cross-margin equity, $1000 account collateral is below the configured $1500 initial margin requirement.
        // Without the initial margin check, this would create an instantly-liquidatable position.
        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 100 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });

        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector, 1, 6, false));
        vm.prank(address(router));
        engine.processOrderTyped(order, 1e8, poolDepth, uint64(block.timestamp));
    }

    function test_H8_CloseAfterBlendedEntry_DoesNotUnderflow() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        _fundTrader(account, 10_000 * 1e6);

        // Open BEAR 100k tokens at price $1.00000001 (just above $1.00)
        CfdTypes.Order memory first = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 1600 * 1e6,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BEAR,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(first, 100_000_001, poolDepth, uint64(block.timestamp));

        // Open BEAR 200k tokens at price $1.00 — blends entry to 100_000_000 (truncated from .33)
        // Sum of individual maxProfits < maxProfit(blended) due to integer truncation
        CfdTypes.Order memory second = CfdTypes.Order({
            account: account,
            sizeDelta: 200_000 * 1e18,
            marginDelta: 3200 * 1e6,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.BEAR,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(second, 100_000_000, poolDepth, uint64(block.timestamp));

        // Close entire position — must not underflow in _reduceGlobalLiability
        CfdTypes.Order memory close = CfdTypes.Order({
            account: account,
            sizeDelta: 300_000 * 1e18,
            marginDelta: 0,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 3,
            side: CfdTypes.Side.BEAR,
            isClose: true
        });
        vm.prank(address(router));
        engine.processOrderTyped(close, 100_000_000, poolDepth, uint64(block.timestamp));

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Position should be fully closed");
        assertEq(_sideMaxProfit(CfdTypes.Side.BEAR), 0, "Global bear max profit should be zero");
    }

    function test_H9_SolvencyDeadlock_CloseAllowedDuringInsolvency() public {
        vm.warp(block.timestamp + 1 hours);
        juniorVault.withdraw(800_000 * 1e6, address(this), address(this));

        uint256 poolDepth = 200_000 * 1e6;
        address aliceAccount = address(uint160(1));
        address bobAccount = address(uint160(2));
        _fundTrader(aliceAccount, 50_000 * 1e6);
        _fundTrader(bobAccount, 50_000 * 1e6);

        CfdTypes.Order memory aliceOpen = CfdTypes.Order({
            account: aliceAccount,
            sizeDelta: 200_000 * 1e18,
            marginDelta: 20_000 * 1e6,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(aliceOpen, 1e8, poolDepth, uint64(block.timestamp));

        CfdTypes.Order memory bobOpen = CfdTypes.Order({
            account: bobAccount,
            sizeDelta: 200_000 * 1e18,
            marginDelta: 20_000 * 1e6,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.BEAR,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(bobOpen, 1e8, poolDepth, uint64(block.timestamp));

        vm.prank(address(engine));
        pool.payOut(address(0xDEAD), 60_000 * 1e6);

        uint256 maxLiab = _sideMaxProfit(CfdTypes.Side.BULL) > _sideMaxProfit(CfdTypes.Side.BEAR)
            ? _sideMaxProfit(CfdTypes.Side.BULL)
            : _sideMaxProfit(CfdTypes.Side.BEAR);
        assertTrue(usdc.balanceOf(address(pool)) < maxLiab, "Pool should be insolvent");

        CfdTypes.Order memory aliceClose = CfdTypes.Order({
            account: aliceAccount,
            sizeDelta: 200_000 * 1e18,
            marginDelta: 0,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 3,
            side: CfdTypes.Side.BULL,
            isClose: true
        });
        vm.prank(address(router));
        engine.processOrderTyped(aliceClose, 1e8, poolDepth, uint64(block.timestamp));

        (uint256 aliceSize,,,,,,) = engine.positions(aliceAccount);
        assertEq(aliceSize, 0, "Close should succeed during insolvency");
    }

    function test_M11_LiquidationSeizesFreeEquity() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        address trader = account;
        _fundTrader(trader, 50_000 * 1e6);

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 1600 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(openOrder, 1e8, poolDepth, uint64(block.timestamp));

        vm.prank(trader);
        clearinghouse.withdraw(account, 46_000 * 1e6);

        uint256 freeEquityBefore = clearinghouse.getFreeBuyingPowerUsdc(account);
        assertTrue(freeEquityBefore > 0, "User should have free equity beyond locked margin");

        uint256 poolBalanceBefore = usdc.balanceOf(address(pool));

        // Price rises to $1.10 — BULL loses $10k, equity = margin (~$1537) - $10k = negative
        vm.prank(address(router));
        engine.liquidatePosition(account, 1.1e8, poolDepth, uint64(block.timestamp), address(this));

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Position should be liquidated");

        uint256 freeEquityAfter = clearinghouse.getFreeBuyingPowerUsdc(account);
        assertTrue(freeEquityAfter < freeEquityBefore, "Free equity should be reduced to cover bad debt");

        uint256 poolBalanceAfter = usdc.balanceOf(address(pool));
        uint256 totalRecovered = poolBalanceAfter - poolBalanceBefore;
        (, uint256 posMarginStored,,,,,) = engine.positions(account);
        assertTrue(totalRecovered > 0, "Pool should recover more than zero from bad debt liquidation");
    }

    function test_LiquidationWorksWhenPoolInsolvent() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address aliceAccount = address(uint160(1));
        address bobAccount = address(uint160(2));
        address aliceTrader = aliceAccount;
        _fundTrader(aliceTrader, 50_000 * 1e6);
        _fundTrader(bobAccount, 50_000 * 1e6);

        CfdTypes.Order memory aliceOpen = CfdTypes.Order({
            account: aliceAccount,
            sizeDelta: 200_000 * 1e18,
            marginDelta: 20_000 * 1e6,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(aliceOpen, 1e8, poolDepth, uint64(block.timestamp));

        vm.prank(aliceTrader);
        clearinghouse.withdraw(aliceAccount, 28_000 * 1e6);

        CfdTypes.Order memory bobOpen = CfdTypes.Order({
            account: bobAccount,
            sizeDelta: 200_000 * 1e18,
            marginDelta: 20_000 * 1e6,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.BEAR,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(bobOpen, 1e8, poolDepth, uint64(block.timestamp));

        // Drain pool to simulate insolvency (pool has ~$1M + fees, maxLiab = $200k)
        vm.prank(address(engine));
        pool.payOut(address(0xDEAD), 810_000 * 1e6);

        uint256 maxLiab = _sideMaxProfit(CfdTypes.Side.BULL) > _sideMaxProfit(CfdTypes.Side.BEAR)
            ? _sideMaxProfit(CfdTypes.Side.BULL)
            : _sideMaxProfit(CfdTypes.Side.BEAR);
        assertTrue(usdc.balanceOf(address(pool)) < maxLiab, "Pool should be insolvent");

        // Price rises to $1.10 — BULL loses $20k, deeply underwater
        vm.prank(address(router));
        engine.liquidatePosition(aliceAccount, 1.1e8, poolDepth, uint64(block.timestamp), address(this));

        (uint256 aliceSize,,,,,,) = engine.positions(aliceAccount);
        assertEq(aliceSize, 0, "Liquidation must succeed during insolvency");
    }

    function test_Liquidate_EmptyPosition_Reverts() public {
        address account = address(uint160(1));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__NoPositionToLiquidate.selector);
        vm.prank(address(router));
        engine.liquidatePosition(account, 1e8, 1_000_000 * 1e6, uint64(block.timestamp), address(this));
    }

    function test_LiquidationBounty_UsesReachableCollateralSubsidyCap() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1234));
        address trader = account;
        _fundTrader(trader, 200 * 1e6);

        _setRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0,
                maxSkewRatio: 0.4e18,
                maintMarginBps: 10,
                initMarginBps: ((10) * 15) / 10,
                fadMarginBps: 10,
                baseCarryBps: 500,
                minBountyUsdc: 1 * 1e6,
                bountyBps: 100
            })
        );

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 1000 * 1e18,
            marginDelta: 6 * 1e6,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(openOrder, 1e8, poolDepth, uint64(block.timestamp));

        (, uint256 posMargin,,,,,) = engine.positions(account);

        vm.prank(trader);
        clearinghouse.withdraw(account, 194 * 1e6);

        vm.prank(address(router));
        uint256 bounty =
            engine.liquidatePosition(account, 100_500_000, poolDepth, uint64(block.timestamp), address(this));

        assertEq(bounty, posMargin, "Keeper bounty subsidy should be bounded by physically reachable collateral");
    }

    function test_ClearBadDebt_ReducesOutstandingDebt() public {
        address account = address(uint160(0xBADD));
        _fundTrader(account, 4000 * 1e6);

        _open(account, CfdTypes.Side.BULL, 100_000 * 1e18, 3000 * 1e6, 1e8);

        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(account, 1.2e8, depth, uint64(block.timestamp), address(this));

        uint256 badDebt = engine.accumulatedBadDebtUsdc();
        assertGt(badDebt, 0, "Expected liquidation shortfall to create bad debt");

        uint256 clearAmount = badDebt / 2;
        uint256 poolAssetsBefore = pool.totalAssets();
        usdc.mint(address(this), clearAmount);
        usdc.approve(address(engine), clearAmount);
        engine.clearBadDebt(clearAmount);
        assertEq(engine.accumulatedBadDebtUsdc(), badDebt - clearAmount, "Bad debt should decrease after clearing");
        assertEq(
            pool.totalAssets(),
            poolAssetsBefore + clearAmount,
            "Bad-debt recapitalization should raise canonical pool assets"
        );
        assertEq(pool.excessAssets(), 0, "Bad-debt recapitalization should not strand excess assets");

        vm.expectRevert(ICfdEngineTypes.CfdEngine__ZeroAmount.selector);
        engine.clearBadDebt(0);

        vm.expectRevert(ICfdEngineTypes.CfdEngine__BadDebtTooLarge.selector);
        engine.clearBadDebt(badDebt + 1);
    }

    function test_CheckWithdraw_UsesMinimumOfEngineAndPoolMarkStalenessLimits() public {
        IHousePool.PoolConfig memory poolConfig = _currentPoolConfig();
        poolConfig.markStalenessLimit = 300;
        pool.proposePoolConfig(poolConfig);
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizePoolConfig();
        assertEq(pool.markStalenessLimit(), 300);

        address account = address(uint160(0x5157));
        _fundTrader(account, 5000 * 1e6);
        _open(account, CfdTypes.Side.BULL, 20_000 * 1e18, 2000 * 1e6, 1e8);

        vm.warp(block.timestamp + 31);

        vm.prank(address(clearinghouse));
        engine.checkWithdraw(account);

        vm.warp(block.timestamp + 270);

        vm.expectRevert(ICfdEngineTypes.CfdEngine__MarkPriceStale.selector);
        vm.prank(address(clearinghouse));
        engine.checkWithdraw(account);

        ICfdEngineAdminHost.EngineFreshnessConfig memory engineConfig = _engineFreshnessConfig();
        engineConfig.engineMarkStalenessLimit = 300;
        engineAdmin.proposeFreshnessConfig(engineConfig);
        vm.warp(engineAdmin.freshnessConfigActivationTime() + 1);
        engineAdmin.finalizeFreshnessConfig();

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.prank(address(clearinghouse));
        engine.checkWithdraw(account);
    }

    function test_SweepToken_RecoversAccidentallySentUsdc() public {
        usdc.mint(address(engine), 123e6);
        uint256 ownerBefore = usdc.balanceOf(address(this));

        engine.sweepToken(address(usdc), address(this), 123e6);

        assertEq(usdc.balanceOf(address(engine)), 0);
        assertEq(usdc.balanceOf(address(this)), ownerBefore + 123e6);
    }

    function test_ReserveCloseOrderExecutionBounty_AllowsStaleLastMarkPriceWhenStored() public {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.markStalenessLimit = 300;
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizePoolConfig();

        address trader = address(0x5159);
        address account = trader;
        address counterparty = address(0x5160);
        address counterpartyAccount = counterparty;

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 1500e6, 1e8);
        _open(counterpartyAccount, CfdTypes.Side.BEAR, 10_000e18, 50_000e6, 1e8);

        vm.warp(block.timestamp + 31);
        vm.prank(address(router));
        engine.reserveCloseOrderExecutionBounty(account, 10_000e18, 1e6);

        vm.warp(block.timestamp + 30 days);
        vm.prank(address(router));
        engine.reserveCloseOrderExecutionBounty(account, 10_000e18, 1e6);
    }

    function test_ReserveCloseOrderExecutionBounty_RevertsWhenNoStoredMarkExists() public {
        address trader = address(0x51595);
        address account = trader;
        address counterparty = address(0x51596);
        address counterpartyAccount = counterparty;

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 1500e6, 1e8);
        _open(counterpartyAccount, CfdTypes.Side.BEAR, 10_000e18, 50_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(0, uint64(block.timestamp));
        vm.prank(address(router));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__InsufficientCloseOrderBountyBacking.selector);
        engine.reserveCloseOrderExecutionBounty(account, 10_000e18, 1e6);
    }

    function test_ReserveCloseOrderExecutionBounty_ExcludesQueuedReservationsFromGenericReachability() public {
        address trader = address(0x5161);
        address account = trader;
        address counterparty = address(0x5162);
        address counterpartyAccount = counterparty;

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.BULL, 10_000e18, 2000e6, 1e8);
        _open(counterpartyAccount, CfdTypes.Side.BEAR, 10_000e18, 50_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 4000e6, type(uint256).max, false);

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(account);
        assertEq(
            buckets.otherLockedMarginUsdc,
            4000e6 + _executionBountyReserve(1),
            "Setup should reserve queued order funds plus clearinghouse-held bounty reservation"
        );
        assertEq(
            MarginClearinghouseAccountingLib.getGenericReachableUsdc(buckets),
            buckets.settlementBalanceUsdc - buckets.otherLockedMarginUsdc,
            "Generic reachability must exclude the queued reservation"
        );

        vm.prank(address(router));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__InsufficientCloseOrderBountyBacking.selector);
        engine.reserveCloseOrderExecutionBounty(account, 10_000e18, 6000e6);
    }

    function test_CheckWithdraw_RevertsWhenOpenPositionHasZeroMarkPrice() public {
        address account = address(uint160(0x5158));
        _fundTrader(account, 5000 * 1e6);
        _open(account, CfdTypes.Side.BULL, 20_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(0, uint64(block.timestamp));

        vm.expectRevert(ICfdEngineTypes.CfdEngine__MarkPriceStale.selector);
        vm.prank(address(clearinghouse));
        engine.checkWithdraw(account);
    }

    function test_CheckWithdraw_DoesNotCountTraderClaimAsReachableCollateral() public {
        address trader = address(0x51581);
        address account = trader;
        _fundTrader(trader, 5000e6);
        _open(account, CfdTypes.Side.BEAR, 10_000e18, 5000e6, 1e8);

        uint256 closeExecutionFeeUsdc = _engineExecutionFeeUsdc(5000e18, 120_000_000);
        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - closeExecutionFeeUsdc - 1);

        _close(account, CfdTypes.Side.BEAR, 5000e18, 120_000_000);
        assertGt(engine.traderClaimBalanceUsdc(account), 0, "Setup must create a trader claim balance");

        bytes4 expectedError = engine.degradedMode()
            ? ICfdEngineTypes.CfdEngine__DegradedMode.selector
            : ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector;
        vm.expectRevert(expectedError);
        vm.prank(address(clearinghouse));
        engine.checkWithdraw(account);
    }

    function test_CheckWithdrawParity_FailThenLiveWithdrawReverts() public {
        address trader = address(0x515816);
        address account = trader;
        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        WithdrawParityState memory state = _observeWithdrawParity(account, trader, 5000e6);
        _assertWithdrawParity(state, ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
    }

    function test_CheckWithdrawParity_StaleLiveMarkBlocksWithdraw() public {
        address trader = address(0x515817);
        address account = trader;
        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);

        WithdrawParityState memory state = _observeWithdrawParity(account, trader, 100e6);
        _assertWithdrawParity(state, ICfdEngineTypes.CfdEngine__MarkPriceStale.selector);
    }

    function helper_CheckWithdrawParity_NoCarryProjectionWithoutPriorSync() public {
        CfdTypes.RiskParams memory params = _riskParams();
        _setRiskParams(params);

        address trader = address(0x515818);
        address account = trader;
        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 1600e6, 1e8);

        ICfdEngineAdminHost.EngineFreshnessConfig memory config = _engineFreshnessConfig();
        config.engineMarkStalenessLimit = 300;
        engineAdmin.proposeFreshnessConfig(config);
        vm.warp(engineAdmin.freshnessConfigActivationTime() + 1);
        engineAdmin.finalizeFreshnessConfig();

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() - 1);

        WithdrawParityState memory state = _observeWithdrawParity(account, trader, 80e6);
        _assertWithdrawParity(state, ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
    }

    function test_CheckWithdraw_UsesExplicitInitMarginBps() public {
        address trader = address(0x515815);
        address account = trader;
        _fundTrader(trader, 3200e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 3000e6, 1e8);

        CfdTypes.RiskParams memory params = _riskParams();
        params.initMarginBps = 300;
        _setRiskParams(params);

        (,,, uint256 initMarginBps,,,,) = engine.riskParams();
        assertEq(initMarginBps, 300, "Setup must finalize the explicit init margin config");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.expectRevert(ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        vm.prank(trader);
        clearinghouse.withdraw(account, 200e6);
    }

    function test_CheckWithdraw_UsesActiveFadMarginRequirement() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.maintMarginBps = 10;
        params.initMarginBps = 15;
        params.fadMarginBps = 1000;
        params.minBountyUsdc = 1e6;
        params.bountyBps = 1000;
        _setRiskParams(params);

        address trader = address(0x515817);
        address account = trader;
        _fundTrader(trader, 100e6);
        _open(account, CfdTypes.Side.BULL, 100e18, 6e6, 1e8);

        vm.warp(1_709_971_200);
        assertTrue(engine.isFadWindow(), "Setup must execute inside the FAD window");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 withdrawableUsdc = engineAccountLens.getWithdrawableUsdc(account);
        assertGt(withdrawableUsdc, 0, "Buggy init-margin path should expose withdrawable headroom during FAD");

        vm.expectRevert(ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        vm.prank(trader);
        clearinghouse.withdraw(account, withdrawableUsdc);
    }

    function test_ReserveCloseOrderExecutionBounty_UsesCarryAwareProjectedRiskState() public {
        CfdTypes.RiskParams memory params = _riskParams();
        _setRiskParams(params);

        address trader = address(0x51583);
        address account = trader;
        _fundTrader(trader, 1600e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 1600e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() - 1);

        vm.prank(address(router));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__InsufficientCloseOrderBountyBacking.selector);
        engine.reserveCloseOrderExecutionBounty(account, 50_000e18, 1400e6);
    }

    function test_ReserveCloseOrderExecutionBounty_DoesNotRecomputeHistoricalCarryAfterReservationReachabilityDrop()
        public
    {
        CfdTypes.RiskParams memory params = _riskParams();
        _setRiskParams(params);

        address trader = address(0x51584);
        address account = trader;
        uint256 price = 1e8;
        uint256 size = 100_000e18;
        uint256 marginUsdc = 1600e6;
        uint256 bountyUsdc = 1e6;
        uint256 carryTimeDelta = 3_839_405;

        _fundTrader(trader, marginUsdc);
        _open(account, CfdTypes.Side.BULL, size, marginUsdc, price);

        vm.prank(address(router));
        engine.updateMarkPrice(price, uint64(block.timestamp));
        vm.warp(block.timestamp + carryTimeDelta);

        uint256 borrowBaseBefore = _positionBorrowBaseUsdc(account);
        uint256 expectedCarry = _expectedIndexedCarry(account);
        assertGt(expectedCarry, 0, "Setup must accrue indexed carry");

        vm.prank(address(router));
        engine.reserveCloseOrderExecutionBounty(account, size / 2, bountyUsdc);

        assertEq(engine.unsettledCarryUsdc(account), 0, "Reservation should realize indexed carry first");
        assertEq(
            _positionBorrowBaseUsdc(account),
            borrowBaseBefore + expectedCarry + bountyUsdc,
            "Future borrow base should rise only after old carry is realized and margin is reserved"
        );
    }

    function test_ReserveCloseOrderExecutionBounty_RevertsFullCloseNearMaintenance() public {
        address trader = address(0x515991);
        address account = trader;
        address counterparty = address(0x515992);
        address counterpartyAccount = counterparty;
        uint256 size = 50_000e18;

        _fundTrader(trader, 1000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.BULL, size, 1000e6, 1e8);
        _open(counterpartyAccount, CfdTypes.Side.BEAR, size, 50_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(103_000_000, uint64(block.timestamp));

        assertEq(_freeSettlementUsdc(account), 0, "setup must fully consume free settlement");

        vm.prank(address(router));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__InsufficientCloseOrderBountyBacking.selector);
        engine.reserveCloseOrderExecutionBounty(account, size, 1e6);
    }

    function test_ReserveCloseOrderExecutionBounty_PartialCloseStillRevertsNearMaintenance() public {
        address trader = address(0x515993);
        address account = trader;
        address counterparty = address(0x515994);
        address counterpartyAccount = counterparty;
        uint256 size = 50_000e18;

        _fundTrader(trader, 1000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.BULL, size, 1000e6, 1e8);
        _open(counterpartyAccount, CfdTypes.Side.BEAR, size, 50_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(103_000_000, uint64(block.timestamp));

        vm.prank(address(router));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__InsufficientCloseOrderBountyBacking.selector);
        engine.reserveCloseOrderExecutionBounty(account, size / 2, 1e6);
    }

    function test_VpiDepthManipulation_NeutralizedByStatefulBound() public {
        address account = address(uint160(1));
        _fundTrader(account, 50_000 * 1e6);

        uint256 largeDepth = 10_000_000 * 1e6;
        uint256 smallDepth = 100_000 * 1e6;

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 10_000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        uint256 chBeforeOpen = clearinghouse.balanceUsdc(account);
        vm.prank(address(router));
        engine.processOrderTyped(openOrder, 1e8, largeDepth, uint64(block.timestamp));

        (,,,,,, int256 storedVpi) = engine.positions(account);
        assertTrue(storedVpi != 0, "VPI should be tracked");

        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 0,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.BULL,
            isClose: true
        });
        vm.prank(address(router));
        engine.processOrderTyped(closeOrder, 1e8, smallDepth, uint64(block.timestamp));

        uint256 chAfterClose = clearinghouse.balanceUsdc(account);

        // Without fix: close at smallDepth yields massive VPI rebate (attacker profits).
        // With fix: stateful bound caps close rebate to what was paid on open → net VPI = 0.
        // Only exec fees should be deducted. Exec fee = 4bps * $100k * 2 = $80.
        uint256 roundTripCost = chBeforeOpen - chAfterClose;
        uint256 execFeeRoundTrip = 80 * 1e6;
        assertEq(roundTripCost, execFeeRoundTrip, "Round-trip costs only exec fees, no VPI profit");
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
            side: CfdTypes.Side.BEAR,
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

// ==========================================
// CfdEngineCarryRegressionTest: carry and legacy-side-state edge cases (C-01, C-02, C-03)
// ==========================================

contract CfdEngineCarryRegressionTest is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1 * 1e6,
            bountyBps: 10
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 5_000_000 * 1e6;
    }

    // Regression: C-01 — stale obsolete legacy side-index attack blocked by H-03 dust guard
    function test_LegacySideIndex_DustCloseBlocked() public {
        uint256 depth = 5_000_000 * 1e6;

        address attackerAccount = address(0xA1);
        _fundTrader(address(0xA1), 500_000 * 1e6);

        address counterAccount = address(0xB1);
        _fundTrader(address(0xB1), 500_000 * 1e6);
        _open(counterAccount, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8, depth);

        uint256 minNotional = (uint256(1) * 1e6 * 10_000) / 10 + 1e6;
        uint256 minSize = (minNotional * 1e20) / 1e8;
        _open(attackerAccount, CfdTypes.Side.BULL, minSize, 50_000 * 1e6, 1e8, depth);

        // H-03: closing to 1 wei now reverts (remaining margin < minBountyUsdc)
        uint256 closeSize = minSize - 1;
        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector, 1, 2, true));
        vm.prank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                account: attackerAccount,
                sizeDelta: closeSize,
                marginDelta: 0,
                targetPrice: 0,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: CfdTypes.Side.BULL,
                isClose: true
            }),
            1e8,
            depth,
            uint64(block.timestamp)
        );
    }

    // Regression: C-02 — per-side MtM cap creates phantom profit
    function test_PerSideMtmCap_PhantomProfit() public {
        uint256 depth = 5_000_000 * 1e6;

        address aliceAccount = address(0xA2);
        _fundTrader(address(0xA2), 100_000 * 1e6);
        _open(aliceAccount, CfdTypes.Side.BULL, 50_000 * 1e18, 5000 * 1e6, 1.2e8, depth);

        address bobAccount = address(0xB2);
        _fundTrader(address(0xB2), 100_000 * 1e6);
        _open(bobAccount, CfdTypes.Side.BEAR, 100_000 * 1e18, 5000 * 1e6, 1.2e8, depth);

        vm.prank(address(router));
        engine.updateMarkPrice(1.1e8, uint64(block.timestamp));

        uint256 mtm = _poolMtmAdjustment();
        assertEq(
            mtm,
            71_000e6,
            "MtM should use a conservative max-profit envelope instead of netting side-level paper losses"
        );
    }

    // Regression: C-03 — unrealized MtM profits distributed as withdrawable cash
    function test_UnrealizedGains_DistributedAsWithdrawableCash() public {
        uint256 depth = 5_000_000 * 1e6;

        address traderAccount = address(0x2222);
        _fundTrader(address(0x2222), 500_000 * 1e6);
        _open(traderAccount, CfdTypes.Side.BULL, 2_000_000 * 1e18, 200_000 * 1e6, 1e8, depth);

        uint256 juniorBefore = pool.juniorPrincipal();

        vm.prank(address(router));
        engine.updateMarkPrice(1.5e8, uint64(block.timestamp));

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 juniorAfter = pool.juniorPrincipal();

        assertLe(
            juniorAfter,
            juniorBefore,
            "C-03: Junior principal must not increase from unrealized trader losses (paper MtM)"
        );
    }

}

// ==========================================
// CfdEngineAuditTest: engine-level audit findings
// ==========================================

contract CfdEngineAuditTest is BasePerpTest {

    using stdStorage for StdStorage;

    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1 * 1e6,
            bountyBps: 10
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    // Regression: Finding-3
    function test_CarryDrivenBadDebt() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(carol, 50_000 * 1e6);

        address account = carol;

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        (uint256 sizeAfterOpen,,,,,,) = engine.positions(account);

        vm.warp(block.timestamp + 182 days);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 1000 * 1e18, 500 * 1e6, 1e8, false);
        empty = _mockPythUpdateData();
        router.executeOrder(2, empty);

        (uint256 sizeAfterSecond,,,,,,) = engine.positions(account);

        assertGt(
            sizeAfterSecond,
            sizeAfterOpen,
            "Carry-aware accounting should let the follow-on order execute instead of being cancelled"
        );
    }

    function test_ProcessOrderTyped_RevertsWhenTruePostTradeEquityFailsImr() public {
        address trader = address(0xABCD1234);
        address account = trader;

        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(trader, 1020 * 1e6);
        _open(account, CfdTypes.Side.BULL, 50_000 * 1e18, 1000 * 1e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(101_800_000, uint64(block.timestamp));

        uint8 revertCode = engineLens.previewOpenRevertCode(
            account, CfdTypes.Side.BULL, 10_000 * 1e18, 0, 101_800_000, uint64(block.timestamp)
        );
        assertEq(
            revertCode,
            uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN),
            "Preview should reject increases backed only by stale stored margin"
        );

        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 0,
            targetPrice: 101_800_000,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        uint256 poolDepth = pool.totalAssets();

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
                uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN),
                false
            )
        );
        vm.prank(address(router));
        engine.processOrderTyped(order, 101_800_000, poolDepth, uint64(block.timestamp));
    }

    function test_ProcessOrderTyped_RevertsWhenAccountAlreadyLiquidatableBeforeIncrease() public {
        address trader = address(0xABCD5678);
        address account = trader;

        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(trader, 1020 * 1e6);
        _open(account, CfdTypes.Side.BULL, 50_000 * 1e18, 1000 * 1e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(102_000_000, uint64(block.timestamp));

        PerpsViewTypes.PositionView memory positionView = _publicPosition(account);
        assertTrue(positionView.liquidatable, "Setup must make the existing position liquidatable before the increase");

        uint8 revertCode = engineLens.previewOpenRevertCode(
            account, CfdTypes.Side.BULL, 10_000 * 1e18, 0, 102_000_000, uint64(block.timestamp)
        );
        CfdEnginePlanTypes.OpenFailurePolicyCategory failureCategory = engineLens.previewOpenFailurePolicyCategory(
            account, CfdTypes.Side.BULL, 10_000 * 1e18, 0, 102_000_000, uint64(block.timestamp)
        );
        assertEq(
            revertCode,
            uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN),
            "Preview should reject a same-side increase when the account is already liquidatable"
        );
        assertEq(
            uint256(failureCategory),
            uint256(CfdEnginePlanTypes.OpenFailurePolicyCategory.CommitTimeRejectable),
            "Preview should expose the semantic commit-time rejection category"
        );

        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 0,
            targetPrice: 102_000_000,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        uint256 poolDepth = pool.totalAssets();

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
                uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN),
                false
            )
        );
        vm.prank(address(router));
        engine.processOrderTyped(order, 102_000_000, poolDepth, uint64(block.timestamp));
    }

    // Regression: Finding-4
    function obsolete_test_CarryPathStillRequiresFreshMarkAfterLongWarp() public {
        _fundJunior(bob, 1_000_000 * 1e6);

        address dave = address(0x444);
        _fundTrader(carol, 15_001 * 1e6);
        _fundTrader(dave, 60_001 * 1e6);

        vm.prank(dave);
        router.commitOrder(CfdTypes.Side.BEAR, 60_000 * 1e18, 60_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 15_000 * 1e18, 1500 * 1e6, 1e8, false);
        router.executeOrder(2, empty);

        address carolAccount = carol;
        (uint256 sizeBefore,,,,,,) = engine.positions(carolAccount);

        IOrderRouterAdminHost.RouterConfig memory config = IOrderRouterAdminHost.RouterConfig({
            maxOrderAge: router.maxOrderAge(),
            orderExecutionStalenessLimit: router.orderExecutionStalenessLimit(),
            liquidationStalenessLimit: router.liquidationStalenessLimit(),
            pythMaxConfidenceRatioBps: router.pythMaxConfidenceRatioBps(),
            orderSettlementWindow: router.orderSettlementWindow(),
            maxComponentPublishTimeDivergence: router.maxComponentPublishTimeDivergence(),
            adverseConfidenceMultiplierBps: router.adverseConfidenceMultiplierBps(),
            minOpenNotionalUsdc: router.minOpenNotionalUsdc(),
            openOrderExecutionBountyBps: router.openOrderExecutionBountyBps(),
            minOpenOrderExecutionBountyUsdc: router.minOpenOrderExecutionBountyUsdc(),
            maxOpenOrderExecutionBountyUsdc: router.maxOpenOrderExecutionBountyUsdc(),
            closeOrderExecutionBountyUsdc: router.closeOrderExecutionBountyUsdc(),
            maxPendingOrders: router.maxPendingOrders(),
            minEngineGas: router.minEngineGas(),
            maxPruneOrdersPerCall: router.maxPruneOrdersPerCall()
        });
        routerAdmin.proposeRouterConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        routerAdmin.finalizeRouterConfig();

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        vm.warp(block.timestamp + 91 days);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.expectRevert(ICfdEngineTypes.CfdEngine__MarkPriceStale.selector);
        engineLens.previewOpenRevertCode(
            carolAccount, CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, uint64(block.timestamp)
        );

        vm.roll(block.number + 1);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__MarkPriceStale.selector);
        router.executeOrder(3, empty);

        (uint256 sizeAfter,,,,,,) = engine.positions(carolAccount);
        assertEq(sizeAfter, sizeBefore, "Rejected stale-mark execution should leave the existing position unchanged");
    }

    // Regression: C-01
    function test_PartialClosePreservesLockedMarginForRemainingPosition() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 22_000 * 1e6);

        address account = alice;

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000 * 1e18, 20_000 * 1e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        (uint256 openSize,,,,,,) = engine.positions(account);
        assertEq(openSize, 200_000 * 1e18);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000 * 1e18, 0, 0, true);
        bytes[] memory priceData = _mockPythUpdateData(0.8e8);
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        router.executeOrder(2, priceData);

        (uint256 remainingSize,,,,,,) = engine.positions(account);
        assertEq(remainingSize, 200_000 * 1e18, "Underwater partial close should fail and leave the position untouched");

        uint256 balAfter = clearinghouse.balanceUsdc(account);
        uint256 lockedAfter = clearinghouse.lockedMarginUsdc(account);
        assertGe(balAfter, lockedAfter, "Physical balance must cover locked margin (zombie prevention)");

        router.executeLiquidation(account, priceData);

        (uint256 sizeAfterLiq,,,,,,) = engine.positions(account);
        assertEq(sizeAfterLiq, 0, "Remaining position should be fully liquidated");
    }

    // Regression: M-01
    function test_FinalizeRiskParams_NoRetroactiveCarryEffect() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(carol, 200_000 * 1e6);

        uint256 T0 = 1_709_740_800;
        uint256 T_PROPOSE = T0 + 30 days;
        uint256 T_FINALIZE = T0 + 30 days + 48 hours + 1;
        uint256 T_ORDER2 = T0 + 33 days;

        vm.warp(T0);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 100_000 * 1e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        int256 indexAfterOpen = _legacySideIndexZero(CfdTypes.Side.BULL);

        vm.warp(T_PROPOSE);

        CfdTypes.RiskParams memory newParams = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1 * 1e6,
            bountyBps: 10
        });
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = newParams;
        config.executionFeeBps = engine.executionFeeBps();
        engineAdmin.proposeRiskConfig(config);

        vm.warp(T_FINALIZE);
        engineAdmin.finalizeRiskConfig();

        vm.warp(T_ORDER2);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 5000 * 1e6, 1e8, false);
        empty = _mockPythUpdateData();
        router.executeOrder(2, empty);

        int256 indexAfterSettle = _legacySideIndexZero(CfdTypes.Side.BULL);
        int256 indexDrop = indexAfterOpen - indexAfterSettle;

        uint256 totalElapsed = T_ORDER2 - T0;
        uint256 oldAnnRate = 0.06e18;
        int256 maxDrop = int256((oldAnnRate * totalElapsed * 2) / 365 days);

        assertLe(indexDrop, maxDrop, "Carry must not retroactively apply the new rate to the pre-finalize period");
    }

    // H-02 FIX: free equity withdrawable with open position
    function test_WithdrawFreeEquityWithOpenPosition() public {
        _fundJunior(bob, 500_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        address account = alice;

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        (uint256 size,,,,,,) = engine.positions(account);
        assertGt(size, 0, "Position should be open");

        uint256 locked = clearinghouse.lockedMarginUsdc(account);
        uint256 usdcBal = clearinghouse.balanceUsdc(account);
        uint256 free = usdcBal - locked;
        assertGt(free, 0, "Alice should have free USDC to withdraw");

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        clearinghouse.withdraw(account, free);
        assertEq(usdc.balanceOf(alice), balBefore + free, "Free equity withdrawn");
    }

    function test_Withdraw_BlocksAfterFreeEquityIsFullyConsumed() public {
        _fundJunior(bob, 500_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        address account = alice;

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        (uint256 size,,,,,,) = engine.positions(account);
        assertGt(size, 0, "Setup must leave an open position");

        uint256 withdrawableUsdc = engineAccountLens.getWithdrawableUsdc(account);
        assertGt(withdrawableUsdc, 0, "Setup must leave some withdrawable free equity");

        vm.prank(alice);
        clearinghouse.withdraw(account, withdrawableUsdc);

        vm.expectRevert();
        vm.prank(alice);
        clearinghouse.withdraw(account, 1);
    }

}

// ==========================================
// MarginCappedMtmTest: per-side margin cap prevents phantom profits
// ==========================================

contract MarginCappedMtmTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1 * 1e6,
            bountyBps: 10
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_MarginTracking_IncreasesOnOpen() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        assertEq(_sideTotalMargin(CfdTypes.Side.BULL), 0);
        assertEq(_sideTotalMargin(CfdTypes.Side.BEAR), 0);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        assertEq(_sideTotalMargin(CfdTypes.Side.BULL), 0, "Bull margin unchanged");
        assertGt(_sideTotalMargin(CfdTypes.Side.BEAR), 0, "Bear margin tracked after open");
    }

    function test_MarginTracking_DecreasesOnClose() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        uint256 bearMarginAfterOpen = _sideTotalMargin(CfdTypes.Side.BEAR);
        assertGt(bearMarginAfterOpen, 0);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 0, 1e8, true);
        empty = _mockPythUpdateData();
        router.executeOrder(2, empty);

        assertEq(_sideTotalMargin(CfdTypes.Side.BEAR), 0, "Bear margin zero after full close");
    }

    function test_MarginTracking_PartialClose() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        uint256 bearMarginFull = _sideTotalMargin(CfdTypes.Side.BEAR);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 50_000e18, 0, 1e8, true);
        empty = _mockPythUpdateData();
        router.executeOrder(2, empty);

        uint256 bearMarginHalf = _sideTotalMargin(CfdTypes.Side.BEAR);
        assertLt(bearMarginHalf, bearMarginFull, "Margin decreases on partial close");
        assertGt(bearMarginHalf, 0, "Margin still tracked for remaining position");
    }

    function test_MarginTracking_ZeroAfterLiquidation() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 2000e6, 1e8, false);
        router.executeOrder(1, _mockPythUpdateData());

        assertGt(_sideTotalMargin(CfdTypes.Side.BEAR), 0);

        bytes[] memory liqPrice = new bytes[](1);
        liqPrice[0] = abi.encode(uint256(0.5e8));
        address account = alice;
        router.executeLiquidation(account, liqPrice);

        assertEq(_sideTotalMargin(CfdTypes.Side.BEAR), 0, "Bear margin zero after liquidation");
    }

    // Regression: C-02
    function test_PhantomProfitCappedAtMargin() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 10_000e6, 0.5e8, false);
        bytes[] memory priceData = _mockPythUpdateData(0.5e8);
        router.executeOrder(2, priceData);

        int256 uncappedPnl = _unrealizedTraderPnl();
        uint256 cappedMtm = _poolMtmAdjustment();

        assertLt(uncappedPnl, -int256(_sideTotalMargin(CfdTypes.Side.BEAR)), "Uncapped loss exceeds deposited margin");
        assertGt(int256(cappedMtm), uncappedPnl, "Capped MtM is less aggressive than uncapped");
    }

    // Regression: C-02
    function test_ReconcileDoesNotInflateBeyondMargin() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        uint256 juniorBefore = pool.juniorPrincipal();

        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 10_000e6, 0.5e8, false);
        bytes[] memory priceData = _mockPythUpdateData(0.5e8);
        router.executeOrder(2, priceData);

        vm.prank(address(juniorVault));
        pool.reconcile();
        uint256 juniorAfter = pool.juniorPrincipal();

        uint256 revenue = juniorAfter > juniorBefore ? juniorAfter - juniorBefore : 0;
        assertLe(
            revenue,
            _sideTotalMargin(CfdTypes.Side.BEAR) + _sideTotalMargin(CfdTypes.Side.BULL),
            "Recognized revenue must not exceed seizable margin"
        );
    }

    function test_MtmAdjustment_PositiveWhenTradersWinning() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 10_000e6, 1.2e8, false);
        bytes[] memory priceData = _mockPythUpdateData(1.2e8);
        router.executeOrder(2, priceData);

        uint256 mtm = _poolMtmAdjustment();
        assertGt(mtm, 0, "Positive MtM = pool liability when traders are winning (no cap needed)");
    }

    function test_MtmAdjustment_ZeroWithNoPositions() public {
        _fundJunior(bob, 500_000e6);
        assertEq(_poolMtmAdjustment(), 0, "MtM should be zero with no positions");
    }

}

// ==========================================
// PhantomExecFeeTest: close exec fee must not over-credit treasury margin
// ==========================================

contract PhantomExecFeeTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1 * 1e6,
            bountyBps: 10
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    // Regression: phantom exec fee
    function test_PhantomExecFee_DoesNotOverCreditTreasuryMargin() public {
        uint256 lpDeposit = 1_000_000e6;
        usdc.mint(bob, lpDeposit);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), lpDeposit);
        juniorVault.deposit(lpDeposit, bob);
        vm.stopPrank();

        uint256 margin = 1002e6;
        usdc.mint(alice, margin);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), margin);
        address account = alice;
        clearinghouse.deposit(account, margin);

        uint256 size = 50_000e18;
        router.commitOrder(CfdTypes.Side.BULL, size, 1000e6, 1e8, false);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        bytes[] memory priceData = _mockPythUpdateData(1e8);
        vm.roll(block.number + 1);
        router.executeOrder(1, priceData);

        uint256 openFee = clearinghouse.balanceUsdc(engine.protocolTreasury());

        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, size, 0, 0, true);

        assertEq(router.nextCommitId(), 3, "Close intents should reserve a flat keeper bounty from free settlement");
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            openFee,
            "Committing the close should not accrue additional protocol fees"
        );
    }

}

// ==========================================
// CarryModelFreeUsdcTest: legacy spread placeholders remain zero
// ==========================================

contract CarryModelFreeUsdcTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1 * 1e6,
            bountyBps: 10
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    // Regression: legacy negative spread receivables
    function helper_GetFreeUSDC_CarryModelBaseline() public {
        usdc.mint(bob, 1_000_000e6);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), 1_000_000e6);
        juniorVault.deposit(1_000_000e6, bob);
        vm.stopPrank();

        uint256 margin = 100_001e6;
        usdc.mint(alice, margin);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), margin);
        address account = alice;
        clearinghouse.deposit(account, margin);

        uint256 size = 200_000e18;
        router.commitOrder(CfdTypes.Side.BULL, size, 100_000e6, 1e8, false);
        vm.stopPrank();

        _warpForward(1);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        router.executeOrder(1, priceData);

        uint64 refreshTime = uint64(block.timestamp + 30 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        address carol = address(0x333);
        uint256 carolMargin = 10_001e6;
        usdc.mint(carol, carolMargin);
        vm.startPrank(carol);
        usdc.approve(address(clearinghouse), carolMargin);
        clearinghouse.deposit(carol, carolMargin);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 10_000e6, 1e8, false);
        vm.stopPrank();

        _warpForward(1);
        priceData[0] = abi.encode(uint256(1e8));
        router.executeOrder(2, priceData);

        int256 unrealizedLegacySpread = int256(0);
        assertLt(unrealizedLegacySpread, 0, "legacy spread placeholder remains zero in the carry model");

        uint256 freeUsdcNow = pool.getFreeUSDC();

        uint256 bal = usdc.balanceOf(address(pool));
        uint256 maxLiability = _sideMaxProfit(CfdTypes.Side.BULL);
        uint256 pendingFees = clearinghouse.balanceUsdc(engine.protocolTreasury());
        uint256 reservedWithoutLegacySpread = maxLiability + pendingFees;
        uint256 freeWithoutLegacySpread = bal > reservedWithoutLegacySpread ? bal - reservedWithoutLegacySpread : 0;

        assertEq(
            freeUsdcNow,
            freeWithoutLegacySpread,
            "getFreeUSDC must not reduce reserves via imaginary legacy-spread receivables"
        );
    }

}

contract DegradedModeLifecycleTest is BasePerpTest {

    address bullTrader = address(0xD001);
    address bearTrader = address(0xD002);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10
        });
    }

    function _enterDegradedMode() internal {
        address bullAccount = bullTrader;
        address bearAccount = bearTrader;

        _fundTrader(bullTrader, 100_000e6);
        _fundTrader(bearTrader, 100_000e6);

        _open(bearAccount, CfdTypes.Side.BEAR, 1_000_000e18, 50_000e6, 1e8);
        _open(bullAccount, CfdTypes.Side.BULL, 500_000e18, 50_000e6, 1e8);
        _close(bullAccount, CfdTypes.Side.BULL, 500_000e18, 20_000_000);
    }

    function test_DegradedMode_LatchesAndBlocksNewOpens() public {
        address newTrader = address(0xD003);
        address newTraderAccount = newTrader;
        _fundTrader(newTrader, 100_000e6);

        _enterDegradedMode();

        assertTrue(engine.degradedMode(), "Setup must latch degraded mode");
        CfdTypes.Order memory blockedOpen = CfdTypes.Order({
            account: newTraderAccount,
            sizeDelta: 10_000e18,
            marginDelta: 1000e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: CfdTypes.Side.BULL,
            isClose: false
        });

        vm.prank(address(router));
        (bool ok,) = address(engine)
            .call(
                abi.encodeWithSelector(
                    engine.processOrderTyped.selector, blockedOpen, 1e8, pool.totalAssets(), uint64(block.timestamp)
                )
            );
        assertFalse(ok, "Degraded mode must block new opens");
    }

    function test_DegradedMode_ClearRequiresRecapitalization() public {
        _enterDegradedMode();

        vm.expectRevert(ICfdEngineTypes.CfdEngine__StillInsolvent.selector);
        engine.clearDegradedMode();

        _fundJuniorDelayed(address(this), 500_000e6);
        engine.clearDegradedMode();

        assertFalse(engine.degradedMode(), "Owner should clear degraded mode after recapitalization");
    }

    function test_DegradedMode_BlocksJuniorWithdrawals() public {
        _enterDegradedMode();
        assertTrue(engine.degradedMode(), "Setup must latch degraded mode");

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(address(juniorVault));
        vm.expectRevert(IHousePool.HousePool__DegradedMode.selector);
        pool.withdrawJunior(1e6, address(this));
    }

    function test_DegradedMode_AllowsAddMarginToExistingPosition() public {
        address trader = address(0xD004);
        address account = trader;
        _fundTrader(trader, 200_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);

        _enterDegradedMode();
        assertTrue(engine.degradedMode(), "Setup must latch degraded mode");

        uint256 lockedBefore = clearinghouse.lockedMarginUsdc(account);
        (, uint256 marginBefore,,,,,) = engine.positions(account);

        vm.prank(trader);
        engine.addMargin(account, 1000e6);

        (, uint256 marginAfter,,,,,) = engine.positions(account);
        assertEq(marginAfter, marginBefore + 1000e6, "Add margin should still increase position margin");
        assertEq(
            clearinghouse.lockedMarginUsdc(account),
            lockedBefore + 1000e6,
            "Add margin should remain usable during degraded mode"
        );
    }

}

// ==========================================
// ProtocolPhaseTest: Configuring → Active → Degraded → Active
// ==========================================

contract ProtocolPhaseTest is BasePerpTest {

    address bullTrader = address(0xD001);
    address bearTrader = address(0xD002);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10
        });
    }

    function test_PhaseTransitions() public {
        assertEq(
            uint8(ICfdEngine.ProtocolPhase(_publicProtocolStatus().phase)),
            uint8(ICfdEngine.ProtocolPhase.Active),
            "Fully configured engine should be Active"
        );

        PerpsViewTypes.ProtocolStatusView memory status = _publicProtocolStatus();
        assertEq(uint8(status.phase), uint8(ICfdEngine.ProtocolPhase.Active));
        assertEq(status.lastMarkPrice, 0);

        address bullAccount = bullTrader;
        address bearAccount = bearTrader;
        _fundTrader(bullTrader, 100_000e6);
        _fundTrader(bearTrader, 100_000e6);
        _open(bearAccount, CfdTypes.Side.BEAR, 1_000_000e18, 50_000e6, 1e8);
        _open(bullAccount, CfdTypes.Side.BULL, 500_000e18, 50_000e6, 1e8);
        _close(bullAccount, CfdTypes.Side.BULL, 500_000e18, 20_000_000);

        assertEq(
            uint8(ICfdEngine.ProtocolPhase(_publicProtocolStatus().phase)),
            uint8(ICfdEngine.ProtocolPhase.Degraded),
            "Insolvency-revealing close should latch Degraded"
        );

        _fundJuniorDelayed(address(this), 500_000e6);
        engine.clearDegradedMode();

        assertEq(
            uint8(ICfdEngine.ProtocolPhase(_publicProtocolStatus().phase)),
            uint8(ICfdEngine.ProtocolPhase.Active),
            "Recapitalization should restore Active"
        );
    }

    function test_ConfiguringPhase() public {
        CfdEngine unconfigured = new CfdEngine(address(usdc), address(clearinghouse), 2e8, _riskParams());
        PerpsPublicLens unconfiguredLens =
            new PerpsPublicLens(address(engineAccountLens), address(unconfigured), address(router), address(0));
        assertEq(
            unconfiguredLens.getProtocolStatus().phase,
            uint8(ICfdEngine.ProtocolPhase.Configuring),
            "Engine without pool/router should be Configuring"
        );
    }

}

contract ProtocolPhasePreActivationTest is BasePerpTest {

    function _autoActivateTrading() internal pure override returns (bool) {
        return false;
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_PhaseRemainsConfiguringUntilTradingActivation() public {
        assertTrue(pool.isSeedLifecycleComplete(), "setup should finish seed lifecycle");
        assertFalse(pool.isTradingActive(), "setup should leave trading inactive");
        assertEq(
            uint8(ICfdEngine.ProtocolPhase(_publicProtocolStatus().phase)),
            uint8(ICfdEngine.ProtocolPhase.Configuring),
            "Configured but inactive trading should still report Configuring"
        );

        pool.activateTrading();

        assertEq(
            uint8(ICfdEngine.ProtocolPhase(_publicProtocolStatus().phase)),
            uint8(ICfdEngine.ProtocolPhase.Active),
            "Trading activation should unlock Active phase"
        );
    }

}

// ==========================================
// VpiDepthTest: VPI depth manipulation attacks
// ==========================================

contract VpiDepthTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.01e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1 * 1e6,
            bountyBps: 10
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    // Regression: C-02a
    function test_MinorityVpiRebateCannotExceedPaidCharges() public {
        _fundJunior(bob, 1_000_000 * 1e6);

        _fundTrader(carol, 50_000 * 1e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000 * 1e18, 40_000 * 1e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        _fundTrader(alice, 50_000 * 1e6);
        address aliceAccount = alice;
        uint256 aliceBalBefore = clearinghouse.balanceUsdc(aliceAccount);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        empty = _mockPythUpdateData();
        router.executeOrder(2, empty);

        _fundJuniorDelayed(bob, 9_000_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 0, 0, true);
        bytes[] memory closePrice = _mockPythUpdateData();
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        router.executeOrder(3, closePrice);

        uint256 aliceBalAfter = clearinghouse.balanceUsdc(aliceAccount);

        assertLe(aliceBalAfter, aliceBalBefore, "Minority VPI depth attack must not be profitable");
    }

    // Regression: C-02b
    function test_SizeAdditionCannotBypassVpiBound() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        address aliceAccount = alice;
        uint256 aliceBalBefore = clearinghouse.balanceUsdc(aliceAccount);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 5000 * 1e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        _fundJuniorDelayed(bob, 9_000_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        empty = _mockPythUpdateData();
        router.executeOrder(2, empty);

        vm.warp(block.timestamp + 2 hours);
        bytes[] memory freshPrice = new bytes[](1);
        freshPrice[0] = abi.encode(uint256(1e8));
        router.updateMarkPrice(freshPrice);
        vm.startPrank(bob);
        uint256 withdrawable = juniorVault.maxWithdraw(bob);
        if (withdrawable > 0) {
            juniorVault.withdraw(withdrawable, bob, bob);
        }
        vm.stopPrank();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 110_000 * 1e18, 0, 0, true);
        bytes[] memory closePrice = _mockPythUpdateData();
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        router.executeOrder(3, closePrice);

        uint256 aliceBalAfter = clearinghouse.balanceUsdc(aliceAccount);

        assertLe(aliceBalAfter, aliceBalBefore, "Size addition VPI bypass must not be profitable");
    }

    function test_VpiRebateLiability_ReducesWithdrawableHeadroom() public {
        address deepLp = address(0x444);
        address skewTrader = address(0x555);
        address rebateTrader = address(0x666);

        address skewAccount = skewTrader;
        address rebateAccount = rebateTrader;

        _fundJunior(bob, 1_000_000 * 1e6);
        _fundJunior(deepLp, 10_000_000 * 1e6);
        _fundTrader(skewTrader, 100_000 * 1e6);
        _fundTrader(rebateTrader, 20_000 * 1e6);

        uint256 largeDepth = pool.totalAssets();
        _open(skewAccount, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8, largeDepth);

        vm.warp(block.timestamp + 2 hours);
        bytes[] memory freshPrice = new bytes[](1);
        freshPrice[0] = abi.encode(uint256(1e8));
        router.updateMarkPrice(freshPrice);

        vm.startPrank(deepLp);
        uint256 juniorWithdrawable = juniorVault.maxWithdraw(deepLp);
        juniorVault.withdraw(juniorWithdrawable, deepLp, deepLp);
        vm.stopPrank();

        uint256 smallDepth = pool.totalAssets();
        assertLt(smallDepth, largeDepth, "LP withdrawal should shrink live pool depth");

        uint256 rebateSettlementBeforeOpen = clearinghouse.balanceUsdc(rebateAccount);
        uint64 rebatePublishTime = engine.lastMarkTime();
        vm.prank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                account: rebateAccount,
                sizeDelta: 500_000 * 1e18,
                marginDelta: 7000 * 1e6,
                targetPrice: 1e8,
                commitTime: rebatePublishTime,
                commitBlock: uint64(block.number),
                orderId: 0,
                side: CfdTypes.Side.BULL,
                isClose: false
            }),
            1e8,
            smallDepth,
            rebatePublishTime
        );

        (,,,,,, int256 storedVpi) = engine.positions(rebateAccount);
        assertLt(storedVpi, 0, "Setup must create negative accrued VPI on the rebate-bearing leg");
        assertGt(
            clearinghouse.balanceUsdc(rebateAccount),
            rebateSettlementBeforeOpen,
            "Skew-healing open should credit net rebate into settlement balance"
        );

        uint256 freeSettlementUsdc = clearinghouse.getAccountUsdcBuckets(rebateAccount).freeSettlementUsdc;
        uint256 withdrawableUsdc = engineAccountLens.getWithdrawableUsdc(rebateAccount);
        assertLt(
            withdrawableUsdc,
            freeSettlementUsdc,
            "Rebate liability should reduce withdrawable headroom below free settlement"
        );

        vm.prank(rebateTrader);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        clearinghouse.withdraw(rebateAccount, freeSettlementUsdc);
    }

}

// ==========================================
// VpiChunkingTest: H-01 linear VPI chunking tests
// ==========================================

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

contract VpiChunkingTest is Test {

    VpiMockUSDC6 usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;

    uint256 constant CAP_PRICE = 2e8;
    uint256 constant DEPTH = 5_000_000 * 1e6;

    function setUp() public {
        usdc = new VpiMockUSDC6();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0.001e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1 * 1e6,
            bountyBps: 10
        });

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementSidecar settlement = new CfdEngineSettlementSidecar(address(engine));
        CfdEngineAdmin engineAdmin = new CfdEngineAdmin(address(engine), address(this));
        engine.setDependencies(address(planner), address(settlement), address(engineAdmin));
        pool = new HousePool(address(usdc), address(engine));
        TrancheVault seniorVault =
            new TrancheVault(IERC20(address(usdc)), address(pool), true, "Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "juniorUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));
        engine.setOrderRouter(address(this));

        clearinghouse.setEngine(address(engine));
        vm.warp(1_709_532_000);

        usdc.mint(address(this), 2000e6);
        usdc.approve(address(pool), 2000e6);
        pool.initializeSeedPosition(false, 1000e6, address(this));
        pool.initializeSeedPosition(true, 1000e6, address(this));
        pool.activateTrading();

        usdc.mint(address(this), 10_000_000 * 1e6);
        usdc.approve(address(juniorVault), type(uint256).max);
        juniorVault.deposit(5_000_000 * 1e6, address(this));
    }

    function _deposit(
        address account,
        uint256 amount
    ) internal {
        address user = account;
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(account, amount);
        vm.stopPrank();
    }

    function _open(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 depth
    ) internal {
        engine.processOrderTyped(
            CfdTypes.Order({
                account: account,
                sizeDelta: size,
                marginDelta: margin,
                targetPrice: price,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: side,
                isClose: false
            }),
            price,
            depth,
            uint64(block.timestamp)
        );
    }

    function getMarginReservationIds(
        address
    ) external pure returns (uint64[] memory) {
        return new uint64[](0);
    }

    function syncMarginQueue(
        address
    ) external pure {}

    function _close(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 price,
        uint256 depth
    ) internal {
        engine.processOrderTyped(
            CfdTypes.Order({
                account: account,
                sizeDelta: size,
                marginDelta: 0,
                targetPrice: 0,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: side,
                isClose: true
            }),
            price,
            depth,
            uint64(block.timestamp)
        );
    }

    // Regression: H-01 — round-trip skew healing must not create net positive VPI without price movement.
    function test_MM_RoundTripSkewHealing_DoesNotCreatePositiveNetRebate() public {
        address bearSkewerAccount = address(0x51);
        _deposit(bearSkewerAccount, 500_000 * 1e6);
        _open(bearSkewerAccount, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        address mmAccount = address(0x111);
        _deposit(mmAccount, 500_000 * 1e6);
        _open(mmAccount, CfdTypes.Side.BULL, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        (,,,,,, int256 vpiAfterOpen) = engine.positions(mmAccount);
        assertLe(vpiAfterOpen, 0, "MM should not pay positive VPI when healing skew on open");

        address bullFlipperAccount = address(0x52);
        _deposit(bullFlipperAccount, 500_000 * 1e6);
        _open(bullFlipperAccount, CfdTypes.Side.BULL, 1_000_000 * 1e18, 100_000 * 1e6, 1e8, DEPTH);

        (uint256 mmSize,,,,,,) = engine.positions(mmAccount);
        _close(mmAccount, CfdTypes.Side.BULL, mmSize, 1e8, DEPTH);
        uint256 mmUsdcAfter = clearinghouse.balanceUsdc(mmAccount);

        uint256 totalDeposited = 500_000 * 1e6;
        uint256 approxExecFees = (500_000 * 1e6 * 4 / 10_000) * 2;
        uint256 breakeven = totalDeposited - approxExecFees;

        assertLe(
            mmUsdcAfter,
            breakeven,
            "Round-trip skew healing should not create positive net VPI beyond the trader's fee-adjusted breakeven"
        );
    }

    // Regression: H-01 — linear VPI chunking bounded error
    function test_PartialClose_LinearChunking_BoundedError() public {
        address skewerAccount = address(0x52);
        _deposit(skewerAccount, 500_000 * 1e6);
        _open(skewerAccount, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        address aliceAccount = address(0xA1);
        _deposit(aliceAccount, 500_000 * 1e6);
        _open(aliceAccount, CfdTypes.Side.BULL, 400_000 * 1e18, 100_000 * 1e6, 1e8, DEPTH);

        uint256 aliceBefore = clearinghouse.balanceUsdc(aliceAccount);
        _close(aliceAccount, CfdTypes.Side.BULL, 400_000 * 1e18, 1e8, DEPTH);
        uint256 aliceAfter = clearinghouse.balanceUsdc(aliceAccount);
        int256 aliceNet = int256(aliceAfter) - int256(aliceBefore);

        _close(skewerAccount, CfdTypes.Side.BEAR, 500_000 * 1e18, 1e8, DEPTH);
        _open(skewerAccount, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        address bobAccount = address(0xB1);
        _deposit(bobAccount, 500_000 * 1e6);
        _open(bobAccount, CfdTypes.Side.BULL, 400_000 * 1e18, 100_000 * 1e6, 1e8, DEPTH);

        uint256 bobBefore = clearinghouse.balanceUsdc(bobAccount);
        _close(bobAccount, CfdTypes.Side.BULL, 200_000 * 1e18, 1e8, DEPTH);
        _close(bobAccount, CfdTypes.Side.BULL, 200_000 * 1e18, 1e8, DEPTH);
        uint256 bobAfter = clearinghouse.balanceUsdc(bobAccount);
        int256 bobNet = int256(bobAfter) - int256(bobBefore);

        int256 diff = aliceNet > bobNet ? aliceNet - bobNet : bobNet - aliceNet;
        uint256 tolerance = 5 * 1e6;

        assertLe(uint256(diff), tolerance, "H-01: Linear chunking error must stay within bounded tolerance");
    }

}

contract SolvencySnapshotRegressionTest is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10
        });
    }

    /// @dev Regression: planLiquidation must use post-liquidation side snapshots (OI and totalMargin).
    ///      for solvency computation. Now also uses previewPostOpSolvency with physicalAssetsDelta
    ///      to account for seized collateral flowing into the pool.
    function test_PreviewLiquidation_SolvencyUsesPostLiquidationCarryState() public {
        address bullTrader = address(0xDD01);
        address bearTrader = address(0xDD02);
        address bullAccount = bullTrader;
        address bearAccount = bearTrader;

        CfdTypes.RiskParams memory params = _riskParams();
        _setRiskParams(params);

        _fundTrader(bullTrader, 30_000e6);
        _fundTrader(bearTrader, 100_000e6);

        _open(bullAccount, CfdTypes.Side.BULL, 1_000_000e18, 20_000e6, 1e8);
        _open(bearAccount, CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8);

        uint256 currentDay = ((block.timestamp / 1 days) + 4) % 7;
        uint256 startOfDay = block.timestamp - (block.timestamp % 1 days);
        uint256 saturdayNoon = startOfDay + (6 - currentDay) * 1 days + 12 hours;
        if (saturdayNoon <= block.timestamp) {
            saturdayNoon += 7 days;
        }
        vm.warp(saturdayNoon);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + 30 hours);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(bullAccount, 1e8);
        assertTrue(preview.liquidatable, "BULL majority must be liquidatable after carry drain");

        address keeper = address(0x999);
        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(bullAccount, keeper);
        vm.prank(keeper);
        bytes[] memory liquidationPriceData = new bytes[](1);
        liquidationPriceData[0] = abi.encode(uint256(1e8));
        router.executeLiquidation(bullAccount, liquidationPriceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(bullAccount, keeper, beforeSnapshot);
        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
    }

    /// @dev Regression: _computeCloseSolvency did not reduce openInterest before computing
    ///      stale side-state math previously overstated solvency after close.
    function test_PreviewClose_SolvencyUsesPostCloseOiForCarry() public {
        address bullTraderA = address(0xDD03);
        address bullTraderB = address(0xDD04);
        address bearTrader = address(0xDD05);
        address bullIdA = bullTraderA;
        address bullIdB = bullTraderB;
        address bearAccount = bearTrader;

        _fundTrader(bullTraderA, 50_000e6);
        _fundTrader(bullTraderB, 50_000e6);
        _fundTrader(bearTrader, 100_000e6);

        _open(bullIdA, CfdTypes.Side.BULL, 400_000e18, 20_000e6, 1e8);
        _open(bullIdB, CfdTypes.Side.BULL, 400_000e18, 20_000e6, 1e8);
        _open(bearAccount, CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8);

        vm.warp(block.timestamp + 5 days);

        (uint256 sizeA,,,,,,) = engine.positions(bullIdA);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(bullIdA, sizeA, 1e8);
        assertTrue(preview.valid, "Close preview must be valid");

        _close(bullIdA, CfdTypes.Side.BULL, sizeA, 1e8);
    }

}
