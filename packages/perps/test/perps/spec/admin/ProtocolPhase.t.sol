// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";

import {CfdEngine} from "@plether/perps/CfdEngine.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {PerpsPublicLens} from "@plether/perps/PerpsPublicLens.sol";

import {ICfdEngine} from "@plether/perps/interfaces/ICfdEngine.sol";

import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";

contract ProtocolPhaseTest is BasePerpTest {

    address longTrader = address(0xD001);
    address shortTrader = address(0xD002);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function test_PhaseTransitions() public {
        assertEq(
            uint8(ICfdEngine.ProtocolPhase(_publicProtocolStatus().phase)),
            uint8(ICfdEngine.ProtocolPhase.Active),
            "Fully configured engine should be Active"
        );

        PerpsViewTypes.ProtocolStatusView memory status = _publicProtocolStatus();
        assertEq(uint8(status.phase), uint8(ICfdEngine.ProtocolPhase.Active));
        assertEq(status.lastMarkPrice, 1e8, "Async LP setup should establish the mark used for epoch settlement");

        address longAccount = longTrader;
        address shortAccount = shortTrader;
        _fundTrader(longTrader, 100_000e6);
        _fundTrader(shortTrader, 100_000e6);
        _open(shortAccount, CfdTypes.Side.SHORT, 999_000e18, 50_000e6, 1e8);
        _open(longAccount, CfdTypes.Side.LONG, 500_000e18, 50_000e6, 1e8);
        _close(longAccount, CfdTypes.Side.LONG, 500_000e18, 20_000_000);

        assertEq(
            uint8(ICfdEngine.ProtocolPhase(_publicProtocolStatus().phase)),
            uint8(ICfdEngine.ProtocolPhase.Degraded),
            "Insolvency-revealing close should latch Degraded"
        );

        usdc.mint(address(pool), 500_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            500_000e6, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        vm.prank(address(juniorVault));
        pool.reconcile();
        engine.clearDegradedMode();

        assertEq(
            uint8(ICfdEngine.ProtocolPhase(_publicProtocolStatus().phase)),
            uint8(ICfdEngine.ProtocolPhase.Active),
            "Recapitalization should restore Active"
        );
    }

    function test_ConfiguringPhase() public {
        CfdEngine unconfigured =
            new CfdEngine(address(usdc), address(clearinghouse), 2e8, _riskParams(), FROZEN_CLOSE_SPREAD_BPS);
        PerpsPublicLens unconfiguredLens =
            new PerpsPublicLens(address(engineAccountLens), address(unconfigured), address(router), address(0));
        assertEq(
            unconfiguredLens.getProtocolStatus().phase,
            uint8(ICfdEngine.ProtocolPhase.Configuring),
            "Engine without pool/router should be Configuring"
        );
    }

}
