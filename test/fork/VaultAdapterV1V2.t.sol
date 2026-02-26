// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {SyntheticSplitter} from "../../src/SyntheticSplitter.sol";
import {VaultAdapter} from "../../src/VaultAdapter.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {BasketOracle} from "../../src/oracles/BasketOracle.sol";
import {BaseForkTest, MockCurvePoolForOracle} from "./BaseForkTest.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract VaultAdapterV1V2Test is BaseForkTest {

    IERC4626 constant MORPHO_VAULT_V1 = IERC4626(0xc582F04d8a82795aa2Ff9c8bb4c1c889fe7b754e);
    IERC4626 constant MORPHO_VAULT_V2 = IERC4626(0x9a1D6bd5b8642C41F25e0958129B85f8E1176F3e);

    address treasury;
    address alice = address(0xA11CE);

    function setUp() public {
        try vm.envString("MAINNET_RPC_URL") returns (string memory url) {
            vm.createSelectFork(url);
        } catch {
            revert("Missing MAINNET_RPC_URL in .env");
        }

        treasury = makeAddr("treasury");
        deal(USDC, alice, 1_000_000e6);

        (, int256 price,, uint256 updatedAt,) = AggregatorV3Interface(CL_EUR).latestRoundData();
        realOraclePrice = (uint256(price) * 1e18) / (BASE_EUR * 1e10) * 1e10;
        bearPrice = realOraclePrice;
        uint256 target = updatedAt + 1 hours;
        if (target < block.timestamp) {
            target = block.timestamp;
        }
        vm.warp(target);
    }

    function _deployWithVault(
        IERC4626 vault
    ) internal returns (VaultAdapter adapter) {
        address[] memory feeds = new address[](1);
        feeds[0] = CL_EUR;
        uint256[] memory qtys = new uint256[](1);
        qtys[0] = 1e18;
        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = BASE_EUR;

        address tempCurvePool = address(new MockCurvePoolForOracle(bearPrice));
        basketOracle = new BasketOracle(feeds, qtys, basePrices, 200, 2e8, address(this));
        basketOracle.setCurvePool(tempCurvePool);

        uint64 currentNonce = vm.getNonce(address(this));
        address predictedSplitter = vm.computeCreateAddress(address(this), currentNonce + 1);

        adapter = new VaultAdapter(IERC20(USDC), address(vault), address(this), predictedSplitter);

        splitter = new SyntheticSplitter(address(basketOracle), USDC, address(adapter), 2e8, treasury, address(0));
        require(address(splitter) == predictedSplitter, "Splitter address mismatch");

        bullToken = address(splitter.BULL());
        bearToken = address(splitter.BEAR());
    }

    function _mintAndDeploy(
        uint256 mintAmount
    ) internal returns (uint256 usdcRequired) {
        vm.startPrank(alice);
        (usdcRequired,,) = splitter.previewMint(mintAmount);
        IERC20(USDC).approve(address(splitter), usdcRequired);
        splitter.mint(mintAmount);
        vm.stopPrank();

        splitter.deployToAdapter();
    }

    function _assertMaxFunctionsWork(
        VaultAdapter adapter
    ) internal view {
        assertGt(adapter.totalAssets(), 0, "Should have assets after deposit");
        assertGt(adapter.maxWithdraw(address(splitter)), 0, "maxWithdraw should be > 0");
        assertGt(adapter.maxRedeem(address(splitter)), 0, "maxRedeem should be > 0");
        assertEq(adapter.maxDeposit(address(splitter)), type(uint256).max, "maxDeposit should be unlimited");
        assertEq(adapter.maxMint(address(splitter)), type(uint256).max, "maxMint should be unlimited");
    }

    function _harvestWithSimulatedYield() internal {
        deal(USDC, address(splitter), IERC20(USDC).balanceOf(address(splitter)) + 100e6);

        uint256 treasuryBefore = IERC20(USDC).balanceOf(treasury);
        splitter.harvestYield();
        uint256 harvested = IERC20(USDC).balanceOf(treasury) - treasuryBefore;
        assertGt(harvested, 0, "Treasury should receive yield");
    }

    function _burnAndAssertRoundTrip(
        uint256 mintAmount,
        uint256 usdcRequired
    ) internal {
        deal(USDC, address(splitter), IERC20(USDC).balanceOf(address(splitter)) + 10);

        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.startPrank(alice);
        IERC20(bullToken).approve(address(splitter), mintAmount);
        IERC20(bearToken).approve(address(splitter), mintAmount);
        splitter.burn(mintAmount);
        vm.stopPrank();

        uint256 returned = IERC20(USDC).balanceOf(alice) - aliceBefore;
        assertGt(returned, (usdcRequired * 99) / 100, "Round-trip should return >99% of USDC");
    }

    function test_V1_DepositWithdrawHarvest() public {
        VaultAdapter adapter = _deployWithVault(MORPHO_VAULT_V1);
        uint256 mintAmount = 10_000e18;
        uint256 usdcRequired = _mintAndDeploy(mintAmount);

        _assertMaxFunctionsWork(adapter);
        _harvestWithSimulatedYield();
        _burnAndAssertRoundTrip(mintAmount, usdcRequired);
    }

    function test_V2_DepositWithdrawHarvest() public {
        VaultAdapter adapter = _deployWithVault(MORPHO_VAULT_V2);
        uint256 mintAmount = 10_000e18;
        uint256 usdcRequired = _mintAndDeploy(mintAmount);

        _assertMaxFunctionsWork(adapter);
        _harvestWithSimulatedYield();
        _burnAndAssertRoundTrip(mintAmount, usdcRequired);
    }

}
