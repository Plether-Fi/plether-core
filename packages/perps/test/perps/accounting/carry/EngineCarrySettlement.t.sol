// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";

import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";

import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {CfdEngineTestBase} from "../../shared/CfdEngineTestBase.sol";

contract EngineCarrySettlementTest is CfdEngineTestBase {

    using stdStorage for StdStorage;

    function test_HousePoolSnapshot_ReservesRoundedSettlementBufferAcrossLiveMarkStaleness() public {
        _configureSnapshotBuffer();
        _openSnapshotBufferPositions();
        assertFalse(engine.isOracleFrozen(), "This boundary must use the live freshness policy");
        uint64 markTime = uint64(vm.getBlockTimestamp());
        vm.prank(address(router));
        engine.updateMarkPrice(100_000_001, markTime);
        assertEq(engine.lastMarkTime(), markTime);

        uint256 poolLimit = pool.markStalenessLimit();
        uint256 engineLimit = engine.engineMarkStalenessLimit();
        uint256 selectedLimit = poolLimit == 0 || engineLimit < poolLimit ? engineLimit : poolLimit;
        assertGt(selectedLimit, 0, "The fixture must have a finite live freshness limit");
        vm.warp(uint256(markTime) + selectedLimit);
        assertEq(vm.getBlockTimestamp() - engine.lastMarkTime(), selectedLimit);
        _assertSnapshotBufferAndFreshness(selectedLimit);
        vm.warp(uint256(markTime) + selectedLimit + 1);
        assertEq(vm.getBlockTimestamp() - engine.lastMarkTime(), selectedLimit + 1);
        _assertSnapshotBufferAndFreshness(selectedLimit);
    }

    function test_WithdrawMargin_RejectsFrozenStaleMarkWithoutAccountingMutation() public {
        address trader = address(0xABC5);
        _setFadMaxStaleness(1 hours);
        _fundTrader(trader, 50_000e6);
        _open(trader, CfdTypes.Side.LONG, 200_000e18, 20_000e6, 1e8);

        uint64 frozenMarkTime = uint64(SETUP_TIMESTAMP + 5 days + 2 hours);
        vm.warp(frozenMarkTime);
        assertTrue(engine.isOracleFrozen(), "The fixture must be inside a frozen oracle window");
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, frozenMarkTime);
        assertEq(engine.lastMarkTime(), frozenMarkTime);
        assertEq(engine.fadMaxStaleness(), 1 hours);
        vm.warp(uint256(frozenMarkTime) + 1 hours + 1);
        assertEq(vm.getBlockTimestamp() - engine.lastMarkTime(), 1 hours + 1);

        (uint256 positionSize,,,,,,) = engine.positions(trader);
        assertEq(positionSize, 200_000e18, "Withdrawal must exercise a surviving live position");
        assertGe(_freeSettlementUsdc(trader), 1e6, "Free cash must cover the requested withdrawal");
        bytes32 accountingBefore = _withdrawalAccountingDigest(trader);
        vm.prank(trader);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__MarkPriceStale.selector);
        clearinghouse.withdrawMargin(1e6);
        assertEq(_withdrawalAccountingDigest(trader), accountingBefore, "Stale rejection must roll back all accounting");
    }

    function test_HousePoolSnapshot_ReservesRoundedSettlementBufferAcrossFrozenMarkStaleness() public {
        _configureSnapshotBuffer();
        _setFadMaxStaleness(1 hours);
        _openSnapshotBufferPositions();
        uint64 frozenMarkTime = uint64(SETUP_TIMESTAMP + 5 days + 2 hours);
        vm.warp(frozenMarkTime);
        assertTrue(engine.isOracleFrozen(), "This boundary must use the frozen freshness policy");
        vm.prank(address(router));
        engine.updateMarkPrice(100_000_001, frozenMarkTime);
        assertEq(engine.lastMarkTime(), frozenMarkTime);
        assertEq(engine.fadMaxStaleness(), 1 hours);

        vm.warp(uint256(frozenMarkTime) + 1 hours);
        assertEq(vm.getBlockTimestamp() - engine.lastMarkTime(), 1 hours);
        _assertSnapshotBufferAndFreshness(1 hours);
        vm.warp(uint256(frozenMarkTime) + 1 hours + 1);
        assertEq(vm.getBlockTimestamp() - engine.lastMarkTime(), 1 hours + 1);
        _assertSnapshotBufferAndFreshness(1 hours);
    }

    function _configureSnapshotBuffer() internal {
        ICfdEngineAdminHost.EngineRiskConfig memory config = _engineRiskConfig();
        config.settlementBufferBps = 37;
        engineAdmin.proposeRiskConfig(config);
        vm.warp(engineAdmin.riskConfigActivationTime() + 1);
        engineAdmin.finalizeRiskConfig();
        assertEq(engine.settlementBufferBps(), 37, "The independent buffer expectation requires the configured rate");
    }

    function _openSnapshotBufferPositions() internal {
        address longTrader = address(0xABC6);
        address shortTrader = address(0xABC7);
        _fundTrader(longTrader, 50_000e6);
        _fundTrader(shortTrader, 10_000e6);
        _open(longTrader, CfdTypes.Side.LONG, 200_000e18, 20_000e6, 100_000_001);
        _open(shortTrader, CfdTypes.Side.SHORT, 20_000e18, 2000e6, 100_000_001);
    }

    function _assertSnapshotBufferAndFreshness(
        uint256 expectedStaleness
    ) internal view {
        // LONG liability is entry cost; SHORT liability is its remaining cap envelope. These fixture values
        // deliberately leave a nonzero remainder under the specified round-up settlement-buffer rule.
        uint256 longLiability = (200_000e18 / 100e18) * 100_000_001;
        uint256 shortLiability = (20_000e18 / 100e18) * (CAP_PRICE - 100_000_001);
        uint256 expectedLiability = longLiability > shortLiability ? longLiability : shortLiability;
        uint256 expectedBuffer = (expectedLiability * 37 + 9999) / 10_000;
        assertGt((expectedLiability * 37) % 10_000, 0, "Fixture must distinguish ceiling from floor rounding");
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());
        assertEq(snapshot.maxLiabilityUsdc, expectedLiability, "Snapshot must preserve the known directional liability");
        assertEq(snapshot.supplementalReservedUsdc, expectedBuffer, "Staleness must not erase the settlement buffer");
        assertTrue(snapshot.hasOpenPositions);
        assertTrue(snapshot.markFreshnessRequired);
        assertEq(snapshot.maxMarkStaleness, expectedStaleness, "Snapshot must select the active freshness limit");
    }

    function _withdrawalAccountingDigest(
        address account
    ) internal view returns (bytes32) {
        (uint256 borrowBase, uint256 carryIndex, uint64 carryTimestamp) = engine.positionCarryState(account);
        return keccak256(
            abi.encode(
                clearinghouse.getAccountUsdcBuckets(account),
                clearinghouse.totalBountyReservationsUsdc(account),
                engine.unsettledCarryUsdc(account),
                borrowBase,
                carryIndex,
                carryTimestamp,
                _lastCarryTimestamp(account),
                terminalNavBook.curveHashOf(account),
                usdc.balanceOf(account),
                usdc.balanceOf(address(clearinghouse)),
                pool.rawAssets(),
                pool.accountedAssets()
            )
        );
    }

    function test_StaleDeposit_PreservesPreMutationCarryBasis() public {
        address trader = address(0xD30D2);
        address account = trader;
        uint256 depositAmount = 500e6;

        _fundTrader(trader, 10_000e6);
        usdc.mint(trader, depositAmount);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        uint256 settlementBefore = clearinghouse.balanceUsdc(account);
        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 30 days);
        uint256 expectedCarry = _expectedIndexedCarry(account);

        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.depositMargin(depositAmount);
        vm.stopPrank();

        assertEq(
            clearinghouse.balanceUsdc(account),
            settlementBefore + depositAmount - expectedCarry,
            "Stale deposit should checkpoint carry on the pre-deposit basis before increasing collateral"
        );
        assertEq(
            engine.unsettledCarryUsdc(account),
            0,
            "Covered stale deposit carry should not leave residual unsettled carry"
        );
        assertEq(
            _lastCarryTimestamp(account),
            block.timestamp,
            "Stored-mark carry checkpoint should advance the carry timestamp at the stale deposit time"
        );
    }

    function test_NoSideCarryRealization_KeepsClearinghouseMarginInSync() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        _fundTrader(account, 20_000 * 1e6);

        // Open LONG $100k at $1.00
        CfdTypes.Order memory openOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(openOrder, 1e8, poolDepth, uint64(block.timestamp));

        (, uint256 marginAfterOpen,,,,,) = engine.positions(account);
        IMarginClearinghouse.LockedMarginBuckets memory lockedAfterOpen = clearinghouse.getLockedMarginBuckets(account);
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

        // Warp 30 days before the next carry checkpoint; no legacy side-spread state exists.
        vm.warp(block.timestamp + 30 days);

        // Increase position — triggers carry realization in processOrder
        CfdTypes.Order memory addOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 500 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(addOrder, 1e8, poolDepth, uint64(block.timestamp));

        (, uint256 marginAfterAdd,,,,,) = engine.positions(account);
        IMarginClearinghouse.LockedMarginBuckets memory lockedAfterAdd = clearinghouse.getLockedMarginBuckets(account);
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

    function test_DepositWithdrawMargin_RealizesCarryBeforeBalanceMutation() public {
        address trader = address(0xABD0);
        address account = trader;
        uint256 depositAmount = 50_000e6;

        _fundTrader(trader, 20_000e6);
        usdc.mint(trader, depositAmount);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        uint64 mutationTime = uint64(vm.getBlockTimestamp() + 1 days);
        vm.warp(mutationTime);
        assertEq(vm.getBlockTimestamp(), mutationTime, "The balance mutation must occur after one day of carry");
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, mutationTime);
        assertEq(engine.lastMarkTime(), mutationTime, "The withdrawal must use the intended fresh mark");

        uint256 settlementBefore = clearinghouse.balanceUsdc(account);
        uint256 poolRawBefore = pool.rawAssets();
        uint256 poolAccountedBefore = pool.accountedAssets();
        uint256 clearinghouseRawBefore = usdc.balanceOf(address(clearinghouse));
        uint256 expectedCarry = _expectedIndexedCarry(account);
        assertGt(expectedCarry, 0, "Setup must accrue carry before the balance mutation");

        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.depositMargin(depositAmount);
        assertEq(
            clearinghouse.balanceUsdc(account),
            settlementBefore + depositAmount - expectedCarry,
            "Deposit hook should realize carry before adding fresh settlement"
        );
        assertEq(pool.rawAssets(), poolRawBefore + expectedCarry, "Carry realization should physically fund the pool");
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
            clearinghouse.balanceUsdc(account),
            settlementBefore - expectedCarry,
            "Deposit-withdraw roundtrip must not erase accrued carry"
        );
    }

    function test_DepositMargin_CanRescueAccountWhenIncomingCashCoversCarry() public {
        address trader = address(0xABD1);
        address account = trader;
        uint256 rescueDeposit = 50_000e6;
        uint256 carryElapsed = 365 days * 3;

        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.LONG, 500_000e18, 10_000e6, 1e8);

        uint256 settlementBefore = clearinghouse.balanceUsdc(account);

        usdc.mint(trader, rescueDeposit);

        vm.warp(block.timestamp + carryElapsed);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.roll(block.number + 1);

        uint256 expectedCarry = _expectedIndexedCarry(account);
        assertGt(
            expectedCarry, settlementBefore, "Setup must accrue more carry than the pre-deposit settlement balance"
        );

        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.depositMargin(rescueDeposit);
        vm.stopPrank();

        assertEq(
            clearinghouse.balanceUsdc(account),
            settlementBefore + rescueDeposit - expectedCarry,
            "Rescue deposit should settle pre-basis carry from the incoming cash in the same tx"
        );
    }

    function test_DepositMargin_SucceedsOnStaleMarkWithoutCheckpointingCarry() public {
        address trader = address(0xABD1A);
        address account = trader;
        uint256 depositAmount = 500e6;

        _fundTrader(trader, 10_000e6);
        usdc.mint(trader, depositAmount);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        uint256 settlementBefore = clearinghouse.balanceUsdc(account);
        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 30 days);

        uint256 expectedCarry = _expectedIndexedCarry(account);

        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.depositMargin(depositAmount);
        vm.stopPrank();

        assertEq(
            clearinghouse.balanceUsdc(account),
            settlementBefore + depositAmount - expectedCarry,
            "Stale-oracle deposit should checkpoint indexed carry before crediting settlement"
        );
        assertEq(
            _lastCarryTimestamp(account), block.timestamp, "Stale-mark deposit should advance the carry checkpoint"
        );
        assertEq(engine.unsettledCarryUsdc(account), 0, "Indexed carry deposit should settle elapsed carry");
    }

    function test_ReserveCommittedOrderMargin_CheckpointsCarryBeforeReachabilityDrops() public {
        address trader = address(0xABD3);
        address account = trader;
        uint256 reserveAmount = 4000e6;
        uint256 depositAmount = 1000e6;
        uint256 carryElapsed = 30 days;

        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        uint256 settlementBefore = clearinghouse.balanceUsdc(account);

        vm.warp(block.timestamp + carryElapsed);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.roll(block.number + 1);

        uint256 expectedCarry = _expectedIndexedCarry(account);

        vm.prank(address(router));
        clearinghouse.reserveCommittedOrderMargin(account, 77, reserveAmount);

        assertEq(
            clearinghouse.balanceUsdc(account),
            settlementBefore - expectedCarry,
            "Committed-order reservation should realize carry before lowering reachable collateral"
        );
        assertEq(
            engine.unsettledCarryUsdc(account), 0, "Reservation checkpoint should settle elapsed carry immediately"
        );

        usdc.mint(trader, depositAmount);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.depositMargin(depositAmount);
        vm.stopPrank();

        assertEq(
            clearinghouse.balanceUsdc(account),
            settlementBefore - expectedCarry + depositAmount,
            "Later deposits must not retroactively reprice pre-reservation carry on the reduced basis"
        );
    }

    function test_UnlockReservedSettlement_CheckpointsCarryBeforeReachabilityRises() public {
        address trader = address(0xABD6);
        address account = trader;
        uint256 reservedAmount = 3000e6;
        uint256 carryElapsed = 30 days;

        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        vm.prank(address(router));
        clearinghouse.lockReservedSettlement(account, reservedAmount);

        uint256 settlementBeforeUnlock = clearinghouse.balanceUsdc(account);
        vm.warp(block.timestamp + carryElapsed);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 expectedCarry = _expectedIndexedCarry(account);

        vm.prank(address(engine));
        clearinghouse.unlockReservedSettlement(account, reservedAmount);

        assertEq(
            clearinghouse.balanceUsdc(account),
            settlementBeforeUnlock - expectedCarry,
            "Reserved-settlement unlock should checkpoint carry before reserved funds become reachable again"
        );
        assertEq(engine.unsettledCarryUsdc(account), 0, "Unlock should not leave elapsed carry uncheckpointed");
    }

    function test_ProfitableClose_DoesNotDoubleBookCarryIntoAccountedAssets() public {
        address trader = address(0xABD2);
        address account = trader;

        _fundTrader(trader, 20_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        vm.warp(block.timestamp + 1 days);
        vm.prank(address(router));
        engine.updateMarkPrice(80_000_000, uint64(block.timestamp));

        _close(account, CfdTypes.Side.LONG, 100_000e18, 80_000_000);

        assertEq(
            pool.accountedAssets(),
            pool.rawAssets(),
            "Profitable close carry should not create accounted-assets overhang"
        );
    }

    function test_CloseExecution_UsesCarryAdjustedLossKernel() public {
        address trader = address(0xAB14004);
        address account = trader;

        _fundTrader(trader, 20_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        vm.warp(block.timestamp + 1 days);
        vm.prank(address(router));
        engine.updateMarkPrice(100_010_000, uint64(block.timestamp));

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 100_000e18, 100_010_000);
        assertTrue(preview.valid, "Carry-adjusted full close should remain executable");
        assertEq(preview.badDebtUsdc, 0, "Carry-adjusted close should remain fully covered in this setup");

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 100_010_000, true);

        bytes[] memory priceData = _mockPythUpdateData(100_010_000);
        router.executeOrder(1, priceData);

        (uint256 sizeAfter,,,,,,) = engine.positions(account);
        assertEq(sizeAfter, 0, "Close should execute instead of reverting when carry flips the trade into a loss");
    }

    function test_CarryRealization_DoesNotBackfillAfterFreshCheckpoint() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        _fundTrader(account, 20_000 * 1e6);

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(openOrder, 1e8, poolDepth, uint64(block.timestamp));

        uint64 refreshTime = uint64(block.timestamp + 365 days);
        vm.warp(refreshTime);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, refreshTime);

        uint64 accrualTime = refreshTime + 30;
        vm.warp(accrualTime);

        CfdTypes.Order memory addOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 5000 * 1e6,
            targetPrice: 1e8,
            commitTime: accrualTime,
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(addOrder, 1e8, poolDepth, accrualTime);

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 110_000 * 1e18, "Fresh mark checkpoint should not retroactively create a carry-driven revert");
    }

    function test_CarryRealization_OnClose() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        _fundTrader(account, 5000 * 1e6);

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(openOrder, 1e8, poolDepth, uint64(block.timestamp));

        uint256 chBefore = clearinghouse.balanceUsdc(account);

        vm.warp(block.timestamp + 90 days);

        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 0,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.LONG,
            isClose: true
        });
        vm.prank(address(router));
        engine.processOrderTyped(closeOrder, 1e8, poolDepth, uint64(block.timestamp));

        uint256 chAfter = clearinghouse.balanceUsdc(account);
        assertLt(chAfter, chBefore, "Carry drain should reduce clearinghouse balance on close");
    }

    function test_CloseSucceeds_WhenCarryExceedsMargin_ButPositionProfitable() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        _fundTrader(account, 10_000 * 1e6);

        // Open LONG 100k tokens at $1.00 with enough supplied collateral for pledge plus liquidation reserve.
        CfdTypes.Order memory openOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(openOrder, 1e8, poolDepth, uint64(block.timestamp));

        // Warp 365 days — carry will far exceed margin
        vm.warp(block.timestamp + 365 days);

        // Price dropped to $0.50 → LONG has $50k unrealized profit
        // User should be able to close and receive profit minus carry minus fees
        uint256 chBefore = clearinghouse.balanceUsdc(account);

        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 0,
            targetPrice: 0.5e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.LONG,
            isClose: true
        });

        // This should NOT revert — the position is profitable despite carry > margin
        vm.prank(address(router));
        engine.processOrderTyped(closeOrder, 0.5e8, poolDepth, uint64(block.timestamp));

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Position should be fully closed");

        uint256 chAfter = clearinghouse.balanceUsdc(account);
        assertGt(chAfter, chBefore, "User should net positive after profitable close minus carry");
    }

    function test_ReserveCloseOrderExecutionBounty_UsesCarryAwareProjectedRiskState() public {
        CfdTypes.RiskParams memory params = _riskParams();
        _setRiskParams(params);

        address trader = address(0x51583);
        address account = trader;
        _fundTrader(trader, 2000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() - 1);

        vm.prank(address(router));
        vm.expectPartialRevert(ICfdEngineTypes.CfdEngine__PartialCloseUnhealthy.selector);
        engine.reserveCloseOrderExecutionBounty(account, 50_000e18, 1400e6);
    }

    function test_ReserveCloseOrderExecutionBounty_DoesNotRecomputeHistoricalCarryAfterReservationReachabilityDrop()
        public
    {
        CfdTypes.RiskParams memory params = _riskParams();
        _setRiskParams(params);

        address trader = address(0x51584);
        address account = trader;
        uint256 price = 1e8;
        uint256 size = 100_000e18;
        uint256 marginUsdc = 2000e6;
        uint256 bountyUsdc = 1e6;
        uint256 carryTimeDelta = 3_839_405;

        // Leave a distinct free-settlement slice so the historical carry and close bounty are actually collectible;
        // carry consumes position margin; the bounty remains exclusively free-funded.
        _fundTrader(trader, marginUsdc + 100e6);
        _open(account, CfdTypes.Side.LONG, size, marginUsdc, price);

        vm.prank(address(router));
        engine.updateMarkPrice(price, uint64(block.timestamp));
        vm.warp(block.timestamp + carryTimeDelta);

        uint256 borrowBaseBefore = _positionBorrowBaseUsdc(account);
        uint256 expectedCarry = _expectedIndexedCarry(account);
        uint256 settlementBefore = clearinghouse.balanceUsdc(account);
        uint256 pnlPledgeBefore = clearinghouse.pnlPledgeUsdc(account);
        uint256 actionReserveBefore = clearinghouse.actionReserveUsdc(account);
        assertGt(expectedCarry, 0, "Setup must accrue indexed carry");

        vm.prank(address(router));
        engine.reserveCloseOrderExecutionBounty(account, size / 2, bountyUsdc);

        assertEq(engine.unsettledCarryUsdc(account), 0, "Reservation should realize indexed carry first");
        assertEq(
            _positionBorrowBaseUsdc(account),
            borrowBaseBefore + expectedCarry,
            "Margin-funded carry increases the borrow base only after historical carry is assessed"
        );
        assertEq(
            clearinghouse.balanceUsdc(account),
            settlementBefore - expectedCarry,
            "Exactly the historical carry should leave settlement custody"
        );
        assertEq(
            clearinghouse.pnlPledgeUsdc(account),
            pnlPledgeBefore - expectedCarry,
            "Only carry consumes position margin; bounty reservation preserves the remaining pledge"
        );
        assertEq(
            clearinghouse.actionReserveUsdc(account),
            actionReserveBefore + bountyUsdc,
            "The close bounty should move only into the isolated action reserve"
        );
    }

}
