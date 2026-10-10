// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: accounting. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/ACCOUNTING_SPEC.md#degraded-mode

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

contract CloseContainmentTransitionsTest is BasePerpTest {

    address longTrader = address(0xB011);
    address shortTrader = address(0xBEA2);

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

    /// @dev accounting; source: ACCOUNTING_SPEC.md#degraded-mode.
    function test_ProfitableCloseLatchesDegradedModeWhenBackingFallsBelowLiability() public {
        address longAccount = longTrader;
        address shortAccount = shortTrader;

        _fundTrader(longTrader, 100_000e6);
        _fundTrader(shortTrader, 100_000e6);

        _open(shortAccount, CfdTypes.Side.SHORT, 999_000e18, 50_000e6, 1e8);
        _open(longAccount, CfdTypes.Side.LONG, 500_000e18, 50_000e6, 1e8);

        _close(longAccount, CfdTypes.Side.LONG, 500_000e18, 20_000_000);

        assertTrue(engine.degradedMode(), "Profitable close should latch degraded mode when it reveals insolvency");
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#degraded-mode.
    function test_DegradedModeBlocksNewOpensUntilRecapitalized() public {
        address longAccount = longTrader;
        address shortAccount = shortTrader;
        address newTrader = address(0xCAFE);
        address newTraderAccount = newTrader;

        _fundTrader(longTrader, 100_000e6);
        _fundTrader(shortTrader, 100_000e6);
        _fundTrader(newTrader, 100_000e6);

        _open(shortAccount, CfdTypes.Side.SHORT, 999_000e18, 50_000e6, 1e8);
        _open(longAccount, CfdTypes.Side.LONG, 500_000e18, 50_000e6, 1e8);
        _close(longAccount, CfdTypes.Side.LONG, 500_000e18, 20_000_000);

        assertTrue(engine.degradedMode(), "Setup must enter degraded mode");
        CfdTypes.Order memory blockedOpen = CfdTypes.Order({
            account: newTraderAccount,
            sizeDelta: 10_000e18,
            marginDelta: 1000e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: CfdTypes.Side.LONG,
            isClose: false
        });

        uint256 depthBefore = pool.totalAssets();
        uint256 balanceBefore = clearinghouse.balanceUsdc(newTraderAccount);
        (uint256 sizeBefore, uint256 marginBefore,,,,,) = engine.positions(newTraderAccount);
        assertEq(sizeBefore, 0, "the rejected order must attempt a new position");
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated,
                uint8(CfdEnginePlanTypes.OpenRevertCode.DEGRADED_MODE),
                false
            )
        );
        vm.prank(address(router));
        engine.processOrderTyped(blockedOpen, 1e8, depthBefore, uint64(block.timestamp));

        (uint256 sizeAfter, uint256 marginAfter,,,,,) = engine.positions(newTraderAccount);
        assertEq(sizeAfter, sizeBefore, "degraded admission must preserve the position size");
        assertEq(marginAfter, marginBefore, "degraded admission must preserve the position margin");
        assertEq(clearinghouse.balanceUsdc(newTraderAccount), balanceBefore);
        assertEq(pool.totalAssets(), depthBefore);
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#degraded-mode.
    function test_OwnerCanClearDegradedModeAfterRecapitalization() public {
        address longAccount = longTrader;
        address shortAccount = shortTrader;
        address newTrader = address(0xCAFE);
        address newTraderAccount = newTrader;

        _fundTrader(longTrader, 100_000e6);
        _fundTrader(shortTrader, 100_000e6);
        _fundTrader(newTrader, 100_000e6);

        _open(shortAccount, CfdTypes.Side.SHORT, 999_000e18, 50_000e6, 1e8);
        _open(longAccount, CfdTypes.Side.LONG, 500_000e18, 50_000e6, 1e8);
        _close(longAccount, CfdTypes.Side.LONG, 500_000e18, 20_000_000);

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
        _open(newTraderAccount, CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8);
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#degraded-mode.
    function test_TraderClaimDoesNotRequireDegradedModeWithoutOpenLiability() public {
        address longAccount = longTrader;

        _fundTrader(longTrader, 11_000e6);
        _open(longAccount, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(longAccount, CfdTypes.Side.LONG, 100_000e18, 80_000_000);

        assertGt(engine.traderClaimBalanceUsdc(longAccount), 0, "Setup should create a trader claim liability");
        assertFalse(
            engine.degradedMode(),
            "A standalone trader claim should not force degraded mode once bounded open liability is gone"
        );
    }

}

contract LiquidationContainmentTest is BasePerpTest {

    address winner = address(0xAAA1);
    address loser = address(0xBBB1);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 10,
            initMarginBps: ((10) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 150_500e6;
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#degraded-mode.
    function test_LiquidationThatCreatesInsolvencyMustLatchDegradedMode() public {
        address winnerAccount = winner;
        address loserAccount = loser;

        _fundTrader(winner, 100_000e6);
        _fundTrader(loser, 2000e6);

        _open(winnerAccount, CfdTypes.Side.LONG, 100_000e18, 100_000e6, 1.5e8);
        _open(loserAccount, CfdTypes.Side.SHORT, 100_000e18, 2000e6, 0.5e8);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 20_000e6);

        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(loserAccount, 0.1e8, depth, uint64(block.timestamp), address(this));

        assertTrue(
            engine.degradedMode(),
            "Liquidations that push effective assets below max liability must latch degraded mode"
        );
    }

}
