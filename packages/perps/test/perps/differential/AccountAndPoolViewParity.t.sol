// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: differential. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/ACCOUNTING_SPEC.md#snapshot-boundaries

import {BasePerpTest} from "../BasePerpTest.sol";
import {HousePoolAccountingLibHarness} from "../support/BehaviorScenarioHelpers.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";
import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {HousePoolAccountingLib} from "@plether/perps/libraries/HousePoolAccountingLib.sol";

contract ProjectedCarryHealthTest is BasePerpTest {

    address trader = address(0x7777);

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

    /// @dev differential; source: ACCOUNTING_SPEC.md#snapshot-boundaries.
    function test_SimpleHealthViewsMustUseProjectedCarryState() public {
        address account = trader;
        _fundTrader(trader, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);
        uint256 pledgeBefore = clearinghouse.pnlPledgeUsdc(account);
        vm.warp(block.timestamp + 30 days);
        AccountLensViewTypes.AccountLedgerSnapshot memory ledger = engineAccountLens.getAccountLedgerSnapshot(account);
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 1e8);
        assertEq(ledger.unrealizedPnlUsdc, 0, "Same-price fixture isolates carry");
        assertGt(ledger.netEquityUsdc, 0, "Pledge must fully cover this carry interval");
        assertLt(uint256(ledger.netEquityUsdc), pledgeBefore, "Elapsed carry must reduce projected risk equity");
        assertEq(ledger.netEquityUsdc, preview.equityUsdc, "Health views use the same carry projection");
        assertEq(ledger.liquidatable, preview.liquidatable);
        assertEq(clearinghouse.pnlPledgeUsdc(account), pledgeBefore, "Reading health must not realize carry");
        uint256 poolBefore = pool.totalAssets();
        _fundTrader(account, 1);
        assertEq(
            clearinghouse.pnlPledgeUsdc(account),
            uint256(ledger.netEquityUsdc),
            "Checkpoint applies the projected pledge debit"
        );
        assertEq(pool.totalAssets() - poolBefore, pledgeBefore - uint256(ledger.netEquityUsdc));
        assertEq(
            engineLens.previewLiquidation(account, 1e8).equityUsdc,
            preview.equityUsdc,
            "Checkpoint must not charge carry twice"
        );
    }

}

contract WithdrawalCapacityLivenessTest is BasePerpTest {

    address seniorLp = address(0x8888);
    address juniorLp = address(0x9999);
    address trader = address(0xAAAA);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
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

    /// @dev differential; source: ACCOUNTING_SPEC.md#snapshot-boundaries.
    function test_WithdrawalCapGettersMustZeroWhenWithdrawalsAreNotLive() public {
        _fundSenior(seniorLp, 100_000e6);
        _fundJunior(juniorLp, 100_000e6);
        _fundTrader(trader, 50_000e6);

        address traderAccount = trader;
        _open(traderAccount, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        vm.warp(block.timestamp + 121);

        assertFalse(pool.isWithdrawalLive(), "Withdrawal liveness should be false once the mark is stale");
        assertEq(pool.getMaxSeniorWithdraw(), 0, "Senior withdrawal cap getter should be liveness-gated");
        assertEq(pool.getMaxJuniorWithdraw(), 0, "Junior withdrawal cap getter should be liveness-gated");
    }

}

contract GrossCashAssetBoundaryTest is BasePerpTest {

    HousePoolAccountingLibHarness harness;

    function setUp() public override {
        super.setUp();
        harness = new HousePoolAccountingLibHarness();
    }

    /// @dev differential; source: ACCOUNTING_SPEC.md#snapshot-boundaries.
    function test_GrossAssetsMustNotExceedActualCashWhenFeesExceedCash() public {
        address trader = address(0x1234);
        address traderAccount = trader;

        _fundJunior(address(this), 500_000e6);
        _fundTrader(trader, 50_000e6);
        _open(traderAccount, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        uint256 fees = clearinghouse.balanceUsdc(engine.protocolTreasury());
        assertGt(fees, 0, "Setup must accrue protocol fees");

        uint256 actualCash = 10_000_000;
        uint256 burnAmount = pool.totalAssets() - actualCash;
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), burnAmount);

        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());
        HousePoolAccountingLib.WithdrawalSnapshot memory withdrawalSnapshot = harness.buildWithdrawal(snapshot);
        harness.buildReconcile(snapshot);

        assertEq(snapshot.netPhysicalAssetsUsdc, 0, "Net physical assets should saturate to zero once fees exceed cash");
        assertEq(pool.totalAssets(), actualCash, "Test must leave the pool with less cash than the fee ledger");
        assertLe(
            withdrawalSnapshot.physicalAssets,
            pool.totalAssets(),
            "Withdrawal snapshot gross assets must not exceed actual cash"
        );
        assertLe(snapshot.physicalAssetsUsdc, pool.totalAssets(), "Reconcile input must not exceed actual cash");
    }

}
