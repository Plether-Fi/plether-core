// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {HousePool} from "@plether/perps/HousePool.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
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

contract BootstrapPerpsArbitrumSepolia is Script {

    uint256 internal constant DEFAULT_SENIOR_SEED_USDC = 50_000_000e6;
    uint256 internal constant DEFAULT_JUNIOR_SEED_USDC = 50_000_000e6;

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
        console.log("Note: this script funds users with mock USDC only; ETH still needs a faucet.");
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
