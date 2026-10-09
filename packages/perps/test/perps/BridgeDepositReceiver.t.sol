// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {BridgeDepositReceiver} from "@plether/perps/funding/BridgeDepositReceiver.sol";
import {BridgeDepositReceiverFactory} from "@plether/perps/funding/BridgeDepositReceiverFactory.sol";
import {Test} from "forge-std/Test.sol";

contract BridgeFundingTestToken is ERC20 {

    error TransferRejected();

    bool public rejectTransfers;

    constructor() ERC20("Test USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(
        address account,
        uint256 amount
    ) external {
        _mint(account, amount);
    }

    function setRejectTransfers(
        bool reject
    ) external {
        rejectTransfers = reject;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (rejectTransfers) {
            revert TransferRejected();
        }
        return super.transferFrom(from, to, amount);
    }

}

/// @dev Observes receiver integration boundaries that the real clearinghouse does not expose as test state.
contract BridgeFundingClearinghouseProbe {

    error DepositRejected();

    address public immutable settlementAsset;
    uint256 public depositCalls;
    uint256 public observedAllowance;
    address public creditedAccount;
    bool public rejectDeposit;
    bool public probeReentry;
    bool[3] public reentrySucceeded;
    bytes4[3] public reentryErrors;

    constructor(
        address token
    ) {
        settlementAsset = token;
    }

    function configure(
        bool reject,
        bool reenter
    ) external {
        rejectDeposit = reject;
        probeReentry = reenter;
    }

    function depositFor(
        address account,
        uint256 amount
    ) external {
        if (rejectDeposit) {
            revert DepositRejected();
        }
        depositCalls++;
        observedAllowance = IERC20(settlementAsset).allowance(msg.sender, address(this));
        creditedAccount = account;
        if (probeReentry) {
            bytes[3] memory calls = [
                abi.encodeCall(BridgeDepositReceiver.flush, ()),
                abi.encodeCall(BridgeDepositReceiver.recover, ()),
                abi.encodeCall(BridgeDepositReceiver.recoverToken, (settlementAsset))
            ];
            for (uint256 i; i < calls.length; i++) {
                bytes memory result;
                (reentrySucceeded[i], result) = msg.sender.call(calls[i]);
                reentryErrors[i] = bytes4(result);
            }
        }
        IERC20(settlementAsset).transferFrom(msg.sender, address(this), amount);
    }

}

/// @dev A small authenticated contract beneficiary demonstrates recovery from a smart-account execution context.
contract BridgeFundingBeneficiary {

    address private immutable owner;

    constructor(
        address owner_
    ) {
        owner = owner_;
    }

    function recover(
        BridgeDepositReceiver receiver
    ) external returns (uint256) {
        require(msg.sender == owner, "not owner");
        return receiver.recover();
    }

}

