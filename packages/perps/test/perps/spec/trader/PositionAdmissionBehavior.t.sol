// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: spec. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/ACCOUNTING_SPEC.md#open-projection

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

contract PositionLotAdmissionTest is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#open-projection.
    function test_ScalingLargePositionRejectsSubLotIncreaseWithoutChangingExactBasis() public {
        address account = address(uint160(1));
        _fundTrader(account, 10_000e6);

        vm.startPrank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                account: account,
                sizeDelta: 1000e18,
                marginDelta: 2000e6,
                targetPrice: 150_000_001,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 1,
                side: CfdTypes.Side.LONG,
                isClose: false
            }),
            150_000_001,
            pool.totalAssets(),
            uint64(block.timestamp)
        );

        (uint256 sizeBefore,, uint256 entryPriceBefore,,,,) = engine.positions(account);
        uint256 entryCostBefore = engine.positionEntryCostUsdcAtoms(account);
        uint256 sideEntryNotionalBefore = _sideEntryNotional(CfdTypes.Side.LONG);
        uint256 poolDepth = pool.totalAssets();

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
                uint8(CfdEnginePlanTypes.OpenRevertCode.INVALID_SIZE_QUANTUM),
                false
            )
        );
        engine.processOrderTyped(
            CfdTypes.Order({
                account: account,
                sizeDelta: 1,
                marginDelta: 0,
                targetPrice: 150_000_000,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 2,
                side: CfdTypes.Side.LONG,
                isClose: false
            }),
            150_000_000,
            poolDepth,
            uint64(block.timestamp)
        );
        vm.stopPrank();

        (uint256 size,, uint256 entryPrice,,,,) = engine.positions(account);
        assertEq(size, sizeBefore, "Rejected sub-lot increase must not change position size");
        assertEq(entryPrice, entryPriceBefore, "Rejected sub-lot increase must not change entry price");
        assertEq(
            engine.positionEntryCostUsdcAtoms(account),
            entryCostBefore,
            "Rejected sub-lot increase must not change exact entry-cost atoms"
        );
        assertEq(
            _sideEntryNotional(CfdTypes.Side.LONG),
            sideEntryNotionalBefore,
            "Rejected sub-lot increase must not change aggregate entry notional"
        );
        assertEq(sideEntryNotionalBefore, size * entryPrice, "Whole-lot aggregate basis must remain exact");
        _assertTerminalCurveMatchesEngine(account);
    }

}

contract SingleDeltaSkewAdmissionTest is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.15e18,
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

    /// @dev spec; source: ACCOUNTING_SPEC.md#open-projection.
    function test_OpenSkewCapMustUseSingleSizeDelta() public {
        address shortTrader = address(0xBEA2);
        address longTrader = address(0xB011);

        address shortAccount = shortTrader;
        address longAccount = longTrader;

        _fundTrader(shortTrader, 60_000e6);
        _fundTrader(longTrader, 120_000e6);

        _open(shortAccount, CfdTypes.Side.SHORT, 100_000e18, 20_000e6, 1e8);
        _open(longAccount, CfdTypes.Side.LONG, 100_000e18, 20_000e6, 1e8);

        _open(longAccount, CfdTypes.Side.LONG, 100_000e18, 20_000e6, 1e8);

        (uint256 longSize,,,,,,) = engine.positions(longAccount);
        assertEq(longSize, 200_000e18, "Open-path skew cap should use the intended post-trade skew");
    }

}

contract ZeroSizeOrderAdmissionTest is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    /// @dev spec; source: ACCOUNTING_SPEC.md#open-projection.
    function test_ZeroSizeMarginUpdateRejectedAtCommit() public {
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ZeroSize.selector);
        router.commitOrder(CfdTypes.Side.LONG, 0, 500e6, 1e8, false);
    }

}

contract FeeAdjustedAdmissionTest is BasePerpTest {

    /// @dev spec; source: ACCOUNTING_SPEC.md#open-projection.
    function test_CommitPrefilterMustRejectFeeDrainedOpen() public {
        address trader = address(0xE113);
        address account = trader;
        uint256 sizeDelta = 100_000e18;
        uint256 marginDelta = 1500e6;

        _fundTrader(trader, 2000e6);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint8 revertCode = engineLens.previewOpenRevertCode(
            account, CfdTypes.Side.LONG, sizeDelta, marginDelta, 1e8, uint64(block.timestamp)
        );
        CfdEnginePlanTypes.OpenFailurePolicyCategory failureCategory = engineLens.previewOpenFailurePolicyCategory(
            account, CfdTypes.Side.LONG, sizeDelta, marginDelta, 1e8, uint64(block.timestamp)
        );

        assertEq(
            revertCode,
            uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN),
            "preview should include executionFeeBps when checking exact-threshold initial margin"
        );
        assertEq(
            uint256(failureCategory),
            uint256(CfdEnginePlanTypes.OpenFailurePolicyCategory.CommitTimeRejectable),
            "execution-fee invalid opens should be blocked at commit time"
        );

        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderRouterErrors.OrderRouter__PredictableOpenInvalid.selector,
                uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN)
            )
        );
        router.commitOrder(CfdTypes.Side.LONG, sizeDelta, marginDelta, 1e8, false);
    }

}

