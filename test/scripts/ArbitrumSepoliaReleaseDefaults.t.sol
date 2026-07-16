// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BootstrapPerpsArbitrumSepolia} from "../../script/BootstrapPerpsArbitrumSepolia.s.sol";
import {DeployPerpsArbitrumSepolia, MockUSDC} from "../../script/DeployPerpsArbitrumSepolia.s.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {Test} from "forge-std/Test.sol";

contract DeployPerpsArbitrumSepoliaHarness is DeployPerpsArbitrumSepolia {

    function riskParams() external pure returns (CfdTypes.RiskParams memory) {
        return _riskParams();
    }

    function frozenCloseSpreadBps() external pure returns (uint256) {
        return FROZEN_CLOSE_SPREAD_BPS;
    }

}

contract BootstrapPerpsArbitrumSepoliaHarness is BootstrapPerpsArbitrumSepolia {

    function defaultSeniorSeedUsdc() external pure returns (uint256) {
        return DEFAULT_SENIOR_SEED_USDC;
    }

    function defaultJuniorSeedUsdc() external pure returns (uint256) {
        return DEFAULT_JUNIOR_SEED_USDC;
    }

}

contract ArbitrumSepoliaReleaseDefaultsTest is Test {

    function test_DeployScriptRiskDefaults_MatchArbitrumSepoliaReleaseParams() public {
        DeployPerpsArbitrumSepoliaHarness deployScript = new DeployPerpsArbitrumSepoliaHarness();

        CfdTypes.RiskParams memory params = deployScript.riskParams();

        assertEq(params.vpiFactor, 0.005e18, "vpi factor");
        assertEq(deployScript.frozenCloseSpreadBps(), 50, "frozen close spread");
        assertEq(params.maxSkewRatio, 0.4e18, "max skew");
        assertEq(params.maintMarginBps, 30, "maintenance margin");
        assertEq(params.initMarginBps, 45, "initial margin");
        assertEq(params.fadMarginBps, 300, "fad margin");
        assertEq(params.baseCarryBps, 500, "base carry");
        assertEq(params.minBountyUsdc, 1e6, "min bounty");
        assertEq(params.bountyBps, 10, "bounty bps");
    }

    function test_CoreDefaultConfigs_MatchArbitrumSepoliaReleaseParams() public {
        DeployPerpsArbitrumSepoliaHarness deployScript = new DeployPerpsArbitrumSepoliaHarness();
        MockUSDC usdc = new MockUSDC();
        MarginClearinghouse clearinghouse = new MarginClearinghouse(address(usdc));
        CfdEngine engine = new CfdEngine(
            address(usdc), address(clearinghouse), 2e8, deployScript.riskParams(), deployScript.frozenCloseSpreadBps()
        );

        assertEq(engine.executionFeeBps(), 4, "execution fee");
        assertEq(engine.frozenCloseSpreadBps(), 50, "frozen close spread");
        assertEq(engine.fadRunwaySeconds(), 1 hours, "fad runway");

        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = bytes32(uint256(1));
        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1e18;
        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = 1e8;
        bool[] memory inversions = new bool[](1);

        MockPyth pyth = new MockPyth();
        PletherOracle oracle = new PletherOracle(
            address(engine), address(0xBEEF), address(pyth), feedIds, quantities, basePrices, inversions
        );

        assertEq(oracle.pythMaxConfidenceRatioBps(), 10, "pyth confidence ratio");
        assertEq(oracle.adverseConfidenceMultiplierBps(), 2000, "adverse confidence multiplier");
    }

    function test_BootstrapDefaults_MatchArbitrumSepoliaReleaseSeeds() public {
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();

        assertEq(bootstrapScript.defaultSeniorSeedUsdc(), 50_000_000e6, "senior seed");
        assertEq(bootstrapScript.defaultJuniorSeedUsdc(), 50_000_000e6, "junior seed");
    }

}
