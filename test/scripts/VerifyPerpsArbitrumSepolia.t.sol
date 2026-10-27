// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BootstrapPerpsArbitrumSepolia} from "../../script/BootstrapPerpsArbitrumSepolia.s.sol";
import {DeployPerpsArbitrumSepolia, MockUSDG} from "../../script/DeployPerpsArbitrumSepolia.s.sol";
import {ArbitrumSepoliaReleaseRouter} from "../../script/DeployPerpsArbitrumSepolia.s.sol";
import {VerifyPerpsArbitrumSepolia} from "../../script/VerifyPerpsArbitrumSepolia.s.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {SettlementMonitorLens} from "@plether/perps/SettlementMonitorLens.sol";
import {Test} from "forge-std/Test.sol";

contract VerifyPerpsArbitrumSepoliaTest is Test {

    address internal constant RELEASE_PYTH = 0x0B73614636C855Bf23F342F307FB981A3e47f42B;
    uint256 internal constant DEPLOYER_KEY = 0xA11CE;

    function test_VerifiesMockUSDGReleaseAcrossDeploymentSeedingAndActivation() public {
        vm.chainId(421_614);
        MockPyth pyth = new MockPyth();
        vm.etch(RELEASE_PYTH, address(pyth).code);
        vm.setEnv("TEST_PRIVATE_KEY", vm.toString(DEPLOYER_KEY));

        DeployPerpsArbitrumSepolia deployScript = new DeployPerpsArbitrumSepolia();
        DeployPerpsArbitrumSepolia.DeployedContracts memory deployed = deployScript.run();
        _assertDeploymentLimits(deployed);
        assertEq(deployed.juniorVault.maintenanceFeeAprBps(), 0, "Junior maintenance fee starts disabled");
        assertEq(
            deployed.juniorVault.maintenanceFeeRecipient(),
            deployed.engine.protocolTreasury(),
            "Junior fee recipient remains treasury"
        );

        _setAddress("PERPS_OWNER", vm.addr(DEPLOYER_KEY));
        _setAddress("PERPS_GUARDIAN", address(0xBEEF));
        _setAddress("PERPS_SETTLEMENT_TOKEN", address(deployed.settlementToken));
        _setAddress("PERPS_CLEARINGHOUSE", address(deployed.clearinghouse));
        _setAddress("PERPS_ENGINE", address(deployed.engine));
        _setAddress("PERPS_TERMINAL_NAV_BOOK", address(deployed.terminalNavBook));
        _setAddress("PERPS_ENGINE_PLANNER", address(deployed.planner));
        _setAddress("PERPS_ENGINE_SETTLEMENT_SIDECAR", address(deployed.settlementSidecar));
        _setAddress("PERPS_ENGINE_ADMIN", address(deployed.engineAdmin));
        _setAddress("PERPS_HOUSE_POOL_REDEMPTION_MATH_SIDECAR", address(deployed.housePoolRedemptionMathSidecar));
        _setAddress("PERPS_HOUSE_POOL", address(deployed.housePool));
        _setAddress("PERPS_SENIOR_VAULT", address(deployed.seniorVault));
        _setAddress("PERPS_JUNIOR_VAULT", address(deployed.juniorVault));
        _setAddress("PERPS_ACCOUNT_LENS", address(deployed.accountLens));
        _setAddress("PERPS_ENGINE_LENS", address(deployed.engineLens));
        _setAddress("PERPS_ORDER_POLICY_EVALUATOR", address(deployed.orderPolicyEvaluator));
        _setAddress("PERPS_CLOSE_PREVIEW", address(deployed.closePreview));
        _setAddress("PERPS_ORDER_EXECUTION_SIDECAR", address(deployed.orderExecutionSidecar));
        _setAddress("PERPS_ORDER_RECOVERY_SIDECAR", deployed.orderExecutionSidecar.recoverySidecar());
        _setAddress("PERPS_ORDER_ROUTER", address(deployed.router));
        _setAddress("PERPS_LIQUIDATION_BATCH_SIDECAR", address(deployed.liquidationBatchSidecar));
        _setAddress("PERPS_ORDER_LIFECYCLE_BOOK", address(deployed.lifecycleBook));
        _setAddress("PERPS_POSITION_PROTECTION_BOOK", deployed.positionProtectionBook);
        _setAddress("PERPS_ORACLE", deployed.pletherOracle);
        _setAddress("PERPS_ORDER_ROUTER_ADMIN", deployed.routerAdmin);
        _setAddress("PERPS_PUBLIC_LENS", address(deployed.publicLens));
        _setAddress("PERPS_SETTLEMENT_MONITOR_LENS", address(deployed.settlementMonitorLens));
        _setAddress("PERPS_SETTLEMENT_MONITOR_SIDECAR", address(deployed.settlementMonitorLensSidecar));
        _setAddress("PERPS_EMERGENCY_COORDINATOR", address(deployed.emergencyPauseCoordinator));
        vm.setEnv("VERIFY_PHASE", "deployed");

        VerifyPerpsArbitrumSepolia verifier = new VerifyPerpsArbitrumSepolia();
        verifier.run();
        assertEq(deployed.settlementToken.name(), "Mock USDG");
        assertEq(deployed.settlementToken.symbol(), "USDG");
        assertEq(deployed.settlementToken.decimals(), 6);

        vm.mockCall(address(deployed.engine), abi.encodeWithSignature("planningReader()"), abi.encode(address(0xBAD)));
        vm.expectRevert(bytes("Engine planning reader has no code"));
        verifier.run();
        vm.clearMockedCalls();
        vm.mockCall(
            address(deployed.engine.planningReader()), abi.encodeWithSignature("ENGINE()"), abi.encode(address(0xBAD))
        );
        vm.expectRevert(bytes("Engine planning reader binding mismatch"));
        verifier.run();
        vm.clearMockedCalls();

        vm.mockCall(address(deployed.settlementToken), abi.encodeWithSignature("name()"), abi.encode("Mock USDC"));
        vm.expectRevert(bytes("Settlement token name mismatch"));
        verifier.run();
        vm.clearMockedCalls();
        vm.mockCall(address(deployed.settlementToken), abi.encodeWithSignature("symbol()"), abi.encode("USDC"));
        vm.expectRevert(bytes("Settlement token symbol mismatch"));
        verifier.run();
        vm.clearMockedCalls();
        vm.mockCall(address(deployed.settlementToken), abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.expectRevert(bytes("Settlement token decimals mismatch"));
        verifier.run();
        vm.clearMockedCalls();

        // A second mock has the right metadata but is not the stack's configured settlement asset.
        MockUSDG wrongSettlementToken = new MockUSDG();
        _setAddress("PERPS_SETTLEMENT_TOKEN", address(wrongSettlementToken));
        vm.expectRevert(bytes("Clearinghouse asset mismatch"));
        verifier.run();
        _setAddress("PERPS_SETTLEMENT_TOKEN", address(deployed.settlementToken));

        assertGt(address(deployed.closePreview).code.length, 0);
        assertTrue(deployed.router.policyEvaluator() != address(deployed.closePreview));
        // Even a code-bearing evaluator must not be accepted as the preview's manifest entry.
        _setAddress("PERPS_CLOSE_PREVIEW", address(deployed.orderPolicyEvaluator));
        vm.expectRevert(bytes("Close preview must not be the router evaluator"));
        verifier.run();
        _setAddress("PERPS_CLOSE_PREVIEW", address(deployed.closePreview));

        _setAddress("SENIOR_SEED_RECEIVER", address(0x5151));
        _setAddress("JUNIOR_SEED_RECEIVER", address(0x7171));
        vm.setEnv("SENIOR_SEED_ASSETS", "1000000");
        vm.setEnv("JUNIOR_SEED_ASSETS", "1000000");
        vm.setEnv("ACTIVATE_TRADING", "false");
        // Empty optional arrays make the initial seed-only pass independent of the caller's environment.
        vm.setEnv("TEST_USER_RECIPIENTS", "");
        vm.setEnv("TEST_USER_AMOUNTS", "");
        BootstrapPerpsArbitrumSepolia bootstrap = new BootstrapPerpsArbitrumSepolia();
        _setAddress("PERPS_SETTLEMENT_TOKEN", address(wrongSettlementToken));
        vm.expectRevert(bytes("PERPS_SETTLEMENT_TOKEN does not match HousePool"));
        bootstrap.run();
        assertEq(deployed.settlementToken.totalSupply(), 0, "wrong configuration must not mint seeds");
        _setAddress("PERPS_SETTLEMENT_TOKEN", address(deployed.settlementToken));
        bootstrap.run();

        assertEq(deployed.housePool.seniorPrincipal(), 1e6, "one Mock USDG senior backing");
        assertEq(deployed.housePool.juniorPrincipal(), 1e6, "one Mock USDG junior backing");
        assertEq(deployed.settlementToken.totalSupply(), 2e6, "only two Mock USDG minted for seeds");
        assertEq(deployed.seniorVault.seedReceiver(), address(0x5151));
        assertEq(deployed.juniorVault.seedReceiver(), address(0x7171));
        assertGt(deployed.seniorVault.seedShareFloor(), 0);
        assertGt(deployed.juniorVault.seedShareFloor(), 0);
        assertFalse(deployed.housePool.isTradingActive(), "seeding must not activate trading");
        vm.setEnv("VERIFY_PHASE", "seeded");
        verifier.run();

        uint256 seniorShares = deployed.seniorVault.totalSupply();
        uint256 juniorShares = deployed.juniorVault.totalSupply();
        bootstrap.run();
        assertEq(deployed.settlementToken.totalSupply(), 2e6, "seed rerun must not mint again");
        assertEq(deployed.seniorVault.totalSupply(), seniorShares, "senior seed rerun is a no-op");
        assertEq(deployed.juniorVault.totalSupply(), juniorShares, "junior seed rerun is a no-op");
        assertFalse(deployed.housePool.isTradingActive(), "seed rerun must stay inactive");

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = abi.encode(uint256(1e8));
        vm.setEnv("PYTH_UPDATE_DATA", vm.toString(abi.encode(updateData)));
        vm.setEnv("ACTIVATE_TRADING", "true");
        bootstrap.run();
        vm.setEnv("VERIFY_PHASE", "active");
        verifier.run();
        assertTrue(deployed.housePool.isTradingActive());
        assertEq(deployed.settlementToken.totalSupply(), 2e6, "activation must not repeat seed funding");

        vm.setEnv("TEST_USER_RECIPIENTS", vm.toString(address(0xF00D)));
        vm.setEnv("TEST_USER_AMOUNTS", "25000000");
        bootstrap.run();
        bootstrap.run();
        assertEq(deployed.settlementToken.balanceOf(address(0xF00D)), 50e6, "optional tester funding repeats");
        assertEq(deployed.settlementToken.totalSupply(), 52e6, "permanent seeds remain unchanged on funding reruns");
        assertEq(deployed.seniorVault.totalSupply(), seniorShares, "tester funding preserves senior seed");
        assertEq(deployed.juniorVault.totalSupply(), juniorShares, "tester funding preserves junior seed");
        vm.warp(block.timestamp + 365 days);
        assertEq(deployed.juniorVault.pendingMaintenanceFeeShares(), 0, "disabled fee must not accrue");
    }

    function _setAddress(
        string memory key,
        address value
    ) internal {
        vm.setEnv(key, vm.toString(value));
    }

    function _assertDeploymentLimits(
        DeployPerpsArbitrumSepolia.DeployedContracts memory d
    ) private view {
        address[25] memory contracts = [
            address(d.settlementToken),
            address(d.clearinghouse),
            address(d.engine),
            address(d.terminalNavBook),
            address(d.planner),
            address(d.settlementSidecar),
            address(d.engineAdmin),
            address(d.housePoolRedemptionMathSidecar),
            address(d.housePool),
            address(d.seniorVault),
            address(d.juniorVault),
            address(d.accountLens),
            address(d.engineLens),
            address(d.orderPolicyEvaluator),
            address(d.closePreview),
            address(d.orderExecutionSidecar),
            d.orderExecutionSidecar.recoverySidecar(),
            address(d.router),
            address(d.liquidationBatchSidecar),
            d.positionProtectionBook,
            address(d.lifecycleBook),
            d.pletherOracle,
            d.routerAdmin,
            address(d.publicLens),
            address(d.settlementMonitorLens)
        ];
        for (uint256 i; i < contracts.length; ++i) {
            assertLe(contracts[i].code.length, 24_576, "deployed runtime exceeds EIP-170");
        }
        assertLe(address(d.settlementMonitorLensSidecar).code.length, 24_576);
        assertLe(address(d.engine.planningReader()).code.length, 24_576);
        assertLe(address(d.emergencyPauseCoordinator).code.length, 24_576);
        // These constructors embed other deployable contracts and are the limiting initcode paths.
        assertLe(
            type(ArbitrumSepoliaReleaseRouter).creationCode.length + 8 * 32,
            49_152,
            "release router including constructor arguments exceeds EIP-3860"
        );
        assertLe(
            type(SettlementMonitorLens).creationCode.length + 32,
            49_152,
            "monitor including constructor argument exceeds EIP-3860"
        );
    }

}
