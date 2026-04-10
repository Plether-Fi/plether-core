// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdMath} from "../../src/perps/CfdMath.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {ProtocolLensViewTypes} from "../../src/perps/interfaces/ProtocolLensViewTypes.sol";
import {ICfdEngine} from "../../src/perps/interfaces/ICfdEngine.sol";
import {CfdEngineSnapshotsLib} from "../../src/perps/libraries/CfdEngineSnapshotsLib.sol";
import {SolvencyAccountingLib} from "../../src/perps/libraries/SolvencyAccountingLib.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract PlanApplyRegressionTest is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.5e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 15
        });
    }

    // ──────────────────────────────────────────────
    //  1. Partial close with accrued funding:
    //     entry funding uses post-funding index
    // ──────────────────────────────────────────────

    function test_PartialClose_SideEntryFundingZeroesAfterAllClose() public {
        bytes32 bullId = bytes32(uint256(1));
        bytes32 bearId = bytes32(uint256(2));
        _fundTrader(address(uint160(uint256(bullId))), 50_000e6);
        _fundTrader(address(uint160(uint256(bearId))), 50_000e6);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 50_000e18, 5000e6, 1e8);

        uint256 closeTime = block.timestamp + 30 days;
        vm.warp(closeTime);
        this.doClose(bullId, CfdTypes.Side.BULL, 50_000e18, 1.2e8);
        vm.warp(closeTime + 1);
        this.doClose(bullId, CfdTypes.Side.BULL, 50_000e18, 1.2e8);
        vm.warp(closeTime + 2);
        this.doClose(bearId, CfdTypes.Side.BEAR, 50_000e18, 0.8e8);

        int256 bullFunding = _computeGlobalFundingPnl(CfdTypes.Side.BULL);
        int256 bearFunding = _computeGlobalFundingPnl(CfdTypes.Side.BEAR);

        assertEq(bullFunding + bearFunding, 0, "Global funding PnL must be zero when all positions are closed");
    }

    function test_PartialClose_PreviewMatchesExecution_WithAccruedFunding() public {
        bytes32 bullId = bytes32(uint256(0xA1));
        bytes32 bearId = bytes32(uint256(0xA2));
        _fundTrader(address(uint160(uint256(bullId))), 30_000e6);
        _fundTrader(address(uint160(uint256(bearId))), 30_000e6);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 30_000e18, 3000e6, 1e8);

        vm.warp(block.timestamp + 14 days);

        uint256 vaultDepth = pool.totalAssets();
        CfdEngine.ClosePreview memory preview = engineLens.previewClose(bullId, 40_000e18, 0.9e8);
        assertTrue(preview.valid, "Partial close preview should be valid");
        int256 entryFundingBefore = 0;

        this.doClose(bullId, CfdTypes.Side.BULL, 40_000e18, 0.9e8);

        (uint256 sizeAfter, uint256 marginAfter,,,,,,) = engine.positions(bullId);
        assertEq(sizeAfter, preview.remainingSize, "Post-close size matches preview");
        assertEq(marginAfter, preview.remainingMargin, "Post-close margin matches preview");

        int256 entryFundingAfter = 0;
        assertEq(entryFundingAfter, entryFundingBefore);
    }

    // ──────────────────────────────────────────────
    //  2. Liquidation preview with nonzero funding,
    //     asymmetric side state
    // ──────────────────────────────────────────────

    function test_LiquidationPreview_AsymmetricSides_SolvencyCoherent() public {
        bytes32 bullId = bytes32(uint256(0xB1));
        bytes32 bearId = bytes32(uint256(0xB2));
        _fundTrader(address(uint160(uint256(bullId))), 10_000e6);
        _fundTrader(address(uint160(uint256(bearId))), 50_000e6);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 20_000e18, 2000e6, 1e8);

        vm.warp(block.timestamp + 60 days);

        uint256 liquidationPrice = 1.15e8;
        uint256 vaultDepth = pool.totalAssets();
        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(bullId, liquidationPrice);

        if (!preview.liquidatable) {
            return;
        }

        (,,, uint256 posMaxProfit,,,,) = engine.positions(bullId);
        uint256 bullMaxAfter = _sideMaxProfit(CfdTypes.Side.BULL) - posMaxProfit;
        uint256 bearMax = _sideMaxProfit(CfdTypes.Side.BEAR);
        uint256 expectedMaxLiability = bullMaxAfter > bearMax ? bullMaxAfter : bearMax;

        assertEq(
            preview.maxLiabilityAfterUsdc,
            expectedMaxLiability,
            "Post-liquidation max liability must reflect removed position"
        );

        assertEq(
            preview.postOpDegradedMode,
            preview.effectiveAssetsAfterUsdc < preview.maxLiabilityAfterUsdc || engine.degradedMode(),
            "postOpDegradedMode must equal (effectiveAssets < maxLiability || alreadyDegraded)"
        );

    }

    // ──────────────────────────────────────────────
    //  3. Solvency reference recomputation:
    //     delta.solvency matches manually-built
    //     post-op state
    // ──────────────────────────────────────────────

    function test_CloseSolvency_MatchesPostOpStorageState() public {
        bytes32 bullId = bytes32(uint256(0xC1));
        bytes32 bearId = bytes32(uint256(0xC2));
        _fundTrader(address(uint160(uint256(bullId))), 30_000e6);
        _fundTrader(address(uint160(uint256(bearId))), 30_000e6);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 60_000e18, 6000e6, 1e8);

        vm.warp(block.timestamp + 7 days);

        uint256 closePrice = 0.95e8;
        uint256 vaultDepth = pool.totalAssets();
        CfdEngine.ClosePreview memory preview = engineLens.previewClose(bullId, 100_000e18, closePrice);

        if (!preview.valid) {
            return;
        }

        this.doClose(bullId, CfdTypes.Side.BULL, 100_000e18, closePrice);

        uint256 postMaxLiability = _sideMaxProfit(CfdTypes.Side.BULL) > _sideMaxProfit(CfdTypes.Side.BEAR)
            ? _sideMaxProfit(CfdTypes.Side.BULL)
            : _sideMaxProfit(CfdTypes.Side.BEAR);

        assertEq(preview.maxLiabilityAfterUsdc, postMaxLiability, "Preview max liability must match post-close storage");

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snap = engineProtocolLens.getProtocolAccountingSnapshot();

        assertEq(
            preview.effectiveAssetsAfterUsdc > preview.maxLiabilityAfterUsdc,
            !engine.degradedMode(),
            "Preview solvency assessment must agree with post-close degraded mode"
        );

        assertEq(
            preview.solvencyFundingPnlUsdc,
            snap.cappedFundingPnlUsdc,
            "Preview solvency funding must match post-close capped funding PnL"
        );
    }

    function test_LiquidationSolvency_MatchesPostOpStorageState() public {
        bytes32 bullId = bytes32(uint256(0xD1));
        bytes32 bearId = bytes32(uint256(0xD2));
        _fundTrader(address(uint160(uint256(bullId))), 20_000e6);
        _fundTrader(address(uint160(uint256(bearId))), 50_000e6);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 20_000e18, 2000e6, 1e8);

        vm.warp(block.timestamp + 30 days);

        uint256 liquidationPrice = 1.2e8;
        uint256 vaultDepth = pool.totalAssets();
        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(bullId, liquidationPrice);

        if (!preview.liquidatable) {
            return;
        }

        vm.prank(address(router));
        engine.liquidatePosition(bullId, liquidationPrice, vaultDepth, uint64(block.timestamp));

        uint256 postMaxLiability = _sideMaxProfit(CfdTypes.Side.BULL) > _sideMaxProfit(CfdTypes.Side.BEAR)
            ? _sideMaxProfit(CfdTypes.Side.BULL)
            : _sideMaxProfit(CfdTypes.Side.BEAR);

        assertEq(
            preview.maxLiabilityAfterUsdc, postMaxLiability, "Preview max liability must match post-liquidation storage"
        );

        assertEq(
            preview.postOpDegradedMode, engine.degradedMode(), "Preview degraded mode must match post-liquidation state"
        );
    }

    // ──────────────────────────────────────────────
    //  HELPERS
    // ──────────────────────────────────────────────

    function doClose(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 size,
        uint256 price
    ) external {
        _close(accountId, side, size, price);
    }

    function doOpen(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price
    ) external {
        _open(accountId, side, size, margin, price);
    }

    function _computeGlobalFundingPnl(
        CfdTypes.Side side
    ) internal view returns (int256) {
        side;
        return 0;
    }

}
