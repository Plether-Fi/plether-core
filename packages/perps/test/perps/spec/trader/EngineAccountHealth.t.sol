// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract CfdEngineAccountBehaviorTest is BasePerpTest {

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
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_IncreaseWithSufficientSettlementSurvivesCarryAccrual() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(carol, 50_000 * 1e6);

        address account = carol;

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.LONG, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        (uint256 sizeAfterOpen,,,,,,) = engine.positions(account);

        vm.warp(block.timestamp + 182 days);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.LONG, 1000 * 1e18, 500 * 1e6, 1e8, false);
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
        _fundTrader(trader, 1040 * 1e6);
        _open(account, CfdTypes.Side.LONG, 50_000 * 1e18, 1000 * 1e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(101_800_000, uint64(block.timestamp));

        uint8 revertCode = engineLens.previewOpenRevertCode(
            account, CfdTypes.Side.LONG, 10_000 * 1e18, 20 * 1e6, 101_800_000, uint64(block.timestamp)
        );
        assertEq(
            revertCode,
            uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN),
            "Preview should reject increases backed only by stale stored margin"
        );

        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 20 * 1e6,
            targetPrice: 101_800_000,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: CfdTypes.Side.LONG,
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
        _fundTrader(trader, 1040 * 1e6);
        _open(account, CfdTypes.Side.LONG, 50_000 * 1e18, 1000 * 1e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(102_000_000, uint64(block.timestamp));

        PerpsViewTypes.PositionView memory positionView = _publicPosition(account);
        assertTrue(positionView.liquidatable, "Setup must make the existing position liquidatable before the increase");

        uint8 revertCode = engineLens.previewOpenRevertCode(
            account, CfdTypes.Side.LONG, 10_000 * 1e18, 20 * 1e6, 102_000_000, uint64(block.timestamp)
        );
        CfdEnginePlanTypes.OpenFailurePolicyCategory failureCategory = engineLens.previewOpenFailurePolicyCategory(
            account, CfdTypes.Side.LONG, 10_000 * 1e18, 20 * 1e6, 102_000_000, uint64(block.timestamp)
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
            marginDelta: 20 * 1e6,
            targetPrice: 102_000_000,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: CfdTypes.Side.LONG,
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

    function test_UnhealthyPartialClosePreservesAllBackingUntilLiquidation() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 22_000 * 1e6);

        address account = alice;

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.SHORT, 200_000 * 1e18, 20_000 * 1e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        (uint256 openSize, uint256 openMargin,,,,,) = engine.positions(account);
        assertEq(openSize, 200_000 * 1e18);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000 * 1e18, 0.8e8);
        assertFalse(preview.valid, "unhealthy partial remainders must be rejected");
        assertEq(uint8(preview.invalidReason), uint8(CfdTypes.CloseInvalidReason.PartialCloseUnhealthy));

        bytes[] memory priceData = _mockPythUpdateData(0.8e8);
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        preview = engineLens.previewClose(account, 100_000e18, 0.8e8);
        uint256 depth = pool.totalAssets();
        vm.expectRevert(
            abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector, uint8(1), uint8(6), true)
        );
        _close(account, CfdTypes.Side.SHORT, 100_000e18, 0.8e8, depth);

        (uint256 remainingSize, uint256 remainingMargin,,,,,) = engine.positions(account);
        assertEq(remainingSize, openSize, "Rejected reduction leaves size unchanged");
        assertEq(remainingMargin, openMargin, "Rejected reduction preserves pledge");
        assertEq(
            clearinghouse.pnlPledgeUsdc(account),
            remainingMargin,
            "The surviving position's canonical PnL pledge must stay locked"
        );

        uint256 balAfter = clearinghouse.balanceUsdc(account);
        uint256 lockedAfter = clearinghouse.lockedMarginUsdc(account);
        assertGe(balAfter, lockedAfter, "Physical balance must cover locked margin (zombie prevention)");

        router.executeLiquidation(account, priceData);

        (uint256 sizeAfterLiq,,,,,,) = engine.positions(account);
        assertEq(sizeAfterLiq, 0, "Remaining position should be fully liquidated");
    }

    struct CarryRateChangeModel {
        uint256 openedAt;
        uint256 finalizedAt;
        uint256 utilizationBps;
        uint256 oldRateIndex;
        uint256 finalIndex;
        uint256 expectedCarryUsdc;
        uint256 poolBefore;
        uint256 settlementBefore;
        uint256 initialPledgeUsdc;
        uint256 initialBorrowBaseUsdc;
    }

    function test_FinalizeRiskParams_NoRetroactiveCarryEffect() public {
        _fundJunior(bob, 1_000_000e6);
        _fundTrader(carol, 200_000e6);
        _open(carol, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        CarryRateChangeModel memory model;
        model.openedAt = block.timestamp;
        model.finalizedAt = model.openedAt + 3 days + 1;
        model.poolBefore = usdc.balanceOf(address(pool));
        model.settlementBefore = clearinghouse.balanceUsdc(carol);
        // The supplied $10,000 first pays a 4-bps execution fee and funds a 10-bps liquidation reserve.
        // The remaining $9,860 pledge funds part of the $100,000 maximum-profit envelope.
        assertEq(engine.executionFeeBps(), 4);
        model.initialPledgeUsdc = 10_000e6 - 100_000e6 * 4 / 10_000 - 100_000e6 * 10 / 10_000;
        model.initialBorrowBaseUsdc = 100_000e6 - model.initialPledgeUsdc;
        assertEq(clearinghouse.liquidationReserveUsdc(carol), 100_000e6 * 10 / 10_000);
        assertEq(clearinghouse.pnlPledgeUsdc(carol), model.initialPledgeUsdc);
        assertEq(engine.sideBorrowBaseUsdc(uint256(CfdTypes.Side.LONG)), model.initialBorrowBaseUsdc);
        assertEq(pool.totalAssets(), model.poolBefore);
        assertEq(engine.sideCarryIndex(uint256(CfdTypes.Side.LONG)), 0);
        (uint256 borrowBase, uint256 accountIndex, uint64 accountTime) = engine.positionCarryState(carol);
        assertEq(borrowBase, model.initialBorrowBaseUsdc);
        assertEq(accountIndex, 0);
        assertEq(accountTime, model.openedAt);
        model.utilizationBps = model.initialBorrowBaseUsdc * 10_000 / model.poolBefore;
        assertGt(model.utilizationBps, 0);
        assertLt(model.utilizationBps, 10_000);

        vm.warp(model.openedAt + 1 days);
        ICfdEngineAdminHost.EngineRiskConfig memory config = _engineRiskConfig();
        assertEq(config.riskParams.baseCarryBps, 500);
        assertEq(config.riskParams.bountyBps, 10);
        assertEq(config.riskParams.minBountyUsdc, 1e6);
        config.riskParams.baseCarryBps = 1500;
        engineAdmin.proposeRiskConfig(config);

        vm.warp(model.finalizedAt);
        // No preceding mark refresh or manual checkpoint may mask finalization's own old-rate checkpoint.
        engineAdmin.finalizeRiskConfig();
        model.oldRateIndex =
            500 * model.utilizationBps * 1e18 * (model.finalizedAt - model.openedAt) / (365 days * 10_000 * 10_000);
        assertGt(model.oldRateIndex, 0);
        assertEq(engine.sideCarryIndex(uint256(CfdTypes.Side.LONG)), model.oldRateIndex);
        assertEq(engine.sideCarryTimestamp(uint256(CfdTypes.Side.LONG)), model.finalizedAt);
        (, accountIndex, accountTime) = engine.positionCarryState(carol);
        assertEq(accountIndex, 0, "changing the rate checkpoints global indexes without collecting the position");
        assertEq(accountTime, model.openedAt);
        assertEq(clearinghouse.balanceUsdc(carol), model.settlementBefore);
        assertEq(usdc.balanceOf(address(pool)), model.poolBefore);

        vm.warp(model.finalizedAt + 1 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        model.finalIndex =
            model.oldRateIndex + 1500 * model.utilizationBps * 1e18 * 1 days / (365 days * 10_000 * 10_000);
        assertEq(engine.sideCarryIndex(uint256(CfdTypes.Side.LONG)), model.finalIndex);
        assertGt(model.finalIndex, model.oldRateIndex);
        model.expectedCarryUsdc = model.initialBorrowBaseUsdc * model.finalIndex / 1e18;
        assertGt(model.expectedCarryUsdc, 0);

        vm.prank(carol);
        engine.addMargin(carol, 1e6);
        assertEq(clearinghouse.balanceUsdc(carol), model.settlementBefore - model.expectedCarryUsdc);
        assertEq(usdc.balanceOf(address(pool)), model.poolBefore + model.expectedCarryUsdc);
        assertEq(engine.unsettledCarryUsdc(carol), 0);
        (, uint256 marginAfter,,,,,) = engine.positions(carol);
        assertEq(marginAfter, model.initialPledgeUsdc - model.expectedCarryUsdc + 1e6);
        (borrowBase, accountIndex, accountTime) = engine.positionCarryState(carol);
        assertEq(borrowBase, model.initialBorrowBaseUsdc + model.expectedCarryUsdc - 1e6);
        assertEq(accountIndex, model.finalIndex);
        assertEq(accountTime, block.timestamp);
    }

    // free equity withdrawable with open position
    function test_WithdrawFreeEquityWithOpenPosition() public {
        _fundJunior(bob, 500_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        address account = alice;

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 10_000 * 1e6, 1e8, false);
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
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 10_000 * 1e6, 1e8, false);
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
