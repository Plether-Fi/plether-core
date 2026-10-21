// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {PletherOracleEngineMock, PletherOracleVaultMock} from "../../spec/oracle/PletherOracleMocks.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Deliberately has no payable receive or fallback function.
contract NonPayableRefundClaimant {

    function claimSelf(
        address ledger,
        bool fromOracle
    ) external {
        if (fromOracle) {
            IPletherOracle(ledger).claimEthRefund();
        } else {
            OrderRouterAdmin(ledger).claimBalance();
        }
    }

    function claimTo(
        address ledger,
        bool fromOracle,
        address payable recipient
    ) external {
        if (fromOracle) {
            IPletherOracle(ledger).claimEthRefundTo(recipient);
        } else {
            OrderRouterAdmin(ledger).claimBalanceTo(recipient);
        }
    }

}

contract CallbackRefundClaimant is NonPayableRefundClaimant {

    bool public acceptEth;
    bool public reenter;
    bool public fromOracle;
    bool public reentryRejected;

    function configure(
        bool fromOracle_,
        bool reenter_
    ) external {
        acceptEth = true;
        fromOracle = fromOracle_;
        reenter = reenter_;
    }

    receive() external payable {
        require(acceptEth, "reject ETH");
        if (reenter) {
            (bool legacyOk,) = address(this).call(abi.encodeCall(this.claimSelf, (msg.sender, fromOracle)));
            (bool directedOk,) =
                address(this).call(abi.encodeCall(this.claimTo, (msg.sender, fromOracle, payable(address(this)))));
            require(!legacyOk && !directedOk, "reentrant claim succeeded");
            reentryRejected = true;
        }
    }

}

