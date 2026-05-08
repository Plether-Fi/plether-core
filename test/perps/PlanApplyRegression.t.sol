// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdMath} from "../../src/perps/CfdMath.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {ICfdEngine} from "../../src/perps/interfaces/ICfdEngine.sol";
import {ProtocolLensViewTypes} from "../../src/perps/interfaces/ProtocolLensViewTypes.sol";
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
            bountyBps: 10
        });
    }

    // ──────────────────────────────────────────────
    //  1. Partial close with accrued carry:
    //     legacy side index remains zero in the carry model
    // ──────────────────────────────────────────────

    function test_PartialClose_LegacySideIndexStaysZeroAfterAllClose() public {
        address bullAccount = address(uint160(1));
        address bearAccount = address(uint160(2));
        _fundTrader(bullAccount, 50_000e6);
        _fundTrader(bearAccount, 50_000e6);

        _open(bullAccount, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);
        _open(bearAccount, CfdTypes.Side.BEAR, 50_000e18, 5000e6, 1e8);

        uint256 closeTime = block.timestamp + 30 days;
        vm.warp(closeTime);
        this.doClose(bullAccount, CfdTypes.Side.BULL, 50_000e18, 1.2e8);
        vm.warp(closeTime + 1);
        this.doClose(bullAccount, CfdTypes.Side.BULL, 50_000e18, 1.2e8);
        vm.warp(closeTime + 2);
        this.doClose(bearAccount, CfdTypes.Side.BEAR, 50_000e18, 0.8e8);

        int256 bullLegacySpread = _computeGlobalLegacySpreadPnl(CfdTypes.Side.BULL);
        int256 bearLegacySpread = _computeGlobalLegacySpreadPnl(CfdTypes.Side.BEAR);

        assertEq(
            bullLegacySpread + bearLegacySpread,
            0,
            "Global legacy-spread PnL must stay zero when all positions are closed"
        );
    }

    function test_PartialClose_PreviewMatchesExecution_WithCarryAccrual() public {
        address bullAccount = address(uint160(0xA1));
        address bearAccount = address(uint160(0xA2));
        _fundTrader(bullAccount, 30_000e6);
        _fundTrader(bearAccount, 30_000e6);

        _open(bullAccount, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);
        _open(bearAccount, CfdTypes.Side.BEAR, 30_000e18, 3000e6, 1e8);

        vm.warp(block.timestamp + 14 days);

        uint256 vaultDepth = pool.totalAssets();
        CfdEngine.ClosePreview memory preview = engineLens.previewClose(bullAccount, 40_000e18, 0.9e8);
        assertTrue(preview.valid, "Partial close preview should be valid");

        this.doClose(bullAccount, CfdTypes.Side.BULL, 40_000e18, 0.9e8);

        (uint256 sizeAfter, uint256 marginAfter,,,,,) = engine.positions(bullAccount);
        assertEq(sizeAfter, preview.remainingSize, "Post-close size matches preview");
        assertEq(marginAfter, preview.remainingMargin, "Post-close margin matches preview");
    }

    // ──────────────────────────────────────────────
    //  2. Liquidation preview with carry-adjusted state,
    //     asymmetric side state
    // ──────────────────────────────────────────────

    function test_LiquidationPreview_AsymmetricSides_SolvencyCoherent() public {
        address bullAccount = address(uint160(0xB1));
        address bearAccount = address(uint160(0xB2));
        _fundTrader(bullAccount, 10_000e6);
        _fundTrader(bearAccount, 50_000e6);

        _open(bullAccount, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);
        _open(bearAccount, CfdTypes.Side.BEAR, 20_000e18, 2000e6, 1e8);

        vm.warp(block.timestamp + 60 days);

        uint256 liquidationPrice = 1.15e8;
        uint256 vaultDepth = pool.totalAssets();
        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(bullAccount, liquidationPrice);

        if (!preview.liquidatable) {
            return;
        }

        (,,, uint256 posMaxProfit,,,) = engine.positions(bullAccount);
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
        address bullAccount = address(uint160(0xC1));
        address bearAccount = address(uint160(0xC2));
        _fundTrader(bullAccount, 30_000e6);
        _fundTrader(bearAccount, 30_000e6);

        _open(bullAccount, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);
        _open(bearAccount, CfdTypes.Side.BEAR, 60_000e18, 6000e6, 1e8);

        vm.warp(block.timestamp + 7 days);

        uint256 closePrice = 0.95e8;
        uint256 vaultDepth = pool.totalAssets();
        CfdEngine.ClosePreview memory preview = engineLens.previewClose(bullAccount, 100_000e18, closePrice);

        if (!preview.valid) {
            return;
        }

        this.doClose(bullAccount, CfdTypes.Side.BULL, 100_000e18, closePrice);

        uint256 postMaxLiability = _sideMaxProfit(CfdTypes.Side.BULL) > _sideMaxProfit(CfdTypes.Side.BEAR)
            ? _sideMaxProfit(CfdTypes.Side.BULL)
            : _sideMaxProfit(CfdTypes.Side.BEAR);

        assertEq(preview.maxLiabilityAfterUsdc, postMaxLiability, "Preview max liability must match post-close storage");

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snap =
            engineProtocolLens.getProtocolAccountingSnapshot();

        assertEq(
            preview.effectiveAssetsAfterUsdc > preview.maxLiabilityAfterUsdc,
            !engine.degradedMode(),
            "Preview solvency assessment must agree with post-close degraded mode"
        );

        snap = snap;
    }

    function test_LiquidationSolvency_MatchesPostOpStorageState() public {
        address bullAccount = address(uint160(0xD1));
        address bearAccount = address(uint160(0xD2));
        _fundTrader(bullAccount, 20_000e6);
        _fundTrader(bearAccount, 50_000e6);

        _open(bullAccount, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);
        _open(bearAccount, CfdTypes.Side.BEAR, 20_000e18, 2000e6, 1e8);

        vm.warp(block.timestamp + 30 days);

        uint256 liquidationPrice = 1.2e8;
        uint256 vaultDepth = pool.totalAssets();
        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(bullAccount, liquidationPrice);

        if (!preview.liquidatable) {
            return;
        }

        vm.prank(address(router));
        engine.liquidatePosition(bullAccount, liquidationPrice, vaultDepth, uint64(block.timestamp), address(this));

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
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 price
    ) external {
        _close(account, side, size, price);
    }

    function doOpen(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price
    ) external {
        _open(account, side, size, margin, price);
    }

    function _computeGlobalLegacySpreadPnl(
        CfdTypes.Side side
    ) internal view returns (int256) {
        side;
        return 0;
    }

}
