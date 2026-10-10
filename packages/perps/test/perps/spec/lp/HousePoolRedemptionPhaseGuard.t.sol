// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {HousePoolRedemptionMathSidecar} from "@plether/perps/HousePoolRedemptionMathSidecar.sol";
import {HousePoolRedemptionMathLib} from "@plether/perps/libraries/HousePoolRedemptionMathLib.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

contract HousePoolRedemptionPhaseHarness is HousePool {

    constructor(
        address usdc
    ) HousePool(usdc, address(0xE11E), address(new HousePoolRedemptionMathSidecar())) {}

    function runRedemptionPhase(
        address vault,
        uint256 cutoffEpoch,
        uint256 pricingPrincipal,
        uint256 pricingSupply,
        uint256 budget,
        uint256 feeBps
    ) external returns (uint256 fundedShares, uint256 fundedAssets, uint256 processedEpochs, bool backlog) {
        RedemptionPhase memory phase = RedemptionPhase({
            pricingPrincipal: pricingPrincipal,
            pricingSupply: pricingSupply,
            budget: budget,
            fundedShares: 0,
            fundedAssets: 0,
            processedEpochs: 0,
            backlog: false
        });
        phase = _fundRedemptionPhase(vault, cutoffEpoch, phase, feeBps);
        return (phase.fundedShares, phase.fundedAssets, phase.processedEpochs, phase.backlog);
    }

    function runDepositPhase(
        address vault,
        uint256 cutoffEpoch,
        uint256 pricingAssets,
        uint256 pricingSupply
    ) external returns (uint256 acceptedAssets, uint256 mintedShares, uint256 processedEpochs, bool backlog) {
        DepositPhase memory phase = DepositPhase({
            pricingAssets: pricingAssets,
            pricingSupply: pricingSupply,
            acceptedAssets: 0,
            mintedShares: 0,
            processedEpochs: 0,
            backlog: false
        });
        phase = _settleDepositPhase(vault, cutoffEpoch, phase, 0, false);
        return (phase.acceptedAssets, phase.mintedShares, phase.processedEpochs, phase.backlog);
    }

}

contract TwoHeadRedemptionQueueMock is ERC20 {

    address internal constant FEE_RECIPIENT = address(0xFEE);

    struct Head {
        uint256 epochId;
        uint256 remainingShares;
    }

    address internal immutable POOL;
    Head[2] internal _heads;
    uint256 internal _headIndex;

    uint256 public refundedShares;
    uint256 public pendingAccruedShares;

    constructor(
        address pool,
        uint256 supply,
        uint256 firstHeadShares,
        uint256 secondHeadShares
    ) ERC20("Queue Share", "QSH") {
        POOL = pool;
        _heads[0] = Head({epochId: 1, remainingShares: firstHeadShares});
        _heads[1] = Head({epochId: 2, remainingShares: secondHeadShares});
        _mint(address(this), firstHeadShares + secondHeadShares);
        _mint(address(0xBEEF), supply - firstHeadShares - secondHeadShares);
    }

    function accruedTotalSupply() external view returns (uint256) {
        return totalSupply() + pendingAccruedShares;
    }

    function setPendingAccruedShares(
        uint256 shares
    ) external {
        pendingAccruedShares = shares;
    }

    function getMaturedRedeemHead(
        uint256 cutoffEpoch
    ) external view returns (uint256 epochId, uint256 remainingShares) {
        if (_headIndex == 2 || _heads[_headIndex].epochId > cutoffEpoch) {
            return (0, 0);
        }
        Head memory head = _heads[_headIndex];
        return (head.epochId, head.remainingShares);
    }

    function fundRedeemEpoch(
        uint256 epochId,
        uint256 shares,
        uint256
    ) external {
        require(msg.sender == POOL, "only pool");
        Head storage head = _heads[_headIndex];
        require(epochId == head.epochId && shares <= head.remainingShares, "invalid fill");
        uint256 accruedShares = pendingAccruedShares;
        if (accruedShares != 0) {
            pendingAccruedShares = 0;
            _mint(FEE_RECIPIENT, accruedShares);
        }
        head.remainingShares -= shares;
        _burn(address(this), shares);
        if (head.remainingShares == 0) {
            _headIndex += 1;
        }
    }

    function refundRedeemEpochRemainder(
        uint256 epochId,
        uint256 expectedShares
    ) external returns (uint256 shares) {
        require(msg.sender == POOL, "only pool");
        Head storage head = _heads[_headIndex];
        require(epochId == head.epochId && expectedShares == head.remainingShares, "invalid refund");
        shares = head.remainingShares;
        head.remainingShares = 0;
        refundedShares += shares;
        _headIndex += 1;
    }

}

