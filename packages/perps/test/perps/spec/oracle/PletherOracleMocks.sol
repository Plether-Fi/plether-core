// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";

contract PletherOracleEngineMock {

    uint256 public lastMarkPrice;
    uint64 public lastMarkTime;
    uint256 public CAP_PRICE = 2e8;
    bool public isFadWindow;
    uint256 public fadMaxStaleness = 3 days;
    uint256 public engineMarkStalenessLimit = 60;
    address public orderRouter;
    mapping(uint256 => bool) public fadDayOverrides;
    uint256 internal mockPositionSize;
    CfdTypes.Side internal mockPositionSide;

    function setLastMark(
        uint256 price,
        uint64 publishTime
    ) external {
        lastMarkPrice = price;
        lastMarkTime = publishTime;
    }

    function setCapPrice(
        uint256 price
    ) external {
        CAP_PRICE = price;
    }

    function setFadWindow(
        bool active
    ) external {
        isFadWindow = active;
    }

    function setOrderRouter(
        address router
    ) external {
        orderRouter = router;
    }

    function setFadDayOverride(
        uint256 dayNumber,
        bool active
    ) external {
        fadDayOverrides[dayNumber] = active;
    }

    function isOracleFrozen() external view returns (bool) {
        return fadDayOverrides[block.timestamp / 86_400];
    }

    function setPosition(
        uint256 size,
        CfdTypes.Side side
    ) external {
        mockPositionSize = size;
        mockPositionSide = side;
    }

    function positions(
        address
    )
        external
        view
        returns (
            uint256 size,
            uint256 margin,
            uint256 entryPrice,
            uint256 maxProfitUsdc,
            CfdTypes.Side side,
            uint64 lastUpdateTime,
            int256 vpiAccrued
        )
    {
        return (mockPositionSize, 0, 0, 0, mockPositionSide, 0, 0);
    }

}

contract PletherOracleVaultMock {

    uint256 public markStalenessLimit = 60;

    function setMarkStalenessLimit(
        uint256 limit
    ) external {
        markStalenessLimit = limit;
    }

}

/// @dev Consumes every gas unit offered to the immediate refund callback until explicitly configured to accept ETH.
contract GasBurningOracleRefundRecipient {

    bool internal burnRefundGas = true;
    uint256 public receivedEth;

    receive() external payable {
        if (burnRefundGas) {
            assembly ("memory-safe") {
                for {} 1 {} { pop(gas()) }
            }
        }
        receivedEth += msg.value;
    }

    function setBurnRefundGas(
        bool burnRefundGas_
    ) external {
        burnRefundGas = burnRefundGas_;
    }

    function claim(
        IPletherOracle oracle
    ) external {
        oracle.claimEthRefund();
    }

}
