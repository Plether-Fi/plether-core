// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {MockSettlementToken} from "../../utils/MockSettlementToken.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {CfdEngineCollateralSnapshotLib} from "@plether/perps/libraries/CfdEngineCollateralSnapshotLib.sol";
import {Test} from "forge-std/Test.sol";

contract CollateralSnapshotHarness {

    function consolidated(
        IMarginClearinghouse clearinghouse,
        address account,
        bool closeCommit
    ) external view returns (CfdEnginePlanTypes.RawSnapshot memory snapshot) {
        snapshot.position.margin = type(uint256).max;
        CfdEngineCollateralSnapshotLib.load(snapshot, clearinghouse, account, closeCommit);
    }

    /// @dev Independent reference: the exact six getter calls used before collateral read consolidation.
    function legacy(
        IMarginClearinghouse clearinghouse,
        address account,
        bool closeCommit
    ) external view returns (CfdEnginePlanTypes.RawSnapshot memory snapshot) {
        snapshot.accountBuckets = clearinghouse.getAccountAssetBuckets(account);
        snapshot.lockedBuckets = clearinghouse.getLockedMarginBuckets(account);
        snapshot.liquidationReserveAssets = clearinghouse.liquidationReserveAssets(account);
        snapshot.actionReserveAssets = clearinghouse.actionReserveAssets(account);
        if (!closeCommit) {
            snapshot.vpiRebateReserveAssets = clearinghouse.vpiRebateReserveAssets(account);
            snapshot.protectedExecutionBountyAssets = clearinghouse.totalBountyReservationsAssets(account);
        }
        snapshot.position.margin = snapshot.lockedBuckets.positionMarginAssets;
    }

}

/// @dev Synthetic corruption only; the funded fixtures below use public clearinghouse lifecycle calls.
contract CorruptCollateralClearinghouse is MarginClearinghouse {

    constructor(
        address settlementToken
    ) MarginClearinghouse(settlementToken) {}

    function corruptBuckets(
        address account,
        uint256[7] memory amounts
    ) external {
        settlementBalances[account] = amounts[0];
        positionMarginAssets[account] = amounts[1];
        liquidationReserveBalances[account] = amounts[2];
        committedOrderMarginAssets[account] = amounts[3];
        reservedSettlementAssets[account] = amounts[4];
        vpiRebateReserveBalances[account] = amounts[5];
        totalBountyReservationsAssets[account] = amounts[6];
    }

}

