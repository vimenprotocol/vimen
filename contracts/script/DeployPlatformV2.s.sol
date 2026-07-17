// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CuratorRegistry2} from "../src/CuratorRegistry2.sol";
import {CuratorGuardian} from "../src/CuratorGuardian.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {MakerRegistry} from "../src/MakerRegistry.sol";
import {BasketFactory2} from "../src/BasketFactory2.sol";
import {BasketTokenDeployer} from "../src/BasketTokenDeployer.sol";
import {IAggregatorV3} from "../src/BasketToken2.sol";

/// Deploys the AGENTIC (V2) shelf around the live repriced platform:
/// AssetRegistry + MakerRegistry (Safe-administered gates), a third
/// FeeSplitter instance (each factory freezes its own), and BasketFactory2
/// gated on CuratorRegistry2.isLicensedV2. REUSES the live CuratorRegistry2
/// and CuratorGuardian. Populating the registries (assets + Rialto maker)
/// is a separate Safe step after this deploy.
///
///   CURATOR_REGISTRY2=0x6d513D431Ea76CfeBB85AaD637664dda32560Cd6 \
///   CURATOR_GUARDIAN=0xC93b74B490D1bdd71045766c90F1F743D0C356be \
///   USDG=0x... USDG_FEED=0x... USDG_HEARTBEAT=86400 \
///   CONFIRM_DEPLOY=yes forge script script/DeployPlatformV2.s.sol \
///     --rpc-url $RH_RPC --broadcast --private-key $DEPLOY_KEY \
///     --verify --verifier blockscout \
///     --verifier-url https://robinhoodchain.blockscout.com/api
contract DeployPlatformV2 is Script {
    function run() external {
        require(block.chainid == 4663, "wrong chain: expected Robinhood Chain (4663)");

        address registry2 = vm.envAddress("CURATOR_REGISTRY2");
        address guardianAddr = vm.envAddress("CURATOR_GUARDIAN");
        address usdg = vm.envAddress("USDG");
        address usdgFeed = vm.envAddress("USDG_FEED");
        uint32 usdgHeartbeat = uint32(vm.envUint("USDG_HEARTBEAT"));

        require(registry2.code.length > 0, "registry2 has no code");
        require(guardianAddr.code.length > 0, "guardian has no code");
        require(usdg.code.length > 0, "USDG has no code");
        require(IERC20Metadata(usdg).decimals() == 6, "USDG must have 6 decimals");
        require(usdgFeed.code.length > 0, "USDG feed has no code");
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(usdgFeed).latestRoundData();
        require(answer > 0 && block.timestamp < updatedAt + usdgHeartbeat + 1 hours, "USDG feed dead/stale");

        address protocolSafe = CuratorGuardian(guardianAddr).admin();
        // the treasury side of the split, read from the live splitter wired
        // to the repriced factory (deploy artifact of DeployPlatform2)
        address treasury = FeeSplitter(vm.envAddress("LIVE_SPLITTER")).treasury();

        console.log("=== PlatformV2 (agentic shelf) deploy config ===");
        console.log("registry2 (REUSED): %s", registry2);
        console.log("guardian  (REUSED): %s (Safe %s)", guardianAddr, protocolSafe);
        console.log("USDG: %s | feed %s (heartbeat %s)", usdg, usdgFeed, usdgHeartbeat);
        console.log("treasury: %s", treasury);

        if (keccak256(bytes(vm.envOr("CONFIRM_DEPLOY", string("")))) != keccak256("yes")) {
            console.log("");
            console.log("DRY RUN ONLY. Set CONFIRM_DEPLOY=yes to allow broadcast.");
            return;
        }

        vm.startBroadcast();
        AssetRegistry assets = new AssetRegistry(protocolSafe);
        MakerRegistry makers = new MakerRegistry(protocolSafe);
        FeeSplitter splitter = new FeeSplitter(treasury);
        // the token's creation code lives in its own deployer contract:
        // embedded in the factory it pushed the runtime past EIP-170's 24,576
        BasketTokenDeployer tokenDeployer = new BasketTokenDeployer();
        BasketFactory2 factory = new BasketFactory2(
            CuratorRegistry2(registry2),
            splitter,
            CuratorGuardian(guardianAddr),
            assets,
            makers,
            IERC20(usdg),
            IAggregatorV3(usdgFeed),
            usdgHeartbeat,
            tokenDeployer
        );
        splitter.initFactory(address(factory));
        vm.stopBroadcast();

        require(splitter.factory() == address(factory), "wiring: splitter.factory");
        require(address(factory.registry()) == registry2, "wiring: factory.registry");
        require(address(factory.assetRegistry()) == address(assets), "wiring: factory.assets");
        require(address(factory.makerRegistry()) == address(makers), "wiring: factory.makers");
        require(assets.admin() == protocolSafe && makers.admin() == protocolSafe, "wiring: admins");
        require(address(factory.tokenDeployer()) == address(tokenDeployer), "wiring: factory.tokenDeployer");

        console.log("");
        console.log("AssetRegistry:   %s", address(assets));
        console.log("MakerRegistry:   %s", address(makers));
        console.log("FeeSplitterV2:   %s", address(splitter));
        console.log("TokenDeployer:   %s", address(tokenDeployer));
        console.log("BasketFactory2:  %s", address(factory));
        console.log("NEXT (Safe txs): assets.addAsset per feed-priced name; makers.addMaker(rialto router)");
    }
}
