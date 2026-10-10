// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

contract DegradedModeLifecycleTest is BasePerpTest {

    address longTrader = address(0xD001);
    address shortTrader = address(0xD002);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _enterDegradedMode() internal {
        address longAccount = longTrader;
        address shortAccount = shortTrader;

        _fundTrader(longTrader, 100_000e6);
        _fundTrader(shortTrader, 100_000e6);

        _open(shortAccount, CfdTypes.Side.SHORT, 999_000e18, 50_000e6, 1e8);
        _open(longAccount, CfdTypes.Side.LONG, 500_000e18, 50_000e6, 1e8);
        _close(longAccount, CfdTypes.Side.LONG, 500_000e18, 20_000_000);
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

    function test_DegradedMode_ClearRequiresRecapitalization() public {
        _enterDegradedMode();

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

        assertFalse(engine.degradedMode(), "Owner should clear degraded mode after recapitalization");
    }

    function test_DegradedMode_BlocksJuniorWithdrawals() public {
        _enterDegradedMode();
        assertTrue(engine.degradedMode(), "Setup must latch degraded mode");

        vm.warp(block.timestamp + 1 hours + 1);
        uint256 requestedShares = juniorVault.estimateWithdrawShares(1e6);
        uint256 requestId = juniorVault.requestRedeem(requestedShares, address(this), address(this));
        vm.warp(pool.lpEpochStart(requestId));
        uint256 markPrice = engine.lastMarkPrice();
        vm.prank(address(router));
        engine.updateMarkPrice(markPrice == 0 ? 1e8 : markPrice, uint64(block.timestamp));
        uint256 markTime = engine.lastMarkTime();
        vm.expectRevert(IHousePool.HousePool__DegradedMode.selector);
        vm.prank(address(router));
        pool.settleLpEpoch(markPrice == 0 ? 1e8 : markPrice, markTime);
    }

    function test_DegradedMode_AllowsAddMarginToExistingPosition() public {
        address trader = address(0xD004);
        address account = trader;
        _fundTrader(trader, 200_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);

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
