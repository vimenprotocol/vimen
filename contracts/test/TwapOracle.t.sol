// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolTwapObserver, IPoolManagerExtsload} from "../src/PoolTwapObserver.sol";
import {V2TwapFeed, IUniswapV2PairOracle} from "../src/TwapFeeds.sol";
import {PoolMaker, IUniswapV2PairSwap} from "../src/PoolMaker.sol";
import {IPoolManager} from "../src/interfaces/IUniswapV4.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeed} from "./mocks/AgenticMocks.sol";
import {IAggregatorV3} from "../src/BasketToken2.sol";

/// @dev PoolManager storage stand-in: the test sets the sqrtPrice the
///      observer will read for a pool.
contract MockManagerStorage is IPoolManagerExtsload {
    mapping(bytes32 => uint160) public priceOf; // keyed by pool STATE SLOT

    bytes32 constant POOLS_SLOT = bytes32(uint256(6));

    function set(bytes32 poolId, uint160 sqrtPriceX96) external {
        priceOf[keccak256(abi.encodePacked(poolId, POOLS_SLOT))] = sqrtPriceX96;
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return bytes32(uint256(priceOf[slot]));
    }
}

/// @dev Constant-product v2 pair stand-in with real cumulative bookkeeping.
contract MockPair is IUniswapV2PairOracle {
    MockERC20 public token0;
    MockERC20 public token1;
    uint112 r0;
    uint112 r1;
    uint32 tsLast;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    constructor(MockERC20 t0, MockERC20 t1, uint112 r0_, uint112 r1_) {
        token0 = t0;
        token1 = t1;
        r0 = r0_;
        r1 = r1_;
        tsLast = uint32(block.timestamp);
        t0.mint(address(this), r0_);
        t1.mint(address(this), r1_);
    }

    function _accrue() private {
        uint32 elapsed = uint32(block.timestamp) - tsLast;
        if (elapsed > 0 && r0 > 0 && r1 > 0) {
            unchecked {
                price0CumulativeLast += ((uint256(r1) << 112) / r0) * elapsed;
                price1CumulativeLast += ((uint256(r0) << 112) / r1) * elapsed;
            }
            tsLast = uint32(block.timestamp);
        }
    }

    /// test hook: move the price by setting new reserves (a "trade")
    function setReserves(uint112 r0_, uint112 r1_) external {
        _accrue();
        r0 = r0_;
        r1 = r1_;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (r0, r1, tsLast);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        _accrue();
        // pull-payment already arrived (v2 style); pay out and roll reserves
        if (amount0Out > 0) token0.transfer(to, amount0Out);
        if (amount1Out > 0) token1.transfer(to, amount1Out);
        r0 = uint112(token0.balanceOf(address(this)));
        r1 = uint112(token1.balanceOf(address(this)));
    }
}

