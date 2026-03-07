// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
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

contract PerpHandler is Test {

    MockUSDC public usdc;
    CfdEngine public engine;
    HousePool public pool;
    MarginClearinghouse public clearinghouse;
    OrderRouter public router;
    TrancheVault public juniorVault;

    address[3] public traders;
    address public lp;

    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalLpDeposited;
    uint256 public ghost_liquidationCount;
    uint256 public ghost_tradeCount;

    constructor(
        MockUSDC _usdc,
        CfdEngine _engine,
        HousePool _pool,
        MarginClearinghouse _clearinghouse,
        OrderRouter _router,
        TrancheVault _juniorVault
    ) {
        usdc = _usdc;
        engine = _engine;
        pool = _pool;
        clearinghouse = _clearinghouse;
        router = _router;
        juniorVault = _juniorVault;

        traders[0] = address(0x1001);
        traders[1] = address(0x1002);
        traders[2] = address(0x1003);
        lp = address(0x2001);
    }

    function depositAndTrade(
        uint8 sideRaw,
        uint256 sizeFuzz,
        uint256 marginFuzz,
        uint256 priceFuzz
    ) external {
        address trader = traders[ghost_tradeCount % 3];
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        priceFuzz = bound(priceFuzz, 0.5e8, 1.5e8);
        sizeFuzz = bound(sizeFuzz, 1000e18, 100_000e18);
        marginFuzz = bound(marginFuzz, 100e6, 10_000e6);

        CfdTypes.Side side = sideRaw % 2 == 0 ? CfdTypes.Side.BULL : CfdTypes.Side.BEAR;

        usdc.mint(address(this), marginFuzz);
        usdc.approve(address(clearinghouse), marginFuzz);
        clearinghouse.deposit(accountId, address(usdc), marginFuzz);
        ghost_totalDeposited += marginFuzz;

        uint64 commitId = router.nextCommitId();
        vm.prank(trader);
        router.commitOrder(side, sizeFuzz, marginFuzz, priceFuzz, false);

        bytes[] memory empty = new bytes[](0);
        router.executeOrder(commitId, empty);

        ghost_tradeCount++;
    }

    function closeTrade(
        uint256 traderIdx,
        uint256 priceFuzz
    ) external {
        address trader = traders[traderIdx % 3];
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        (uint256 size,,,, CfdTypes.Side side,) = engine.positions(accountId);
        if (size == 0) {
            return;
        }

        priceFuzz = bound(priceFuzz, 0.5e8, 1.5e8);

        uint64 commitId = router.nextCommitId();
        vm.prank(trader);
        router.commitOrder(side, size, 0, priceFuzz, true);

        bytes[] memory empty = new bytes[](0);
        router.executeOrder(commitId, empty);
    }

    function liquidate(
        uint256 traderIdx,
        uint256 priceFuzz
    ) external {
        address trader = traders[traderIdx % 3];
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        (uint256 size,,,,,) = engine.positions(accountId);
        if (size == 0) {
            return;
        }

        priceFuzz = bound(priceFuzz, 0.3e8, 1.7e8);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(priceFuzz);

        try router.executeLiquidation(accountId, priceData) {
            ghost_liquidationCount++;
        } catch {}
    }

    function depositLP(
        uint256 amountFuzz
    ) external {
        amountFuzz = bound(amountFuzz, 1000e6, 100_000e6);

        usdc.mint(lp, amountFuzz);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), amountFuzz);
        juniorVault.deposit(amountFuzz, lp);
        vm.stopPrank();

        ghost_totalLpDeposited += amountFuzz;
    }

    function withdrawLP(
        uint256 amountFuzz
    ) external {
        uint256 maxW = juniorVault.maxWithdraw(lp);
        if (maxW == 0) {
            return;
        }

        amountFuzz = bound(amountFuzz, 1e6, maxW);

        vm.prank(lp);
        juniorVault.withdraw(amountFuzz, lp, lp);
    }

}

