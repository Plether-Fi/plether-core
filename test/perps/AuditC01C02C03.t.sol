// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdMath} from "../../src/perps/CfdMath.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockUSDC is ERC20 {

    constructor() ERC20("Mock USDC", "USDC") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

contract AuditC01C02C03Test is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;

    uint256 constant CAP_PRICE = 2e8;

    function setUp() public {
        usdc = new MockUSDC();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.5e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "juniorUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        engine.setOrderRouter(address(this));

        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        clearinghouse.proposeWithdrawGuard(address(engine));
        vm.warp(48 hours + 2);
        clearinghouse.finalizeAssetConfig();
        clearinghouse.finalizeWithdrawGuard();

        clearinghouse.proposeOperator(address(engine), true);
        vm.warp(96 hours + 3);
        clearinghouse.finalizeOperator();

        vm.warp(1_709_532_000);

        usdc.mint(address(this), 10_000_000 * 1e6);
        usdc.approve(address(juniorVault), type(uint256).max);
        juniorVault.deposit(5_000_000 * 1e6, address(this));
    }

    function _deposit(
        bytes32 accountId,
        uint256 amount
    ) internal {
        address user = address(uint160(uint256(accountId)));
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, address(usdc), amount);
        vm.stopPrank();
    }

    function _open(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 depth
    ) internal {
        engine.processOrder(
            CfdTypes.Order({
                accountId: accountId,
                sizeDelta: size,
                marginDelta: margin,
                targetPrice: price,
                commitTime: uint64(block.timestamp),
                orderId: 0,
                side: side,
                isClose: false
            }),
            price,
            depth
        );
    }

    function _close(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 size,
        uint256 price,
        uint256 depth
    ) internal {
        engine.processOrder(
            CfdTypes.Order({
                accountId: accountId,
                sizeDelta: size,
                marginDelta: 0,
                targetPrice: 0,
                commitTime: uint64(block.timestamp),
                orderId: 0,
                side: side,
                isClose: true
            }),
            price,
            depth
        );
    }

    // ==========================================
    // C-01: Precision loss bypass — stale funding index via partial close to 1 wei
    // ==========================================
    // Attack: open min-size → partial close to 1 wei → funding truncates to 0
    //         so entryFundingIndex never updates → add massive size at stale index
    //         → close and extract months of backdated funding
    function test_C01_StaleFundingIndex_PartialCloseTo1Wei() public {
        uint256 depth = 5_000_000 * 1e6;

        bytes32 attackerId = bytes32(uint256(uint160(address(0xA1))));
        _deposit(attackerId, 500_000 * 1e6);

        // Counterparty to create skew (BEAR side so BULL pays funding)
        bytes32 counterId = bytes32(uint256(uint160(address(0xB1))));
        _deposit(counterId, 500_000 * 1e6);
        _open(counterId, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8, depth);

        // Step 1: Attacker opens minimum-size BULL position (~$3,333 notional at $1)
        uint256 minNotional = (uint256(5) * 1e6 * 10_000) / 15 + 1e6;
        uint256 minSize = (minNotional * 1e20) / 1e8;
        _open(attackerId, CfdTypes.Side.BULL, minSize, 50_000 * 1e6, 1e8, depth);

        // Step 2: Partial close to 1 wei
        uint256 closeSize = minSize - 1;
        _close(attackerId, CfdTypes.Side.BULL, closeSize, 1e8, depth);

        (uint256 sizeAfterClose,,,, int256 entryFundingBefore,,,) = engine.positions(attackerId);
        assertEq(sizeAfterClose, 1, "Position reduced to 1 wei");

        // Step 3: Wait 90 days — funding accumulates but getPendingFunding(1 wei) truncates to 0
        vm.warp(block.timestamp + 90 days);

        int256 bullIdx = engine.bullFundingIndex();
        int256 indexDelta = bullIdx - entryFundingBefore;
        int256 pendingWith1Wei = (int256(uint256(1)) * indexDelta) / int256(CfdMath.FUNDING_INDEX_SCALE);
        assertEq(pendingWith1Wei, 0, "Funding truncates to 0 for 1 wei position");

        // Step 4: Add massive size — should use CURRENT funding index, not stale one
        _open(attackerId, CfdTypes.Side.BULL, 1_000_000 * 1e18, 200_000 * 1e6, 1e8, depth);

        (,,,, int256 entryFundingAfter,,,) = engine.positions(attackerId);

        // THE BUG: entryFundingIndex was never updated (pendingFunding == 0 skipped the block)
        // so _processIncrease uses the stale index for globalBullEntryFunding
        // If the fix is in place, entryFundingAfter == current bullFundingIndex
        int256 currentBullIndex = engine.bullFundingIndex();
        assertEq(
            entryFundingAfter, currentBullIndex, "C-01: entryFundingIndex must be current after increase, not stale"
        );

        // Step 5: Verify no profit extraction — close immediately should yield ~0 funding
        uint256 chBefore = clearinghouse.balances(attackerId, address(usdc));
        _close(attackerId, CfdTypes.Side.BULL, 1_000_000 * 1e18 + 1, 1e8, depth);
        uint256 chAfter = clearinghouse.balances(attackerId, address(usdc));

        // Attacker should NOT have extracted significant funding gains
        // Any profit beyond margin return + small rounding is exploit proceeds
        uint256 totalDeposited = 500_000 * 1e6;
        assertLe(chAfter, totalDeposited, "C-01: Attacker must not profit from stale funding index");
    }

    // ==========================================
    // C-02: Per-side MtM cap creates phantom profit with isolated margins
    // ==========================================
    // Two BULL positions: A is profitable ($1k PnL, $500 margin),
    // B is deeply underwater (-$3k PnL, $200 margin → $2.8k bad debt).
    // Reality: vault owes A $1k, can seize $200 from B → net liability $800.
    // Bug: aggregate bullPnl = -$2k, capped at -$700 → vault sees $700 asset not $800 liability.
    function test_C02_PerSideMtmCap_PhantomProfit() public {
        uint256 depth = 5_000_000 * 1e6;

        // Position A: BULL, profitable
        bytes32 aliceId = bytes32(uint256(uint160(address(0xA2))));
        _deposit(aliceId, 100_000 * 1e6);
        // Open BULL 50k tokens at $1.20 with $500 margin
        _open(aliceId, CfdTypes.Side.BULL, 50_000 * 1e18, 5000 * 1e6, 1.2e8, depth);

        // Position B: BULL, will be deeply underwater
        bytes32 bobId = bytes32(uint256(uint160(address(0xB2))));
        _deposit(bobId, 100_000 * 1e6);
        // Open BULL 100k tokens at $0.80 with small margin ($200)
        _open(bobId, CfdTypes.Side.BULL, 100_000 * 1e18, 5000 * 1e6, 0.8e8, depth);

        // Price moves to $1.10:
        // A (entered $1.20, BULL profits when price drops): pnl = (1.20-1.10)*50k/1e20 = $5k profit
        // B (entered $0.80, BULL profits when price drops): pnl = (0.80-1.10)*100k/1e20 = -$30k loss
        engine.updateMarkPrice(1.1e8);

        int256 mtm = engine.getVaultMtmAdjustment();

        // True per-position accounting:
        // A: +$5,000 PnL (vault owes this)
        // B: -$30,000 PnL but only $5,000 margin seizable → bad debt = $25,000
        // Net vault obligation = $5,000 (owe A) - $5,000 (seize B's margin) = $0 net,
        // but $25k bad debt is socialized

        // The per-side cap should NOT produce a positive value (vault asset)
        // when the vault actually has a net liability to profitable positions
        uint256 totalBullMargin = engine.totalBullMargin();

        // With the bug: aggregate PnL + funding is capped at -totalBullMargin,
        // which nets the bad debt against profitable positions.
        // A profitable position's claim is a REAL liability that can't be offset
        // by another position's bad debt (isolated margin).

        // If position A has real profit and the vault caps the whole side,
        // the mtm should still reflect that A's profit is a real liability
        // Per-position: mtm = sum(max(pnl_i, -margin_i)) for each position
        // Per-side (buggy): mtm = max(sum(pnl_i), -sum(margin_i))

        // With the fix, per-side MtM is clamped at 0: the vault never counts
        // unrealized trader losses as assets through MtM. Clamping is conservative
        // (may undercount obligations) but eliminates phantom profits entirely.
        // Solvency checks use separate paths (_getCappedFundingPnl, _getEffectiveAssets).
        assertGe(
            mtm,
            int256(0),
            "C-02: Per-side cap must not create phantom profit by netting bad debt against profitable positions"
        );
    }

    // ==========================================
    // C-03: Unrealized MtM profits distributed as withdrawable cash
    // ==========================================
    // When traders are losing (mtm < 0), _reconcile adds paper profits to distributable.
    // Junior LPs withdraw real USDC. If market reverses, paper profits vanish but cash is gone.
    function test_C03_UnrealizedGains_DistributedAsWithdrawableCash() public {
        uint256 depth = 5_000_000 * 1e6;

        bytes32 traderId = bytes32(uint256(uint160(address(0x2222))));
        _deposit(traderId, 500_000 * 1e6);
        _open(traderId, CfdTypes.Side.BULL, 2_000_000 * 1e18, 200_000 * 1e6, 1e8, depth);

        // Record junior principal BEFORE any MtM movement
        uint256 juniorBefore = pool.juniorPrincipal();

        // Price rises to $1.50: BULL losing -> vault has paper profit
        engine.updateMarkPrice(1.5e8);

        assertGe(engine.getVaultMtmAdjustment(), 0, "Fix: MtM clamped at 0, vault never sees paper profit");

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 juniorAfter = pool.juniorPrincipal();

        // THE BUG: distributable = cashMinusFees + uint256(-mtm)
        // Paper MtM profits should NOT inflate LP principal.
        // They're unrealized — the losing trader hasn't been liquidated yet,
        // and the market can reverse at any time.
        assertLe(
            juniorAfter,
            juniorBefore,
            "C-03: Junior principal must not increase from unrealized trader losses (paper MtM)"
        );
    }

}
