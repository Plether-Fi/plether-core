// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract AuditFollowupFindingsFailing_CloseSettlementShielding is BasePerpTest {

    address trader = address(0xC105E);

    function test_C1_LaterCommittedMarginMustNotShieldCloseLosses() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 1e18, 7_900e6, type(uint256).max, false);

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 103_000_000);

        assertEq(
            engine.accumulatedBadDebtUsdc(),
            0,
            "Later committed margin must not be able to shield close-loss settlement and create bad debt"
        );
    }

}

contract AuditFollowupFindingsFailing_StaleWithdrawals is BasePerpTest {

    address trader = address(0x57A1);

    function test_C2_LiveMarketWithdrawalMustRequireFreshPrice() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.warp(block.timestamp + 119);

        vm.prank(trader);
        vm.expectRevert(CfdEngine.CfdEngine__MarkPriceStale.selector);
        clearinghouse.withdraw(accountId, address(usdc), 100e6);
    }

}

contract AuditFollowupFindingsFailing_LiquidationBadDebt is BasePerpTest {

    address trader = address(0xA11CE);

    function test_C1_LiquidationMustRecordResidualBadDebtWithoutSubtractingBalanceTwice() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2_000e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(accountId, address(usdc), 8_000e6);

        vm.startPrank(address(router));
        engine.liquidatePosition(accountId, 101_900_000, pool.totalAssets(), uint64(block.timestamp));
        vm.stopPrank();

        assertEq(
            engine.accumulatedBadDebtUsdc(),
            112_850_000,
            "Residual deficit should be recorded as bad debt after seizing the full account balance"
        );
    }

}

contract AuditFollowupFindingsFailing_LiquidationBounty is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 10,
            fadMarginBps: 1000,
            minBountyUsdc: 1e6,
            bountyBps: 1000
        });
    }

    function test_H1_PositiveEquityLiquidationMustPayStandardBounty() public {
        address trader = address(0xA201);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 100e6);

        _open(accountId, CfdTypes.Side.BULL, 100e18, 6e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(accountId, address(usdc), 94e6);

        vm.startPrank(address(router));
        vm.warp(1_709_971_200);
        uint256 bounty = engine.liquidatePosition(accountId, 101_000_000, pool.totalAssets(), uint64(block.timestamp));
        vm.stopPrank();

        assertEq(
            bounty,
            10_100_000,
            "Keeper bounty should stay notional-based even when equity remains slightly positive"
        );
    }

}

