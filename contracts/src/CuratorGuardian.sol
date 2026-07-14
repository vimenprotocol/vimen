// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @dev The single guardian lever curated baskets keep: advancing the supply
///      cap along the public roadmap. `supplyCap` is read to enforce a
///      monotonic (upward-only) change.
interface IBasketCap {
    function setSupplyCap(uint256 newCap) external;
    function supplyCap() external view returns (uint256);
}

/// @title CuratorGuardian — the restricted guardian of every curated basket
/// @notice Baskets published through the BasketFactory are wired with this
///         contract as their `guardian` instead of the protocol Safe directly.
///         It exposes ONLY the supply-cap roadmap lever, and only upward:
///         - it can RAISE a basket's cap (never lower it), bounded by the
///           basket's own immutable `maxSupplyCap`;
///         - it has NO path to `setFeeRecipient` or `setMintPaused`.
///
///         Because it is the basket's sole guardian and simply lacks those two
///         functions, the fee recipient (the FeeSplitter) is frozen forever
///         and minting can never be paused on a curated basket. That is what
///         makes the curator's bargain real: burn 25,000 VIM for a
///         non-revocable license and 60% of every mint fee forever, with no
///         party — not even the protocol — able to redirect or choke that fee
///         stream after the basket is published. Redeem is already
///         unstoppable at the BasketToken level.
///
///         No owner, no upgrade, no admin transfer: `admin` is immutable and
///         `raiseCap` is the only state-changing function.
contract CuratorGuardian {
    error NotAdmin();
    error ZeroAddress();
    error CapNotIncreasing();

    event CapRaised(address indexed basket, uint256 newCap);

    /// @notice The protocol Safe — the only caller allowed to advance caps.
    address public immutable admin;

    constructor(address admin_) {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
    }

    /// @notice Advance a curated basket's supply cap along the roadmap.
    ///         Monotonic: `newCap` must be strictly greater than the current
    ///         cap, which closes the cap-lowering choke (setting a cap below
    ///         live supply would freeze new mints exactly like a pause). The
    ///         basket's `maxSupplyCap` still bounds the top (reverts there).
    function raiseCap(IBasketCap basket, uint256 newCap) external {
        if (msg.sender != admin) revert NotAdmin();
        if (newCap <= basket.supplyCap()) revert CapNotIncreasing();
        basket.setSupplyCap(newCap);
        emit CapRaised(address(basket), newCap);
    }
}
