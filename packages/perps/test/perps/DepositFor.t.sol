// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {ICfdEngineSettlementSidecar} from "@plether/perps/interfaces/ICfdEngineSettlementSidecar.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

contract DepositForRejectingEngine {

    function realizeCarryBeforeMarginChange(
        address
    ) external pure {
        revert("carry hook called");
    }

}

contract DepositForAdversarialToken is MockUSDC {

    uint256 public mode;
    bool public reentryBlocked;

    function setMode(
        uint256 value
    ) external {
        mode = value;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (mode == 1) {
            super.transferFrom(from, to, amount - 1);
        } else if (mode == 2) {
            super.transferFrom(from, to, amount);
            _mint(to, 1);
        } else if (mode == 3) {
            return false;
        } else {
            if (mode == 4) {
                (bool ok, bytes memory reason) = to.call(abi.encodeCall(MarginClearinghouse.depositFor, (from, 1)));
                require(!ok && bytes4(reason) == bytes4(keccak256("ReentrancyGuardReentrantCall()")), "wrong revert");
                reentryBlocked = true;
            }
            super.transferFrom(from, to, amount);
        }
        return true;
    }

}

contract DepositForTest is Test {

    address private constant PAYER = address(0xF00D);
    address private constant ACCOUNT = address(0xA11CE);
    MockUSDC private usdc;
    MarginClearinghouse private clearinghouse;

    function setUp() public {
        usdc = new MockUSDC();
        clearinghouse = new MarginClearinghouse(address(usdc));
        usdc.mint(PAYER, 1000e6);
        vm.prank(PAYER);
        usdc.approve(address(clearinghouse), type(uint256).max);
    }

    function test_CreditsOnlyBeneficiaryAndEmitsOneCanonicalDeposit() public {
        // An undeployed account needs neither code nor an allowance to receive a deposit.
        assertEq(ACCOUNT.code.length, 0);
        vm.recordLogs();
        vm.prank(PAYER);
        clearinghouse.depositFor(ACCOUNT, 100e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 deposits;
        uint256 metadata;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(clearinghouse)) {
                continue;
            }
            if (logs[i].topics[0] == keccak256("Deposit(address,address,uint256)")) {
                ++deposits;
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(ACCOUNT))));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(usdc)))));
                assertEq(abi.decode(logs[i].data, (uint256)), 100e6);
            } else if (logs[i].topics[0] == keccak256("DepositFor(address,address,uint256)")) {
                ++metadata;
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(PAYER))));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(ACCOUNT))));
                assertEq(abi.decode(logs[i].data, (uint256)), 100e6);
            }
        }
        assertEq(deposits, 1);
        assertEq(metadata, 1);
        assertEq(usdc.balanceOf(PAYER), 900e6);
        assertEq(usdc.balanceOf(ACCOUNT), 0);
        assertEq(usdc.balanceOf(address(clearinghouse)), 100e6);
        assertEq(clearinghouse.balanceUsdc(PAYER), 0);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), 100e6);
        assertEq(clearinghouse.getFreeBuyingPowerUsdc(ACCOUNT), 100e6);
        assertEq(clearinghouse.lockedMarginUsdc(ACCOUNT), 0);
    }

    function test_PayerCannotWithdrawBeneficiaryFunds() public {
        vm.prank(PAYER);
        clearinghouse.depositFor(ACCOUNT, 100e6);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotAccountOwner.selector);
        vm.prank(PAYER);
        clearinghouse.withdraw(ACCOUNT, 100e6);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientBalance.selector);
        vm.prank(PAYER);
        clearinghouse.withdrawMargin(100e6);
        vm.prank(ACCOUNT);
        clearinghouse.withdrawMargin(100e6);
        assertEq(usdc.balanceOf(ACCOUNT), 100e6);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), 0);
        assertEq(usdc.balanceOf(address(clearinghouse)), 0);
    }

    function test_RejectsZeroBeneficiaryAndAmountWithoutTakingFunds() public {
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__ZeroAddress.selector);
        vm.prank(PAYER);
        clearinghouse.depositFor(address(0), 100e6);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__ZeroAmount.selector);
        vm.prank(PAYER);
        clearinghouse.depositFor(ACCOUNT, 0);
        assertEq(usdc.balanceOf(PAYER), 1000e6);
        assertEq(usdc.balanceOf(address(clearinghouse)), 0);
    }

    function test_RequiresPayerAllowanceRatherThanBeneficiaryAllowance() public {
        usdc.mint(ACCOUNT, 200e6);
        vm.prank(ACCOUNT);
        usdc.approve(address(clearinghouse), type(uint256).max);
        vm.prank(PAYER);
        usdc.approve(address(clearinghouse), 0);
        vm.expectRevert();
        vm.prank(PAYER);
        clearinghouse.depositFor(ACCOUNT, 100e6);
        assertEq(usdc.balanceOf(PAYER), 1000e6);
        assertEq(usdc.balanceOf(ACCOUNT), 200e6);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), 0);
    }

    function test_TransferFailureDoesNotCreditAccount() public {
        vm.expectRevert();
        vm.prank(PAYER);
        clearinghouse.depositFor(ACCOUNT, 1001e6);
        assertEq(usdc.balanceOf(PAYER), 1000e6);
        assertEq(usdc.balanceOf(address(clearinghouse)), 0);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), 0);
    }

    function test_PrefundedCustodyIsNotCreditedAsPartOfDeposit() public {
        usdc.mint(address(clearinghouse), 777e6);
        vm.prank(PAYER);
        clearinghouse.depositFor(ACCOUNT, 100e6);
        assertEq(usdc.balanceOf(address(clearinghouse)), 877e6);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), 100e6);
    }

    function test_NoCarryHookEvenWhenEngineWouldRevertAndLegacyStillCallsHook() public {
        clearinghouse.setEngine(address(new DepositForRejectingEngine()));
        vm.prank(PAYER);
        clearinghouse.depositFor(ACCOUNT, 100e6);
        vm.prank(PAYER);
        clearinghouse.depositFor(PAYER, 10e6);
        vm.expectRevert("carry hook called");
        vm.prank(PAYER);
        clearinghouse.depositMargin(10e6);
        vm.expectRevert("carry hook called");
        vm.prank(PAYER);
        clearinghouse.deposit(PAYER, 10e6);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), 100e6);
        assertEq(clearinghouse.balanceUsdc(PAYER), 10e6);
        assertEq(usdc.balanceOf(PAYER), 890e6);
    }

    function test_InexactAndFalseReturningTokensRollBack() public {
        DepositForAdversarialToken token = new DepositForAdversarialToken();
        MarginClearinghouse house = new MarginClearinghouse(address(token));
        token.mint(PAYER, 100e6);
        vm.prank(PAYER);
        token.approve(address(house), 100e6);
        for (uint256 mode = 1; mode <= 3; ++mode) {
            token.setMode(mode);
            if (mode < 3) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        MarginClearinghouse.MarginClearinghouse__UnexpectedTransferAmount.selector,
                        100e6,
                        mode == 1 ? 100e6 - 1 : 100e6 + 1
                    )
                );
            } else {
                vm.expectRevert();
            }
            vm.prank(PAYER);
            house.depositFor(ACCOUNT, 100e6);
            assertEq(token.balanceOf(PAYER), 100e6);
            assertEq(token.balanceOf(address(house)), 0);
            assertEq(house.balanceUsdc(ACCOUNT), 0);
            assertEq(token.allowance(PAYER, address(house)), 100e6);
        }
    }

    function test_ReentrantDepositIsBlocked() public {
        DepositForAdversarialToken token = new DepositForAdversarialToken();
        MarginClearinghouse house = new MarginClearinghouse(address(token));
        token.mint(PAYER, 100e6);
        token.setMode(4);
        vm.prank(PAYER);
        token.approve(address(house), 100e6);
        vm.prank(PAYER);
        house.depositFor(ACCOUNT, 100e6);
        assertTrue(token.reentryBlocked());
        assertEq(house.balanceUsdc(ACCOUNT), 100e6);
        assertEq(house.balanceUsdc(PAYER), 0);
        assertEq(token.balanceOf(address(house)), 100e6);
    }

    function testFuzz_MultipleRecipientsConserveCustody(
        uint96 first,
        uint96 second
    ) public {
        uint256 amountA = bound(first, 1, 500e6);
        uint256 amountB = bound(second, 1, 500e6);
        vm.startPrank(PAYER);
        clearinghouse.depositFor(ACCOUNT, amountA);
        clearinghouse.depositFor(PAYER, amountB);
        vm.stopPrank();
        assertEq(clearinghouse.balanceUsdc(ACCOUNT) + clearinghouse.balanceUsdc(PAYER), amountA + amountB);
        assertEq(usdc.balanceOf(address(clearinghouse)), amountA + amountB);
        assertEq(usdc.balanceOf(PAYER) + usdc.balanceOf(address(clearinghouse)), 1000e6);
    }

}

