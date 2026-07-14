// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {DeploySpotArbitrumSepolia} from "../../script/DeploySpotArbitrumSepolia.s.sol";
import {IMintableERC20, MockUSDC} from "../../script/DeployToTest.s.sol";
import {MockTwocryptoPool} from "../../script/mocks/MockTwocryptoPool.s.sol";
import {MockToken} from "../mocks/MockToken.sol";
import {InvarCoin} from "@plether/spot/core/InvarCoin.sol";
import {Test} from "forge-std/Test.sol";

contract MockBasketOracleForSpotScriptTest {

    int256 internal immutable price;

    constructor(
        int256 price_
    ) {
        price = price_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, block.timestamp, block.timestamp, 1);
    }

}

contract DeploySpotArbitrumSepoliaHarness is DeploySpotArbitrumSepolia {

    function deployOrLoadUsdc() external returns (IMintableERC20) {
        return _deployOrLoadUsdc();
    }

    function deployCurvePool(
        address usdc,
        address bear,
        uint256 initialPrice
    ) external returns (address) {
        return _deployCurvePool(usdc, bear, initialPrice);
    }

    function nonceOffset() external pure returns (uint64) {
        return _getNonceOffset();
    }

}

contract DeploySpotArbitrumSepoliaTest is Test {

    function test_DeployOrLoadUsdc_UsesSpotUsdcOverride() public {
        DeploySpotArbitrumSepoliaHarness deployScript = new DeploySpotArbitrumSepoliaHarness();
        MockUSDC usdc = new MockUSDC();
        vm.setEnv("SPOT_USDC", vm.toString(address(usdc)));

        IMintableERC20 loaded = deployScript.deployOrLoadUsdc();

        assertEq(address(loaded), address(usdc), "loaded usdc");
        assertEq(loaded.decimals(), 6, "decimals");

        loaded.mint(address(this), 1e6);
        assertEq(loaded.balanceOf(address(this)), 1e6, "mintable");
    }

    function test_DeployOrLoadUsdc_RevertsForWrongDecimals() public {
        DeploySpotArbitrumSepoliaHarness deployScript = new DeploySpotArbitrumSepoliaHarness();
        MockToken badUsdc = new MockToken("Bad USDC", "BAD", 18);
        vm.setEnv("SPOT_USDC", vm.toString(address(badUsdc)));

        vm.expectRevert("USDC must have 6 decimals");
        deployScript.deployOrLoadUsdc();
    }

    function test_DeployCurvePool_DeploysPoolAsLpToken() public {
        DeploySpotArbitrumSepoliaHarness deployScript = new DeploySpotArbitrumSepoliaHarness();
        MockUSDC usdc = new MockUSDC();
        MockToken bear = new MockToken("BEAR", "BEAR", 18);

        address pool = deployScript.deployCurvePool(address(usdc), address(bear), 1e18);

        assertEq(MockTwocryptoPool(pool).token(), pool, "pool is lp token");
        assertEq(MockTwocryptoPool(pool).price_oracle(), 1e18, "price");
        assertEq(deployScript.nonceOffset(), 42, "nonce offset");
    }

}

