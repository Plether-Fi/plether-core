// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30; // Added Pragma

import "forge-std/Test.sol";
import "../src/LeverageRouter.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";

contract LeverageRouterTest is Test {
    LeverageRouter public leverageRouter;

    // Mocks
    MockToken public usdc;
    MockToken public mDXY;
    MockMorpho public morpho;
    MockSwapRouter public swapRouter;
    MockFlashLender public lender;

    address alice = address(0xA11ce);
    MarketParams params;

    function setUp() public {
        usdc = new MockToken("USDC", "USDC");
        mDXY = new MockToken("mDXY", "mDXY");
        morpho = new MockMorpho();
        swapRouter = new MockSwapRouter();
        lender = new MockFlashLender(address(usdc));

        params = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(mDXY),
            oracle: address(0),
            irm: address(0),
            lltv: 900000000000000000 // 90%
        });

        leverageRouter = new LeverageRouter(
            address(morpho), address(swapRouter), address(usdc), address(mDXY), address(lender), params
        );

        // Setup Alice
        usdc.mint(alice, 10_000 * 1e6); // $10k
    }

    function test_OpenLeverage_3x_Success() public {
        uint256 principal = 1000 * 1e6; // $1,000
        uint256 leverage = 3 * 1e18; // 3x

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);

        morpho.setAuthorization(address(leverageRouter), true);

        leverageRouter.openLeverage(principal, leverage, 2900 * 1e18); // Slippage check
        vm.stopPrank();

        (uint256 supplied, uint256 borrowed) = morpho.positions(alice);
        assertEq(supplied, 3000 * 1e18, "Incorrect supplied amount");
        assertEq(borrowed, 2000 * 1e6, "Incorrect borrowed amount");
    }

    function test_OpenLeverage_Revert_NoAuth() public {
        uint256 principal = 1000 * 1e6;
        uint256 leverage = 2 * 1e18;

        vm.startPrank(alice);
        usdc.approve(address(leverageRouter), principal);
        // Skip auth

        vm.expectRevert("Morpho: Not authorized");
        leverageRouter.openLeverage(principal, leverage, 0);
        vm.stopPrank();
    }
}

// ==========================================
// MOCKS
// ==========================================

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFlashLender is IERC3156FlashLender {
    address token;

    constructor(address _token) {
        token = _token;
    }

    function maxFlashLoan(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function flashFee(address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function flashLoan(IERC3156FlashBorrower receiver, address t, uint256 amount, bytes calldata data)
        external
        override
        returns (bool)
    {
        MockToken(token).mint(address(receiver), amount); // Send money
        require(
            receiver.onFlashLoan(msg.sender, t, amount, 0, data) == keccak256("ERC3156FlashBorrower.onFlashLoan"),
            "Callback failed"
        );
        return true;
    }
}

contract MockSwapRouter is ISwapRouter {
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        // USDC (6) -> mDXY (18) : * 1e12
        amountOut = params.amountIn * 1e12;
        MockToken(params.tokenOut).mint(params.recipient, amountOut);
        return amountOut;
    }
}

contract MockMorpho is IMorpho {
    mapping(address => mapping(address => bool)) public isAuthorized;
    mapping(address => ActionData) public positions;

    struct ActionData {
        uint256 supplied;
        uint256 borrowed;
    }

    function setAuthorization(address operator, bool approved) external {
        isAuthorized[msg.sender][operator] = approved;
    }

    function supply(MarketParams memory, uint256 assets, uint256, address onBehalfOf, bytes calldata)
        external
        override
        returns (uint256, uint256)
    {
        if (msg.sender != onBehalfOf) {
            require(isAuthorized[onBehalfOf][msg.sender], "Morpho: Not authorized");
        }
        positions[onBehalfOf].supplied += assets;
        return (assets, 0);
    }

    function borrow(MarketParams memory, uint256 assets, uint256, address onBehalfOf, address)
        external
        override
        returns (uint256, uint256)
    {
        if (msg.sender != onBehalfOf) {
            require(isAuthorized[onBehalfOf][msg.sender], "Morpho: Not authorized");
        }
        positions[onBehalfOf].borrowed += assets;
        return (assets, 0);
    }
}
