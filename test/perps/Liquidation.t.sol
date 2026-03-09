// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockUSDC is ERC20 {

    constructor() ERC20("Mock USDC", "USDC") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

contract LiquidationTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    OrderRouter router;
    MarginClearinghouse clearinghouse;

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address keeper = address(0x999);

    uint256 constant WEDNESDAY_NOON = 1_729_080_000;
    uint256 constant FRIDAY_EVENING = 1_729_281_600;

    receive() external payable {}

    function setUp() public {
        usdc = new MockUSDC();
        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        clearinghouse = new MarginClearinghouse();
        clearinghouse.supportAsset(address(usdc), 6, 10_000, address(0));

        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        router = new OrderRouter(
            address(engine), address(pool), address(0), new bytes32[](0), new uint256[](0), new uint256[](0)
        );

        clearinghouse.setOperator(address(engine), true);
        clearinghouse.setOperator(address(router), true);
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        usdc.mint(address(this), 1_000_000 * 1e6);
        usdc.approve(address(juniorVault), type(uint256).max);
        juniorVault.deposit(1_000_000 * 1e6, address(this));

        // Fund trader via clearinghouse
        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(bytes32(uint256(uint160(alice))), address(usdc), 10_000 * 1e6);
        vm.stopPrank();
    }

    function test_FridayAutoDeleverage() public {
        vm.warp(WEDNESDAY_NOON);
        assertEq(
            engine.getMaintenanceMarginUsdc(100_000 * 1e18, 1e8), 1000 * 1e6, "MMR should be 1.0% ($1k) on Wednesday"
        );

        // Alice opens 50x BULL (Size $100k, Margin $2k)
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);

        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        // Keeper tries to liquidate immediately. Should REVERT.
        vm.startPrank(keeper);
        vm.expectRevert(CfdEngine.CfdEngine__PositionIsSolvent.selector);
        router.executeLiquidation(accountId, empty);
        vm.stopPrank();

        // FAD Window activates
        vm.warp(FRIDAY_EVENING);
        assertEq(
            engine.getMaintenanceMarginUsdc(100_000 * 1e18, 1e8),
            3000 * 1e6,
            "MMR should jump to 3.0% ($3k) on Friday evening"
        );

        // Keeper liquidates. $3k required but only ~$2k margin → liquidatable.
        uint256 keeperBalBefore = usdc.balanceOf(keeper);

        vm.startPrank(keeper);
        router.executeLiquidation(accountId, empty);
        vm.stopPrank();

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be wiped");

        uint256 bounty = usdc.balanceOf(keeper) - keeperBalBefore;
        assertEq(bounty, 150 * 1e6, "Keeper should receive $150 USDC bounty (0.15% of $100k)");

        // Ethical: Alice keeps surplus equity
        // Opening: exec fee = 6 bps of $100k = $60. pos.margin = $2000 - $60 = $1940.
        // Clearinghouse after open: $10k - $60 (fee seized) = $9940. Locked = $1940.
        // Liquidation: equity = $1940 + $0 (PnL) = $1940. Bounty = $150.
        // residual = $1940 - $150 = $1790. toSeize = $1940 - $1790 = $150.
        // Clearinghouse after liq: $9940 - $150 = $9790.
        uint256 chBalance = clearinghouse.balances(accountId, address(usdc));
        assertEq(chBalance, 9790 * 1e6, "Alice keeps surplus equity after ethical liquidation");
    }

    function test_LiquidationOnPriceDrop() public {
        vm.warp(WEDNESDAY_NOON);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        // BULL loses when price rises. Price rises to $1.015
        // PnL = -$0.015 * 100k = -$1500. Equity = $2000 - $1500 = $500
        // Required margin = 1% of $101.5k = $1015. $500 < $1015 → liquidatable
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(1.015e8);

        uint256 keeperBalBefore = usdc.balanceOf(keeper);

        vm.startPrank(keeper);
        router.executeLiquidation(accountId, pythData);
        vm.stopPrank();

        uint256 bounty = usdc.balanceOf(keeper) - keeperBalBefore;
        assertTrue(bounty > 0, "Keeper should get bounty");

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be wiped");

        // Ethical: user should retain equity - bounty
        // PnL = -$1500, Margin = $2000, Equity = $500
        // Bounty ~ 0.15% * $101.5k = $152.25, but min $5 → $152.25
        // Residual = $500 - $152.25 = $347.75
        uint256 chBalance = clearinghouse.balances(accountId, address(usdc));
        assertTrue(chBalance > 8000 * 1e6, "Alice retains most of her clearinghouse balance");
    }

    function test_SolventPosition_RevertsLiquidation() public {
        vm.warp(WEDNESDAY_NOON);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 50_000 * 1e18, 2000 * 1e6, 1e8, false);

        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.expectRevert(CfdEngine.CfdEngine__PositionIsSolvent.selector);
        router.executeLiquidation(accountId, empty);
    }

    function test_KeeperBounty_MinimumFloor() public {
        vm.warp(WEDNESDAY_NOON);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 1000 * 1e18, 100 * 1e6, 1e8, false);

        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        // BULL loses when price rises. At $1.095:
        // PnL = -$95, equity ≈ $4.4, MMR = 1% of $1095 = $10.95 → liquidatable
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(1.095e8);

        uint256 keeperBalBefore = usdc.balanceOf(keeper);
        vm.prank(keeper);
        router.executeLiquidation(accountId, pythData);
        uint256 bounty = usdc.balanceOf(keeper) - keeperBalBefore;

        // 0.15% of $1095 = $1.64 → below $5 minimum → floor applies.
        // Vault absorbs the difference between bounty and equity as bad-debt cost.
        assertEq(bounty, 5 * 1e6, "Keeper always receives full minBounty to prevent liquidation delay");
    }

    function test_LiquidationEquity_IncludesFunding() public {
        // Enable funding (setUp has baseApy=0)
        engine.setRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0,
                maxSkewRatio: 0.4e18,
                kinkSkewRatio: 0.25e18,
                baseApy: 0.15e18,
                maxApy: 3.0e18,
                maintMarginBps: 100,
                fadMarginBps: 300,
                minBountyUsdc: 5 * 1e6,
                bountyBps: 15
            })
        );

        vm.warp(WEDNESDAY_NOON);

        // Alice opens a lone BULL — will accumulate negative funding
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 3000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        // Without funding, $3k margin at same price is solvent (MMR = 1% of $100k = $1k)
        vm.expectRevert(CfdEngine.CfdEngine__PositionIsSolvent.selector);
        router.executeLiquidation(accountId, empty);

        // Warp 180 days — massive negative funding drains equity below MMR
        vm.warp(WEDNESDAY_NOON + 180 days);

        // Now liquidatable due to funding erosion (no price change needed)
        uint256 keeperBal = usdc.balanceOf(keeper);
        vm.prank(keeper);
        router.executeLiquidation(accountId, empty);

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position liquidated by funding drain alone");
        assertTrue(usdc.balanceOf(keeper) > keeperBal, "Keeper received bounty");
    }

    function test_KeeperBounty_PaidFromVault() public {
        vm.warp(WEDNESDAY_NOON);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        (, uint256 posMargin,,,,,) = engine.positions(accountId);

        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 chBefore = clearinghouse.balances(accountId, address(usdc));

        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(1.015e8);

        vm.prank(keeper);
        router.executeLiquidation(accountId, pythData);

        uint256 bounty = usdc.balanceOf(keeper);
        uint256 chAfter = clearinghouse.balances(accountId, address(usdc));
        uint256 poolAfter = usdc.balanceOf(address(pool));

        uint256 userSeized = chBefore - chAfter;
        assertEq(
            poolAfter, poolBefore + userSeized - bounty, "Vault intermediates: receives seized margin, pays bounty"
        );
    }

    function test_FadWindow_ExactBoundaries() public {
        // Friday 18:59:59 UTC → NOT FAD
        vm.warp(1_729_277_999);
        assertFalse(engine.isFadWindow(), "Friday 18:59 is not FAD");

        // Friday 19:00:00 UTC → FAD begins
        vm.warp(1_729_278_000);
        assertTrue(engine.isFadWindow(), "Friday 19:00 is FAD");

        // Saturday midday → FAD (all Saturday is FAD)
        vm.warp(1_729_278_000 + 17 hours);
        assertTrue(engine.isFadWindow(), "Saturday is FAD");

        // Sunday 21:59:59 UTC → still FAD
        vm.warp(1_729_461_599);
        assertTrue(engine.isFadWindow(), "Sunday 21:59 is FAD");

        // Sunday 22:00:00 UTC → FAD ends
        vm.warp(1_729_461_600);
        assertFalse(engine.isFadWindow(), "Sunday 22:00 is not FAD");
    }

}
