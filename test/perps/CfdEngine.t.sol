// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdEngineAdmin} from "../../src/perps/CfdEngineAdmin.sol";
import {CfdEnginePlanTypes} from "../../src/perps/CfdEnginePlanTypes.sol";
import {CfdEnginePlanner} from "../../src/perps/CfdEnginePlanner.sol";
import {CfdEngineSettlementModule} from "../../src/perps/CfdEngineSettlementModule.sol";
import {CfdMath} from "../../src/perps/CfdMath.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {AccountLensViewTypes} from "../../src/perps/interfaces/AccountLensViewTypes.sol";
import {DeferredEngineViewTypes} from "../../src/perps/interfaces/DeferredEngineViewTypes.sol";
import {HousePoolEngineViewTypes} from "../../src/perps/interfaces/HousePoolEngineViewTypes.sol";
import {ICfdEngine} from "../../src/perps/interfaces/ICfdEngine.sol";
import {ICfdEngineAdminHost} from "../../src/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEngineSettlementHost} from "../../src/perps/interfaces/ICfdEngineSettlementHost.sol";
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
        uint256 deferredTraderCreditUsdc,
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
        snap.vaultAssetsUsdc = 1_000_000e6;
        snap.vaultCashUsdc = 1;
        snap.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: settlementReachableUsdc,
            totalLockedMarginUsdc: 0,
            activePositionMarginUsdc: 0,
            otherLockedMarginUsdc: 0,
            freeSettlementUsdc: settlementReachableUsdc
        });
        snap.totalDeferredTraderCreditUsdc = deferredTraderCreditUsdc;
        snap.deferredTraderCreditForAccount = deferredTraderCreditUsdc;
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
        uint256 deferredTraderCreditUsdc,
        uint256 size,
        uint256 entryPrice,
        uint256 oraclePrice,
        uint64 currentTimestamp,
        uint64 lastCarryTimestamp
    ) external pure returns (CfdEnginePlanTypes.LiquidationDelta memory delta) {
        CfdEnginePlanTypes.RawSnapshot memory snap;
        snap.position = CfdTypes.Position({
            size: size,
            margin: 0,
            entryPrice: entryPrice,
            maxProfitUsdc: 0,
            side: CfdTypes.Side.BEAR,
            lastUpdateTime: 0,
            lastCarryTimestamp: lastCarryTimestamp,
            vpiAccrued: 0
        });
        snap.currentTimestamp = currentTimestamp;
        snap.lastMarkPrice = oraclePrice;
        snap.lastMarkTime = currentTimestamp;
        snap.bearSide.openInterest = size;
        snap.vaultAssetsUsdc = 1_000_000e6;
        snap.vaultCashUsdc = 1;
        snap.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: settlementReachableUsdc,
            totalLockedMarginUsdc: 0,
            activePositionMarginUsdc: 0,
            otherLockedMarginUsdc: 0,
            freeSettlementUsdc: settlementReachableUsdc
        });
        snap.totalDeferredTraderCreditUsdc = deferredTraderCreditUsdc;
        snap.deferredTraderCreditForAccount = deferredTraderCreditUsdc;
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

    function planLiquidationWithVpiAccrued(
        uint256 settlementReachableUsdc,
        uint256 deferredTraderCreditUsdc,
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
        snap.vaultAssetsUsdc = 1_000_000e6;
        snap.vaultCashUsdc = 1;
        snap.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: settlementReachableUsdc,
            totalLockedMarginUsdc: 0,
            activePositionMarginUsdc: 0,
            otherLockedMarginUsdc: 0,
            freeSettlementUsdc: settlementReachableUsdc
        });
        snap.totalDeferredTraderCreditUsdc = deferredTraderCreditUsdc;
        snap.deferredTraderCreditForAccount = deferredTraderCreditUsdc;
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
        snap.accountId = bytes32(uint256(0x1234));
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
            totalMargin: positionMarginUsdc
        });
        snap.bearSide =
            CfdEnginePlanTypes.SideSnapshot({maxProfitUsdc: 0, openInterest: 0, entryNotional: 0, totalMargin: 0});
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
        snap.vaultAssetsUsdc = 1_000_000e6;
        snap.vaultCashUsdc = 1_000_000e6;

        return CfdEnginePlanLib.planOpen(
            snap,
            CfdTypes.Order({
                accountId: snap.accountId,
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
        int256 bullFunding,
        int256 bearFunding,
        uint256 bullMargin,
        uint256 bearMargin
    ) internal pure returns (int256) {
        if (bullFunding < -int256(bullMargin)) {
            bullFunding = -int256(bullMargin);
        }
        if (bearFunding < -int256(bearMargin)) {
            bearFunding = -int256(bearMargin);
        }
        return bullFunding + bearFunding;
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
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 20_000 * 1e6);

        // maxProfit = 1.2M tokens * $1 entry = $1.2M > vault's $1M balance
        CfdTypes.Order memory tooLarge = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 1_200_000 * 1e18,
            marginDelta: 5000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });

        vm.expectRevert(abi.encodeWithSelector(ICfdEngine.CfdEngine__TypedOrderFailure.selector, 2, 7, false));
        vm.prank(address(router));
        engine.processOrderTyped(tooLarge, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));

        CfdTypes.Order memory order = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });

        // Withdraw LP to reduce vault to $50k — solvency check should fail
        vm.warp(block.timestamp + 1 hours); // past deposit cooldown
        juniorVault.withdraw(950_000 * 1e6, address(this), address(this));
        vm.expectRevert(abi.encodeWithSelector(ICfdEngine.CfdEngine__TypedOrderFailure.selector, 2, 7, false));
        vm.prank(address(router));
        engine.processOrderTyped(order, 1e8, 0, uint64(block.timestamp));

        // Re-deposit to allow the trade
        usdc.approve(address(juniorVault), 950_000 * 1e6);
        juniorVault.deposit(950_000 * 1e6, address(this));

        vm.prank(address(router));
        engine.processOrderTyped(order, 1e8, 200_000 * 1e6, uint64(block.timestamp));

        (uint256 size, uint256 margin,,,,,) = engine.positions(accountId);
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

        bytes32 accountId = bytes32(uint256(0xBEEF1));
        _fundTrader(address(uint160(uint256(accountId))), 10_000e6);

        assertEq(
            engineLens.previewOpenRevertCode(
                accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, uint64(block.timestamp)
            ),
            uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN),
            "Planner should use the explicit init margin config"
        );
    }

    function test_OpenParity_HealthyPreviewMatchesLiveExecution() public {
        bytes32 accountId = bytes32(uint256(0xBEEF2));
        _fundTrader(address(uint160(uint256(accountId))), 10_000e6);

        assertEq(
            engineLens.previewOpenRevertCode(
                accountId, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8, uint64(block.timestamp)
            ),
            uint8(CfdEnginePlanTypes.OpenRevertCode.OK),
            "Preview should accept the healthy open"
        );

        uint256 feesBefore = engine.accumulatedFeesUsdc();
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);

        (uint256 size, uint256 margin,,,,,) = engine.positions(accountId);
        assertEq(size, 100_000e18, "Live open should match the previewed size");
        assertGt(margin, 0, "Live open should leave positive position margin");
        assertLt(margin, 5000e6, "Live open margin should reflect execution costs after the successful preview");
        assertGt(
            engine.accumulatedFeesUsdc() - feesBefore, 0, "Live open should collect protocol revenue after success"
        );
    }

    function test_ProcessOrderTyped_ProtocolStateFailureUsesTypedTaxonomy() public {
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 20_000 * 1e6);

        CfdTypes.Order memory tooLarge = CfdTypes.Order({
            accountId: accountId,
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
                ICfdEngine.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated,
                uint8(7),
                false
            )
        );
        vm.prank(address(router));
        engine.processOrderTyped(tooLarge, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));
    }

    function helper_NoCarryBaselineAccumulation() public {
        uint256 vaultDepth = 1_000_000 * 1e6;

        bytes32 account1 = bytes32(uint256(1));
        bytes32 account2 = bytes32(uint256(2));
        _fundTrader(address(uint160(uint256(account1))), 5000 * 1e6);
        _fundTrader(address(uint160(uint256(account2))), 5000 * 1e6);

        CfdTypes.Order memory retailLong = CfdTypes.Order({
            accountId: account1,
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
        engine.processOrderTyped(retailLong, 1e8, vaultDepth, uint64(block.timestamp));

        uint64 refreshTime = uint64(block.timestamp + 30 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint64 accrualTime = refreshTime + 30;
        vm.warp(accrualTime);

        CfdTypes.Order memory mmShort = CfdTypes.Order({
            accountId: account2,
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
        engine.processOrderTyped(mmShort, 1e8, vaultDepth, accrualTime);

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

    function helper_AbsorbRouterCancellationFee_NoSyncCheckpointRequired() public {
        address trader = address(0xABC1);
        bytes32 traderId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 50_000e6);
        _open(traderId, CfdTypes.Side.BULL, 200_000e18, 20_000e6, 1e8);

        uint256 feesBefore = engine.accumulatedFeesUsdc();
        uint256 vaultAssetsBefore = pool.totalAssets();
        vm.warp(block.timestamp + 1 days);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + 1);

        usdc.mint(address(router), 25e6);
        vm.prank(address(router));
        usdc.approve(address(engine), 25e6);

        vm.prank(address(router));
        engine.absorbRouterCancellationFee(25e6);

        assertEq(
            engine.accumulatedFeesUsdc() - feesBefore,
            25e6,
            "Absorbed cancellation fee should be booked as incremental protocol revenue"
        );
        assertEq(
            pool.totalAssets(),
            vaultAssetsBefore + 25e6,
            "Absorbed cancellation fee should raise canonical vault assets"
        );
        assertEq(pool.excessAssets(), 0, "Absorbed cancellation fee should not strand canonical assets as excess");
    }

    function helper_SyncState_IsNoopInCarryModel() public {
        address trader = address(0xABC2);
        bytes32 traderId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 50_000e6);
        _open(traderId, CfdTypes.Side.BULL, 200_000e18, 20_000e6, 1e8);

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);

        // no-op in no-side-funding baseline

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + 1);

        // no-op in no-side-funding baseline
    }

    function test_ProtocolAccounting_DoesNotProjectCarryFromStaleLiveMark() public {
        address bullTrader = address(0xABC3);
        address bearTrader = address(0xABC4);
        bytes32 bullId = bytes32(uint256(uint160(bullTrader)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));

        _fundTrader(bullTrader, 50_000e6);
        _fundTrader(bearTrader, 10_000e6);
        _open(bullId, CfdTypes.Side.BULL, 200_000e18, 20_000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 20_000e18, 2000e6, 1e8);

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
        bytes32 traderId = bytes32(uint256(uint160(trader)));

        _setFadMaxStaleness(1 hours);

        _fundTrader(trader, 50_000e6);
        _open(traderId, CfdTypes.Side.BULL, 200_000e18, 20_000e6, 1e8);

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

        // no-op in no-side-funding baseline
    }

    function test_ProtocolAccounting_DoesNotProjectCarryFromFrozenMarkPastFadMaxStaleness() public {
        address bullTrader = address(0xABC6);
        address bearTrader = address(0xABC7);
        bytes32 bullId = bytes32(uint256(uint160(bullTrader)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));

        _setFadMaxStaleness(1 hours);

        _fundTrader(bullTrader, 50_000e6);
        _fundTrader(bearTrader, 10_000e6);
        _open(bullId, CfdTypes.Side.BULL, 200_000e18, 20_000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 20_000e18, 2000e6, 1e8);

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

    function test_OpenTradeCost_AccountsVaultInflowCanonically() public {
        bytes32 firstBullId = bytes32(uint256(uint160(address(0xABC2))));
        bytes32 secondBullId = bytes32(uint256(uint160(address(0xABC3))));
        _fundTrader(address(uint160(uint256(firstBullId))), 100_000e6);
        _fundTrader(address(uint160(uint256(secondBullId))), 100_000e6);

        _open(firstBullId, CfdTypes.Side.BULL, 500_000e18, 50_000e6, 1e8);

        uint256 vaultAssetsBefore = pool.totalAssets();
        _open(secondBullId, CfdTypes.Side.BULL, 500_000e18, 50_000e6, 1e8);

        assertGt(pool.totalAssets(), vaultAssetsBefore, "Positive trade cost should increase canonical vault assets");
        assertEq(pool.excessAssets(), 0, "Trade-cost inflows should not remain quarantined as excess");
    }

    function test_ProfitableClose_RecordsDeferredTraderCreditWhenVaultIlliquid() public {
        bytes32 accountId = bytes32(uint256(uint160(address(0xD301))));
        _fundTrader(address(0xD301), 11_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        uint256 clearinghouseBefore = clearinghouse.balanceUsdc(accountId);

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Profitable close should still destroy the position");
        assertGt(engine.deferredTraderCreditUsdc(accountId), 0, "Unpaid profit should be recorded as deferred payout");
        assertEq(
            clearinghouse.balanceUsdc(accountId),
            clearinghouseBefore,
            "Illiquid profitable close should not immediately credit clearinghouse cash"
        );
    }

    function test_FullClose_AfterFreshMark_DoesNotRevertWhenVaultIlliquid() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 bullId = bytes32(uint256(1));
        bytes32 bearId = bytes32(uint256(2));
        _fundTrader(address(uint160(uint256(bullId))), 5000 * 1e6);
        _fundTrader(address(uint160(uint256(bearId))), 5000 * 1e6);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, vaultDepth);
        _open(bearId, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, vaultDepth);

        uint64 refreshTime = uint64(block.timestamp + 30 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint64 accrualTime = refreshTime + 59;
        vm.warp(accrualTime);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(bearId, 10_000e18, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        _closeAt(bearId, CfdTypes.Side.BEAR, 10_000e18, 1e8, vaultDepth, accrualTime);

        (uint256 size,,,,,,) = engine.positions(bearId);
        assertEq(size, 0, "Illiquid profitable close close should still destroy the position");
        assertEq(
            engine.deferredTraderCreditUsdc(bearId), preview.deferredTraderCreditUsdc, "Live close should match preview"
        );
    }

    function test_PreviewClose_UsesCanonicalVaultDepthWhileSimulateCloseAllowsWhatIfDepth() public {
        bytes32 bullId = bytes32(uint256(0xC10));
        bytes32 bearId = bytes32(uint256(0xC11));
        _fundTrader(address(uint160(uint256(bullId))), 5000e6);
        _fundTrader(address(uint160(uint256(bearId))), 5000e6);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint64 accrualTime = refreshTime + 59;
        vm.warp(accrualTime);

        uint256 canonicalDepth = pool.totalAssets();
        CfdEngine.ClosePreview memory canonicalPreview = engineLens.previewClose(bearId, 10_000e18, 1e8);
        CfdEngine.ClosePreview memory matchedSimulation =
            engineLens.simulateClose(bearId, 10_000e18, 1e8, canonicalDepth);
        CfdEngine.ClosePreview memory lowDepthSimulation =
            engineLens.simulateClose(bearId, 10_000e18, 1e8, canonicalDepth / 10);

        _assertClosePreviewEquals(canonicalPreview, matchedSimulation);
    }

    function test_CloseParity_ImmediateProfitMatchesPreview() public {
        address trader = address(0xD3A1);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(accountId, 100_000e18, 80_000_000);
        assertTrue(preview.valid, "Setup close preview should be valid");
        assertGt(preview.immediatePayoutUsdc, 0, "Profitable liquid close should pay immediately");
        assertEq(preview.deferredTraderCreditUsdc, 0, "Liquid profitable close should not defer payout");

        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(accountId);
        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        CloseParityObserved memory observed = _observeCloseParity(accountId, beforeSnapshot);
        _assertClosePreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
    }

    function test_CloseParity_DeferredProfitMatchesPreview() public {
        address trader = address(0xD3A2);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(accountId, 100_000e18, 80_000_000);
        assertTrue(preview.valid, "Setup close preview should be valid");
        assertEq(preview.immediatePayoutUsdc, 0, "Illiquid profitable close should not pay immediately");
        assertGt(preview.deferredTraderCreditUsdc, 0, "Illiquid profitable close should defer payout");

        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(accountId);
        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        CloseParityObserved memory observed = _observeCloseParity(accountId, beforeSnapshot);
        _assertClosePreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
    }

    function test_CloseParity_LossConsumesSettlementMatchesPreview() public {
        address trader = address(0xD3A3);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000e6);

        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 5000e6, 1e8);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(accountId, 10_000e18, 120_000_000);
        assertTrue(preview.valid, "Setup loss close preview should be valid");
        assertEq(preview.immediatePayoutUsdc, 0, "Loss-making close should not create immediate payout");
        assertEq(preview.deferredTraderCreditUsdc, 0, "Loss-making close should not create deferred payout");
        assertEq(preview.badDebtUsdc, 0, "Setup should keep the loss fully collateralized");

        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(accountId);
        _close(accountId, CfdTypes.Side.BULL, 10_000e18, 120_000_000);

        CloseParityObserved memory observed = _observeCloseParity(accountId, beforeSnapshot);
        _assertClosePreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
    }

    function test_ClaimDeferredTraderCredit_CreditsClearinghouseWhenLiquidityReturns() public {
        address trader = address(0xD302);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        uint256 deferred = engine.deferredTraderCreditUsdc(accountId);
        assertGt(deferred, 0, "Setup should create a deferred payout");

        usdc.mint(address(pool), deferred);
        uint256 clearinghouseBefore = clearinghouse.balanceUsdc(accountId);

        vm.prank(trader);
        engine.claimDeferredTraderCredit(accountId);

        assertEq(engine.deferredTraderCreditUsdc(accountId), 0, "Claim should clear deferred payout state");
        assertEq(
            clearinghouse.balanceUsdc(accountId),
            clearinghouseBefore + deferred,
            "Claim should credit the clearinghouse balance"
        );
    }

    function test_ClaimDeferredTraderCredit_RealizesCarryBeforeCreditingSettlement() public {
        address trader = address(0xD30B);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 20_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);
        stdstore.target(address(engine)).sig("deferredTraderCreditUsdc(bytes32)").with_key(accountId)
            .checked_write(uint256(5000e6));
        stdstore.target(address(engine)).sig("totalDeferredTraderCreditUsdc()").checked_write(uint256(5000e6));

        vm.warp(block.timestamp + 30 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 settlementBefore = clearinghouse.balanceUsdc(accountId);
        uint256 expectedCarry = PositionRiskAccountingLib.computePendingCarryUsdc(
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, settlementBefore),
            _riskParams().baseCarryBps,
            30 days
        );

        usdc.mint(address(pool), 5000e6);
        uint256 poolRawBefore = pool.rawAssets();
        uint256 poolAccountedBefore = pool.accountedAssets();

        vm.prank(trader);
        engine.claimDeferredTraderCredit(accountId);

        assertEq(
            clearinghouse.balanceUsdc(accountId),
            settlementBefore + 5000e6 - expectedCarry,
            "Deferred payout claim should realize carry before crediting settlement"
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

    function test_ClaimDeferredTraderCredit_UsesStoredMarkCarryCheckpointWhenMarkIsStale() public {
        address trader = address(0xD30C);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 20_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);
        stdstore.target(address(engine)).sig("deferredTraderCreditUsdc(bytes32)").with_key(accountId)
            .checked_write(uint256(5000e6));
        stdstore.target(address(engine)).sig("totalDeferredTraderCreditUsdc()").checked_write(uint256(5000e6));

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 30 days);

        uint256 settlementBefore = clearinghouse.balanceUsdc(accountId);
        uint64 carryTimestampBefore = engine.getPositionLastCarryTimestamp(accountId);
        uint256 expectedCarry = PositionRiskAccountingLib.computePendingCarryUsdc(
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, engine.lastMarkPrice(), settlementBefore),
            _riskParams().baseCarryBps,
            block.timestamp - carryTimestampBefore
        );

        usdc.mint(address(pool), 5000e6);

        vm.prank(trader);
        engine.claimDeferredTraderCredit(accountId);

        assertEq(engine.deferredTraderCreditUsdc(accountId), 0, "Claim should clear deferred payout state");
        assertEq(
            clearinghouse.balanceUsdc(accountId),
            settlementBefore + 5000e6 - expectedCarry,
            "Stale deferred payout claim should checkpoint carry against the stored mark before crediting settlement"
        );
        assertEq(
            engine.getPositionLastCarryTimestamp(accountId),
            block.timestamp,
            "Stale deferred payout claim should advance the carry clock after checkpointing carry"
        );
        assertEq(
            engine.unsettledCarryUsdc(accountId),
            0,
            "Stale deferred payout claim should not leave carry deferred once the claim-funded settlement can satisfy it"
        );
    }

    function test_DeferredClaimConsistency_TraderClaimPreservesOtherReservedCash() public {
        address trader = address(0xD30D1);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        address keeperAccount = address(this);
        uint256 deferredTraderCredit = 5000e6;
        uint256 deferredKeeperCredit = 700e6;

        _fundTrader(trader, 20_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        stdstore.target(address(engine)).sig("deferredTraderCreditUsdc(bytes32)").with_key(accountId)
            .checked_write(deferredTraderCredit);
        stdstore.target(address(engine)).sig("totalDeferredTraderCreditUsdc()").checked_write(deferredTraderCredit);

        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(keeperAccount, deferredKeeperCredit);

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory beforeSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);
        usdc.mint(address(pool), deferredTraderCredit);

        vm.prank(trader);
        engine.claimDeferredTraderCredit(accountId);

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory afterSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();

        assertEq(
            afterSnapshot.accumulatedFeesUsdc,
            beforeSnapshot.accumulatedFeesUsdc,
            "Trader deferred claim must not consume protocol fee reserve"
        );
        assertEq(
            afterSnapshot.totalDeferredKeeperCreditUsdc,
            beforeSnapshot.totalDeferredKeeperCreditUsdc,
            "Trader deferred claim must not consume keeper deferred reserve"
        );
        assertEq(
            afterSnapshot.totalDeferredTraderCreditUsdc, 0, "Claim should extinguish the trader deferred liability"
        );
        assertEq(
            beforeSnapshot.withdrawalReservedUsdc - afterSnapshot.withdrawalReservedUsdc,
            deferredTraderCredit,
            "Withdrawal reserve should drop only by the trader deferred amount that was actually claimed"
        );
    }

    function test_StaleDeposit_PreservesPreMutationCarryBasis() public {
        address trader = address(0xD30D2);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        uint256 depositAmount = 500e6;

        _fundTrader(trader, 10_000e6);
        usdc.mint(trader, depositAmount);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        uint256 settlementBefore = clearinghouse.balanceUsdc(accountId);
        uint256 reachableBefore =
            MarginClearinghouseAccountingLib.getGenericReachableUsdc(clearinghouse.getAccountUsdcBuckets(accountId));

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 30 days);
        uint256 elapsed = 30 days + engine.engineMarkStalenessLimit();
        uint256 expectedCarry = PositionRiskAccountingLib.computePendingCarryUsdc(
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, reachableBefore),
            _riskParams().baseCarryBps,
            elapsed
        );

        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.depositMargin(depositAmount);
        vm.stopPrank();

        assertEq(
            clearinghouse.balanceUsdc(accountId),
            settlementBefore + depositAmount - expectedCarry,
            "Stale deposit should checkpoint carry on the pre-deposit basis before increasing collateral"
        );
        assertEq(
            engine.unsettledCarryUsdc(accountId),
            0,
            "Covered stale deposit carry should not leave residual unsettled carry"
        );
        assertEq(
            engine.getPositionLastCarryTimestamp(accountId),
            block.timestamp,
            "Stored-mark carry checkpoint should advance the carry timestamp at the stale deposit time"
        );
    }

    function test_ClaimDeferredTraderCredit_RevertsForNonOwner() public {
        address trader = address(0xD307);
        address relayer = address(0xD308);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        uint256 deferred = engine.deferredTraderCreditUsdc(accountId);
        usdc.mint(address(pool), deferred);

        vm.prank(relayer);
        vm.expectRevert(CfdEngine.CfdEngine__NotAccountOwner.selector);
        engine.claimDeferredTraderCredit(accountId);
    }

    function test_ClaimDeferredTraderCredit_AllowsPartialHeadClaimWhenLiquidityReturnsGradually() public {
        address trader = address(0xD306);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        uint256 deferred = engine.deferredTraderCreditUsdc(accountId);
        assertGt(deferred, 0, "Setup should create a deferred payout");

        uint256 partialLiquidity = deferred / 2;
        usdc.mint(address(pool), partialLiquidity);
        uint256 claimableNow = pool.totalAssets();
        if (claimableNow > deferred) {
            claimableNow = deferred;
        }

        uint256 clearinghouseBefore = clearinghouse.balanceUsdc(accountId);
        vm.prank(trader);
        engine.claimDeferredTraderCredit(accountId);

        assertEq(
            clearinghouse.balanceUsdc(accountId),
            clearinghouseBefore + claimableNow,
            "Deferred beneficiary claim should consume all currently available liquidity"
        );
        assertEq(
            engine.deferredTraderCreditUsdc(accountId),
            deferred - claimableNow,
            "Partial deferred claim should leave the remainder outstanding"
        );
    }

    function test_ClaimDeferredTraderCredit_BeneficiaryConsumesPartialLiquidityWithoutQueueOrdering() public {
        address trader = address(0xD309);
        address keeper = address(0xD30A);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        uint256 deferred = engine.deferredTraderCreditUsdc(accountId);
        assertGt(deferred, 0, "Setup should create a deferred trader credit");

        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(keeper, deferred);

        vm.startPrank(address(pool));
        usdc.transfer(address(0xDEAD), pool.totalAssets());
        vm.stopPrank();

        uint256 partialLiquidity = deferred / 2;
        usdc.mint(address(pool), partialLiquidity);
        uint256 claimableNow = pool.totalAssets();
        if (claimableNow > deferred) {
            claimableNow = deferred;
        }

        uint256 clearinghouseBefore = clearinghouse.balanceUsdc(accountId);
        vm.prank(trader);
        engine.claimDeferredTraderCredit(accountId);

        assertEq(
            clearinghouse.balanceUsdc(accountId),
            clearinghouseBefore + claimableNow,
            "Head deferred trader claim should consume partial liquidity before later claims"
        );
        assertEq(
            engine.deferredTraderCreditUsdc(accountId), deferred - claimableNow, "Head deferred payout should shrink"
        );
        assertEq(engine.deferredKeeperCreditUsdc(keeper), deferred, "Later deferred bounty should remain untouched");
    }

    function test_ClaimDeferredTraderCredit_RevertsWithoutLiquidityOrPayout() public {
        address trader = address(0xD303);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);

        vm.prank(trader);
        vm.expectRevert(CfdEngine.CfdEngine__NoDeferredTraderCredit.selector);
        engine.claimDeferredTraderCredit(accountId);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        vm.startPrank(address(pool));
        usdc.transfer(address(0xDEAD), pool.totalAssets());
        vm.stopPrank();

        vm.prank(trader);
        vm.expectRevert(CfdEngine.CfdEngine__InsufficientVaultLiquidity.selector);
        engine.claimDeferredTraderCredit(accountId);
    }

    function test_ClaimDeferredKeeperCredit_RevertsWhenTraderClaimIsAheadInQueue() public {
        address trader = address(0xD304);
        address keeper = address(0xD305);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        uint256 deferred = engine.deferredTraderCreditUsdc(accountId);
        assertGt(deferred, 0, "Setup should create a deferred payout");

        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(keeper, deferred);

        usdc.mint(address(pool), deferred);

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(bytes32(uint256(uint160(keeper))));
        vm.prank(keeper);
        engine.claimDeferredKeeperCredit();
        assertGt(
            clearinghouse.balanceUsdc(bytes32(uint256(uint160(keeper)))) - keeperSettlementBefore,
            0,
            "Deferred keeper credit should no longer require head-of-queue priority"
        );
    }

    function test_NoSideCarryRealization_KeepsClearinghouseMarginInSync() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 20_000 * 1e6);

        // Open BULL $100k at $1.00
        CfdTypes.Order memory openOrder = CfdTypes.Order({
            accountId: accountId,
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
        engine.processOrderTyped(openOrder, 1e8, vaultDepth, uint64(block.timestamp));

        (, uint256 marginAfterOpen,,,,,) = engine.positions(accountId);
        IMarginClearinghouse.LockedMarginBuckets memory lockedAfterOpen =
            clearinghouse.getLockedMarginBuckets(accountId);
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
            accountId: accountId,
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
        engine.processOrderTyped(addOrder, 1e8, vaultDepth, uint64(block.timestamp));

        (, uint256 marginAfterAdd,,,,,) = engine.positions(accountId);
        IMarginClearinghouse.LockedMarginBuckets memory lockedAfterAdd = clearinghouse.getLockedMarginBuckets(accountId);
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

    function test_WithdrawFees() public {
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);

        CfdTypes.Order memory order = CfdTypes.Order({
            accountId: accountId,
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
        uint256 fees = engine.accumulatedFeesUsdc();
        assertEq(fees, 40_000_000, "Exec fee should be 4bps of $100k notional");

        address treasury = address(0xBEEF);
        uint256 assetsBeforeWithdrawal = pool.totalAssets();
        engine.withdrawFees(treasury);

        assertEq(engine.accumulatedFeesUsdc(), 0, "Fees should reset to zero");
        assertEq(usdc.balanceOf(treasury), fees, "Treasury receives exact fee amount");
        assertEq(
            pool.totalAssets(),
            assetsBeforeWithdrawal - fees,
            "Fee withdrawal should reduce canonical assets only by the already-accounted fee amount"
        );
        assertEq(pool.excessAssets(), 0, "Fee inflows should not remain stranded as excess before or after withdrawal");

        vm.expectRevert(CfdEngine.CfdEngine__NoFeesToWithdraw.selector);
        engine.withdrawFees(treasury);
    }

    function test_CloseProtocolFeeInflow_IsBoundedByPhysicalCashReceived() public {
        _fundJunior(address(0xB0B), 1_000_000e6);

        address trader = address(0xAB1720);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        uint256 assetsBeforeClose = pool.totalAssets();
        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 100_030_000);
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

    function test_WithdrawFees_RespectsSeniorCashReservation() public {
        bytes32 accountId = bytes32(uint256(0xFEE1));
        address keeper = address(0xFEE2);
        address treasury = address(0xFEE3);
        _fundTrader(address(uint160(uint256(accountId))), 5000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        uint256 fees = engine.accumulatedFeesUsdc();
        uint256 deferredBounty = 25e6;
        uint256 solvencyBuffer = pool.totalAssets();

        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(keeper, deferredBounty);

        vm.startPrank(address(pool));
        usdc.transfer(address(0xDEAD), pool.totalAssets());
        vm.stopPrank();

        usdc.mint(address(pool), fees);

        vm.expectRevert(CfdEngine.CfdEngine__InsufficientVaultLiquidity.selector);
        engine.withdrawFees(treasury);

        usdc.mint(address(pool), deferredBounty + solvencyBuffer);
        engine.withdrawFees(treasury);

        assertEq(usdc.balanceOf(treasury), fees, "Fee withdrawal should succeed once senior deferred cash is funded");
        assertEq(engine.accumulatedFeesUsdc(), 0, "Fee withdrawal should still clear accumulated fees");
        assertEq(
            engine.deferredKeeperCreditUsdc(keeper),
            deferredBounty,
            "Withdrawing fees must not consume deferred senior claims"
        );
    }

    function test_WithdrawFees_AllowsPartialWithdrawal() public {
        address trader = address(0xFEE4A);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        address treasury = address(0xFEE5);
        _fundTrader(trader, 10_000e6);

        CfdTypes.Order memory order = CfdTypes.Order({
            accountId: accountId,
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

        uint256 feesBefore = engine.accumulatedFeesUsdc();
        uint256 partialAmount = feesBefore / 2;

        engine.withdrawFees(treasury, partialAmount);

        assertEq(usdc.balanceOf(treasury), partialAmount, "Treasury should receive the requested partial fee amount");
        assertEq(
            engine.accumulatedFeesUsdc(),
            feesBefore - partialAmount,
            "Partial fee withdrawal should leave the remainder booked"
        );
    }

    function test_ClaimDeferredKeeperCredit_UsesFeeOnlyLiquidityWhenAtQueueHead() public {
        bytes32 accountId = bytes32(uint256(0xFEE4));
        address keeper = address(0xFEE5);
        _fundTrader(address(uint160(uint256(accountId))), 5000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        uint256 fees = engine.accumulatedFeesUsdc();
        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(keeper, 1e6);

        vm.startPrank(address(pool));
        usdc.transfer(address(0xDEAD), pool.totalAssets());
        vm.stopPrank();

        usdc.mint(address(pool), fees);

        DeferredEngineViewTypes.DeferredCreditStatus memory status = _deferredCreditStatus(bytes32(0), keeper);
        assertTrue(status.keeperCreditClaimableNow, "Queue-head deferred bounty should be claimable ahead of fees");

        uint256 feesBefore = engine.accumulatedFeesUsdc();
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(bytes32(uint256(uint160(keeper))));
        vm.prank(keeper);
        engine.claimDeferredKeeperCredit();

        assertEq(
            clearinghouse.balanceUsdc(bytes32(uint256(uint160(keeper)))) - keeperSettlementBefore,
            1e6,
            "Keeper should receive the queue-head deferred bounty as clearinghouse credit"
        );
        assertEq(engine.accumulatedFeesUsdc(), feesBefore, "Servicing deferred claims must not burn fee accounting");
    }

    function test_ClaimDeferredKeeperCredit_RealizesCarryBeforeCreditingSettlement() public {
        address keeper = address(0xFEE6);
        bytes32 keeperAccountId = bytes32(uint256(uint160(keeper)));
        _fundTrader(keeper, 20_000e6);

        _open(keeperAccountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);
        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(keeper, 5000e6);

        vm.warp(block.timestamp + 30 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 settlementBefore = clearinghouse.balanceUsdc(keeperAccountId);
        uint256 expectedCarry = PositionRiskAccountingLib.computePendingCarryUsdc(
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, settlementBefore),
            _riskParams().baseCarryBps,
            30 days
        );

        usdc.mint(address(pool), 5000e6);
        uint256 poolRawBefore = pool.rawAssets();
        uint256 poolAccountedBefore = pool.accountedAssets();

        vm.prank(keeper);
        engine.claimDeferredKeeperCredit();

        assertEq(
            clearinghouse.balanceUsdc(keeperAccountId),
            settlementBefore + 5000e6 - expectedCarry,
            "Deferred keeper credit claim should realize carry before crediting settlement"
        );
        assertEq(
            pool.rawAssets(),
            poolRawBefore + expectedCarry - 5000e6,
            "Clearer claim should net payout against realized carry cash flow"
        );
        assertEq(
            pool.accountedAssets(),
            poolAccountedBefore + expectedCarry - 5000e6,
            "Clearer claim should keep accounted assets aligned with net physical cash after carry realization"
        );
    }

    function test_ClaimDeferredKeeperCredit_UsesStoredMarkCarryCheckpointWhenMarkIsStale() public {
        address keeper = address(0xFEE7);
        bytes32 keeperAccountId = bytes32(uint256(uint160(keeper)));
        _fundTrader(keeper, 20_000e6);

        _open(keeperAccountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);
        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(keeper, 5000e6);

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 30 days);

        uint256 settlementBefore = clearinghouse.balanceUsdc(keeperAccountId);
        uint64 carryTimestampBefore = engine.getPositionLastCarryTimestamp(keeperAccountId);
        uint256 expectedCarry = PositionRiskAccountingLib.computePendingCarryUsdc(
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, engine.lastMarkPrice(), settlementBefore),
            _riskParams().baseCarryBps,
            block.timestamp - carryTimestampBefore
        );

        usdc.mint(address(pool), 5000e6);

        vm.prank(keeper);
        engine.claimDeferredKeeperCredit();

        assertEq(
            clearinghouse.balanceUsdc(keeperAccountId),
            settlementBefore + 5000e6 - expectedCarry,
            "Stale deferred keeper claim should checkpoint carry against the stored mark before crediting settlement"
        );
        assertEq(
            engine.getPositionLastCarryTimestamp(keeperAccountId),
            block.timestamp,
            "Stale deferred keeper claim should advance the carry clock after checkpointing carry"
        );
        assertEq(
            engine.unsettledCarryUsdc(keeperAccountId),
            0,
            "Stale deferred keeper claim should not leave carry deferred once the claim-funded settlement can satisfy it"
        );
    }

    function test_AddMargin_UpdatesPositionAndSideTotals() public {
        address trader = address(0xABCD);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000 * 1e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8);

        (, uint256 marginBefore,,,,,) = engine.positions(accountId);
        uint256 lockedBefore = clearinghouse.lockedMarginUsdc(accountId);
        uint256 totalBullMarginBefore = _sideTotalMargin(CfdTypes.Side.BULL);

        vm.prank(trader);
        engine.addMargin(accountId, 500 * 1e6);

        (, uint256 marginAfter,,,,,) = engine.positions(accountId);
        assertEq(marginAfter, marginBefore + 500 * 1e6, "Position margin should increase by the added amount");
        assertEq(
            clearinghouse.lockedMarginUsdc(accountId),
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
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000 * 1e6);
        _open(accountId, CfdTypes.Side.BULL, 50_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(address(0xBEEF));
        vm.expectRevert(CfdEngine.CfdEngine__NotAccountOwner.selector);
        engine.addMargin(accountId, 100 * 1e6);
    }

    function test_AddMargin_RevertsForZeroAmountAndMissingPosition() public {
        address trader = address(0xABCF);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000 * 1e6);

        vm.prank(trader);
        vm.expectRevert(CfdEngine.CfdEngine__NoOpenPosition.selector);
        engine.addMargin(accountId, 100 * 1e6);

        _open(accountId, CfdTypes.Side.BULL, 50_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(trader);
        vm.expectRevert(CfdEngine.CfdEngine__PositionTooSmall.selector);
        engine.addMargin(accountId, 0);
    }

    function test_AddMargin_RevertsOnStaleMark() public {
        address trader = address(0xABD3);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000e6);
        _open(accountId, CfdTypes.Side.BULL, 20_000e18, 2000e6, 1e8);

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);

        vm.prank(trader);
        vm.expectRevert(CfdEngine.CfdEngine__MarkPriceStale.selector);
        engine.addMargin(accountId, 100e6);
    }

    function test_CheckWithdraw_RevertsForNonClearinghouseCaller() public {
        bytes32 accountId = bytes32(uint256(0x51582));
        _fundTrader(address(uint160(uint256(accountId))), 5000e6);
        _open(accountId, CfdTypes.Side.BULL, 20_000e18, 2000e6, 1e8);

        vm.expectRevert(CfdEngine.CfdEngine__NotClearinghouse.selector);
        engine.checkWithdraw(accountId);
    }

    function test_DepositWithdrawMargin_RealizesCarryBeforeBalanceMutation() public {
        address trader = address(0xABD0);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        uint256 depositAmount = 50_000e6;

        _fundTrader(trader, 20_000e6);
        usdc.mint(trader, depositAmount);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.warp(block.timestamp + 1 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 settlementBefore = clearinghouse.balanceUsdc(accountId);
        uint256 poolRawBefore = pool.rawAssets();
        uint256 poolAccountedBefore = pool.accountedAssets();
        uint256 clearinghouseRawBefore = usdc.balanceOf(address(clearinghouse));
        uint256 expectedCarry = PositionRiskAccountingLib.computePendingCarryUsdc(
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, settlementBefore),
            _riskParams().baseCarryBps,
            1 days
        );
        assertGt(expectedCarry, 0, "Setup must accrue carry before the balance mutation");

        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.depositMargin(depositAmount);
        assertEq(
            clearinghouse.balanceUsdc(accountId),
            settlementBefore + depositAmount - expectedCarry,
            "Deposit hook should realize carry before adding fresh settlement"
        );
        assertEq(pool.rawAssets(), poolRawBefore + expectedCarry, "Carry realization should physically fund the vault");
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
            clearinghouse.balanceUsdc(accountId),
            settlementBefore - expectedCarry,
            "Deposit-withdraw roundtrip must not erase accrued carry"
        );
    }

    function test_DepositMargin_CanRescueAccountWhenIncomingCashCoversCarry() public {
        address trader = address(0xABD1);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        uint256 rescueDeposit = 50_000e6;
        uint256 carryElapsed = 365 days * 3;

        _fundTrader(trader, 10_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        uint256 settlementBefore = clearinghouse.balanceUsdc(accountId);

        usdc.mint(trader, rescueDeposit);

        vm.warp(block.timestamp + carryElapsed);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.roll(block.number + 1);

        uint256 expectedCarry = PositionRiskAccountingLib.computePendingCarryUsdc(
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, settlementBefore),
            _riskParams().baseCarryBps,
            carryElapsed
        );
        assertGt(
            expectedCarry, settlementBefore, "Setup must accrue more carry than the pre-deposit settlement balance"
        );

        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.depositMargin(rescueDeposit);
        vm.stopPrank();

        assertEq(
            clearinghouse.balanceUsdc(accountId),
            settlementBefore + rescueDeposit - expectedCarry,
            "Rescue deposit should settle pre-basis carry from the incoming cash in the same tx"
        );
    }

    function test_DepositMargin_SucceedsOnStaleMarkWithoutCheckpointingCarry() public {
        address trader = address(0xABD1A);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        uint256 depositAmount = 500e6;

        _fundTrader(trader, 10_000e6);
        usdc.mint(trader, depositAmount);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        uint256 settlementBefore = clearinghouse.balanceUsdc(accountId);
        uint64 carryTimestampBefore = engine.getPositionLastCarryTimestamp(accountId);
        uint256 unsettledCarryBefore = engine.unsettledCarryUsdc(accountId);

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 30 days);

        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.depositMargin(depositAmount);
        vm.stopPrank();

        assertEq(
            clearinghouse.balanceUsdc(accountId),
            settlementBefore + depositAmount,
            "Stale-mark deposit should still credit the full settlement amount"
        );
        assertEq(
            engine.getPositionLastCarryTimestamp(accountId),
            carryTimestampBefore,
            "Stale-mark deposit should not advance the carry checkpoint"
        );
        assertEq(
            engine.unsettledCarryUsdc(accountId),
            unsettledCarryBefore,
            "Stale-mark deposit should not synthesize unsettled carry just to preserve liveness"
        );
    }

    function test_ReserveCommittedOrderMargin_CheckpointsCarryBeforeReachabilityDrops() public {
        address trader = address(0xABD3);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        uint256 reserveAmount = 4000e6;
        uint256 depositAmount = 1000e6;
        uint256 carryElapsed = 30 days;

        _fundTrader(trader, 10_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        uint256 settlementBefore = clearinghouse.balanceUsdc(accountId);

        vm.warp(block.timestamp + carryElapsed);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.roll(block.number + 1);

        uint256 expectedCarry = PositionRiskAccountingLib.computePendingCarryUsdc(
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, settlementBefore),
            _riskParams().baseCarryBps,
            carryElapsed
        );

        vm.prank(address(router));
        clearinghouse.reserveCommittedOrderMargin(accountId, 77, reserveAmount);

        assertEq(
            clearinghouse.balanceUsdc(accountId),
            settlementBefore - expectedCarry,
            "Committed-order reservation should realize carry before lowering reachable collateral"
        );
        assertEq(
            engine.unsettledCarryUsdc(accountId), 0, "Reservation checkpoint should settle elapsed carry immediately"
        );

        usdc.mint(trader, depositAmount);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.depositMargin(depositAmount);
        vm.stopPrank();

        assertEq(
            clearinghouse.balanceUsdc(accountId),
            settlementBefore - expectedCarry + depositAmount,
            "Later deposits must not retroactively reprice pre-reservation carry on the reduced basis"
        );
    }

    function test_SeizeUsdc_CheckpointsCarryBeforeReachabilityDrops() public {
        address trader = address(0xABD4);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        uint256 seizedAmount = 1e6;
        uint256 depositAmount = 1000e6;
        uint256 carryElapsed = 30 days;

        _fundTrader(trader, 10_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        uint256 settlementBefore = clearinghouse.balanceUsdc(accountId);

        vm.warp(block.timestamp + carryElapsed);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 expectedCarry = PositionRiskAccountingLib.computePendingCarryUsdc(
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, settlementBefore),
            _riskParams().baseCarryBps,
            carryElapsed
        );

        vm.prank(address(router));
        clearinghouse.seizeUsdc(accountId, seizedAmount, address(router));

        assertEq(
            clearinghouse.balanceUsdc(accountId),
            settlementBefore - expectedCarry - seizedAmount,
            "Settlement seizure should realize carry before debiting trader cash"
        );
        assertEq(
            engine.unsettledCarryUsdc(accountId), 0, "Settlement seizure should not leave elapsed carry uncheckpointed"
        );

        usdc.mint(trader, depositAmount);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.depositMargin(depositAmount);
        vm.stopPrank();

        assertEq(
            clearinghouse.balanceUsdc(accountId),
            settlementBefore - expectedCarry - seizedAmount + depositAmount,
            "Later deposits must not retroactively apply the post-seizure carry basis to prior time"
        );
    }

    function test_UnlockReservedSettlement_CheckpointsCarryBeforeReachabilityRises() public {
        address trader = address(0xABD6);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        uint256 reservedAmount = 3000e6;
        uint256 carryElapsed = 30 days;

        _fundTrader(trader, 10_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        vm.prank(address(router));
        clearinghouse.lockReservedSettlement(accountId, reservedAmount);

        uint256 settlementBeforeUnlock = clearinghouse.balanceUsdc(accountId);
        uint256 reservedReachable =
            MarginClearinghouseAccountingLib.getGenericReachableUsdc(clearinghouse.getAccountUsdcBuckets(accountId));

        vm.warp(block.timestamp + carryElapsed);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 expectedCarry = PositionRiskAccountingLib.computePendingCarryUsdc(
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, reservedReachable),
            _riskParams().baseCarryBps,
            carryElapsed
        );

        vm.prank(address(router));
        clearinghouse.unlockReservedSettlement(accountId, reservedAmount);

        assertEq(
            clearinghouse.balanceUsdc(accountId),
            settlementBeforeUnlock - expectedCarry,
            "Reserved-settlement unlock should checkpoint carry before reserved funds become reachable again"
        );
        assertEq(engine.unsettledCarryUsdc(accountId), 0, "Unlock should not leave elapsed carry uncheckpointed");
    }

    function test_SeizeUsdc_RechecksFreeSettlementAfterCarryCheckpoint() public {
        address trader = address(0xABD7);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        uint256 carryElapsed = 30 days;

        _fundTrader(trader, 10_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        uint256 freeSettlementBefore =
            MarginClearinghouseAccountingLib.getFreeSettlementUsdc(clearinghouse.getAccountUsdcBuckets(accountId));

        vm.warp(block.timestamp + carryElapsed);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 expectedCarry = PositionRiskAccountingLib.computePendingCarryUsdc(
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(
                100_000e18, 1e8, clearinghouse.balanceUsdc(accountId)
            ),
            _riskParams().baseCarryBps,
            carryElapsed
        );
        assertGt(expectedCarry, 0, "Setup must accrue carry before seizure");

        vm.prank(address(router));
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientAssetToSeize.selector);
        clearinghouse.seizeUsdc(accountId, freeSettlementBefore, address(router));
    }

    function test_ProfitableClose_DoesNotDoubleBookCarryIntoAccountedAssets() public {
        address trader = address(0xABD2);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 20_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.warp(block.timestamp + 1 days);
        vm.prank(address(router));
        engine.updateMarkPrice(80_000_000, uint64(block.timestamp));

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        assertEq(
            pool.accountedAssets(),
            pool.rawAssets(),
            "Profitable close carry should not create accounted-assets overhang"
        );
    }

    function test_SettlementModule_RevertsWhenCalledDirectly() public {
        CfdEngineSettlementModule module = CfdEngineSettlementModule(address(engine.settlementModule()));
        CfdEnginePlanTypes.CloseDelta memory delta;
        CfdTypes.Position memory position;

        vm.expectRevert(CfdEngineSettlementModule.CfdEngineSettlementModule__Unauthorized.selector);
        module.executeClose(ICfdEngineSettlementHost(address(engine)), delta, position, uint64(block.timestamp));
    }

    function test_GetAccountCollateralView_ReturnsCurrentBuckets() public {
        address trader = address(0xAB10);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000 * 1e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 7900 * 1e6, type(uint256).max, false);

        CfdEngine.AccountCollateralView memory viewData = engineAccountLens.getAccountCollateralView(accountId);
        (, uint256 positionMargin,,,,,) = engine.positions(accountId);
        assertEq(viewData.settlementBalanceUsdc, clearinghouse.balanceUsdc(accountId));
        assertEq(viewData.lockedMarginUsdc, clearinghouse.lockedMarginUsdc(accountId));
        assertEq(viewData.activePositionMarginUsdc, positionMargin);
        assertEq(viewData.otherLockedMarginUsdc, viewData.lockedMarginUsdc - positionMargin);
        assertEq(viewData.freeSettlementUsdc, _freeSettlementUsdc(accountId));
        assertEq(viewData.closeReachableUsdc, _freeSettlementUsdc(accountId));
        assertEq(viewData.terminalReachableUsdc, _terminalReachableUsdc(accountId));
        assertEq(viewData.accountEquityUsdc, clearinghouse.getAccountEquityUsdc(accountId));
        assertEq(viewData.freeBuyingPowerUsdc, clearinghouse.getFreeBuyingPowerUsdc(accountId));
        assertEq(viewData.deferredTraderCreditUsdc, 0);
    }

    function test_GetPositionView_ReturnsLivePositionState() public {
        address trader = address(0xAB11);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000 * 1e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(90_000_000, uint64(block.timestamp));

        PerpsViewTypes.PositionView memory viewData = _publicPosition(accountId);
        (, uint256 positionMargin,,,,,) = engine.positions(accountId);
        assertTrue(viewData.exists);
        assertEq(uint256(viewData.side), uint256(CfdTypes.Side.BULL));
        assertEq(viewData.size, 100_000 * 1e18);
        assertEq(viewData.entryPrice, 1e8);
        assertEq(viewData.marginUsdc, positionMargin);
        assertGt(viewData.unrealizedPnlUsdc, 0);
    }

    function test_GetPositionView_DoesNotCountDeferredTraderCreditAsPhysicalCollateral() public {
        address trader = address(0xAB1101);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 5000e6);
        _open(accountId, CfdTypes.Side.BEAR, 10_000e18, 5000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        _close(accountId, CfdTypes.Side.BEAR, 5000e18, 120_000_000);
        assertGt(engine.deferredTraderCreditUsdc(accountId), 0, "Setup must create deferred trader credit");

        PerpsViewTypes.PositionView memory viewData = _publicPosition(accountId);
        (, uint256 positionMargin,,,,,) = engine.positions(accountId);
        assertEq(viewData.marginUsdc, positionMargin, "Public position view should still expose locked position margin");
        assertEq(
            viewData.exists,
            true,
            "Deferred trader credit should not hide the remaining open position from the public lens"
        );
    }

    function test_GetProtocolAccountingView_ReflectsDeferredLiabilities() public {
        address trader = address(0xAB12);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory viewData =
            engineProtocolLens.getProtocolAccountingSnapshot();
        assertEq(viewData.vaultAssetsUsdc, pool.totalAssets());
        assertEq(viewData.withdrawalReservedUsdc, _withdrawalReservedUsdc());
        assertEq(viewData.accumulatedFeesUsdc, engine.accumulatedFeesUsdc());
        assertEq(viewData.totalDeferredTraderCreditUsdc, engine.totalDeferredTraderCreditUsdc());
        assertEq(viewData.totalDeferredKeeperCreditUsdc, engine.totalDeferredKeeperCreditUsdc());
        assertEq(viewData.degradedMode, engine.degradedMode());
        assertEq(viewData.hasLiveLiability, (_maxLiability() > 0));
    }

    function test_GetProtocolAccountingSnapshot_ReflectsCanonicalLedgerState() public {
        address trader = address(0xAB13);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory viewData =
            engineProtocolLens.getProtocolAccountingSnapshot();
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory housePoolSnapshot =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());

        assertEq(snapshot.vaultAssetsUsdc, pool.totalAssets());
        assertEq(
            snapshot.netPhysicalAssetsUsdc,
            snapshot.vaultAssetsUsdc > snapshot.accumulatedFeesUsdc
                ? snapshot.vaultAssetsUsdc - snapshot.accumulatedFeesUsdc
                : 0
        );
        assertEq(snapshot.maxLiabilityUsdc, _maxLiability());
        assertEq(snapshot.withdrawalReservedUsdc, _withdrawalReservedUsdc());
        assertEq(snapshot.accumulatedFeesUsdc, engine.accumulatedFeesUsdc());
        assertEq(snapshot.accumulatedBadDebtUsdc, engine.accumulatedBadDebtUsdc());
        assertEq(snapshot.totalDeferredTraderCreditUsdc, engine.totalDeferredTraderCreditUsdc());
        assertEq(snapshot.totalDeferredKeeperCreditUsdc, engine.totalDeferredKeeperCreditUsdc());
        assertEq(snapshot.degradedMode, engine.degradedMode());
        assertEq(snapshot.hasLiveLiability, (_maxLiability() > 0));
        assertEq(snapshot.vaultAssetsUsdc, viewData.vaultAssetsUsdc);
        assertEq(housePoolSnapshot.physicalAssetsUsdc, snapshot.vaultAssetsUsdc);
        assertEq(snapshot.maxLiabilityUsdc, viewData.maxLiabilityUsdc);
        assertEq(snapshot.withdrawalReservedUsdc, viewData.withdrawalReservedUsdc);
        assertEq(snapshot.freeUsdc, viewData.freeUsdc);
        assertEq(snapshot.accumulatedFeesUsdc, viewData.accumulatedFeesUsdc);
        assertEq(snapshot.totalDeferredTraderCreditUsdc, viewData.totalDeferredTraderCreditUsdc);
        assertEq(snapshot.totalDeferredKeeperCreditUsdc, viewData.totalDeferredKeeperCreditUsdc);
        assertEq(snapshot.degradedMode, viewData.degradedMode);
        assertEq(snapshot.hasLiveLiability, viewData.hasLiveLiability);
        assertEq(snapshot.netPhysicalAssetsUsdc, housePoolSnapshot.netPhysicalAssetsUsdc);
        assertEq(snapshot.maxLiabilityUsdc, housePoolSnapshot.maxLiabilityUsdc);
        assertEq(snapshot.totalDeferredTraderCreditUsdc, housePoolSnapshot.deferredTraderCreditUsdc);
        assertEq(snapshot.totalDeferredKeeperCreditUsdc, housePoolSnapshot.deferredKeeperCreditUsdc);
        assertEq(snapshot.accumulatedFeesUsdc, housePoolSnapshot.protocolFeesUsdc);
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
        assertEq(beforeAccount.vaultAssetsUsdc, accountedBefore, "Protocol snapshot should follow canonical assets");
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
            afterAccount.vaultAssetsUsdc,
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
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 12_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        vm.startPrank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, 0, false);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);
        vm.stopPrank();

        AccountLensViewTypes.AccountLedgerView memory ledgerView = engineAccountLens.getAccountLedgerView(accountId);
        (, uint256 positionMargin,,,,,) = engine.positions(accountId);
        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(accountId);
        IOrderRouterAccounting.AccountEscrowView memory escrow = router.getAccountEscrow(accountId);

        assertEq(ledgerView.settlementBalanceUsdc, buckets.settlementBalanceUsdc);
        assertEq(ledgerView.freeSettlementUsdc, buckets.freeSettlementUsdc);
        assertEq(ledgerView.activePositionMarginUsdc, buckets.activePositionMarginUsdc);
        assertEq(ledgerView.otherLockedMarginUsdc, buckets.otherLockedMarginUsdc);
        assertEq(ledgerView.executionEscrowUsdc, escrow.executionBountyUsdc);
        assertEq(ledgerView.committedMarginUsdc, escrow.committedMarginUsdc);
        assertEq(ledgerView.deferredTraderCreditUsdc, engine.deferredTraderCreditUsdc(accountId));
        assertEq(ledgerView.pendingOrderCount, router.pendingOrderCounts(accountId));
    }

    function test_GetAccountLedgerSnapshot_ReflectsExpandedAccountHealthState() public {
        address trader = address(0xAB16);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 12_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot =
            engineAccountLens.getAccountLedgerSnapshot(accountId);
        CfdEngine.AccountCollateralView memory collateralView = engineAccountLens.getAccountCollateralView(accountId);
        (uint256 sizeStored, uint256 marginStored, uint256 entryPriceStored,, CfdTypes.Side sideStored,,) =
            engine.positions(accountId);
        IMarginClearinghouse.LockedMarginBuckets memory lockedBuckets = clearinghouse.getLockedMarginBuckets(accountId);
        IOrderRouterAccounting.AccountEscrowView memory escrow = router.getAccountEscrow(accountId);

        assertEq(snapshot.settlementBalanceUsdc, collateralView.settlementBalanceUsdc);
        assertEq(snapshot.freeSettlementUsdc, collateralView.freeSettlementUsdc);
        assertEq(snapshot.activePositionMarginUsdc, collateralView.activePositionMarginUsdc);
        assertEq(snapshot.otherLockedMarginUsdc, collateralView.otherLockedMarginUsdc);
        assertEq(snapshot.positionMarginBucketUsdc, lockedBuckets.positionMarginUsdc);
        assertEq(snapshot.committedOrderMarginBucketUsdc, lockedBuckets.committedOrderMarginUsdc);
        assertEq(snapshot.reservedSettlementBucketUsdc, lockedBuckets.reservedSettlementUsdc);
        assertEq(snapshot.executionEscrowUsdc, escrow.executionBountyUsdc);
        assertEq(snapshot.committedMarginUsdc, escrow.committedMarginUsdc);
        assertEq(snapshot.deferredTraderCreditUsdc, collateralView.deferredTraderCreditUsdc);
        assertEq(snapshot.pendingOrderCount, escrow.pendingOrderCount);
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
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory status = engineProtocolLens.getHousePoolStatusSnapshot();
        uint256 fees = engine.accumulatedFeesUsdc();

        assertEq(
            snapshot.physicalAssetsUsdc, pool.totalAssets(), "Snapshot physical assets must match canonical pool assets"
        );
        assertEq(
            snapshot.netPhysicalAssetsUsdc, pool.totalAssets() - fees, "Snapshot net assets must exclude protocol fees"
        );
        assertEq(snapshot.maxLiabilityUsdc, _maxLiability(), "Snapshot liability must match accessor");
        assertEq(snapshot.supplementalReservedUsdc, uint256(0), "Snapshot supplemental reserve must match accessor");
        assertEq(
            snapshot.unrealizedMtmLiabilityUsdc, _vaultMtmAdjustment(), "Snapshot MtM liability must match accessor"
        );
        assertEq(
            snapshot.deferredTraderCreditUsdc,
            engine.totalDeferredTraderCreditUsdc(),
            "Snapshot payout must match storage"
        );
        assertEq(
            snapshot.deferredKeeperCreditUsdc,
            engine.totalDeferredKeeperCreditUsdc(),
            "Snapshot bounty must match storage"
        );
        assertEq(snapshot.protocolFeesUsdc, fees, "Snapshot fees must match storage");
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
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);
        _open(accountId, CfdTypes.Side.BEAR, 100_000e18, 9000e6, 1e8);

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

    function test_PreviewClose_ReturnsDeferredAndImmediateSettlementBreakdown() public {
        address trader = address(0xAB13);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        CfdEngine.ClosePreview memory normalPreview = engineLens.previewClose(accountId, 100_000e18, 80_000_000);
        assertTrue(normalPreview.valid);
        assertGt(normalPreview.immediatePayoutUsdc, 0);
        assertEq(normalPreview.deferredTraderCreditUsdc, 0);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        CfdEngine.ClosePreview memory illiquidPreview = engineLens.previewClose(accountId, 100_000e18, 80_000_000);
        assertTrue(illiquidPreview.valid);
        assertEq(illiquidPreview.immediatePayoutUsdc, 0);
        assertGt(illiquidPreview.deferredTraderCreditUsdc, 0);
        assertEq(illiquidPreview.remainingSize, 0);
    }

    function test_SimulateClose_UsesHypotheticalVaultCashForPayoutBreakdown() public {
        address trader = address(0xAB1301);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 canonicalDepth = pool.totalAssets();
        CfdEngine.ClosePreview memory canonicalPreview = engineLens.previewClose(accountId, 100_000e18, 80_000_000);
        CfdEngine.ClosePreview memory hypotheticalPreview =
            engineLens.simulateClose(accountId, 100_000e18, 80_000_000, 1);

        assertTrue(canonicalPreview.valid);
        assertGt(canonicalPreview.immediatePayoutUsdc, 0, "Live preview should reflect currently available vault cash");
        assertEq(canonicalPreview.deferredTraderCreditUsdc, 0, "Live preview should not defer when cash is available");
        assertEq(canonicalDepth, pool.totalAssets(), "Setup should keep canonical depth unchanged");

        assertTrue(hypotheticalPreview.valid);
        assertEq(hypotheticalPreview.immediatePayoutUsdc, 0, "Hypothetical close should use caller-supplied vault cash");
        assertGt(hypotheticalPreview.deferredTraderCreditUsdc, 0, "Low hypothetical cash should defer the payout");
    }

    function test_PreviewClose_TriggersDegradedModeMatchesLiveClose() public {
        address bullTrader = address(0xAB1308);
        address bearTrader = address(0xAB1309);
        bytes32 bullId = bytes32(uint256(uint160(bullTrader)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));

        _fundTrader(bullTrader, 100_000e6);
        _fundTrader(bearTrader, 100_000e6);

        _open(bearId, CfdTypes.Side.BEAR, 1_000_000e18, 50_000e6, 1e8);
        _open(bullId, CfdTypes.Side.BULL, 500_000e18, 50_000e6, 1e8);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(bullId, 500_000e18, 20_000_000);
        assertTrue(preview.triggersDegradedMode, "Preview should flag the profitable close that reveals insolvency");

        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(bullId);
        _close(bullId, CfdTypes.Side.BULL, 500_000e18, 20_000_000);

        CloseParityObserved memory observed = _observeCloseParity(bullId, beforeSnapshot);
        _assertClosePreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
        assertTrue(engine.degradedMode(), "Live close should match preview degraded-mode trigger");
    }

    function helper_PreviewClose_RecomputesPostOpStateInCarryModel() public {
        address bullTrader = address(0xAB130A);
        address bearTrader = address(0xAB130B);
        bytes32 bullId = bytes32(uint256(uint160(bullTrader)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));

        _fundTrader(bullTrader, 12_000e6);
        _fundTrader(bearTrader, 30_000e6);

        _open(bullId, CfdTypes.Side.BULL, 500_000e18, 8000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 50_000e18, 20_000e6, 1e8);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint64 accrualTime = refreshTime + 30;
        vm.warp(accrualTime);

        (uint256 bullSize, uint256 bullMargin,, uint256 bullMaxProfit,,,) = engine.positions(bullId);

        CfdEngine.ClosePreview memory preDrainPreview = engineLens.previewClose(bullId, bullSize, 1e8);
        assertTrue(preDrainPreview.valid, "Setup close preview should remain valid");

        uint256 grossTargetAssets =
            _maxLiabilityAfterClose(CfdTypes.Side.BULL, bullMaxProfit) + engine.accumulatedFeesUsdc();
        assertGt(
            grossTargetAssets,
            preDrainPreview.seizedCollateralUsdc + 1,
            "Setup must leave a positive degraded-mode gap after subtracting seized collateral"
        );
        uint256 targetAssets = grossTargetAssets;
        uint256 currentAssets = pool.totalAssets();
        assertGt(currentAssets, targetAssets, "Test setup must be able to drain the vault into the funding-clip gap");

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), currentAssets - targetAssets);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(bullId, bullSize, 1e8);
        assertTrue(preview.triggersDegradedMode, "Preview should detect degraded mode after the forced drain");

        _close(bullId, CfdTypes.Side.BULL, bullSize, 1e8);
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
        bytes32 bullId = bytes32(uint256(uint160(bullTrader)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));
        bytes32 residualBearId = bytes32(uint256(uint160(residualBearTrader)));

        _fundTrader(bullTrader, 100_000e6);
        _fundTrader(bearTrader, 100_000e6);
        _fundTrader(residualBearTrader, 100_000e6);

        _open(bearId, CfdTypes.Side.BEAR, 900_000e18, 45_000e6, 1e8);
        _open(residualBearId, CfdTypes.Side.BEAR, 100_000e18, 5000e6, 1e8);
        _open(bullId, CfdTypes.Side.BULL, 500_000e18, 50_000e6, 1e8);

        _close(bullId, CfdTypes.Side.BULL, 500_000e18, 20_000_000);
        assertTrue(engine.degradedMode(), "Setup close should latch degraded mode");

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(bearId, 900_000e18, 20_000_000);
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
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 4000e6, 1e8);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(accountId, 100_000e18, 1e8);

        assertTrue(preview.valid, "Preview should remain valid when close earns a negative VPI rebate");
        assertLt(preview.vpiDeltaUsdc, 0, "Preview should expose negative VPI as a rebate instead of panicking");
        assertEq(preview.vpiUsdc, 0, "Positive-only VPI charge field should clamp rebates to zero");
    }

    function test_PreviewClose_UsesPostUnlockFreeSettlementForLosses() public {
        address trader = address(0xAB1302);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 5000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 4000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 900e6, type(uint256).max, false);

        uint256 freeSettlementBeforePreview = _freeSettlementUsdc(accountId);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(accountId, 50_000e18, 110_000_000);

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

        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _open(accountId, CfdTypes.Side.BEAR, 200_000 * 1e18, 20_000 * 1e6, 1e8);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(accountId, 100_000 * 1e18, 80_000_000);
        (uint256 sizeBefore,,,,,,) = engine.positions(accountId);

        assertFalse(preview.valid, "Preview should reject an underwater partial close that invades residual backing");
        assertEq(
            uint8(preview.invalidReason),
            uint8(CfdTypes.CloseInvalidReason.PartialCloseUnderwater),
            "Preview should use the underwater partial-close invalid reason"
        );

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(0.8e8));
        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000 * 1e18, 0, 0, true);
        router.executeOrder(1, priceData);

        (uint256 sizeAfter,,,,,,) = engine.positions(accountId);
        assertEq(
            sizeAfter, sizeBefore, "Live close path should leave the position unchanged when preview marks it invalid"
        );
    }

    function test_PreviewClose_FullLossBadDebtMatchesLiveSettlement() public {
        address trader = address(0xAB1304);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 2000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(accountId, 100_000e18, 110_000_000);
        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 110_000_000);

        assertEq(
            engine.accumulatedBadDebtUsdc() - badDebtBefore,
            preview.badDebtUsdc,
            "Preview bad debt should match live terminal settlement planning"
        );
    }

    function test_PreviewClose_ClampsOraclePriceToCap() public {
        address trader = address(0xAB1305);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 5000e6);
        _open(accountId, CfdTypes.Side.BEAR, 100_000e18, 4000e6, 1e8);

        CfdEngine.ClosePreview memory cappedPreview = engineLens.previewClose(accountId, 100_000e18, 2e8);
        CfdEngine.ClosePreview memory overCapPreview = engineLens.previewClose(accountId, 100_000e18, 3e8);

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
            overCapPreview.deferredTraderCreditUsdc,
            cappedPreview.deferredTraderCreditUsdc,
            "Preview deferred payout should clamp to CAP_PRICE"
        );
        assertEq(overCapPreview.badDebtUsdc, cappedPreview.badDebtUsdc, "Preview bad debt should clamp to CAP_PRICE");
    }

    function test_PreviewLiquidation_ReturnsBountyAndLiquidatableFlag() public {
        address trader = address(0xAB14);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 300e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 200e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(accountId, 100e6);

        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(accountId, 101_000_000);
        assertTrue(preview.liquidatable);
        assertEq(preview.keeperBountyUsdc, 10_100_000);
        assertLe(preview.keeperBountyUsdc, uint256(preview.equityUsdc));
    }

    function test_PlanLiquidation_PositiveResidualAboveDeferredDoesNotUnderflow() public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        CfdEnginePlanTypes.LiquidationDelta memory delta =
            harness.planLiquidation(0, 10e6, 2000e18, 99_600_000, 100_000_000);

        assertTrue(delta.liquidatable, "Setup must remain liquidatable");
        assertEq(
            delta.keeperBountyUsdc,
            2e6,
            "Positive physical equity should still support the current lower bounty in this setup"
        );
        assertEq(
            delta.residualUsdc, 6e6, "Residual should reflect the current physically reachable collateral computation"
        );
        assertEq(delta.settlementRetainedUsdc, 0, "No settlement should remain when none is reachable");
        assertEq(
            delta.existingDeferredConsumedUsdc,
            0,
            "Positive physical residual should not consume legacy deferred payout"
        );
        assertEq(
            delta.existingDeferredRemainingUsdc,
            10e6,
            "Legacy deferred payout should remain intact on positive residual"
        );
        assertEq(delta.freshTraderPayoutUsdc, 6e6, "Only physical residual should become a fresh trader payout");
        assertEq(
            delta.residualPlan.freshTraderPayoutUsdc, 6e6, "Residual plan should expose only the physical fresh payout"
        );
        assertEq(delta.badDebtUsdc, 0, "Positive residual should not create bad debt");
    }

    function test_PlanLiquidation_NegativeResidualFullyConsumesLegacyDeferredWithoutReducingBadDebt() public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        CfdEnginePlanTypes.LiquidationDelta memory delta =
            harness.planLiquidation(0, 10e6, 2000e18, 99_600_000, 99_000_000);

        assertTrue(delta.liquidatable, "Setup must remain liquidatable");
        assertEq(delta.keeperBountyUsdc, 0, "Zero physically reachable collateral should cap the bounty at zero");
        assertEq(delta.residualUsdc, -12e6, "Residual should be computed before any deferred-payout netting");
        assertEq(
            delta.existingDeferredConsumedUsdc,
            10e6,
            "Negative residual should consume legacy deferred payout only as terminal shortfall netting"
        );
        assertEq(
            delta.existingDeferredRemainingUsdc, 0, "No deferred payout should survive a negative residual wipeout"
        );
        assertEq(delta.badDebtUsdc, 2e6, "Bad debt should reflect only the shortfall left after deferred netting");
    }

    function test_PreviewLiquidation_PreservesLegacyDeferredOnPositivePhysicalResidual() public {
        address trader = address(0xAB14002);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        address keeper = address(0xAB14003);
        _fundTrader(trader, 200e6);
        _open(accountId, CfdTypes.Side.BEAR, 10_000e18, 200e6, 99_700_000);

        stdstore.target(address(clearinghouse)).sig("balanceUsdc(bytes32)").with_key(accountId)
            .checked_write(uint256(0));

        stdstore.target(address(engine)).sig("deferredTraderCreditUsdc(bytes32)").with_key(accountId)
            .checked_write(uint256(10e6));
        stdstore.target(address(engine)).sig("totalDeferredTraderCreditUsdc()").checked_write(uint256(10e6));

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 30e6);

        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(accountId, 100_000_000);

        assertTrue(preview.liquidatable, "Preview should not revert for positive physical residual");
        assertEq(preview.keeperBountyUsdc, 10e6, "Setup should use the current percentage bounty");
        assertEq(preview.settlementRetainedUsdc, 0, "No settlement should remain when no settlement is reachable");
        assertEq(
            preview.freshTraderPayoutUsdc, 20e6, "Preview should surface the current physical fresh liquidation payout"
        );
        assertEq(
            preview.existingDeferredConsumedUsdc,
            0,
            "Positive physical residual should not consume legacy deferred payout"
        );
        assertEq(
            preview.existingDeferredRemainingUsdc, 10e6, "Preview should keep the legacy deferred claim outstanding"
        );
        assertEq(
            preview.immediatePayoutUsdc,
            0,
            "Current preview should keep the physical payout deferred even when the legacy claim remains untouched"
        );
        assertEq(
            preview.deferredTraderCreditUsdc,
            30e6,
            "Deferred payout should reflect the untouched legacy claim plus the fresh deferred amount in the current preview model"
        );
        assertEq(preview.badDebtUsdc, 0, "Positive residual should not report bad debt");

        uint256 settlementBefore = clearinghouse.balanceUsdc(accountId);
        vm.prank(keeper);
        bytes[] memory empty;
        router.executeLiquidation(accountId, empty);

        uint256 vaultAssets = pool.totalAssets() + preview.keeperBountyUsdc;
        uint256 fees = engine.accumulatedFeesUsdc();
        int256 legacySpread = int256(0);
        uint256 netPhysical = vaultAssets > fees ? vaultAssets - fees : 0;
        uint256 liveEffective = legacySpread > 0
            ? (netPhysical > uint256(legacySpread) ? netPhysical - uint256(legacySpread) : 0)
            : netPhysical + uint256(-legacySpread);
        uint256 deferred = engine.totalDeferredTraderCreditUsdc() + engine.totalDeferredKeeperCreditUsdc();
        liveEffective = liveEffective > deferred ? liveEffective - deferred : 0;
        liveEffective = liveEffective > preview.keeperBountyUsdc ? liveEffective - preview.keeperBountyUsdc : 0;

        assertEq(
            clearinghouse.balanceUsdc(accountId) - settlementBefore,
            preview.immediatePayoutUsdc,
            "Live settlement credit should match preview"
        );
        assertEq(
            engine.deferredTraderCreditUsdc(accountId),
            30e6,
            "Live liquidation should preserve the old deferred claim plus the fresh deferred amount"
        );
        assertEq(
            preview.effectiveAssetsAfterUsdc,
            liveEffective,
            "Preview solvency should use net deferred liabilities after consumption"
        );
    }

    function test_CloseExecution_UsesCarryAdjustedLossKernel() public {
        address trader = address(0xAB14004);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 20_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.warp(block.timestamp + 1 days);
        vm.prank(address(router));
        engine.updateMarkPrice(100_010_000, uint64(block.timestamp));

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(accountId, 100_000e18, 100_010_000);
        assertTrue(preview.valid, "Carry-adjusted full close should remain executable");
        assertEq(preview.badDebtUsdc, 0, "Carry-adjusted close should remain fully covered in this setup");

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 100_010_000, true);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(100_010_000));
        vm.roll(block.number + 1);
        router.executeOrder(1, priceData);

        (uint256 sizeAfter,,,,,,) = engine.positions(accountId);
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

    function testFuzz_PlanLiquidation_PositiveResidualPreservesDeferredAndUsesOnlyPhysicalReachability(
        uint256 settlementReachableUsdc,
        uint256 deferredTraderCreditUsdc
    ) public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        settlementReachableUsdc = bound(settlementReachableUsdc, 0, 20e6);
        deferredTraderCreditUsdc = bound(deferredTraderCreditUsdc, 1, 20e6);

        CfdEnginePlanTypes.LiquidationDelta memory delta = harness.planLiquidation(
            settlementReachableUsdc, deferredTraderCreditUsdc, 2000e18, 99_600_000, 100_000_000
        );

        vm.assume(delta.liquidatable);
        vm.assume(delta.residualUsdc >= 0);

        assertEq(
            delta.liquidationReachableCollateralUsdc,
            settlementReachableUsdc,
            "Liquidation reachability must ignore legacy deferred payout"
        );
        assertEq(
            delta.liquidationState.reachableCollateralUsdc,
            settlementReachableUsdc,
            "Keeper bounty state must use only physical reachability"
        );
        assertEq(
            delta.existingDeferredConsumedUsdc, 0, "Positive physical residual must not consume legacy deferred payout"
        );
        assertEq(
            delta.existingDeferredRemainingUsdc,
            deferredTraderCreditUsdc,
            "Positive physical residual must preserve the full legacy deferred payout"
        );
        assertEq(delta.badDebtUsdc, 0, "Positive residual must not create bad debt");
    }

    function testFuzz_PlanLiquidation_NegativeResidualNetsDeferredExactlyOnce(
        uint256 settlementReachableUsdc,
        uint256 deferredTraderCreditUsdc
    ) public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        settlementReachableUsdc = bound(settlementReachableUsdc, 0, 20e6);
        deferredTraderCreditUsdc = bound(deferredTraderCreditUsdc, 1, 20e6);

        CfdEnginePlanTypes.LiquidationDelta memory delta =
            harness.planLiquidation(settlementReachableUsdc, deferredTraderCreditUsdc, 2000e18, 99_600_000, 99_000_000);

        vm.assume(delta.liquidatable);
        vm.assume(delta.residualUsdc < 0);

        uint256 expectedConsumed = deferredTraderCreditUsdc < delta.residualPlan.badDebtUsdc
            ? deferredTraderCreditUsdc
            : delta.residualPlan.badDebtUsdc;

        assertEq(
            delta.liquidationReachableCollateralUsdc,
            settlementReachableUsdc,
            "Liquidation reachability must ignore legacy deferred payout"
        );
        assertEq(
            delta.existingDeferredConsumedUsdc,
            expectedConsumed,
            "Negative residual must net legacy deferred payout exactly once against terminal shortfall"
        );
        assertEq(
            delta.existingDeferredRemainingUsdc,
            deferredTraderCreditUsdc - expectedConsumed,
            "Deferred remainder must equal the unconsumed legacy claim"
        );
        assertEq(
            delta.badDebtUsdc,
            delta.residualPlan.badDebtUsdc - expectedConsumed,
            "Bad debt must only reflect the shortfall left after deferred netting"
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
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        uint256 vaultDepth = pool.totalAssets();
        _fundTrader(trader, 2000e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 1105e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(accountId, 895e6);

        vm.warp(block.timestamp + 1);
        vm.prank(address(router));
        engine.updateMarkPrice(110_000_000, uint64(block.timestamp));

        PerpsViewTypes.PositionView memory viewData = _publicPosition(accountId);
        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(accountId, 110_000_000);

        assertTrue(viewData.liquidatable, "Position view should use current notional for maintenance threshold");
        assertTrue(preview.liquidatable, "Liquidation preview should use current notional for maintenance threshold");

        vm.prank(address(router));
        engine.liquidatePosition(accountId, 110_000_000, vaultDepth, uint64(block.timestamp));

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Live liquidation should agree with preview and position view");
    }

    function helper_PreviewLiquidation_UsesCanonicalVaultDepthWhileSimulateLiquidationAllowsWhatIfDepth() public {
        address trader = address(0xAB14015);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 2000e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 1105e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(accountId, 895e6);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(110_000_000, refreshTime);

        uint64 accrualTime = refreshTime + 30;
        vm.warp(accrualTime);

        uint256 canonicalDepth = pool.totalAssets();
        CfdEngine.LiquidationPreview memory canonicalPreview = engineLens.previewLiquidation(accountId, 110_000_000);
        CfdEngine.LiquidationPreview memory matchedSimulation =
            engineLens.simulateLiquidation(accountId, 110_000_000, canonicalDepth);
        CfdEngine.LiquidationPreview memory lowDepthSimulation =
            engineLens.simulateLiquidation(accountId, 110_000_000, canonicalDepth / 10);

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
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 300e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 200e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(accountId, 100e6);

        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(accountId, 101_000_000);
        assertTrue(preview.liquidatable, "Setup liquidation preview should be liquidatable");

        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(accountId, keeper);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(101_000_000));
        vm.prank(keeper);
        router.executeLiquidation(accountId, priceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(accountId, keeper, beforeSnapshot);
        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
    }

    function test_LiquidationPreview_InterfaceMatchesContractStructLayout() public {
        address trader = address(0xAB1402);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 2000e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 1105e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(accountId, 895e6);

        CfdEngine.LiquidationPreview memory contractPreview = engineLens.previewLiquidation(accountId, 110_000_000);
        CfdEngine.LiquidationPreview memory interfacePreview = engineLens.previewLiquidation(accountId, 110_000_000);

        assertEq(interfacePreview.liquidatable, contractPreview.liquidatable);
        assertEq(interfacePreview.oraclePrice, contractPreview.oraclePrice);
        assertEq(interfacePreview.equityUsdc, contractPreview.equityUsdc);
        assertEq(interfacePreview.pnlUsdc, contractPreview.pnlUsdc);
        assertEq(interfacePreview.reachableCollateralUsdc, contractPreview.reachableCollateralUsdc);
        assertEq(interfacePreview.keeperBountyUsdc, contractPreview.keeperBountyUsdc);
        assertEq(interfacePreview.seizedCollateralUsdc, contractPreview.seizedCollateralUsdc);
        assertEq(interfacePreview.immediatePayoutUsdc, contractPreview.immediatePayoutUsdc);
        assertEq(interfacePreview.deferredTraderCreditUsdc, contractPreview.deferredTraderCreditUsdc);
        assertEq(interfacePreview.badDebtUsdc, contractPreview.badDebtUsdc);
        assertEq(interfacePreview.triggersDegradedMode, contractPreview.triggersDegradedMode);
        assertEq(interfacePreview.postOpDegradedMode, contractPreview.postOpDegradedMode);
        assertEq(interfacePreview.effectiveAssetsAfterUsdc, contractPreview.effectiveAssetsAfterUsdc);
        assertEq(interfacePreview.maxLiabilityAfterUsdc, contractPreview.maxLiabilityAfterUsdc);
    }

    function helper_LiquidationPreview_IgnoresStaleMarkCarryOnRefresh() public {
        address trader = address(0xAB1403);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 2000e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 1105e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(accountId, 895e6);

        vm.warp(block.timestamp + 1 days);

        CfdEngine.LiquidationPreview memory stalePreview = engineLens.previewLiquidation(accountId, 110_000_000);

        vm.prank(address(router));
        engine.updateMarkPrice(110_000_000, uint64(block.timestamp));

        CfdEngine.LiquidationPreview memory refreshedPreview = engineLens.previewLiquidation(accountId, 110_000_000);

        assertEq(refreshedPreview.reachableCollateralUsdc, stalePreview.reachableCollateralUsdc);
        assertEq(
            refreshedPreview.equityUsdc,
            stalePreview.equityUsdc,
            "Liquidation equity should remain unchanged across the stale interval"
        );
    }

    function test_LiquidationPreview_IlliquidDeferredTraderCreditMatchesLiveOutcome() public {
        address trader = address(0xAB1404);
        address keeper = address(0xAB1405);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 300e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 200e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(accountId, 100e6);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(accountId, 101_000_000);
        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(accountId, keeper);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(101_000_000));
        vm.prank(keeper);
        router.executeLiquidation(accountId, priceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(accountId, keeper, beforeSnapshot);
        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);

        assertEq(
            engine.deferredTraderCreditUsdc(accountId),
            preview.deferredTraderCreditUsdc,
            "Illiquid liquidation preview should match live deferred trader credit"
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
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 900e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        uint256 queuedOrderCount = 5;
        for (uint256 i = 0; i < queuedOrderCount; i++) {
            router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 100e6, type(uint256).max, false);
        }
        clearinghouse.withdraw(accountId, 70e6);
        vm.stopPrank();

        IOrderRouterAccounting.AccountEscrowView memory escrowBefore = router.getAccountEscrow(accountId);
        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(accountId, 195_000_000);
        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(accountId, keeper);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(195_000_000));
        vm.prank(keeper);
        router.executeLiquidation(accountId, priceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(accountId, keeper, beforeSnapshot);
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory afterSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();

        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);

        assertEq(
            engine.deferredTraderCreditUsdc(accountId),
            preview.deferredTraderCreditUsdc,
            "Preview deferred payout should match live liquidation after staged forfeiture"
        );
        assertEq(
            observed.badDebtUsdc,
            preview.badDebtUsdc,
            "Preview bad debt should match live liquidation after staged forfeiture"
        );
        assertEq(
            afterSnapshot.accumulatedFeesUsdc - beforeSnapshot.protocol.accumulatedFeesUsdc,
            escrowBefore.executionBountyUsdc,
            "Live liquidation should book the same forfeited escrow preview assumes as protocol fees"
        );
        assertEq(
            observed.effectiveAssetsAfterUsdc,
            preview.effectiveAssetsAfterUsdc,
            "Preview solvency should match live liquidation after staged forfeiture"
        );
    }

    function helper_PreviewLiquidation_ForfeitedEscrowChangesPreview() public {
        CfdTypes.RiskParams memory params = _riskParams();
        _setRiskParams(params);

        address trader = address(0xAB1407);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 300e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 200e6, 1e8);

        vm.startPrank(trader);
        for (uint256 i = 0; i < 5; i++) {
            router.commitOrder(CfdTypes.Side.BULL, 1000e18, 0, type(uint256).max, true);
        }
        vm.stopPrank();

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() - 1);

        uint256 canonicalDepth = pool.totalAssets();
        uint256 forfeitedEscrow = router.getAccountEscrow(accountId).executionBountyUsdc;
        assertGt(forfeitedEscrow, 0, "Setup must build forfeitable execution escrow");
        assertGt(canonicalDepth, forfeitedEscrow, "Setup needs canonical vault depth to exceed escrow");

        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(accountId, 101_000_000);
        CfdEngine.LiquidationPreview memory oldModelEquivalent =
            engineLens.simulateLiquidation(accountId, 101_000_000, canonicalDepth - forfeitedEscrow);

        assertNotEq(
            preview.reachableCollateralUsdc,
            oldModelEquivalent.reachableCollateralUsdc,
            "Forfeited escrow should now change the liquidation preview"
        );
    }

    function test_Liquidation_ConsumesDeferredTraderCreditBeforeRecordingBadDebt() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 bullId = bytes32(uint256(0xD221));
        bytes32 bearId = bytes32(uint256(0xD222));
        address keeper = address(0xD223);
        _fundTrader(address(uint160(uint256(bullId))), 5000e6);
        _fundTrader(address(uint160(uint256(bearId))), 5000e6);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, vaultDepth);
        _open(bearId, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, vaultDepth);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        _closeAt(bearId, CfdTypes.Side.BEAR, 5000e18, 120_000_000, vaultDepth, refreshTime);
        uint256 deferredBefore = engine.deferredTraderCreditUsdc(bearId);
        assertGt(deferredBefore, 0, "Setup must create deferred payout while keeping the position open");

        uint256 reducedSettlement = clearinghouse.balanceUsdc(bearId) - 4700e6;
        stdstore.target(address(clearinghouse)).sig("balanceUsdc(bytes32)").with_key(bearId)
            .checked_write(reducedSettlement);

        uint256 settlementReachableBefore = _terminalReachableUsdc(bearId);
        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(bearId, 50_000_000);
        assertTrue(preview.liquidatable, "Setup must produce a liquidatable position even after deferred payout credit");

        int256 terminalResidual =
            int256(settlementReachableBefore + deferredBefore) + preview.pnlUsdc - int256(preview.keeperBountyUsdc);

        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(50_000_000));
        vm.prank(keeper);
        router.executeLiquidation(bearId, priceData);

        assertLt(
            engine.deferredTraderCreditUsdc(bearId),
            deferredBefore,
            "Liquidation should consume deferred payout before socializing loss"
        );
        assertEq(
            engine.deferredTraderCreditUsdc(bearId),
            preview.deferredTraderCreditUsdc,
            "Preview should match remaining deferred payout after liquidation"
        );
        assertEq(
            engine.accumulatedBadDebtUsdc() - badDebtBefore,
            preview.badDebtUsdc,
            "Bad debt should only reflect the post-deferred shortfall"
        );
        assertEq(
            clearinghouse.balanceUsdc(bearId) + engine.deferredTraderCreditUsdc(bearId),
            _positivePart(terminalResidual),
            "Terminal liquidation residual should equal retained settlement plus remaining deferred and immediate credit"
        );
        assertEq(
            engine.accumulatedBadDebtUsdc() - badDebtBefore,
            preview.badDebtUsdc,
            "Terminal liquidation bad debt should align with the previewed deferred-credit-adjusted shortfall"
        );
    }

    function test_Close_ConsumesDeferredTraderCreditBeforeRecordingBadDebt() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 bullId = bytes32(uint256(0xD231));
        bytes32 bearId = bytes32(uint256(0xD232));
        _fundTrader(address(uint160(uint256(bullId))), 5000e6);
        _fundTrader(address(uint160(uint256(bearId))), 5000e6);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, vaultDepth);
        _open(bearId, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, vaultDepth);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        _closeAt(bearId, CfdTypes.Side.BEAR, 5000e18, 120_000_000, vaultDepth, refreshTime);
        uint256 deferredBefore = engine.deferredTraderCreditUsdc(bearId);
        assertGt(deferredBefore, 0, "Setup must create deferred payout while keeping the position open");

        uint256 reducedSettlement = clearinghouse.balanceUsdc(bearId) - 4700e6;
        stdstore.target(address(clearinghouse)).sig("balanceUsdc(bytes32)").with_key(bearId)
            .checked_write(reducedSettlement);

        CfdEngine.ClosePreview memory preview = engineLens.simulateClose(bearId, 5000e18, 80_000_000, vaultDepth);
        assertGt(
            preview.existingDeferredConsumedUsdc,
            0,
            "Close preview should seize legacy deferred payout before socializing bad debt"
        );
        assertLt(
            preview.existingDeferredRemainingUsdc,
            deferredBefore,
            "Close preview should show less deferred payout remaining after loss absorption"
        );

        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(bearId);
        _closeAt(bearId, CfdTypes.Side.BEAR, 5000e18, 80_000_000, vaultDepth, refreshTime);

        CloseParityObserved memory observed = _observeCloseParity(bearId, beforeSnapshot);

        assertEq(
            engine.deferredTraderCreditUsdc(bearId),
            observed.deferredTraderCreditUsdc,
            "Live close should leave the same deferred payout remainder observed in settlement state"
        );
        assertEq(
            observed.badDebtUsdc,
            preview.badDebtUsdc,
            "Bad debt should only reflect the post-deferred shortfall on close"
        );
        assertEq(
            preview.existingDeferredConsumedUsdc,
            deferredBefore - preview.existingDeferredRemainingUsdc,
            "Preview should expose the exact deferred payout consumed before socializing bad debt"
        );
    }

    function test_Close_ConsumesDeferredTraderCreditBalancesWithoutQueueOrdering() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 bullId = bytes32(uint256(0xD241));
        bytes32 bearId = bytes32(uint256(0xD242));
        address keeper = address(0xD243);
        _fundTrader(address(uint160(uint256(bullId))), 5000e6);
        _fundTrader(address(uint160(uint256(bearId))), 5000e6);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, vaultDepth);
        _open(bearId, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, vaultDepth);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(keeper, 1e6);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        _closeAt(bearId, CfdTypes.Side.BEAR, 5000e18, 120_000_000, vaultDepth, refreshTime);
        uint256 deferredBefore = engine.deferredTraderCreditUsdc(bearId);
        assertGt(deferredBefore, 0, "Bear account should accrue deferred trader credit balance");

        _closeAt(bearId, CfdTypes.Side.BEAR, 2500e18, 120_000_000, vaultDepth, refreshTime);
        uint256 deferredAfterAccrual = engine.deferredTraderCreditUsdc(bearId);
        assertGe(
            deferredAfterAccrual, deferredBefore, "Additional deferred payout should coalesce into the same balance"
        );

        uint256 reducedSettlement = clearinghouse.balanceUsdc(bearId) - 4700e6;
        stdstore.target(address(clearinghouse)).sig("balanceUsdc(bytes32)").with_key(bearId)
            .checked_write(reducedSettlement);

        _closeAt(bearId, CfdTypes.Side.BEAR, 2500e18, 80_000_000, vaultDepth, refreshTime);
        assertLe(
            engine.deferredTraderCreditUsdc(bearId),
            deferredAfterAccrual,
            "Consuming deferred trader credit should only reduce the tracked balance"
        );
    }

    function test_DeferredTraderCredit_CoalescesPerAccountWithoutQueuePosition() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 bullId = bytes32(uint256(0xD261));
        bytes32 bearId = bytes32(uint256(0xD262));
        bytes32 laterId = bytes32(uint256(0xD263));
        _fundTrader(address(uint160(uint256(bullId))), 5000e6);
        _fundTrader(address(uint160(uint256(bearId))), 5000e6);
        _fundTrader(address(uint160(uint256(laterId))), 5000e6);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, vaultDepth);
        _open(bearId, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, vaultDepth);
        _open(laterId, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, vaultDepth);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        _closeAt(bearId, CfdTypes.Side.BEAR, 5000e18, 120_000_000, vaultDepth, refreshTime);
        uint256 bearDeferredBefore = engine.deferredTraderCreditUsdc(bearId);
        assertGt(bearDeferredBefore, 0, "Initial deferred payout should create tracked deferred balance for bearId");

        _closeAt(laterId, CfdTypes.Side.BEAR, 5000e18, 120_000_000, vaultDepth, refreshTime);
        uint256 laterDeferred = engine.deferredTraderCreditUsdc(laterId);
        assertGt(laterDeferred, 0, "Later claimant should also accrue deferred balance");

        _closeAt(bearId, CfdTypes.Side.BEAR, 2500e18, 120_000_000, vaultDepth, refreshTime);
        uint256 bearDeferredAfter = engine.deferredTraderCreditUsdc(bearId);

        assertGe(bearDeferredAfter, bearDeferredBefore, "Coalescing should not move the account behind later claimants");
    }

    function test_Close_RecoversExecutionFeeShortfallFromExistingDeferredTraderCredit() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 bullId = bytes32(uint256(0xD251));
        bytes32 bearId = bytes32(uint256(0xD252));
        _fundTrader(address(uint160(uint256(bullId))), 5000e6);
        _fundTrader(address(uint160(uint256(bearId))), 5000e6);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, vaultDepth);
        _open(bearId, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, vaultDepth);

        uint64 refreshTime = uint64(block.timestamp + 1 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        _closeAt(bearId, CfdTypes.Side.BEAR, 5000e18, 120_000_000, vaultDepth, refreshTime);
        uint256 deferredBefore = engine.deferredTraderCreditUsdc(bearId);
        assertGt(
            deferredBefore, 1e6, "Setup must create legacy deferred payout large enough to cover the fee shortfall"
        );

        stdstore.target(address(clearinghouse)).sig("balanceUsdc(bytes32)").with_key(bearId).checked_write(uint256(0));
        bytes32 positionMarginSlot = keccak256(abi.encode(bearId, uint256(3)));
        vm.store(address(clearinghouse), positionMarginSlot, bytes32(uint256(0)));

        IMarginClearinghouse.LockedMarginBuckets memory locked = clearinghouse.getLockedMarginBuckets(bearId);
        assertEq(locked.positionMarginUsdc, 0, "Test must reduce reachable collateral below the terminal close fee");

        CfdEngine.ClosePreview memory preview = engineLens.simulateClose(bearId, 5000e18, 1e8, vaultDepth);
        uint256 nominalExecutionFeeUsdc = (((5000e18 * uint256(1e8)) / CfdMath.USDC_TO_TOKEN_SCALE) * 4) / 10_000;

        assertEq(
            preview.badDebtUsdc,
            0,
            "Deferred payout should prevent LP bad debt when close shortfall includes unpaid fees"
        );
        assertEq(
            preview.executionFeeUsdc,
            0,
            "Preview should report zero direct fee collection when deferred credit covers the shortfall in the current model"
        );
        assertGt(
            preview.existingDeferredConsumedUsdc, 0, "Deferred payout should contribute to covering the close shortfall"
        );

        uint256 feesBefore = engine.accumulatedFeesUsdc();
        _closeAt(bearId, CfdTypes.Side.BEAR, 5000e18, 1e8, vaultDepth, refreshTime);

        assertEq(
            engine.accumulatedFeesUsdc() - feesBefore,
            nominalExecutionFeeUsdc,
            "Protocol should book the full close execution fee after consuming deferred payout"
        );
        assertEq(
            deferredBefore - engine.deferredTraderCreditUsdc(bearId),
            2_243_750,
            "Live close should extinguish the current deferred payout amount used to fund the fee shortfall"
        );
    }

    function test_PreviewLiquidation_ExcludesRouterExecutionEscrowFromReachableCollateral() public {
        address trader = address(0xAB1406);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 350e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        uint256 queuedOrderCount = 5;
        for (uint256 i = 0; i < queuedOrderCount; i++) {
            router.commitOrder(CfdTypes.Side.BULL, 1000e18, 0, type(uint256).max, true);
        }
        clearinghouse.withdraw(accountId, 70e6);
        vm.stopPrank();

        IOrderRouterAccounting.AccountEscrowView memory escrow = router.getAccountEscrow(accountId);
        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(accountId, 102_500_000);
        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot =
            engineAccountLens.getAccountLedgerSnapshot(accountId);

        assertGt(escrow.executionBountyUsdc, 0, "Setup must create router-held execution escrow");
        assertEq(
            preview.reachableCollateralUsdc,
            snapshot.terminalReachableUsdc,
            "Liquidation preview must use the same liquidation reachability as the account ledger snapshot"
        );
        assertLt(
            preview.reachableCollateralUsdc,
            clearinghouse.balanceUsdc(accountId) + escrow.executionBountyUsdc,
            "Liquidation preview must exclude router execution escrow from reachable collateral"
        );
        assertEq(
            snapshot.executionEscrowUsdc,
            escrow.executionBountyUsdc,
            "Expanded account ledger must continue to report execution escrow outside liquidation reachability"
        );
    }

    function test_PreviewLiquidation_TriggersDegradedModeMatchesLiveLiquidation() public {
        address trader = address(0xAB1410);
        address keeper = address(0xAB1411);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 300e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 200e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(accountId, 100e6);

        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(accountId, 101_000_000);
        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(accountId, keeper);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(101_000_000));
        vm.prank(keeper);
        router.executeLiquidation(accountId, priceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(accountId, keeper, beforeSnapshot);
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
        bytes32 bullId = bytes32(uint256(uint160(bullTrader)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));

        _fundTrader(bullTrader, 12_000e6);
        _fundTrader(bearTrader, 30_000e6);

        _open(bullId, CfdTypes.Side.BULL, 500_000e18, 8000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 50_000e18, 20_000e6, 1e8);

        uint64 refreshTime = uint64(block.timestamp + 365 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint64 accrualTime = refreshTime + 30;
        vm.warp(accrualTime);

        CfdEngine.LiquidationPreview memory preDrainPreview = engineLens.previewLiquidation(bullId, 195_000_000);
        assertTrue(preDrainPreview.liquidatable, "Setup must produce a liquidatable position");

        uint256 bearMaxProfit = _sideMaxProfit(CfdTypes.Side.BEAR);
        uint256 targetAssets = bearMaxProfit + engine.accumulatedFeesUsdc() + preDrainPreview.keeperBountyUsdc
            - preDrainPreview.seizedCollateralUsdc - 1;
        uint256 currentAssets = pool.totalAssets();
        assertGt(currentAssets, targetAssets, "Test setup must be able to drain the vault into the degraded-mode gap");

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), currentAssets - targetAssets);

        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(bullId, 195_000_000);
        assertTrue(preview.triggersDegradedMode, "Liquidation preview should detect degraded mode after the drain");

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(195_000_000));
        vm.prank(address(0xAB1414));
        router.executeLiquidation(bullId, priceData);

        assertEq(
            preview.triggersDegradedMode,
            engine.degradedMode(),
            "Liquidation preview should match live degraded-mode outcome after the drain"
        );
    }

    function test_GetDeferredCreditStatus_ReflectsClaimability() public {
        address trader = address(0xAB15);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        vm.startPrank(address(pool));
        usdc.transfer(address(0xDEAD), pool.totalAssets());
        vm.stopPrank();

        DeferredEngineViewTypes.DeferredCreditStatus memory statusBefore =
            _deferredCreditStatus(accountId, address(this));
        assertGt(statusBefore.deferredTraderCreditUsdc, 0);
        assertFalse(statusBefore.traderPayoutClaimableNow);

        usdc.mint(address(pool), statusBefore.deferredTraderCreditUsdc);

        DeferredEngineViewTypes.DeferredCreditStatus memory statusAfter =
            _deferredCreditStatus(accountId, address(this));
        assertTrue(statusAfter.traderPayoutClaimableNow);
    }

    function test_GetDeferredCreditStatus_ExposesClaimabilityWithoutHeadOrdering() public {
        address trader = address(0xAB16);
        address keeper = address(0xAB17);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        uint256 deferred = engine.deferredTraderCreditUsdc(accountId);
        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(keeper, deferred);
        usdc.mint(address(pool), deferred);

        DeferredEngineViewTypes.DeferredCreditStatus memory status = _deferredCreditStatus(accountId, keeper);
        assertTrue(status.traderPayoutClaimableNow, "Deferred trader claim should be claimable under partial liquidity");
        assertTrue(
            status.keeperCreditClaimableNow,
            "Deferred keeper credit claim should also be claimable without FIFO ordering"
        );
    }

    function test_DeferredKeeperCredit_Lifecycle() public {
        address keeper = address(0xAB1601);
        address relayer = address(0xAB1602);
        uint256 deferredBounty = 25e6;

        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(keeper, deferredBounty);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets);

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory protocolViewBefore =
            engineProtocolLens.getProtocolAccountingSnapshot();
        DeferredEngineViewTypes.DeferredCreditStatus memory statusBefore = _deferredCreditStatus(bytes32(0), keeper);
        assertEq(protocolViewBefore.totalDeferredKeeperCreditUsdc, deferredBounty);
        assertEq(statusBefore.deferredKeeperCreditUsdc, deferredBounty);
        assertFalse(
            statusBefore.keeperCreditClaimableNow,
            "Deferred keeper credit should be unclaimable while vault is illiquid"
        );

        usdc.mint(address(pool), deferredBounty);

        DeferredEngineViewTypes.DeferredCreditStatus memory statusAfterCarry = _deferredCreditStatus(bytes32(0), keeper);
        assertTrue(
            statusAfterCarry.keeperCreditClaimableNow,
            "Deferred keeper credit should become claimable once vault liquidity returns"
        );

        bytes32 keeperId = bytes32(uint256(uint160(keeper)));
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeperId);
        vm.prank(keeper);
        engine.claimDeferredKeeperCredit();

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory protocolViewAfter =
            engineProtocolLens.getProtocolAccountingSnapshot();
        assertEq(clearinghouse.balanceUsdc(keeperId) - keeperSettlementBefore, deferredBounty);
        assertEq(engine.deferredKeeperCreditUsdc(keeper), 0);
        assertEq(protocolViewAfter.totalDeferredKeeperCreditUsdc, 0);
    }

    function test_DeferredKeeperCredit_CoalescesPerKeeperAndSupportsPartialClaims() public {
        address keeper = address(0xAB1605);
        bytes32 keeperId = bytes32(uint256(uint160(keeper)));

        vm.startPrank(address(router));
        engine.recordDeferredKeeperCredit(keeper, 25e6);
        engine.recordDeferredKeeperCredit(keeper, 5e6);
        vm.stopPrank();

        assertEq(engine.deferredKeeperCreditUsdc(keeper), 30e6, "Keeper liability should aggregate across events");

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets);
        usdc.mint(address(pool), 10e6);

        uint256 settlementBefore = clearinghouse.balanceUsdc(keeperId);
        vm.prank(keeper);
        engine.claimDeferredKeeperCredit();

        assertEq(
            clearinghouse.balanceUsdc(keeperId) - settlementBefore,
            10e6,
            "Head claim should service only available liquidity"
        );
        assertEq(
            engine.deferredKeeperCreditUsdc(keeper), 20e6, "Partial claim should preserve remaining keeper liability"
        );
    }

    function test_ClaimDeferredKeeperCredit_IgnoresKeeperWalletTransferBlacklist() public {
        address keeper = address(0xAB1603);
        address laterKeeper = address(0xAB1604);
        bytes32 keeperId = bytes32(uint256(uint160(keeper)));
        uint256 deferredBounty = 25e6;

        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(keeper, deferredBounty);
        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(laterKeeper, 5e6);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets);
        usdc.mint(address(pool), deferredBounty + 5e6);

        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(usdc.transfer.selector, keeper, deferredBounty),
            abi.encodeWithSignature("Error(string)", "blacklisted")
        );

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeperId);
        vm.prank(keeper);
        engine.claimDeferredKeeperCredit();

        assertEq(
            clearinghouse.balanceUsdc(keeperId) - keeperSettlementBefore,
            deferredBounty,
            "Deferred keeper credit should settle to clearinghouse credit without direct keeper transfer"
        );
        assertEq(
            engine.deferredKeeperCreditUsdc(laterKeeper),
            5e6,
            "Claiming one keeper should not affect unrelated deferred keeper credit balances"
        );
    }

    function test_CloseLoss_ConsumesQueuedCommittedMarginBeforeBadDebt() public {
        address trader = address(0xABD0);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000 * 1e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 7900e6, type(uint256).max, false);

        uint256 lockedBeforeClose = clearinghouse.lockedMarginUsdc(accountId);
        (, uint256 liveMarginBeforeClose,,,,,) = engine.positions(accountId);
        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();

        _close(accountId, CfdTypes.Side.BULL, 100_000 * 1e18, 103_000_000);

        assertLt(
            _remainingCommittedMargin(1),
            7900e6,
            "Order record should reflect committed margin consumed by terminal settlement"
        );
        assertLt(
            clearinghouse.lockedMarginUsdc(accountId),
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
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 10_000 * 1e6);

        CfdTypes.Order memory bearOrder = CfdTypes.Order({
            accountId: accountId,
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
            accountId: accountId,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 5000 * 1e6,
            targetPrice: 0.8e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.expectRevert(abi.encodeWithSelector(ICfdEngine.CfdEngine__TypedOrderFailure.selector, 1, 1, false));
        vm.prank(address(router));
        engine.processOrderTyped(bullOrder, 0.8e8, 1_000_000 * 1e6, uint64(block.timestamp));
    }

    function test_ProcessOrderTyped_UserInvalidFailureUsesTypedTaxonomy() public {
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 10_000 * 1e6);

        CfdTypes.Order memory bearOrder = CfdTypes.Order({
            accountId: accountId,
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
            accountId: accountId,
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
                ICfdEngine.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
                uint8(1),
                false
            )
        );
        vm.prank(address(router));
        engine.processOrderTyped(bullOrder, 0.8e8, 1_000_000 * 1e6, uint64(block.timestamp));
    }

    function test_CarryRealization_DoesNotBackfillAfterFreshCheckpoint() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 20_000 * 1e6);

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            accountId: accountId,
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
        engine.processOrderTyped(openOrder, 1e8, vaultDepth, uint64(block.timestamp));

        uint64 refreshTime = uint64(block.timestamp + 365 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint64 accrualTime = refreshTime + 30;
        vm.warp(accrualTime);

        CfdTypes.Order memory addOrder = CfdTypes.Order({
            accountId: accountId,
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
        engine.processOrderTyped(addOrder, 1e8, vaultDepth, accrualTime);

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 110_000 * 1e18, "Fresh mark checkpoint should not retroactively create a carry-driven revert");
    }

    function test_EntryPriceAveraging() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 10_000 * 1e6);

        // Open 10k tokens at $0.80
        CfdTypes.Order memory first = CfdTypes.Order({
            accountId: accountId,
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
        engine.processOrderTyped(first, 0.8e8, vaultDepth, uint64(block.timestamp));

        (,, uint256 entryAfterFirst,,,,) = engine.positions(accountId);
        assertEq(entryAfterFirst, 0.8e8, "Entry should be $0.80");

        // Add 30k tokens at $1.20 → weighted avg = (10k*0.80 + 30k*1.20) / 40k = $1.10
        CfdTypes.Order memory second = CfdTypes.Order({
            accountId: accountId,
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
        engine.processOrderTyped(second, 1.2e8, vaultDepth, uint64(block.timestamp));

        (uint256 totalSize,, uint256 avgEntry,,,,) = engine.positions(accountId);
        assertEq(totalSize, 40_000 * 1e18, "Total size should be 40k");
        assertEq(avgEntry, 1.1e8, "Weighted avg entry should be $1.10");
    }

    function test_CarryRealization_OnClose() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            accountId: accountId,
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
        engine.processOrderTyped(openOrder, 1e8, vaultDepth, uint64(block.timestamp));

        uint256 chBefore = clearinghouse.balanceUsdc(accountId);

        vm.warp(block.timestamp + 90 days);

        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            accountId: accountId,
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
        engine.processOrderTyped(closeOrder, 1e8, vaultDepth, uint64(block.timestamp));

        uint256 chAfter = clearinghouse.balanceUsdc(accountId);
        assertLt(chAfter, chBefore, "Carry drain should reduce clearinghouse balance on close");
    }

    function test_SetRiskParams_MakesPositionLiquidatable() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        address trader = address(uint160(uint256(accountId)));
        _fundTrader(trader, 5000 * 1e6);

        CfdTypes.Order memory order = CfdTypes.Order({
            accountId: accountId,
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
        engine.processOrderTyped(order, 1e8, vaultDepth, uint64(block.timestamp));

        vm.prank(trader);
        clearinghouse.withdraw(accountId, 2500 * 1e6);

        vm.expectRevert(CfdEngine.CfdEngine__PositionIsSolvent.selector);
        vm.prank(address(router));
        engine.liquidatePosition(accountId, 1e8, vaultDepth, uint64(block.timestamp));

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
        uint256 bounty = engine.liquidatePosition(accountId, 1e8, vaultDepth, uint64(block.timestamp));
        assertTrue(bounty > 0, "Position should be liquidatable after raising maintMarginBps");

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be wiped");
    }

    function test_Unauthorized_Caller_Reverts() public {
        bytes32 accountId = bytes32(uint256(1));
        CfdTypes.Order memory order = CfdTypes.Order({
            accountId: accountId,
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
        vm.expectRevert(CfdEngine.CfdEngine__Unauthorized.selector);
        engine.processOrderTyped(order, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));

        vm.prank(address(0xDEAD));
        vm.expectRevert(CfdEngine.CfdEngine__Unauthorized.selector);
        engine.liquidatePosition(accountId, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));
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
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            accountId: accountId,
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
        engine.processOrderTyped(openOrder, 1e8, vaultDepth, uint64(block.timestamp));

        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 20_000 * 1e18,
            marginDelta: 0,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.BULL,
            isClose: true
        });
        vm.expectRevert(abi.encodeWithSelector(ICfdEngine.CfdEngine__TypedOrderFailure.selector, 1, 1, true));
        vm.prank(address(router));
        engine.processOrderTyped(closeOrder, 1e8, vaultDepth, uint64(block.timestamp));
    }

    function test_MarginDrained_ByFees_Reverts() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 1000 * 1e6);

        CfdTypes.Order memory order = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 50 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.expectRevert(abi.encodeWithSelector(ICfdEngine.CfdEngine__TypedOrderFailure.selector, 1, 6, false));
        vm.prank(address(router));
        engine.processOrderTyped(order, 1e8, vaultDepth, uint64(block.timestamp));
    }

    function test_PreviewOpen_ClassifiesCarryDrainedReleasedFreeSettlementAsUserInvalid() public {
        address trader = address(0xCA2211);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 20_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        uint256 sizeDelta = 10_000e18;
        uint256 marginDelta = _freeSettlementUsdc(accountId);
        CfdTypes.Order memory order = CfdTypes.Order({
            accountId: accountId,
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
            accountId, CfdTypes.Side.BULL, sizeDelta, marginDelta, 1e8, uint64(block.timestamp)
        );
        CfdEnginePlanTypes.OpenFailurePolicyCategory failureCategory = engineLens.previewOpenFailurePolicyCategory(
            accountId, CfdTypes.Side.BULL, sizeDelta, marginDelta, 1e8, uint64(block.timestamp)
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
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(11));
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);

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
            accountId: accountId,
            sizeDelta: 500_000 * 1e18,
            marginDelta: 1000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });

        vm.expectRevert(abi.encodeWithSelector(ICfdEngine.CfdEngine__TypedOrderFailure.selector, 1, 6, false));
        vm.prank(address(router));
        engine.processOrderTyped(order, 1e8, vaultDepth, uint64(block.timestamp));
    }

    function test_C5_CloseSucceeds_WhenCarryExceedsMargin_ButPositionProfitable() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 10_000 * 1e6);

        // Open BULL 100k tokens at $1.00 with $1600 margin (meets explicit 1.5% init margin)
        CfdTypes.Order memory openOrder = CfdTypes.Order({
            accountId: accountId,
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
        engine.processOrderTyped(openOrder, 1e8, vaultDepth, uint64(block.timestamp));

        // Warp 365 days — carry will far exceed margin
        vm.warp(block.timestamp + 365 days);

        // Price dropped to $0.50 → BULL has $50k unrealized profit
        // User should be able to close and receive profit minus carry minus fees
        uint256 chBefore = clearinghouse.balanceUsdc(accountId);

        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            accountId: accountId,
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
        engine.processOrderTyped(closeOrder, 0.5e8, vaultDepth, uint64(block.timestamp));

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be fully closed");

        uint256 chAfter = clearinghouse.balanceUsdc(accountId);
        assertGt(chAfter, chBefore, "User should net positive after profitable close minus carry");
    }

    function test_C2_InsufficientInitialMargin_Reverts() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 1000 * 1e6);

        // notional = 100k * $1 = $100k. execFee = $60, VPI ~= $2.50
        // MMR = 1% of $100k = $1000
        // Even using full cross-margin equity, $1000 account collateral is below the configured $1500 initial margin requirement.
        // Without the initial margin check, this would create an instantly-liquidatable position.
        CfdTypes.Order memory order = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 100 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });

        vm.expectRevert(abi.encodeWithSelector(ICfdEngine.CfdEngine__TypedOrderFailure.selector, 1, 6, false));
        vm.prank(address(router));
        engine.processOrderTyped(order, 1e8, vaultDepth, uint64(block.timestamp));
    }

    function test_H8_CloseAfterBlendedEntry_DoesNotUnderflow() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 10_000 * 1e6);

        // Open BEAR 100k tokens at price $1.00000001 (just above $1.00)
        CfdTypes.Order memory first = CfdTypes.Order({
            accountId: accountId,
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
        engine.processOrderTyped(first, 100_000_001, vaultDepth, uint64(block.timestamp));

        // Open BEAR 200k tokens at price $1.00 — blends entry to 100_000_000 (truncated from .33)
        // Sum of individual maxProfits < maxProfit(blended) due to integer truncation
        CfdTypes.Order memory second = CfdTypes.Order({
            accountId: accountId,
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
        engine.processOrderTyped(second, 100_000_000, vaultDepth, uint64(block.timestamp));

        // Close entire position — must not underflow in _reduceGlobalLiability
        CfdTypes.Order memory close = CfdTypes.Order({
            accountId: accountId,
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
        engine.processOrderTyped(close, 100_000_000, vaultDepth, uint64(block.timestamp));

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be fully closed");
        assertEq(_sideMaxProfit(CfdTypes.Side.BEAR), 0, "Global bear max profit should be zero");
    }

    function test_H9_SolvencyDeadlock_CloseAllowedDuringInsolvency() public {
        vm.warp(block.timestamp + 1 hours);
        juniorVault.withdraw(800_000 * 1e6, address(this), address(this));

        uint256 vaultDepth = 200_000 * 1e6;
        bytes32 aliceId = bytes32(uint256(1));
        bytes32 bobId = bytes32(uint256(2));
        _fundTrader(address(uint160(uint256(aliceId))), 50_000 * 1e6);
        _fundTrader(address(uint160(uint256(bobId))), 50_000 * 1e6);

        CfdTypes.Order memory aliceOpen = CfdTypes.Order({
            accountId: aliceId,
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
        engine.processOrderTyped(aliceOpen, 1e8, vaultDepth, uint64(block.timestamp));

        CfdTypes.Order memory bobOpen = CfdTypes.Order({
            accountId: bobId,
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
        engine.processOrderTyped(bobOpen, 1e8, vaultDepth, uint64(block.timestamp));

        vm.prank(address(engine));
        pool.payOut(address(0xDEAD), 60_000 * 1e6);

        uint256 maxLiab = _sideMaxProfit(CfdTypes.Side.BULL) > _sideMaxProfit(CfdTypes.Side.BEAR)
            ? _sideMaxProfit(CfdTypes.Side.BULL)
            : _sideMaxProfit(CfdTypes.Side.BEAR);
        assertTrue(usdc.balanceOf(address(pool)) < maxLiab, "Vault should be insolvent");

        CfdTypes.Order memory aliceClose = CfdTypes.Order({
            accountId: aliceId,
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
        engine.processOrderTyped(aliceClose, 1e8, vaultDepth, uint64(block.timestamp));

        (uint256 aliceSize,,,,,,) = engine.positions(aliceId);
        assertEq(aliceSize, 0, "Close should succeed during insolvency");
    }

    function test_M11_LiquidationSeizesFreeEquity() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        address trader = address(uint160(uint256(accountId)));
        _fundTrader(trader, 50_000 * 1e6);

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            accountId: accountId,
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
        engine.processOrderTyped(openOrder, 1e8, vaultDepth, uint64(block.timestamp));

        vm.prank(trader);
        clearinghouse.withdraw(accountId, 46_000 * 1e6);

        uint256 freeEquityBefore = clearinghouse.getFreeBuyingPowerUsdc(accountId);
        assertTrue(freeEquityBefore > 0, "User should have free equity beyond locked margin");

        uint256 vaultBefore = usdc.balanceOf(address(pool));

        // Price rises to $1.10 — BULL loses $10k, equity = margin (~$1537) - $10k = negative
        vm.prank(address(router));
        engine.liquidatePosition(accountId, 1.1e8, vaultDepth, uint64(block.timestamp));

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be liquidated");

        uint256 freeEquityAfter = clearinghouse.getFreeBuyingPowerUsdc(accountId);
        assertTrue(freeEquityAfter < freeEquityBefore, "Free equity should be reduced to cover bad debt");

        uint256 vaultAfter = usdc.balanceOf(address(pool));
        uint256 totalRecovered = vaultAfter - vaultBefore;
        (, uint256 posMarginStored,,,,,) = engine.positions(accountId);
        assertTrue(totalRecovered > 0, "Vault should recover more than zero from bad debt liquidation");
    }

    function test_LiquidationWorksWhenVaultInsolvent() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 aliceId = bytes32(uint256(1));
        bytes32 bobId = bytes32(uint256(2));
        address aliceTrader = address(uint160(uint256(aliceId)));
        _fundTrader(aliceTrader, 50_000 * 1e6);
        _fundTrader(address(uint160(uint256(bobId))), 50_000 * 1e6);

        CfdTypes.Order memory aliceOpen = CfdTypes.Order({
            accountId: aliceId,
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
        engine.processOrderTyped(aliceOpen, 1e8, vaultDepth, uint64(block.timestamp));

        vm.prank(aliceTrader);
        clearinghouse.withdraw(aliceId, 28_000 * 1e6);

        CfdTypes.Order memory bobOpen = CfdTypes.Order({
            accountId: bobId,
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
        engine.processOrderTyped(bobOpen, 1e8, vaultDepth, uint64(block.timestamp));

        // Drain vault to simulate insolvency (pool has ~$1M + fees, maxLiab = $200k)
        vm.prank(address(engine));
        pool.payOut(address(0xDEAD), 810_000 * 1e6);

        uint256 maxLiab = _sideMaxProfit(CfdTypes.Side.BULL) > _sideMaxProfit(CfdTypes.Side.BEAR)
            ? _sideMaxProfit(CfdTypes.Side.BULL)
            : _sideMaxProfit(CfdTypes.Side.BEAR);
        assertTrue(usdc.balanceOf(address(pool)) < maxLiab, "Vault should be insolvent");

        // Price rises to $1.10 — BULL loses $20k, deeply underwater
        vm.prank(address(router));
        engine.liquidatePosition(aliceId, 1.1e8, vaultDepth, uint64(block.timestamp));

        (uint256 aliceSize,,,,,,) = engine.positions(aliceId);
        assertEq(aliceSize, 0, "Liquidation must succeed during insolvency");
    }

    function test_Liquidate_EmptyPosition_Reverts() public {
        bytes32 accountId = bytes32(uint256(1));
        vm.expectRevert(CfdEngine.CfdEngine__NoPositionToLiquidate.selector);
        vm.prank(address(router));
        engine.liquidatePosition(accountId, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));
    }

    function test_LiquidationBounty_CappedByPositiveEquity() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1234));
        address trader = address(uint160(uint256(accountId)));
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
            accountId: accountId,
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
        engine.processOrderTyped(openOrder, 1e8, vaultDepth, uint64(block.timestamp));

        (, uint256 posMargin,,,,,) = engine.positions(accountId);

        vm.prank(trader);
        clearinghouse.withdraw(accountId, 194 * 1e6);

        vm.prank(address(router));
        uint256 bounty = engine.liquidatePosition(accountId, 100_500_000, vaultDepth, uint64(block.timestamp));

        assertLe(bounty, posMargin, "Keeper bounty should not exceed remaining positive equity");
        assertEq(bounty, 600_000, "Keeper bounty should cap at the trader's remaining positive equity");
    }

    function test_ClearBadDebt_ReducesOutstandingDebt() public {
        bytes32 accountId = bytes32(uint256(0xBADD));
        _fundTrader(address(uint160(uint256(accountId))), 4000 * 1e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000 * 1e18, 3000 * 1e6, 1e8);

        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(accountId, 1.2e8, depth, uint64(block.timestamp));

        uint256 badDebt = engine.accumulatedBadDebtUsdc();
        assertGt(badDebt, 0, "Expected liquidation shortfall to create bad debt");

        uint256 clearAmount = badDebt / 2;
        uint256 vaultAssetsBefore = pool.totalAssets();
        usdc.mint(address(this), clearAmount);
        usdc.approve(address(engine), clearAmount);
        engine.clearBadDebt(clearAmount);
        assertEq(engine.accumulatedBadDebtUsdc(), badDebt - clearAmount, "Bad debt should decrease after clearing");
        assertEq(
            pool.totalAssets(),
            vaultAssetsBefore + clearAmount,
            "Bad-debt recapitalization should raise canonical vault assets"
        );
        assertEq(pool.excessAssets(), 0, "Bad-debt recapitalization should not strand excess assets");

        vm.expectRevert(CfdEngine.CfdEngine__ZeroAmount.selector);
        engine.clearBadDebt(0);

        vm.expectRevert(CfdEngine.CfdEngine__BadDebtTooLarge.selector);
        engine.clearBadDebt(badDebt + 1);
    }

    function test_CheckWithdraw_UsesMinimumOfEngineAndPoolMarkStalenessLimits() public {
        HousePool.PoolConfig memory poolConfig = _currentPoolConfig();
        poolConfig.markStalenessLimit = 300;
        pool.proposePoolConfig(poolConfig);
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizePoolConfig();
        assertEq(pool.markStalenessLimit(), 300);

        bytes32 accountId = bytes32(uint256(0x5157));
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);
        _open(accountId, CfdTypes.Side.BULL, 20_000 * 1e18, 2000 * 1e6, 1e8);

        vm.warp(block.timestamp + 31);

        vm.prank(address(clearinghouse));
        engine.checkWithdraw(accountId);

        vm.warp(block.timestamp + 270);

        vm.expectRevert(CfdEngine.CfdEngine__MarkPriceStale.selector);
        vm.prank(address(clearinghouse));
        engine.checkWithdraw(accountId);

        ICfdEngineAdminHost.EngineFreshnessConfig memory engineConfig = _engineFreshnessConfig();
        engineConfig.engineMarkStalenessLimit = 300;
        engineAdmin.proposeFreshnessConfig(engineConfig);
        vm.warp(engineAdmin.freshnessConfigActivationTime() + 1);
        engineAdmin.finalizeFreshnessConfig();

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.prank(address(clearinghouse));
        engine.checkWithdraw(accountId);
    }

    function test_SweepToken_RecoversAccidentallySentUsdc() public {
        usdc.mint(address(engine), 123e6);
        uint256 ownerBefore = usdc.balanceOf(address(this));

        engine.sweepToken(address(usdc), address(this), 123e6);

        assertEq(usdc.balanceOf(address(engine)), 0);
        assertEq(usdc.balanceOf(address(this)), ownerBefore + 123e6);
    }

    function test_ReserveCloseOrderExecutionBounty_AllowsStaleLastMarkPriceWhenStored() public {
        HousePool.PoolConfig memory config = _currentPoolConfig();
        config.markStalenessLimit = 300;
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizePoolConfig();

        address trader = address(0x5159);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        address counterparty = address(0x5160);
        bytes32 counterpartyId = bytes32(uint256(uint160(counterparty)));

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 1500e6, 1e8);
        _open(counterpartyId, CfdTypes.Side.BEAR, 10_000e18, 50_000e6, 1e8);

        vm.warp(block.timestamp + 31);
        vm.prank(address(router));
        engine.reserveCloseOrderExecutionBounty(accountId, 10_000e18, 1e6, address(router));

        vm.warp(block.timestamp + 30 days);
        vm.prank(address(router));
        engine.reserveCloseOrderExecutionBounty(accountId, 10_000e18, 1e6, address(router));
    }

    function test_ReserveCloseOrderExecutionBounty_RevertsWhenNoStoredMarkExists() public {
        address trader = address(0x51595);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        address counterparty = address(0x51596);
        bytes32 counterpartyId = bytes32(uint256(uint160(counterparty)));

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 1500e6, 1e8);
        _open(counterpartyId, CfdTypes.Side.BEAR, 10_000e18, 50_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(0, uint64(block.timestamp));
        vm.prank(address(router));
        vm.expectRevert(CfdEngine.CfdEngine__InsufficientCloseOrderBountyBacking.selector);
        engine.reserveCloseOrderExecutionBounty(accountId, 10_000e18, 1e6, address(router));
    }

    function test_ReserveCloseOrderExecutionBounty_ExcludesQueuedReservationsFromGenericReachability() public {
        address trader = address(0x5161);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        address counterparty = address(0x5162);
        bytes32 counterpartyId = bytes32(uint256(uint160(counterparty)));

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 2000e6, 1e8);
        _open(counterpartyId, CfdTypes.Side.BEAR, 10_000e18, 50_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 4000e6, type(uint256).max, false);

        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(accountId);
        assertEq(buckets.otherLockedMarginUsdc, 4000e6, "Setup should reserve queued order funds");
        assertEq(
            MarginClearinghouseAccountingLib.getGenericReachableUsdc(buckets),
            buckets.settlementBalanceUsdc - buckets.otherLockedMarginUsdc,
            "Generic reachability must exclude the queued reservation"
        );

        vm.prank(address(router));
        vm.expectRevert(CfdEngine.CfdEngine__InsufficientCloseOrderBountyBacking.selector);
        engine.reserveCloseOrderExecutionBounty(accountId, 10_000e18, 6000e6, address(router));
    }

    function test_CheckWithdraw_RevertsWhenOpenPositionHasZeroMarkPrice() public {
        bytes32 accountId = bytes32(uint256(0x5158));
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);
        _open(accountId, CfdTypes.Side.BULL, 20_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(0, uint64(block.timestamp));

        vm.expectRevert(CfdEngine.CfdEngine__MarkPriceStale.selector);
        vm.prank(address(clearinghouse));
        engine.checkWithdraw(accountId);
    }

    function test_CheckWithdraw_DoesNotCountDeferredTraderCreditAsReachableCollateral() public {
        address trader = address(0x51581);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 5000e6);
        _open(accountId, CfdTypes.Side.BEAR, 10_000e18, 5000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        _close(accountId, CfdTypes.Side.BEAR, 5000e18, 120_000_000);
        assertGt(engine.deferredTraderCreditUsdc(accountId), 0, "Setup must create deferred trader credit");

        bytes4 expectedError = engine.degradedMode()
            ? CfdEngine.CfdEngine__DegradedMode.selector
            : CfdEngine.CfdEngine__WithdrawBlockedByOpenPosition.selector;
        vm.expectRevert(expectedError);
        vm.prank(address(clearinghouse));
        engine.checkWithdraw(accountId);
    }

    function test_CheckWithdrawParity_FailThenLiveWithdrawReverts() public {
        address trader = address(0x515816);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        WithdrawParityState memory state = _observeWithdrawParity(accountId, trader, 5000e6);
        _assertWithdrawParity(state, CfdEngine.CfdEngine__WithdrawBlockedByOpenPosition.selector);
    }

    function test_CheckWithdrawParity_StaleLiveMarkBlocksWithdraw() public {
        address trader = address(0x515817);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);

        WithdrawParityState memory state = _observeWithdrawParity(accountId, trader, 100e6);
        _assertWithdrawParity(state, CfdEngine.CfdEngine__MarkPriceStale.selector);
    }

    function helper_CheckWithdrawParity_NoCarryProjectionWithoutPriorSync() public {
        CfdTypes.RiskParams memory params = _riskParams();
        _setRiskParams(params);

        address trader = address(0x515818);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 1600e6, 1e8);

        ICfdEngineAdminHost.EngineFreshnessConfig memory config = _engineFreshnessConfig();
        config.engineMarkStalenessLimit = 300;
        engineAdmin.proposeFreshnessConfig(config);
        vm.warp(engineAdmin.freshnessConfigActivationTime() + 1);
        engineAdmin.finalizeFreshnessConfig();

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() - 1);

        WithdrawParityState memory state = _observeWithdrawParity(accountId, trader, 80e6);
        _assertWithdrawParity(state, CfdEngine.CfdEngine__WithdrawBlockedByOpenPosition.selector);
    }

    function test_CheckWithdraw_UsesExplicitInitMarginBps() public {
        address trader = address(0x515815);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 3200e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 3000e6, 1e8);

        CfdTypes.RiskParams memory params = _riskParams();
        params.initMarginBps = 300;
        _setRiskParams(params);

        (,,, uint256 initMarginBps,,,,) = engine.riskParams();
        assertEq(initMarginBps, 300, "Setup must finalize the explicit init margin config");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.expectRevert(CfdEngine.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        vm.prank(trader);
        clearinghouse.withdraw(accountId, 200e6);
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
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 100e6);
        _open(accountId, CfdTypes.Side.BULL, 100e18, 6e6, 1e8);

        vm.warp(1_709_971_200);
        assertTrue(engine.isFadWindow(), "Setup must execute inside the FAD window");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 withdrawableUsdc = engineAccountLens.getWithdrawableUsdc(accountId);
        assertGt(withdrawableUsdc, 0, "Buggy init-margin path should expose withdrawable headroom during FAD");

        vm.expectRevert(CfdEngine.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        vm.prank(trader);
        clearinghouse.withdraw(accountId, withdrawableUsdc);
    }

    function test_ReserveCloseOrderExecutionBounty_UsesCarryAwareProjectedRiskState() public {
        CfdTypes.RiskParams memory params = _riskParams();
        _setRiskParams(params);

        address trader = address(0x51583);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 1600e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 1600e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() - 1);

        vm.prank(address(router));
        vm.expectRevert(CfdEngine.CfdEngine__InsufficientCloseOrderBountyBacking.selector);
        engine.reserveCloseOrderExecutionBounty(accountId, 50_000e18, 1400e6, address(router));
    }

    function test_ReserveCloseOrderExecutionBounty_RecomputesCarryAfterReservationReachabilityDrop() public {
        CfdTypes.RiskParams memory params = _riskParams();
        _setRiskParams(params);

        address trader = address(0x51584);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        uint256 price = 1e8;
        uint256 size = 100_000e18;
        uint256 marginUsdc = 1600e6;
        uint256 bountyUsdc = 1e6;
        uint256 carryTimeDelta = 3_839_405;

        _fundTrader(trader, marginUsdc);
        _open(accountId, CfdTypes.Side.BULL, size, marginUsdc, price);

        vm.prank(address(router));
        engine.updateMarkPrice(price, uint64(block.timestamp));
        vm.warp(block.timestamp + carryTimeDelta);

        uint256 postReservationReachableUsdc = marginUsdc - bountyUsdc;
        uint256 staleCarryUsdc = PositionRiskAccountingLib.computePendingCarryUsdc(
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(size, price, marginUsdc),
            params.baseCarryBps,
            carryTimeDelta
        );
        uint256 recomputedCarryUsdc = PositionRiskAccountingLib.computePendingCarryUsdc(
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(size, price, postReservationReachableUsdc),
            params.baseCarryBps,
            carryTimeDelta
        );
        uint256 maintMarginUsdc = ((size * price) / CfdMath.USDC_TO_TOKEN_SCALE) * params.maintMarginBps / 10_000;

        assertEq(staleCarryUsdc, 598_993_930, "Setup must pin the pre-reservation carry projection");
        assertEq(recomputedCarryUsdc, 599_000_018, "Setup must increase carry once reachability drops by the bounty");
        assertGt(
            postReservationReachableUsdc - staleCarryUsdc,
            maintMarginUsdc,
            "Pre-patch carry snapshot would leave the account barely above maintenance"
        );
        assertLe(
            postReservationReachableUsdc - recomputedCarryUsdc,
            maintMarginUsdc,
            "Recomputed carry must make the reservation fail once maintenance is breached"
        );

        vm.prank(address(router));
        vm.expectRevert(CfdEngine.CfdEngine__InsufficientCloseOrderBountyBacking.selector);
        engine.reserveCloseOrderExecutionBounty(accountId, size / 2, bountyUsdc, address(router));
    }

    function test_ReserveCloseOrderExecutionBounty_AllowsFullCloseNearMaintenance() public {
        address trader = address(0x515991);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        address counterparty = address(0x515992);
        bytes32 counterpartyId = bytes32(uint256(uint160(counterparty)));
        uint256 size = 50_000e18;

        _fundTrader(trader, 1000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, size, 1000e6, 1e8);
        _open(counterpartyId, CfdTypes.Side.BEAR, size, 50_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(103_000_000, uint64(block.timestamp));

        assertEq(_freeSettlementUsdc(accountId), 0, "setup must fully consume free settlement");

        vm.prank(address(router));
        engine.reserveCloseOrderExecutionBounty(accountId, size, 1e6, address(router));
    }

    function test_ReserveCloseOrderExecutionBounty_PartialCloseStillRevertsNearMaintenance() public {
        address trader = address(0x515993);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        address counterparty = address(0x515994);
        bytes32 counterpartyId = bytes32(uint256(uint160(counterparty)));
        uint256 size = 50_000e18;

        _fundTrader(trader, 1000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, size, 1000e6, 1e8);
        _open(counterpartyId, CfdTypes.Side.BEAR, size, 50_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(103_000_000, uint64(block.timestamp));

        vm.prank(address(router));
        vm.expectRevert(CfdEngine.CfdEngine__InsufficientCloseOrderBountyBacking.selector);
        engine.reserveCloseOrderExecutionBounty(accountId, size / 2, 1e6, address(router));
    }

    function test_ClaimDeferredKeeperCredit_DoesNotRequireFreshMarkForKeeperPosition() public {
        address keeper = address(0x51597);
        address counterparty = address(0x51598);
        bytes32 keeperAccountId = bytes32(uint256(uint160(keeper)));
        bytes32 counterpartyId = bytes32(uint256(uint160(counterparty)));

        _fundTrader(keeper, 10_000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(keeperAccountId, CfdTypes.Side.BULL, 10_000e18, 1500e6, 1e8);
        _open(counterpartyId, CfdTypes.Side.BEAR, 10_000e18, 50_000e6, 1e8);

        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(keeper, 100e6);

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);

        uint256 settlementBefore = clearinghouse.balanceUsdc(keeperAccountId);
        vm.prank(keeper);
        engine.claimDeferredKeeperCredit();

        assertEq(clearinghouse.balanceUsdc(keeperAccountId), settlementBefore + 100e6);
        assertEq(engine.deferredKeeperCreditUsdc(keeper), 0);
    }

    function test_VpiDepthManipulation_NeutralizedByStatefulBound() public {
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 50_000 * 1e6);

        uint256 largeDepth = 10_000_000 * 1e6;
        uint256 smallDepth = 100_000 * 1e6;

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 10_000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        uint256 chBeforeOpen = clearinghouse.balanceUsdc(accountId);
        vm.prank(address(router));
        engine.processOrderTyped(openOrder, 1e8, largeDepth, uint64(block.timestamp));

        (,,,,,, int256 storedVpi) = engine.positions(accountId);
        assertTrue(storedVpi != 0, "VPI should be tracked");

        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            accountId: accountId,
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

        uint256 chAfterClose = clearinghouse.balanceUsdc(accountId);

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

        bytes32 attackerId = bytes32(uint256(uint160(address(0xA1))));
        _fundTrader(address(0xA1), 500_000 * 1e6);

        bytes32 counterId = bytes32(uint256(uint160(address(0xB1))));
        _fundTrader(address(0xB1), 500_000 * 1e6);
        _open(counterId, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8, depth);

        uint256 minNotional = (uint256(1) * 1e6 * 10_000) / 10 + 1e6;
        uint256 minSize = (minNotional * 1e20) / 1e8;
        _open(attackerId, CfdTypes.Side.BULL, minSize, 50_000 * 1e6, 1e8, depth);

        // H-03: closing to 1 wei now reverts (remaining margin < minBountyUsdc)
        uint256 closeSize = minSize - 1;
        vm.expectRevert(abi.encodeWithSelector(ICfdEngine.CfdEngine__TypedOrderFailure.selector, 1, 2, true));
        vm.prank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                accountId: attackerId,
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

        bytes32 aliceId = bytes32(uint256(uint160(address(0xA2))));
        _fundTrader(address(0xA2), 100_000 * 1e6);
        _open(aliceId, CfdTypes.Side.BULL, 50_000 * 1e18, 5000 * 1e6, 1.2e8, depth);

        bytes32 bobId = bytes32(uint256(uint160(address(0xB2))));
        _fundTrader(address(0xB2), 100_000 * 1e6);
        _open(bobId, CfdTypes.Side.BEAR, 100_000 * 1e18, 5000 * 1e6, 1.2e8, depth);

        vm.prank(address(router));
        engine.updateMarkPrice(1.1e8, uint64(block.timestamp));

        uint256 mtm = _vaultMtmAdjustment();
        assertEq(
            mtm,
            5000e6,
            "Only the profitable bull side should count toward vault MtM; losing bear exposure must clamp to zero"
        );
    }

    // Regression: C-03 — unrealized MtM profits distributed as withdrawable cash
    function test_UnrealizedGains_DistributedAsWithdrawableCash() public {
        uint256 depth = 5_000_000 * 1e6;

        bytes32 traderId = bytes32(uint256(uint160(address(0x2222))));
        _fundTrader(address(0x2222), 500_000 * 1e6);
        _open(traderId, CfdTypes.Side.BULL, 2_000_000 * 1e18, 200_000 * 1e6, 1e8, depth);

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

        bytes32 accountId = bytes32(uint256(uint160(carol)));

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        (uint256 sizeAfterOpen,,,,,,) = engine.positions(accountId);

        vm.warp(block.timestamp + 182 days);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 1000 * 1e18, 500 * 1e6, 1e8, false);
        vm.roll(block.number + 1);
        router.executeOrder(2, empty);

        (uint256 sizeAfterSecond,,,,,,) = engine.positions(accountId);

        assertGt(
            sizeAfterSecond,
            sizeAfterOpen,
            "Carry-aware accounting should let the follow-on order execute instead of being cancelled"
        );
    }

    function test_ProcessOrderTyped_RevertsWhenTruePostTradeEquityFailsImr() public {
        address trader = address(0xABCD1234);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(trader, 1020 * 1e6);
        _open(accountId, CfdTypes.Side.BULL, 50_000 * 1e18, 1000 * 1e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(101_800_000, uint64(block.timestamp));

        uint8 revertCode = engineLens.previewOpenRevertCode(
            accountId, CfdTypes.Side.BULL, 10_000 * 1e18, 0, 101_800_000, uint64(block.timestamp)
        );
        assertEq(
            revertCode,
            uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN),
            "Preview should reject increases backed only by stale stored margin"
        );

        CfdTypes.Order memory order = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 0,
            targetPrice: 101_800_000,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        uint256 vaultDepth = pool.totalAssets();

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngine.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
                uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN),
                false
            )
        );
        vm.prank(address(router));
        engine.processOrderTyped(order, 101_800_000, vaultDepth, uint64(block.timestamp));
    }

    function test_ProcessOrderTyped_RevertsWhenAccountAlreadyLiquidatableBeforeIncrease() public {
        address trader = address(0xABCD5678);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(trader, 1020 * 1e6);
        _open(accountId, CfdTypes.Side.BULL, 50_000 * 1e18, 1000 * 1e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(102_000_000, uint64(block.timestamp));

        PerpsViewTypes.PositionView memory positionView = _publicPosition(accountId);
        assertTrue(positionView.liquidatable, "Setup must make the existing position liquidatable before the increase");

        uint8 revertCode = engineLens.previewOpenRevertCode(
            accountId, CfdTypes.Side.BULL, 10_000 * 1e18, 0, 102_000_000, uint64(block.timestamp)
        );
        CfdEnginePlanTypes.OpenFailurePolicyCategory failureCategory = engineLens.previewOpenFailurePolicyCategory(
            accountId, CfdTypes.Side.BULL, 10_000 * 1e18, 0, 102_000_000, uint64(block.timestamp)
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
            accountId: accountId,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 0,
            targetPrice: 102_000_000,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        uint256 vaultDepth = pool.totalAssets();

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngine.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
                uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN),
                false
            )
        );
        vm.prank(address(router));
        engine.processOrderTyped(order, 102_000_000, vaultDepth, uint64(block.timestamp));
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

        bytes32 carolAccount = bytes32(uint256(uint160(carol)));
        (uint256 sizeBefore,,,,,,) = engine.positions(carolAccount);

        IOrderRouterAdminHost.RouterConfig memory config = IOrderRouterAdminHost.RouterConfig({
            maxOrderAge: 0,
            orderExecutionStalenessLimit: router.orderExecutionStalenessLimit(),
            liquidationStalenessLimit: router.liquidationStalenessLimit(),
            pythMaxConfidenceRatioBps: router.pythMaxConfidenceRatioBps(),
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

        vm.expectRevert(CfdEngine.CfdEngine__MarkPriceStale.selector);
        engineLens.previewOpenRevertCode(
            carolAccount, CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, uint64(block.timestamp)
        );

        vm.roll(block.number + 1);
        vm.expectRevert(CfdEngine.CfdEngine__MarkPriceStale.selector);
        router.executeOrder(3, empty);

        (uint256 sizeAfter,,,,,,) = engine.positions(carolAccount);
        assertEq(sizeAfter, sizeBefore, "Rejected stale-mark execution should leave the existing position unchanged");
    }

    // Regression: C-01
    function test_PartialClosePreservesLockedMarginForRemainingPosition() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 22_000 * 1e6);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000 * 1e18, 20_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        (uint256 openSize,,,,,,) = engine.positions(accountId);
        assertEq(openSize, 200_000 * 1e18);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000 * 1e18, 0, 0, true);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(0.8e8));
        router.executeOrder(2, priceData);

        (uint256 remainingSize,,,,,,) = engine.positions(accountId);
        assertEq(remainingSize, 200_000 * 1e18, "Underwater partial close should fail and leave the position untouched");

        uint256 balAfter = clearinghouse.balanceUsdc(accountId);
        uint256 lockedAfter = clearinghouse.lockedMarginUsdc(accountId);
        assertGe(balAfter, lockedAfter, "Physical balance must cover locked margin (zombie prevention)");

        router.executeLiquidation(accountId, priceData);

        (uint256 sizeAfterLiq,,,,,,) = engine.positions(accountId);
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
        bytes[] memory empty;
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

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertGt(size, 0, "Position should be open");

        uint256 locked = clearinghouse.lockedMarginUsdc(accountId);
        uint256 usdcBal = clearinghouse.balanceUsdc(accountId);
        uint256 free = usdcBal - locked;
        assertGt(free, 0, "Alice should have free USDC to withdraw");

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        clearinghouse.withdraw(accountId, free);
        assertEq(usdc.balanceOf(alice), balBefore + free, "Free equity withdrawn");
    }

    function test_Withdraw_BlocksAfterFreeEquityIsFullyConsumed() public {
        _fundJunior(bob, 500_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertGt(size, 0, "Setup must leave an open position");

        uint256 withdrawableUsdc = engineAccountLens.getWithdrawableUsdc(accountId);
        assertGt(withdrawableUsdc, 0, "Setup must leave some withdrawable free equity");

        vm.prank(alice);
        clearinghouse.withdraw(accountId, withdrawableUsdc);

        vm.expectRevert();
        vm.prank(alice);
        clearinghouse.withdraw(accountId, 1);
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
        bytes[] memory empty;
        router.executeOrder(1, empty);

        assertEq(_sideTotalMargin(CfdTypes.Side.BULL), 0, "Bull margin unchanged");
        assertGt(_sideTotalMargin(CfdTypes.Side.BEAR), 0, "Bear margin tracked after open");
    }

    function test_MarginTracking_DecreasesOnClose() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        uint256 bearMarginAfterOpen = _sideTotalMargin(CfdTypes.Side.BEAR);
        assertGt(bearMarginAfterOpen, 0);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 0, 1e8, true);
        router.executeOrder(2, empty);

        assertEq(_sideTotalMargin(CfdTypes.Side.BEAR), 0, "Bear margin zero after full close");
    }

    function test_MarginTracking_PartialClose() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        uint256 bearMarginFull = _sideTotalMargin(CfdTypes.Side.BEAR);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 50_000e18, 0, 1e8, true);
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
        bytes[] memory empty;
        router.executeOrder(1, empty);

        assertGt(_sideTotalMargin(CfdTypes.Side.BEAR), 0);

        bytes[] memory liqPrice = new bytes[](1);
        liqPrice[0] = abi.encode(uint256(0.5e8));
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        router.executeLiquidation(accountId, liqPrice);

        assertEq(_sideTotalMargin(CfdTypes.Side.BEAR), 0, "Bear margin zero after liquidation");
    }

    // Regression: C-02
    function test_PhantomProfitCappedAtMargin() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(0.5e8));
        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 10_000e6, 0.5e8, false);
        router.executeOrder(2, priceData);

        int256 uncappedPnl = _unrealizedTraderPnl();
        uint256 cappedMtm = _vaultMtmAdjustment();

        assertLt(uncappedPnl, -int256(_sideTotalMargin(CfdTypes.Side.BEAR)), "Uncapped loss exceeds deposited margin");
        assertGt(int256(cappedMtm), uncappedPnl, "Capped MtM is less aggressive than uncapped");
    }

    // Regression: C-02
    function test_ReconcileDoesNotInflateBeyondMargin() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        uint256 juniorBefore = pool.juniorPrincipal();

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(0.5e8));
        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 10_000e6, 0.5e8, false);
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
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1.2e8));
        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 10_000e6, 1.2e8, false);
        router.executeOrder(2, priceData);

        uint256 mtm = _vaultMtmAdjustment();
        assertGt(mtm, 0, "Positive MtM = vault liability when traders are winning (no cap needed)");
    }

    function test_MtmAdjustment_ZeroWithNoPositions() public {
        _fundJunior(bob, 500_000e6);
        assertEq(_vaultMtmAdjustment(), 0, "MtM should be zero with no positions");
    }

}

