// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";

import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

abstract contract HousePoolAsyncTestBase is BasePerpTest {

    function _requestAsyncDeposit(
        TrancheVault vault,
        address owner,
        uint256 assets
    ) internal returns (uint256 requestId) {
        usdc.mint(owner, assets);
        vm.startPrank(owner);
        usdc.approve(address(vault), assets);
        requestId = vault.requestDeposit(assets, owner, owner);
        vm.stopPrank();
    }

    function _requestAsyncRedeem(
        TrancheVault vault,
        address owner,
        uint256 shares
    ) internal returns (uint256 requestId) {
        vm.prank(owner);
        requestId = vault.requestRedeem(shares, owner, owner);
    }

    function _refreshMarkForAsyncSettlement() internal {
        uint256 markPrice = engine.lastMarkPrice();
        vm.prank(address(router));
        engine.updateMarkPrice(markPrice == 0 ? 1e8 : markPrice, uint64(vm.getBlockTimestamp()));
    }

    function _settleAsyncRequest(
        uint256 requestId,
        bool refreshMark
    ) internal returns (IHousePool.LpEpochSettlementResult memory result) {
        uint256 maturity = pool.lpEpochStart(requestId);
        if (block.timestamp < maturity) {
            vm.warp(maturity);
        }
        if (refreshMark) {
            _refreshMarkForAsyncSettlement();
        }
        result = _settleLpEpochForTest();
    }

    function _claimAsyncDeposit(
        TrancheVault vault,
        uint256 requestId,
        address owner
    ) internal returns (uint256 shares) {
        uint256 assets = vault.claimableDepositRequest(requestId, owner);
        assertGt(assets, 0, "deposit request should be claimable");
        vm.prank(owner);
        shares = vault.claimDeposit(requestId, assets, owner, owner);
    }

    function _depositAsync(
        TrancheVault vault,
        address owner,
        uint256 assets
    ) internal returns (uint256 requestId, uint256 shares) {
        requestId = _requestAsyncDeposit(vault, owner, assets);
        _settleAsyncRequest(requestId, true);
        shares = _claimAsyncDeposit(vault, requestId, owner);
    }

    function _claimAsyncRedeem(
        TrancheVault vault,
        uint256 requestId,
        address owner
    ) internal returns (uint256 shares, uint256 assets) {
        shares = vault.claimableRedeemRequest(requestId, owner);
        assertGt(shares, 0, "redeem request should be claimable");
        vm.prank(owner);
        assets = vault.claimRedeem(requestId, shares, owner, owner);
    }

    function _redeemAsync(
        TrancheVault vault,
        address owner,
        uint256 shares,
        bool refreshMark
    ) internal returns (uint256 requestId, uint256 fundedShares, uint256 assets) {
        requestId = _requestAsyncRedeem(vault, owner, shares);
        _settleAsyncRequest(requestId, refreshMark);
        (fundedShares, assets) = _claimAsyncRedeem(vault, requestId, owner);
    }

    function _finishAsyncCooldown(
        TrancheVault vault,
        address owner
    ) internal {
        uint256 unlockTime = vault.lastDepositTime(owner) + vault.DEPOSIT_COOLDOWN();
        if (block.timestamp < unlockTime) {
            vm.warp(unlockTime);
        }
    }

}

abstract contract HousePoolTestBase is HousePoolAsyncTestBase {

    using stdStorage for StdStorage;

    uint256 constant SEEDED_SENIOR = 1000e6;
    uint256 constant SEEDED_JUNIOR = 1000e6;

    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _mintAndAccountPoolExcess(
        uint256 amount
    ) internal {
        usdc.mint(address(pool), amount);
        pool.accountExcess();
    }

    function _setTotalTraderClaim(
        uint256 amount
    ) internal {
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceUsdc()").checked_write(amount);
    }

    function _enterFrozenWindow() internal {
        uint256 saturdayFrozen = 1_710_021_600;
        vm.warp(saturdayFrozen - 12 hours);
        assertTrue(engine.isOracleFrozen(), "setup should enter a frozen-oracle window");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(saturdayFrozen - 12 hours));

        vm.warp(saturdayFrozen);
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

}
