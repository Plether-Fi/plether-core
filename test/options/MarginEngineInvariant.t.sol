// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {MarginEngine} from "../../src/options/MarginEngine.sol";
import {OptionToken} from "../../src/options/OptionToken.sol";
import {MockOracle} from "../utils/MockOracle.sol";
import {MockOptionsSplitter, MockStakedTokenOptions} from "../utils/OptionsMocks.sol";
import {OptionsTestSetup} from "../utils/OptionsTestSetup.sol";
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
    uint256 public ghost_totalSharesSwept;
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

    function _isExpectedRevert(
        bytes memory reason,
        bytes4[] memory allowed
    ) internal pure returns (bool) {
        if (reason.length < 4) {
            return false;
        }
        bytes4 sel;
        assembly { sel := mload(add(reason, 0x20)) }
        for (uint256 i = 0; i < allowed.length; i++) {
            if (sel == allowed[i]) {
                return true;
            }
        }
        return false;
    }

    function _bubbleRevert(
        bytes memory reason
    ) internal pure {
        assembly { revert(add(reason, 0x20), mload(reason)) }
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
        } catch (bytes memory reason) {
            bytes4[] memory allowed = new bytes4[](2);
            allowed[0] = MarginEngine.MarginEngine__InvalidParams.selector;
            allowed[1] = MarginEngine.MarginEngine__Expired.selector;
            if (!_isExpectedRevert(reason, allowed)) {
                _bubbleRevert(reason);
            }
        }
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
        } catch (bytes memory reason) {
            bytes4[] memory allowed = new bytes4[](4);
            allowed[0] = MarginEngine.MarginEngine__Expired.selector;
            allowed[1] = MarginEngine.MarginEngine__ZeroAmount.selector;
            allowed[2] = MarginEngine.MarginEngine__Unauthorized.selector;
            allowed[3] = MarginEngine.MarginEngine__SplitterNotActive.selector;
            if (!_isExpectedRevert(reason, allowed)) {
                _bubbleRevert(reason);
            }
        }
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

        (,, uint256 expiry,,,,) = engine.series(seriesId);

        uint80[] memory hints = new uint80[](2);
        hints[0] = _findHintRound(eurFeed, expiry);
        hints[1] = _findHintRound(jpyFeed, expiry);

        try engine.settle(seriesId, hints) {
            (,,,, uint256 sp, uint256 ssr,) = engine.series(seriesId);
            ghost_settledPrice[seriesId] = sp;
            ghost_settledRate[seriesId] = ssr;
            ghost_isSettled[seriesId] = true;
        } catch (bytes memory reason) {
            bytes4[] memory allowed = new bytes4[](2);
            allowed[0] = MarginEngine.MarginEngine__AlreadySettled.selector;
            allowed[1] = MarginEngine.MarginEngine__NotExpired.selector;
            if (!_isExpectedRevert(reason, allowed)) {
                _bubbleRevert(reason);
            }
        }
    }

    function sweep(
        uint256 seriesSeed
    ) external {
        if (seriesIds.length == 0) {
            return;
        }
        uint256 seriesId = seriesIds[seriesSeed % seriesIds.length];
        (bool isBull,,,,,,) = engine.series(seriesId);
        MockStakedTokenOptions vault = isBull ? stakedBull : stakedBear;
        uint256 vaultBefore = vault.balanceOf(address(this));
        try engine.sweepUnclaimedShares(seriesId) {
            ghost_totalSharesSwept += vault.balanceOf(address(this)) - vaultBefore;
        } catch (bytes memory reason) {
            bytes4[] memory allowed = new bytes4[](3);
            allowed[0] = MarginEngine.MarginEngine__NotSettled.selector;
            allowed[1] = MarginEngine.MarginEngine__SweepTooEarly.selector;
            allowed[2] = MarginEngine.MarginEngine__ZeroAmount.selector;
            if (!_isExpectedRevert(reason, allowed)) {
                _bubbleRevert(reason);
            }
        }
    }

    function _findHintRound(
        MockOracle feed,
        uint256 expiry
    ) internal view returns (uint80) {
        uint80 roundId = feed.currentRoundId();
        while (roundId > 0) {
            (,,, uint256 updatedAt,) = feed.getRoundData(roundId);
            if (updatedAt <= expiry) {
                return roundId;
            }
            roundId--;
        }
        return feed.currentRoundId();
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
        } catch (bytes memory reason) {
            bytes4[] memory allowed = new bytes4[](4);
            allowed[0] = MarginEngine.MarginEngine__ZeroAmount.selector;
            allowed[1] = MarginEngine.MarginEngine__NotSettled.selector;
            allowed[2] = MarginEngine.MarginEngine__Expired.selector;
            allowed[3] = MarginEngine.MarginEngine__OptionIsOTM.selector;
            if (!_isExpectedRevert(reason, allowed)) {
                _bubbleRevert(reason);
            }
        }
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
        } catch (bytes memory reason) {
            bytes4[] memory allowed = new bytes4[](2);
            allowed[0] = MarginEngine.MarginEngine__NotSettled.selector;
            allowed[1] = MarginEngine.MarginEngine__ZeroAmount.selector;
            if (!_isExpectedRevert(reason, allowed)) {
                _bubbleRevert(reason);
            }
        }
    }

}

// ─── Invariant Test ─────────────────────────────────────────────────────

contract MarginEngineInvariantTest is OptionsTestSetup {

    MarginEngineHandler public handler;

    address[] public actors;

    function setUp() public {
        _deployOptionsInfra();

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
        engine.grantRole(engine.DEFAULT_ADMIN_ROLE(), address(handler));
        stakedBear.mint(address(handler), 10_000_000e21);
        stakedBull.mint(address(handler), 10_000_000e21);

        targetContract(address(handler));
    }

    /// @dev Under single-writer, share conservation is mathematically exact:
    /// engine_balance + exercised + unlocked + swept = deposited.
    function invariant_sharesConservation() public view {
        uint256 bearInEngine = stakedBear.balanceOf(address(engine));
        uint256 bullInEngine = stakedBull.balanceOf(address(engine));
        uint256 totalInEngine = bearInEngine + bullInEngine;

        uint256 totalReleased = handler.ghost_totalSharesExercised() + handler.ghost_totalSharesUnlocked()
            + handler.ghost_totalSharesSwept();
        uint256 totalDeposited = handler.ghost_totalSharesDeposited();

        assertEq(totalInEngine + totalReleased, totalDeposited, "share conservation violated");
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

    /// @dev Exercised shares for any series must never exceed its total locked shares.
    function invariant_exercisedSharesBounded() public view {
        uint256 count = handler.getSeriesCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 seriesId = handler.seriesIds(i);
            uint256 exercised = engine.totalSeriesExercisedShares(seriesId);
            uint256 total = engine.totalSeriesShares(seriesId);
            assertLe(exercised, total, "exercised shares exceed total series shares");
        }
    }

}
