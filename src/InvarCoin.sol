// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {StakedToken} from "./StakedToken.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {ICurveGauge} from "./interfaces/ICurveGauge.sol";
import {ICurveMinter} from "./interfaces/ICurveMinter.sol";
import {ICurveTwocrypto} from "./interfaces/ICurveTwocrypto.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/// @title InvarCoin (INVAR)
/// @custom:security-contact contact@plether.com
/// @notice Global purchasing power token backed 50/50 by USDC + plDXY-BEAR via Curve LP.
/// @dev INVAR is a vault token whose backing is held as Curve USDC/plDXY-BEAR LP tokens. Users deposit USDC,
///      which is single-sided deployed to Curve. The vault earns Curve trading fee yield (virtual price growth),
///      which is harvested and donated to sINVAR stakers.
///
///      LP tokens are valued with dual pricing to prevent manipulation:
///        - totalAssets() and harvest use pessimistic pricing (min of EMA, oracle) for conservative NAV.
///        - totalAssetsValidated() provides strict oracle-validated NAV (reverts on stale/invalid oracle).
///        - deposit() uses optimistic NAV (max of EMA, oracle) so new depositors cannot dilute existing holders.
///        - lpDeposit() values minted LP pessimistically so depositors cannot extract value from stale-high EMA.
///        - withdraw() and lpWithdraw() use pro-rata asset distribution (no NAV pricing needed).
///
///      The oracle-derived LP price mirrors the twocrypto-ng formula: 2 * virtualPrice * sqrt(bearPrice).
///
///      A 2% USDC buffer (BUFFER_TARGET_BPS) is maintained locally for gas-efficient withdrawals.
///      Excess USDC is deployed to Curve via permissionless keeper calls (deployToCurve).
///
///      Virtual shares (1e18 INVAR / 1e6 USDC) protect against inflation attacks on the first deposit.
contract InvarCoin is ERC20, ERC20Permit, Ownable2Step, Pausable, ReentrancyGuard {

    using SafeERC20 for IERC20;

    // ==========================================
    // IMMUTABLES & CONSTANTS
    // ==========================================

    /// @notice USDC collateral token (6 decimals).
    IERC20 public immutable USDC;
    /// @notice plDXY-BEAR synthetic token (18 decimals).
    IERC20 public immutable BEAR;
    /// @notice Curve USDC/plDXY-BEAR LP token.
    IERC20 public immutable CURVE_LP_TOKEN;
    /// @notice Curve twocrypto-ng pool for USDC/plDXY-BEAR.
    ICurveTwocrypto public immutable CURVE_POOL;
    /// @notice Chainlink BasketOracle — weighted basket of 6 FX feeds, returns foreign currencies priced in USD (8 decimals).
    AggregatorV3Interface public immutable BASKET_ORACLE;
    /// @notice L2 sequencer uptime feed for staleness protection (address(0) on L1).
    AggregatorV3Interface public immutable SEQUENCER_UPTIME_FEED;
    /// @notice Curve Minter for CRV emissions on L1 (address(0) on L2 where claim_rewards handles CRV).
    ICurveMinter public immutable CRV_MINTER;

    uint256 public constant BUFFER_TARGET_BPS = 200; // 2% target buffer
    uint256 public constant DEPLOY_THRESHOLD = 1000e6; // Min $1000 to deploy
    uint256 public constant MAX_SPOT_DEVIATION_BPS = 50; // 0.5% max spot-vs-EMA deviation

    uint256 public constant ORACLE_TIMEOUT = 24 hours;
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;

    // Inflation attack protection (Virtual Shares)
    uint256 public constant VIRTUAL_SHARES = 1e18;
    uint256 public constant VIRTUAL_ASSETS = 1e6;

    uint256 private constant USDC_INDEX = 0;
    uint256 private constant BPS = 10_000;

    // ==========================================
    // STATE
    // ==========================================

    /// @notice sINVAR staking contract that receives harvested yield.
    StakedToken public stakedInvarCoin;
    address public pendingStakedInvarCoin;
    uint256 public stakedInvarCoinActivationTime;
    uint256 public constant STAKED_INVAR_TIMELOCK = 7 days;
    /// @notice Cumulative virtual-price cost basis of tracked LP tokens (18 decimals).
    /// @dev Used to isolate fee yield (VP growth) from price appreciation. Only LP tokens
    ///      deployed by the vault are tracked — donated LP is excluded to prevent yield manipulation.
    uint256 public curveLpCostVp;
    /// @notice LP token balance deployed by the vault (excludes donated LP).
    uint256 public trackedLpBalance;
    /// @notice True when emergency mode is active — blocks deposits and single-sided withdrawals.
    bool public emergencyActive;

    ICurveGauge public curveGauge;
    address public pendingGauge;
    uint256 public gaugeActivationTime;
    uint256 public constant GAUGE_TIMELOCK = 7 days;
    mapping(address => bool) public approvedGauges;
    address public gaugeRewardsReceiver;
    address public pendingGaugeRewardsReceiver;
    uint256 public gaugeRewardsReceiverActivationTime;
    uint256 public constant GAUGE_REWARDS_TIMELOCK = 7 days;
    mapping(address => bool) public protectedRewardTokens;

    // ==========================================
    // EVENTS & ERRORS
    // ==========================================

    event Deposited(address indexed user, address indexed receiver, uint256 usdcIn, uint256 glUsdOut);
    event Withdrawn(address indexed user, address indexed receiver, uint256 glUsdIn, uint256 usdcOut);
    event LpWithdrawn(address indexed user, uint256 sharesBurned, uint256 usdcReturned, uint256 bearReturned);
    event LpDeposited(address indexed user, address indexed receiver, uint256 usdcIn, uint256 bearIn, uint256 glUsdOut);
    event DeployedToCurve(address indexed caller, uint256 usdcDeployed, uint256 bearDeployed, uint256 lpMinted);
    event BufferReplenished(uint256 lpBurned, uint256 usdcRecovered);
    event YieldHarvested(uint256 glUsdMinted, uint256 callerReward, uint256 donated);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event EmergencyWithdrawCurve(uint256 lpBurned, uint256 usdcReceived, uint256 bearReceived);
    event StakedInvarCoinProposed(address indexed stakedInvarCoin, uint256 activationTime);
    event StakedInvarCoinSet(address indexed stakedInvarCoin);
    event GaugeProposed(address indexed gauge, uint256 activationTime);
    event GaugeUpdated(address indexed oldGauge, address indexed newGauge);
    event GaugeRewardsReceiverProposed(address indexed receiver, uint256 activationTime);
    event GaugeRewardsReceiverSet(address indexed receiver);
    event RewardTokenProtected(address indexed token);
    event GaugeStaked(uint256 amount);
    event GaugeUnstaked(uint256 amount);
    event GaugeRewardsClaimed();
    event GaugeRewardsSwept(address indexed token, address indexed receiver, uint256 amount);
    event UsdcDonated(address indexed donor, uint256 usdcAmount, uint256 invarMinted);
    error InvarCoin__ZeroAmount();
    error InvarCoin__StakingNotSet();
    error InvarCoin__ZeroAddress();
    error InvarCoin__SlippageExceeded();
    error InvarCoin__NothingToDeploy();
    error InvarCoin__NoYield();
    error InvarCoin__CannotRescueCoreAsset();
    error InvarCoin__PermitFailed();
    error InvarCoin__AlreadySet();
    error InvarCoin__SpotDeviationTooHigh();
    error InvarCoin__UseLpWithdraw();
    error InvarCoin__Unauthorized();
    error InvarCoin__GaugeTimelockActive();
    error InvarCoin__StakingTimelockActive();
    error InvarCoin__GaugeRewardsTimelockActive();
    error InvarCoin__InvalidProposal();
    error InvarCoin__NoGauge();
    error InvarCoin__EmergencyActive();
    error InvarCoin__InvalidGauge();
    error InvarCoin__InvalidStakingVault();
    error InvarCoin__GaugeRewardsReceiverNotSet();

    /// @param _usdc USDC token address.
    /// @param _bear plDXY-BEAR token address.
    /// @param _curveLpToken Curve USDC/plDXY-BEAR LP token address.
    /// @param _curvePool Curve twocrypto-ng pool address.
    /// @param _oracle BasketOracle address (Chainlink AggregatorV3Interface).
    /// @param _sequencerUptimeFeed L2 sequencer uptime feed (address(0) on L1).
    /// @param _crvMinter Curve Minter for CRV emissions (address(0) on L2).
    constructor(
        address _usdc,
        address _bear,
        address _curveLpToken,
        address _curvePool,
        address _oracle,
        address _sequencerUptimeFeed,
        address _crvMinter
    ) ERC20("InvarCoin", "INVAR") ERC20Permit("InvarCoin") Ownable(msg.sender) {
        if (
            _usdc == address(0) || _bear == address(0) || _curveLpToken == address(0) || _curvePool == address(0)
                || _oracle == address(0)
        ) {
            revert InvarCoin__ZeroAddress();
        }

        USDC = IERC20(_usdc);
        BEAR = IERC20(_bear);
        CURVE_LP_TOKEN = IERC20(_curveLpToken);
        CURVE_POOL = ICurveTwocrypto(_curvePool);
        BASKET_ORACLE = AggregatorV3Interface(_oracle);
        SEQUENCER_UPTIME_FEED = AggregatorV3Interface(_sequencerUptimeFeed);
        CRV_MINTER = ICurveMinter(_crvMinter);

        USDC.safeIncreaseAllowance(_curvePool, type(uint256).max);
        BEAR.safeIncreaseAllowance(_curvePool, type(uint256).max);
    }

    function _validateStakingVault(
        address stakingVault
    ) private view {
        if (stakingVault == address(0) || stakingVault.code.length == 0) {
            revert InvarCoin__InvalidStakingVault();
        }

        try StakedToken(stakingVault).asset() returns (address assetToken) {
            if (assetToken != address(this)) {
                revert InvarCoin__InvalidStakingVault();
            }
        } catch {
            revert InvarCoin__InvalidStakingVault();
        }
    }

    /// @notice Propose the sINVAR staking contract. Finalized after STAKED_INVAR_TIMELOCK.
    /// @param _stakedInvarCoin Address of the StakedToken (sINVAR) contract.
    function proposeStakedInvarCoin(
        address _stakedInvarCoin
    ) external onlyOwner {
        if (address(stakedInvarCoin) != address(0)) {
            revert InvarCoin__AlreadySet();
        }

        _validateStakingVault(_stakedInvarCoin);

        pendingStakedInvarCoin = _stakedInvarCoin;
        stakedInvarCoinActivationTime = block.timestamp + STAKED_INVAR_TIMELOCK;

        emit StakedInvarCoinProposed(_stakedInvarCoin, stakedInvarCoinActivationTime);
    }

    /// @notice Finalize the proposed sINVAR staking contract after the timelock.
    function finalizeStakedInvarCoin() external onlyOwner {
        if (address(stakedInvarCoin) != address(0)) {
            revert InvarCoin__AlreadySet();
        }
        if (pendingStakedInvarCoin == address(0) || block.timestamp < stakedInvarCoinActivationTime) {
            revert InvarCoin__StakingTimelockActive();
        }

        address nextStakedInvarCoin = pendingStakedInvarCoin;
        _validateStakingVault(nextStakedInvarCoin);

        stakedInvarCoin = StakedToken(nextStakedInvarCoin);
        pendingStakedInvarCoin = address(0);
        stakedInvarCoinActivationTime = 0;

        emit StakedInvarCoinSet(nextStakedInvarCoin);
    }

    /// @notice Propose the receiver for protected gauge reward tokens.
    function proposeGaugeRewardsReceiver(
        address receiver
    ) external onlyOwner {
        if (receiver == address(0)) {
            revert InvarCoin__ZeroAddress();
        }

        pendingGaugeRewardsReceiver = receiver;
        gaugeRewardsReceiverActivationTime = block.timestamp + GAUGE_REWARDS_TIMELOCK;

        emit GaugeRewardsReceiverProposed(receiver, gaugeRewardsReceiverActivationTime);
    }

    /// @notice Finalize the protected reward receiver after the timelock.
    function finalizeGaugeRewardsReceiver() external onlyOwner {
        if (pendingGaugeRewardsReceiver == address(0) || block.timestamp < gaugeRewardsReceiverActivationTime) {
            revert InvarCoin__GaugeRewardsTimelockActive();
        }

        gaugeRewardsReceiver = pendingGaugeRewardsReceiver;
        pendingGaugeRewardsReceiver = address(0);
        gaugeRewardsReceiverActivationTime = 0;

        emit GaugeRewardsReceiverSet(gaugeRewardsReceiver);
    }

    /// @notice Irreversibly marks a token as a protected gauge reward token.
    function protectRewardToken(
        address token
    ) external onlyOwner {
        if (token == address(0)) {
            revert InvarCoin__ZeroAddress();
        }

        protectedRewardTokens[token] = true;
        emit RewardTokenProtected(token);
    }

    /// @notice Sweeps a protected gauge reward token to the configured receiver.
    function sweepGaugeRewards(
        address token
    ) external onlyOwner {
        if (!protectedRewardTokens[token]) {
            revert InvarCoin__CannotRescueCoreAsset();
        }
        if (gaugeRewardsReceiver == address(0)) {
            revert InvarCoin__GaugeRewardsReceiverNotSet();
        }

        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(gaugeRewardsReceiver, balance);

        emit GaugeRewardsSwept(token, gaugeRewardsReceiver, balance);
    }

    // ==========================================
    // NAV CALCULATION (Safe from Flash Loans)
    // ==========================================

    /// @notice Total assets backing INVAR (USDC, 6 decimals).
    /// @dev Uses pessimistic LP pricing: min(Curve EMA, oracle-derived) to prevent stale-EMA exploitation.
    function totalAssets() public view returns (uint256) {
        return _totalAssetsWithLpBal(_lpBalance());
    }

    /// @notice Total assets backing INVAR with strict oracle validation (USDC, 6 decimals).
    /// @dev Reverts if sequencer/oracle checks fail (stale, invalid, or within sequencer grace period).
    function totalAssetsValidated() external view returns (uint256) {
        uint256 oraclePrice =
            OracleLib.getValidatedPrice(BASKET_ORACLE, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD, ORACLE_TIMEOUT);
        return _totalAssetsWithPrice(_lpBalance(), oraclePrice);
    }

    /// @dev Total assets using a pre-fetched LP balance (avoids redundant gauge.balanceOf calls).
    function _totalAssetsWithLpBal(
        uint256 lpBal
    ) private view returns (uint256) {
        (, int256 rawPrice,,,) = BASKET_ORACLE.latestRoundData();
        uint256 oraclePrice = rawPrice > 0 ? uint256(rawPrice) : 0;
        return _totalAssetsWithPrice(lpBal, oraclePrice);
    }

    /// @dev Total assets using pre-fetched LP balance and validated oracle price.
    function _totalAssetsWithPrice(
        uint256 lpBal,
        uint256 oraclePrice
    ) private view returns (uint256) {
        uint256 localUsdc = USDC.balanceOf(address(this));

        uint256 lpUsdcValue = 0;
        if (lpBal > 0) {
            lpUsdcValue = (lpBal * _pessimisticLpPrice(oraclePrice)) / 1e30;
        }

        uint256 bearBal = BEAR.balanceOf(address(this));
        uint256 bearUsdcValue = 0;
        if (bearBal > 0 && oraclePrice > 0) {
            bearUsdcValue = (bearBal * oraclePrice) / 1e20;
        }

        return localUsdc + lpUsdcValue + bearUsdcValue;
    }

    /// @notice Buffer health metrics for keeper bots and frontends.
    /// @dev Uses permissive totalAssets() (best-effort oracle read). For strict oracle-validated NAV,
    ///      use totalAssetsValidated().
    /// @return currentBuffer USDC held locally (6 decimals).
    /// @return targetBuffer Target USDC buffer based on total assets (6 decimals).
    /// @return deployable Excess USDC deployable to Curve (0 if below threshold).
    /// @return replenishable USDC deficit that needs replenishing from Curve LP.
    function getBufferMetrics()
        external
        view
        returns (uint256 currentBuffer, uint256 targetBuffer, uint256 deployable, uint256 replenishable)
    {
        uint256 assets = totalAssets();
        targetBuffer = (assets * BUFFER_TARGET_BPS) / BPS;
        currentBuffer = USDC.balanceOf(address(this));
        if (currentBuffer > targetBuffer) {
            uint256 excess = currentBuffer - targetBuffer;
            deployable = excess >= DEPLOY_THRESHOLD ? excess : 0;
        } else {
            replenishable = targetBuffer - currentBuffer;
        }
    }

    /// @notice Estimated harvestable Curve fee yield (USDC, 6 decimals).
    /// @dev Read-only estimator mirroring _harvest math. Uses permissive oracle reads and returns 0 if no staking
    ///      contract or no VP growth.
    function getHarvestableYield() external view returns (uint256 yieldUsdc) {
        uint256 lpBal = trackedLpBalance;
        if (lpBal == 0 || address(stakedInvarCoin) == address(0)) {
            return 0;
        }

        uint256 currentVpValue = (lpBal * CURVE_POOL.get_virtual_price()) / 1e18;
        if (currentVpValue <= curveLpCostVp) {
            return 0;
        }

        (, int256 rawPrice,,,) = BASKET_ORACLE.latestRoundData();
        uint256 oraclePrice = rawPrice > 0 ? uint256(rawPrice) : 0;

        uint256 vpGrowth = currentVpValue - curveLpCostVp;
        uint256 currentLpUsdc = (lpBal * _pessimisticLpPrice(oraclePrice)) / 1e30;
        yieldUsdc = Math.mulDiv(currentLpUsdc, vpGrowth, currentVpValue);
    }

    /// @notice Spot-vs-EMA deviation for a 1 USDC deposit (basis points).
    /// @dev Returns 0 if spot >= EMA (no discount). Used by keepers to check if deploy/replenish is safe.
    function getSpotDeviation() external view returns (uint256 deviationBps) {
        uint256[2] memory amounts = [uint256(1e6), uint256(0)];
        uint256 spotLp = CURVE_POOL.calc_token_amount(amounts, true);
        uint256 emaLp = (1e6 * 1e30) / CURVE_POOL.lp_price();
        if (spotLp >= emaLp) {
            return 0;
        }
        deviationBps = ((emaLp - spotLp) * BPS) / emaLp;
    }

    /// @dev Total assets using optimistic LP pricing — max(EMA, oracle) to prevent deposit dilution.
    function _totalAssetsOptimistic(
        uint256 oraclePrice
    ) private view returns (uint256) {
        uint256 localUsdc = USDC.balanceOf(address(this));

        uint256 lpBal = _lpBalance();
        uint256 lpUsdcValue = 0;
        if (lpBal > 0) {
            lpUsdcValue = (lpBal * _optimisticLpPrice(oraclePrice)) / 1e30;
        }

        uint256 bearBal = BEAR.balanceOf(address(this));
        uint256 bearUsdcValue = 0;
        if (bearBal > 0 && oraclePrice > 0) {
            bearUsdcValue = (bearBal * oraclePrice) / 1e20;
        }

        return localUsdc + lpUsdcValue + bearUsdcValue;
    }

    /// @dev Oracle-derived LP price: mirrors twocrypto-ng formula 2 * vp * sqrt(bearPrice_18dec).
    function _oracleLpPrice(
        uint256 oraclePrice
    ) private view returns (uint256) {
        uint256 vp = CURVE_POOL.get_virtual_price();
        return 2 * vp * Math.sqrt(oraclePrice * 1e28) / 1e18;
    }

    /// @dev min(Curve EMA, oracle-derived) — protects withdrawals from stale-high EMA.
    function _pessimisticLpPrice(
        uint256 oraclePrice
    ) private view returns (uint256) {
        uint256 lpPrice = CURVE_POOL.lp_price();
        if (oraclePrice == 0) {
            return lpPrice;
        }
        uint256 oracleLp = _oracleLpPrice(oraclePrice);
        return oracleLp < lpPrice ? oracleLp : lpPrice;
    }

    /// @dev max(Curve EMA, oracle-derived) — used for vault NAV to prevent deposit dilution.
    function _optimisticLpPrice(
        uint256 oraclePrice
    ) private view returns (uint256) {
        uint256 lpPrice = CURVE_POOL.lp_price();
        if (oraclePrice == 0) {
            return lpPrice;
        }
        uint256 oracleLp = _oracleLpPrice(oraclePrice);
        return oracleLp > lpPrice ? oracleLp : lpPrice;
    }

    /// @dev Total LP held: local + gauge-staked. Reverts if gauge is bricked — use emergencyWithdrawFromCurve().
    function _lpBalance() private view returns (uint256) {
        uint256 bal = CURVE_LP_TOKEN.balanceOf(address(this));
        ICurveGauge gauge = curveGauge;
        if (address(gauge) != address(0)) {
            bal += gauge.balanceOf(address(this));
        }
        return bal;
    }

    /// @dev Unstakes LP from gauge if local balance is insufficient for the requested amount.
    function _ensureUnstakedLp(
        uint256 amount
    ) private {
        uint256 local = CURVE_LP_TOKEN.balanceOf(address(this));
        if (local < amount) {
            ICurveGauge gauge = curveGauge;
            if (address(gauge) != address(0)) {
                gauge.withdraw(amount - local);
            }
        }
    }

    function _stakeLpToGauge(
        uint256 amount
    ) private {
        if (amount == 0) {
            return;
        }

        ICurveGauge gauge = curveGauge;
        if (address(gauge) == address(0)) {
            return;
        }

        CURVE_LP_TOKEN.approve(address(gauge), 0);
        CURVE_LP_TOKEN.approve(address(gauge), amount);
        gauge.deposit(amount);
        CURVE_LP_TOKEN.approve(address(gauge), 0);
    }

    function _validateGaugeAddress(
        address gauge
    ) private view {
        if (gauge == address(0)) {
            return;
        }
        if (gauge.code.length == 0) {
            revert InvarCoin__InvalidGauge();
        }
        if (ICurveGauge(gauge).lp_token() != address(CURVE_LP_TOKEN)) {
            revert InvarCoin__InvalidGauge();
        }
    }

    function _validateGauge(
        address gauge
    ) private view {
        _validateGaugeAddress(gauge);
        if (gauge != address(0) && !approvedGauges[gauge]) {
            revert InvarCoin__InvalidGauge();
        }
    }

    // ==========================================
    // USER FLOWS
    // ==========================================

    /// @notice Deposit USDC to mint INVAR shares. USDC stays in the local buffer until deployed to Curve.
    /// @dev Uses optimistic LP pricing for NAV to prevent deposit dilution. Harvests yield before minting.
    ///      Reverts while emergencyActive is true.
    /// @param usdcAmount Amount of USDC to deposit (6 decimals).
    /// @param receiver Address that receives the minted INVAR shares.
    /// @param minSharesOut Minimum INVAR shares to receive (0 = no minimum).
    /// @return glUsdMinted Number of INVAR shares minted.
    function deposit(
        uint256 usdcAmount,
        address receiver,
        uint256 minSharesOut
    ) public nonReentrant whenNotPaused returns (uint256 glUsdMinted) {
        if (emergencyActive) {
            revert InvarCoin__EmergencyActive();
        }
        if (usdcAmount == 0) {
            revert InvarCoin__ZeroAmount();
        }
        _harvest();
        uint256 oraclePrice =
            OracleLib.getValidatedPrice(BASKET_ORACLE, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD, ORACLE_TIMEOUT);

        uint256 assets = _totalAssetsOptimistic(oraclePrice);
        uint256 supply = totalSupply();

        // Virtual shares math against inflation attacks
        glUsdMinted = Math.mulDiv(usdcAmount, supply + VIRTUAL_SHARES, assets + VIRTUAL_ASSETS);

        if (glUsdMinted < minSharesOut) {
            revert InvarCoin__SlippageExceeded();
        }

        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);

        _mint(receiver, glUsdMinted);
        emit Deposited(msg.sender, receiver, usdcAmount, glUsdMinted);
    }

    /// @notice Gasless deposit using ERC-2612 permit. Falls back to existing allowance if permit
    ///         fails (e.g., front-run griefing) and the allowance is sufficient.
    /// @param usdcAmount Amount of USDC to deposit (6 decimals).
    /// @param receiver Address that receives the minted INVAR shares.
    /// @param minSharesOut Minimum INVAR shares to receive (0 = no minimum).
    /// @param deadline Permit signature expiry timestamp.
    /// @param v ECDSA recovery byte.
    /// @param r ECDSA r component.
    /// @param s ECDSA s component.
    /// @return Number of INVAR shares minted.
    function depositWithPermit(
        uint256 usdcAmount,
        address receiver,
        uint256 minSharesOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256) {
        // Safe permit wrapper against mempool griefing
        try IERC20Permit(address(USDC)).permit(msg.sender, address(this), usdcAmount, deadline, v, r, s) {}
        catch {
            if (block.timestamp > deadline) {
                revert InvarCoin__PermitFailed();
            }
            if (USDC.allowance(msg.sender, address(this)) < usdcAmount) {
                revert InvarCoin__PermitFailed();
            }
        }
        return deposit(usdcAmount, receiver, minSharesOut);
    }

    /// @notice USDC-only withdrawal via pro-rata buffer + JIT Curve LP burn.
    /// @dev Burns the user's pro-rata share of local USDC and Curve LP (single-sided to USDC).
    ///      Does not distribute raw BEAR balances — use lpWithdraw() if the contract holds BEAR.
    ///      Blocked during emergencyActive since single-sided LP exit may be unavailable.
    /// @param glUsdAmount Amount of INVAR shares to burn.
    /// @param receiver Address that receives the withdrawn USDC.
    /// @param minUsdcOut Minimum USDC to receive (slippage protection).
    /// @return usdcOut Total USDC returned (buffer + Curve LP proceeds).
    function withdraw(
        uint256 glUsdAmount,
        address receiver,
        uint256 minUsdcOut
    ) external nonReentrant whenNotPaused returns (uint256 usdcOut) {
        if (glUsdAmount == 0) {
            revert InvarCoin__ZeroAmount();
        }
        if (emergencyActive) {
            revert InvarCoin__UseLpWithdraw();
        }
        _harvestSafe();

        uint256 supply = totalSupply();
        _burn(msg.sender, glUsdAmount);

        usdcOut = Math.mulDiv(USDC.balanceOf(address(this)), glUsdAmount, supply);

        uint256 lpBal = _lpBalance();
        if (lpBal > 0) {
            uint256 lpShare = Math.mulDiv(lpBal, glUsdAmount, supply);
            if (lpShare > 0) {
                trackedLpBalance -= Math.mulDiv(trackedLpBalance, lpShare, lpBal);
                curveLpCostVp -= Math.mulDiv(curveLpCostVp, lpShare, lpBal);
                uint256 minCurveOut = minUsdcOut > usdcOut ? minUsdcOut - usdcOut : 0;
                try CURVE_POOL.lp_price() returns (uint256 lpPrice) {
                    uint256 emaMin = (lpShare * lpPrice) / 1e30 * (BPS - MAX_SPOT_DEVIATION_BPS) / BPS;
                    if (emaMin > minCurveOut) {
                        minCurveOut = emaMin;
                    }
                } catch {}
                _ensureUnstakedLp(lpShare);
                usdcOut += CURVE_POOL.remove_liquidity_one_coin(lpShare, USDC_INDEX, minCurveOut);
            }
        }

        if (usdcOut < minUsdcOut) {
            revert InvarCoin__SlippageExceeded();
        }

        USDC.safeTransfer(receiver, usdcOut);
        emit Withdrawn(msg.sender, receiver, glUsdAmount, usdcOut);
    }

    // ==========================================
    // LP WITHDRAWAL (Deep Liquidity Exit)
    // ==========================================

    /// @notice Balanced withdrawal: returns pro-rata USDC + BEAR from Curve LP (remove_liquidity).
    /// @dev Intentionally lacks whenNotPaused — serves as the emergency exit when the contract is paused.
    ///      Emergency mode still honors pro-rata LP claims by redeeming any remaining LP before paying out.
    /// @param glUsdAmount Amount of INVAR shares to burn.
    /// @param minUsdcOut Minimum USDC to receive (slippage protection).
    /// @param minBearOut Minimum plDXY-BEAR to receive (slippage protection).
    /// @return usdcReturned Total USDC returned.
    /// @return bearReturned Total plDXY-BEAR returned.
    function lpWithdraw(
        uint256 glUsdAmount,
        uint256 minUsdcOut,
        uint256 minBearOut
    ) external nonReentrant returns (uint256 usdcReturned, uint256 bearReturned) {
        (usdcReturned, bearReturned) = _lpWithdraw(glUsdAmount, minUsdcOut, minBearOut);
    }

    function _lpWithdraw(
        uint256 glUsdAmount,
        uint256 minUsdcOut,
        uint256 minBearOut
    ) internal returns (uint256 usdcReturned, uint256 bearReturned) {
        if (glUsdAmount == 0) {
            revert InvarCoin__ZeroAmount();
        }
        _harvestSafe();

        uint256 supply = totalSupply();
        _burn(msg.sender, glUsdAmount);

        uint256 localUsdcShare = Math.mulDiv(USDC.balanceOf(address(this)), glUsdAmount, supply);
        usdcReturned += localUsdcShare;

        uint256 bearBal = BEAR.balanceOf(address(this));
        if (bearBal > 0) {
            bearReturned += Math.mulDiv(bearBal, glUsdAmount, supply);
        }

        uint256 lpBal = _lpBalance();
        if (lpBal > 0) {
            uint256 lpToBurn = Math.mulDiv(lpBal, glUsdAmount, supply);
            trackedLpBalance -= Math.mulDiv(trackedLpBalance, lpToBurn, lpBal);
            curveLpCostVp -= Math.mulDiv(curveLpCostVp, lpToBurn, lpBal);
            _ensureUnstakedLp(lpToBurn);
            uint256[2] memory min_amounts = [uint256(0), uint256(0)];
            uint256[2] memory withdrawn = CURVE_POOL.remove_liquidity(lpToBurn, min_amounts);
            usdcReturned += withdrawn[0];
            bearReturned += withdrawn[1];
        }

        if (usdcReturned < minUsdcOut || bearReturned < minBearOut) {
            revert InvarCoin__SlippageExceeded();
        }

        if (usdcReturned > 0) {
            USDC.safeTransfer(msg.sender, usdcReturned);
        }
        if (bearReturned > 0) {
            BEAR.safeTransfer(msg.sender, bearReturned);
        }

        emit LpWithdrawn(msg.sender, glUsdAmount, usdcReturned, bearReturned);
    }

    /// @notice Direct LP deposit: provide USDC and/or plDXY-BEAR, deploy to Curve, mint INVAR.
    /// @dev Inverse of lpWithdraw. Curve slippage is borne by the depositor, not existing holders.
    ///      Shares are priced using pessimistic LP valuation so the depositor cannot extract value
    ///      from a stale-high EMA. Spot deviation is checked against EMA to block sandwich attacks.
    ///      Reverts while emergencyActive is true.
    /// @param usdcAmount Amount of USDC to deposit (6 decimals, can be 0 if bearAmount > 0).
    /// @param bearAmount Amount of plDXY-BEAR to deposit (18 decimals, can be 0 if usdcAmount > 0).
    /// @param receiver Address that receives the minted INVAR shares.
    /// @param minSharesOut Minimum INVAR shares to receive (slippage protection).
    /// @return glUsdMinted Number of INVAR shares minted.
    function lpDeposit(
        uint256 usdcAmount,
        uint256 bearAmount,
        address receiver,
        uint256 minSharesOut
    ) external nonReentrant whenNotPaused returns (uint256 glUsdMinted) {
        if (emergencyActive) {
            revert InvarCoin__EmergencyActive();
        }
        if (usdcAmount == 0 && bearAmount == 0) {
            revert InvarCoin__ZeroAmount();
        }
        _harvest();
        uint256 oraclePrice =
            OracleLib.getValidatedPrice(BASKET_ORACLE, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD, ORACLE_TIMEOUT);

        uint256 assets = _totalAssetsOptimistic(oraclePrice);
        uint256 supply = totalSupply();

        if (usdcAmount > 0) {
            USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);
        }
        if (bearAmount > 0) {
            BEAR.safeTransferFrom(msg.sender, address(this), bearAmount);
        }

        uint256[2] memory amounts = [usdcAmount, bearAmount];
        uint256 expectedLp = CURVE_POOL.calc_token_amount(amounts, true);
        uint256 totalUsdcValue = usdcAmount + (bearAmount * oraclePrice) / 1e20;
        uint256 emaExpectedLp = (totalUsdcValue * 1e30) / CURVE_POOL.lp_price();
        if (
            expectedLp * BPS < emaExpectedLp * (BPS - MAX_SPOT_DEVIATION_BPS)
                || expectedLp * BPS > emaExpectedLp * (BPS + MAX_SPOT_DEVIATION_BPS)
        ) {
            revert InvarCoin__SpotDeviationTooHigh();
        }
        uint256 lpMinted = CURVE_POOL.add_liquidity(amounts, expectedLp > 0 ? expectedLp - 1 : 0);
        trackedLpBalance += lpMinted;

        uint256 lpValue = (lpMinted * _pessimisticLpPrice(oraclePrice)) / 1e30;
        curveLpCostVp += (lpMinted * CURVE_POOL.get_virtual_price()) / 1e18;

        _stakeLpToGauge(lpMinted);

        glUsdMinted = Math.mulDiv(lpValue, supply + VIRTUAL_SHARES, assets + VIRTUAL_ASSETS);

        if (glUsdMinted < minSharesOut) {
            revert InvarCoin__SlippageExceeded();
        }

        _mint(receiver, glUsdMinted);
        emit LpDeposited(msg.sender, receiver, usdcAmount, bearAmount, glUsdMinted);
    }

    // ==========================================
    // KEEPER OPERATIONS & YIELD
    // ==========================================

    /// @notice Permissionless keeper harvest for Curve LP fee yield.
    /// @dev Measures fee yield as virtual price growth above the cost basis (curveLpCostVp).
    ///      Mints INVAR proportional to the USDC value of yield and donates it to sINVAR stakers.
    ///      Only tracks VP growth on vault-deployed LP (trackedLpBalance), not donated LP.
    ///      Reverts if no yield is available — use as a heartbeat signal for keepers.
    /// @return donated Amount of INVAR minted and donated to sINVAR.
    function harvest() external nonReentrant whenNotPaused returns (uint256 donated) {
        donated = _harvest();
        if (donated == 0) {
            revert InvarCoin__NoYield();
        }
    }

    /// @dev Harvest yield before withdrawals. Skips safely when no yield is pending or Curve is down.
    ///      When yield IS pending, harvest must succeed (oracle must be fresh) or the withdrawal reverts
    ///      to prevent withdrawers from extracting unharvested yield meant for sINVAR stakers.
    function _harvestSafe() internal {
        if (address(stakedInvarCoin) == address(0)) {
            return;
        }
        uint256 lpBal = trackedLpBalance;
        if (lpBal == 0) {
            return;
        }

        uint256 vp;
        try CURVE_POOL.get_virtual_price() returns (uint256 _vp) {
            vp = _vp;
        } catch {
            return;
        }

        uint256 currentVpValue = (lpBal * vp) / 1e18;
        if (currentVpValue <= curveLpCostVp) {
            return;
        }

        uint256 oraclePrice =
            OracleLib.getValidatedPrice(BASKET_ORACLE, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD, ORACLE_TIMEOUT);

        _harvestWithPrice(lpBal, currentVpValue, oraclePrice);
    }

    function _harvest() internal returns (uint256 donated) {
        if (address(stakedInvarCoin) == address(0)) {
            return 0;
        }

        uint256 lpBal = trackedLpBalance;
        if (lpBal > 0) {
            uint256 currentVpValue = (lpBal * CURVE_POOL.get_virtual_price()) / 1e18;
            if (currentVpValue > curveLpCostVp) {
                uint256 oraclePrice = OracleLib.getValidatedPrice(
                    BASKET_ORACLE, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD, ORACLE_TIMEOUT
                );
                donated = _harvestWithPrice(lpBal, currentVpValue, oraclePrice);
            }
        }
    }

    function _harvestWithPrice(
        uint256 lpBal,
        uint256 currentVpValue,
        uint256 oraclePrice
    ) private returns (uint256 donated) {
        uint256 vpGrowth = currentVpValue - curveLpCostVp;
        uint256 currentLpUsdc = (lpBal * _pessimisticLpPrice(oraclePrice)) / 1e30;
        uint256 totalYieldUsdc = Math.mulDiv(currentLpUsdc, vpGrowth, currentVpValue);

        if (totalYieldUsdc == 0) {
            return 0;
        }
        curveLpCostVp = currentVpValue;

        uint256 supply = totalSupply();
        uint256 currentAssets = _totalAssetsWithPrice(_lpBalance(), oraclePrice);
        uint256 assetsBeforeYield = currentAssets > totalYieldUsdc ? currentAssets - totalYieldUsdc : 0;

        donated = Math.mulDiv(totalYieldUsdc, supply + VIRTUAL_SHARES, assetsBeforeYield + VIRTUAL_ASSETS);

        _mint(address(this), donated);
        IERC20(this).approve(address(stakedInvarCoin), donated);
        stakedInvarCoin.donateYield(donated);

        emit YieldHarvested(donated, 0, donated);
    }

    /// @notice Accepts USDC donations from RewardDistributor, mints proportional INVAR, and donates to sINVAR.
    /// @param usdcAmount Amount of USDC to donate (6 decimals).
    function donateUsdc(
        uint256 usdcAmount
    ) external nonReentrant whenNotPaused {
        if (usdcAmount == 0) {
            revert InvarCoin__ZeroAmount();
        }
        if (address(stakedInvarCoin) == address(0)) {
            revert InvarCoin__StakingNotSet();
        }

        _harvest();

        uint256 oraclePrice =
            OracleLib.getValidatedPrice(BASKET_ORACLE, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD, ORACLE_TIMEOUT);

        uint256 supply = totalSupply();
        uint256 assetsBefore = _totalAssetsOptimistic(oraclePrice);

        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);

        uint256 invarMinted = Math.mulDiv(usdcAmount, supply + VIRTUAL_SHARES, assetsBefore + VIRTUAL_ASSETS);
        if (invarMinted == 0) {
            return;
        }

        _mint(address(this), invarMinted);
        IERC20(this).approve(address(stakedInvarCoin), invarMinted);
        stakedInvarCoin.donateYield(invarMinted);

        emit UsdcDonated(msg.sender, usdcAmount, invarMinted);
    }

    /// @notice Permissionless keeper function: deploys excess USDC buffer into Curve as single-sided liquidity.
    /// @dev Maintains a 2% USDC buffer (BUFFER_TARGET_BPS). Only deploys if excess exceeds DEPLOY_THRESHOLD ($1000).
    ///      Spot-vs-EMA deviation check (MAX_SPOT_DEVIATION_BPS = 0.5%) blocks deployment during pool manipulation.
    /// @param maxUsdc Cap on USDC to deploy (0 = no cap, deploy entire excess).
    /// @return lpMinted Amount of Curve LP tokens minted.
    function deployToCurve(
        uint256 maxUsdc
    ) external nonReentrant whenNotPaused returns (uint256 lpMinted) {
        uint256 oraclePrice =
            OracleLib.getValidatedPrice(BASKET_ORACLE, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD, ORACLE_TIMEOUT);
        uint256 assets = _totalAssetsWithPrice(_lpBalance(), oraclePrice);
        uint256 bufferTarget = (assets * BUFFER_TARGET_BPS) / BPS;

        uint256 localUsdc = USDC.balanceOf(address(this));

        if (localUsdc <= bufferTarget || localUsdc - bufferTarget < DEPLOY_THRESHOLD) {
            revert InvarCoin__NothingToDeploy();
        }

        uint256 usdcToDeploy = localUsdc - bufferTarget;
        if (maxUsdc > 0 && maxUsdc < usdcToDeploy) {
            usdcToDeploy = maxUsdc;
        }

        uint256[2] memory amounts = [usdcToDeploy, uint256(0)];
        uint256 calcLp = CURVE_POOL.calc_token_amount(amounts, true);
        uint256 emaExpectedLp = (usdcToDeploy * 1e30) / CURVE_POOL.lp_price();
        if (calcLp * BPS < emaExpectedLp * (BPS - MAX_SPOT_DEVIATION_BPS)) {
            revert InvarCoin__SpotDeviationTooHigh();
        }
        lpMinted = CURVE_POOL.add_liquidity(amounts, calcLp > 0 ? calcLp - 1 : 0);
        trackedLpBalance += lpMinted;
        curveLpCostVp += (lpMinted * CURVE_POOL.get_virtual_price()) / 1e18;

        _stakeLpToGauge(lpMinted);

        emit DeployedToCurve(msg.sender, usdcToDeploy, 0, lpMinted);
    }

    /// @notice Permissionless keeper function: restores USDC buffer by burning Curve LP (single-sided to USDC).
    /// @dev Inverse of deployToCurve. Uses same spot-vs-EMA deviation check for sandwich protection.
    ///      The maxLpToBurn parameter allows chunked replenishment when the full withdrawal would
    ///      exceed the 0.5% spot deviation limit due to price impact.
    /// @param maxLpToBurn Cap on LP tokens to burn (0 = no cap, burn entire deficit).
    function replenishBuffer(
        uint256 maxLpToBurn
    ) external nonReentrant whenNotPaused returns (uint256 usdcRecovered) {
        _harvestSafe();
        uint256 oraclePrice =
            OracleLib.getValidatedPrice(BASKET_ORACLE, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD, ORACLE_TIMEOUT);
        uint256 lpBalBefore = _lpBalance();
        uint256 assets = _totalAssetsWithPrice(lpBalBefore, oraclePrice);
        uint256 bufferTarget = (assets * BUFFER_TARGET_BPS) / BPS;

        uint256 currentBuffer = USDC.balanceOf(address(this));

        if (currentBuffer >= bufferTarget) {
            revert InvarCoin__NothingToDeploy();
        }

        if (lpBalBefore == 0) {
            revert InvarCoin__NothingToDeploy();
        }
        uint256 usdcBefore = currentBuffer;

        uint256 maxReplenish = bufferTarget - currentBuffer;
        uint256 lpPrice = CURVE_POOL.lp_price();
        uint256 lpToBurn = (maxReplenish * 1e30) / lpPrice;
        if (lpToBurn > lpBalBefore) {
            lpToBurn = lpBalBefore;
        }
        if (maxLpToBurn > 0 && maxLpToBurn < lpToBurn) {
            lpToBurn = maxLpToBurn;
        }

        uint256 calcOut = CURVE_POOL.calc_withdraw_one_coin(lpToBurn, USDC_INDEX);
        uint256 emaExpectedUsdc = (lpToBurn * lpPrice) / 1e30;
        if (calcOut * BPS < emaExpectedUsdc * (BPS - MAX_SPOT_DEVIATION_BPS)) {
            revert InvarCoin__SpotDeviationTooHigh();
        }
        _ensureUnstakedLp(lpToBurn);
        CURVE_POOL.remove_liquidity_one_coin(lpToBurn, USDC_INDEX, calcOut * (BPS - 5) / BPS);
        trackedLpBalance -= Math.mulDiv(trackedLpBalance, lpToBurn, lpBalBefore);
        curveLpCostVp -= Math.mulDiv(curveLpCostVp, lpToBurn, lpBalBefore);

        usdcRecovered = USDC.balanceOf(address(this)) - usdcBefore;

        emit BufferReplenished(lpToBurn, usdcRecovered);
    }

    // ==========================================
    // EMERGENCY & ADMIN
    // ==========================================

    /// @notice Re-deploys recovered BEAR + excess USDC to Curve after emergency recovery.
    /// @dev Clears emergencyActive flag. Should only be called after emergencyWithdrawFromCurve()
    ///      has recovered the BEAR tokens from the pool.
    /// @param minLpOut Minimum LP tokens to mint (slippage protection for the two-sided deposit).
    function redeployToCurve(
        uint256 minLpOut
    ) external onlyOwner nonReentrant {
        uint256 bearBal = BEAR.balanceOf(address(this));
        if (bearBal == 0) {
            revert InvarCoin__NothingToDeploy();
        }

        uint256 assets = totalAssets();
        uint256 bufferTarget = (assets * BUFFER_TARGET_BPS) / BPS;
        uint256 localUsdc = USDC.balanceOf(address(this));
        uint256 usdcToDeploy = localUsdc > bufferTarget ? localUsdc - bufferTarget : 0;

        uint256[2] memory amounts = [usdcToDeploy, bearBal];
        uint256 lpMinted = CURVE_POOL.add_liquidity(amounts, minLpOut);
        trackedLpBalance += lpMinted;
        curveLpCostVp += (lpMinted * CURVE_POOL.get_virtual_price()) / 1e18;
        emergencyActive = false;

        _stakeLpToGauge(lpMinted);

        emit DeployedToCurve(msg.sender, usdcToDeploy, bearBal, lpMinted);
    }

    /// @notice Activates emergency mode without touching Curve.
    /// @dev Pauses the contract and blocks deposits plus single-sided withdrawals.
    ///      LP accounting is left intact so users retain their pro-rata claim once balanced exits recover.
    function setEmergencyMode() external onlyOwner {
        emergencyActive = true;
        if (!paused()) {
            _pause();
        }
    }

    /// @notice Attempts to recover LP tokens from Curve via balanced remove_liquidity.
    /// @dev Also callable as a standalone emergency — sets emergencyActive, pauses, and only zeroes
    ///      tracked LP accounting after the LP has actually been recovered.
    ///      If Curve is bricked, the remove_liquidity call reverts and the entire tx rolls back,
    ///      leaving state unchanged. Use setEmergencyMode() first in that case.
    function emergencyWithdrawFromCurve() external onlyOwner nonReentrant {
        uint256 lpBal = _lpBalance();
        emergencyActive = true;
        if (!paused()) {
            _pause();
        }

        uint256[2] memory received;
        if (lpBal > 0) {
            _ensureUnstakedLp(lpBal);
            received = CURVE_POOL.remove_liquidity(lpBal, [uint256(0), uint256(0)]);
        }
        trackedLpBalance = 0;
        curveLpCostVp = 0;
        emit EmergencyWithdrawCurve(lpBal, received[0], received[1]);
    }

    function setGaugeApproval(
        address gauge,
        bool approved
    ) external onlyOwner {
        if (approved) {
            _validateGaugeAddress(gauge);
        }
        approvedGauges[gauge] = approved;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Rescue accidentally sent ERC20 tokens. Cannot rescue USDC, BEAR, or Curve LP.
    /// @param token Address of the token to rescue.
    /// @param to Destination address for the rescued tokens.
    function rescueToken(
        address token,
        address to
    ) external onlyOwner {
        if (
            token == address(USDC) || token == address(BEAR) || token == address(CURVE_LP_TOKEN)
                || token == address(curveGauge) || protectedRewardTokens[token]
        ) {
            revert InvarCoin__CannotRescueCoreAsset();
        }
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, balance);
        emit TokenRescued(token, to, balance);
    }

    // ==========================================
    // CURVE GAUGE STAKING
    // ==========================================

    /// @notice Propose a new Curve gauge for LP staking. Subject to GAUGE_TIMELOCK delay.
    /// @param _gauge Address of the new gauge (address(0) to remove gauge).
    function proposeGauge(
        address _gauge
    ) external onlyOwner {
        if (_gauge == address(curveGauge)) {
            revert InvarCoin__InvalidProposal();
        }
        _validateGauge(_gauge);
        pendingGauge = _gauge;
        gaugeActivationTime = block.timestamp + GAUGE_TIMELOCK;
        emit GaugeProposed(_gauge, gaugeActivationTime);
    }

    /// @notice Finalize a pending gauge change after the timelock expires.
    /// @dev This MUST revert if oldGauge.withdraw() fails. Do NOT wrap in try/catch:
    ///      silent failure would update curveGauge to newGauge while LP stays locked in
    ///      oldGauge, causing _lpBalance() to forget the stuck LP and collapsing totalAssets().
    ///      If the old gauge is permanently bricked, use setEmergencyMode() instead.
    function finalizeGauge() external onlyOwner {
        if (gaugeActivationTime == 0 || block.timestamp < gaugeActivationTime) {
            revert InvarCoin__GaugeTimelockActive();
        }

        ICurveGauge oldGauge = curveGauge;
        address newGauge = pendingGauge;

        _validateGauge(newGauge);

        if (address(oldGauge) != address(0)) {
            uint256 stakedBal = oldGauge.balanceOf(address(this));
            if (stakedBal > 0) {
                oldGauge.withdraw(stakedBal);
            }
            CURVE_LP_TOKEN.approve(address(oldGauge), 0);
        }

        curveGauge = ICurveGauge(newGauge);
        pendingGauge = address(0);
        gaugeActivationTime = 0;

        if (newGauge != address(0)) {
            uint256 lpBal = CURVE_LP_TOKEN.balanceOf(address(this));
            _stakeLpToGauge(lpBal);
        }

        emit GaugeUpdated(address(oldGauge), newGauge);
    }

    /// @notice Stake LP tokens to the active Curve gauge.
    /// @param amount Amount of LP to stake (0 = all unstaked LP).
    function stakeToGauge(
        uint256 amount
    ) external onlyOwner {
        ICurveGauge gauge = curveGauge;
        if (address(gauge) == address(0)) {
            revert InvarCoin__NoGauge();
        }
        if (amount == 0) {
            amount = CURVE_LP_TOKEN.balanceOf(address(this));
        }
        if (amount == 0) {
            revert InvarCoin__ZeroAmount();
        }
        _stakeLpToGauge(amount);
        emit GaugeStaked(amount);
    }

    /// @notice Unstake LP tokens from the active Curve gauge.
    /// @param amount Amount of LP to unstake (0 = all staked LP).
    function unstakeFromGauge(
        uint256 amount
    ) external onlyOwner {
        ICurveGauge gauge = curveGauge;
        if (address(gauge) == address(0)) {
            revert InvarCoin__NoGauge();
        }
        if (amount == 0) {
            amount = gauge.balanceOf(address(this));
        }
        if (amount == 0) {
            revert InvarCoin__ZeroAmount();
        }
        gauge.withdraw(amount);
        emit GaugeUnstaked(amount);
    }

    /// @notice Claim CRV + extra rewards from the gauge. Use rescueToken() to sweep reward tokens.
    /// @dev On L1, CRV is minted via the Curve Minter (not claim_rewards). On L2, claim_rewards handles CRV.
    function claimGaugeRewards() external onlyOwner {
        ICurveGauge gauge = curveGauge;
        if (address(gauge) == address(0)) {
            revert InvarCoin__NoGauge();
        }
        if (address(CRV_MINTER) != address(0)) {
            CRV_MINTER.mint(address(gauge));
        }
        gauge.claim_rewards();
        emit GaugeRewardsClaimed();
    }

}
