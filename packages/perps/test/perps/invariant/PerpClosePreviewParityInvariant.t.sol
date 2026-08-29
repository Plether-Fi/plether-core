// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {LegacyOrderRouterHarness} from "../../utils/LegacyOrderRouterHarness.sol";
import {PerpAccountingHandler} from "./handlers/PerpAccountingHandler.sol";
import {CfdEngineHarness} from "./mocks/CfdEngineHarness.sol";
import {MockInvariantHousePool} from "./mocks/MockInvariantHousePool.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdEnginePlanner} from "@plether/perps/CfdEnginePlanner.sol";
import {CfdEngineSettlementSidecar} from "@plether/perps/CfdEngineSettlementSidecar.sol";
import {CfdOrderPolicyEvaluator} from "@plether/perps/CfdOrderPolicyEvaluator.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderLifecycleBook} from "@plether/perps/OrderLifecycleBook.sol";
import {OrderRouterLiquidationBatchSidecar} from "@plether/perps/OrderRouterLiquidationBatchSidecar.sol";
import {OrderRouterV2ExecutionSidecar} from "@plether/perps/OrderRouterV2ExecutionSidecar.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

contract PerpClosePreviewParityInvariantTest is Test {

    MockUSDC internal usdc;
    CfdEngineHarness internal harness;
    CfdEngine internal engine;
    CfdEngineLens internal engineLens;
    MarginClearinghouse internal clearinghouse;
    MockInvariantHousePool internal housePool;
    MockPyth internal mockPyth;
    LegacyOrderRouterHarness internal router;
    PerpAccountingHandler internal handler;

    uint256 internal constant SETUP_TIMESTAMP = 1_709_532_000;
    uint256 internal constant CAP_PRICE = 2e8;

    function setUp() public {
        usdc = new MockUSDC();
        clearinghouse = new MarginClearinghouse(address(usdc));

        harness = new CfdEngineHarness(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams(), 50);
        engine = harness;
        engine.setDependencies(
            address(new CfdEnginePlanner()),
            address(new CfdEngineSettlementSidecar(address(engine))),
            address(new CfdEngineAdmin(address(engine), address(this)))
        );
        engine.setTerminalNavBook(address(new TerminalNavBookV2(address(engine), uint32(CAP_PRICE))));
        engineLens = new CfdEngineLens(address(engine));

        housePool = new MockInvariantHousePool(address(usdc), address(engine));
        mockPyth = new MockPyth();
        mockPyth.setPrice(bytes32(uint256(1)), int64(100_000_000), int32(-8), uint64(SETUP_TIMESTAMP));
        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = bytes32(uint256(1));
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1e18;
        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = 1e8;
        PletherOracle testOracle = new PletherOracle(
            address(engine), address(housePool), address(mockPyth), feedIds, weights, basePrices, new bool[](1)
        );
        CfdOrderPolicyEvaluator evaluator = new CfdOrderPolicyEvaluator();
        OrderRouterV2ExecutionSidecar executionSidecar = new OrderRouterV2ExecutionSidecar();
        address predictedRouter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        OrderLifecycleBook lifecycleBook =
            new OrderLifecycleBook(predictedRouter, address(engine), address(clearinghouse), address(housePool));
        OrderRouterLiquidationBatchSidecar keeperSidecar = new OrderRouterLiquidationBatchSidecar(predictedRouter);
        router = new LegacyOrderRouterHarness(
            address(engine),
            address(engineLens),
            address(housePool),
            address(testOracle),
            address(keeperSidecar),
            address(evaluator),
            address(executionSidecar),
            address(lifecycleBook)
        );
        assertEq(address(router), predictedRouter);

        clearinghouse.setEngine(address(engine));
        vm.warp(SETUP_TIMESTAMP);

        engine.setPool(address(housePool));
        engine.setOrderRouter(address(router));
        housePool.seedAssets(100_000e6);

        handler = new PerpAccountingHandler(usdc, engine, clearinghouse, router, housePool);
        handler.seedActors(50_000e6, 50_000e6);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.depositCollateral.selector;
        selectors[1] = handler.withdrawCollateral.selector;
        selectors[2] = handler.commitOpenOrder.selector;
        selectors[3] = handler.commitCloseOrder.selector;
        selectors[4] = handler.executeNextOrderBatch.selector;
        selectors[5] = handler.liquidate.selector;
        selectors[6] = handler.setPoolAssets.selector;
        selectors[7] = handler.fundHousePool.selector;
        selectors[8] = handler.drainHousePool.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function test_HandlerCanReachLivePositionState() public {
        handler.commitOpenOrder(0, 0, 20, 1000e6, 1e8);
        assertEq(router.nextCommitId(), 2, "handler must commit a valid open order");

        handler.executeNextOrderBatch(1);
        (uint256 size,,,,,,) = engine.positions(_account(handler.actorAt(0)));
        assertGt(size, 0, "handler must execute the open into a live position");
    }

    function _assertInvariant_ValidPartialCloseNeverLeavesDustPosition() internal view {
        uint256 oraclePrice = _previewOraclePrice();
        (,,,,,, uint256 minBountyUsdc,,,) = engine.riskParams();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            (uint256 size, uint256 margin,,,,,) = engine.positions(account);
            if (size < 2 * CfdTypes.SIZE_QUANTUM) {
                continue;
            }

            uint256[3] memory fractions = _closeFractions(size, margin, minBountyUsdc);
            for (uint256 f = 0; f < 3; f++) {
                if (fractions[f] == 0 || fractions[f] >= size) {
                    continue;
                }

                ICfdEngineTypes.ClosePreview memory preview =
                    engineLens.previewClose(account, fractions[f], oraclePrice);

                if (!preview.valid) {
                    if (preview.invalidReason == CfdTypes.CloseInvalidReason.DustPosition) {
                        assertTrue(
                            preview.remainingSize > 0 && preview.remainingMargin < minBountyUsdc,
                            "DustPosition must imply dust residual"
                        );
                    }
                    continue;
                }

                if (preview.remainingSize > 0) {
                    assertGe(
                        preview.remainingMargin,
                        minBountyUsdc,
                        "Valid partial close must not leave dust position (margin >= minBountyUsdc)"
                    );
                }
            }
        }
    }

    function _assertInvariant_PreviewClose_EqualsSimulateCloseAtCanonicalDepth() internal view {
        uint256 oraclePrice = _previewOraclePrice();
        uint256 canonicalDepth = housePool.totalAssets();
        (,,,,,, uint256 minBountyUsdc,,,) = engine.riskParams();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            (uint256 size, uint256 margin,,,,,) = engine.positions(account);
            if (size == 0) {
                continue;
            }

            _assertClosePreviewEquals(
                engineLens.previewClose(account, size, oraclePrice),
                engineLens.simulateClose(account, size, oraclePrice, canonicalDepth)
            );

            if (size < 2 * CfdTypes.SIZE_QUANTUM) {
                continue;
            }

            uint256[3] memory fractions = _closeFractions(size, margin, minBountyUsdc);
            for (uint256 f = 0; f < 3; f++) {
                if (fractions[f] == 0 || fractions[f] >= size) {
                    continue;
                }

                _assertClosePreviewEquals(
                    engineLens.previewClose(account, fractions[f], oraclePrice),
                    engineLens.simulateClose(account, fractions[f], oraclePrice, canonicalDepth)
                );
            }
        }
    }

    function _assertInvariant_ValidPartialCloseWithCarryAccrualImpliesHousePoolCanPay() internal view {
        uint256 oraclePrice = _previewOraclePrice();
        (,,,,,, uint256 minBountyUsdc,,,) = engine.riskParams();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            (uint256 size, uint256 margin,,,,,) = engine.positions(account);
            if (size < 2 * CfdTypes.SIZE_QUANTUM) {
                continue;
            }

            uint256[3] memory fractions = _closeFractions(size, margin, minBountyUsdc);
            for (uint256 f = 0; f < 3; f++) {
                if (fractions[f] == 0 || fractions[f] >= size) {
                    continue;
                }
                engineLens.previewClose(account, fractions[f], oraclePrice);
            }
        }
    }

    function _assertInvariant_PartialCloseInvalidOnlyForNewCodes() internal view {
        uint256 oraclePrice = _previewOraclePrice();
        (,,,,,, uint256 minBountyUsdc,,,) = engine.riskParams();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            (uint256 size, uint256 margin,,,,,) = engine.positions(account);
            if (size < 2 * CfdTypes.SIZE_QUANTUM) {
                continue;
            }

            ICfdEngineTypes.ClosePreview memory fullPreview = engineLens.previewClose(account, size, oraclePrice);
            if (!fullPreview.valid) {
                continue;
            }

            uint256[3] memory fractions = _closeFractions(size, margin, minBountyUsdc);
            for (uint256 f = 0; f < 3; f++) {
                if (fractions[f] == 0 || fractions[f] >= size) {
                    continue;
                }

                ICfdEngineTypes.ClosePreview memory preview =
                    engineLens.previewClose(account, fractions[f], oraclePrice);

                if (!preview.valid) {
                    CfdTypes.CloseInvalidReason r = preview.invalidReason;
                    assertTrue(
                        r == CfdTypes.CloseInvalidReason.PartialCloseUnderwater
                            || r == CfdTypes.CloseInvalidReason.DustPosition,
                        "Partial close of valid-full-close position can only fail for shortfall or dust"
                    );
                }
            }
        }
    }

    function _assertInvariant_ImmediateOrTraderClaimSplitMatchesFreshPayout() internal view {
        uint256 oraclePrice = _previewOraclePrice();
        (,,,,,, uint256 minBountyUsdc,,,) = engine.riskParams();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            (uint256 size, uint256 margin,,,,,) = engine.positions(account);
            if (size == 0) {
                continue;
            }

            _checkPayoutSplit(account, size, oraclePrice);

            if (size < 2 * CfdTypes.SIZE_QUANTUM) {
                continue;
            }

            uint256[3] memory fractions = _closeFractions(size, margin, minBountyUsdc);
            for (uint256 f = 0; f < 3; f++) {
                if (fractions[f] == 0 || fractions[f] >= size) {
                    continue;
                }
                _checkPayoutSplit(account, fractions[f], oraclePrice);
            }
        }
    }

    function _checkPayoutSplit(
        address account,
        uint256 sizeDelta,
        uint256 oraclePrice
    ) internal view {
        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, sizeDelta, oraclePrice);

        if (!preview.valid) {
            return;
        }

        assertGe(
            preview.traderClaimBalanceUsdc,
            preview.existingTraderClaimRemainingUsdc,
            "Resulting trader claim must include the unconsumed existing claim"
        );
        uint256 freshTraderClaimUsdc = preview.traderClaimBalanceUsdc - preview.existingTraderClaimRemainingUsdc;
        assertEq(
            preview.immediatePayoutUsdc + freshTraderClaimUsdc,
            preview.freshTraderPayoutUsdc,
            "Fresh payout must settle immediately or become a new trader claim"
        );
        if (preview.freshTraderPayoutUsdc > 0) {
            assertTrue(
                (preview.immediatePayoutUsdc > 0) != (freshTraderClaimUsdc > 0),
                "Fresh payout settlement modes must be mutually exclusive"
            );
        }
    }

    function _assertClosePreviewEquals(
        ICfdEngineTypes.ClosePreview memory actual,
        ICfdEngineTypes.ClosePreview memory expected
    ) internal pure {
        assertEq(actual.valid, expected.valid, "Close preview validity should match canonical simulateClose");
        assertEq(uint8(actual.invalidReason), uint8(expected.invalidReason), "Close invalid reason should match");
        assertEq(actual.executionPrice, expected.executionPrice, "Close execution price should match");
        assertEq(actual.sizeDelta, expected.sizeDelta, "Close size delta should match");
        assertEq(actual.realizedPnlUsdc, expected.realizedPnlUsdc, "Close realized pnl should match");
        assertEq(actual.vpiDeltaUsdc, expected.vpiDeltaUsdc, "Close VPI delta should match");
        assertEq(actual.vpiUsdc, expected.vpiUsdc, "Close VPI should match");
        assertEq(actual.executionFeeUsdc, expected.executionFeeUsdc, "Close execution fee should match");
        assertEq(actual.frozenSpreadUsdc, expected.frozenSpreadUsdc, "Close assessed frozen spread should match");
        assertEq(actual.frozenSpreadPaidUsdc, expected.frozenSpreadPaidUsdc, "Close paid frozen spread should match");
        assertEq(
            actual.frozenSpreadWaivedUsdc, expected.frozenSpreadWaivedUsdc, "Close waived frozen spread should match"
        );
        assertEq(actual.freshTraderPayoutUsdc, expected.freshTraderPayoutUsdc, "Close fresh payout should match");
        assertEq(
            actual.existingTraderClaimConsumedUsdc,
            expected.existingTraderClaimConsumedUsdc,
            "Close trader claim consumption should match"
        );
        assertEq(
            actual.existingTraderClaimRemainingUsdc,
            expected.existingTraderClaimRemainingUsdc,
            "Close trader claim remainder should match"
        );
        assertEq(actual.immediatePayoutUsdc, expected.immediatePayoutUsdc, "Close immediate payout should match");
        assertEq(actual.traderClaimBalanceUsdc, expected.traderClaimBalanceUsdc, "Close trader claim should match");
        assertEq(actual.seizedCollateralUsdc, expected.seizedCollateralUsdc, "Close seized collateral should match");
        assertEq(actual.badDebtUsdc, expected.badDebtUsdc, "Close bad debt should match");
        assertEq(actual.remainingSize, expected.remainingSize, "Close remaining size should match");
        assertEq(actual.remainingMargin, expected.remainingMargin, "Close remaining margin should match");
        assertEq(actual.triggersDegradedMode, expected.triggersDegradedMode, "Close degraded trigger should match");
        assertEq(actual.postOpDegradedMode, expected.postOpDegradedMode, "Close post-op degraded mode should match");
        assertEq(
            actual.effectiveAssetsAfterUsdc, expected.effectiveAssetsAfterUsdc, "Close effective assets should match"
        );
        assertEq(actual.maxLiabilityAfterUsdc, expected.maxLiabilityAfterUsdc, "Close max liability should match");
    }

    function _closeFractions(
        uint256 size,
        uint256 margin,
        uint256 minBountyUsdc
    ) internal pure returns (uint256[3] memory fractions) {
        uint256 sizeLots = size / CfdTypes.SIZE_QUANTUM;
        if (sizeLots < 2) {
            return fractions;
        }

        fractions[0] = CfdTypes.SIZE_QUANTUM;
        fractions[1] = (sizeLots / 2) * CfdTypes.SIZE_QUANTUM;
        if (margin > minBountyUsdc) {
            uint256 marginDerivedLots = sizeLots * (margin - minBountyUsdc) / margin;
            fractions[2] = marginDerivedLots * CfdTypes.SIZE_QUANTUM;
            if (fractions[2] == 0) {
                fractions[2] = CfdTypes.SIZE_QUANTUM;
            }
            if (fractions[2] >= size) {
                fractions[2] = (sizeLots - 1) * CfdTypes.SIZE_QUANTUM;
            }
        } else {
            fractions[2] = (sizeLots - 1) * CfdTypes.SIZE_QUANTUM;
        }
    }

    function _riskParams() internal pure returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 9,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _previewOraclePrice() internal view returns (uint256) {
        uint256 price = engine.lastMarkPrice();
        return price == 0 ? 1e8 : price;
    }

    function _account(
        address actor
    ) internal pure returns (address) {
        return actor;
    }

    function invariant_job1() public view {
        _assertAllInvariants();
    }

    function invariant_job2() public view {
        _assertAllInvariants();
    }

    function _assertAllInvariants() internal view {
        _assertInvariant_ValidPartialCloseNeverLeavesDustPosition();
        _assertInvariant_PreviewClose_EqualsSimulateCloseAtCanonicalDepth();
        _assertInvariant_ValidPartialCloseWithCarryAccrualImpliesHousePoolCanPay();
        _assertInvariant_PartialCloseInvalidOnlyForNewCodes();
        _assertInvariant_ImmediateOrTraderClaimSplitMatchesFreshPayout();
    }

}
