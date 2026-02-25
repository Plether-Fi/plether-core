// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMorpho, IMorphoFlashLoanCallback, MarketParams} from "../../src/interfaces/IMorpho.sol";
import {MockToken} from "./MockToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

error MockMorpho__NotAuthorized();

contract MockMorpho is IMorpho {

    address public usdc;
    address public stakedToken;
    mapping(address => uint256) public collateralBalance;
    mapping(address => uint256) public borrowBalance;
    mapping(address => mapping(address => bool)) public _isAuthorized;

    constructor(
        address _usdc,
        address _stakedToken
    ) {
        usdc = _usdc;
        stakedToken = _stakedToken;
    }

    function setAuthorization(
        address authorized,
        bool newIsAuthorized
    ) external override {
        _isAuthorized[msg.sender][authorized] = newIsAuthorized;
    }

    function isAuthorized(
        address authorizer,
        address authorized
    ) external view override returns (bool) {
        return _isAuthorized[authorizer][authorized];
    }

    function createMarket(
        MarketParams memory
    ) external override {}

    function idToMarketParams(
        bytes32
    ) external pure override returns (MarketParams memory) {
        return MarketParams(address(0), address(0), address(0), address(0), 0);
    }

    function flashLoan(
        address token,
        uint256 assets,
        bytes calldata data
    ) external override {
        MockToken(token).mint(msg.sender, assets);
        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);
        IERC20(token).transferFrom(msg.sender, address(this), assets);
        MockToken(token).burn(address(this), assets);
    }

    function supply(
        MarketParams memory,
        uint256 assets,
        uint256,
        address,
        bytes calldata
    ) external override returns (uint256, uint256) {
        return (assets, 0);
    }

    function withdraw(
        MarketParams memory,
        uint256 assets,
        uint256,
        address,
        address
    ) external override returns (uint256, uint256) {
        return (assets, 0);
    }

    function supplyCollateral(
        MarketParams memory,
        uint256 assets,
        address onBehalfOf,
        bytes calldata
    ) external override {
        IERC20(stakedToken).transferFrom(msg.sender, address(this), assets);
        collateralBalance[onBehalfOf] += assets;
    }

    function withdrawCollateral(
        MarketParams memory,
        uint256 assets,
        address onBehalfOf,
        address receiver
    ) external override {
        if (msg.sender != onBehalfOf) {
            if (!_isAuthorized[onBehalfOf][msg.sender]) {
                revert MockMorpho__NotAuthorized();
            }
        }
        collateralBalance[onBehalfOf] -= assets;
        IERC20(stakedToken).transfer(receiver, assets);
    }

    function borrow(
        MarketParams memory,
        uint256 assets,
        uint256,
        address onBehalfOf,
        address receiver
    ) external override returns (uint256, uint256) {
        if (msg.sender != onBehalfOf) {
            if (!_isAuthorized[onBehalfOf][msg.sender]) {
                revert MockMorpho__NotAuthorized();
            }
        }
        MockToken(usdc).mint(receiver, assets);
        borrowBalance[onBehalfOf] += assets;
        return (assets, 0);
    }

    function repay(
        MarketParams memory,
        uint256 assets,
        uint256 shares,
        address onBehalfOf,
        bytes calldata
    ) external override returns (uint256, uint256) {
        uint256 repayAmount = assets > 0 ? assets : shares;
        MockToken(usdc).transferFrom(msg.sender, address(this), repayAmount);
        borrowBalance[onBehalfOf] -= repayAmount;
        return (repayAmount, shares > 0 ? shares : repayAmount);
    }

    function position(
        bytes32,
        address user
    ) external view override returns (uint256, uint128, uint128) {
        return (0, uint128(borrowBalance[user]), uint128(collateralBalance[user]));
    }

    function market(
        bytes32
    ) external pure override returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        return (0, 0, type(uint128).max, type(uint128).max, 0, 0);
    }

    function accrueInterest(
        MarketParams memory
    ) external override {}

    function liquidate(
        MarketParams memory,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

}
