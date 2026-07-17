// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BasketToken2} from "./BasketToken2.sol";

/// @title BasketTokenDeployer — BasketToken2's creation code, split out
/// @notice BasketFactory2's runtime used to embed the full creation code of
///         BOTH BasketToken2 and BasketDistributor and blew past EIP-170
///         (31,454 > 24,576 bytes). This contract carries the token's
///         creation code instead (the Uniswap pool-deployer pattern); the
///         factory keeps the (small) distributor inline and calls here.
///
///         Stateless and permissionless by design. A token deployed through
///         this contract records IT as `_deployer`, so the one-shot
///         `initDistributor` is forwarded here too. That forwarder needs no
///         access control: inside `BasketFactory2.createBasket` the
///         deploy -> wire sequence is a single atomic transaction, and
///         `initDistributor` is one-shot on the token, so by the time anyone
///         else could call it the slot is already frozen. Calling `deploy`
///         directly just creates an orphan token that no factory registered:
///         it never reaches the FeeSplitter or the shelf.
contract BasketTokenDeployer {
    function deploy(
        BasketToken2.Init calldata init,
        BasketToken2.Wiring calldata wiring,
        BasketToken2.Policy calldata policy
    ) external returns (BasketToken2 token) {
        token = new BasketToken2(init, wiring, policy);
    }

    function initDistributor(BasketToken2 token, address distributor) external {
        token.initDistributor(distributor);
    }
}
