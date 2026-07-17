// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IPoolManagerExtsload {
    function extsload(bytes32 slot) external view returns (bytes32);
}

/// @title PoolTwapObserver — permissionless price memory for hookless v4 pools
/// @notice Uniswap v4 removed the oracle from core: a hookless pool has no
///         TWAP. This contract is that memory, rebuilt trust-minimized: anyone
///         may `poke` a pool, which reads the pool's CURRENT sqrtPrice
///         straight from the PoolManager's storage (extsload — the observer
///         can only ever record what the pool truly showed) into a ring
///         buffer, at most one observation per second per pool. Readers take
///         the MEDIAN of the observations inside a time window.
///
///         Why median, not mean: a manipulator can poison an observation by
///         skewing the pool and poking in the same transaction — but to move
///         the MEDIAN they must hold the skew across a majority of the
///         window's observations, in distinct blocks, eating arbitrage all
///         the while. With basket caps bounding the prize (maxSlippage x
///         turnover x TVL per epoch), sustained multi-block manipulation
///         costs more than it can ever extract. Deepen `window`/`minObs`
///         as caps rise.
contract PoolTwapObserver {
    // ---------------------------------------------------------------- errors

    error PoolNotInitialized(bytes32 poolId);
    error AlreadyObservedThisSecond();

    // ---------------------------------------------------------------- events

    event Observed(bytes32 indexed poolId, uint160 sqrtPriceX96, uint32 timestamp);

    // ------------------------------------------------------------- constants

    /// v4-core: `mapping(PoolId => Pool.State) internal _pools` lives at slot
    /// 6; a pool's slot0 (sqrtPriceX96 | tick | fees) is the struct's first
    /// slot. Verified against the deployed PoolManager in the fork test.
    bytes32 private constant POOLS_SLOT = bytes32(uint256(6));

    uint256 public constant RING_SIZE = 64;

    // --------------------------------------------------------------- storage

    struct Observation {
        uint32 timestamp;
        uint160 sqrtPriceX96;
    }

    IPoolManagerExtsload public immutable poolManager;

    mapping(bytes32 poolId => Observation[RING_SIZE]) private _ring;
    mapping(bytes32 poolId => uint256) private _next; // next write index

    constructor(IPoolManagerExtsload poolManager_) {
        poolManager = poolManager_;
    }

    // ------------------------------------------------------------------ poke

    /// @notice Record `poolId`'s current sqrtPrice. Permissionless; at most
    ///         one observation per second per pool.
    function poke(bytes32 poolId) external {
        uint160 sqrtPriceX96 = slot0SqrtPrice(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized(poolId);

        uint256 next = _next[poolId];
        uint256 last = (next + RING_SIZE - 1) % RING_SIZE;
        if (_ring[poolId][last].timestamp == uint32(block.timestamp)) revert AlreadyObservedThisSecond();

        _ring[poolId][next] = Observation({timestamp: uint32(block.timestamp), sqrtPriceX96: sqrtPriceX96});
        _next[poolId] = (next + 1) % RING_SIZE;
        emit Observed(poolId, sqrtPriceX96, uint32(block.timestamp));
    }

    // ------------------------------------------------------------------ read

    /// @notice The pool's live sqrtPrice, read from the PoolManager storage.
    function slot0SqrtPrice(bytes32 poolId) public view returns (uint160) {
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, POOLS_SLOT));
        return uint160(uint256(poolManager.extsload(stateSlot)));
    }

    /// @notice Median observed sqrtPrice over the last `window` seconds.
    /// @return sqrtPriceX96 the median (0 when the window holds < `minObs`
    ///         observations — callers treat that as "no price")
    /// @return newest timestamp of the freshest qualifying observation
    /// @return count qualifying observations
    function medianSqrtPrice(bytes32 poolId, uint32 window, uint256 minObs)
        external
        view
        returns (uint160 sqrtPriceX96, uint32 newest, uint256 count)
    {
        uint256 cutoff = block.timestamp > window ? block.timestamp - window : 0;
        uint160[] memory prices = new uint160[](RING_SIZE);
        for (uint256 i = 0; i < RING_SIZE; i++) {
            Observation memory o = _ring[poolId][i];
            if (o.timestamp == 0 || o.timestamp <= cutoff) continue;
            prices[count++] = o.sqrtPriceX96;
            if (o.timestamp > newest) newest = o.timestamp;
        }
        if (count < minObs || count == 0) return (0, newest, count);

        // insertion sort over the qualifying prefix (<= 64 elements, view-only)
        for (uint256 i = 1; i < count; i++) {
            uint160 key = prices[i];
            uint256 j = i;
            while (j > 0 && prices[j - 1] > key) {
                prices[j] = prices[j - 1];
                j--;
            }
            prices[j] = key;
        }
        sqrtPriceX96 = prices[count / 2];
    }
}
