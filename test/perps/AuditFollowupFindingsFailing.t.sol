// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

// Audit-history file: tests prefixed with `obsolete_` preserve superseded findings for context only.
// They are intentionally not statements about the live carry model or current accounting semantics.

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {ICfdEngineAdminHost} from "../../src/perps/interfaces/ICfdEngineAdminHost.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TrancheCooldownBypassReceiver {

    function approveAsset(
        TrancheVault vault,
        uint256 amount
    ) external {
        IERC20(vault.asset()).approve(address(vault), amount);
    }

    function withdrawMax(
        TrancheVault vault,
        address receiver
    ) external {
        uint256 assets = vault.maxWithdraw(address(this));
        vault.withdraw(assets, receiver, address(this));
    }

}

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
            bountyBps: 10
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
        vm.prank(address(router));
        (bool ok,) = address(engine)
            .call(
                abi.encodeWithSelector(
                    engine.processOrderTyped.selector,
                    CfdTypes.Order({
                        account: newTraderAccount,
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

        vm.expectRevert(CfdEngine.CfdEngine__StillInsolvent.selector);
        engine.clearDegradedMode();

        _fundJunior(address(this), 500_000e6);
        engine.clearDegradedMode();

        assertFalse(engine.degradedMode(), "Owner should clear degraded mode after recapitalization restores solvency");
        _open(newTraderAccount, CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8);
    }

    function test_C3_DeferredTraderCreditDoesNotRequireDegradedModeWithoutOpenLiability() public {
        address bullAccount = bullTrader;

        _fundTrader(bullTrader, 11_000e6);
        _open(bullAccount, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(bullAccount, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        assertGt(engine.deferredTraderCreditUsdc(bullAccount), 0, "Setup should create a deferred payout liability");
        assertFalse(
            engine.degradedMode(),
            "A standalone deferred payout should not force degraded mode once bounded open liability is gone"
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

        vm.startPrank(address(router));
        engine.liquidatePosition(account, 101_900_000, pool.totalAssets(), uint64(block.timestamp), address(this));
        vm.stopPrank();

        assertEq(
            engine.accumulatedBadDebtUsdc(),
            0,
            "Liquidation should not manufacture bad debt after seizing reachable account balance"
        );
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
            bountyBps: 1000
        });
    }

    function test_H1_PositiveEquityLiquidationUsesExplicitSubsidy() public {
        address trader = address(0xA201);
        address account = trader;

        _fundTrader(trader, 100e6);

        _open(account, CfdTypes.Side.BULL, 100e18, 6e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 94e6);

        vm.startPrank(address(router));
        vm.warp(1_709_971_200);
        uint256 bounty =
            engine.liquidatePosition(account, 101_000_000, pool.totalAssets(), uint64(block.timestamp), address(this));
        vm.stopPrank();

        assertGt(bounty, 0, "Keeper bounty should stay positive for a still-positive-equity liquidation");
        assertGe(bounty, 5e6, "Keeper bounty subsidy should avoid a near-zero positive-equity cliff");
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
            bountyBps: 10
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

        int256 bullFundingA = 0;
        int256 bullFundingB = 0;
        int256 bearLegacySpread = 0;
        assertLt(
            bullFundingA,
            -int256(bullPosA.margin),
            "Large undercollateralized bull should owe more legacy spread than its own margin in the obsolete model"
        );
        assertGt(
            bullFundingA + bullFundingB,
            -int256(bullPosA.margin + bullPosB.margin),
            "Global bull margin should mask the single-account deficit"
        );
        assertGt(bearLegacySpread, 0, "Setup must make the bear side owed legacy spread");

        uint256 bal = usdc.balanceOf(address(pool));
        uint256 maxLiability = _sideMaxProfit(CfdTypes.Side.BULL);
        uint256 pendingFees = engine.accumulatedFeesUsdc();
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
        vm.expectRevert(TrancheVault.TrancheVault__ThirdPartyDepositForExistingHolder.selector);
        juniorVault.deposit(4999e6, alice);
        vm.stopPrank();
    }

}

contract AuditFollowupFindingsFailing_TrancheCooldownBypass is BasePerpTest {

    address attacker = address(0xBAD);

    function test_H1_TwoContractThirdPartyDepositForExistingHolderMustRevert() public {
        TrancheCooldownBypassReceiver receiver = new TrancheCooldownBypassReceiver();
        address receiverAddr = address(receiver);

        usdc.mint(receiverAddr, 1);
        vm.prank(receiverAddr);
        receiver.approveAsset(juniorVault, 1);
        vm.prank(receiverAddr);
        juniorVault.deposit(1, receiverAddr);

        vm.warp(block.timestamp + 1 hours + 1);

        usdc.mint(attacker, 10_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), 10_000e6);
        vm.expectRevert(TrancheVault.TrancheVault__ThirdPartyDepositForExistingHolder.selector);
        juniorVault.deposit(10_000e6, receiverAddr);
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
        vm.expectRevert();
        engineAdmin.proposeRiskConfig(config);
    }

    function test_M2_ProposeRiskParamsRejectsMaxSkewRatioAboveOne() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.maxSkewRatio = 1e18 + 1;
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        vm.expectRevert();
        engineAdmin.proposeRiskConfig(config);
    }

}
