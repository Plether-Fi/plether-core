// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {DeployPerpsArbitrumSepolia} from "../../script/DeployPerpsArbitrumSepolia.s.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Reuses the release's actual constructor configuration instead of duplicating economic values or feed arrays.
contract PerpsReleaseSizeDeployment is DeployPerpsArbitrumSepolia {

    function engineArguments(
        address usdc,
        address clearinghouse
    ) external pure returns (bytes memory) {
        return abi.encode(usdc, clearinghouse, CAP_PRICE, _riskParams(), FROZEN_CLOSE_SPREAD_BPS);
    }

    function oracleArguments(
        address engine,
        address housePool
    ) external pure returns (bytes memory) {
        return abi.encode(engine, housePool, PYTH, _pythFeedIds(), _quantities(), _basePrices(), _inversions());
    }

    function terminalNavArguments(
        address engine
    ) external pure returns (bytes memory) {
        return abi.encode(engine, uint256(CAP_PRICE));
    }

}

/// @notice Local-EVM deployment evidence only. Never invoke this test as a broadcast script or on a remote fork.
/// @dev The exporter consumes the RELEASE_SIZE JSON log for every manifest entry, including embedded deployments.
contract PerpsReleaseDeploymentSizeTest is Test {

    string internal constant DEPLOY_SCRIPT = "DeployPerpsArbitrumSepolia.s.sol:";
    address internal constant RELEASE_PYTH = 0x0B73614636C855Bf23F342F307FB981A3e47f42B;
    uint256 internal constant LOCAL_DEPLOYER_KEY = 0xA11CE;

    function test_AllReleaseContractsFitFullDeploymentLimits() public {
        vm.chainId(421_614);
        MockPyth pyth = new MockPyth();
        vm.etch(RELEASE_PYTH, address(pyth).code);
        vm.setEnv("TEST_PRIVATE_KEY", vm.toString(LOCAL_DEPLOYER_KEY));
        PerpsReleaseSizeDeployment deployment = new PerpsReleaseSizeDeployment();
        DeployPerpsArbitrumSepolia.DeployedContracts memory d = deployment.run();
        address owner = vm.addr(LOCAL_DEPLOYER_KEY);

        _measure("mockUsdc", string.concat(DEPLOY_SCRIPT, "MockUSDC"), address(d.usdc), "");
        _measure(
            "marginClearinghouse",
            "MarginClearinghouse.sol:MarginClearinghouse",
            address(d.clearinghouse),
            abi.encode(address(d.usdc))
        );
        _measure(
            "cfdEngine",
            "CfdEngine.sol:CfdEngine",
            address(d.engine),
            deployment.engineArguments(address(d.usdc), address(d.clearinghouse))
        );
        _measure(
            "terminalNavBookV2",
            "TerminalNavBookV2.sol:TerminalNavBookV2",
            address(d.terminalNavBook),
            deployment.terminalNavArguments(address(d.engine))
        );
        _measure("cfdEnginePlanner", "CfdEnginePlanner.sol:CfdEnginePlanner", address(d.planner), "");
        _measure(
            "cfdEngineSettlementSidecar",
            "CfdEngineSettlementSidecar.sol:CfdEngineSettlementSidecar",
            address(d.settlementSidecar),
            abi.encode(address(d.engine))
        );
        _measure(
            "cfdEngineAdmin",
            "CfdEngineAdmin.sol:CfdEngineAdmin",
            address(d.engineAdmin),
            abi.encode(address(d.engine), owner)
        );
        _measure(
            "housePoolRedemptionMathSidecar",
            "HousePoolRedemptionMathSidecar.sol:HousePoolRedemptionMathSidecar",
            address(d.housePoolRedemptionMathSidecar),
            ""
        );
        _measure(
            "housePool",
            string.concat(DEPLOY_SCRIPT, "ArbitrumSepoliaReleaseHousePool"),
            address(d.housePool),
            abi.encode(address(d.usdc), address(d.engine), address(d.housePoolRedemptionMathSidecar))
        );
        _measure(
            "cfdEngineProtocolLens",
            "CfdEngineProtocolLens.sol:CfdEngineProtocolLens",
            address(d.housePool.ENGINE_PROTOCOL_LENS()),
            abi.encode(address(d.engine))
        );
        _measure(
            "seniorVault",
            "TrancheVault.sol:TrancheVault",
            address(d.seniorVault),
            abi.encode(
                address(d.usdc),
                address(d.housePool),
                true,
                d.seniorVault.name(),
                d.seniorVault.symbol(),
                d.seniorVault.maintenanceFeeAprBps(),
                d.seniorVault.maintenanceFeeRecipient()
            )
        );
        _measure(
            "juniorVault",
            "TrancheVault.sol:TrancheVault",
            address(d.juniorVault),
            abi.encode(
                address(d.usdc),
                address(d.housePool),
                false,
                d.juniorVault.name(),
                d.juniorVault.symbol(),
                d.juniorVault.maintenanceFeeAprBps(),
                d.juniorVault.maintenanceFeeRecipient()
            )
        );
        _measure(
            "cfdEngineAccountLens",
            "CfdEngineAccountLens.sol:CfdEngineAccountLens",
            address(d.accountLens),
            abi.encode(address(d.engine))
        );
        _measure(
            "cfdEngineLens", "CfdEngineLens.sol:CfdEngineLens", address(d.engineLens), abi.encode(address(d.engine))
        );
        // CfdEngineLens creates its immutable quoter with its first CREATE (contract nonces start at one).
        _measure(
            "cfdEngineOpenQuoter",
            "CfdEngineOpenQuoter.sol:CfdEngineOpenQuoter",
            vm.computeCreateAddress(address(d.engineLens), 1),
            ""
        );
        _measure(
            "cfdOrderPolicyEvaluator",
            "CfdOrderPolicyEvaluator.sol:CfdOrderPolicyEvaluator",
            address(d.orderPolicyEvaluator),
            ""
        );
        _measure(
            "cfdClosePreview",
            "CfdClosePreview.sol:CfdClosePreview",
            address(d.closePreview),
            abi.encode(address(d.engine))
        );
        _measure(
            "orderRouterExecutionSidecar",
            "OrderRouterExecutionSidecar.sol:OrderRouterExecutionSidecar",
            address(d.orderExecutionSidecar),
            ""
        );
        _measure(
            "orderRecoverySidecar",
            "OrderRecoverySidecar.sol:OrderRecoverySidecar",
            d.orderExecutionSidecar.recoverySidecar(),
            ""
        );
        _measure(
            "pletherOracle",
            string.concat(DEPLOY_SCRIPT, "ArbitrumSepoliaReleaseOracle"),
            d.pletherOracle,
            deployment.oracleArguments(address(d.engine), address(d.housePool))
        );
        _measure(
            "orderRouterLiquidationBatchSidecar",
            "OrderRouterLiquidationBatchSidecar.sol:OrderRouterLiquidationBatchSidecar",
            address(d.liquidationBatchSidecar),
            abi.encode(address(d.router))
        );
        _measure(
            "orderLifecycleBook",
            "OrderLifecycleBook.sol:OrderLifecycleBook",
            address(d.lifecycleBook),
            abi.encode(address(d.router), address(d.engine), address(d.clearinghouse), address(d.housePool))
        );
        _measure(
            "orderRouter",
            string.concat(DEPLOY_SCRIPT, "ArbitrumSepoliaReleaseRouter"),
            address(d.router),
            abi.encode(
                address(d.engine),
                address(d.engineLens),
                address(d.housePool),
                d.pletherOracle,
                address(d.liquidationBatchSidecar),
                address(d.orderPolicyEvaluator),
                address(d.orderExecutionSidecar),
                address(d.lifecycleBook)
            )
        );
        _measure(
            "orderRouterAdmin",
            "OrderRouterAdmin.sol:OrderRouterAdmin",
            d.routerAdmin,
            abi.encode(address(d.router), owner)
        );
        _measure(
            "positionProtectionBook",
            "PositionProtectionBook.sol:PositionProtectionBook",
            d.positionProtectionBook,
            abi.encode(address(d.router), address(d.engine))
        );
        _measure(
            "perpsPublicLens",
            "PerpsPublicLens.sol:PerpsPublicLens",
            address(d.publicLens),
            abi.encode(address(d.accountLens), address(d.engine), address(d.router), address(d.housePool))
        );
        _measure(
            "settlementMonitorLens",
            "SettlementMonitorLens.sol:SettlementMonitorLens",
            address(d.settlementMonitorLens),
            abi.encode(address(d.router))
        );
        _measure(
            "settlementMonitorLensSidecar",
            "SettlementMonitorLensSidecar.sol:SettlementMonitorLensSidecar",
            address(d.settlementMonitorLensSidecar),
            abi.encode(address(d.router))
        );
        _measure(
            "emergencyPauseCoordinator",
            "EmergencyPauseCoordinator.sol:EmergencyPauseCoordinator",
            address(d.emergencyPauseCoordinator),
            abi.encode(d.routerAdmin, address(d.housePool), owner)
        );
        assertFalse(d.housePool.isTradingActive(), "local size fixture must remain inactive");
    }

    function _measure(
        string memory key,
        string memory artifact,
        address deployed,
        bytes memory arguments
    ) internal {
        bytes memory creationCode = vm.getCode(artifact);
        bytes memory creationInput = bytes.concat(creationCode, arguments);
        bytes memory runtime = deployed.code;
        assertGt(runtime.length, 0, string.concat(key, ": missing deployed runtime"));
        assertLe(runtime.length, 24_576, string.concat(key, ": runtime exceeds EIP-170"));
        assertLe(creationInput.length, 49_152, string.concat(key, ": full creation input exceeds EIP-3860"));

        vm.serializeString(key, "contractKey", key);
        vm.serializeString(key, "artifact", artifact);
        vm.serializeAddress(key, "localAddress", deployed);
        vm.serializeBytes(key, "constructorArguments", arguments);
        vm.serializeUint(key, "runtimeBytes", runtime.length);
        vm.serializeUint(key, "creationCodeBytes", creationCode.length);
        vm.serializeUint(key, "creationInputBytes", creationInput.length);
        vm.serializeBytes32(key, "creationInputSha256", sha256(creationInput));
        string memory result = vm.serializeBytes32(key, "runtimeSha256", sha256(runtime));
        emit log(string.concat("RELEASE_SIZE ", result));
    }

}
