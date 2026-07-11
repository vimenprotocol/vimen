// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BasketToken} from "../../src/BasketToken.sol";

/// @dev ERC-20 with a transfer hook that re-enters the basket during
///      mint (via transferFrom) and redeem (via transfer). Both attempts
///      must be stopped by the basket's reentrancy guard.
contract ReentrantToken is ERC20 {
    enum Attack {
        None,
        MintDuringMint,
        RedeemDuringMint,
        MintDuringRedeem,
        RedeemDuringRedeem
    }

    BasketToken public basket;
    Attack public attack;

    constructor() ERC20("Reentrant", "REENT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setAttack(BasketToken basket_, Attack attack_) external {
        basket = basket_;
        attack = attack_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (attack == Attack.None || address(basket) == address(0)) return;

        Attack a = attack;
        attack = Attack.None; // single-shot to avoid infinite loops
        if (a == Attack.MintDuringMint || a == Attack.MintDuringRedeem) {
            basket.mint(1e18, address(this));
        } else {
            basket.redeem(1e18, address(this));
        }
    }
}
