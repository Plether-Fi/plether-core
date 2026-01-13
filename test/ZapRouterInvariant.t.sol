// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ZapRouter} from "../src/ZapRouter.sol";
import {ICurvePool} from "../src/interfaces/ICurvePool.sol";
import {ISyntheticSplitter} from "../src/interfaces/ISyntheticSplitter.sol";
import {IERC3156FlashBorrower, IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test, console} from "forge-std/Test.sol";

// ==========================================
// MOCK CONTRACTS FOR INVARIANT TESTS
// ==========================================

contract InvMockToken is ERC20 {

    uint8 private _decimals;

    constructor(
        string memory name,
        string memory symbol,
        uint8 dec
    ) ERC20(name, symbol) {
        _decimals = dec;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
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

}

contract InvMockFlashToken is ERC20, IERC3156FlashLender {

    uint8 private _decimals;
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    constructor(
        string memory name,
        string memory symbol,
        uint8 dec
    ) ERC20(name, symbol) {
        _decimals = dec;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
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
        address token
    ) external view override returns (uint256) {
        return token == address(this) ? type(uint256).max - totalSupply() : 0;
    }

    function flashFee(
        address token,
        uint256
    ) external view override returns (uint256) {
        require(token == address(this), "Invalid token");
        return 0;
    }

    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override returns (bool) {
        require(token == address(this), "Invalid token");
        _mint(address(receiver), amount);
        require(receiver.onFlashLoan(msg.sender, token, amount, 0, data) == CALLBACK_SUCCESS, "Callback failed");
        _burn(address(receiver), amount);
        return true;
    }

}

contract InvMockCurvePool is ICurvePool {

    address public token0; // USDC
    address public token1; // dxyBear
    uint256 public bearPrice = 1e6; // 1 BEAR = 1 USDC

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
    ) external view override returns (uint256) {
        if (i == 1 && j == 0) return (dx * bearPrice) / 1e18;
        if (i == 0 && j == 1) return (dx * 1e18) / bearPrice;
        return 0;
    }

    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy
    ) external payable override returns (uint256 dy) {
        dy = this.get_dy(i, j, dx);
        require(dy >= min_dy, "Too little received");
        address tokenIn = i == 0 ? token0 : token1;
        address tokenOut = j == 0 ? token0 : token1;
        InvMockToken(tokenIn).transferFrom(msg.sender, address(this), dx);
        InvMockToken(tokenOut).mint(msg.sender, dy);
        return dy;
    }

    function price_oracle() external view override returns (uint256) {
        return bearPrice * 1e12;
    }

}

contract InvMockSplitter is ISyntheticSplitter {

    address public tA; // BEAR
    address public tB; // BULL
    address public usdc;
    Status private _status = Status.ACTIVE;
    uint256 public constant CAP_VALUE = 2e8; // $2.00 in 8 decimals

    constructor(
        address _tA,
        address _tB,
        address _usdc
    ) {
        tA = _tA;
        tB = _tB;
        usdc = _usdc;
    }

    function CAP() external pure override returns (uint256) {
        return CAP_VALUE;
    }

    function currentStatus() external view override returns (Status) {
        return _status;
    }

    function setStatus(
        Status newStatus
    ) external {
        _status = newStatus;
    }

    function mint(
        uint256 amount
    ) external override {
        uint256 usdcCost = (amount * CAP_VALUE) / 1e20;
        InvMockToken(usdc).transferFrom(msg.sender, address(this), usdcCost);
        InvMockFlashToken(tA).mint(msg.sender, amount);
        InvMockFlashToken(tB).mint(msg.sender, amount);
    }

    function burn(
        uint256 amount
    ) external override {
        InvMockFlashToken(tA).burn(msg.sender, amount);
        InvMockFlashToken(tB).burn(msg.sender, amount);
        uint256 usdcOut = (amount * CAP_VALUE) / 1e20;
        InvMockToken(usdc).mint(msg.sender, usdcOut);
    }

    function emergencyRedeem(
        uint256
    ) external override {}

}

// ==========================================
// ZAP ROUTER HANDLER
// ==========================================

