// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../CfdEngine.sol";
import {ICfdEngine} from "./ICfdEngine.sol";

interface ICfdEngineAccountLens {

    function engine() external view returns (address);

    function getAccountCollateralView(
        bytes32 accountId
    ) external view returns (CfdEngine.AccountCollateralView memory viewData);

    function getAccountLedgerView(
        bytes32 accountId
    ) external view returns (ICfdEngine.AccountLedgerView memory viewData);

    function getAccountLedgerSnapshot(
        bytes32 accountId
    ) external view returns (ICfdEngine.AccountLedgerSnapshot memory snapshot);

}
