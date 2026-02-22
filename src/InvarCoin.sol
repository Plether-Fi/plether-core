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
import {OracleLib} from "./libraries/OracleLib.sol";

interface ICurveTwocrypto {

    function add_liquidity(
        uint256[2] calldata amounts,
        uint256 min_mint_amount
    ) external returns (uint256);
    function remove_liquidity_one_coin(
        uint256 token_amount,
        uint256 i,
        uint256 min_amount
    ) external returns (uint256);
    function remove_liquidity(
        uint256 amount,
        uint256[2] calldata min_amounts
    ) external returns (uint256[2] memory);
    function get_virtual_price() external view returns (uint256);
    function lp_price() external view returns (uint256);
    function calc_token_amount(
        uint256[2] calldata amounts,
        bool deposit
    ) external view returns (uint256);
    function calc_withdraw_one_coin(
        uint256 token_amount,
        uint256 i
    ) external view returns (uint256);

}

/// @title InvarCoin (INVAR)
/// @custom:security-contact contact@plether.com
/// @notice Retail-friendly global purchasing power token backed 50/50 by USDC + plDXY-BEAR.
/// @dev Combines asynchronous batching, exact yield stripping, and flash-loan resistant NAV.
contract InvarCoin is ERC20, ERC20Permit, Ownable2Step, Pausable, ReentrancyGuard {

    using SafeERC20 for IERC20;

    // ==========================================
    // IMMUTABLES & CONSTANTS
    // ==========================================

    IERC20 public immutable USDC;
    IERC20 public immutable BEAR;
    IERC20 public immutable CURVE_LP_TOKEN;
    ICurveTwocrypto public immutable CURVE_POOL;
    AggregatorV3Interface public immutable BASKET_ORACLE;
    AggregatorV3Interface public immutable SEQUENCER_UPTIME_FEED;

    uint256 public constant BUFFER_TARGET_BPS = 200; // 2% target buffer
    uint256 public constant DEPLOY_THRESHOLD = 1000e6; // Min $1000 to deploy
    uint256 public constant MAX_DEPLOY_SLIPPAGE_BPS = 100; // 1% max slippage
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

    StakedToken public stakedInvarCoin;
    uint256 public curveLpCostVp;
    uint256 public trackedLpBalance;
    bool public emergencyActive;

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

    error InvarCoin__ZeroAmount();
    error InvarCoin__ZeroAddress();
    error InvarCoin__SlippageExceeded();
    error InvarCoin__NothingToDeploy();
    error InvarCoin__NoYield();
    error InvarCoin__CannotRescueCoreAsset();
    error InvarCoin__PermitFailed();
    error InvarCoin__AlreadySet();
    error InvarCoin__SpotDeviationTooHigh();
    error InvarCoin__UseLpWithdraw();

    constructor(
        address _usdc,
        address _bear,
        address _curveLpToken,
        address _curvePool,
        address _oracle,
        address _sequencerUptimeFeed
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

        USDC.safeIncreaseAllowance(_curvePool, type(uint256).max);
        BEAR.safeIncreaseAllowance(_curvePool, type(uint256).max);
    }

    function setStakedInvarCoin(
        address _stakedInvarCoin
    ) external onlyOwner {
        if (_stakedInvarCoin == address(0)) {
            revert InvarCoin__ZeroAddress();
        }
        if (address(stakedInvarCoin) != address(0)) {
            revert InvarCoin__AlreadySet();
        }
        stakedInvarCoin = StakedToken(_stakedInvarCoin);
    }

    // ==========================================
    // NAV CALCULATION (Safe from Flash Loans)
    // ==========================================

    /// @notice Total assets backing INVAR (USDC, 6 decimals).
    /// @dev Uses pessimistic LP pricing: min(Curve EMA, oracle-derived) to prevent stale-EMA exploitation.
    function totalAssets() public view returns (uint256) {
        uint256 localUsdc = USDC.balanceOf(address(this));

        (, int256 rawPrice,,,) = BASKET_ORACLE.latestRoundData();
        uint256 oraclePrice = rawPrice > 0 ? uint256(rawPrice) : 0;

        uint256 lpBal = CURVE_LP_TOKEN.balanceOf(address(this));
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

    /// @dev Total assets using optimistic LP pricing — max(EMA, oracle) to prevent deposit dilution.
    function _totalAssetsOptimistic(
        uint256 oraclePrice
    ) private view returns (uint256) {
        uint256 localUsdc = USDC.balanceOf(address(this));

        uint256 lpBal = CURVE_LP_TOKEN.balanceOf(address(this));
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

    // ==========================================
    // RETAIL FLOWS (Cheap & Gas Efficient)
    // ==========================================

    function deposit(
        uint256 usdcAmount,
        address receiver
    ) public nonReentrant whenNotPaused returns (uint256 glUsdMinted) {
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

        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);

        _mint(receiver, glUsdMinted);
        emit Deposited(msg.sender, receiver, usdcAmount, glUsdMinted);
    }

    function depositWithPermit(
        uint256 usdcAmount,
        address receiver,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256) {
        // Safe permit wrapper against mempool griefing
        try IERC20Permit(address(USDC)).permit(msg.sender, address(this), usdcAmount, deadline, v, r, s) {}
        catch {
            if (USDC.allowance(msg.sender, address(this)) < usdcAmount) {
                revert InvarCoin__PermitFailed();
            }
        }
        return deposit(usdcAmount, receiver);
    }

    /// @notice USDC-only withdrawal via pro-rata buffer + JIT Curve LP burn.
    ///      Does not distribute raw BEAR balances — use lpWithdraw() if the contract holds BEAR.
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

        uint256 lpBal = CURVE_LP_TOKEN.balanceOf(address(this));
        if (lpBal > 0) {
            uint256 lpShare = Math.mulDiv(lpBal, glUsdAmount, supply);
            if (lpShare > 0) {
                uint256 minCurveOut = minUsdcOut > usdcOut ? minUsdcOut - usdcOut : 0;
                usdcOut += CURVE_POOL.remove_liquidity_one_coin(lpShare, USDC_INDEX, minCurveOut);
                trackedLpBalance -= Math.mulDiv(trackedLpBalance, lpShare, lpBal);
                curveLpCostVp -= Math.mulDiv(curveLpCostVp, lpShare, lpBal);
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

    /// @notice LP withdrawal: bypasses buffer and unwinds Curve LP pro-rata.
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

        uint256 lpBal = CURVE_LP_TOKEN.balanceOf(address(this));
        if (lpBal > 0) {
            uint256 lpToBurn = Math.mulDiv(lpBal, glUsdAmount, supply);
            trackedLpBalance -= Math.mulDiv(trackedLpBalance, lpToBurn, lpBal);
            curveLpCostVp -= Math.mulDiv(curveLpCostVp, lpToBurn, lpBal);
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

    /// @notice Direct LP deposit: provide USDC + BEAR, deploy to Curve, mint INVAR.
    /// @dev Inverse of lpWithdraw. Curve slippage borne by the depositor, not existing holders.
    function lpDeposit(
        uint256 usdcAmount,
        uint256 bearAmount,
        address receiver,
        uint256 minSharesOut
    ) external nonReentrant whenNotPaused returns (uint256 glUsdMinted) {
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
        if (expectedLp * BPS < emaExpectedLp * (BPS - MAX_SPOT_DEVIATION_BPS)) {
            revert InvarCoin__SpotDeviationTooHigh();
        }
        uint256 lpMinted = CURVE_POOL.add_liquidity(amounts, expectedLp > 0 ? expectedLp - 1 : 0);
        trackedLpBalance += lpMinted;

        uint256 lpValue = (lpMinted * _pessimisticLpPrice(oraclePrice)) / 1e30;
        curveLpCostVp += (lpMinted * CURVE_POOL.get_virtual_price()) / 1e18;

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

    /// @notice Keeper harvest for Curve LP fee yield.
    /// @dev Mints INVAR proportional to yield, donates to sINVAR stakers.
    function harvest() external nonReentrant whenNotPaused returns (uint256 donated) {
        donated = _harvest();
        if (donated == 0) {
            revert InvarCoin__NoYield();
        }
    }

    /// @dev Best-effort harvest that silently skips on oracle failure, preserving withdrawal liveness.
    function _harvestSafe() internal {
        if (address(stakedInvarCoin) == address(0)) {
            return;
        }
        uint256 lpBal = trackedLpBalance;
        if (lpBal == 0) {
            return;
        }
        uint256 currentVpValue = (lpBal * CURVE_POOL.get_virtual_price()) / 1e18;
        if (currentVpValue <= curveLpCostVp) {
            return;
        }
        try BASKET_ORACLE.latestRoundData() returns (uint80, int256 rawPrice, uint256, uint256 updatedAt, uint80) {
            if (rawPrice <= 0 || block.timestamp - updatedAt > ORACLE_TIMEOUT) {
                return;
            }
            _harvestWithPrice(lpBal, currentVpValue, uint256(rawPrice));
        } catch {
            return;
        }
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
        uint256 currentAssets = totalAssets();
        uint256 assetsBeforeYield = currentAssets > totalYieldUsdc ? currentAssets - totalYieldUsdc : 0;

        donated = Math.mulDiv(totalYieldUsdc, supply + VIRTUAL_SHARES, assetsBeforeYield + VIRTUAL_ASSETS);

        _mint(address(this), donated);
        IERC20(this).approve(address(stakedInvarCoin), donated);
        stakedInvarCoin.donateYield(donated);

        emit YieldHarvested(donated, 0, donated);
    }

    /// @notice Keeper function: Deploys excess USDC buffer into Curve as single-sided liquidity.
    /// @param maxUsdc Cap on USDC to deploy (0 = no cap, deploy entire excess).
    function deployToCurve(
        uint256 maxUsdc
    ) external nonReentrant whenNotPaused returns (uint256 lpMinted) {
        uint256 assets = totalAssets();
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

        emit DeployedToCurve(msg.sender, usdcToDeploy, 0, lpMinted);
    }

    /// @notice Keeper function: Restores USDC buffer by burning Curve LP.
    function replenishBuffer() external nonReentrant whenNotPaused {
        uint256 assets = totalAssets();
        uint256 bufferTarget = (assets * BUFFER_TARGET_BPS) / BPS;

        uint256 currentBuffer = USDC.balanceOf(address(this));

        if (currentBuffer >= bufferTarget) {
            revert InvarCoin__NothingToDeploy();
        }

        uint256 lpBalBefore = CURVE_LP_TOKEN.balanceOf(address(this));
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

        uint256 calcOut = CURVE_POOL.calc_withdraw_one_coin(lpToBurn, USDC_INDEX);
        uint256 emaExpectedUsdc = (lpToBurn * lpPrice) / 1e30;
        if (calcOut * BPS < emaExpectedUsdc * (BPS - MAX_SPOT_DEVIATION_BPS)) {
            revert InvarCoin__SpotDeviationTooHigh();
        }
        CURVE_POOL.remove_liquidity_one_coin(lpToBurn, USDC_INDEX, calcOut * (BPS - 5) / BPS);
        trackedLpBalance -= Math.mulDiv(trackedLpBalance, lpToBurn, lpBalBefore);
        curveLpCostVp -= Math.mulDiv(curveLpCostVp, lpToBurn, lpBalBefore);

        uint256 usdcRecovered = USDC.balanceOf(address(this)) - usdcBefore;

        emit BufferReplenished(lpToBurn, usdcRecovered);
    }

    // ==========================================
    // EMERGENCY & ADMIN
    // ==========================================

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

        emit DeployedToCurve(msg.sender, usdcToDeploy, bearBal, lpMinted);
    }

    function emergencyWithdrawFromCurve() external onlyOwner nonReentrant {
        uint256 lpBal = CURVE_LP_TOKEN.balanceOf(address(this));
        trackedLpBalance = 0;
        curveLpCostVp = 0;
        emergencyActive = true;
        if (!paused()) {
            _pause();
        }

        uint256[2] memory received;
        if (lpBal > 0) {
            received = CURVE_POOL.remove_liquidity(lpBal, [uint256(0), uint256(0)]);
        }
        emit EmergencyWithdrawCurve(lpBal, received[0], received[1]);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function rescueToken(
        address token,
        address to
    ) external onlyOwner {
        if (token == address(USDC) || token == address(BEAR) || token == address(CURVE_LP_TOKEN)) {
            revert InvarCoin__CannotRescueCoreAsset();
        }
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, balance);
        emit TokenRescued(token, to, balance);
    }

}
