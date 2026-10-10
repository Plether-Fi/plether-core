// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";

import {PletherOracle} from "@plether/perps/PletherOracle.sol";

import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

import {MockPyth} from "@plether/test-utils/MockPyth.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {OrderRouterPythTestBase} from "../../shared/OrderRouterTestBase.sol";

contract OrderRouterOracleConfigurationTest is OrderRouterPythTestBase {

    using stdStorage for StdStorage;

    function test_OracleConfigTimelock_RotatesPythBasket() public {
        _startRecordingLogs();
        MockPyth newPyth = new MockPyth();
        bytes32[] memory newFeedIds = new bytes32[](2);
        uint256[] memory newWeights = new uint256[](2);
        uint256[] memory newBases = new uint256[](2);
        bool[] memory newInversions = new bool[](2);

        newFeedIds[0] = bytes32(uint256(101));
        newFeedIds[1] = bytes32(uint256(202));
        newWeights[0] = 0.7e18;
        newWeights[1] = 0.3e18;
        newBases[0] = 1e8;
        newBases[1] = 1e8;

        PletherOracle newOracle = new PletherOracle(
            address(engine), address(pool), address(newPyth), newFeedIds, newWeights, newBases, newInversions
        );
        IOrderRouterAdminHost.OracleConfig memory config =
            IOrderRouterAdminHost.OracleConfig({pletherOracle: address(newOracle)});

        routerAdmin.proposeOracleConfig(config);
        vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__TimelockNotReady.selector);
        routerAdmin.finalizeOracleConfig();

        vm.warp(block.timestamp + 48 hours + 1);
        routerAdmin.finalizeOracleConfig();

        assertEq(address(router.pletherOracle().pyth()), address(newPyth), "Pyth endpoint should rotate after timelock");
        PletherOracle rotatedOracle = PletherOracle(address(router.pletherOracle()));
        assertEq(address(rotatedOracle), address(newOracle), "Oracle endpoint should rotate after timelock");
        assertEq(rotatedOracle.pythFeedIds(0), newFeedIds[0], "First feed id should rotate");
        assertEq(rotatedOracle.pythFeedIds(1), newFeedIds[1], "Second feed id should rotate");
        assertEq(rotatedOracle.quantities(0), newWeights[0], "First weight should rotate");
        assertEq(rotatedOracle.quantities(1), newWeights[1], "Second weight should rotate");
    }

    function test_OracleConfigTimelock_RejectsOracleForDifferentEngine() public {
        _startRecordingLogs();
        PletherOracle wrongEngineOracle = new PletherOracle(
            address(0xE111), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2)
        );
        IOrderRouterAdminHost.OracleConfig memory config =
            IOrderRouterAdminHost.OracleConfig({pletherOracle: address(wrongEngineOracle)});

        routerAdmin.proposeOracleConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);

        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidPletherOracle.selector);
        routerAdmin.finalizeOracleConfig();
    }

    function test_OracleConfigTimelock_RejectsOracleForDifferentPool() public {
        _startRecordingLogs();
        PletherOracle wrongPoolOracle = new PletherOracle(
            address(engine), address(0xB001), address(mockPyth), feedIds, weights, bases, new bool[](2)
        );
        IOrderRouterAdminHost.OracleConfig memory config =
            IOrderRouterAdminHost.OracleConfig({pletherOracle: address(wrongPoolOracle)});

        routerAdmin.proposeOracleConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);

        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidPletherOracle.selector);
        routerAdmin.finalizeOracleConfig();
    }

}