contract PostFeeInitialMarginTest is BasePerpTest {

    address alice = address(0x111);

    /// @dev spec; source: ACCOUNTING_SPEC.md#open-projection.
    function test_PostFeeMarginBelowImr() public {
        _fundTrader(alice, 100_000 * 1e6);
        address aliceAccount = alice;

        // Open 200k LONG tokens at $1.00
        // Notional = $200k, MMR = 1% = $2000, explicit IMR = 1.5% = $3000
        // marginDelta = $3070 → pre-fee passes IMR ($3070 >= $3000)
        // The $80 execution fee and dedicated liquidation reserve reduce the available PnL pledge
        // below $3000, so the typed initial-margin failure is expected.
        uint256 depth = pool.totalAssets();
        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector, 1, 6, false));
        vm.prank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                account: aliceAccount,
                sizeDelta: 200_000 * 1e18,
                marginDelta: 3070 * 1e6,
                targetPrice: 1e8,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: CfdTypes.Side.LONG,
                isClose: false
            }),
            1e8,
            depth,
            uint64(block.timestamp)
        );
    }

}

contract PendingOpenCloseAdmissionTest is BasePerpTest {

    address trader = address(0xCAFE);

    /// @dev spec; source: ACCOUNTING_SPEC.md#open-projection.
    function test_CloseIntentBehindPendingOpenIsRejected() public {
        _fundTrader(trader, 50_000e6);

        vm.startPrank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 20_000e18, 5000e6, 1e8, false);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__NoOpenPosition.selector);
        router.commitOrder(CfdTypes.Side.LONG, 20_000e18, 0, 0, true);
        vm.stopPrank();

        assertEq(
            router.nextCommitId(), 2, "Rejected close intent should not advance the queue behind the pending open order"
        );
    }

}

contract PostTradeSkewAdmissionTest is BasePerpTest {

    address trader = address(0x5E77);

    /// @dev spec; source: ACCOUNTING_SPEC.md#open-projection.
    function test_IncreaseMustRejectPostTradeSkewAboveMaxSkewRatio() public {
        address account = trader;
        address counterpartyAccount = address(0xBEEF);
        _fundTrader(trader, 100_000e6);
        _fundTrader(address(0xBEEF), 100_000e6);
        _open(counterpartyAccount, CfdTypes.Side.SHORT, 100_000e18, 10_000e6, 1e8);
        uint256 depth = pool.totalAssets();

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated,
                uint8(CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH),
                false
            )
        );
        _open(account, CfdTypes.Side.LONG, 600_000e18, 50_000e6, 1e8, depth);
    }

}

contract AccountPriceCollateralPositionTest is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
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
        return 1_000_000e6;
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#open-projection.
    function test_MarginOnlyUpdateViaRouterReverts() public {
        address aliceAccount = alice;
        _fundTrader(alice, 50_000e6);
        _open(aliceAccount, CfdTypes.Side.LONG, 20_000e18, 5000e6, 1e8);

        vm.prank(alice);
        (bool ok,) = address(router)
            .call(
                abi.encodeWithSelector(
                    bytes4(keccak256("commitOrder(uint8,uint256,uint256,uint256,bool)")),
                    CfdTypes.Side.LONG,
                    0,
                    500e6,
                    1e8,
                    false
                )
            );
        assertFalse(ok, "Margin-only updates must be rejected at commit time");
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#open-projection.
    function test_CloseWithMarginDeltaMustRevert() public {
        _fundTrader(alice, 50_000e6);
        _open(alice, CfdTypes.Side.LONG, 20_000e18, 5000e6, 1e8);
        vm.prank(alice);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__CloseWithPositiveMargin.selector);
        router.commitOrder(CfdTypes.Side.LONG, 20_000e18, 500e6, 0, true);
        assertEq(router.pendingOrderCounts(alice), 0);
    }

}

contract TinyCloseAdmissionTest is BasePerpTest {

    address attacker = address(0xBAD);

    /// @dev spec; source: ACCOUNTING_SPEC.md#open-projection.
    function test_TinyInvalidCloseBehindQueuedIntentIsRejectedAtCommit() public {
        address account = attacker;
        _fundTrader(attacker, 21e6);

        vm.prank(attacker);
        router.commitOrder(CfdTypes.Side.LONG, 1000e18, 20e6, 0, false);

        vm.prank(attacker);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidSizeQuantum.selector);
        router.commitOrder(CfdTypes.Side.LONG, 1, 0, 0, true);

        IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);
        assertEq(reservation.pendingOrderCount, 1, "Rejected close intent should not be queued behind the pending open");
    }

}

