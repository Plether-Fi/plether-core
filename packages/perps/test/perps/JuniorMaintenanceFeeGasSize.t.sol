// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";

/// @dev Test-only mint driver that isolates the production vault's `_update` fee hook.
contract TrancheVaultMaintenanceFeeGasDriver is TrancheVault {

    constructor(
        IERC20 asset_,
        address pool_,
        bool isSenior_
    ) TrancheVault(asset_, pool_, isSenior_, "Maintenance Fee Gas Driver", "feeGas", 0, address(0)) {}

    function mintForGasTest(
        address receiver,
        uint256 shares
    ) external {
        _mint(receiver, shares);
    }

    function burnForGasTest(
        address owner,
        uint256 shares
    ) external {
        _burn(owner, shares);
    }

}

/// @notice Runtime-size and gas acceptance gates for Junior maintenance-fee integration.
contract JuniorMaintenanceFeeGasSizeTest is BasePerpTest {

    uint256 internal constant EIP170_RUNTIME_CODE_LIMIT = 24_576;
    uint256 internal constant HOUSE_POOL_RUNTIME_TARGET = 24_529;
    uint256 internal constant TRANCHE_VAULT_RUNTIME_TARGET = 24_000;
    uint256 internal constant DEFAULT_ZERO_INCREMENTAL_GAS_LIMIT = 5000;
    uint256 internal constant ACTIVE_EPOCH_SETTLEMENT_GAS_LIMIT = 1_000_000;
    uint256 internal constant ACTIVE_EPOCH_INCREMENTAL_GAS_LIMIT = 150_000;

    uint256 internal constant SEED_SHARES = 1_000_000e9;
    uint256 internal constant MUTATION_SHARES = 1000e9;
    uint256 internal constant EPOCH_DEPOSIT_ASSETS = 100_000e6;
    address internal constant FEE_RECIPIENT = address(0xFEE);
    address internal constant EPOCH_DEPOSITOR = address(0xE90C);

    function test_Runtime_HousePoolAndTrancheVaultStayWithinAcceptanceTargets() public {
        uint256 poolRuntime = address(pool).code.length;
        uint256 trancheVaultRuntime = address(juniorVault).code.length;

        emit log_named_uint("house_pool_runtime_bytes", poolRuntime);
        emit log_named_uint("tranche_vault_runtime_bytes", trancheVaultRuntime);

        assertLe(poolRuntime, HOUSE_POOL_RUNTIME_TARGET, "HousePool exceeds its measured runtime target");
        assertLt(poolRuntime, EIP170_RUNTIME_CODE_LIMIT, "HousePool must remain EIP-170 deployable");
        assertLe(trancheVaultRuntime, TRANCHE_VAULT_RUNTIME_TARGET, "TrancheVault exceeds its runtime target");
        assertLt(trancheVaultRuntime, EIP170_RUNTIME_CODE_LIMIT, "TrancheVault must remain EIP-170 deployable");
    }

    function test_Gas_DefaultZeroJuniorSupplyMutationAddsAtMostFiveThousandGas() public {
        TrancheVaultMaintenanceFeeGasDriver seniorDriver = _newDriver(true);
        TrancheVaultMaintenanceFeeGasDriver juniorDriver = _newDriver(false);
        seniorDriver.mintForGasTest(address(0x5100), SEED_SHARES);
        juniorDriver.mintForGasTest(address(0x6100), SEED_SHARES);

        uint256 gasBefore = gasleft();
        seniorDriver.mintForGasTest(address(0x5101), MUTATION_SHARES);
        uint256 seniorGas = gasBefore - gasleft();

        gasBefore = gasleft();
        juniorDriver.mintForGasTest(address(0x6101), MUTATION_SHARES);
        uint256 juniorGas = gasBefore - gasleft();
        uint256 incrementalGas = juniorGas > seniorGas ? juniorGas - seniorGas : 0;

        emit log_named_uint("default_zero_senior_supply_mutation_gas", seniorGas);
        emit log_named_uint("default_zero_junior_supply_mutation_gas", juniorGas);
        emit log_named_uint("default_zero_incremental_gas", incrementalGas);

        assertEq(juniorDriver.maintenanceFeeAprBps(), 0, "Junior driver must retain the deployment default");
        assertEq(juniorDriver.pendingMaintenanceFeeShares(), 0, "zero fee must not accrue shares");
        assertLe(
            incrementalGas, DEFAULT_ZERO_INCREMENTAL_GAS_LIMIT, "default-zero Junior supply mutation overhead regressed"
        );
    }

    function test_Gas_DefaultZeroJuniorSupplyBurnAddsAtMostFiveThousandGas() public {
        TrancheVaultMaintenanceFeeGasDriver seniorDriver = _newDriver(true);
        TrancheVaultMaintenanceFeeGasDriver juniorDriver = _newDriver(false);
        address seniorOwner = address(0x5200);
        address juniorOwner = address(0x6200);
        seniorDriver.mintForGasTest(seniorOwner, SEED_SHARES);
        juniorDriver.mintForGasTest(juniorOwner, SEED_SHARES);

        uint256 gasBefore = gasleft();
        seniorDriver.burnForGasTest(seniorOwner, MUTATION_SHARES);
        uint256 seniorGas = gasBefore - gasleft();

        gasBefore = gasleft();
        juniorDriver.burnForGasTest(juniorOwner, MUTATION_SHARES);
        uint256 juniorGas = gasBefore - gasleft();
        uint256 incrementalGas = juniorGas > seniorGas ? juniorGas - seniorGas : 0;

        emit log_named_uint("default_zero_senior_supply_burn_gas", seniorGas);
        emit log_named_uint("default_zero_junior_supply_burn_gas", juniorGas);
        emit log_named_uint("default_zero_burn_incremental_gas", incrementalGas);

        assertEq(juniorDriver.maintenanceFeeAprBps(), 0, "Junior driver must retain the deployment default");
        assertEq(juniorDriver.pendingMaintenanceFeeShares(), 0, "zero fee must not accrue shares");
        assertLe(
            incrementalGas, DEFAULT_ZERO_INCREMENTAL_GAS_LIMIT, "default-zero Junior supply burn overhead regressed"
        );
    }

    function test_Gas_MaximumCatchUpActiveFeeHousePoolEpochSettlementRemainsPracticallyBounded() public {
        uint256 requestId = _requestJuniorDepositForGas(EPOCH_DEPOSITOR, EPOCH_DEPOSIT_ASSETS);
        uint256 branchPoint = vm.snapshotState();

        juniorVault.proposeMaintenanceFeeConfig(1000, FEE_RECIPIENT);
        vm.warp(juniorVault.maintenanceFeeConfigActivationTime());
        juniorVault.finalizeMaintenanceFeeConfig();
        uint256 settlementTime = juniorVault.maintenanceFeeCheckpointBoundary() + 2
            * juniorVault.MAX_MAINTENANCE_FEE_CHECKPOINT_HOURS() * 1 hours;
        vm.warp(settlementTime);
        assertLe(requestId, pool.currentLpEpoch(), "fee branch must mature the queued deposit");
        uint256 expectedFeeShares = juniorVault.pendingMaintenanceFeeShares();
        assertGt(expectedFeeShares, 0, "fee branch must have accrued dilution");

        uint256 activeReady = vm.snapshotState();
        pool.settleLpEpoch(0, 0);
        vm.revertToState(activeReady);

        uint256 gasBefore = gasleft();
        pool.settleLpEpoch(0, 0);
        uint256 activeFeeSettlementGas = gasBefore - gasleft();
        assertEq(
            juniorVault.balanceOf(FEE_RECIPIENT), expectedFeeShares, "active settlement must mint the capped fee quote"
        );
        assertEq(
            juniorVault.maintenanceFeeCheckpointBoundary(),
            settlementTime,
            "maximum catch-up must advance directly to the current completed-hour boundary"
        );
        assertEq(
            juniorVault.claimableDepositRequest(requestId, EPOCH_DEPOSITOR),
            EPOCH_DEPOSIT_ASSETS,
            "active settlement must consume the matured deposit"
        );

        vm.revertToState(branchPoint);
        vm.warp(settlementTime);
        assertEq(juniorVault.maintenanceFeeAprBps(), 0, "comparison branch must retain the default-zero fee");

        uint256 defaultReady = vm.snapshotState();
        pool.settleLpEpoch(0, 0);
        vm.revertToState(defaultReady);

        gasBefore = gasleft();
        pool.settleLpEpoch(0, 0);
        uint256 defaultFeeSettlementGas = gasBefore - gasleft();
        uint256 incrementalGas =
            activeFeeSettlementGas > defaultFeeSettlementGas ? activeFeeSettlementGas - defaultFeeSettlementGas : 0;

        emit log_named_uint("house_pool_default_zero_epoch_settlement_gas", defaultFeeSettlementGas);
        emit log_named_uint("house_pool_active_fee_epoch_settlement_gas", activeFeeSettlementGas);
        emit log_named_uint("house_pool_active_fee_incremental_gas", incrementalGas);

        assertEq(juniorVault.balanceOf(FEE_RECIPIENT), 0, "default settlement must not mint fee shares");
        assertEq(
            juniorVault.claimableDepositRequest(requestId, EPOCH_DEPOSITOR),
            EPOCH_DEPOSIT_ASSETS,
            "default settlement must consume the same matured deposit"
        );
        assertLe(
            activeFeeSettlementGas,
            ACTIVE_EPOCH_SETTLEMENT_GAS_LIMIT,
            "active-fee HousePool epoch settlement exceeds the practical gas bound"
        );
        assertLe(
            incrementalGas,
            ACTIVE_EPOCH_INCREMENTAL_GAS_LIMIT,
            "active fee adds too much gas to an equivalent HousePool epoch settlement"
        );
    }

    function _newDriver(
        bool isSenior
    ) internal returns (TrancheVaultMaintenanceFeeGasDriver driver) {
        driver = new TrancheVaultMaintenanceFeeGasDriver(IERC20(address(usdc)), address(pool), isSenior);
    }

    function _requestJuniorDepositForGas(
        address owner,
        uint256 assets
    ) internal returns (uint256 requestId) {
        usdc.mint(owner, assets);
        vm.startPrank(owner);
        usdc.approve(address(juniorVault), assets);
        requestId = juniorVault.requestDeposit(assets, owner, owner);
        vm.stopPrank();
    }

}
