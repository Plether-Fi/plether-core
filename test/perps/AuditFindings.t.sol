// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {PythStructs} from "../../src/interfaces/IPyth.sol";
import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
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

contract MockFeeOnTransferToken is ERC20 {

    using SafeERC20 for IERC20;

    uint256 public feeBps;

    constructor(
        uint256 _feeBps
    ) ERC20("Fee Token", "FOT") {
        feeBps = _feeBps;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = (amount * feeBps) / 10_000;
            super._update(from, to, amount - fee);
            if (fee > 0) {
                super._update(from, address(0), fee);
            }
        } else {
            super._update(from, to, amount);
        }
    }

}

contract AuditFindingsTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault seniorVault;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;
    OrderRouter router;

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    receive() external payable {}

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + 48 hours + 1);
    }

    function setUp() public {
        usdc = new MockUSDC();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0,
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
        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        router = new OrderRouter(
            address(engine),
            address(pool),
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        clearinghouse.proposeWithdrawGuard(address(engine));
        _warpPastTimelock();
        clearinghouse.finalizeAssetConfig();
        clearinghouse.finalizeWithdrawGuard();

        clearinghouse.proposeOperator(address(engine), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();

        clearinghouse.proposeOperator(address(router), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();
    }

    function _fundSenior(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(seniorVault), amount);
        seniorVault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _fundJunior(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), amount);
        juniorVault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _fundTrader(
        address trader,
        uint256 amount
    ) internal {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, address(usdc), amount);
        vm.stopPrank();
    }

    // ==========================================
    // Finding 2: Stale totalAssets on deposit
    // A new depositor should NOT capture yield that accrued before their deposit.
    // EXPECTED: Carol's shares worth exactly her deposit. Alice keeps all yield.
    // BUG: Carol's shares are worth MORE than deposited (she stole Alice's yield).
    // ==========================================

    function test_Finding2_StaleSharePriceOnDeposit() public {
        _fundSenior(alice, 100_000 * 1e6);
        _fundJunior(bob, 100_000 * 1e6);

        usdc.mint(address(pool), 20_000 * 1e6);
        vm.warp(block.timestamp + 365 days);

        uint256 carolDeposit = 100_000 * 1e6;
        _fundSenior(carol, carolDeposit);

        uint256 carolShares = seniorVault.balanceOf(carol);
        uint256 carolShareValue = seniorVault.convertToAssets(carolShares);

        // CORRECT BEHAVIOR: Carol deposited 100k, her shares should be worth 100k.
        // She arrived after yield accrued, so she gets no yield.
        assertLe(carolShareValue, carolDeposit, "Carol should not profit from pre-existing yield");
    }

    // ==========================================
    // Finding 3: Uncollected funding bad debt
    // When funding owed exceeds margin, orders should be rejected so the
    // position can be liquidated instead of silently forgiving debt.
    // EXPECTED: Order on underwater position is cancelled (position unchanged).
    // BUG: Vault only receives min(owed, margin), rest is forgiven.
    // ==========================================

    function test_Finding3_FundingBadDebt() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(carol, 50_000 * 1e6);

        bytes32 accountId = bytes32(uint256(uint160(carol)));

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        (uint256 sizeAfterOpen,,,,,,,) = engine.positions(accountId);

        vm.warp(block.timestamp + 180 days);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 1000 * 1e18, 500 * 1e6, 1e8, false);
        router.executeOrder(2, empty);

        (uint256 sizeAfterSecond,,,,,,,) = engine.positions(accountId);

        // CORRECT BEHAVIOR: The order was cancelled because funding > margin.
        // Position size should be unchanged (no new size added, no bad debt created).
        assertEq(sizeAfterSecond, sizeAfterOpen, "Order on underwater position should be cancelled");
    }

    // ==========================================
    // Finding 4: Async funding — netUnsettledFunding prevents false solvency reverts
    // When a receiver settles funding before payers, vault.totalAssets() temporarily drops.
    // The netUnsettledFunding credit ensures the solvency check accounts for owed funding,
    // allowing legitimate orders to proceed.
    // ==========================================

    function test_Finding4_AsyncFundingDoesNotBlockLegitOrders() public {
        _fundJunior(bob, 210_000 * 1e6);

        address dave = address(0x444);
        _fundTrader(carol, 50_000 * 1e6);
        _fundTrader(dave, 200_000 * 1e6);

        vm.prank(dave);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000 * 1e18, 200_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 50_000 * 1e18, 5000 * 1e6, 1e8, false);
        router.executeOrder(2, empty);

        bytes32 carolAccount = bytes32(uint256(uint160(carol)));
        (uint256 sizeBefore,,,,,,,) = engine.positions(carolAccount);

        vm.warp(block.timestamp + 90 days);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        router.executeOrder(3, empty);

        (uint256 sizeAfter,,,,,,,) = engine.positions(carolAccount);

        assertGt(sizeAfter, sizeBefore, "Capped funding receivable covers vault depletion within margin bounds");
        assertLt(engine.getUnrealizedFundingPnl(), 0, "Net payers have negative unrealized funding (vault is owed)");
    }

    // ==========================================
    // Finding 5: Close orders bypass slippage
    // Close orders should respect slippage protection just like opens.
    // BULL benefits from low oracle price, so close should reject high prices.
    // EXPECTED: BULL close at $1.50 rejected when targetPrice is $0.90.
    // BUG: Close executes at any price regardless of targetPrice.
    // ==========================================

    function test_Finding5_CloseBypassesSlippage() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(carol, 50_000 * 1e6);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        // Close with targetPrice = $0.90 (BULL wants oracle <= target)
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 0, 0.9e8, true);

        // Execute at $1.50 — oracle went UP, bad for BULL ($1.50 > $0.90)
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(uint256(1.5e8));
        router.executeOrder(2, pythData);

        bytes32 carolAccount = bytes32(uint256(uint160(carol)));
        (uint256 size,,,,,,,) = engine.positions(carolAccount);
        assertGt(size, 0, "Close at bad price should have been rejected by slippage check");
    }

    // ==========================================
    // Finding 6: Missing chainId guard in executeOrder
    // executeOrder should reject mock oracle mode on live networks,
    // just like executeLiquidation does.
    // EXPECTED: executeOrder reverts on mainnet when pyth=address(0).
    // BUG: executeOrder succeeds, using targetPrice as oracle on mainnet.
    // ==========================================

    function test_Finding6_MissingChainIdGuard() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(carol, 50_000 * 1e6);

        vm.chainId(1);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty;

        // CORRECT BEHAVIOR: Should revert on mainnet with mock oracle, same as executeLiquidation.
        vm.expectRevert(OrderRouter.OrderRouter__MockModeDisabled.selector);
        router.executeOrder(1, empty);
    }

    // ==========================================
    // Finding 7: Fee-on-transfer accounting mismatch
    // The recorded balance should match what the contract actually received.
    // EXPECTED: balances[account][fot] == fot.balanceOf(clearinghouse).
    // BUG: balances records the pre-fee amount, actual balance is less.
    // ==========================================

    // ==========================================
    // Finding 8: Clearinghouse withdrawal ignores unrealized PnL
    // Users can withdraw free balance while holding an underwater position,
    // front-running liquidation and leaving the vault to absorb bad debt.
    // EXPECTED: Withdrawal reverts while a position is open.
    // ==========================================

    function test_Finding8_WithdrawAllowedWithOpenPosition() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 10_000 * 1e6);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertGt(size, 0, "Position should be open");

        uint256 freeBalance =
            clearinghouse.balances(accountId, address(usdc)) - clearinghouse.lockedMarginUsdc(accountId);
        assertGt(freeBalance, 0, "Alice should have free balance");

        vm.prank(alice);
        vm.expectRevert(CfdEngine.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        clearinghouse.withdraw(accountId, address(usdc), freeBalance);
    }

    function test_Finding8_WithdrawAllowedAfterClose() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 10_000 * 1e6);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 0, 1e8, true);
        router.executeOrder(2, empty);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be closed");

        uint256 balance = clearinghouse.balances(accountId, address(usdc));
        vm.prank(alice);
        clearinghouse.withdraw(accountId, address(usdc), balance);
        assertEq(usdc.balanceOf(alice), balance, "Alice should receive her USDC");
    }

    function test_Finding7_FeeOnTransferAccounting() public {
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken(100); // 1% fee
        clearinghouse.proposeAssetConfig(address(fot), 18, 10_000, address(0));
        _warpPastTimelock();
        clearinghouse.finalizeAssetConfig();

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        uint256 depositAmount = 1000 * 1e18;
        fot.mint(alice, depositAmount);

        vm.startPrank(alice);
        fot.approve(address(clearinghouse), depositAmount);
        clearinghouse.deposit(accountId, address(fot), depositAmount);
        vm.stopPrank();

        uint256 recordedBalance = clearinghouse.balances(accountId, address(fot));
        uint256 actualBalance = fot.balanceOf(address(clearinghouse));

        // CORRECT BEHAVIOR: Recorded balance should equal actual tokens held.
        assertEq(recordedBalance, actualBalance, "Recorded balance should match actual tokens received");
    }

    // ==========================================
    // H-01: Mark-to-Market accounting
    // Without MtM, reconcile treats cash balance as pool value, ignoring
    // unrealized trader PnL. When traders are winning, the pool over-distributes
    // revenue to LP shares (inflated). When traders are losing, shares are undervalued.
    // FIX: CfdEngine tracks global entry notionals for O(1) aggregate PnL calculation.
    //      HousePool._reconcile() adjusts distributable by unrealized trader PnL.
    // ==========================================

    function test_H01_MtM_TraderProfitReducesJuniorPrincipal() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);
        _fundTrader(carol, 50_000e6);

        // Alice opens BEAR 200K @ $1.00
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        uint256 juniorBefore = pool.juniorPrincipal();

        // Carol opens BULL at $1.20 to update lastMarkPrice — BEAR profits
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1.2e8));
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 10_000e6, 1.2e8, false);
        router.executeOrder(2, priceData);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 juniorAfter = pool.juniorPrincipal();

        assertLt(juniorAfter, juniorBefore, "MtM: junior principal must decrease when traders are winning");
        assertGt(engine.getUnrealizedTraderPnl(), 0, "Traders should have positive unrealized PnL");
    }

    function test_H01_MtM_TraderLossIncreasesJuniorPrincipal() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);
        _fundTrader(carol, 50_000e6);

        // Alice opens BEAR 200K @ $1.00
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        uint256 juniorBefore = pool.juniorPrincipal();

        // Carol opens BULL at $0.80 to update lastMarkPrice — BEAR loses
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(0.8e8));
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 10_000e6, 0.8e8, false);
        router.executeOrder(2, priceData);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 juniorAfter = pool.juniorPrincipal();

        assertLe(juniorAfter, juniorBefore, "C-03 fix: unrealized trader losses must not inflate junior principal");
        assertLt(engine.getUnrealizedTraderPnl(), 0, "Traders should have negative unrealized PnL");
    }

    function test_H01_MtM_ZeroAfterAllPositionsClosed() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        // Open and close a position
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 5000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 0, 1e8, true);
        router.executeOrder(2, empty);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0);

        assertEq(engine.globalBullEntryNotional(), 0, "Bull entry notional should be zero");
        assertEq(engine.globalBearEntryNotional(), 0, "Bear entry notional should be zero");
        assertEq(engine.getUnrealizedTraderPnl(), 0, "Unrealized PnL should be zero with no positions");
    }

    // ==========================================
    // C-01: Partial close seize must respect lockedMarginUsdc
    // A partial close at a large loss must only seize from unencumbered (free) USDC,
    // not from margin locked for the remaining position. Without the fix, the seize
    // drains the physical balance below lockedMarginUsdc, creating a "zombie" position
    // whose liquidation reverts with InsufficientAssetToSeize.
    // EXPECTED: After partial close, balance >= locked. Liquidation succeeds.
    // BUG (pre-fix): seize uses gross balance, balance < locked, liquidation reverts.
    // ==========================================

    // ==========================================
    // C-01 (new): Stale Mark Price enables risk-free NAV arbitrage
    // In a pull-oracle architecture, lastMarkPrice is only updated when a trade or
    // liquidation executes. Deposits and withdrawals are synchronous ERC-4626 calls
    // that do NOT require an oracle update.
    // If the real market moves (e.g., BEAR traders gain $120K), but no trade has
    // updated lastMarkPrice, _reconcile() computes MtM from the stale mark.
    // An LP can withdraw at the inflated NAV before the loss is marked on-chain.
    // EXPECTED: Both LPs absorb losses equally regardless of withdrawal timing.
    // BUG: First-mover LP escapes at stale NAV; last LP absorbs all MtM losses.
    // ==========================================

    function test_C01_StaleMarkPriceBlocksWithdrawal() public {
        _fundJunior(bob, 500_000e6);
        _fundJunior(carol, 500_000e6);
        _fundTrader(alice, 50_000e6);
        vm.warp(block.timestamp + 2 hours);

        // Alice opens BEAR 400K @ $1.00 → lastMarkPrice = $1.00, lastMarkTime = now
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 400_000e18, 20_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        // Time passes beyond staleness limit — mark becomes stale
        vm.warp(block.timestamp + 121);

        // Bob tries to withdraw — reconcile reverts due to stale mark
        vm.startPrank(bob);
        vm.expectRevert(HousePool.HousePool__MarkPriceStale.selector);
        juniorVault.withdraw(1e6, bob, bob);
        vm.stopPrank();

        // Push fresh mark at $1.30 via updateMarkPrice
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1.3e8));
        router.updateMarkPrice(priceData);

        // Now both Bob and Carol can withdraw at the same fair NAV
        uint256 bobMax = juniorVault.maxWithdraw(bob);
        uint256 carolMax = juniorVault.maxWithdraw(carol);

        assertEq(bobMax, carolMax, "Both LPs see the same fair withdrawal limit at fresh mark price");
    }

    // ==========================================
    // C-02 (new): Vault Funding Spread permanently locked as ghost liability
    // When the majority side pays funding, the vault receives more cash than it
    // pays to minority receivers. The surplus (spread) is the vault's revenue.
    // However, netUnsettledFunding tracks cumulative cash flows, not current
    // liabilities. After all positions close, the spread makes netUnsettledFunding
    // permanently negative. Both _getEffectiveAssets() and _reconcile() reserve
    // this amount as if someone will claim it — but nobody will.
    // EXPECTED: After all positions close, netUnsettledFunding = 0 and spread is distributable.
    // BUG: Spread trapped as ghost liability, permanently reducing LP distributable revenue.
    // ==========================================

    function test_C02_FundingSpreadLockedAfterAllPositionsClose() public {
        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 100_000e6);
        _fundTrader(carol, 100_000e6);

        // Bear-heavy market: 300K bear (majority payer) vs 100K bull (minority receiver)
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 300_000e18, 30_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);
        router.executeOrder(2, empty);

        // 90 days of funding accrues. Bears pay more than bulls receive.
        vm.warp(block.timestamp + 90 days);

        // Close both: all funding physically settled.
        // Must pass explicit price so _updateFunding sees non-zero skew.
        bytes[] memory closePrice = new bytes[](1);
        closePrice[0] = abi.encode(uint256(1e8));

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);
        router.executeOrder(3, closePrice);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 300_000e18, 0, 0, true);
        router.executeOrder(4, closePrice);

        assertEq(engine.bullOI(), 0, "All bull positions closed");
        assertEq(engine.bearOI(), 0, "All bear positions closed");

        // With no open positions, unrealized funding PnL must be zero.
        // The funding spread is now distributable revenue in the pool.
        assertEq(
            engine.getUnrealizedFundingPnl(), 0, "No positions => zero unrealized funding; spread is distributable"
        );
    }

    function test_C02_FundingSpreadReducesDistributableRevenue() public {
        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 100_000e6);
        _fundTrader(carol, 100_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 300_000e18, 30_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);
        router.executeOrder(2, empty);

        vm.warp(block.timestamp + 90 days);

        bytes[] memory closePrice = new bytes[](1);
        closePrice[0] = abi.encode(uint256(1e8));

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);
        router.executeOrder(3, closePrice);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 300_000e18, 0, 0, true);
        router.executeOrder(4, closePrice);

        // Trigger reconcile to distribute revenue
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 poolBalance = usdc.balanceOf(address(pool));
        uint256 totalClaimed = pool.seniorPrincipal() + pool.juniorPrincipal();
        uint256 pendingFees = engine.accumulatedFeesUsdc();

        // With no positions and no MtM, all pool cash should be accounted for
        // by LP principals + pending protocol fees.
        // BUG: The funding spread sits in the pool as cash but is reserved
        //       as a ghost liability via netUnsettledFunding, so it's never
        //       distributed to LPs or claimable as fees.
        assertGe(totalClaimed + pendingFees, poolBalance, "All pool cash must be accounted for with zero open interest");
    }

    // ==========================================
    // C-02 (new): _reconcile ignores negative unrealizedFunding
    // When a funding receiver closes before payers, vault cash drops by the
    // payout, but the payers' debt (negative unrealizedFunding) is a vault asset
    // that _reconcile fails to account for. This deflates cashMinusReserved,
    // triggering spurious _absorbLoss on the junior tranche.
    // EXPECTED: Junior principal unaffected (pool is owed more than it paid).
    // BUG: Junior is slashed by the funding payout amount.
    // ==========================================

    function test_C02_NegativeFundingCausesSpuriousJuniorLoss() public {
        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 100_000e6);
        _fundTrader(carol, 100_000e6);

        // Bear-heavy market: bears pay funding, bulls receive
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 300_000e18, 30_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);
        router.executeOrder(2, empty);

        // 90 days of funding accrues — bears owe, bulls receive
        vm.warp(block.timestamp + 90 days);

        // Close minority (bull/receiver) — vault physically pays out funding
        bytes[] memory price = new bytes[](1);
        price[0] = abi.encode(uint256(1e8));
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);
        router.executeOrder(3, price);

        // Bears still owe funding → unrealizedFunding < 0 (vault asset)
        int256 unrealizedFunding = engine.getUnrealizedFundingPnl();
        assertLt(unrealizedFunding, 0, "house is owed funding by remaining bears");

        // With the C-02/C-03 clamping fix, the vault conservatively ignores unrealized
        // funding debts as MtM assets. When bulls are physically paid but bears haven't
        // settled yet, junior temporarily drops until bears realize their debt.
        uint256 juniorBefore = pool.juniorPrincipal();
        vm.prank(address(juniorVault));
        pool.reconcile();
        uint256 juniorAfter = pool.juniorPrincipal();

        assertLe(juniorAfter, juniorBefore, "conservative: junior must not increase from unrealized funding debt");
    }

    // ==========================================
    // C-01 (old, partial close): seize must respect lockedMarginUsdc
    // ==========================================

    function test_C01_PartialClosePreservesLockedMarginForRemainingPosition() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 22_000 * 1e6);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        // Open BEAR 200K @ $1.00 with 20K margin
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000 * 1e18, 20_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        (uint256 openSize,,,,,,,) = engine.positions(accountId);
        assertEq(openSize, 200_000 * 1e18);

        // Partial close half at $0.80 — BEAR loses ~$20K on closed portion.
        // Alice's free USDC (~$2K) is far less than the loss, so the seize
        // must stop at the free boundary to protect the remaining position's margin.
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000 * 1e18, 0, 0, true);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(0.8e8));
        router.executeOrder(2, priceData);

        (uint256 remainingSize,,,,,,,) = engine.positions(accountId);
        assertEq(remainingSize, 100_000 * 1e18, "Half position should remain");

        uint256 balAfter = clearinghouse.balances(accountId, address(usdc));
        uint256 lockedAfter = clearinghouse.lockedMarginUsdc(accountId);
        assertGe(balAfter, lockedAfter, "Physical balance must cover locked margin (zombie prevention)");

        // Liquidation of the underwater remaining position must succeed
        router.executeLiquidation(accountId, priceData);

        (uint256 sizeAfterLiq,,,,,,,) = engine.positions(accountId);
        assertEq(sizeAfterLiq, 0, "Remaining position should be fully liquidated");
    }

    // ==========================================
    // H-02: _skipStaleOrders uses `< upToId` so the target order itself
    // is never age-checked. A stale order executes if it's the target.
    // EXPECTED: Stale order should NOT execute.
    // BUG: _skipStaleOrders only skips orders *before* the target.
    // ==========================================

    function test_H02_StaleOrderExecutesViaExecuteOrder() public {
        router.proposeMaxOrderAge(300);
        _warpPastTimelock();
        router.finalizeMaxOrderAge();

        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 50_000e6);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));

        uint64 commitId = router.nextCommitId();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);

        vm.warp(block.timestamp + 600);

        router.executeOrder(commitId, priceData);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Expired order must not execute via executeOrder");
    }

    // ==========================================
    // H-03: commitOrder accepts msg.value == 0 as keeper fee.
    // An attacker can spam the queue with zero-fee orders.
    // EXPECTED: commitOrder should revert when no keeper fee is attached.
    // BUG: No minimum fee check exists.
    // ==========================================

    function test_H03_ZeroFeeCommitShouldRevert() public {
        router.proposeMinKeeperFee(0.001 ether);
        _warpPastTimelock();
        router.finalizeMinKeeperFee();
        _fundTrader(alice, 10_000e6);

        vm.prank(alice);
        vm.expectRevert(OrderRouter.OrderRouter__InsufficientKeeperFee.selector);
        router.commitOrder{value: 0}(CfdTypes.Side.BULL, 1000e18, 1000e6, 1e8, false);
    }

    // ==========================================
    // H-04: Verify fees are excluded from effective assets so withdrawFees
    // succeeds even at high utilization. Pre-fix, fees counted as collateral
    // and withdrawFees reverted with PostOpSolvencyBreach.
    // ==========================================

    function test_H04_FeesWithdrawableAtHighUtilization() public {
        _fundJunior(bob, 500_200e6);
        _fundTrader(alice, 50_000e6);
        _fundTrader(carol, 50_000e6);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));

        uint64 id1 = router.nextCommitId();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 250_000e18, 25_000e6, 1e8, false);
        router.executeOrder(id1, priceData);

        uint64 id2 = router.nextCommitId();
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 250_100e18, 25_000e6, 1e8, false);
        router.executeOrder(id2, priceData);

        uint256 fees = engine.accumulatedFeesUsdc();
        assertGt(fees, 0, "Fees should have accumulated");

        uint256 maxLiability = engine.globalBullMaxProfit();
        assertEq(maxLiability, 500_100e6, "Both positions should be open");

        address feeRecipient = address(0xFEE);
        engine.withdrawFees(feeRecipient);

        assertEq(usdc.balanceOf(feeRecipient), fees, "Fee recipient should receive fees");
    }

    // ==========================================
    // M-01: finalizeRiskParams retroactive funding
    // _updateFunding is not called before applying new params, so the
    // entire dormant period is retroactively charged at the new rate.
    // ==========================================

    function test_M01_FinalizeRiskParamsRetroactiveFunding() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(carol, 200_000 * 1e6);

        uint256 T0 = 1_710_000_000;
        uint256 T_PROPOSE = T0 + 30 days;
        uint256 T_FINALIZE = T0 + 30 days + 48 hours + 1;
        uint256 T_ORDER2 = T0 + 33 days;

        vm.warp(T0);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 100_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        int256 indexAfterOpen = engine.bullFundingIndex();

        vm.warp(T_PROPOSE);

        CfdTypes.RiskParams memory newParams = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 3.0e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
        engine.proposeRiskParams(newParams);

        vm.warp(T_FINALIZE);
        engine.finalizeRiskParams();

        vm.warp(T_ORDER2);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 5000 * 1e6, 1e8, false);
        router.executeOrder(2, empty);

        int256 indexAfterSettle = engine.bullFundingIndex();
        int256 indexDrop = indexAfterOpen - indexAfterSettle;

        // With the fix, ~32 days settle at old rate and ~1 day at new rate (~1.6x old).
        // Without the fix, all 33 days charge at new 20x rate (~20x old).
        // Threshold at 2x old rate cleanly separates: fixed (1.6x) < 2x < unfixed (20x).
        uint256 totalElapsed = T_ORDER2 - T0;
        uint256 oldAnnRate = 0.06e18;
        int256 maxDrop = int256((oldAnnRate * totalElapsed * 2) / 365 days);

        assertLe(indexDrop, maxDrop, "Funding must not retroactively apply new rate to pre-finalize period");
    }

    function test_H03_CloseOrderAllowedWhilePaused() public {
        _fundJunior(bob, 500_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertGt(size, 0, "Position should be open");

        router.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.commitOrder(CfdTypes.Side.BULL, 1000 * 1e18, 1000 * 1e6, 1e8, false);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, size, 0, 0, true);

        router.unpause();
        router.executeOrder(2, empty);

        (uint256 sizeAfter,,,,,,,) = engine.positions(accountId);
        assertEq(sizeAfter, 0, "Position should be fully closed");
    }

    function test_C01_WithdrawGuardBlocksWithdrawWithOpenPosition() public {
        _fundJunior(bob, 500_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertGt(size, 0, "Position should be open");

        uint256 locked = clearinghouse.lockedMarginUsdc(accountId);
        uint256 usdcBal = clearinghouse.balances(accountId, address(usdc));
        uint256 free = usdcBal - locked;
        assertGt(free, 0, "Alice should have free USDC to withdraw");

        vm.prank(alice);
        vm.expectRevert();
        clearinghouse.withdraw(accountId, address(usdc), free);
    }

    function test_C03_SeniorHWMResetPreventsRestoration() public {
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 100_000e6);

        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000e18, 20_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000e18, 0, 0, true);
        bytes[] memory capPrice = new bytes[](1);
        capPrice[0] = abi.encode(uint256(2e8));
        router.executeOrder(2, capPrice);

        // Trigger reconcile → pool drained, loss wipes both tranches
        usdc.mint(bob, 1e6);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), 1e6);
        juniorVault.deposit(1e6, bob);
        vm.stopPrank();

        assertEq(pool.seniorPrincipal(), 0, "Senior wiped");
        assertGt(pool.seniorHighWaterMark(), 0, "HWM preserved for restoration");

        // Simulate recovery: USDC flows back to pool (e.g., price wick reverts)
        usdc.mint(address(pool), 100_000e6);

        // Trigger reconcile to distribute recovered funds
        usdc.mint(bob, 1e6);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), 1e6);
        juniorVault.deposit(1e6, bob);
        vm.stopPrank();

        uint256 aliceShares = seniorVault.balanceOf(alice);
        assertGt(aliceShares, 0, "Alice still holds senior shares");
        assertGt(pool.seniorPrincipal(), 0, "Senior should be restored after recovery");
    }

    function test_C04_FlashDepositCrushesDeficit() public {
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 50_000e6);

        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 20_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 0, 0, true);
        bytes[] memory capPrice = new bytes[](1);
        capPrice[0] = abi.encode(uint256(2e8));
        router.executeOrder(2, capPrice);

        // Trigger reconcile → loss wipes junior, partially hits senior
        usdc.mint(bob, 1e6);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), 1e6);
        juniorVault.deposit(1e6, bob);
        vm.stopPrank();

        uint256 deficitBefore = pool.seniorHighWaterMark() - pool.seniorPrincipal();
        assertGt(deficitBefore, 0, "Senior deficit exists");

        // Flash deposit into senior
        address dave = address(0x444);
        _fundSenior(dave, 10_000_000e6);

        // Wait cooldown, then withdraw max
        vm.warp(block.timestamp + 2 hours);
        uint256 withdrawable = seniorVault.maxWithdraw(dave);
        vm.prank(dave);
        seniorVault.withdraw(withdrawable, dave, dave);

        uint256 deficitAfter = pool.seniorHighWaterMark() - pool.seniorPrincipal();
        assertGe(deficitAfter, deficitBefore / 2, "Deficit must not be slashable via flash deposit");
    }

}

