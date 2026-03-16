// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../../src/perps/CfdTypes.sol";
import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpAccountingHandler} from "./handlers/PerpAccountingHandler.sol";

contract PerpClosePreviewParityInvariantTest is BasePerpInvariantTest {

    PerpAccountingHandler internal handler;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
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

    function _initialVaultAssets() internal pure override returns (uint256) {
        return 100_000e6;
    }

    function setUp() public override {
        super.setUp();

        handler = new PerpAccountingHandler(usdc, engine, clearinghouse, router, vault);
        handler.seedActors(50_000e6, 50_000e6);

        bytes4[] memory selectors = new bytes4[](10);
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

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_ValidPartialCloseNeverLeavesDustPosition() public view {
        uint256 oraclePrice = _previewOraclePrice();
        uint256 vaultDepthUsdc = vault.totalAssets();
        (,,,,,,, uint256 minBountyUsdc,) = engine.riskParams();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            (uint256 size,,,,,,,) = engine.positions(accountId);
            if (size < 2) {
                continue;
            }

            uint256[3] memory fractions = _closeFractions(size);
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

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            (uint256 size,,,,,,,) = engine.positions(accountId);
            if (size < 2) {
                continue;
            }

            uint256[3] memory fractions = _closeFractions(size);
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

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            (uint256 size,,,,,,,) = engine.positions(accountId);
            if (size < 2) {
                continue;
            }

            CfdEngine.ClosePreview memory fullPreview =
                engine.previewClose(accountId, size, oraclePrice, vaultDepthUsdc);
            if (!fullPreview.valid) {
                continue;
            }

            uint256[3] memory fractions = _closeFractions(size);
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

    function invariant_NegativeFundingInflowImprovesPartialCloseSolvency() public view {
        uint256 oraclePrice = _previewOraclePrice();
        uint256 vaultDepthUsdc = vault.totalAssets();

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            (uint256 size,,,,,,,) = engine.positions(accountId);
            if (size < 2) {
                continue;
            }

            CfdEngine.ClosePreview memory fullPreview =
                engine.previewClose(accountId, size, oraclePrice, vaultDepthUsdc);
            if (!fullPreview.valid) {
                continue;
            }

            uint256 partialSize = size / 2;
            CfdEngine.ClosePreview memory partialPreview =
                engine.previewClose(accountId, partialSize, oraclePrice, vaultDepthUsdc);
            if (!partialPreview.valid || partialPreview.fundingUsdc >= 0) {
                continue;
            }

            uint256 partialEffective = partialPreview.effectiveAssetsAfterUsdc;
            uint256 partialLiability = partialPreview.maxLiabilityAfterUsdc;

            assertGe(
                partialEffective + partialLiability,
                fullPreview.effectiveAssetsAfterUsdc + fullPreview.maxLiabilityAfterUsdc,
                "Negative funding inflow must not reduce total effective+liability pool vs full close"
            );
        }
    }

    function _closeFractions(
        uint256 size
    ) internal pure returns (uint256[3] memory fractions) {
        fractions[0] = 1;
        fractions[1] = size / 2;
        fractions[2] = size - 1;
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
