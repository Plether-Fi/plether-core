// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {PerpAccountingHandler} from "./handlers/PerpAccountingHandler.sol";
import {CfdEngineHarness} from "./mocks/CfdEngineHarness.sol";
import {MockInvariantHousePool} from "./mocks/MockInvariantHousePool.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
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
    OrderRouter internal router;
    PerpAccountingHandler internal handler;

    uint256 internal constant SETUP_TIMESTAMP = 1_709_532_000;
    uint256 internal constant CAP_PRICE = 2e8;

    function setUp() public {
        usdc = new MockUSDC();
        clearinghouse = new MarginClearinghouse(address(usdc));

        harness = new CfdEngineHarness(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams(), 0.005e18);
        engine = harness;
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
        router = new OrderRouter(
            address(engine),
            address(engineLens),
            address(housePool),
            address(
                new PletherOracle(
                    address(engine), address(housePool), address(mockPyth), feedIds, weights, basePrices, new bool[](1)
                )
            )
        );

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

    function invariant_ValidPartialCloseNeverLeavesDustPosition() public view {
        uint256 oraclePrice = _previewOraclePrice();
        (,,,,,, uint256 minBountyUsdc,) = engine.riskParams();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            (uint256 size, uint256 margin,,,,,) = engine.positions(account);
            if (size < 2) {
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

    function invariant_PreviewClose_EqualsSimulateCloseAtCanonicalDepth() public view {
        uint256 oraclePrice = _previewOraclePrice();
        uint256 canonicalDepth = housePool.totalAssets();
        (,,,,,, uint256 minBountyUsdc,) = engine.riskParams();

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

            if (size < 2) {
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

    function invariant_ValidPartialCloseWithCarryAccrualImpliesHousePoolCanPay() public view {
        uint256 oraclePrice = _previewOraclePrice();
        (,,,,,, uint256 minBountyUsdc,) = engine.riskParams();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            (uint256 size, uint256 margin,,,,,) = engine.positions(account);
            if (size < 2) {
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

    function invariant_PartialCloseInvalidOnlyForNewCodes() public view {
        uint256 oraclePrice = _previewOraclePrice();
        (,,,,,, uint256 minBountyUsdc,) = engine.riskParams();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            (uint256 size, uint256 margin,,,,,) = engine.positions(account);
            if (size < 2) {
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

    function invariant_ImmediateOrTraderClaimSplitMatchesAdjustedCash() public view {
        uint256 oraclePrice = _previewOraclePrice();
        uint256 poolDepthUsdc = housePool.totalAssets();
        (,,,,,, uint256 minBountyUsdc,) = engine.riskParams();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = _account(handler.actorAt(i));
            (uint256 size, uint256 margin,,,,,) = engine.positions(account);
            if (size == 0) {
                continue;
            }

            _checkPayoutSplit(account, size, oraclePrice, poolDepthUsdc, true);

            if (size < 2) {
                continue;
            }

            uint256[3] memory fractions = _closeFractions(size, margin, minBountyUsdc);
            for (uint256 f = 0; f < 3; f++) {
                if (fractions[f] == 0 || fractions[f] >= size) {
                    continue;
                }
                _checkPayoutSplit(account, fractions[f], oraclePrice, poolDepthUsdc, false);
            }
        }
    }

    function _checkPayoutSplit(
        address account,
        uint256 sizeDelta,
        uint256 oraclePrice,
        uint256 poolDepthUsdc,
        bool isFullClose
    ) internal view {
        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, sizeDelta, oraclePrice);

        if (!preview.valid || (preview.immediatePayoutUsdc == 0 && preview.traderClaimBalanceUsdc == 0)) {
            return;
        }

        uint256 adjustedCash = housePool.totalAssets();
        uint256 totalOwed = preview.immediatePayoutUsdc + preview.traderClaimBalanceUsdc;

        if (preview.immediatePayoutUsdc > 0) {
            assertGe(adjustedCash, preview.immediatePayoutUsdc, "Post-carry HousePool cash must cover immediate payout");
            assertEq(preview.traderClaimBalanceUsdc, 0, "Immediate payout excludes trader claim");
        }

        if (preview.traderClaimBalanceUsdc > 0) {
            assertEq(preview.immediatePayoutUsdc, 0, "Trader claim excludes immediate payout");
            assertLt(adjustedCash, totalOwed, "Trader claim implies adjusted cash insufficient for full settlement");
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
        fractions[0] = 1;
        fractions[1] = size / 2;
        if (margin > minBountyUsdc && size > 1) {
            fractions[2] = size * (margin - minBountyUsdc) / margin;
            if (fractions[2] == 0) {
                fractions[2] = 1;
            }
            if (fractions[2] >= size) {
                fractions[2] = size - 1;
            }
        } else {
            fractions[2] = size - 1;
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
            bountyBps: 9
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

}
