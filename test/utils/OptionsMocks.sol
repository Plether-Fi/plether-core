// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ISyntheticSplitter} from "../../src/interfaces/ISyntheticSplitter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockOptionsSplitter {

    uint256 public CAP = 2e8;
    uint256 public liquidationTimestamp;
    ISyntheticSplitter.Status private _status = ISyntheticSplitter.Status.ACTIVE;

    function currentStatus() external view returns (ISyntheticSplitter.Status) {
        return _status;
    }

    function setStatus(
        ISyntheticSplitter.Status s
    ) external {
        _status = s;
        if (s == ISyntheticSplitter.Status.SETTLED) {
            liquidationTimestamp = block.timestamp;
        }
    }

}

/// @dev 21-decimal ERC20 simulating StakedToken (ERC4626 with _decimalsOffset=3).
contract MockStakedTokenOptions is ERC20 {

    uint256 private _rateNum = 1;
    uint256 private _rateDen = 1;

    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 21;
    }

    function setExchangeRate(
        uint256 num,
        uint256 den
    ) external {
        _rateNum = num;
        _rateDen = den;
    }

    /// @dev Rounds DOWN: shares → assets.
    function convertToAssets(
        uint256 shares
    ) external view returns (uint256) {
        return (shares * _rateNum) / (_rateDen * 1e3);
    }

    /// @dev Rounds DOWN: shares → assets (fee-aware for DOV).
    function previewRedeem(
        uint256 shares
    ) external view returns (uint256) {
        return (shares * _rateNum) / (_rateDen * 1e3);
    }

    /// @dev Rounds UP: assets → shares (ERC4626 previewWithdraw spec).
    function previewWithdraw(
        uint256 assets
    ) external view returns (uint256) {
        if (_rateNum == 0) {
            return assets * 1e3;
        }
        uint256 numerator = assets * _rateDen * 1e3;
        return (numerator + _rateNum - 1) / _rateNum;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}
