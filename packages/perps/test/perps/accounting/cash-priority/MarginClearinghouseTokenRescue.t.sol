// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {Test} from "forge-std/Test.sol";

contract RescueTestToken is ERC20 {

    bool public failTransfer;

    constructor() ERC20("Rescue test token", "RESCUE") {}

    function mint(
        address recipient,
        uint256 amount
    ) external {
        _mint(recipient, amount);
    }

    function setFailTransfer() external {
        failTransfer = true;
    }

    function transfer(
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        if (failTransfer) {
            return false;
        }
        return super.transfer(recipient, amount);
    }

}

contract MarginClearinghouseTokenRescueTest is Test {

    event TokenRescued(address indexed token, address indexed recipient, uint256 amount);

    MarginClearinghouse internal clearinghouse;
    RescueTestToken internal settlementToken;
    RescueTestToken internal accidentalToken;
    address internal alice = address(0xA11CE);

    function setUp() public {
        settlementToken = new RescueTestToken();
        accidentalToken = new RescueTestToken();
        clearinghouse = new MarginClearinghouse(address(settlementToken));
        settlementToken.mint(alice, 100e6);
        vm.startPrank(alice);
        settlementToken.approve(address(clearinghouse), 100e6);
        clearinghouse.depositMargin(100e6);
        vm.stopPrank();
        clearinghouse.setEngine(address(this));
        clearinghouse.lockPositionMargin(alice, 40e6);
        accidentalToken.mint(address(clearinghouse), 25e18);
    }

    function test_OwnerRescuesFullBalanceWithoutChangingSettlementCustody() public {
        bytes32 bucketsBefore = keccak256(abi.encode(clearinghouse.getAccountAssetBuckets(alice)));
        vm.expectEmit(true, true, false, true, address(clearinghouse));
        emit TokenRescued(address(accidentalToken), alice, 25e18);
        clearinghouse.rescueToken(address(accidentalToken), alice);

        assertEq(accidentalToken.balanceOf(alice), 25e18);
        assertEq(accidentalToken.balanceOf(address(clearinghouse)), 0);
        assertEq(settlementToken.balanceOf(address(clearinghouse)), 100e6);
        assertEq(keccak256(abi.encode(clearinghouse.getAccountAssetBuckets(alice))), bucketsBefore);
    }

    function test_NonOwnerCannotRescueTokens() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        clearinghouse.rescueToken(address(accidentalToken), alice);
        assertEq(accidentalToken.balanceOf(address(clearinghouse)), 25e18);
    }

    function test_OwnerCannotRescueSettlementAssetEvenWithUncreditedExcess() public {
        settlementToken.mint(address(clearinghouse), 50e6);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__CannotRescueSettlementAsset.selector);
        clearinghouse.rescueToken(address(settlementToken), alice);
        assertEq(settlementToken.balanceOf(address(clearinghouse)), 150e6);
        assertEq(clearinghouse.getAccountAssetBuckets(alice).settlementBalanceAssets, 100e6);
    }

    function test_RescueRejectsZeroToken() public {
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__ZeroAddress.selector);
        clearinghouse.rescueToken(address(0), alice);
    }

    function test_RescueRejectsZeroRecipient() public {
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__ZeroAddress.selector);
        clearinghouse.rescueToken(address(accidentalToken), address(0));
    }

    function test_RescueRevertsOnFalseTransferReturn() public {
        accidentalToken.setFailTransfer();
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(accidentalToken)));
        clearinghouse.rescueToken(address(accidentalToken), alice);
        assertEq(accidentalToken.balanceOf(address(clearinghouse)), 25e18);
        assertEq(accidentalToken.balanceOf(alice), 0);
    }

}
