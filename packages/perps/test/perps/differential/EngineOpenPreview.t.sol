// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {CfdEngineTestBase} from "../shared/CfdEngineTestBase.sol";

contract EngineOpenPreviewTest is CfdEngineTestBase {

    using stdStorage for StdStorage;

    function test_PreviewOpen_PreservesFreeSettlementForIncreaseAfterMarginFundedCarry() public {
        address trader = address(0xCA2211);
        address account = trader;
        _fundTrader(trader, 20_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        uint256 sizeDelta = 10_000e18;
        uint256 marginDelta = _freeSettlementUsdc(account);
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

        uint8 revertCode = engineLens.previewOpenRevertCode(
            account, CfdTypes.Side.LONG, sizeDelta, marginDelta, 1e8, uint64(block.timestamp)
        );
        CfdEnginePlanTypes.OpenFailurePolicyCategory failureCategory = engineLens.previewOpenFailurePolicyCategory(
            account, CfdTypes.Side.LONG, sizeDelta, marginDelta, 1e8, uint64(block.timestamp)
        );

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

