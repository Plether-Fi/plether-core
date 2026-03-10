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

        clearinghouse = new MarginClearinghouse();
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

    // Sub-issue 1: MM who heals skew on both open AND close gets rebate zeroed by clamp.
    // An MM opens BULL into a BEAR-heavy market (reducing skew → earns VPI rebate),
    // then closes when skew is still favorable (also reducing skew → earns VPI rebate).
    // The clamp forces proportionalVpi + vpiUsdc >= 0, zeroing the close rebate.
    // The MM should retain both rebates since both trades improved market health.
    function test_H01_MM_RebateDestroyed_ByClamping() public {
        bytes32 skewerId = bytes32(uint256(uint160(address(0x51))));
        _deposit(skewerId, 500_000 * 1e6);

        // Create heavy BEAR skew so MM can heal it
        _open(skewerId, CfdTypes.Side.BEAR, 1_000_000 * 1e18, 100_000 * 1e6, 1e8, DEPTH);

        uint256 preSkew = _absSkew(1e8);
        assertGt(preSkew, 0, "Skew exists before MM enters");

        // MM opens BULL — heals skew → should earn a VPI rebate (negative vpiAccrued)
        bytes32 mmId = bytes32(uint256(uint160(address(0x111))));
        _deposit(mmId, 500_000 * 1e6);
        _open(mmId, CfdTypes.Side.BULL, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        (,,,,,,, int256 vpiAfterOpen) = engine.positions(mmId);
        assertLt(vpiAfterOpen, 0, "MM earned VPI rebate on open (healed skew)");

        uint256 postOpenSkew = _absSkew(1e8);
        assertLt(postOpenSkew, preSkew, "Skew decreased after MM opened");

        // MM closes BULL — still reduces skew further (since BEAR > BULL even after MM)
        // Close should ALSO earn a rebate. But the clamp will zero it out.
        uint256 mmUsdcBefore = clearinghouse.balances(mmId, address(usdc));
        (uint256 mmSize,,,,,,,) = engine.positions(mmId);
        _close(mmId, CfdTypes.Side.BULL, mmSize, 1e8, DEPTH);
        uint256 mmUsdcAfter = clearinghouse.balances(mmId, address(usdc));

        // Compute what VPI *should* have been without the clamp:
        // Both open and close reduced skew → both should yield negative (rebate) VPI.
        // The close VPI rebate is a real earned spread for providing liquidity.
        // With the clamp: proportionalVpi (negative) + vpiUsdc (negative) < 0 → vpiUsdc = -proportionalVpi → net 0
        // Without the clamp: MM keeps both rebates.

        // The MM deposited margin, paid exec fees, took zero price risk (entry=exit=$1).
        // Their USDC balance after close should exceed deposit minus exec fees IF rebates retained.
        // With the bug, they net ~$0 from VPI (rebate zeroed), losing to exec fees.
        uint256 totalDeposited = 500_000 * 1e6;
        uint256 approxExecFees = (500_000 * 1e6 * 6 / 10_000) * 2; // open + close
        uint256 breakeven = totalDeposited - approxExecFees;

        assertGt(
            mmUsdcAfter,
            breakeven,
            "H-01: MM who healed skew on both open and close must retain VPI rebate, not get zeroed by clamp"
        );
    }

    // Sub-issue 2: Partial close uses linear VPI chunking on quadratic curve.
    // Open 100% at once, then close in two 50% chunks. The quadratic curve means
    // the outer half carries 75% of total VPI cost, but linear chunking releases only 50%.
    // Compare against closing 100% at once — the total VPI should be identical.
    function test_H01_PartialClose_LinearChunking_Mismatch() public {
        // Create some BEAR skew so BULL open incurs a charge
        bytes32 skewerId = bytes32(uint256(uint160(address(0x52))));
        _deposit(skewerId, 500_000 * 1e6);
        _open(skewerId, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8, DEPTH);

        // --- Path A: Open + close 100% at once ---
        bytes32 aliceId = bytes32(uint256(uint160(address(0xA1))));
        _deposit(aliceId, 500_000 * 1e6);
        _open(aliceId, CfdTypes.Side.BULL, 400_000 * 1e18, 100_000 * 1e6, 1e8, DEPTH);

        uint256 aliceBefore = clearinghouse.balances(aliceId, address(usdc));
        _close(aliceId, CfdTypes.Side.BULL, 400_000 * 1e18, 1e8, DEPTH);
        uint256 aliceAfter = clearinghouse.balances(aliceId, address(usdc));
        int256 aliceNet = int256(aliceAfter) - int256(aliceBefore);

        // --- Path B: Open same size, close in two 50% chunks ---
        // Reset skew to same starting state
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

        // On a quadratic curve, closing in chunks vs all-at-once should yield the same
        // total VPI (the integral is path-independent for same start/end skew).
        // The linear chunking breaks this: partial closers get different VPI than full closers.
        int256 diff = aliceNet > bobNet ? aliceNet - bobNet : bobNet - aliceNet;
        uint256 tolerance = 1e6; // $1 tolerance for rounding

        assertLe(
            uint256(diff),
            tolerance,
            "H-01: Closing in chunks vs all-at-once must yield same total VPI (quadratic curve is path-independent)"
        );
    }

    // ==========================================
    // H-02: Non-USDC collateral enables risk-free trading
    // ==========================================

    // Attacker deposits small USDC (for fees) + large WBTC (inflates buying power).
    // Opens oversized position backed mostly by WBTC equity. Takes a loss bigger
    // than USDC balance. Engine seizes all available USDC but can't touch WBTC.
    // Shortfall becomes bad debt socialized to LPs. WBTC stays intact.
    function test_H02_NonUsdcCollateral_BadDebtSocializedToVault() public {
        MockWBTC wbtc = new MockWBTC();
        MockOracle wbtcOracle = new MockOracle(60_000 * 1e8);

        clearinghouse.proposeAssetConfig(address(wbtc), 8, 8000, address(wbtcOracle));
        vm.warp(block.timestamp + 48 hours + 1);
        clearinghouse.finalizeAssetConfig();

        address attacker = address(0xBAD);
        bytes32 attackerId = bytes32(uint256(uint160(attacker)));

        uint256 wbtcAmount = 2 * 1e8;
        wbtc.mint(attacker, wbtcAmount);
        vm.startPrank(attacker);
        wbtc.approve(address(clearinghouse), wbtcAmount);
        clearinghouse.deposit(attackerId, address(wbtc), wbtcAmount);
        vm.stopPrank();

        uint256 marginUsdc = 20_000 * 1e6;
        _deposit(attackerId, marginUsdc);

        assertGt(
            clearinghouse.getFreeBuyingPowerUsdc(attackerId),
            marginUsdc,
            "WBTC inflates buying power beyond USDC balance"
        );

        _open(attackerId, CfdTypes.Side.BULL, 500_000 * 1e18, marginUsdc, 1e8, DEPTH);

        // Price rises $1.00 -> $1.05: BULL loses $25k
        engine.updateMarkPrice(1.05e8);

        _close(attackerId, CfdTypes.Side.BULL, 500_000 * 1e18, 1.05e8, DEPTH);

        // The loss (~$25k + fees) exceeded available USDC (~$19.7k after open fees).
        // In a correct system, the shortfall would be covered by seizing WBTC.
        // With the bug, WBTC sits untouched and the shortfall becomes bad debt for LPs.
        uint256 wbtcAfter = clearinghouse.balances(attackerId, address(wbtc));

        // This SHOULD be less than wbtcAmount (protocol should have seized some WBTC
        // to cover the ~$5k shortfall). With the bug, WBTC is fully intact.
        assertLt(
            wbtcAfter,
            wbtcAmount,
            "H-02: WBTC must be partially seized to cover loss shortfall, not left intact as bad debt for LPs"
        );
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
