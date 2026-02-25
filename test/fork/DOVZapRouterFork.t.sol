// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {StakedToken} from "../../src/StakedToken.sol";
import {DOVZapRouter} from "../../src/options/DOVZapRouter.sol";
import {MarginEngine} from "../../src/options/MarginEngine.sol";
import {OptionToken} from "../../src/options/OptionToken.sol";
import {PletherDOV} from "../../src/options/PletherDOV.sol";
import {SettlementOracle} from "../../src/oracles/SettlementOracle.sol";
import {BaseForkTest} from "./BaseForkTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Test.sol";

contract DOVZapRouterForkTest is BaseForkTest {

    StakedToken stBear;
    StakedToken stBull;
    SettlementOracle settlementOracle;
    MarginEngine marginEngine;
    OptionToken optionImpl;
    PletherDOV bearDov;
    PletherDOV bullDov;
    DOVZapRouter router;

    function setUp() public {
        _setupFork();
        require(block.chainid == 1, "Must be Mainnet");

        deal(USDC, address(this), 5_000_000e6);

        _fetchPriceAndWarp();
        _deployProtocol(address(this));

        stBear = new StakedToken(IERC20(bearToken), "Staked Bear", "stBEAR");
        stBull = new StakedToken(IERC20(bullToken), "Staked Bull", "stBULL");

        _mintInitialTokens(510_000e18);
        _deployCurvePool(500_000e18);

        address[] memory feeds = new address[](1);
        feeds[0] = CL_EUR;
        uint256[] memory qtys = new uint256[](1);
        qtys[0] = 1e18;
        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = BASE_EUR;
        settlementOracle = new SettlementOracle(feeds, qtys, basePrices, 2e8, address(0));

        optionImpl = new OptionToken();
        marginEngine = new MarginEngine(
            address(splitter), address(settlementOracle), address(stBear), address(stBull), address(optionImpl)
        );

        bearDov = new PletherDOV("BEAR DOV", "bDOV", address(marginEngine), address(stBear), USDC, false);
        bullDov = new PletherDOV("BULL DOV", "buDOV", address(marginEngine), address(stBull), USDC, true);

        marginEngine.grantRole(marginEngine.SERIES_CREATOR_ROLE(), address(bearDov));
        marginEngine.grantRole(marginEngine.SERIES_CREATOR_ROLE(), address(bullDov));

        router = new DOVZapRouter(
            address(splitter),
            curvePool,
            USDC,
            bearToken,
            bullToken,
            address(stBear),
            address(stBull),
            address(bearDov),
            address(bullDov)
        );

        bearDov.setZapKeeper(address(router));
        bullDov.setZapKeeper(address(router));

        _seedDov(bearDov, stBear, IERC20(bearToken), 10_000e18);
        _seedDov(bullDov, stBull, IERC20(bullToken), 10_000e18);
    }

    function _seedDov(
        PletherDOV dov,
        StakedToken st,
        IERC20 token,
        uint256 amount
    ) internal {
        token.approve(address(st), amount);
        uint256 shares = st.deposit(amount, address(dov));
        require(shares > 0, "seed failed");
        dov.initializeShares();
    }

    function _defaultBearParams() internal view returns (DOVZapRouter.EpochParams memory) {
        return DOVZapRouter.EpochParams({
            strike: 90e6, expiry: block.timestamp + 7 days, maxPremium: 1e6, minPremium: 100_000, duration: 1 hours
        });
    }

    function _defaultBullParams() internal view returns (DOVZapRouter.EpochParams memory) {
        return DOVZapRouter.EpochParams({
            strike: 90e6, expiry: block.timestamp + 7 days, maxPremium: 1e6, minPremium: 100_000, duration: 1 hours
        });
    }

    function test_BullExcessZap_RealFlashMint() public {
        deal(USDC, address(bearDov), 5000e6);
        deal(USDC, address(bullDov), 15_000e6);

        uint256 seedBaseline = 10_000e18;

        router.coordinatedZapAndStartEpochs(_defaultBearParams(), _defaultBullParams(), 0, 0);

        assertEq(uint256(bearDov.currentState()), uint256(PletherDOV.State.AUCTIONING));
        assertEq(uint256(bullDov.currentState()), uint256(PletherDOV.State.AUCTIONING));
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "no USDC left in router");
        assertEq(IERC20(bearToken).balanceOf(address(router)), 0, "no BEAR left in router");
        assertEq(IERC20(bullToken).balanceOf(address(router)), 0, "no BULL left in router");

        (, uint256 bullOpts,,,,,) = bullDov.epochs(1);
        assertGt(bullOpts, seedBaseline, "bull DOV minted more options than seed alone");
    }

    function test_MatchedZap_NoFlashNeeded() public {
        deal(USDC, address(bearDov), 10_000e6);
        deal(USDC, address(bullDov), 10_000e6);

        router.coordinatedZapAndStartEpochs(_defaultBearParams(), _defaultBullParams(), 0, 0);

        assertEq(uint256(bearDov.currentState()), uint256(PletherDOV.State.AUCTIONING));
        assertEq(uint256(bullDov.currentState()), uint256(PletherDOV.State.AUCTIONING));
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "no USDC left in router");
    }

    function test_BearExcessZap_CurveSwap() public {
        deal(USDC, address(bearDov), 15_000e6);
        deal(USDC, address(bullDov), 5000e6);

        uint256 seedBaseline = 10_000e18;

        router.coordinatedZapAndStartEpochs(_defaultBearParams(), _defaultBullParams(), 0, 0);

        assertEq(uint256(bearDov.currentState()), uint256(PletherDOV.State.AUCTIONING));
        assertEq(uint256(bullDov.currentState()), uint256(PletherDOV.State.AUCTIONING));
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "no USDC left in router");

        (, uint256 bearOpts,,,,,) = bearDov.epochs(1);
        assertGt(bearOpts, seedBaseline, "bear DOV minted more options than seed alone");
    }

}
