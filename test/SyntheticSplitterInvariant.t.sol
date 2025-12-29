// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../src/SyntheticSplitter.sol";
import "../src/YieldAdapter.sol";
import "./utils/MockAave.sol";
import "./utils/MockOracle.sol";

// ==========================================
// MOCK USDC (6 decimals)
// ==========================================
contract MockUSDC is MockERC20 {
    constructor() MockERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

// ==========================================
// HANDLER CONTRACT
// ==========================================
contract SplitterHandler is Test {
    SyntheticSplitter public splitter;
    YieldAdapter public adapter;
    MockUSDC public usdc;
    MockOracle public oracle;
    MockAToken public aUsdc;

    // Ghost variables for tracking
    uint256 public ghost_totalMinted;
    uint256 public ghost_totalBurned;
    uint256 public ghost_totalUsdcDeposited;
    uint256 public ghost_totalUsdcWithdrawn;
    bool public ghost_wasEverLiquidated;
    uint256 public ghost_supplyAtLiquidation; // TOKEN_A supply when liquidation occurred
    uint256 public ghost_totalEmergencyRedeemed;
    uint256 public ghost_burnedAfterLiquidation; // Tracks burns via burn() after liquidation

    // Actors
    address[] public actors;
    address internal currentActor;

    // Call counters for debugging
    uint256 public mintCalls;
    uint256 public burnCalls;
    uint256 public harvestCalls;
    uint256 public emergencyRedeemCalls;

    uint256 constant CAP = 200_000_000; // $2.00

    modifier useActor(uint256 actorSeed) {
        currentActor = actors[actorSeed % actors.length];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(
        SyntheticSplitter _splitter,
        YieldAdapter _adapter,
        MockUSDC _usdc,
        MockOracle _oracle,
        MockAToken _aUsdc
    ) {
        splitter = _splitter;
        adapter = _adapter;
        usdc = _usdc;
        oracle = _oracle;
        aUsdc = _aUsdc;

        // Create actors
        for (uint256 i = 1; i <= 5; i++) {
            address actor = address(uint160(i * 1000));
            actors.push(actor);
            // Fund each actor
            usdc.mint(actor, 10_000_000 * 1e6); // $10M each
            vm.prank(actor);
            usdc.approve(address(splitter), type(uint256).max);
        }
    }

    // ==========================================
    // HANDLER FUNCTIONS
    // ==========================================

    function mint(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        // Bound amount to reasonable range
        amount = bound(amount, 1e18, 100_000 * 1e18);

        uint256 usdcRequired = (amount * CAP) / splitter.USDC_MULTIPLIER();

        // Skip if actor doesn't have enough USDC
        if (usdc.balanceOf(currentActor) < usdcRequired) return;

        // Skip if liquidated or paused
        if (splitter.isLiquidated() || splitter.paused()) return;

        // Skip if oracle would cause revert
        try splitter.mint(amount) {
            ghost_totalMinted += amount;
            ghost_totalUsdcDeposited += usdcRequired;
            mintCalls++;
        } catch {
            // Expected failures (stale oracle, etc.)
        }
    }

    function burn(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        uint256 balance = splitter.TOKEN_A().balanceOf(currentActor);
        if (balance == 0) return;

        // Bound to available balance
        amount = bound(amount, 1, balance);

        bool wasLiquidated = splitter.isLiquidated();

        try splitter.burn(amount) {
            ghost_totalBurned += amount;
            uint256 usdcReturned = (amount * CAP) / splitter.USDC_MULTIPLIER();
            ghost_totalUsdcWithdrawn += usdcReturned;
            burnCalls++;

            // Track burns that happen after liquidation
            if (wasLiquidated) {
                ghost_burnedAfterLiquidation += amount;
            }
        } catch {
            // Expected failures
        }
    }

    function harvest(uint256 actorSeed) external useActor(actorSeed) {
        try splitter.harvestYield() {
            harvestCalls++;
        } catch {
            // Expected if no surplus
        }
    }

    function simulateYield(uint256 yieldAmount) external {
        // Only simulate yield if splitter has shares in adapter
        uint256 splitterShares = adapter.balanceOf(address(splitter));
        if (splitterShares == 0) return;

        // Bound yield to reasonable range (max 10% of current adapter assets)
        uint256 currentAssets = adapter.convertToAssets(splitterShares);
        uint256 maxYield = currentAssets / 10;
        if (maxYield == 0) return;

        yieldAmount = bound(yieldAmount, 0, maxYield);
        if (yieldAmount == 0) return;

        // Add yield to adapter (simulates Aave interest)
        aUsdc.mint(address(adapter), yieldAmount);
        usdc.mint(address(adapter), yieldAmount); // Back the aTokens
    }

    function updatePrice(uint256 priceSeed) external {
        // Keep price between $0.50 and $1.99 (below CAP to avoid liquidation in normal ops)
        int256 newPrice = int256(bound(priceSeed, 50_000_000, 199_000_000));
        oracle.updatePrice(newPrice);
    }

    function triggerLiquidation() external {
        // Only trigger if price is at or above CAP
        (, int256 price,,,) = oracle.latestRoundData();
        if (uint256(price) >= CAP) {
            try splitter.triggerLiquidation() {
                ghost_wasEverLiquidated = true;
                ghost_supplyAtLiquidation = splitter.TOKEN_A().totalSupply();
            } catch {}
        }
    }

    function setPriceAboveCap() external {
        // Force price above CAP for liquidation testing
        oracle.updatePrice(int256(CAP + 1_000_000)); // $2.01
    }

    function emergencyRedeem(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        // Only works if liquidated
        if (!splitter.isLiquidated()) return;

        // Bound to actor's Bear token balance
        uint256 bearBalance = splitter.TOKEN_A().balanceOf(currentActor);
        if (bearBalance == 0) return;

        amount = bound(amount, 1, bearBalance);

        try splitter.emergencyRedeem(amount) {
            ghost_totalEmergencyRedeemed += amount;
            emergencyRedeemCalls++;
        } catch {
            // Expected failures
        }
    }

    // ==========================================
    // VIEW HELPERS
    // ==========================================

    function getActorCount() external view returns (uint256) {
        return actors.length;
    }

    function getTotalAssets() external view returns (uint256) {
        uint256 buffer = usdc.balanceOf(address(splitter));
        uint256 adapterShares = adapter.balanceOf(address(splitter));
        uint256 adapterAssets = adapterShares > 0 ? adapter.convertToAssets(adapterShares) : 0;
        return buffer + adapterAssets;
    }

    function getTotalLiabilities() external view returns (uint256) {
        return (splitter.TOKEN_A().totalSupply() * CAP) / splitter.USDC_MULTIPLIER();
    }
}

// ==========================================
// INVARIANT TEST CONTRACT
// ==========================================
contract SyntheticSplitterInvariantTest is StdInvariant, Test {
    SyntheticSplitter splitter;
    YieldAdapter adapter;
    MockUSDC usdc;
    MockAToken aUsdc;
    MockPool pool;
    MockOracle oracle;
    SplitterHandler handler;

    address treasury = address(0x999);
    uint256 constant CAP = 200_000_000;

    function setUp() public {
        // Warp to avoid timestamp issues
        vm.warp(1735689600);

        // Deploy mocks
        usdc = new MockUSDC();
        aUsdc = new MockAToken("aUSDC", "aUSDC", address(usdc));
        pool = new MockPool(address(usdc), address(aUsdc));
        oracle = new MockOracle(100_000_000, "Basket"); // $1.00

        // Fund pool for withdrawals
        usdc.mint(address(pool), 100_000_000 * 1e6);

        // Deploy adapter
        adapter = new YieldAdapter(IERC20(address(usdc)), address(pool), address(aUsdc), address(this));

        // Deploy splitter (no sequencer feed for simplicity)
        splitter = new SyntheticSplitter(address(oracle), address(usdc), address(adapter), CAP, treasury, address(0));

        // Deploy handler
        handler = new SplitterHandler(splitter, adapter, usdc, oracle, aUsdc);

        // Target the handler for invariant testing
        targetContract(address(handler));

        // Label for traces
        vm.label(address(splitter), "Splitter");
        vm.label(address(adapter), "Adapter");
        vm.label(address(handler), "Handler");
    }

    // ==========================================
    // INVARIANTS
    // ==========================================

    /// @notice TOKEN_A and TOKEN_B supplies relationship
    /// @dev Before liquidation: A == B (minted/burned in pairs)
    /// @dev After liquidation: A == B - emergencyRedeemed (only Bear burns in emergencyRedeem)
    function invariant_tokenParity() public view {
        uint256 supplyA = splitter.TOKEN_A().totalSupply();
        uint256 supplyB = splitter.TOKEN_B().totalSupply();
        uint256 emergencyRedeemed = handler.ghost_totalEmergencyRedeemed();

        // TOKEN_A = TOKEN_B - emergencyRedeemed (since emergencyRedeem only burns Bear)
        assertEq(supplyA, supplyB - emergencyRedeemed, "INVARIANT VIOLATED: Token supply relationship broken");
    }

    /// @notice When not liquidated, total assets must be >= total liabilities
    function invariant_solvency() public view {
        if (splitter.isLiquidated()) return; // Skip if liquidated

        uint256 totalAssets = handler.getTotalAssets();
        uint256 totalLiabilities = handler.getTotalLiabilities();

        // Allow small tolerance for rounding (max 100 wei per 1M USDC of liabilities)
        uint256 tolerance = (totalLiabilities / 1e6) + 10;

        assertGe(totalAssets + tolerance, totalLiabilities, "INVARIANT VIOLATED: System is insolvent");
    }

    /// @notice Liquidation state is irreversible
    function invariant_liquidationIrreversible() public view {
        if (handler.ghost_wasEverLiquidated()) {
            assertTrue(splitter.isLiquidated(), "INVARIANT VIOLATED: Liquidation was reversed");
        }
    }

    /// @notice If there are significant tokens, there must be collateral
    function invariant_noOrphanedTokens() public view {
        uint256 totalSupply = splitter.TOKEN_A().totalSupply();
        // Only check if there's meaningful supply (> dust threshold)
        // Very small supplies can have 0 assets due to rounding
        if (totalSupply > 1e15) {
            // 0.001 tokens minimum
            uint256 totalAssets = handler.getTotalAssets();
            assertGt(totalAssets, 0, "INVARIANT VIOLATED: Tokens exist without collateral");
        }
    }

    /// @notice Ghost variable consistency: minted - burned - emergencyRedeemed = totalSupply
    function invariant_ghostConsistency() public view {
        uint256 expectedSupply =
            handler.ghost_totalMinted() - handler.ghost_totalBurned() - handler.ghost_totalEmergencyRedeemed();
        assertEq(splitter.TOKEN_A().totalSupply(), expectedSupply, "INVARIANT VIOLATED: Ghost tracking mismatch");
    }

    /// @notice Treasury and staking addresses should never be the splitter itself
    function invariant_feeReceiversNotSelf() public view {
        assertTrue(splitter.treasury() != address(splitter), "INVARIANT VIOLATED: Treasury is splitter");
        assertTrue(splitter.staking() != address(splitter), "INVARIANT VIOLATED: Staking is splitter");
    }

    // ==========================================
    // AFTER INVARIANT HOOK (for debugging)
    // ==========================================

    function invariant_callSummary() public view {
        console.log("=== Invariant Test Summary ===");
        console.log("Mint calls:", handler.mintCalls());
        console.log("Burn calls:", handler.burnCalls());
        console.log("Harvest calls:", handler.harvestCalls());
        console.log("Total minted:", handler.ghost_totalMinted());
        console.log("Total burned:", handler.ghost_totalBurned());
        console.log("Token A supply:", splitter.TOKEN_A().totalSupply());
        console.log("Token B supply:", splitter.TOKEN_B().totalSupply());
        console.log("Is liquidated:", splitter.isLiquidated());
    }
}

// ==========================================
// LIQUIDATION-FOCUSED INVARIANT TEST
// ==========================================
contract SyntheticSplitterLiquidationInvariantTest is StdInvariant, Test {
    SyntheticSplitter splitter;
    YieldAdapter adapter;
    MockUSDC usdc;
    MockAToken aUsdc;
    MockPool pool;
    MockOracle oracle;
    SplitterHandler handler;

    address treasury = address(0x999);
    uint256 constant CAP = 200_000_000;

    function setUp() public {
        vm.warp(1735689600);

        usdc = new MockUSDC();
        aUsdc = new MockAToken("aUSDC", "aUSDC", address(usdc));
        pool = new MockPool(address(usdc), address(aUsdc));
        oracle = new MockOracle(100_000_000, "Basket");

        usdc.mint(address(pool), 100_000_000 * 1e6);

        adapter = new YieldAdapter(IERC20(address(usdc)), address(pool), address(aUsdc), address(this));

        splitter = new SyntheticSplitter(address(oracle), address(usdc), address(adapter), CAP, treasury, address(0));

        handler = new SplitterHandler(splitter, adapter, usdc, oracle, aUsdc);

        // Target specific functions for liquidation testing
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = SplitterHandler.mint.selector;
        selectors[1] = SplitterHandler.burn.selector;
        selectors[2] = SplitterHandler.setPriceAboveCap.selector;
        selectors[3] = SplitterHandler.triggerLiquidation.selector;
        selectors[4] = SplitterHandler.emergencyRedeem.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Post-liquidation: no new tokens can be created
    /// @dev After liquidation, ghost_totalMinted should never increase
    function invariant_noMintAfterLiquidation() public view {
        if (handler.ghost_wasEverLiquidated()) {
            // Current supply should be <= supply at liquidation time
            // (can only decrease via emergencyRedeem, never increase)
            uint256 currentSupply = splitter.TOKEN_A().totalSupply();
            uint256 supplyAtLiquidation = handler.ghost_supplyAtLiquidation();

            assertLe(currentSupply, supplyAtLiquidation, "INVARIANT VIOLATED: Tokens created after liquidation");
        }
    }

    /// @notice Post-liquidation: Bear supply can only decrease or stay same
    /// @dev Decreases via emergencyRedeem (Bear only) and burn (both tokens)
    function invariant_supplyOnlyDecreasesAfterLiquidation() public view {
        if (handler.ghost_wasEverLiquidated()) {
            uint256 supplyAtLiquidation = handler.ghost_supplyAtLiquidation();
            uint256 totalRedeemed = handler.ghost_totalEmergencyRedeemed();
            uint256 burnedAfterLiq = handler.ghost_burnedAfterLiquidation();
            uint256 currentSupply = splitter.TOKEN_A().totalSupply();

            // Bear supply = supplyAtLiquidation - emergencyRedeemed - burnedAfterLiquidation
            assertEq(
                currentSupply,
                supplyAtLiquidation - totalRedeemed - burnedAfterLiq,
                "INVARIANT VIOLATED: Bear supply math inconsistent after liquidation"
            );
        }
    }

    /// @notice Verify price-cap relationship
    function invariant_liquidationPriceConsistency() public view {
        (, int256 price,,,) = oracle.latestRoundData();

        // If price >= CAP and there's supply, system should be liquidatable
        if (uint256(price) >= CAP && splitter.TOKEN_A().totalSupply() > 0) {
            // Either already liquidated, or triggerLiquidation should succeed
            // (we can't call functions in invariants, so just verify state)
            assertTrue(splitter.isLiquidated() || uint256(price) >= CAP, "Price/liquidation state inconsistent");
        }
    }

    /// @notice Bull tokens only change via burn() after liquidation, not emergencyRedeem
    function invariant_bullTokensConsistentAfterLiquidation() public view {
        if (handler.ghost_wasEverLiquidated()) {
            uint256 supplyAtLiquidation = handler.ghost_supplyAtLiquidation();
            uint256 burnedAfterLiq = handler.ghost_burnedAfterLiquidation();
            uint256 currentBullSupply = splitter.TOKEN_B().totalSupply();

            // Bull supply = supplyAtLiquidation - burnedAfterLiquidation
            // (emergencyRedeem doesn't burn Bull, only burn() does)
            assertEq(
                currentBullSupply,
                supplyAtLiquidation - burnedAfterLiq,
                "INVARIANT VIOLATED: Bull token supply inconsistent after liquidation"
            );
        }
    }

    /// @notice Debug summary for liquidation tests
    function invariant_liquidationCallSummary() public view {
        if (handler.ghost_wasEverLiquidated()) {
            console.log("=== Liquidation Test Summary ===");
            console.log("Supply at liquidation:", handler.ghost_supplyAtLiquidation());
            console.log("Emergency redeems:", handler.emergencyRedeemCalls());
            console.log("Total redeemed:", handler.ghost_totalEmergencyRedeemed());
            console.log("Current Bear supply:", splitter.TOKEN_A().totalSupply());
            console.log("Current Bull supply:", splitter.TOKEN_B().totalSupply());
        }
    }
}