contract AuditFollowupFindingsFailing_FundingReserve is BasePerpTest {

    address bullTraderA = address(0xB011);
    address bullTraderB = address(0xB012);
    address bearTrader = address(0xBEA2);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 1e18,
            maxApy: 5e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_H2_GetFreeUsdcMustReserveAllPositiveFundingWithoutNettingAgainstGlobalMargin() public {
        _fundJunior(address(this), 1_000_000e6);

        _fundTrader(bullTraderA, 15_000e6);
        _fundTrader(bullTraderB, 400_000e6);
        _fundTrader(bearTrader, 100_000e6);

        bytes32 bullIdA = bytes32(uint256(uint160(bullTraderA)));
        bytes32 bullIdB = bytes32(uint256(uint160(bullTraderB)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));

        _open(bullIdA, CfdTypes.Side.BULL, 390_000e18, 6_500e6, 1e8);
        _open(bullIdB, CfdTypes.Side.BULL, 10_000e18, 300_000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        vm.warp(block.timestamp + 180 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        CfdTypes.Position memory bullPosA;
        CfdTypes.Position memory bullPosB;
        CfdTypes.Position memory bearPos;
        {
            (uint256 size, uint256 margin, uint256 entryPrice,, int256 entryFunding, CfdTypes.Side side,,) = engine.positions(bullIdA);
            bullPosA = CfdTypes.Position(size, margin, entryPrice, 0, entryFunding, side, 0, 0);
        }
        {
            (uint256 size, uint256 margin, uint256 entryPrice,, int256 entryFunding, CfdTypes.Side side,,) = engine.positions(bullIdB);
            bullPosB = CfdTypes.Position(size, margin, entryPrice, 0, entryFunding, side, 0, 0);
        }
        {
            (uint256 size, uint256 margin, uint256 entryPrice,, int256 entryFunding, CfdTypes.Side side,,) = engine.positions(bearId);
            bearPos = CfdTypes.Position(size, margin, entryPrice, 0, entryFunding, side, 0, 0);
        }

        int256 bullFundingA = engine.getPendingFunding(bullPosA);
        int256 bullFundingB = engine.getPendingFunding(bullPosB);
        int256 bearFunding = engine.getPendingFunding(bearPos);
        assertLt(bullFundingA, -int256(bullPosA.margin), "Large undercollateralized bull should owe more funding than its own margin");
        assertGt(bullFundingA + bullFundingB, -int256(bullPosA.margin + bullPosB.margin), "Global bull margin should mask the single-account deficit");
        assertGt(bearFunding, 0, "Setup must make the bear side owed funding");

        uint256 bal = usdc.balanceOf(address(pool));
        uint256 maxLiability = engine.globalBullMaxProfit();
        uint256 pendingFees = engine.accumulatedFeesUsdc();
        uint256 expectedFree = bal > maxLiability + pendingFees + uint256(bearFunding)
            ? bal - maxLiability - pendingFees - uint256(bearFunding)
            : 0;

        assertEq(
            pool.getFreeUSDC(),
            expectedFree,
            "Free USDC should reserve all positive funding liabilities without netting them against global margin"
        );
    }

}

contract AuditFollowupFindingsFailing_TrancheComposability is BasePerpTest {

    address alice = address(0xA11CE);
    address helper = address(0xB0B);

    function test_M1_ThirdPartyTopUpForExistingHolderMustRemainComposable() public {
        _fundJunior(alice, 100_000e6);
        uint256 initialCooldown = juniorVault.lastDepositTime(alice);

        usdc.mint(helper, 10_000e6);
        vm.startPrank(helper);
        usdc.approve(address(juniorVault), 10_000e6);
        juniorVault.deposit(10_000e6, alice);
        vm.stopPrank();

        assertGt(juniorVault.balanceOf(alice), 100_000e9, "Third-party top-up should mint additional shares for the existing holder");
        assertEq(juniorVault.lastDepositTime(alice), initialCooldown, "Third-party top-up should not reset the holder cooldown");
    }

}

contract AuditFollowupFindingsFailing_AsyncCloseIntent is BasePerpTest {

    address trader = address(0xCAFE);

    function test_M2_CloseIntentCanBeQueuedBehindPendingOpenIntent() public {
        _fundTrader(trader, 50_000e6);

        vm.startPrank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 20_000e18, 5_000e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.BULL, 20_000e18, 0, 0, true);
        vm.stopPrank();

        assertEq(router.nextCommitId(), 3, "Async close intent should queue successfully behind the pending open order");
    }

}

contract AuditFollowupFindingsFailing_SkewCap is BasePerpTest {

    address trader = address(0x5E77);

    function test_M1_IncreaseMustRejectPostTradeSkewAboveMaxSkewRatio() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        bytes32 counterpartyId = bytes32(uint256(uint160(address(0xBEEF))));
        _fundTrader(trader, 100_000e6);
        _fundTrader(address(0xBEEF), 100_000e6);
        _open(counterpartyId, CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8);
        uint256 depth = pool.totalAssets();

        vm.expectRevert();
        _open(accountId, CfdTypes.Side.BULL, 600_000e18, 50_000e6, 1e8, depth);
    }

}

contract AuditFollowupFindingsFailing_RiskParamValidation is BasePerpTest {

    function test_M2_ProposeRiskParamsRejectsBaseApyAboveMaxApy() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.baseApy = params.maxApy + 1;

        vm.expectRevert();
        engine.proposeRiskParams(params);
    }

    function test_M2_ProposeRiskParamsRejectsMaxSkewRatioAboveOne() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.maxSkewRatio = 1e18 + 1;

        vm.expectRevert();
        engine.proposeRiskParams(params);
    }

}
