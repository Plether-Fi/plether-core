// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {CfdEngineTestBase} from "../shared/CfdEngineTestBase.sol";

contract EngineOpenPreviewTest is CfdEngineTestBase {

    using stdStorage for StdStorage;

    function test_InvalidOpenReportsActiveMaintenanceWithoutInventingEarlyEconomics() public {
        address trader = address(0xCA2212);
        _fundTrader(trader, 20_000e6);
        // Friday FAD start, followed by a weekday. At $0.80, 10,000 tokens have $8,000 notional.
        uint256[2] memory times = [uint256(1_709_933_400), uint256(1_709_683_200)];
        for (uint256 i; i < times.length; ++i) {
            vm.warp(times[i]);
            assertEq(engine.isFadWindow(), i == 0);
            ICfdEngineTypes.OpenPreview memory preview =
                engineLens.previewOpen(trader, CfdTypes.Side.LONG, 10_000e18, 50e6, 0.8e8);
            assertFalse(preview.valid);
            assertEq(uint8(preview.invalidReason), uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN));
            assertEq(preview.maintenanceMarginAssets, i == 0 ? 240e6 : 80e6);
            assertEq(preview.postHealthBps, 0, "Rejected plan must not invent post-health diagnostics");
            preview = engineLens.previewOpen(trader, CfdTypes.Side.SHORT, 10_000e18, 50e6, 1.2e8);
            assertFalse(preview.valid);
            assertEq(preview.maintenanceMarginAssets, i == 0 ? 360e6 : 120e6);
            preview = engineLens.previewOpen(trader, CfdTypes.Side.LONG, 1, 50e6, 0.8e8);
            assertEq(uint8(preview.invalidReason), uint8(CfdEnginePlanTypes.OpenRevertCode.INVALID_SIZE_QUANTUM));
            assertEq(preview.maintenanceMarginAssets, 0, "No constructed economics on size rejection");
            preview = engineLens.previewOpen(trader, CfdTypes.Side.LONG, 10_000e18, type(uint256).max, 0.8e8);
            assertEq(uint8(preview.invalidReason), uint8(CfdEnginePlanTypes.OpenRevertCode.NUMERIC_DOMAIN_EXCEEDED));
            assertEq(preview.maintenanceMarginAssets, 0, "No constructed economics on numeric rejection");
        }
    }

    function test_PreviewOpen_PreservesFreeSettlementForIncreaseAfterMarginFundedCarry() public {
        address trader = address(0xCA2211);
        address account = trader;
        _fundTrader(trader, 20_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        uint256 sizeDelta = 10_000e18;
        uint256 marginDelta = _freeSettlementAssets(account);
        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: sizeDelta,
            marginDelta: marginDelta,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 1,
            side: CfdTypes.Side.LONG,
            isClose: false
        });

        vm.warp(block.timestamp + 30 days);

        uint8 revertCode = engineLens.previewOpenRevertCode(account, CfdTypes.Side.LONG, sizeDelta, marginDelta, 1e8);
        CfdEnginePlanTypes.OpenFailurePolicyCategory failureCategory =
            engineLens.previewOpenFailurePolicyCategory(account, CfdTypes.Side.LONG, sizeDelta, marginDelta, 1e8);

        assertEq(
            revertCode,
            uint8(CfdEnginePlanTypes.OpenRevertCode.OK),
            "Margin-funded carry must preserve free settlement for the increase"
        );
        assertEq(
            uint256(failureCategory),
            uint256(CfdEnginePlanTypes.OpenFailurePolicyCategory.None),
            "A funded and healthy increase should remain valid"
        );
    }

}
