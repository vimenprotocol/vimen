// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    IPoolManager,
    IUnlockCallback,
    PoolKey,
    SwapParams,
    BalanceDeltaLib,
    V4TickMath
} from "./interfaces/IUniswapV4.sol";

interface IUniswapV2PairSwap {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @title PoolMaker — the canonical-pool "maker" for agentic rebalances
/// @notice BasketToken2 fills legs through registered makers with the RFQ
///         boundary (approve exact -> call -> delta-check -> reset). Chain
///         natives have no RFQ desk — their venue IS their pool. This
///         contract is the adapter that lets the SAME boundary reach those
///         pools: a stateless, custody-free executor (exactly like the zap)
///         that pulls the approved input, swaps in the canonical venue the
///         calldata names, and returns every output to the caller in the
///         same transaction. It holds nothing, knows nobody, and has no
///         admin; registering it in the MakerRegistry is safe because a
///         dishonest route through it still answers to the basket's own
///         delta checks and TWAP-priced NAV invariant.
///
///         Venues: Uniswap v2 pairs (Virtuals agents — input is sent
///         STRAIGHT to the pair so the 1% agent-token tax is paid once, the
///         planner's grossOut accounts for it) and Uniswap v4 pools
///         (launchpad memes), multi-hop inside one unlock so ETH-quoted
///         memes reach USDG through the main pair without touching native
///         ETH outside the manager.
contract PoolMaker is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using BalanceDeltaLib for int256;

    error OnlyPoolManager();
    error EmptyPath();
    error BrokenPath(uint256 hop);
    error PartialFill(uint256 hop);
    error NativeEndpointsUnsupported();

    struct Hop {
        PoolKey key;
        bool zeroForOne;
    }

    IPoolManager public immutable poolManager;

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    // ------------------------------------------------------------------- v2

    /// @notice Exact-input swap on a v2 pair. The input travels caller->pair
    ///         directly (one transfer, one tax for taxed agent tokens);
    ///         `grossOut` is the pair-side output the planner computed from
    ///         reserves (the caller's own delta check enforces its minimum
    ///         after any output-side tax).
    function swapV2(address pair, IERC20 tokenIn, uint256 amountIn, IERC20 tokenOut, bool outIs0, uint256 grossOut)
        external
        nonReentrant
    {
        tokenIn.safeTransferFrom(msg.sender, pair, amountIn);
        (uint256 a0, uint256 a1) = outIs0 ? (grossOut, uint256(0)) : (uint256(0), grossOut);
        IUniswapV2PairSwap(pair).swap(a0, a1, address(this), "");
        tokenOut.safeTransfer(msg.sender, tokenOut.balanceOf(address(this)));
    }

    // ------------------------------------------------------------------- v4

    /// @notice Exact-input swap along a v4 path. Endpoints must be ERC20s
    ///         (USDG and the meme); native ETH may only appear as an
    ///         INTERMEDIATE hop, where it nets to zero inside the unlock.
    function swapV4(Hop[] calldata hops, uint256 amountIn) external nonReentrant {
        if (hops.length == 0) revert EmptyPath();
        (address tokenIn, address tokenOut) = _endpoints(hops);
        if (tokenIn == address(0) || tokenOut == address(0)) revert NativeEndpointsUnsupported();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        poolManager.unlock(abi.encode(msg.sender, hops, tokenIn, amountIn, tokenOut));
    }

    // -------------------------------------------------------- bridged (v2+v4)
    // A Virtuals-agent leg has no direct USDG venue: it trades VIRTUAL on its
    // v2 pair, and VIRTUAL trades USDG on v4. The basket's leg boundary wants
    // one maker call from constituent to USDG (or back) — these compose the
    // two venues inside a single call, still stateless and custody-free.