contract SingleHeadDepositQueueMock is ERC20 {

    address internal constant FEE_RECIPIENT = address(0xFEE);

    HousePoolRedemptionPhaseHarness internal immutable POOL;
    MockUSDC internal immutable USDC;
    uint256 internal immutable EPOCH_ASSETS;

    bool internal _queued = true;
    uint256 public pendingAccruedShares;

    constructor(
        HousePoolRedemptionPhaseHarness pool,
        MockUSDC usdc,
        uint256 supply,
        uint256 epochAssets
    ) ERC20("Queue Share", "QSH") {
        POOL = pool;
        USDC = usdc;
        EPOCH_ASSETS = epochAssets;
        _mint(address(0xBEEF), supply);
    }

    function accruedTotalSupply() external view returns (uint256) {
        return totalSupply() + pendingAccruedShares;
    }

    function setPendingAccruedShares(
        uint256 shares
    ) external {
        pendingAccruedShares = shares;
    }

    function getMaturedDepositHead(
        uint256 cutoffEpoch
    ) external view returns (uint256 epochId, uint256 assets) {
        if (_queued && cutoffEpoch >= 1) {
            return (1, EPOCH_ASSETS);
        }
        return (0, 0);
    }

    function quoteDepositFromState(
        uint256 assets,
        uint256,
        uint256,
        uint256
    ) external pure returns (uint256 shares) {
        return assets * 1000;
    }

    function finalizeDepositEpochFromPool(
        uint256 epochId,
        uint256 shares
    ) external returns (uint256 assets) {
        require(msg.sender == address(POOL), "only pool");
        require(_queued && epochId == 1, "invalid head");
        _queued = false;
        assets = EPOCH_ASSETS;
        if (shares == 0) {
            return assets;
        }
        uint256 accruedShares = pendingAccruedShares;
        if (accruedShares != 0) {
            pendingAccruedShares = 0;
            _mint(FEE_RECIPIENT, accruedShares);
        }
        require(USDC.transfer(address(POOL), assets), "transfer failed");
        _mint(address(this), shares);
    }

}

