// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @dev The read shape BasketToken2 relies on (Chainlink proxy or a TWAP
///      adapter of the same shape). Only what addAsset needs to sanity-check.
interface IFeedProbe {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title AssetRegistry — the universe an agentic basket may touch
/// @notice The allowlist every BasketToken2 rebalance is checked against: an
///         asset is tradable by agents only if it is registered here with a
///         live Chainlink feed. Listing is additive and disable-only:
///         - the admin (the protocol Safe) can ADD an asset and can DISABLE
///           it for NEW buys;
///         - nothing can ever be removed, and disabling an asset never
///           touches funds — baskets already holding it keep holding it,
///           redeem stays in-kind, and the agent can still SELL it (selling
///           out of a delisted asset is risk-reducing, blocking it would
///           trap holders).
///         The feed and heartbeat are frozen at registration: repointing a
///         feed is a rug vector, so a bad feed means disabling the asset and
///         registering nothing in its place.
///
///         Launch policy (owner decision 2026-07-17): feed-priced assets
///         only. Pool-priced natives stay out until TWAP protections ship —
///         a manipulable price would let an agent game the NAV invariant.
contract AssetRegistry {
    // ---------------------------------------------------------------- errors

    error NotAdmin();
    error ZeroAddress();
    error NotAContract(address token);
    error AlreadyRegistered(address token);
    error NotRegistered(address token);
    error ZeroHeartbeat();
    error Not18Decimals(address token);
    error FeedNotLive(address feed);

    // ---------------------------------------------------------------- events

    event AssetAdded(address indexed token, address indexed feed, uint32 heartbeatSeconds);
    event AssetEnabledSet(address indexed token, bool enabled);

    // --------------------------------------------------------------- storage

    struct Asset {
        address feed; // Chainlink proxy, frozen at registration
        uint32 heartbeatSeconds; // staleness bound for that feed, frozen
        bool enabled; // false = no NEW buys; selling and redeeming unaffected
        bool exists;
    }

    /// @notice The protocol Safe: adds assets and toggles `enabled`. No path
    ///         to funds, feeds, or live baskets.
    address public immutable admin;

    mapping(address token => Asset) private _assets;
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

    /// @notice Register `token` with its Chainlink `feed`. Registration is
    ///         permanent; the feed and heartbeat can never change afterwards.
    function addAsset(address token, address feed, uint32 heartbeatSeconds) external onlyAdmin {
        if (token == address(0) || feed == address(0)) revert ZeroAddress();
        if (token.code.length == 0) revert NotAContract(token);
        if (feed.code.length == 0) revert NotAContract(feed);
        if (heartbeatSeconds == 0) revert ZeroHeartbeat();
        if (_assets[token].exists) revert AlreadyRegistered(token);
        // BasketToken2's NAV math prices every registered asset as an
        // 18-decimal token; every Robinhood stock token is. Enforced here so
        // a 6/8-decimal listing can never silently corrupt an invariant.
        if (IERC20Metadata(token).decimals() != 18) revert Not18Decimals(token);
        // The feed is frozen forever once registered, so prove it answers live
        // and fresh right now: a dead, wrong-shaped, or already-stale feed
        // caught here can never poison a basket's NAV. (Reverting reads bubble
        // up and also fail the listing.)
        (, int256 answer,, uint256 updatedAt,) = IFeedProbe(feed).latestRoundData();
        if (answer <= 0 || updatedAt == 0 || block.timestamp > updatedAt + heartbeatSeconds) {
            revert FeedNotLive(feed);
        }

        _assets[token] = Asset({feed: feed, heartbeatSeconds: heartbeatSeconds, enabled: true, exists: true});
        _list.push(token);
        emit AssetAdded(token, feed, heartbeatSeconds);
    }

    /// @notice Enable or disable NEW buys of `token`. Never blocks selling,
    ///         holding, or redeeming.
    function setEnabled(address token, bool enabled) external onlyAdmin {
        if (!_assets[token].exists) revert NotRegistered(token);
        _assets[token].enabled = enabled;
        emit AssetEnabledSet(token, enabled);
    }

    // ------------------------------------------------------------------ view

    /// @notice True when `token` may be BOUGHT by an agent right now.
    function isBuyable(address token) external view returns (bool) {
        return _assets[token].enabled; // exists=false implies enabled=false
    }

    /// @notice True when `token` was ever registered (sellable/holdable by
    ///         agents; feed data is valid for NAV pricing).
    function isRegistered(address token) external view returns (bool) {
        return _assets[token].exists;
    }

    /// @notice The frozen feed wiring for `token`. Reverts when unregistered.
    function assetOf(address token) external view returns (address feed, uint32 heartbeatSeconds, bool enabled) {
        Asset storage a = _assets[token];
        if (!a.exists) revert NotRegistered(token);
        return (a.feed, a.heartbeatSeconds, a.enabled);
    }

    function assetCount() external view returns (uint256) {
        return _list.length;
    }

    function assetAt(uint256 i) external view returns (address) {
        return _list[i];
    }
}
