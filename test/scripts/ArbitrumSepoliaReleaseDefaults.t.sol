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

    function defaultActivateTrading() external pure returns (bool) {
        return DEFAULT_ACTIVATE_TRADING;
    }

}

contract ArbitrumSepoliaReleaseDefaultsTest is Test {

    function test_DeployAndBootstrapScripts_RejectWrongChain() public {
        vm.chainId(1);

        DeployPerpsArbitrumSepolia deployScript = new DeployPerpsArbitrumSepolia();
        vm.expectRevert(
            abi.encodeWithSelector(DeployPerpsArbitrumSepolia.DeployPerpsArbitrumSepolia__WrongChain.selector, 1)
        );
        deployScript.run();

        BootstrapPerpsArbitrumSepolia bootstrapScript = new BootstrapPerpsArbitrumSepolia();
        vm.expectRevert(
            abi.encodeWithSelector(BootstrapPerpsArbitrumSepolia.BootstrapPerpsArbitrumSepolia__WrongChain.selector, 1)
        );
        bootstrapScript.run();
    }

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
        assertEq(engine.fadMaxStaleness(), 3 days, "fad max staleness");
        assertEq(engine.engineMarkStalenessLimit(), 60, "engine mark staleness");

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

    function test_RecurringCalendar_MatchesArbitrumSepoliaReleasePacket() public {
        DeployPerpsArbitrumSepoliaHarness deployScript = new DeployPerpsArbitrumSepoliaHarness();
        MockUSDC usdc = new MockUSDC();
        MarginClearinghouse clearinghouse = new MarginClearinghouse(address(usdc));
        CfdEngine engine = new CfdEngine(
            address(usdc), address(clearinghouse), 2e8, deployScript.riskParams(), deployScript.frozenCloseSpreadBps()
        );

        vm.warp(1_709_933_399); // Friday 21:29:59 UTC
        assertFalse(engine.isFadWindow(), "FAD must be inactive before the live-oracle shoulder");
        assertFalse(engine.isOracleFrozen(), "Oracle must be live before the freeze boundary");

        vm.warp(1_709_933_400); // Friday 21:30:00 UTC
        assertTrue(engine.isFadWindow(), "FAD must begin 30 minutes before freeze");
        assertFalse(engine.isOracleFrozen(), "Oracle must remain live during the first FAD shoulder");

        vm.warp(1_709_935_200); // Friday 22:00:00 UTC
        assertTrue(engine.isFadWindow(), "FAD must remain active during freeze");
        assertTrue(engine.isOracleFrozen(), "Oracle freeze must begin Friday at 22:00 UTC");

        vm.warp(1_710_104_400); // Sunday 21:00:00 UTC
        assertTrue(engine.isFadWindow(), "FAD must remain active during the second shoulder");
        assertFalse(engine.isOracleFrozen(), "Oracle freeze must end Sunday at 21:00 UTC");

        vm.warp(1_710_105_300); // Sunday 21:15:00 UTC
        assertFalse(engine.isFadWindow(), "FAD must end after the 15-minute live-oracle shoulder");
        assertFalse(engine.isOracleFrozen(), "Oracle must remain live after FAD ends");
    }

    function test_BootstrapDefaults_MatchArbitrumSepoliaReleaseSeeds() public {
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();

        assertEq(bootstrapScript.defaultSeniorSeedUsdc(), 50_000_000e6, "senior seed");
        assertEq(bootstrapScript.defaultJuniorSeedUsdc(), 50_000_000e6, "junior seed");
        assertFalse(
            bootstrapScript.defaultActivateTrading(), "trading activation must require an explicit bootstrap rerun"
        );
    }

}
