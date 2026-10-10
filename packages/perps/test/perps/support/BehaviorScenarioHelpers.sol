// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";
import {HousePoolAccountingLib} from "@plether/perps/libraries/HousePoolAccountingLib.sol";

contract RejectingRefundReceiver {

    bool internal acceptEth;

    receive() external payable {
        if (!acceptEth) {
            revert();
        }
    }

    function setAcceptEth(
        bool acceptEth_
    ) external {
        acceptEth = acceptEth_;
    }

    function refreshMark(
        OrderRouter router,
        bytes[] calldata updateData
    ) external payable {
        router.updateMarkPrice{value: msg.value}(updateData);
    }

}

contract TrancheCooldownBypassReceiver {}

contract HousePoolAccountingLibHarness {

    function buildWithdrawal(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot
    ) external pure returns (HousePoolAccountingLib.WithdrawalSnapshot memory) {
        return HousePoolAccountingLib.buildWithdrawalSnapshot(snapshot);
    }

    function buildReconcile(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot
    ) external pure returns (HousePoolAccountingLib.ReconcileSnapshot memory) {
        return HousePoolAccountingLib.buildReconcileSnapshot(snapshot);
    }

}

contract CooldownBypassReceiver {

    function claimDeposit(
        TrancheVault vault,
        uint256 requestId
    ) external {
        uint256 assets = vault.claimableDepositRequest(requestId, address(this));
        vault.claimDeposit(requestId, assets, address(this), address(this));
    }

    function requestRedeemAll(
        TrancheVault vault
    ) external {
        vault.requestRedeem(vault.balanceOf(address(this)), address(this), address(this));
    }

}
