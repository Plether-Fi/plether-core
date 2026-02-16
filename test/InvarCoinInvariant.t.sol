// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {InvarCoin} from "../src/InvarCoin.sol";
import {StakedToken} from "../src/StakedToken.sol";
import {OracleLib} from "../src/libraries/OracleLib.sol";
import {MockBEAR, MockCurveLpToken, MockCurvePool, MockMorphoVault, MockUSDC6} from "./InvarCoin.t.sol";
import {MockOracle} from "./utils/MockOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test, console} from "forge-std/Test.sol";

contract InvarCoinHandler is Test {

    InvarCoin public ic;
    StakedToken public sInvar;
    MockUSDC6 public usdc;
    MockBEAR public bear;
    MockMorphoVault public morpho;
    MockCurvePool public curve;
    MockCurveLpToken public curveLp;
    MockOracle public oracle;

    uint256 public ghost_totalInvarMinted;
    uint256 public ghost_totalInvarBurned;
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_totalYieldSimulated;
    uint256 public ghost_totalDustSent;

    uint256 public depositCalls;
    uint256 public withdrawCalls;
    uint256 public lpWithdrawCalls;
    uint256 public deployToCurveCalls;
    uint256 public replenishBufferCalls;
    uint256 public harvestCalls;
    uint256 public simulateYieldCalls;
    uint256 public simulateCurveYieldCalls;
    uint256 public sendUsdcDustCalls;
    uint256 public lpDepositCalls;

    address[] public actors;
    address internal currentActor;

    bytes4 constant ERR_ZERO_AMOUNT = InvarCoin.InvarCoin__ZeroAmount.selector;
    bytes4 constant ERR_SLIPPAGE = InvarCoin.InvarCoin__SlippageExceeded.selector;
    bytes4 constant ERR_INSUFFICIENT_BUFFER = InvarCoin.InvarCoin__InsufficientBuffer.selector;
    bytes4 constant ERR_NOTHING_TO_DEPLOY = InvarCoin.InvarCoin__NothingToDeploy.selector;
    bytes4 constant ERR_NO_YIELD = InvarCoin.InvarCoin__NoYield.selector;
    bytes4 constant ERR_STALE_PRICE = OracleLib.OracleLib__StalePrice.selector;

    function _assertExpectedError(
        bytes memory reason,
        bytes4[] memory allowed
    ) internal pure {
        if (reason.length < 4) {
            revert("Unknown error (no selector)");
        }
        bytes4 selector = bytes4(reason);
        for (uint256 i = 0; i < allowed.length; i++) {
            if (selector == allowed[i]) {
                return;
            }
        }
        assembly {
            revert(add(reason, 32), mload(reason))
        }
    }

    modifier useActor(
        uint256 actorSeed
    ) {
        currentActor = actors[actorSeed % actors.length];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(
        InvarCoin _ic,
        StakedToken _sInvar,
        MockUSDC6 _usdc,
        MockBEAR _bear,
        MockMorphoVault _morpho,
        MockCurvePool _curve,
        MockCurveLpToken _curveLp,
        MockOracle _oracle
    ) {
        ic = _ic;
        sInvar = _sInvar;
        usdc = _usdc;
        bear = _bear;
        morpho = _morpho;
        curve = _curve;
        curveLp = _curveLp;
        oracle = _oracle;

        for (uint256 i = 1; i <= 5; i++) {
            address actor = address(uint160(i * 1000));
            actors.push(actor);
            usdc.mint(actor, 1_000_000e6);
            vm.prank(actor);
            usdc.approve(address(_ic), type(uint256).max);
        }
    }

    function deposit(
        uint256 actorSeed,
        uint256 amount
    ) external useActor(actorSeed) {
        amount = bound(amount, 1e6, 100_000e6);
        if (ic.paused()) {
            return;
        }
        if (usdc.balanceOf(currentActor) < amount) {
            return;
        }

        try ic.deposit(amount, currentActor) returns (uint256 minted) {
            ghost_totalDeposited += amount;
            ghost_totalInvarMinted += minted;
            depositCalls++;
        } catch (bytes memory reason) {
            bytes4[] memory allowed = new bytes4[](2);
            allowed[0] = ERR_ZERO_AMOUNT;
            allowed[1] = ERR_STALE_PRICE;
            _assertExpectedError(reason, allowed);
        }
    }

    function withdraw(
        uint256 actorSeed,
        uint256 amount,
        uint256 slippageSeed
    ) external useActor(actorSeed) {
        uint256 balance = ic.balanceOf(currentActor);
        if (balance == 0) {
            return;
        }
        amount = bound(amount, 1, balance);

        uint256 minOut = 0;
        if (slippageSeed % 3 == 1) {
            uint256 assets = ic.totalAssets();
            uint256 supply = ic.totalSupply();
            if (supply > 0) {
                uint256 expectedOut = (amount * assets) / supply;
                minOut = (expectedOut * 95) / 100;
            }
        }

        try ic.withdraw(amount, currentActor, minOut) returns (uint256 usdcOut) {
            ghost_totalWithdrawn += usdcOut;
            ghost_totalInvarBurned += amount;
            withdrawCalls++;
        } catch (bytes memory reason) {
            bytes4[] memory allowed = new bytes4[](4);
            allowed[0] = ERR_ZERO_AMOUNT;
            allowed[1] = ERR_SLIPPAGE;
            allowed[2] = ERR_INSUFFICIENT_BUFFER;
            allowed[3] = ERR_STALE_PRICE;
            _assertExpectedError(reason, allowed);
        }
    }

    function lpWithdraw(
        uint256 actorSeed,
        uint256 amount,
        uint256 slippageSeed
    ) external useActor(actorSeed) {
        uint256 balance = ic.balanceOf(currentActor);
        if (balance == 0) {
            return;
        }
        amount = bound(amount, 1, balance);

        uint256 minUsdc = 0;
        uint256 minBear = 0;
        if (slippageSeed % 3 == 1) {
            uint256 assets = ic.totalAssets();
            uint256 supply = ic.totalSupply();
            if (supply > 0) {
                uint256 proRataValue = (amount * assets) / supply;
                minUsdc = (proRataValue * 90) / 100;
            }
        }

        try ic.lpWithdraw(amount, minUsdc, minBear) {
            ghost_totalInvarBurned += amount;
            lpWithdrawCalls++;
        } catch (bytes memory reason) {
            bytes4[] memory allowed = new bytes4[](2);
            allowed[0] = ERR_ZERO_AMOUNT;
            allowed[1] = ERR_SLIPPAGE;
            _assertExpectedError(reason, allowed);
        }
    }

    function deployToCurve() external {
        if (ic.paused()) {
            return;
        }

        try ic.deployToCurve(0) {
            deployToCurveCalls++;
        } catch (bytes memory reason) {
            bytes4[] memory allowed = new bytes4[](1);
            allowed[0] = ERR_NOTHING_TO_DEPLOY;
            _assertExpectedError(reason, allowed);
        }
    }

    function replenishBuffer(
        uint256 lpAmount
    ) external {
        uint256 lpBal = curveLp.balanceOf(address(ic));
        if (lpBal == 0) {
            return;
        }
        lpAmount = bound(lpAmount, 1, lpBal);

        ic.replenishBuffer(lpAmount, 0);
        replenishBufferCalls++;
    }

    function harvest() external {
        if (ic.paused()) {
            return;
        }

        uint256 supplyBefore = ic.totalSupply();
        try ic.harvest() {
            uint256 supplyAfter = ic.totalSupply();
            ghost_totalInvarMinted += supplyAfter - supplyBefore;
            harvestCalls++;
        } catch (bytes memory reason) {
            bytes4[] memory allowed = new bytes4[](2);
            allowed[0] = ERR_NO_YIELD;
            allowed[1] = InvarCoin.InvarCoin__ZeroAddress.selector;
            _assertExpectedError(reason, allowed);
        }
    }

    function simulateYield(
        uint256 amount
    ) external {
        uint256 morphoShares = morpho.balanceOf(address(ic));
        if (morphoShares == 0) {
            return;
        }

        uint256 currentAssets = morpho.convertToAssets(morphoShares);
        uint256 maxYield = currentAssets / 10;
        if (maxYield == 0) {
            return;
        }

        amount = bound(amount, 1e4, maxYield);
        morpho.simulateYield(amount);
        ghost_totalYieldSimulated += amount;
        simulateYieldCalls++;
    }

    function simulateCurveYield(
        uint256 bpsDelta
    ) external {
        uint256 currentVp = curve.virtualPrice();
        bpsDelta = bound(bpsDelta, 1, 50);
        uint256 newVp = currentVp + (currentVp * bpsDelta) / 10_000;
        curve.setVirtualPrice(newVp);
        simulateCurveYieldCalls++;
    }

    function sendUsdcDust(
        uint256 amount
    ) external {
        amount = bound(amount, 1, 1000e6);
        usdc.mint(address(ic), amount);
        ghost_totalDustSent += amount;
        sendUsdcDustCalls++;
    }

    function lpDeposit(
        uint256 actorSeed,
        uint256 usdcAmount,
        uint256 bearAmount
    ) external useActor(actorSeed) {
        if (ic.paused()) {
            return;
        }
        usdcAmount = bound(usdcAmount, 0, 50_000e6);
        bearAmount = bound(bearAmount, 0, 50_000e18);
        if (usdcAmount == 0 && bearAmount == 0) {
            usdcAmount = 1e6;
        }

        if (usdcAmount > 0) {
            usdc.mint(currentActor, usdcAmount);
        }
        if (bearAmount > 0) {
            bear.mint(currentActor, bearAmount);
            bear.approve(address(ic), bearAmount);
        }

        try ic.lpDeposit(usdcAmount, bearAmount, currentActor, 0) returns (uint256 minted) {
            ghost_totalDeposited += usdcAmount + bearAmount / 1e12;
            ghost_totalInvarMinted += minted;
            lpDepositCalls++;
        } catch (bytes memory reason) {
            bytes4[] memory allowed = new bytes4[](2);
            allowed[0] = ERR_ZERO_AMOUNT;
            allowed[1] = ERR_STALE_PRICE;
            _assertExpectedError(reason, allowed);
        }
    }

}

contract InvarCoinInvariantTest is StdInvariant, Test {

    InvarCoin ic;
    StakedToken sInvar;
    MockUSDC6 usdc;
    MockBEAR bear;
    MockMorphoVault morpho;
    MockCurvePool curve;
    MockCurveLpToken curveLp;
    MockOracle oracle;
    InvarCoinHandler handler;

    function setUp() public {
        vm.warp(100_000);

        usdc = new MockUSDC6();
        oracle = new MockOracle(int256(80_000_000), "plDXY Basket");
        bear = new MockBEAR();
        curveLp = new MockCurveLpToken();
        curve = new MockCurvePool(address(usdc), address(bear), address(curveLp));
        morpho = new MockMorphoVault(IERC20(address(usdc)));

        ic = new InvarCoin(
            address(usdc), address(bear), address(curveLp), address(morpho), address(curve), address(oracle), address(0)
        );

        sInvar = new StakedToken(IERC20(address(ic)), "Staked InvarCoin", "sINVAR");
        ic.setStakedInvarCoin(address(sInvar));

        curve.setSwapFeeBps(30);

        handler = new InvarCoinHandler(ic, sInvar, usdc, bear, morpho, curve, curveLp, oracle);

        targetContract(address(handler));
        vm.label(address(ic), "InvarCoin");
        vm.label(address(morpho), "MorphoVault");
        vm.label(address(handler), "Handler");
    }

    function invariant_Solvency() public view {
        if (ic.totalSupply() > 1e12) {
            assertGt(ic.totalAssets(), 0, "INVARIANT: Tokens exist without backing");
        }
    }

    /// @notice Withdrawal output must never exceed total assets (no value creation from thin air).
    /// Checked indirectly: ghost_totalWithdrawn should never exceed ghost_totalDeposited + yield.
    function invariant_NoValueCreation() public view {
        uint256 totalIn =
            handler.ghost_totalDeposited() + handler.ghost_totalYieldSimulated() + handler.ghost_totalDustSent();
        uint256 totalWithdrawn = handler.ghost_totalWithdrawn();
        uint256 tolerance = 1000 + (totalIn * 100) / 1e6;
        assertLe(totalWithdrawn, totalIn + tolerance, "INVARIANT: More withdrawn than total value in");
    }

    function invariant_GhostSupplyConsistency() public view {
        uint256 expected = handler.ghost_totalInvarMinted() - handler.ghost_totalInvarBurned();
        assertEq(ic.totalSupply(), expected, "INVARIANT: Ghost supply tracking mismatch");
    }

    function invariant_CallSummary() public view {
        console.log("=== InvarCoin Invariant Summary ===");
        console.log("Deposits:", handler.depositCalls());
        console.log("Withdraws:", handler.withdrawCalls());
        console.log("LpWithdraws:", handler.lpWithdrawCalls());
        console.log("DeployToCurve:", handler.deployToCurveCalls());
        console.log("ReplenishBuffer:", handler.replenishBufferCalls());
        console.log("Harvest:", handler.harvestCalls());
        console.log("SimulateYield:", handler.simulateYieldCalls());
        console.log("SimulateCurveYield:", handler.simulateCurveYieldCalls());
        console.log("SendUsdcDust:", handler.sendUsdcDustCalls());
        console.log("LpDeposit:", handler.lpDepositCalls());
        console.log("TotalSupply:", ic.totalSupply());
        console.log("TotalAssets:", ic.totalAssets());
        console.log("MorphoPrincipal:", ic.morphoPrincipal());
    }

}
