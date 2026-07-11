// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @dev ERC-20 impostor: `transferFrom` returns true but moves nothing.
///      BasketToken's balance-delta check must reject deposits of it.
contract MaliciousToken {
    string public name = "Malicious";
    string public symbol = "EVIL";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true; // lies: moves nothing
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true; // lies: moves nothing
    }
}
