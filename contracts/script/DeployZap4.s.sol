// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VimenZap4, IWETH9} from "../src/VimenZap4.sol";
import {IPoolManager} from "../src/interfaces/IUniswapV4.sol";

/// Deploys VimenZap4 (v4 + v2 pairs + v3 pools + Rialto, per-leg venues).
///
///   CONFIRM_DEPLOY=yes forge script script/DeployZap4.s.sol \
///     --rpc-url $RH_RPC --broadcast --private-key $DEPLOY_KEY \
///     --verify --verifier blockscout \
///     --verifier-url https://robinhoodchain.blockscout.com/api
///
/// Stateless like every zap before it: no owner, no admin, holds nothing
/// between transactions. Supersedes VimenZap3 in the frontend config; the
/// old router keeps working for anyone still pointed at it.
contract DeployZap4 is Script {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    function run() external {
        require(block.chainid == 4663, "wrong chain: expected Robinhood Chain (4663)");
        require(POOL_MANAGER.code.length > 0, "PoolManager has no code");
        require(WETH.code.length > 0, "WETH has no code");

        console.log("=== VimenZap4 deploy config ===");
        console.log("PoolManager: %s", POOL_MANAGER);
        console.log("WETH:        %s", WETH);

        if (keccak256(bytes(vm.envOr("CONFIRM_DEPLOY", string("")))) != keccak256("yes")) {
            console.log("");
            console.log("DRY RUN ONLY. Set CONFIRM_DEPLOY=yes to allow broadcast.");
            return;
        }

        vm.startBroadcast();
        VimenZap4 zap = new VimenZap4(IPoolManager(POOL_MANAGER), IWETH9(WETH));
        vm.stopBroadcast();

        console.log("");
        console.log("VimenZap4: %s", address(zap));
        console.log("frontend env: NEXT_PUBLIC_ZAP_ADDRESS=%s", address(zap));
    }
}
