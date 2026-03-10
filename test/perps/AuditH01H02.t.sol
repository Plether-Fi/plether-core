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

contract MockUSDC6 is ERC20 {

    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

contract MockWBTC is ERC20 {

    constructor() ERC20("Wrapped BTC", "WBTC") {}

    function decimals() public pure override returns (uint8) {
        return 8;
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

}

contract AuditH01H02Test is Test {

    MockUSDC6 usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;

    uint256 constant CAP_PRICE = 2e8;
    uint256 constant DEPTH = 5_000_000 * 1e6;

    function setUp() public {
        usdc = new MockUSDC6();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0.001e18,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
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
    // H-01: Linear VPI chunking on quadratic curve
    // ==========================================

    // H-01 sub-issue 1: MM rebate destruction by bidirectional clamp.
    //
    // DESIGN TRADEOFF (WON'T FIX): The bidirectional clamp
    // (proportionalAccrual + vpiUsdc >= 0) prevents the C02a depth-change attack
    // ($15/round-trip, infinitely repeatable via LP sandwich). Removing it to allow
    // MM rebate retention enables that attack, which is strictly worse.
    //
    // This test documents the tradeoff: an MM who heals skew on both open and close
    // nets $0 VPI. The MM earns rebate on open, but the clamp forces an equal charge
    // on close. MMs must earn spread through price movement, not VPI rebates.
    function test_H01_MM_RebateZeroed_DesignTradeoff() public {
        bytes32 bearSkewerId = bytes32(uint256(uint160(address(0x51))));
        _deposit(bearSkewerId, 500_000 * 1e6);
        _open(bearSkewerId, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        bytes32 mmId = bytes32(uint256(uint160(address(0x111))));
        _deposit(mmId, 500_000 * 1e6);
        _open(mmId, CfdTypes.Side.BULL, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        (,,,,,,, int256 vpiAfterOpen) = engine.positions(mmId);
        assertLt(vpiAfterOpen, 0, "MM earned VPI rebate on open (healed skew)");

        bytes32 bullFlipperId = bytes32(uint256(uint160(address(0x52))));
        _deposit(bullFlipperId, 500_000 * 1e6);
        _open(bullFlipperId, CfdTypes.Side.BULL, 1_000_000 * 1e18, 100_000 * 1e6, 1e8, DEPTH);

        (uint256 mmSize,,,,,,,) = engine.positions(mmId);
        _close(mmId, CfdTypes.Side.BULL, mmSize, 1e8, DEPTH);
        uint256 mmUsdcAfter = clearinghouse.balances(mmId, address(usdc));

        uint256 totalDeposited = 500_000 * 1e6;
        uint256 approxExecFees = (500_000 * 1e6 * 6 / 10_000) * 2;
        uint256 breakeven = totalDeposited - approxExecFees;

        // MM nets exactly breakeven (open rebate cancelled by forced close charge)
        assertEq(
            mmUsdcAfter,
            breakeven,
            "H-01 tradeoff: MM nets $0 VPI (open rebate clawed back on close to prevent depth attack)"
        );
    }

    // H-01 sub-issue 2: Linear proportional VPI chunking on quadratic curve.
    //
    // DESIGN TRADEOFF (ACCEPTED): The proportional clamp linearly allocates VPI
    // across partial closes, which doesn't match the quadratic cost curve.
    // Closing in 2 chunks costs ~$4 more than closing all at once ($4 on $400k
    // notional = 0.001%). This is an acceptable approximation to prevent
    // the C02a depth-change attack.
    function test_H01_PartialClose_LinearChunking_BoundedError() public {
        bytes32 skewerId = bytes32(uint256(uint160(address(0x52))));
        _deposit(skewerId, 500_000 * 1e6);
        _open(skewerId, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        bytes32 aliceId = bytes32(uint256(uint160(address(0xA1))));
        _deposit(aliceId, 500_000 * 1e6);
        _open(aliceId, CfdTypes.Side.BULL, 400_000 * 1e18, 100_000 * 1e6, 1e8, DEPTH);

        uint256 aliceBefore = clearinghouse.balances(aliceId, address(usdc));
        _close(aliceId, CfdTypes.Side.BULL, 400_000 * 1e18, 1e8, DEPTH);
        uint256 aliceAfter = clearinghouse.balances(aliceId, address(usdc));
        int256 aliceNet = int256(aliceAfter) - int256(aliceBefore);

        _close(skewerId, CfdTypes.Side.BEAR, 500_000 * 1e18, 1e8, DEPTH);
        _open(skewerId, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        bytes32 bobId = bytes32(uint256(uint160(address(0xB1))));
        _deposit(bobId, 500_000 * 1e6);
        _open(bobId, CfdTypes.Side.BULL, 400_000 * 1e18, 100_000 * 1e6, 1e8, DEPTH);

        uint256 bobBefore = clearinghouse.balances(bobId, address(usdc));
        _close(bobId, CfdTypes.Side.BULL, 200_000 * 1e18, 1e8, DEPTH);
        _close(bobId, CfdTypes.Side.BULL, 200_000 * 1e18, 1e8, DEPTH);
        uint256 bobAfter = clearinghouse.balances(bobId, address(usdc));
        int256 bobNet = int256(bobAfter) - int256(bobBefore);

        // Linear chunking introduces a small error vs the quadratic ideal.
        // The error is bounded: at most ~$4 per 2-chunk close on $400k notional (0.001%).
        int256 diff = aliceNet > bobNet ? aliceNet - bobNet : bobNet - aliceNet;
        uint256 tolerance = 5 * 1e6; // $5 tolerance for 2-chunk linear approximation

        assertLe(uint256(diff), tolerance, "H-01: Linear chunking error must stay within bounded tolerance");
    }

    // ==========================================
    // H-02: Non-USDC collateral enables risk-free trading
    // ==========================================

    // Attacker deposits small USDC + large WBTC. WBTC inflates buying power
    // allowing a position far larger than USDC alone could support.
    // Without the fix, lockMargin checks only aggregate equity and accepts this.
    // With the fix, lockMargin requires USDC >= total locked amount, blocking the attack.
    function test_H02_NonUsdcCollateral_LockMarginBlocksOverleveragedPosition() public {
        MockWBTC wbtc = new MockWBTC();
        MockOracle wbtcOracle = new MockOracle(60_000 * 1e8);

        clearinghouse.proposeAssetConfig(address(wbtc), 8, 8000, address(wbtcOracle));
        vm.warp(block.timestamp + 48 hours + 1);
        clearinghouse.finalizeAssetConfig();

        address attacker = address(0xBAD);
        bytes32 attackerId = bytes32(uint256(uint160(attacker)));

        // Deposit 2 WBTC ($96k buying power after 80% LTV) + only 5k USDC
        uint256 wbtcAmount = 2 * 1e8;
        wbtc.mint(attacker, wbtcAmount);
        vm.startPrank(attacker);
        wbtc.approve(address(clearinghouse), wbtcAmount);
        clearinghouse.deposit(attackerId, address(wbtc), wbtcAmount);
        vm.stopPrank();

        uint256 smallUsdc = 5000 * 1e6;
        _deposit(attackerId, smallUsdc);

        // Aggregate buying power is huge (96k + 5k = 101k), but physical USDC is only 5k
        uint256 freeBp = clearinghouse.getFreeBuyingPowerUsdc(attackerId);
        assertGt(freeBp, 50_000 * 1e6, "WBTC inflates buying power far beyond USDC");

        // Try to open a position with 50k margin (needs 50k USDC locked).
        // Without fix: lockMargin sees 101k free buying power >= 50k, succeeds.
        // With fix: USDC balance (5k) < lockedMarginUsdc (0) + 50k = 50k, reverts.
        bool opened;
        try this.externalOpen(attackerId, CfdTypes.Side.BULL, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH) {
            opened = true;
        } catch {
            opened = false;
        }

        assertFalse(opened, "H-02: lockMargin must block positions where USDC is insufficient to back locked margin");
    }

    // lockMargin accepts non-USDC equity as backing even though settlement only seizes USDC.
    // This allows positions where the USDC backing is far less than the locked margin.
    function test_H02_LockMargin_AcceptsNonUsdcEquity() public {
        MockWBTC wbtc = new MockWBTC();
        MockOracle wbtcOracle = new MockOracle(60_000 * 1e8);

        clearinghouse.proposeAssetConfig(address(wbtc), 8, 8000, address(wbtcOracle));
        vm.warp(block.timestamp + 48 hours + 1);
        clearinghouse.finalizeAssetConfig();

        address attacker = address(0xBAD2);
        bytes32 attackerId = bytes32(uint256(uint160(attacker)));

        // Deposit WBTC only (no USDC at all)
        wbtc.mint(attacker, 2 * 1e8);
        vm.startPrank(attacker);
        wbtc.approve(address(clearinghouse), 2 * 1e8);
        clearinghouse.deposit(attackerId, address(wbtc), 2 * 1e8);
        vm.stopPrank();

        uint256 equity = clearinghouse.getAccountEquityUsdc(attackerId);
        assertGt(equity, 0, "WBTC creates buying power");
        assertEq(clearinghouse.balances(attackerId, address(usdc)), 0, "Zero USDC");

        // lockMargin should reject when the account has zero USDC, because
        // settlement can only seize USDC. Without the fix, it succeeds
        // because it only checks aggregate equity (including WBTC).
        // We call through the engine (which IS an operator) by trying to open a position.
        // Give attacker just enough USDC for the exec fee seizure on open.
        uint256 minUsdc = 1000 * 1e6;
        _deposit(attackerId, minUsdc);

        // Try to open a position where marginDelta ($50k) far exceeds USDC balance ($1k).
        // lockMargin will try to lock $50k - fees. The WBTC equity makes this pass.
        // But the locked margin has no USDC to settle against on loss.
        // With a proper fix, this should revert (USDC < locked amount).
        bool opened;
        try this.externalOpen(attackerId, CfdTypes.Side.BULL, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH) {
            opened = true;
        } catch {
            opened = false;
        }

        // If opened==true, lockMargin accepted non-USDC equity as backing for a $50k position
        // with only $1k USDC. This is the bug.
        assertFalse(
            opened, "H-02: lockMargin must require sufficient USDC, not just aggregate equity including non-USDC"
        );
    }

    function externalOpen(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 depth
    ) external {
        _open(accountId, side, size, margin, price, depth);
    }

    // ==========================================
    // Helpers
    // ==========================================

    function _absSkew(
        uint256 price
    ) internal view returns (uint256) {
        uint256 bullUsdc = (engine.bullOI() * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 bearUsdc = (engine.bearOI() * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        return bullUsdc > bearUsdc ? bullUsdc - bearUsdc : bearUsdc - bullUsdc;
    }

}
