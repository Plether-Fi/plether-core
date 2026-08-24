// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Audit-history file: tests prefixed with `obsolete_` preserve superseded findings for context only.
// They are intentionally not statements about the live carry model or current accounting semantics.

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

contract TrancheCooldownBypassReceiver {}

contract AuditFollowupFindingsFailing_CloseSolvency is BasePerpTest {

    address bullTrader = address(0xB011);
    address bearTrader = address(0xBEA2);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function test_C3_ProfitableCloseEntersDegradedModeInsteadOfReverting() public {
        address bullAccount = bullTrader;
        address bearAccount = bearTrader;

        _fundTrader(bullTrader, 100_000e6);
        _fundTrader(bearTrader, 100_000e6);

        _open(bearAccount, CfdTypes.Side.BEAR, 1_000_000e18, 50_000e6, 1e8);
        _open(bullAccount, CfdTypes.Side.BULL, 500_000e18, 50_000e6, 1e8);

        _close(bullAccount, CfdTypes.Side.BULL, 500_000e18, 20_000_000);

        assertTrue(engine.degradedMode(), "Profitable close should latch degraded mode when it reveals insolvency");
    }

    function test_C3_DegradedModeBlocksNewOpensUntilRecapitalized() public {
        address bullAccount = bullTrader;
        address bearAccount = bearTrader;
        address newTrader = address(0xCAFE);
        address newTraderAccount = newTrader;

        _fundTrader(bullTrader, 100_000e6);
        _fundTrader(bearTrader, 100_000e6);
        _fundTrader(newTrader, 100_000e6);

        _open(bearAccount, CfdTypes.Side.BEAR, 1_000_000e18, 50_000e6, 1e8);
        _open(bullAccount, CfdTypes.Side.BULL, 500_000e18, 50_000e6, 1e8);
        _close(bullAccount, CfdTypes.Side.BULL, 500_000e18, 20_000_000);

        assertTrue(engine.degradedMode(), "Setup must enter degraded mode");
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
        assertFalse(ok, "Degraded mode must block new opens until recapitalized");
    }

    function test_C3_OwnerCanClearDegradedModeAfterRecapitalization() public {
        address bullAccount = bullTrader;
        address bearAccount = bearTrader;
        address newTrader = address(0xCAFE);
        address newTraderAccount = newTrader;

        _fundTrader(bullTrader, 100_000e6);
        _fundTrader(bearTrader, 100_000e6);
        _fundTrader(newTrader, 100_000e6);

        _open(bearAccount, CfdTypes.Side.BEAR, 1_000_000e18, 50_000e6, 1e8);
        _open(bullAccount, CfdTypes.Side.BULL, 500_000e18, 50_000e6, 1e8);
        _close(bullAccount, CfdTypes.Side.BULL, 500_000e18, 20_000_000);

        vm.expectRevert(ICfdEngineTypes.CfdEngine__StillInsolvent.selector);
        engine.clearDegradedMode();

        usdc.mint(address(pool), 500_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            500_000e6, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        vm.prank(address(juniorVault));
        pool.reconcile();
        engine.clearDegradedMode();

        assertFalse(engine.degradedMode(), "Owner should clear degraded mode after recapitalization restores solvency");
        _open(newTraderAccount, CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8);
    }

    function test_C3_TraderClaimDoesNotRequireDegradedModeWithoutOpenLiability() public {
        address bullAccount = bullTrader;

        _fundTrader(bullTrader, 11_000e6);
        _open(bullAccount, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(bullAccount, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        assertGt(engine.traderClaimBalanceUsdc(bullAccount), 0, "Setup should create a trader claim liability");
        assertFalse(
            engine.degradedMode(),
            "A standalone trader claim should not force degraded mode once bounded open liability is gone"
        );
    }

}

contract AuditFollowupFindingsFailing_LiquidationBadDebt is BasePerpTest {

    address trader = address(0xA11CE);

    function test_C1_LiquidationConsumesReachableBalanceWithoutArtificialBadDebt() public {
        address account = trader;
        _fundTrader(trader, 10_000e6);

        _open(account, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 8000e6);

        uint256 liquidationPrice = 101_800_000;
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, liquidationPrice);
        assertTrue(preview.liquidatable, "Setup must remain below maintenance margin");
        assertLt(preview.pnlUsdc, 0, "Setup must realize a trader price loss");
        uint256 priceLossUsdc = uint256(-preview.pnlUsdc);
        uint256 collectibleCapUsdc = engineAccountLens.getAccountLedgerSnapshot(account).terminalPriceCollectibleCapUsdc;
        assertLe(priceLossUsdc, collectibleCapUsdc, "Setup price loss must remain fully collectible");
        assertEq(preview.badDebtUsdc, 0, "A collectible price loss must not produce a debt diagnostic");

        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(account, liquidationPrice, depth, uint64(block.timestamp), address(this));

        (uint256 remainingSize,,,,,,) = engine.positions(account);
        assertEq(remainingSize, 0, "Liquidation should consume reachable price collateral and clear the position");
        assertEq(clearinghouse.pnlPledgeUsdc(account), 0, "Terminal liquidation must release the PnL pledge bucket");
    }

}

contract AuditFollowupFindingsFailing_LiquidationBounty is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 10,
            initMarginBps: ((10) * 15) / 10,
            fadMarginBps: 1000,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 1000,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function test_H1_PositiveEquityLiquidationUsesExplicitSubsidy() public {
        address trader = address(0xA201);
        address account = trader;

        _fundTrader(trader, 100e6);

        _open(account, CfdTypes.Side.BULL, CfdTypes.SIZE_QUANTUM, 12e6, 1e8);

        uint256 freeSettlementUsdc = _freeSettlementUsdc(account);
        vm.prank(trader);
        clearinghouse.withdraw(account, freeSettlementUsdc);

        vm.warp(1_709_971_200);
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 101_000_000);
        uint256 liquidationReserveBefore = clearinghouse.liquidationReserveUsdc(account);
        assertTrue(preview.liquidatable, "FAD maintenance must make the positive-equity fixture liquidatable");

        uint256 poolDepth = pool.totalAssets();
        vm.prank(address(router));
        uint256 bounty =
            engine.liquidatePosition(account, 101_000_000, poolDepth, uint64(block.timestamp), address(this));

        assertEq(bounty, preview.keeperBountyUsdc, "Execution must match the dedicated-reserve preview");
        assertEq(
            bounty,
            (liquidationReserveBefore * _riskParams().keeperShareBps) / 10_000,
            "Keeper must receive its configured share of the dedicated liquidation reserve"
        );
    }

}

