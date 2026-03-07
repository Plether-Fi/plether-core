// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test, console} from "forge-std/Test.sol";

contract MockToken is ERC20 {

    uint8 _decimals;

    constructor(
        string memory name,
        string memory sym,
        uint8 dec
    ) ERC20(name, sym) {
        _decimals = dec;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

contract MockOracle {

    uint256 public price;

    constructor(
        uint256 _price
    ) {
        price = _price;
    }

    function getPriceUnsafe() external view returns (uint256) {
        return price;
    }

    function setPrice(
        uint256 _price
    ) external {
        price = _price;
    }

}

contract MarginClearinghouseTest is Test {

    MarginClearinghouse clearinghouse;
    MockToken usdc;
    MockToken splDxy;
    MockOracle splDxyOracle;

    address alice = address(0x111);
    address engine = address(0x999);
    bytes32 aliceId;

    function setUp() public {
        clearinghouse = new MarginClearinghouse();
        aliceId = bytes32(uint256(uint160(alice)));

        usdc = new MockToken("USDC", "USDC", 6);
        splDxy = new MockToken("Staked DXY", "splDXY", 18);

        // Oracle returns $1.00 in 8 decimals
        splDxyOracle = new MockOracle(1e8);

        // Whitelist USDC (100% LTV, 6 dec, No Oracle)
        clearinghouse.supportAsset(address(usdc), 6, 10_000, address(0));

        // Whitelist splDXY (95% LTV Haircut, 18 dec, Mock Oracle)
        clearinghouse.supportAsset(address(splDxy), 18, 9500, address(splDxyOracle));

        // Authorize our mock Engine to lock/seize funds
        clearinghouse.setOperator(engine, true);

        // Fund Alice
        usdc.mint(alice, 5000 * 1e6); // $5k USDC
        splDxy.mint(alice, 10_000 * 1e18); // 10k splDXY

        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), type(uint256).max);
        splDxy.approve(address(clearinghouse), type(uint256).max);
        vm.stopPrank();
    }

    function test_CrossMarginValuation() public {
        vm.startPrank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 1000 * 1e6); // Deposit $1,000 USDC
        clearinghouse.deposit(aliceId, address(splDxy), 10_000 * 1e18); // Deposit 10k splDXY ($10,000 spot value)
        vm.stopPrank();

        // 1. Check Portfolio Value
        // $1,000 USDC * 100% = $1,000
        // $10,000 splDXY * 95% LTV Haircut = $9,500
        // Total Expected Equity = $10,500 USDC (6 decimals)

        uint256 equity = clearinghouse.getAccountEquityUsdc(aliceId);
        assertEq(equity, 10_500 * 1e6, "Equity valuation incorrect");

        // 2. Oracle Price Crash! splDXY drops from $1.00 to $0.50
        splDxyOracle.setPrice(0.5e8);

        // New Value: $1,000 + ($5,000 * 95%) = $5,750
        uint256 crashedEquity = clearinghouse.getAccountEquityUsdc(aliceId);
        assertEq(crashedEquity, 5750 * 1e6, "Oracle price crash did not update equity");
    }

    function test_WithdrawalFirewall_LockedMargin() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 5000 * 1e6); // $5k USDC

        // 1. Engine locks $4,000 of Buying Power for a CFD trade
        vm.prank(engine);
        clearinghouse.lockMargin(aliceId, 4000 * 1e6);

        // 2. Check Free Buying Power
        uint256 freeBp = clearinghouse.getFreeBuyingPowerUsdc(aliceId);
        assertEq(freeBp, 1000 * 1e6, "Free BP should be exactly $1,000");

        // 3. Alice tries to withdraw $2,000. MUST REVERT because it breaches locked margin.
        vm.prank(alice);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
        clearinghouse.withdraw(aliceId, address(usdc), 2000 * 1e6);

        // 4. Alice withdraws exactly $1,000. MUST SUCCEED.
        vm.prank(alice);
        clearinghouse.withdraw(aliceId, address(usdc), 1000 * 1e6);

        assertEq(usdc.balanceOf(alice), 1000 * 1e6, "Alice should receive $1k");
        assertEq(
            clearinghouse.getAccountEquityUsdc(aliceId),
            4000 * 1e6,
            "Remaining equity should exactly match locked margin"
        );
    }

    function test_LtvHaircut_80Percent() public {
        MockToken weth = new MockToken("Wrapped ETH", "WETH", 18);
        MockOracle wethOracle = new MockOracle(2000e8);
        clearinghouse.supportAsset(address(weth), 18, 8000, address(wethOracle));

        weth.mint(alice, 1e18);
        vm.startPrank(alice);
        weth.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(aliceId, address(weth), 1e18);
        vm.stopPrank();

        // 1e18 * 2000e8 / 10^20 = 2000e6 spot value → 80% haircut = 1600e6
        uint256 equity = clearinghouse.getAccountEquityUsdc(aliceId);
        assertEq(equity, 1600 * 1e6, "80% LTV should haircut to $1600");
    }

    function test_BuyingPower_BlockedByActivePositions() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 5000 * 1e6);

        vm.prank(engine);
        clearinghouse.lockMargin(aliceId, 4500 * 1e6);

        uint256 freeBp = clearinghouse.getFreeBuyingPowerUsdc(aliceId);
        assertEq(freeBp, 500 * 1e6, "Free BP should be $500");

        vm.prank(alice);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
        clearinghouse.withdraw(aliceId, address(usdc), 1000 * 1e6);
    }

    function test_Deposit_UnsupportedAsset_Reverts() public {
        MockToken randomToken = new MockToken("Random", "RND", 18);
        randomToken.mint(alice, 1000e18);

        vm.startPrank(alice);
        randomToken.approve(address(clearinghouse), type(uint256).max);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__AssetNotSupported.selector);
        clearinghouse.deposit(aliceId, address(randomToken), 1000e18);
        vm.stopPrank();
    }

    function test_Withdraw_WrongOwner_Reverts() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 1000 * 1e6);

        address bob = address(0x222);
        vm.prank(bob);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotAccountOwner.selector);
        clearinghouse.withdraw(aliceId, address(usdc), 500 * 1e6);
    }

    function test_UnlockMargin_DefensiveUnderflow() public {
        vm.prank(alice);
        clearinghouse.deposit(aliceId, address(usdc), 5000 * 1e6);

        vm.prank(engine);
        clearinghouse.lockMargin(aliceId, 1000 * 1e6);

        // Unlock more than locked — should defensively set to 0
        vm.prank(engine);
        clearinghouse.unlockMargin(aliceId, 2000 * 1e6);

        assertEq(clearinghouse.lockedMarginUsdc(aliceId), 0, "Locked margin should be zero after defensive unlock");
    }

    function test_SupportAsset_InvalidLTV_Reverts() public {
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InvalidLTV.selector);
        clearinghouse.supportAsset(address(0xBEEF), 18, 10_001, address(0));
    }

    function test_Deposit_ZeroAmount_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__ZeroAmount.selector);
        clearinghouse.deposit(aliceId, address(usdc), 0);
    }

}
