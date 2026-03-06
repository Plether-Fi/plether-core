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

contract OrderRouterTest is Test {

    receive() external payable {}

    MockUSDC usdc;
    CfdEngine engine;
    CfdVault vault;
    OrderRouter router;

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address bob = address(0x222);

    function setUp() public {
        usdc = new MockUSDC();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0.0005e18, maxSkewRatio: 0.4e18, kinkSkewRatio: 0.25e18, baseApy: 0.15e18, maxApy: 3.0e18
        });

        engine = new CfdEngine(CAP_PRICE, params);
        vault = new CfdVault(usdc, address(engine));

        // Use address(0) for Pyth in test to trigger the mock fallback mode
        router = new OrderRouter(address(engine), address(vault), address(usdc), address(0), bytes32(0));

        engine.setOrderRouter(address(router));
        vault.setOrderRouter(address(router));

        // Fund LP (Bob) with $1 Million
        usdc.mint(bob, 1_000_000 * 1e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000 * 1e6, bob);
        vm.stopPrank();

        // Fund Trader (Alice)
        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(router), type(uint256).max);
        vm.deal(alice, 10 ether); // Keeper bounties
        vm.stopPrank();
    }

    function test_UnbrickableQueue_OnEngineRevert() public {
        // 1. Bob withdraws all Vault funds so Solvency check will fail
        vm.prank(bob);
        vault.withdraw(1_000_000 * 1e6, bob, bob);

        // 2. Alice commits a trade
        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 50_000 * 1e18, 1000 * 1e6, 1e8, false);

        uint256 aliceBalBefore = usdc.balanceOf(alice);

        // 3. Keeper executes. Engine will REVERT inside the Try/Catch!
        bytes[] memory emptyPayload;
        router.executeOrder(1, emptyPayload);

        // 4. Assertions: Tx succeeded, Queue advanced, Margin fully refunded
        assertEq(router.nextExecuteId(), 2, "Queue MUST increment even if Engine reverts");
        assertEq(usdc.balanceOf(alice), aliceBalBefore + 1000 * 1e6, "Margin must be refunded completely");

        (uint256 size,,,,,) = engine.positions(bytes32(uint256(uint160(alice))));
        assertEq(size, 0, "Position should not exist");
    }

    function test_WithdrawalFirewall() public {
        // Alice opens a trade
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 50_000 * 1e18, 1000 * 1e6, 1e8, false);

        bytes[] memory empty;
        router.executeOrder(1, empty);

        uint256 maxLiability = engine.globalBullMaxProfit();
        uint256 lockedCapital = engine.globalMargin() + maxLiability;
        uint256 freeUsdc = vault.getFreeUSDC();

        assertEq(freeUsdc, vault.totalAssets() - lockedCapital, "Firewall did not lock Max Liability + Margin");
        assertTrue(lockedCapital > 50_000 * 1e6, "Locked capital must include max profit");
        assertTrue(engine.globalMargin() > 0, "Margin must be tracked");

        // Bob tries to withdraw EVERYTHING, but is strictly capped at freeUsdc
        uint256 bobMaxWithdraw = vault.maxWithdraw(bob);
        assertEq(bobMaxWithdraw, freeUsdc, "LP should only be able to withdraw unencumbered capital");
    }

}
