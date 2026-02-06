// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BullLeverageRouter} from "../src/BullLeverageRouter.sol";
import {LeverageRouter} from "../src/LeverageRouter.sol";
import {SyntheticSplitter} from "../src/SyntheticSplitter.sol";
import {ZapRouter} from "../src/ZapRouter.sol";
import {IMorpho, MarketParams} from "../src/interfaces/IMorpho.sol";
import {MockYieldAdapter} from "./utils/MockYieldAdapter.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title ReentrancyTest
 * @notice Tests for reentrancy protection across all router contracts
 * @dev Verifies that nonReentrant modifiers prevent various attack vectors:
 *      - Flash loan callback re-entrance
 *      - Curve pool callback attacks
 *      - Nested flash loan re-entrance
 */
contract ReentrancyTest is Test {

    // Core contracts
    SyntheticSplitter public splitter;
    ZapRouter public zapRouter;
    MockYieldAdapter public adapter;

    // Tokens
    MockUSDC public usdc;
    MockFlashToken public plDxyBear;
    MockFlashToken public plDxyBull;

    // Mocks
    MockOracle public oracle;
    MockOracle public sequencer;
    MockCurvePool public curvePool;

    address owner = address(0x1);
    address alice = address(0xA11ce);
    address treasury = address(0x99);

    uint256 constant CAP = 200_000_000; // $2.00 in 8 decimals

    function setUp() public {
        vm.warp(1_735_689_600);

        // Deploy tokens
        usdc = new MockUSDC();
        plDxyBear = new MockFlashToken("plDXY-BEAR", "plDXY-BEAR");
        plDxyBull = new MockFlashToken("plDXY-BULL", "plDXY-BULL");

        // Deploy oracles
        oracle = new MockOracle(100_000_000, block.timestamp, block.timestamp);
        sequencer = new MockOracle(0, block.timestamp - 2 hours, block.timestamp);

        // Deploy Curve pool mock
        curvePool = new MockCurvePool(address(usdc), address(plDxyBear));
        curvePool.setPrice(1e6); // 1 BEAR = 1 USDC

        // Calculate future splitter address
        vm.startPrank(owner);
        uint256 nonce = vm.getNonce(owner);
        address futureSplitterAddr = vm.computeCreateAddress(owner, nonce + 1);

        // Deploy adapter
        adapter = new MockYieldAdapter(IERC20(address(usdc)), owner, futureSplitterAddr);

        // Deploy splitter
        splitter =
            new SyntheticSplitter(address(oracle), address(usdc), address(adapter), CAP, treasury, address(sequencer));
        vm.stopPrank();

        // Deploy ZapRouter with mock splitter for flash loan tests
        MockSplitter mockSplitter = new MockSplitter(address(plDxyBear), address(plDxyBull));
        mockSplitter.setUsdc(address(usdc));
        zapRouter = new ZapRouter(
            address(mockSplitter), address(plDxyBear), address(plDxyBull), address(usdc), address(curvePool)
        );

        // Fund accounts
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(address(curvePool), 10_000_000e6);

        // Labels
        vm.label(address(splitter), "Splitter");
        vm.label(address(zapRouter), "ZapRouter");
    }

    // ==========================================
    // FLASH LOAN CALLBACK SECURITY
    // ==========================================

    function test_ZapRouter_OnFlashLoan_RejectsExternalCalls() public {
        // Try calling onFlashLoan directly from a random address
        vm.prank(alice);
        vm.expectRevert();
        zapRouter.onFlashLoan(address(zapRouter), address(plDxyBear), 100, 0, "");
    }

    function test_ZapRouter_OnFlashLoan_RejectsWrongInitiator() public {
        // Try calling from the correct lender but wrong initiator
        vm.prank(address(plDxyBear));
        vm.expectRevert();
        zapRouter.onFlashLoan(alice, address(plDxyBear), 100, 0, "");
    }

    // ==========================================
    // CURVE POOL CALLBACK ATTACK SIMULATION
    // ==========================================

    function test_CurvePoolReentrancy_Blocked() public {
        // Deploy malicious curve pool (target set after router creation)
        MaliciousCurvePool maliciousPool = new MaliciousCurvePool(address(usdc), address(plDxyBear));

        // Create new ZapRouter with malicious pool
        MockSplitter mockSplitter = new MockSplitter(address(plDxyBear), address(plDxyBull));
        mockSplitter.setUsdc(address(usdc));
        ZapRouter maliciousRouter = new ZapRouter(
            address(mockSplitter), address(plDxyBear), address(plDxyBull), address(usdc), address(maliciousPool)
        );

        // Point reentrancy at the SAME router (not a different one)
        maliciousPool.setTargetRouter(address(maliciousRouter));

        usdc.mint(alice, 1_000_000e6);

        vm.startPrank(alice);
        usdc.approve(address(maliciousRouter), type(uint256).max);

        // Malicious pool calls maliciousRouter.zapMint during exchange,
        // which reverts because nonReentrant is already locked
        vm.expectRevert();
        maliciousRouter.zapMint(100e6, 0, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

}

contract MaliciousCurvePool {

    address public token0;
    address public token1;
    address public targetRouter;
    bool public hasAttacked;

    constructor(
        address _token0,
        address _token1
    ) {
        token0 = _token0;
        token1 = _token1;
    }

    function setTargetRouter(
        address _router
    ) external {
        targetRouter = _router;
    }

    function get_dy(
        uint256,
        uint256,
        uint256 dx
    ) external pure returns (uint256) {
        return dx; // 1:1 for simplicity
    }

    function exchange(
        uint256,
        uint256,
        uint256,
        uint256
    ) external payable returns (uint256) {
        // Try to reenter the router during exchange
        if (!hasAttacked) {
            hasAttacked = true;
            // This should fail due to nonReentrant
            ZapRouter(targetRouter).zapMint(1e6, 0, 100, block.timestamp + 1 hours);
        }
        return 0;
    }

    function price_oracle() external pure returns (uint256) {
        return 1e18;
    }

}

// ==========================================
// MOCKS
// ==========================================

contract MockUSDC is ERC20 {

    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

contract MockFlashToken is ERC20, IERC3156FlashLender {

    uint256 public feeBps = 0;

    constructor(
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) {}

    function setFeeBps(
        uint256 _feeBps
    ) external {
        feeBps = _feeBps;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function burn(
        address from,
        uint256 amount
    ) external {
        _burn(from, amount);
    }

    function maxFlashLoan(
        address
    ) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function flashFee(
        address,
        uint256 amount
    ) public view override returns (uint256) {
        return (amount * feeBps) / 10_000;
    }

    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override returns (bool) {
        uint256 fee = flashFee(token, amount);
        _mint(address(receiver), amount);
        require(
            receiver.onFlashLoan(msg.sender, token, amount, fee, data) == keccak256("ERC3156FlashBorrower.onFlashLoan"),
            "Callback failed"
        );
        _burn(address(receiver), amount + fee);
        return true;
    }

}

contract MockOracle {

    int256 public price;
    uint256 public startedAt;
    uint256 public updatedAt;

    constructor(
        int256 _price,
        uint256 _startedAt,
        uint256 _updatedAt
    ) {
        price = _price;
        startedAt = _startedAt;
        updatedAt = _updatedAt;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, price, startedAt, updatedAt, 0);
    }

}

contract MockCurvePool {

    address public token0;
    address public token1;
    uint256 public bearPrice = 1e6;

    constructor(
        address _token0,
        address _token1
    ) {
        token0 = _token0;
        token1 = _token1;
    }

    function setPrice(
        uint256 _price
    ) external {
        bearPrice = _price;
    }

    function get_dy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view returns (uint256) {
        if (i == 1 && j == 0) {
            return (dx * bearPrice) / 1e18;
        }
        if (i == 0 && j == 1) {
            return (dx * 1e18) / bearPrice;
        }
        return 0;
    }

    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy
    ) external payable returns (uint256 dy) {
        dy = this.get_dy(i, j, dx);
        require(dy >= min_dy, "Too little received");

        address tokenIn = i == 0 ? token0 : token1;
        address tokenOut = j == 0 ? token0 : token1;

        ERC20(tokenIn).transferFrom(msg.sender, address(this), dx);
        MockFlashToken(tokenOut).mint(msg.sender, dy);

        return dy;
    }

    function price_oracle() external view returns (uint256) {
        return bearPrice * 1e12;
    }

}

contract MockSplitter {

    address public tA;
    address public tB;
    address public usdc;
    uint256 public constant CAP = 2e8;

    constructor(
        address _tA,
        address _tB
    ) {
        tA = _tA;
        tB = _tB;
    }

    function setUsdc(
        address _usdc
    ) external {
        usdc = _usdc;
    }

    function currentStatus() external pure returns (uint8) {
        return 0; // ACTIVE
    }

    function mint(
        uint256 amount
    ) external {
        MockFlashToken(tA).mint(msg.sender, amount);
        MockFlashToken(tB).mint(msg.sender, amount);
    }

    function burn(
        uint256 amount
    ) external {
        MockFlashToken(tA).burn(msg.sender, amount);
        MockFlashToken(tB).burn(msg.sender, amount);
        uint256 usdcOut = (amount * 2) / 1e12;
        MockUSDC(usdc).mint(msg.sender, usdcOut);
    }

}
