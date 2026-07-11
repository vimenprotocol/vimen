// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Minimal Uniswap v4 core interface, vendored
/// @notice Only the five entry points VimenZap touches, with `Currency` and
///         `IHooks` flattened to `address` (ABI-identical: both are value
///         types over address in v4-core). Vendoring keeps the repo free of
///         a full v4-core dependency and everything compiles on 0.8.24.
///
///         Sign conventions (v4-core):
///         - `SwapParams.amountSpecified`: NEGATIVE = exact input,
///           POSITIVE = exact output.
///         - The returned delta is from the caller's point of view:
///           positive = the caller is owed that currency (credit),
///           negative = the caller owes it (debt).
///         - The delta packs two int128: amount0 in the upper 128 bits,
///           amount1 in the lower 128 bits.

struct PoolKey {
    address currency0; // lower address sorts first; address(0) = native ETH
    address currency1;
    uint24 fee; // hundredths of a bip (3000 = 0.30%)
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);

    /// @notice Must be called before transferring ERC-20s in for `settle`.
    function sync(address currency) external;

    /// @notice Resolves the caller's debt for the synced currency (or native
    ///         via msg.value). Returns the amount paid.
    function settle() external payable returns (uint256);

    /// @notice Sends `amount` of `currency` to `to`, consuming a credit.
    function take(address currency, address to, uint256 amount) external;
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

library V4TickMath {
    /// @dev TickMath.MIN_SQRT_PRICE + 1 and MAX_SQRT_PRICE - 1: the swap
    ///      price limits that mean "no limit" for either direction.
    uint160 internal constant MIN_SQRT_PRICE_PLUS_ONE = 4295128740;
    uint160 internal constant MAX_SQRT_PRICE_MINUS_ONE = 1461446703485210103287273052203988822378723970341;
}

library BalanceDeltaLib {
    function amount0(int256 delta) internal pure returns (int128) {
        return int128(delta >> 128);
    }

    function amount1(int256 delta) internal pure returns (int128) {
        return int128(delta); // truncates to the low 128 bits, keeps sign
    }
}
