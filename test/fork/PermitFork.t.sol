// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ZapRouter} from "../../src/ZapRouter.sol";
import {BaseForkTest} from "./BaseForkTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "forge-std/Test.sol";

/// @title Permit Fork Tests
/// @notice Tests zapBurnWithPermit which uses DXY-BULL's EIP-2612 permit
contract PermitForkTest is BaseForkTest {

    ZapRouter zapRouter;

    uint256 alicePrivateKey = 0xA11CE;
    address alice;

    function setUp() public {
        _setupFork();

        alice = vm.addr(alicePrivateKey);

        deal(USDC, address(this), 10_000_000e6);

        _fetchPriceAndWarp();
        _deployProtocol(address(this));
        _mintInitialTokens(1_000_000e18);
        _deployCurvePool(800_000e18);

        zapRouter = new ZapRouter(address(splitter), bearToken, bullToken, USDC, curvePool);

        IERC20(bullToken).transfer(alice, 10_000e18);
    }

    function test_ZapBurnWithPermit() public {
        uint256 bullAmount = 1000e18;
        uint256 deadline = block.timestamp + 1 hours;

        (,, uint256 expectedUsdcOut,) = zapRouter.previewZapBurn(bullAmount);
        uint256 minUsdcOut = (expectedUsdcOut * 95) / 100;

        bytes32 permitHash = _getPermitHash(
            bullToken, alice, address(zapRouter), bullAmount, IERC20Permit(bullToken).nonces(alice), deadline
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, permitHash);

        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);
        uint256 aliceBullBefore = IERC20(bullToken).balanceOf(alice);

        vm.prank(alice);
        zapRouter.zapBurnWithPermit(bullAmount, minUsdcOut, deadline, v, r, s);

        assertEq(aliceBullBefore - IERC20(bullToken).balanceOf(alice), bullAmount, "BULL tokens should be burned");
        assertGt(IERC20(USDC).balanceOf(alice) - aliceUsdcBefore, minUsdcOut, "Should receive USDC");
    }

    function _getPermitHash(
        address token,
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));

        bytes32 domainSeparator = IERC20Permit(token).DOMAIN_SEPARATOR();

        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

}
