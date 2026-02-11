// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BaseForkTest} from "./BaseForkTest.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployToAdapterForkTest is BaseForkTest {

    address treasury;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        _setupFork();
        treasury = makeAddr("treasury");
        deal(USDC, alice, 1_000_000e6);
        deal(USDC, bob, 1_000_000e6);
        _fetchPriceAndWarp();
        _deployProtocol(treasury);
    }

    function test_DeployToAdapter_PushesExcessToVault() public {
        uint256 mintAmount = 10_000e18;

        vm.startPrank(alice);
        (uint256 usdcRequired,,) = splitter.previewMint(mintAmount);
        IERC20(USDC).approve(address(splitter), usdcRequired);
        splitter.mint(mintAmount);
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(address(splitter)), usdcRequired, "All USDC local before deploy");
        assertEq(STEAKHOUSE_USDC.balanceOf(address(yieldAdapter)), 0, "No vault shares before deploy");

        uint256 deployed = splitter.deployToAdapter();

        uint256 expectedBuffer = usdcRequired / 10;
        uint256 expectedDeployed = usdcRequired - expectedBuffer;

        assertApproxEqRel(deployed, expectedDeployed, 0.01e18, "Deployed amount ~90%");
        assertApproxEqRel(
            IERC20(USDC).balanceOf(address(splitter)), expectedBuffer, 0.01e18, "Buffer ~10% of liabilities"
        );
        assertGt(STEAKHOUSE_USDC.balanceOf(address(yieldAdapter)), 0, "Adapter holds Morpho vault shares");
    }

    function test_DeployToAdapter_NoopWhenBalanced() public {
        uint256 mintAmount = 10_000e18;

        vm.startPrank(alice);
        (uint256 usdcRequired,,) = splitter.previewMint(mintAmount);
        IERC20(USDC).approve(address(splitter), usdcRequired);
        splitter.mint(mintAmount);
        vm.stopPrank();

        splitter.deployToAdapter();
        uint256 sharesAfterFirst = STEAKHOUSE_USDC.balanceOf(address(yieldAdapter));

        uint256 deployed = splitter.deployToAdapter();

        assertEq(deployed, 0, "Should return 0 when balanced");
        assertEq(STEAKHOUSE_USDC.balanceOf(address(yieldAdapter)), sharesAfterFirst, "No additional shares minted");
    }

    function test_DeployToAdapter_SkipsBelowMinDeploy() public {
        // 55 tokens → 110 USDC → excess = 99 USDC < MIN_DEPLOY_AMOUNT (100 USDC)
        uint256 mintAmount = 55e18;

        vm.startPrank(alice);
        (uint256 usdcRequired,,) = splitter.previewMint(mintAmount);
        IERC20(USDC).approve(address(splitter), usdcRequired);
        splitter.mint(mintAmount);
        vm.stopPrank();

        uint256 deployed = splitter.deployToAdapter();

        assertEq(deployed, 0, "Should skip below MIN_DEPLOY_AMOUNT");
        assertEq(STEAKHOUSE_USDC.balanceOf(address(yieldAdapter)), 0, "No vault shares created");
    }

    function test_DeployToAdapter_MultipleMintsThenDeploy() public {
        uint256 mintAmount = 5000e18;

        vm.startPrank(alice);
        (uint256 usdcAlice,,) = splitter.previewMint(mintAmount);
        IERC20(USDC).approve(address(splitter), usdcAlice);
        splitter.mint(mintAmount);
        vm.stopPrank();

        vm.startPrank(bob);
        (uint256 usdcBob,,) = splitter.previewMint(mintAmount);
        IERC20(USDC).approve(address(splitter), usdcBob);
        splitter.mint(mintAmount);
        vm.stopPrank();

        uint256 totalUsdc = usdcAlice + usdcBob;
        assertEq(IERC20(USDC).balanceOf(address(splitter)), totalUsdc, "All USDC local before deploy");

        uint256 deployed = splitter.deployToAdapter();

        uint256 expectedBuffer = totalUsdc / 10;
        uint256 expectedDeployed = totalUsdc - expectedBuffer;

        assertApproxEqRel(deployed, expectedDeployed, 0.01e18, "Should deploy combined excess");
        assertApproxEqRel(
            IERC20(USDC).balanceOf(address(splitter)),
            expectedBuffer,
            0.01e18,
            "Buffer correct for combined liabilities"
        );
        assertGt(STEAKHOUSE_USDC.balanceOf(address(yieldAdapter)), 0, "Adapter received combined deposit");
    }

    function test_DeployToAdapter_AfterBurnReducesLiabilities() public {
        uint256 mintAmount = 10_000e18;

        // First mint + deploy → balanced (10% local, 90% adapter)
        vm.startPrank(alice);
        (uint256 usdcFirst,,) = splitter.previewMint(mintAmount);
        IERC20(USDC).approve(address(splitter), usdcFirst);
        splitter.mint(mintAmount);
        vm.stopPrank();

        splitter.deployToAdapter();

        // Second mint → USDC accumulates locally (no auto-deploy)
        vm.startPrank(alice);
        (uint256 usdcSecond,,) = splitter.previewMint(mintAmount);
        IERC20(USDC).approve(address(splitter), usdcSecond);
        splitter.mint(mintAmount);
        vm.stopPrank();

        // Burn 5k tokens → reduces liabilities, refund served entirely from local buffer
        uint256 burnAmount = mintAmount / 2;
        vm.startPrank(alice);
        IERC20(bullToken).approve(address(splitter), burnAmount);
        IERC20(bearToken).approve(address(splitter), burnAmount);
        splitter.burn(burnAmount);
        vm.stopPrank();

        // 15k tokens remain. Local has excess from second mint minus burn refund.
        uint256 liabilities = (splitter.BEAR().totalSupply() * splitter.CAP()) / splitter.USDC_MULTIPLIER();
        uint256 targetBuffer = (liabilities * 10) / 100;
        uint256 localBefore = IERC20(USDC).balanceOf(address(splitter));
        assertGt(localBefore, targetBuffer, "Local exceeds buffer target after mint+burn");

        uint256 deployed = splitter.deployToAdapter();

        assertGt(deployed, 0, "Should deploy excess after burn reduced liabilities");
        assertApproxEqRel(
            IERC20(USDC).balanceOf(address(splitter)), targetBuffer, 0.01e18, "Buffer ~10% of reduced liabilities"
        );
    }

}
