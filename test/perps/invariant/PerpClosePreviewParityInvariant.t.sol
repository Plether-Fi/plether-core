// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../../src/perps/CfdTypes.sol";
import {MarginClearinghouse} from "../../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../../src/perps/OrderRouter.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {PerpAccountingHandler} from "./handlers/PerpAccountingHandler.sol";
import {CfdEngineHarness} from "./mocks/CfdEngineHarness.sol";
import {MockInvariantVault} from "./mocks/MockInvariantVault.sol";
import {Test} from "forge-std/Test.sol";

contract PerpClosePreviewParityInvariantTest is Test {

    MockUSDC internal usdc;
    CfdEngineHarness internal harness;
    CfdEngine internal engine;
    MarginClearinghouse internal clearinghouse;
    MockInvariantVault internal vault;
    OrderRouter internal router;
    PerpAccountingHandler internal handler;

    uint256 internal constant SETUP_TIMESTAMP = 1_709_532_000;
    uint256 internal constant CAP_PRICE = 2e8;

    function setUp() public {
        usdc = new MockUSDC();
        clearinghouse = new MarginClearinghouse(address(usdc));

        harness = new CfdEngineHarness(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
        engine = harness;

        vault = new MockInvariantVault(address(usdc), address(engine));
        router = new OrderRouter(
            address(engine),
            address(vault),
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        );

        clearinghouse.setEngine(address(engine));
        vm.warp(SETUP_TIMESTAMP);

        engine.setVault(address(vault));
        engine.setOrderRouter(address(router));
        vault.setOrderRouter(address(router));
        vault.seedAssets(100_000e6);

        handler = new PerpAccountingHandler(usdc, engine, clearinghouse, router, vault);
        handler.seedActors(50_000e6, 50_000e6);

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.depositCollateral.selector;
        selectors[1] = handler.withdrawCollateral.selector;
        selectors[2] = handler.commitOpenOrder.selector;
        selectors[3] = handler.commitCloseOrder.selector;
        selectors[4] = handler.executeNextOrderBatch.selector;
        selectors[5] = handler.liquidate.selector;
        selectors[6] = handler.claimDeferredClearerBounty.selector;
        selectors[7] = handler.setRouterPayoutFailureMode.selector;
        selectors[8] = handler.setVaultAssets.selector;
        selectors[9] = handler.fundVault.selector;
        selectors[10] = handler.drainVault.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_ValidPartialCloseNeverLeavesDustPosition() public view {
        uint256 oraclePrice = _previewOraclePrice();
        uint256 vaultDepthUsdc = vault.totalAssets();
        (,,,,,,, uint256 minBountyUsdc,) = engine.riskParams();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            (uint256 size, uint256 margin,,,,,,) = engine.positions(accountId);
            if (size < 2) {
                continue;
            }

            uint256[3] memory fractions = _closeFractions(size, margin, minBountyUsdc);
            for (uint256 f = 0; f < 3; f++) {
                if (fractions[f] == 0 || fractions[f] >= size) {
                    continue;
                }

                CfdEngine.ClosePreview memory preview =
                    engine.previewClose(accountId, fractions[f], oraclePrice, vaultDepthUsdc);

                if (!preview.valid) {
                    if (preview.invalidCode == 5) {
                        assertTrue(
                            preview.remainingSize > 0 && preview.remainingMargin < minBountyUsdc,
                            "invalidCode 5 must imply dust residual"
                        );
                    }
                    continue;
                }

                if (preview.remainingSize > 0) {
                    assertGe(
                        preview.remainingMargin,
                        minBountyUsdc,
                        "Valid partial close must not leave dust position (margin >= minBountyUsdc)"
                    );
                }
            }
        }
    }

    function invariant_ValidPartialCloseWithPositiveFundingImpliesVaultCanPay() public view {
        uint256 oraclePrice = _previewOraclePrice();
        uint256 vaultDepthUsdc = vault.totalAssets();
        (,,,,,,, uint256 minBountyUsdc,) = engine.riskParams();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            (uint256 size, uint256 margin,,,,,,) = engine.positions(accountId);
            if (size < 2) {
                continue;
            }

            uint256[3] memory fractions = _closeFractions(size, margin, minBountyUsdc);
            for (uint256 f = 0; f < 3; f++) {
                if (fractions[f] == 0 || fractions[f] >= size) {
                    continue;
                }

                CfdEngine.ClosePreview memory preview =
                    engine.previewClose(accountId, fractions[f], oraclePrice, vaultDepthUsdc);

                if (preview.valid && preview.fundingUsdc > 0) {
                    assertGe(
                        vault.totalAssets(),
                        uint256(preview.fundingUsdc),
                        "Valid partial close with positive funding requires vault to cover the outflow"
                    );
                }

                if (preview.invalidCode == 4) {
                    assertFalse(preview.valid, "invalidCode 4 must mark preview as invalid");
                    assertGt(preview.fundingUsdc, 0, "invalidCode 4 requires positive pending funding");
                }
            }
        }
    }

    function invariant_PartialCloseInvalidOnlyForNewCodes() public view {
        uint256 oraclePrice = _previewOraclePrice();
        uint256 vaultDepthUsdc = vault.totalAssets();
        (,,,,,,, uint256 minBountyUsdc,) = engine.riskParams();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            (uint256 size, uint256 margin,,,,,,) = engine.positions(accountId);
            if (size < 2) {
                continue;
            }

            CfdEngine.ClosePreview memory fullPreview =
                engine.previewClose(accountId, size, oraclePrice, vaultDepthUsdc);
            if (!fullPreview.valid) {
                continue;
            }

            uint256[3] memory fractions = _closeFractions(size, margin, minBountyUsdc);
            for (uint256 f = 0; f < 3; f++) {
                if (fractions[f] == 0 || fractions[f] >= size) {
                    continue;
                }

                CfdEngine.ClosePreview memory preview =
                    engine.previewClose(accountId, fractions[f], oraclePrice, vaultDepthUsdc);

                if (!preview.valid) {
                    assertTrue(
                        preview.invalidCode == 3 || preview.invalidCode == 4 || preview.invalidCode == 5,
                        "Partial close of valid-full-close position can only fail for shortfall (3), vault cash (4), or dust (5)"
                    );
                }
            }
        }
    }

    function invariant_FundingSettlementFieldsConsistent() public view {
        uint256 vaultDepthUsdc = vault.totalAssets();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            (uint256 size,,,,,,,) = engine.positions(accountId);
            if (size == 0) {
                continue;
            }

            CfdEngine.PreviewFundingSettlement memory partialFs =
                harness.exposed_previewFundingSettlement(accountId, false, vaultDepthUsdc);
            CfdEngine.PreviewFundingSettlement memory fullFs =
                harness.exposed_previewFundingSettlement(accountId, true, vaultDepthUsdc);

            assertEq(
                partialFs.pendingFundingUsdc,
                fullFs.pendingFundingUsdc,
                "Pending funding must be identical for full and partial"
            );

            if (partialFs.pendingFundingUsdc >= 0) {
                assertEq(
                    partialFs.fundingVaultCashInflowUsdc, 0, "Non-negative partial funding must not produce inflow"
                );
                assertEq(fullFs.fundingVaultCashInflowUsdc, 0, "Non-negative full funding must not produce inflow");
            } else {
                assertEq(
                    fullFs.fundingVaultCashInflowUsdc,
                    0,
                    "Full close negative funding uses closeFundingSettlement, not vault transfer"
                );
            }

            assertEq(fullFs.fundingVaultCashOutflowUsdc, 0, "Full close never produces vault funding outflow");
        }
    }

    function invariant_ImmediateDeferredSplitMatchesAdjustedCash() public view {
        uint256 oraclePrice = _previewOraclePrice();
        uint256 vaultDepthUsdc = vault.totalAssets();
        (,,,,,,, uint256 minBountyUsdc,) = engine.riskParams();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            (uint256 size, uint256 margin,,,,,,) = engine.positions(accountId);
            if (size == 0) {
                continue;
            }

            _checkPayoutSplit(accountId, size, oraclePrice, vaultDepthUsdc, true);

            if (size < 2) {
                continue;
            }

            uint256[3] memory fractions = _closeFractions(size, margin, minBountyUsdc);
            for (uint256 f = 0; f < 3; f++) {
                if (fractions[f] == 0 || fractions[f] >= size) {
                    continue;
                }
                _checkPayoutSplit(accountId, fractions[f], oraclePrice, vaultDepthUsdc, false);
            }
        }
    }

    function _checkPayoutSplit(
        bytes32 accountId,
        uint256 sizeDelta,
        uint256 oraclePrice,
        uint256 vaultDepthUsdc,
        bool isFullClose
    ) internal view {
        CfdEngine.ClosePreview memory preview = engine.previewClose(accountId, sizeDelta, oraclePrice, vaultDepthUsdc);

        if (!preview.valid || (preview.immediatePayoutUsdc == 0 && preview.deferredPayoutUsdc == 0)) {
            return;
        }

        CfdEngine.PreviewFundingSettlement memory fs =
            harness.exposed_previewFundingSettlement(accountId, isFullClose, vaultDepthUsdc);
        uint256 adjustedCash = vault.totalAssets() + fs.fundingVaultCashInflowUsdc - fs.fundingVaultCashOutflowUsdc;
        uint256 totalOwed = preview.immediatePayoutUsdc + preview.deferredPayoutUsdc;

        if (preview.immediatePayoutUsdc > 0) {
            assertGe(adjustedCash, preview.immediatePayoutUsdc, "Post-funding vault cash must cover immediate payout");
            assertEq(preview.deferredPayoutUsdc, 0, "Immediate payout excludes deferred payout");
        }

        if (preview.deferredPayoutUsdc > 0) {
            assertEq(preview.immediatePayoutUsdc, 0, "Deferred payout excludes immediate payout");
            assertLt(adjustedCash, totalOwed, "Deferred payout implies adjusted cash insufficient for full settlement");
        }
    }

    function _closeFractions(
        uint256 size,
        uint256 margin,
        uint256 minBountyUsdc
    ) internal pure returns (uint256[3] memory fractions) {
        fractions[0] = 1;
        fractions[1] = size / 2;
        if (margin > minBountyUsdc && size > 1) {
            fractions[2] = size * (margin - minBountyUsdc) / margin;
            if (fractions[2] == 0) {
                fractions[2] = 1;
            }
            if (fractions[2] >= size) {
                fractions[2] = size - 1;
            }
        } else {
            fractions[2] = size - 1;
        }
    }

    function _riskParams() internal pure returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.02e18,
            maxApy: 0.1e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 1e6,
            bountyBps: 9
        });
    }

    function _previewOraclePrice() internal view returns (uint256) {
        uint256 price = engine.lastMarkPrice();
        return price == 0 ? 1e8 : price;
    }

    function _accountId(
        address actor
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(actor)));
    }

}
