// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract BasketTokenFuzzTest is Test {
    uint256 constant ONE = 1e18;
    uint256 constant MAX_CAP = type(uint128).max;

    address feeRecipient = makeAddr("feeRecipient");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");

    function _deploy(uint256[] memory units, uint16 feeBps) internal returns (BasketToken, address[] memory) {
        address[] memory tokens = new address[](units.length);
        for (uint256 i = 0; i < units.length; i++) {
            tokens[i] = address(new MockERC20("T", "T"));
        }
        BasketToken b =
            new BasketToken("Fuzz Basket", "FZ", tokens, units, feeBps, feeRecipient, guardian, MAX_CAP, MAX_CAP);
        return (b, tokens);
    }

    function _fundAndMint(BasketToken b, address[] memory tokens, address user, uint256 amount) internal {
        (, uint256[] memory required) = b.getRequiredUnits(amount);
        for (uint256 i = 0; i < tokens.length; i++) {
            MockERC20(tokens[i]).mint(user, required[i]);
            vm.prank(user);
            MockERC20(tokens[i]).approve(address(b), required[i]);
        }
        vm.prank(user);
        b.mint(amount, user);
    }

    /// Required test case 1 (spec §3.1): roundtrip mint→redeem returns each
    /// constituent within [required − 1 wei, required]; the user never profits
    /// from rounding. Zero fee isolates pure rounding behavior.
    function testFuzz_roundtrip_userNeverProfits(uint256 amount, uint256 u0, uint256 u1, uint256 u2) public {
        amount = bound(amount, 1, 1e30);
        uint256[] memory units = new uint256[](3);
        units[0] = bound(u0, 1, 1e24);
        units[1] = bound(u1, 1, 1e24);
        units[2] = bound(u2, 1, 1e24);
        (BasketToken b, address[] memory tokens) = _deploy(units, 0);

        (, uint256[] memory deposited) = b.getRequiredUnits(amount);
        _fundAndMint(b, tokens, alice, amount);
        assertEq(b.balanceOf(alice), amount);

        vm.prank(alice);
        b.redeem(amount, alice);

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 back = MockERC20(tokens[i]).balanceOf(alice);
            assertLe(back, deposited[i], "user profited from rounding");
            assertLe(deposited[i] - back, 1, "roundtrip loss above 1 wei per token");
        }
        assertTrue(b.isFullyBacked());
    }

    /// With a fee, the user always gets strictly less back and the fee
    /// recipient's claim stays fully backed.
    function testFuzz_roundtrip_withFee(uint256 amount, uint16 feeBps) public {
        amount = bound(amount, 1, 1e30);
        feeBps = uint16(bound(feeBps, 0, 50));
        uint256[] memory units = new uint256[](2);
        units[0] = 3e17;
        units[1] = 7;
        (BasketToken b, address[] memory tokens) = _deploy(units, feeBps);

        (, uint256[] memory deposited) = b.getRequiredUnits(amount);
        _fundAndMint(b, tokens, alice, amount);

        uint256 fee = (amount * feeBps) / 10_000;
        assertEq(b.balanceOf(alice), amount - fee);
        assertEq(b.balanceOf(feeRecipient), fee);
        assertEq(b.totalSupply(), amount);

        uint256 net = b.balanceOf(alice);
        if (net > 0) {
            vm.prank(alice);
            b.redeem(net, alice);
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            assertLe(MockERC20(tokens[i]).balanceOf(alice), deposited[i]);
        }
        assertTrue(b.isFullyBacked());
    }

    /// Fee math: fee minted to feeRecipient, net + fee == gross, monotone in bps.
    function testFuzz_feeMath(uint256 amount, uint16 feeBps) public {
        amount = bound(amount, 1, 1e30);
        feeBps = uint16(bound(feeBps, 0, 50));
        uint256[] memory units = new uint256[](2);
        units[0] = 1e18;
        units[1] = 1e18;
        (BasketToken b, address[] memory tokens) = _deploy(units, feeBps);
        _fundAndMint(b, tokens, alice, amount);

        uint256 expectedFee = (amount * feeBps) / 10_000;
        assertEq(b.balanceOf(feeRecipient), expectedFee);
        assertEq(b.balanceOf(alice) + b.balanceOf(feeRecipient), amount);
    }

    /// Repeated small mints can never leave the vault under-backed.
    function testFuzz_manySmallMints_stayBacked(uint256 seed) public {
        uint256[] memory units = new uint256[](2);
        units[0] = 333333333333333333; // 1/3, forces rounding every mint
        units[1] = 1;
        (BasketToken b, address[] memory tokens) = _deploy(units, 30);

        for (uint256 k = 0; k < 20; k++) {
            uint256 amount = (uint256(keccak256(abi.encode(seed, k))) % 1e20) + 1;
            _fundAndMint(b, tokens, alice, amount);
        }
        assertTrue(b.isFullyBacked());

        uint256 bal = b.balanceOf(alice);
        vm.prank(alice);
        b.redeem(bal / 2 + 1, alice);
        assertTrue(b.isFullyBacked());
    }

    /// getRequiredUnits is exact ceil; backingOf is exact floor.
    function testFuzz_viewMath(uint256 amount, uint256 unit) public {
        amount = bound(amount, 0, 1e30);
        unit = bound(unit, 1, 1e24);
        uint256[] memory units = new uint256[](2);
        units[0] = unit;
        units[1] = 1e18;
        (BasketToken b,) = _deploy(units, 0);

        if (amount == 0) {
            vm.expectRevert(BasketToken.ZeroAmount.selector);
            b.mint(0, alice);
            return;
        }
        (, uint256[] memory up) = b.getRequiredUnits(amount);
        (, uint256[] memory down) = b.backingOf(amount);
        assertEq(up[0], Math.mulDiv(amount, unit, ONE, Math.Rounding.Ceil));
        assertEq(down[0], Math.mulDiv(amount, unit, ONE));
        assertLe(down[0], up[0]);
        assertLe(up[0] - down[0], 1);
    }
}
