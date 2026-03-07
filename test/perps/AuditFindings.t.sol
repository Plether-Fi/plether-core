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
        router = new OrderRouter(address(engine), address(pool), address(0), bytes32(0));

        clearinghouse.setOperator(address(engine), true);
        clearinghouse.setOperator(address(router), true);
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
    // When funding owed exceeds margin, the FULL debt should be collected or
    // the position should be blocked/liquidated. The vault should not silently
    // absorb the shortfall as bad debt.
    // EXPECTED: Vault receives the full funding owed.
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

        (uint256 sizeAfterOpen, uint256 marginAfterOpen,, int256 entryFundingBefore,,) = engine.positions(accountId);

        vm.warp(block.timestamp + 180 days);

        uint256 vaultBalanceBefore = usdc.balanceOf(address(pool));

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 1000 * 1e18, 500 * 1e6, 1e8, false);
        router.executeOrder(2, empty);

        uint256 vaultBalanceAfter = usdc.balanceOf(address(pool));

        // Compute the full funding that was owed
        int256 bullIndexAfter = engine.bullFundingIndex();
        int256 indexDelta = bullIndexAfter - entryFundingBefore;
        int256 fundingOwed = (int256(sizeAfterOpen) * indexDelta) / 1e18;
        uint256 fullFundingLoss = uint256(-fundingOwed);

        // CORRECT BEHAVIOR: The vault should receive the full funding amount owed.
        // The increase in vault balance from funding settlement should equal the full debt.
        // (Ignoring fees from the second order for clarity — they only make the
        // vault balance higher, strengthening this assertion.)
        assertGe(
            vaultBalanceAfter - vaultBalanceBefore,
            fullFundingLoss,
            "Vault should collect full funding owed, not just available margin"
        );
    }

    // ==========================================
    // Finding 4: Stale vault depth solvency check
    // The solvency check should use the vault's ACTUAL balance at the time of
    // the check, not a stale snapshot from before funding settlement.
    // EXPECTED: Vault balance after trade >= maxLiability (solvency maintained).
    // BUG: Vault balance can drop below what was checked due to stale snapshot.
    // ==========================================

    function test_Finding4_StaleVaultDepth() public {
        _fundJunior(bob, 500_000 * 1e6);

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

        vm.warp(block.timestamp + 90 days);

        uint256 vaultDepthSnapshot = usdc.balanceOf(address(pool));

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        router.executeOrder(3, empty);

        uint256 actualVaultBalance = usdc.balanceOf(address(pool));

        // CORRECT BEHAVIOR: The solvency check should use the actual vault balance
        // at the point of the check, so the snapshot and post-trade balance should
        // be consistent. If funding moved USDC out during processOrder, the check
        // should have seen the reduced balance.
        assertGe(actualVaultBalance, vaultDepthSnapshot, "Vault balance should not drop below what solvency check used");
    }

    // ==========================================
    // Finding 5: Close orders bypass slippage
    // Close orders should respect slippage protection just like opens.
    // EXPECTED: Close at $0.50 reverts when targetPrice is $0.90.
    // BUG: Close executes at any price regardless of targetPrice.
    // ==========================================

    function test_Finding5_CloseBypassesSlippage() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(carol, 50_000 * 1e6);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        // Close with targetPrice = $0.90
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 0, 0.9e8, true);

        // Execute at $0.50 — far below the $0.90 target
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(uint256(0.5e8));
        router.executeOrder(2, pythData);

        // CORRECT BEHAVIOR: The close should have been cancelled due to slippage.
        // The position should still be open.
        bytes32 carolAccount = bytes32(uint256(uint160(carol)));
        (uint256 size,,,,,) = engine.positions(carolAccount);
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
        vm.expectRevert("OrderRouter: Mock mode disabled on live networks");
        router.executeOrder(1, empty);
    }

    // ==========================================
    // Finding 7: Fee-on-transfer accounting mismatch
    // The recorded balance should match what the contract actually received.
    // EXPECTED: balances[account][fot] == fot.balanceOf(clearinghouse).
    // BUG: balances records the pre-fee amount, actual balance is less.
    // ==========================================

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

}