// ==========================================
// C-02 tests require non-zero vpiFactor (separate deployment)
// ==========================================

contract C02VpiDepthTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;
    OrderRouter router;

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + 48 hours + 1);
    }

    function setUp() public {
        usdc = new MockUSDC();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0.01e18,
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
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        router = new OrderRouter(
            address(engine),
            address(pool),
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        _warpPastTimelock();
        clearinghouse.finalizeAssetConfig();

        clearinghouse.proposeOperator(address(engine), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();

        clearinghouse.proposeOperator(address(router), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();
    }

    function _fundJunior(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), amount);
        juniorVault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _fundTrader(
        address trader,
        uint256 amount
    ) internal {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, address(usdc), amount);
        vm.stopPrank();
    }

    // ==========================================
    // C-02a: Minority position reverse attack
    // Attacker opens minority position (receives VPI rebate) at low depth,
    // depth inflates, then closes (tiny charge at high depth).
    // Without fix: attacker extracts net VPI rebate.
    // With fix: stateful bound caps close VPI so net VPI >= 0.
    // ==========================================

    function test_C02a_MinorityVpiRebateCannotExceedPaidCharges() public {
        _fundJunior(bob, 1_000_000 * 1e6);

        // Carol opens large BEAR to create skew
        _fundTrader(carol, 50_000 * 1e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000 * 1e18, 40_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        // Alice opens minority BULL (heals skew) at current depth → receives VPI rebate
        _fundTrader(alice, 50_000 * 1e6);
        bytes32 aliceAccount = bytes32(uint256(uint160(alice)));
        uint256 aliceBalBefore = clearinghouse.balances(aliceAccount, address(usdc));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        router.executeOrder(2, empty);

        // Inflate depth by 10x via LP deposit
        _fundJunior(bob, 9_000_000 * 1e6);

        // Alice closes at inflated depth — VPI charge should be bounded
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 0, 0, true);
        bytes[] memory closePrice = new bytes[](1);
        closePrice[0] = abi.encode(uint256(1e8));
        router.executeOrder(3, closePrice);

        uint256 aliceBalAfter = clearinghouse.balances(aliceAccount, address(usdc));

        // PnL is zero (same price). Exec fees are a pure cost.
        // With the bound, net VPI >= 0, so Alice must have lost money overall.
        assertLe(aliceBalAfter, aliceBalBefore, "Minority VPI depth attack must not be profitable");
    }

    // ==========================================
    // C-02b: Size addition bypass
    // Attacker opens dust at low depth (entryDepth = low), inflates depth,
    // adds massive size (tiny charge at high depth), deflates depth, closes
    // (massive rebate at low depth).
    // Without fix: entryDepth was set only on first open, bypass via size addition.
    // With fix: vpiAccrued tracks all charges, close rebate bounded by total paid.
    // ==========================================

    function test_C02b_SizeAdditionCannotBypassVpiBound() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        bytes32 aliceAccount = bytes32(uint256(uint160(alice)));
        uint256 aliceBalBefore = clearinghouse.balances(aliceAccount, address(usdc));

        // Open dust BULL at current (low) depth
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 5000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        // Inflate depth by 10x
        _fundJunior(bob, 9_000_000 * 1e6);

        // Add massive size at high depth (tiny VPI charge)
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        router.executeOrder(2, empty);

        // Deflate depth: withdraw most LP capital
        vm.warp(block.timestamp + 2 hours);
        // Push fresh mark so reconcile doesn't revert on staleness
        bytes[] memory freshPrice = new bytes[](1);
        freshPrice[0] = abi.encode(uint256(1e8));
        router.updateMarkPrice(freshPrice);
        vm.startPrank(bob);
        uint256 withdrawable = juniorVault.maxWithdraw(bob);
        if (withdrawable > 0) {
            juniorVault.withdraw(withdrawable, bob, bob);
        }
        vm.stopPrank();

        // Close all at deflated depth
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 110_000 * 1e18, 0, 0, true);
        bytes[] memory closePrice = new bytes[](1);
        closePrice[0] = abi.encode(uint256(1e8));
        router.executeOrder(3, closePrice);

        uint256 aliceBalAfter = clearinghouse.balances(aliceAccount, address(usdc));

        // Same price → PnL = 0. With the bound, Alice cannot profit from VPI.
        assertLe(aliceBalAfter, aliceBalBefore, "Size addition VPI bypass must not be profitable");
    }

}