contract PerpInvariantTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    MarginClearinghouse clearinghouse;
    OrderRouter router;
    TrancheVault seniorVault;
    TrancheVault juniorVault;
    PerpHandler handler;

    uint256 constant CAP_PRICE = 2e8;
    uint256 seniorHighWaterMark;

    function setUp() public {
        usdc = new MockUSDC();

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

        clearinghouse = new MarginClearinghouse();
        clearinghouse.supportAsset(address(usdc), 6, 10_000, address(0));

        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");

        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        router = new OrderRouter(address(engine), address(pool), address(0), bytes32(0));

        clearinghouse.setOperator(address(engine), true);
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        // Seed senior with $200k
        usdc.mint(address(this), 200_000e6);
        usdc.approve(address(seniorVault), 200_000e6);
        seniorVault.deposit(200_000e6, address(this));

        // Seed junior with $500k
        usdc.mint(address(this), 500_000e6);
        usdc.approve(address(juniorVault), 500_000e6);
        juniorVault.deposit(500_000e6, address(this));

        handler = new PerpHandler(usdc, engine, pool, clearinghouse, router, juniorVault);

        // Seed 3 traders with $10k each in clearinghouse
        for (uint256 i = 0; i < 3; i++) {
            address trader = handler.traders(i);
            bytes32 accountId = bytes32(uint256(uint160(trader)));
            usdc.mint(address(this), 10_000e6);
            usdc.approve(address(clearinghouse), 10_000e6);
            clearinghouse.deposit(accountId, address(usdc), 10_000e6);
        }

        seniorHighWaterMark = pool.seniorPrincipal();

        targetContract(address(handler));
    }

    function invariant_GlobalSolvency() public {
        uint256 poolBalance = pool.totalAssets();
        uint256 maxLiability = engine.globalBullMaxProfit() > engine.globalBearMaxProfit()
            ? engine.globalBullMaxProfit()
            : engine.globalBearMaxProfit();
        assertGe(poolBalance, maxLiability, "Pool must cover worst-case liability");
    }

    function invariant_TranchePriority() public {
        pool.reconcile();
        uint256 currentSenior = pool.seniorPrincipal();
        if (currentSenior < seniorHighWaterMark) {
            assertEq(pool.juniorPrincipal(), 0, "Junior must be wiped before senior takes losses");
        }
        if (currentSenior > seniorHighWaterMark) {
            seniorHighWaterMark = currentSenior;
        }
    }

    function invariant_SymmetricalFunding() public {
        int256 bullIdx = engine.bullFundingIndex();
        int256 bearIdx = engine.bearFundingIndex();
        assertEq(bullIdx + bearIdx, 0, "Funding must be zero-sum");
    }

    function invariant_NoNegativePrincipal() public {
        pool.reconcile();
        uint256 claimed = pool.seniorPrincipal() + pool.juniorPrincipal();
        uint256 bal = pool.totalAssets();
        assertLe(claimed, bal, "Claimed equity cannot exceed pool balance");
    }

    function invariant_AggregateOIMatchesPositions() public {
        uint256 sumBullSize;
        uint256 sumBearSize;

        for (uint256 i = 0; i < 3; i++) {
            address trader = handler.traders(i);
            bytes32 accountId = bytes32(uint256(uint160(trader)));
            (uint256 size,,,, CfdTypes.Side side,) = engine.positions(accountId);
            if (size > 0) {
                if (side == CfdTypes.Side.BULL) {
                    sumBullSize += size;
                } else {
                    sumBearSize += size;
                }
            }
        }

        assertEq(engine.bullOI(), sumBullSize, "Bull OI must match sum of bull positions");
        assertEq(engine.bearOI(), sumBearSize, "Bear OI must match sum of bear positions");
    }

    function invariant_PositionMarginsBackedByClearinghouse() public {
        for (uint256 i = 0; i < 3; i++) {
            address trader = handler.traders(i);
            bytes32 accountId = bytes32(uint256(uint160(trader)));
            (uint256 size, uint256 margin,,,,) = engine.positions(accountId);
            if (size > 0) {
                uint256 locked = clearinghouse.lockedMarginUsdc(accountId);
                assertGe(locked, margin, "Clearinghouse must back position margin");
            }
        }
    }

}
