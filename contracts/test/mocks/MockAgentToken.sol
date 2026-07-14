// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title MockAgentToken — the burn-relevant semantics of the real VIM token
/// @notice The deployed VIM is a Virtuals `AgentTokenV4`: a 1% transfer tax and
///         an owner blacklist. This mock reproduces exactly the behaviors the
///         platform relies on, verified against the real bytecode:
///         - transfers are taxed 1% and blocked for blacklisted addresses;
///         - `burnFrom` -> burn is NOT taxed and is EXEMPT from the blacklist
///           (the real token skips the blacklist check when `to == address(0)`),
///           and reduces `totalSupply` by exactly the amount.
///         Used to prove `CuratorRegistry.burnForLicense` works against the
///         real token, not just a clean OZ ERC20.
contract MockAgentToken {
    string public constant name = "Vimen by Virtuals";
    string public constant symbol = "VIM";
    uint8 public constant decimals = 18;

    uint16 public constant TAX_BPS = 100; // 1%, on transfers only
    address public constant TAX_RECIPIENT = address(0x7A);

    uint256 public totalSupply;
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;
    mapping(address account => bool) public blacklists;

    error Blacklisted();
    error InsufficientBalance();
    error InsufficientAllowance();

    constructor(address holder, uint256 supply) {
        totalSupply = supply;
        balanceOf[holder] = supply;
    }

    /// Owner surface (any caller here, for tests): blacklist an address.
    function setBlacklist(address account, bool value) external {
        blacklists[account] = value;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _taxedTransfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        return _taxedTransfer(from, to, amount);
    }

    /// @dev Transfers are taxed 1% and blocked for blacklisted parties.
    function _taxedTransfer(address from, address to, uint256 amount) internal returns (bool) {
        if (blacklists[from] || blacklists[to]) revert Blacklisted();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        uint256 tax = (amount * TAX_BPS) / 10_000;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - tax;
        balanceOf[TAX_RECIPIENT] += tax;
        return true;
    }

    /// @dev Burn: no tax, no blacklist check (burns are exempt), supply shrinks.
    function burnFrom(address account, uint256 amount) external {
        _spendAllowance(account, msg.sender, amount);
        if (balanceOf[account] < amount) revert InsufficientBalance();
        balanceOf[account] -= amount;
        totalSupply -= amount;
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 current = allowance[owner][spender];
        if (current < amount) revert InsufficientAllowance();
        if (current != type(uint256).max) allowance[owner][spender] = current - amount;
    }
}