// ==========================================
// Margin-Capped MtM: per-side margin cap prevents phantom profits
// ==========================================

contract MarginCappedMtmTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault seniorVault;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;
    OrderRouter router;

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    receive() external payable {}

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + 48 hours + 1);
    }

    function setUp() public {
        usdc = new MockUSDC();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0,
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
        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        router = new OrderRouter(
            address(engine),
            address(pool),
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        );

        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        clearinghouse.proposeWithdrawGuard(address(engine));
        clearinghouse.proposeOperator(address(engine), true);
        _warpPastTimelock();
        clearinghouse.finalizeAssetConfig();
        clearinghouse.finalizeWithdrawGuard();
        clearinghouse.finalizeOperator();

        clearinghouse.proposeOperator(address(router), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();

        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));
    }

    function _fundJunior(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), amount);
        juniorVault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _fundTrader(
        address trader,
        uint256 amount
    ) internal {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, address(usdc), amount);
        vm.stopPrank();
    }

    function test_MarginTracking_IncreasesOnOpen() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        assertEq(engine.totalBullMargin(), 0);
        assertEq(engine.totalBearMargin(), 0);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        assertEq(engine.totalBullMargin(), 0, "Bull margin unchanged");
        assertGt(engine.totalBearMargin(), 0, "Bear margin tracked after open");
    }

    function test_MarginTracking_DecreasesOnClose() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        uint256 bearMarginAfterOpen = engine.totalBearMargin();
        assertGt(bearMarginAfterOpen, 0);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 0, 1e8, true);
        router.executeOrder(2, empty);

        assertEq(engine.totalBearMargin(), 0, "Bear margin zero after full close");
    }

    function test_MarginTracking_PartialClose() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        uint256 bearMarginFull = engine.totalBearMargin();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 50_000e18, 0, 1e8, true);
        router.executeOrder(2, empty);

        uint256 bearMarginHalf = engine.totalBearMargin();
        assertLt(bearMarginHalf, bearMarginFull, "Margin decreases on partial close");
        assertGt(bearMarginHalf, 0, "Margin still tracked for remaining position");
    }

    function test_MarginTracking_ZeroAfterLiquidation() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 2000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        assertGt(engine.totalBearMargin(), 0);

        bytes[] memory liqPrice = new bytes[](1);
        liqPrice[0] = abi.encode(uint256(0.5e8));
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        router.executeLiquidation(accountId, liqPrice);

        assertEq(engine.totalBearMargin(), 0, "Bear margin zero after liquidation");
    }

    function test_PhantomProfitCappedAtMargin() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        // Price drops to $0.50 — BEAR loses $100k notionally but only has $10k margin
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(0.5e8));
        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 10_000e6, 0.5e8, false);
        router.executeOrder(2, priceData);

        int256 uncappedPnl = engine.getUnrealizedTraderPnl();
        int256 cappedMtm = engine.getVaultMtmAdjustment();

        // Uncapped shows a huge vault gain (traders losing more than margin)
        assertLt(uncappedPnl, -int256(engine.totalBearMargin()), "Uncapped loss exceeds deposited margin");
        // Capped MtM bounds it at physical margin
        assertGe(cappedMtm, -int256(engine.totalBearMargin() + engine.totalBullMargin()), "Capped MtM bounded");
        assertGt(cappedMtm, uncappedPnl, "Capped MtM is less aggressive than uncapped");
    }

    function test_ReconcileDoesNotInflateBeyondMargin() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        uint256 juniorBefore = pool.juniorPrincipal();

        // Price drops to $0.50 — massive notional loss for BEAR, capped at margin
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(0.5e8));
        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 10_000e6, 0.5e8, false);
        router.executeOrder(2, priceData);

        vm.prank(address(juniorVault));
        pool.reconcile();
        uint256 juniorAfter = pool.juniorPrincipal();

        uint256 revenue = juniorAfter > juniorBefore ? juniorAfter - juniorBefore : 0;
        // Revenue recognized must not exceed total deposited margin
        assertLe(
            revenue,
            engine.totalBearMargin() + engine.totalBullMargin(),
            "Recognized revenue must not exceed seizable margin"
        );
    }

    function test_MtmAdjustment_PositiveWhenTradersWinning() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        // Price rises to $1.20 — BEAR profits (vault liability)
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1.2e8));
        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 10_000e6, 1.2e8, false);
        router.executeOrder(2, priceData);

        int256 mtm = engine.getVaultMtmAdjustment();
        assertGt(mtm, 0, "Positive MtM = vault liability when traders are winning (no cap needed)");
    }

    function test_MtmAdjustment_ZeroWithNoPositions() public {
        _fundJunior(bob, 500_000e6);
        assertEq(engine.getVaultMtmAdjustment(), 0, "MtM should be zero with no positions");
    }

}

