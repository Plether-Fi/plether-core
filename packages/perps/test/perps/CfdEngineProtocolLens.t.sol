// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEngineProtocolLens} from "@plether/perps/CfdEngineProtocolLens.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";
import {stdError} from "forge-std/StdError.sol";
import {Test} from "forge-std/Test.sol";

contract CfdEngineProtocolLensTest is Test {

    address internal constant ENGINE = address(0xE11);
    address internal constant POOL = address(0xB001);
    address internal constant CLEARINGHOUSE = address(0xC1EA);
    address internal constant TREASURY = address(0x7EA5);

    CfdEngineProtocolLens internal lens;

    function setUp() public {
        vm.mockCall(ENGINE, abi.encodeWithSignature("pool()"), abi.encode(POOL));
        vm.mockCall(ENGINE, abi.encodeWithSignature("clearinghouse()"), abi.encode(CLEARINGHOUSE));
        vm.mockCall(ENGINE, abi.encodeWithSignature("protocolTreasury()"), abi.encode(TREASURY));
        vm.mockCall(POOL, abi.encodeWithSignature("totalAssets()"), abi.encode(uint256(100_000e6)));
        vm.mockCall(
            CLEARINGHOUSE, abi.encodeWithSignature("balanceUsdc(address)", TREASURY), abi.encode(uint256(10_000e6))
        );
        _mockSide(CfdTypes.Side.LONG, 20_000e6, 20_000e18);
        _mockSide(CfdTypes.Side.SHORT, 35_000e6, 35_000e18);
        vm.mockCall(ENGINE, abi.encodeWithSignature("totalTraderClaimBalanceUsdc()"), abi.encode(uint256(5000e6)));
        vm.mockCall(ENGINE, abi.encodeWithSignature("settlementBufferBps()"), abi.encode(uint256(125)));
        vm.mockCall(ENGINE, abi.encodeWithSignature("degradedMode()"), abi.encode(false));
        lens = new CfdEngineProtocolLens(ENGINE);
    }

    function _mockSide(
        CfdTypes.Side side,
        uint256 maxProfitUsdc,
        uint256 openInterest
    ) internal {
        vm.mockCall(
            ENGINE,
            abi.encodeWithSignature("sides(uint256)", uint256(side)),
            abi.encode(maxProfitUsdc, openInterest, uint256(0), uint256(0))
        );
    }

    function _assertSnapshot(
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory expected
    ) internal {
        uint256 gasBefore = gasleft();
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory actual = lens.getProtocolAccountingSnapshot();
        emit log_named_uint("protocol_snapshot_gas", gasBefore - gasleft());
        assertEq(actual.poolAssetsUsdc, expected.poolAssetsUsdc, "physical assets");
        assertEq(actual.netPhysicalAssetsUsdc, expected.netPhysicalAssetsUsdc, "treasury-adjusted assets");
        assertEq(actual.maxLiabilityUsdc, expected.maxLiabilityUsdc, "maximum directional liability");
        assertEq(actual.effectiveSolvencyAssetsUsdc, expected.effectiveSolvencyAssetsUsdc, "claim-adjusted solvency");
        assertEq(actual.withdrawalReservedUsdc, expected.withdrawalReservedUsdc, "liability, claims, and buffer");
        assertEq(actual.freeUsdc, expected.freeUsdc, "free liquidity");
        assertEq(actual.protocolTreasuryBalanceUsdc, expected.protocolTreasuryBalanceUsdc, "treasury balance");
        assertEq(actual.totalTraderClaimBalanceUsdc, expected.totalTraderClaimBalanceUsdc, "trader claims");
        assertEq(actual.degradedMode, expected.degradedMode, "engine degraded-mode flag");
        assertEq(actual.hasLiveLiability, expected.hasLiveLiability, "live liability flag");
        assertEq(
            keccak256(abi.encode(lens.getProtocolAccountingSnapshot())),
            keccak256(abi.encode(actual)),
            "repeated snapshot must be stable"
        );
    }

    function test_ProtocolSnapshotSeparatesTreasuryFromSolvencyAndReserves() public {
        _assertSnapshot(
            ProtocolLensViewTypes.ProtocolAccountingSnapshot(
                100_000e6, 90_000e6, 35_000e6, 95_000e6, 40_437_500_000, 59_562_500_000, 10_000e6, 5000e6, false, true
            )
        );
    }

    function test_ProtocolSnapshotFloorsTreasuryAdjustedAssetsIndependently() public {
        vm.mockCall(
            CLEARINGHOUSE, abi.encodeWithSignature("balanceUsdc(address)", TREASURY), abi.encode(uint256(125_000e6))
        );
        _assertSnapshot(
            ProtocolLensViewTypes.ProtocolAccountingSnapshot(
                100_000e6, 0, 35_000e6, 95_000e6, 40_437_500_000, 59_562_500_000, 125_000e6, 5000e6, false, true
            )
        );
    }

    function test_ProtocolSnapshotFloorsAssetsWhenClaimsExceedCustody() public {
        vm.mockCall(ENGINE, abi.encodeWithSignature("totalTraderClaimBalanceUsdc()"), abi.encode(uint256(125_000e6)));
        vm.mockCall(ENGINE, abi.encodeWithSignature("degradedMode()"), abi.encode(true));
        _assertSnapshot(
            ProtocolLensViewTypes.ProtocolAccountingSnapshot(
                100_000e6, 90_000e6, 35_000e6, 0, 160_437_500_000, 0, 10_000e6, 125_000e6, true, true
            )
        );
    }

    function test_ProtocolSnapshotPreservesEngineModeWhenInsolvent() public {
        vm.mockCall(POOL, abi.encodeWithSignature("totalAssets()"), abi.encode(uint256(30_000e6)));
        _assertSnapshot(
            ProtocolLensViewTypes.ProtocolAccountingSnapshot(
                30_000e6, 20_000e6, 35_000e6, 25_000e6, 40_437_500_000, 0, 10_000e6, 5000e6, false, true
            )
        );
    }

    function test_ProtocolSnapshotOpenInterestAloneDoesNotCreateLiveLiability() public {
        _mockSide(CfdTypes.Side.LONG, 0, 20_000e18);
        _mockSide(CfdTypes.Side.SHORT, 0, 35_000e18);
        _assertSnapshot(
            ProtocolLensViewTypes.ProtocolAccountingSnapshot(
                100_000e6, 90_000e6, 0, 95_000e6, 5000e6, 95_000e6, 10_000e6, 5000e6, false, false
            )
        );
    }

    function test_ProtocolSnapshotRoundsLongLiabilityBufferUp() public {
        _mockSide(CfdTypes.Side.LONG, 1, 1e18);
        _mockSide(CfdTypes.Side.SHORT, 0, 0);
        _assertSnapshot(
            ProtocolLensViewTypes.ProtocolAccountingSnapshot(
                100_000e6, 90_000e6, 1, 95_000e6, 5000e6 + 2, 95_000e6 - 2, 10_000e6, 5000e6, false, true
            )
        );
    }

    function test_ProtocolSnapshotPreservesCheckedLiabilitySum() public {
        _mockSide(CfdTypes.Side.LONG, type(uint256).max / 2 + 1, 0);
        _mockSide(CfdTypes.Side.SHORT, type(uint256).max / 2 + 1, 0);
        vm.mockCall(ENGINE, abi.encodeWithSignature("totalTraderClaimBalanceUsdc()"), abi.encode(uint256(0)));
        vm.mockCall(ENGINE, abi.encodeWithSignature("settlementBufferBps()"), abi.encode(uint256(0)));
        vm.expectRevert(stdError.arithmeticError);
        lens.getProtocolAccountingSnapshot();
    }

}
