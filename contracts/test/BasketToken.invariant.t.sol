// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// Random-action handler: mints, redeems, transfers and guardian ops from a
/// pool of actors. All calls are bounded-valid so fail_on_revert stays
/// meaningful where it matters (the invariant itself).
contract Handler is Test {
    BasketToken public basket;
    address[] public tokens;
    address public guardian;
    address[] public actors;

    uint256 public totalMinted;
    uint256 public totalRedeemed;

    constructor(BasketToken basket_, address[] memory tokens_, address guardian_) {
        basket = basket_;
        tokens = tokens_;
        guardian = guardian_;
        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string(abi.encodePacked("actor", i))));
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function mint(uint256 seed, uint256 amount) external {
        address user = _actor(seed);
        amount = bound(amount, 1, 1e24);
        if (basket.mintPaused()) return;
        if (basket.totalSupply() + amount > basket.supplyCap()) return;

        (, uint256[] memory required) = basket.getRequiredUnits(amount);
        for (uint256 i = 0; i < tokens.length; i++) {
            MockERC20(tokens[i]).mint(user, required[i]);
            vm.prank(user);
            MockERC20(tokens[i]).approve(address(basket), required[i]);
        }
        vm.prank(user);
        basket.mint(amount, user);
        totalMinted += amount;
    }

    function redeem(uint256 seed, uint256 amount) external {
        address user = _actor(seed);
        uint256 balance = basket.balanceOf(user);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(user);
        basket.redeem(amount, user);
        totalRedeemed += amount;
    }

    function transferBasket(uint256 seedFrom, uint256 seedTo, uint256 amount) external {
        address from = _actor(seedFrom);
        address to = _actor(seedTo);
        uint256 balance = basket.balanceOf(from);
        if (balance == 0 || from == to) return;
        amount = bound(amount, 1, balance);
        vm.prank(from);
        basket.transfer(to, amount);
    }

    function donate(uint256 seed, uint256 amount) external {
        // Direct transfers into the vault must never break anything.
        amount = bound(amount, 1, 1e20);
        MockERC20(tokens[seed % tokens.length]).mint(address(basket), amount);
    }

    function guardianOps(uint256 seed, uint256 newCap) external {
        uint256 op = seed % 3;
        vm.startPrank(guardian);
        if (op == 0) {
            basket.setMintPaused(seed % 2 == 0);
        } else if (op == 1) {
            basket.setSupplyCap(bound(newCap, 1, basket.maxSupplyCap()));
        } else {
            basket.setFeeRecipient(_actor(seed));
        }
        vm.stopPrank();
    }
}

contract BasketTokenInvariantTest is Test {
    uint256 constant ONE = 1e18;

    BasketToken basket;
    Handler handler;
    address[] tokens;
    uint256[] units;
    address guardian = makeAddr("guardian");
    address feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        for (uint256 i = 0; i < 4; i++) {
            tokens.push(address(new MockERC20("T", "T")));
        }
        // Rounding-hostile units: 1/3, 1 wei, 2.5, 1e-15
        units = [uint256(333333333333333333), 1, 25e17, 1e3];
        basket = new BasketToken(
            "Invariant Basket", "INV", tokens, units, 30, feeRecipient, guardian, type(uint128).max, type(uint128).max
        );
        handler = new Handler(basket, tokens, guardian);
        targetContract(address(handler));
    }

    /// Required test case 2 (spec §3.1): after any call sequence, every
    /// constituent balance covers total supply (full backing).
    function invariant_fullBacking() public view {
        uint256 supply = basket.totalSupply();
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 required = Math.mulDiv(supply, units[i], ONE, Math.Rounding.Ceil);
            assertGe(MockERC20(tokens[i]).balanceOf(address(basket)), required, "constituent under-backs total supply");
        }
        assertTrue(basket.isFullyBacked());
    }

    /// Supply accounting: totalSupply == minted − redeemed, and never above
    /// the immutable ceiling.
    function invariant_supplyAccounting() public view {
        assertEq(basket.totalSupply(), handler.totalMinted() - handler.totalRedeemed());
        assertLe(basket.totalSupply(), basket.maxSupplyCap());
    }
}
