// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVimBurnable} from "./CuratorRegistry.sol";

/// @dev The read side of the original 25k registry, for grandfathering.
interface ILegacyRegistry {
    function isLicensed(address curator) external view returns (bool);
}

/// @title CuratorRegistry2 — two license tiers, earned by burning VIM
/// @notice The repriced curation license (owner decision 2026-07-17):
///         - V1 (immutable baskets): burn a fixed 10,000 VIM — lowered from
///           25,000 so more curators build.
///         - V2 (agentic baskets):   burn a fixed 25,000 VIM.
///         Both burns are one-shot, permanent and non-revocable; both amounts
///         are hard constants with no admin to change them. A V2 license
///         includes V1 (25k ≥ 10k: whoever can publish a living recipe can
///         publish a frozen one).
///
///         Grandfathering: every curator who burned 25,000 VIM in the original
///         registry already paid today's V2 price, so `isLicensedV2` honors
///         the legacy registry — early believers get the V2 tier for free and
///         the original registry stays deployed and true forever.
///
///         VIM handling is identical to the original registry: `burnFrom`
///         destroys the tokens straight from the caller (skipping the token's
///         transfer tax and blacklist — verified against the deployed token);
///         this contract never holds funds.
contract CuratorRegistry2 is ReentrancyGuard {
    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    error AlreadyLicensed();

    // ---------------------------------------------------------------- events

    /// @dev Same signature the original registry emits, so indexers and the
    ///      frontend parse both registries with one ABI. `amount`
    ///      distinguishes the tier (10k = V1, 25k = V2).
    event LicenseBurned(address indexed curator, uint256 amount);

    // ------------------------------------------------------------- constants

    /// @notice VIM burned, once, for a permanent V1 (immutable-basket) license.
    uint256 public constant LICENSE_BURN_V1 = 10_000e18;
    /// @notice VIM burned, once, for a permanent V2 (agentic-basket) license.
    uint256 public constant LICENSE_BURN_V2 = 25_000e18;

    // --------------------------------------------------------------- storage

    IVimBurnable public immutable vim;
    ILegacyRegistry public immutable legacy;
    mapping(address curator => bool) private _v1;
    mapping(address curator => bool) private _v2;

    // ----------------------------------------------------------- constructor

    constructor(IVimBurnable vim_, ILegacyRegistry legacy_) {
        if (address(vim_) == address(0) || address(legacy_) == address(0)) revert ZeroAddress();
        vim = vim_;
        legacy = legacy_;
    }

    // --------------------------------------------------------------- license

    /// @notice Burn `LICENSE_BURN_V1` VIM from the caller (who must first
    ///         approve this contract) for a permanent V1 curation license.
    ///         Reverts for anyone already V1-licensed through any path — a
    ///         V2 or legacy licensee has nothing to gain from this burn.
    function burnForLicense() external nonReentrant {
        if (isLicensed(msg.sender)) revert AlreadyLicensed();
        _v1[msg.sender] = true; // effects before the external burn (CEI)
        vim.burnFrom(msg.sender, LICENSE_BURN_V1);
        emit LicenseBurned(msg.sender, LICENSE_BURN_V1);
    }

    /// @notice Burn `LICENSE_BURN_V2` VIM from the caller for a permanent V2
    ///         curation license. The full 25k regardless of a prior V1 burn:
    ///         tiers are flat constants, not a top-up schedule.
    function burnForLicenseV2() external nonReentrant {
        if (isLicensedV2(msg.sender)) revert AlreadyLicensed();
        _v2[msg.sender] = true; // effects before the external burn (CEI)
        vim.burnFrom(msg.sender, LICENSE_BURN_V2);
        emit LicenseBurned(msg.sender, LICENSE_BURN_V2);
    }

    // ------------------------------------------------------------------ view

    /// @notice The V1 license: a direct V1 burn, a V2 burn (superset), or a
    ///         legacy 25k burn. Same selector the BasketFactory checks.
    function isLicensed(address curator) public view returns (bool) {
        return _v1[curator] || _v2[curator] || legacy.isLicensed(curator);
    }

    /// @notice The V2 license: a direct V2 burn, or a legacy 25k burn
    ///         (grandfathered — they paid today's V2 price).
    function isLicensedV2(address curator) public view returns (bool) {
        return _v2[curator] || legacy.isLicensed(curator);
    }
}