contract HousePoolRedemptionPhaseGuardTest is Test {

    uint256 internal constant PRINCIPAL = 4;
    uint256 internal constant SUPPLY = 204_673_751;
    uint256 internal constant FIRST_HEAD_SHARES = 163_739_800;
    uint256 internal constant SECOND_HEAD_SHARES = 37_836_560;
    uint256 internal constant FEE_BPS = 360;

    MockUSDC internal usdc;
    HousePoolRedemptionPhaseHarness internal pool;
    TwoHeadRedemptionQueueMock internal vault;

    function setUp() public {
        usdc = new MockUSDC();
        pool = new HousePoolRedemptionPhaseHarness(address(usdc));
        vault = new TwoHeadRedemptionQueueMock(address(pool), SUPPLY, FIRST_HEAD_SHARES, SECOND_HEAD_SHARES);
        usdc.mint(address(pool), 3);
    }

    function test_FrozenZeroHeadAfterBurnWaitsForCanonicalRepricing() public {
        assertEq(
            HousePoolRedemptionMathLib.netAssetsForShares(FIRST_HEAD_SHARES, PRINCIPAL, SUPPLY, 1, 1000, FEE_BPS),
            2,
            "first head payout"
        );
        assertEq(
            HousePoolRedemptionMathLib.netAssetsForShares(SECOND_HEAD_SHARES, PRINCIPAL, SUPPLY, 1, 1000, FEE_BPS),
            0,
            "second head is zero only at the frozen pre-burn price"
        );

        (uint256 fundedShares, uint256 fundedAssets, uint256 processedEpochs, bool backlog) =
            pool.runRedemptionPhase(address(vault), 2, PRINCIPAL, SUPPLY, 3, FEE_BPS);

        assertEq(fundedShares, FIRST_HEAD_SHARES);
        assertEq(fundedAssets, 2);
        assertEq(processedEpochs, 1, "the later frozen-zero head must not be terminally refunded");
        assertTrue(backlog);
        assertEq(vault.refundedShares(), 0);

        uint256 postBurnPrincipal = PRINCIPAL - fundedAssets;
        uint256 postBurnSupply = SUPPLY - fundedShares;
        assertEq(
            HousePoolRedemptionMathLib.netAssetsForShares(
                SECOND_HEAD_SHARES, postBurnPrincipal, postBurnSupply, 1, 1000, FEE_BPS
            ),
            1,
            "the queued head is positive at the canonical post-burn price"
        );

        (fundedShares, fundedAssets, processedEpochs, backlog) =
            pool.runRedemptionPhase(address(vault), 2, postBurnPrincipal, postBurnSupply, 1, FEE_BPS);

        assertEq(fundedShares, SECOND_HEAD_SHARES);
        assertEq(fundedAssets, 1);
        assertEq(processedEpochs, 1);
        assertFalse(backlog);
        assertEq(vault.refundedShares(), 0);
    }

    function test_RedemptionSupplyGuardAllowsAccruedSharesMaterializedBeforeBurn() public {
        uint256 rawSupply = 1_000_000_000;
        uint256 accruedShares = 100_000_000;
        uint256 redeemShares = 100_000_000;
        uint256 pricingSupply = rawSupply + accruedShares;
        uint256 principal = 1_100_000;
        TwoHeadRedemptionQueueMock feeVault = new TwoHeadRedemptionQueueMock(address(pool), rawSupply, redeemShares, 0);
        feeVault.setPendingAccruedShares(accruedShares);
        usdc.mint(address(pool), principal);

        (uint256 fundedShares, uint256 fundedAssets, uint256 processedEpochs, bool backlog) =
            pool.runRedemptionPhase(address(feeVault), 1, principal, pricingSupply, principal, 0);

        assertEq(fundedShares, redeemShares);
        assertGt(fundedAssets, 0);
        assertEq(processedEpochs, 1);
        assertFalse(backlog);
        assertEq(feeVault.balanceOf(address(0xFEE)), accruedShares);
        assertEq(feeVault.totalSupply(), rawSupply + accruedShares - redeemShares);
    }

    function test_DepositSupplyGuardAllowsAccruedSharesMaterializedBeforeMint() public {
        uint256 rawSupply = 1_000_000_000;
        uint256 accruedShares = 100_000_000;
        uint256 depositAssets = 1_000_000;
        uint256 expectedDepositShares = depositAssets * 1000;
        SingleHeadDepositQueueMock feeVault = new SingleHeadDepositQueueMock(pool, usdc, rawSupply, depositAssets);
        feeVault.setPendingAccruedShares(accruedShares);
        usdc.mint(address(feeVault), depositAssets);

        (uint256 acceptedAssets, uint256 mintedShares, uint256 processedEpochs, bool backlog) =
            pool.runDepositPhase(address(feeVault), 1, depositAssets, rawSupply + accruedShares);

        assertEq(acceptedAssets, depositAssets);
        assertEq(mintedShares, expectedDepositShares);
        assertEq(processedEpochs, 1);
        assertFalse(backlog);
        assertEq(feeVault.balanceOf(address(0xFEE)), accruedShares);
        assertEq(feeVault.totalSupply(), rawSupply + accruedShares + expectedDepositShares);
    }

}