contract CfdCollateralSnapshotParityTest is Test {

    address private constant ACCOUNT = address(0xA11CE);
    MockSettlementToken private settlementToken;
    CorruptCollateralClearinghouse private clearinghouse;
    CollateralSnapshotHarness private harness;

    function setUp() public {
        settlementToken = new MockSettlementToken();
        clearinghouse = new CorruptCollateralClearinghouse(address(settlementToken));
        clearinghouse.setEngine(address(this));
        harness = new CollateralSnapshotHarness();
    }

    // This isolated clearinghouse fixture has no position/carry state outside its custody buckets.
    function realizeCarryBeforeMarginChange(
        address
    ) external pure {}

    function orderRouter() external view returns (address) {
        return address(this);
    }

    function test_EmptyAccountMatchesBothSnapshotShapes() public view {
        _assertParity(false);
        _assertParity(true);
    }

    function test_AllFundedBucketsRemainIndependent() public {
        _fundPublicBuckets(200e6, 100e6, 150e6, 50e6, 20e6, 80e6);
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _assertParity(false);
        assertEq(snapshot.position.margin, 200e6, "canonical pledge replaces stale Engine margin");
        assertEq(snapshot.accountBuckets.freeSettlementAssets, 80e6);
        assertEq(snapshot.actionReserveAssets, 70e6, "VPI belongs inside the action reserve");
        assertEq(snapshot.protectedExecutionBountyAssets, 50e6);
        assertEq(snapshot.accountBuckets.otherLockedMarginAssets, 320e6, "liquidation reserve remains locked");
        snapshot = _assertParity(true);
        assertEq(snapshot.actionReserveAssets, 70e6, "commitment still protects the entire action reserve");
        assertEq(snapshot.vpiRebateReserveAssets, 0, "commitment omits execution-only VPI field");
        assertEq(snapshot.protectedExecutionBountyAssets, 0, "commitment omits execution-only bounty field");
    }

    function test_ZeroFreeSettlementMatchesBothSnapshotShapes() public {
        _fundPublicBuckets(200e6, 100e6, 150e6, 50e6, 20e6, 0);
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _assertParity(false);
        assertEq(snapshot.accountBuckets.freeSettlementAssets, 0);
        assertEq(snapshot.accountBuckets.totalLockedMarginAssets, snapshot.accountBuckets.settlementBalanceAssets);
        _assertParity(true);
    }

    function testFuzz_PublicFundedBucketsMatchLegacyGetters(
        uint96 pledge,
        uint96 liquidation,
        uint96 orderMargin,
        uint96 bounty,
        uint96 vpi,
        uint96 free
    ) public {
        _fundPublicBuckets(pledge, liquidation, orderMargin, bounty, vpi, free);
        _assertParity(false);
        _assertParity(true);
    }

    function testFuzz_SyntheticBucketsPreserveFullUint256Values(
        uint256[7] memory amounts
    ) public {
        // Synthetic, possibly undercollateralized custody and protected floors; keep the four-bucket sum representable.
        for (uint256 i = 1; i < 5; ++i) {
            amounts[i] /= 4;
        }
        clearinghouse.corruptBuckets(ACCOUNT, amounts);
        _assertParity(false);
        _assertParity(true);
    }

    function test_SyntheticUndercollateralizationKeepsZeroFloorAndRawClassifications() public {
        clearinghouse.corruptBuckets(ACCOUNT, [uint256(1), 2, 3, 4, 5, 6, 7]);
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _assertParity(false);
        assertEq(snapshot.accountBuckets.freeSettlementAssets, 0);
        assertEq(snapshot.accountBuckets.totalLockedMarginAssets, 14);
        assertEq(snapshot.actionReserveAssets, 5, "disputed backing is not silently repaired");
        assertEq(snapshot.vpiRebateReserveAssets, 6);
        assertEq(snapshot.protectedExecutionBountyAssets, 7);
        _assertParity(true);
    }

    function testFuzz_SyntheticBucketSumOverflowPreservesPanic(
        uint8 bucketIndex
    ) public {
        uint256[7] memory amounts;
        amounts[0] = type(uint256).max;
        amounts[1 + bucketIndex % 4] = type(uint256).max;
        amounts[1 + (bucketIndex + uint256(1)) % 4] = 1;
        clearinghouse.corruptBuckets(ACCOUNT, amounts);
        IMarginClearinghouse house = IMarginClearinghouse(address(clearinghouse));
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
            harness.legacy(house, ACCOUNT, i == 1);
            vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
            harness.consolidated(house, ACCOUNT, i == 1);
        }
    }

    function _fundPublicBuckets(
        uint256 pledge,
        uint256 liquidation,
        uint256 orderMargin,
        uint256 bounty,
        uint256 vpi,
        uint256 free
    ) private {
        uint256 settlement = pledge + liquidation + orderMargin + bounty + vpi + free;
        if (settlement > 0) {
            settlementToken.mint(ACCOUNT, settlement);
            vm.startPrank(ACCOUNT);
            settlementToken.approve(address(clearinghouse), settlement);
            clearinghouse.deposit(ACCOUNT, settlement);
            vm.stopPrank();
        }
        clearinghouse.lockPositionMargin(ACCOUNT, pledge + liquidation);
        clearinghouse.reclassifyPnlPledgeToLiquidationReserve(ACCOUNT, liquidation);
        if (orderMargin > 0) {
            clearinghouse.reserveCommittedOrderMargin(ACCOUNT, 1, orderMargin);
        }
        clearinghouse.lockReservedSettlement(ACCOUNT, bounty);
        clearinghouse.recordBountyReservation(ACCOUNT, IMarginClearinghouse.BountyKind.Order, 1, bounty);
        clearinghouse.lockVpiRebateReserve(ACCOUNT, vpi);
    }

    function _assertParity(
        bool closeCommit
    ) private view returns (CfdEnginePlanTypes.RawSnapshot memory actual) {
        IMarginClearinghouse house = IMarginClearinghouse(address(clearinghouse));
        CfdEnginePlanTypes.RawSnapshot memory expected = harness.legacy(house, ACCOUNT, closeCommit);
        actual = harness.consolidated(house, ACCOUNT, closeCommit);
        assertEq(keccak256(abi.encode(actual)), keccak256(abi.encode(expected)), "exact collateral snapshot parity");
    }

}
