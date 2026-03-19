// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdMath} from "../../src/perps/CfdMath.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {ICfdEngine} from "../../src/perps/interfaces/ICfdEngine.sol";
import {IMarginClearinghouse} from "../../src/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "../../src/perps/interfaces/IOrderRouterAccounting.sol";
import {LiquidationAccountingLib} from "../../src/perps/libraries/LiquidationAccountingLib.sol";
import {PositionRiskAccountingLib} from "../../src/perps/libraries/PositionRiskAccountingLib.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
            size,
            oraclePrice,
            reachableCollateralUsdc,
            fundingUsdc,
            pnlUsdc,
            maintMarginBps,
            minBountyUsdc,
            bountyBps,
            tokenScale
        );
    }

}

contract CfdEngineTest is BasePerpTest {

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
        PositionRiskAccountingLib.FundingStepResult memory step = PositionRiskAccountingLib.computeFundingStep(
            PositionRiskAccountingLib.FundingStepInputs({
                price: engine.lastMarkPrice(),
                bullOi: _sideOpenInterest(CfdTypes.Side.BULL),
                bearOi: _sideOpenInterest(CfdTypes.Side.BEAR),
                timeDelta: block.timestamp - engine.lastFundingTime(),
                vaultDepthUsdc: vaultDepthUsdc,
                riskParams: _riskParams()
            })
        );
        return side == CfdTypes.Side.BULL
            ? _sideFundingIndex(CfdTypes.Side.BULL) + step.bullFundingIndexDelta
            : _sideFundingIndex(CfdTypes.Side.BEAR) + step.bearFundingIndexDelta;
    }

    function _previewFundingPnl(
        CfdTypes.Side side,
        uint256 openInterest,
        int256 entryFunding
    ) internal view returns (int256) {
        return (int256(openInterest) * _previewFundingIndex(side, pool.totalAssets()) - entryFunding)
            / int256(CfdMath.FUNDING_INDEX_SCALE);
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 1e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
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
                ICfdEngine.OrderExecutionFailureClass.ProtocolStateInvalidated,
                uint8(7),
                false
            )
        );
        vm.prank(address(router));
        engine.processOrderTyped(tooLarge, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));
    }

    function test_FundingAccumulation() public {
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

        vm.warp(block.timestamp + 365 days);

        CfdTypes.Order memory mmShort = CfdTypes.Order({
            accountId: account2,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 500 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.BEAR,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrder(mmShort, 1e8, vaultDepth, uint64(block.timestamp));

        int256 bullIndex = _sideFundingIndex(CfdTypes.Side.BULL);
        assertTrue(bullIndex < 0, "BULL index should decrease");

        int256 bearIndex = _sideFundingIndex(CfdTypes.Side.BEAR);
        assertTrue(bearIndex > 0, "BEAR index should increase");

        (uint256 size,, uint256 entryPrice,, int256 entryFunding, CfdTypes.Side side,,) = engine.positions(account1);

        CfdTypes.Position memory bullPos = CfdTypes.Position({
            size: size,
            margin: 0,
            entryPrice: entryPrice,
            maxProfitUsdc: 0,
            entryFundingIndex: entryFunding,
            side: side,
            lastUpdateTime: 0,
            vpiAccrued: 0
        });

        int256 bullFunding = engine.getPendingFunding(bullPos);
        assertTrue(bullFunding < 0, "Retail BULL should owe massive funding");
    }

    function test_AbsorbRouterCancellationFee_SyncsFundingBeforeVaultCashMutation() public {
        address trader = address(0xABC1);
        bytes32 traderId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 50_000e6);
        _open(traderId, CfdTypes.Side.BULL, 200_000e18, 20_000e6, 1e8);

        uint64 fundingBefore = engine.lastFundingTime();
        uint256 feesBefore = engine.accumulatedFeesUsdc();
        vm.warp(block.timestamp + 1 days);

        usdc.mint(address(router), 25e6);
        vm.prank(address(router));
        usdc.approve(address(engine), 25e6);

        vm.prank(address(router));
        engine.absorbRouterCancellationFee(25e6);

        assertEq(engine.lastFundingTime(), uint64(block.timestamp), "Absorbing router fees must sync funding first");
        assertGt(engine.lastFundingTime(), fundingBefore, "Funding timestamp should advance before fee absorption");
        assertEq(
            engine.accumulatedFeesUsdc() - feesBefore,
            25e6,
            "Absorbed cancellation fee should be booked as incremental protocol revenue"
        );
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

    function test_FullClose_WithPositiveFunding_DoesNotRevertWhenVaultIlliquid() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 bullId = bytes32(uint256(1));
        bytes32 bearId = bytes32(uint256(2));
        _fundTrader(address(uint160(uint256(bullId))), 5000 * 1e6);
        _fundTrader(address(uint160(uint256(bearId))), 5000 * 1e6);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, vaultDepth);
        _open(bearId, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, vaultDepth);

        vm.warp(block.timestamp + 365 days);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        _close(bearId, CfdTypes.Side.BEAR, 10_000e18, 1e8, vaultDepth);

        (uint256 size,,,,,,,) = engine.positions(bearId);
        assertEq(size, 0, "Illiquid positive-funding close should still destroy the position");
        assertGt(
            engine.deferredPayoutUsdc(bearId), 0, "Positive funding credit should roll into deferred trader payout"
        );
    }

    function test_PreviewClose_FullCloseWithPositiveFunding_ShowsDeferredPayoutWhenVaultIlliquid() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 bullId = bytes32(uint256(1));
        bytes32 bearId = bytes32(uint256(2));
        _fundTrader(address(uint160(uint256(bullId))), 5000 * 1e6);
        _fundTrader(address(uint160(uint256(bearId))), 5000 * 1e6);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, vaultDepth);
        _open(bearId, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, vaultDepth);

        vm.warp(block.timestamp + 365 days);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        CfdEngine.ClosePreview memory preview = engine.previewClose(bearId, 10_000e18, 1e8, vaultDepth);
        assertTrue(preview.valid, "Full close preview should remain valid under illiquid positive funding");
        assertEq(preview.immediatePayoutUsdc, 0, "Illiquid positive-funding close should not promise immediate cash");
        assertGt(preview.deferredPayoutUsdc, 0, "Preview should surface deferred payout from positive funding credit");
    }

    function test_PreviewClose_PartialCloseWithPositiveFunding_ShowsDeferredPayoutWhenVaultIlliquid() public {
        uint256 vaultDepth = 1_000_000 * 1e6;
        bytes32 bullId = bytes32(uint256(1));
        bytes32 bearId = bytes32(uint256(2));
        _fundTrader(address(uint160(uint256(bullId))), 5000 * 1e6);
        _fundTrader(address(uint160(uint256(bearId))), 5000 * 1e6);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8, vaultDepth);
        _open(bearId, CfdTypes.Side.BEAR, 10_000e18, 500e6, 1e8, vaultDepth);

        vm.warp(block.timestamp + 365 days);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        CfdEngine.ClosePreview memory preview = engine.previewClose(bearId, 5000e18, 1e8, vaultDepth);
        assertTrue(preview.valid, "Partial close preview should remain valid under illiquid positive funding");
        assertEq(preview.immediatePayoutUsdc, 0, "Illiquid positive-funding partial close should not promise cash");
        assertGt(preview.deferredPayoutUsdc, 0, "Preview should include deferred funding payout on partial close");

        _close(bearId, CfdTypes.Side.BEAR, 5000e18, 1e8, vaultDepth);

        assertEq(
            engine.deferredPayoutUsdc(bearId), preview.deferredPayoutUsdc, "Execution should match previewed deferment"
        );
        (uint256 remainingSize,,,,,,,) = engine.positions(bearId);
        assertEq(remainingSize, preview.remainingSize, "Partial close should preserve the residual position");
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

        _fundJunior(address(this), deferred);
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

        vm.prank(trader);
        vm.expectRevert(CfdEngine.CfdEngine__InsufficientVaultLiquidity.selector);
        engine.claimDeferredPayout(accountId);
    }

    function test_FundingSettlement_SyncsClearinghouse() public {
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
        engine.withdrawFees(treasury);

        assertEq(engine.accumulatedFeesUsdc(), 0, "Fees should reset to zero");
        assertEq(usdc.balanceOf(treasury), fees, "Treasury receives exact fee amount");

        vm.expectRevert(CfdEngine.CfdEngine__NoFeesToWithdraw.selector);
        engine.withdrawFees(treasury);
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
        router.commitOrder(CfdTypes.Side.BULL, 1e18, 7900 * 1e6, type(uint256).max, false);

        CfdEngine.AccountCollateralView memory viewData = engine.getAccountCollateralView(accountId);
        (, uint256 positionMargin,,,,,,) = engine.positions(accountId);
        assertEq(viewData.settlementBalanceUsdc, clearinghouse.balanceUsdc(accountId));
        assertEq(viewData.lockedMarginUsdc, clearinghouse.lockedMarginUsdc(accountId));
        assertEq(viewData.activePositionMarginUsdc, positionMargin);
        assertEq(viewData.otherLockedMarginUsdc, viewData.lockedMarginUsdc - positionMargin);
        assertEq(viewData.freeSettlementUsdc, clearinghouse.getFreeSettlementBalanceUsdc(accountId));
        assertEq(viewData.closeReachableUsdc, clearinghouse.getFreeSettlementBalanceUsdc(accountId));
        assertEq(viewData.terminalReachableUsdc, clearinghouse.getTerminalReachableUsdc(accountId));
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

        CfdEngine.PositionView memory viewData = engine.getPositionView(accountId);
        assertTrue(viewData.exists);
        assertEq(uint256(viewData.side), uint256(CfdTypes.Side.BULL));
        assertEq(viewData.size, 100_000 * 1e18);
        assertEq(viewData.entryPrice, 1e8);
        assertEq(viewData.entryNotionalUsdc, 100_000 * 1e6);
        assertGt(viewData.unrealizedPnlUsdc, 0);
        assertEq(viewData.maxProfitUsdc, 100_000 * 1e6);
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

        CfdEngine.ProtocolAccountingView memory viewData = engine.getProtocolAccountingView();
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

        ICfdEngine.ProtocolAccountingSnapshot memory snapshot = engine.getProtocolAccountingSnapshot();
        CfdEngine.ProtocolAccountingView memory viewData = engine.getProtocolAccountingView();
        ICfdEngine.HousePoolInputSnapshot memory housePoolSnapshot =
            engine.getHousePoolInputSnapshot(pool.markStalenessLimit());

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
        assertEq(snapshot.liabilityOnlyFundingPnlUsdc, engine.getLiabilityOnlyFundingPnl());
        assertEq(snapshot.totalDeferredPayoutUsdc, engine.totalDeferredPayoutUsdc());
        assertEq(snapshot.totalDeferredClearerBountyUsdc, engine.totalDeferredClearerBountyUsdc());
        assertEq(snapshot.degradedMode, engine.degradedMode());
        assertEq(snapshot.hasLiveLiability, engine.hasLiveLiability());
        assertEq(snapshot.vaultAssetsUsdc, viewData.vaultAssetsUsdc);
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

        ICfdEngine.ProtocolAccountingSnapshot memory beforeAccount = engine.getProtocolAccountingSnapshot();
        ICfdEngine.HousePoolInputSnapshot memory houseBefore = engine.getHousePoolInputSnapshot(pool.markStalenessLimit());

        assertEq(pool.rawAssets(), accountedBefore + 100_000e6, "Raw pool balance should include the donation");
        assertEq(pool.totalAssets(), accountedBefore, "Canonical pool assets should ignore the donation until accounted");
        assertEq(beforeAccount.vaultAssetsUsdc, accountedBefore, "Protocol snapshot should follow canonical assets");
        assertEq(houseBefore.netPhysicalAssetsUsdc, accountedBefore, "HousePool snapshot should ignore unaccounted donations");

        pool.accountExcess();

        ICfdEngine.ProtocolAccountingSnapshot memory afterAccount = engine.getProtocolAccountingSnapshot();
        ICfdEngine.HousePoolInputSnapshot memory houseAfter = engine.getHousePoolInputSnapshot(pool.markStalenessLimit());

        assertEq(pool.totalAssets(), accountedBefore + 100_000e6, "Explicit accounting should raise canonical pool assets");
        assertEq(afterAccount.vaultAssetsUsdc, accountedBefore + 100_000e6, "Protocol snapshot should reflect explicit accounting");
        assertEq(houseAfter.netPhysicalAssetsUsdc, accountedBefore + 100_000e6, "HousePool snapshot should reflect explicit accounting");
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

        ICfdEngine.AccountLedgerView memory ledgerView = engine.getAccountLedgerView(accountId);
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

        ICfdEngine.AccountLedgerSnapshot memory snapshot = engine.getAccountLedgerSnapshot(accountId);
        CfdEngine.AccountCollateralView memory collateralView = engine.getAccountCollateralView(accountId);
        CfdEngine.PositionView memory positionView = engine.getPositionView(accountId);
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
        assertEq(snapshot.hasPosition, positionView.exists);
        assertEq(uint256(snapshot.side), uint256(positionView.side));
        assertEq(snapshot.size, positionView.size);
        assertEq(snapshot.margin, positionView.margin);
        assertEq(snapshot.entryPrice, positionView.entryPrice);
        assertEq(snapshot.unrealizedPnlUsdc, positionView.unrealizedPnlUsdc);
        assertEq(snapshot.pendingFundingUsdc, positionView.pendingFundingUsdc);
        assertEq(snapshot.netEquityUsdc, positionView.netEquityUsdc);
        assertEq(snapshot.liquidatable, positionView.liquidatable);
    }

    function test_GetHousePoolInputSnapshot_ReflectsCurrentAccountingState() public {
        address trader = address(0xAB14);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 11_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        ICfdEngine.HousePoolInputSnapshot memory snapshot = engine.getHousePoolInputSnapshot(pool.markStalenessLimit());
        ICfdEngine.HousePoolStatusSnapshot memory status = engine.getHousePoolStatusSnapshot();
        uint256 fees = engine.accumulatedFeesUsdc();

        assertEq(
            snapshot.netPhysicalAssetsUsdc, pool.totalAssets() - fees, "Snapshot net assets must exclude protocol fees"
        );
        assertEq(snapshot.maxLiabilityUsdc, engine.getMaxLiability(), "Snapshot liability must match accessor");
        assertEq(
            snapshot.withdrawalFundingLiabilityUsdc,
            engine.getLiabilityOnlyFundingPnl(),
            "Snapshot funding liability must match accessor"
        );
        assertEq(
            snapshot.unrealizedMtmLiabilityUsdc,
            engine.getVaultMtmAdjustment(),
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

        ICfdEngine.HousePoolInputSnapshot memory snapshot = engine.getHousePoolInputSnapshot(pool.markStalenessLimit());
        ICfdEngine.HousePoolStatusSnapshot memory status = engine.getHousePoolStatusSnapshot();
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

        CfdEngine.ClosePreview memory normalPreview =
            engine.previewClose(accountId, 100_000e18, 80_000_000, pool.totalAssets());
        assertTrue(normalPreview.valid);
        assertGt(normalPreview.immediatePayoutUsdc, 0);
        assertEq(normalPreview.deferredPayoutUsdc, 0);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        CfdEngine.ClosePreview memory illiquidPreview =
            engine.previewClose(accountId, 100_000e18, 80_000_000, pool.totalAssets());
        assertTrue(illiquidPreview.valid);
        assertEq(illiquidPreview.immediatePayoutUsdc, 0);
        assertGt(illiquidPreview.deferredPayoutUsdc, 0);
        assertEq(illiquidPreview.remainingSize, 0);
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

        CfdEngine.ClosePreview memory preview = engine.previewClose(bullId, 500_000e18, 20_000_000, pool.totalAssets());
        assertTrue(preview.triggersDegradedMode, "Preview should flag the profitable close that reveals insolvency");

        _close(bullId, CfdTypes.Side.BULL, 500_000e18, 20_000_000);
        assertTrue(engine.degradedMode(), "Live close should match preview degraded-mode trigger");
    }

    function test_PreviewClose_RecomputesPostOpFundingClipForDegradedModeWithPendingAccrual() public {
        address bullTrader = address(0xAB130A);
        address bearTrader = address(0xAB130B);
        bytes32 bullId = bytes32(uint256(uint160(bullTrader)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));

        _fundTrader(bullTrader, 12_000e6);
        _fundTrader(bearTrader, 30_000e6);

        _open(bullId, CfdTypes.Side.BULL, 500_000e18, 8000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 50_000e18, 20_000e6, 1e8);

        vm.warp(block.timestamp + 365 days);

        (uint256 bullSize, uint256 bullMargin,, uint256 bullMaxProfit, int256 bullEntryFunding,,,) =
            engine.positions(bullId);
        int256 bullFundingAfter = 0;
        int256 bearFundingAfter = _previewFundingPnl(
            CfdTypes.Side.BEAR, _sideOpenInterest(CfdTypes.Side.BEAR), _sideEntryFunding(CfdTypes.Side.BEAR)
        );
        int256 currentFunding = engine.getCappedFundingPnl();
        int256 postFunding =
            _cappedFundingAfter(bullFundingAfter, bearFundingAfter, 0, _sideTotalMargin(CfdTypes.Side.BEAR));

        assertGt(
            postFunding, currentFunding, "Full close should remove the clipped funding receivable from solvency assets"
        );
        assertGt(postFunding, 0, "Setup must leave post-close funding as a solvency liability");

        CfdEngine.ClosePreview memory preDrainPreview = engine.previewClose(bullId, bullSize, 1e8, pool.totalAssets());
        assertTrue(preDrainPreview.valid, "Setup close preview should remain valid");

        uint256 targetAssets = _maxLiabilityAfterClose(CfdTypes.Side.BULL, bullMaxProfit) + engine.accumulatedFeesUsdc()
            + uint256(postFunding) - preDrainPreview.seizedCollateralUsdc - 1;
        uint256 currentAssets = pool.totalAssets();
        assertGt(currentAssets, targetAssets, "Test setup must be able to drain the vault into the funding-clip gap");

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), currentAssets - targetAssets);

        CfdEngine.ClosePreview memory preview = engine.previewClose(bullId, bullSize, 1e8, pool.totalAssets());
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

        CfdEngine.ClosePreview memory preview = engine.previewClose(bearId, 900_000e18, 20_000_000, pool.totalAssets());
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

        CfdEngine.ClosePreview memory preview = engine.previewClose(accountId, 100_000e18, 1e8, pool.totalAssets());

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
        router.commitOrder(CfdTypes.Side.BULL, 1e18, 900e6, type(uint256).max, false);

        uint256 freeSettlementBeforePreview = clearinghouse.getFreeSettlementBalanceUsdc(accountId);

        CfdEngine.ClosePreview memory preview =
            engine.previewClose(accountId, 50_000e18, 110_000_000, pool.totalAssets());

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

        CfdEngine.ClosePreview memory preview =
            engine.previewClose(accountId, 100_000 * 1e18, 80_000_000, pool.totalAssets());
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

        CfdEngine.ClosePreview memory preview =
            engine.previewClose(accountId, 100_000e18, 110_000_000, pool.totalAssets());
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

        CfdEngine.ClosePreview memory cappedPreview =
            engine.previewClose(accountId, 100_000e18, 2e8, pool.totalAssets());
        CfdEngine.ClosePreview memory overCapPreview =
            engine.previewClose(accountId, 100_000e18, 3e8, pool.totalAssets());

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

        CfdEngine.LiquidationPreview memory preview =
            engine.previewLiquidation(accountId, 101_000_000, pool.totalAssets());
        assertTrue(preview.liquidatable);
        assertEq(preview.keeperBountyUsdc, 15_150_000);
        assertLe(preview.keeperBountyUsdc, uint256(preview.equityUsdc));
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

        CfdEngine.PositionView memory viewData = engine.getPositionView(accountId);
        CfdEngine.LiquidationPreview memory preview = engine.previewLiquidation(accountId, 110_000_000, vaultDepth);

        assertTrue(viewData.liquidatable, "Position view should use current notional for maintenance threshold");
        assertTrue(preview.liquidatable, "Liquidation preview should use current notional for maintenance threshold");

        vm.prank(address(router));
        engine.liquidatePosition(accountId, 110_000_000, vaultDepth, uint64(block.timestamp));

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Live liquidation should agree with preview and position view");
    }

    function test_LiquidationPreview_InterfaceMatchesContractStructLayout() public {
        address trader = address(0xAB1402);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 2000e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 1105e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(accountId, 895e6);

        CfdEngine.LiquidationPreview memory contractPreview =
            engine.previewLiquidation(accountId, 110_000_000, pool.totalAssets());
        ICfdEngine.LiquidationPreview memory interfacePreview =
            ICfdEngine(address(engine)).previewLiquidation(accountId, 110_000_000, pool.totalAssets());

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

    function test_LiquidationPreview_ProjectsFundingAccrualLikeLiveUpdate() public {
        address trader = address(0xAB1403);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 2000e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 1105e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(accountId, 895e6);

        vm.warp(block.timestamp + 1 days);

        uint256 vaultDepth = pool.totalAssets();

        CfdEngine.LiquidationPreview memory projectedPreview =
            engine.previewLiquidation(accountId, 110_000_000, vaultDepth);

        vm.prank(address(router));
        engine.updateMarkPrice(110_000_000, uint64(block.timestamp));

        CfdEngine.LiquidationPreview memory fundedPreview =
            engine.previewLiquidation(accountId, 110_000_000, vaultDepth);

        assertApproxEqAbs(
            projectedPreview.fundingUsdc,
            fundedPreview.fundingUsdc,
            1,
            "Preview should include accrued funding before live update"
        );
        assertApproxEqAbs(
            projectedPreview.equityUsdc,
            fundedPreview.equityUsdc,
            1,
            "Projected funding should flow through liquidation equity"
        );
        assertEq(
            projectedPreview.keeperBountyUsdc,
            fundedPreview.keeperBountyUsdc,
            "Projected funding should align keeper bounty with live state"
        );
        assertEq(
            projectedPreview.liquidatable,
            fundedPreview.liquidatable,
            "Preview liquidatability should match the accrued live state"
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

        CfdEngine.LiquidationPreview memory preview =
            engine.previewLiquidation(accountId, 101_000_000, pool.totalAssets());
        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(101_000_000));
        vm.prank(keeper);
        router.executeLiquidation(accountId, priceData);

        assertEq(
            engine.deferredPayoutUsdc(accountId),
            preview.deferredPayoutUsdc,
            "Illiquid liquidation preview should match live deferred trader payout"
        );
        assertEq(
            engine.accumulatedBadDebtUsdc() - badDebtBefore,
            preview.badDebtUsdc,
            "Illiquid liquidation preview should match live bad debt"
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
            router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, type(uint256).max, false);
        }
        clearinghouse.withdraw(accountId, 70e6);
        vm.stopPrank();

        IOrderRouterAccounting.AccountEscrowView memory escrow = router.getAccountEscrow(accountId);
        CfdEngine.LiquidationPreview memory preview =
            engine.previewLiquidation(accountId, 102_500_000, pool.totalAssets());
        ICfdEngine.AccountLedgerSnapshot memory snapshot = engine.getAccountLedgerSnapshot(accountId);

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
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 300e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 200e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(accountId, 100e6);

        CfdEngine.LiquidationPreview memory preview =
            engine.previewLiquidation(accountId, 101_000_000, pool.totalAssets());

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(101_000_000));
        vm.prank(address(0xAB1411));
        router.executeLiquidation(accountId, priceData);

        assertEq(
            preview.triggersDegradedMode,
            engine.degradedMode(),
            "Liquidation preview should match live degraded-mode outcome"
        );
    }

    function test_PreviewLiquidation_RecomputesPostOpFundingClipForDegradedModeWithPendingAccrual() public {
        address bullTrader = address(0xAB1412);
        address bearTrader = address(0xAB1413);
        bytes32 bullId = bytes32(uint256(uint160(bullTrader)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));

        _fundTrader(bullTrader, 12_000e6);
        _fundTrader(bearTrader, 30_000e6);

        _open(bullId, CfdTypes.Side.BULL, 500_000e18, 8000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 50_000e18, 20_000e6, 1e8);

        vm.warp(block.timestamp + 365 days);

        int256 currentFunding = engine.getCappedFundingPnl();
        int256 bearFundingAfter = _previewFundingPnl(
            CfdTypes.Side.BEAR, _sideOpenInterest(CfdTypes.Side.BEAR), _sideEntryFunding(CfdTypes.Side.BEAR)
        );
        int256 postFunding = _cappedFundingAfter(0, bearFundingAfter, 0, _sideTotalMargin(CfdTypes.Side.BEAR));
        assertGt(
            postFunding, currentFunding, "Liquidation should remove the clipped funding receivable from solvency assets"
        );
        assertGt(postFunding, 0, "Setup must leave post-liquidation funding as a solvency liability");

        CfdEngine.LiquidationPreview memory preDrainPreview = engine.previewLiquidation(bullId, 1e8, pool.totalAssets());
        assertTrue(preDrainPreview.liquidatable, "Setup must produce a liquidatable position");

        uint256 bearMaxProfit = _sideMaxProfit(CfdTypes.Side.BEAR);
        uint256 targetAssets = bearMaxProfit + engine.accumulatedFeesUsdc() + uint256(postFunding)
            + preDrainPreview.keeperBountyUsdc - preDrainPreview.seizedCollateralUsdc - 1;
        uint256 currentAssets = pool.totalAssets();
        assertGt(currentAssets, targetAssets, "Test setup must be able to drain the vault into the funding-clip gap");

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), currentAssets - targetAssets);

        CfdEngine.LiquidationPreview memory preview = engine.previewLiquidation(bullId, 1e8, pool.totalAssets());
        assertTrue(
            preview.triggersDegradedMode,
            "Liquidation preview should use post-liquidation funding clip when testing degraded mode"
        );

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
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

        CfdEngine.DeferredPayoutStatus memory statusBefore = engine.getDeferredPayoutStatus(accountId, address(this));
        assertGt(statusBefore.deferredTraderPayoutUsdc, 0);
        assertFalse(statusBefore.traderPayoutClaimableNow);

        _fundJunior(address(this), statusBefore.deferredTraderPayoutUsdc);

        CfdEngine.DeferredPayoutStatus memory statusAfter = engine.getDeferredPayoutStatus(accountId, address(this));
        assertTrue(statusAfter.traderPayoutClaimableNow);
    }

    function test_DeferredClearerBounty_Lifecycle() public {
        address keeper = address(0xAB1601);
        uint256 deferredBounty = 25e6;

        vm.prank(address(router));
        engine.recordDeferredClearerBounty(keeper, deferredBounty);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets);

        CfdEngine.ProtocolAccountingView memory protocolViewBefore = engine.getProtocolAccountingView();
        CfdEngine.DeferredPayoutStatus memory statusBefore = engine.getDeferredPayoutStatus(bytes32(0), keeper);
        assertEq(protocolViewBefore.totalDeferredClearerBountyUsdc, deferredBounty);
        assertEq(statusBefore.deferredClearerBountyUsdc, deferredBounty);
        assertFalse(
            statusBefore.liquidationBountyClaimableNow,
            "Deferred clearer bounty should be unclaimable while vault is illiquid"
        );

        _fundJunior(address(this), deferredBounty);

        CfdEngine.DeferredPayoutStatus memory statusAfterFunding = engine.getDeferredPayoutStatus(bytes32(0), keeper);
        assertTrue(
            statusAfterFunding.liquidationBountyClaimableNow,
            "Deferred clearer bounty should become claimable once vault liquidity returns"
        );

        uint256 keeperBalanceBefore = usdc.balanceOf(keeper);
        vm.prank(keeper);
        engine.claimDeferredClearerBounty();

        CfdEngine.ProtocolAccountingView memory protocolViewAfter = engine.getProtocolAccountingView();
        assertEq(usdc.balanceOf(keeper) - keeperBalanceBefore, deferredBounty);
        assertEq(engine.deferredClearerBountyUsdc(keeper), 0);
        assertEq(protocolViewAfter.totalDeferredClearerBountyUsdc, 0);
    }

    function test_CloseLoss_ConsumesQueuedCommittedMarginBeforeBadDebt() public {
        address trader = address(0xABD0);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000 * 1e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 1e18, 7900e6, type(uint256).max, false);

        uint256 lockedBeforeClose = clearinghouse.lockedMarginUsdc(accountId);
        (, uint256 liveMarginBeforeClose,,,,,,) = engine.positions(accountId);
        uint256 badDebtBefore = engine.accumulatedBadDebtUsdc();

        _close(accountId, CfdTypes.Side.BULL, 100_000 * 1e18, 103_000_000);

        assertLt(
            router.committedMargins(1),
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
                ICfdEngine.OrderExecutionFailureClass.UserOrderInvalid,
                uint8(1),
                false
            )
        );
        vm.prank(address(router));
        engine.processOrderTyped(bullOrder, 0.8e8, 1_000_000 * 1e6, uint64(block.timestamp));
    }

    function test_FundingSettlement_ExceedsMargin_Reverts() public {
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

        vm.warp(block.timestamp + 365 days);

        CfdTypes.Order memory addOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: 1000 * 1e18,
            marginDelta: 1000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        vm.expectRevert(CfdEngine.CfdEngine__FundingExceedsMargin.selector);
        vm.prank(address(router));
        engine.processOrder(addOrder, 1e8, vaultDepth, uint64(block.timestamp));
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
                kinkSkewRatio: 0.25e18,
                baseApy: 0.15e18,
                maxApy: 3.0e18,
                maintMarginBps: 300,
                fadMarginBps: 500,
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
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);

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
                kinkSkewRatio: 0.25e18,
                baseApy: 0.15e18,
                maxApy: 3.0e18,
                maintMarginBps: 100,
                fadMarginBps: 300,
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

        // Open BULL 100k tokens at $1.00 with $1600 margin (meets 1.5x initial margin)
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
        _fundTrader(address(uint160(uint256(accountId))), 10_000 * 1e6);

        // notional = 100k * $1 = $100k. execFee = $60, VPI ~= $2.50
        // MMR = 1% of $100k = $1000
        // marginDelta = $100 covers fees but leaves pos.margin ~= $37, far below MMR
        // Without initial margin check, this succeeds and creates an instantly-liquidatable position
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
                kinkSkewRatio: 0.25e18,
                baseApy: 0.15e18,
                maxApy: 3.0e18,
                maintMarginBps: 10,
                fadMarginBps: 10,
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
        usdc.mint(address(this), clearAmount);
        usdc.approve(address(engine), clearAmount);
        engine.clearBadDebt(clearAmount);
        assertEq(engine.accumulatedBadDebtUsdc(), badDebt - clearAmount, "Bad debt should decrease after clearing");

        vm.expectRevert(CfdEngine.CfdEngine__BadDebtTooLarge.selector);
        engine.clearBadDebt(badDebt + 1);
    }

    function test_CheckWithdraw_UsesPoolMarkStalenessLimit() public {
        pool.proposeMarkStalenessLimit(300);
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizeMarkStalenessLimit();
        assertEq(pool.markStalenessLimit(), 300);

        bytes32 accountId = bytes32(uint256(0x5157));
        _fundTrader(address(uint160(uint256(accountId))), 5000 * 1e6);
        _open(accountId, CfdTypes.Side.BULL, 20_000 * 1e18, 2000 * 1e6, 1e8);

        vm.warp(block.timestamp + 31);

        vm.expectRevert(CfdEngine.CfdEngine__MarkPriceStale.selector);
        engine.checkWithdraw(accountId);
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

}

