// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";

/// @notice Public trading and LP calls reach atom-scale impairment before testing the remaining owners' recovery.
/// @dev MockPyth permits one 1e-8 price tick per USDG atom on the final one-lot close. This establishes the accounting
///      consequence in a controlled oracle fixture, not production availability of an arbitrary signed price.
contract SeniorHwmAtomExitTest is BasePerpTest {

    address internal constant KEEPER = address(0xC0FFEE);
    address internal constant LONG_TRADER = address(0x10A6);
    address internal constant SHORT_TRADER = address(0x5407);
    address internal constant STAY = address(0x57A1);
    address internal constant EXIT = address(0xE817);
    address internal constant JUNIOR_A = address(0x7A);
    address internal constant JUNIOR_B = address(0x7B);

    uint256 internal lastPublishTime;
    uint256 internal currentPrice = 1e8;
    OrderRouter internal publicRouter;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.01e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 10,
            initMarginBps: 20,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyAssets: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 1e6;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 1e6;
    }

    function setUp() public override {
        super.setUp();
        publicRouter = OrderRouter(address(router));
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.adverseConfidenceMultiplierBps = 2500;
        config.minOpenNotionalAssets = 1000e6;
        _setRouterConfig(config);
        _setSeniorCapacity(40_000_000e6, 8000);
        baseMockPyth.setSynchronizeLegacyUniquePrices(false);

        // Start the public trading sequence on the next Monday at 06:00 UTC.
        uint256 day = vm.getBlockTimestamp() / 1 days;
        uint256 daysUntilMonday = (8 - (day + 4) % 7) % 7;
        vm.warp((day + (daysUntilMonday == 0 ? 7 : daysUntilMonday)) * 1 days + 6 hours);
    }

    function test_ImpairedAtomExitPreservesRemainingSeniorRecovery() public {
        _drainPoolToThreeAtoms();
        engine.clearDegradedMode();
        _settleWithJunior(JUNIOR_A);

        uint256 hwmBefore = pool.seniorHighWaterMark();
        assertEq(pool.seniorPrincipal(), 3, "loss must leave three Senior principal atoms");
        assertEq(pool.juniorPrincipal(), 0);
        assertGt(hwmBefore, 600_000e6, "loss preserves the pre-loss recovery claim");
        uint256 snapshot = vm.snapshotState();

        uint256 stayControl = _recapitalizeAndValueOf(STAY, hwmBefore);
        assertEq(pool.seniorPrincipal(), hwmBefore, "no-exit control restores Senior to its HWM");
        assertTrue(vm.revertToState(snapshot));

        uint256 exitShares = seniorVault.balanceOf(EXIT);
        uint256 supplyBefore = seniorVault.totalSupply();
        uint256 unassignedBefore = pool.unassignedAssets();
        vm.prank(EXIT);
        uint256 requestId = seniorVault.requestRedeem(exitShares, EXIT, EXIT);
        _settle(requestId);

        uint256 hwmAfter = pool.seniorHighWaterMark();
        uint256 shareProportionalHwm = hwmBefore - hwmBefore * exitShares / supplyBefore;
        uint256 formerAssetProportionalHwm = hwmBefore - hwmBefore * 2 / 3;
        assertEq(exitShares * 10_000 / supplyBefore, 5001, "exiting holder owns about 50.01 percent");
        assertEq(seniorVault.totalSupply(), supplyBefore - exitShares, "only funded shares are burned");
        assertEq(pool.seniorPrincipal(), 1, "two of three principal atoms fund the exit");
        assertEq(hwmAfter, shareProportionalHwm, "partial impaired exit preserves remaining share ownership");
        assertGt(hwmAfter - formerAssetProportionalHwm, 99_000e6, "prevents the former recovery entitlement loss");
        assertEq(pool.unassignedAssets(), unassignedBefore, "exit itself assigns no surplus");

        vm.prank(EXIT);
        uint256 paid = seniorVault.claimRedeem(requestId, exitShares, EXIT, EXIT);
        assertEq(paid, 2, "redeeming holder receives only two USDG atoms");

        uint256 stayAfter = _recapitalizeAndValueOf(STAY, hwmBefore);
        assertEq(pool.seniorPrincipal(), hwmAfter, "recapitalization restores the corrected HWM");
        // The independent share quote rounds to USDG atoms; the recovery entitlement also rounds in incumbents' favor.
        assertApproxEqAbs(stayAfter, stayControl, 1, "remaining holder recovers the no-exit control value");
        assertEq(
            pool.unassignedAssets(),
            unassignedBefore + hwmBefore - (hwmAfter - 1),
            "only recapitalization beyond the corrected recovery gap becomes unassigned"
        );
    }

    function test_RecapitalizationBeforeClearingAvoidsAtomPrincipalExit() public {
        _drainPoolToThreeAtoms();
        _recapitalize(pool.seniorHighWaterMark());
        engine.clearDegradedMode();
        _settleWithJunior(JUNIOR_A);
        assertGt(pool.seniorPrincipal(), 500_000e6, "reconcile applies recovery before any Senior exit");

        uint256 exitShares = seniorVault.balanceOf(EXIT);
        vm.prank(EXIT);
        uint256 requestId = seniorVault.requestRedeem(exitShares, EXIT, EXIT);
        _settle(requestId);
        vm.prank(EXIT);
        uint256 paid = seniorVault.claimRedeem(requestId, exitShares, EXIT, EXIT);
        assertGt(paid, 250_000e6, "recapitalization-first control has an ordinary-scale payout");
    }

    /// @dev Public opposing positions consume both tranches; the final one-lot close sets the three-atom remainder.
    function _drainPoolToThreeAtoms() internal {
        _mark(1e8);
        _deposit(juniorVault, JUNIOR_A, 100_000e6);
        _deposit(juniorVault, JUNIOR_B, 100_000e6);
        _deposit(seniorVault, STAY, 299_900e6);
        _deposit(seniorVault, EXIT, 300_100e6);
        _fundTrader(LONG_TRADER, 300_000e6);
        _fundTrader(SHORT_TRADER, 800_000e6);
        for (uint256 i; i < 3; ++i) {
            _trade(LONG_TRADER, false, CfdTypes.Side.LONG, 2400, 80_000e6, 1e8);
            _trade(SHORT_TRADER, false, CfdTypes.Side.SHORT, 2400, 240_000e6, 1e8);
        }
        _trade(LONG_TRADER, true, CfdTypes.Side.LONG, 7200, 0, 0.5e8);
        _closeShortLeaving(7172, 1000e6);
        _closeShortLeaving(20, 200e6);
        _closeShortLeaving(7, 60e6);

        uint256 price = 1e8 + _equity() - 3;
        for (uint256 i; i < 16; ++i) {
            uint256 snapshot = vm.snapshotState();
            _trade(SHORT_TRADER, true, CfdTypes.Side.SHORT, 1, 0, price);
            uint256 remaining = _equity();
            if (remaining == 3) {
                break;
            }
            assertTrue(vm.revertToState(snapshot));
            price = remaining > 3 ? price + (remaining - 3) : price - (3 - remaining);
        }
        assertEq(_equity(), 3, "final public close leaves three atoms");
        assertTrue(engine.degradedMode(), "owner must clear the terminal-loss latch before settlement");
    }

    function _recapitalizeAndValueOf(
        address lp,
        uint256 amount
    ) internal returns (uint256) {
        _recapitalize(amount);
        _settleWithJunior(JUNIOR_B);
        return seniorVault.balanceOf(lp) * (pool.seniorPrincipal() + 1) / (seniorVault.totalSupply() + 1000);
    }

    function _recapitalize(
        uint256 amount
    ) internal {
        settlementToken.mint(address(this), amount);
        settlementToken.approve(address(engine), amount);
        engine.recapitalizePool(amount);
    }

    /// @dev A worthless Junior redemption supplies work so reconciliation can commit without a no-progress revert.
    function _settleWithJunior(
        address lp
    ) internal {
        uint256 shares = juniorVault.balanceOf(lp);
        vm.prank(lp);
        uint256 requestId = juniorVault.requestRedeem(shares, lp, lp);
        _settle(requestId);
    }

    function _equity() internal view returns (uint256) {
        return pool.totalAssets() - engine.totalTraderClaimBalanceAssets();
    }

    function _closeShortLeaving(
        uint256 lots,
        uint256 targetAssets
    ) internal {
        _trade(SHORT_TRADER, true, CfdTypes.Side.SHORT, lots, 0, 1e8 + (_equity() - targetAssets) / lots);
    }

    function _settle(
        uint256 epochId
    ) internal {
        if (vm.getBlockTimestamp() < pool.lpEpochStart(epochId)) {
            vm.warp(pool.lpEpochStart(epochId));
        }
        bytes[] memory data = _priceUpdate(currentPrice);
        vm.prank(KEEPER);
        publicRouter.settleLpEpoch(data);
    }

    function _priceUpdate(
        uint256 price
    ) internal returns (bytes[] memory data) {
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 publishTime = vm.getBlockTimestamp();
        MockPyth.FeedUpdate[] memory updates = new MockPyth.FeedUpdate[](2);
        updates[0] = MockPyth.FeedUpdate(
            BASE_PYTH_FEED_A, MockPyth.MockPrice(int64(int256(price)), 0, -8, publishTime, lastPublishTime)
        );
        updates[1] = MockPyth.FeedUpdate(
            BASE_PYTH_FEED_B, MockPyth.MockPrice(int64(int256(price)), 0, -8, publishTime, lastPublishTime)
        );
        lastPublishTime = publishTime;
        currentPrice = price;
        data = new bytes[](1);
        data[0] = abi.encode(updates);
    }

    function _mark(
        uint256 price
    ) internal {
        bytes[] memory data = _priceUpdate(price);
        vm.prank(KEEPER);
        publicRouter.updateMarkPrice(data);
    }

    function _trade(
        address account,
        bool isClose,
        CfdTypes.Side side,
        uint256 lots,
        uint256 margin,
        uint256 price
    ) internal {
        OrderV3Types.OrderRequest memory request;
        request.clientOrderId = keccak256(abi.encode(account, publicRouter.nextCommitId()));
        request.side = side;
        request.sizeDelta = lots * CfdTypes.SIZE_QUANTUM;
        request.marginDelta = margin;
        request.isClose = isClose;
        request.targetPrice = (side == CfdTypes.Side.LONG) != isClose ? 1 : CAP_PRICE;
        uint256 unlimited = type(uint256).max;
        request.bounds = OrderV3Types.ExecutionBounds({
            submitBy: uint64(vm.getBlockTimestamp() + 60),
            executionWindowSeconds: 60,
            allowedExecutionModes: 7,
            expectedConfigHash: publicRouter.lifecycleBook().currentExecutionConfigHash(),
            maxExecutionBountyAssets: unlimited,
            maxExecutionNotionalAssets: unlimited,
            maxGrossAccountDebitAssets: unlimited,
            maxActionChargeAssets: unlimited,
            maxExplicitFeesAssets: unlimited,
            maxPostPositionSize: unlimited,
            minPostSettlementBalanceAssets: 0,
            minPostPositionEquityAssets: 0,
            maxPostLeverageBps: type(uint32).max
        });
        vm.prank(account);
        uint64 orderId = publicRouter.commitOrder(request);
        bytes[] memory data = _priceUpdate(price);
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = publicRouter.executeOrder(orderId, data);
        assertTrue(result.status == OrderV3Types.LifecycleStatus.Executed, "public order must execute");
    }

    function _deposit(
        TrancheVault vault,
        address lp,
        uint256 assets
    ) internal {
        settlementToken.mint(lp, assets);
        vm.startPrank(lp);
        settlementToken.approve(address(vault), assets);
        uint256 requestId = vault.requestDeposit(assets, lp, lp);
        vm.stopPrank();
        vm.warp(pool.lpEpochStart(requestId));
        pool.settleLpEpoch(0, 0);
        vm.prank(lp);
        vault.claimDeposit(requestId, assets, lp, lp);
    }

}
