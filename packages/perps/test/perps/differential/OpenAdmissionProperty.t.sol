// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

/// @notice Admission is checked from installed pledge and exact entry cost, without using previewed equity.
contract OpenAdmissionPropertyTest is BasePerpTest {

    address private constant SEED = address(0xAD10);
    address private constant ACCOUNT = address(0xAD11);
    uint256 private constant MARK = 1e8;

    function _seedSkew() private {
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 0.02e18;
        params.baseCarryBps = 0;
        _setRiskParams(params);
        _fundTrader(SEED, 50_000e6);
        _fundTrader(ACCOUNT, 20_000e6);
        _open(SEED, CfdTypes.Side.LONG, 100_000e18, 20_000e6, MARK);
    }

    function testFuzz_SuccessfulOpenOrIncreaseMeetsInstalledInitialMargin(
        bool existing,
        bool healing,
        bool zeroSuppliedMargin,
        uint256 sizeSeed,
        uint256 marginSeed
    ) public {
        _seedSkew();
        CfdTypes.Side side = healing ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
        if (existing) {
            _open(ACCOUNT, side, 10_000e18, 2000e6, MARK);
        }
        uint256 size = bound(sizeSeed, 10, 400) * 100e18;
        uint256 margin = zeroSuppliedMargin ? 0 : bound(marginSeed, 1, 3000e6);
        _tryOpenAndCheck(side, size, margin);
    }

    function test_ZeroMarginHealingIncreaseIsReachableAndCollateralized() public {
        _seedSkew();
        _open(ACCOUNT, CfdTypes.Side.SHORT, 10_000e18, 2000e6, MARK);
        // Governance lowers the reserve ratio: the existing reserve now covers the increased notional.
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 0.02e18;
        params.baseCarryBps = 0;
        params.bountyBps = 5;
        _setRiskParams(params);
        assertTrue(_tryOpenAndCheck(CfdTypes.Side.SHORT, 10_000e18, 0), "Reach zero-supplied-margin increase");
        (,,,,,, int256 lifetimeVpi) = engine.positions(ACCOUNT);
        assertLt(lifetimeVpi, 0, "Scenario must earn and reserve a lifetime rebate");
    }

    function test_HealingRebateCannotSubstituteForInitialMargin_AtomBoundary() public {
        _seedSkew();
        // 40,000 settlement token notional needs 600 settlement token price-risk pledge and 40 settlement token liquidation reserve.
        // A healing rebate is free settlement / VPI reserve, never additional pledge for admission.
        for (uint256 supplied = 640e6 - 1; supplied <= 640e6 + 1; supplied++) {
            uint256 snapshot = vm.snapshotState();
            bool success = _tryOpenAndCheck(CfdTypes.Side.SHORT, 40_000e18, supplied);
            assertEq(success, supplied > 640e6, "Admission boundary must exclude the rebate from price-risk equity");
            if (success) {
                assertEq(clearinghouse.pnlPledgeAssets(ACCOUNT), supplied - 40e6);
                (,,,,,, int256 lifetimeVpi) = engine.positions(ACCOUNT);
                assertLt(lifetimeVpi, 0, "Boundary must execute a healing rebate");
            }
            assertTrue(vm.revertToState(snapshot));
            vm.deleteStateSnapshot(snapshot);
        }
    }

    /// @notice This classified domain has no VPI, carry, pool shortage or skew rejection. Every input has a
    /// predetermined result; unlike the broad conditional property, an unjustified rejection fails the test.
    function testFuzz_ClassifiedOpenAndIncreaseInitialMarginBoundary(
        bool existing,
        bool isShort,
        bool highPrice,
        uint256 lotSeed,
        uint8 boundarySeed
    ) public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.baseCarryBps = 0;
        _setRiskParams(params);
        _fundTrader(ACCOUNT, 20_000e6);
        CfdTypes.Side side = isShort ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
        uint256 price = highPrice ? 120_000_000 : 80_000_000;
        // Per 100-token lot: $120 or $80 notional, 1.5% price pledge, separate 0.1% reserve, and the mandatory 4-bps execution fee.
        uint256 pledgePerLot = highPrice ? 1_800_000 : 1_200_000;
        uint256 reservePerLot = highPrice ? 120_000 : 80_000;
        uint256 feePerLot = highPrice ? 48_000 : 32_000;
        uint256 priorLots = existing ? 17 : 0;
        if (existing) {
            _open(
                ACCOUNT,
                side,
                priorLots * CfdTypes.SIZE_QUANTUM,
                priorLots * (pledgePerLot + reservePerLot + feePerLot) + 1,
                price
            );
        }
        uint256 addedLots = bound(lotSeed, 17, 251);
        uint256 boundary = bound(uint256(boundarySeed), 0, 2);
        uint256 supplied = addedLots * (pledgePerLot + reservePerLot + feePerLot) + boundary - 1 - (existing ? 1 : 0);
        bytes32 beforeState = _admissionState();
        uint256 depth = pool.totalAssets();
        if (boundary <= 1) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                    CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
                    uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN),
                    false
                )
            );
        }
        _open(ACCOUNT, side, addedLots * CfdTypes.SIZE_QUANTUM, supplied, price, depth);
        if (boundary <= 1) {
            assertEq(_admissionState(), beforeState, "Initial-margin rejection must roll back every observed ledger");
        } else {
            (uint256 installedSize,,,,,,) = engine.positions(ACCOUNT);
            uint256 totalLots = priorLots + addedLots;
            assertEq(installedSize, totalLots * CfdTypes.SIZE_QUANTUM);
            assertEq(engine.positionEntryCostAssetAtoms(ACCOUNT), totalLots * price);
            assertEq(clearinghouse.pnlPledgeAssets(ACCOUNT), totalLots * pledgePerLot + boundary - 1);
            assertEq(clearinghouse.liquidationReserveAssets(ACCOUNT), totalLots * reservePerLot);
            assertEq(
                clearinghouse.balanceAssets(ACCOUNT),
                20_000e6 - totalLots * feePerLot,
                "Only execution fees debit custody"
            );
            assertEq(engine.unsettledCarryAssets(ACCOUNT), 0);
        }
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

    function _admissionState() private view returns (bytes32) {
        (bool ok, bytes memory position) =
            address(engine).staticcall(abi.encodeWithSignature("positions(address)", ACCOUNT));
        assertTrue(ok);
        return keccak256(
            abi.encode(
                position,
                _carryState(),
                engine.positionEntryCostAssetAtoms(ACCOUNT),
                engineProtocolLens.getProtocolAccountingSnapshot(),
                _custodyState(),
                engine.traderClaimBalanceAssets(ACCOUNT),
                engine.unsettledCarryAssets(ACCOUNT),
                terminalNavBook.curveHashOf(ACCOUNT)
            )
        );
    }

    function _custodyState() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                clearinghouse.balanceAssets(ACCOUNT),
                clearinghouse.lockedMarginAssets(ACCOUNT),
                clearinghouse.liquidationReserveAssets(ACCOUNT),
                clearinghouse.vpiRebateReserveAssets(ACCOUNT),
                settlementToken.balanceOf(address(pool)),
                settlementToken.balanceOf(address(clearinghouse)),
                clearinghouse.balanceAssets(PROTOCOL_TREASURY_ACCOUNT)
            )
        );
    }

    function _tryOpenAndCheck(
        CfdTypes.Side side,
        uint256 size,
        uint256 margin
    ) private returns (bool success) {
        bytes32 beforeState = _admissionState();
        CfdTypes.Order memory order = CfdTypes.Order({
            account: ACCOUNT,
            sizeDelta: size,
            marginDelta: margin,
            targetPrice: MARK,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: side,
            isClose: false
        });
        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        try engine.processOrderTyped(order, MARK, depth, uint64(block.timestamp)) {
            success = true;
            _assertInstalledAdmission(side);
        } catch (bytes memory reason) {
            assertEq(
                _revertSelector(reason),
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                "No unexpected execution revert"
            );
            assertEq(reason.length, 100, "Typed failure must include its complete category, code and action");
            uint256 category;
            uint256 code;
            uint256 isClose;
            assembly {
                category := mload(add(reason, 36))
                code := mload(add(reason, 68))
                isClose := mload(add(reason, 100))
            }
            assertEq(category, uint256(CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid));
            assertEq(isClose, 0, "Open admission cannot report a close failure");
            assertTrue(
                code == uint8(CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES)
                    || code == uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN)
                    || code == uint8(CfdEnginePlanTypes.OpenRevertCode.LIQUIDATION_RESERVE_UNFUNDED)
                    || code == uint8(CfdEnginePlanTypes.OpenRevertCode.VPI_REBATE_RESERVE_UNFUNDED),
                "This collateral-only domain cannot justify a protocol, skew or input-shape rejection"
            );
            assertEq(_admissionState(), beforeState, "Rejected admission rolls back custody, risk and carry ledgers");
        }
    }

    function _assertInstalledAdmission(
        CfdTypes.Side side
    ) private view {
        (uint256 size,,,,,, int256 lifetimeVpi) = engine.positions(ACCOUNT);
        uint256 markedNotional = size * MARK / 1e20;
        int256 pnl = int256(engine.positionEntryCostAssetAtoms(ACCOUNT)) - int256(markedNotional);
        if (side == CfdTypes.Side.SHORT) {
            pnl = -pnl;
        }
        int256 priceEquity =
            int256(clearinghouse.pnlPledgeAssets(ACCOUNT) + engine.traderClaimBalanceAssets(ACCOUNT)) + pnl;
        uint256 initialRequirement = markedNotional * 150 / 10_000;
        if (initialRequirement < 1e6) {
            initialRequirement = 1e6;
        }
        assertGt(priceEquity, int256(initialRequirement), "Every successful admission exceeds initial price equity");
        assertGe(
            clearinghouse.vpiRebateReserveAssets(ACCOUNT),
            lifetimeVpi < 0 ? uint256(-lifetimeVpi) : 0,
            "Negative lifetime VPI is physically reserved separately"
        );
        assertEq(engine.unsettledCarryAssets(ACCOUNT), 0, "New risk cannot leave carry arrears");
    }

}
