// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdOrderPolicyEvaluator} from "@plether/perps/CfdOrderPolicyEvaluator.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {ICfdEngineSettlementSidecar} from "@plether/perps/interfaces/ICfdEngineSettlementSidecar.sol";

contract CfdOrderPolicyEvaluatorParityTest is BasePerpTest {

    uint256 private constant PRICE = 1e8;
    uint256 private constant BOUNTY = 250_000;
    address private constant ACCOUNT = address(0xA11CE);
    address private constant EXTERNAL_EXECUTOR = address(0xB0B);

    CfdOrderPolicyEvaluator internal parityEvaluator;

    function setUp() public override {
        super.setUp();
        parityEvaluator = new CfdOrderPolicyEvaluator();
    }

    function test_AssessOpenMatchesDirectSidecarSnapshotPlanAndEvaluation() public {
        _fundTrader(ACCOUNT, 20_000e6);
        CfdTypes.Order memory order = _openOrder();
        uint256 depth = pool.totalAssets();
        uint64 publishTime = uint64(block.timestamp);
        OrderV2Types.ExecutionBounds memory bounds = _permissiveBounds();

        CfdEnginePlanTypes.RawSnapshot memory snapshot = _sidecarSnapshot(ACCOUNT, depth);
        CfdEnginePlanTypes.OpenDelta memory delta = engine.planner().planOpen(snapshot, order, PRICE, publishTime);
        assertTrue(delta.valid);

        OrderV2Types.ExecutionAssessment memory expected = parityEvaluator.evaluateOpen(snapshot, delta, bounds, BOUNTY);
        OrderV2Types.ExecutionAssessment memory actual = parityEvaluator.assessOrder(
            address(engine), order, EXTERNAL_EXECUTOR, PRICE, depth, publishTime, bounds, BOUNTY
        );

        assertEq(keccak256(abi.encode(actual)), keccak256(abi.encode(expected)));
    }

    function test_AssessPartialCloseMatchesDirectSidecarSnapshotPlanAndEvaluation() public {
        _fundTrader(ACCOUNT, 20_000e6);
        _open(ACCOUNT, CfdTypes.Side.BULL, 100_000e18, 10_000e6, PRICE);

        CfdTypes.Order memory order = _partialCloseOrder();
        uint256 depth = pool.totalAssets();
        uint64 publishTime = uint64(block.timestamp);
        OrderV2Types.ExecutionBounds memory bounds = _permissiveBounds();

        CfdEnginePlanTypes.RawSnapshot memory snapshot = _sidecarSnapshot(ACCOUNT, depth);
        CfdEnginePlanTypes.CloseDelta memory delta = engine.planner().planClose(snapshot, order, PRICE, publishTime);
        assertTrue(delta.valid);

        OrderV2Types.ExecutionAssessment memory expected =
            parityEvaluator.evaluateClose(snapshot, delta, bounds, BOUNTY);
        OrderV2Types.ExecutionAssessment memory actual = parityEvaluator.assessOrder(
            address(engine), order, EXTERNAL_EXECUTOR, PRICE, depth, publishTime, bounds, BOUNTY
        );

        assertEq(keccak256(abi.encode(actual)), keccak256(abi.encode(expected)));
    }

    function test_SelfExecutionKeepsGrossBountyDebitButNetsSettlementCredit() public {
        _fundTrader(ACCOUNT, 20_000e6);
        CfdTypes.Order memory order = _openOrder();
        uint256 depth = pool.totalAssets();
        uint64 publishTime = uint64(block.timestamp);
        OrderV2Types.ExecutionBounds memory bounds = _permissiveBounds();

        OrderV2Types.ExecutionAssessment memory externalExecution = parityEvaluator.assessOrder(
            address(engine), order, EXTERNAL_EXECUTOR, PRICE, depth, publishTime, bounds, BOUNTY
        );
        OrderV2Types.ExecutionAssessment memory selfExecution =
            parityEvaluator.assessOrder(address(engine), order, ACCOUNT, PRICE, depth, publishTime, bounds, BOUNTY);

        assertEq(selfExecution.grossAccountDebitUsdc, externalExecution.grossAccountDebitUsdc);
        assertEq(selfExecution.postSettlementBalanceUsdc, externalExecution.postSettlementBalanceUsdc + BOUNTY);
    }

    function _sidecarSnapshot(
        address account,
        uint256 depth
    ) private returns (CfdEnginePlanTypes.RawSnapshot memory snapshot) {
        ICfdEngineSettlementSidecar sidecar = engine.settlementSidecar();
        vm.prank(address(engine));
        snapshot = sidecar.buildRawSnapshot(account, depth);
    }

    function _openOrder() private view returns (CfdTypes.Order memory order) {
        order = CfdTypes.Order({
            account: ACCOUNT,
            sizeDelta: 100_000e18,
            marginDelta: 10_000e6,
            targetPrice: PRICE,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: CfdTypes.Side.BULL,
            isClose: false
        });
    }

    function _partialCloseOrder() private view returns (CfdTypes.Order memory order) {
        order = CfdTypes.Order({
            account: ACCOUNT,
            sizeDelta: 50_000e18,
            marginDelta: 0,
            targetPrice: PRICE,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: CfdTypes.Side.BULL,
            isClose: true
        });
    }

    function _permissiveBounds() private pure returns (OrderV2Types.ExecutionBounds memory bounds) {
        bounds.allowedExecutionModes = 7;
        bounds.maxExecutionBountyUsdc = type(uint256).max;
        bounds.maxExecutionNotionalUsdc = type(uint256).max;
        bounds.maxGrossAccountDebitUsdc = type(uint256).max;
        bounds.maxActionChargeUsdc = type(uint256).max;
        bounds.maxExplicitFeesUsdc = type(uint256).max;
        bounds.maxPostPositionSize = type(uint256).max;
        bounds.maxPostLeverageBps = type(uint32).max;
    }

}
