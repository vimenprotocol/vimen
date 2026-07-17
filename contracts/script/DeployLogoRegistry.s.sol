// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BasketFactory} from "../src/BasketFactory.sol";
import {LogoRegistry} from "../src/LogoRegistry.sol";

/// Deploys the LogoRegistry against the LIVE BasketFactory.
///
///   BASKET_FACTORY=0x... \
///   CONFIRM_DEPLOY=yes forge script script/DeployLogoRegistry.s.sol \
///     --rpc-url $RH_RPC --broadcast --private-key $DEPLOY_KEY \
///     --verify --verifier blockscout \
///     --verifier-url https://robinhoodchain.blockscout.com/api
///
/// Pure metadata sidecar: no admin, no funds, no wiring back into the
/// platform — nothing else has to know it exists. Same human checkpoint as
/// every deploy: prints the resolved config and refuses to broadcast unless
/// CONFIRM_DEPLOY=yes.
contract DeployLogoRegistry is Script {
    function run() external {
        require(block.chainid == 4663, "wrong chain: expected Robinhood Chain (4663)");

        address factory = vm.envAddress("BASKET_FACTORY");
        require(factory.code.length > 0, "factory has no code on this chain");
        // sanity: it quacks like the live factory
        require(BasketFactory(factory).CEILING() == 1_000_000e18, "unexpected factory CEILING");

        console.log("=== LogoRegistry deploy config ===");
        console.log("factory:      %s", factory);
        console.log("baskets live: %s", BasketFactory(factory).basketCount());

        if (keccak256(bytes(vm.envOr("CONFIRM_DEPLOY", string("")))) != keccak256("yes")) {
            console.log("");
            console.log("DRY RUN ONLY. Set CONFIRM_DEPLOY=yes to allow broadcast.");
            return;
        }

        vm.startBroadcast();
        LogoRegistry logos = new LogoRegistry(BasketFactory(factory));
        vm.stopBroadcast();

        console.log("");
        console.log("LogoRegistry: %s", address(logos));
        console.log("frontend env: NEXT_PUBLIC_LOGO_REGISTRY_ADDRESS=%s", address(logos));
    }
}
