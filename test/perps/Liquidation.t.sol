// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {CfdVault} from "../../src/perps/CfdVault.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test, console} from "forge-std/Test.sol";

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
    CfdVault vault;
    OrderRouter router;

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address keeper = address(0x999);

    // Wed, Oct 16, 2024, 12:00:00 UTC (Wednesday - Normal Margin)
    uint256 constant WEDNESDAY_NOON = 1_729_080_000;
    // Fri, Oct 18, 2024, 20:00:00 UTC (Friday - FAD Active)
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
            maintMarginBps: 100, // 1%
            fadMarginBps: 300, // 3%
            minBountyUsdc: 5 * 1e6, // $5
            bountyBps: 15 // 0.15%
        });

        engine = new CfdEngine(CAP_PRICE, params);
        vault = new CfdVault(usdc, address(engine));
        router = new OrderRouter(address(engine), address(vault), address(usdc), address(0), bytes32(0));
        engine.setOrderRouter(address(router));
        vault.setOrderRouter(address(router));

        usdc.mint(address(vault), 1_000_000 * 1e6); // LP depth
        usdc.mint(alice, 10_000 * 1e6);

        vm.startPrank(alice);
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function test_FridayAutoDeleverage() public {
        // 1. Start on a Wednesday
        vm.warp(WEDNESDAY_NOON);
        assertEq(
            engine.getMaintenanceMarginUsdc(100_000 * 1e18, 1e8), 1000 * 1e6, "MMR should be 1.0% ($1k) on Wednesday"
        );

        // 2. Alice opens 50x BULL (Size $100k, Margin $2k)
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);

        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        // 3. Keeper tries to liquidate immediately. Should REVERT because $2k margin > $1k required.
        vm.startPrank(keeper);
        vm.expectRevert("CfdEngine: Position is solvent");
        router.executeLiquidation(accountId, empty);
        vm.stopPrank();

        // 4. Time travel to Friday 20:00 UTC! (FAD Window activates)
        vm.warp(FRIDAY_EVENING);
        assertEq(
            engine.getMaintenanceMarginUsdc(100_000 * 1e18, 1e8),
            3000 * 1e6,
            "MMR should jump to 3.0% ($3k) on Friday evening"
        );

        // 5. Keeper liquidates. Because required margin is $3k and Alice only has $2k, she is liquidatable.
        uint256 keeperBalBefore = usdc.balanceOf(keeper);

        vm.startPrank(keeper);
        router.executeLiquidation(accountId, empty);
        vm.stopPrank();

        // 6. Assertions
        (uint256 size,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be wiped");

        uint256 bounty = usdc.balanceOf(keeper) - keeperBalBefore;
        assertEq(bounty, 150 * 1e6, "Keeper should receive $150 USDC bounty (0.15% of $100k)");
    }

    function test_LiquidationOnPriceDrop() public {
        vm.warp(WEDNESDAY_NOON);
        vm.prank(alice);
        // Alice opens 50x BULL (Size 100k at $1.00 = $100k notional. Margin = $2k)
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        // BULL loses when price rises. Price rises to $1.015
        // PnL = -$0.015 * 100k = -$1500. Remaining equity = $2000 - $1500 = $500
        // Required margin = 1% of $101.5k = $1015. $500 < $1015 → liquidatable
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(1.015e8);

        uint256 keeperBalBefore = usdc.balanceOf(keeper);

        vm.startPrank(keeper);
        router.executeLiquidation(accountId, pythData);
        vm.stopPrank();

        uint256 bounty = usdc.balanceOf(keeper) - keeperBalBefore;
        assertTrue(bounty > 0, "Keeper should get bounty");

        (uint256 size,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be wiped");
    }

}
