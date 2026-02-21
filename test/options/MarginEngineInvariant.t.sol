// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {MarginEngine} from "../../src/options/MarginEngine.sol";
import {OptionToken} from "../../src/options/OptionToken.sol";
import {SettlementOracle} from "../../src/oracles/SettlementOracle.sol";
import {MockOracle} from "../utils/MockOracle.sol";
import {MockOptionsSplitter, MockStakedTokenOptions} from "../utils/OptionsMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Test.sol";

// ─── Handler ────────────────────────────────────────────────────────────

contract MarginEngineHandler is Test {

    MarginEngine public engine;
    MockStakedTokenOptions public stakedBear;
    MockStakedTokenOptions public stakedBull;
    MockOptionsSplitter public splitter;
    MockOracle public eurFeed;
    MockOracle public jpyFeed;

    address[] public actors;
    uint256[] public seriesIds;

    // Ghost accounting
    uint256 public ghost_totalSharesDeposited;
    uint256 public ghost_totalSharesExercised;
    uint256 public ghost_totalSharesUnlocked;
    uint256 public ghost_totalOptionsMinted;
    uint256 public ghost_totalOptionsExercised;

    // Per-series settlement snapshots
    mapping(uint256 => uint256) public ghost_settledPrice;
    mapping(uint256 => uint256) public ghost_settledRate;
    mapping(uint256 => bool) public ghost_isSettled;

    // Per-series option token addresses
    mapping(uint256 => address) public seriesOptionToken;

    constructor(
        MarginEngine _engine,
        MockStakedTokenOptions _stakedBear,
        MockStakedTokenOptions _stakedBull,
        MockOptionsSplitter _splitter,
        MockOracle _eurFeed,
        MockOracle _jpyFeed,
        address[] memory _actors
    ) {
        engine = _engine;
        stakedBear = _stakedBear;
        stakedBull = _stakedBull;
        splitter = _splitter;
        eurFeed = _eurFeed;
        jpyFeed = _jpyFeed;
        actors = _actors;
        _stakedBear.approve(address(_engine), type(uint256).max);
        _stakedBull.approve(address(_engine), type(uint256).max);
    }

    function getSeriesCount() external view returns (uint256) {
        return seriesIds.length;
    }

    function createSeries(
        uint256 strikeSeed,
        uint256 expirySeed,
        bool isBull
    ) external {
        uint256 strike = bound(strikeSeed, 1, 199_000_000);
        uint256 expiry = block.timestamp + bound(expirySeed, 1 hours, 30 days);

        try engine.createSeries(isBull, strike, expiry, "TEST", "tOPT") returns (uint256 id) {
            seriesIds.push(id);
            (,,, address optAddr,,,) = engine.series(id);
            seriesOptionToken[id] = optAddr;
        } catch {}
    }

    function mintOptions(
        uint256 actorSeed,
        uint256 seriesSeed,
        uint256 amount
    ) external {
        if (seriesIds.length == 0) {
            return;
        }

        address actor = actors[actorSeed % actors.length];
        uint256 seriesId = seriesIds[seriesSeed % seriesIds.length];
        amount = bound(amount, 1e18, 10_000e18);

        (bool isBull,,,,,,) = engine.series(seriesId);
        MockStakedTokenOptions vault = isBull ? stakedBull : stakedBear;
        uint256 sharesToLock = vault.previewWithdraw(amount);

        try engine.mintOptions(seriesId, amount) {
            ghost_totalSharesDeposited += sharesToLock;
            ghost_totalOptionsMinted += amount;
            OptionToken(seriesOptionToken[seriesId]).transfer(actor, amount);
        } catch {}
    }

    function warpTime(
        uint256 timeDelta
    ) external {
        timeDelta = bound(timeDelta, 1 hours, 7 days);
        vm.warp(block.timestamp + timeDelta);
    }

    function warpYield(
        uint256 bearNum,
        uint256 bearDen,
        uint256 bullNum,
        uint256 bullDen
    ) external {
        bearNum = bound(bearNum, 1, 10);
        bearDen = bound(bearDen, 1, 10);
        bullNum = bound(bullNum, 1, 10);
        bullDen = bound(bullDen, 1, 10);
        stakedBear.setExchangeRate(bearNum, bearDen);
        stakedBull.setExchangeRate(bullNum, bullDen);
    }

    function warpPrices(
        uint256 eurPrice,
        uint256 jpyPrice
    ) external {
        eurPrice = bound(eurPrice, 50_000_000, 200_000_000);
        jpyPrice = bound(jpyPrice, 300_000, 1_500_000);
        eurFeed.updatePrice(int256(eurPrice));
        jpyFeed.updatePrice(int256(jpyPrice));
    }

    function settle(
        uint256 seriesSeed
    ) external {
        if (seriesIds.length == 0) {
            return;
        }
        uint256 seriesId = seriesIds[seriesSeed % seriesIds.length];

        uint80[] memory hints = new uint80[](2);
        (hints[0],,,,) = eurFeed.latestRoundData();
        (hints[1],,,,) = jpyFeed.latestRoundData();

        try engine.settle(seriesId, hints) {
            (,,,, uint256 sp, uint256 ssr,) = engine.series(seriesId);
            ghost_settledPrice[seriesId] = sp;
            ghost_settledRate[seriesId] = ssr;
            ghost_isSettled[seriesId] = true;
        } catch {}
    }

    function exercise(
        uint256 actorSeed,
        uint256 seriesSeed,
        uint256 amount
    ) external {
        if (seriesIds.length == 0) {
            return;
        }

        address actor = actors[actorSeed % actors.length];
        uint256 seriesId = seriesIds[seriesSeed % seriesIds.length];

        uint256 balance = OptionToken(seriesOptionToken[seriesId]).balanceOf(actor);
        if (balance == 0) {
            return;
        }
        amount = bound(amount, 1, balance);

        (bool isBull,,,,,,) = engine.series(seriesId);
        MockStakedTokenOptions vault = isBull ? stakedBull : stakedBear;
        uint256 vaultBefore = vault.balanceOf(actor);

        vm.prank(actor);
        try engine.exercise(seriesId, amount) {
            uint256 received = vault.balanceOf(actor) - vaultBefore;
            ghost_totalSharesExercised += received;
            ghost_totalOptionsExercised += amount;
        } catch {}
    }

    function unlockCollateral(
        uint256 actorSeed,
        uint256 seriesSeed
    ) external {
        if (seriesIds.length == 0) {
            return;
        }

        uint256 seriesId = seriesIds[seriesSeed % seriesIds.length];

        (bool isBull,,,,,,) = engine.series(seriesId);
        MockStakedTokenOptions vault = isBull ? stakedBull : stakedBear;
        uint256 vaultBefore = vault.balanceOf(address(this));

        try engine.unlockCollateral(seriesId) {
            uint256 received = vault.balanceOf(address(this)) - vaultBefore;
            ghost_totalSharesUnlocked += received;
        } catch {}
    }

}

