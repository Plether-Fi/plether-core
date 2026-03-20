// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IPyth, PythStructs} from "../../src/interfaces/IPyth.sol";
import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {ICfdEngine} from "../../src/perps/interfaces/ICfdEngine.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Test.sol";

contract ControllablePythGas {

    struct MockPrice {
        int64 price;
        int32 expo;
        uint256 publishTime;
    }

    mapping(bytes32 => MockPrice) public prices;

    function setAllPrices(
        bytes32[] memory feedIds,
        int64 _price,
        int32 _expo,
        uint256 _publishTime
    ) external {
        for (uint256 i = 0; i < feedIds.length; i++) {
            prices[feedIds[i]] = MockPrice(_price, _expo, _publishTime);
        }
    }

    function getPriceUnsafe(
        bytes32 id
    ) external view returns (PythStructs.Price memory) {
        MockPrice memory p = prices[id];
        return PythStructs.Price({price: p.price, conf: 0, expo: p.expo, publishTime: p.publishTime});
    }

    function getUpdateFee(
        bytes[] calldata
    ) external pure returns (uint256) {
        return 0;
    }

    function updatePriceFeeds(
        bytes[] calldata
    ) external payable {}

}

/// @notice Gas profiling for top 20 perps operations.
/// Run: (source .env && forge test --match-contract GasProfileTest --fork-url $MAINNET_RPC_URL -vv)
/// Or without fork: forge test --match-contract GasProfileTest -vv
contract GasProfileTest is Test {

    address constant USDC_MAINNET = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    bytes32 constant EUR_USD_FEED_ID = 0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b;
    uint256 constant CAP_PRICE = 2e8;

    MarginClearinghouse clearinghouse;
    CfdEngine engine;
    HousePool pool;
    TrancheVault seniorVault;
    TrancheVault juniorVault;
    OrderRouter router;
    ControllablePythGas pyth;
    address usdc;

    bytes32[] feedIds;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address keeper = makeAddr("keeper");
    address lp = makeAddr("lp");
    address lp2 = makeAddr("lp2");

    function setUp() public {
        string memory rpc;
        try vm.envString("MAINNET_RPC_URL") returns (string memory url) {
            rpc = url;
        } catch {
            rpc = "";
        }

        if (bytes(rpc).length > 0) {
            vm.createSelectFork(rpc, 24_136_062);
            usdc = USDC_MAINNET;
        } else {
            usdc = address(new MockUSDC6());
            vm.label(usdc, "MockUSDC");
        }

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5e6,
            bountyBps: 15
        });

        clearinghouse = new MarginClearinghouse(usdc);
        engine = new CfdEngine(usdc, address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(usdc, address(engine));

        seniorVault = new TrancheVault(IERC20(usdc), address(pool), true, "Senior LP", "senUSDC");
        juniorVault = new TrancheVault(IERC20(usdc), address(pool), false, "Junior LP", "junUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        pyth = new ControllablePythGas();
        feedIds.push(EUR_USD_FEED_ID);
        uint256[] memory w = new uint256[](1);
        w[0] = 1e18;
        uint256[] memory b = new uint256[](1);
        b[0] = 1e8;
        router = new OrderRouter(address(engine), address(pool), address(pyth), feedIds, w, b, new bool[](1));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        uint256 t0 = block.timestamp;
        clearinghouse.setEngine(address(engine));
        vm.warp(t0 + 144 hours + 3);

        _mintUsdc(lp, 1_000_000e6);
        vm.startPrank(lp);
        IERC20(usdc).approve(address(juniorVault), type(uint256).max);
        juniorVault.deposit(1_000_000e6, lp);
        vm.stopPrank();
    }

    // ==========================================
    // GAS PROFILING — 20 operations
    // ==========================================

    // --- 1. commitOrder (open) ---
    function test_gas_01_commitOrder_open() public {
        _depositToClearinghouse(alice, 10_000e6);

        vm.prank(alice);
        uint256 g0 = gasleft();
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 5000e6, 1e8, false);
        uint256 gas = g0 - gasleft();
        emit log_named_uint("01_commitOrder_open", gas);
    }

    // --- 2. commitOrder (close) ---
    function test_gas_02_commitOrder_close() public {
        _depositToClearinghouse(alice, 10_000e6);
        _openPosition(alice, CfdTypes.Side.BULL, 50_000e18, 5000e6, 1e8);

        vm.prank(alice);
        uint256 g0 = gasleft();
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 0, 0, true);
        uint256 gas = g0 - gasleft();
        emit log_named_uint("02_commitOrder_close", gas);
    }

    // --- 3. executeOrder (open, first position — cold storage) ---
    function test_gas_03_executeOrder_open_first() public {
        _depositToClearinghouse(alice, 10_000e6);
        uint256 ts = block.timestamp;

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 5000e6, 1e8, false);

        pyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), ts + 6);
        vm.warp(ts + 7);
        vm.roll(block.number + 2);

        vm.prank(keeper);
        uint256 g0 = gasleft();
        router.executeOrder(1, _pythUpdateData());
        uint256 gas = g0 - gasleft();
        emit log_named_uint("03_executeOrder_open_first", gas);
    }

    // --- 4. executeOrder (open, increase existing position — warm storage) ---
    function test_gas_04_executeOrder_open_increase() public {
        _depositToClearinghouse(alice, 20_000e6);
        _openPosition(alice, CfdTypes.Side.BULL, 50_000e18, 5000e6, 1e8);

        uint256 ts = block.timestamp + 30;
        vm.warp(ts);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 20_000e18, 3000e6, 1e8, false);

        pyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), ts + 6);
        vm.warp(ts + 7);
        vm.roll(block.number + 2);

        vm.prank(keeper);
        uint256 g0 = gasleft();
        router.executeOrder(2, _pythUpdateData());
        uint256 gas = g0 - gasleft();
        emit log_named_uint("04_executeOrder_open_increase", gas);
    }

    // --- 5. executeOrder (close, full) ---
    function test_gas_05_executeOrder_close_full() public {
        _depositToClearinghouse(alice, 10_000e6);
        _openPosition(alice, CfdTypes.Side.BULL, 50_000e18, 5000e6, 1e8);

        uint256 ts = block.timestamp + 30;
        vm.warp(ts);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 0, 0, true);

        pyth.setAllPrices(feedIds, int64(95_000_000), int32(-8), ts + 6);
        vm.warp(ts + 7);
        vm.roll(block.number + 2);

        vm.prank(keeper);
        uint256 g0 = gasleft();
        router.executeOrder(2, _pythUpdateData());
        uint256 gas = g0 - gasleft();
        emit log_named_uint("05_executeOrder_close_full", gas);
    }

    // --- 6. executeOrder (close, partial) ---
    function test_gas_06_executeOrder_close_partial() public {
        _depositToClearinghouse(alice, 10_000e6);
        _openPosition(alice, CfdTypes.Side.BULL, 50_000e18, 5000e6, 1e8);

        uint256 ts = block.timestamp + 30;
        vm.warp(ts);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 20_000e18, 0, 0, true);

        pyth.setAllPrices(feedIds, int64(95_000_000), int32(-8), ts + 6);
        vm.warp(ts + 7);
        vm.roll(block.number + 2);

        vm.prank(keeper);
        uint256 g0 = gasleft();
        router.executeOrder(2, _pythUpdateData());
        uint256 gas = g0 - gasleft();
        emit log_named_uint("06_executeOrder_close_partial", gas);
    }

    // --- 7. executeOrderBatch (3 orders) ---
    function test_gas_07_executeOrderBatch_3() public {
        _depositToClearinghouse(alice, 20_000e6);
        _depositToClearinghouse(bob, 20_000e6);
        _depositToClearinghouse(carol, 20_000e6);

        uint256 ts = block.timestamp;

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 30_000e18, 3000e6, 1e8, false);
        vm.prank(bob);
        router.commitOrder(CfdTypes.Side.BEAR, 25_000e18, 2500e6, 1e8, false);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 20_000e18, 2000e6, 1e8, false);

        pyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), ts + 6);
        vm.warp(ts + 7);
        vm.roll(block.number + 2);

        vm.prank(keeper);
        uint256 g0 = gasleft();
        router.executeOrderBatch(3, _pythUpdateData());
        uint256 gas = g0 - gasleft();
        emit log_named_uint("07_executeOrderBatch_3_orders", gas);
    }

    // --- 8. executeLiquidation ---
    function test_gas_08_executeLiquidation() public {
        _depositToClearinghouse(alice, 10_000e6);
        _openPosition(alice, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);

        // Withdraw free margin so position is thinly margined
        bytes32 aliceId = _accountId(alice);
        uint256 balance = clearinghouse.balanceUsdc(aliceId);
        uint256 locked = clearinghouse.lockedMarginUsdc(aliceId);
        if (balance > locked) {
            vm.prank(alice);
            clearinghouse.withdraw(aliceId, balance - locked);
        }

        // Price rises → BULL loses. $1.10 = -$10k PnL on $100k notional
        uint256 liqTs = block.timestamp + 60;
        vm.warp(liqTs);
        pyth.setAllPrices(feedIds, int64(110_000_000), int32(-8), liqTs);

        vm.prank(keeper);
        uint256 g0 = gasleft();
        router.executeLiquidation(aliceId, _pythUpdateData());
        uint256 gas = g0 - gasleft();
        emit log_named_uint("08_executeLiquidation", gas);
    }

    // --- 9. addMargin ---
    function test_gas_09_addMargin() public {
        _depositToClearinghouse(alice, 10_000e6);
        _openPosition(alice, CfdTypes.Side.BULL, 50_000e18, 3000e6, 1e8);

        bytes32 aliceId = _accountId(alice);

        vm.prank(alice);
        uint256 g0 = gasleft();
        engine.addMargin(aliceId, 1000e6);
        uint256 gas = g0 - gasleft();
        emit log_named_uint("09_addMargin", gas);
    }

    // --- 10. claimDeferredPayout ---
    function test_gas_10_claimDeferredPayout() public {
        _depositToClearinghouse(alice, 11_000e6);
        _openPosition(alice, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        bytes32 aliceId = _accountId(alice);

        // Drain pool to force deferred payout
        uint256 poolAssets = IERC20(usdc).balanceOf(address(pool));
        vm.prank(address(pool));
        IERC20(usdc).transfer(address(0xDEAD), poolAssets - 9000e6);

        // Close at profit — payout gets deferred (use external call for clean timestamp reads)
        this._closeAtPrice(alice, CfdTypes.Side.BULL, 100_000e18, int64(80_000_000));

        uint256 deferred = engine.deferredPayoutUsdc(aliceId);
        require(deferred > 0, "Setup failed: no deferred payout");

        // Replenish pool so claim can succeed
        _mintUsdc(address(pool), deferred);

        vm.prank(alice);
        uint256 g0 = gasleft();
        engine.claimDeferredPayout(aliceId);
        uint256 gas = g0 - gasleft();
        emit log_named_uint("10_claimDeferredPayout", gas);
    }

    // --- 11. clearinghouse.deposit ---
    function test_gas_11_clearinghouse_deposit() public {
        _mintUsdc(alice, 10_000e6);
        vm.startPrank(alice);
        IERC20(usdc).approve(address(clearinghouse), type(uint256).max);

        bytes32 aliceId = _accountId(alice);
        uint256 g0 = gasleft();
        clearinghouse.deposit(aliceId, 5000e6);
        uint256 gas = g0 - gasleft();
        vm.stopPrank();
        emit log_named_uint("11_clearinghouse_deposit", gas);
    }

    // --- 12. clearinghouse.withdraw ---
    function test_gas_12_clearinghouse_withdraw() public {
        _depositToClearinghouse(alice, 10_000e6);

        bytes32 aliceId = _accountId(alice);
        vm.prank(alice);
        uint256 g0 = gasleft();
        clearinghouse.withdraw(aliceId, 5000e6);
        uint256 gas = g0 - gasleft();
        emit log_named_uint("12_clearinghouse_withdraw", gas);
    }

    // --- 13. juniorVault.deposit ---
    function test_gas_13_juniorVault_deposit() public {
        _mintUsdc(lp2, 100_000e6);
        vm.startPrank(lp2);
        IERC20(usdc).approve(address(juniorVault), type(uint256).max);

        uint256 g0 = gasleft();
        juniorVault.deposit(100_000e6, lp2);
        uint256 gas = g0 - gasleft();
        vm.stopPrank();
        emit log_named_uint("13_juniorVault_deposit", gas);
    }

    // --- 14. juniorVault.withdraw ---
    function test_gas_14_juniorVault_withdraw() public {
        _mintUsdc(lp2, 100_000e6);
        vm.startPrank(lp2);
        IERC20(usdc).approve(address(juniorVault), type(uint256).max);
        juniorVault.deposit(100_000e6, lp2);
        vm.warp(block.timestamp + 2 hours);

        uint256 g0 = gasleft();
        juniorVault.withdraw(50_000e6, lp2, lp2);
        uint256 gas = g0 - gasleft();
        vm.stopPrank();
        emit log_named_uint("14_juniorVault_withdraw", gas);
    }

    // --- 15. seniorVault.deposit ---
    function test_gas_15_seniorVault_deposit() public {
        _mintUsdc(lp2, 500_000e6);
        vm.startPrank(lp2);
        IERC20(usdc).approve(address(seniorVault), type(uint256).max);

        uint256 g0 = gasleft();
        seniorVault.deposit(500_000e6, lp2);
        uint256 gas = g0 - gasleft();
        vm.stopPrank();
        emit log_named_uint("15_seniorVault_deposit", gas);
    }

    // --- 16. seniorVault.withdraw ---
    function test_gas_16_seniorVault_withdraw() public {
        _mintUsdc(lp2, 500_000e6);
        vm.startPrank(lp2);
        IERC20(usdc).approve(address(seniorVault), type(uint256).max);
        seniorVault.deposit(500_000e6, lp2);
        vm.warp(block.timestamp + 2 hours);

        uint256 g0 = gasleft();
        seniorVault.withdraw(200_000e6, lp2, lp2);
        uint256 gas = g0 - gasleft();
        vm.stopPrank();
        emit log_named_uint("16_seniorVault_withdraw", gas);
    }

    // --- 17. previewClose ---
    function test_gas_17_previewClose() public {
        _depositToClearinghouse(alice, 10_000e6);
        _openPosition(alice, CfdTypes.Side.BULL, 50_000e18, 5000e6, 1e8);

        bytes32 aliceId = _accountId(alice);
        uint256 g0 = gasleft();
        engine.previewClose(aliceId, 50_000e18, 0.95e8, pool.totalAssets());
        uint256 gas = g0 - gasleft();
        emit log_named_uint("17_previewClose", gas);
    }

    // --- 18. previewLiquidation ---
    function test_gas_18_previewLiquidation() public {
        _depositToClearinghouse(alice, 10_000e6);
        _openPosition(alice, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);

        bytes32 aliceId = _accountId(alice);
        uint256 g0 = gasleft();
        engine.previewLiquidation(aliceId, 1.1e8, pool.totalAssets());
        uint256 gas = g0 - gasleft();
        emit log_named_uint("18_previewLiquidation", gas);
    }

    // --- 19. getAccountLedgerSnapshot ---
    function test_gas_19_getAccountLedgerSnapshot() public {
        _depositToClearinghouse(alice, 10_000e6);
        _openPosition(alice, CfdTypes.Side.BULL, 50_000e18, 5000e6, 1e8);

        bytes32 aliceId = _accountId(alice);
        uint256 g0 = gasleft();
        engine.getAccountLedgerSnapshot(aliceId);
        uint256 gas = g0 - gasleft();
        emit log_named_uint("19_getAccountLedgerSnapshot", gas);
    }

    // --- 20. getVaultLiquidityView ---
    function test_gas_20_getVaultLiquidityView() public {
        // Add some state: positions + both tranches
        _mintUsdc(lp2, 500_000e6);
        vm.startPrank(lp2);
        IERC20(usdc).approve(address(seniorVault), type(uint256).max);
        seniorVault.deposit(500_000e6, lp2);
        vm.stopPrank();

        _depositToClearinghouse(alice, 10_000e6);
        _openPosition(alice, CfdTypes.Side.BULL, 50_000e18, 5000e6, 1e8);

        uint256 g0 = gasleft();
        pool.getVaultLiquidityView();
        uint256 gas = g0 - gasleft();
        emit log_named_uint("20_getVaultLiquidityView", gas);
    }

    // --- Batch scaling ---

    function test_gas_21_executeOrderBatch_30() public {
        _batchOpenTest(30);
    }

    function test_gas_22_executeOrderBatch_300() public {
        _batchOpenTest(300);
    }

    function _batchOpenTest(
        uint256 n
    ) internal {
        // Seed pool with enough liquidity for all positions
        _mintUsdc(lp, n * 100_000e6);
        vm.startPrank(lp);
        IERC20(usdc).approve(address(juniorVault), type(uint256).max);
        juniorVault.deposit(n * 100_000e6, lp);
        vm.stopPrank();

        uint256 ts = block.timestamp;

        for (uint256 i = 0; i < n; i++) {
            address trader = address(uint160(0xA000 + i));
            _depositToClearinghouse(trader, 5000e6);
            CfdTypes.Side side = i % 2 == 0 ? CfdTypes.Side.BULL : CfdTypes.Side.BEAR;
            vm.prank(trader);
            router.commitOrder(side, 10_000e18, 1000e6, 1e8, false);
        }

        pyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), ts + 6);
        vm.warp(ts + 7);
        vm.roll(block.number + 2);

        vm.prank(keeper);
        uint256 g0 = gasleft();
        router.executeOrderBatch(uint64(n), _pythUpdateData());
        uint256 gasUsed = g0 - gasleft();

        emit log_named_uint(string.concat("batch_", vm.toString(n), "_total"), gasUsed);
        emit log_named_uint(string.concat("batch_", vm.toString(n), "_per_order"), gasUsed / n);
    }

    // ==========================================
    // HELPERS
    // ==========================================

    function _mintUsdc(
        address to,
        uint256 amount
    ) internal {
        if (usdc == USDC_MAINNET) {
            deal(usdc, to, IERC20(usdc).balanceOf(to) + amount);
        } else {
            MockUSDC6(usdc).mint(to, amount);
        }
    }

    function _depositToClearinghouse(
        address trader,
        uint256 amount
    ) internal {
        _mintUsdc(trader, amount);
        vm.startPrank(trader);
        IERC20(usdc).approve(address(clearinghouse), amount);
        clearinghouse.deposit(_accountId(trader), amount);
        vm.stopPrank();
    }

    function _openPosition(
        address trader,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 targetPrice
    ) internal {
        uint256 ts = block.timestamp;
        uint64 orderId = router.nextCommitId();

        vm.prank(trader);
        router.commitOrder(side, size, margin, targetPrice, false);

        pyth.setAllPrices(feedIds, int64(int256(targetPrice)), int32(-8), ts + 6);
        vm.warp(ts + 7);
        vm.roll(block.number + 2);

        vm.prank(keeper);
        router.executeOrder(orderId, _pythUpdateData());
    }

    function _closeAtPrice(
        address trader,
        CfdTypes.Side side,
        uint256 size,
        int64 pythPrice
    ) external {
        uint256 commitTime = block.timestamp + 30;
        vm.warp(commitTime);
        uint64 orderId = router.nextCommitId();

        vm.prank(trader);
        router.commitOrder(side, size, 0, 0, true);

        pyth.setAllPrices(feedIds, pythPrice, int32(-8), commitTime + 6);
        vm.warp(commitTime + 7);
        vm.roll(block.number + 2);

        vm.prank(keeper);
        router.executeOrder(orderId, _pythUpdateData());
    }

    function _accountId(
        address trader
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(trader)));
    }

    function _pythUpdateData() internal pure returns (bytes[] memory updateData) {
        updateData = new bytes[](1);
        updateData[0] = "";
    }

}

contract MockUSDC6 {

    string public constant name = "Mock USDC";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(
        address to,
        uint256 amount
    ) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(
        address spender,
        uint256 amount
    ) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(
        address to,
        uint256 amount
    ) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        return _transfer(from, to, amount);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

}
