// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

// Audit-history file: tests prefixed with `obsolete_` preserve superseded findings for context only.
// They are intentionally not statements about the live carry model or current accounting semantics.

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdEngineLens} from "../../src/perps/CfdEngineLens.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract CooldownBypassReceiver {

    function withdrawAll(
        TrancheVault vault
    ) external {
        uint256 shares = vault.balanceOf(address(this));
        vault.redeem(shares, address(this), address(this));
    }

}

contract AuditVerifiedFindingsFailing_F1_LegacySpreadSolvency is BasePerpTest {

    address bullTrader = address(0xCA01);
    address bearTrader = address(0xDA02);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 15
        });
    }

    function obsolete_F1_CappedLegacySpreadShouldNetCollectibleReceivablesAgainstLiabilities() public {
        _fundTrader(bullTrader, 300_000e6);
        _fundTrader(bearTrader, 100_000e6);

        bytes32 bullId = bytes32(uint256(uint160(bullTrader)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));

        _open(bullId, CfdTypes.Side.BULL, 200_000e18, 200_000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        vm.warp(block.timestamp + 180 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        CfdTypes.Position memory bullPos;
        CfdTypes.Position memory bearPos;
        {
            (uint256 size, uint256 margin, uint256 entryPrice,, CfdTypes.Side side,,) = engine.positions(bullId);
            bullPos = CfdTypes.Position(size, margin, entryPrice, 0, side, 0, 0, 0);
        }
        {
            (uint256 size, uint256 margin, uint256 entryPrice,, CfdTypes.Side side,,) = engine.positions(bearId);
            bearPos = CfdTypes.Position(size, margin, entryPrice, 0, side, 0, 0, 0);
        }

        int256 bullLegacySpread = 0;
        int256 bearLegacySpread = 0;
        assertLt(bullLegacySpread, 0, "Bull side should owe legacy spread in the obsolete skewed-market model");
        assertGt(bearLegacySpread, 0, "Bear side should be owed legacy spread in the obsolete skewed-market model");
        assertLt(
            int256(0),
            0,
            "Legacy-spread solvency should include collectible receivables instead of liability-only clipping"
        );
        assertGt(
            uint256(0), 0, "Legacy-spread withdrawal reserve should remain conservative and reserve only liabilities"
        );
    }

}

contract AuditVerifiedFindingsFailing_F2_SkewCapBypass is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 15
        });
    }

    function test_F2_EmptyMarketShouldStillEnforceMaxSkewRatio() public {
        address whale = address(0x5E77);
        bytes32 whaleId = bytes32(uint256(uint160(whale)));

        _fundTrader(whale, 100_000e6);

        uint256 depth = pool.totalAssets();
        vm.expectRevert();
        _open(whaleId, CfdTypes.Side.BULL, 500_000e18, 50_000e6, 1e8, depth);
    }

}

contract AuditVerifiedFindingsFailing_F2_SkewDoubleCount is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.15e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 15
        });
    }

    function test_F2_SkewCapShouldUseSinglePostTradeSizeDelta() public {
        address bearTrader = address(0xBEA2);
        address bullTrader = address(0xB011);

        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));
        bytes32 bullId = bytes32(uint256(uint160(bullTrader)));

        _fundTrader(bearTrader, 60_000e6);
        _fundTrader(bullTrader, 120_000e6);

        _open(bearId, CfdTypes.Side.BEAR, 100_000e18, 20_000e6, 1e8);
        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 20_000e6, 1e8);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 20_000e6, 1e8);

        (uint256 bullSize,,,,,,) = engine.positions(bullId);
        assertEq(bullSize, 200_000e18, "Skew cap should evaluate the real post-trade open interest");
    }

}

