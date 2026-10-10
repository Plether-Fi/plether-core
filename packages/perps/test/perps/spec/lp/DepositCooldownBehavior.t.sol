// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: spec. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CooldownBypassReceiver, TrancheCooldownBypassReceiver} from "../../support/BehaviorScenarioHelpers.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";

contract ExistingHolderDustDepositsTest is BasePerpTest {

    address alice = address(0xA11CE);
    address attacker = address(0xBAD);

    /// @dev spec; source: ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries.
    function test_ThirdPartyDustDepositToExistingHolderReverts() public {
        _fundJunior(alice, 100_000e6);

        vm.warp(block.timestamp + 50 minutes);

        uint256 minimumDeposit = pool.minTrancheDepositUsdc();
        usdc.mint(attacker, minimumDeposit);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), minimumDeposit);
        uint256 requestId = juniorVault.requestDeposit(minimumDeposit, attacker);
        vm.stopPrank();

        vm.warp(juniorVault.depositEpochStart(requestId));
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        _settleLpEpochForTest();

        vm.startPrank(attacker);
        vm.expectRevert(TrancheVault.TrancheVault__ThirdPartyDepositForExistingHolder.selector);
        juniorVault.claimDeposit(requestId, minimumDeposit, alice, attacker);
        vm.stopPrank();
    }

}

contract TransferredShareCooldownTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries.
    function test_ShareTransferPreservesRecipientCooldown() public {
        _fundJunior(alice, 100_000 * 1e6);
        uint256 aliceDepositTime = juniorVault.lastDepositTime(alice);

        // Wait for Alice's cooldown to expire
        vm.warp(aliceDepositTime + juniorVault.DEPOSIT_COOLDOWN());

        // Alice transfers to bob (fresh address, lastDepositTime=0)
        uint256 shares = juniorVault.balanceOf(alice);
        vm.prank(alice);
        juniorVault.transfer(bob, shares);

        // Bob inherits Alice's deposit timestamp. This fixture transfers only after the
        // sender cooldown has elapsed and verifies timestamp propagation to a fresh recipient.
        assertEq(juniorVault.lastDepositTime(bob), aliceDepositTime, "Bob inherits Alice's deposit time");
        assertGt(juniorVault.lastDepositTime(bob), 0, "Zero default is eliminated");
    }

}

contract ExistingHolderTopUpTest is BasePerpTest {

    address alice = address(0xA11CE);
    address helper = address(0xB0B);

    /// @dev spec; source: ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries.
    function test_SmallThirdPartyTopUpForExistingHolderReverts() public {
        _fundJunior(alice, 100_000e6);

        usdc.mint(helper, 4999e6);
        vm.startPrank(helper);
        usdc.approve(address(juniorVault), 4999e6);
        uint256 requestId = juniorVault.requestDeposit(4999e6, helper);
        vm.stopPrank();

        vm.warp(juniorVault.depositEpochStart(requestId));
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        _settleLpEpochForTest();

        vm.startPrank(helper);
        vm.expectRevert(TrancheVault.TrancheVault__ThirdPartyDepositForExistingHolder.selector);
        juniorVault.claimDeposit(requestId, 4999e6, alice, helper);
        vm.stopPrank();
    }

}

contract IntermediatedTopUpTest is BasePerpTest {

    address attacker = address(0xBAD);

    /// @dev spec; source: ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries.
    function test_TwoContractThirdPartyDepositForExistingHolderMustRevert() public {
        TrancheCooldownBypassReceiver receiver = new TrancheCooldownBypassReceiver();
        address receiverAddr = address(receiver);

        uint256 minimumDeposit = pool.minTrancheDepositUsdc();
        _fundJunior(receiverAddr, minimumDeposit);

        vm.warp(block.timestamp + 1 hours + 1);

        usdc.mint(attacker, 10_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), 10_000e6);
        uint256 requestId = juniorVault.requestDeposit(10_000e6, attacker);
        vm.stopPrank();

        vm.warp(juniorVault.depositEpochStart(requestId));
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        _settleLpEpochForTest();

        vm.startPrank(attacker);
        vm.expectRevert(TrancheVault.TrancheVault__ThirdPartyDepositForExistingHolder.selector);
        juniorVault.claimDeposit(requestId, 10_000e6, receiverAddr, attacker);
        vm.stopPrank();
    }

}

contract ThirdPartyActivationCooldownTest is BasePerpTest {

    address alice = address(0xA11CE);
    address helper = address(0xB0B);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries.
    function test_ThirdPartyDepositMustNotBypassCooldown() public {
        usdc.mint(helper, 100_000e6);
        vm.startPrank(helper);
        usdc.approve(address(juniorVault), 100_000e6);
        uint256 depositRequestId = juniorVault.requestDeposit(100_000e6, alice, helper);
        vm.stopPrank();

        vm.warp(juniorVault.depositEpochStart(depositRequestId));
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        _settleLpEpochForTest();

        vm.prank(alice);
        juniorVault.claimDeposit(depositRequestId, 100_000e6, alice, alice);

        uint256 aliceShares = juniorVault.balanceOf(alice);
        vm.expectRevert(TrancheVault.TrancheVault__DepositCooldown.selector);
        vm.prank(alice);
        juniorVault.requestRedeem(aliceShares, alice, alice);
    }

}