contract AuditFollowupFindingsFailing_LegacySpreadReserve is BasePerpTest {

    address bullTraderA = address(0xB011);
    address bullTraderB = address(0xB012);
    address bearTrader = address(0xBEA2);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function obsolete_H2_GetFreeUsdcMustReservePositiveLegacySpreadWithoutNettingAgainstGlobalMargin() public {
        _fundJunior(address(this), 1_000_000e6);

        _fundTrader(bullTraderA, 15_000e6);
        _fundTrader(bullTraderB, 400_000e6);
        _fundTrader(bearTrader, 100_000e6);

        address bullIdA = bullTraderA;
        address bullIdB = bullTraderB;
        address bearAccount = bearTrader;

        _open(bullIdA, CfdTypes.Side.BULL, 390_000e18, 6500e6, 1e8);
        _open(bullIdB, CfdTypes.Side.BULL, 10_000e18, 300_000e6, 1e8);
        _open(bearAccount, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        vm.warp(block.timestamp + 180 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        CfdTypes.Position memory bullPosA;
        CfdTypes.Position memory bullPosB;
        CfdTypes.Position memory bearPos;
        {
            (uint256 size, uint256 margin, uint256 entryPrice,, CfdTypes.Side side,,) = engine.positions(bullIdA);
            bullPosA = CfdTypes.Position(size, margin, entryPrice, 0, side, 0, 0, 0);
        }
        {
            (uint256 size, uint256 margin, uint256 entryPrice,, CfdTypes.Side side,,) = engine.positions(bullIdB);
            bullPosB = CfdTypes.Position(size, margin, entryPrice, 0, side, 0, 0, 0);
        }
        {
            (uint256 size, uint256 margin, uint256 entryPrice,, CfdTypes.Side side,,) = engine.positions(bearAccount);
            bearPos = CfdTypes.Position(size, margin, entryPrice, 0, side, 0, 0, 0);
        }

        int256 bullLegacySpreadA = 0;
        int256 bullLegacySpreadB = 0;
        int256 bearLegacySpread = 0;
        assertLt(
            bullLegacySpreadA,
            -int256(bullPosA.margin),
            "Large undercollateralized bull should owe more legacy spread than its own margin in the obsolete model"
        );
        assertGt(
            bullLegacySpreadA + bullLegacySpreadB,
            -int256(bullPosA.margin + bullPosB.margin),
            "Global bull margin should mask the single-account deficit"
        );
        assertGt(bearLegacySpread, 0, "Setup must make the bear side owed legacy spread");

        uint256 bal = usdc.balanceOf(address(pool));
        uint256 maxLiability = _sideMaxProfit(CfdTypes.Side.BULL);
        uint256 pendingFees = clearinghouse.balanceUsdc(engine.protocolTreasury());
        uint256 expectedFree = bal > maxLiability + pendingFees + uint256(bearLegacySpread)
            ? bal - maxLiability - pendingFees - uint256(bearLegacySpread)
            : 0;

        assertEq(
            pool.getFreeUSDC(),
            expectedFree,
            "Free USDC should reserve all positive legacy-spread liabilities without netting them against global margin"
        );
    }

}

contract AuditFollowupFindingsFailing_TrancheComposability is BasePerpTest {

    address alice = address(0xA11CE);
    address helper = address(0xB0B);

    function test_M1_SmallThirdPartyTopUpForExistingHolderReverts() public {
        _fundJunior(alice, 100_000e6);

        usdc.mint(helper, 4999e6);
        vm.startPrank(helper);
        usdc.approve(address(juniorVault), 4999e6);
        uint256 requestId = juniorVault.requestDeposit(4999e6, helper);
        vm.stopPrank();

        vm.warp(juniorVault.depositEpochStart(requestId));
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        _settleLpEpochForTest();

        vm.startPrank(helper);
        vm.expectRevert(TrancheVault.TrancheVault__ThirdPartyDepositForExistingHolder.selector);
        juniorVault.claimDeposit(requestId, 4999e6, alice, helper);
        vm.stopPrank();
    }

}

contract AuditFollowupFindingsFailing_TrancheCooldownBypass is BasePerpTest {

    address attacker = address(0xBAD);

    function test_H1_TwoContractThirdPartyDepositForExistingHolderMustRevert() public {
        TrancheCooldownBypassReceiver receiver = new TrancheCooldownBypassReceiver();
        address receiverAddr = address(receiver);

        uint256 minimumDeposit = pool.minTrancheDepositUsdc();
        _fundJunior(receiverAddr, minimumDeposit);

        vm.warp(block.timestamp + 1 hours + 1);

        usdc.mint(attacker, 10_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), 10_000e6);
        uint256 requestId = juniorVault.requestDeposit(10_000e6, attacker);
        vm.stopPrank();

        vm.warp(juniorVault.depositEpochStart(requestId));
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        _settleLpEpochForTest();

        vm.startPrank(attacker);
        vm.expectRevert(TrancheVault.TrancheVault__ThirdPartyDepositForExistingHolder.selector);
        juniorVault.claimDeposit(requestId, 10_000e6, receiverAddr, attacker);
        vm.stopPrank();
    }

}

contract AuditFollowupFindingsFailing_AsyncCloseIntent is BasePerpTest {

    address trader = address(0xCAFE);

    function test_M2_CloseIntentBehindPendingOpenIsRejected() public {
        _fundTrader(trader, 50_000e6);

        vm.startPrank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 20_000e18, 5000e6, 1e8, false);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.BULL, 20_000e18, 0, 0, true);
        vm.stopPrank();

        assertEq(
            router.nextCommitId(), 2, "Rejected close intent should not advance the queue behind the pending open order"
        );
    }

}

