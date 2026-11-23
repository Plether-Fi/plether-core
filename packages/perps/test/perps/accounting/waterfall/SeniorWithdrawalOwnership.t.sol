// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {HousePoolTestBase} from "../../shared/HousePoolTestBase.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

/// @notice Settlement-level ownership bounds after an authorized payout nearly wipes the tranches.
/// @dev Public trading reachability is covered separately by SeniorHwmAtomExit.t.sol.
contract SeniorWithdrawalOwnershipTest is HousePoolTestBase {

    struct WithdrawalState {
        uint256 principal;
        uint256 hwm;
        uint256 supply;
        uint256 escrow;
        uint256 unassigned;
    }

    address internal constant FIRST_EXIT = address(0xE817);
    address internal constant SECOND_EXIT = address(0xE818);

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 1e6;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 1e6;
    }

    function setUp() public override {
        super.setUp();
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 0;
        pool.proposePoolConfig(config);
        vm.warp(pool.poolConfigActivationTime());
        _refreshMarkForAsyncSettlement();
        pool.finalizePoolConfig();

        _fundJunior(bob, 100_000e6);
        _fundSenior(alice, 600_000e6);
        _finishAsyncCooldown(seniorVault, alice);
        assertFalse(engine.isOracleFrozen(), "ownership tests use fee-free live settlement");
    }

    function test_AtomScaleExitsPreserveRemainingShareProtection() public {
        uint256[6] memory principals = [uint256(3), 11, 101, 571, 1001, 1e6];
        for (uint256 i; i < principals.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            uint256 principal = principals[i];
            uint256 payout = principal * 85 / 100;
            uint256 supply = seniorVault.totalSupply();
            // Choose the first share amount quoting this many atoms. Its ownership fraction is smaller than A/P.
            uint256 shares = (payout * (supply + 1000) + principal) / (principal + 1);
            _giveShares(FIRST_EXIT, shares);
            _impairTo(principal);
            WithdrawalState memory beforeState = _withdrawalState();
            uint256 requestId = _requestAsyncRedeem(seniorVault, FIRST_EXIT, shares);

            IHousePool.LpEpochSettlementResult memory result = _settleAsyncRequest(requestId, true);

            assertEq(result.seniorFundedShares, shares);
            assertEq(result.seniorFundedAssets, payout);
            _assertWithdrawal(beforeState, result);
            uint256 principalBasedHwm = beforeState.hwm - beforeState.hwm * payout / principal;
            assertGt(pool.seniorHighWaterMark(), principalBasedHwm, "share floor must bind for this atom-scale quote");
            assertEq(seniorVault.claimableRedeemAssets(requestId, FIRST_EXIT), payout);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_MultipleEpochsUseAggregateSharesAndPreBurnSupply() public {
        uint256 shares = seniorVault.totalSupply() * 2501 / 10_000;
        _giveShares(FIRST_EXIT, shares);
        _giveShares(SECOND_EXIT, shares);
        _impairTo(3);
        uint256 firstId = _requestAsyncRedeem(seniorVault, FIRST_EXIT, shares);
        vm.warp(pool.lpEpochStart(firstId));
        uint256 secondId = _requestAsyncRedeem(seniorVault, SECOND_EXIT, shares);
        assertGt(secondId, firstId, "each rounded quote must belong to a distinct epoch");
        WithdrawalState memory beforeState = _withdrawalState();

        IHousePool.LpEpochSettlementResult memory result = _settleAsyncRequest(secondId, true);

        assertEq(result.seniorProcessedEpochs, 2);
        assertEq(result.seniorFundedShares, shares * 2);
        assertEq(result.seniorFundedAssets, 2);
        _assertWithdrawal(beforeState, result);
        assertEq(pool.seniorHighWaterMark(), beforeState.hwm - beforeState.hwm * (shares * 2) / beforeState.supply);
        assertEq(seniorVault.claimableRedeemAssets(firstId, FIRST_EXIT), 1);
        assertEq(seniorVault.claimableRedeemAssets(secondId, SECOND_EXIT), 1);
    }

    function test_SuccessiveSettlementsUseFreshOwnershipSnapshots() public {
        uint256 shares = seniorVault.totalSupply() * 3 / 10;
        _giveShares(FIRST_EXIT, shares);
        _giveShares(SECOND_EXIT, shares);
        _impairTo(3);
        WithdrawalState memory firstState = _withdrawalState();
        uint256 firstId = _requestAsyncRedeem(seniorVault, FIRST_EXIT, shares);
        IHousePool.LpEpochSettlementResult memory first = _settleAsyncRequest(firstId, true);
        assertEq(first.seniorFundedAssets, 1);
        _assertWithdrawal(firstState, first);

        WithdrawalState memory secondState = _withdrawalState();
        uint256 secondId = _requestAsyncRedeem(seniorVault, SECOND_EXIT, shares);
        IHousePool.LpEpochSettlementResult memory second = _settleAsyncRequest(secondId, true);
        assertEq(second.seniorFundedAssets, 1);
        _assertWithdrawal(secondState, second);
        assertEq(pool.seniorPrincipal(), 1);
        assertEq(pool.seniorHighWaterMark(), secondState.hwm - secondState.hwm * shares / secondState.supply);
    }

    function test_ZeroQuoteRefundPreservesHwmAndShareSupply() public {
        uint256 shares = seniorVault.totalSupply() / 5;
        _giveShares(FIRST_EXIT, shares);
        _impairTo(3);
        WithdrawalState memory beforeState = _withdrawalState();
        uint256 requestId = _requestAsyncRedeem(seniorVault, FIRST_EXIT, shares);

        IHousePool.LpEpochSettlementResult memory result = _settleAsyncRequest(requestId, true);

        assertEq(result.seniorFundedShares, 0);
        assertEq(result.seniorFundedAssets, 0);
        _assertWithdrawal(beforeState, result);
        assertEq(seniorVault.refundableRedeemRequest(requestId, FIRST_EXIT), shares);
        assertEq(seniorVault.claimableRedeemAssets(requestId, FIRST_EXIT), 0);
    }

    function test_FullPrincipalFundingStillClearsHwmWithSharesRemaining() public {
        uint256 shares = seniorVault.totalSupply() * 4 / 5;
        _giveShares(FIRST_EXIT, shares);
        _impairTo(3);
        WithdrawalState memory beforeState = _withdrawalState();
        uint256 requestId = _requestAsyncRedeem(seniorVault, FIRST_EXIT, shares);

        IHousePool.LpEpochSettlementResult memory result = _settleAsyncRequest(requestId, true);

        assertEq(result.seniorFundedAssets, 3);
        assertEq(result.seniorFundedShares, shares);
        _assertWithdrawal(beforeState, result);
        assertEq(pool.seniorHighWaterMark(), 0, "full-principal funding keeps the existing clearing rule");
        assertGt(seniorVault.totalSupply(), 0, "remaining shares do not change the full-funding exception");
    }

    function test_WorkCapContinuationPreservesExistingConservativeRetention() public {
        uint256 supply = seniorVault.totalSupply();
        // Each distinct epoch quotes just below two atoms and pays one against the frozen P=101 snapshot.
        uint256 shares = (supply + 1000) * 199 / (100 * 102);
        for (uint256 i; i < 17; ++i) {
            _giveShares(address(uint160(0xE900 + i)), shares);
        }
        _impairTo(101);
        for (uint256 i; i < 17; ++i) {
            uint256 requestId = _requestAsyncRedeem(seniorVault, address(uint160(0xE900 + i)), shares);
            vm.warp(pool.lpEpochStart(requestId));
        }
        _refreshMarkForAsyncSettlement();
        assertFalse(engine.isOracleFrozen());
        WithdrawalState memory firstState = _withdrawalState();

        IHousePool.LpEpochSettlementResult memory first = _settleLpEpochForTest();

        assertEq(first.seniorProcessedEpochs, 16);
        assertEq(first.seniorFundedShares, shares * 16);
        assertEq(first.seniorFundedAssets, 16);
        assertTrue(first.seniorBacklog);
        _assertWithdrawal(firstState, first);
        assertEq(pool.seniorHighWaterMark(), firstState.hwm - firstState.hwm * 16 / 101);
        uint256 shareBasedHwm = firstState.hwm - firstState.hwm * first.seniorFundedShares / firstState.supply;
        assertGt(pool.seniorHighWaterMark() - shareBasedHwm, 90_000e6, "reverse excess retention remains unchanged");

        WithdrawalState memory secondState = _withdrawalState();
        uint256 freshQuote = shares * (secondState.principal + 1) / (secondState.supply + 1000);
        IHousePool.LpEpochSettlementResult memory second = _settleLpEpochForTest();
        assertEq(second.seniorProcessedEpochs, 1);
        assertEq(second.seniorFundedShares, shares);
        assertEq(second.seniorFundedAssets, freshQuote);
        assertFalse(second.seniorBacklog);
        _assertWithdrawal(secondState, second);
    }

    function _giveShares(
        address holder,
        uint256 shares
    ) internal {
        vm.prank(alice);
        seniorVault.transfer(holder, shares);
    }

    function _impairTo(
        uint256 principal
    ) internal {
        _refreshMarkForAsyncSettlement();
        uint256 payout = pool.totalAssets() - principal;
        vm.prank(address(engine));
        pool.payOut(address(0xDEAD), payout);
        vm.prank(address(seniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), principal);
        assertEq(pool.juniorPrincipal(), 0);
        assertGt(pool.seniorHighWaterMark(), principal);
    }

    function _withdrawalState() internal view returns (WithdrawalState memory state) {
        state = WithdrawalState({
            principal: pool.seniorPrincipal(),
            hwm: pool.seniorHighWaterMark(),
            supply: seniorVault.totalSupply(),
            escrow: seniorVault.withdrawalEscrowAssets(),
            unassigned: pool.unassignedAssets()
        });
    }

    function _assertWithdrawal(
        WithdrawalState memory beforeState,
        IHousePool.LpEpochSettlementResult memory result
    ) internal view {
        uint256 principalAfter = beforeState.principal - result.seniorFundedAssets;
        uint256 hwmAfter = pool.seniorHighWaterMark();
        assertEq(pool.seniorPrincipal(), principalAfter);
        assertEq(pool.juniorPrincipal(), 0);
        assertEq(seniorVault.totalSupply(), beforeState.supply - result.seniorFundedShares);
        assertEq(seniorVault.withdrawalEscrowAssets(), beforeState.escrow + result.seniorFundedAssets);
        assertEq(settlementToken.balanceOf(address(seniorVault)), seniorVault.withdrawalEscrowAssets());
        assertEq(pool.unassignedAssets(), beforeState.unassigned, "HWM protection does not move immediate value");
        assertLe(hwmAfter, beforeState.hwm);
        if (result.seniorFundedAssets == 0) {
            assertEq(hwmAfter, beforeState.hwm);
        } else if (principalAfter == 0) {
            assertEq(hwmAfter, 0);
        } else {
            // Independent cross-products bound protection by both remaining principal and remaining ownership.
            assertGe(hwmAfter * beforeState.principal, beforeState.hwm * principalAfter);
            assertGe(hwmAfter * beforeState.supply, beforeState.hwm * (beforeState.supply - result.seniorFundedShares));
        }
    }

}