contract DeferredEthRefundClaimsTest is Test {

    event EthRefundClaimed(address indexed recipient, uint256 amount);
    event EthRefundClaimedTo(address indexed beneficiary, address indexed recipient, uint256 amount);

    OrderRouterAdmin internal admin;
    PletherOracle internal oracle;
    MockPyth internal pyth;
    address payable internal recipient = payable(address(0xA11CE));
    bytes32 internal constant FEED = bytes32(uint256(1));

    function setUp() public {
        vm.warp(1000);
        vm.deal(address(this), 100 ether);
        admin = new OrderRouterAdmin(address(this), address(this));
        pyth = new MockPyth();
        pyth.setSynchronizeLegacyUniquePrices(true);
        pyth.setPrice(FEED, int64(100_000_000), int32(-8), block.timestamp);
        PletherOracleEngineMock engine = new PletherOracleEngineMock();
        engine.setOrderRouter(address(this));
        bytes32[] memory ids = new bytes32[](1);
        uint256[] memory weights = new uint256[](1);
        uint256[] memory bases = new uint256[](1);
        ids[0] = FEED;
        weights[0] = 1e18;
        bases[0] = 1e8;
        oracle = new PletherOracle(
            address(engine), address(new PletherOracleVaultMock()), address(pyth), ids, weights, bases, new bool[](1)
        );
    }

    function _ledger(
        bool fromOracle
    ) internal view returns (address) {
        return fromOracle ? address(oracle) : address(admin);
    }

    function _balance(
        bool fromOracle,
        address beneficiary
    ) internal view returns (uint256) {
        return fromOracle ? oracle.claimableEth(beneficiary) : admin.claimableEth(beneficiary);
    }

    function _credit(
        bool fromOracle,
        address beneficiary,
        uint256 amount
    ) internal {
        if (fromOracle) {
            bytes[] memory data = new bytes[](1);
            data[0] = hex"00";
            oracle.updatePrice{value: amount + pyth.getUpdateFee(data)}(
                beneficiary, data, IPletherOracle.PriceMode.MarkRefresh
            );
        } else {
            admin.creditClaimableEth{value: amount}(beneficiary, amount);
        }
        assertEq(_balance(fromOracle, beneficiary), amount, "fixture creates funded deferred credit");
    }

    function _nothingToClaim(
        bool fromOracle
    ) internal pure returns (bytes4) {
        return fromOracle
            ? IPletherOracle.PletherOracle__NothingToClaim.selector
            : OrderRouterAdmin.OrderRouterAdmin__NothingToClaim.selector;
    }

    function _transferFailed(
        bool fromOracle
    ) internal pure returns (bytes4) {
        return fromOracle
            ? IPletherOracle.PletherOracle__EthTransferFailed.selector
            : OrderRouterAdmin.OrderRouterAdmin__EthTransferFailed.selector;
    }

    function test_NonPayableBeneficiaryCanRedirectAfterLegacyClaimFails() public {
        for (uint256 i; i < 2; ++i) {
            bool fromOracle = i == 1;
            NonPayableRefundClaimant claimant = new NonPayableRefundClaimant();
            _credit(fromOracle, address(claimant), 1 ether);
            vm.expectRevert(_transferFailed(fromOracle));
            claimant.claimSelf(_ledger(fromOracle), fromOracle);
            assertEq(_balance(fromOracle, address(claimant)), 1 ether);

            uint256 beforeBalance = recipient.balance;
            vm.expectEmit(true, true, false, true, _ledger(fromOracle));
            emit EthRefundClaimedTo(address(claimant), recipient, 1 ether);
            claimant.claimTo(_ledger(fromOracle), fromOracle, recipient);
            assertEq(recipient.balance - beforeBalance, 1 ether);
            assertEq(_balance(fromOracle, address(claimant)), 0);
            assertEq(_ledger(fromOracle).balance, 0);
            vm.expectRevert(_nothingToClaim(fromOracle));
            claimant.claimTo(_ledger(fromOracle), fromOracle, recipient);
        }
    }

    function test_UnrelatedCallerCannotClaimAnotherBeneficiaryCredit() public {
        for (uint256 i; i < 2; ++i) {
            bool fromOracle = i == 1;
            NonPayableRefundClaimant claimant = new NonPayableRefundClaimant();
            _credit(fromOracle, address(claimant), 1 ether);
            vm.expectRevert(_nothingToClaim(fromOracle));
            if (fromOracle) {
                oracle.claimEthRefundTo(recipient);
            } else {
                admin.claimBalanceTo(recipient);
            }
            assertEq(_balance(fromOracle, address(claimant)), 1 ether);
            assertEq(_ledger(fromOracle).balance, 1 ether);
        }
    }

    function test_RedirectionDoesNotConsumeRecipientsOwnCredit() public {
        for (uint256 i; i < 2; ++i) {
            bool fromOracle = i == 1;
            NonPayableRefundClaimant claimant = new NonPayableRefundClaimant();
            CallbackRefundClaimant receiver = new CallbackRefundClaimant();
            _credit(fromOracle, address(claimant), 1 ether);
            _credit(fromOracle, address(receiver), 2 ether);
            receiver.configure(fromOracle, false);
            claimant.claimTo(_ledger(fromOracle), fromOracle, payable(address(receiver)));
            assertEq(address(receiver).balance, 1 ether);
            assertEq(_balance(fromOracle, address(claimant)), 0);
            assertEq(_balance(fromOracle, address(receiver)), 2 ether);
            assertEq(_ledger(fromOracle).balance, 2 ether);
        }
    }

    function test_FailedDirectedTransferPreservesCreditForRetry() public {
        for (uint256 i; i < 2; ++i) {
            bool fromOracle = i == 1;
            NonPayableRefundClaimant claimant = new NonPayableRefundClaimant();
            NonPayableRefundClaimant rejectingRecipient = new NonPayableRefundClaimant();
            _credit(fromOracle, address(claimant), 1 ether);
            vm.expectRevert(_transferFailed(fromOracle));
            claimant.claimTo(_ledger(fromOracle), fromOracle, payable(address(rejectingRecipient)));
            assertEq(_balance(fromOracle, address(claimant)), 1 ether);
            assertEq(_ledger(fromOracle).balance, 1 ether);
            claimant.claimTo(_ledger(fromOracle), fromOracle, recipient);
            assertEq(_balance(fromOracle, address(claimant)), 0);
        }
    }

    function test_ZeroRecipientPreservesCreditAndCustody() public {
        for (uint256 i; i < 2; ++i) {
            bool fromOracle = i == 1;
            NonPayableRefundClaimant claimant = new NonPayableRefundClaimant();
            _credit(fromOracle, address(claimant), 1 ether);
            vm.expectRevert(
                fromOracle
                    ? IPletherOracle.PletherOracle__InvalidRefundRecipient.selector
                    : OrderRouterAdmin.OrderRouterAdmin__InvalidRefundRecipient.selector
            );
            claimant.claimTo(_ledger(fromOracle), fromOracle, payable(address(0)));
            assertEq(_balance(fromOracle, address(claimant)), 1 ether);
            assertEq(_ledger(fromOracle).balance, 1 ether);
        }
    }

    function test_LegacySelfClaimsStillPayFullBalance() public {
        for (uint256 i; i < 2; ++i) {
            bool fromOracle = i == 1;
            CallbackRefundClaimant claimant = new CallbackRefundClaimant();
            _credit(fromOracle, address(claimant), 1 ether);
            claimant.configure(fromOracle, false);
            if (fromOracle) {
                vm.expectEmit(true, false, false, true, address(oracle));
                emit EthRefundClaimed(address(claimant), 1 ether);
            }
            claimant.claimSelf(_ledger(fromOracle), fromOracle);
            assertEq(address(claimant).balance, 1 ether);
            assertEq(_balance(fromOracle, address(claimant)), 0);
        }
    }

    function test_CallbackCannotDoubleClaimThroughEitherSelector() public {
        for (uint256 i; i < 2; ++i) {
            bool fromOracle = i == 1;
            CallbackRefundClaimant claimant = new CallbackRefundClaimant();
            _credit(fromOracle, address(claimant), 1 ether);
            claimant.configure(fromOracle, true);
            claimant.claimTo(_ledger(fromOracle), fromOracle, payable(address(claimant)));
            assertTrue(claimant.reentryRejected());
            assertEq(address(claimant).balance, 1 ether);
            assertEq(_balance(fromOracle, address(claimant)), 0);
            assertEq(_ledger(fromOracle).balance, 0);
        }
    }

    function test_OracleRedirectsRefundWhenPythFeeIsNonzero() public {
        pyth.setFee(1 gwei);
        NonPayableRefundClaimant claimant = new NonPayableRefundClaimant();
        _credit(true, address(claimant), 1 ether);
        claimant.claimTo(address(oracle), true, recipient);
        assertEq(recipient.balance, 1 ether);
        assertEq(address(pyth).balance, 1 gwei);
        assertEq(oracle.claimableEth(address(claimant)), 0);
    }

}