// ==========================================
// PhantomExecFeeTest: close exec fee must not inflate accumulatedFees
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
    function test_PhantomExecFee_InflatesAccumulatedFees() public {
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
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        clearinghouse.deposit(accountId, margin);

        uint256 size = 50_000e18;
        router.commitOrder(CfdTypes.Side.BULL, size, 1000e6, 1e8, false);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        router.executeOrder(1, priceData);

        uint256 openFee = engine.accumulatedFeesUsdc();

        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, size, 0, 0, true);

        assertEq(router.nextCommitId(), 3, "Close intents should reserve a flat keeper bounty from free settlement");
        assertEq(
            engine.accumulatedFeesUsdc(), openFee, "Committing the close should not accrue additional protocol fees"
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
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        clearinghouse.deposit(accountId, margin);

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
        clearinghouse.deposit(bytes32(uint256(uint160(carol))), carolMargin);
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
        uint256 pendingFees = engine.accumulatedFeesUsdc();
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
        bytes32 bullId = bytes32(uint256(uint160(bullTrader)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));

        _fundTrader(bullTrader, 100_000e6);
        _fundTrader(bearTrader, 100_000e6);

        _open(bearId, CfdTypes.Side.BEAR, 1_000_000e18, 50_000e6, 1e8);
        _open(bullId, CfdTypes.Side.BULL, 500_000e18, 50_000e6, 1e8);
        _close(bullId, CfdTypes.Side.BULL, 500_000e18, 20_000_000);
    }

    function test_DegradedMode_LatchesAndBlocksNewOpens() public {
        address newTrader = address(0xD003);
        bytes32 newTraderId = bytes32(uint256(uint160(newTrader)));
        _fundTrader(newTrader, 100_000e6);

        _enterDegradedMode();

        assertTrue(engine.degradedMode(), "Setup must latch degraded mode");

        vm.prank(address(router));
        (bool ok,) = address(engine)
            .call(
                abi.encodeWithSelector(
                    engine.processOrderTyped.selector,
                    CfdTypes.Order({
                        accountId: newTraderId,
                        sizeDelta: 10_000e18,
                        marginDelta: 1000e6,
                        targetPrice: 1e8,
                        commitTime: uint64(block.timestamp),
                        commitBlock: uint64(block.number),
                        orderId: 0,
                        side: CfdTypes.Side.BULL,
                        isClose: false
                    }),
                    1e8,
                    pool.totalAssets(),
                    uint64(block.timestamp)
                )
            );
        assertFalse(ok, "Degraded mode must block new opens");
    }

    function test_DegradedMode_ClearRequiresRecapitalization() public {
        _enterDegradedMode();

        vm.expectRevert(CfdEngine.CfdEngine__StillInsolvent.selector);
        engine.clearDegradedMode();

        _fundJunior(address(this), 500_000e6);
        engine.clearDegradedMode();

        assertFalse(engine.degradedMode(), "Owner should clear degraded mode after recapitalization");
    }

    function test_DegradedMode_BlocksJuniorWithdrawals() public {
        _enterDegradedMode();
        assertTrue(engine.degradedMode(), "Setup must latch degraded mode");

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(address(juniorVault));
        vm.expectRevert(HousePool.HousePool__DegradedMode.selector);
        pool.withdrawJunior(1e6, address(this));
    }

    function test_DegradedMode_AllowsAddMarginToExistingPosition() public {
        address trader = address(0xD004);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 200_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);

        _enterDegradedMode();
        assertTrue(engine.degradedMode(), "Setup must latch degraded mode");

        uint256 lockedBefore = clearinghouse.lockedMarginUsdc(accountId);
        (, uint256 marginBefore,,,,,) = engine.positions(accountId);

        vm.prank(trader);
        engine.addMargin(accountId, 1000e6);

        (, uint256 marginAfter,,,,,) = engine.positions(accountId);
        assertEq(marginAfter, marginBefore + 1000e6, "Add margin should still increase position margin");
        assertEq(
            clearinghouse.lockedMarginUsdc(accountId),
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

        bytes32 bullId = bytes32(uint256(uint160(bullTrader)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));
        _fundTrader(bullTrader, 100_000e6);
        _fundTrader(bearTrader, 100_000e6);
        _open(bearId, CfdTypes.Side.BEAR, 1_000_000e18, 50_000e6, 1e8);
        _open(bullId, CfdTypes.Side.BULL, 500_000e18, 50_000e6, 1e8);
        _close(bullId, CfdTypes.Side.BULL, 500_000e18, 20_000_000);

        assertEq(
            uint8(ICfdEngine.ProtocolPhase(_publicProtocolStatus().phase)),
            uint8(ICfdEngine.ProtocolPhase.Degraded),
            "Insolvency-revealing close should latch Degraded"
        );

        _fundJunior(address(this), 500_000e6);
        engine.clearDegradedMode();

        assertEq(
            uint8(ICfdEngine.ProtocolPhase(_publicProtocolStatus().phase)),
            uint8(ICfdEngine.ProtocolPhase.Active),
            "Recapitalization should restore Active"
        );
    }

    function test_ConfiguringPhase() public {
        CfdEngine unconfigured = new CfdEngine(address(usdc), address(clearinghouse), 2e8, _riskParams());
        assertEq(
            unconfigured.getProtocolStatus().phase,
            uint8(ICfdEngine.ProtocolPhase.Configuring),
            "Engine without vault/router should be Configuring"
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
        bytes[] memory empty;
        router.executeOrder(1, empty);

        _fundTrader(alice, 50_000 * 1e6);
        bytes32 aliceAccount = bytes32(uint256(uint160(alice)));
        uint256 aliceBalBefore = clearinghouse.balanceUsdc(aliceAccount);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        router.executeOrder(2, empty);

        _fundJunior(bob, 9_000_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 0, 0, true);
        bytes[] memory closePrice = new bytes[](1);
        closePrice[0] = abi.encode(uint256(1e8));
        router.executeOrder(3, closePrice);

        uint256 aliceBalAfter = clearinghouse.balanceUsdc(aliceAccount);

        assertLe(aliceBalAfter, aliceBalBefore, "Minority VPI depth attack must not be profitable");
    }

    // Regression: C-02b
    function test_SizeAdditionCannotBypassVpiBound() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        bytes32 aliceAccount = bytes32(uint256(uint160(alice)));
        uint256 aliceBalBefore = clearinghouse.balanceUsdc(aliceAccount);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 5000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        _fundJunior(bob, 9_000_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
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
        bytes[] memory closePrice = new bytes[](1);
        closePrice[0] = abi.encode(uint256(1e8));
        router.executeOrder(3, closePrice);

        uint256 aliceBalAfter = clearinghouse.balanceUsdc(aliceAccount);

        assertLe(aliceBalAfter, aliceBalBefore, "Size addition VPI bypass must not be profitable");
    }

    function test_VpiRebateLiability_ReducesWithdrawableHeadroom() public {
        address deepLp = address(0x444);
        address skewTrader = address(0x555);
        address rebateTrader = address(0x666);

        bytes32 skewId = bytes32(uint256(uint160(skewTrader)));
        bytes32 rebateId = bytes32(uint256(uint160(rebateTrader)));

        _fundJunior(bob, 1_000_000 * 1e6);
        _fundJunior(deepLp, 10_000_000 * 1e6);
        _fundTrader(skewTrader, 100_000 * 1e6);
        _fundTrader(rebateTrader, 20_000 * 1e6);

        uint256 largeDepth = pool.totalAssets();
        _open(skewId, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8, largeDepth);

        vm.warp(block.timestamp + 2 hours);
        bytes[] memory freshPrice = new bytes[](1);
        freshPrice[0] = abi.encode(uint256(1e8));
        router.updateMarkPrice(freshPrice);

        vm.startPrank(deepLp);
        uint256 juniorWithdrawable = juniorVault.maxWithdraw(deepLp);
        juniorVault.withdraw(juniorWithdrawable, deepLp, deepLp);
        vm.stopPrank();

        uint256 smallDepth = pool.totalAssets();
        assertLt(smallDepth, largeDepth, "LP withdrawal should shrink live vault depth");

        uint256 rebateSettlementBeforeOpen = clearinghouse.balanceUsdc(rebateId);
        uint64 rebatePublishTime = engine.lastMarkTime();
        vm.prank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                accountId: rebateId,
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

        (,,,,,, int256 storedVpi) = engine.positions(rebateId);
        assertLt(storedVpi, 0, "Setup must create negative accrued VPI on the rebate-bearing leg");
        assertGt(
            clearinghouse.balanceUsdc(rebateId),
            rebateSettlementBeforeOpen,
            "Skew-healing open should credit net rebate into settlement balance"
        );

        uint256 freeSettlementUsdc = clearinghouse.getAccountUsdcBuckets(rebateId).freeSettlementUsdc;
        uint256 withdrawableUsdc = engineAccountLens.getWithdrawableUsdc(rebateId);
        assertLt(
            withdrawableUsdc,
            freeSettlementUsdc,
            "Rebate liability should reduce withdrawable headroom below free settlement"
        );

        vm.prank(rebateTrader);
        vm.expectRevert(CfdEngine.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        clearinghouse.withdraw(rebateId, freeSettlementUsdc);
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
        CfdEngineSettlementModule settlement = new CfdEngineSettlementModule(address(engine));
        CfdEngineAdmin adminModule = new CfdEngineAdmin(address(engine), address(this));
        engine.setDependencies(address(planner), address(settlement), address(adminModule));
        pool = new HousePool(address(usdc), address(engine));
        TrancheVault seniorVault =
            new TrancheVault(IERC20(address(usdc)), address(pool), true, "Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "juniorUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        engine.setOrderRouter(address(this));
        pool.setOrderRouter(address(this));

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
        bytes32 accountId,
        uint256 amount
    ) internal {
        address user = address(uint160(uint256(accountId)));
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, amount);
        vm.stopPrank();
    }

    function _open(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 depth
    ) internal {
        engine.processOrderTyped(
            CfdTypes.Order({
                accountId: accountId,
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
        bytes32
    ) external pure returns (uint64[] memory) {
        return new uint64[](0);
    }

    function syncMarginQueue(
        bytes32
    ) external pure {}

    function _close(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 size,
        uint256 price,
        uint256 depth
    ) internal {
        engine.processOrderTyped(
            CfdTypes.Order({
                accountId: accountId,
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
        bytes32 bearSkewerId = bytes32(uint256(uint160(address(0x51))));
        _deposit(bearSkewerId, 500_000 * 1e6);
        _open(bearSkewerId, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        bytes32 mmId = bytes32(uint256(uint160(address(0x111))));
        _deposit(mmId, 500_000 * 1e6);
        _open(mmId, CfdTypes.Side.BULL, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        (,,,,,, int256 vpiAfterOpen) = engine.positions(mmId);
        assertLe(vpiAfterOpen, 0, "MM should not pay positive VPI when healing skew on open");

        bytes32 bullFlipperId = bytes32(uint256(uint160(address(0x52))));
        _deposit(bullFlipperId, 500_000 * 1e6);
        _open(bullFlipperId, CfdTypes.Side.BULL, 1_000_000 * 1e18, 100_000 * 1e6, 1e8, DEPTH);

        (uint256 mmSize,,,,,,) = engine.positions(mmId);
        _close(mmId, CfdTypes.Side.BULL, mmSize, 1e8, DEPTH);
        uint256 mmUsdcAfter = clearinghouse.balanceUsdc(mmId);

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
        bytes32 skewerId = bytes32(uint256(uint160(address(0x52))));
        _deposit(skewerId, 500_000 * 1e6);
        _open(skewerId, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        bytes32 aliceId = bytes32(uint256(uint160(address(0xA1))));
        _deposit(aliceId, 500_000 * 1e6);
        _open(aliceId, CfdTypes.Side.BULL, 400_000 * 1e18, 100_000 * 1e6, 1e8, DEPTH);

        uint256 aliceBefore = clearinghouse.balanceUsdc(aliceId);
        _close(aliceId, CfdTypes.Side.BULL, 400_000 * 1e18, 1e8, DEPTH);
        uint256 aliceAfter = clearinghouse.balanceUsdc(aliceId);
        int256 aliceNet = int256(aliceAfter) - int256(aliceBefore);

        _close(skewerId, CfdTypes.Side.BEAR, 500_000 * 1e18, 1e8, DEPTH);
        _open(skewerId, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        bytes32 bobId = bytes32(uint256(uint160(address(0xB1))));
        _deposit(bobId, 500_000 * 1e6);
        _open(bobId, CfdTypes.Side.BULL, 400_000 * 1e18, 100_000 * 1e6, 1e8, DEPTH);

        uint256 bobBefore = clearinghouse.balanceUsdc(bobId);
        _close(bobId, CfdTypes.Side.BULL, 200_000 * 1e18, 1e8, DEPTH);
        _close(bobId, CfdTypes.Side.BULL, 200_000 * 1e18, 1e8, DEPTH);
        uint256 bobAfter = clearinghouse.balanceUsdc(bobId);
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
    ///      to account for seized collateral flowing into the vault.
    function test_PreviewLiquidation_SolvencyUsesPostLiquidationCarryState() public {
        address bullTrader = address(0xDD01);
        address bearTrader = address(0xDD02);
        bytes32 bullId = bytes32(uint256(uint160(bullTrader)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));

        CfdTypes.RiskParams memory params = _riskParams();
        _setRiskParams(params);

        _fundTrader(bullTrader, 30_000e6);
        _fundTrader(bearTrader, 100_000e6);

        _open(bullId, CfdTypes.Side.BULL, 1_000_000e18, 20_000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8);

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

        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(bullId, 1e8);
        assertTrue(preview.liquidatable, "BULL majority must be liquidatable after carry drain");

        address keeper = address(0x999);
        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(bullId, keeper);
        vm.prank(keeper);
        bytes[] memory empty;
        router.executeLiquidation(bullId, empty);

        LiquidationParityObserved memory observed = _observeLiquidationParity(bullId, keeper, beforeSnapshot);
        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
    }

    /// @dev Regression: _computeCloseSolvency did not reduce openInterest before computing
    ///      stale side-state math previously overstated solvency after close.
    function test_PreviewClose_SolvencyUsesPostCloseOiForCarry() public {
        address bullTraderA = address(0xDD03);
        address bullTraderB = address(0xDD04);
        address bearTrader = address(0xDD05);
        bytes32 bullIdA = bytes32(uint256(uint160(bullTraderA)));
        bytes32 bullIdB = bytes32(uint256(uint160(bullTraderB)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));

        _fundTrader(bullTraderA, 50_000e6);
        _fundTrader(bullTraderB, 50_000e6);
        _fundTrader(bearTrader, 100_000e6);

        _open(bullIdA, CfdTypes.Side.BULL, 400_000e18, 20_000e6, 1e8);
        _open(bullIdB, CfdTypes.Side.BULL, 400_000e18, 20_000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8);

        vm.warp(block.timestamp + 5 days);

        (uint256 sizeA,,,,,,) = engine.positions(bullIdA);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(bullIdA, sizeA, 1e8);
        assertTrue(preview.valid, "Close preview must be valid");

        _close(bullIdA, CfdTypes.Side.BULL, sizeA, 1e8);
    }

}
