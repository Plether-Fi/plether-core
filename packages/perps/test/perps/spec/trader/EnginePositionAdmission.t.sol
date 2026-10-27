// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {CfdEnginePlanLibHarness, CfdEngineTestBase} from "../../shared/CfdEngineTestBase.sol";

contract EnginePositionAdmissionTest is CfdEngineTestBase {

    using stdStorage for StdStorage;

    function test_OpenPosition_SolvencyCheck() public {
        address account = address(uint160(1));
        _fundTrader(account, 20_000 * 1e6);

        // At the $1M skew cap, $20k supplied margin covers the $15k IMR after all costs.
        // The 25-bps buffer requires $1,002,500, but $1,002,000 cash plus $250 VPI is $250 short.
        assertEq(pool.totalAssets(), 1_002_000e6, "Include both seed tranches in available cash");
        assertEq(engine.settlementBufferBps(), 25, "Fixture uses the default protected buffer");
        CfdTypes.Order memory bufferShortfall = CfdTypes.Order({
            account: account,
            sizeDelta: 1_000_000 * 1e18,
            marginDelta: 20_000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });

        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector, 2, 7, false));
        vm.prank(address(router));
        engine.processOrderTyped(bufferShortfall, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));

        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 2000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.SHORT,
            isClose: false
        });

        // Withdrawal leaves about $52k including seeds. At $0.50, the order's $50k skew fits the actual
        // depth, but its $150k maximum Short profit exceeds cash. Its $2k margin also comfortably covers IMR.
        vm.warp(block.timestamp + 1 hours); // past deposit cooldown
        uint256 withdrawnAssets = _settleJuniorWithdrawal(address(this), 950_000 * 1e6);
        uint256 remainingDepth = pool.totalAssets();
        assertGe(remainingDepth, 50_000e6, "The failing order must remain within the supported skew cap");
        assertLt(remainingDepth, 150_000e6, "The failure must expose a genuine cash shortfall");
        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector, 2, 7, false));
        vm.prank(address(router));
        engine.processOrderTyped(order, 0.5e8, remainingDepth, uint64(block.timestamp));

        // Re-deposit to allow the trade
        settlementToken.approve(address(juniorVault), withdrawnAssets);
        _settleJuniorDepositFromBalance(address(this), withdrawnAssets);

        vm.prank(address(router));
        engine.processOrderTyped(order, 1e8, 200_000 * 1e6, uint64(block.timestamp));

        (uint256 size, uint256 margin,,,,,) = engine.positions(account);
        assertEq(size, 100_000 * 1e18, "Size mismatch");
        assertEq(margin, 1_847_500_000, "PnL pledge should exclude the dedicated liquidation reserve");
        assertEq(
            clearinghouse.liquidationReserveAssets(account),
            100_000_000,
            "The entry-notional bounty target must be isolated in its dedicated reserve"
        );
        assertEq(
            margin + clearinghouse.liquidationReserveAssets(account),
            1_947_500_000,
            "PnL pledge plus liquidation reserve should conserve post-cost supplied collateral"
        );
    }

    function test_OpenPosition_UsesExplicitInitMarginBps() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.initMarginBps = 400;
        _setRiskParams(params);

        (,,, uint256 initMarginBps,,,,,,) = engine.riskParams();
        assertEq(initMarginBps, 400, "Setup must finalize the explicit init margin config");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        address account = address(uint160(0xBEEF1));
        _fundTrader(account, 10_000e6);

        assertEq(
            engineLens.previewOpenRevertCode(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8),
            uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN),
            "Planner should use the explicit init margin config"
        );
    }

    function test_ProcessOrderTyped_ProtocolStateFailureUsesTypedTaxonomy() public {
        address account = address(uint160(1));
        _fundTrader(account, 20_000 * 1e6);

        // The skew cap is exactly met and post-cost margin exceeds IMR, isolating the default 25-bps
        // buffer shortfall: $1,002,500 required versus $1,002,000 initial cash plus $250 VPI.
        CfdTypes.Order memory bufferShortfall = CfdTypes.Order({
            account: account,
            sizeDelta: 1_000_000 * 1e18,
            marginDelta: 20_000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated,
                uint8(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED),
                false
            )
        );
        vm.prank(address(router));
        engine.processOrderTyped(bufferShortfall, 1e8, 1_000_000 * 1e6, uint64(block.timestamp));
    }

    function test_OpenTradeCost_AccountsPoolInflowCanonically() public {
        address firstLongAccount = address(0xABC2);
        address secondLongAccount = address(0xABC3);
        _fundTrader(firstLongAccount, 100_000e6);
        _fundTrader(secondLongAccount, 100_000e6);

        _open(firstLongAccount, CfdTypes.Side.LONG, 500_000e18, 50_000e6, 1e8);

        uint256 poolAssetsBefore = pool.totalAssets();
        _open(secondLongAccount, CfdTypes.Side.LONG, 499_000e18, 50_000e6, 1e8);

        assertGt(pool.totalAssets(), poolAssetsBefore, "Positive trade cost should increase canonical pool assets");
        assertEq(pool.excessAssets(), 0, "Trade-cost inflows should not remain quarantined as excess");
    }

    function test_AddMargin_UpdatesPositionAndSideTotals() public {
        address trader = address(0xABCD);
        address account = trader;
        _fundTrader(trader, 10_000 * 1e6);

        _open(account, CfdTypes.Side.LONG, 100_000 * 1e18, 2000 * 1e6, 1e8);

        (, uint256 marginBefore,,,,,) = engine.positions(account);
        uint256 lockedBefore = clearinghouse.lockedMarginAssets(account);
        uint256 totalLongMarginBefore = _sideTotalMargin(CfdTypes.Side.LONG);

        vm.prank(trader);
        engine.addMargin(account, 500 * 1e6);

        (, uint256 marginAfter,,,,,) = engine.positions(account);
        assertEq(marginAfter, marginBefore + 500 * 1e6, "Position margin should increase by the added amount");
        assertEq(
            clearinghouse.lockedMarginAssets(account),
            lockedBefore + 500 * 1e6,
            "Clearinghouse locked margin should increase by the same amount"
        );
        assertEq(
            _sideTotalMargin(CfdTypes.Side.LONG),
            totalLongMarginBefore + 500 * 1e6,
            "Global long margin should track addMargin"
        );
    }

    function test_AddMargin_RequiresAccountOwner() public {
        address trader = address(0xABCE);
        address account = trader;
        _fundTrader(trader, 10_000 * 1e6);
        _open(account, CfdTypes.Side.LONG, 50_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(address(0xBEEF));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__NotAccountOwner.selector);
        engine.addMargin(account, 100 * 1e6);
    }

    function test_AddMargin_RevertsForZeroAmountAndMissingPosition() public {
        address trader = address(0xABCF);
        address account = trader;
        _fundTrader(trader, 10_000 * 1e6);

        vm.prank(trader);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__NoOpenPosition.selector);
        engine.addMargin(account, 100 * 1e6);

        _open(account, CfdTypes.Side.LONG, 50_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(trader);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__ZeroAmount.selector);
        engine.addMargin(account, 0);
    }

    function test_AddMargin_SucceedsOnStaleMark() public {
        address trader = address(0xABD3);
        address account = trader;
        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.LONG, 20_000e18, 2000e6, 1e8);

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);

        vm.prank(trader);
        engine.addMargin(account, 100e6);

        (, uint256 marginAfter,, uint256 maxProfitAssets,,,) = engine.positions(account);
        assertEq(
            _positionBorrowBaseAssets(account),
            PositionRiskAccountingLib.computeBorrowBaseAssets(maxProfitAssets, marginAfter),
            "stale-mark add-margin should reduce future borrow base"
        );
    }

    function test_PlanOpen_FundedNegativeVpiDoesNotDoubleCountAgainstImr() public {
        CfdEnginePlanLibHarness harness = new CfdEnginePlanLibHarness();

        CfdEnginePlanTypes.OpenDelta memory delta = harness.planOpenWithExistingVpiAccrued(
            CfdEnginePlanLibHarness.OpenWithExistingVpiParams({
                settlementBalanceAssets: 1900e6,
                positionMarginAssets: 1700e6,
                currentSize: 100_000e18,
                currentEntryPrice: 1e8,
                vpiAccrued: -1000e6,
                sizeDelta: 10_000e18,
                marginDelta: 200e6,
                price: 1e8
            })
        );

        assertTrue(delta.valid, "Fully backed legacy VPI must not be charged against open risk a second time");
        assertEq(uint8(delta.revertCode), uint8(CfdEnginePlanTypes.OpenRevertCode.OK));
        assertEq(delta.vpiRebateReserveBeforeAssets, 1000e6);
        assertEq(delta.vpiRebateReserveAfterAssets, 1000e6);
    }

    function test_OpposingPosition_Reverts() public {
        address account = address(uint160(1));
        _fundTrader(account, 10_000 * 1e6);

        CfdTypes.Order memory shortOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 5000 * 1e6,
            targetPrice: 0.8e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.SHORT,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(shortOrder, 0.8e8, 1_000_000 * 1e6, uint64(block.timestamp));

        CfdTypes.Order memory longOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 5000 * 1e6,
            targetPrice: 0.8e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector, 1, 1, false));
        vm.prank(address(router));
        engine.processOrderTyped(longOrder, 0.8e8, 1_000_000 * 1e6, uint64(block.timestamp));
    }

    function test_ProcessOrderTyped_UserInvalidFailureUsesTypedTaxonomy() public {
        address account = address(uint160(1));
        _fundTrader(account, 10_000 * 1e6);

        CfdTypes.Order memory shortOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 1000 * 1e6,
            targetPrice: 0.8e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.SHORT,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(shortOrder, 0.8e8, 1_000_000 * 1e6, uint64(block.timestamp));

        CfdTypes.Order memory longOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 1000 * 1e6,
            targetPrice: 0.8e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
                uint8(1),
                false
            )
        );
        vm.prank(address(router));
        engine.processOrderTyped(longOrder, 0.8e8, 1_000_000 * 1e6, uint64(block.timestamp));
    }

    function test_EntryPriceAveraging() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        _fundTrader(account, 10_000 * 1e6);

        // Open 10k tokens at $0.80
        CfdTypes.Order memory first = CfdTypes.Order({
            account: account,
            sizeDelta: 10_000 * 1e18,
            marginDelta: 1000 * 1e6,
            targetPrice: 0.8e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(first, 0.8e8, poolDepth, uint64(block.timestamp));

        (,, uint256 entryAfterFirst,,,,) = engine.positions(account);
        assertEq(entryAfterFirst, 0.8e8, "Entry should be $0.80");

        // Add 30k tokens at $1.20 → weighted avg = (10k*0.80 + 30k*1.20) / 40k = $1.10
        CfdTypes.Order memory second = CfdTypes.Order({
            account: account,
            sizeDelta: 30_000 * 1e18,
            marginDelta: 7000 * 1e6,
            targetPrice: 1.2e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        vm.prank(address(router));
        engine.processOrderTyped(second, 1.2e8, poolDepth, uint64(block.timestamp));

        (uint256 totalSize,, uint256 avgEntry,,,,) = engine.positions(account);
        assertEq(totalSize, 40_000 * 1e18, "Total size should be 40k");
        assertEq(avgEntry, 1.1e8, "Weighted avg entry should be $1.10");
    }

    function test_MarginDrained_ByFees_Reverts() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        _fundTrader(account, 1000 * 1e6);

        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 1100 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
                uint8(CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES),
                false
            )
        );
        vm.prank(address(router));
        engine.processOrderTyped(order, 1e8, poolDepth, uint64(block.timestamp));
    }

    function test_OpenOrder_SkewPrecedesIMRWhenBothFail() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(11));
        _fundTrader(account, 5000 * 1e6);

        _setRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0.0005e18,
                maxSkewRatio: 0.4e18,
                maintMarginBps: 100,
                initMarginBps: ((100) * 15) / 10,
                fadMarginBps: 300,
                baseCarryBps: 500,
                minBountyAssets: 1 * 1e6,
                bountyBps: 10,
                keeperShareBps: 5000,
                protocolShareBps: 0
            })
        );

        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 500_000 * 1e18,
            marginDelta: 1000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated,
                uint8(CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH),
                false
            )
        );
        vm.prank(address(router));
        engine.processOrderTyped(order, 1e8, poolDepth, uint64(block.timestamp));
    }

    function test_InsufficientInitialMargin_Reverts() public {
        uint256 poolDepth = 1_000_000 * 1e6;
        address account = address(uint160(1));
        _fundTrader(account, 1000 * 1e6);

        // The $100k notional requires $1500 of isolated initial margin before considering fees and reserve carve-outs.
        // MMR = 1% of $100k = $1000
        // Even the full $1000 account balance is below that requirement; the order supplies only $200 of margin.
        // Without the initial margin check, this would create an instantly-liquidatable position.
        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 200 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
                uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN),
                false
            )
        );
        vm.prank(address(router));
        engine.processOrderTyped(order, 1e8, poolDepth, uint64(block.timestamp));
    }

    function test_VpiDepthManipulation_NeutralizedByStatefulBound() public {
        address account = address(uint160(1));
        _fundTrader(account, 50_000 * 1e6);

        uint256 largeDepth = 10_000_000 * 1e6;
        uint256 smallDepth = 100_000 * 1e6;

        CfdTypes.Order memory openOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 10_000 * 1e6,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        uint256 chBeforeOpen = clearinghouse.balanceAssets(account);
        vm.prank(address(router));
        engine.processOrderTyped(openOrder, 1e8, largeDepth, uint64(block.timestamp));

        (,,,,,, int256 storedVpi) = engine.positions(account);
        assertTrue(storedVpi != 0, "VPI should be tracked");

        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            account: account,
            sizeDelta: 100_000 * 1e18,
            marginDelta: 0,
            targetPrice: 0,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 2,
            side: CfdTypes.Side.LONG,
            isClose: true
        });
        vm.prank(address(router));
        engine.processOrderTyped(closeOrder, 1e8, smallDepth, uint64(block.timestamp));

        uint256 chAfterClose = clearinghouse.balanceAssets(account);

        // Without fix: close at smallDepth yields massive VPI rebate (attacker profits).
        // With fix: stateful bound caps close rebate to what was paid on open → net VPI = 0.
        // Only exec fees should be deducted. Exec fee = 4bps * $100k * 2 = $80.
        uint256 roundTripCost = chBeforeOpen - chAfterClose;
        uint256 execFeeRoundTrip = 80 * 1e6;
        assertEq(roundTripCost, execFeeRoundTrip, "Round-trip costs only exec fees, no VPI profit");
    }

}
