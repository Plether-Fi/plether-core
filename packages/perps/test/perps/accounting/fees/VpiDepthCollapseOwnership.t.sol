// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

/// @notice A depth-amplified opening rebate must not sell ownership of its locked recovery at a discount.
/// @dev Public Router orders and asynchronous LP calls, with a local zero-confidence oracle at the cap.
///      Carry/coupon are zero to isolate VPI; execution fees, lifetime clamps, and release risk limits remain active.
///      This reproduces the accounting path, not the report's real-Pyth fork or its confidence-spread amounts.
contract VpiDepthCollapseOwnershipTest is BasePerpTest {

    address internal constant VICTIM = address(0xB0B);
    address internal constant ATTACKER = address(0xA11CE);
    address internal constant SKEW_TRADER = address(0xA11CF);
    address internal constant OFFSET_TRADER = address(0xA11D0);
    uint256 internal constant VICTIM_CAPITAL = 1_000_000e6;
    uint256 internal constant DEEP_CAPITAL = 9_000_000e6;
    uint256 internal constant TRADER_CAPITAL = 200_000e6;
    uint256 internal constant SHORT_SIZE = 2_000_000e18;

    struct CaseState {
        uint256 depositId;
        uint256 principalBeforeRebate;
        uint256 supplyBeforeDeposit;
        uint256 cashBeforeRebate;
        uint256 rebate;
        uint256 dipShares;
        uint256 victimOut;
        uint256 attackerOut;
        int256 shortVpi;
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.vpiFactor = 0.01e18;
        params.initMarginBps = 20;
        params.maintMarginBps = 10;
        params.baseCarryBps = 0;
    }

    function setUp() public override {
        super.setUp();
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 0;
        config.maxSeniorExposureAssets = 40_000_000e6;
        config.maxSeniorShareBps = 8000;
        pool.proposePoolConfig(config);
        vm.warp(pool.poolConfigActivationTime());
        router.updateMarkPrice(_mockPythUpdateData(CAP_PRICE));
        pool.finalizePoolConfig();
    }

    function test_DepthCollapse_PrequeuedLargeDepositCannotCaptureAmplifiedRebate() public {
        _assertDepthCollapse(10_000_000e6, 400_000e18);
    }

    function test_DepthCollapse_HalfOwnershipCannotCaptureAmplifiedRebate() public {
        _assertDepthCollapse(1_000_000e6, 400_000e18);
    }

    function testFuzz_DepthCollapse_ReserveRecoveryPreservesLpOwnership(
        uint256 depositSeed,
        uint256 sizeSeed
    ) public {
        _assertDepthCollapse(bound(depositSeed, 1_000_000e6, 10_000_000e6), bound(sizeSeed, 3500, 4200) * 100e18);
    }

    function _assertDepthCollapse(
        uint256 dipCapital,
        uint256 offsetSize
    ) private {
        CaseState memory c;
        _deposit(VICTIM, VICTIM_CAPITAL);
        _deposit(ATTACKER, DEEP_CAPITAL);
        _fundTrader(SKEW_TRADER, TRADER_CAPITAL);
        _fundTrader(OFFSET_TRADER, TRADER_CAPITAL);
        assertEq(engine.executionFeeBps(), 4, "release execution fee stays active");
        _trade(SKEW_TRADER, CfdTypes.Side.SHORT, SHORT_SIZE, false);
        {
            (uint256 shortSize,, uint256 entry, uint256 maxProfit,,, int256 shortVpi) = engine.positions(SKEW_TRADER);
            c.shortVpi = shortVpi;
            assertEq(shortSize, SHORT_SIZE);
            assertEq(entry, CAP_PRICE, "cap short is essential to the zero-liability withdrawal path");
            assertEq(maxProfit, 0);
        }
        assertGt(c.shortVpi, 0);

        vm.warp(juniorVault.lastDepositTime(ATTACKER) + juniorVault.DEPOSIT_COOLDOWN());
        _redeemAll(ATTACKER);
        assertEq(engine.terminalNavSnapshot().terminalLpPriceDeltaAssets, 0);
        assertLt(pool.totalAssets(), 1_100_000e6, "the original deep LP must actually withdraw");
        assertGt(SHORT_SIZE * CAP_PRICE / 1e20, pool.totalAssets() * 40 / 100, "skew must exceed the reduced-depth cap");

        // Escrow the next deposit before the negative-VPI open, as in the reported attack.
        c.depositId = _requestDeposit(ATTACKER, dipCapital);
        (, c.principalBeforeRebate,,) = pool.getPendingTrancheState();
        c.supplyBeforeDeposit = juniorVault.totalSupply();
        c.cashBeforeRebate = pool.totalAssets();
        _trade(OFFSET_TRADER, CfdTypes.Side.LONG, offsetSize, false);
        {
            (,,,,,, int256 offsetVpi) = engine.positions(OFFSET_TRADER);
            assertLt(offsetVpi, 0, "the recovery open must remain allowed");
            c.rebate = uint256(-offsetVpi);
        }
        assertGt(c.rebate, uint256(c.shortVpi), "depth collapse must amplify rebate beyond original VPI paid");
        assertLt(pool.totalAssets(), c.cashBeforeRebate, "rebate must leave physical pool cash");
        assertEq(clearinghouse.vpiRebateReserveAssets(OFFSET_TRADER), c.rebate, "full receivable must be backed");
        assertEq(engine.totalNegativeVpiAccruedAssets(), c.rebate);
        assertEq(engine.terminalNavSnapshot().terminalLpPriceDeltaAssets, 0, "exclude a price-receivable explanation");
        {
            (, uint256 pendingJunior,,) = pool.getPendingTrancheState();
            assertGe(
                pendingJunior, c.principalBeforeRebate, "locked negative VPI must not write down existing principal"
            );
        }

        vm.warp(pool.lpEpochStart(c.depositId));
        router.settleLpEpoch(_mockPythUpdateData(CAP_PRICE));
        assertEq(juniorVault.claimableDepositRequest(c.depositId, ATTACKER), dipCapital);
        vm.prank(ATTACKER);
        c.dipShares = juniorVault.claimDeposit(c.depositId, dipCapital, ATTACKER, ATTACKER);
        assertGe(pool.juniorPrincipal() - dipCapital, c.principalBeforeRebate, "activation must retain old LP equity");
        // Only ordinary fee revenue can change the old book between these observations. The amplified reserve
        // must not award extra shares relative to the independently observed pre-rebate principal and supply.
        assertLe(
            c.dipShares,
            dipCapital * (c.supplyBeforeDeposit + 1000) / (c.principalBeforeRebate + 1),
            "prequeued entry must not buy the reserve recovery at a discount"
        );

        uint256 cashBeforeClose = pool.totalAssets();
        (, uint256 principalBeforeClose,,) = pool.getPendingTrancheState();
        _trade(OFFSET_TRADER, CfdTypes.Side.LONG, offsetSize, true);
        assertEq(clearinghouse.vpiRebateReserveAssets(OFFSET_TRADER), 0);
        assertEq(engine.totalNegativeVpiAccruedAssets(), 0);
        assertEq(engine.totalPositiveVpiAccruedAssets(), uint256(c.shortVpi));
        assertGe(pool.totalAssets(), cashBeforeClose + c.rebate, "close must recover the entire backing");
        (, uint256 principalAfterClose,,) = pool.getPendingTrancheState();
        assertLe(
            principalAfterClose - principalBeforeClose,
            offsetSize * CAP_PRICE / 1e20 * engine.executionFeeBps() / 10_000,
            "collection of a receivable must not create rebate-sized revenue"
        );

        vm.warp(juniorVault.lastDepositTime(ATTACKER) + juniorVault.DEPOSIT_COOLDOWN());
        c.victimOut = _redeemAll(VICTIM);
        _redeemAll(ATTACKER);
        assertGe(c.victimOut, VICTIM_CAPITAL, "victim must recover principal in actual cash");
        c.attackerOut = settlementToken.balanceOf(ATTACKER) + settlementToken.balanceOf(SKEW_TRADER)
            + settlementToken.balanceOf(OFFSET_TRADER) + clearinghouse.balanceAssets(SKEW_TRADER)
            + clearinghouse.balanceAssets(OFFSET_TRADER);
        assertLe(
            c.attackerOut, DEEP_CAPITAL + dipCapital + 2 * TRADER_CAPITAL, "all controlled wallets must not profit"
        );
        assertEq(engine.traderClaimBalanceAssets(SKEW_TRADER), 0);
        assertEq(engine.traderClaimBalanceAssets(OFFSET_TRADER), 0);
        assertEq(engine.terminalNavSnapshot().terminalLpPriceDeltaAssets, 0);
        (uint256 shortSize,, uint256 entry, uint256 maxProfit,,,) = engine.positions(SKEW_TRADER);
        assertEq(shortSize, SHORT_SIZE, "original cap short stays open, as in the report");
        assertEq(entry, CAP_PRICE);
        assertEq(maxProfit, 0);
    }

    function _deposit(
        address owner,
        uint256 assets
    ) private {
        uint256 id = _requestDeposit(owner, assets);
        vm.warp(pool.lpEpochStart(id));
        router.settleLpEpoch(_mockPythUpdateData(CAP_PRICE));
        vm.prank(owner);
        assertGt(juniorVault.claimDeposit(id, assets, owner, owner), 0);
    }

    function _requestDeposit(
        address owner,
        uint256 assets
    ) private returns (uint256 id) {
        settlementToken.mint(owner, assets);
        vm.startPrank(owner);
        settlementToken.approve(address(juniorVault), assets);
        id = juniorVault.requestDeposit(assets, owner, owner);
        vm.stopPrank();
    }

    function _redeemAll(
        address owner
    ) private returns (uint256 assets) {
        uint256 shares = juniorVault.maxRequestRedeem(owner);
        assertEq(shares, juniorVault.balanceOf(owner));
        assertGt(shares, 0);
        vm.prank(owner);
        uint256 id = juniorVault.requestRedeem(shares, owner, owner);
        vm.warp(pool.lpEpochStart(id));
        router.settleLpEpoch(_mockPythUpdateData(CAP_PRICE));
        assertEq(juniorVault.claimableRedeemRequest(id, owner), shares, "all ownership must exit for cash");
        vm.prank(owner);
        assets = juniorVault.claimRedeem(id, shares, owner, owner);
        assertEq(juniorVault.balanceOf(owner), 0);
        assertEq(juniorVault.pendingRedeemRequest(id, owner), 0);
        assertEq(juniorVault.claimableRedeemAssets(id, owner), 0);
    }

    function _trade(
        address trader,
        CfdTypes.Side side,
        uint256 size,
        bool close
    ) private {
        vm.prank(trader);
        uint64 id = router.commitOrder(side, size, close ? 0 : 100_000e6, 0, close);
        router.executeOrder(id, _mockPythUpdateData(CAP_PRICE));
        (uint256 liveSize,,,,,,) = engine.positions(trader);
        assertEq(liveSize, close ? 0 : size, "public order must execute");
    }

}
