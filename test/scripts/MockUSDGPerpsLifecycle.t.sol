// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {DeployPerpsArbitrumSepolia} from "../../script/DeployPerpsArbitrumSepolia.s.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Mirrors the Arbitrum precompile's block-number view inside the local test EVM.
contract MockUSDGArbSys {

    function arbBlockNumber() external view returns (uint256) {
        return block.number;
    }

}

/// @notice Exercises the release token and full release stack entirely inside Forge's local test EVM.
contract MockUSDGPerpsLifecycleTest is Test {

    address internal constant RELEASE_PYTH = 0x0B73614636C855Bf23F342F307FB981A3e47f42B;
    uint256 internal constant DEPLOYER_KEY = 0xA11CE;
    uint256 internal constant MONDAY_MORNING = 1_709_532_000;
    address internal constant TRADER = address(0x7ADE);
    address internal constant LP = address(0x1F);
    address internal constant KEEPER = address(0xB07);
    uint256 internal constant POSITION_SIZE = 10_000e18;
    uint256 internal constant LP_ASSETS = 1_000_000e6;

    DeployPerpsArbitrumSepolia.DeployedContracts internal deployed;

    function setUp() public {
        vm.chainId(421_614);
        vm.warp(MONDAY_MORNING);
        MockUSDGArbSys arbSys = new MockUSDGArbSys();
        vm.etch(address(100), address(arbSys).code);
        MockPyth pyth = new MockPyth();
        vm.etch(RELEASE_PYTH, address(pyth).code);
        vm.setEnv("TEST_PRIVATE_KEY", vm.toString(DEPLOYER_KEY));
        deployed =
            DeployPerpsArbitrumSepolia(deployCode("DeployPerpsArbitrumSepolia.s.sol:DeployPerpsArbitrumSepolia")).run();

        // Keep permanent seed funding small; ordinary asynchronous LP deposits supply trading liquidity below.
        address owner = vm.addr(DEPLOYER_KEY);
        deployed.settlementToken.mint(owner, 2e6);
        vm.startPrank(owner);
        deployed.settlementToken.approve(address(deployed.housePool), 2e6);
        deployed.housePool.initializeSeedPosition(false, 1e6, owner);
        deployed.housePool.initializeSeedPosition(true, 1e6, owner);
        deployed.housePool.activateTrading();
        vm.stopPrank();

        _setBasketPrices(120_000_000);
        deployed.router.updateMarkPrice(_updateData());
        assertApproxEqAbs(deployed.engine.lastMarkPrice(), 120_000_000, 10, "non-unit FX basket");
    }

    function test_MockUSDGFundsTradingAndAsyncLpLifecycle() public {
        uint256 lpShares = _depositJuniorLiquidity();

        // Minting is unrestricted and repeatable, including when somebody other than the trader submits it.
        vm.prank(LP);
        deployed.settlementToken.mint(TRADER, 5000e6);
        vm.prank(KEEPER);
        deployed.settlementToken.mint(TRADER, 5000e6);
        assertEq(deployed.settlementToken.balanceOf(TRADER), 10_000e6);
        vm.startPrank(TRADER);
        deployed.settlementToken.approve(address(deployed.clearinghouse), 10_000e6);
        deployed.clearinghouse.depositMargin(10_000e6);
        vm.stopPrank();
        assertEq(deployed.clearinghouse.balanceUsdc(TRADER), 10_000e6, "legacy units hold USDG");
        assertEq(deployed.settlementToken.balanceOf(TRADER), 0);

        _executeTrade(false, 120_000_000);
        (uint256 size,, uint256 entryPrice,,,,) = deployed.engine.positions(TRADER);
        assertEq(size, POSITION_SIZE);
        assertApproxEqAbs(entryPrice, 120_000_000, 10);
        uint256 entryCost = deployed.engine.positionEntryCostUsdcAtoms(TRADER);
        assertApproxEqAbs(entryCost, 12_000e6, 1000, "basket price must participate in notional conversion");

        // A LONG loses as the raw FX basket rises. Exercise actual PnL settlement before withdrawing collateral.
        _executeTrade(true, 125_000_000);
        (size,,,,,,) = deployed.engine.positions(TRADER);
        assertEq(size, 0);
        uint256 withdrawable = deployed.clearinghouse.balanceUsdc(TRADER);
        assertGt(withdrawable, 9400e6, "collateral survives ordinary settlement costs");
        assertLt(withdrawable, 9500e6, "500 USDG price loss plus execution costs");
        vm.prank(TRADER);
        deployed.clearinghouse.withdrawMargin(withdrawable);
        assertEq(deployed.settlementToken.balanceOf(TRADER), withdrawable);
        assertEq(deployed.clearinghouse.balanceUsdc(TRADER), 0);
        assertGt(deployed.clearinghouse.balanceUsdc(KEEPER), 0, "keeper receives USDG execution bounties");

        _redeemJuniorLiquidity(lpShares / 2);
        assertEq(deployed.juniorVault.balanceOf(LP), lpShares - lpShares / 2);
        assertEq(deployed.housePool.excessAssets(), 0, "settlement cash remains accounted for");
    }

    function _depositJuniorLiquidity() internal returns (uint256 shares) {
        deployed.settlementToken.mint(LP, LP_ASSETS);
        vm.startPrank(LP);
        deployed.settlementToken.approve(address(deployed.juniorVault), LP_ASSETS);
        uint256 requestId = deployed.juniorVault.requestDeposit(LP_ASSETS, LP, LP);
        vm.stopPrank();
        assertEq(deployed.juniorVault.pendingDepositRequest(requestId, LP), LP_ASSETS);
        assertEq(deployed.juniorVault.claimableDepositRequest(requestId, LP), 0);
        assertEq(deployed.settlementToken.balanceOf(address(deployed.juniorVault)), LP_ASSETS);

        vm.warp(deployed.housePool.lpEpochStart(requestId));
        _setBasketPrices(120_000_000);
        deployed.router.settleLpEpoch(_updateData());
        assertEq(deployed.juniorVault.pendingDepositRequest(requestId, LP), 0);
        assertEq(deployed.juniorVault.claimableDepositRequest(requestId, LP), LP_ASSETS);
        vm.prank(LP);
        shares = deployed.juniorVault.claimDeposit(requestId, LP_ASSETS, LP, LP);
        assertGt(shares, 0);
        assertEq(deployed.juniorVault.balanceOf(LP), shares);
        assertEq(deployed.settlementToken.balanceOf(address(deployed.housePool)), LP_ASSETS + 2e6);
    }

    function _redeemJuniorLiquidity(
        uint256 shares
    ) internal {
        vm.warp(deployed.juniorVault.lastDepositTime(LP) + deployed.juniorVault.DEPOSIT_COOLDOWN());
        _setBasketPrices(125_000_000);
        deployed.router.updateMarkPrice(_updateData());
        vm.prank(LP);
        uint256 requestId = deployed.juniorVault.requestRedeem(shares, LP, LP);
        assertEq(deployed.juniorVault.pendingRedeemRequest(requestId, LP), shares);
        assertEq(deployed.juniorVault.claimableRedeemRequest(requestId, LP), 0);
        assertEq(deployed.settlementToken.balanceOf(LP), 0);

        vm.warp(deployed.housePool.lpEpochStart(requestId));
        _setBasketPrices(125_000_000);
        deployed.router.settleLpEpoch(_updateData());
        assertEq(deployed.juniorVault.pendingRedeemRequest(requestId, LP), 0);
        assertEq(deployed.juniorVault.claimableRedeemRequest(requestId, LP), shares);
        uint256 claimableAssets = deployed.juniorVault.claimableRedeemAssets(requestId, LP);
        assertGt(claimableAssets, 0);
        vm.prank(LP);
        uint256 redeemedAssets = deployed.juniorVault.claimRedeem(requestId, shares, LP, LP);
        assertEq(redeemedAssets, claimableAssets);
        assertEq(deployed.settlementToken.balanceOf(LP), redeemedAssets);
        assertEq(deployed.juniorVault.claimableRedeemRequest(requestId, LP), 0);
    }

    function _executeTrade(
        bool isClose,
        uint256 basketPrice
    ) internal {
        OrderV3Types.OrderRequest memory request;
        request.clientOrderId = isClose ? bytes32("usdg-close") : bytes32("usdg-open");
        request.side = CfdTypes.Side.LONG;
        request.sizeDelta = POSITION_SIZE;
        request.marginDelta = isClose ? 0 : 1000e6;
        request.targetPrice = isClose ? 130_000_000 : 115_000_000;
        request.isClose = isClose;
        request.bounds = OrderV3Types.ExecutionBounds({
            submitBy: uint64(vm.getBlockTimestamp() + 60),
            executionWindowSeconds: 60,
            allowedExecutionModes: 1,
            expectedConfigHash: deployed.lifecycleBook.currentExecutionConfigHash(),
            maxExecutionBountyUsdc: 100e6,
            maxExecutionNotionalUsdc: 13_000e6,
            maxGrossAccountDebitUsdc: 1100e6,
            maxActionChargeUsdc: 100e6,
            maxExplicitFeesUsdc: 100e6,
            maxPostPositionSize: POSITION_SIZE,
            minPostSettlementBalanceUsdc: isClose ? 0 : 8800e6,
            minPostPositionEquityUsdc: 0,
            maxPostLeverageBps: 200_000
        });
        vm.prank(TRADER);
        uint64 orderId = deployed.router.commitOrder(request);
        vm.warp(vm.getBlockTimestamp() + 7);
        vm.roll(vm.getBlockNumber() + 2);
        _setBasketPrices(basketPrice);
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = deployed.router.executeOrder(orderId, _updateData());
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed), "release order executes");
        assertEq(uint8(result.terminalReason), uint8(OrderV3Types.TerminalReason.Executed));
    }

    function _setBasketPrices(
        uint256 basketPrice
    ) internal {
        PletherOracle oracle = PletherOracle(deployed.pletherOracle);
        for (uint256 i; i < 6; ++i) {
            // Each real release feed moves by the same normalized factor; inverse FX feeds keep their own units.
            uint256 normalizedPrice = oracle.basePrices(i) * basketPrice / 1e8;
            uint256 feedPrice = oracle.inversions(i) ? 1e16 / normalizedPrice : normalizedPrice;
            MockPyth(RELEASE_PYTH)
                .setPrice(oracle.pythFeedIds(i), int64(uint64(feedPrice)), int32(-8), vm.getBlockTimestamp());
        }
    }

    function _updateData() internal pure returns (bytes[] memory data) {
        data = new bytes[](1);
        // A non-encoded payload tells this Pyth test double to use the individually configured FX prices.
        data[0] = "";
    }

}