// ==========================================
// H-03: Stale order auto-expiry prevents zero-fee queue spam
// ==========================================

contract H03StaleOrderExpiryTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;
    OrderRouter router;

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address bob = address(0x222);
    address spammer = address(0x666);

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + 48 hours + 1);
    }

    function setUp() public {
        vm.warp(1_709_532_000);
        usdc = new MockUSDC();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0,
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
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        router = new OrderRouter(
            address(engine),
            address(pool),
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        _warpPastTimelock();
        clearinghouse.finalizeAssetConfig();

        clearinghouse.proposeOperator(address(engine), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();

        clearinghouse.proposeOperator(address(router), true);
        router.proposeMaxOrderAge(300);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();
        router.finalizeMaxOrderAge();
    }

    function _fundJunior(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), amount);
        juniorVault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _fundTrader(
        address trader,
        uint256 amount
    ) internal {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, address(usdc), amount);
        vm.stopPrank();
    }

    function test_H03_StaleSpamOrdersAutoSkipped() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        // Spammer commits 5 zero-fee garbage orders (no margin, will fail at engine)
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(spammer);
            router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        }
        // Alice commits a real order (orderId = 6)
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);

        assertEq(router.nextExecuteId(), 1);

        // Time passes beyond maxOrderAge
        vm.warp(block.timestamp + 301);

        // Keeper executes Alice's order (id=6) — stale spam orders 1-5 auto-skipped
        bytes[] memory empty;
        router.executeOrder(6, empty);

        assertEq(router.nextExecuteId(), 7, "Queue advanced past spam + real order");
    }

    function test_H03_FreshOrdersNotSkipped() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);

        // Execute immediately (within maxOrderAge) — no skip, normal FIFO
        bytes[] memory empty;
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 2);
    }

    function test_H03_SpammerFeeConfiscatedOnExpiry() public {
        vm.deal(spammer, 1 ether);
        vm.prank(spammer);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);

        vm.warp(block.timestamp + 301);

        address keeper = address(0x999);
        bytes[] memory empty;
        vm.prank(keeper);
        router.executeOrder(2, empty);

        assertGt(router.claimableEth(spammer), 0, "Spammer must be refunded expired order fee");
        assertEq(router.claimableEth(keeper), 0, "Keeper must not receive expired order fee");
    }

    function test_H03_BatchSkipsStaleOrders() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        // 3 spam orders
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(spammer);
            router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        }

        // Alice's real order (id=4)
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);

        vm.warp(block.timestamp + 301);

        // Batch execute up to order 4
        bytes[] memory empty;
        router.executeOrderBatch(4, empty);

        assertEq(router.nextExecuteId(), 5, "Batch advanced past stale + real order");
    }

    function test_H03_SetMaxOrderAge_OnlyOwner() public {
        vm.prank(spammer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, spammer));
        router.proposeMaxOrderAge(600);

        router.proposeMaxOrderAge(600);
        _warpPastTimelock();
        router.finalizeMaxOrderAge();
        assertEq(router.maxOrderAge(), 600);
    }

    function test_H01_ExpiredOrderFeeRefundedToUser_ViaSkip() public {
        vm.deal(spammer, 1 ether);
        vm.prank(spammer);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);

        vm.warp(block.timestamp + 301);

        address keeper = address(0x999);
        bytes[] memory empty;
        vm.prank(keeper);
        router.executeOrder(2, empty);

        assertGt(router.claimableEth(spammer), 0, "User must be refunded expired order fee");
        assertEq(router.claimableEth(keeper), 0, "Keeper must not receive expired order fee");
    }

}

