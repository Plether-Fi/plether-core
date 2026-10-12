// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";

/// @notice Real-state admission classifications derived from explicit price equity, never preview.valid.
/// VPI is disabled; the mandatory 4-bps fee is included. Carry and real deferred claims have separate fixtures.
contract PartialCloseAdmissionPropertyTest is BasePerpTest {

    address private constant ACCOUNT = address(0xAD21);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.baseCarryBps = 0;
    }

    /// @dev A 2-cent adverse move loses $2 per 100-token lot. Keep enough total pledge to absorb that entire
    /// loss and leave the remaining lots exactly at maintenance (reject), or one USDC atom above (accept).
    function testFuzz_PartialCloseResidualMaintenanceAtomBoundary(
        bool isShort,
        bool aboveBoundary,
        uint256 lotSeed,
        uint256 closeSeed
    ) public {
        uint256 lots = bound(lotSeed, 40, 251);
        uint256 closedLots = bound(closeSeed, 1, lots - 1);
        uint256 entry = isShort ? 120_000_000 : 80_000_000;
        uint256 mark = isShort ? 118_000_000 : 82_000_000;
        uint256 residualRequirement = (lots - closedLots) * (isShort ? 1_180_000 : 820_000);
        uint256 totalPriceLoss = lots * 2e6;
        uint256 margin = totalPriceLoss + residualRequirement + lots * (isShort ? 168_000 : 112_000);
        if (aboveBoundary) {
            margin++;
        }
        CfdTypes.Side side = isShort ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
        _fundTrader(ACCOUNT, margin + 1000e6);
        _open(ACCOUNT, side, lots * CfdTypes.SIZE_QUANTUM, margin, entry);
        bytes32 beforeState = _state();
        uint256 depth = pool.totalAssets();
        if (!aboveBoundary) {
            _expectUnhealthy();
        }
        _close(ACCOUNT, side, closedLots * CfdTypes.SIZE_QUANTUM, mark, depth);
        if (!aboveBoundary) {
            assertEq(_state(), beforeState, "Rejected residual health preserves all account and pool state");
        } else {
            (uint256 size, uint256 pledge,,,,,) = engine.positions(ACCOUNT);
            assertEq(size, (lots - closedLots) * CfdTypes.SIZE_QUANTUM);
            assertEq(engine.positionEntryCostUsdcAtoms(ACCOUNT), (lots - closedLots) * entry);
            assertEq(pledge, (lots - closedLots) * 2e6 + residualRequirement + 1);
            assertEq(pledge - (lots - closedLots) * 2e6, residualRequirement + 1);
            assertEq(engine.traderClaimBalanceUsdc(ACCOUNT), 0);
            assertEq(engine.unsettledCarryUsdc(ACCOUNT), 0);
        }
    }

    function test_RealClaimBacksOtherwiseUnhealthyPartialClose() public {
        _createClaim();
        // After the $3.20 fee, all supplied margin becomes reserve. The independently known $995.60 claim, rather than
        // PnL pledge, admits the $8000 position and supports its $4000 partial remainder.
        _open(ACCOUNT, CfdTypes.Side.LONG, 100 * CfdTypes.SIZE_QUANTUM, 11_200_000, 80_000_000);
        assertEq(clearinghouse.pnlPledgeUsdc(ACCOUNT), 0);
        assertEq(engine.traderClaimBalanceUsdc(ACCOUNT), 995_600_000);
        _close(ACCOUNT, CfdTypes.Side.LONG, 50 * CfdTypes.SIZE_QUANTUM, 80_000_000);
        (uint256 size, uint256 pledge,,,,,) = engine.positions(ACCOUNT);
        assertEq(size, 50 * CfdTypes.SIZE_QUANTUM);
        assertEq(pledge, 0);
        assertEq(engine.positionEntryCostUsdcAtoms(ACCOUNT), 4000e6);
        assertEq(engine.traderClaimBalanceUsdc(ACCOUNT), 995_600_000);
        assertGt(
            engine.traderClaimBalanceUsdc(ACCOUNT),
            40e6,
            "Same-account claim exceeds the independently known residual requirement"
        );
    }

    function test_RealClaimCannotAdmitUnderwaterPartialRemainder() public {
        _createClaim();
        _open(ACCOUNT, CfdTypes.Side.LONG, 100 * CfdTypes.SIZE_QUANTUM, 11_200_000, 80_000_000);
        // A $0.15 adverse move loses $1500: the existing $995.60 claim cannot support even zero equity.
        bytes32 beforeState = _state();
        uint256 depth = pool.totalAssets();
        _expectUnhealthy();
        _close(ACCOUNT, CfdTypes.Side.LONG, 50 * CfdTypes.SIZE_QUANTUM, 95_000_000, depth);
        assertEq(_state(), beforeState, "Rejected close cannot consume the existing claim");
        assertEq(engine.traderClaimBalanceUsdc(ACCOUNT), 995_600_000);
    }

    function test_FundedCarryStillAdmitsHealthyPartialClose() public {
        _enableCarry();
        _fundTrader(ACCOUNT, 1_003_200_000);
        _open(ACCOUNT, CfdTypes.Side.LONG, 100 * CfdTypes.SIZE_QUANTUM, 1_003_200_000, 80_000_000);
        assertEq(pool.totalAssets(), 1_002_000e6);
        vm.warp(block.timestamp + 1 days);
        // Golden vector: $7008 borrow / $1,002,000 depth -> 69 utilization bps. At 500 annual bps,
        // one day advances index by 945205479452 and assesses exactly 6623 USDC atoms.
        uint256 cashBefore = usdc.balanceOf(address(pool));
        _close(ACCOUNT, CfdTypes.Side.LONG, 50 * CfdTypes.SIZE_QUANTUM, 80_000_000);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), 1000e6 - 6623 - 1_600_000);
        assertEq(usdc.balanceOf(address(pool)), cashBefore + 6623);
        assertEq(engine.sideCarryIndex(uint256(CfdTypes.Side.LONG)), 945_205_479_452);
        assertEq(engine.unsettledCarryUsdc(ACCOUNT), 0);
        (uint256 size, uint256 pledge,,,,,) = engine.positions(ACCOUNT);
        assertEq(size, 50 * CfdTypes.SIZE_QUANTUM);
        assertEq(pledge, 495_996_689, "Carry is collected once before proportional release, retaining the odd atom");
    }

    function test_UnfundedCarryRejectsPublicPartialCommitAndRollsBack() public {
        _checkUnfundedCarryCommit(false);
    }

    function test_UnfundedCarryRejectsEvenWhenCloseBountyIsZero() public {
        _checkUnfundedCarryCommit(true);
    }

    function _checkUnfundedCarryCommit(
        bool zeroBounty
    ) private {
        if (zeroBounty) {
            IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
            config.closeOrderExecutionBountyUsdc = 0;
            _setRouterConfig(config);
        }
        _enableCarry();
        _fundTrader(ACCOUNT, 131_200_000);
        _open(ACCOUNT, CfdTypes.Side.LONG, 100 * CfdTypes.SIZE_QUANTUM, 131_200_000, 80_000_000);
        // $7880 borrow, 78 utilization bps, and 100 years produce $307.32 carry. Only $120 pledge is
        // collectible; the separate $8 liquidation reserve remains protected, leaving $187.32 arrears.
        vm.warp(block.timestamp + 100 * 365 days);
        vm.prank(address(router));
        engine.updateMarkPrice(80_000_000, uint64(block.timestamp));
        bytes32 beforeState = _state();
        uint64 nextId = router.nextCommitId();
        if (zeroBounty) {
            vm.expectRevert(
                abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__PartialCloseCarryUnfunded.selector, 187_320_000)
            );
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    ICfdEngineTypes.CfdEngine__InsufficientCloseOrderBountyBacking.selector, 200_000, 0, 187_320_000
                )
            );
        }
        vm.prank(ACCOUNT);
        router.commitOrder(CfdTypes.Side.LONG, 50 * CfdTypes.SIZE_QUANTUM, 0, 80_000_000, true);
        assertEq(_state(), beforeState, "Commit rejection rolls back assessed carry and bounty reservation");
        assertEq(router.nextCommitId(), nextId, "Rejected commitment does not allocate an order");
    }

    function _createClaim() private {
        _fundTrader(ACCOUNT, 20_000e6);
        _open(ACCOUNT, CfdTypes.Side.LONG, 100 * CfdTypes.SIZE_QUANTUM, 1000e6, 120_000_000);
        uint256 drainedCash = usdc.balanceOf(address(pool));
        // Explicit external liquidity shock; the claim itself is created only by ordinary close execution.
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), drainedCash);
        _close(ACCOUNT, CfdTypes.Side.LONG, 100 * CfdTypes.SIZE_QUANTUM, 110_000_000);
        assertEq(engine.traderClaimBalanceUsdc(ACCOUNT), 995_600_000);
        usdc.mint(address(pool), drainedCash);
        if (engine.degradedMode()) {
            engine.clearDegradedMode();
        }
    }

    function _enableCarry() private {
        CfdTypes.RiskParams memory params = _riskParams();
        params.baseCarryBps = 500;
        _setRiskParams(params);
    }

    function _expectUnhealthy() private {
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
                uint8(CfdEnginePlanTypes.CloseRevertCode.PARTIAL_CLOSE_UNHEALTHY),
                true
            )
        );
    }

    function _carryState() private view returns (bytes32) {
        (uint256 borrowBase, uint256 lastIndex, uint64 lastTimestamp) = engine.positionCarryState(ACCOUNT);
        return keccak256(
            abi.encode(
                borrowBase,
                lastIndex,
                lastTimestamp,
                engine.sideCarryIndex(0),
                engine.sideCarryIndex(1),
                engine.sideCarryTimestamp(0),
                engine.sideCarryTimestamp(1)
            )
        );
    }

    function _state() private view returns (bytes32) {
        (bool ok, bytes memory position) =
            address(engine).staticcall(abi.encodeWithSignature("positions(address)", ACCOUNT));
        assertTrue(ok);
        return keccak256(
            abi.encode(
                position,
                _carryState(),
                engine.positionEntryCostUsdcAtoms(ACCOUNT),
                engineProtocolLens.getProtocolAccountingSnapshot(),
                _custodyState(),
                engine.traderClaimBalanceUsdc(ACCOUNT),
                engine.unsettledCarryUsdc(ACCOUNT),
                terminalNavBook.curveHashOf(ACCOUNT)
            )
        );
    }

    function _custodyState() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                clearinghouse.balanceUsdc(ACCOUNT),
                clearinghouse.lockedMarginUsdc(ACCOUNT),
                clearinghouse.liquidationReserveUsdc(ACCOUNT),
                clearinghouse.vpiRebateReserveUsdc(ACCOUNT),
                usdc.balanceOf(address(pool)),
                usdc.balanceOf(address(clearinghouse)),
                clearinghouse.balanceUsdc(PROTOCOL_TREASURY_ACCOUNT)
            )
        );
    }

}
