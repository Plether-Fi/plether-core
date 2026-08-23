// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {ITerminalNavBookV2} from "@plether/perps/interfaces/ITerminalNavBookV2.sol";
import "forge-std/Script.sol";

interface IMintableERC20 {

    function approve(
        address spender,
        uint256 amount
    ) external returns (bool);
    function mint(
        address to,
        uint256 amount
    ) external;

}

/// @dev Minimal compatibility surface used to reject an old or partially upgraded tranche pair before bootstrap.
interface IAsyncTrancheVaultBootstrapView {

    function POOL() external view returns (address);
    function IS_SENIOR() external view returns (bool);
    function asset() external view returns (address);
    function share() external view returns (address);
    function vault(
        address asset_
    ) external view returns (address);
    function supportsInterface(
        bytes4 interfaceId
    ) external view returns (bool);

}

contract BootstrapPerpsArbitrumSepolia is Script {

    uint256 internal constant DEFAULT_SENIOR_SEED_USDC = 50_000_000e6;
    uint256 internal constant DEFAULT_JUNIOR_SEED_USDC = 50_000_000e6;

    bytes4 internal constant ERC165_INTERFACE_ID = 0x01ffc9a7;
    bytes4 internal constant ERC7540_OPERATOR_INTERFACE_ID = 0xe3bc4e65;
    bytes4 internal constant ERC7575_INTERFACE_ID = 0x2f0a18c5;
    bytes4 internal constant ERC7575_SHARE_INTERFACE_ID = 0xf815c03d;
    bytes4 internal constant ERC7540_DEPOSIT_INTERFACE_ID = 0xce3bbe50;
    bytes4 internal constant ERC7540_REDEEM_INTERFACE_ID = 0x620ee8e4;

    function run() external {
        uint256 privateKey = vm.envUint("TEST_PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        address usdc = vm.envAddress("PERPS_USDC");
        address housePoolAddr = vm.envAddress("PERPS_HOUSE_POOL");
        address routerAddr = vm.envAddress("PERPS_ORDER_ROUTER");

        address pauser = vm.envOr("PERPS_PAUSER", address(0));
        uint256 maxSeniorExposureUsdc = vm.envUint("MAX_SENIOR_EXPOSURE_USDC");
        uint256 maxSeniorShareBps = vm.envUint("MAX_SENIOR_SHARE_BPS");
        uint256 seniorSeedUsdc = vm.envOr("SENIOR_SEED_USDC", DEFAULT_SENIOR_SEED_USDC);
        uint256 juniorSeedUsdc = vm.envOr("JUNIOR_SEED_USDC", DEFAULT_JUNIOR_SEED_USDC);
        address seniorSeedReceiver = vm.envOr("SENIOR_SEED_RECEIVER", deployer);
        address juniorSeedReceiver = vm.envOr("JUNIOR_SEED_RECEIVER", deployer);
        bool activateTrading = vm.envOr("ACTIVATE_TRADING", true);

        address[] memory testUsers = vm.envOr("TEST_USER_RECIPIENTS", ",", new address[](0));
        uint256[] memory testUserAmounts = vm.envOr("TEST_USER_AMOUNTS", ",", new uint256[](0));

        if (testUsers.length != testUserAmounts.length) {
            revert("TEST_USER_RECIPIENTS/AMOUNTS length mismatch");
        }

        HousePool housePool = HousePool(housePoolAddr);
        OrderRouter router = OrderRouter(routerAddr);
        OrderRouterAdmin routerAdmin = OrderRouterAdmin(router.admin());

        _validateSeniorLimits(maxSeniorExposureUsdc, maxSeniorShareBps);
        _verifyAsyncVaultPair(housePool, usdc);
        _verifyTerminalNavBook(housePool);
        _verifyRouterWiring(housePool, router);

        console.log("Bootstrapping Plether perps on Arbitrum Sepolia");
        console.log("Deployer:", deployer);
        console.log("USDC:", usdc);
        console.log("HousePool:", housePoolAddr);
        console.log("OrderRouter:", routerAddr);
        console.log("OrderRouterAdmin:", address(routerAdmin));

        vm.startBroadcast(privateKey);

        _configurePauser(housePool, routerAdmin, pauser);
        bool poolConfigReady = _configureSeniorLimits(housePool, maxSeniorExposureUsdc, maxSeniorShareBps);
        if (!poolConfigReady) {
            vm.stopBroadcast();
            console.log("");
            console.log("Senior limits proposed but not yet active.");
            console.log("Wait for the HousePool 48-hour timelock, then rerun this same command.");
            console.log("No tranche seeds, test-user funds, or trading activation were performed.");
            return;
        }
        _seedLifecycle(
            housePool,
            IMintableERC20(usdc),
            seniorSeedUsdc,
            juniorSeedUsdc,
            seniorSeedReceiver,
            juniorSeedReceiver,
            deployer
        );
        _fundTestUsers(IMintableERC20(usdc), testUsers, testUserAmounts);
        _activateTrading(housePool, activateTrading);

        vm.stopBroadcast();

        console.log("");
        console.log("HousePool trading active:", housePool.isTradingActive());
        console.log("Senior seed initialized:", housePool.seniorSeedInitialized());
        console.log("Junior seed initialized:", housePool.juniorSeedInitialized());
        console.log("HousePool pauser:", housePool.pauser());
        console.log("Router pauser:", routerAdmin.pauser());
        console.log("Maximum senior exposure (USDC units):", housePool.maxSeniorExposureUsdc());
        console.log("Maximum senior share (bps):", housePool.maxSeniorShareBps());
        console.log("LP epoch duration:", housePool.LP_EPOCH_DURATION());
        console.log("Maximum LP epochs per settlement phase:", housePool.MAX_LP_EPOCHS_PER_PHASE());
        console.log("Current LP epoch:", housePool.currentLpEpoch());
        console.log("Note: this script funds users with mock USDC only; ETH still needs a faucet.");
    }

    /// @dev Refuses to seed or activate a stack whose exact terminal-NAV book is absent or misbound.
    function _verifyTerminalNavBook(
        HousePool housePool
    ) internal view {
        CfdEngine engine = CfdEngine(address(housePool.ENGINE()));
        ITerminalNavBookV2 book = engine.terminalNavBook();
        require(address(book) != address(0), "TerminalNavBookV2 is not wired");
        require(address(book).code.length > 0, "TerminalNavBookV2 has no code");
        require(book.ENGINE() == address(engine), "TerminalNavBookV2 engine mismatch");
        require(book.CAP_PRICE() == uint32(engine.CAP_PRICE()), "TerminalNavBookV2 cap mismatch");
        require(book.SIZE_QUANTUM() == 1e20, "TerminalNavBookV2 quantum mismatch");
    }

    /// @dev Refuses to bootstrap a stack whose permissionless Router cannot authenticate the HousePool callback or
    ///      whose oracle is wired to another Engine/HousePool pair.
    function _verifyRouterWiring(
        HousePool housePool,
        OrderRouter router
    ) internal view {
        CfdEngine engine = CfdEngine(address(housePool.ENGINE()));
        require(engine.orderRouter() == address(router), "Engine OrderRouter mismatch");
        require(address(router.pletherOracle()).code.length > 0, "PletherOracle has no code");
        require(address(router.pletherOracle().engine()) == address(engine), "PletherOracle Engine mismatch");
        require(address(router.pletherOracle().housePool()) == address(housePool), "PletherOracle HousePool mismatch");
        require(address(router.pyth()).code.length > 0, "Pyth has no code");
    }

    /// @dev Checks all immutable/set-once LP wiring before any governance proposal, seed mint, or activation occurs.
    function _verifyAsyncVaultPair(
        HousePool housePool,
        address usdc
    ) internal view {
        require(address(housePool.USDC()) == usdc, "PERPS_USDC does not match HousePool");
        require(housePool.LP_EPOCH_DURATION() == 1 hours, "Unexpected LP epoch duration");
        require(housePool.MAX_LP_EPOCHS_PER_PHASE() == 16, "Unexpected LP epoch bound");

        uint256 currentEpoch = housePool.currentLpEpoch();
        require(currentEpoch == block.timestamp / housePool.LP_EPOCH_DURATION(), "Invalid current LP epoch");
        require(
            housePool.lpEpochStart(currentEpoch) == currentEpoch * housePool.LP_EPOCH_DURATION(),
            "Invalid LP epoch start"
        );

        address seniorVault = housePool.seniorVault();
        address juniorVault = housePool.juniorVault();
        require(seniorVault != address(0) && juniorVault != address(0), "HousePool vault pair is incomplete");
        require(seniorVault != juniorVault, "HousePool vault pair is duplicated");
        _verifyAsyncVault(seniorVault, address(housePool), usdc, true);
        _verifyAsyncVault(juniorVault, address(housePool), usdc, false);
    }

    function _verifyAsyncVault(
        address vault,
        address housePool,
        address usdc,
        bool isSenior
    ) internal view {
        IAsyncTrancheVaultBootstrapView candidate = IAsyncTrancheVaultBootstrapView(vault);
        require(candidate.POOL() == housePool, "TrancheVault pool mismatch");
        require(candidate.IS_SENIOR() == isSenior, "TrancheVault side mismatch");
        require(candidate.asset() == usdc, "TrancheVault asset mismatch");
        require(candidate.share() == vault, "TrancheVault share mismatch");
        require(candidate.supportsInterface(ERC165_INTERFACE_ID), "TrancheVault missing ERC165");
        require(candidate.supportsInterface(ERC7540_OPERATOR_INTERFACE_ID), "TrancheVault missing ERC7540 operator");
        require(candidate.supportsInterface(ERC7575_INTERFACE_ID), "TrancheVault missing ERC7575");
        require(candidate.supportsInterface(ERC7575_SHARE_INTERFACE_ID), "TrancheVault missing ERC7575 share lookup");
        require(candidate.supportsInterface(ERC7540_DEPOSIT_INTERFACE_ID), "TrancheVault missing async deposit");
        require(candidate.supportsInterface(ERC7540_REDEEM_INTERFACE_ID), "TrancheVault missing async redeem");
        require(!candidate.supportsInterface(0xffffffff), "TrancheVault accepts invalid ERC165 id");
        require(candidate.vault(usdc) == vault, "TrancheVault share lookup mismatch");
    }

    /// @dev Stages finite senior limits on the first run, then finalizes the exact proposal on a later run after the
    ///      HousePool timelock. Returning false deliberately stops bootstrap before either seed is initialized.
    function _configureSeniorLimits(
        HousePool housePool,
        uint256 maxSeniorExposureUsdc,
        uint256 maxSeniorShareBps
    ) internal returns (bool ready) {
        uint256 activationTime = housePool.poolConfigActivationTime();
        bool activeLimitsMatch = housePool.maxSeniorExposureUsdc() == maxSeniorExposureUsdc
            && housePool.maxSeniorShareBps() == maxSeniorShareBps;

        if (activeLimitsMatch) {
            if (activationTime != 0) {
                revert("Outstanding HousePool config proposal");
            }
            return true;
        }

        IHousePool.PoolConfig memory desiredConfig = IHousePool.PoolConfig({
            seniorRateBps: housePool.seniorRateBps(),
            markStalenessLimit: housePool.markStalenessLimit(),
            seniorFrozenLpFeeBps: housePool.seniorFrozenLpFeeBps(),
            juniorFrozenLpFeeBps: housePool.juniorFrozenLpFeeBps(),
            maxSeniorExposureUsdc: maxSeniorExposureUsdc,
            maxSeniorShareBps: maxSeniorShareBps
        });

        if (activationTime == 0) {
            housePool.proposePoolConfig(desiredConfig);
            console.log("Proposed maximum senior exposure:", maxSeniorExposureUsdc);
            console.log("Proposed maximum senior share (bps):", maxSeniorShareBps);
            console.log("Pool config activation time:", housePool.poolConfigActivationTime());
            return false;
        }

        (
            uint256 pendingSeniorRateBps,
            uint256 pendingMarkStalenessLimit,
            uint256 pendingSeniorFrozenLpFeeBps,
            uint256 pendingJuniorFrozenLpFeeBps,
            uint256 pendingMaxSeniorExposureUsdc,
            uint256 pendingMaxSeniorShareBps
        ) = housePool.pendingPoolConfig();
        if (
            pendingSeniorRateBps != desiredConfig.seniorRateBps
                || pendingMarkStalenessLimit != desiredConfig.markStalenessLimit
                || pendingSeniorFrozenLpFeeBps != desiredConfig.seniorFrozenLpFeeBps
                || pendingJuniorFrozenLpFeeBps != desiredConfig.juniorFrozenLpFeeBps
                || pendingMaxSeniorExposureUsdc != desiredConfig.maxSeniorExposureUsdc
                || pendingMaxSeniorShareBps != desiredConfig.maxSeniorShareBps
        ) {
            revert("Pending HousePool config does not match bootstrap limits");
        }

        if (block.timestamp < activationTime) {
            console.log("HousePool config is still timelocked until:", activationTime);
            return false;
        }

        housePool.finalizePoolConfig();
        console.log("Finalized maximum senior exposure:", maxSeniorExposureUsdc);
        console.log("Finalized maximum senior share (bps):", maxSeniorShareBps);
        return true;
    }

    function _validateSeniorLimits(
        uint256 maxSeniorExposureUsdc,
        uint256 maxSeniorShareBps
    ) internal pure {
        if (maxSeniorExposureUsdc == type(uint256).max) {
            revert("MAX_SENIOR_EXPOSURE_USDC must be finite");
        }
        if (maxSeniorShareBps >= 10_000) {
            revert("MAX_SENIOR_SHARE_BPS must be below 10000");
        }
    }

    function _configurePauser(
        HousePool housePool,
        OrderRouterAdmin routerAdmin,
        address pauser
    ) internal {
        if (pauser == address(0)) {
            return;
        }

        if (housePool.pauser() != pauser) {
            housePool.setPauser(pauser);
            console.log("Set HousePool pauser:", pauser);
        }

        if (routerAdmin.pauser() != pauser) {
            routerAdmin.setPauser(pauser);
            console.log("Set OrderRouterAdmin pauser:", pauser);
        }
    }

    function _seedLifecycle(
        HousePool housePool,
        IMintableERC20 usdc,
        uint256 seniorSeedUsdc,
        uint256 juniorSeedUsdc,
        address seniorSeedReceiver,
        address juniorSeedReceiver,
        address seedFunder
    ) internal {
        uint256 totalSeedUsdc;
        if (!housePool.seniorSeedInitialized() && seniorSeedUsdc > 0) {
            totalSeedUsdc += seniorSeedUsdc;
        }
        if (!housePool.juniorSeedInitialized() && juniorSeedUsdc > 0) {
            totalSeedUsdc += juniorSeedUsdc;
        }

        if (totalSeedUsdc > 0) {
            usdc.mint(seedFunder, totalSeedUsdc);
            usdc.approve(address(housePool), totalSeedUsdc);
            console.log("Minted seed USDC to broadcaster:", seedFunder);
            console.log("Seed USDC amount:", totalSeedUsdc);
        }

        if (!housePool.juniorSeedInitialized() && juniorSeedUsdc > 0) {
            housePool.initializeSeedPosition(false, juniorSeedUsdc, juniorSeedReceiver);
            console.log("Initialized junior seed:", juniorSeedUsdc);
            console.log("Junior seed receiver:", juniorSeedReceiver);
        }

        if (!housePool.seniorSeedInitialized() && seniorSeedUsdc > 0) {
            housePool.initializeSeedPosition(true, seniorSeedUsdc, seniorSeedReceiver);
            console.log("Initialized senior seed:", seniorSeedUsdc);
            console.log("Senior seed receiver:", seniorSeedReceiver);
        }
    }

    function _fundTestUsers(
        IMintableERC20 usdc,
        address[] memory testUsers,
        uint256[] memory testUserAmounts
    ) internal {
        for (uint256 i; i < testUsers.length; ++i) {
            if (testUsers[i] == address(0) || testUserAmounts[i] == 0) {
                continue;
            }
            usdc.mint(testUsers[i], testUserAmounts[i]);
            console.log("Funded test user:", testUsers[i]);
            console.log("Amount:", testUserAmounts[i]);
        }
    }

    function _activateTrading(
        HousePool housePool,
        bool activateTrading
    ) internal {
        if (!activateTrading || housePool.isTradingActive()) {
            return;
        }

        if (!housePool.seniorSeedInitialized() || !housePool.juniorSeedInitialized()) {
            revert("Cannot activate trading before both seeds exist");
        }

        housePool.activateTrading();
        console.log("Activated trading");
    }

}