contract DepositForCarryTest is BasePerpTest {

    using stdStorage for StdStorage;

    address private constant ACCOUNT = address(0xA11CE);
    address private constant PAYER = address(0xF00D);

    function _fixture(
        bool shortSide
    ) private {
        _fundTrader(ACCOUNT, 6200e6);
        _open(ACCOUNT, shortSide ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        vm.startPrank(address(engine));
        clearinghouse.reserveCommittedOrderMargin(ACCOUNT, type(uint64).max, 200e6);
        clearinghouse.lockReservedSettlement(ACCOUNT, 100e6);
        clearinghouse.lockVpiRebateReserve(ACCOUNT, 50e6);
        vm.stopPrank();
        usdc.mint(PAYER, 100_000e6);
        vm.prank(PAYER);
        usdc.approve(address(clearinghouse), type(uint256).max);
    }

    function _arrears(
        uint256 amount
    ) private {
        stdstore.target(address(engine)).sig("unsettledCarryUsdc(address)").with_key(ACCOUNT).checked_write(amount);
    }

    function _snapshot() private returns (CfdEnginePlanTypes.RawSnapshot memory snapshot) {
        uint256 depth = pool.totalAssets();
        ICfdEngineSettlementSidecar sidecar = engine.settlementSidecar();
        vm.prank(address(engine));
        snapshot = sidecar.buildRawSnapshot(ACCOUNT, depth);
    }

    function _raw(
        address target,
        bytes memory data
    ) private view returns (bytes memory result) {
        bool ok;
        (ok, result) = target.staticcall(data);
        require(ok, "state read failed");
    }

    function _unchangedState() private view returns (bytes32) {
        // Keep each encoder bounded so this snapshot also compiles in the non-IR fast-test profile.
        return keccak256(abi.encode(_positionState(), _carryState(), _reservationState(), _navAndPoolState()));
    }

    function _positionState() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _raw(address(engine), abi.encodeWithSelector(engine.positions.selector, ACCOUNT)),
                _raw(address(engine), abi.encodeWithSelector(engine.positionCarryState.selector, ACCOUNT)),
                _raw(address(engine), abi.encodeWithSelector(engine.sides.selector, 0)),
                _raw(address(engine), abi.encodeWithSelector(engine.sides.selector, 1))
            )
        );
    }

    function _carryState() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                engine.sideCarryIndex(0),
                engine.sideCarryIndex(1),
                engine.sideCarryTimestamp(0),
                engine.sideCarryTimestamp(1),
                engine.sideBorrowBaseUsdc(0),
                engine.sideBorrowBaseUsdc(1),
                engine.unsettledCarryUsdc(ACCOUNT),
                engine.traderClaimBalanceUsdc(ACCOUNT)
            )
        );
    }

    function _reservationState() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                clearinghouse.getLockedMarginBuckets(ACCOUNT),
                clearinghouse.getOrderReservation(type(uint64).max),
                clearinghouse.vpiRebateReserveUsdc(ACCOUNT),
                clearinghouse.totalBountyReservationsUsdc(ACCOUNT)
            )
        );
    }

    function _navAndPoolState() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                terminalNavBook.curveHashOf(ACCOUNT),
                terminalNavBook.bookState(),
                usdc.balanceOf(address(pool)),
                pool.totalAssets()
            )
        );
    }

    function test_ThirdPartyFundingChangesOnlyCustodyAndFreeSettlementWithPendingCarry() public {
        _fixture(false);
        vm.warp(block.timestamp + 30 days);
        _arrears(20e6);
        bytes32 beforeState = _unchangedState();
        uint256 pending = _expectedIndexedCarryUsdc(ACCOUNT);
        uint256 balance = clearinghouse.balanceUsdc(ACCOUNT);
        uint256 free = _freeSettlementUsdc(ACCOUNT);
        uint256 custody = usdc.balanceOf(address(clearinghouse));
        assertGt(pending, 0);
        vm.prank(PAYER);
        clearinghouse.depositFor(ACCOUNT, 100e6);
        assertEq(_unchangedState(), beforeState);
        assertEq(_expectedIndexedCarryUsdc(ACCOUNT), pending);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), balance + 100e6);
        assertEq(_freeSettlementUsdc(ACCOUNT), free + 100e6);
        assertEq(usdc.balanceOf(address(clearinghouse)), custody + 100e6);
        vm.prank(address(engine));
        assertEq(terminalNavBook.authenticateEngineState(ACCOUNT), terminalNavBook.curveHashOf(ACCOUNT));
    }

    function test_RepeatedDustFundingDoesNotCheckpointOrForgiveCarry() public {
        _fixture(false);
        uint256 lastTimestamp = _lastCarryTimestamp(ACCOUNT);
        for (uint256 i; i < 10; ++i) {
            vm.warp(block.timestamp + 1 days);
            uint256 pending = _expectedIndexedCarryUsdc(ACCOUNT);
            bytes32 beforeState = _unchangedState();
            vm.prank(PAYER);
            clearinghouse.depositFor(ACCOUNT, 1);
            assertEq(_unchangedState(), beforeState);
            assertEq(_expectedIndexedCarryUsdc(ACCOUNT), pending);
            assertEq(_lastCarryTimestamp(ACCOUNT), lastTimestamp);
        }
        assertGt(_expectedIndexedCarryUsdc(ACCOUNT), 0);
    }

    function testFuzz_DeferredCarryProjectionMatchesLaterCollection(
        bool shortSide,
        uint96 arrears,
        uint32 elapsed
    ) public {
        _fixture(shortSide);
        _arrears(bound(arrears, 0, 12_000e6));
        vm.warp(block.timestamp + bound(elapsed, 0, 365 days));
        vm.prank(PAYER);
        clearinghouse.depositFor(ACCOUNT, 1000e6);
        uint256 due = engine.unsettledCarryUsdc(ACCOUNT) + _expectedIndexedCarryUsdc(ACCOUNT);
        CfdEnginePlanTypes.RawSnapshot memory projected = _snapshot();
        uint256 settlementBefore = projected.accountBuckets.settlementBalanceUsdc;
        CfdEnginePlanLib.projectOpenCarry(projected);
        vm.prank(address(clearinghouse));
        engine.realizeCarryBeforeMarginChange(ACCOUNT);
        CfdEnginePlanTypes.RawSnapshot memory actual = _snapshot();
        assertEq(keccak256(abi.encode(actual.accountBuckets)), keccak256(abi.encode(projected.accountBuckets)));
        assertEq(actual.position.margin, projected.position.margin);
        assertEq(actual.positionBorrowBaseUsdc, projected.positionBorrowBaseUsdc);
        assertEq(actual.unsettledCarryUsdc, projected.unsettledCarryUsdc);
        assertEq(actual.poolAssetsUsdc, projected.poolAssetsUsdc);
        assertEq(actual.poolCashUsdc, projected.poolCashUsdc);
        assertEq(actual.longSide.totalMargin, projected.longSide.totalMargin);
        assertEq(actual.shortSide.totalMargin, projected.shortSide.totalMargin);
        assertEq(due, settlementBefore - actual.accountBuckets.settlementBalanceUsdc + actual.unsettledCarryUsdc);
        assertEq(_expectedIndexedCarryUsdc(ACCOUNT), 0);
        vm.prank(address(engine));
        terminalNavBook.authenticateEngineState(ACCOUNT);
    }

    function test_ArrearsCannotBeHiddenInNewReservationsAfterFunding() public {
        _fixture(false);
        uint256 available = clearinghouse.pnlPledgeUsdc(ACCOUNT) + _freeSettlementUsdc(ACCOUNT);
        _arrears(available + 100e6);
        vm.prank(PAYER);
        clearinghouse.depositFor(ACCOUNT, 100e6);
        bytes32 state = _unchangedState();
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
        vm.prank(address(engine));
        clearinghouse.reserveCommittedOrderMargin(ACCOUNT, 1, 1);
        assertEq(_unchangedState(), state, "failed reservation must roll back carry as well");
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
        vm.prank(address(engine));
        clearinghouse.lockReservedSettlement(ACCOUNT, 1);
        assertEq(_unchangedState(), state);
        assertEq(engineAccountLens.getWithdrawableUsdc(ACCOUNT), 0);
        vm.expectRevert();
        vm.prank(ACCOUNT);
        clearinghouse.withdrawMargin(1);
        assertEq(_unchangedState(), state);
    }

    function test_WithdrawCollectsDeferredCarryAndMatchesWithdrawableProjection() public {
        _fixture(false);
        vm.warp(block.timestamp + 1 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.prank(PAYER);
        clearinghouse.depositFor(ACCOUNT, 100e6);
        uint256 due = _expectedIndexedCarryUsdc(ACCOUNT);
        uint256 withdrawable = engineAccountLens.getWithdrawableUsdc(ACCOUNT);
        uint256 balanceBefore = clearinghouse.balanceUsdc(ACCOUNT);
        uint256 marginBefore = clearinghouse.pnlPledgeUsdc(ACCOUNT);
        assertGt(due, 0);
        assertGt(withdrawable, 0);
        vm.prank(ACCOUNT);
        clearinghouse.withdrawMargin(withdrawable);
        assertEq(usdc.balanceOf(ACCOUNT), withdrawable);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), balanceBefore - due - withdrawable);
        assertEq(clearinghouse.pnlPledgeUsdc(ACCOUNT), marginBefore - due);
        assertEq(_freeSettlementUsdc(ACCOUNT), 0);
        assertEq(engine.unsettledCarryUsdc(ACCOUNT), 0);
        assertEq(_expectedIndexedCarryUsdc(ACCOUNT), 0);
    }

    function test_SelfFundingLeavesCarryUntouchedButLegacyDepositStillRealizesIt() public {
        _fixture(false);
        vm.warp(block.timestamp + 30 days);
        usdc.mint(ACCOUNT, 2e6);
        vm.prank(ACCOUNT);
        usdc.approve(address(clearinghouse), 2e6);
        uint256 pending = _expectedIndexedCarryUsdc(ACCOUNT);
        bytes32 beforeState = _unchangedState();
        vm.prank(ACCOUNT);
        clearinghouse.depositFor(ACCOUNT, 1e6);
        assertEq(_unchangedState(), beforeState);
        uint256 balanceBefore = clearinghouse.balanceUsdc(ACCOUNT);
        vm.prank(ACCOUNT);
        clearinghouse.depositMargin(1e6);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), balanceBefore + 1e6 - pending);
        assertEq(_expectedIndexedCarryUsdc(ACCOUNT), 0);
    }

}