// ==========================================
// CfdEngineFundingTest: funding edge cases (C-01, C-02, C-03)
// ==========================================

contract CfdEngineFundingTest is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.5e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
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

        uint256 mtm = engine.getVaultMtmAdjustment();
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

    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
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

    // Regression: Finding-4
    function test_AsyncFundingDoesNotBlockLegitOrders() public {
        _fundJunior(bob, 210_000 * 1e6);

        address dave = address(0x444);
        _fundTrader(carol, 50_001 * 1e6);
        _fundTrader(dave, 200_001 * 1e6);

        vm.prank(dave);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000 * 1e18, 200_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 50_000 * 1e18, 5000 * 1e6, 1e8, false);
        router.executeOrder(2, empty);

        bytes32 carolAccount = bytes32(uint256(uint160(carol)));
        (uint256 sizeBefore,,,,,,,) = engine.positions(carolAccount);

        vm.warp(block.timestamp + 91 days);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        router.executeOrder(3, empty);

        (uint256 sizeAfter,,,,,,,) = engine.positions(carolAccount);

        assertGt(sizeAfter, sizeBefore, "Collectible funding receivables should no longer block legitimate increases");
        assertLe(
            engine.getCappedFundingPnl(),
            0,
            "Solvency funding should not overstate trader liabilities once receivables are netted"
        );
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
            kinkSkewRatio: 0.25e18,
            baseApy: 3.0e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
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
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
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
        uint256 cappedMtm = engine.getVaultMtmAdjustment();

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

        uint256 mtm = engine.getVaultMtmAdjustment();
        assertGt(mtm, 0, "Positive MtM = vault liability when traders are winning (no cap needed)");
    }

    function test_MtmAdjustment_ZeroWithNoPositions() public {
        _fundJunior(bob, 500_000e6);
        assertEq(engine.getVaultMtmAdjustment(), 0, "MtM should be zero with no positions");
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
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
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
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    // Regression: negative funding receivables
    function test_GetFreeUSDC_IgnoresNegativeFunding() public {
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

        _warpForward(30 days);

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

        int256 unrealizedFunding = engine.getUnrealizedFundingPnl();
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
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 100,
            fadMarginBps: 300,
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
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 100,
            fadMarginBps: 300,
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

        ICfdEngine.ProtocolStatus memory status = engine.getProtocolStatus();
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
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
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
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "juniorUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        engine.setOrderRouter(address(this));

        clearinghouse.setEngine(address(engine));
        vm.warp(1_709_532_000);

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
            kinkSkewRatio: 0.25e18,
            baseApy: 0.5e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5e6,
            bountyBps: 15
        });
    }

    function _liveEffectiveAssets(
        uint256 pendingPayoutUsdc
    ) internal view returns (uint256) {
        uint256 vaultAssets = pool.totalAssets() + pendingPayoutUsdc;
        uint256 fees = engine.accumulatedFeesUsdc();
        int256 funding = engine.getCappedFundingPnl();
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

        _fundTrader(bullTrader, 30_000e6);
        _fundTrader(bearTrader, 100_000e6);

        _open(bullId, CfdTypes.Side.BULL, 500_000e18, 20_000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8);

        vm.warp(block.timestamp + 180 days);

        CfdEngine.LiquidationPreview memory preview = engine.previewLiquidation(bullId, 1e8, pool.totalAssets());
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

        CfdEngine.ClosePreview memory preview = engine.previewClose(bullIdA, sizeA, 1e8, pool.totalAssets());
        assertTrue(preview.valid, "Close preview must be valid");

        _close(bullIdA, CfdTypes.Side.BULL, sizeA, 1e8);

        int256 liveFunding = engine.getCappedFundingPnl();
        assertEq(
            preview.solvencyFundingPnlUsdc,
            liveFunding,
            "Close preview solvency funding must match live post-close capped funding"
        );
    }

}