contract MockTwocryptoPoolTest is Test {

    MockUSDC internal usdc;
    MockToken internal bear;
    MockTwocryptoPool internal pool;

    uint256 internal constant PRICE = 0.8e18;

    function setUp() public {
        vm.warp(2 days);

        usdc = new MockUSDC();
        bear = new MockToken("BEAR", "BEAR", 18);
        pool = new MockTwocryptoPool(address(usdc), address(bear), PRICE);

        usdc.mint(address(this), 1000e6);
        bear.mint(address(this), 1250e18);
        usdc.approve(address(pool), type(uint256).max);
        bear.approve(address(pool), type(uint256).max);

        pool.add_liquidity([uint256(1000e6), uint256(1250e18)], 0);
    }

    function test_QuotesUseInitialPriceAndTokenDecimals() public {
        assertEq(pool.get_dy(0, 1, 1e6), 1.25e18, "usdc to bear");
        assertEq(pool.get_dy(1, 0, 1e18), 0.8e6, "bear to usdc");
        assertEq(pool.price_oracle(), PRICE, "oracle price");
    }

    function test_AddLiquidityMintsPoolAddressLpToken() public {
        assertEq(pool.token(), address(pool), "lp token");
        assertEq(pool.balanceOf(address(this)), 2000e18, "lp minted");
        assertEq(pool.get_virtual_price(), 1e18, "virtual price");
        assertEq(pool.lp_price(), 1e18, "lp price");
    }

    function test_ExchangeTransfersReservesAtQuotedPrice() public {
        address trader = address(0xA11CE);
        usdc.mint(trader, 8e6);

        vm.startPrank(trader);
        usdc.approve(address(pool), 8e6);
        uint256 bearOut = pool.exchange(0, 1, 8e6, 10e18);
        vm.stopPrank();

        assertEq(bearOut, 10e18, "bear out");
        assertEq(bear.balanceOf(trader), 10e18, "trader bear");
        assertEq(usdc.balanceOf(address(pool)), 1008e6, "pool usdc");
    }

    function test_ExchangeReceiverOverloadMatchesSepoliaCurveAbi() public {
        address trader = address(0xA11CE);
        address receiver = address(0xBEEF);
        usdc.mint(trader, 8e6);

        vm.startPrank(trader);
        usdc.approve(address(pool), 8e6);
        (bool ok, bytes memory data) = address(pool)
            .call(
                abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256,address)", 0, 1, 8e6, 10e18, receiver)
            );
        vm.stopPrank();

        assertTrue(ok, "5-arg exchange");
        assertEq(abi.decode(data, (uint256)), 10e18, "bear out");
        assertEq(bear.balanceOf(receiver), 10e18, "receiver bear");
    }

    function test_LiquidityReceiverOverloadsMatchSepoliaCurveAbi() public {
        address receiver = address(0xBEEF);
        usdc.mint(address(this), 1e6);

        (bool addOk, bytes memory addData) = address(pool)
            .call(
                abi.encodeWithSignature(
                    "add_liquidity(uint256[2],uint256,address)", [uint256(1e6), uint256(0)], 0, receiver
                )
            );
        assertTrue(addOk, "3-arg add_liquidity");
        assertEq(abi.decode(addData, (uint256)), 1e18, "lp minted");
        assertEq(pool.balanceOf(receiver), 1e18, "receiver lp");

        vm.startPrank(receiver);
        (bool removeOneOk, bytes memory removeOneData) = address(pool)
            .call(
                abi.encodeWithSignature(
                    "remove_liquidity_one_coin(uint256,uint256,uint256,address)", 1e18, 0, 1e6, receiver
                )
            );
        vm.stopPrank();

        assertTrue(removeOneOk, "4-arg remove_liquidity_one_coin");
        assertEq(abi.decode(removeOneData, (uint256)), 1e6, "usdc out");
        assertEq(usdc.balanceOf(receiver), 1e6, "receiver usdc");
    }

    function test_SepoliaCurveReadSurfaceIsAvailable() public view {
        assertEq(pool.coins(0), address(usdc), "coin 0");
        assertEq(pool.coins(1), address(bear), "coin 1");
        assertEq(pool.balances(0), 1000e6, "usdc balance");
        assertEq(pool.balances(1), 1250e18, "bear balance");
        assertEq(pool.get_dx(0, 1, 10e18), 8e6, "get dx");
        assertEq(pool.price_scale(), PRICE, "price scale");
        assertEq(pool.last_prices(), PRICE, "last prices");
        assertEq(pool.virtual_price(), pool.get_virtual_price(), "virtual price alias");
        assertTrue(pool.DOMAIN_SEPARATOR() != bytes32(0), "domain separator");
    }

    function test_RemoveLiquidityReturnsProRataReserves() public {
        uint256 lpToBurn = pool.balanceOf(address(this)) / 2;

        uint256[2] memory amounts = pool.remove_liquidity(lpToBurn, [uint256(500e6), uint256(625e18)]);

        assertEq(amounts[0], 500e6, "usdc out");
        assertEq(amounts[1], 625e18, "bear out");
        assertEq(pool.balanceOf(address(this)), 1000e18, "remaining lp");
    }

    function test_RemoveLiquidityOneCoinUsesLpValue() public {
        uint256 usdcOut = pool.remove_liquidity_one_coin(10e18, 0, 10e6);

        assertEq(usdcOut, 10e6, "usdc out");
        assertEq(usdc.balanceOf(address(this)), 10e6, "receiver usdc");
        assertEq(pool.balanceOf(address(this)), 1990e18, "remaining lp");
    }

    function test_CalcTokenAmountMatchesLpMintingValue() public {
        assertEq(pool.calc_token_amount([uint256(1e6), uint256(0)], true), 1e18, "usdc lp");
        assertEq(pool.calc_token_amount([uint256(0), uint256(1e18)], true), 0.8e18, "bear lp");
    }

    function test_InvarCoinLpDepositUsesMockPoolTwocryptoSurface() public {
        MockBasketOracleForSpotScriptTest oracle = new MockBasketOracleForSpotScriptTest(80_000_000);
        InvarCoin invar = new InvarCoin(
            address(usdc), address(bear), address(pool), address(pool), address(oracle), address(0), address(0)
        );

        address depositor = address(0xB0B);
        usdc.mint(depositor, 1e6);
        bear.mint(depositor, 1.25e18);

        vm.startPrank(depositor);
        usdc.approve(address(invar), 1e6);
        bear.approve(address(invar), 1.25e18);
        uint256 shares = invar.lpDeposit(1e6, 1.25e18, depositor, 0);
        vm.stopPrank();

        assertEq(shares, 2e18, "shares");
        assertEq(pool.balanceOf(address(invar)), 2e18, "invar lp");
        assertEq(invar.trackedLpBalance(), 2e18, "tracked lp");
        assertEq(invar.curveLpCostVp(), 2e18, "vp cost");
    }

}
