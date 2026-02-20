// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ISyntheticSplitter} from "../../src/interfaces/ISyntheticSplitter.sol";
import {MarginEngine} from "../../src/options/MarginEngine.sol";
import {OptionToken} from "../../src/options/OptionToken.sol";
import {SettlementOracle} from "../../src/oracles/SettlementOracle.sol";
import {MockOracle} from "../utils/MockOracle.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Test.sol";

// ─── Inline Mocks (same as MarginEngine.t.sol) ─────────────────────────

contract MockOptionsSplitterInv {

    uint256 public CAP = 2e8;
    ISyntheticSplitter.Status private _status = ISyntheticSplitter.Status.ACTIVE;

    function currentStatus() external view returns (ISyntheticSplitter.Status) {
        return _status;
    }

    function setStatus(
        ISyntheticSplitter.Status s
    ) external {
        _status = s;
    }

}

contract MockStakedTokenInv is ERC20 {

    uint256 private _rateNum = 1;
    uint256 private _rateDen = 1;

    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 21;
    }

    function setExchangeRate(
        uint256 num,
        uint256 den
    ) external {
        _rateNum = num;
        _rateDen = den;
    }

    function convertToAssets(
        uint256 shares
    ) external view returns (uint256) {
        return (shares * _rateNum) / (_rateDen * 1e3);
    }

    function previewWithdraw(
        uint256 assets
    ) external view returns (uint256) {
        uint256 numerator = assets * _rateDen * 1e3;
        return (numerator + _rateNum - 1) / _rateNum;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

// ─── Handler ────────────────────────────────────────────────────────────

contract MarginEngineHandler is Test {

    MarginEngine public engine;
    MockStakedTokenInv public stakedBear;
    MockStakedTokenInv public stakedBull;
    MockOptionsSplitterInv public splitter;

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
        MockStakedTokenInv _stakedBear,
        MockStakedTokenInv _stakedBull,
        MockOptionsSplitterInv _splitter,
        address[] memory _actors
    ) {
        engine = _engine;
        stakedBear = _stakedBear;
        stakedBull = _stakedBull;
        splitter = _splitter;
        actors = _actors;
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
        MockStakedTokenInv vault = isBull ? stakedBull : stakedBear;
        uint256 sharesToLock = vault.previewWithdraw(amount);

        vm.prank(actor);
        try engine.mintOptions(seriesId, amount) {
            ghost_totalSharesDeposited += sharesToLock;
            ghost_totalOptionsMinted += amount;
        } catch {}
    }

    function warpTime(
        uint256 timeDelta
    ) external {
        timeDelta = bound(timeDelta, 1 hours, 7 days);
        vm.warp(block.timestamp + timeDelta);
    }

    function settle(
        uint256 seriesSeed
    ) external {
        if (seriesIds.length == 0) {
            return;
        }
        uint256 seriesId = seriesIds[seriesSeed % seriesIds.length];

        try engine.settle(seriesId) {
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
        MockStakedTokenInv vault = isBull ? stakedBull : stakedBear;
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

        address actor = actors[actorSeed % actors.length];
        uint256 seriesId = seriesIds[seriesSeed % seriesIds.length];

        (bool isBull,,,,,,) = engine.series(seriesId);
        MockStakedTokenInv vault = isBull ? stakedBull : stakedBear;
        uint256 vaultBefore = vault.balanceOf(actor);

        vm.prank(actor);
        try engine.unlockCollateral(seriesId) {
            uint256 received = vault.balanceOf(actor) - vaultBefore;
            ghost_totalSharesUnlocked += received;
        } catch {}
    }

}

// ─── Invariant Test ─────────────────────────────────────────────────────

contract MarginEngineInvariantTest is Test {

    MarginEngine public engine;
    MockOptionsSplitterInv public splitter;
    MockStakedTokenInv public stakedBear;
    MockStakedTokenInv public stakedBull;
    MarginEngineHandler public handler;

    MockOracle public eurFeed;
    MockOracle public jpyFeed;
    MockOracle public sequencerFeed;

    address[] public actors;

    function setUp() public {
        vm.warp(1_735_689_600);

        splitter = new MockOptionsSplitterInv();

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

        stakedBear = new MockStakedTokenInv("splDXY-BEAR", "splBEAR");
        stakedBull = new MockStakedTokenInv("splDXY-BULL", "splBULL");
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

        handler = new MarginEngineHandler(engine, stakedBear, stakedBull, splitter, actors);

        targetContract(address(handler));
    }

    /// @dev Shares in engine + released (exercised + unlocked) should account for all deposited shares.
    /// Allows 1e3 dust per series for rounding.
    function invariant_sharesConservation() public view {
        uint256 bearInEngine = stakedBear.balanceOf(address(engine));
        uint256 bullInEngine = stakedBull.balanceOf(address(engine));
        uint256 totalInEngine = bearInEngine + bullInEngine;

        uint256 totalReleased = handler.ghost_totalSharesExercised() + handler.ghost_totalSharesUnlocked();
        uint256 totalDeposited = handler.ghost_totalSharesDeposited();

        uint256 seriesCount = handler.getSeriesCount();
        uint256 dustAllowance = seriesCount * 1e3;

        assertLe(totalInEngine + totalReleased, totalDeposited + dustAllowance, "more shares released than deposited");
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