contract AuditVerifiedFindingsFailing_F3_StaleKeeperFee is Test {

    MockUSDC usdc;
    MockPyth mockPyth;
    CfdEngine engine;
    HousePool pool;
    MarginClearinghouse clearinghouse;
    TrancheVault seniorVault;
    TrancheVault juniorVault;
    OrderRouter router;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    uint256 constant CAP_PRICE = 2e8;

    address alice = address(0xA11CE);
    address keeper = address(0xBEEF);

    receive() external payable {}

    function setUp() public {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
        pool = new HousePool(address(usdc), address(engine));

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        bytes32[] memory feedIds = new bytes32[](2);
        uint256[] memory weights = new uint256[](2);
        uint256[] memory bases = new uint256[](2);
        bool[] memory inversions = new bool[](2);
        feedIds[0] = FEED_A;
        feedIds[1] = FEED_B;
        weights[0] = 0.5e18;
        weights[1] = 0.5e18;
        bases[0] = 1e8;
        bases[1] = 1e8;

        router = new OrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(mockPyth),
            feedIds,
            weights,
            bases,
            inversions
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _bypassAllTimelocks();
        usdc.mint(address(this), 2000e6);
        usdc.approve(address(pool), 2000e6);
        pool.initializeSeedPosition(false, 1000e6, address(this));
        pool.initializeSeedPosition(true, 1000e6, address(this));
        pool.activateTrading();
        _fundJunior(address(this), 1_000_000e6);
        _fundTrader(alice, 50_000e6);

        vm.deal(alice, 1 ether);
        vm.deal(keeper, 1 ether);
    }

    function test_F3_StaleOracleCancellationMustNotPayKeeperUsdc() public {
        router.proposeMaxOrderAge(3600);
        vm.warp(block.timestamp + 48 hours + 1);
        router.finalizeMaxOrderAge();

        uint256 t0 = 2_000_000_000;
        vm.warp(t0);
        vm.roll(100);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), t0 + 61);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), t0);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        uint256 keeperUsdcBefore = usdc.balanceOf(keeper);

        vm.warp(t0 + 61);
        vm.roll(101);
        vm.prank(keeper);
        vm.expectRevert(OrderRouter.OrderRouter__OraclePriceTooStale.selector);
        router.executeOrder(1, updateData);

        assertEq(
            usdc.balanceOf(keeper) - keeperUsdcBefore, 0, "Keeper should not collect the reserve on stale oracle input"
        );
    }

    function _riskParams() internal pure returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 15
        });
    }

    function _bypassAllTimelocks() internal {
        clearinghouse.setEngine(address(engine));
    }

    function _fundJunior(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), amount);
        juniorVault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _fundTrader(
        address trader,
        uint256 amount
    ) internal {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, amount);
        vm.stopPrank();
    }

}

contract AuditVerifiedFindingsFailing_F4_PartialCloseLosses is BasePerpTest {

    address trader = address(0xD00D);

    function test_F4_UnderwaterPartialCloseMustRevertInsteadOfSocializingLosses() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 10_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        uint256 depth = pool.totalAssets();
        vm.expectRevert();
        _close(accountId, CfdTypes.Side.BULL, 99_000e18, 110_000_000, depth);
    }

}

contract AuditVerifiedFindingsFailing_F5_CooldownBypass is BasePerpTest {

    address helper = address(0xB0B);

    function test_F5_ThirdPartyDepositIntoProxyMustStillStartCooldown() public {
        CooldownBypassReceiver receiver = new CooldownBypassReceiver();

        usdc.mint(helper, 100_000e6);
        vm.startPrank(helper);
        usdc.approve(address(juniorVault), 100_000e6);
        juniorVault.deposit(100_000e6, address(receiver));
        vm.stopPrank();

        vm.expectRevert();
        receiver.withdrawAll(juniorVault);
    }

}

contract AuditVerifiedFindingsFailing_F6_KeeperFeeReserveFreeEquity is BasePerpTest {

    address trader = address(0xA11CE);

    function test_F6_CommitReserveMustNotReduceUsdcBelowLockedMargin() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 10_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        uint256 lockedBefore = clearinghouse.lockedMarginUsdc(accountId);
        uint256 freeBefore = clearinghouse.getFreeBuyingPowerUsdc(accountId);
        uint256 closeBounty = 1e6;

        vm.prank(trader);
        clearinghouse.withdraw(accountId, freeBefore - closeBounty);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        assertGe(
            clearinghouse.balanceUsdc(accountId),
            lockedBefore,
            "Close commits must not strip locked margin to fund keeper reserves"
        );
    }

}

contract AuditVerifiedFindingsFailing_F8_LiquidationDegradedMode is BasePerpTest {

    address winner = address(0xAAA1);
    address loser = address(0xBBB1);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 10,
            initMarginBps: ((10) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 150_500e6;
    }

    function test_F8_LiquidationThatCreatesInsolvencyMustLatchDegradedMode() public {
        bytes32 winnerId = bytes32(uint256(uint160(winner)));
        bytes32 loserId = bytes32(uint256(uint160(loser)));

        _fundTrader(winner, 100_000e6);
        _fundTrader(loser, 2000e6);

        _open(winnerId, CfdTypes.Side.BULL, 100_000e18, 100_000e6, 1.5e8);
        _open(loserId, CfdTypes.Side.BEAR, 100_000e18, 2000e6, 0.5e8);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 20_000e6);

        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(loserId, 0.1e8, depth, uint64(block.timestamp));

        assertTrue(
            engine.degradedMode(),
            "Liquidations that push effective assets below max liability must latch degraded mode"
        );
    }

}
