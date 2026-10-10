// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdClosePreview} from "@plether/perps/CfdClosePreview.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";

import {CfdSponsoredClosePreviewTestFixture} from "../shared/CfdSponsoredClosePreviewFixture.sol";

contract CfdSponsoredClosePreviewTest is CfdSponsoredClosePreviewTestFixture {

    function test_MaxOpenThenSponsoredFullClose() public {
        _maxOpenThenClose(false);
    }

    function test_MaxOpenThenSponsoredPartialClose() public {
        _maxOpenThenClose(true);
    }

    function test_FullCloseFromZero() public {
        _parity(SIZE, 0);
    }

    function test_PartialCloseFromZero() public {
        _parity(SIZE / 2, 0);
    }

    function test_ExactShortfall() public {
        _parity(SIZE, 2000);
    }

    function test_OneAtomicUnitShortfall() public {
        _parity(SIZE, 199_999);
    }

    function test_FundedAccountNeedsNoSubsidy() public {
        _openNormally(CfdTypes.Side.LONG, 200_000);
        OrderV3Types.OrderRequest memory r = _request(SIZE);
        assertEq(_fundedPreview(r).subsidyUsdc, 0);
        vm.expectRevert(abi.encodeWithSelector(CfdClosePreview.CfdClosePreview__SubsidyMismatch.selector, 1, 0));
        _batch(r, 1);
    }

    function test_ReplayDoesNotMintTwice() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV3Types.OrderRequest memory r = _request(SIZE);
        _batch(r, 200_000);
        uint256 supply = usdc.totalSupply();
        vm.expectRevert(CfdClosePreview.CfdClosePreview__SponsoredIntentInvalid.selector);
        _batch(r, 200_000);
        assertEq(usdc.totalSupply(), supply);
    }

    function test_MismatchedSubsidyDoesNotMint() public {
        _openNormally(CfdTypes.Side.LONG, 2000);
        OrderV3Types.OrderRequest memory r = _request(SIZE);
        vm.expectRevert(
            abi.encodeWithSelector(CfdClosePreview.CfdClosePreview__SubsidyMismatch.selector, 200_000, 198_000)
        );
        _batch(r, 200_000);
    }

    function test_NoCompetitionExpiry() public {
        vm.warp(1_800_000_000);
        _parity(SIZE, 0);
    }

    function test_WrongChainFails() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV3Types.OrderRequest memory r = _request(SIZE);
        vm.chainId(1);
        vm.expectRevert(CfdClosePreview.CfdClosePreview__SponsoredDeploymentMismatch.selector);
        _fundedPreview(r);
    }

    function test_ExpiredOrderFails() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV3Types.OrderRequest memory r = _request(SIZE);
        r.bounds.submitBy = uint64(vm.getBlockTimestamp() - 1);
        r.bounds.executionWindowSeconds = 1;
        vm.expectRevert(CfdClosePreview.CfdClosePreview__SponsoredIntentInvalid.selector);
        _batch(r, 200_000);
    }

    function test_ChangedConfigurationFails() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV3Types.OrderRequest memory r = _request(SIZE);
        r.bounds.expectedConfigHash = bytes32(uint256(1));
        vm.expectRevert(CfdClosePreview.CfdClosePreview__SponsoredIntentInvalid.selector);
        _batch(r, 200_000);
    }

    function test_CommitFailureRollsBackMintAndDeposit() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV3Types.OrderRequest memory r = _request(SIZE);
        vm.mockCallRevert(
            address(router),
            abi.encodeCall(OrderRouter.commitOrder, (r)),
            abi.encodeWithSignature("Error(string)", "commit failed")
        );
        uint256 supply = usdc.totalSupply();
        uint256 balance = clearinghouse.balanceUsdc(ACCOUNT);
        vm.expectRevert();
        _batch(r, 200_000);
        assertEq(usdc.totalSupply(), supply);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), balance);
        assertEq(router.lifecycleBook().clientIntent(ACCOUNT, r.clientOrderId).orderId, 0);
    }

    function test_PartialCloseFundsChargesFromSafeReleaseOnNewStack() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV3Types.OrderRequest memory r = _request(SIZE / 2);
        CfdClosePreview.SponsoredClosePreview memory preview =
            sponsored.previewSponsoredClose(address(engine), ACCOUNT, r, KEEPER, PRICE, uint64(vm.getBlockTimestamp()));
        assertGt(preview.assessment.close.actionChargeFromReleasedMarginUsdc, 0);
        assertEq(preview.assessment.close.actionChargeWaivedUsdc, 0);
    }

    function test_PendingOrderRejectsBeforeMint() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV3Types.OrderRequest memory r = _request(SIZE);
        vm.mockCall(address(router), abi.encodeWithSignature("pendingOrderCounts(address)", ACCOUNT), abi.encode(1));
        uint256 supply = usdc.totalSupply();
        vm.expectRevert(CfdClosePreview.CfdClosePreview__SponsoredAccountBusy.selector);
        _batch(r, 200_000);
        assertEq(usdc.totalSupply(), supply);
    }

    function test_ActiveProtectionRejectsBeforeMint() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV3Types.OrderRequest memory r = _request(SIZE);
        vm.mockCall(
            address(router.positionProtectionBook()),
            abi.encodeWithSignature("activePositionProtectionId(address)", ACCOUNT),
            abi.encode(uint64(1))
        );
        vm.expectRevert(CfdClosePreview.CfdClosePreview__SponsoredAccountBusy.selector);
        _batch(r, 200_000);
    }

    function test_InvalidPartialDustRejected() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV3Types.OrderRequest memory r = _request(CfdTypes.SIZE_QUANTUM);
        vm.expectRevert();
        _batch(r, 200_000);
    }

}

contract CfdSponsoredCloseCarryTest is CfdSponsoredClosePreviewTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.baseCarryBps = 500;
    }

    function test_DepositCarryIsCollectedExactlyOnce() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        OrderV3Types.OrderRequest memory r = _request(SIZE);
        CfdClosePreview.SponsoredClosePreview memory p = _fundedPreview(r);
        assertGt(p.depositCarryUsdc, 0);
        assertEq(p.commitmentCarryUsdc, 0);
        uint256 beforeBalance = clearinghouse.balanceUsdc(ACCOUNT);
        _batch(r, p.subsidyUsdc);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), beforeBalance + p.subsidyUsdc - p.depositCarryUsdc);
        OrderV3Types.ExecutionAssessment memory actual = policyEvaluator.assessOrder(
            address(engine),
            _order(r.side, SIZE),
            KEEPER,
            PRICE,
            pool.totalAssets(),
            uint64(vm.getBlockTimestamp()),
            r.bounds,
            p.executionBountyUsdc
        );
        assertEq(keccak256(abi.encode(actual)), keccak256(abi.encode(p.assessment)));
    }

    function test_UncoveredCarryCannotConsumeGrant() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        vm.warp(vm.getBlockTimestamp() + 365_000 days);
        OrderV3Types.OrderRequest memory r = _request(SIZE);
        vm.expectPartialRevert(CfdClosePreview.CfdClosePreview__UncoveredCarry.selector);
        _fundedPreview(r);
    }

}
