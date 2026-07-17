// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PoolTwapObserver, IPoolManagerExtsload} from "../src/PoolTwapObserver.sol";
import {PoolMaker} from "../src/PoolMaker.sol";
import {IPoolManager} from "../src/interfaces/IUniswapV4.sol";

/// Deploys the two singleton pieces of the agentic oracle/execution layer:
/// PoolTwapObserver (the manipulation-resistant price memory the native TWAP
/// feeds read) and PoolMaker (the stateless settlement contract native
/// rebalance legs call). Both take only the v4 PoolManager. Per-asset feeds
/// (V4TwapFeed/V2TwapFeed) deploy separately via DeployTwapFeed, and the
/// Safe whitelists PoolMaker in MakerRegistry afterward.
///
/// IMPORTANT: rerun `forge test --match-contract TwapOracleFork --fork-url
/// $RH_RPC` right before this — it proves the observer's slot-6 read matches
/// the live PoolManager's storage layout (an immutable assumption).
///
///   POOL_MANAGER=0x8366a39CC670B4001A1121B8F6A443A643e40951 \
///   CONFIRM_DEPLOY=yes forge script script/DeployOracleCore.s.sol \
///     --rpc-url $RH_RPC --broadcast --private-key $DEPLOY_KEY \
///     --verify --verifier blockscout \
///     --verifier-url https://robinhoodchain.blockscout.com/api
contract DeployOracleCore is Script {
    function run() external {
        require(block.chainid == 4663, "wrong chain: expected Robinhood Chain (4663)");

        address poolManager = vm.envAddress("POOL_MANAGER");
        require(poolManager.code.length > 0, "PoolManager has no code");

        console.log("=== Oracle core deploy config ===");
        console.log("PoolManager: %s", poolManager);

        if (keccak256(bytes(vm.envOr("CONFIRM_DEPLOY", string("")))) != keccak256("yes")) {
            console.log("");
            console.log("DRY RUN ONLY. Set CONFIRM_DEPLOY=yes to allow broadcast.");
            console.log("First: rerun TwapOracleFork against the live PoolManager (slot-6 check).");
            return;
        }

        vm.startBroadcast();
        PoolTwapObserver observer = new PoolTwapObserver(IPoolManagerExtsload(poolManager));
        PoolMaker maker = new PoolMaker(IPoolManager(poolManager));
        vm.stopBroadcast();

        require(address(observer.poolManager()) == poolManager, "wiring: observer.poolManager");
        require(observer.RING_SIZE() == 64, "sanity: observer ring size");

        console.log("");
        console.log("PoolTwapObserver: %s", address(observer));
        console.log("PoolMaker:        %s", address(maker));
        console.log("NEXT: DeployTwapFeed per asset, then Safe whitelists PoolMaker in MakerRegistry.");
    }
}
