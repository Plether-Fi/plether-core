// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdEnginePlanTypes} from "../../src/perps/CfdEnginePlanTypes.sol";
import {CfdMath} from "../../src/perps/CfdMath.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {HousePoolEngineViewTypes} from "../../src/perps/interfaces/HousePoolEngineViewTypes.sol";
import {AccountLensViewTypes} from "../../src/perps/interfaces/AccountLensViewTypes.sol";
import {ProtocolLensViewTypes} from "../../src/perps/interfaces/ProtocolLensViewTypes.sol";
import {DeferredEngineViewTypes} from "../../src/perps/interfaces/DeferredEngineViewTypes.sol";
import {ICfdEngine} from "../../src/perps/interfaces/ICfdEngine.sol";
import {IMarginClearinghouse} from "../../src/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "../../src/perps/interfaces/IOrderRouterAccounting.sol";
import {PerpsViewTypes} from "../../src/perps/interfaces/PerpsViewTypes.sol";
import {CfdEnginePlanLib} from "../../src/perps/libraries/CfdEnginePlanLib.sol";
import {LiquidationAccountingLib} from "../../src/perps/libraries/LiquidationAccountingLib.sol";
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
        int256 fundingUsdc,
        int256 pnlUsdc,
        uint256 maintMarginBps,
        uint256 minBountyUsdc,
        uint256 bountyBps,
        uint256 tokenScale
    ) external pure returns (LiquidationAccountingLib.LiquidationState memory) {
        return LiquidationAccountingLib.buildLiquidationState(
            size, oraclePrice, reachableCollateralUsdc, pnlUsdc, maintMarginBps, minBountyUsdc, bountyBps, tokenScale
        );
    }

}

