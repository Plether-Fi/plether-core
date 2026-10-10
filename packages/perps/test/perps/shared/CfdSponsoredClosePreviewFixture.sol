// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdClosePreviewTestBase} from "../CfdClosePreviewTestBase.sol";
import {CfdClosePreview} from "@plether/perps/CfdClosePreview.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineLens} from "@plether/perps/interfaces/ICfdEngineLens.sol";

contract SponsoredPreviewHarness is CfdClosePreview {

    address private immutable fixtureEngine;

    constructor(
        address engine
    ) CfdClosePreview(engine) {
        fixtureEngine = engine;
    }

    function _sponsoredEngine() internal view override returns (address) {
        return fixtureEngine;
    }

}

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

abstract contract CfdSponsoredClosePreviewTestFixture is CfdClosePreviewTestBase {

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
    ) internal view returns (OrderV3Types.OrderRequest memory r) {
        r.clientOrderId = keccak256("sponsored-close");
        r.side = CfdTypes.Side.LONG;
        r.sizeDelta = size;
        r.targetPrice = type(uint256).max;
        r.isClose = true;
        r.bounds = _bounds();
        r.bounds.allowedExecutionModes = 1;
        r.bounds.submitBy = uint64(vm.getBlockTimestamp() + router.maxExecutionWindowSeconds());
        r.bounds.executionWindowSeconds =
            uint32(uint256(uint64(vm.getBlockTimestamp() + router.maxExecutionWindowSeconds())) - block.timestamp);
        r.bounds.expectedConfigHash = router.lifecycleBook().currentExecutionConfigHash();
    }

    function _fundedPreview(
        OrderV3Types.OrderRequest memory r
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
        OrderV3Types.OrderRequest memory r,
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
        OrderV3Types.OrderRequest memory r = _request(size);
        CfdClosePreview.SponsoredClosePreview memory p = _fundedPreview(r);
        assertEq(p.subsidyUsdc, 200_000 - free);
        _batch(r, p.subsidyUsdc);
        OrderV3Types.ExecutionAssessment memory actual = policyEvaluator.assessOrder(
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

    function _maxOpenThenClose(
        bool isPartial
    ) internal {
        _fundTrader(ACCOUNT, 1000e6);
        // The old Max flow commits all spendable collateral after the opening bounty.
        uint256 margin = 1000e6 - router.maxOpenOrderExecutionBountyUsdc();
        ICfdEngineLens.MaxOpenQuote memory quote =
            engineLens.quoteMaxOpen(ACCOUNT, CfdTypes.Side.LONG, margin, PRICE, uint64(vm.getBlockTimestamp()));
        assertGt(quote.maxSizeDelta, 0);
        vm.prank(ACCOUNT);
        uint64 openId = router.commitOrder(CfdTypes.Side.LONG, quote.maxSizeDelta, margin, PRICE, false);
        bytes[] memory update = _mockPythUpdateData(PRICE);
        vm.prank(KEEPER);
        router.executeOrder(openId, update);
        (uint256 opened,,,,,,) = engine.positions(ACCOUNT);
        assertEq(opened, quote.maxSizeDelta, "maximum position actually opened");
        assertLt(clearinghouse.getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc, 200_000);
        uint256 closeSize = isPartial ? (opened / 2 / CfdTypes.SIZE_QUANTUM) * CfdTypes.SIZE_QUANTUM : opened;
        OrderV3Types.OrderRequest memory r = _request(closeSize);
        uint256 closePrice = isPartial ? PRICE - 1_000_000 : PRICE;
        CfdClosePreview.SponsoredClosePreview memory p = sponsored.previewSponsoredClose(
            address(engine), ACCOUNT, r, KEEPER, closePrice, uint64(vm.getBlockTimestamp())
        );
        _batch(r, p.subsidyUsdc);
        uint64 closeId = router.lifecycleBook().clientIntent(ACCOUNT, r.clientOrderId).orderId;
        update = _mockPythUpdateData(closePrice);
        vm.prank(KEEPER);
        router.executeOrder(closeId, update);
        (uint256 remaining,,,,,,) = engine.positions(ACCOUNT);
        assertEq(remaining, opened - closeSize);
    }

}
