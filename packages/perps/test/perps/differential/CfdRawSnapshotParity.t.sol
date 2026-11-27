// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdEnginePlanningReader} from "@plether/perps/CfdEnginePlanningReader.sol";
import {CfdOrderPolicyEvaluatorBase, ICfdOrderPolicyEngineView} from "@plether/perps/CfdOrderPolicyEvaluatorBase.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {Test} from "forge-std/Test.sol";

contract RawSnapshotLensHarness is CfdEngineLens {

    constructor(
        address engine
    ) CfdEngineLens(engine) {}

    function build(
        address account,
        uint256 depth
    ) external view returns (CfdEnginePlanTypes.RawSnapshot memory) {
        return _buildRawSnapshot(account, depth);
    }

}

contract RawSnapshotPolicyHarness is CfdOrderPolicyEvaluatorBase {

    function build(
        address engineAddress,
        address account,
        uint256 depth
    ) external view returns (CfdEnginePlanTypes.RawSnapshot memory) {
        ICfdOrderPolicyEngineView engine = ICfdOrderPolicyEngineView(engineAddress);
        return _buildRawSnapshot(engine, account, depth);
    }

    function buildWithCash(
        address engineAddress,
        address account,
        uint256 depth,
        uint256 cash
    ) external view returns (CfdEnginePlanTypes.RawSnapshot memory) {
        ICfdOrderPolicyEngineView engine = ICfdOrderPolicyEngineView(engineAddress);
        return _buildRawSnapshot(engine, account, depth, cash);
    }

}

