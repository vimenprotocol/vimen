// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev The burn entry point of the VIM token (ERC20 with `burnFrom`).
///      `burnFrom` spends the caller's allowance and destroys the tokens.
interface IVimBurnable {
    function burnFrom(address account, uint256 amount) external;
}

/// @title CuratorRegistry — the curation license, earned by burning VIM
/// @notice Burn `LICENSE_BURN` (a fixed 25,000 VIM) to earn a permanent,
///         non-revocable curator license: the right to publish baskets through
///         the BasketFactory. There is no stake to lock, unlock, or delegate,
///         and no admin: the amount is a hard constant, the same for everyone,
///         forever.
///
///         VIM is external (a Virtuals `AgentTokenV4`); the platform touches it
///         only here. `burnFrom` -> the token's `_burn` skips the token's
///         transfer tax and blacklist and reduces total supply, so the burn is
///         exact and cannot be blocked (verified against the deployed token).
///         The contract holds no funds: the VIM is destroyed directly from the
///         caller, it never passes through here.
contract CuratorRegistry is ReentrancyGuard {
    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    error AlreadyLicensed();

    // ---------------------------------------------------------------- events

    event LicenseBurned(address indexed curator, uint256 amount);

    // ------------------------------------------------------------- constants

    /// @notice VIM burned, once, for a permanent license. Fixed forever.
    uint256 public constant LICENSE_BURN = 25_000e18;

    // --------------------------------------------------------------- storage

    IVimBurnable public immutable vim;
    mapping(address curator => bool) private _licensed;

    // ----------------------------------------------------------- constructor

    constructor(IVimBurnable vim_) {
        if (address(vim_) == address(0)) revert ZeroAddress();
        vim = vim_;
    }

    // ------------------------------------------------------------- license

    /// @notice Burn `LICENSE_BURN` VIM from the caller (who must first approve
    ///         this contract) to earn a permanent curation license. Idempotent
    ///         guard: a licensed curator cannot burn again.
    function burnForLicense() external nonReentrant {
        if (_licensed[msg.sender]) revert AlreadyLicensed();
        _licensed[msg.sender] = true; // effects before the external burn (CEI)
        vim.burnFrom(msg.sender, LICENSE_BURN);
        emit LicenseBurned(msg.sender, LICENSE_BURN);
    }

    /// @notice The curation license: whether `curator` has burned for it.
    function isLicensed(address curator) external view returns (bool) {
        return _licensed[curator];
    }
}