contract ZapRouterHandler is Test {

    ZapRouter public router;
    InvMockToken public usdc;
    InvMockFlashToken public dxyBear;
    InvMockFlashToken public dxyBull;
    InvMockCurvePool public curvePool;
    InvMockSplitter public splitter;

    // Actors
    address[] public actors;
    address internal currentActor;

    // Ghost variables
    uint256 public ghost_totalZapMints;
    uint256 public ghost_totalZapBurns;
    uint256 public ghost_totalUsdcDeposited;
    uint256 public ghost_totalBullMinted;
    uint256 public ghost_totalBullBurned;
    uint256 public ghost_totalUsdcReturned;

    modifier useActor(
        uint256 actorSeed
    ) {
        currentActor = actors[actorSeed % actors.length];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(
        ZapRouter _router,
        InvMockToken _usdc,
        InvMockFlashToken _dxyBear,
        InvMockFlashToken _dxyBull,
        InvMockCurvePool _curvePool,
        InvMockSplitter _splitter
    ) {
        router = _router;
        usdc = _usdc;
        dxyBear = _dxyBear;
        dxyBull = _dxyBull;
        curvePool = _curvePool;
        splitter = _splitter;

        // Create actors
        for (uint256 i = 1; i <= 5; i++) {
            address actor = address(uint160(i * 1000));
            actors.push(actor);
            // Fund each actor with USDC
            usdc.mint(actor, 1_000_000 * 1e6);
            vm.prank(actor);
            usdc.approve(address(router), type(uint256).max);
            vm.prank(actor);
            dxyBull.approve(address(router), type(uint256).max);
        }
    }

    function zapMint(
        uint256 actorSeed,
        uint256 usdcAmount
    ) external useActor(actorSeed) {
        // Bound inputs
        usdcAmount = bound(usdcAmount, 10e6, 100_000e6); // $10 to $100k

        // Skip if actor doesn't have enough
        if (usdc.balanceOf(currentActor) < usdcAmount) return;

        uint256 bullBefore = dxyBull.balanceOf(currentActor);

        try router.zapMint(usdcAmount, 0, 100, block.timestamp + 1 hours) {
            ghost_totalZapMints++;
            ghost_totalUsdcDeposited += usdcAmount;
            uint256 bullReceived = dxyBull.balanceOf(currentActor) - bullBefore;
            ghost_totalBullMinted += bullReceived;
        } catch {
            // Expected failures are OK
        }
    }

    function zapBurn(
        uint256 actorSeed,
        uint256 bullAmount
    ) external useActor(actorSeed) {
        uint256 bullBalance = dxyBull.balanceOf(currentActor);

        // Skip if no BULL to burn
        if (bullBalance == 0) return;

        // Bound to available balance
        bullAmount = bound(bullAmount, 1e18, bullBalance);

        uint256 usdcBefore = usdc.balanceOf(currentActor);

        try router.zapBurn(bullAmount, 0, block.timestamp + 1 hours) {
            ghost_totalZapBurns++;
            ghost_totalBullBurned += bullAmount;
            uint256 usdcReceived = usdc.balanceOf(currentActor) - usdcBefore;
            ghost_totalUsdcReturned += usdcReceived;
        } catch {
            // Expected failures are OK
        }
    }

    function zapMintThenBurn(
        uint256 actorSeed,
        uint256 usdcAmount
    ) external useActor(actorSeed) {
        // Bound inputs
        usdcAmount = bound(usdcAmount, 100e6, 10_000e6); // $100 to $10k

        if (usdc.balanceOf(currentActor) < usdcAmount) return;

        uint256 bullBefore = dxyBull.balanceOf(currentActor);
        uint256 usdcBefore = usdc.balanceOf(currentActor);

        // Mint
        try router.zapMint(usdcAmount, 0, 100, block.timestamp + 1 hours) {
            ghost_totalZapMints++;
            ghost_totalUsdcDeposited += usdcAmount;
            uint256 bullReceived = dxyBull.balanceOf(currentActor) - bullBefore;
            ghost_totalBullMinted += bullReceived;

            // Immediately burn
            if (bullReceived > 0) {
                try router.zapBurn(bullReceived, 0, block.timestamp + 1 hours) {
                    ghost_totalZapBurns++;
                    ghost_totalBullBurned += bullReceived;
                    uint256 usdcReturned = usdc.balanceOf(currentActor) - (usdcBefore - usdcAmount);
                    ghost_totalUsdcReturned += usdcReturned;
                } catch {
                    // Burn failed, that's OK
                }
            }
        } catch {
            // Mint failed, that's OK
        }
    }

    // View helpers
    function getActorCount() external view returns (uint256) {
        return actors.length;
    }

    function getActor(
        uint256 index
    ) external view returns (address) {
        return actors[index % actors.length];
    }

}

// ==========================================
// ZAP ROUTER INVARIANT TESTS
// ==========================================

contract ZapRouterInvariantTest is StdInvariant, Test {

    ZapRouter public router;
    InvMockToken public usdc;
    InvMockFlashToken public dxyBear;
    InvMockFlashToken public dxyBull;
    InvMockCurvePool public curvePool;
    InvMockSplitter public splitter;
    ZapRouterHandler public handler;

    function setUp() public {
        // Deploy mocks
        usdc = new InvMockToken("USDC", "USDC", 6);
        dxyBear = new InvMockFlashToken("DXY-BEAR", "BEAR", 18);
        dxyBull = new InvMockFlashToken("DXY-BULL", "BULL", 18);
        curvePool = new InvMockCurvePool(address(usdc), address(dxyBear));
        splitter = new InvMockSplitter(address(dxyBear), address(dxyBull), address(usdc));

        // Deploy router
        router = new ZapRouter(address(splitter), address(dxyBear), address(dxyBull), address(usdc), address(curvePool));

        // Create handler
        handler = new ZapRouterHandler(router, usdc, dxyBear, dxyBull, curvePool, splitter);

        targetContract(address(handler));

        // Labels
        vm.label(address(router), "ZapRouter");
        vm.label(address(splitter), "Splitter");
        vm.label(address(curvePool), "CurvePool");
        vm.label(address(handler), "Handler");
    }

    /// @notice Router should never hold any tokens after operations complete
    function invariant_routerStateless() public view {
        assertEq(usdc.balanceOf(address(router)), 0, "Router holds USDC");
        assertEq(dxyBear.balanceOf(address(router)), 0, "Router holds DXY-BEAR");
        assertEq(dxyBull.balanceOf(address(router)), 0, "Router holds DXY-BULL");
    }

    /// @notice Total BULL burned should be <= total BULL minted
    function invariant_mintBurnConsistency() public view {
        assertGe(handler.ghost_totalBullMinted(), handler.ghost_totalBullBurned(), "More BULL burned than minted");
    }

    /// @notice Summary for debugging
    function invariant_callSummary() public view {
        console.log("=== ZapRouter Invariant Summary ===");
        console.log("Total zapMints:", handler.ghost_totalZapMints());
        console.log("Total zapBurns:", handler.ghost_totalZapBurns());
        console.log("Total USDC deposited:", handler.ghost_totalUsdcDeposited());
        console.log("Total BULL minted:", handler.ghost_totalBullMinted());
        console.log("Total BULL burned:", handler.ghost_totalBullBurned());
        console.log("Total USDC returned:", handler.ghost_totalUsdcReturned());
    }

}
