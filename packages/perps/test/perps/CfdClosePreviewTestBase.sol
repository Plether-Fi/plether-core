// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdClosePreview} from "@plether/perps/CfdClosePreview.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {Vm} from "forge-std/Vm.sol";

abstract contract CfdClosePreviewTestBase is BasePerpTest {

    address internal constant ACCOUNT = address(0xA11CE);
    address internal constant KEEPER = address(0xB0B);
    uint256 internal constant SIZE = 10_000e18;
    uint256 internal constant PRICE = 1e8;
    CfdClosePreview internal previewer;

    function setUp() public virtual override {
        super.setUp();
        previewer = new CfdClosePreview(address(engine));
    }

    function _riskParams() internal pure virtual override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.baseCarryBps = 0;
    }

    function _bounds() internal pure returns (OrderV3Types.ExecutionBounds memory b) {
        b.allowedExecutionModes = 7;
        b.maxExecutionBountyUsdc = type(uint256).max;
        b.maxExecutionNotionalUsdc = type(uint256).max;
        b.maxGrossAccountDebitUsdc = type(uint256).max;
        b.maxActionChargeUsdc = type(uint256).max;
        b.maxExplicitFeesUsdc = type(uint256).max;
        b.maxPostPositionSize = type(uint256).max;
        b.maxPostLeverageBps = type(uint32).max;
    }

    function _order(
        CfdTypes.Side side,
        uint256 size
    ) internal view returns (CfdTypes.Order memory o) {
        o = CfdTypes.Order(
            ACCOUNT,
            size,
            0,
            side == CfdTypes.Side.LONG ? type(uint256).max : 1,
            uint64(vm.getBlockTimestamp()),
            uint64(vm.getBlockNumber()),
            0,
            side,
            true
        );
    }

    function _openNormally(
        CfdTypes.Side side,
        uint256 freeAfter
    ) internal {
        _fundTrader(ACCOUNT, 1000e6);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(side, SIZE, 250e6, PRICE, false);
        bytes[] memory update = _mockPythUpdateData(PRICE);
        vm.prank(KEEPER);
        router.executeOrder(id, update);
        (uint256 size,,,,,,) = engine.positions(ACCOUNT);
        assertEq(size, SIZE, "normal router opening succeeds");
        uint256 free = clearinghouse.getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc;
        vm.prank(ACCOUNT);
        clearinghouse.withdraw(ACCOUNT, free - freeAfter);
    }

    function _preview(
        CfdTypes.Order memory o,
        uint256 price,
        address executor
    ) internal view returns (CfdClosePreview.ClosePreview memory) {
        // The optimizer can cache block.timestamp across the fixture's vm.warp calls.
        return previewer.previewClose(address(engine), o, executor, price, uint64(vm.getBlockTimestamp()), _bounds());
    }

    function _commitParity(
        CfdTypes.Order memory o,
        uint256 price,
        address executor
    ) internal returns (uint64 id, CfdClosePreview.ClosePreview memory p) {
        bytes32 bucketsBefore = keccak256(
            abi.encode(
                clearinghouse.getAccountUsdcBuckets(ACCOUNT),
                clearinghouse.getLockedMarginBuckets(ACCOUNT),
                clearinghouse.totalBountyReservationsUsdc(ACCOUNT)
            )
        );
        uint256 settlementBefore = clearinghouse.balanceUsdc(ACCOUNT);
        p = _preview(o, price, executor);
        assertEq(
            bucketsBefore,
            keccak256(
                abi.encode(
                    clearinghouse.getAccountUsdcBuckets(ACCOUNT),
                    clearinghouse.getLockedMarginBuckets(ACCOUNT),
                    clearinghouse.totalBountyReservationsUsdc(ACCOUNT)
                )
            ),
            "preview is read-only"
        );
        vm.prank(ACCOUNT);
        id = router.commitOrder(o.side, o.sizeDelta, 0, o.targetPrice, true);
        assertEq(settlementBefore - clearinghouse.balanceUsdc(ACCOUNT), p.commitmentCarryUsdc);
        OrderV3Types.ExecutionAssessment memory actual = policyEvaluator.assessOrder(
            address(engine),
            o,
            executor,
            price,
            pool.totalAssets(),
            uint64(vm.getBlockTimestamp()),
            _bounds(),
            p.executionBountyUsdc
        );
        assertEq(
            keccak256(abi.encode(p.assessment)), keccak256(abi.encode(actual)), "preview equals committed assessment"
        );
    }

    function _assertReceipt(
        Vm.Log[] memory logs,
        uint64 id,
        OrderV3Types.ExecutionAssessment memory predicted
    ) internal {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(router.lifecycleBook()) && logs[i].topics.length == 4
                    && uint64(uint256(logs[i].topics[1])) == id
            ) {
                (,,, OrderV3Types.OrderReceipt memory receipt) =
                    abi.decode(logs[i].data, (bytes32, uint64, uint64, OrderV3Types.OrderReceipt));
                assertEq(receipt.economics.postSettlementBalanceUsdc, clearinghouse.balanceUsdc(ACCOUNT));
                assertEq(receipt.economics.grossAccountDebitUsdc, predicted.grossAccountDebitUsdc);
                assertEq(receipt.economics.actionChargeCollectedUsdc, predicted.actionChargeCollectedUsdc);
                assertEq(receipt.economics.postTraderClaimBalanceUsdc, predicted.postTraderClaimUsdc);
                return;
            }
        }
        fail("missing terminal receipt");
    }

    function _lifecycle(
        CfdTypes.Side side,
        uint256 size,
        uint256 price,
        bool self
    ) internal {
        _openNormally(side, size == SIZE ? 200_000 : 20e6);
        CfdTypes.Order memory o = _order(side, size);
        address executor = self ? ACCOUNT : KEEPER;
        (uint64 id, CfdClosePreview.ClosePreview memory p) = _commitParity(o, price, executor);
        uint256 keeperBefore = clearinghouse.balanceUsdc(KEEPER);
        bytes[] memory update = _mockPythUpdateData(price);
        vm.recordLogs();
        vm.prank(executor);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(id, update);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        _assertReceipt(vm.getRecordedLogs(), id, p.assessment);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), p.assessment.postSettlementBalanceUsdc);
        assertEq(engine.traderClaimBalanceUsdc(ACCOUNT), p.assessment.postTraderClaimUsdc);
        (uint256 actualSize,,,,,,) = engine.positions(ACCOUNT);
        assertEq(actualSize, p.assessment.postPositionSize);
        assertEq(clearinghouse.pnlPledgeUsdc(ACCOUNT), p.assessment.postPositionMarginUsdc);
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 0);
        if (!self) {
            assertEq(clearinghouse.balanceUsdc(KEEPER) - keeperBefore, p.executionBountyUsdc);
        }
    }

}

