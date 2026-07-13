// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VimenZap3, IRialtoRegistry} from "../src/VimenZap3.sol";
import {IPoolManager} from "../src/interfaces/IUniswapV4.sol";

/// Deploys the VimenZap3 router (Uniswap v4 + Rialto, stateless, ownerless).
///
///   CONFIRM_DEPLOY=yes forge script script/DeployZap3.s.sol \
///     --rpc-url $RH_RPC --broadcast --private-key $DEPLOY_KEY \
///     --verify --verifier blockscout \
///     --verifier-url https://robinhoodchain.blockscout.com/api
contract DeployZap3 is Script {
    /// Uniswap v4 PoolManager on Robinhood Chain (unchanged from v1).
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    /// Rialto router registry, verified against docs.rialto.xyz 2026-07-12.
    address constant RIALTO_REGISTRY = 0x71a120CbBf3Ce7cD910a3c50fF77aFc62735687E;

    function run() external {
        require(block.chainid == 4663, "wrong chain: expected Robinhood Chain (4663)");
        require(POOL_MANAGER.code.length > 0, "PoolManager has no code on this chain");
        require(RIALTO_REGISTRY.code.length > 0, "Rialto registry has no code on this chain");

        (, address current,, bool paused) = IRialtoRegistry(RIALTO_REGISTRY).getFeature(2);
        require(current != address(0) && current.code.length > 0, "no active Rialto router");
        require(!paused, "Rialto swap feature is paused");

        console.log("=== VimenZap3 deploy config ===");
        console.log("PoolManager:   %s", POOL_MANAGER);
        console.log("RialtoRegistry:%s", RIALTO_REGISTRY);
        console.log("Active router: %s", current);

        // Same dry-run contract as Deploy.s.sol: without CONFIRM_DEPLOY=yes the
        // script prints the resolved config above and exits without broadcasting.
        if (keccak256(bytes(vm.envOr("CONFIRM_DEPLOY", string("")))) != keccak256("yes")) {
            console.log("DRY RUN ONLY - set CONFIRM_DEPLOY=yes to broadcast");
            return;
        }

        vm.startBroadcast();
        VimenZap3 zap = new VimenZap3(IPoolManager(POOL_MANAGER));
        vm.stopBroadcast();

        console.log("VimenZap3 deployed at: %s", address(zap));
        console.log("frontend: set NEXT_PUBLIC_ZAP_ADDRESS=%s", address(zap));
    }
}
