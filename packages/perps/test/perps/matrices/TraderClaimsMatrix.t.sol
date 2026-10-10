// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

/// @notice Claims are created by executed profitable closes; only cash scarcity is imposed synthetically.
contract TraderClaimsMatrixTest is BasePerpTest {

    address private constant ALICE = address(0xDC01);
    address private constant BOB = address(0xDC02);
    uint256 private constant CLAIM = 960_400_000;

    function _createClaims(
        bool secondClaim
    ) private {
        _fundTrader(ALICE, 11_000e6);
        _open(ALICE, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);
        if (secondClaim) {
            _fundTrader(BOB, 11_000e6);
            _open(BOB, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);
        }
        usdc.burn(address(pool), usdc.balanceOf(address(pool)));
        _close(ALICE, CfdTypes.Side.LONG, 100_000e18, 99_000_000);
        assertEq(
            engine.traderClaimBalanceUsdc(ALICE), CLAIM, "Claim equals 1000 USDC profit less 39.6 USDC execution fee"
        );
        if (secondClaim) {
            _close(BOB, CfdTypes.Side.LONG, 100_000e18, 99_000_000);
            assertEq(engine.traderClaimBalanceUsdc(BOB), CLAIM, "Second beneficiary owns its own profit");
        }
        assertEq(engine.totalTraderClaimBalanceUsdc(), secondClaim ? 2 * CLAIM : CLAIM);
    }

    function test_TraderClaim_RevertsWhenSingleClaimExceedsAvailablePoolCash() public {
        _createClaims(false);
        usdc.mint(address(pool), CLAIM - 1);
        _assertBlockedClaim(ALICE, ICfdEngineTypes.CfdEngine__InsufficientPoolLiquidity.selector);
    }

    function test_TraderClaim_AggregatePriorityBlocksIndividuallyAffordableClaim() public {
        _createClaims(true);
        usdc.mint(address(pool), 2 * CLAIM - 1);
        _assertBlockedClaim(ALICE, ICfdEngineTypes.CfdEngine__InsufficientPoolLiquidity.selector);
        _assertBlockedClaim(BOB, ICfdEngineTypes.CfdEngine__InsufficientPoolLiquidity.selector);
    }

    function test_TraderClaim_ExactAggregateCashPaysBothBeneficiariesOnce() public {
        _createClaims(true);
        usdc.mint(address(pool), 2 * CLAIM);
        _assertClaimPaid(ALICE);
        assertEq(engine.traderClaimBalanceUsdc(BOB), CLAIM, "First settlement preserves the other beneficiary");
        _assertClaimPaid(BOB);
        assertEq(engine.totalTraderClaimBalanceUsdc(), 0);
        assertEq(usdc.balanceOf(address(pool)), 0);
        _assertBlockedClaim(ALICE, ICfdEngineTypes.CfdEngine__NoTraderClaim.selector);
        _assertBlockedClaim(BOB, ICfdEngineTypes.CfdEngine__NoTraderClaim.selector);
    }

    function test_TraderClaim_SurplusCashRemainsInPool() public {
        _createClaims(false);
        usdc.mint(address(pool), CLAIM + 1);
        _assertClaimPaid(ALICE);
        assertEq(usdc.balanceOf(address(pool)), 1, "Claim does not consume surplus cash");
    }

    function test_TraderClaim_OnlyBeneficiaryCanSettle() public {
        _createClaims(false);
        usdc.mint(address(pool), CLAIM);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__NotAccountOwner.selector);
        vm.prank(BOB);
        engine.settleTraderClaim(ALICE);
        assertEq(engine.traderClaimBalanceUsdc(ALICE), CLAIM);
        assertEq(usdc.balanceOf(address(pool)), CLAIM);
    }

    function test_TraderClaim_DownstreamTransferFailureRollsBackAccounting() public {
        _createClaims(false);
        usdc.mint(address(pool), CLAIM);
        bytes memory failure = abi.encodeWithSignature("Error(string)", "injected transfer failure");
        vm.mockCallRevert(
            address(usdc), abi.encodeWithSelector(usdc.transfer.selector, address(clearinghouse), CLAIM), failure
        );
        _assertBlockedClaim(ALICE, bytes4(keccak256("Error(string)")));
        vm.clearMockedCalls();
        _assertClaimPaid(ALICE);
    }

    function _assertBlockedClaim(
        address account,
        bytes4 selector
    ) private {
        uint256 claimBefore = engine.traderClaimBalanceUsdc(account);
        uint256 totalBefore = engine.totalTraderClaimBalanceUsdc();
        uint256 settlementBefore = clearinghouse.balanceUsdc(account);
        uint256 poolCashBefore = usdc.balanceOf(address(pool));
        uint256 custodyBefore = usdc.balanceOf(address(clearinghouse));
        vm.expectPartialRevert(selector);
        vm.prank(account);
        engine.settleTraderClaim(account);
        assertEq(engine.traderClaimBalanceUsdc(account), claimBefore);
        assertEq(engine.totalTraderClaimBalanceUsdc(), totalBefore);
        assertEq(clearinghouse.balanceUsdc(account), settlementBefore);
        assertEq(usdc.balanceOf(address(pool)), poolCashBefore);
        assertEq(usdc.balanceOf(address(clearinghouse)), custodyBefore);
    }

    function _assertClaimPaid(
        address account
    ) private {
        uint256 totalBefore = engine.totalTraderClaimBalanceUsdc();
        uint256 settlementBefore = clearinghouse.balanceUsdc(account);
        uint256 walletBefore = usdc.balanceOf(account);
        uint256 poolCashBefore = usdc.balanceOf(address(pool));
        uint256 custodyBefore = usdc.balanceOf(address(clearinghouse));
        vm.prank(account);
        engine.settleTraderClaim(account);
        assertEq(engine.traderClaimBalanceUsdc(account), 0);
        assertEq(engine.totalTraderClaimBalanceUsdc(), totalBefore - CLAIM);
        assertEq(clearinghouse.balanceUsdc(account), settlementBefore + CLAIM);
        assertEq(usdc.balanceOf(address(pool)), poolCashBefore - CLAIM);
        assertEq(usdc.balanceOf(address(clearinghouse)), custodyBefore + CLAIM);
        assertEq(usdc.balanceOf(account), walletBefore, "Claims settle into clearinghouse custody");
    }

}