contract TwapOracleTest is Test {
    MockManagerStorage manager;
    PoolTwapObserver observer;
    bytes32 constant POOL = keccak256("pool");

    // sqrtPriceX96 for a 1:1e12-ish USDG(c1,6d)/TOKEN(c0,18d) pool at $1:
    // ratio c1/c0 = 1e6/1e18 = 1e-12 -> sqrt = 1e-6 -> * 2^96
    uint160 constant FAIR = uint160((uint256(1) << 96) / 1e6);

    function setUp() public {
        manager = new MockManagerStorage();
        observer = new PoolTwapObserver(IPoolManagerExtsload(address(manager)));
        manager.set(POOL, FAIR);
    }

    function _poke(uint256 times, uint160 price, uint256 stepSec) internal returns (uint256 t) {
        t = block.timestamp;
        for (uint256 i = 0; i < times; i++) {
            manager.set(POOL, price);
            observer.poke(POOL);
            t += stepSec;
            vm.warp(t);
        }
        manager.set(POOL, FAIR);
    }

    function test_median_resistsMinorityPoisoning() public {
        _poke(5, FAIR, 5 minutes); // 5 honest observations
        _poke(2, FAIR * 10, 5 minutes); // attacker skews 2 of them 10x

        (uint160 median,, uint256 count) = observer.medianSqrtPrice(POOL, 1 hours, 5);
        assertEq(count, 7);
        assertEq(median, FAIR, "minority poisoning must not move the median");
    }

    function test_median_majorityPoisoning_wouldCost() public {
        // the attack that WOULD work needs a majority of the window: 4 honest,
        // 5 poisoned across >= 5 distinct seconds of sustained skew
        _poke(4, FAIR, 5 minutes);
        _poke(5, FAIR * 10, 5 minutes);
        (uint160 median,,) = observer.medianSqrtPrice(POOL, 1 hours, 5);
        assertEq(median, FAIR * 10, "documents the cost: sustained majority skew");
    }

    function test_onePokePerSecond() public {
        observer.poke(POOL);
        vm.expectRevert(PoolTwapObserver.AlreadyObservedThisSecond.selector);
        observer.poke(POOL);
    }

    function test_uncoveredWindow_returnsZero() public {
        _poke(3, FAIR, 1 minutes);
        (uint160 median,, uint256 count) = observer.medianSqrtPrice(POOL, 1 hours, 5);
        assertEq(count, 3);
        assertEq(median, 0, "below minObs must read as no-price");
    }

    // ------------------------------------------------------------ V2 feed

    function test_v2Feed_twapLagsSpotJump() public {
        MockERC20 agent = new MockERC20("Agent", "AGT");
        MockERC20 virt = new MockERC20("Virtual", "VIRT");
        // 1 agent = 0.01 VIRTUAL: r0 1M agents, r1 10k VIRTUAL
        MockPair pair = new MockPair(agent, virt, 1_000_000e18, 10_000e18);
        MockFeed vUsd = new MockFeed(1e8); // VIRTUAL at $1 for round numbers
        V2TwapFeed feed =
            new V2TwapFeed(IUniswapV2PairOracle(address(pair)), true, IAggregatorV3(address(vUsd)), 86400, 30 minutes, 6 hours);

        feed.poke();
        vm.warp(block.timestamp + 40 minutes);
        vUsd.set(1e8, block.timestamp);
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertGt(updatedAt, 0);
        assertApproxEqRel(uint256(answer), 0.01e8, 0.01e18, "flat market: TWAP == spot");

        // price pumps 5x for five minutes right before the read: the TWAP
        // barely moves — the manipulation window is the whole 45 minutes
        pair.setReserves(1_000_000e18, 50_000e18);
        vm.warp(block.timestamp + 5 minutes);
        vUsd.set(1e8, block.timestamp);
        (, int256 pumped,,,) = feed.latestRoundData();
        assertLt(uint256(pumped), 0.016e8, "5-minute pump must be diluted by the window");
    }

    function test_v2Feed_pokeSpamGuard() public {
        MockERC20 agent = new MockERC20("Agent", "AGT");
        MockERC20 virt = new MockERC20("Virtual", "VIRT");
        MockPair pair = new MockPair(agent, virt, 1_000_000e18, 10_000e18);
        MockFeed vUsd = new MockFeed(1e8);
        V2TwapFeed feed =
            new V2TwapFeed(IUniswapV2PairOracle(address(pair)), true, IAggregatorV3(address(vUsd)), 86400, 30 minutes, 6 hours);
        feed.poke();
        vm.expectRevert(V2TwapFeed.CheckpointTooSoon.selector);
        feed.poke(); // spam can't evict aged checkpoints
    }

    // ----------------------------------------------------------- PoolMaker

    function test_poolMaker_v2Swap_roundTrips() public {
        MockERC20 agent = new MockERC20("Agent", "AGT");
        MockERC20 virt = new MockERC20("Virtual", "VIRT");
        MockPair pair = new MockPair(agent, virt, 1_000_000e18, 10_000e18);
        PoolMaker maker = new PoolMaker(IPoolManager(address(0xdead)));

        // we are "the basket": sell 1000 agents for VIRTUAL
        agent.mint(address(this), 1_000e18);
        agent.approve(address(maker), 1_000e18);
        uint256 expectedOut = 9.9e18; // ~0.01 each minus fee-ish margin
        maker.swapV2(address(pair), IERC20(address(agent)), 1_000e18, IERC20(address(virt)), false, expectedOut);

        assertEq(virt.balanceOf(address(this)), expectedOut, "all output forwarded to the caller");
        assertEq(virt.balanceOf(address(maker)), 0, "maker keeps nothing");
        assertEq(agent.balanceOf(address(maker)), 0, "maker keeps nothing");
    }

    /// A misconfigured immutable feed is caught at construction, not after
    /// deploy: empty window (max<=min), spot-collapse (minWindow 0), zeros.
    function test_v2feed_constructor_rejectsBadConfig() public {
        // the constructor only null-checks these + validates the windows, so
        // non-zero placeholders exercise every BadConfig branch
        IUniswapV2PairOracle p = IUniswapV2PairOracle(address(0xBEEF));
        IAggregatorV3 q = IAggregatorV3(address(0xCAFE));
        vm.expectRevert(V2TwapFeed.BadConfig.selector);
        new V2TwapFeed(p, true, q, 86400, 0, 6 hours); // minWindow 0
        vm.expectRevert(V2TwapFeed.BadConfig.selector);
        new V2TwapFeed(p, true, q, 86400, 1 hours, 1 hours); // max <= min
        vm.expectRevert(V2TwapFeed.BadConfig.selector);
        new V2TwapFeed(IUniswapV2PairOracle(address(0)), true, q, 86400, 30 minutes, 6 hours);
        vm.expectRevert(V2TwapFeed.BadConfig.selector);
        new V2TwapFeed(p, true, q, 0, 30 minutes, 6 hours); // zero heartbeat
    }
}
