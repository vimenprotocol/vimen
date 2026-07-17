// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CuratorRegistry2, ILegacyRegistry} from "../src/CuratorRegistry2.sol";
import {IVimBurnable} from "../src/CuratorRegistry.sol";
import {CuratorRegistry} from "../src/CuratorRegistry.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {BasketFactory} from "../src/BasketFactory.sol";
import {CuratorGuardian} from "../src/CuratorGuardian.sol";

/// Deploys the repriced curation platform (V1 license 25k -> 10k VIM) around
/// the LIVE original platform. Three contracts, one of them new source:
///   - CuratorRegistry2 (new): 10k V1 tier + 25k V2 tier, legacy 25k burns
///     grandfathered into V2;
///   - FeeSplitter (same source, second instance): the original's `factory`
///     is frozen forever, so the new factory needs its own splitter;
///   - BasketFactory (same source, second instance): points at the new
///     registry and splitter, REUSES the live CuratorGuardian (it has no
///     factory coupling — one cap roadmap for every curated basket).
/// The original registry/factory stay live: legacy licensees keep publishing
/// through them, and the frontend merges both factories' baskets.
///
///   VIM_TOKEN=0x43E7Cb9984aD95aA808ac21998cc8D5f909e47aF \
///   LEGACY_REGISTRY=0x7184caa070238618AD7076C4A8a76C02BA5a2E59 \
///   LEGACY_SPLITTER=0xA8fF1c9138ea889537f79A6866e5EA0af4e9685f \
///   CURATOR_GUARDIAN=0xC93b74B490D1bdd71045766c90F1F743D0C356be \
///   CONFIRM_DEPLOY=yes forge script script/DeployPlatform2.s.sol \
///     --rpc-url $RH_RPC --broadcast --private-key $DEPLOY_KEY \
///     --verify --verifier blockscout \
///     --verifier-url https://robinhoodchain.blockscout.com/api
contract DeployPlatform2 is Script {
    function run() external {
        require(block.chainid == 4663, "wrong chain: expected Robinhood Chain (4663)");

        address token = vm.envAddress("VIM_TOKEN");
        address legacyRegistry = vm.envAddress("LEGACY_REGISTRY");
        address legacySplitter = vm.envAddress("LEGACY_SPLITTER");
        address guardianAddr = vm.envAddress("CURATOR_GUARDIAN");

        require(token.code.length > 0, "VIM token has no code on this chain");
        require(IERC20Metadata(token).decimals() == 18, "VIM token must have 18 decimals");
        require(legacyRegistry.code.length > 0, "legacy registry has no code");
        // The legacy registry must be the one wired to this VIM token: the new
        // tiers burn the same asset the grandfathered licenses burned.
        require(address(CuratorRegistry(legacyRegistry).vim()) == token, "legacy registry burns a different token");
        // Treasury comes from the live splitter, not an env var: the 40% side
        // of the split can't silently move in the redeploy.
        address treasury = FeeSplitter(legacySplitter).treasury();
        require(treasury.code.length > 0, "treasury has no code on this chain (use the Safe)");
        require(guardianAddr.code.length > 0, "CuratorGuardian has no code on this chain");
        address protocolSafe = CuratorGuardian(guardianAddr).admin();

        console.log("=== Platform2 deploy config ===");
        console.log("VIM token:       %s (%s)", token, IERC20Metadata(token).symbol());
        console.log("legacy registry: %s (grandfathered into V2)", legacyRegistry);
        console.log("treasury:        %s (read from live splitter)", treasury);
        console.log("guardian:        %s (REUSED; admin %s)", guardianAddr, protocolSafe);

        if (keccak256(bytes(vm.envOr("CONFIRM_DEPLOY", string("")))) != keccak256("yes")) {
            console.log("");
            console.log("DRY RUN ONLY. Set CONFIRM_DEPLOY=yes to allow broadcast.");
            return;
        }

        vm.startBroadcast();
        CuratorRegistry2 registry = new CuratorRegistry2(IVimBurnable(token), ILegacyRegistry(legacyRegistry));
        FeeSplitter splitter = new FeeSplitter(treasury);
        // Same-source factory: CuratorRegistry2 answers the same isLicensed
        // selector with the same semantics, so the cast is exact at the ABI.
        BasketFactory factory = new BasketFactory(CuratorRegistry(address(registry)), splitter, guardianAddr);
        splitter.initFactory(address(factory));
        vm.stopBroadcast();

        // wiring sanity: everything frozen and pointing at each other
        require(splitter.factory() == address(factory), "wiring: splitter.factory");
        require(address(factory.registry()) == address(registry), "wiring: factory.registry");
        require(address(factory.splitter()) == address(splitter), "wiring: factory.splitter");
        require(factory.basketGuardian() == guardianAddr, "wiring: factory.basketGuardian");
        require(splitter.treasury() == treasury, "wiring: splitter.treasury");
        require(address(registry.legacy()) == legacyRegistry, "wiring: registry.legacy");

        console.log("");
        console.log("CuratorRegistry2: %s", address(registry));
        console.log("FeeSplitter2:     %s", address(splitter));
        console.log("BasketFactory2:   %s", address(factory));
        console.log("V1 burn: %s | V2 burn: %s (raw, fixed)", registry.LICENSE_BURN_V1(), registry.LICENSE_BURN_V2());
    }
}