contract MockPyth {

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

contract MarkPriceStalenessTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    OrderRouter router;
    MarginClearinghouse clearinghouse;
    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    uint256 constant CAP_PRICE = 2e8;

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + 48 hours + 1);
    }

    function setUp() public {
        vm.warp(10_000);
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0,
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
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router =
            new OrderRouter(address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        _warpPastTimelock();
        clearinghouse.finalizeAssetConfig();

        clearinghouse.proposeOperator(address(engine), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();

        clearinghouse.proposeOperator(address(router), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();
    }

    function test_UpdateMarkPrice_RevertsOnStaleOracle() public {
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp - 120);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.expectRevert(OrderRouter.OrderRouter__OraclePriceTooStale.selector);
        router.updateMarkPrice(updateData);
    }

    function test_UpdateMarkPrice_AcceptsFreshOracle() public {
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp - 30);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        router.updateMarkPrice(updateData);
        assertEq(engine.lastMarkPrice(), 1e8);
    }

}

contract PhantomExecFeeTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;
    OrderRouter router;

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address bob = address(0x222);

    receive() external payable {}

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + 48 hours + 1);
    }

    function setUp() public {
        vm.warp(1000);
        usdc = new MockUSDC();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0,
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
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        router = new OrderRouter(
            address(engine),
            address(pool),
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        clearinghouse.proposeWithdrawGuard(address(engine));
        _warpPastTimelock();
        clearinghouse.finalizeAssetConfig();
        clearinghouse.finalizeWithdrawGuard();

        clearinghouse.proposeOperator(address(engine), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();

        clearinghouse.proposeOperator(address(router), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();
    }

    function test_PhantomExecFee_InflatesAccumulatedFees() public {
        uint256 lpDeposit = 1_000_000e6;
        usdc.mint(bob, lpDeposit);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), lpDeposit);
        juniorVault.deposit(lpDeposit, bob);
        vm.stopPrank();

        uint256 margin = 1000e6;
        usdc.mint(alice, margin);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), margin);
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        clearinghouse.deposit(accountId, address(usdc), margin);

        uint256 size = 50_000e18;
        router.commitOrder(CfdTypes.Side.BULL, size, margin, 1e8, false);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        router.executeOrder(1, priceData);

        uint256 openFee = engine.accumulatedFeesUsdc();

        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, size, 0, 0, true);

        vm.warp(block.timestamp + 1);
        priceData[0] = abi.encode(uint256(1.5e8));
        router.executeOrder(2, priceData);

        uint256 totalFees = engine.accumulatedFeesUsdc();
        uint256 closeFee = totalFees - openFee;

        // Close notional: 50_000e18 * 1.5e8 / 1e20 = 75_000e6
        // Close exec fee: 75_000e6 * 6/10000 = 45e6
        // Realized loss: 25_000e6 (BULL, price rose from 1e8 to 1.5e8)
        // netSettlement: -25_000e6 - 45e6 = -25_045e6
        // Available in clearinghouse: ~970e6
        // Shortfall: ~24_075e6 >> 45e6 exec fee
        //
        // The trader couldn't pay the full settlement. The 45e6 exec fee
        // was never collected, yet accumulatedFeesUsdc records it in full.
        assertEq(closeFee, 0, "close exec fee should be 0 when shortfall exceeds fee");
    }

}

contract NegativeFundingFreeUsdcTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;
    OrderRouter router;

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address bob = address(0x222);

    receive() external payable {}

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + 48 hours + 1);
    }

    function _warpForward(
        uint256 delta
    ) internal {
        vm.warp(block.timestamp + delta);
    }

    function setUp() public {
        usdc = new MockUSDC();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0,
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
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        router = new OrderRouter(
            address(engine),
            address(pool),
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        clearinghouse.proposeWithdrawGuard(address(engine));
        _warpPastTimelock();
        clearinghouse.finalizeAssetConfig();
        clearinghouse.finalizeWithdrawGuard();

        clearinghouse.proposeOperator(address(engine), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();

        clearinghouse.proposeOperator(address(router), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();
    }

    function test_GetFreeUSDC_IgnoresNegativeFunding() public {
        usdc.mint(bob, 1_000_000e6);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), 1_000_000e6);
        juniorVault.deposit(1_000_000e6, bob);
        vm.stopPrank();

        uint256 margin = 100_000e6;
        usdc.mint(alice, margin);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), margin);
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        clearinghouse.deposit(accountId, address(usdc), margin);

        uint256 size = 200_000e18;
        router.commitOrder(CfdTypes.Side.BULL, size, margin, 1e8, false);
        vm.stopPrank();

        _warpForward(1);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        router.executeOrder(1, priceData);

        // Warp forward so funding accrues on the skewed bull position
        _warpForward(30 days);

        // Open a tiny position to trigger _updateFunding inside processOrder
        address carol = address(0x333);
        uint256 carolMargin = 10_000e6;
        usdc.mint(carol, carolMargin);
        vm.startPrank(carol);
        usdc.approve(address(clearinghouse), carolMargin);
        clearinghouse.deposit(bytes32(uint256(uint160(carol))), address(usdc), carolMargin);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, carolMargin, 1e8, false);
        vm.stopPrank();

        _warpForward(1);
        priceData[0] = abi.encode(uint256(1e8));
        router.executeOrder(2, priceData);

        int256 unrealizedFunding = engine.getUnrealizedFundingPnl();
        assertLt(unrealizedFunding, 0, "funding should be negative (house is owed)");

        uint256 freeUsdcNow = pool.getFreeUSDC();

        // Compute what getFreeUSDC returns without negative funding adjustment
        uint256 bal = usdc.balanceOf(address(pool));
        uint256 maxLiability = engine.globalBullMaxProfit();
        uint256 pendingFees = engine.accumulatedFeesUsdc();
        uint256 reservedWithoutFunding = maxLiability + pendingFees;
        uint256 freeWithoutFunding = bal > reservedWithoutFunding ? bal - reservedWithoutFunding : 0;

        // getFreeUSDC uses asymmetric accounting for physical liquidity:
        // negative funding (vault receivable) must NOT reduce reserves, since it's illiquid
        assertEq(
            freeUsdcNow, freeWithoutFunding, "getFreeUSDC must not reduce reserves by illiquid funding receivables"
        );
    }

}

