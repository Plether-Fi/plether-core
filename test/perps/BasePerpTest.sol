// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdEngineAccountLens} from "../../src/perps/CfdEngineAccountLens.sol";
import {CfdEngineLens} from "../../src/perps/CfdEngineLens.sol";
import {CfdEngineProtocolLens} from "../../src/perps/CfdEngineProtocolLens.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {ICfdEngine} from "../../src/perps/interfaces/ICfdEngine.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

abstract contract BasePerpTest is Test {

    struct CloseParitySnapshot {
        ICfdEngine.ProtocolAccountingSnapshot protocol;
        uint256 settlementUsdc;
        uint256 deferredPayoutUsdc;
    }

    struct CloseParityObserved {
        uint256 immediatePayoutUsdc;
        uint256 deferredPayoutUsdc;
        uint256 badDebtUsdc;
        uint256 remainingSize;
        uint256 remainingMargin;
        bool degradedMode;
        uint256 effectiveAssetsAfterUsdc;
        uint256 maxLiabilityAfterUsdc;
    }

    struct LiquidationParitySnapshot {
        ICfdEngine.ProtocolAccountingSnapshot protocol;
        uint256 settlementUsdc;
        uint256 deferredPayoutUsdc;
        uint256 keeperWalletUsdc;
        uint256 deferredClearerBountyUsdc;
    }

    struct LiquidationParityObserved {
        uint256 immediatePayoutUsdc;
        uint256 deferredPayoutUsdc;
        uint256 badDebtUsdc;
        uint256 keeperWalletUsdc;
        uint256 deferredClearerBountyUsdc;
        uint256 remainingSize;
        bool degradedMode;
        uint256 effectiveAssetsAfterUsdc;
        uint256 maxLiabilityAfterUsdc;
    }

    struct WithdrawParityState {
        bool checkWithdrawPasses;
        bytes4 checkWithdrawSelector;
        bool withdrawPasses;
        bytes4 withdrawSelector;
    }

    MockUSDC usdc;
    CfdEngine engine;
    CfdEngineAccountLens engineAccountLens;
    CfdEngineLens engineLens;
    CfdEngineProtocolLens engineProtocolLens;
    HousePool pool;
    MarginClearinghouse clearinghouse;
    TrancheVault seniorVault;
    TrancheVault juniorVault;
    OrderRouter router;

    /// @dev Monday 2024-03-04 10:00 UTC. Avoids FAD window.
    uint256 constant SETUP_TIMESTAMP = 1_709_532_000;
    uint256 constant CAP_PRICE = 2e8;

    receive() external payable {}

    function setUp() public virtual {
        usdc = new MockUSDC();
        clearinghouse = new MarginClearinghouse(address(usdc));

        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
        engineAccountLens = new CfdEngineAccountLens(address(engine));
        engineLens = new CfdEngineLens(address(engine));
        engineProtocolLens = new CfdEngineProtocolLens(address(engine));
        pool = new HousePool(address(usdc), address(engine));

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");

        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        router = new OrderRouter(
            address(engine),
            address(pool),
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _bypassAllTimelocks();

        uint256 juniorSeed = _initialJuniorSeedDeposit();
        if (juniorSeed > 0) {
            usdc.mint(address(this), juniorSeed);
            usdc.approve(address(pool), juniorSeed);
            pool.initializeSeedPosition(false, juniorSeed, _juniorSeedReceiver());
        }

        uint256 seniorSeed = _initialSeniorSeedDeposit();
        if (seniorSeed > 0) {
            usdc.mint(address(this), seniorSeed);
            usdc.approve(address(pool), seniorSeed);
            pool.initializeSeedPosition(true, seniorSeed, _seniorSeedReceiver());
        }

        if (_autoActivateTrading() && pool.isSeedLifecycleComplete()) {
            pool.activateTrading();
        }

        uint256 junior = _initialJuniorDeposit();
        if (junior > 0) {
            _fundJunior(address(this), junior);
        }

        uint256 senior = _initialSeniorDeposit();
        if (senior > 0) {
            _fundSenior(address(this), senior);
        }
    }

    function _bypassAllTimelocks() internal {
        clearinghouse.setEngine(address(engine));
        vm.warp(SETUP_TIMESTAMP);
    }

    function _bootstrapSeededLifecycle() internal {
        uint256 juniorSeed = _initialJuniorSeedDeposit();
        if (juniorSeed > 0 && !pool.hasSeedLifecycleStarted()) {
            usdc.mint(address(this), juniorSeed);
            usdc.approve(address(pool), juniorSeed);
            pool.initializeSeedPosition(false, juniorSeed, _juniorSeedReceiver());
        }

        uint256 seniorSeed = _initialSeniorSeedDeposit();
        if (seniorSeed > 0 && !pool.isSeedLifecycleComplete()) {
            usdc.mint(address(this), seniorSeed);
            usdc.approve(address(pool), seniorSeed);
            pool.initializeSeedPosition(true, seniorSeed, _seniorSeedReceiver());
        }

        if (_autoActivateTrading() && pool.isSeedLifecycleComplete() && !pool.isTradingActive()) {
            pool.activateTrading();
        }
    }

    // --- Virtual hooks ---

    function _riskParams() internal pure virtual returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure virtual returns (uint256) {
        return 1_000_000 * 1e6;
    }

    function _initialSeniorDeposit() internal pure virtual returns (uint256) {
        return 0;
    }

    function _initialJuniorSeedDeposit() internal pure virtual returns (uint256) {
        return 1000e6;
    }

    function _initialSeniorSeedDeposit() internal pure virtual returns (uint256) {
        return 1000e6;
    }

    function _juniorSeedReceiver() internal view virtual returns (address) {
        return address(this);
    }

    function _autoActivateTrading() internal pure virtual returns (bool) {
        return true;
    }

    function _seniorSeedReceiver() internal view virtual returns (address) {
        return address(this);
    }

    // --- Funding helpers ---

    function _fundJunior(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), amount);
        juniorVault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _fundSenior(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(seniorVault), amount);
        seniorVault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _fundTrader(
        address trader,
        uint256 amount
    ) internal {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, amount);
        vm.stopPrank();
    }

    // --- Trading helpers ---

    function _open(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price
    ) internal {
        _open(accountId, side, size, margin, price, pool.totalAssets());
    }

    function _open(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 depth
    ) internal {
        vm.prank(address(router));
        engine.processOrder(
            CfdTypes.Order({
                accountId: accountId,
                sizeDelta: size,
                marginDelta: margin,
                targetPrice: price,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: side,
                isClose: false
            }),
            price,
            depth,
            uint64(block.timestamp)
        );
    }

    function _close(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 size,
        uint256 price
    ) internal {
        _close(accountId, side, size, price, pool.totalAssets());
    }

    function _close(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 size,
        uint256 price,
        uint256 depth
    ) internal {
        _closeAt(accountId, side, size, price, depth, uint64(block.timestamp));
    }

    function _closeAt(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 size,
        uint256 price,
        uint256 depth,
        uint64 publishTime
    ) internal {
        vm.prank(address(router));
        engine.processOrder(
            CfdTypes.Order({
                accountId: accountId,
                sizeDelta: size,
                marginDelta: 0,
                targetPrice: 0,
                commitTime: publishTime,
                commitBlock: uint64(block.number),
                orderId: 0,
                side: side,
                isClose: true
            }),
            price,
            depth,
            publishTime
        );
    }

    function _captureCloseParitySnapshot(
        bytes32 accountId
    ) internal view returns (CloseParitySnapshot memory snapshot) {
        snapshot.protocol = engineProtocolLens.getProtocolAccountingSnapshot();
        snapshot.settlementUsdc = clearinghouse.balanceUsdc(accountId);
        snapshot.deferredPayoutUsdc = engine.deferredPayoutUsdc(accountId);
    }

    function _observeCloseParity(
        bytes32 accountId,
        CloseParitySnapshot memory beforeSnapshot
    ) internal view returns (CloseParityObserved memory observed) {
        ICfdEngine.ProtocolAccountingSnapshot memory afterSnapshot = engineProtocolLens.getProtocolAccountingSnapshot();
        (observed.remainingSize, observed.remainingMargin,,,,,,) = engine.positions(accountId);
        uint256 settlementAfter = clearinghouse.balanceUsdc(accountId);
        observed.immediatePayoutUsdc =
            settlementAfter > beforeSnapshot.settlementUsdc ? settlementAfter - beforeSnapshot.settlementUsdc : 0;
        observed.deferredPayoutUsdc = engine.deferredPayoutUsdc(accountId);
        observed.badDebtUsdc = afterSnapshot.accumulatedBadDebtUsdc - beforeSnapshot.protocol.accumulatedBadDebtUsdc;
        observed.degradedMode = engine.degradedMode();
        observed.effectiveAssetsAfterUsdc = afterSnapshot.effectiveSolvencyAssetsUsdc;
        observed.maxLiabilityAfterUsdc = afterSnapshot.maxLiabilityUsdc;
    }

    function _assertClosePreviewMatchesObserved(
        CfdEngine.ClosePreview memory preview,
        CloseParityObserved memory observed,
        bool degradedModeBefore
    ) internal pure {
        assertEq(
            observed.immediatePayoutUsdc, preview.immediatePayoutUsdc, "Immediate payout should match close preview"
        );
        assertEq(observed.deferredPayoutUsdc, preview.deferredPayoutUsdc, "Deferred payout should match close preview");
        assertEq(observed.badDebtUsdc, preview.badDebtUsdc, "Bad debt should match close preview");
        assertEq(observed.remainingSize, preview.remainingSize, "Remaining size should match close preview");
        assertEq(observed.remainingMargin, preview.remainingMargin, "Remaining margin should match close preview");
        assertEq(
            observed.degradedMode,
            degradedModeBefore || preview.triggersDegradedMode,
            "Latched degraded mode should match close preview transition semantics"
        );
        assertEq(
            observed.effectiveAssetsAfterUsdc,
            preview.effectiveAssetsAfterUsdc,
            "Effective assets after close should match preview"
        );
        assertEq(
            observed.maxLiabilityAfterUsdc,
            preview.maxLiabilityAfterUsdc,
            "Max liability after close should match preview"
        );
    }

    function _assertClosePreviewEquals(
        CfdEngine.ClosePreview memory actual,
        CfdEngine.ClosePreview memory expected
    ) internal pure {
        assertEq(actual.valid, expected.valid, "Close preview validity should match");
        assertEq(uint8(actual.invalidReason), uint8(expected.invalidReason), "Close invalid reason should match");
        assertEq(actual.executionPrice, expected.executionPrice, "Close execution price should match");
        assertEq(actual.sizeDelta, expected.sizeDelta, "Close size delta should match");
        assertEq(actual.realizedPnlUsdc, expected.realizedPnlUsdc, "Close realized pnl should match");
        assertEq(actual.fundingUsdc, expected.fundingUsdc, "Close funding should match");
        assertEq(actual.vpiDeltaUsdc, expected.vpiDeltaUsdc, "Close VPI delta should match");
        assertEq(actual.vpiUsdc, expected.vpiUsdc, "Close VPI should match");
        assertEq(actual.executionFeeUsdc, expected.executionFeeUsdc, "Close execution fee should match");
        assertEq(actual.freshTraderPayoutUsdc, expected.freshTraderPayoutUsdc, "Close fresh payout should match");
        assertEq(
            actual.existingDeferredConsumedUsdc,
            expected.existingDeferredConsumedUsdc,
            "Close deferred consumption should match"
        );
        assertEq(
            actual.existingDeferredRemainingUsdc,
            expected.existingDeferredRemainingUsdc,
            "Close deferred remainder should match"
        );
        assertEq(actual.immediatePayoutUsdc, expected.immediatePayoutUsdc, "Close immediate payout should match");
        assertEq(actual.deferredPayoutUsdc, expected.deferredPayoutUsdc, "Close deferred payout should match");
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
        assertEq(
            actual.solvencyFundingPnlUsdc, expected.solvencyFundingPnlUsdc, "Close solvency funding pnl should match"
        );
    }

    function _captureLiquidationParitySnapshot(
        bytes32 accountId,
        address keeper
    ) internal view returns (LiquidationParitySnapshot memory snapshot) {
        snapshot.protocol = engineProtocolLens.getProtocolAccountingSnapshot();
        snapshot.settlementUsdc = clearinghouse.balanceUsdc(accountId);
        snapshot.deferredPayoutUsdc = engine.deferredPayoutUsdc(accountId);
        snapshot.keeperWalletUsdc = usdc.balanceOf(keeper);
        snapshot.deferredClearerBountyUsdc = engine.deferredClearerBountyUsdc(keeper);
    }

    function _observeLiquidationParity(
        bytes32 accountId,
        address keeper,
        LiquidationParitySnapshot memory beforeSnapshot
    ) internal view returns (LiquidationParityObserved memory observed) {
        ICfdEngine.ProtocolAccountingSnapshot memory afterSnapshot = engineProtocolLens.getProtocolAccountingSnapshot();
        (observed.remainingSize,,,,,,,) = engine.positions(accountId);
        uint256 settlementAfter = clearinghouse.balanceUsdc(accountId);
        observed.immediatePayoutUsdc =
            settlementAfter > beforeSnapshot.settlementUsdc ? settlementAfter - beforeSnapshot.settlementUsdc : 0;
        observed.deferredPayoutUsdc = engine.deferredPayoutUsdc(accountId);
        observed.badDebtUsdc = afterSnapshot.accumulatedBadDebtUsdc - beforeSnapshot.protocol.accumulatedBadDebtUsdc;
        uint256 keeperWalletAfter = usdc.balanceOf(keeper);
        observed.keeperWalletUsdc = keeperWalletAfter > beforeSnapshot.keeperWalletUsdc
            ? keeperWalletAfter - beforeSnapshot.keeperWalletUsdc
            : 0;
        uint256 deferredClearerAfter = engine.deferredClearerBountyUsdc(keeper);
        observed.deferredClearerBountyUsdc = deferredClearerAfter > beforeSnapshot.deferredClearerBountyUsdc
            ? deferredClearerAfter - beforeSnapshot.deferredClearerBountyUsdc
            : 0;
        observed.degradedMode = engine.degradedMode();
        observed.effectiveAssetsAfterUsdc = afterSnapshot.effectiveSolvencyAssetsUsdc;
        observed.maxLiabilityAfterUsdc = afterSnapshot.maxLiabilityUsdc;
    }

    function _assertLiquidationPreviewMatchesObserved(
        CfdEngine.LiquidationPreview memory preview,
        LiquidationParityObserved memory observed,
        bool degradedModeBefore
    ) internal pure {
        assertEq(
            observed.immediatePayoutUsdc,
            preview.immediatePayoutUsdc,
            "Immediate trader payout should match liquidation preview"
        );
        assertEq(
            observed.deferredPayoutUsdc,
            preview.deferredPayoutUsdc,
            "Deferred trader payout should match liquidation preview"
        );
        assertEq(observed.badDebtUsdc, preview.badDebtUsdc, "Bad debt should match liquidation preview");
        assertEq(
            observed.keeperWalletUsdc + observed.deferredClearerBountyUsdc,
            preview.keeperBountyUsdc,
            "Keeper bounty settlement should match liquidation preview"
        );
        assertEq(observed.remainingSize, 0, "Liquidation parity helper expects the position to be fully removed");
        assertEq(
            observed.degradedMode,
            degradedModeBefore || preview.triggersDegradedMode,
            "Latched degraded mode should match liquidation preview transition semantics"
        );
        assertEq(
            observed.effectiveAssetsAfterUsdc,
            preview.effectiveAssetsAfterUsdc,
            "Effective assets after liquidation should match preview"
        );
        assertEq(
            observed.maxLiabilityAfterUsdc,
            preview.maxLiabilityAfterUsdc,
            "Max liability after liquidation should match preview"
        );
    }

    function _assertLiquidationPreviewEquals(
        CfdEngine.LiquidationPreview memory actual,
        CfdEngine.LiquidationPreview memory expected
    ) internal pure {
        assertEq(
            actual.liquidatable, expected.liquidatable, "Liquidatable flag should match canonical simulateLiquidation"
        );
        assertEq(actual.oraclePrice, expected.oraclePrice, "Liquidation oracle price should match");
        assertEq(actual.equityUsdc, expected.equityUsdc, "Liquidation equity should match");
        assertEq(actual.pnlUsdc, expected.pnlUsdc, "Liquidation pnl should match");
        assertEq(actual.fundingUsdc, expected.fundingUsdc, "Liquidation funding should match");
        assertEq(actual.reachableCollateralUsdc, expected.reachableCollateralUsdc, "Reachable collateral should match");
        assertEq(actual.keeperBountyUsdc, expected.keeperBountyUsdc, "Keeper bounty should match");
        assertEq(actual.seizedCollateralUsdc, expected.seizedCollateralUsdc, "Seized collateral should match");
        assertEq(actual.settlementRetainedUsdc, expected.settlementRetainedUsdc, "Settlement retained should match");
        assertEq(actual.freshTraderPayoutUsdc, expected.freshTraderPayoutUsdc, "Fresh trader payout should match");
        assertEq(
            actual.existingDeferredConsumedUsdc,
            expected.existingDeferredConsumedUsdc,
            "Deferred consumption should match"
        );
        assertEq(
            actual.existingDeferredRemainingUsdc,
            expected.existingDeferredRemainingUsdc,
            "Deferred remainder should match"
        );
        assertEq(actual.immediatePayoutUsdc, expected.immediatePayoutUsdc, "Immediate payout should match");
        assertEq(actual.deferredPayoutUsdc, expected.deferredPayoutUsdc, "Deferred payout should match");
        assertEq(actual.badDebtUsdc, expected.badDebtUsdc, "Bad debt should match");
        assertEq(actual.triggersDegradedMode, expected.triggersDegradedMode, "Degraded trigger should match");
        assertEq(actual.postOpDegradedMode, expected.postOpDegradedMode, "Post-op degraded mode should match");
        assertEq(actual.effectiveAssetsAfterUsdc, expected.effectiveAssetsAfterUsdc, "Effective assets should match");
        assertEq(actual.maxLiabilityAfterUsdc, expected.maxLiabilityAfterUsdc, "Max liability should match");
        assertEq(actual.solvencyFundingPnlUsdc, expected.solvencyFundingPnlUsdc, "Solvency funding pnl should match");
    }

    function _observeWithdrawParity(
        bytes32 accountId,
        address trader,
        uint256 amountUsdc
    ) internal returns (WithdrawParityState memory state) {
        try engine.checkWithdraw(accountId) {
            state.checkWithdrawPasses = true;
        } catch (bytes memory err) {
            state.checkWithdrawSelector = _revertSelector(err);
        }

        vm.prank(trader);
        try clearinghouse.withdraw(accountId, amountUsdc) {
            state.withdrawPasses = true;
        } catch (bytes memory err) {
            state.withdrawSelector = _revertSelector(err);
        }
    }

    function _assertWithdrawParity(
        WithdrawParityState memory state,
        bytes4 expectedGuardSelector
    ) internal pure {
        assertEq(state.withdrawPasses, state.checkWithdrawPasses, "Withdraw result should mirror checkWithdraw gate");
        if (!state.checkWithdrawPasses) {
            assertEq(
                state.checkWithdrawSelector, expectedGuardSelector, "checkWithdraw should fail with expected selector"
            );
            assertEq(state.withdrawSelector, expectedGuardSelector, "live withdraw should fail with same selector");
        }
    }

    function _revertSelector(
        bytes memory err
    ) internal pure returns (bytes4 selector) {
        if (err.length < 4) {
            return bytes4(0);
        }
        assembly {
            selector := mload(add(err, 32))
        }
    }

    // --- Governance helpers ---

    function _setRiskParams(
        CfdTypes.RiskParams memory params
    ) internal {
        engine.proposeRiskParams(params);
        vm.warp(block.timestamp + 48 hours + 1);
        engine.finalizeRiskParams();
    }

    // --- Time helpers ---

    function _warpForward(
        uint256 delta
    ) internal {
        uint256 ts;
        assembly {
            ts := timestamp()
        }
        vm.warp(ts + delta);
    }

    function _sideState(
        CfdTypes.Side side
    ) internal view returns (ICfdEngine.SideState memory) {
        return engine.getSideState(side);
    }

    function _sideOpenInterest(
        CfdTypes.Side side
    ) internal view returns (uint256) {
        return _sideState(side).openInterest;
    }

    function _sideEntryNotional(
        CfdTypes.Side side
    ) internal view returns (uint256) {
        return _sideState(side).entryNotional;
    }

    function _sideTotalMargin(
        CfdTypes.Side side
    ) internal view returns (uint256) {
        return _sideState(side).totalMargin;
    }

    function _sideFundingIndex(
        CfdTypes.Side side
    ) internal view returns (int256) {
        return _sideState(side).fundingIndex;
    }

    function _sideEntryFunding(
        CfdTypes.Side side
    ) internal view returns (int256) {
        return _sideState(side).entryFunding;
    }

    function _sideMaxProfit(
        CfdTypes.Side side
    ) internal view returns (uint256) {
        return _sideState(side).maxProfitUsdc;
    }

}