    /// @notice SELL an agent token for the v4 path's output: caller's tokenIn
    ///         goes straight to the pair (one tax hop), the pair pays the
    ///         bridge here, and the bridge is sold exact-input along `hops`
    ///         (e.g. VIRTUAL -> USDG), output to the caller.
    function swapV2ThenV4(
        address pair,
        IERC20 tokenIn,
        uint256 amountIn,
        IERC20 bridge,
        bool bridgeIs0,
        uint256 grossBridgeOut,
        Hop[] calldata hops
    ) external nonReentrant {
        if (hops.length == 0) revert EmptyPath();
        (address hopIn, address tokenOut) = _endpoints(hops);
        if (hopIn != address(bridge)) revert BrokenPath(0);
        if (tokenOut == address(0)) revert NativeEndpointsUnsupported();

        tokenIn.safeTransferFrom(msg.sender, pair, amountIn);
        (uint256 a0, uint256 a1) = bridgeIs0 ? (grossBridgeOut, uint256(0)) : (uint256(0), grossBridgeOut);
        IUniswapV2PairSwap(pair).swap(a0, a1, address(this), "");
        // sell whatever the pair actually delivered (output-side tax safe)
        uint256 bridgeGot = bridge.balanceOf(address(this));
        poolManager.unlock(abi.encode(msg.sender, hops, address(bridge), bridgeGot, tokenOut));
    }

    /// @notice BUY an agent token: caller's v4-path input (e.g. USDG) is sold
    ///         exact-input along `hops` into the bridge, the bridge goes to
    ///         the pair, and the pair pays `grossOut` of the agent token
    ///         straight to the caller.
    function swapV4ThenV2(
        Hop[] calldata hops,
        uint256 amountIn,
        address pair,
        bool agentIs0,
        uint256 grossOut
    ) external nonReentrant {
        if (hops.length == 0) revert EmptyPath();
        (address tokenIn, address bridge) = _endpoints(hops);
        if (tokenIn == address(0) || bridge == address(0)) revert NativeEndpointsUnsupported();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        poolManager.unlock(abi.encode(address(this), hops, tokenIn, amountIn, bridge));
        uint256 bridgeGot = IERC20(bridge).balanceOf(address(this));
        IERC20(bridge).safeTransfer(pair, bridgeGot);
        (uint256 a0, uint256 a1) = agentIs0 ? (grossOut, uint256(0)) : (uint256(0), grossOut);
        IUniswapV2PairSwap(pair).swap(a0, a1, msg.sender, "");
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (address recipient, Hop[] memory hops, address tokenIn, uint256 amountIn, address tokenOut) =
            abi.decode(rawData, (address, Hop[], address, uint256, address));

        uint256 carry = amountIn;
        for (uint256 j = 0; j < hops.length; j++) {
            Hop memory hop = hops[j];
            int256 delta = poolManager.swap(
                hop.key,
                SwapParams({
                    zeroForOne: hop.zeroForOne,
                    amountSpecified: -int256(carry), // negative = exact input
                    sqrtPriceLimitX96: hop.zeroForOne
                        ? V4TickMath.MIN_SQRT_PRICE_PLUS_ONE
                        : V4TickMath.MAX_SQRT_PRICE_MINUS_ONE
                }),
                ""
            );
            int128 dIn = hop.zeroForOne ? delta.amount0() : delta.amount1();
            int128 dOut = hop.zeroForOne ? delta.amount1() : delta.amount0();
            // a partial fill would strand input as an unresolvable delta
            if (uint256(uint128(-dIn)) != carry) revert PartialFill(j);
            carry = uint256(uint128(dOut));
        }

        // settle the input side, take the output straight to the caller
        poolManager.sync(tokenIn);
        IERC20(tokenIn).safeTransfer(address(poolManager), amountIn);
        poolManager.settle();
        poolManager.take(tokenOut, recipient, carry);
        return "";
    }

    /// @dev Walk the path: each hop consumes the previous hop's output.
    function _endpoints(Hop[] calldata hops) private pure returns (address tokenIn, address tokenOut) {
        tokenIn = hops[0].zeroForOne ? hops[0].key.currency0 : hops[0].key.currency1;
        address current = hops[0].zeroForOne ? hops[0].key.currency1 : hops[0].key.currency0;
        for (uint256 j = 1; j < hops.length; j++) {
            address from = hops[j].zeroForOne ? hops[j].key.currency0 : hops[j].key.currency1;
            if (from != current) revert BrokenPath(j);
            current = hops[j].zeroForOne ? hops[j].key.currency1 : hops[j].key.currency0;
        }
        tokenOut = current;
    }
}