/// @notice Spec tests for immutable bridge-receiver routing and beneficiary-only recovery.
/// @dev Exercises the real clearinghouse's sponsored deposit path, with a probe only for allowance/reentry boundaries.
contract BridgeDepositReceiverTest is Test {

    BridgeFundingTestToken private usdc;
    MarginClearinghouse private clearinghouse;
    BridgeDepositReceiverFactory private factory;
    address private beneficiary = makeAddr("beneficiary");
    address private keeper = makeAddr("keeper");
    address private stranger = makeAddr("stranger");
    bytes32 private constant INTENT_SALT = keccak256("bridge-intent-1");

    function setUp() public {
        usdc = new BridgeFundingTestToken();
        clearinghouse = new MarginClearinghouse(address(usdc));
        factory = new BridgeDepositReceiverFactory(address(clearinghouse), address(usdc));
    }

    function test_PrefundedReceiverCreditsOnlyImmutableBeneficiary() public {
        address predicted = factory.predictReceiver(beneficiary, INTENT_SALT);
        assertEq(predicted.code.length, 0);
        assertEq(beneficiary.code.length, 0);
        usdc.mint(predicted, 250e6);

        vm.prank(keeper);
        address created = factory.createReceiver(beneficiary, INTENT_SALT);
        assertEq(created, predicted);
        BridgeDepositReceiver receiver = BridgeDepositReceiver(created);
        assertEq(receiver.beneficiary(), beneficiary);
        assertEq(receiver.clearinghouse(), address(clearinghouse));
        assertEq(receiver.usdc(), address(usdc));

        vm.prank(keeper);
        assertEq(receiver.flush(), 250e6);
        assertEq(usdc.balanceOf(predicted), 0);
        assertEq(usdc.balanceOf(address(clearinghouse)), 250e6);
        assertEq(clearinghouse.balanceUsdc(beneficiary), 250e6);
        assertEq(clearinghouse.balanceUsdc(keeper), 0);
        assertEq(clearinghouse.balanceUsdc(predicted), 0);
        assertEq(usdc.allowance(predicted, address(clearinghouse)), 0);
    }

    function test_FrontRunningCreationCannotRedirectOrRecover() public {
        address predicted = factory.predictReceiver(beneficiary, INTENT_SALT);
        usdc.mint(predicted, 7e6);
        vm.prank(stranger);
        BridgeDepositReceiver receiver = BridgeDepositReceiver(factory.createReceiver(beneficiary, INTENT_SALT));

        vm.recordLogs();
        vm.prank(beneficiary);
        assertEq(factory.createReceiver(beneficiary, INTENT_SALT), predicted);
        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(factory.predictReceiver(stranger, INTENT_SALT) != predicted);
        assertTrue(factory.predictReceiver(beneficiary, bytes32(uint256(2))) != predicted);
        vm.prank(stranger);
        vm.expectRevert(BridgeDepositReceiver.BridgeDepositReceiver__NotBeneficiary.selector);
        receiver.recover();
        assertEq(usdc.balanceOf(predicted), 7e6);
        assertEq(receiver.beneficiary(), beneficiary);
    }

    function test_RepeatedFlushAndLateArrivalReuseSameReceiver() public {
        BridgeDepositReceiver receiver = _createReceiver();
        assertEq(receiver.flush(), 0);
        usdc.mint(address(receiver), 11e6);
        assertEq(receiver.flush(), 11e6);
        assertEq(receiver.flush(), 0);
        usdc.mint(address(receiver), 29e6);
        vm.prank(stranger);
        assertEq(receiver.flush(), 29e6);
        assertEq(clearinghouse.balanceUsdc(beneficiary), 40e6);
        assertEq(usdc.balanceOf(address(clearinghouse)), 40e6);
        assertEq(usdc.allowance(address(receiver), address(clearinghouse)), 0);
    }

    function test_OnlyBeneficiaryCanRecoverCanonicalAndWrongToken() public {
        BridgeDepositReceiver receiver = _createReceiver();
        BridgeFundingTestToken other = new BridgeFundingTestToken();
        usdc.mint(address(receiver), 9e6);
        other.mint(address(receiver), 31e6);
        vm.prank(stranger);
        vm.expectRevert(BridgeDepositReceiver.BridgeDepositReceiver__NotBeneficiary.selector);
        receiver.recoverToken(address(other));

        vm.startPrank(beneficiary);
        vm.expectRevert(BridgeDepositReceiver.BridgeDepositReceiver__UseCanonicalRecovery.selector);
        receiver.recoverToken(address(usdc));
        assertEq(receiver.recoverToken(address(other)), 31e6);
        assertEq(receiver.recover(), 9e6);
        assertEq(receiver.recover(), 0);
        vm.stopPrank();
        assertEq(other.balanceOf(beneficiary), 31e6);
        assertEq(usdc.balanceOf(beneficiary), 9e6);
        assertEq(other.balanceOf(stranger), 0);
        assertEq(clearinghouse.balanceUsdc(beneficiary), 0);

        usdc.mint(address(receiver), 5e6);
        assertEq(receiver.flush(), 5e6);
        assertEq(clearinghouse.balanceUsdc(beneficiary), 5e6);
    }

    function test_FlushBeforeRecoveryLeavesFundsOnlyInBeneficiaryMargin() public {
        BridgeDepositReceiver receiver = _createReceiver();
        usdc.mint(address(receiver), 19e6);
        vm.prank(stranger);
        receiver.flush();
        vm.prank(beneficiary);
        assertEq(receiver.recover(), 0);
        assertEq(usdc.balanceOf(beneficiary), 0);
        assertEq(clearinghouse.balanceUsdc(beneficiary), 19e6);
        assertEq(usdc.balanceOf(address(clearinghouse)), 19e6);
    }

    function test_ContractBeneficiaryRecoversThroughItsAuthenticatedCall() public {
        BridgeFundingBeneficiary account = new BridgeFundingBeneficiary(beneficiary);
        BridgeDepositReceiver receiver = BridgeDepositReceiver(factory.createReceiver(address(account), INTENT_SALT));
        usdc.mint(address(receiver), 4e6);
        vm.prank(beneficiary);
        vm.expectRevert(BridgeDepositReceiver.BridgeDepositReceiver__NotBeneficiary.selector);
        receiver.recover();
        vm.prank(beneficiary);
        assertEq(account.recover(receiver), 4e6);
        assertEq(usdc.balanceOf(address(account)), 4e6);
        assertEq(usdc.balanceOf(beneficiary), 0);
    }

    function test_DepositFailureRollsBackApprovalAndCanRetry() public {
        BridgeDepositReceiver receiver = _createReceiver();
        usdc.mint(address(receiver), 13e6);
        usdc.setRejectTransfers(true);
        vm.expectRevert(BridgeFundingTestToken.TransferRejected.selector);
        receiver.flush();
        assertEq(usdc.balanceOf(address(receiver)), 13e6);
        assertEq(usdc.allowance(address(receiver), address(clearinghouse)), 0);
        assertEq(clearinghouse.balanceUsdc(beneficiary), 0);
        assertEq(usdc.balanceOf(address(clearinghouse)), 0);
        usdc.setRejectTransfers(false);
        assertEq(receiver.flush(), 13e6);
        assertEq(clearinghouse.balanceUsdc(beneficiary), 13e6);
    }

    function test_EmptyFlushDoesNotCallClearinghouse() public {
        BridgeFundingClearinghouseProbe probe = new BridgeFundingClearinghouseProbe(address(usdc));
        BridgeDepositReceiver receiver = new BridgeDepositReceiver(beneficiary, address(probe), address(usdc));
        probe.configure(true, false);
        assertEq(receiver.flush(), 0);
        assertEq(probe.depositCalls(), 0);
        assertEq(usdc.allowance(address(receiver), address(probe)), 0);
    }

    function test_ExactAllowanceAndSharedGuardAcrossEveryReceiverMutation() public {
        BridgeFundingClearinghouseProbe probe = new BridgeFundingClearinghouseProbe(address(usdc));
        // Making the callback contract the beneficiary reaches both recovery guards rather than failing authorization.
        BridgeDepositReceiver receiver = new BridgeDepositReceiver(address(probe), address(probe), address(usdc));
        probe.configure(false, true);
        usdc.mint(address(receiver), 17e6);
        assertEq(receiver.flush(), 17e6);
        assertEq(probe.observedAllowance(), 17e6);
        assertEq(probe.creditedAccount(), address(probe));
        assertEq(probe.depositCalls(), 1);
        assertEq(usdc.allowance(address(receiver), address(probe)), 0);
        assertEq(usdc.balanceOf(address(probe)), 17e6);
        for (uint256 i; i < 3; i++) {
            assertFalse(probe.reentrySucceeded(i));
            assertEq(probe.reentryErrors(i), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        }
    }

    function test_ConstructorRejectsInvalidDependenciesAndWrongSettlementAsset() public {
        BridgeFundingTestToken other = new BridgeFundingTestToken();
        vm.expectRevert(BridgeDepositReceiver.BridgeDepositReceiver__ZeroBeneficiary.selector);
        new BridgeDepositReceiver(address(0), address(clearinghouse), address(usdc));
        vm.expectRevert(BridgeDepositReceiver.BridgeDepositReceiver__InvalidClearinghouse.selector);
        new BridgeDepositReceiver(beneficiary, stranger, address(usdc));
        vm.expectRevert(BridgeDepositReceiver.BridgeDepositReceiver__InvalidToken.selector);
        new BridgeDepositReceiver(beneficiary, address(clearinghouse), address(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                BridgeDepositReceiver.BridgeDepositReceiver__SettlementAssetMismatch.selector,
                address(usdc),
                address(other)
            )
        );
        new BridgeDepositReceiver(beneficiary, address(clearinghouse), address(other));
        vm.expectRevert(BridgeDepositReceiverFactory.BridgeDepositReceiverFactory__InvalidClearinghouse.selector);
        new BridgeDepositReceiverFactory(address(0), address(usdc));
        vm.expectRevert(BridgeDepositReceiverFactory.BridgeDepositReceiverFactory__InvalidToken.selector);
        new BridgeDepositReceiverFactory(address(clearinghouse), stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                BridgeDepositReceiverFactory.BridgeDepositReceiverFactory__SettlementAssetMismatch.selector,
                address(usdc),
                address(other)
            )
        );
        new BridgeDepositReceiverFactory(address(clearinghouse), address(other));
        vm.expectRevert(BridgeDepositReceiverFactory.BridgeDepositReceiverFactory__ZeroBeneficiary.selector);
        factory.createReceiver(address(0), INTENT_SALT);
    }

    function testFuzz_CompleteBalanceCreditsBeneficiaryExactly(
        uint96 amount
    ) public {
        vm.assume(amount != 0);
        BridgeDepositReceiver receiver = _createReceiver();
        usdc.mint(address(receiver), amount);
        assertEq(receiver.flush(), amount);
        assertEq(clearinghouse.balanceUsdc(beneficiary), amount);
        assertEq(usdc.balanceOf(address(clearinghouse)), amount);
        assertEq(usdc.balanceOf(address(receiver)), 0);
    }

    function _createReceiver() private returns (BridgeDepositReceiver) {
        return BridgeDepositReceiver(factory.createReceiver(beneficiary, INTENT_SALT));
    }

}
