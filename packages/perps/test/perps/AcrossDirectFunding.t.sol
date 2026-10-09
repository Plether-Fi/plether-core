// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {ArbitrumEventEmitterRuntime} from "../fixtures/across-direct-funding/ArbitrumEventEmitterRuntime.sol";
import {ArbitrumMulticallHandlerRuntime} from "../fixtures/across-direct-funding/ArbitrumMulticallHandlerRuntime.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev ABI of the exact deployed runtime fixture. This interface does not implement the handler.
interface IPinnedAcrossMulticallHandler {

    struct Call {
        address target;
        bytes callData;
        uint256 value;
    }

    struct Replacement {
        address token;
        uint256 offset;
    }

    struct Instructions {
        Call[] calls;
        address fallbackRecipient;
    }

    function handleV3AcrossMessage(
        address token,
        uint256 amount,
        address relayer,
        bytes calldata message
    ) external;
    function attemptCalls(
        Call[] calldata calls
    ) external;
    function makeCallWithBalance(
        address target,
        bytes calldata callData,
        uint256 value,
        Replacement[] calldata replacement
    ) external;

}

interface IPinnedAcrossEventEmitter {

    function emitData(
        bytes calldata data
    ) external;

}

/// @dev Token failure controls isolate the economic calls without substituting a mock clearinghouse or handler.
contract AcrossDirectFundingToken is MockUSDC {

    error RejectedTransfer();
    error RejectedApproval();

    bool public rejectPull;
    bool public rejectZeroApproval;
    bool public rejectSend;

    function setFailures(
        bool pull,
        bool zeroApproval,
        bool send
    ) external {
        rejectPull = pull;
        rejectZeroApproval = zeroApproval;
        rejectSend = send;
    }

    function approve(
        address spender,
        uint256 amount
    ) public override returns (bool) {
        if (rejectZeroApproval && amount == 0) {
            revert RejectedApproval();
        }
        return super.approve(spender, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (rejectPull) {
            revert RejectedTransfer();
        }
        return super.transferFrom(from, to, amount);
    }

    function transfer(
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (rejectSend) {
            revert RejectedTransfer();
        }
        return super.transfer(to, amount);
    }

}

/// @notice Validation of direct margin funding against pinned, actually deployed Across handler bytecode.
/// @dev Offline handler integration proof: the token is a controlled local ERC-20 and the clearinghouse is real.
///      This does not simulate SpokePool delivery, a provider quote, or bridge replay protection.
contract AcrossDirectFundingTest is Test {

    address private constant BENEFICIARY = address(0xBEEF);
    address private constant SOURCE_OWNER = address(0xA11CE);
    address private constant RELAYER = address(0xCAFE);
    address private constant HANDLER = ArbitrumMulticallHandlerRuntime.DEPLOYED_ADDRESS;
    address private constant EVENT_EMITTER = ArbitrumEventEmitterRuntime.DEPLOYED_ADDRESS;
    bytes32 private constant QUOTE_ID = 0x7777777777777777777777777777777777777777777777777777777777777777;

    bytes32 private constant DEPOSIT = keccak256("Deposit(address,address,uint256)");
    bytes32 private constant DEPOSIT_FOR = keccak256("DepositFor(address,address,uint256)");
    bytes32 private constant CALLS_FAILED = keccak256("CallsFailed((address,bytes,uint256)[],address)");
    bytes32 private constant DRAINED = keccak256("DrainedTokens(address,address,uint256)");
    bytes32 private constant METADATA = keccak256("MetadataEmitted(bytes)");

    AcrossDirectFundingToken private usdc;
    MarginClearinghouse private clearinghouse;

    function setUp() public {
        usdc = new AcrossDirectFundingToken();
        clearinghouse = new MarginClearinghouse(address(usdc));
        vm.etch(HANDLER, ArbitrumMulticallHandlerRuntime.runtimeCode());
        // The verified deployment's only storage is OZ v4 ReentrancyGuard._status, initialized to 1 by its constructor.
        vm.store(HANDLER, bytes32(0), bytes32(uint256(1)));
        assertEq(HANDLER.codehash, ArbitrumMulticallHandlerRuntime.CODE_HASH);
        assertEq(HANDLER.code.length, 3758);
        vm.etch(EVENT_EMITTER, ArbitrumEventEmitterRuntime.runtimeCode());
        assertEq(EVENT_EMITTER.codehash, ArbitrumEventEmitterRuntime.CODE_HASH);
        assertEq(EVENT_EMITTER.code.length, 302);
    }

    function test_DynamicBalanceCreditsActualDeliveredAmountAndLeavesNoAllowance() public {
        uint256 delivered = 103e6 + 7;
        usdc.mint(HANDLER, delivered);
        assertEq(BENEFICIARY.code.length, 0, "counterfactual beneficiary does not need code");
        vm.recordLogs();
        // The callback amount is deliberately different: makeCallWithBalance reads the actual token balance.
        _deliver(_message(_calls(), BENEFICIARY), 100e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertDeposit(logs, delivered);
        _assertMarker(logs);
        assertEq(_count(logs, HANDLER, CALLS_FAILED), 0);
        assertEq(_count(logs, HANDLER, DRAINED), 0);
        assertEq(usdc.balanceOf(HANDLER), 0);
        assertEq(usdc.balanceOf(BENEFICIARY), 0);
        assertEq(usdc.balanceOf(SOURCE_OWNER), 0);
        assertEq(usdc.balanceOf(address(clearinghouse)), delivered);
        assertEq(usdc.allowance(HANDLER, address(clearinghouse)), 0);
        assertEq(clearinghouse.balanceUsdc(BENEFICIARY), delivered);
        assertEq(clearinghouse.balanceUsdc(HANDLER), 0);
        assertEq(clearinghouse.getFreeBuyingPowerUsdc(BENEFICIARY), delivered);
    }

    function test_DepositFailureRollsBackApprovalAndFallsBackToTradingAccount() public {
        usdc.mint(HANDLER, 9e6);
        usdc.setFailures(true, false, false);
        vm.recordLogs();
        _deliver(_message(_calls(), BENEFICIARY), 9e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, address(clearinghouse), DEPOSIT), 0);
        assertEq(_count(logs, EVENT_EMITTER, METADATA), 0);
        _assertFallback(logs, 9e6);
    }

    function test_FinalAllowanceResetFailureRollsBackSuccessfulDepositBeforeFallback() public {
        usdc.mint(HANDLER, 11e6);
        // The dynamic approval and deposit succeed, but the third call reverts. The handler must undo both.
        usdc.setFailures(false, true, false);
        vm.recordLogs();
        _deliver(_message(_calls(), BENEFICIARY), 11e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // recordLogs is a trace recorder: it includes logs from reverted nested calls. This proves the deposit was
        // reached before reset failed; the final custody/account/allowance assertions below prove atomic rollback.
        // A real transaction receipt discards these reverted inner logs.
        _assertDeposit(logs, 11e6);
        assertEq(_count(logs, EVENT_EMITTER, METADATA), 0, "marker is after allowance reset");
        _assertFallback(logs, 11e6);
    }

    function test_FailureAfterMarkerRollsBackCreditAndFallsBack() public {
        usdc.mint(HANDLER, 12e6);
        IPinnedAcrossMulticallHandler.Call[] memory baseCalls = _calls();
        IPinnedAcrossMulticallHandler.Call[] memory calls = new IPinnedAcrossMulticallHandler.Call[](5);
        for (uint256 i; i < baseCalls.length; ++i) {
            calls[i] = baseCalls[i];
        }
        // This is a deliberate fault after the reviewed recipe, not an accepted funding instruction.
        // The pinned emitter rejects empty metadata. Its earlier marker and all economic calls must roll back.
        calls[4] = IPinnedAcrossMulticallHandler.Call({
            target: EVENT_EMITTER, callData: abi.encodeCall(IPinnedAcrossEventEmitter.emitData, (bytes(""))), value: 0
        });
        vm.recordLogs();
        _deliver(_message(calls, BENEFICIARY), 12e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // These are attempted trace logs. The local receipt proof verifies neither log survives in the receipt.
        _assertDeposit(logs, 12e6);
        _assertMarker(logs);
        _assertFallback(logs, 12e6);
    }

    function test_FallbackDrainsActualBalanceIncludingPreexistingDust() public {
        usdc.mint(HANDLER, 9e6 + 7);
        usdc.setFailures(true, false, false);
        vm.recordLogs();
        _deliver(_message(_calls(), BENEFICIARY), 9e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, EVENT_EMITTER, METADATA), 0);
        _assertFallback(logs, 9e6 + 7);
    }

    function test_SuccessfulPartialConsumptionDrainsLeftoversAndClearsAllowance() public {
        usdc.mint(HANDLER, 13e6);
        IPinnedAcrossMulticallHandler.Call[] memory calls = _calls();
        calls[1] = IPinnedAcrossMulticallHandler.Call({
            target: address(clearinghouse),
            callData: abi.encodeCall(MarginClearinghouse.depositFor, (BENEFICIARY, 8e6)),
            value: 0
        });
        vm.recordLogs();
        _deliver(_message(calls, BENEFICIARY), 13e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertDeposit(logs, 8e6);
        _assertMarker(logs);
        assertEq(_count(logs, HANDLER, CALLS_FAILED), 0);
        _assertDrained(logs, 5e6);
        assertEq(clearinghouse.balanceUsdc(BENEFICIARY), 8e6);
        assertEq(usdc.balanceOf(BENEFICIARY), 5e6);
        assertEq(usdc.balanceOf(HANDLER), 0);
        assertEq(usdc.allowance(HANDLER, address(clearinghouse)), 0);
    }

    function test_UnsendableFallbackRevertsWholeCallbackInsteadOfReportingCredit() public {
        usdc.mint(HANDLER, 17e6);
        usdc.setFailures(true, false, true);
        vm.expectRevert();
        _deliver(_message(_calls(), BENEFICIARY), 17e6);
        assertEq(usdc.balanceOf(HANDLER), 17e6);
        assertEq(usdc.balanceOf(BENEFICIARY), 0);
        assertEq(usdc.balanceOf(address(clearinghouse)), 0);
        assertEq(clearinghouse.balanceUsdc(BENEFICIARY), 0);
        assertEq(usdc.allowance(HANDLER, address(clearinghouse)), 0);
    }

    function test_ZeroFallbackPropagatesActionFailure() public {
        usdc.mint(HANDLER, 19e6);
        usdc.setFailures(true, false, false);
        vm.expectRevert();
        _deliver(_message(_calls(), address(0)), 19e6);
        assertEq(usdc.balanceOf(HANDLER), 19e6);
        assertEq(clearinghouse.balanceUsdc(BENEFICIARY), 0);
        assertEq(usdc.allowance(HANDLER, address(clearinghouse)), 0);
    }

    function test_EmptyReplayCannotCreateSecondCredit() public {
        usdc.mint(HANDLER, 23e6);
        bytes memory message = _message(_calls(), BENEFICIARY);
        _deliver(message, 23e6);
        vm.recordLogs();
        _deliver(message, 23e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, HANDLER, CALLS_FAILED), 1, "zero deposit is caught by handler");
        assertEq(_count(logs, address(clearinghouse), DEPOSIT), 0);
        assertEq(_count(logs, EVENT_EMITTER, METADATA), 0);
        assertEq(clearinghouse.balanceUsdc(BENEFICIARY), 23e6);
        assertEq(usdc.allowance(HANDLER, address(clearinghouse)), 0);
    }

    function test_InnerBalanceHelperCannotBeCalledDirectly() public {
        IPinnedAcrossMulticallHandler.Replacement[] memory replacements = _replacements(address(usdc));
        vm.expectRevert(bytes4(keccak256("NotSelf()")));
        IPinnedAcrossMulticallHandler(HANDLER)
            .makeCallWithBalance(
                address(usdc), abi.encodeCall(IERC20.approve, (address(clearinghouse), 0)), 0, replacements
            );
    }

    function test_FourCallMessageMatchesIndependentViemVector() public pure {
        address token = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
        address margin = 0x3333333333333333333333333333333333333333;
        address beneficiary = 0x2222222222222222222222222222222222222222;
        bytes memory message = _message(_callsFor(token, margin, beneficiary), beneficiary);
        // message-vector.json is independently generated with viem and shared with the backend parser tests.
        assertEq(message.length, 1760);
        assertEq(keccak256(message), 0x418a684024510a35b56a1aa18ff7c782e129af4a2b22da5317915a7e6a4a7839);
    }

    function testFuzz_DynamicAmountIsConserved(
        uint96 rawAmount
    ) public {
        uint256 amount = bound(rawAmount, 1, 1e15);
        usdc.mint(HANDLER, amount);
        _deliver(_message(_calls(), BENEFICIARY), 1);
        assertEq(clearinghouse.balanceUsdc(BENEFICIARY), amount);
        assertEq(usdc.balanceOf(address(clearinghouse)), amount);
        assertEq(usdc.balanceOf(HANDLER), 0);
        assertEq(usdc.allowance(HANDLER, address(clearinghouse)), 0);
    }

    function _calls() private view returns (IPinnedAcrossMulticallHandler.Call[] memory calls) {
        return _callsFor(address(usdc), address(clearinghouse), BENEFICIARY);
    }

    function _callsFor(
        address token,
        address margin,
        address beneficiary
    ) private pure returns (IPinnedAcrossMulticallHandler.Call[] memory calls) {
        calls = new IPinnedAcrossMulticallHandler.Call[](4);
        calls[0] = _dynamicCall(token, token, abi.encodeCall(IERC20.approve, (margin, 0)));
        calls[1] = _dynamicCall(token, margin, abi.encodeCall(MarginClearinghouse.depositFor, (beneficiary, 0)));
        calls[2] = IPinnedAcrossMulticallHandler.Call({
            target: token, callData: abi.encodeCall(IERC20.approve, (margin, 0)), value: 0
        });
        calls[3] = IPinnedAcrossMulticallHandler.Call({
            target: EVENT_EMITTER,
            callData: abi.encodeCall(IPinnedAcrossEventEmitter.emitData, (abi.encodePacked(QUOTE_ID))),
            value: 0
        });
    }

    function _dynamicCall(
        address token,
        address target,
        bytes memory callData
    ) private pure returns (IPinnedAcrossMulticallHandler.Call memory) {
        return IPinnedAcrossMulticallHandler.Call({
            target: HANDLER,
            callData: abi.encodeCall(
                IPinnedAcrossMulticallHandler.makeCallWithBalance, (target, callData, 0, _replacements(token))
            ),
            value: 0
        });
    }

    function _replacements(
        address token
    ) private pure returns (IPinnedAcrossMulticallHandler.Replacement[] memory replacements) {
        replacements = new IPinnedAcrossMulticallHandler.Replacement[](1);
        // Selector (4 bytes) + first address argument (32 bytes); the original uint256 must be zero (OR replacement).
        replacements[0] = IPinnedAcrossMulticallHandler.Replacement({token: token, offset: 36});
    }

    function _message(
        IPinnedAcrossMulticallHandler.Call[] memory calls,
        address fallbackRecipient
    ) private pure returns (bytes memory) {
        return
            abi.encode(IPinnedAcrossMulticallHandler.Instructions({calls: calls, fallbackRecipient: fallbackRecipient}));
    }

    function _deliver(
        bytes memory message,
        uint256 declaredAmount
    ) private {
        vm.prank(RELAYER);
        IPinnedAcrossMulticallHandler(HANDLER).handleV3AcrossMessage(address(usdc), declaredAmount, RELAYER, message);
    }

    function _assertFallback(
        Vm.Log[] memory logs,
        uint256 amount
    ) private view {
        assertEq(_count(logs, HANDLER, CALLS_FAILED), 1);
        _assertDrained(logs, amount);
        assertEq(usdc.balanceOf(BENEFICIARY), amount);
        assertEq(usdc.balanceOf(SOURCE_OWNER), 0, "destination fallback is not the source wallet");
        assertEq(usdc.balanceOf(HANDLER), 0);
        assertEq(usdc.balanceOf(address(clearinghouse)), 0);
        assertEq(clearinghouse.balanceUsdc(BENEFICIARY), 0);
        assertEq(usdc.allowance(HANDLER, address(clearinghouse)), 0);
    }

    function _assertDeposit(
        Vm.Log[] memory logs,
        uint256 amount
    ) private view {
        assertEq(_count(logs, address(clearinghouse), DEPOSIT), 1);
        assertEq(_count(logs, address(clearinghouse), DEPOSIT_FOR), 1);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(clearinghouse) || logs[i].topics[0] != DEPOSIT_FOR) {
                continue;
            }
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(HANDLER))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(BENEFICIARY))));
            assertEq(abi.decode(logs[i].data, (uint256)), amount);
            assertGt(i, 0);
            assertEq(logs[i - 1].emitter, address(clearinghouse));
            assertEq(logs[i - 1].topics[0], DEPOSIT);
        }
    }

    function _assertDrained(
        Vm.Log[] memory logs,
        uint256 amount
    ) private view {
        assertEq(_count(logs, HANDLER, DRAINED), 1);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != HANDLER || logs[i].topics[0] != DRAINED) {
                continue;
            }
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(BENEFICIARY))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(usdc)))));
            assertEq(logs[i].topics[3], bytes32(amount));
        }
    }

    function _assertMarker(
        Vm.Log[] memory logs
    ) private pure {
        assertEq(_count(logs, EVENT_EMITTER, METADATA), 1);
        uint256 creditIndex;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == DEPOSIT_FOR) {
                creditIndex = i;
            }
            if (logs[i].emitter == EVENT_EMITTER && logs[i].topics[0] == METADATA) {
                assertEq(logs[i].topics.length, 1);
                assertEq(logs[i].data, abi.encode(abi.encodePacked(QUOTE_ID)));
                assertGt(i, creditIndex, "unique marker follows canonical credit");
            }
        }
    }

    function _count(
        Vm.Log[] memory logs,
        address emitter,
        bytes32 topic
    ) private pure returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length != 0 && logs[i].topics[0] == topic) {
                ++count;
            }
        }
    }

}
