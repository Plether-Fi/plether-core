// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ICfdEngineCore} from "../../../../src/perps/interfaces/ICfdEngineCore.sol";
import {IHousePool} from "../../../../src/perps/interfaces/IHousePool.sol";
import {MockUSDC} from "../../../mocks/MockUSDC.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockInvariantHousePool is IHousePool {

    using SafeERC20 for MockUSDC;

    MockUSDC public immutable usdc;
    address public immutable engine;

    constructor(
        address _usdc,
        address _engine
    ) {
        usdc = MockUSDC(_usdc);
        engine = _engine;
    }

    function seedAssets(
        uint256 amountUsdc
    ) external {
        usdc.mint(address(this), amountUsdc);
    }

    function setAssets(
        uint256 targetAmountUsdc
    ) external {
        uint256 currentAssets = usdc.balanceOf(address(this));
        if (targetAmountUsdc > currentAssets) {
            usdc.mint(address(this), targetAmountUsdc - currentAssets);
        } else if (currentAssets > targetAmountUsdc) {
            usdc.burn(address(this), currentAssets - targetAmountUsdc);
        }
    }

    function totalAssets() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function payOut(
        address recipient,
        uint256 amount
    ) external {
        _requireAuthorized();
        usdc.safeTransfer(recipient, amount);
    }

    function recordProtocolInflow(
        uint256
    ) external view {
        _requireAuthorized();
    }

    function recordClaimantInflow(
        uint256,
        IHousePool.ClaimantInflowKind,
        IHousePool.ClaimantInflowCashMode
    ) external view {
        _requireAuthorized();
    }

    function _requireAuthorized() internal view {
        if (msg.sender != engine && msg.sender != ICfdEngineCore(engine).settlementSidecar()) {
            revert("unauthorized");
        }
    }

    function markStalenessLimit() external pure returns (uint256) {
        return 120;
    }

    function isSeedLifecycleComplete() external pure returns (bool) {
        return true;
    }

    function hasSeedLifecycleStarted() external pure returns (bool) {
        return true;
    }

    function canAcceptOrdinaryDeposits() external pure returns (bool) {
        return true;
    }

    function canIncreaseRisk() external pure returns (bool) {
        return true;
    }

    function isTradingActive() external pure returns (bool) {
        return true;
    }

    function seniorPrincipal() external pure returns (uint256) {
        return 0;
    }

    function juniorPrincipal() external pure returns (uint256) {
        return 0;
    }

    function seniorHighWaterMark() external pure returns (uint256) {
        return 0;
    }

    function unassignedAssets() external pure returns (uint256) {
        return 0;
    }

    function depositSenior(
        uint256
    ) external pure {}

    function withdrawSenior(
        uint256,
        address
    ) external pure {}

    function depositJunior(
        uint256
    ) external pure {}

    function withdrawJunior(
        uint256,
        address
    ) external pure {}

    function assignUnassignedAssets(
        bool,
        address
    ) external pure {}

    function initializeSeedPosition(
        bool,
        uint256,
        address
    ) external pure {}

    function getMaxSeniorWithdraw() external pure returns (uint256) {
        return 0;
    }

    function getMaxJuniorWithdraw() external pure returns (uint256) {
        return 0;
    }

    function getPendingTrancheState()
        external
        pure
        returns (
            uint256 seniorPrincipalUsdc,
            uint256 juniorPrincipalUsdc,
            uint256 maxSeniorWithdrawUsdc,
            uint256 maxJuniorWithdrawUsdc
        )
    {
        return (0, 0, 0, 0);
    }

    function getPendingDepositTrancheState()
        external
        pure
        returns (uint256 seniorPrincipalUsdc, uint256 juniorPrincipalUsdc)
    {
        return (0, 0);
    }

    function reconcile() external pure {}

    function isWithdrawalLive() external pure returns (bool) {
        return true;
    }

    function canAcceptTrancheDeposits(
        bool
    ) external pure returns (bool) {
        return true;
    }

    function canAcceptInstantTrancheDeposits(
        bool
    ) external pure returns (bool) {
        return true;
    }

    function isOracleFrozen() external pure returns (bool) {
        return false;
    }

    function frozenLpFeeBps(
        bool
    ) external pure returns (uint256) {
        return 0;
    }

    function minTrancheDepositUsdc() external pure returns (uint256) {
        return 1e6;
    }

}