// ─── Invariant Test ─────────────────────────────────────────────────────

contract MarginEngineInvariantTest is Test {

    MarginEngine public engine;
    MockOptionsSplitter public splitter;
    MockStakedTokenOptions public stakedBear;
    MockStakedTokenOptions public stakedBull;
    MarginEngineHandler public handler;

    MockOracle public eurFeed;
    MockOracle public jpyFeed;
    MockOracle public sequencerFeed;

    address[] public actors;

    function setUp() public {
        vm.warp(1_735_689_600);

        splitter = new MockOptionsSplitter();

        sequencerFeed = new MockOracle(0, "Sequencer");
        vm.warp(block.timestamp + 2 hours);

        eurFeed = new MockOracle(118_800_000, "EUR/USD");
        jpyFeed = new MockOracle(670_000, "JPY/USD");

        address[] memory feeds = new address[](2);
        feeds[0] = address(eurFeed);
        feeds[1] = address(jpyFeed);
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 600_000_000_000_000_000;
        quantities[1] = 400_000_000_000_000_000;
        uint256[] memory basePrices = new uint256[](2);
        basePrices[0] = 108_000_000;
        basePrices[1] = 670_000;

        SettlementOracle oracle = new SettlementOracle(feeds, quantities, basePrices, 2e8, address(sequencerFeed));

        stakedBear = new MockStakedTokenOptions("splDXY-BEAR", "splBEAR");
        stakedBull = new MockStakedTokenOptions("splDXY-BULL", "splBULL");
        OptionToken optionImpl = new OptionToken();

        engine = new MarginEngine(
            address(splitter), address(oracle), address(stakedBear), address(stakedBull), address(optionImpl)
        );

        // 5 actors
        for (uint256 i = 1; i <= 5; i++) {
            address actor = address(uint160(i * 111));
            actors.push(actor);
            stakedBear.mint(actor, 10_000_000e21);
            stakedBull.mint(actor, 10_000_000e21);
            vm.prank(actor);
            stakedBear.approve(address(engine), type(uint256).max);
            vm.prank(actor);
            stakedBull.approve(address(engine), type(uint256).max);
        }

        handler = new MarginEngineHandler(engine, stakedBear, stakedBull, splitter, eurFeed, jpyFeed, actors);
        engine.grantRole(engine.SERIES_CREATOR_ROLE(), address(handler));
        stakedBear.mint(address(handler), 10_000_000e21);
        stakedBull.mint(address(handler), 10_000_000e21);

        targetContract(address(handler));
    }

    /// @dev Shares in engine + released (exercised + unlocked) must never exceed deposited.
    /// Rounding dust gets trapped inside the engine (favors protocol), so the lower bound uses a dust allowance.
    function invariant_sharesConservation() public view {
        uint256 bearInEngine = stakedBear.balanceOf(address(engine));
        uint256 bullInEngine = stakedBull.balanceOf(address(engine));
        uint256 totalInEngine = bearInEngine + bullInEngine;

        uint256 totalReleased = handler.ghost_totalSharesExercised() + handler.ghost_totalSharesUnlocked();
        uint256 totalDeposited = handler.ghost_totalSharesDeposited();

        assertLe(totalInEngine + totalReleased, totalDeposited, "more shares released than deposited");

        uint256 seriesCount = handler.getSeriesCount();
        uint256 dustAllowance = seriesCount * 1e3;
        assertGe(
            totalInEngine + totalReleased,
            totalDeposited > dustAllowance ? totalDeposited - dustAllowance : 0,
            "shares went missing"
        );
    }

    /// @dev Settlement prices for a series must never change once set.
    function invariant_settledSeriesImmutable() public view {
        uint256 count = handler.getSeriesCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 seriesId = handler.seriesIds(i);
            if (!handler.ghost_isSettled(seriesId)) {
                continue;
            }

            (,,,, uint256 currentPrice, uint256 currentRate, bool isSettled) = engine.series(seriesId);
            assertTrue(isSettled, "settled flag flipped");
            assertEq(currentPrice, handler.ghost_settledPrice(seriesId), "settlement price changed");
            assertEq(currentRate, handler.ghost_settledRate(seriesId), "settlement rate changed");
        }
    }

    /// @dev Option token totalSupply should equal minted minus exercised (burned).
    function invariant_optionSupplyConsistency() public view {
        uint256 expectedSupply = handler.ghost_totalOptionsMinted() - handler.ghost_totalOptionsExercised();
        uint256 actualSupply = 0;

        uint256 count = handler.getSeriesCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 seriesId = handler.seriesIds(i);
            address optAddr = handler.seriesOptionToken(seriesId);
            if (optAddr != address(0)) {
                actualSupply += OptionToken(optAddr).totalSupply();
            }
        }

        assertEq(actualSupply, expectedSupply, "option supply mismatch");
    }

}
