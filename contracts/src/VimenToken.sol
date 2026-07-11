// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title VIMEN — the curation license of the Vimen protocol
/// @notice Fixed supply of 100,000,000, minted once to the distribution
///         address (a Safe) and never again: no mint function, no owner,
///         no hooks. Distribution (airdrop, locked liquidity, on-chain
///         founder vesting, treasury) happens from there via dedicated,
///         verifiable vehicles — see docs/TOKENOMICS.md.
contract VimenToken is ERC20, ERC20Permit {
    uint256 public constant TOTAL_SUPPLY = 100_000_000e18;

    error ZeroAddress();

    constructor(address distributor) ERC20("Vimen", "VIMEN") ERC20Permit("Vimen") {
        if (distributor == address(0)) revert ZeroAddress();
        _mint(distributor, TOTAL_SUPPLY);
    }
}
