// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BasketFactory2} from "../src/BasketFactory2.sol";
import {BasketToken2} from "../src/BasketToken2.sol";
import {CuratorRegistry2} from "../src/CuratorRegistry2.sol";

/// Publishes ONE agentic pilot basket (VCT / VVIRT / VMAG) through the live
/// BasketFactory2 in a single transaction (token + USDG distributor). The
/// deployer must hold the V2 license (burned or grandfathered). Tokens and
/// units come from `npx tsx scripts/agent/targets.ts` (units = $100-NAV target
/// at fresh prices); pass them as comma-separated env arrays.
///
/// Every asset in TOKENS must already be in AssetRegistry, and its feed/adapter
/// must be live (poked) — otherwise the first rebalance reverts. This script
/// only deploys; the first rebalance + first payout cycle are run via
/// scripts/agent/runner.ts before any public announcement.
///
///   FACTORY2=0x.. NAME="Crypto Twitter" SYMBOL=VCT AGENT=0x.. \
///   TOKENS=0xA,0xB,0xC UNITS=1000000000000000000,2000...,3000... \
///   MINT_FEE_BPS=30 INITIAL_CAP=1000000000000000000000 \
///   COOLDOWN=86400 MAX_TURNOVER_BPS=2500 MAX_SLIPPAGE_BPS=100 \
///   MIN_SHARE=1000000000000000000 PAYOUT_INTERVAL=604800 \
///   CONFIRM_DEPLOY=yes forge script script/DeployPilotBasket.s.sol \
///     --rpc-url $RH_RPC --broadcast --private-key $DEPLOY_KEY
contract DeployPilotBasket is Script {
    function run() external {
        require(block.chainid == 4663, "wrong chain: expected Robinhood Chain (4663)");

        BasketFactory2 factory = BasketFactory2(vm.envAddress("FACTORY2"));
        require(address(factory).code.length > 0, "factory has no code");

        string memory name = vm.envString("NAME");
        string memory symbol = vm.envString("SYMBOL");
        address agent = vm.envAddress("AGENT");
        address[] memory tokens = vm.envAddress("TOKENS", ",");
        uint256[] memory units = vm.envUint("UNITS", ",");
        require(tokens.length == units.length, "TOKENS/UNITS length mismatch");
        uint16 mintFeeBps = uint16(vm.envUint("MINT_FEE_BPS"));
        uint256 initialCap = vm.envUint("INITIAL_CAP");
        uint256 payoutInterval = vm.envUint("PAYOUT_INTERVAL");

        BasketToken2.Policy memory policy = BasketToken2.Policy({
            rebalanceCooldown: uint32(vm.envUint("COOLDOWN")),
            maxTurnoverBps: uint16(vm.envUint("MAX_TURNOVER_BPS")),
            maxSlippageBps: uint16(vm.envUint("MAX_SLIPPAGE_BPS")),
            minShareBalance: vm.envUint("MIN_SHARE")
        });

        // sanity vs the factory/token ceilings, surfaced before broadcast
        address deployer = vm.envOr("DEPLOYER", tx.origin);
        bool licensed = CuratorRegistry2(factory.registry()).isLicensedV2(deployer);

        console.log("=== Agentic pilot basket ===");
        console.log("factory %s | symbol %s | agent %s", address(factory), symbol, agent);
        console.log("constituents %s | mintFeeBps %s | payoutInterval %s", tokens.length, mintFeeBps, payoutInterval);
        console.log("policy: cooldown %s turnoverBps %s", policy.rebalanceCooldown, policy.maxTurnoverBps);
        console.log("deployer %s | V2-licensed: %s", deployer, licensed);
        require(licensed, "deployer is not V2-licensed (burn or grandfather first)");

        if (keccak256(bytes(vm.envOr("CONFIRM_DEPLOY", string("")))) != keccak256("yes")) {
            console.log("");
            console.log("DRY RUN ONLY. Set CONFIRM_DEPLOY=yes to allow broadcast.");
            console.log("Confirm every TOKEN is registered + its feed poked, or the first rebalance reverts.");
            return;
        }

        vm.startBroadcast();
        (address basket, address distributor) =
            factory.createBasket(name, symbol, tokens, units, mintFeeBps, initialCap, agent, policy, payoutInterval);
        vm.stopBroadcast();

        require(factory.curatorOf(basket) == deployer, "wiring: curatorOf");
        require(factory.distributorOf(basket) == distributor, "wiring: distributorOf");

        console.log("");
        console.log("BasketToken2:     %s", basket);
        console.log("BasketDistributor: %s", distributor);
        console.log("NEXT: runner.ts dry-run the first rebalance, then --send; then first payout cycle.");
    }
}
