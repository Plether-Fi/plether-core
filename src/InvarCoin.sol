// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
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
import {DecimalConstants} from "./libraries/DecimalConstants.sol";
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
    IERC4626 public immutable MORPHO_VAULT;
    ICurveTwocrypto public immutable CURVE_POOL;
    AggregatorV3Interface public immutable BASKET_ORACLE;
    AggregatorV3Interface public immutable SEQUENCER_UPTIME_FEED;

    uint256 public constant BUFFER_TARGET_BPS = 1000; // 10% target buffer
    uint256 public constant DEPLOY_THRESHOLD = 1000e6; // Min $1000 to deploy
    uint256 public constant MAX_DEPLOY_SLIPPAGE_BPS = 100; // 1% max slippage
    uint256 public constant HARVEST_CALLER_REWARD_BPS = 10; // 0.1% caller reward

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

    address public rewardDistributor;
    StakedToken public stakedInvarCoin;
    uint256 public morphoPrincipal;

    // ==========================================
    // EVENTS & ERRORS
    // ==========================================

    event Deposited(address indexed user, address indexed receiver, uint256 usdcIn, uint256 glUsdOut);
    event Withdrawn(address indexed user, address indexed receiver, uint256 glUsdIn, uint256 usdcOut);
    event WhaleExit(address indexed user, uint256 sharesBurned, uint256 usdcReturned, uint256 bearReturned);
    event DeployedToCurve(address indexed caller, uint256 usdcDeployed, uint256 bearDeployed, uint256 lpMinted);
    event BufferReplenished(uint256 lpBurned, uint256 usdcRecovered);
    event YieldHarvested(uint256 glUsdMinted, uint256 callerReward, uint256 donated);
    event BearYieldDonated(address indexed donor, uint256 bearAmount);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event EmergencyWithdrawCurve(uint256 lpBurned, uint256 usdcReceived, uint256 bearReceived);
    event EmergencyWithdrawMorpho(uint256 sharesBurned, uint256 usdcReceived);

    error InvarCoin__ZeroAmount();
    error InvarCoin__ZeroAddress();
    error InvarCoin__SlippageExceeded();
    error InvarCoin__InsufficientBuffer();
    error InvarCoin__NothingToDeploy();
    error InvarCoin__NoYield();
    error InvarCoin__CannotRescueCoreAsset();
    error InvarCoin__Unauthorized();
    error InvarCoin__PermitFailed();

    constructor(
        address _usdc,
        address _bear,
        address _curveLpToken,
        address _morphoVault,
        address _curvePool,
        address _oracle,
        address _sequencerUptimeFeed
    ) ERC20("InvarCoin", "INVAR") ERC20Permit("InvarCoin") Ownable(msg.sender) {
        if (
            _usdc == address(0) || _bear == address(0) || _curveLpToken == address(0) || _morphoVault == address(0)
                || _curvePool == address(0) || _oracle == address(0)
        ) {
            revert InvarCoin__ZeroAddress();
        }

        USDC = IERC20(_usdc);
        BEAR = IERC20(_bear);
        CURVE_LP_TOKEN = IERC20(_curveLpToken);
        MORPHO_VAULT = IERC4626(_morphoVault);
        CURVE_POOL = ICurveTwocrypto(_curvePool);
        BASKET_ORACLE = AggregatorV3Interface(_oracle);
        SEQUENCER_UPTIME_FEED = AggregatorV3Interface(_sequencerUptimeFeed);

        USDC.safeIncreaseAllowance(_morphoVault, type(uint256).max);
        USDC.safeIncreaseAllowance(_curvePool, type(uint256).max);
        BEAR.safeIncreaseAllowance(_curvePool, type(uint256).max);
    }

    function setIntegrations(
        address _rewardDistributor,
        address _stakedInvarCoin
    ) external onlyOwner {
        rewardDistributor = _rewardDistributor;
        stakedInvarCoin = StakedToken(_stakedInvarCoin);
    }

    // ==========================================
    // NAV CALCULATION (Safe from Flash Loans)
    // ==========================================

    /// @notice Total assets backing INVAR (USDC, 6 decimals).
    /// @dev Uses virtual_price to remain strictly flash-loan resistant.
    function totalAssets() public view returns (uint256) {
        // 1. Morpho Buffer
        uint256 localUsdc = USDC.balanceOf(address(this));
        uint256 adapterShares = MORPHO_VAULT.balanceOf(address(this));
        uint256 bufferValue = localUsdc + (adapterShares > 0 ? MORPHO_VAULT.convertToAssets(adapterShares) : 0);

        // 2. Pending Arbitrage BEAR
        uint256 localBear = BEAR.balanceOf(address(this));
        uint256 bearUsdcValue = 0;
        if (localBear > 0) {
            uint256 bearPrice8 = OracleLib.getValidatedPrice(
                BASKET_ORACLE, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD, ORACLE_TIMEOUT
            );
            bearUsdcValue = (localBear * bearPrice8) / DecimalConstants.USDC_TO_TOKEN_SCALE;
        }

        // 3. Curve LP Position
        // SAFE: lp_price() uses monotonic virtual_price + EMA price oracle, immune to flash loans
        uint256 lpBal = CURVE_LP_TOKEN.balanceOf(address(this));
        uint256 lpUsdcValue = 0;
        if (lpBal > 0) {
            lpUsdcValue = (lpBal * CURVE_POOL.lp_price()) / 1e30;
        }

        return bufferValue + bearUsdcValue + lpUsdcValue;
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
        OracleLib.getValidatedPrice(BASKET_ORACLE, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD, ORACLE_TIMEOUT);

        uint256 assets = totalAssets();
        uint256 supply = totalSupply();

        // Virtual shares math against inflation attacks
        glUsdMinted = Math.mulDiv(usdcAmount, supply + VIRTUAL_SHARES, assets + VIRTUAL_ASSETS);

        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Sweep directly into Morpho to earn baseline yield
        MORPHO_VAULT.deposit(usdcAmount, address(this));
        morphoPrincipal += usdcAmount;

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

    /// @notice Retail withdrawal exclusively using the safe local buffer.
    function withdraw(
        uint256 glUsdAmount,
        address receiver,
        uint256 minUsdcOut
    ) external nonReentrant returns (uint256 usdcOut) {
        if (glUsdAmount == 0) {
            revert InvarCoin__ZeroAmount();
        }
        OracleLib.getValidatedPrice(BASKET_ORACLE, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD, ORACLE_TIMEOUT);

        uint256 assets = totalAssets();
        uint256 supply = totalSupply();
        usdcOut = Math.mulDiv(glUsdAmount, assets + VIRTUAL_ASSETS, supply + VIRTUAL_SHARES);

        if (usdcOut < minUsdcOut) {
            revert InvarCoin__SlippageExceeded();
        }

        uint256 localUsdc = USDC.balanceOf(address(this));
        uint256 morphoAssets = MORPHO_VAULT.maxWithdraw(address(this));

        if (usdcOut > localUsdc + morphoAssets) {
            revert InvarCoin__InsufficientBuffer();
        }

        _burn(msg.sender, glUsdAmount);
        morphoPrincipal = morphoPrincipal > usdcOut ? morphoPrincipal - usdcOut : 0;

        if (usdcOut > localUsdc) {
            MORPHO_VAULT.withdraw(usdcOut - localUsdc, address(this), address(this));
        }

        USDC.safeTransfer(receiver, usdcOut);
        emit Withdrawn(msg.sender, receiver, glUsdAmount, usdcOut);
    }

    // ==========================================
    // WHALE FLOW (Deep Liquidity Exit)
    // ==========================================

    /// @notice Deep exit for whales. Bypasses buffer and forcibly unwinds Curve LP.
    /// @dev User receives a mix of USDC and BEAR, paying AMM gas/slippage themselves.
    function whaleExit(
        uint256 glUsdAmount,
        uint256 minUsdcOut,
        uint256 minBearOut
    ) external nonReentrant returns (uint256 usdcReturned, uint256 bearReturned) {
        if (glUsdAmount == 0) {
            revert InvarCoin__ZeroAmount();
        }

        uint256 supply = totalSupply();
        _burn(msg.sender, glUsdAmount);

        // 1. Pro-rata local USDC / Morpho
        uint256 localUsdcBefore = USDC.balanceOf(address(this));

        uint256 morphoShares = MORPHO_VAULT.balanceOf(address(this));
        if (morphoShares > 0) {
            uint256 sharesToBurn = Math.mulDiv(morphoShares, glUsdAmount, supply);
            uint256 withdrawn = MORPHO_VAULT.redeem(sharesToBurn, address(this), address(this));
            usdcReturned += withdrawn;
            morphoPrincipal = morphoPrincipal > withdrawn ? morphoPrincipal - withdrawn : 0;
        }

        uint256 localUsdcShare = Math.mulDiv(localUsdcBefore, glUsdAmount, supply);
        usdcReturned += localUsdcShare;

        // 2. Pro-rata Local BEAR (pending deployment)
        uint256 localBear = BEAR.balanceOf(address(this));
        if (localBear > 0) {
            bearReturned += Math.mulDiv(localBear, glUsdAmount, supply);
        }

        // 3. Pro-rata Curve LP
        uint256 lpBal = CURVE_LP_TOKEN.balanceOf(address(this));
        if (lpBal > 0) {
            uint256 lpToBurn = Math.mulDiv(lpBal, glUsdAmount, supply);
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

        emit WhaleExit(msg.sender, glUsdAmount, usdcReturned, bearReturned);
    }

    // ==========================================
    // KEEPER OPERATIONS & YIELD
    // ==========================================

    /// @notice Hook for RewardDistributor to donate arbitrage yield.
    function donateBearYield(
        uint256 amount
    ) external nonReentrant {
        if (msg.sender != rewardDistributor) {
            revert InvarCoin__Unauthorized();
        }
        if (amount == 0) {
            return;
        }

        BEAR.safeTransferFrom(msg.sender, address(this), amount);

        // Strip yield based on strict oracle price
        uint256 bearPrice8 =
            OracleLib.getValidatedPrice(BASKET_ORACLE, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD, ORACLE_TIMEOUT);
        uint256 yieldUsdcValue = (amount * bearPrice8) / DecimalConstants.USDC_TO_TOKEN_SCALE;

        if (yieldUsdcValue > 0 && address(stakedInvarCoin) != address(0)) {
            uint256 assetsBeforeYield = totalAssets() - yieldUsdcValue;
            uint256 supply = totalSupply();
            if (assetsBeforeYield > 0 && supply > 0) {
                uint256 sharesToMint =
                    Math.mulDiv(yieldUsdcValue, supply + VIRTUAL_SHARES, assetsBeforeYield + VIRTUAL_ASSETS);
                if (sharesToMint > 0) {
                    _mint(address(this), sharesToMint);
                    _approve(address(this), address(stakedInvarCoin), sharesToMint);
                    stakedInvarCoin.donateYield(sharesToMint);
                }
            }
        }

        emit BearYieldDonated(msg.sender, amount);
    }

    /// @notice Keeper function to harvest Morpho lending interest.
    function harvestYield() external nonReentrant whenNotPaused returns (uint256 glUsdDonated) {
        if (address(stakedInvarCoin) == address(0)) {
            revert InvarCoin__Unauthorized();
        }

        uint256 morphoShares = MORPHO_VAULT.balanceOf(address(this));
        uint256 currentMorphoUsdc = morphoShares > 0 ? MORPHO_VAULT.convertToAssets(morphoShares) : 0;

        if (currentMorphoUsdc <= morphoPrincipal) {
            revert InvarCoin__NoYield();
        }
        uint256 morphoYieldUsdc = currentMorphoUsdc - morphoPrincipal;

        uint256 assetsBeforeYield = totalAssets() - morphoYieldUsdc;
        uint256 supply = totalSupply();

        uint256 glUsdToMint = Math.mulDiv(morphoYieldUsdc, supply + VIRTUAL_SHARES, assetsBeforeYield + VIRTUAL_ASSETS);
        morphoPrincipal = currentMorphoUsdc;

        uint256 callerReward = (glUsdToMint * HARVEST_CALLER_REWARD_BPS) / BPS;
        glUsdDonated = glUsdToMint - callerReward;

        _mint(address(this), glUsdDonated);
        _approve(address(this), address(stakedInvarCoin), glUsdDonated);
        stakedInvarCoin.donateYield(glUsdDonated);

        if (callerReward > 0) {
            _mint(msg.sender, callerReward);
        }

        emit YieldHarvested(glUsdToMint, callerReward, glUsdDonated);
    }

    /// @notice Keeper function: Deploys dual-sided liquidity into Curve
    function deployToCurve(
        uint256 minLpOut
    ) external nonReentrant whenNotPaused returns (uint256 lpMinted) {
        uint256 assets = totalAssets();
        uint256 bufferTarget = (assets * BUFFER_TARGET_BPS) / BPS;

        uint256 morphoShares = MORPHO_VAULT.balanceOf(address(this));
        uint256 currentMorphoUsdc = morphoShares > 0 ? MORPHO_VAULT.convertToAssets(morphoShares) : 0;

        uint256 usdcToDeploy = 0;
        if (currentMorphoUsdc > bufferTarget && currentMorphoUsdc - bufferTarget >= DEPLOY_THRESHOLD) {
            usdcToDeploy = currentMorphoUsdc - bufferTarget;
            MORPHO_VAULT.withdraw(usdcToDeploy, address(this), address(this));
            morphoPrincipal = morphoPrincipal > usdcToDeploy ? morphoPrincipal - usdcToDeploy : 0;
        }

        uint256 bearToDeploy = BEAR.balanceOf(address(this));
        if (usdcToDeploy == 0 && bearToDeploy == 0) {
            revert InvarCoin__NothingToDeploy();
        }

        // Two-Sided AMM deployment (Highly capital efficient, minimal slippage)
        uint256[2] memory amounts = [usdcToDeploy, bearToDeploy];
        lpMinted = CURVE_POOL.add_liquidity(amounts, minLpOut);

        emit DeployedToCurve(msg.sender, usdcToDeploy, bearToDeploy, lpMinted);
    }

    /// @notice Keeper function: Restores USDC buffer by burning Curve LP
    function replenishBuffer(
        uint256 lpToBurn,
        uint256 minUsdcOut
    ) external nonReentrant {
        uint256 usdcBefore = USDC.balanceOf(address(this));
        CURVE_POOL.remove_liquidity_one_coin(lpToBurn, USDC_INDEX, minUsdcOut);

        uint256 usdcRecovered = USDC.balanceOf(address(this)) - usdcBefore;
        MORPHO_VAULT.deposit(usdcRecovered, address(this));
        morphoPrincipal += usdcRecovered;

        emit BufferReplenished(lpToBurn, usdcRecovered);
    }

    // ==========================================
    // EMERGENCY & ADMIN
    // ==========================================

    function emergencyWithdrawFromCurve() external onlyOwner {
        uint256 lpBal = CURVE_LP_TOKEN.balanceOf(address(this));
        uint256[2] memory received;
        if (lpBal > 0) {
            received = CURVE_POOL.remove_liquidity(lpBal, [uint256(0), uint256(0)]);
        }
        _pause();
        emit EmergencyWithdrawCurve(lpBal, received[0], received[1]);
    }

    function emergencyWithdrawFromMorpho() external onlyOwner {
        uint256 shares = MORPHO_VAULT.balanceOf(address(this));
        uint256 usdcReceived = 0;
        if (shares > 0) {
            usdcReceived = MORPHO_VAULT.redeem(shares, address(this), address(this));
        }
        morphoPrincipal = 0;
        _pause();
        emit EmergencyWithdrawMorpho(shares, usdcReceived);
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
        if (
            token == address(USDC) || token == address(MORPHO_VAULT) || token == address(CURVE_LP_TOKEN)
                || token == address(BEAR)
        ) {
            revert InvarCoin__CannotRescueCoreAsset();
        }
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, balance);
        emit TokenRescued(token, to, balance);
    }

}
