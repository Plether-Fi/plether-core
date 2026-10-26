// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

import {HousePoolAsyncTestBase} from "../../shared/HousePoolTestBase.sol";

contract HousePoolUnseededBootstrapTest is HousePoolAsyncTestBase {

    address alice = address(0x111);
    address bob = address(0x222);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _mintAndAccountPoolExcess(
        uint256 amount
    ) internal {
        usdc.mint(address(pool), amount);
        pool.accountExcess();
    }

    function _enterFrozenWindow() internal {
        uint256 saturdayFrozen = 1_710_021_600;
        vm.warp(saturdayFrozen - 12 hours);
        assertTrue(engine.isOracleFrozen(), "setup should enter a frozen-oracle window");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(saturdayFrozen - 12 hours));

        vm.warp(saturdayFrozen);
    }

    function test_InitializeSeedPosition_RevertsWhenOracleFrozen() public {
        uint256 seedAssets = 50_000e6;
        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);

        _enterFrozenWindow();

        vm.expectRevert(IHousePool.HousePool__OracleFrozen.selector);
        pool.initializeSeedPosition(true, seedAssets, address(this));
    }

    function test_EmptyTerminalBookWithoutMark_AllowsSeedBootstrap() public {
        assertEq(engine.lastMarkTime(), 0, "setup must not manufacture a mark");
        ICfdEngineTypes.TerminalNavSnapshot memory terminalSnapshot = engine.terminalNavSnapshot();
        assertFalse(terminalSnapshot.hasOpenPositions, "empty book must report no exposure");
        assertEq(terminalSnapshot.terminalLpPriceDeltaUsdc, 0, "empty terminal delta must be zero");

        uint256 seedAssets = 1000e6;
        assertGt(juniorVault.estimateDepositShares(seedAssets), 0, "an empty unseeded tranche is not wiped");
        assertGt(seniorVault.estimateDepositShares(seedAssets), 0, "an empty unseeded tranche is not wiped");
        usdc.mint(address(this), seedAssets * 2);
        usdc.approve(address(pool), seedAssets * 2);
        pool.initializeSeedPosition(false, seedAssets, address(this));
        pool.initializeSeedPosition(true, seedAssets, address(this));

        assertTrue(pool.isSeedLifecycleComplete(), "missing mark must not block empty-book seed bootstrap");
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function test_AssignUnassignedAssets_MintsMatchingSharesToReceiver() public {
        usdc.mint(address(pool), 100_000e6);
        pool.accountExcess();
        vm.prank(address(juniorVault));
        pool.reconcile();
        uint256 supplyBefore = juniorVault.totalSupply();
        uint256 receiverSharesBefore = juniorVault.balanceOf(alice);
        pool.assignUnassignedAssets(false, alice);
        uint256 mintedShares = juniorVault.balanceOf(alice) - receiverSharesBefore;
        assertGt(mintedShares, 0);
        assertEq(juniorVault.totalSupply(), supplyBefore + mintedShares);
        assertEq(pool.unassignedAssets(), 0);
    }

    function test_InitializeSeedPosition_MintsPermanentSeedShares() public {
        uint256 assets = 100_000e6;
        address seed = address(0xBEEF);
        usdc.mint(address(this), assets);
        usdc.approve(address(pool), assets);
        pool.initializeSeedPosition(false, assets, seed);
        assertEq(juniorVault.seedReceiver(), seed);
        assertGt(juniorVault.seedShareFloor(), 0);
        assertEq(juniorVault.balanceOf(seed), juniorVault.seedShareFloor());
    }

    function test_JuniorRedeemRequest_RequiresOwnSeedBeforeTradingActivation() public {
        _assertRedeemRequestRequiresOwnSeed(false);
    }

    function test_SeniorRedeemRequest_RequiresOwnSeedBeforeTradingActivation() public {
        _assertRedeemRequestRequiresOwnSeed(true);
    }

    function _assertRedeemRequestRequiresOwnSeed(
        bool isSenior
    ) internal {
        // Quarantine assets before any shares exist, then exercise owner-controlled assignment.
        _mintAndAccountPoolExcess(1000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();
        if (isSenior) {
            // Senior assignment needs Junior backing; that seed must not unlock the unseeded Senior vault.
            usdc.mint(address(this), 1000e6);
            usdc.approve(address(pool), 1000e6);
            pool.initializeSeedPosition(false, 1000e6, address(this));
        }
        pool.assignUnassignedAssets(isSenior, alice);

        TrancheVault vault = isSenior ? seniorVault : juniorVault;
        uint256 shares = vault.balanceOf(alice);
        assertGt(shares, 0);
        _finishAsyncCooldown(vault, alice);
        vm.prank(alice);
        vault.approve(bob, shares);

        bytes memory rejection =
            abi.encodeWithSelector(TrancheVault.TrancheVault__ExceededMaxRequestRedeem.selector, alice, shares, 0);
        vm.expectRevert(rejection);
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);
        vm.expectRevert(rejection);
        vm.prank(bob);
        vault.requestRedeem(shares, alice, alice);

        assertEq(vault.maxRequestRedeem(alice), 0);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.allowance(alice, bob), shares);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.pendingRedeemEscrowShares(), 0);
        assertEq(vault.redeemQueueHead(), 0);
        assertEq(vault.controllerRedeemHead(alice), 0);

        usdc.mint(address(this), 1e6);
        usdc.approve(address(pool), 1e6);
        pool.initializeSeedPosition(isSenior, 1e6, address(this));
        assertEq(pool.isSeedLifecycleComplete(), isSenior, "Junior requests must not require a Senior seed");
        assertFalse(pool.isTradingActive());
        assertEq(vault.maxRequestRedeem(alice), shares);

        vm.prank(bob);
        uint256 requestId = vault.requestRedeem(shares, alice, alice);
        assertEq(vault.pendingRedeemRequest(requestId, alice), shares);
        assertEq(vault.pendingRedeemEscrowShares(), shares);
        assertEq(vault.balanceOf(address(vault)), shares);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.allowance(alice, bob), 0);
    }

    function test_InitializeJuniorSeed_QuarantinesPreviouslyAccountedExcess() public {
        uint256 excess = 100_000e6;
        uint256 seedAssets = 10_000e6;
        usdc.mint(address(this), excess + seedAssets);
        usdc.transfer(address(pool), excess);
        pool.accountExcess();
        assertEq(pool.unassignedAssets(), 0, "excess has not yet been reconciled");
        assertEq(juniorVault.totalSupply(), 0, "junior has no owners before seeding");

        usdc.approve(address(pool), seedAssets);
        pool.initializeSeedPosition(false, seedAssets, alice);

        assertEq(pool.accountedAssets(), excess + seedAssets);
        assertEq(pool.unassignedAssets(), excess, "pre-seed excess must remain ownerless");
        assertEq(pool.juniorPrincipal(), seedAssets, "only the seed deposit belongs to junior");
        assertEq(juniorVault.totalAssets(), seedAssets);
        assertGt(juniorVault.seedShareFloor(), 0);
        assertEq(juniorVault.balanceOf(alice), juniorVault.seedShareFloor());

        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.unassignedAssets(), excess, "later reconciliation must preserve the quarantine");
        assertEq(pool.juniorPrincipal(), seedAssets);
        assertEq(juniorVault.totalAssets(), seedAssets);
    }

    function test_SeedReceiverCannotRedeemBelowFloor() public {
        uint256 assets = 100_000e6;
        address seed = address(0xBEEF);
        usdc.mint(address(this), assets);
        usdc.approve(address(pool), assets);
        pool.initializeSeedPosition(false, assets, seed);
        vm.warp(block.timestamp + juniorVault.DEPOSIT_COOLDOWN() + 1);
        vm.startPrank(seed);
        vm.expectRevert(TrancheVault.TrancheVault__SeedFloorBreached.selector);
        juniorVault.transfer(alice, 1);
        vm.stopPrank();
    }

    function test_SeedReceiverMaxViews_ExcludeLockedFloor() public {
        uint256 assets = 100_000e6;
        address seed = address(0xBEEF);
        usdc.mint(address(this), assets);
        usdc.approve(address(pool), assets);
        pool.initializeSeedPosition(false, assets, seed);
        vm.warp(block.timestamp + juniorVault.DEPOSIT_COOLDOWN() + 1);
        assertEq(juniorVault.maxRequestRedeem(seed), 0);
    }

    function test_WipedSeededTranche_IsTerminallyNonDepositable() public {
        uint256 seedAssets = 100_000e6;
        address seed = address(0xBEEF);
        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);
        pool.initializeSeedPosition(false, seedAssets, seed);
        usdc.mint(address(this), 1e6);
        usdc.approve(address(pool), 1e6);
        pool.initializeSeedPosition(true, 1e6, address(this));
        pool.activateTrading();
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertGt(juniorVault.totalSupply(), 0);
        assertEq(juniorVault.totalAssets(), 0);
        assertEq(juniorVault.maxRequestDeposit(alice), 0);
        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(juniorVault), 1e6);
        vm.expectRevert(TrancheVault.TrancheVault__TerminallyWiped.selector);
        juniorVault.requestDeposit(1e6, alice, alice);
        vm.stopPrank();
    }

    function test_SeededJuniorRevenueStaysOwnedAfterLastUserExits() public {
        uint256 seedAssets = 100_000e6;
        address seed = address(0xBEEF);
        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);
        pool.initializeSeedPosition(false, seedAssets, seed);
        usdc.mint(address(this), 1e6);
        usdc.approve(address(pool), 1e6);
        pool.initializeSeedPosition(true, 1e6, address(this));
        pool.activateTrading();
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 100_000e6);
        _finishAsyncCooldown(juniorVault, bob);
        _redeemAsync(juniorVault, bob, juniorVault.balanceOf(bob), true);
        uint256 unassignedBefore = pool.unassignedAssets();
        _mintAndAccountPoolExcess(50_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.unassignedAssets(), unassignedBefore);
        assertGt(pool.juniorPrincipal(), seedAssets);
    }

    function test_RecordRecapitalizationInflow_RestoresSeededSeniorBeforeFallbackAccounting() public {
        uint256 seniorSeedAssets = 100_000e6;
        uint256 juniorSeedAssets = 100_000e6;
        usdc.mint(address(this), seniorSeedAssets + juniorSeedAssets);
        usdc.approve(address(pool), seniorSeedAssets + juniorSeedAssets);
        pool.initializeSeedPosition(false, juniorSeedAssets, address(this));
        pool.initializeSeedPosition(true, seniorSeedAssets, address(this));
        vm.prank(address(pool));
        usdc.transfer(address(0xdead), juniorSeedAssets + 40_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 60_000e6);
        usdc.mint(address(pool), 25_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            25_000e6, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        (uint256 pendingSenior,,,) = pool.getPendingTrancheState();
        assertEq(pendingSenior, 85_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 85_000e6);
        assertEq(pool.unassignedAssets(), 0);
    }

    function test_RecordRecapitalizationInflow_SeedsSeniorWhenNoPrincipalButSeedSharesExist() public {
        uint256 seedAssets = 50_000e6;
        usdc.mint(address(this), 2 * seedAssets);
        usdc.approve(address(pool), 2 * seedAssets);
        pool.initializeSeedPosition(false, seedAssets, address(this));
        pool.initializeSeedPosition(true, seedAssets, address(this));
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 0);
        assertGt(seniorVault.totalSupply(), 0);
        usdc.mint(address(pool), 10_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            10_000e6, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        (uint256 pendingSenior,,, uint256 maxJuniorWithdraw) = pool.getPendingTrancheState();
        assertEq(pendingSenior, 10_000e6);
        assertEq(maxJuniorWithdraw, 0);
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 10_000e6);
        assertEq(pool.seniorHighWaterMark(), 10_000e6);
    }

    function test_GetPendingTrancheState_ProjectedRecapitalizationDoesNotDoubleReserveCreditedSeniorAssets() public {
        uint256 seedAssets = 50_000e6;
        usdc.mint(address(this), 2 * seedAssets);
        usdc.approve(address(pool), 2 * seedAssets);
        pool.initializeSeedPosition(false, seedAssets, address(this));
        pool.initializeSeedPosition(true, seedAssets, address(this));
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();
        usdc.mint(address(pool), 10_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            10_000e6, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        (uint256 pendingSenior,, uint256 maxSeniorWithdraw,) = pool.getPendingTrancheState();
        assertEq(pendingSenior, 10_000e6);
        assertEq(maxSeniorWithdraw, 10_000e6);
    }

    function test_RecordRecapitalizationInflow_NoClaimantPathFallsBackToUnassignedAssets() public {
        usdc.mint(address(pool), 10_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            10_000e6, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 0);
        assertEq(pool.unassignedAssets(), 10_000e6);
    }

    function test_RecordTradingRevenueInflow_AttachesToSeededJuniorWhenNoLivePrincipalExists() public {
        uint256 seedAssets = 20_000e6;
        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);
        pool.initializeSeedPosition(false, seedAssets, address(this));
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.juniorPrincipal(), 0);
        assertGt(juniorVault.totalSupply(), 0);
        usdc.mint(address(pool), 7000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            7000e6, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        (, uint256 pendingJunior,,) = pool.getPendingTrancheState();
        assertEq(pendingJunior, 7000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.juniorPrincipal(), 7000e6);
        assertEq(pool.unassignedAssets(), 0);
    }

    function test_OpenExecutionFee_DoesNotDoubleCountIntoSeededTradingRevenueAfterWipeout() public {
        uint256 juniorSeedAssets = 20_000e6;
        uint256 seniorSeedAssets = 1000e6;
        usdc.mint(address(this), juniorSeedAssets + seniorSeedAssets);
        usdc.approve(address(pool), juniorSeedAssets + seniorSeedAssets);
        pool.initializeSeedPosition(false, juniorSeedAssets, address(this));
        pool.initializeSeedPosition(true, seniorSeedAssets, address(this));
        pool.activateTrading();
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 0);
        assertEq(pool.juniorPrincipal(), 0);
        assertGt(juniorVault.totalSupply(), 0);

        usdc.mint(address(pool), 1_000_000e6);
        pool.accountExcess();
        (, uint256 pendingJuniorBefore,,) = pool.getPendingTrancheState();

        address trader = address(0xAB1717);
        _fundTrader(trader, 50_000e6);
        router.updateMarkPrice(_mockPythUpdateData());

        uint256 assetsBefore = pool.totalAssets();
        uint256 feesBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());

        uint64 orderId = router.nextCommitId();
        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8, false);
        router.executeOrder(orderId, _mockPythUpdateData());

        uint256 assetsDelta = pool.totalAssets() - assetsBefore;
        uint256 feesDelta = clearinghouse.balanceUsdc(engine.protocolTreasury()) - feesBefore;
        (, uint256 pendingJunior,,) = pool.getPendingTrancheState();
        uint256 expectedLpTradingRevenue = assetsDelta > feesDelta ? assetsDelta - feesDelta : 0;
        uint256 pendingJuniorDelta = pendingJunior > pendingJuniorBefore ? pendingJunior - pendingJuniorBefore : 0;

        assertEq(feesDelta, 40_000_000, "Open should still accrue the full execution fee as protocol revenue");
        assertEq(pool.excessAssets(), 0, "Execution fee inflow should be canonically accounted, not stranded as excess");
        assertEq(
            pendingJuniorDelta,
            expectedLpTradingRevenue,
            "Seeded pending LP revenue should exclude the execution fee portion"
        );

        uint256 juniorBeforeFeeWithdrawal = pool.juniorPrincipal();
        address feeRecipient = engine.protocolTreasury();
        uint256 recipientBalanceBefore = usdc.balanceOf(feeRecipient);
        _withdrawProtocolTreasury(feesDelta);
        assertEq(
            usdc.balanceOf(feeRecipient) - recipientBalanceBefore,
            feesDelta,
            "Treasury should withdraw protocol fee margin"
        );
        assertEq(
            pool.juniorPrincipal(), juniorBeforeFeeWithdrawal, "Fee withdrawal should not drain seeded LP principal"
        );
    }

    function test_LiquidationKeeperBounty_DoesNotDoubleCountIntoSeededTradingRevenueAfterWipeout() public {
        uint256 juniorSeedAssets = 20_000e6;
        uint256 seniorSeedAssets = 1000e6;
        usdc.mint(address(this), juniorSeedAssets + seniorSeedAssets);
        usdc.approve(address(pool), juniorSeedAssets + seniorSeedAssets);
        pool.initializeSeedPosition(false, juniorSeedAssets, address(this));
        pool.initializeSeedPosition(true, seniorSeedAssets, address(this));
        pool.activateTrading();
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();

        usdc.mint(address(pool), 1_000_000e6);
        pool.accountExcess();
        {
            (uint256 pendingSeniorBefore, uint256 pendingJuniorBefore,,) = pool.getPendingTrancheState();
            assertEq(pendingSeniorBefore, seniorSeedAssets, "Admitted cash restores the seeded Senior claim");
            assertEq(pendingJuniorBefore, 1_000_000e6 - seniorSeedAssets, "Junior owns the remaining admitted cash");
        }

        // Independent fixture ledger: $10,000 entry notional, 4-bps open fee, 10-bps reserved charge,
        // and a 50% keeper share. The $5,000 raw price loss exceeds the remaining $236 pledge.
        uint256 expectedOpenFee = (10_000e6 * 4) / 10_000;
        uint256 expectedCharge = (10_000e6 * 10) / 10_000;
        uint256 expectedPriceRecovery = 250e6 - expectedOpenFee - expectedCharge;
        uint256 expectedKeeperCredit = expectedCharge / 2;
        uint256 expectedPoolRevenue = expectedPriceRecovery + expectedCharge - expectedKeeperCredit;

        address trader = address(0xAB1719);
        _fundTrader(trader, 900e6);
        _open(trader, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);
        assertEq(clearinghouse.pnlPledgeUsdc(trader), expectedPriceRecovery, "Open isolates the $236 price pledge");
        assertEq(clearinghouse.liquidationReserveUsdc(trader), expectedCharge, "Charge is capped by the $10 reserve");
        assertEq(clearinghouse.balanceUsdc(engine.protocolTreasury()), expectedOpenFee, "Open credits the $4 fee once");
        assertEq(clearinghouse.balanceUsdc(address(this)), 0, "Keeper starts without a clearinghouse entitlement");
        assertEq(pool.totalAssets(), 1_000_000e6, "The clearinghouse execution fee is not pool cash");

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(150_000_000));
        _ensureLaterOracleTime();
        router.executeLiquidation(trader, priceData);

        assertEq(clearinghouse.balanceUsdc(address(this)), expectedKeeperCredit, "Only $5 belongs to the keeper");
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()), expectedOpenFee, "Liquidation adds no protocol fee"
        );
        assertEq(clearinghouse.balanceUsdc(trader), 900e6 - 250e6, "Liquidation preserves the $650 free settlement");
        assertEq(clearinghouse.pnlPledgeUsdc(trader), 0, "The bounded price pledge was fully recovered");
        assertEq(clearinghouse.liquidationReserveUsdc(trader), 0, "The liquidation charge was fully allocated");
        assertEq(pool.totalAssets(), 1_000_000e6 + expectedPoolRevenue, "Pool owns $236 recovery plus its $5 charge");
        assertEq(usdc.balanceOf(address(pool)), 1_000_000e6 + expectedPoolRevenue, "Accounted LP revenue is real cash");
        assertEq(usdc.balanceOf(address(clearinghouse)), 900e6 - expectedPoolRevenue, "Custody conserves the deposit");
        {
            (uint256 pendingSenior, uint256 pendingJunior,,) = pool.getPendingTrancheState();
            assertEq(pendingSenior, seniorSeedAssets, "Senior restoration is not counted twice");
            assertEq(
                pendingJunior,
                1_000_000e6 - seniorSeedAssets + expectedPoolRevenue,
                "Junior receives valid recovery and its charge share, excluding the keeper portion"
            );
        }
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), seniorSeedAssets, "Live Senior agrees with the pending allocation");
        assertEq(
            pool.juniorPrincipal(), 1_000_000e6 - seniorSeedAssets + expectedPoolRevenue, "Live Junior retains $241"
        );
        assertEq(pool.pendingTradingRevenueUsdc(), 0, "Revenue routing consumes the pending bucket exactly once");
        assertEq(pool.unassignedAssets(), 0, "Seeded claimant revenue must not be stranded as unassigned cash");
        assertEq(pool.excessAssets(), 0, "LP inflow is canonically accounted, not stranded as excess");
    }

    function test_RecordTradingRevenueInflow_NoClaimantPathFallsBackToUnassignedAssets() public {
        usdc.mint(address(pool), 7000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            7000e6, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 0);
        assertEq(pool.juniorPrincipal(), 0);
        assertEq(pool.unassignedAssets(), 7000e6);
    }

    function test_RecordTradingRevenueInflow_RestoresSeededSeniorBeforeJuniorWhenBothAreZero() public {
        usdc.mint(address(this), 30_000e6);
        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(pool), 40_000e6);
        pool.initializeSeedPosition(false, 10_000e6, address(this));
        pool.initializeSeedPosition(true, 30_000e6, address(this));
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();
        usdc.mint(address(pool), 35_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            35_000e6, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        (uint256 pendingSenior, uint256 pendingJunior,,) = pool.getPendingTrancheState();
        assertEq(pendingSenior, 30_000e6);
        assertEq(pendingJunior, 5000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 30_000e6);
        assertEq(pool.juniorPrincipal(), 5000e6);
        assertEq(pool.unassignedAssets(), 0);
    }

    function test_UnassignedAssets_AreReservedFromWithdrawalLiquidity() public {
        _mintAndAccountPoolExcess(100_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();
        (,, uint256 maxSeniorWithdraw, uint256 maxJuniorWithdraw) = pool.getPendingTrancheState();
        assertEq(pool.unassignedAssets(), 100_000e6);
        assertEq(pool.getFreeUSDC(), 0);
        assertEq(pool.getMaxSeniorWithdraw(), 0);
        assertEq(pool.getMaxJuniorWithdraw(), 0);
        assertEq(maxSeniorWithdraw, 0);
        assertEq(maxJuniorWithdraw, 0);
        assertTrue(pool.isWithdrawalLive());
    }

    function test_UnassignedAssets_DoNotTrapExistingSeniorWithdrawals() public {
        usdc.mint(address(this), 2000e6);
        usdc.approve(address(pool), 2000e6);
        pool.initializeSeedPosition(false, 1000e6, address(this));
        pool.initializeSeedPosition(true, 1000e6, address(this));
        pool.activateTrading();
        _fundSenior(alice, 100_000e6);
        usdc.mint(address(pool), 10_000e6);
        pool.accountExcess();
        vm.prank(address(juniorVault));
        pool.reconcile();
        _finishAsyncCooldown(seniorVault, alice);
        uint256 requestId = _requestAsyncRedeem(seniorVault, alice, seniorVault.maxRequestRedeem(alice));
        _settleAsyncRequest(requestId, true);
        uint256 quotedAssets = seniorVault.maxWithdraw(alice);
        assertEq(pool.unassignedAssets(), 0);
        assertGe(quotedAssets, 100_000e6);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        seniorVault.withdraw(quotedAssets, alice, alice);
        assertEq(usdc.balanceOf(alice), aliceBefore + quotedAssets);
    }

    function test_InitializeSeedPosition_CheckpointsSeniorCouponBeforePrincipalMutation() public {
        uint256 staleTime = block.timestamp + 30 days;
        usdc.mint(address(this), 200_000e6);
        usdc.approve(address(pool), 200_000e6);
        pool.initializeSeedPosition(false, 100_000e6, address(this));
        vm.warp(staleTime);
        pool.initializeSeedPosition(true, 100_000e6, address(this));
        assertEq(pool.lastSeniorCouponCheckpointTime(), block.timestamp);
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 100_000e6);
    }

    function test_AssignUnassignedAssets_ReconcilesBeforeBootstrappingAndAvoidsPhantomAssets() public {
        usdc.mint(address(pool), 100_000e6);
        pool.accountExcess();
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.unassignedAssets(), 100_000e6);
        address trader = address(0x99992);
        address traderAccount = trader;
        _fundTrader(trader, 50_000e6);
        _open(traderAccount, CfdTypes.Side.SHORT, 99_700e18, 10_000e6, 1e8);
        _ensureLaterOracleTime();
        vm.prank(address(router));
        engine.updateMarkPrice(1.2e8, uint64(vm.getBlockTimestamp()));
        pool.assignUnassignedAssets(false, alice);
        assertLt(pool.juniorPrincipal(), 100_000e6);
        assertEq(pool.unassignedAssets(), 0);
    }

    function test_RecordImplicitTradingRevenue_RestoresSeededSeniorBeforeJuniorWhenBothAreZero() public {
        usdc.mint(address(this), 30_000e6);
        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(pool), 40_000e6);
        pool.initializeSeedPosition(false, 10_000e6, address(this));
        pool.initializeSeedPosition(true, 30_000e6, address(this));
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();

        usdc.mint(address(pool), 35_000e6);
        uint256 accountedBefore = pool.accountedAssets();
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            35_000e6, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.AlreadyRetained
        );

        assertEq(
            pool.accountedAssets(), accountedBefore, "Implicit retained revenue must not increment accounted assets"
        );

        (uint256 pendingSenior, uint256 pendingJunior,,) = pool.getPendingTrancheState();
        assertEq(pendingSenior, 30_000e6, "Pending state should restore seeded senior to its HWM first");
        assertEq(pendingJunior, 5000e6, "Pending state should route residual retained carry to seeded junior");

        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 30_000e6, "Implicit retained revenue should restore seeded senior first");
        assertEq(pool.juniorPrincipal(), 5000e6, "Residual implicit retained revenue should attach to seeded junior");
        assertEq(pool.unassignedAssets(), 0, "Seeded implicit retained revenue should avoid quarantine");
    }

}
