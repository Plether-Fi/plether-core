// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BridgeDepositReceiverFactory} from "@plether/perps/funding/BridgeDepositReceiverFactory.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @dev Read-only getters shared across the funding integration graph.
interface IFundingDeploymentBindings {

    function settlementAsset() external view returns (address);
    function decimals() external view returns (uint8);
    function engine() external view returns (address);
    function ENGINE() external view returns (address);
    function USDC() external view returns (address);
    function clearinghouse() external view returns (address);
    function pool() external view returns (address);
    function housePool() external view returns (address);
    function orderRouter() external view returns (address);
    function pletherOracle() external view returns (address);
    function lifecycleBook() external view returns (address);
    function ROUTER() external view returns (address);
    function CLEARINGHOUSE() external view returns (address);
    function HOUSE_POOL() external view returns (address);

}

/// @notice Deploys a receiver factory against an explicitly pinned, already deployed funding integration graph.
/// @dev No default network or integration addresses are supplied. Code hashes must be independently derived from
///      reviewed release artifacts, including a clearinghouse build that implements depositFor. This preflight does
///      not prove depositFor behavior; the separate release verifier requires a successful third-party deposit probe
///      before the manifest can be activated. Other perps sidecars, admin policy, and vault configuration still require
///      the ordinary perps release verification. Running this script without --broadcast only simulates deployment.
contract DeployBridgeDepositReceiverFactory is Script {

    struct Graph {
        address usdc;
        address clearinghouse;
        address engine;
        address housePool;
        address router;
        address oracle;
        address lifecycleBook;
    }

    function run() external returns (BridgeDepositReceiverFactory factory) {
        uint256 expectedChainId = vm.envUint("FUNDING_CHAIN_ID");
        require(expectedChainId != 0 && block.chainid == expectedChainId, "Funding chain mismatch");
        Graph memory graph = Graph({
            usdc: _readPinned("FUNDING_USDC", "FUNDING_USDC_CODE_HASH"),
            clearinghouse: _readPinned("FUNDING_CLEARINGHOUSE", "FUNDING_CLEARINGHOUSE_CODE_HASH"),
            engine: _readPinned("FUNDING_ENGINE", "FUNDING_ENGINE_CODE_HASH"),
            housePool: _readPinned("FUNDING_HOUSE_POOL", "FUNDING_HOUSE_POOL_CODE_HASH"),
            router: _readPinned("FUNDING_ROUTER", "FUNDING_ROUTER_CODE_HASH"),
            oracle: _readPinned("FUNDING_ORACLE", "FUNDING_ORACLE_CODE_HASH"),
            lifecycleBook: _readPinned("FUNDING_LIFECYCLE_BOOK", "FUNDING_LIFECYCLE_BOOK_CODE_HASH")
        });
        _verifyGraph(graph);

        // This reference exists only in the script simulation, outside broadcast. It derives the expected runtime
        // from this compiled artifact with the exact constructor immutables, without guessing or hand-patching them.
        BridgeDepositReceiverFactory referenceFactory =
            new BridgeDepositReceiverFactory(graph.clearinghouse, graph.usdc);
        bytes32 expectedRuntimeHash = address(referenceFactory).codehash;

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        factory = new BridgeDepositReceiverFactory(graph.clearinghouse, graph.usdc);
        vm.stopBroadcast();

        require(address(factory).code.length > 0, "Factory has no code");
        require(address(factory).codehash == expectedRuntimeHash, "Factory runtime mismatch");
        require(factory.clearinghouse() == graph.clearinghouse, "Factory clearinghouse mismatch");
        require(factory.usdc() == graph.usdc, "Factory token mismatch");
        console2.log("Funding chain", block.chainid);
        console2.log("BridgeDepositReceiverFactory", address(factory));
        console2.log("Clearinghouse", graph.clearinghouse);
        console2.log("Settlement token", graph.usdc);
        console2.log("Factory runtime code hash");
        console2.logBytes32(address(factory).codehash);
        console2.log("Run the separate funding release verifier with a mined depositFor probe before activation.");
    }

    function _readPinned(
        string memory addressVariable,
        string memory hashVariable
    ) internal view returns (address target) {
        target = vm.envAddress(addressVariable);
        bytes32 expectedHash = vm.envBytes32(hashVariable);
        require(target.code.length > 0, string.concat(addressVariable, " has no code"));
        require(expectedHash != bytes32(0) && target.codehash == expectedHash, string.concat(hashVariable, " mismatch"));
    }

    function _verifyGraph(
        Graph memory graph
    ) internal view {
        address[7] memory integrations = [
            graph.usdc,
            graph.clearinghouse,
            graph.engine,
            graph.housePool,
            graph.router,
            graph.oracle,
            graph.lifecycleBook
        ];
        for (uint256 i; i < integrations.length; ++i) {
            for (uint256 j = i + 1; j < integrations.length; ++j) {
                require(integrations[i] != integrations[j], "Aliased funding integrations");
            }
        }
        require(IFundingDeploymentBindings(graph.usdc).decimals() == 6, "Funding token must have six decimals");
        IFundingDeploymentBindings clearinghouse = IFundingDeploymentBindings(graph.clearinghouse);
        IFundingDeploymentBindings engine = IFundingDeploymentBindings(graph.engine);
        IFundingDeploymentBindings pool = IFundingDeploymentBindings(graph.housePool);
        IFundingDeploymentBindings router = IFundingDeploymentBindings(graph.router);
        IFundingDeploymentBindings oracle = IFundingDeploymentBindings(graph.oracle);
        IFundingDeploymentBindings lifecycleBook = IFundingDeploymentBindings(graph.lifecycleBook);

        require(clearinghouse.settlementAsset() == graph.usdc, "Clearinghouse token mismatch");
        require(clearinghouse.engine() == graph.engine, "Clearinghouse engine mismatch");
        require(engine.USDC() == graph.usdc, "Engine token mismatch");
        require(engine.clearinghouse() == graph.clearinghouse, "Engine clearinghouse mismatch");
        require(engine.pool() == graph.housePool, "Engine pool mismatch");
        require(engine.orderRouter() == graph.router, "Engine router mismatch");
        require(pool.USDC() == graph.usdc, "Pool token mismatch");
        require(pool.ENGINE() == graph.engine, "Pool engine mismatch");
        require(router.engine() == graph.engine, "Router engine mismatch");
        require(router.pletherOracle() == graph.oracle, "Router oracle mismatch");
        require(router.lifecycleBook() == graph.lifecycleBook, "Router lifecycle book mismatch");
        require(oracle.engine() == graph.engine, "Oracle engine mismatch");
        require(oracle.housePool() == graph.housePool, "Oracle pool mismatch");
        require(lifecycleBook.ROUTER() == graph.router, "Lifecycle book router mismatch");
        require(lifecycleBook.ENGINE() == graph.engine, "Lifecycle book engine mismatch");
        require(lifecycleBook.CLEARINGHOUSE() == graph.clearinghouse, "Lifecycle book clearinghouse mismatch");
        require(lifecycleBook.HOUSE_POOL() == graph.housePool, "Lifecycle book pool mismatch");
    }

}
