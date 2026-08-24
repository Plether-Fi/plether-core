// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BootstrapPerpsArbitrumSepolia} from "../../script/BootstrapPerpsArbitrumSepolia.s.sol";
import {DeployPerpsArbitrumSepolia, MockUSDC} from "../../script/DeployPerpsArbitrumSepolia.s.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {Test} from "forge-std/Test.sol";

contract DeployPerpsArbitrumSepoliaHarness is DeployPerpsArbitrumSepolia {

    function riskParams() external pure returns (CfdTypes.RiskParams memory) {
        return _riskParams();
    }

    function frozenCloseSpreadBps() external pure returns (uint256) {
        return FROZEN_CLOSE_SPREAD_BPS;
    }

    function verifyAsyncVaultPair(
        HousePool housePool,
        TrancheVault seniorVault,
        TrancheVault juniorVault,
        MockUSDC usdc
    ) external view {
        _verifyAsyncVaultPair(housePool, seniorVault, juniorVault, usdc);
    }

    function verifyPositionProtectionBook(
        OrderRouter router,
        CfdEngine engine
    ) external view returns (address book) {
        return _verifyPositionProtectionBook(router, engine);
    }

}

contract BootstrapPerpsArbitrumSepoliaHarness is BootstrapPerpsArbitrumSepolia {

    function defaultSeniorSeedUsdc() external pure returns (uint256) {
        return DEFAULT_SENIOR_SEED_USDC;
    }

    function defaultJuniorSeedUsdc() external pure returns (uint256) {
        return DEFAULT_JUNIOR_SEED_USDC;
    }

    function validateSeniorLimits(
        uint256 maxSeniorExposureUsdc,
        uint256 maxSeniorShareBps
    ) external pure {
        _validateSeniorLimits(maxSeniorExposureUsdc, maxSeniorShareBps);
    }

    function deployConfigTestPool(
        address usdc
    ) external returns (HousePool) {
        return new HousePool(usdc, address(0xE11E));
    }

    function configureSeniorLimits(
        HousePool housePool,
        uint256 maxSeniorExposureUsdc,
        uint256 maxSeniorShareBps
    ) external returns (bool) {
        return _configureSeniorLimits(housePool, maxSeniorExposureUsdc, maxSeniorShareBps);
    }

    function verifyTerminalNavBook(
        HousePool housePool
    ) external view {
        _verifyTerminalNavBook(housePool);
    }

    function verifyAsyncVaultPair(
        HousePool housePool,
        address usdc
    ) external view {
        _verifyAsyncVaultPair(housePool, usdc);
    }

    function verifyRouterWiring(
        HousePool housePool,
        OrderRouter router
    ) external view {
        _verifyRouterWiring(housePool, router);
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
        assertEq(params.keeperShareBps, 5000, "keeper share bps");
        assertEq(params.protocolShareBps, 0, "protocol share bps");
    }

    function test_CoreDefaultConfigs_MatchArbitrumSepoliaReleaseParams() public {
        DeployPerpsArbitrumSepoliaHarness deployScript = new DeployPerpsArbitrumSepoliaHarness();
        MockUSDC usdc = new MockUSDC();
        MarginClearinghouse clearinghouse = new MarginClearinghouse(address(usdc));
        CfdEngine engine = new CfdEngine(
            address(usdc), address(clearinghouse), 2e8, deployScript.riskParams(), deployScript.frozenCloseSpreadBps()
        );
        TerminalNavBookV2 terminalNavBook = new TerminalNavBookV2(address(engine), 2e8);
        engine.setTerminalNavBook(address(terminalNavBook));

        assertEq(engine.executionFeeBps(), 4, "execution fee");
        assertEq(engine.frozenCloseSpreadBps(), 50, "frozen close spread");
        assertEq(engine.fadRunwaySeconds(), 1 hours, "fad runway");
        assertEq(address(engine.terminalNavBook()), address(terminalNavBook), "terminal NAV book");
        assertEq(terminalNavBook.SIZE_QUANTUM(), 1e20, "position size quantum");

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
        OrderRouter router = new OrderRouter(address(engine), address(0xCAFE), address(0xBEEF), address(oracle));

        assertEq(oracle.basketMaxConfidenceRatioBps(), 10, "basket confidence ratio");
        assertEq(oracle.adverseConfidenceMultiplierBps(), 2000, "adverse confidence multiplier");
        assertFalse(router.positionProtectionCommitsEnabled(), "position protection disabled");
        assertEq(router.positionProtectionTriggerBountyUsdc(), 200_000, "position protection trigger bounty");
        assertEq(router.closeOrderExecutionBountyUsdc(), 200_000, "position protection close bounty");
    }

    function test_DeploymentGuardsAcceptCanonicalPositionProtectionBookBinding() public {
        DeployPerpsArbitrumSepoliaHarness deployScript = new DeployPerpsArbitrumSepoliaHarness();
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();
        MockUSDC usdc = new MockUSDC();
        MarginClearinghouse clearinghouse = new MarginClearinghouse(address(usdc));
        CfdEngine engine = new CfdEngine(
            address(usdc), address(clearinghouse), 2e8, deployScript.riskParams(), deployScript.frozenCloseSpreadBps()
        );
        HousePool pool = new HousePool(address(usdc), address(engine));

        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = bytes32(uint256(1));
        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1e18;
        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = 1e8;
        bool[] memory inversions = new bool[](1);
        MockPyth pyth = new MockPyth();
        PletherOracle oracle = new PletherOracle(
            address(engine), address(pool), address(pyth), feedIds, quantities, basePrices, inversions
        );
        OrderRouter router = new OrderRouter(address(engine), address(0xCAFE), address(pool), address(oracle));
        engine.setOrderRouter(address(router));

        address book = deployScript.verifyPositionProtectionBook(router, engine);
        assertEq(book, address(router.positionProtectionBook()), "position-protection book discovery");
        bootstrapScript.verifyRouterWiring(pool, router);
    }

    function test_BootstrapDefaults_MatchArbitrumSepoliaReleaseSeeds() public {
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();

        assertEq(bootstrapScript.defaultSeniorSeedUsdc(), 50_000_000e6, "senior seed");
        assertEq(bootstrapScript.defaultJuniorSeedUsdc(), 50_000_000e6, "junior seed");
    }

    function test_DeploymentGuardsAcceptCanonicalRequestWindowAcrossCutoffs() public {
        DeployPerpsArbitrumSepoliaHarness deployScript = new DeployPerpsArbitrumSepoliaHarness();
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();
        (MockUSDC usdc, HousePool pool, TrancheVault seniorVault, TrancheVault juniorVault) = _deployAsyncVaultPair();

        uint256 boundary = 10 hours;
        uint256[4] memory timestamps = [boundary - 301 seconds, boundary - 300 seconds, boundary, boundary + 55 minutes];
        for (uint256 i; i < timestamps.length; ++i) {
            vm.warp(timestamps[i]);
            deployScript.verifyAsyncVaultPair(pool, seniorVault, juniorVault, usdc);
            bootstrapScript.verifyAsyncVaultPair(pool, address(usdc));
        }
    }

    function test_BootstrapRejectsStackWithoutTerminalNavBook() public {
        DeployPerpsArbitrumSepoliaHarness deployScript = new DeployPerpsArbitrumSepoliaHarness();
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();
        MockUSDC usdc = new MockUSDC();
        MarginClearinghouse clearinghouse = new MarginClearinghouse(address(usdc));
        CfdEngine engine = new CfdEngine(
            address(usdc), address(clearinghouse), 2e8, deployScript.riskParams(), deployScript.frozenCloseSpreadBps()
        );
        HousePool pool = new HousePool(address(usdc), address(engine));

        vm.expectRevert(bytes("TerminalNavBookV2 is not wired"));
        bootstrapScript.verifyTerminalNavBook(pool);

        TerminalNavBookV2 terminalNavBook = new TerminalNavBookV2(address(engine), 2e8);
        engine.setTerminalNavBook(address(terminalNavBook));
        bootstrapScript.verifyTerminalNavBook(pool);
    }

    function test_BootstrapRequiresFiniteExplicitSeniorLimits() public {
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();

        bootstrapScript.validateSeniorLimits(100_000_000e6, 5000);
        bootstrapScript.validateSeniorLimits(0, 0);

        vm.expectRevert(bytes("MAX_SENIOR_EXPOSURE_USDC must be finite"));
        bootstrapScript.validateSeniorLimits(type(uint256).max, 5000);

        vm.expectRevert(bytes("MAX_SENIOR_SHARE_BPS must be below 10000"));
        bootstrapScript.validateSeniorLimits(100_000_000e6, 10_000);
    }

    function test_BootstrapSeniorLimitsUseTwoRunProposalAndFinalizeFlow() public {
        BootstrapPerpsArbitrumSepoliaHarness bootstrapScript = new BootstrapPerpsArbitrumSepoliaHarness();
        MockUSDC usdc = new MockUSDC();
        HousePool pool = bootstrapScript.deployConfigTestPool(address(usdc));
        uint256 maxExposure = 100_000_000e6;
        uint256 maxShareBps = 6000;

        assertFalse(bootstrapScript.configureSeniorLimits(pool, maxExposure, maxShareBps));
        uint256 activationTime = pool.poolConfigActivationTime();
        assertEq(activationTime, block.timestamp + pool.TIMELOCK_DELAY());
        (,,,, uint256 pendingMaxExposure, uint256 pendingMaxShareBps) = pool.pendingPoolConfig();
        assertEq(pendingMaxExposure, maxExposure);
        assertEq(pendingMaxShareBps, maxShareBps);

        assertFalse(bootstrapScript.configureSeniorLimits(pool, maxExposure, maxShareBps));
        assertEq(pool.poolConfigActivationTime(), activationTime, "matching rerun must not restart the timelock");

        vm.warp(activationTime);
        assertTrue(bootstrapScript.configureSeniorLimits(pool, maxExposure, maxShareBps));
        assertEq(pool.poolConfigActivationTime(), 0);
        assertEq(pool.maxSeniorExposureUsdc(), maxExposure);
        assertEq(pool.maxSeniorShareBps(), maxShareBps);

        assertTrue(bootstrapScript.configureSeniorLimits(pool, maxExposure, maxShareBps));
    }

    function _deployAsyncVaultPair()
        internal
        returns (MockUSDC usdc, HousePool pool, TrancheVault seniorVault, TrancheVault juniorVault)
    {
        usdc = new MockUSDC();
        pool = new HousePool(address(usdc), address(0xE11E));
        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Senior", "senior");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior", "junior");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
    }

}
