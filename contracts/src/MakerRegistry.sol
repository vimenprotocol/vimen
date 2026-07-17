// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title MakerRegistry — who may fill an RFQ leg
/// @notice The gate on WHICH settlement contracts a rebalance (and, later,
///         zapMint5) may approve and call. Without it, calldata could point
///         a leg's exact-input approval at an arbitrary contract; with it,
///         the approve-exact -> call -> delta-check -> approval-reset
///         boundary (the audited Rialto pattern) only ever targets makers
///         the Safe has publicly added.
///
///         Same immutable-admin shape as CuratorGuardian/AssetRegistry: the
///         Safe can ADD a maker and DISABLE it (instant, e.g. on a
///         misbehaving endpoint); it cannot touch funds, quotes, or live
///         fills — a disabled maker only makes its own future legs revert.
///         Adding a maker is a Safe transaction and a public announcement by
///         construction (the event is the announcement).
contract MakerRegistry {
    // ---------------------------------------------------------------- errors

    error NotAdmin();
    error ZeroAddress();
    error NotAContract(address maker);
    error AlreadyRegistered(address maker);
    error NotRegistered(address maker);

    // ---------------------------------------------------------------- events

    event MakerAdded(address indexed maker, string label);
    event MakerEnabledSet(address indexed maker, bool enabled);

    // --------------------------------------------------------------- storage

    struct Maker {
        bool enabled;
        bool exists;
    }

    /// @notice The protocol Safe: adds and toggles makers. Nothing else.
    address public immutable admin;

    mapping(address maker => Maker) private _makers;
    address[] private _list;

    // ----------------------------------------------------------- constructor

    constructor(address admin_) {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // ----------------------------------------------------------------- admin

    /// @notice Register a settlement contract. `label` names the operator in
    ///         the public log (e.g. "rialto-router-v2"); it is not stored.
    function addMaker(address maker, string calldata label) external onlyAdmin {
        if (maker == address(0)) revert ZeroAddress();
        if (maker.code.length == 0) revert NotAContract(maker);
        if (_makers[maker].exists) revert AlreadyRegistered(maker);
        _makers[maker] = Maker({enabled: true, exists: true});
        _list.push(maker);
        emit MakerAdded(maker, label);
    }

    /// @notice Instantly enable/disable a maker for future fills.
    function setEnabled(address maker, bool enabled) external onlyAdmin {
        if (!_makers[maker].exists) revert NotRegistered(maker);
        _makers[maker].enabled = enabled;
        emit MakerEnabledSet(maker, enabled);
    }

    // ------------------------------------------------------------------ view

    /// @notice True when `maker` may be approved and called for a fill.
    function isMaker(address maker) external view returns (bool) {
        return _makers[maker].enabled;
    }

    function makerCount() external view returns (uint256) {
        return _list.length;
    }

    function makerAt(uint256 i) external view returns (address) {
        return _list[i];
    }
}
