// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {PythStructs} from "../../src/interfaces/IPyth.sol";
import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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

        clearinghouse = new MarginClearinghouse();
        clearinghouse.supportAsset(address(usdc), 6, 10_000, address(0));

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

        clearinghouse.setOperator(address(engine), true);
        clearinghouse.setOperator(address(router), true);
        clearinghouse.setWithdrawGuard(address(engine));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));
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
        _fundTrader(dave, 50_000 * 1e6);

        vm.prank(dave);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000 * 1e18, 20_000 * 1e6, 1e8, false);
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

        assertGt(sizeAfter, sizeBefore, "Order should succeed: unsettled funding credit covers vault depletion");
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

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        clearinghouse.withdraw(accountId, address(usdc), freeBalance);
        assertEq(usdc.balanceOf(alice) - balBefore, freeBalance, "Free equity withdrawable with open position");
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
        clearinghouse.supportAsset(address(fot), 18, 10_000, address(0));

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

        assertGt(juniorAfter, juniorBefore, "MtM: junior principal must increase when traders are losing");
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

        // Reconcile should NOT absorb loss — the funding debt is a vault asset
        uint256 juniorBefore = pool.juniorPrincipal();
        vm.prank(address(juniorVault));
        pool.reconcile();
        uint256 juniorAfter = pool.juniorPrincipal();

        assertGe(juniorAfter, juniorBefore, "negative funding must not cause spurious junior loss");
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
        router.setMaxOrderAge(300);

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
        router.setMinKeeperFee(0.001 ether);
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

    function setUp() public {
        vm.warp(1_709_532_000);
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

        clearinghouse = new MarginClearinghouse();
        clearinghouse.supportAsset(address(usdc), 6, 10_000, address(0));

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

        clearinghouse.setOperator(address(engine), true);
        clearinghouse.setOperator(address(router), true);
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

        clearinghouse = new MarginClearinghouse();
        clearinghouse.supportAsset(address(usdc), 6, 10_000, address(0));

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

        clearinghouse.setOperator(address(engine), true);
        clearinghouse.setOperator(address(router), true);
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        router.setMaxOrderAge(300);
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

        assertEq(router.claimableEth(spammer), 0, "Spammer must not be refunded for expired order");
        assertGt(router.claimableEth(keeper), 0, "Keeper must be compensated for cleaning expired order");
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
        vm.expectRevert(OrderRouter.OrderRouter__Unauthorized.selector);
        router.setMaxOrderAge(600);

        // Engine owner (this contract) can set it
        router.setMaxOrderAge(600);
        assertEq(router.maxOrderAge(), 600);
    }

    // ==========================================
    // H-03 (new): Expired order fee must compensate keeper, not refund spammer
    // _skipStaleOrders and _cancelOrder refund the keeper fee to the user
    // who submitted the expired order. Keepers pay gas to clean the queue
    // but receive nothing, so they have no incentive to process expired spam.
    // EXPECTED: Keeper receives the expired order's fee.
    // BUG: Spammer gets 100% refund; keeper gets nothing.
    // ==========================================

    function test_H03_ExpiredOrderFeeGoesToKeeper() public {
        vm.deal(spammer, 1 ether);
        vm.prank(spammer);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);

        vm.warp(block.timestamp + 301);

        // Keeper executes alice's order (id=2), auto-skipping spammer's expired order (id=1)
        address keeper = address(0x999);
        bytes[] memory empty;
        vm.prank(keeper);
        router.executeOrder(2, empty);

        // Keeper should be compensated for cleaning expired order
        assertGt(router.claimableEth(keeper), 0, "keeper must receive expired order fee");
        assertEq(router.claimableEth(spammer), 0, "spammer must not be refunded for expired order");
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

        clearinghouse = new MarginClearinghouse();
        clearinghouse.supportAsset(address(usdc), 6, 10_000, address(0));

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

        clearinghouse.setOperator(address(engine), true);
        clearinghouse.setOperator(address(router), true);
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));
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

        clearinghouse = new MarginClearinghouse();
        clearinghouse.supportAsset(address(usdc), 6, 10_000, address(0));

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

        clearinghouse.setOperator(address(engine), true);
        clearinghouse.setOperator(address(router), true);
        clearinghouse.setWithdrawGuard(address(engine));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));
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

        vm.warp(1001);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        router.executeOrder(1, priceData);

        uint256 openFee = engine.accumulatedFeesUsdc();

        vm.warp(1002);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, size, 0, 0, true);

        vm.warp(1003);
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

        clearinghouse = new MarginClearinghouse();
        clearinghouse.supportAsset(address(usdc), 6, 10_000, address(0));

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

        clearinghouse.setOperator(address(engine), true);
        clearinghouse.setOperator(address(router), true);
        clearinghouse.setWithdrawGuard(address(engine));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));
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

        vm.warp(1001);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        router.executeOrder(1, priceData);

        // Warp forward so funding accrues on the skewed bull position
        vm.warp(1001 + 30 days);

        // Open a tiny position to trigger _updateFunding inside processOrder
        address carol = address(0x333);
        uint256 carolMargin = 10_000e6;
        usdc.mint(carol, carolMargin);
        vm.startPrank(carol);
        usdc.approve(address(clearinghouse), carolMargin);
        clearinghouse.deposit(bytes32(uint256(uint160(carol))), address(usdc), carolMargin);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, carolMargin, 1e8, false);
        vm.stopPrank();

        vm.warp(1001 + 30 days + 1);
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

        // getFreeUSDC currently returns the same as if negative funding didn't exist
        // After the fix, it should return MORE (negative funding = house asset = less reserved)
        assertGt(
            freeUsdcNow, freeWithoutFunding, "getFreeUSDC should account for negative funding by reducing reserved"
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

        clearinghouse = new MarginClearinghouse();
        clearinghouse.supportAsset(address(usdc), 6, 10_000, address(0));

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

        clearinghouse.setOperator(address(engine), true);
        clearinghouse.setOperator(address(router), true);
        clearinghouse.setWithdrawGuard(address(engine));
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
