// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BasketFactory} from "./BasketFactory.sol";

/// @title LogoRegistry — a basket's logo, set by its curator
/// @notice A pure-metadata sidecar for curated baskets: the curator of a
///         factory-published basket can point its logo at an image URI
///         (`ipfs://` or `https://`). Nothing else. The registry has no
///         admin, holds no funds, and has zero power over the basket — the
///         recipe stays immutable, redeem stays ungated. Interfaces MAY
///         render the URI (after their own sanitization) and MAY ignore it.
contract LogoRegistry {
    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    error NotCurator();
    error UriTooLong();

    // ---------------------------------------------------------------- events

    event LogoSet(address indexed basket, address indexed curator, string uri);

    // ------------------------------------------------------------- constants

    /// @notice Byte bound on a stored URI: IPFS CIDs and ordinary image URLs
    ///         fit comfortably; anything longer is garbage or abuse.
    uint256 public constant MAX_URI_LENGTH = 200;

    // --------------------------------------------------------------- storage

    BasketFactory public immutable factory;

    /// @notice The logo URI of a basket; empty until its curator sets one.
    mapping(address basket => string uri) public logoURI;

    // ----------------------------------------------------------- constructor

    constructor(BasketFactory factory_) {
        if (address(factory_) == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    // ------------------------------------------------------------------ logo

    /// @notice Set — or clear, with an empty string — the logo of a basket
    ///         published by the caller. Only `factory.curatorOf(basket)` may
    ///         call; for any address the factory did not deploy, `curatorOf`
    ///         is zero and nobody qualifies.
    function setLogoURI(address basket, string calldata uri) external {
        if (factory.curatorOf(basket) != msg.sender) revert NotCurator();
        if (bytes(uri).length > MAX_URI_LENGTH) revert UriTooLong();
        logoURI[basket] = uri;
        emit LogoSet(basket, msg.sender, uri);
    }
}
