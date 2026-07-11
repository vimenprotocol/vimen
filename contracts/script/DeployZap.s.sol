// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VimenZap} from "../src/VimenZap.sol";
import {IPoolManager} from "../src/interfaces/IUniswapV4.sol";

/// Deploys the VimenZap router. Stateless, ownerless: one deploy, no wiring.
///
///   CONFIRM_DEPLOY=yes forge script script/DeployZap.s.sol \
///     --rpc-url $RH_RPC --broadcast --private-key $DEPLOY_KEY \
///     --verify --verifier blockscout \
///     --verifier-url https://robinhoodchain.blockscout.com/api
contract DeployZap is Script {
    /// Uniswap v4 PoolManager on Robinhood Chain, verified on-chain 2026-07-11
    /// (holds the live stock-token pools; see docs/ZAP.md).
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function run() external {
        require(block.chainid == 4663, "wrong chain: expected Robinhood Chain (4663)");
        require(POOL_MANAGER.code.length > 0, "PoolManager has no code on this chain");

        console.log("=== VimenZap deploy config ===");
        console.log("PoolManager: %s", POOL_MANAGER);

        // Same dry-run contract as Deploy.s.sol: without CONFIRM_DEPLOY=yes the
        // script prints the resolved config above and exits without broadcasting.
        if (keccak256(bytes(vm.envOr("CONFIRM_DEPLOY", string("")))) != keccak256("yes")) {
            console.log("DRY RUN ONLY - set CONFIRM_DEPLOY=yes to broadcast");
            return;
        }

        vm.startBroadcast();
        VimenZap zap = new VimenZap(IPoolManager(POOL_MANAGER));
        vm.stopBroadcast();

        console.log("VimenZap deployed at: %s", address(zap));
        console.log("frontend: set NEXT_PUBLIC_ZAP_ADDRESS=%s", address(zap));
    }
}
