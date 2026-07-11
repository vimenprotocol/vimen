// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Minimal Permit2 SignatureTransfer interface, vendored
/// @notice Canonical deployment on every chain (Robinhood Chain included,
///         verified on-chain 2026-07-11):
///         0x000000000022D473030F116dDEE9F6B43aC78BA3.
///         Signature-based transfers use unordered nonces, so the frontend
///         can pick any unused random value; the signed `spender` is the
///         contract calling `permitTransferFrom`.
interface ISignatureTransfer {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom memory permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;

    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