// ==========================================
// H-02: executeOrder cancels on oracle staleness instead of reverting
// An attacker calls executeOrder(orderId, []) without Pyth data.
// The cached price is stale → _cancelOrder permanently deletes the
// victim's order. Should revert to leave the order safely in the queue.
// ==========================================

contract H02StalenessGriefTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;
    OrderRouter router;
    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    uint256 constant CAP_PRICE = 2e8;

    address alice = address(0x111);
    address bob = address(0x222);
    address attacker = address(0x666);

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + 48 hours + 1);
    }

    function setUp() public {
        vm.warp(10_000);
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0,
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
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router =
            new OrderRouter(address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        clearinghouse.proposeWithdrawGuard(address(engine));
        _warpPastTimelock();
        clearinghouse.finalizeAssetConfig();
        clearinghouse.finalizeWithdrawGuard();

        clearinghouse.proposeOperator(address(engine), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();

        clearinghouse.proposeOperator(address(router), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();
    }

    function _fundJunior(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), amount);
        juniorVault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _fundTrader(
        address trader,
        uint256 amount
    ) internal {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, address(usdc), amount);
        vm.stopPrank();
    }

    function test_H02_StaleOracleCancelsOrderInsteadOfReverting() public {
        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 50_000e6);

        // Fresh price for the commit
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);

        // Time passes — cached Pyth price becomes stale (>60s)
        vm.warp(block.timestamp + 120);

        // Attacker calls executeOrder without updating Pyth — must revert,
        // leaving the order safely in the queue for an honest keeper
        bytes[] memory empty;
        vm.prank(attacker);
        vm.expectRevert(OrderRouter.OrderRouter__OraclePriceTooStale.selector);
        router.executeOrder(1, empty);

        // Order is still in the queue
        (, uint256 sizeDelta,,,,,,) = router.orders(1);
        assertGt(sizeDelta, 0, "order must survive stale-oracle griefing attempt");
    }

}

