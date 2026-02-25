// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISyntheticSplitter} from "../../src/interfaces/ISyntheticSplitter.sol";
import {MockFlashToken} from "./MockFlashToken.sol";
import {MockToken} from "./MockToken.sol";

contract MockSplitter is ISyntheticSplitter {

    address public tA; // BEAR
    address public tB; // BULL
    address public usdc;
    Status private _status = Status.ACTIVE;
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

    function setStatus(
        Status newStatus
    ) external {
        _status = newStatus;
    }

    function mint(
        uint256 amount
    ) external override {
        uint256 usdcCost = (amount * CAP) / 1e20;
        MockToken(usdc).transferFrom(msg.sender, address(this), usdcCost);
        MockFlashToken(tA).mint(msg.sender, amount);
        MockFlashToken(tB).mint(msg.sender, amount);
    }

    function burn(
        uint256 amount
    ) external override {
        MockFlashToken(tA).burn(msg.sender, amount);
        MockFlashToken(tB).burn(msg.sender, amount);
        uint256 usdcOut = (amount * CAP) / 1e20;
        MockToken(usdc).mint(msg.sender, usdcOut);
    }

    function emergencyRedeem(
        uint256
    ) external override {}

    function mintWithPermit(
        uint256,
        uint256,
        uint8,
        bytes32,
        bytes32
    ) external override {}

    function currentStatus() external view override returns (Status) {
        return _status;
    }

    function treasury() external view returns (address) {
        return address(this);
    }

    function liquidationTimestamp() external pure returns (uint256) {
        return 0;
    }

}