contract AuditFollowupFindingsFailing_SkewCap is BasePerpTest {

    address trader = address(0x5E77);

    function test_M1_IncreaseMustRejectPostTradeSkewAboveMaxSkewRatio() public {
        address account = trader;
        address counterpartyAccount = address(0xBEEF);
        _fundTrader(trader, 100_000e6);
        _fundTrader(address(0xBEEF), 100_000e6);
        _open(counterpartyAccount, CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8);
        uint256 depth = pool.totalAssets();

        vm.expectRevert();
        _open(account, CfdTypes.Side.BULL, 600_000e18, 50_000e6, 1e8, depth);
    }

}

contract AuditFollowupFindingsFailing_RiskParamValidation is BasePerpTest {

    function obsolete_M2_ProposeRiskParamsRejectsBaseApyAboveMaxApy() public {
        CfdTypes.RiskParams memory params = _riskParams();
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        config.frozenCloseSpreadBps = engine.frozenCloseSpreadBps();
        vm.expectRevert();
        engineAdmin.proposeRiskConfig(config);
    }

    function test_M2_ProposeRiskParamsRejectsMaxSkewRatioAboveOne() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.maxSkewRatio = 1e18 + 1;
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        config.frozenCloseSpreadBps = engine.frozenCloseSpreadBps();
        vm.expectRevert();
        engineAdmin.proposeRiskConfig(config);
    }

}