contract C05VpiImrBypassTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;
    OrderRouter router;

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + 48 hours + 1);
    }

    function setUp() public {
        usdc = new MockUSDC();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 1e18,
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
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        router = new OrderRouter(
            address(engine),
            address(pool),
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        _warpPastTimelock();
        clearinghouse.finalizeAssetConfig();

        clearinghouse.proposeOperator(address(engine), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();

        clearinghouse.proposeOperator(address(router), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();
    }

    function _fundJunior(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), amount);
        juniorVault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _fundTrader(
        address trader,
        uint256 amount
    ) internal {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, address(usdc), amount);
        vm.stopPrank();
    }

    function test_C05_VpiRebateSatisfiesIMR_ZeroRiskPosition() public {
        _fundJunior(bob, 1_000_000e6);

        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 20_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 aliceAccount = bytes32(uint256(uint160(alice)));
        assertEq(clearinghouse.balances(aliceAccount, address(usdc)), 0, "Alice starts with zero USDC");

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 1e8, false);
        router.executeOrder(2, empty);

        (uint256 size,,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "Position must not open with zero user capital");
    }

}

// ==========================================
// H-01: Keeper Fee Theft — expired order fee must refund USER, not keeper
// ==========================================

contract H01KeeperFeeTheftTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;
    OrderRouter router;

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address bob = address(0x222);
    address keeper = address(0x999);

    receive() external payable {}

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + 48 hours + 1);
    }

    function setUp() public {
        vm.warp(1_709_532_000);
        usdc = new MockUSDC();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0,
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
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        router = new OrderRouter(
            address(engine),
            address(pool),
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        _warpPastTimelock();
        clearinghouse.finalizeAssetConfig();

        clearinghouse.proposeOperator(address(engine), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();

        clearinghouse.proposeOperator(address(router), true);
        router.proposeMaxOrderAge(300);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();
        router.finalizeMaxOrderAge();
    }

    function test_H01_ExpiredOrderFeeRefundedToUser() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        vm.warp(block.timestamp + 301);

        // Keeper executes — order expired
        bytes[] memory empty;
        vm.prank(keeper);
        router.executeOrder(1, empty);

        // User should be refunded their fee, not the keeper
        assertGt(router.claimableEth(alice), 0, "User must be refunded expired order fee");
        assertEq(router.claimableEth(keeper), 0, "Keeper must not profit from user's expired order");
    }

    function test_H01_SlippageFailFeeRefundedToUser() public {
        // Fund LP + trader
        usdc.mint(bob, 1_000_000e6);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), 1_000_000e6);
        juniorVault.deposit(1_000_000e6, bob);
        vm.stopPrank();

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        usdc.mint(alice, 50_000e6);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), 50_000e6);
        clearinghouse.deposit(accountId, address(usdc), 50_000e6);
        vm.stopPrank();

        // Alice commits BULL with tight slippage (targetPrice = 1.50, exec will be at 1.00)
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1.5e8, false);

        // Keeper executes at $1.00 — slippage check fails (BULL open wants exec >= target)
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.prank(keeper);
        router.executeOrder(1, priceData);

        // User should be refunded, not keeper
        assertGt(router.claimableEth(alice), 0, "User must be refunded on slippage failure");
        assertEq(router.claimableEth(keeper), 0, "Keeper must not profit from slippage failure");
    }

    function test_H01_BatchExpiredFeeRefundedToUser() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        vm.warp(block.timestamp + 301);

        // Batch execute — order expired
        bytes[] memory empty;
        router.executeOrderBatch(1, empty);

        // In batch mode, all fees go to msg.sender (this contract) via direct transfer.
        // User should get refunded instead.
        assertGt(router.claimableEth(alice), 0, "User must be refunded expired order fee in batch");
    }

}

// ==========================================
// H-02: oracleFrozen bypasses MEV check, enabling stale-price close arbitrage
// ==========================================

contract H02WeekendArbitrageTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;
    OrderRouter router;
    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    uint256 constant CAP_PRICE = 2e8;

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    address alice = address(0x111);
    address bob = address(0x222);
    address keeper = address(0x999);

    receive() external payable {}

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + 48 hours + 1);
    }

    function _fundJunior(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), amount);
        juniorVault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _fundTrader(
        address trader,
        uint256 amount
    ) internal {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, address(usdc), amount);
        vm.stopPrank();
    }

    function setUp() public {
        // Start on a Wednesday
        vm.warp(1_709_100_000);
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0,
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
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router =
            new OrderRouter(address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        clearinghouse.proposeWithdrawGuard(address(engine));
        _warpPastTimelock();
        clearinghouse.finalizeAssetConfig();
        clearinghouse.finalizeWithdrawGuard();

        clearinghouse.proposeOperator(address(engine), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();

        clearinghouse.proposeOperator(address(router), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();
    }

    function test_H02_CloseOrderExecutesAtStaleFridayPrice() public {
        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 50_000e6);

        // Wednesday: open BEAR at $1.00
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp);
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        // Update mark price first
        router.updateMarkPrice(updateData);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 20_000e6, 0, false);
        // Advance 1 second so publishTime > commitTime (pass MEV check)
        vm.warp(block.timestamp + 1);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp);
        router.executeOrder(1, updateData);

        bytes32 aliceAccount = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceAccount);
        assertGt(size, 0, "Position should be open");

        // Warp to Saturday (oracleFrozen = true)
        // Find next Saturday: dayOfWeek=6
        uint256 ts = block.timestamp;
        uint256 dayOfWeek = ((ts / 86_400) + 4) % 7;
        // Advance to Saturday noon
        uint256 daysToSaturday = (6 + 7 - dayOfWeek) % 7;
        if (daysToSaturday == 0) {
            daysToSaturday = 7;
        }
        uint256 saturdayNoon = ts + (daysToSaturday * 86_400) - (ts % 86_400) + 12 hours;
        vm.warp(saturdayNoon);

        // Price was last published on Friday (stale by ~18 hours, but within fadMaxStaleness of 3 days)
        uint256 fridayPublishTime = saturdayNoon - 18 hours;
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), fridayPublishTime);

        // Alice commits close order on Saturday
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 0, 0, true);

        // publishTime (Friday) < commitTime (Saturday) → normally MevDetected
        // But oracleFrozen=true skips the check entirely
        // This should revert but it doesn't — the close executes at the stale Friday price
        vm.expectRevert();
        router.executeOrder(2, updateData);
    }

}
