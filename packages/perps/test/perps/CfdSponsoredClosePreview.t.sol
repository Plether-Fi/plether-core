// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdClosePreviewTestBase} from "./CfdClosePreview.t.sol";
import {CfdClosePreview} from "@plether/perps/CfdClosePreview.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";

contract SponsoredPreviewHarness is CfdClosePreview {

    address private immutable fixtureEngine;

    constructor(
        address engine
    ) {
        fixtureEngine = engine;
    }

    function _sponsoredEngine() internal view override returns (address) {
        return fixtureEngine;
    }

}

/// @dev Reverting account batch fixture; fork coverage separately checks the deployed SimpleAccount profile.
contract SponsoredBatchAccount {

    address private immutable owner = msg.sender;

    function executeBatch(
        address[] calldata targets,
        bytes[] calldata calls
    ) external {
        require(msg.sender == owner);
        for (uint256 i; i < targets.length; ++i) {
            (bool ok, bytes memory result) = targets[i].call(calls[i]);
            if (!ok) {
                assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
            }
        }
    }

}

contract CfdSponsoredClosePreviewTest is CfdClosePreviewTestBase {

    SponsoredPreviewHarness internal sponsored;

    function setUp() public virtual override {
        vm.chainId(421_614);
        super.setUp();
        sponsored = new SponsoredPreviewHarness(address(engine));
        SponsoredBatchAccount account = new SponsoredBatchAccount();
        vm.etch(ACCOUNT, address(account).code);
    }

    function _request(
        uint256 size
    ) internal view returns (OrderV2Types.OrderRequest memory r) {
        r.clientOrderId = keccak256("sponsored-close");
        r.side = CfdTypes.Side.LONG;
        r.sizeDelta = size;
        r.targetPrice = type(uint256).max;
        r.isClose = true;
        r.bounds = _bounds();
        r.bounds.allowedExecutionModes = 1;
        r.bounds.validUntil = uint64(vm.getBlockTimestamp() + router.maxOrderAge());
        r.bounds.expectedConfigHash = router.lifecycleBook().currentExecutionConfigHash();
    }

    function _fundedPreview(
        OrderV2Types.OrderRequest memory r
    ) internal view returns (CfdClosePreview.SponsoredClosePreview memory) {
        return sponsored.previewSponsoredClose(
            address(engine),
            ACCOUNT,
            r,
            KEEPER,
            r.sizeDelta == SIZE ? PRICE : PRICE - 1_000_000,
            uint64(vm.getBlockTimestamp())
        );
    }

    function _batch(
        OrderV2Types.OrderRequest memory r,
        uint256 amount
    ) internal {
        address[] memory targets = new address[](5);
        bytes[] memory calls = new bytes[](5);
        targets[0] = address(sponsored);
        calls[0] = abi.encodeCall(CfdClosePreview.validateSponsoredClose, (address(engine), r, amount));
        targets[1] = address(usdc);
        calls[1] = abi.encodeWithSignature("mint(address,uint256)", ACCOUNT, amount);
        targets[2] = address(usdc);
        calls[2] = abi.encodeWithSignature("approve(address,uint256)", address(clearinghouse), amount);
        targets[3] = address(clearinghouse);
        calls[3] = abi.encodeWithSignature("depositMargin(uint256)", amount);
        targets[4] = address(router);
        calls[4] = abi.encodeCall(OrderRouter.commitOrder, (r));
        SponsoredBatchAccount(ACCOUNT).executeBatch(targets, calls);
    }

    function _parity(
        uint256 size,
        uint256 free
    ) internal {
        _openNormally(CfdTypes.Side.LONG, free);
        OrderV2Types.OrderRequest memory r = _request(size);
        CfdClosePreview.SponsoredClosePreview memory p = _fundedPreview(r);
        assertEq(p.subsidyUsdc, 200_000 - free);
        _batch(r, p.subsidyUsdc);
        OrderV2Types.ExecutionAssessment memory actual = policyEvaluator.assessOrder(
            address(engine),
            _order(r.side, size),
            KEEPER,
            size == SIZE ? PRICE : PRICE - 1_000_000,
            pool.totalAssets(),
            uint64(vm.getBlockTimestamp()),
            r.bounds,
            p.executionBountyUsdc
        );
        assertEq(keccak256(abi.encode(actual)), keccak256(abi.encode(p.assessment)));
        assertEq(usdc.allowance(ACCOUNT, address(clearinghouse)), 0);
        uint64 id = router.lifecycleBook().clientIntent(ACCOUNT, r.clientOrderId).orderId;
        bytes[] memory update = _mockPythUpdateData(size == SIZE ? PRICE : PRICE - 1_000_000);
        vm.prank(KEEPER);
        router.executeOrder(id, update);
        (uint256 remaining,,,,,,) = engine.positions(ACCOUNT);
        assertEq(remaining, SIZE - size);
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
        OrderV2Types.OrderRequest memory r = _request(SIZE);
        assertEq(_fundedPreview(r).subsidyUsdc, 0);
        vm.expectRevert(abi.encodeWithSelector(CfdClosePreview.CfdClosePreview__SubsidyMismatch.selector, 1, 0));
        _batch(r, 1);
    }

    function test_ReplayDoesNotMintTwice() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV2Types.OrderRequest memory r = _request(SIZE);
        _batch(r, 200_000);
        uint256 supply = usdc.totalSupply();
        vm.expectRevert(CfdClosePreview.CfdClosePreview__SponsoredIntentInvalid.selector);
        _batch(r, 200_000);
        assertEq(usdc.totalSupply(), supply);
    }

    function test_MismatchedSubsidyDoesNotMint() public {
        _openNormally(CfdTypes.Side.LONG, 2000);
        OrderV2Types.OrderRequest memory r = _request(SIZE);
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
        OrderV2Types.OrderRequest memory r = _request(SIZE);
        vm.chainId(1);
        vm.expectRevert(CfdClosePreview.CfdClosePreview__SponsoredDeploymentMismatch.selector);
        _fundedPreview(r);
    }

    function test_ExpiredOrderFails() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV2Types.OrderRequest memory r = _request(SIZE);
        r.bounds.validUntil = uint64(vm.getBlockTimestamp() - 1);
        vm.expectRevert(CfdClosePreview.CfdClosePreview__SponsoredIntentInvalid.selector);
        _batch(r, 200_000);
    }

    function test_ChangedConfigurationFails() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV2Types.OrderRequest memory r = _request(SIZE);
        r.bounds.expectedConfigHash = bytes32(uint256(1));
        vm.expectRevert(CfdClosePreview.CfdClosePreview__SponsoredIntentInvalid.selector);
        _batch(r, 200_000);
    }

    function test_CommitFailureRollsBackMintAndDeposit() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV2Types.OrderRequest memory r = _request(SIZE);
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

    function test_PartialCloseDoesNotWaiveUnfundedTradingCharges() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV2Types.OrderRequest memory r = _request(SIZE / 2);
        vm.expectRevert();
        sponsored.previewSponsoredClose(address(engine), ACCOUNT, r, KEEPER, PRICE, uint64(vm.getBlockTimestamp()));
    }

    function test_PendingOrderRejectsBeforeMint() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV2Types.OrderRequest memory r = _request(SIZE);
        vm.mockCall(address(router), abi.encodeWithSignature("pendingOrderCounts(address)", ACCOUNT), abi.encode(1));
        uint256 supply = usdc.totalSupply();
        vm.expectRevert(CfdClosePreview.CfdClosePreview__SponsoredAccountBusy.selector);
        _batch(r, 200_000);
        assertEq(usdc.totalSupply(), supply);
    }

    function test_ActiveProtectionRejectsBeforeMint() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV2Types.OrderRequest memory r = _request(SIZE);
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
        OrderV2Types.OrderRequest memory r = _request(CfdTypes.SIZE_QUANTUM);
        vm.expectRevert();
        _batch(r, 200_000);
    }

    function testProductionRuntimeFitsEip170() public view {
        assertLe(address(previewer).code.length, 24_576);
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
        OrderV2Types.OrderRequest memory r = _request(SIZE);
        CfdClosePreview.SponsoredClosePreview memory p = _fundedPreview(r);
        assertGt(p.depositCarryUsdc, 0);
        assertEq(p.commitmentCarryUsdc, 0);
        uint256 beforeBalance = clearinghouse.balanceUsdc(ACCOUNT);
        _batch(r, p.subsidyUsdc);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), beforeBalance + p.subsidyUsdc - p.depositCarryUsdc);
        OrderV2Types.ExecutionAssessment memory actual = policyEvaluator.assessOrder(
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
        OrderV2Types.OrderRequest memory r = _request(SIZE);
        vm.expectPartialRevert(CfdClosePreview.CfdClosePreview__UncoveredCarry.selector);
        _fundedPreview(r);
    }

}
