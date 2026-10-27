// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";

/// @notice There is no settlement-specific claim preview API. Compare documented lens buckets around execution.
contract ClaimSettlementParityTest is BasePerpTest {

    address private constant ACCOUNT = address(0xDC17);

    function test_ClaimSettlement_FlatAccountBecomesFreeCustody() public {
        _claimRow(false);
    }

    function test_ClaimSettlement_LiveAccountReclassifiesClaimToPledgeAtSameMark() public {
        _claimRow(true);
    }

    function _claimRow(
        bool keepPosition
    ) private {
        _fundTrader(ACCOUNT, 11_000e6);
        _open(ACCOUNT, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);
        settlementToken.burn(address(pool), settlementToken.balanceOf(address(pool)));
        _close(ACCOUNT, CfdTypes.Side.LONG, keepPosition ? 50_000e18 : 100_000e18, 99_000_000);
        // A 1% price gain less the 4 bps fee on the 0.99 execution notional.
        uint256 expectedClaim = keepPosition ? 480_200_000 : 960_400_000;
        AccountLensViewTypes.AccountLedgerSnapshot memory before_ = engineAccountLens.getAccountLedgerSnapshot(ACCOUNT);
        assertEq(before_.traderClaimBalanceAssets, expectedClaim);
        settlementToken.mint(address(pool), expectedClaim);
        uint256 custodyBefore = settlementToken.balanceOf(address(clearinghouse));
        uint256 markBefore = engine.lastMarkPrice();
        uint256 timestampBefore = block.timestamp;
        vm.prank(ACCOUNT);
        engine.settleTraderClaim(ACCOUNT);
        AccountLensViewTypes.AccountLedgerSnapshot memory after_ = engineAccountLens.getAccountLedgerSnapshot(ACCOUNT);
        assertEq(after_.traderClaimBalanceAssets, 0);
        assertEq(after_.settlementBalanceAssets, before_.settlementBalanceAssets + expectedClaim);
        assertEq(settlementToken.balanceOf(address(clearinghouse)), custodyBefore + expectedClaim);
        assertEq(settlementToken.balanceOf(address(pool)), 0);
        assertEq(
            after_.positionMarginBucketAssets, before_.positionMarginBucketAssets + (keepPosition ? expectedClaim : 0)
        );
        assertEq(after_.freeSettlementAssets, before_.freeSettlementAssets + (keepPosition ? 0 : expectedClaim));
        assertEq(
            after_.netEquityAssets,
            before_.netEquityAssets,
            "Claim-to-pledge reclassification adds no price-risk wealth"
        );
        assertEq(engine.lastMarkPrice(), markBefore);
        assertEq(block.timestamp, timestampBefore);
        _assertTerminalCurveMatchesEngine(ACCOUNT);
    }

}
