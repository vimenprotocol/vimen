// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {PoolTwapObserver, IPoolManagerExtsload} from "../src/PoolTwapObserver.sol";
import {V4TwapFeed, V2TwapFeed, IUniswapV2PairOracle} from "../src/TwapFeeds.sol";
import {IAggregatorV3} from "../src/BasketToken2.sol";

/// Validates the whole native-pricing stack against REAL mainnet state
/// (fork; runs only when RH_RPC is set):
/// - the v4 slot-6 extsload assumption, against VIRTUAL's live USDG pool;
/// - V4TwapFeed's Q96 math, by sanity-ranging VIRTUAL/USD;
/// - V2TwapFeed's cumulative math, by pricing HAN (a live Virtuals agent)
///   through its real pair, chained VIRTUAL/USD.
///
///   RH_RPC=https://rpc.mainnet.chain.robinhood.com \
///     forge test --match-contract TwapOracleFork --fork-url $RH_RPC -vv
contract TwapOracleFork is Test {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    bytes32 constant VIRTUAL_USDG_POOL = 0xa95732060867f07aa9b8ae9a4b7b8d737bc3374f1dfbb952759c5ed676e8737c;
    address constant USDG_USD_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address constant HAN_PAIR = 0x5Ae5c378d28637311A66a7AAA52111397822ABDd; // HAN is token0, VIRTUAL-quoted

    PoolTwapObserver observer;
    V4TwapFeed virtualUsd;
    V2TwapFeed hanUsd;

    /// Skips when not running against a fork (foundry auto-loads .env, so an
    /// env check is not enough — probe for the live PoolManager instead).
    modifier onFork() {
        if (POOL_MANAGER.code.length == 0) vm.skip(true);
        _;
    }

    function setUp() public {
        if (POOL_MANAGER.code.length == 0) return;
        observer = new PoolTwapObserver(IPoolManagerExtsload(POOL_MANAGER));
        // VIRTUAL is currency1 of its USDG pool (config/markets.ts tokenIs0=false)
        virtualUsd = new V4TwapFeed(
            observer,
            VIRTUAL_USDG_POOL,
            false,
            IAggregatorV3(USDG_USD_FEED),
            86400,
            1e12, // USDG has 6 decimals
            1 hours,
            5
        );
        hanUsd = new V2TwapFeed(
            IUniswapV2PairOracle(HAN_PAIR),
            true, // HAN is token0
            virtualUsd,
            2 hours, // the adapter chain's own freshness bound
            30 minutes,
            6 hours
        );
    }

    function test_fork_slot0_matchesLivePool() public onFork {
        uint160 sqrtPrice = observer.slot0SqrtPrice(VIRTUAL_USDG_POOL);
        assertGt(sqrtPrice, 0, "slot-6 extsload returned nothing: v4 storage layout assumption broken");
        console.log("VIRTUAL/USDG sqrtPriceX96:", sqrtPrice);
    }

    function test_fork_v4Feed_pricesVirtualInSaneRange() public onFork {
        // build a covered window: 6 observations across the last hour
        // (explicit clock: via_ir hoists TIMESTAMP as loop-invariant)
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < 6; i++) {
            observer.poke(VIRTUAL_USDG_POOL);
            t += 10 minutes;
            vm.warp(t);
        }
        (, int256 answer,, uint256 updatedAt,) = virtualUsd.latestRoundData();
        assertGt(updatedAt, 0, "window should be covered");
        // VIRTUAL traded ~$0.62 on 2026-07-17; accept a wide sanity band
        assertGt(answer, 0.05e8, "VIRTUAL priced absurdly low: Q96 math broken");
        assertLt(answer, 20e8, "VIRTUAL priced absurdly high: Q96 math broken");
        console.log("VIRTUAL/USD (8d):", uint256(answer));
    }

    function test_fork_v4Feed_uncoveredWindow_readsStale() public onFork {
        observer.poke(VIRTUAL_USDG_POOL); // 1 observation < minObs 5
        (, int256 answer,, uint256 updatedAt,) = virtualUsd.latestRoundData();
        assertEq(updatedAt, 0);
        assertEq(answer, 0);
    }

    function test_fork_v2Feed_pricesHanInSaneRange() public onFork {
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < 6; i++) {
            observer.poke(VIRTUAL_USDG_POOL);
            t += 10 minutes;
            vm.warp(t);
        }
        hanUsd.poke();
        t += 31 minutes;
        vm.warp(t);
        // keep the v4 window covered after the warp
        for (uint256 i = 0; i < 5; i++) {
            observer.poke(VIRTUAL_USDG_POOL);
            t += 5 minutes;
            vm.warp(t);
        }
        (, int256 answer,, uint256 updatedAt,) = hanUsd.latestRoundData();
        assertGt(updatedAt, 0, "checkpoint window should be valid");
        // HAN traded ~$0.006-0.01 on 2026-07-17; wide sanity band
        assertGt(answer, 0.0001e8, "HAN priced absurdly low: UQ112 math broken");
        assertLt(answer, 1e8, "HAN priced absurdly high: UQ112 math broken");
        console.log("HAN/USD (8d):", uint256(answer));
    }

    function test_fork_v2Feed_noCheckpoint_readsStale() public onFork {
        (, int256 answer,, uint256 updatedAt,) = hanUsd.latestRoundData();
        assertEq(updatedAt, 0);
        assertEq(answer, 0);
    }
}
