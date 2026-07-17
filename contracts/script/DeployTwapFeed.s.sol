// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PoolTwapObserver} from "../src/PoolTwapObserver.sol";
import {V4TwapFeed, V2TwapFeed, IUniswapV2PairOracle} from "../src/TwapFeeds.sol";
import {IAggregatorV3} from "../src/BasketToken2.sol";

/// Deploys ONE native-asset TWAP feed (Chainlink-shaped adapter). Run once per
/// asset; the constructors now reject bad params on-chain (BadConfig), so a
/// misconfigured immutable feed can't be created. Recommended params from the
/// V2 handoff: V4 window ~1h / minObs 5-7; V2 minWindow 30min / maxWindow 6h;
/// adapter quoteHeartbeat ~2-3h (pokes are hourly).
///
/// The FIRST V4 feed is VIRTUAL/USDG (quote = the Chainlink USDG/USD feed,
/// quoteScale = 1e12). Its address then becomes QUOTE_FEED for every V2
/// (Virtuals-agent) feed, and quoteScale for those is unused (V2 both-18d).
///
/// V4 (meme / VIRTUAL):
///   FEED_KIND=v4 OBSERVER=0x.. POOL_ID=0x..(32b) TOKEN_IS0=true \
///   QUOTE_FEED=0x.. QUOTE_HEARTBEAT=10800 QUOTE_SCALE=1000000000000 \
///   WINDOW=3600 MIN_OBS=6 CONFIRM_DEPLOY=yes forge script \
///   script/DeployTwapFeed.s.sol --rpc-url $RH_RPC --broadcast \
///   --private-key $DEPLOY_KEY --verify --verifier blockscout \
///   --verifier-url https://robinhoodchain.blockscout.com/api
///
/// V2 (Virtuals agent):
///   FEED_KIND=v2 PAIR=0x.. TOKEN_IS0=true QUOTE_FEED=<VIRTUAL_ADAPTER> \
///   QUOTE_HEARTBEAT=10800 MIN_WINDOW=1800 MAX_WINDOW=21600 \
///   CONFIRM_DEPLOY=yes forge script script/DeployTwapFeed.s.sol ...
contract DeployTwapFeed is Script {
    function run() external {
        require(block.chainid == 4663, "wrong chain: expected Robinhood Chain (4663)");

        string memory kind = vm.envString("FEED_KIND");
        bool isV4 = keccak256(bytes(kind)) == keccak256("v4");
        bool isV2 = keccak256(bytes(kind)) == keccak256("v2");
        require(isV4 || isV2, "FEED_KIND must be v4 or v2");

        address quoteFeed = vm.envAddress("QUOTE_FEED");
        uint32 quoteHeartbeat = uint32(vm.envUint("QUOTE_HEARTBEAT"));
        bool tokenIs0 = vm.envBool("TOKEN_IS0");
        require(quoteFeed.code.length > 0, "quote feed has no code");
        // the quote feed must itself answer (Chainlink) or be a live adapter
        (, int256 q,, uint256 qUpd,) = IAggregatorV3(quoteFeed).latestRoundData();
        require(q > 0 && qUpd != 0, "quote feed not live");

        bool go = keccak256(bytes(vm.envOr("CONFIRM_DEPLOY", string("")))) == keccak256("yes");

        if (isV4) {
            address observer = vm.envAddress("OBSERVER");
            bytes32 poolId = vm.envBytes32("POOL_ID");
            uint256 quoteScale = vm.envUint("QUOTE_SCALE");
            uint32 window = uint32(vm.envUint("WINDOW"));
            uint256 minObs = vm.envUint("MIN_OBS");
            require(observer.code.length > 0, "observer has no code");
            console.log("=== V4TwapFeed deploy ===");
            console.log("observer %s | window %s | minObs %s", observer, window, minObs);
            console.log("quoteFeed %s | quoteScale %s", quoteFeed, quoteScale);
            if (!go) {
                console.log("DRY RUN. Set CONFIRM_DEPLOY=yes to broadcast.");
                return;
            }
            vm.startBroadcast();
            V4TwapFeed feed = new V4TwapFeed(
                PoolTwapObserver(observer), poolId, tokenIs0,
                IAggregatorV3(quoteFeed), quoteHeartbeat, quoteScale, window, minObs
            );
            vm.stopBroadcast();
            console.log("V4TwapFeed: %s", address(feed));
            console.log("Poke it hourly (agent/keeper.ts) BEFORE listing the asset or a basket.");
        } else {
            address pair = vm.envAddress("PAIR");
            uint32 minWindow = uint32(vm.envUint("MIN_WINDOW"));
            uint32 maxWindow = uint32(vm.envUint("MAX_WINDOW"));
            require(pair.code.length > 0, "pair has no code");
            console.log("=== V2TwapFeed deploy ===");
            console.log("pair %s | minWindow %s | maxWindow %s", pair, minWindow, maxWindow);
            console.log("quoteFeed (VIRTUAL adapter) %s", quoteFeed);
            if (!go) {
                console.log("DRY RUN. Set CONFIRM_DEPLOY=yes to broadcast.");
                return;
            }
            vm.startBroadcast();
            V2TwapFeed feed = new V2TwapFeed(
                IUniswapV2PairOracle(pair), tokenIs0, IAggregatorV3(quoteFeed), quoteHeartbeat, minWindow, maxWindow
            );
            vm.stopBroadcast();
            console.log("V2TwapFeed: %s", address(feed));
            console.log("Checkpoint it (agent/keeper.ts) BEFORE listing the asset or a basket.");
        }
    }
}