contract ThirdPartyCooldownMutationsTest is BasePerpTest {

    address alice = address(0xA11CE);
    address helper = address(0xB0B);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries.
    function test_SmallThirdPartyTopUpForExistingHolderReverts() public {
        _fundJunior(alice, 100_000e6);
        vm.warp(block.timestamp + 1 hours + 1);

        usdc.mint(helper, 1000e6);
        vm.startPrank(helper);
        usdc.approve(address(juniorVault), 1000e6);
        uint256 requestId = juniorVault.requestDeposit(1000e6, helper);
        vm.stopPrank();

        vm.warp(juniorVault.depositEpochStart(requestId));
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        _settleLpEpochForTest();

        vm.startPrank(helper);
        vm.expectRevert(TrancheVault.TrancheVault__ThirdPartyDepositForExistingHolder.selector);
        juniorVault.claimDeposit(requestId, 1000e6, alice, helper);
        vm.stopPrank();
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries.
    function test_ThirdPartyWithdrawZeroCannotResetCooldown() public {
        _fundJunior(alice, 100_000e6);
        vm.warp(block.timestamp + juniorVault.DEPOSIT_COOLDOWN() + 1);

        uint256 maxRequestRedeemBefore = juniorVault.maxRequestRedeem(alice);
        uint256 lastDepositBefore = juniorVault.lastDepositTime(alice);
        assertGt(maxRequestRedeemBefore, 0, "Alice should be redeemable before zero-amount grief");
        assertEq(juniorVault.allowance(alice, helper), 0, "Helper should have no share allowance");

        vm.prank(helper);
        vm.expectRevert(TrancheVault.TrancheVault__NotControllerOrOperator.selector);
        juniorVault.withdraw(0, helper, alice);

        assertEq(juniorVault.lastDepositTime(alice), lastDepositBefore, "Zero withdraw must not reset cooldown");
        assertEq(juniorVault.maxRequestRedeem(alice), maxRequestRedeemBefore, "Alice should retain request capacity");
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries.
    function test_ThirdPartyRedeemZeroCannotResetCooldown() public {
        _fundJunior(alice, 100_000e6);
        vm.warp(block.timestamp + juniorVault.DEPOSIT_COOLDOWN() + 1);

        uint256 maxRequestRedeemBefore = juniorVault.maxRequestRedeem(alice);
        uint256 lastDepositBefore = juniorVault.lastDepositTime(alice);
        assertGt(maxRequestRedeemBefore, 0, "Alice should be redeemable before zero-amount grief");
        assertEq(juniorVault.allowance(alice, helper), 0, "Helper should have no share allowance");

        vm.prank(helper);
        vm.expectRevert(TrancheVault.TrancheVault__NotControllerOrOperator.selector);
        juniorVault.redeem(0, helper, alice);

        assertEq(juniorVault.lastDepositTime(alice), lastDepositBefore, "Zero redeem must not reset cooldown");
        assertEq(juniorVault.maxRequestRedeem(alice), maxRequestRedeemBefore, "Alice should retain request capacity");
    }

}

contract MaterialThirdPartyTopUpTest is BasePerpTest {

    address alice = address(0xA11CE);
    address attacker = address(0xBAD);

    /// @dev spec; source: ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries.
    function test_FivePercentThirdPartyTopUpForExistingHolderReverts() public {
        _fundJunior(alice, 100_000e6);

        vm.warp(block.timestamp + 50 minutes);

        usdc.mint(attacker, 5000e6);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), 5000e6);
        uint256 requestId = juniorVault.requestDeposit(5000e6, attacker);
        vm.stopPrank();

        vm.warp(juniorVault.depositEpochStart(requestId));
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        _settleLpEpochForTest();

        vm.startPrank(attacker);
        vm.expectRevert(TrancheVault.TrancheVault__ThirdPartyDepositForExistingHolder.selector);
        juniorVault.claimDeposit(requestId, 5000e6, alice, attacker);
        vm.stopPrank();
    }

}

contract CarryAndMarginCheckpointCooldownTest is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address keeper = address(0xBEEF);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries.
    function test_NewDepositResetsCooldownTimestamp() public {
        _fundJunior(alice, 100_000 * 1e6);
        uint256 previousDepositTime = juniorVault.lastDepositTime(alice);

        vm.warp(block.timestamp + 2 hours);
        _fundJunior(alice, 100_000 * 1e6);
        uint256 redepositTime = block.timestamp;

        assertGt(redepositTime, previousDepositTime, "New deposit should advance the cooldown timestamp");
        assertEq(juniorVault.lastDepositTime(alice), redepositTime, "New deposit should reset cooldown timestamp");
    }

}

contract ProxyDepositCooldownTest is BasePerpTest {

    address helper = address(0xB0B);

    /// @dev spec; source: ACCOUNTING_SPEC.md#lp-request-admission-maturity-and-oracle-boundaries.
    function test_ThirdPartyDepositIntoProxyMustStillStartCooldown() public {
        CooldownBypassReceiver receiver = new CooldownBypassReceiver();

        usdc.mint(helper, 100_000e6);
        vm.startPrank(helper);
        usdc.approve(address(juniorVault), 100_000e6);
        uint256 requestId = juniorVault.requestDeposit(100_000e6, address(receiver), helper);
        vm.stopPrank();

        vm.warp(juniorVault.depositEpochStart(requestId));
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        _settleLpEpochForTest();
        receiver.claimDeposit(juniorVault, requestId);

        vm.expectRevert(TrancheVault.TrancheVault__DepositCooldown.selector);
        receiver.requestRedeemAll(juniorVault);
    }

}