contract MarginAndReservationAdmissionPositionTest is BasePerpTest {

    address alice = address(0xA11CE);
    address attacker = address(0xBAD);

    /// @dev spec; source: ACCOUNTING_SPEC.md#open-projection.
    function test_UserCanAddMarginWithoutChangingSize() public {
        address account = alice;
        _fundTrader(alice, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 20_000e18, 5000e6, 1e8);

        (, uint256 marginBefore,,,,,) = engine.positions(account);
        vm.prank(alice);
        engine.addMargin(account, 500e6);

        (uint256 size, uint256 margin,,,,,) = engine.positions(account);
        assertEq(margin, marginBefore + 500e6, "Added margin increases pledge");
        assertEq(size, 20_000e18, "Margin adjustment preserves position size");
    }

}

contract VpiCollateralAdmissionTest is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.05e18,
            maxSkewRatio: 0.4e18,
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
        return 2_000_000e6;
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#open-projection.
    function test_ZeroMarginVpiRebateOpenRejectsUnfundedRebateReserve() public {
        _fundTrader(alice, 200_000e6);
        address aliceAccount = alice;
        // Alice creates LONG skew; pays VPI to open
        _open(aliceAccount, CfdTypes.Side.LONG, 300_000e18, 50_000e6, 1e8);

        // Bob attempts an opposing SHORT with zero margin. Its skew-reducing rebate must not
        // substitute for the required PnL pledge and protected reserves.
        _fundTrader(bob, 1e6);
        address bobAccount = bob;

        uint256 poolDepth = pool.totalAssets();
        vm.prank(address(router));
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
                uint8(CfdEnginePlanTypes.OpenRevertCode.VPI_REBATE_RESERVE_UNFUNDED),
                false
            )
        );
        engine.processOrderTyped(
            CfdTypes.Order({
                account: bobAccount,
                sizeDelta: 300_000e18,
                marginDelta: 0,
                targetPrice: 1e8,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: CfdTypes.Side.SHORT,
                isClose: false
            }),
            1e8,
            poolDepth,
            uint64(block.timestamp)
        );
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#open-projection.
    function test_NonzeroMarginRebateOpenProjectsFreshVpiLiability() public {
        _fundTrader(alice, 200_000e6);
        _open(alice, CfdTypes.Side.LONG, 300_000e18, 50_000e6, 1e8);

        _fundTrader(bob, 4000e6);

        uint8 code = engineLens.previewOpenRevertCode(
            bob, CfdTypes.Side.SHORT, 300_000e18, 4000e6, 1e8, uint64(block.timestamp)
        );
        assertEq(
            code,
            uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN),
            "planner should subtract fresh negative VPI liability before admitting the open"
        );

        uint256 vaultDepth = pool.totalAssets();
        vm.prank(address(router));
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
                uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN),
                false
            )
        );
        engine.processOrderTyped(
            CfdTypes.Order({
                account: bob,
                sizeDelta: 300_000e18,
                marginDelta: 4000e6,
                targetPrice: 1e8,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: CfdTypes.Side.SHORT,
                isClose: false
            }),
            1e8,
            vaultDepth,
            uint64(block.timestamp)
        );
    }

}

contract CloseSideAdmissionTest is BasePerpTest {

    address alice = address(0xA11CE);

    /// @dev spec; source: ACCOUNTING_SPEC.md#open-projection.
    function test_CloseCommitRejectsMismatchedSide() public {
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 1 ether);
        address account = alice;
        _open(account, CfdTypes.Side.LONG, 20_000e18, 5000e6, 1e8);

        vm.prank(alice);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__SideMismatch.selector);
        router.commitOrder(CfdTypes.Side.SHORT, 20_000e18, 0, 0, true);
    }

}

contract EmptyMarketSkewAdmissionTest is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
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

    /// @dev spec; source: ACCOUNTING_SPEC.md#open-projection.
    function test_EmptyMarketShouldStillEnforceMaxSkewRatio() public {
        address whale = address(0x5E77);
        address whaleAccount = whale;

        _fundTrader(whale, 100_000e6);

        uint256 depth = pool.totalAssets();
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated,
                uint8(CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH),
                false
            )
        );
        _open(whaleAccount, CfdTypes.Side.LONG, 500_000e18, 50_000e6, 1e8, depth);
    }

}

contract SingleTradeSkewAdmissionTest is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.15e18,
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

    /// @dev spec; source: ACCOUNTING_SPEC.md#open-projection.
    function test_SkewCapShouldUseSinglePostTradeSizeDelta() public {
        address shortTrader = address(0xBEA2);
        address longTrader = address(0xB011);

        address shortAccount = shortTrader;
        address longAccount = longTrader;

        _fundTrader(shortTrader, 60_000e6);
        _fundTrader(longTrader, 120_000e6);

        _open(shortAccount, CfdTypes.Side.SHORT, 100_000e18, 20_000e6, 1e8);
        _open(longAccount, CfdTypes.Side.LONG, 100_000e18, 20_000e6, 1e8);

        _open(longAccount, CfdTypes.Side.LONG, 100_000e18, 20_000e6, 1e8);

        (uint256 longSize,,,,,,) = engine.positions(longAccount);
        assertEq(longSize, 200_000e18, "Skew cap should evaluate the real post-trade open interest");
    }

}
