// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CuratorRegistry} from "../src/CuratorRegistry.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {BasketFactory} from "../src/BasketFactory.sol";

/// Deploys the curation platform around an EXTERNALLY deployed VIMEN token.
///
///   VIMEN_TOKEN=0x... TREASURY=0x... PROTOCOL_GUARDIAN=0x... \
///   CONFIRM_DEPLOY=yes forge script script/DeployPlatform.s.sol \
///     --rpc-url $RH_RPC --broadcast --private-key $DEPLOY_KEY \
///     --verify --verifier blockscout \
///     --verifier-url https://robinhoodchain.blockscout.com/api
///
/// The token address is immutable in the registry: the token contract must
/// be FINAL (deployed, verified, no pending migrations) before running this.
/// Same human checkpoint as the basket deploy: prints the resolved config
/// and refuses to broadcast unless CONFIRM_DEPLOY=yes.
contract DeployPlatform is Script {
    function run() external {
        require(block.chainid == 4663, "wrong chain: expected Robinhood Chain (4663)");

        address token = vm.envAddress("VIMEN_TOKEN");
        address treasury = vm.envAddress("TREASURY");
        address protocolGuardian = vm.envAddress("PROTOCOL_GUARDIAN");

        require(token.code.length > 0, "VIMEN token has no code on this chain");
        // MIN_SELF_STAKE (25_000e18) and all UI amounts assume 18 decimals.
        require(IERC20Metadata(token).decimals() == 18, "VIMEN token must have 18 decimals");
        require(treasury.code.length > 0, "treasury has no code on this chain (use the Safe)");
        require(protocolGuardian.code.length > 0, "guardian has no code on this chain (use the Safe)");

        console.log("=== Platform deploy config ===");
        console.log(
            "VIMEN token:  %s (%s, %s decimals)",
            token,
            IERC20Metadata(token).symbol(),
            IERC20Metadata(token).decimals()
        );
        console.log("total supply: %s", IERC20Metadata(token).totalSupply());
        console.log("treasury:     %s", treasury);
        console.log("guardian:     %s", protocolGuardian);

        if (keccak256(bytes(vm.envOr("CONFIRM_DEPLOY", string("")))) != keccak256("yes")) {
            console.log("");
            console.log("DRY RUN ONLY. Set CONFIRM_DEPLOY=yes to allow broadcast.");
            return;
        }

        vm.startBroadcast();
        CuratorRegistry registry = new CuratorRegistry(IERC20(token));
        FeeSplitter splitter = new FeeSplitter(registry, treasury);
        BasketFactory factory = new BasketFactory(registry, splitter, protocolGuardian);
        registry.initSplitter(address(splitter));
        splitter.initFactory(address(factory));
        vm.stopBroadcast();

        // wiring sanity: everything frozen and pointing at each other
        require(registry.splitter() == address(splitter), "wiring: registry.splitter");
        require(splitter.factory() == address(factory), "wiring: splitter.factory");
        require(address(factory.registry()) == address(registry), "wiring: factory.registry");

        console.log("");
        console.log("CuratorRegistry: %s", address(registry));
        console.log("FeeSplitter:     %s", address(splitter));
        console.log("BasketFactory:   %s", address(factory));
        console.log("license threshold: %s VIMEN (raw)", registry.MIN_SELF_STAKE());
    }
}
