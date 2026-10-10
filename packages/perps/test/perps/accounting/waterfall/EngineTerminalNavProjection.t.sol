// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {ITerminalNavBookV2} from "@plether/perps/interfaces/ITerminalNavBookV2.sol";

contract EngineTerminalNavProjectionTest is BasePerpTest {

    function _accountTerminalLpPriceDelta(
        address account,
        uint256 markPrice
    ) internal view returns (int256 deltaUsdc) {
        ITerminalNavBookV2.CurveRecord memory curve = terminalNavBook.curveOf(account);
        int256 markedNotionalUsdc = int256(uint256(curve.lots) * markPrice);
        int256 entryCostUsdc = int256(uint256(curve.entryCostUsdcAtoms));
        int256 uncappedUsdc =
            curve.side == CfdTypes.Side.LONG ? markedNotionalUsdc - entryCostUsdc : entryCostUsdc - markedNotionalUsdc;
        int256 collectibleCapUsdc = int256(uint256(curve.effectiveCapUsdcAtoms));
        deltaUsdc = uncappedUsdc > collectibleCapUsdc ? collectibleCapUsdc : uncappedUsdc;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 5_000_000 * 1e6;
    }

    // A non-lot close must fail before changing any account-local terminal exposure.
    function test_NonLotCloseRejectedBeforeAccountingMutation() public {
        uint256 depth = 5_000_000 * 1e6;

        address attackerAccount = address(0xA1);
        _fundTrader(address(0xA1), 500_000 * 1e6);

        address counterAccount = address(0xB1);
        _fundTrader(address(0xB1), 500_000 * 1e6);
        _open(counterAccount, CfdTypes.Side.SHORT, 500_000 * 1e18, 50_000 * 1e6, 1e8, depth);

        uint256 minNotional = (uint256(1) * 1e6 * 10_000) / 10 + 1e6;
        uint256 rawMinSize = (minNotional * CfdTypes.SIZE_QUANTUM) / 1e8;
        uint256 minSize = ((rawMinSize + CfdTypes.SIZE_QUANTUM - 1) / CfdTypes.SIZE_QUANTUM) * CfdTypes.SIZE_QUANTUM;
        _open(attackerAccount, CfdTypes.Side.LONG, minSize, 50_000 * 1e6, 1e8, depth);

        // Canonical whole-lot accounting rejects a close that would create a sub-lot dust position.
        uint256 closeSize = minSize - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
                uint8(CfdEnginePlanTypes.CloseRevertCode.INVALID_SIZE_QUANTUM),
                true
            )
        );
        vm.prank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                account: attackerAccount,
                sizeDelta: closeSize,
                marginDelta: 0,
                targetPrice: 0,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: CfdTypes.Side.LONG,
                isClose: true
            }),
            1e8,
            depth,
            uint64(block.timestamp)
        );
    }

    // aggregate exact account-local terminal curves, never a side-level cap.
    function test_TerminalNavBook_AggregatesAccountLocalCappedPriceCurves() public {
        uint256 depth = 5_000_000 * 1e6;

        address aliceAccount = address(0xA2);
        _fundTrader(address(0xA2), 100_000 * 1e6);
        _open(aliceAccount, CfdTypes.Side.LONG, 50_000 * 1e18, 5000 * 1e6, 1.2e8, depth);

        address bobAccount = address(0xB2);
        _fundTrader(address(0xB2), 100_000 * 1e6);
        _open(bobAccount, CfdTypes.Side.SHORT, 100_000 * 1e18, 5000 * 1e6, 1.2e8, depth);

        vm.prank(address(router));
        engine.updateMarkPrice(1.1e8, uint64(block.timestamp));

        int256 aliceDeltaUsdc = _accountTerminalLpPriceDelta(aliceAccount, 1.1e8);
        int256 bobDeltaUsdc = _accountTerminalLpPriceDelta(bobAccount, 1.1e8);
        int256 aggregateDeltaUsdc = _terminalLpPriceDelta();
        assertEq(
            aggregateDeltaUsdc,
            aliceDeltaUsdc + bobDeltaUsdc,
            "Book aggregate must equal the sum of exact account-local collateral-capped curves"
        );
        uint256 expectedLiabilityUsdc = aggregateDeltaUsdc < 0 ? uint256(-(aggregateDeltaUsdc + 1)) + 1 : 0;
        assertEq(_poolMtmAdjustment(), expectedLiabilityUsdc, "HousePool liability must derive from the signed book");
        _assertTerminalCurveMatchesEngine(aliceAccount);
        _assertTerminalCurveMatchesEngine(bobAccount);
    }

    // entry and exit share one signed terminal NAV without mutating physical cash.
    function test_UnrealizedTraderLoss_UsesOneSignedDepositAndWithdrawalNav() public {
        uint256 depth = 5_000_000 * 1e6;

        address traderAccount = address(0x2222);
        _fundTrader(address(0x2222), 500_000 * 1e6);
        _open(traderAccount, CfdTypes.Side.LONG, 2_000_000 * 1e18, 200_000 * 1e6, 1e8, depth);

        uint256 rawAssetsBefore = pool.rawAssets();
        uint256 accountedAssetsBefore = pool.accountedAssets();
        uint256 juniorBefore = juniorVault.totalAssets();

        vm.prank(address(router));
        engine.updateMarkPrice(1.5e8, uint64(block.timestamp));

        int256 terminalDeltaUsdc = _terminalLpPriceDelta();
        (uint256 withdrawalSeniorNav, uint256 withdrawalJuniorNav,,) = pool.getPendingTrancheState();
        (uint256 depositSeniorNav, uint256 depositJuniorNav) = pool.getPendingDepositTrancheState();
        assertGt(terminalDeltaUsdc, 0, "Adverse LONG mark must create collectible LP terminal price value");
        assertEq(depositSeniorNav, withdrawalSeniorNav, "Senior entry and exit must share the signed projection");
        assertEq(depositJuniorNav, withdrawalJuniorNav, "Junior entry and exit must share the signed projection");
        assertGt(withdrawalJuniorNav, juniorBefore, "Collectible trader loss must increase the shared Junior NAV");
        assertEq(pool.rawAssets(), rawAssetsBefore, "A mark update must not move physical pool cash");
        assertEq(pool.accountedAssets(), accountedAssetsBefore, "A mark update must not fabricate accounted cash");

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.juniorPrincipal(), withdrawalJuniorNav, "Reconcile must commit the same projected Junior NAV");
        assertEq(pool.rawAssets(), rawAssetsBefore, "Reconcile of terminal price value must not move physical cash");
        assertEq(pool.accountedAssets(), accountedAssetsBefore, "Reconcile must preserve canonical cash accounting");
    }

}
