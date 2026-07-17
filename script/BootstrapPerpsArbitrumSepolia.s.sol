// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
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

    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421_614;
    uint256 internal constant DEFAULT_SENIOR_SEED_USDC = 50_000_000e6;
    uint256 internal constant DEFAULT_JUNIOR_SEED_USDC = 50_000_000e6;
    bool internal constant DEFAULT_ACTIVATE_TRADING = false;

    error BootstrapPerpsArbitrumSepolia__WrongChain(uint256 actualChainId);
    error BootstrapPerpsArbitrumSepolia__MissingCode(address target);
    error BootstrapPerpsArbitrumSepolia__StackMismatch();

    function run() external {
        if (block.chainid != ARBITRUM_SEPOLIA_CHAIN_ID) {
            revert BootstrapPerpsArbitrumSepolia__WrongChain(block.chainid);
        }

        uint256 privateKey = vm.envUint("TEST_PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        address usdc = vm.envAddress("PERPS_USDC");
        address housePoolAddr = vm.envAddress("PERPS_HOUSE_POOL");
        address routerAddr = vm.envAddress("PERPS_ORDER_ROUTER");

        address pauser = vm.envOr("PERPS_PAUSER", address(0));
        uint256 seniorSeedUsdc = vm.envOr("SENIOR_SEED_USDC", DEFAULT_SENIOR_SEED_USDC);
        uint256 juniorSeedUsdc = vm.envOr("JUNIOR_SEED_USDC", DEFAULT_JUNIOR_SEED_USDC);
        address seniorSeedReceiver = vm.envOr("SENIOR_SEED_RECEIVER", deployer);
        address juniorSeedReceiver = vm.envOr("JUNIOR_SEED_RECEIVER", deployer);
        bool activateTrading = vm.envOr("ACTIVATE_TRADING", DEFAULT_ACTIVATE_TRADING);

        address[] memory testUsers = vm.envOr("TEST_USER_RECIPIENTS", ",", new address[](0));
        uint256[] memory testUserAmounts = vm.envOr("TEST_USER_AMOUNTS", ",", new uint256[](0));

        if (testUsers.length != testUserAmounts.length) {
            revert("TEST_USER_RECIPIENTS/AMOUNTS length mismatch");
        }

        HousePool housePool = HousePool(housePoolAddr);
        OrderRouter router = OrderRouter(routerAddr);
        _validateStack(usdc, housePool, router);
        OrderRouterAdmin routerAdmin = OrderRouterAdmin(router.admin());

        console.log("Bootstrapping Plether perps on Arbitrum Sepolia");
        console.log("Deployer:", deployer);
        console.log("USDC:", usdc);
        console.log("HousePool:", housePoolAddr);
        console.log("OrderRouter:", routerAddr);
        console.log("OrderRouterAdmin:", address(routerAdmin));

        vm.startBroadcast(privateKey);

        _configurePauser(housePool, routerAdmin, pauser);
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
        console.log("Note: this script funds users with mock USDC only; ETH still needs a faucet.");
    }

    function _validateStack(
        address usdc,
        HousePool housePool,
        OrderRouter router
    ) internal view {
        _requireCode(usdc);
        _requireCode(address(housePool));
        _requireCode(address(router));

        address engine = address(housePool.ENGINE());
        address oracle = address(router.pletherOracle());
        address routerAdmin = router.admin();

        _requireCode(engine);
        _requireCode(oracle);
        _requireCode(routerAdmin);

        address clearinghouseAddress = housePool.ENGINE().clearinghouse();
        _requireCode(clearinghouseAddress);

        MarginClearinghouse clearinghouse = MarginClearinghouse(clearinghouseAddress);

        if (
            address(housePool.USDC()) != usdc || address(housePool.ENGINE().USDC()) != usdc
                || clearinghouse.settlementAsset() != usdc || clearinghouse.engine() != engine
                || housePool.ENGINE().pool() != address(housePool)
                || housePool.ENGINE().orderRouter() != address(router) || address(router.engine()) != engine
                || address(router.pletherOracle().engine()) != engine
                || address(router.pletherOracle().housePool()) != address(housePool)
        ) {
            revert BootstrapPerpsArbitrumSepolia__StackMismatch();
        }
    }

    function _requireCode(
        address target
    ) private view {
        if (target.code.length == 0) {
            revert BootstrapPerpsArbitrumSepolia__MissingCode(target);
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