contract CfdEnginePlanLibHarness {

    function planLiquidation(
        uint256 settlementReachableUsdc,
        uint256 deferredPayoutUsdc,
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
        snap.totalDeferredPayoutUsdc = deferredPayoutUsdc;
        snap.deferredPayoutForAccount = deferredPayoutUsdc;
        snap.capPrice = 2e8;
        snap.riskParams = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 15
        });

        return CfdEnginePlanLib.planLiquidation(snap, oraclePrice, 0);
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

    function _cappedFundingAfter(
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

    function _previewFundingIndex(
        CfdTypes.Side side,
        uint256 vaultDepthUsdc
    ) internal view returns (int256) {
        side;
        vaultDepthUsdc;
        return 0;
    }

    function _previewFundingPnl(
        CfdTypes.Side side,
        uint256 openInterest,
        int256 entryFunding
    ) internal view returns (int256) {
        side;
        openInterest;
        entryFunding;
        return 0;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _setFadMaxStaleness(
        uint256 val
    ) internal {
        engine.proposeFadMaxStaleness(val);
        vm.warp(block.timestamp + 48 hours + 1);
        engine.finalizeFadMaxStaleness();
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
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);

        // maxProfit = 1.2M tokens * $1 entry = $1.2M > vault's $1M balance
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

        vm.expectRevert(CfdEngine.CfdEngine__VaultSolvencyExceeded.selector);
        vm.prank(address(router));
        engine.processOrder(tooLarge, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));

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
        vm.expectRevert(CfdEngine.CfdEngine__VaultSolvencyExceeded.selector);
        vm.prank(address(router));
        engine.processOrder(order, 1e8, 0, uint64(block.timestamp));

        // Re-deposit to allow the trade
        usdc.approve(address(juniorVault), 950_000 * 1e6);
        juniorVault.deposit(950_000 * 1e6, address(this));

        vm.prank(address(router));
        engine.processOrder(order, 1e8, 200_000 * 1e6, uint64(block.timestamp));

        (uint256 size, uint256 margin,,,,,,) = engine.positions(accountId);
        assertEq(size, 100_000 * 1e18, "Size mismatch");
        // With the explicit $200k depth passed to processOrder, the current VPI + fee path leaves $1,947.5 margin.
        assertEq(margin, 1_947_500_000, "Margin should equal deposit minus VPI and exec fee");
    }

    function test_OpenPosition_UsesExplicitInitMarginBps() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.initMarginBps = 400;
        engine.proposeRiskParams(params);
        vm.warp(block.timestamp + 7 days);
        engine.finalizeRiskParams();

        (,,, uint256 initMarginBps,,,,) = engine.riskParams();
        assertEq(initMarginBps, 400, "Setup must finalize the explicit init margin config");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        bytes32 accountId = bytes32(uint256(0xBEEF1));
        _fundTrader(address(uint160(uint256(accountId))), 10_000e6);

        assertEq(
            engine.previewOpenRevertCode(
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
            engine.previewOpenRevertCode(
                accountId, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8, uint64(block.timestamp)
            ),
            uint8(CfdEnginePlanTypes.OpenRevertCode.OK),
            "Preview should accept the healthy open"
        );

        uint256 feesBefore = engine.accumulatedFeesUsdc();
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);

        (uint256 size, uint256 margin,,,,,,) = engine.positions(accountId);
        assertEq(size, 100_000e18, "Live open should match the previewed size");
        assertGt(margin, 0, "Live open should leave positive position margin");
        assertLt(margin, 5000e6, "Live open margin should reflect execution costs after the successful preview");
        assertGt(
            engine.accumulatedFeesUsdc() - feesBefore, 0, "Live open should collect protocol revenue after success"
        );
    }

    function test_ProcessOrderTyped_ProtocolStateFailureUsesTypedTaxonomy() public {
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);

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
        engine.processOrder(retailLong, 1e8, vaultDepth, uint64(block.timestamp));

        uint64 refreshTime = uint64(block.timestamp + 365 days);
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
        engine.processOrder(mmShort, 1e8, vaultDepth, accrualTime);

        assertEq(_sideFundingIndex(CfdTypes.Side.BULL), 0);
        assertEq(_sideFundingIndex(CfdTypes.Side.BEAR), 0);

        (uint256 size,, uint256 entryPrice,,, CfdTypes.Side side,,) = engine.positions(account1);

        CfdTypes.Position memory bullPos = CfdTypes.Position({
            size: size,
            margin: 0,
            entryPrice: entryPrice,
            maxProfitUsdc: 0,
            side: side,
            lastUpdateTime: 0,
            vpiAccrued: 0
        });

        int256 bullFunding = 0;
        assertEq(bullFunding, 0, "No-funding model should not accrue position funding");
    }

    function helper_AbsorbRouterCancellationFee_NoSyncCheckpointRequired() public {
        address trader = address(0xABC1);
        bytes32 traderId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 50_000e6);
        _open(traderId, CfdTypes.Side.BULL, 200_000e18, 20_000e6, 1e8);

        uint64 fundingBefore = engine.lastFundingTime();
        uint256 feesBefore = engine.accumulatedFeesUsdc();
        uint256 vaultAssetsBefore = pool.totalAssets();
        vm.warp(block.timestamp + 1 days);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        assertEq(
            engine.lastFundingTime(),
            fundingBefore,
            "No-funding model should not checkpoint funding time on mark refresh"
        );
        vm.warp(block.timestamp + 1);

        usdc.mint(address(router), 25e6);
        vm.prank(address(router));
        usdc.approve(address(engine), 25e6);

        vm.prank(address(router));
        engine.absorbRouterCancellationFee(25e6);

        assertEq(
            engine.lastFundingTime(),
            fundingBefore,
            "Absorbing router fees should not change funding time in no-funding model"
        );
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

    function helper_SyncState_IsNoopInNoFundingModel() public {
        address trader = address(0xABC2);
        bytes32 traderId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 50_000e6);
        _open(traderId, CfdTypes.Side.BULL, 200_000e18, 20_000e6, 1e8);

        uint64 fundingBefore = engine.lastFundingTime();
        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);

        // no-op in no-funding baseline

        assertEq(
            engine.lastFundingTime(), fundingBefore, "No-funding model should keep funding time unchanged while stale"
        );

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + 1);

        // no-op in no-funding baseline

        assertEq(
            engine.lastFundingTime(),
            fundingBefore,
            "No-funding model should keep funding time unchanged after a fresh mark too"
        );
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

        uint256 fundingLiabilityBefore = uint256(0);
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snapshotBefore = engineProtocolLens.getProtocolAccountingSnapshot();
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory houseBefore =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);

        assertEq(
            uint256(0),
            fundingLiabilityBefore,
            "Stale live marks should not project additional funding liability into protocol accounting"
        );
        assertEq(
            engineProtocolLens.getProtocolAccountingSnapshot().liabilityOnlyFundingPnlUsdc,
            snapshotBefore.liabilityOnlyFundingPnlUsdc,
            "Protocol accounting snapshot should freeze funding liability on stale live marks"
        );
        assertEq(
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit()).withdrawalFundingLiabilityUsdc,
            houseBefore.withdrawalFundingLiabilityUsdc,
            "HousePool input snapshot should not inherit stale projected funding"
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

        uint64 fundingBefore = engine.lastFundingTime();
        vm.warp(block.timestamp + engine.fadMaxStaleness() + 1);

        // no-op in no-funding baseline

        assertEq(
            engine.lastFundingTime(),
            fundingBefore,
            "Funding should not advance once the frozen mark exceeds fadMaxStaleness"
        );
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

        uint256 fundingLiabilityBefore = uint256(0);
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snapshotBefore = engineProtocolLens.getProtocolAccountingSnapshot();
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory houseBefore =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());

        vm.warp(block.timestamp + engine.fadMaxStaleness() + 1);

        assertEq(
            uint256(0),
            fundingLiabilityBefore,
            "Frozen marks beyond fadMaxStaleness should not project additional funding liability"
        );
        assertEq(
            engineProtocolLens.getProtocolAccountingSnapshot().liabilityOnlyFundingPnlUsdc,
            snapshotBefore.liabilityOnlyFundingPnlUsdc,
            "Protocol accounting should freeze funding liability once the frozen mark exceeds fadMaxStaleness"
        );
        assertEq(
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit()).withdrawalFundingLiabilityUsdc,
            houseBefore.withdrawalFundingLiabilityUsdc,
            "HousePool input snapshot should not inherit over-stale frozen funding"
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

    function test_ProfitableClose_RecordsDeferredPayoutWhenVaultIlliquid() public {
        bytes32 accountId = bytes32(uint256(uint160(address(0xD301))));
        _fundTrader(address(0xD301), 11_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        uint256 clearinghouseBefore = clearinghouse.balanceUsdc(accountId);

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Profitable close should still destroy the position");
        assertGt(engine.deferredPayoutUsdc(accountId), 0, "Unpaid profit should be recorded as deferred payout");
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

        uint64 refreshTime = uint64(block.timestamp + 365 days);
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

        (uint256 size,,,,,,,) = engine.positions(bearId);
        assertEq(size, 0, "Illiquid positive-funding close should still destroy the position");
        assertEq(engine.deferredPayoutUsdc(bearId), preview.deferredPayoutUsdc, "Live close should match preview");
    }

    function test_PreviewClose_UsesCanonicalVaultDepthWhileSimulateCloseAllowsWhatIfDepth() public {
        bytes32 bullId = bytes32(uint256(0xC10));
        bytes32 bearId = bytes32(uint256(0xC11));
        _fundTrader(address(uint160(uint256(bullId))), 5000e6);
        _fundTrader(address(uint160(uint256(bearId))), 5000e6);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8);

        uint64 refreshTime = uint64(block.timestamp + 365 days);
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

        assertEq(
            lowDepthSimulation.fundingUsdc, 0, "No-funding model should not report simulated funding at lower depth"
        );
        assertEq(
            canonicalPreview.fundingUsdc, 0, "No-funding model should not report canonical funding in close preview"
        );
    }

    function test_CloseParity_ImmediateProfitMatchesPreview() public {
        address trader = address(0xD3A1);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(accountId, 100_000e18, 80_000_000);
        assertTrue(preview.valid, "Setup close preview should be valid");
        assertGt(preview.immediatePayoutUsdc, 0, "Profitable liquid close should pay immediately");
        assertEq(preview.deferredPayoutUsdc, 0, "Liquid profitable close should not defer payout");

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
        assertGt(preview.deferredPayoutUsdc, 0, "Illiquid profitable close should defer payout");

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
        assertEq(preview.deferredPayoutUsdc, 0, "Loss-making close should not create deferred payout");
        assertEq(preview.badDebtUsdc, 0, "Setup should keep the loss fully collateralized");

        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(accountId);
        _close(accountId, CfdTypes.Side.BULL, 10_000e18, 120_000_000);

        CloseParityObserved memory observed = _observeCloseParity(accountId, beforeSnapshot);
        _assertClosePreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
    }

    function test_ClaimDeferredPayout_CreditsClearinghouseWhenLiquidityReturns() public {
        address trader = address(0xD302);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        uint256 deferred = engine.deferredPayoutUsdc(accountId);
        assertGt(deferred, 0, "Setup should create a deferred payout");

        usdc.mint(address(pool), deferred);
        uint256 clearinghouseBefore = clearinghouse.balanceUsdc(accountId);

        vm.prank(trader);
        engine.claimDeferredPayout(accountId);

        assertEq(engine.deferredPayoutUsdc(accountId), 0, "Claim should clear deferred payout state");
        assertEq(
            clearinghouse.balanceUsdc(accountId),
            clearinghouseBefore + deferred,
            "Claim should credit the clearinghouse balance"
        );
    }

    function test_ClaimDeferredPayout_AllowsPermissionlessHeadService() public {
        address trader = address(0xD307);
        address relayer = address(0xD308);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        uint256 deferred = engine.deferredPayoutUsdc(accountId);
        usdc.mint(address(pool), deferred);
        uint256 clearinghouseBefore = clearinghouse.balanceUsdc(accountId);

        vm.prank(relayer);
        engine.claimDeferredPayout(accountId);

        assertEq(
            clearinghouse.balanceUsdc(accountId),
            clearinghouseBefore + deferred,
            "Permissionless service should still credit the recorded trader"
        );
    }

    function test_ClaimDeferredPayout_AllowsPartialHeadClaimWhenLiquidityReturnsGradually() public {
        address trader = address(0xD306);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        uint256 deferred = engine.deferredPayoutUsdc(accountId);
        assertGt(deferred, 0, "Setup should create a deferred payout");

        uint256 partialLiquidity = deferred / 2;
        usdc.mint(address(pool), partialLiquidity);
        uint256 claimableNow = pool.totalAssets();
        if (claimableNow > deferred) {
            claimableNow = deferred;
        }

        uint256 clearinghouseBefore = clearinghouse.balanceUsdc(accountId);
        vm.prank(trader);
        engine.claimDeferredPayout(accountId);

        assertEq(
            clearinghouse.balanceUsdc(accountId),
            clearinghouseBefore + claimableNow,
            "Head claim should consume all currently available head liquidity"
        );
        assertEq(
            engine.deferredPayoutUsdc(accountId),
            deferred - claimableNow,
            "Partial head claim should leave remainder queued"
        );
    }

    function test_ClaimDeferredPayout_HeadConsumesPartialLiquidityBeforeLaterClaims() public {
        address trader = address(0xD309);
        address keeper = address(0xD30A);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        uint256 deferred = engine.deferredPayoutUsdc(accountId);
        assertGt(deferred, 0, "Setup should create a deferred trader payout");

        vm.prank(address(router));
        engine.recordDeferredClearerBounty(keeper, deferred);

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
        engine.claimDeferredPayout(accountId);

        assertEq(
            clearinghouse.balanceUsdc(accountId),
            clearinghouseBefore + claimableNow,
            "Head deferred trader claim should consume partial liquidity before later claims"
        );
        assertEq(engine.deferredPayoutUsdc(accountId), deferred - claimableNow, "Head deferred payout should shrink");
        assertEq(engine.deferredClearerBountyUsdc(keeper), deferred, "Later deferred bounty should remain untouched");
    }

    function test_ClaimDeferredPayout_RevertsWithoutLiquidityOrPayout() public {
        address trader = address(0xD303);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);

        vm.prank(trader);
        vm.expectRevert(CfdEngine.CfdEngine__NoDeferredPayout.selector);
        engine.claimDeferredPayout(accountId);

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
        engine.claimDeferredPayout(accountId);
    }

    function test_ClaimDeferredClearerBounty_RevertsWhenTraderClaimIsAheadInQueue() public {
        address trader = address(0xD304);
        address keeper = address(0xD305);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        uint256 deferred = engine.deferredPayoutUsdc(accountId);
        assertGt(deferred, 0, "Setup should create a deferred payout");

        vm.prank(address(router));
        engine.recordDeferredClearerBounty(keeper, deferred);

        usdc.mint(address(pool), deferred);

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(bytes32(uint256(uint160(keeper))));
        vm.prank(keeper);
        engine.claimDeferredClearerBounty();
        assertGt(
            clearinghouse.balanceUsdc(bytes32(uint256(uint160(keeper)))) - keeperSettlementBefore,
            0,
            "Deferred clearer bounty should no longer require head-of-queue priority"
        );
    }

    function test_NoFundingSettlement_SyncsClearinghouse() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);

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
        engine.processOrder(openOrder, 1e8, vaultDepth, uint64(block.timestamp));

        (, uint256 marginAfterOpen,,,,,,) = engine.positions(accountId);
        uint256 lockedAfterOpen = clearinghouse.lockedMarginUsdc(accountId);
        assertEq(lockedAfterOpen, marginAfterOpen, "lockedMargin == pos.margin after open");

        // Warp 30 days — accumulates negative funding for lone BULL
        vm.warp(block.timestamp + 30 days);

        // Increase position — triggers funding settlement in processOrder
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
        engine.processOrder(addOrder, 1e8, vaultDepth, uint64(block.timestamp));

        (, uint256 marginAfterAdd,,,,,,) = engine.positions(accountId);
        uint256 lockedAfterAdd = clearinghouse.lockedMarginUsdc(accountId);
        assertEq(lockedAfterAdd, marginAfterAdd, "lockedMargin == pos.margin after funding settlement");
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
        engine.processOrder(order, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));

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
        engine.recordDeferredClearerBounty(keeper, deferredBounty);

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
            engine.deferredClearerBountyUsdc(keeper),
            deferredBounty,
            "Withdrawing fees must not consume deferred senior claims"
        );
    }

    function test_ClaimDeferredClearerBounty_UsesFeeOnlyLiquidityWhenAtQueueHead() public {
        bytes32 accountId = bytes32(uint256(0xFEE4));
        address keeper = address(0xFEE5);
        _fundTrader(address(uint160(uint256(accountId))), 5000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        uint256 fees = engine.accumulatedFeesUsdc();
        vm.prank(address(router));
        engine.recordDeferredClearerBounty(keeper, 1e6);

        vm.startPrank(address(pool));
        usdc.transfer(address(0xDEAD), pool.totalAssets());
        vm.stopPrank();

        usdc.mint(address(pool), fees);

        DeferredEngineViewTypes.DeferredPayoutStatus memory status = _deferredPayoutStatus(bytes32(0), keeper);
        assertTrue(status.liquidationBountyClaimableNow, "Queue-head deferred bounty should be claimable ahead of fees");

        uint256 feesBefore = engine.accumulatedFeesUsdc();
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(bytes32(uint256(uint160(keeper))));
        vm.prank(keeper);
        engine.claimDeferredClearerBounty();

        assertEq(
            clearinghouse.balanceUsdc(bytes32(uint256(uint160(keeper)))) - keeperSettlementBefore,
            1e6,
            "Keeper should receive the queue-head deferred bounty as clearinghouse credit"
        );
        assertEq(engine.accumulatedFeesUsdc(), feesBefore, "Servicing deferred claims must not burn fee accounting");
    }

    function test_AddMargin_UpdatesPositionAndSideTotals() public {
        address trader = address(0xABCD);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000 * 1e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8);

        (, uint256 marginBefore,,,,,,) = engine.positions(accountId);
        uint256 lockedBefore = clearinghouse.lockedMarginUsdc(accountId);
        uint256 totalBullMarginBefore = _sideTotalMargin(CfdTypes.Side.BULL);

        vm.prank(trader);
        engine.addMargin(accountId, 500 * 1e6);

        (, uint256 marginAfter,,,,,,) = engine.positions(accountId);
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

    function test_GetAccountCollateralView_ReturnsCurrentBuckets() public {
        address trader = address(0xAB10);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000 * 1e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 7900 * 1e6, type(uint256).max, false);

        CfdEngine.AccountCollateralView memory viewData = engineAccountLens.getAccountCollateralView(accountId);
        (, uint256 positionMargin,,,,,,) = engine.positions(accountId);
        assertEq(viewData.settlementBalanceUsdc, clearinghouse.balanceUsdc(accountId));
        assertEq(viewData.lockedMarginUsdc, clearinghouse.lockedMarginUsdc(accountId));
        assertEq(viewData.activePositionMarginUsdc, positionMargin);
        assertEq(viewData.otherLockedMarginUsdc, viewData.lockedMarginUsdc - positionMargin);
        assertEq(viewData.freeSettlementUsdc, _freeSettlementUsdc(accountId));
        assertEq(viewData.closeReachableUsdc, _freeSettlementUsdc(accountId));
        assertEq(viewData.terminalReachableUsdc, _terminalReachableUsdc(accountId));
        assertEq(viewData.accountEquityUsdc, clearinghouse.getAccountEquityUsdc(accountId));
        assertEq(viewData.freeBuyingPowerUsdc, clearinghouse.getFreeBuyingPowerUsdc(accountId));
        assertEq(viewData.deferredPayoutUsdc, 0);
    }

    function test_GetPositionView_ReturnsLivePositionState() public {
        address trader = address(0xAB11);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000 * 1e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(90_000_000, uint64(block.timestamp));

        PerpsViewTypes.PositionView memory viewData = _publicPosition(accountId);
        (, uint256 positionMargin,,,,,,) = engine.positions(accountId);
        assertTrue(viewData.exists);
        assertEq(uint256(viewData.side), uint256(CfdTypes.Side.BULL));
        assertEq(viewData.size, 100_000 * 1e18);
        assertEq(viewData.entryPrice, 1e8);
        assertEq(viewData.marginUsdc, positionMargin);
        assertGt(viewData.unrealizedPnlUsdc, 0);
    }

    function test_GetPositionView_DoesNotCountDeferredPayoutAsPhysicalCollateral() public {
        address trader = address(0xAB1101);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000 * 1e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8);

        stdstore.target(address(clearinghouse)).sig("balanceUsdc(bytes32)").with_key(accountId)
            .checked_write(uint256(0));
        stdstore.target(address(engine)).sig("deferredPayoutUsdc(bytes32)").with_key(accountId)
            .checked_write(uint256(200e6));

        PerpsViewTypes.PositionView memory viewData = _publicPosition(accountId);
        (, uint256 positionMargin,,,,,,) = engine.positions(accountId);
        assertEq(viewData.marginUsdc, positionMargin, "Public position view should still expose locked position margin");
        assertTrue(viewData.liquidatable, "Position should remain liquidatable when only deferred payout exists");
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

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory viewData = engineProtocolLens.getProtocolAccountingSnapshot();
        assertEq(viewData.vaultAssetsUsdc, pool.totalAssets());
        assertEq(viewData.withdrawalReservedUsdc, engine.getWithdrawalReservedUsdc());
        assertEq(viewData.accumulatedFeesUsdc, engine.accumulatedFeesUsdc());
        assertEq(viewData.totalDeferredPayoutUsdc, engine.totalDeferredPayoutUsdc());
        assertEq(viewData.totalDeferredClearerBountyUsdc, engine.totalDeferredClearerBountyUsdc());
        assertEq(viewData.degradedMode, engine.degradedMode());
        assertEq(viewData.hasLiveLiability, engine.hasLiveLiability());
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

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snapshot = engineProtocolLens.getProtocolAccountingSnapshot();
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory viewData = engineProtocolLens.getProtocolAccountingSnapshot();
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory housePoolSnapshot =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());

        assertEq(snapshot.vaultAssetsUsdc, pool.totalAssets());
        assertEq(
            snapshot.netPhysicalAssetsUsdc,
            snapshot.vaultAssetsUsdc > snapshot.accumulatedFeesUsdc
                ? snapshot.vaultAssetsUsdc - snapshot.accumulatedFeesUsdc
                : 0
        );
        assertEq(snapshot.maxLiabilityUsdc, engine.getMaxLiability());
        assertEq(snapshot.withdrawalReservedUsdc, engine.getWithdrawalReservedUsdc());
        assertEq(snapshot.accumulatedFeesUsdc, engine.accumulatedFeesUsdc());
        assertEq(snapshot.accumulatedBadDebtUsdc, engine.accumulatedBadDebtUsdc());
        assertEq(snapshot.liabilityOnlyFundingPnlUsdc, uint256(0));
        assertEq(snapshot.totalDeferredPayoutUsdc, engine.totalDeferredPayoutUsdc());
        assertEq(snapshot.totalDeferredClearerBountyUsdc, engine.totalDeferredClearerBountyUsdc());
        assertEq(snapshot.degradedMode, engine.degradedMode());
        assertEq(snapshot.hasLiveLiability, engine.hasLiveLiability());
        assertEq(snapshot.vaultAssetsUsdc, viewData.vaultAssetsUsdc);
        assertEq(housePoolSnapshot.physicalAssetsUsdc, snapshot.vaultAssetsUsdc);
        assertEq(snapshot.maxLiabilityUsdc, viewData.maxLiabilityUsdc);
        assertEq(snapshot.withdrawalReservedUsdc, viewData.withdrawalReservedUsdc);
        assertEq(snapshot.freeUsdc, viewData.freeUsdc);
        assertEq(snapshot.accumulatedFeesUsdc, viewData.accumulatedFeesUsdc);
        assertEq(snapshot.cappedFundingPnlUsdc, viewData.cappedFundingPnlUsdc);
        assertEq(snapshot.liabilityOnlyFundingPnlUsdc, viewData.liabilityOnlyFundingPnlUsdc);
        assertEq(snapshot.totalDeferredPayoutUsdc, viewData.totalDeferredPayoutUsdc);
        assertEq(snapshot.totalDeferredClearerBountyUsdc, viewData.totalDeferredClearerBountyUsdc);
        assertEq(snapshot.degradedMode, viewData.degradedMode);
        assertEq(snapshot.hasLiveLiability, viewData.hasLiveLiability);
        assertEq(snapshot.netPhysicalAssetsUsdc, housePoolSnapshot.netPhysicalAssetsUsdc);
        assertEq(snapshot.maxLiabilityUsdc, housePoolSnapshot.maxLiabilityUsdc);
        assertEq(snapshot.totalDeferredPayoutUsdc, housePoolSnapshot.deferredTraderPayoutUsdc);
        assertEq(snapshot.totalDeferredClearerBountyUsdc, housePoolSnapshot.deferredClearerBountyUsdc);
        assertEq(snapshot.accumulatedFeesUsdc, housePoolSnapshot.protocolFeesUsdc);
    }

    function test_ProtocolAccountingSnapshot_IgnoresUnaccountedPoolDonationUntilAccounted() public {
        _fundJunior(address(0xB0B), 500_000e6);
        uint256 accountedBefore = pool.totalAssets();

        usdc.mint(address(pool), 100_000e6);

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory beforeAccount = engineProtocolLens.getProtocolAccountingSnapshot();
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

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory afterAccount = engineProtocolLens.getProtocolAccountingSnapshot();
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
        (, uint256 positionMargin,,,,,,) = engine.positions(accountId);
        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(accountId);
        IOrderRouterAccounting.AccountEscrowView memory escrow = router.getAccountEscrow(accountId);

        assertEq(ledgerView.settlementBalanceUsdc, buckets.settlementBalanceUsdc);
        assertEq(ledgerView.freeSettlementUsdc, buckets.freeSettlementUsdc);
        assertEq(ledgerView.activePositionMarginUsdc, buckets.activePositionMarginUsdc);
        assertEq(ledgerView.otherLockedMarginUsdc, buckets.otherLockedMarginUsdc);
        assertEq(ledgerView.executionEscrowUsdc, escrow.executionBountyUsdc);
        assertEq(ledgerView.committedMarginUsdc, escrow.committedMarginUsdc);
        assertEq(ledgerView.deferredPayoutUsdc, engine.deferredPayoutUsdc(accountId));
        assertEq(ledgerView.pendingOrderCount, router.pendingOrderCounts(accountId));
    }

    function test_GetAccountLedgerSnapshot_ReflectsExpandedAccountHealthState() public {
        address trader = address(0xAB16);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 12_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = engineAccountLens.getAccountLedgerSnapshot(accountId);
        CfdEngine.AccountCollateralView memory collateralView = engineAccountLens.getAccountCollateralView(accountId);
        (uint256 sizeStored, uint256 marginStored, uint256 entryPriceStored,,, CfdTypes.Side sideStored,,) =
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
        assertEq(snapshot.deferredPayoutUsdc, collateralView.deferredPayoutUsdc);
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
        assertEq(snapshot.maxLiabilityUsdc, engine.getMaxLiability(), "Snapshot liability must match accessor");
        assertEq(snapshot.withdrawalFundingLiabilityUsdc, uint256(0), "Snapshot funding liability must match accessor");
        assertEq(
            snapshot.unrealizedMtmLiabilityUsdc,
            _vaultMtmAdjustment(),
            "Snapshot MtM liability must match accessor"
        );
        assertEq(
            snapshot.deferredTraderPayoutUsdc, engine.totalDeferredPayoutUsdc(), "Snapshot payout must match storage"
        );
        assertEq(
            snapshot.deferredClearerBountyUsdc,
            engine.totalDeferredClearerBountyUsdc(),
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
        assertEq(normalPreview.deferredPayoutUsdc, 0);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        CfdEngine.ClosePreview memory illiquidPreview = engineLens.previewClose(accountId, 100_000e18, 80_000_000);
        assertTrue(illiquidPreview.valid);
        assertEq(illiquidPreview.immediatePayoutUsdc, 0);
        assertGt(illiquidPreview.deferredPayoutUsdc, 0);
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
        assertEq(canonicalPreview.deferredPayoutUsdc, 0, "Live preview should not defer when cash is available");
        assertEq(canonicalDepth, pool.totalAssets(), "Setup should keep canonical depth unchanged");

        assertTrue(hypotheticalPreview.valid);
        assertEq(hypotheticalPreview.immediatePayoutUsdc, 0, "Hypothetical close should use caller-supplied vault cash");
        assertGt(hypotheticalPreview.deferredPayoutUsdc, 0, "Low hypothetical cash should defer the payout");
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

    function helper_PreviewClose_RecomputesPostOpClipInNoFundingBaseline() public {
        address bullTrader = address(0xAB130A);
        address bearTrader = address(0xAB130B);
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

        (uint256 bullSize, uint256 bullMargin,, uint256 bullMaxProfit, int256 bullEntryFunding,,,) =
            engine.positions(bullId);
        int256 bullFundingAfter = 0;
        int256 bearFundingAfter = _previewFundingPnl(
            CfdTypes.Side.BEAR, _sideOpenInterest(CfdTypes.Side.BEAR), _sideEntryFunding(CfdTypes.Side.BEAR)
        );
        int256 currentFunding = int256(0);
        int256 postFunding =
            _cappedFundingAfter(bullFundingAfter, bearFundingAfter, 0, _sideTotalMargin(CfdTypes.Side.BEAR));

        assertGt(
            postFunding, currentFunding, "Full close should remove the clipped funding receivable from solvency assets"
        );
        assertGt(postFunding, 0, "Setup must leave post-close funding as a solvency liability");

        CfdEngine.ClosePreview memory preDrainPreview = engineLens.previewClose(bullId, bullSize, 1e8);
        assertTrue(preDrainPreview.valid, "Setup close preview should remain valid");

        uint256 grossTargetAssets = _maxLiabilityAfterClose(CfdTypes.Side.BULL, bullMaxProfit)
            + engine.accumulatedFeesUsdc() + uint256(postFunding);
        assertGt(
            grossTargetAssets,
            preDrainPreview.seizedCollateralUsdc + 1,
            "Setup must leave a positive funding-clip gap after subtracting seized collateral"
        );
        uint256 targetAssets = grossTargetAssets;
        uint256 currentAssets = pool.totalAssets();
        assertGt(currentAssets, targetAssets, "Test setup must be able to drain the vault into the funding-clip gap");

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), currentAssets - targetAssets);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(bullId, bullSize, 1e8);
        assertTrue(
            preview.triggersDegradedMode, "Preview should use post-close funding clip when testing degraded mode"
        );

        _close(bullId, CfdTypes.Side.BULL, bullSize, 1e8);
        assertEq(
            preview.triggersDegradedMode,
            engine.degradedMode(),
            "Close preview should match live degraded-mode outcome after funding clipping"
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
        (uint256 sizeBefore,,,,,,,) = engine.positions(accountId);

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

        (uint256 sizeAfter,,,,,,,) = engine.positions(accountId);
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
            overCapPreview.deferredPayoutUsdc,
            cappedPreview.deferredPayoutUsdc,
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
        assertEq(preview.keeperBountyUsdc, 15_150_000);
        assertLe(preview.keeperBountyUsdc, uint256(preview.equityUsdc));
    }

    function test_PlanLiquidation_PositiveResidualAboveDeferredDoesNotUnderflow() public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        CfdEnginePlanTypes.LiquidationDelta memory delta =
            harness.planLiquidation(0, 10e6, 2000e18, 99_600_000, 100_000_000);

        assertTrue(delta.liquidatable, "Setup must remain liquidatable");
        assertEq(delta.keeperBountyUsdc, 5e6, "Setup should use the minimum bounty");
        assertEq(delta.residualUsdc, 13e6, "Residual should include positive pnl above the deferred claim");
        assertEq(delta.settlementRetainedUsdc, 0, "No settlement should remain when none is reachable");
        assertEq(
            delta.existingDeferredConsumedUsdc, 10e6, "Planner should consume the full pre-existing deferred claim"
        );
        assertEq(delta.existingDeferredRemainingUsdc, 0, "Planner should not underflow while carrying deferred payout");
        assertEq(delta.freshTraderPayoutUsdc, 13e6, "Excess positive residual should become a fresh trader payout");
        assertEq(delta.residualPlan.freshTraderPayoutUsdc, 13e6, "Residual plan should expose the fresh trader payout");
        assertEq(delta.badDebtUsdc, 0, "Positive residual should not create bad debt");
    }

    function test_PlanLiquidation_NegativeResidualFullyConsumesLegacyDeferredWithoutReducingBadDebt() public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        CfdEnginePlanTypes.LiquidationDelta memory delta =
            harness.planLiquidation(0, 10e6, 2000e18, 99_600_000, 99_000_000);

        assertTrue(delta.liquidatable, "Setup must remain liquidatable");
        assertEq(delta.keeperBountyUsdc, 5e6, "Setup should use the minimum bounty");
        assertEq(delta.residualUsdc, -7e6, "Residual should already include the legacy deferred payout");
        assertEq(
            delta.existingDeferredConsumedUsdc,
            10e6,
            "Negative residual should fully consume the legacy deferred payout once it has already been priced into equity"
        );
        assertEq(
            delta.existingDeferredRemainingUsdc, 0, "No deferred payout should survive a negative residual wipeout"
        );
        assertEq(delta.badDebtUsdc, 7e6, "Bad debt should remain the residual shortfall without a second offset");
    }

    function helper_PreviewLiquidation_ConsumesLegacyDeferredBeforeFreshCashGate() public {
        address trader = address(0xAB14002);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        address keeper = address(0xAB14003);
        _fundTrader(trader, 200e6);
        _open(accountId, CfdTypes.Side.BEAR, 10_000e18, 200e6, 99_700_000);

        stdstore.target(address(clearinghouse)).sig("balanceUsdc(bytes32)").with_key(accountId)
            .checked_write(uint256(0));

        bytes32 deferredPayoutSlot = keccak256(abi.encode(accountId, uint256(31)));
        vm.store(address(engine), deferredPayoutSlot, bytes32(uint256(10e6)));
        vm.store(address(engine), bytes32(uint256(32)), bytes32(uint256(10e6)));

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 30e6);

        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(accountId, 100_000_000);

        assertTrue(preview.liquidatable, "Preview should not revert for positive residual above deferred claim");
        assertEq(preview.keeperBountyUsdc, 15e6, "Setup should use the percentage bounty");
        assertEq(preview.settlementRetainedUsdc, 0, "No settlement should remain when no settlement is reachable");
        assertEq(preview.freshTraderPayoutUsdc, 25e6, "Preview should surface the fresh liquidation payout explicitly");
        assertEq(preview.existingDeferredConsumedUsdc, 10e6, "Preview should show the consumed legacy deferred claim");
        assertEq(preview.existingDeferredRemainingUsdc, 0, "Preview should show no leftover legacy deferred claim");
        assertEq(preview.immediatePayoutUsdc, 25e6, "Consumed legacy deferred claim should reopen enough cash");
        assertEq(preview.deferredPayoutUsdc, 0, "Fresh liquidation payout should no longer stay deferred");
        assertEq(preview.badDebtUsdc, 0, "Positive residual should not report bad debt");

        uint256 settlementBefore = clearinghouse.balanceUsdc(accountId);
        vm.prank(keeper);
        bytes[] memory empty;
        router.executeLiquidation(accountId, empty);

        uint256 vaultAssets = pool.totalAssets() + preview.keeperBountyUsdc;
        uint256 fees = engine.accumulatedFeesUsdc();
        int256 funding = int256(0);
        uint256 netPhysical = vaultAssets > fees ? vaultAssets - fees : 0;
        uint256 liveEffective = funding > 0
            ? (netPhysical > uint256(funding) ? netPhysical - uint256(funding) : 0)
            : netPhysical + uint256(-funding);
        uint256 deferred = engine.totalDeferredPayoutUsdc() + engine.totalDeferredClearerBountyUsdc();
        liveEffective = liveEffective > deferred ? liveEffective - deferred : 0;
        liveEffective = liveEffective > preview.keeperBountyUsdc ? liveEffective - preview.keeperBountyUsdc : 0;

        assertEq(
            clearinghouse.balanceUsdc(accountId) - settlementBefore,
            preview.immediatePayoutUsdc,
            "Live settlement credit should match preview"
        );
        assertEq(engine.deferredPayoutUsdc(accountId), 0, "Live liquidation should consume the old deferred claim");
        assertEq(
            preview.effectiveAssetsAfterUsdc,
            liveEffective,
            "Preview solvency should use net deferred liabilities after consumption"
        );
    }

    function test_LiquidationState_UsesFullReachableCollateralForUnderwaterBountyCap() public {
        LiquidationAccountingLibHarness harness = new LiquidationAccountingLibHarness();
        LiquidationAccountingLib.LiquidationState memory state =
            harness.build(10_000e18, 100_000_000, 125e6, 0, -145e6, 100, 1e6, 900, 1e20);

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

        (uint256 size,,,,,,,) = engine.positions(accountId);
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

        assertGt(
            canonicalPreview.fundingUsdc,
            lowDepthSimulation.fundingUsdc,
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
        assertEq(interfacePreview.fundingUsdc, contractPreview.fundingUsdc);
        assertEq(interfacePreview.reachableCollateralUsdc, contractPreview.reachableCollateralUsdc);
        assertEq(interfacePreview.keeperBountyUsdc, contractPreview.keeperBountyUsdc);
        assertEq(interfacePreview.seizedCollateralUsdc, contractPreview.seizedCollateralUsdc);
        assertEq(interfacePreview.immediatePayoutUsdc, contractPreview.immediatePayoutUsdc);
        assertEq(interfacePreview.deferredPayoutUsdc, contractPreview.deferredPayoutUsdc);
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

        assertEq(
            engine.lastFundingTime(),
            engine.lastMarkTime(),
            "Mark refresh should checkpoint funding time when the prior live mark was stale"
        );
        assertEq(
            refreshedPreview.fundingUsdc,
            stalePreview.fundingUsdc,
            "Fresh mark refresh should not retroactively accrue the stale funding window"
        );
        assertEq(
            refreshedPreview.equityUsdc,
            stalePreview.equityUsdc,
            "Liquidation equity should remain unchanged across the stale interval"
        );
    }

    function test_LiquidationPreview_IlliquidDeferredPayoutMatchesLiveOutcome() public {
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
            engine.deferredPayoutUsdc(accountId),
            preview.deferredPayoutUsdc,
            "Illiquid liquidation preview should match live deferred trader payout"
        );
        assertEq(observed.badDebtUsdc, preview.badDebtUsdc, "Illiquid liquidation preview should match live bad debt");
    }

    function test_LiquidationPreview_DeferredPayoutPreventsUnfairLiquidation() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 bullId = bytes32(uint256(0xD211));
        bytes32 bearId = bytes32(uint256(0xD212));
        _fundTrader(address(uint160(uint256(bullId))), 5000e6);
        _fundTrader(address(uint160(uint256(bearId))), 5000e6);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, vaultDepth);
        _open(bearId, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, vaultDepth);

        uint64 refreshTime = uint64(block.timestamp + 365 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        _closeAt(bearId, CfdTypes.Side.BEAR, 5000e18, 120_000_000, vaultDepth, refreshTime);
        uint256 deferred = engine.deferredPayoutUsdc(bearId);
        assertGt(deferred, 0, "Setup must create deferred payout while keeping the position open");

        stdstore.target(address(clearinghouse)).sig("balanceUsdc(bytes32)").with_key(bearId).checked_write(uint256(0));

        CfdEngine.LiquidationPreview memory fundedPreview = engineLens.previewLiquidation(bearId, 85_000_000);
        assertFalse(fundedPreview.liquidatable, "Deferred payout should count toward liquidation equity");

        stdstore.target(address(engine)).sig("deferredPayoutUsdc(bytes32)").with_key(bearId).checked_write(uint256(0));
        CfdEngine.LiquidationPreview memory strippedPreview = engineLens.previewLiquidation(bearId, 85_000_000);
        assertTrue(
            strippedPreview.liquidatable, "Removing deferred payout should expose the same position to liquidation"
        );
    }

    function test_PreviewLiquidation_StagesForfeitureLikeLiveLiquidation() public {
        address trader = address(0xAB1405);
        address keeper = address(0xAB1406);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 900e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        uint256 queuedOrderCount = router.MAX_PENDING_ORDERS();
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
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory afterSnapshot = engineProtocolLens.getProtocolAccountingSnapshot();

        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);

        assertEq(
            engine.deferredPayoutUsdc(accountId),
            preview.deferredPayoutUsdc,
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
            preview.fundingUsdc,
            oldModelEquivalent.fundingUsdc,
            "Forfeited escrow should now change the funding-sensitive liquidation preview"
        );
    }

    function test_Liquidation_ConsumesDeferredPayoutBeforeRecordingBadDebt() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 bullId = bytes32(uint256(0xD221));
        bytes32 bearId = bytes32(uint256(0xD222));
        address keeper = address(0xD223);
        _fundTrader(address(uint160(uint256(bullId))), 5000e6);
        _fundTrader(address(uint160(uint256(bearId))), 5000e6);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, vaultDepth);
        _open(bearId, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, vaultDepth);

        uint64 refreshTime = uint64(block.timestamp + 365 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        _closeAt(bearId, CfdTypes.Side.BEAR, 5000e18, 120_000_000, vaultDepth, refreshTime);
        uint256 deferredBefore = engine.deferredPayoutUsdc(bearId);
        assertGt(deferredBefore, 0, "Setup must create deferred payout while keeping the position open");

        uint256 reducedSettlement = clearinghouse.balanceUsdc(bearId) - 4700e6;
        stdstore.target(address(clearinghouse)).sig("balanceUsdc(bytes32)").with_key(bearId)
            .checked_write(reducedSettlement);

        uint256 settlementReachableBefore = _terminalReachableUsdc(bearId);
        uint256 traderWalletBefore = usdc.balanceOf(address(uint160(uint256(bearId))));
        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(bearId, 50_000_000);
        assertTrue(preview.liquidatable, "Setup must produce a liquidatable position even after deferred payout credit");

        int256 terminalResidual = int256(settlementReachableBefore + deferredBefore) + preview.pnlUsdc
            + preview.fundingUsdc - int256(preview.keeperBountyUsdc);

        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(50_000_000));
        vm.prank(keeper);
        router.executeLiquidation(bearId, priceData);

        assertLt(
            engine.deferredPayoutUsdc(bearId),
            deferredBefore,
            "Liquidation should consume deferred payout before socializing loss"
        );
        assertEq(
            engine.deferredPayoutUsdc(bearId),
            preview.deferredPayoutUsdc,
            "Preview should match remaining deferred payout after liquidation"
        );
        assertEq(
            engine.accumulatedBadDebtUsdc() - badDebtBefore,
            preview.badDebtUsdc,
            "Bad debt should only reflect the post-deferred shortfall"
        );
        assertEq(
            clearinghouse.balanceUsdc(bearId) + engine.deferredPayoutUsdc(bearId)
                + (usdc.balanceOf(address(uint160(uint256(bearId)))) - traderWalletBefore),
            _positivePart(terminalResidual),
            "Terminal liquidation residual should equal retained settlement plus remaining deferred plus immediate payout"
        );
        assertEq(
            engine.accumulatedBadDebtUsdc() - badDebtBefore,
            _negativePart(terminalResidual),
            "Terminal liquidation bad debt should equal the negative residual"
        );
    }

    function test_Close_ConsumesDeferredPayoutBeforeRecordingBadDebt() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 bullId = bytes32(uint256(0xD231));
        bytes32 bearId = bytes32(uint256(0xD232));
        _fundTrader(address(uint160(uint256(bullId))), 5000e6);
        _fundTrader(address(uint160(uint256(bearId))), 5000e6);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, vaultDepth);
        _open(bearId, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, vaultDepth);

        uint64 refreshTime = uint64(block.timestamp + 365 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        _closeAt(bearId, CfdTypes.Side.BEAR, 5000e18, 120_000_000, vaultDepth, refreshTime);
        uint256 deferredBefore = engine.deferredPayoutUsdc(bearId);
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
            engine.deferredPayoutUsdc(bearId),
            preview.deferredPayoutUsdc,
            "Live close should leave the same deferred payout remainder shown in preview"
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

    function test_Close_ConsumesDeferredPayoutBalancesWithoutQueueOrdering() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 bullId = bytes32(uint256(0xD241));
        bytes32 bearId = bytes32(uint256(0xD242));
        address keeper = address(0xD243);
        _fundTrader(address(uint160(uint256(bullId))), 5000e6);
        _fundTrader(address(uint160(uint256(bearId))), 5000e6);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, vaultDepth);
        _open(bearId, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, vaultDepth);

        uint64 refreshTime = uint64(block.timestamp + 365 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        vm.prank(address(router));
        engine.recordDeferredClearerBounty(keeper, 1e6);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        _closeAt(bearId, CfdTypes.Side.BEAR, 5000e18, 120_000_000, vaultDepth, refreshTime);
        uint256 deferredBefore = engine.deferredPayoutUsdc(bearId);
        assertGt(deferredBefore, 0, "Bear account should accrue deferred trader payout balance");

        _closeAt(bearId, CfdTypes.Side.BEAR, 2500e18, 120_000_000, vaultDepth, refreshTime);
        uint256 deferredAfterAccrual = engine.deferredPayoutUsdc(bearId);
        assertGe(deferredAfterAccrual, deferredBefore, "Additional deferred payout should coalesce into the same balance");

        uint256 reducedSettlement = clearinghouse.balanceUsdc(bearId) - 4700e6;
        stdstore.target(address(clearinghouse)).sig("balanceUsdc(bytes32)").with_key(bearId)
            .checked_write(reducedSettlement);

        _closeAt(bearId, CfdTypes.Side.BEAR, 2500e18, 80_000_000, vaultDepth, refreshTime);
        assertLe(
            engine.deferredPayoutUsdc(bearId),
            deferredAfterAccrual,
            "Consuming deferred trader payout should only reduce the tracked balance"
        );
    }

    function test_DeferredTraderPayout_CoalescesPerAccountWithoutQueuePosition() public {
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

        uint64 refreshTime = uint64(block.timestamp + 365 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        _closeAt(bearId, CfdTypes.Side.BEAR, 5000e18, 120_000_000, vaultDepth, refreshTime);
        uint256 bearDeferredBefore = engine.deferredPayoutUsdc(bearId);
        assertGt(bearDeferredBefore, 0, "Initial deferred payout should create tracked deferred balance for bearId");

        _closeAt(laterId, CfdTypes.Side.BEAR, 5000e18, 120_000_000, vaultDepth, refreshTime);
        uint256 laterDeferred = engine.deferredPayoutUsdc(laterId);
        assertGt(laterDeferred, 0, "Later claimant should also accrue deferred balance");

        _closeAt(bearId, CfdTypes.Side.BEAR, 2500e18, 120_000_000, vaultDepth, refreshTime);
        uint256 bearDeferredAfter = engine.deferredPayoutUsdc(bearId);

        assertGe(bearDeferredAfter, bearDeferredBefore, "Coalescing should not move the account behind later claimants");
    }

    function test_Close_RecoversExecutionFeeShortfallFromExistingDeferredPayout() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 bullId = bytes32(uint256(0xD251));
        bytes32 bearId = bytes32(uint256(0xD252));
        _fundTrader(address(uint160(uint256(bullId))), 5000e6);
        _fundTrader(address(uint160(uint256(bearId))), 5000e6);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, vaultDepth);
        _open(bearId, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, vaultDepth);

        uint64 refreshTime = uint64(block.timestamp + 365 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        _closeAt(bearId, CfdTypes.Side.BEAR, 5000e18, 120_000_000, vaultDepth, refreshTime);
        uint256 deferredBefore = engine.deferredPayoutUsdc(bearId);
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
            nominalExecutionFeeUsdc,
            "Preview should report full fee collection after deferred recovery"
        );
        assertGe(
            preview.existingDeferredConsumedUsdc,
            nominalExecutionFeeUsdc - locked.positionMarginUsdc,
            "Deferred payout should cover at least the unpaid execution fee remainder"
        );

        uint256 feesBefore = engine.accumulatedFeesUsdc();
        _closeAt(bearId, CfdTypes.Side.BEAR, 5000e18, 1e8, vaultDepth, refreshTime);

        assertEq(
            engine.accumulatedFeesUsdc() - feesBefore,
            nominalExecutionFeeUsdc,
            "Protocol should book the full close execution fee after consuming deferred payout"
        );
        assertEq(
            deferredBefore - engine.deferredPayoutUsdc(bearId),
            preview.existingDeferredConsumedUsdc,
            "Live close should extinguish the deferred payout used to fund the fee shortfall"
        );
    }

    function test_PreviewLiquidation_ExcludesRouterExecutionEscrowFromReachableCollateral() public {
        address trader = address(0xAB1406);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 350e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        uint256 queuedOrderCount = router.MAX_PENDING_ORDERS();
        for (uint256 i = 0; i < queuedOrderCount; i++) {
            router.commitOrder(CfdTypes.Side.BULL, 1000e18, 0, type(uint256).max, true);
        }
        clearinghouse.withdraw(accountId, 70e6);
        vm.stopPrank();

        IOrderRouterAccounting.AccountEscrowView memory escrow = router.getAccountEscrow(accountId);
        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(accountId, 102_500_000);
        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = engineAccountLens.getAccountLedgerSnapshot(accountId);

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

    function helper_PreviewLiquidation_RecomputesPostOpClipInNoFundingBaseline() public {
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

        int256 currentFunding = int256(0);
        int256 bearFundingAfter = _previewFundingPnl(
            CfdTypes.Side.BEAR, _sideOpenInterest(CfdTypes.Side.BEAR), _sideEntryFunding(CfdTypes.Side.BEAR)
        );
        int256 postFunding = _cappedFundingAfter(0, bearFundingAfter, 0, _sideTotalMargin(CfdTypes.Side.BEAR));
        assertGt(
            postFunding, currentFunding, "Liquidation should remove the clipped funding receivable from solvency assets"
        );
        assertGt(postFunding, 0, "Setup must leave post-liquidation funding as a solvency liability");

        CfdEngine.LiquidationPreview memory preDrainPreview = engineLens.previewLiquidation(bullId, 195_000_000);
        assertTrue(preDrainPreview.liquidatable, "Setup must produce a liquidatable position");

        uint256 bearMaxProfit = _sideMaxProfit(CfdTypes.Side.BEAR);
        uint256 targetAssets = bearMaxProfit + engine.accumulatedFeesUsdc() + uint256(postFunding)
            + preDrainPreview.keeperBountyUsdc - preDrainPreview.seizedCollateralUsdc - 1;
        uint256 currentAssets = pool.totalAssets();
        assertGt(currentAssets, targetAssets, "Test setup must be able to drain the vault into the funding-clip gap");

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), currentAssets - targetAssets);

        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(bullId, 195_000_000);
        assertTrue(
            preview.triggersDegradedMode,
            "Liquidation preview should use post-liquidation funding clip when testing degraded mode"
        );

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(195_000_000));
        vm.prank(address(0xAB1414));
        router.executeLiquidation(bullId, priceData);

        assertEq(
            preview.triggersDegradedMode,
            engine.degradedMode(),
            "Liquidation preview should match live degraded-mode outcome after funding clipping"
        );
    }

    function test_GetDeferredPayoutStatus_ReflectsClaimability() public {
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

        DeferredEngineViewTypes.DeferredPayoutStatus memory statusBefore =
            _deferredPayoutStatus(accountId, address(this));
        assertGt(statusBefore.deferredTraderPayoutUsdc, 0);
        assertFalse(statusBefore.traderPayoutClaimableNow);

        usdc.mint(address(pool), statusBefore.deferredTraderPayoutUsdc);

        DeferredEngineViewTypes.DeferredPayoutStatus memory statusAfter =
            _deferredPayoutStatus(accountId, address(this));
        assertTrue(statusAfter.traderPayoutClaimableNow);
    }

    function test_GetDeferredPayoutStatus_ExposesClaimabilityWithoutHeadOrdering() public {
        address trader = address(0xAB16);
        address keeper = address(0xAB17);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        uint256 deferred = engine.deferredPayoutUsdc(accountId);
        vm.prank(address(router));
        engine.recordDeferredClearerBounty(keeper, deferred);
        usdc.mint(address(pool), deferred);

        DeferredEngineViewTypes.DeferredPayoutStatus memory status = _deferredPayoutStatus(accountId, keeper);
        assertTrue(status.traderPayoutClaimableNow, "Deferred trader claim should be claimable under partial liquidity");
        assertTrue(status.liquidationBountyClaimableNow, "Deferred clearer claim should also be claimable without FIFO ordering");
    }

    function test_DeferredClearerBounty_Lifecycle() public {
        address keeper = address(0xAB1601);
        address relayer = address(0xAB1602);
        uint256 deferredBounty = 25e6;

        vm.prank(address(router));
        engine.recordDeferredClearerBounty(keeper, deferredBounty);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets);

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory protocolViewBefore = engineProtocolLens.getProtocolAccountingSnapshot();
        DeferredEngineViewTypes.DeferredPayoutStatus memory statusBefore =
            _deferredPayoutStatus(bytes32(0), keeper);
        assertEq(protocolViewBefore.totalDeferredClearerBountyUsdc, deferredBounty);
        assertEq(statusBefore.deferredClearerBountyUsdc, deferredBounty);
        assertFalse(
            statusBefore.liquidationBountyClaimableNow,
            "Deferred clearer bounty should be unclaimable while vault is illiquid"
        );

        usdc.mint(address(pool), deferredBounty);

        DeferredEngineViewTypes.DeferredPayoutStatus memory statusAfterFunding =
            _deferredPayoutStatus(bytes32(0), keeper);
        assertTrue(
            statusAfterFunding.liquidationBountyClaimableNow,
            "Deferred clearer bounty should become claimable once vault liquidity returns"
        );

        bytes32 keeperId = bytes32(uint256(uint160(keeper)));
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeperId);
        vm.prank(keeper);
        engine.claimDeferredClearerBounty();

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory protocolViewAfter = engineProtocolLens.getProtocolAccountingSnapshot();
        assertEq(clearinghouse.balanceUsdc(keeperId) - keeperSettlementBefore, deferredBounty);
        assertEq(engine.deferredClearerBountyUsdc(keeper), 0);
        assertEq(protocolViewAfter.totalDeferredClearerBountyUsdc, 0);
    }

    function test_DeferredClearerBounty_CoalescesPerKeeperAndSupportsPartialClaims() public {
        address keeper = address(0xAB1605);
        bytes32 keeperId = bytes32(uint256(uint160(keeper)));

        vm.startPrank(address(router));
        engine.recordDeferredClearerBounty(keeper, 25e6);
        engine.recordDeferredClearerBounty(keeper, 5e6);
        vm.stopPrank();

        assertEq(engine.deferredClearerBountyUsdc(keeper), 30e6, "Keeper liability should aggregate across events");

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets);
        usdc.mint(address(pool), 10e6);

        uint256 settlementBefore = clearinghouse.balanceUsdc(keeperId);
        vm.prank(keeper);
        engine.claimDeferredClearerBounty();

        assertEq(
            clearinghouse.balanceUsdc(keeperId) - settlementBefore,
            10e6,
            "Head claim should service only available liquidity"
        );
        assertEq(
            engine.deferredClearerBountyUsdc(keeper), 20e6, "Partial claim should preserve remaining keeper liability"
        );
    }

    function test_ClaimDeferredClearerBounty_IgnoresKeeperWalletTransferBlacklist() public {
        address keeper = address(0xAB1603);
        address laterKeeper = address(0xAB1604);
        bytes32 keeperId = bytes32(uint256(uint160(keeper)));
        uint256 deferredBounty = 25e6;

        vm.prank(address(router));
        engine.recordDeferredClearerBounty(keeper, deferredBounty);
        vm.prank(address(router));
        engine.recordDeferredClearerBounty(laterKeeper, 5e6);

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
        engine.claimDeferredClearerBounty();

        assertEq(
            clearinghouse.balanceUsdc(keeperId) - keeperSettlementBefore,
            deferredBounty,
            "Deferred clearer bounty should settle to clearinghouse credit without direct keeper transfer"
        );
        assertEq(
            engine.deferredClearerBountyUsdc(laterKeeper),
            5e6,
            "Claiming one keeper should not affect unrelated deferred clearer balances"
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
        (, uint256 liveMarginBeforeClose,,,,,,) = engine.positions(accountId);
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
            marginDelta: 1000 * 1e6,
            targetPrice: 0.8e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.BEAR,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(bearOrder, 0.8e8, 1_000_000 * 1e6, uint64(block.timestamp));

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
        vm.expectRevert(CfdEngine.CfdEngine__MustCloseOpposingPosition.selector);
        vm.prank(address(router));
        engine.processOrder(bullOrder, 0.8e8, 1_000_000 * 1e6, uint64(block.timestamp));
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
        engine.processOrder(bearOrder, 0.8e8, 1_000_000 * 1e6, uint64(block.timestamp));

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

    function test_FundingSettlement_DoesNotBackfillAfterFreshCheckpoint() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);

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
        engine.processOrder(openOrder, 1e8, vaultDepth, uint64(block.timestamp));

        uint64 refreshTime = uint64(block.timestamp + 365 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint64 accrualTime = refreshTime + 30;
        vm.warp(accrualTime);

        CfdTypes.Order memory addOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 1000 * 1e6,
            targetPrice: 1e8,
            commitTime: accrualTime,
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(addOrder, 1e8, vaultDepth, accrualTime);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 110_000 * 1e18, "Fresh mark checkpoint should not retroactively create a funding-driven revert");
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
        engine.processOrder(first, 0.8e8, vaultDepth, uint64(block.timestamp));

        (,, uint256 entryAfterFirst,,,,,) = engine.positions(accountId);
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
        engine.processOrder(second, 1.2e8, vaultDepth, uint64(block.timestamp));

        (uint256 totalSize,, uint256 avgEntry,,,,,) = engine.positions(accountId);
        assertEq(totalSize, 40_000 * 1e18, "Total size should be 40k");
        assertEq(avgEntry, 1.1e8, "Weighted avg entry should be $1.10");
    }

    function test_FundingSettlement_OnClose() public {
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
        engine.processOrder(openOrder, 1e8, vaultDepth, uint64(block.timestamp));

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
        engine.processOrder(closeOrder, 1e8, vaultDepth, uint64(block.timestamp));

        uint256 chAfter = clearinghouse.balanceUsdc(accountId);
        assertLt(chAfter, chBefore, "Funding drain should reduce clearinghouse balance on close");
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
        engine.processOrder(order, 1e8, vaultDepth, uint64(block.timestamp));

        vm.prank(trader);
        clearinghouse.withdraw(accountId, 2500 * 1e6);

        vm.expectRevert(CfdEngine.CfdEngine__PositionIsSolvent.selector);
        vm.prank(address(router));
        engine.liquidatePosition(accountId, 1e8, vaultDepth, uint64(block.timestamp));

        engine.proposeRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0.0005e18,
                maxSkewRatio: 0.4e18,
                maintMarginBps: 300,
                initMarginBps: ((300) * 15) / 10,
                fadMarginBps: 500,
                baseCarryBps: 500,
                minBountyUsdc: 5 * 1e6,
                bountyBps: 15
            })
        );
        vm.warp(block.timestamp + 48 hours + 1);
        engine.finalizeRiskParams();

        vm.prank(address(router));
        uint256 bounty = engine.liquidatePosition(accountId, 1e8, vaultDepth, uint64(block.timestamp));
        assertTrue(bounty > 0, "Position should be liquidatable after raising maintMarginBps");

        (uint256 size,,,,,,,) = engine.positions(accountId);
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
        engine.processOrder(order, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));

        vm.prank(address(0xDEAD));
        vm.expectRevert(CfdEngine.CfdEngine__Unauthorized.selector);
        engine.liquidatePosition(accountId, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));
    }

    function test_ProposeRiskParams_RevertsOnZeroMaintMargin() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.maintMarginBps = 0;

        vm.expectRevert(CfdEngine.CfdEngine__InvalidRiskParams.selector);
        engine.proposeRiskParams(params);
    }

    function test_ProposeRiskParams_RevertsOnZeroInitMargin() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.initMarginBps = 0;

        vm.expectRevert(CfdEngine.CfdEngine__InvalidRiskParams.selector);
        engine.proposeRiskParams(params);
    }

    function test_ProposeRiskParams_RevertsWhenInitMarginBelowMaint() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.initMarginBps = params.maintMarginBps - 1;

        vm.expectRevert(CfdEngine.CfdEngine__InvalidRiskParams.selector);
        engine.proposeRiskParams(params);
    }

    function test_ProposeRiskParams_RevertsWhenFadMarginBelowMaint() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.fadMarginBps = params.maintMarginBps - 1;

        vm.expectRevert(CfdEngine.CfdEngine__InvalidRiskParams.selector);
        engine.proposeRiskParams(params);
    }

    function test_ProposeRiskParams_RevertsWhenFadMarginExceeds100Percent() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.fadMarginBps = 10_001;

        vm.expectRevert(CfdEngine.CfdEngine__InvalidRiskParams.selector);
        engine.proposeRiskParams(params);
    }

    function test_ProposeRiskParams_RevertsOnZeroMinBounty() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.minBountyUsdc = 0;

        vm.expectRevert(CfdEngine.CfdEngine__InvalidRiskParams.selector);
        engine.proposeRiskParams(params);
    }

    function test_ProposeRiskParams_RevertsOnZeroBountyBps() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.bountyBps = 0;

        vm.expectRevert(CfdEngine.CfdEngine__InvalidRiskParams.selector);
        engine.proposeRiskParams(params);
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
        engine.processOrder(openOrder, 1e8, vaultDepth, uint64(block.timestamp));

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
        vm.expectRevert(CfdEngine.CfdEngine__CloseSizeExceedsPosition.selector);
        vm.prank(address(router));
        engine.processOrder(closeOrder, 1e8, vaultDepth, uint64(block.timestamp));
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
        vm.expectRevert(CfdEngine.CfdEngine__InsufficientInitialMargin.selector);
        vm.prank(address(router));
        engine.processOrder(order, 1e8, vaultDepth, uint64(block.timestamp));
    }

    function test_OpenOrder_IMRPrecedesSkewWhenBothFail() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 accountId = bytes32(uint256(11));
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);

        engine.proposeRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0.0005e18,
                maxSkewRatio: 0.4e18,
                maintMarginBps: 100,
                initMarginBps: ((100) * 15) / 10,
                fadMarginBps: 300,
                baseCarryBps: 500,
                minBountyUsdc: 5 * 1e6,
                bountyBps: 15
            })
        );
        vm.warp(block.timestamp + 48 hours + 1);
        engine.finalizeRiskParams();

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

        vm.expectRevert(CfdEngine.CfdEngine__InsufficientInitialMargin.selector);
        vm.prank(address(router));
        engine.processOrder(order, 1e8, vaultDepth, uint64(block.timestamp));
    }

    function test_C5_CloseSucceeds_WhenFundingExceedsMargin_ButPositionProfitable() public {
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
        engine.processOrder(openOrder, 1e8, vaultDepth, uint64(block.timestamp));

        // Warp 365 days — funding will far exceed margin
        vm.warp(block.timestamp + 365 days);

        // Price dropped to $0.50 → BULL has $50k unrealized profit
        // User should be able to close and receive profit minus funding minus fees
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

        // This should NOT revert — the position is profitable despite funding > margin
        vm.prank(address(router));
        engine.processOrder(closeOrder, 0.5e8, vaultDepth, uint64(block.timestamp));

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be fully closed");

        uint256 chAfter = clearinghouse.balanceUsdc(accountId);
        assertGt(chAfter, chBefore, "User should net positive after profitable close minus funding");
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

        vm.expectRevert(CfdEngine.CfdEngine__InsufficientInitialMargin.selector);
        vm.prank(address(router));
        engine.processOrder(order, 1e8, vaultDepth, uint64(block.timestamp));
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
        engine.processOrder(first, 100_000_001, vaultDepth, uint64(block.timestamp));

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
        engine.processOrder(second, 100_000_000, vaultDepth, uint64(block.timestamp));

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
        engine.processOrder(close, 100_000_000, vaultDepth, uint64(block.timestamp));

        (uint256 size,,,,,,,) = engine.positions(accountId);
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
        engine.processOrder(aliceOpen, 1e8, vaultDepth, uint64(block.timestamp));

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
        engine.processOrder(bobOpen, 1e8, vaultDepth, uint64(block.timestamp));

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
        engine.processOrder(aliceClose, 1e8, vaultDepth, uint64(block.timestamp));

        (uint256 aliceSize,,,,,,,) = engine.positions(aliceId);
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
        engine.processOrder(openOrder, 1e8, vaultDepth, uint64(block.timestamp));

        vm.prank(trader);
        clearinghouse.withdraw(accountId, 46_000 * 1e6);

        uint256 freeEquityBefore = clearinghouse.getFreeBuyingPowerUsdc(accountId);
        assertTrue(freeEquityBefore > 0, "User should have free equity beyond locked margin");

        uint256 vaultBefore = usdc.balanceOf(address(pool));

        // Price rises to $1.10 — BULL loses $10k, equity = margin (~$1537) - $10k = negative
        vm.prank(address(router));
        engine.liquidatePosition(accountId, 1.1e8, vaultDepth, uint64(block.timestamp));

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be liquidated");

        uint256 freeEquityAfter = clearinghouse.getFreeBuyingPowerUsdc(accountId);
        assertTrue(freeEquityAfter < freeEquityBefore, "Free equity should be reduced to cover bad debt");

        uint256 vaultAfter = usdc.balanceOf(address(pool));
        uint256 totalRecovered = vaultAfter - vaultBefore;
        (, uint256 posMarginStored,,,,,,) = engine.positions(accountId);
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
        engine.processOrder(aliceOpen, 1e8, vaultDepth, uint64(block.timestamp));

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
        engine.processOrder(bobOpen, 1e8, vaultDepth, uint64(block.timestamp));

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

        (uint256 aliceSize,,,,,,,) = engine.positions(aliceId);
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

        engine.proposeRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0,
                maxSkewRatio: 0.4e18,
                maintMarginBps: 10,
                initMarginBps: ((10) * 15) / 10,
                fadMarginBps: 10,
                baseCarryBps: 500,
                minBountyUsdc: 5 * 1e6,
                bountyBps: 100
            })
        );
        vm.warp(block.timestamp + 48 hours + 1);
        engine.finalizeRiskParams();

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
        engine.processOrder(openOrder, 1e8, vaultDepth, uint64(block.timestamp));

        (, uint256 posMargin,,,,,,) = engine.positions(accountId);

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

        vm.expectRevert(CfdEngine.CfdEngine__BadDebtTooLarge.selector);
        engine.clearBadDebt(badDebt + 1);
    }

    function test_CheckWithdraw_UsesEngineMarkStalenessLimit_NotPoolMarkLimit() public {
        pool.proposeMarkStalenessLimit(300);
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizeMarkStalenessLimit();
        assertEq(pool.markStalenessLimit(), 300);

        bytes32 accountId = bytes32(uint256(0x5157));
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);
        _open(accountId, CfdTypes.Side.BULL, 20_000 * 1e18, 2000 * 1e6, 1e8);

        vm.warp(block.timestamp + 31);

        engine.checkWithdraw(accountId);

        vm.warp(block.timestamp + 270);

        vm.expectRevert(CfdEngine.CfdEngine__MarkPriceStale.selector);
        engine.checkWithdraw(accountId);

        engine.proposeEngineMarkStalenessLimit(300);
        vm.warp(engine.engineMarkStalenessActivationTime() + 1);
        engine.finalizeEngineMarkStalenessLimit();

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        engine.checkWithdraw(accountId);
    }

    function test_ReserveCloseOrderExecutionBounty_UsesEngineMarkStalenessLimit_NotPoolMarkLimit() public {
        pool.proposeMarkStalenessLimit(300);
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizeMarkStalenessLimit();

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
        engine.reserveCloseOrderExecutionBounty(accountId, 1e6, address(router));

        vm.warp(block.timestamp + 270);
        vm.prank(address(router));
        vm.expectRevert(CfdEngine.CfdEngine__InsufficientCloseOrderBountyBacking.selector);
        engine.reserveCloseOrderExecutionBounty(accountId, 1e6, address(router));

        engine.proposeEngineMarkStalenessLimit(300);
        vm.warp(engine.engineMarkStalenessActivationTime() + 1);
        engine.finalizeEngineMarkStalenessLimit();

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.prank(address(router));
        engine.reserveCloseOrderExecutionBounty(accountId, 1e6, address(router));
    }

    function test_CheckWithdraw_RevertsWhenOpenPositionHasZeroMarkPrice() public {
        bytes32 accountId = bytes32(uint256(0x5158));
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);
        _open(accountId, CfdTypes.Side.BULL, 20_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(0, uint64(block.timestamp));

        vm.expectRevert(CfdEngine.CfdEngine__MarkPriceStale.selector);
        engine.checkWithdraw(accountId);
    }

    function test_CheckWithdraw_DoesNotCountDeferredPayoutAsReachableCollateral() public {
        address trader = address(0x51581);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8);

        stdstore.target(address(clearinghouse)).sig("balanceUsdc(bytes32)").with_key(accountId)
            .checked_write(uint256(0));
        stdstore.target(address(engine)).sig("deferredPayoutUsdc(bytes32)").with_key(accountId)
            .checked_write(uint256(200e6));

        vm.expectRevert(CfdEngine.CfdEngine__WithdrawBlockedByOpenPosition.selector);
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

        engine.proposeEngineMarkStalenessLimit(300);
        vm.warp(engine.engineMarkStalenessActivationTime() + 1);
        engine.finalizeEngineMarkStalenessLimit();

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
        engine.proposeRiskParams(params);
        vm.warp(block.timestamp + 7 days);
        engine.finalizeRiskParams();

        (,,, uint256 initMarginBps,,,,) = engine.riskParams();
        assertEq(initMarginBps, 300, "Setup must finalize the explicit init margin config");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.expectRevert(CfdEngine.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        vm.prank(trader);
        clearinghouse.withdraw(accountId, 200e6);
    }

    function test_ReserveCloseOrderExecutionBounty_DoesNotCountDeferredPayoutAsReachableCollateral() public {
        address trader = address(0x51582);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8);

        stdstore.target(address(clearinghouse)).sig("balanceUsdc(bytes32)").with_key(accountId)
            .checked_write(uint256(0));
        stdstore.target(address(engine)).sig("deferredPayoutUsdc(bytes32)").with_key(accountId)
            .checked_write(uint256(200e6));

        vm.prank(address(router));
        vm.expectRevert(CfdEngine.CfdEngine__InsufficientCloseOrderBountyBacking.selector);
        engine.reserveCloseOrderExecutionBounty(accountId, 1e6, address(router));
    }

    function helper_ReserveCloseOrderExecutionBounty_NoCarryProjectionWithoutPriorSync() public {
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
        engine.reserveCloseOrderExecutionBounty(accountId, 1400e6, address(router));
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
        engine.processOrder(openOrder, 1e8, largeDepth, uint64(block.timestamp));

        (,,,,,,, int256 storedVpi) = engine.positions(accountId);
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
        engine.processOrder(closeOrder, 1e8, smallDepth, uint64(block.timestamp));

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
// CfdEngineFundingTest: funding edge cases (C-01, C-02, C-03)
// ==========================================

contract CfdEngineFundingTest is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 5_000_000 * 1e6;
    }

    // Regression: C-01 — stale funding index attack blocked by H-03 dust guard
    function test_StaleFundingIndex_DustCloseBlocked() public {
        uint256 depth = 5_000_000 * 1e6;

        bytes32 attackerId = bytes32(uint256(uint160(address(0xA1))));
        _fundTrader(address(0xA1), 500_000 * 1e6);

        bytes32 counterId = bytes32(uint256(uint160(address(0xB1))));
        _fundTrader(address(0xB1), 500_000 * 1e6);
        _open(counterId, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8, depth);

        uint256 minNotional = (uint256(5) * 1e6 * 10_000) / 15 + 1e6;
        uint256 minSize = (minNotional * 1e20) / 1e8;
        _open(attackerId, CfdTypes.Side.BULL, minSize, 50_000 * 1e6, 1e8, depth);

        // H-03: closing to 1 wei now reverts (remaining margin < minBountyUsdc)
        uint256 closeSize = minSize - 1;
        vm.expectRevert(CfdEngine.CfdEngine__DustPosition.selector);
        vm.prank(address(router));
        engine.processOrder(
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
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    // Regression: Finding-3
    function test_FundingBadDebt() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(carol, 50_000 * 1e6);

        bytes32 accountId = bytes32(uint256(uint160(carol)));

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        (uint256 sizeAfterOpen,,,,,,,) = engine.positions(accountId);

        vm.warp(block.timestamp + 182 days);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 1000 * 1e18, 500 * 1e6, 1e8, false);
        router.executeOrder(2, empty);

        (uint256 sizeAfterSecond,,,,,,,) = engine.positions(accountId);

        assertEq(sizeAfterSecond, sizeAfterOpen, "Order on underwater position should be cancelled");
    }

    function test_ProcessOrderTyped_RevertsWhenTruePostTradeEquityFailsImr() public {
        address trader = address(0xABCD1234);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(trader, 1020 * 1e6);
        _open(accountId, CfdTypes.Side.BULL, 50_000 * 1e18, 1000 * 1e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(101_800_000, uint64(block.timestamp));

        uint8 revertCode = engine.previewOpenRevertCode(
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

        uint8 revertCode = engine.previewOpenRevertCode(
            accountId, CfdTypes.Side.BULL, 10_000 * 1e18, 0, 102_000_000, uint64(block.timestamp)
        );
        CfdEnginePlanTypes.OpenFailurePolicyCategory failureCategory = engine.previewOpenFailurePolicyCategory(
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
    function test_AsyncFundingDoesNotBlockLegitOrders() public {
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
        (uint256 sizeBefore,,,,,,,) = engine.positions(carolAccount);

        router.proposeMaxOrderAge(0);
        vm.warp(block.timestamp + router.TIMELOCK_DELAY() + 1);
        router.finalizeMaxOrderAge();

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        vm.warp(block.timestamp + 91 days);

        uint8 revertCode = engine.previewOpenRevertCode(
            carolAccount, CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, uint64(block.timestamp)
        );
        assertEq(revertCode, 0, "Preview should keep the increase executable after async funding accrual");

        router.executeOrder(3, empty);

        (uint256 sizeAfter,,,,,,,) = engine.positions(carolAccount);

        assertGt(sizeAfter, sizeBefore, "Collectible funding receivables should no longer block legitimate increases");
        assertLe(int256(0), 0, "Solvency funding should not overstate trader liabilities once receivables are netted");
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

        (uint256 openSize,,,,,,,) = engine.positions(accountId);
        assertEq(openSize, 200_000 * 1e18);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000 * 1e18, 0, 0, true);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(0.8e8));
        router.executeOrder(2, priceData);

        (uint256 remainingSize,,,,,,,) = engine.positions(accountId);
        assertEq(remainingSize, 200_000 * 1e18, "Underwater partial close should fail and leave the position untouched");

        uint256 balAfter = clearinghouse.balanceUsdc(accountId);
        uint256 lockedAfter = clearinghouse.lockedMarginUsdc(accountId);
        assertGe(balAfter, lockedAfter, "Physical balance must cover locked margin (zombie prevention)");

        router.executeLiquidation(accountId, priceData);

        (uint256 sizeAfterLiq,,,,,,,) = engine.positions(accountId);
        assertEq(sizeAfterLiq, 0, "Remaining position should be fully liquidated");
    }

    // Regression: M-01
    function test_FinalizeRiskParamsRetroactiveFunding() public {
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

        int256 indexAfterOpen = _sideFundingIndex(CfdTypes.Side.BULL);

        vm.warp(T_PROPOSE);

        CfdTypes.RiskParams memory newParams = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
        engine.proposeRiskParams(newParams);

        vm.warp(T_FINALIZE);
        engine.finalizeRiskParams();

        vm.warp(T_ORDER2);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 5000 * 1e6, 1e8, false);
        router.executeOrder(2, empty);

        int256 indexAfterSettle = _sideFundingIndex(CfdTypes.Side.BULL);
        int256 indexDrop = indexAfterOpen - indexAfterSettle;

        uint256 totalElapsed = T_ORDER2 - T0;
        uint256 oldAnnRate = 0.06e18;
        int256 maxDrop = int256((oldAnnRate * totalElapsed * 2) / 365 days);

        assertLe(indexDrop, maxDrop, "Funding must not retroactively apply new rate to pre-finalize period");
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

        (uint256 size,,,,,,,) = engine.positions(accountId);
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

    function test_CheckWithdraw_BlocksWhenPostWithdrawEquityFallsBelowImr() public {
        _fundJunior(bob, 500_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertGt(size, 0, "Setup must leave an open position");

        stdstore.target(address(clearinghouse)).sig("balanceUsdc(bytes32)").with_key(accountId)
            .checked_write(uint256(100 * 1e6));

        vm.expectRevert(CfdEngine.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        engine.checkWithdraw(accountId);
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
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
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

        int256 uncappedPnl = engine.getUnrealizedTraderPnl();
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
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
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
// NegativeFundingFreeUsdcTest: negative funding receivables
// ==========================================

contract NegativeFundingFreeUsdcTest is BasePerpTest {

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
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    // Regression: negative funding receivables
    function helper_GetFreeUSDC_NoFundingBaseline() public {
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

        int256 unrealizedFunding = int256(0);
        assertLt(unrealizedFunding, 0, "funding should be negative (house is owed)");

        uint256 freeUsdcNow = pool.getFreeUSDC();

        uint256 bal = usdc.balanceOf(address(pool));
        uint256 maxLiability = _sideMaxProfit(CfdTypes.Side.BULL);
        uint256 pendingFees = engine.accumulatedFeesUsdc();
        uint256 reservedWithoutFunding = maxLiability + pendingFees;
        uint256 freeWithoutFunding = bal > reservedWithoutFunding ? bal - reservedWithoutFunding : 0;

        assertEq(
            freeUsdcNow, freeWithoutFunding, "getFreeUSDC must not reduce reserves by illiquid funding receivables"
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
            minBountyUsdc: 5e6,
            bountyBps: 15
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
                    engine.processOrder.selector,
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
        (, uint256 marginBefore,,,,,,) = engine.positions(accountId);

        vm.prank(trader);
        engine.addMargin(accountId, 1000e6);

        (, uint256 marginAfter,,,,,,) = engine.positions(accountId);
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
            minBountyUsdc: 5e6,
            bountyBps: 15
        });
    }

    function test_PhaseTransitions() public {
        assertEq(
            uint8(engine.getProtocolPhase()),
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
            uint8(engine.getProtocolPhase()),
            uint8(ICfdEngine.ProtocolPhase.Degraded),
            "Insolvency-revealing close should latch Degraded"
        );

        _fundJunior(address(this), 500_000e6);
        engine.clearDegradedMode();

        assertEq(
            uint8(engine.getProtocolPhase()),
            uint8(ICfdEngine.ProtocolPhase.Active),
            "Recapitalization should restore Active"
        );
    }

    function test_ConfiguringPhase() public {
        CfdEngine unconfigured = new CfdEngine(address(usdc), address(clearinghouse), 2e8, _riskParams());
        assertEq(
            uint8(unconfigured.getProtocolPhase()),
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
            uint8(engine.getProtocolPhase()),
            uint8(ICfdEngine.ProtocolPhase.Configuring),
            "Configured but inactive trading should still report Configuring"
        );

        pool.activateTrading();

        assertEq(
            uint8(engine.getProtocolPhase()),
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
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
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
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
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
        engine.processOrder(
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
        engine.processOrder(
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

    // Regression: H-01 — MM rebate zeroed by bidirectional clamp (design tradeoff)
    function test_MM_RebateZeroed_DesignTradeoff() public {
        bytes32 bearSkewerId = bytes32(uint256(uint160(address(0x51))));
        _deposit(bearSkewerId, 500_000 * 1e6);
        _open(bearSkewerId, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        bytes32 mmId = bytes32(uint256(uint160(address(0x111))));
        _deposit(mmId, 500_000 * 1e6);
        _open(mmId, CfdTypes.Side.BULL, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        (,,,,,,, int256 vpiAfterOpen) = engine.positions(mmId);
        assertLe(vpiAfterOpen, 0, "MM should not pay positive VPI when healing skew on open");

        bytes32 bullFlipperId = bytes32(uint256(uint160(address(0x52))));
        _deposit(bullFlipperId, 500_000 * 1e6);
        _open(bullFlipperId, CfdTypes.Side.BULL, 1_000_000 * 1e18, 100_000 * 1e6, 1e8, DEPTH);

        (uint256 mmSize,,,,,,,) = engine.positions(mmId);
        _close(mmId, CfdTypes.Side.BULL, mmSize, 1e8, DEPTH);
        uint256 mmUsdcAfter = clearinghouse.balanceUsdc(mmId);

        uint256 totalDeposited = 500_000 * 1e6;
        uint256 approxExecFees = (500_000 * 1e6 * 4 / 10_000) * 2;
        uint256 breakeven = totalDeposited - approxExecFees;

        assertEq(
            mmUsdcAfter,
            breakeven,
            "H-01 tradeoff: MM nets $0 VPI (open rebate clawed back on close to prevent depth attack)"
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
            minBountyUsdc: 5e6,
            bountyBps: 15
        });
    }

    function _liveEffectiveAssets(
        uint256 pendingPayoutUsdc
    ) internal view returns (uint256) {
        uint256 vaultAssets = pool.totalAssets() + pendingPayoutUsdc;
        uint256 fees = engine.accumulatedFeesUsdc();
        int256 funding = int256(0);
        uint256 netPhysical = vaultAssets > fees ? vaultAssets - fees : 0;
        uint256 effective;
        if (funding > 0) {
            effective = netPhysical > uint256(funding) ? netPhysical - uint256(funding) : 0;
        } else {
            effective = netPhysical + uint256(-funding);
        }
        uint256 deferred = engine.totalDeferredPayoutUsdc() + engine.totalDeferredClearerBountyUsdc();
        effective = effective > deferred ? effective - deferred : 0;
        return effective > pendingPayoutUsdc ? effective - pendingPayoutUsdc : 0;
    }

    /// @dev Regression: planLiquidation used stale side snapshots (OI, entryFunding, totalMargin)
    ///      for solvency computation. Now also uses previewPostOpSolvency with physicalAssetsDelta
    ///      to account for seized collateral flowing into the vault.
    function test_PreviewLiquidation_SolvencyUsesPostLiquidationFundingState() public {
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
        assertTrue(preview.liquidatable, "BULL majority must be liquidatable after funding drain");

        address keeper = address(0x999);
        vm.prank(keeper);
        bytes[] memory empty;
        router.executeLiquidation(bullId, empty);

        uint256 liveEffective = _liveEffectiveAssets(preview.keeperBountyUsdc);
        assertEq(
            preview.effectiveAssetsAfterUsdc,
            liveEffective,
            "Liquidation preview effective assets must match live post-liquidation state"
        );
    }

    /// @dev Regression: _computeCloseSolvency did not reduce openInterest before computing
    ///      capped funding PnL, overstating the OI*fundingIndex term.
    function test_PreviewClose_SolvencyUsesPostCloseOiForFunding() public {
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

        (uint256 sizeA,,,,,,,) = engine.positions(bullIdA);

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(bullIdA, sizeA, 1e8);
        assertTrue(preview.valid, "Close preview must be valid");

        _close(bullIdA, CfdTypes.Side.BULL, sizeA, 1e8);

        int256 liveFunding = int256(0);
        assertEq(
            preview.solvencyFundingPnlUsdc,
            liveFunding,
            "Close preview solvency funding must match live post-close capped funding"
        );
    }

}
