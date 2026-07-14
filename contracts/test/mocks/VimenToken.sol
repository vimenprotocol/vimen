// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title VimenToken — TEST/REFERENCE MOCK ONLY, never deployed
/// @notice NOT the production VIM. The live VIM is an EXTERNAL Virtuals
///         `AgentTokenV4` (1B supply, 1% tax, blacklist) at 0x43E7…47aF — see
///         SECURITY.md and the docs. This clean `ERC20Burnable`+`ERC20Permit`
///         is only a burnable stand-in for the platform unit tests; the
///         100,000,000 supply here is arbitrary and does not reflect the real
///         token. Do not deploy or reason about the system through it.
contract VimenToken is ERC20, ERC20Burnable, ERC20Permit {
    uint256 public constant TOTAL_SUPPLY = 100_000_000e18;

    error ZeroAddress();

    constructor(address distributor) ERC20("Vimen", "VIM") ERC20Permit("Vimen") {
        if (distributor == address(0)) revert ZeroAddress();
        _mint(distributor, TOTAL_SUPPLY);
    }
}
