// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {HousePool} from "../src/perps/HousePool.sol";
import {OrderRouter} from "../src/perps/OrderRouter.sol";
import {OrderRouterAdmin} from "../src/perps/OrderRouterAdmin.sol";
import "forge-std/Script.sol";

interface IMintableERC20 {

    function approve(address spender, uint256 amount) external returns (bool);
    function mint(address to, uint256 amount) external;

}

contract BootstrapPerpsArbitrumSepolia is Script {

    function run() external {
        uint256 privateKey = vm.envUint("TEST_PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        address usdc = vm.envAddress("PERPS_USDC");
        address housePoolAddr = vm.envAddress("PERPS_HOUSE_POOL");
        address routerAddr = vm.envAddress("PERPS_ORDER_ROUTER");

        address pauser = vm.envOr("PERPS_PAUSER", address(0));
        uint256 seniorSeedUsdc = vm.envOr("SENIOR_SEED_USDC", uint256(1000e6));
        uint256 juniorSeedUsdc = vm.envOr("JUNIOR_SEED_USDC", uint256(1000e6));
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

        console.log("Bootstrapping Plether perps on Arbitrum Sepolia");
        console.log("Deployer:", deployer);
        console.log("USDC:", usdc);
        console.log("HousePool:", housePoolAddr);
        console.log("OrderRouter:", routerAddr);
        console.log("OrderRouterAdmin:", address(routerAdmin));

        vm.startBroadcast(privateKey);

        _configurePauser(housePool, routerAdmin, pauser);
        _seedLifecycle(housePool, IMintableERC20(usdc), seniorSeedUsdc, juniorSeedUsdc, seniorSeedReceiver, juniorSeedReceiver);
        _fundTestUsers(IMintableERC20(usdc), testUsers, testUserAmounts);
        _activateTrading(housePool, activateTrading);

        vm.stopBroadcast();

        console.log("");
        console.log("HousePool trading active:", housePool.isTradingActive());
        console.log("Senior seed initialized:", housePool.seniorSeedInitialized());
        console.log("Junior seed initialized:", housePool.juniorSeedInitialized());
        console.log("HousePool pauser:", housePool.pauser());
        console.log("Router pauser:", routerAdmin.pauser());
        console.log("Note: this script funds users with mock USDC only; ETH still needs a faucet.");
    }

    function _configurePauser(HousePool housePool, OrderRouterAdmin routerAdmin, address pauser) internal {
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
        address juniorSeedReceiver
    ) internal {
        uint256 totalSeedUsdc;
        if (!housePool.seniorSeedInitialized() && seniorSeedUsdc > 0) {
            totalSeedUsdc += seniorSeedUsdc;
        }
        if (!housePool.juniorSeedInitialized() && juniorSeedUsdc > 0) {
            totalSeedUsdc += juniorSeedUsdc;
        }

        if (totalSeedUsdc > 0) {
            usdc.mint(address(this), totalSeedUsdc);
            usdc.approve(address(housePool), totalSeedUsdc);
            console.log("Minted seed USDC to broadcaster:", totalSeedUsdc);
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

    function _fundTestUsers(IMintableERC20 usdc, address[] memory testUsers, uint256[] memory testUserAmounts) internal {
        for (uint256 i; i < testUsers.length; ++i) {
            if (testUsers[i] == address(0) || testUserAmounts[i] == 0) {
                continue;
            }
            usdc.mint(testUsers[i], testUserAmounts[i]);
            console.log("Funded test user:", testUsers[i]);
            console.log("Amount:", testUserAmounts[i]);
        }
    }

    function _activateTrading(HousePool housePool, bool activateTrading) internal {
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
