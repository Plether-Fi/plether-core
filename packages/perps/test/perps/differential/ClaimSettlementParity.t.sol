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
        usdc.burn(address(pool), usdc.balanceOf(address(pool)));
        _close(ACCOUNT, CfdTypes.Side.LONG, keepPosition ? 50_000e18 : 100_000e18, 99_000_000);
        // A 1% price gain less the 4 bps fee on the 0.99 execution notional.
        uint256 expectedClaim = keepPosition ? 480_200_000 : 960_400_000;
        AccountLensViewTypes.AccountLedgerSnapshot memory before_ = engineAccountLens.getAccountLedgerSnapshot(ACCOUNT);
        assertEq(before_.traderClaimBalanceUsdc, expectedClaim);
        usdc.mint(address(pool), expectedClaim);
        uint256 custodyBefore = usdc.balanceOf(address(clearinghouse));
        uint256 markBefore = engine.lastMarkPrice();
        uint256 timestampBefore = block.timestamp;
        vm.prank(ACCOUNT);
        engine.settleTraderClaim(ACCOUNT);
        AccountLensViewTypes.AccountLedgerSnapshot memory after_ = engineAccountLens.getAccountLedgerSnapshot(ACCOUNT);
        assertEq(after_.traderClaimBalanceUsdc, 0);
        assertEq(after_.settlementBalanceUsdc, before_.settlementBalanceUsdc + expectedClaim);
        assertEq(usdc.balanceOf(address(clearinghouse)), custodyBefore + expectedClaim);
        assertEq(usdc.balanceOf(address(pool)), 0);
        assertEq(after_.positionMarginBucketUsdc, before_.positionMarginBucketUsdc + (keepPosition ? expectedClaim : 0));
        assertEq(after_.freeSettlementUsdc, before_.freeSettlementUsdc + (keepPosition ? 0 : expectedClaim));
        assertEq(
            after_.netEquityUsdc, before_.netEquityUsdc, "Claim-to-pledge reclassification adds no price-risk wealth"
        );
        assertEq(engine.lastMarkPrice(), markBefore);
        assertEq(block.timestamp, timestampBefore);
        _assertTerminalCurveMatchesEngine(ACCOUNT);
    }

}
