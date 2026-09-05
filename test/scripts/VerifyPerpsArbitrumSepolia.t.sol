// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BootstrapPerpsArbitrumSepolia} from "../../script/BootstrapPerpsArbitrumSepolia.s.sol";
import {DeployPerpsArbitrumSepolia} from "../../script/DeployPerpsArbitrumSepolia.s.sol";
import {VerifyPerpsArbitrumSepolia} from "../../script/VerifyPerpsArbitrumSepolia.s.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {Test} from "forge-std/Test.sol";

contract VerifyPerpsArbitrumSepoliaTest is Test {

    address internal constant RELEASE_PYTH = 0x0B73614636C855Bf23F342F307FB981A3e47f42B;
    uint256 internal constant DEPLOYER_KEY = 0xA11CE;

    function test_VerifiesOneUsdcReleaseAcrossDeploymentSeedingAndActivation() public {
        vm.chainId(421_614);
        MockPyth pyth = new MockPyth();
        vm.etch(RELEASE_PYTH, address(pyth).code);
        vm.setEnv("TEST_PRIVATE_KEY", vm.toString(DEPLOYER_KEY));

        DeployPerpsArbitrumSepolia deployScript = new DeployPerpsArbitrumSepolia();
        DeployPerpsArbitrumSepolia.DeployedContracts memory deployed = deployScript.run();

        _setAddress("PERPS_OWNER", vm.addr(DEPLOYER_KEY));
        _setAddress("PERPS_GUARDIAN", address(0xBEEF));
        _setAddress("PERPS_USDC", address(deployed.usdc));
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
        _setAddress("PERPS_ORDER_EXECUTION_SIDECAR", address(deployed.orderExecutionSidecar));
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

        _setAddress("SENIOR_SEED_RECEIVER", address(0x5151));
        _setAddress("JUNIOR_SEED_RECEIVER", address(0x7171));
        vm.setEnv("SENIOR_SEED_USDC", "1000000");
        vm.setEnv("JUNIOR_SEED_USDC", "1000000");
        vm.setEnv("ACTIVATE_TRADING", "false");
        BootstrapPerpsArbitrumSepolia bootstrap = new BootstrapPerpsArbitrumSepolia();
        bootstrap.run();

        assertEq(deployed.housePool.seniorPrincipal(), 1e6, "one USDC senior backing");
        assertEq(deployed.housePool.juniorPrincipal(), 1e6, "one USDC junior backing");
        assertEq(deployed.usdc.totalSupply(), 2e6, "only two USDC minted for seeds");
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
        assertEq(deployed.usdc.totalSupply(), 2e6, "seed rerun must not mint again");
        assertEq(deployed.seniorVault.totalSupply(), seniorShares, "senior seed rerun is a no-op");
        assertEq(deployed.juniorVault.totalSupply(), juniorShares, "junior seed rerun is a no-op");
        assertFalse(deployed.housePool.isTradingActive(), "seed rerun must stay inactive");

        vm.setEnv("ACTIVATE_TRADING", "true");
        bootstrap.run();
        vm.setEnv("VERIFY_PHASE", "active");
        verifier.run();
        assertTrue(deployed.housePool.isTradingActive());
        assertEq(deployed.usdc.totalSupply(), 2e6, "activation must not repeat seed funding");
    }

    function _setAddress(
        string memory key,
        address value
    ) internal {
        vm.setEnv(key, vm.toString(value));
    }

}
