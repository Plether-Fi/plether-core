// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @title OptionToken
/// @notice EIP-1167 Minimal Proxy Implementation for Option Series.
contract OptionToken {

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public marginEngine;
    bool private _initialized;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Initialized(string name, string symbol, address marginEngine);

    error OptionToken__AlreadyInitialized();
    error OptionToken__Unauthorized();
    error OptionToken__InsufficientBalance();
    error OptionToken__InsufficientAllowance();
    error OptionToken__ZeroAddress();

    constructor() {
        _initialized = true;
    }

    modifier onlyEngine() {
        if (msg.sender != marginEngine) {
            revert OptionToken__Unauthorized();
        }
        _;
    }

    /// @notice Initialize the proxy (called once by MarginEngine).
    function initialize(
        string memory _name,
        string memory _symbol,
        address _marginEngine
    ) external {
        if (_initialized) {
            revert OptionToken__AlreadyInitialized();
        }
        name = _name;
        symbol = _symbol;
        marginEngine = _marginEngine;
        _initialized = true;
        emit Initialized(_name, _symbol, _marginEngine);
    }

    function mint(
        address to,
        uint256 amount
    ) external onlyEngine {
        if (to == address(0)) {
            revert OptionToken__ZeroAddress();
        }
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(
        address from,
        uint256 amount
    ) external onlyEngine {
        if (balanceOf[from] < amount) {
            revert OptionToken__InsufficientBalance();
        }
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function approve(
        address spender,
        uint256 amount
    ) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(
        address to,
        uint256 amount
    ) external returns (bool) {
        if (to == address(0)) {
            revert OptionToken__ZeroAddress();
        }
        if (balanceOf[msg.sender] < amount) {
            revert OptionToken__InsufficientBalance();
        }
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        if (to == address(0)) {
            revert OptionToken__ZeroAddress();
        }
        if (allowance[from][msg.sender] != type(uint256).max) {
            if (allowance[from][msg.sender] < amount) {
                revert OptionToken__InsufficientAllowance();
            }
            allowance[from][msg.sender] -= amount;
        }
        if (balanceOf[from] < amount) {
            revert OptionToken__InsufficientBalance();
        }

        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

}