/// @dev Synthetic getter observations isolate snapshot assembly, including deliberately stale Engine margin.
contract CfdRawSnapshotParityTest is Test {

    address private constant ENGINE = address(0xE11);
    address private constant POOL = address(0xB001);
    address private constant CLEARINGHOUSE = address(0xC1EA);
    address private constant SIDECAR = address(0x51DE);
    address private constant ACCOUNT = address(0xA11CE);
    uint256 private constant NOW = 1_700_000_000;
    uint256 private constant DEPTH = 3000e6;

    CfdEnginePlanningReader private reader;
    RawSnapshotLensHarness private lens;
    RawSnapshotPolicyHarness private policy;

    function setUp() public {
        vm.warp(NOW);
        vm.prank(ENGINE);
        reader = new CfdEnginePlanningReader();
        lens = new RawSnapshotLensHarness(ENGINE);
        policy = new RawSnapshotPolicyHarness();

        _mockUint(ENGINE, "pool()", uint256(uint160(POOL)));
        _mockUint(ENGINE, "clearinghouse()", uint256(uint160(CLEARINGHOUSE)));
        _mockUint(ENGINE, "currentCarryIndex()", 61e18);
        _mockUint(ENGINE, "settlementSidecar()", uint256(uint160(SIDECAR)));
        _mockPosition(CfdTypes.Side.LONG);
        vm.mockCall(ENGINE, abi.encodeWithSignature("positionEntryCostAssetAtoms(address)", ACCOUNT), abi.encode(16e6));
        vm.mockCall(
            ENGINE,
            abi.encodeWithSignature("positionCarryState(address)", ACCOUNT),
            abi.encode(uint256(19e6), uint256(20e18), uint64(NOW - 21))
        );
        _mockUint(ENGINE, "lastMarkPrice()", 90_000_022);
        _mockUint(ENGINE, "lastMarkTime()", NOW - 29);
        vm.mockCall(
            ENGINE,
            abi.encodeWithSignature("riskParams()"),
            abi.encode(
                CfdTypes.RiskParams({
                    vpiFactor: 34e14,
                    maxSkewRatio: 35e16,
                    maintMarginBps: 136,
                    initMarginBps: 237,
                    fadMarginBps: 338,
                    baseCarryBps: 539,
                    minBountyAssets: 40e6,
                    bountyBps: 41,
                    keeperShareBps: 4242,
                    protocolShareBps: 434
                })
            )
        );
        _mockUint(POOL, "totalAssets()", 2000e6);
        _mockUint(POOL, "pendingRecapitalizationAssets()", 31e6);
        _mockUint(POOL, "pendingTradingRevenueAssets()", 32e6);
        _mockUint(POOL, "unassignedAssets()", 33e6);
        _mockUint(POOL, "seniorPrincipal()", 0);
        _mockUint(POOL, "juniorPrincipal()", 0);
        _mockUint(ENGINE, "totalTraderClaimBalanceAssets()", 44e6);
        _mockUint(ENGINE, "totalPositiveVpiAccruedAssets()", 45e6);
        _mockUint(ENGINE, "totalNegativeVpiAccruedAssets()", 63e6);
        _mockSide(0, 46e6, 47e20, 48e26, 49e6);
        _mockSide(1, 56e6, 57e20, 58e26, 59e6);
        _mockCollateral();
        vm.mockCall(ENGINE, abi.encodeWithSignature("unsettledCarryAssets(address)", ACCOUNT), abi.encode(65e6));
        vm.mockCall(ENGINE, abi.encodeWithSignature("traderClaimBalanceAssets(address)", ACCOUNT), abi.encode(64e6));
        _mockUint(ENGINE, "degradedMode()", 1);
        _mockUint(ENGINE, "CAP_PRICE()", 2e8);
        _mockUint(ENGINE, "executionFeeBps()", 66);
        _mockUint(ENGINE, "settlementBufferBps()", 67);
        _mockUint(ENGINE, "isFadWindow()", 1);
        _mockUint(ENGINE, "isOracleFrozen()", 1);
        _mockUint(ENGINE, "frozenCloseSpreadBps()", 68);
    }

    function test_FullBuildersPreserveEveryFieldAndPermissionlessSidecarIndependence() public {
        vm.mockCallRevert(
            SIDECAR,
            abi.encodeWithSignature("buildRawSnapshot(address,uint256)", ACCOUNT, DEPTH),
            bytes("snapshot must read Engine getters")
        );
        for (uint256 side; side < 2; ++side) {
            _mockPosition(CfdTypes.Side(side));
            _mockCollateral();
            CfdEnginePlanTypes.RawSnapshot memory expected = _expectedFull(CfdTypes.Side(side));
            if (side == 1) {
                _mockUint(POOL, "seniorPrincipal()", 1e6);
                expected.poolQueuesTradingRevenue = false;
            }
            vm.prank(ENGINE);
            assertEq(abi.encode(reader.buildRawSnapshot(ACCOUNT, DEPTH, false)), abi.encode(expected), "Reader fields");
            assertEq(abi.encode(policy.build(ENGINE, ACCOUNT, DEPTH)), abi.encode(expected), "Policy fields");
            // Lens simulations retain hypothetical cash and absent commitment marks.
            expected.poolCashAssets = DEPTH;
            expected.lastMarkPrice = 0;
            expected.lastMarkTime = 0;
            assertEq(
                abi.encode(lens.build(ACCOUNT, DEPTH)), abi.encode(expected), "Lens fields and intentional context"
            );
        }
    }

    function test_PolicyReusesObservedCashWithoutReadingPoolCashAgain() public {
        vm.mockCallRevert(POOL, abi.encodeWithSignature("totalAssets()"), bytes("cash already observed"));
        assertEq(
            abi.encode(policy.buildWithCash(ENGINE, ACCOUNT, DEPTH, 2000e6)),
            abi.encode(_expectedFull(CfdTypes.Side.LONG))
        );
    }

    function test_CloseCommitLongPreservesEveryRequiredFieldAndReducedReads() public {
        _assertCloseCommit(CfdTypes.Side.LONG);
    }

    function test_CloseCommitShortPreservesEveryRequiredFieldAndReducedReads() public {
        _assertCloseCommit(CfdTypes.Side.SHORT);
    }

    function _assertCloseCommit(
        CfdTypes.Side side
    ) private {
        _mockPosition(side);
        uint256 omittedSide = side == CfdTypes.Side.LONG ? 1 : 0;
        bytes memory omittedRead = bytes("execution-only or opposite-side read");
        vm.mockCallRevert(ENGINE, abi.encodeWithSignature("sides(uint256)", omittedSide), omittedRead);
        vm.mockCallRevert(ENGINE, abi.encodeWithSignature("degradedMode()"), omittedRead);
        vm.mockCallRevert(ENGINE, abi.encodeWithSignature("executionFeeBps()"), omittedRead);
        vm.mockCallRevert(ENGINE, abi.encodeWithSignature("settlementBufferBps()"), omittedRead);
        vm.mockCallRevert(ENGINE, abi.encodeWithSignature("isOracleFrozen()"), omittedRead);
        vm.mockCallRevert(ENGINE, abi.encodeWithSignature("frozenCloseSpreadBps()"), omittedRead);
        vm.mockCallRevert(
            CLEARINGHOUSE, abi.encodeWithSignature("totalBountyReservationsAssets(address)", ACCOUNT), omittedRead
        );

        CfdEnginePlanTypes.RawSnapshot memory expected = _expectedFull(side);
        CfdEnginePlanTypes.SideSnapshot memory omitted;
        if (side == CfdTypes.Side.LONG) {
            expected.shortSide = omitted;
        } else {
            expected.longSide = omitted;
        }
        expected.poolAssets = 2000e6;
        expected.vpiRebateReserveAssets = 0;
        expected.protectedExecutionBountyAssets = 0;
        expected.degradedMode = false;
        expected.executionFeeBps = 0;
        expected.settlementBufferBps = 0;
        expected.oracleFrozen = false;
        expected.frozenCloseSpreadBps = 0;
        vm.prank(SIDECAR);
        assertEq(abi.encode(reader.buildRawSnapshot(ACCOUNT, DEPTH, true)), abi.encode(expected));
    }

    /// @dev Independent named fixture: adding a RawSnapshot field requires an explicit expected value here.
    function _expectedFull(
        CfdTypes.Side side
    ) private pure returns (CfdEnginePlanTypes.RawSnapshot memory) {
        return CfdEnginePlanTypes.RawSnapshot({
            position: CfdTypes.Position({
                size: 11e20,
                margin: 23e6,
                entryPrice: 91_000_013,
                maxProfitAssets: 14e6,
                side: side,
                lastUpdateTime: uint64(NOW - 17),
                lastCarryTimestamp: uint64(NOW - 21),
                vpiAccrued: -18e6
            }),
            positionEntryCostAssetAtoms: 16e6,
            account: ACCOUNT,
            currentTimestamp: NOW,
            lastMarkPrice: 90_000_022,
            lastMarkTime: uint64(NOW - 29),
            positionLastCarryIndex: 20e18,
            carryIndex: 61e18,
            longSide: CfdEnginePlanTypes.SideSnapshot({
                maxProfitAssets: 46e6, openInterest: 47e20, entryNotional: 48e26, totalMargin: 49e6
            }),
            shortSide: CfdEnginePlanTypes.SideSnapshot({
                maxProfitAssets: 56e6, openInterest: 57e20, entryNotional: 58e26, totalMargin: 59e6
            }),
            poolAssets: DEPTH,
            poolCashAssets: 2000e6,
            poolAdditionalReservedAssets: 96e6,
            poolQueuesTradingRevenue: true,
            accountBuckets: IMarginClearinghouse.AccountAssetBuckets({
                settlementBalanceAssets: 1000e6,
                totalLockedMarginAssets: 98e6,
                activePositionMarginAssets: 23e6,
                otherLockedMarginAssets: 75e6,
                freeSettlementAssets: 902e6
            }),
            lockedBuckets: IMarginClearinghouse.LockedMarginBuckets({
                positionMarginAssets: 23e6,
                committedOrderMarginAssets: 25e6,
                reservedSettlementAssets: 26e6,
                totalLockedMarginAssets: 98e6
            }),
            liquidationReserveAssets: 24e6,
            actionReserveAssets: 26e6,
            vpiRebateReserveAssets: 27e5,
            protectedExecutionBountyAssets: 28e5,
            protectedPositionMarginAssets: 11e6,
            protectedReleasedMarginAssets: 13e6,
            unsettledCarryAssets: 65e6,
            totalTraderClaimBalanceAssets: 44e6,
            totalPositiveVpiAccruedAssets: 45e6,
            totalNegativeVpiAccruedAssets: 63e6,
            traderClaimBalanceForAccount: 64e6,
            degradedMode: true,
            capPrice: 2e8,
            riskParams: CfdTypes.RiskParams({
                vpiFactor: 34e14,
                maxSkewRatio: 35e16,
                maintMarginBps: 136,
                initMarginBps: 237,
                fadMarginBps: 338,
                baseCarryBps: 539,
                minBountyAssets: 40e6,
                bountyBps: 41,
                keeperShareBps: 4242,
                protocolShareBps: 434
            }),
            executionFeeBps: 66,
            isFadWindow: true,
            oracleFrozen: true,
            frozenCloseSpreadBps: 68,
            settlementBufferBps: 67
        });
    }

    function _mockPosition(
        CfdTypes.Side side
    ) private {
        vm.mockCall(
            ENGINE,
            abi.encodeWithSignature("positions(address)", ACCOUNT),
            abi.encode(
                uint256(11e20), uint256(12e6), uint256(91_000_013), uint256(14e6), side, uint64(NOW - 17), -int256(18e6)
            )
        );
    }

    function _mockSide(
        uint256 side,
        uint256 maxProfit,
        uint256 openInterest,
        uint256 entryNotional,
        uint256 margin
    ) private {
        vm.mockCall(
            ENGINE,
            abi.encodeWithSignature("sides(uint256)", side),
            abi.encode(maxProfit, openInterest, entryNotional, margin)
        );
    }

    function _mockCollateral() private {
        vm.mockCall(
            CLEARINGHOUSE,
            abi.encodeWithSignature("getPnlIsolationBuckets(address)", ACCOUNT),
            abi.encode(
                IMarginClearinghouse.PnlIsolationBuckets({
                    settlementBalanceAssets: 1000e6,
                    pnlPledgeAssets: 23e6,
                    liquidationReserveAssets: 24e6,
                    orderMarginAssets: 25e6,
                    actionReserveAssets: 26e6,
                    vpiRebateReserveAssets: 27e5,
                    totalLockedAssets: 98e6,
                    freeSettlementAssets: 902e6,
                    protectedPledgeAssets: 11e6,
                    protectedReleasedAssets: 13e6
                })
            )
        );
        vm.mockCall(
            CLEARINGHOUSE,
            abi.encodeWithSignature("getAccountAssetBuckets(address)", ACCOUNT),
            abi.encode(
                IMarginClearinghouse.AccountAssetBuckets({
                    settlementBalanceAssets: 1000e6,
                    totalLockedMarginAssets: 98e6,
                    activePositionMarginAssets: 23e6,
                    otherLockedMarginAssets: 75e6,
                    freeSettlementAssets: 902e6
                })
            )
        );
        vm.mockCall(
            CLEARINGHOUSE,
            abi.encodeWithSignature("getLockedMarginBuckets(address)", ACCOUNT),
            abi.encode(
                IMarginClearinghouse.LockedMarginBuckets({
                    positionMarginAssets: 23e6,
                    committedOrderMarginAssets: 25e6,
                    reservedSettlementAssets: 26e6,
                    totalLockedMarginAssets: 98e6
                })
            )
        );
        vm.mockCall(
            CLEARINGHOUSE, abi.encodeWithSignature("liquidationReserveAssets(address)", ACCOUNT), abi.encode(24e6)
        );
        vm.mockCall(CLEARINGHOUSE, abi.encodeWithSignature("actionReserveAssets(address)", ACCOUNT), abi.encode(26e6));
        vm.mockCall(
            CLEARINGHOUSE, abi.encodeWithSignature("vpiRebateReserveAssets(address)", ACCOUNT), abi.encode(27e5)
        );
        vm.mockCall(
            CLEARINGHOUSE, abi.encodeWithSignature("totalBountyReservationsAssets(address)", ACCOUNT), abi.encode(28e5)
        );
    }

    function _mockUint(
        address target,
        string memory signature,
        uint256 value
    ) private {
        vm.mockCall(target, abi.encodeWithSignature(signature), abi.encode(value));
    }

}
