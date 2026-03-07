// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ICfdEngine} from "./interfaces/ICfdEngine.sol";
import {ICfdVault} from "./interfaces/ICfdVault.sol";
import {IHousePool} from "./interfaces/IHousePool.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title HousePool
/// @notice Tranched house pool. Senior tranche gets fixed-rate yield with last-loss protection.
///         Junior tranche absorbs first loss but captures surplus revenue.
/// @custom:security-contact contact@plether.com
contract HousePool is ICfdVault, IHousePool, Ownable2Step {

    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;
    ICfdEngine public immutable ENGINE;

    address public orderRouter;
    address public seniorVault;
    address public juniorVault;

    uint256 public seniorPrincipal;
    uint256 public juniorPrincipal;

    uint256 public lastReconcileTime;
    uint256 public seniorRateBps;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;

    error HousePool__NotAVault();
    error HousePool__RouterAlreadySet();
    error HousePool__SeniorVaultAlreadySet();
    error HousePool__JuniorVaultAlreadySet();
    error HousePool__Unauthorized();
    error HousePool__ExceedsMaxSeniorWithdraw();
    error HousePool__ExceedsMaxJuniorWithdraw();

    event Reconciled(uint256 seniorPrincipal, uint256 juniorPrincipal, int256 delta);
    event SeniorRateUpdated(uint256 newRateBps);

    modifier onlyVault() {
        if (msg.sender != seniorVault && msg.sender != juniorVault) {
            revert HousePool__NotAVault();
        }
        _;
    }

    constructor(
        address _usdc,
        address _engine
    ) Ownable(msg.sender) {
        USDC = IERC20(_usdc);
        ENGINE = ICfdEngine(_engine);
        lastReconcileTime = block.timestamp;
        seniorRateBps = 800; // 8% APY default
    }

    // ==========================================
    // ADMIN (set-once pattern)
    // ==========================================

    function setOrderRouter(
        address _router
    ) external onlyOwner {
        if (orderRouter != address(0)) {
            revert HousePool__RouterAlreadySet();
        }
        orderRouter = _router;
    }

    function setSeniorVault(
        address _vault
    ) external onlyOwner {
        if (seniorVault != address(0)) {
            revert HousePool__SeniorVaultAlreadySet();
        }
        seniorVault = _vault;
    }

    function setJuniorVault(
        address _vault
    ) external onlyOwner {
        if (juniorVault != address(0)) {
            revert HousePool__JuniorVaultAlreadySet();
        }
        juniorVault = _vault;
    }

    function setSeniorRate(
        uint256 _rateBps
    ) external onlyOwner {
        _reconcile();
        seniorRateBps = _rateBps;
        emit SeniorRateUpdated(_rateBps);
    }

    // ==========================================
    // ICfdVault INTERFACE
    // ==========================================

    function totalAssets() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    function payOut(
        address recipient,
        uint256 amount
    ) external {
        if (msg.sender != address(ENGINE) && msg.sender != orderRouter) {
            revert HousePool__Unauthorized();
        }
        USDC.safeTransfer(recipient, amount);
    }

    // ==========================================
    // TRANCHE DEPOSITS & WITHDRAWALS
    // ==========================================

    function depositSenior(
        uint256 amount
    ) external onlyVault {
        _reconcile();
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        seniorPrincipal += amount;
    }

    function withdrawSenior(
        uint256 amount,
        address receiver
    ) external onlyVault {
        _reconcile();
        if (amount > getMaxSeniorWithdraw()) {
            revert HousePool__ExceedsMaxSeniorWithdraw();
        }
        seniorPrincipal -= amount;
        USDC.safeTransfer(receiver, amount);
    }

    function depositJunior(
        uint256 amount
    ) external onlyVault {
        _reconcile();
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        juniorPrincipal += amount;
    }

    function withdrawJunior(
        uint256 amount,
        address receiver
    ) external onlyVault {
        _reconcile();
        if (amount > getMaxJuniorWithdraw()) {
            revert HousePool__ExceedsMaxJuniorWithdraw();
        }
        juniorPrincipal -= amount;
        USDC.safeTransfer(receiver, amount);
    }

    // ==========================================
    // WITHDRAWAL LIMITS
    // ==========================================

    function getFreeUSDC() public view returns (uint256) {
        uint256 bal = USDC.balanceOf(address(this));
        uint256 bullMax = ENGINE.globalBullMaxProfit();
        uint256 bearMax = ENGINE.globalBearMaxProfit();
        uint256 maxLiability = bullMax > bearMax ? bullMax : bearMax;
        return bal > maxLiability ? bal - maxLiability : 0;
    }

    function getMaxSeniorWithdraw() public view returns (uint256) {
        uint256 free = getFreeUSDC();
        return free < seniorPrincipal ? free : seniorPrincipal;
    }

    function getMaxJuniorWithdraw() public view returns (uint256) {
        uint256 free = getFreeUSDC();
        uint256 subordinated = free > seniorPrincipal ? free - seniorPrincipal : 0;
        return subordinated < juniorPrincipal ? subordinated : juniorPrincipal;
    }

    // ==========================================
    // RECONCILIATION (Revenue & Loss Waterfall)
    // ==========================================

    function reconcile() external {
        _reconcile();
    }

    function _reconcile() internal {
        uint256 claimedEquity = seniorPrincipal + juniorPrincipal;
        if (claimedEquity == 0) {
            lastReconcileTime = block.timestamp;
            return;
        }

        uint256 bal = USDC.balanceOf(address(this));
        uint256 pendingFees = ENGINE.accumulatedFeesUsdc();
        uint256 distributable = bal > pendingFees ? bal - pendingFees : 0;

        if (distributable > claimedEquity) {
            _distributeRevenue(distributable - claimedEquity);
        } else if (distributable < claimedEquity) {
            _absorbLoss(claimedEquity - distributable);
        }

        lastReconcileTime = block.timestamp;
    }

    function _distributeRevenue(
        uint256 revenue
    ) internal {
        uint256 elapsed = block.timestamp - lastReconcileTime;
        uint256 seniorYield = (seniorPrincipal * seniorRateBps * elapsed) / (BPS * SECONDS_PER_YEAR);

        if (seniorYield > revenue) {
            seniorYield = revenue;
        }

        seniorPrincipal += seniorYield;

        uint256 juniorSurplus = revenue - seniorYield;
        juniorPrincipal += juniorSurplus;

        emit Reconciled(seniorPrincipal, juniorPrincipal, int256(revenue));
    }

    function _absorbLoss(
        uint256 loss
    ) internal {
        if (loss <= juniorPrincipal) {
            juniorPrincipal -= loss;
        } else {
            uint256 seniorLoss = loss - juniorPrincipal;
            juniorPrincipal = 0;
            seniorPrincipal = seniorPrincipal > seniorLoss ? seniorPrincipal - seniorLoss : 0;
        }

        emit Reconciled(seniorPrincipal, juniorPrincipal, -int256(loss));
    }

}
