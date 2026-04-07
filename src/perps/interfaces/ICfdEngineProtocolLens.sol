// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../CfdEngine.sol";
import {ICfdEngine} from "./ICfdEngine.sol";

interface ICfdEngineProtocolLens {

    function engine() external view returns (address);

    function getPositionView(
        bytes32 accountId
    ) external view returns (CfdEngine.PositionView memory viewData);

    function getDeferredPayoutStatus(
        bytes32 accountId,
        address keeper
    ) external view returns (CfdEngine.DeferredPayoutStatus memory status);

    function getDeferredTraderStatus(
        bytes32 accountId
    ) external view returns (ICfdEngine.DeferredTraderStatus memory status);

    function getDeferredClearerStatus(
        address keeper
    ) external view returns (ICfdEngine.DeferredClearerStatus memory status);

    function getVaultMtmAdjustment() external view returns (uint256 mtmLiabilityUsdc);

    function getProtocolStatus() external view returns (ICfdEngine.ProtocolStatus memory status);

    function getProtocolAccountingView() external view returns (CfdEngine.ProtocolAccountingView memory viewData);

    function getProtocolAccountingSnapshot()
        external
        view
        returns (ICfdEngine.ProtocolAccountingSnapshot memory snapshot);

    function getHousePoolInputSnapshot(
        uint256 markStalenessLimit
    ) external view returns (ICfdEngine.HousePoolInputSnapshot memory snapshot);

    function getHousePoolStatusSnapshot() external view returns (ICfdEngine.HousePoolStatusSnapshot memory snapshot);

}
