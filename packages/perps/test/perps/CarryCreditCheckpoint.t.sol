// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CarryNavProbeToken} from "./MarginFirstCarry.t.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineSettlementSidecar} from "@plether/perps/interfaces/ICfdEngineSettlementSidecar.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";

contract CarryCreditCheckpointTest is BasePerpTest {

    using stdStorage for StdStorage;

    address private constant ACCOUNT = address(0xCA11);
    address private constant SOURCE = address(0xB017);
    address private constant TRADER = address(0xBAD);
    bytes32 private constant REALIZED = keccak256("CarryRealized(address,uint256,uint256,uint256,uint256)");
    bytes32 private constant CHECKPOINTED = keccak256("CarryCheckpointed(address,uint256,uint256)");

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 10_000_000e6;
    }

    function _fixture() private {
        _fundTrader(ACCOUNT, 5100e6);
        _open(ACCOUNT, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        vm.startPrank(address(engine));
        clearinghouse.lockCommittedOrderMargin(ACCOUNT, 30e6);
        clearinghouse.lockReservedSettlement(ACCOUNT, 20e6);
        clearinghouse.lockVpiRebateReserve(ACCOUNT, 10e6);
        vm.stopPrank();
        _fundTrader(SOURCE, 10_000e6);
        vm.prank(address(router));
        clearinghouse.lockReservedSettlement(SOURCE, 10_000e6);
        _claim(ACCOUNT, 2000e6);
    }

    function _claim(
        address account,
        uint256 amount
    ) private {
        bytes32 oldHash = terminalNavBook.curveHashOf(account);
        uint256 total = engine.totalTraderClaimBalanceUsdc() - engine.traderClaimBalanceUsdc(account) + amount;
        stdstore.target(address(engine)).sig("traderClaimBalanceUsdc(address)").with_key(account).checked_write(amount);
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceUsdc()").checked_write(total);
        vm.prank(address(engine));
        terminalNavBook.syncFromEngine(account, oldHash);
        _authenticate(account);
    }

    function _arrears(
        uint256 amount
    ) private {
        stdstore.target(address(engine)).sig("unsettledCarryUsdc(address)").with_key(ACCOUNT).checked_write(amount);
    }

    function _checkpoint() private {
        vm.prank(address(clearinghouse));
        engine.realizeCarryBeforeMarginChange(ACCOUNT);
    }

    function _authenticate(
        address account
    ) private {
        vm.prank(address(engine));
        terminalNavBook.authenticateEngineState(account);
    }

    function _credit(
        bool claim,
        uint256 amount
    ) private {
        if (claim) {
            vm.prank(ACCOUNT);
            engine.settleTraderClaim(ACCOUNT);
        } else {
            vm.prank(address(router));
            engine.creditBounty(SOURCE, ACCOUNT, amount, 1e8, uint64(block.timestamp));
        }
    }

    function _collected(
        address account
    ) private view returns (uint256 margin, uint256 free, uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(engine) || logs[i].topics.length == 0) {
                continue;
            }
            assertTrue(logs[i].topics[0] != CHECKPOINTED, "deprecated event must not be emitted");
            if (logs[i].topics[0] != REALIZED || logs[i].topics[1] != bytes32(uint256(uint160(account)))) {
                continue;
            }
            (uint256 r, uint256 f, uint256 m, uint256 unpaid) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            assertEq(r, f + m);
            assertEq(unpaid, engine.unsettledCarryUsdc(account));
            margin += m;
            free += f;
            ++count;
        }
    }

    function test_ClaimAllocationBoundariesAndLaterCollection() public {
        _boundaries(true);
    }

    function test_BountyAllocationBoundariesAndLaterCollection() public {
        _boundaries(false);
    }

    struct CollectionCase {
        uint256 margin;
        uint256 free;
        uint256 due;
        uint256 marginPaid;
        uint256 freePaid;
        uint256 credit;
        uint256 poolBefore;
        uint64 version;
    }

    function _boundaries(
        bool claim
    ) private {
        _fixture();
        for (uint256 scenario; scenario < 6; ++scenario) {
            uint256 snapshot = vm.snapshotState();
            _boundary(claim, scenario);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function _boundary(
        bool claim,
        uint256 scenario
    ) private {
        IMarginClearinghouse.AccountUsdcBuckets memory beforeBuckets = clearinghouse.getAccountUsdcBuckets(ACCOUNT);
        CollectionCase memory c;
        c.margin = beforeBuckets.activePositionMarginUsdc;
        c.free = beforeBuckets.freeSettlementUsdc;
        c.due = scenario == 0 ? 0 : scenario == 1 ? c.margin : scenario == 2 ? c.margin + c.free / 2 : c.margin + c.free;
        if (scenario >= 4) {
            c.due += 30e6;
        }
        _arrears(c.due);
        if (scenario == 5) {
            _checkpoint();
            c.margin = 0;
            c.free = 0;
            c.due = 30e6;
        }
        c.marginPaid = c.due < c.margin ? c.due : c.margin;
        c.freePaid = c.due - c.marginPaid < c.free ? c.due - c.marginPaid : c.free;
        c.credit = claim ? 2000e6 : 10e6;
        c.poolBefore = pool.totalAssets();
        c.version = terminalNavBook.bookState().bookVersion;
        vm.recordLogs();
        _credit(claim, c.credit);
        (uint256 collectedMargin, uint256 collectedFree, uint256 count) = _collected(ACCOUNT);
        assertEq(count, c.due == 0 ? 0 : 1);
        assertEq(collectedMargin, c.marginPaid);
        assertEq(collectedFree, c.freePaid);
        assertEq(clearinghouse.pnlPledgeUsdc(ACCOUNT), c.margin - c.marginPaid + (claim ? c.credit : 0));
        assertEq(_freeSettlementUsdc(ACCOUNT), c.free - c.freePaid + (claim ? 0 : c.credit));
        uint256 remaining = c.due - c.marginPaid - c.freePaid;
        assertEq(engine.unsettledCarryUsdc(ACCOUNT), remaining, "credit must not fund this collection");
        assertEq(pool.totalAssets(), c.poolBefore + c.marginPaid + c.freePaid - (claim ? c.credit : 0));
        assertEq(
            clearinghouse.getAccountUsdcBuckets(ACCOUNT).otherLockedMarginUsdc, beforeBuckets.otherLockedMarginUsdc
        );
        assertEq(clearinghouse.actionReserveUsdc(ACCOUNT), 30e6);
        assertEq(clearinghouse.vpiRebateReserveUsdc(ACCOUNT), 10e6);
        assertEq(engine.traderClaimBalanceUsdc(ACCOUNT), claim ? 0 : 2000e6);
        assertEq(clearinghouse.actionReserveUsdc(SOURCE), 10_000e6 - (claim ? 0 : c.credit));
        assertEq(
            terminalNavBook.bookState().bookVersion,
            c.version + (c.marginPaid > 0 ? 1 : 0),
            "only outer bracket changes the curve"
        );
        assertEq(_sideState(CfdTypes.Side.LONG).totalMargin, clearinghouse.pnlPledgeUsdc(ACCOUNT));
        assertEq(engine.sideBorrowBaseUsdc(0), _positionBorrowBaseUsdc(ACCOUNT));
        _authenticate(ACCOUNT);
        if (claim) {
            assertFalse(engineAccountLens.getAccountLedgerSnapshot(ACCOUNT).liquidatable);
            assertFalse(engineLens.previewLiquidation(ACCOUNT, 1e8).liquidatable);
        }
        assertEq(_expectedIndexedCarryUsdc(ACCOUNT), 0);
        _checkpoint();
        assertEq(engine.unsettledCarryUsdc(ACCOUNT), remaining > c.credit ? remaining - c.credit : 0);
    }

    function test_HealthProjectsNewCreditAgainstRetainedArrears() public {
        _fixture();
        uint256 available = clearinghouse.pnlPledgeUsdc(ACCOUNT) + _freeSettlementUsdc(ACCOUNT);
        _arrears(available + 30e6);
        _credit(false, 100e6);
        assertEq(engine.unsettledCarryUsdc(ACCOUNT), 30e6);
        assertEq(_freeSettlementUsdc(ACCOUNT), 100e6);
        assertFalse(engineAccountLens.getAccountLedgerSnapshot(ACCOUNT).liquidatable);
        assertFalse(engineLens.previewLiquidation(ACCOUNT, 1e8).liquidatable);
        _checkpoint();
        assertEq(engine.unsettledCarryUsdc(ACCOUNT), 0);
        assertEq(_freeSettlementUsdc(ACCOUNT), 70e6);
        _authenticate(ACCOUNT);
    }

    function test_CreditsCollectWithFreshStaleAndFrozenMarks() public {
        _fixture();
        for (uint256 regime; regime < 3; ++regime) {
            for (uint256 route; route < 2; ++route) {
                uint256 snapshot = vm.snapshotState();
                vm.warp(regime == 2 ? 1_709_985_600 : block.timestamp + 1 days);
                if (regime == 0) {
                    vm.prank(address(router));
                    engine.updateMarkPrice(1e8, uint64(block.timestamp));
                }
                if (regime == 2) {
                    assertTrue(engine.isOracleFrozen());
                }
                uint64 markTime = engine.lastMarkTime();
                uint256 expectedIndex = _currentSideCarryIndex(CfdTypes.Side.LONG);
                uint256 due = _expectedIndexedCarryUsdc(ACCOUNT);
                uint256 margin = clearinghouse.pnlPledgeUsdc(ACCOUNT);
                if (route == 0) {
                    vm.prank(ACCOUNT);
                    engine.settleTraderClaim(ACCOUNT);
                } else {
                    vm.prank(address(router));
                    engine.creditBounty(SOURCE, ACCOUNT, 10e6, 1e8, markTime);
                }
                assertEq(clearinghouse.pnlPledgeUsdc(ACCOUNT), margin - due + (route == 0 ? 2000e6 : 0));
                assertEq(engine.sideCarryIndex(0), expectedIndex, "old borrow base and pool depth");
                assertEq(_lastCarryTimestamp(ACCOUNT), block.timestamp);
                assertEq(engine.lastMarkTime(), markTime, "credit must not invent a fresh mark");
                _authenticate(ACCOUNT);
                assertTrue(vm.revertToState(snapshot));
            }
        }
    }

    function test_FlatClaimPreservesGlobalCheckpointBeforePayout() public {
        _fixture();
        _claim(SOURCE, 1000e6);
        vm.warp(block.timestamp + 30 days);
        uint256 index = _currentSideCarryIndex(CfdTypes.Side.LONG);
        uint256 margin = clearinghouse.pnlPledgeUsdc(ACCOUNT);
        uint256 assets = pool.totalAssets();
        vm.prank(SOURCE);
        engine.settleTraderClaim(SOURCE);
        assertEq(engine.sideCarryIndex(0), index);
        assertEq(pool.totalAssets(), assets - 1000e6);
        assertEq(clearinghouse.pnlPledgeUsdc(ACCOUNT), margin);
        assertEq(_freeSettlementUsdc(SOURCE), 1000e6);
        _authenticate(SOURCE);
    }

    function test_ZeroBountyIsCompleteNoopWithUnpaidCarry() public {
        _fixture();
        _arrears(6000e6);
        vm.warp(block.timestamp + 1 days);
        bytes32 beforeState = _stateHash();
        vm.recordLogs();
        _credit(false, 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(_stateHash(), beforeState);
    }

    function test_SelfBountyProtectsReserveThenReleasesFullCredit() public {
        _fixture();
        uint256 available = clearinghouse.pnlPledgeUsdc(ACCOUNT) + _freeSettlementUsdc(ACCOUNT);
        _arrears(available + 30e6);
        uint256 beforeBalance = clearinghouse.balanceUsdc(ACCOUNT);
        vm.prank(address(router));
        engine.creditBounty(ACCOUNT, ACCOUNT, 10e6, 1e8, uint64(block.timestamp));
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), beforeBalance - available);
        assertEq(clearinghouse.actionReserveUsdc(ACCOUNT), 20e6);
        assertEq(_freeSettlementUsdc(ACCOUNT), 10e6);
        assertEq(engine.unsettledCarryUsdc(ACCOUNT), 30e6);
        _checkpoint();
        assertEq(engine.unsettledCarryUsdc(ACCOUNT), 20e6);
        _authenticate(ACCOUNT);
    }

    function test_CarryCanMakeAllClaimsPayable() public {
        _claimLiquidity(false);
    }

    function test_InsufficientClaimLiquidityRollsBackCollection() public {
        _claimLiquidity(true);
    }

    function _claimLiquidity(
        bool fail
    ) private {
        _fixture();
        _claim(TRADER, 4000e6);
        uint256 available = clearinghouse.pnlPledgeUsdc(ACCOUNT) + _freeSettlementUsdc(ACCOUNT);
        _arrears(available + 30e6);
        uint256 targetCash = engine.totalTraderClaimBalanceUsdc() - available - (fail ? 1 : 0);
        uint256 drain = pool.rawAssets() - targetCash;
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), drain);
        bytes32 beforeState = _stateHash();
        if (fail) {
            vm.expectRevert(ICfdEngineTypes.CfdEngine__InsufficientPoolLiquidity.selector);
        }
        _credit(true, 2000e6);
        if (fail) {
            assertEq(_stateHash(), beforeState);
            _authenticate(ACCOUNT);
        } else {
            assertEq(pool.totalAssets(), 4000e6);
            assertEq(engine.totalTraderClaimBalanceUsdc(), 4000e6);
            assertEq(clearinghouse.pnlPledgeUsdc(ACCOUNT), 2000e6);
            assertEq(engine.unsettledCarryUsdc(ACCOUNT), 30e6);
            assertEq(engine.traderClaimBalanceUsdc(TRADER), 4000e6);
            _authenticate(ACCOUNT);
        }
    }

    function test_FailedBountyTransferRollsBackThenRetryAuthenticates() public {
        _fixture();
        _arrears(6000e6);
        vm.warp(block.timestamp + 1 days);
        bytes32 beforeState = _stateHash();
        vm.expectRevert();
        _credit(false, 10_001e6);
        assertEq(_stateHash(), beforeState);
        _credit(false, 10e6);
        _authenticate(ACCOUNT);
        assertEq(clearinghouse.pnlPledgeUsdc(ACCOUNT), 0);
        assertEq(_freeSettlementUsdc(ACCOUNT), 10e6);
    }

    function test_NestedCreditCollectionBlocksTransientNavReadsAndRollsBackTokenFailure() public {
        _fixture();
        for (uint256 route; route < 2; ++route) {
            uint256 snapshot = vm.snapshotState();
            _arrears(6000e6);
            CarryNavProbeToken failing = new CarryNavProbeToken(address(engine), true);
            vm.etch(address(usdc), address(failing).code);
            bytes32 beforeState = _stateHash();
            vm.expectRevert(bytes("downstream revert"));
            _credit(route == 0, route == 0 ? 2000e6 : 10e6);
            assertEq(_stateHash(), beforeState);
            CarryNavProbeToken probe = new CarryNavProbeToken(address(engine), false);
            vm.etch(address(usdc), address(probe).code);
            _credit(route == 0, route == 0 ? 2000e6 : 10e6);
            assertEq(CarryNavProbeToken(address(usdc)).blockedReads(), 1);
            _authenticate(ACCOUNT);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_LiquidationCollectsUnderfundedKeeperAndRollsBackBothAccountsOnFailure() public {
        _fixture();
        _fundTrader(TRADER, 10_000e6);
        _open(TRADER, CfdTypes.Side.SHORT, 100_000e18, 3000e6, 1e8);
        _arrears(6000e6);
        vm.warp(block.timestamp + 1 days);
        uint256 unpaid = 6000e6 + _expectedIndexedCarryUsdc(ACCOUNT) - clearinghouse.pnlPledgeUsdc(ACCOUNT)
            - _freeSettlementUsdc(ACCOUNT);
        uint256 depth = pool.totalAssets();
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(TRADER, 0.9e8);
        assertTrue(preview.liquidatable);
        CarryNavProbeToken probe = new CarryNavProbeToken(address(engine), false);
        vm.etch(address(usdc), address(probe).code);
        bytes32 beforeState = _stateHash();
        vm.mockCallRevert(
            address(engine.settlementSidecar()),
            abi.encodeWithSelector(ICfdEngineSettlementSidecar.executeLiquidation.selector),
            bytes("settlement failed")
        );
        vm.expectRevert(bytes("settlement failed"));
        vm.prank(address(router));
        engine.liquidatePosition(TRADER, 0.9e8, depth, uint64(block.timestamp), ACCOUNT);
        assertEq(_stateHash(), beforeState);
        assertEq(CarryNavProbeToken(address(usdc)).blockedReads(), 0);
        vm.clearMockedCalls();
        vm.prank(address(router));
        engine.liquidatePosition(TRADER, 0.9e8, depth, uint64(block.timestamp), ACCOUNT);
        assertEq(CarryNavProbeToken(address(usdc)).blockedReads(), 2);
        assertEq(clearinghouse.pnlPledgeUsdc(ACCOUNT), 0);
        assertGt(_freeSettlementUsdc(ACCOUNT), 0, "full keeper bounty remains available");
        assertEq(engine.unsettledCarryUsdc(ACCOUNT), unpaid);
        _authenticate(ACCOUNT);
        _authenticate(TRADER);
    }

    function testFuzz_CreditAndCheckpointInterleavingsConserveCarry(
        uint256 seed
    ) public {
        _fixture();
        if (seed & 1 != 0) {
            vm.warp(block.timestamp + 250 * 365 days);
            _checkpoint();
            assertGt(engine.unsettledCarryUsdc(ACCOUNT), 0);
        }
        uint256 startingArrears = engine.unsettledCarryUsdc(ACCOUNT);
        uint256 accrued;
        uint256 marginCollected;
        uint256 freeCollected;
        for (uint256 i; i < 8; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(block.timestamp + seed % (80 * 365 days));
            accrued += _expectedIndexedCarryUsdc(ACCOUNT);
            uint256 action = seed % 4;
            if (action == 0) {
                _claim(ACCOUNT, 1 + seed % 500e6);
            }
            vm.recordLogs();
            if (action == 0) {
                _credit(true, 0);
            } else if (action == 1) {
                _credit(false, 1 + seed % 500e6);
            } else if (action == 2) {
                _fundTrader(ACCOUNT, 1 + seed % 500e6);
            } else {
                _checkpoint();
            }
            (uint256 m, uint256 f,) = _collected(ACCOUNT);
            marginCollected += m;
            freeCollected += f;
            if (seed & 4 != 0) {
                assertEq(_expectedIndexedCarryUsdc(ACCOUNT), 0);
                vm.recordLogs();
                _checkpoint();
                (m, f,) = _collected(ACCOUNT);
                marginCollected += m;
                freeCollected += f;
            }
            assertEq(startingArrears + accrued, marginCollected + freeCollected + engine.unsettledCarryUsdc(ACCOUNT));
            assertEq(engine.sideBorrowBaseUsdc(0), _positionBorrowBaseUsdc(ACCOUNT));
            _authenticate(ACCOUNT);
        }
    }

    function _accountHash(
        address account
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _read(address(engine), abi.encodeWithSelector(engine.positions.selector, account)),
                _read(address(engine), abi.encodeWithSelector(engine.positionCarryState.selector, account)),
                clearinghouse.getAccountUsdcBuckets(account),
                engine.unsettledCarryUsdc(account),
                engine.traderClaimBalanceUsdc(account),
                terminalNavBook.curveHashOf(account)
            )
        );
    }

    function _stateHash() private view returns (bytes32) {
        bytes32 sidesHash = keccak256(
            abi.encode(
                _sideState(CfdTypes.Side.LONG),
                _sideState(CfdTypes.Side.SHORT),
                engine.sideCarryIndex(0),
                engine.sideCarryIndex(1),
                engine.sideCarryTimestamp(0),
                engine.sideCarryTimestamp(1),
                engine.sideBorrowBaseUsdc(0),
                engine.sideBorrowBaseUsdc(1)
            )
        );
        bytes32 custodyHash = keccak256(
            abi.encode(
                pool.rawAssets(),
                pool.accountedAssets(),
                usdc.balanceOf(address(clearinghouse)),
                usdc.balanceOf(address(engine)),
                engine.totalTraderClaimBalanceUsdc(),
                engine.lastMarkPrice(),
                engine.lastMarkTime()
            )
        );
        return keccak256(
            abi.encode(
                _accountHash(ACCOUNT),
                _accountHash(SOURCE),
                _accountHash(TRADER),
                sidesHash,
                custodyHash,
                terminalNavBook.bookState()
            )
        );
    }

    function _read(
        address target,
        bytes memory data
    ) private view returns (bytes memory result) {
        bool ok;
        (ok, result) = target.staticcall(data);
        require(ok);
    }

}
