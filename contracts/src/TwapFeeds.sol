// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolTwapObserver} from "./PoolTwapObserver.sol";
import {IAggregatorV3} from "./BasketToken2.sol";

/// @dev The two v2-pair cumulative counters plus their bookkeeping.
interface IUniswapV2PairOracle {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

/// @title TwapFeeds — Chainlink-shaped TWAP adapters for pool-priced assets
/// @notice The insight that lets agentic baskets hold chain natives WITHOUT
///         touching BasketToken2: the AssetRegistry stores "a feed", and the
///         basket only ever calls `latestRoundData()` on it with a staleness
///         check. These adapters ARE that feed — immutable per asset,
///         answering in USD with 8 decimals like every Chainlink proxy:
///
///         - V4TwapFeed: median sqrtPrice from the PoolTwapObserver's window
///           (launchpad memes on hookless v4 pools; also VIRTUAL itself),
///           dollarized through the quote side's Chainlink feed;
///         - V2TwapFeed: the pair's own cumulative-price counters (Virtuals
///           agents), TWAP'd against a permissionless checkpoint at least
///           `minWindow` old, then dollarized through a VIRTUAL/USD adapter.
///
///         When the window is not honestly covered (too few observations,
///         checkpoint too old or too young) the adapter answers
///         updatedAt = 0: the basket's staleness check then BLOCKS the
///         rebalance — the failure mode is "agent waits", never "agent
///         trades on a fake price". Mint and redeem never touch prices.
contract V4TwapFeed is IAggregatorV3 {
    error StaleQuoteFeed();
    error BadConfig();

    PoolTwapObserver public immutable observer;
    bytes32 public immutable poolId;
    /// true when the PRICED asset is the pool's currency0
    bool public immutable tokenIs0;
    /// Chainlink USD feed of the pool's OTHER side (USDG/USD or ETH/USD)
    IAggregatorV3 public immutable quoteFeed;
    uint32 public immutable quoteHeartbeat;
    /// 10^(18 - quoteDecimals): 1e12 for USDG(6), 1 for ETH(18)
    uint256 public immutable quoteScale;
    uint32 public immutable window;
    uint256 public immutable minObs;

    constructor(
        PoolTwapObserver observer_,
        bytes32 poolId_,
        bool tokenIs0_,
        IAggregatorV3 quoteFeed_,
        uint32 quoteHeartbeat_,
        uint256 quoteScale_,
        uint32 window_,
        uint256 minObs_
    ) {
        // parameters are immutable; a bad one bricks the feed for good, so
        // validate the ranges that would make it permanently stale or turn
        // the median off (minObs above the observer's ring can never fill).
        if (
            address(observer_) == address(0) || address(quoteFeed_) == address(0) || window_ == 0
                || quoteScale_ == 0 || quoteHeartbeat_ == 0 || minObs_ == 0
                || minObs_ > observer_.RING_SIZE()
        ) revert BadConfig();
        observer = observer_;
        poolId = poolId_;
        tokenIs0 = tokenIs0_;
        quoteFeed = quoteFeed_;
        quoteHeartbeat = quoteHeartbeat_;
        quoteScale = quoteScale_;
        window = window_;
        minObs = minObs_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        (uint160 sqrtPriceX96, uint32 newest,) = observer.medianSqrtPrice(poolId, window, minObs);
        if (sqrtPriceX96 == 0) return (0, 0, 0, 0, 0); // uncovered window: stale by construction

        (, int256 quote8,, uint256 quoteUpdated,) = quoteFeed.latestRoundData();
        if (quote8 <= 0 || block.timestamp > quoteUpdated + quoteHeartbeat + 1 hours) revert StaleQuoteFeed();

        // quoteWei per tokenWei: priceQ96/2^96 when the token is currency0,
        // its inverse when the token is currency1. Folding the decimals:
        //   answer8 = (quoteWei/tokenWei) * 10^(18 - quoteDecimals) * quote8
        // (quote8 already carries the 1e8 of the answer's decimals).
        uint256 priceQ96 = Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        uint256 answer8 = tokenIs0
            ? Math.mulDiv(priceQ96, quoteScale * uint256(quote8), uint256(1) << 96)
            : Math.mulDiv(uint256(1) << 96, quoteScale * uint256(quote8), priceQ96);
        if (answer8 == 0) return (0, 0, 0, 0, 0);
        return (1, int256(answer8), newest, newest, 1);
    }
}

/// @notice Virtuals-agent pricing off the pair's own cumulative counters:
///         anyone checkpoints the pair; the answer is the time-weighted
///         average between a checkpoint aged [minWindow, maxWindow] and now,
///         chained through the VIRTUAL/USD adapter. Both 18-decimals sides.
contract V2TwapFeed is IAggregatorV3 {
    error CheckpointTooSoon();
    error StaleQuoteFeed();
    error BadConfig();

    struct Checkpoint {
        uint32 timestamp;
        uint256 priceCumulative;
    }

    uint256 public constant RING_SIZE = 16;

    IUniswapV2PairOracle public immutable pair;
    /// true when the PRICED (agent) token is the pair's token0
    bool public immutable tokenIs0;
    /// VIRTUAL/USD (8 decimals) — a V4TwapFeed over VIRTUAL's USDG pool
    IAggregatorV3 public immutable quoteFeed;
    uint32 public immutable quoteHeartbeat;
    uint32 public immutable minWindow;
    uint32 public immutable maxWindow;

    Checkpoint[RING_SIZE] private _ring;
    uint256 private _next;

    constructor(
        IUniswapV2PairOracle pair_,
        bool tokenIs0_,
        IAggregatorV3 quoteFeed_,
        uint32 quoteHeartbeat_,
        uint32 minWindow_,
        uint32 maxWindow_
    ) {
        // immutable params: reject the ranges that would make the TWAP either
        // permanently stale (empty window) or a no-op (minWindow 0 disables
        // the rate-limit and collapses the average to spot).
        if (
            address(pair_) == address(0) || address(quoteFeed_) == address(0) || quoteHeartbeat_ == 0
                || minWindow_ == 0 || maxWindow_ <= minWindow_
        ) revert BadConfig();
        pair = pair_;
        tokenIs0 = tokenIs0_;
        quoteFeed = quoteFeed_;
        quoteHeartbeat = quoteHeartbeat_;
        minWindow = minWindow_;
        maxWindow = maxWindow_;
    }

    /// @notice Store the pair's current cumulative price. Permissionless; at
    ///         most one checkpoint per `minWindow / 4` so a spammer can't
    ///         evict the aged checkpoints the TWAP needs.
    function poke() external {
        uint256 last = (_next + RING_SIZE - 1) % RING_SIZE;
        uint32 lastTs = _ring[last].timestamp;
        if (lastTs != 0 && block.timestamp < lastTs + minWindow / 4) revert CheckpointTooSoon();
        (uint256 cumulative,) = _currentCumulative();
        _ring[_next] = Checkpoint({timestamp: uint32(block.timestamp), priceCumulative: cumulative});
        _next = (_next + 1) % RING_SIZE;
    }

    /// @dev The pair's cumulative as of NOW: the stored counter plus the
    ///      current reserve ratio extended over the seconds since the pair's
    ///      last trade (standard v2 oracle bookkeeping; wraps by design).
    function _currentCumulative() private view returns (uint256 cumulative, bool ok) {
        (uint112 r0, uint112 r1, uint32 tsLast) = pair.getReserves();
        if (r0 == 0 || r1 == 0) return (0, false);
        // price0Cumulative accumulates token1-per-token0: for an agent that
        // is token0 that IS "VIRTUAL per agent"; mirrored for token1 agents.
        cumulative = tokenIs0 ? pair.price0CumulativeLast() : pair.price1CumulativeLast();
        uint32 elapsed;
        unchecked {
            elapsed = uint32(block.timestamp) - tsLast;
        }
        if (elapsed > 0) {
            // UQ112x112 ratio of counter-side per priced-side
            uint256 ratioQ112 =
                tokenIs0 ? (uint256(r1) << 112) / uint256(r0) : (uint256(r0) << 112) / uint256(r1);
            unchecked {
                cumulative += ratioQ112 * elapsed;
            }
        }
        return (cumulative, true);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        (uint256 nowCumulative, bool ok) = _currentCumulative();
        if (!ok) return (0, 0, 0, 0, 0);

        // the YOUNGEST checkpoint that is at least minWindow old
        uint32 bestTs;
        uint256 bestCum;
        for (uint256 i = 0; i < RING_SIZE; i++) {
            Checkpoint memory c = _ring[i];
            if (c.timestamp == 0) continue;
            uint256 age = block.timestamp - c.timestamp;
            if (age < minWindow || age > maxWindow) continue;
            if (c.timestamp > bestTs) {
                bestTs = c.timestamp;
                bestCum = c.priceCumulative;
            }
        }
        if (bestTs == 0) return (0, 0, 0, 0, 0); // no honest window: stale by construction

        uint256 elapsed = block.timestamp - bestTs;
        uint256 twapQ112;
        unchecked {
            twapQ112 = (nowCumulative - bestCum) / elapsed; // wrap-safe by design
        }

        (, int256 quote8,, uint256 quoteUpdated,) = quoteFeed.latestRoundData();
        if (quote8 <= 0 || block.timestamp > quoteUpdated + quoteHeartbeat + 1 hours) revert StaleQuoteFeed();

        // both sides 18d: USD8 = twap(VIRTUAL per token) * VIRTUAL_USD8
        uint256 answer8 = Math.mulDiv(twapQ112, uint256(quote8), uint256(1) << 112);
        if (answer8 == 0) return (0, 0, 0, 0, 0);
        return (1, int256(answer8), block.timestamp, block.timestamp, 1);
    }
}
