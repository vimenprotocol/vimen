// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";
import {MaliciousToken} from "./mocks/MaliciousToken.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";

contract BasketTokenTest is Test {
    uint256 constant ONE = 1e18;
    uint16 constant FEE_BPS = 30;
    uint256 constant MAX_CAP = 1_000_000e18;
    uint256 constant INITIAL_CAP = 1_000e18;

    address feeRecipient = makeAddr("feeRecipient");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 tokenC;
    address[] tokens;
    uint256[] units;
    BasketToken basket;

    function setUp() public {
        tokenA = new MockERC20("Token A", "A");
        tokenB = new MockERC20("Token B", "B");
        tokenC = new MockERC20("Token C", "C");
        tokens = [address(tokenA), address(tokenB), address(tokenC)];
        // Deliberately awkward units to exercise rounding: 2.0, 0.5, and 1 wei.
        units = [2e18, 5e17, 1];
        basket = _deploy(tokens, units, FEE_BPS, INITIAL_CAP);
    }

    function _deploy(address[] memory tokens_, uint256[] memory units_, uint16 feeBps, uint256 initialCap)
        internal
        returns (BasketToken)
    {
        return new BasketToken(
            "Test Basket", "TBSK", tokens_, units_, feeBps, feeRecipient, guardian, MAX_CAP, initialCap
        );
    }

    function _fund(address user, uint256 basketAmount) internal {
        (, uint256[] memory amounts) = basket.getRequiredUnits(basketAmount);
        for (uint256 i = 0; i < tokens.length; i++) {
            MockERC20(tokens[i]).mint(user, amounts[i]);
            vm.prank(user);
            MockERC20(tokens[i]).approve(address(basket), amounts[i]);
        }
    }

    // ------------------------------------------------------------ constructor

    function test_constructor_setsState() public view {
        assertEq(basket.name(), "Test Basket");
        assertEq(basket.symbol(), "TBSK");
        assertEq(basket.decimals(), 18);
        assertEq(basket.guardian(), guardian);
        assertEq(basket.feeRecipient(), feeRecipient);
        assertEq(basket.mintFeeBps(), FEE_BPS);
        assertEq(basket.maxSupplyCap(), MAX_CAP);
        assertEq(basket.supplyCap(), INITIAL_CAP);
        assertEq(basket.mintPaused(), false);
        assertEq(basket.constituents(), tokens);
        uint256[] memory u = basket.units();
        assertEq(u.length, units.length);
        for (uint256 i = 0; i < u.length; i++) {
            assertEq(u[i], units[i]);
        }
    }

    function test_constructor_revert_lengthMismatch() public {
        uint256[] memory badUnits = new uint256[](2);
        badUnits[0] = 1e18;
        badUnits[1] = 1e18;
        vm.expectRevert(BasketToken.LengthMismatch.selector);
        _deploy(tokens, badUnits, FEE_BPS, INITIAL_CAP);
    }

    function test_constructor_revert_tooFewConstituents() public {
        address[] memory one = new address[](1);
        one[0] = address(tokenA);
        uint256[] memory u = new uint256[](1);
        u[0] = 1e18;
        vm.expectRevert(BasketToken.InvalidConstituentCount.selector);
        _deploy(one, u, FEE_BPS, INITIAL_CAP);
    }

    function test_constructor_revert_tooManyConstituents() public {
        address[] memory many = new address[](21);
        uint256[] memory u = new uint256[](21);
        for (uint256 i = 0; i < 21; i++) {
            many[i] = address(new MockERC20("T", "T"));
            u[i] = 1e18;
        }
        vm.expectRevert(BasketToken.InvalidConstituentCount.selector);
        _deploy(many, u, FEE_BPS, INITIAL_CAP);
    }

    function test_constructor_revert_duplicateToken() public {
        address[] memory dup = new address[](3);
        dup[0] = address(tokenA);
        dup[1] = address(tokenB);
        dup[2] = address(tokenA);
        vm.expectRevert(BasketToken.DuplicateToken.selector);
        _deploy(dup, units, FEE_BPS, INITIAL_CAP);
    }

    function test_constructor_revert_zeroTokenAddress() public {
        address[] memory bad = new address[](3);
        bad[0] = address(tokenA);
        bad[1] = address(0);
        bad[2] = address(tokenC);
        vm.expectRevert(BasketToken.ZeroAddress.selector);
        _deploy(bad, units, FEE_BPS, INITIAL_CAP);
    }

    function test_constructor_revert_tokenNotAContract() public {
        address[] memory bad = new address[](3);
        bad[0] = address(tokenA);
        bad[1] = makeAddr("eoa");
        bad[2] = address(tokenC);
        vm.expectRevert(abi.encodeWithSelector(BasketToken.NotAContract.selector, bad[1]));
        _deploy(bad, units, FEE_BPS, INITIAL_CAP);
    }

    function test_constructor_revert_zeroUnits() public {
        uint256[] memory bad = new uint256[](3);
        bad[0] = 1e18;
        bad[1] = 0;
        bad[2] = 1e18;
        vm.expectRevert(BasketToken.ZeroUnits.selector);
        _deploy(tokens, bad, FEE_BPS, INITIAL_CAP);
    }

    function test_constructor_revert_feeTooHigh() public {
        vm.expectRevert(BasketToken.FeeTooHigh.selector);
        _deploy(tokens, units, 51, INITIAL_CAP);
    }

    function test_constructor_maxFeeAccepted() public {
        BasketToken b = _deploy(tokens, units, 50, INITIAL_CAP);
        assertEq(b.mintFeeBps(), 50);
    }

    function test_constructor_revert_zeroFeeRecipient() public {
        vm.expectRevert(BasketToken.ZeroAddress.selector);
        new BasketToken("B", "B", tokens, units, FEE_BPS, address(0), guardian, MAX_CAP, INITIAL_CAP);
    }

    function test_constructor_revert_zeroGuardian() public {
        vm.expectRevert(BasketToken.ZeroAddress.selector);
        new BasketToken("B", "B", tokens, units, FEE_BPS, feeRecipient, address(0), MAX_CAP, INITIAL_CAP);
    }

    function test_constructor_revert_zeroMaxSupplyCap() public {
        vm.expectRevert(BasketToken.ZeroSupplyCap.selector);
        new BasketToken("B", "B", tokens, units, FEE_BPS, feeRecipient, guardian, 0, 0);
    }

    function test_constructor_revert_zeroInitialSupplyCap() public {
        vm.expectRevert(BasketToken.ZeroSupplyCap.selector);
        new BasketToken("B", "B", tokens, units, FEE_BPS, feeRecipient, guardian, MAX_CAP, 0);
    }

    function test_constructor_revert_initialCapAboveMax() public {
        vm.expectRevert(BasketToken.CapExceedsMax.selector);
        new BasketToken("B", "B", tokens, units, FEE_BPS, feeRecipient, guardian, MAX_CAP, MAX_CAP + 1);
    }

    // ------------------------------------------------------------------ views

    function test_requiredAndBacking_rounding() public view {
        (address[] memory t,) = basket.getRequiredUnits(1);
        assertEq(t, tokens);
        // basketAmount = 1 wei
        (, uint256[] memory up) = basket.getRequiredUnits(1);
        (, uint256[] memory down) = basket.backingOf(1);
        // unit 2e18: exact 2 wei both directions
        assertEq(up[0], 2);
        assertEq(down[0], 2);
        // unit 0.5e18: exact 0.5 → up 1, down 0
        assertEq(up[1], 1);
        assertEq(down[1], 0);
        // unit 1 wei: exact 1e-18 → up 1, down 0
        assertEq(up[2], 1);
        assertEq(down[2], 0);
    }

    function test_isFullyBacked_emptyBasket() public view {
        assertTrue(basket.isFullyBacked());
    }

    // ------------------------------------------------------------------- mint

    function test_mint_happyPath() public {
        uint256 amount = 100e18;
        _fund(alice, amount);
        (, uint256[] memory required) = basket.getRequiredUnits(amount);

        vm.expectEmit(true, true, false, true);
        emit BasketToken.Minted(alice, alice, amount, (amount * FEE_BPS) / 10_000);
        vm.prank(alice);
        basket.mint(amount, alice);

        uint256 fee = (amount * FEE_BPS) / 10_000;
        assertEq(basket.balanceOf(alice), amount - fee);
        assertEq(basket.balanceOf(feeRecipient), fee);
        assertEq(basket.totalSupply(), amount);
        for (uint256 i = 0; i < tokens.length; i++) {
            assertEq(MockERC20(tokens[i]).balanceOf(address(basket)), required[i]);
            assertEq(MockERC20(tokens[i]).balanceOf(alice), 0);
        }
        assertTrue(basket.isFullyBacked());
    }

    function test_mint_toThirdParty() public {
        _fund(alice, 10e18);
        vm.prank(alice);
        basket.mint(10e18, bob);
        uint256 fee = (10e18 * uint256(FEE_BPS)) / 10_000;
        assertEq(basket.balanceOf(bob), 10e18 - fee);
        assertEq(basket.balanceOf(alice), 0);
    }

    function test_mint_zeroFee() public {
        BasketToken freeBasket = _deploy(tokens, units, 0, INITIAL_CAP);
        (, uint256[] memory amounts) = freeBasket.getRequiredUnits(10e18);
        for (uint256 i = 0; i < tokens.length; i++) {
            MockERC20(tokens[i]).mint(alice, amounts[i]);
            vm.prank(alice);
            MockERC20(tokens[i]).approve(address(freeBasket), amounts[i]);
        }
        vm.prank(alice);
        freeBasket.mint(10e18, alice);
        assertEq(freeBasket.balanceOf(alice), 10e18);
        assertEq(freeBasket.balanceOf(feeRecipient), 0);
    }

    function test_mint_revert_zeroAmount() public {
        vm.expectRevert(BasketToken.ZeroAmount.selector);
        vm.prank(alice);
        basket.mint(0, alice);
    }

    function test_mint_revert_whenPaused() public {
        vm.prank(guardian);
        basket.setMintPaused(true);
        _fund(alice, 1e18);
        vm.expectRevert(BasketToken.MintingPaused.selector);
        vm.prank(alice);
        basket.mint(1e18, alice);
    }

    function test_mint_worksAfterUnpause() public {
        vm.prank(guardian);
        basket.setMintPaused(true);
        vm.prank(guardian);
        basket.setMintPaused(false);
        _fund(alice, 1e18);
        vm.prank(alice);
        basket.mint(1e18, alice);
        assertGt(basket.balanceOf(alice), 0);
    }

    function test_mint_revert_aboveCap() public {
        _fund(alice, INITIAL_CAP + 1);
        vm.expectRevert(BasketToken.SupplyCapExceeded.selector);
        vm.prank(alice);
        basket.mint(INITIAL_CAP + 1, alice);
    }

    function test_mint_exactlyAtCap() public {
        _fund(alice, INITIAL_CAP);
        vm.prank(alice);
        basket.mint(INITIAL_CAP, alice);
        assertEq(basket.totalSupply(), INITIAL_CAP);
    }

    function test_mint_revert_capCountsExistingSupply() public {
        _fund(alice, INITIAL_CAP);
        vm.prank(alice);
        basket.mint(INITIAL_CAP, alice);
        _fund(bob, 1);
        vm.expectRevert(BasketToken.SupplyCapExceeded.selector);
        vm.prank(bob);
        basket.mint(1, bob);
    }

    function test_mint_revert_insufficientAllowance() public {
        (, uint256[] memory amounts) = basket.getRequiredUnits(1e18);
        for (uint256 i = 0; i < tokens.length; i++) {
            MockERC20(tokens[i]).mint(alice, amounts[i]);
        }
        vm.expectRevert(); // ERC20InsufficientAllowance from constituent
        vm.prank(alice);
        basket.mint(1e18, alice);
    }

    function test_mint_revert_feeOnTransferConstituent() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        address[] memory t = new address[](2);
        t[0] = address(tokenA);
        t[1] = address(fot);
        uint256[] memory u = new uint256[](2);
        u[0] = 1e18;
        u[1] = 1e18;
        BasketToken b = _deploy(t, u, FEE_BPS, INITIAL_CAP);

        tokenA.mint(alice, 10e18);
        fot.mint(alice, 10e18);
        vm.startPrank(alice);
        tokenA.approve(address(b), type(uint256).max);
        fot.approve(address(b), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(BasketToken.InsufficientDeposit.selector, address(fot)));
        b.mint(1e18, alice);
        vm.stopPrank();
    }

    function test_mint_revert_maliciousConstituent() public {
        MaliciousToken evil = new MaliciousToken();
        address[] memory t = new address[](2);
        t[0] = address(tokenA);
        t[1] = address(evil);
        uint256[] memory u = new uint256[](2);
        u[0] = 1e18;
        u[1] = 1e18;
        BasketToken b = _deploy(t, u, FEE_BPS, INITIAL_CAP);

        tokenA.mint(alice, 10e18);
        evil.mint(alice, 10e18);
        vm.startPrank(alice);
        tokenA.approve(address(b), type(uint256).max);
        evil.approve(address(b), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(BasketToken.InsufficientDeposit.selector, address(evil)));
        b.mint(1e18, alice);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- redeem

    function test_redeem_happyPath() public {
        uint256 amount = 100e18;
        _fund(alice, amount);
        vm.prank(alice);
        basket.mint(amount, alice);

        uint256 net = basket.balanceOf(alice);
        (, uint256[] memory expected) = basket.backingOf(net);

        vm.expectEmit(true, true, false, true);
        emit BasketToken.Redeemed(alice, alice, net);
        vm.prank(alice);
        basket.redeem(net, alice);

        assertEq(basket.balanceOf(alice), 0);
        for (uint256 i = 0; i < tokens.length; i++) {
            assertEq(MockERC20(tokens[i]).balanceOf(alice), expected[i]);
        }
        assertTrue(basket.isFullyBacked());
    }

    function test_redeem_toThirdParty() public {
        _fund(alice, 10e18);
        vm.prank(alice);
        basket.mint(10e18, alice);
        uint256 net = basket.balanceOf(alice);
        (, uint256[] memory expected) = basket.backingOf(net);
        vm.prank(alice);
        basket.redeem(net, bob);
        for (uint256 i = 0; i < tokens.length; i++) {
            assertEq(MockERC20(tokens[i]).balanceOf(bob), expected[i]);
        }
    }

    function test_redeem_fromAnyHolder() public {
        _fund(alice, 10e18);
        vm.prank(alice);
        basket.mint(10e18, alice);
        uint256 net = basket.balanceOf(alice);
        vm.prank(alice);
        basket.transfer(bob, net);
        vm.prank(bob);
        basket.redeem(net, bob);
        assertEq(basket.balanceOf(bob), 0);
    }

    /// FR-5: redeem must work while minting is paused AND supply is at cap.
    function test_redeem_worksWhilePausedAndAtCap() public {
        _fund(alice, INITIAL_CAP);
        vm.prank(alice);
        basket.mint(INITIAL_CAP, alice);
        assertEq(basket.totalSupply(), basket.supplyCap());

        vm.prank(guardian);
        basket.setMintPaused(true);
        // guardian also slams the cap to 1 wei — must not matter for redeem
        vm.prank(guardian);
        basket.setSupplyCap(1);

        uint256 net = basket.balanceOf(alice);
        vm.prank(alice);
        basket.redeem(net, alice);
        assertEq(basket.balanceOf(alice), 0);
        assertTrue(basket.isFullyBacked());
    }

    function test_redeem_feeRecipientCanRedeemFees() public {
        _fund(alice, 100e18);
        vm.prank(alice);
        basket.mint(100e18, alice);
        uint256 fee = basket.balanceOf(feeRecipient);
        assertGt(fee, 0);
        vm.prank(feeRecipient);
        basket.redeem(fee, feeRecipient);
        assertEq(basket.balanceOf(feeRecipient), 0);
    }

    function test_redeem_revert_zeroAmount() public {
        vm.expectRevert(BasketToken.ZeroAmount.selector);
        vm.prank(alice);
        basket.redeem(0, alice);
    }

    function test_redeem_revert_zeroRecipient() public {
        _fund(alice, 1e18);
        vm.prank(alice);
        basket.mint(1e18, alice);
        vm.expectRevert(BasketToken.ZeroAddress.selector);
        vm.prank(alice);
        basket.redeem(1, address(0));
    }

    function test_redeem_revert_insufficientBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1e18));
        vm.prank(alice);
        basket.redeem(1e18, alice);
    }

    // ------------------------------------------------------------- reentrancy

    function _reentrantBasket() internal returns (BasketToken b, ReentrantToken reent) {
        reent = new ReentrantToken();
        address[] memory t = new address[](2);
        t[0] = address(tokenA);
        t[1] = address(reent);
        uint256[] memory u = new uint256[](2);
        u[0] = 1e18;
        u[1] = 1e18;
        b = _deploy(t, u, FEE_BPS, INITIAL_CAP);

        tokenA.mint(alice, 100e18);
        reent.mint(alice, 100e18);
        vm.startPrank(alice);
        tokenA.approve(address(b), type(uint256).max);
        reent.approve(address(b), type(uint256).max);
        vm.stopPrank();
    }

    function test_reentrancy_mintDuringMint_reverts() public {
        (BasketToken b, ReentrantToken reent) = _reentrantBasket();
        reent.setAttack(b, ReentrantToken.Attack.MintDuringMint);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        b.mint(1e18, alice);
    }

    function test_reentrancy_redeemDuringMint_reverts() public {
        (BasketToken b, ReentrantToken reent) = _reentrantBasket();
        reent.setAttack(b, ReentrantToken.Attack.RedeemDuringMint);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        b.mint(1e18, alice);
    }

    function test_reentrancy_mintDuringRedeem_reverts() public {
        (BasketToken b, ReentrantToken reent) = _reentrantBasket();
        vm.prank(alice);
        b.mint(10e18, alice);
        reent.setAttack(b, ReentrantToken.Attack.MintDuringRedeem);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        b.redeem(1e18, alice);
    }

    function test_reentrancy_redeemDuringRedeem_reverts() public {
        (BasketToken b, ReentrantToken reent) = _reentrantBasket();
        vm.prank(alice);
        b.mint(10e18, alice);
        reent.setAttack(b, ReentrantToken.Attack.RedeemDuringRedeem);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        b.redeem(1e18, alice);
    }

    // --------------------------------------------------------------- guardian

    function test_guardian_setMintPaused() public {
        vm.expectEmit(false, false, false, true);
        emit BasketToken.MintPausedSet(true);
        vm.prank(guardian);
        basket.setMintPaused(true);
        assertTrue(basket.mintPaused());
    }

    function test_guardian_setSupplyCap_upToMax() public {
        vm.expectEmit(false, false, false, true);
        emit BasketToken.SupplyCapSet(MAX_CAP);
        vm.prank(guardian);
        basket.setSupplyCap(MAX_CAP);
        assertEq(basket.supplyCap(), MAX_CAP);
    }

    function test_guardian_setSupplyCap_revert_aboveMax() public {
        vm.expectRevert(BasketToken.CapExceedsMax.selector);
        vm.prank(guardian);
        basket.setSupplyCap(MAX_CAP + 1);
    }

    function test_guardian_setSupplyCap_canLowerBelowSupply() public {
        _fund(alice, 100e18);
        vm.prank(alice);
        basket.mint(100e18, alice);
        vm.prank(guardian);
        basket.setSupplyCap(1); // blocks future mints, never affects redeem
        assertEq(basket.supplyCap(), 1);
        uint256 net = basket.balanceOf(alice);
        vm.prank(alice);
        basket.redeem(net, alice);
    }

    function test_guardian_setFeeRecipient() public {
        vm.expectEmit(true, false, false, true);
        emit BasketToken.FeeRecipientSet(bob);
        vm.prank(guardian);
        basket.setFeeRecipient(bob);
        assertEq(basket.feeRecipient(), bob);

        _fund(alice, 100e18);
        vm.prank(alice);
        basket.mint(100e18, alice);
        assertEq(basket.balanceOf(bob), (100e18 * uint256(FEE_BPS)) / 10_000);
    }

    function test_guardian_setFeeRecipient_revert_zero() public {
        vm.expectRevert(BasketToken.ZeroAddress.selector);
        vm.prank(guardian);
        basket.setFeeRecipient(address(0));
    }

    function test_nonGuardian_reverts_onAllGuardianFunctions() public {
        vm.startPrank(alice);
        vm.expectRevert(BasketToken.NotGuardian.selector);
        basket.setMintPaused(true);
        vm.expectRevert(BasketToken.NotGuardian.selector);
        basket.setSupplyCap(1);
        vm.expectRevert(BasketToken.NotGuardian.selector);
        basket.setFeeRecipient(alice);
        vm.stopPrank();
    }

    /// The guardian has no path to constituents: even after exercising every
    /// guardian power, backing is intact and redeem pays out in full.
    function test_guardian_cannotTouchBacking() public {
        _fund(alice, 100e18);
        vm.prank(alice);
        basket.mint(100e18, alice);
        (, uint256[] memory before) = basket.getRequiredUnits(100e18);

        vm.startPrank(guardian);
        basket.setMintPaused(true);
        basket.setMintPaused(false);
        basket.setSupplyCap(1);
        basket.setSupplyCap(MAX_CAP);
        basket.setFeeRecipient(bob);
        vm.stopPrank();

        for (uint256 i = 0; i < tokens.length; i++) {
            assertEq(MockERC20(tokens[i]).balanceOf(address(basket)), before[i]);
        }
        assertTrue(basket.isFullyBacked());
    }

    // ------------------------------------------------------------- monitoring

    function test_isFullyBacked_falseWhenDrained() public {
        _fund(alice, 100e18);
        vm.prank(alice);
        basket.mint(100e18, alice);
        assertTrue(basket.isFullyBacked());
        // No code path can drain the vault; simulate an exogenous deficit
        // (e.g. issuer clawback) by forcing the balance down.
        deal(address(tokenA), address(basket), 0);
        assertFalse(basket.isFullyBacked());
    }

    function test_isFullyBacked_trueWithDonation() public {
        _fund(alice, 100e18);
        vm.prank(alice);
        basket.mint(100e18, alice);
        tokenA.mint(address(basket), 1e18); // donations only help
        assertTrue(basket.isFullyBacked());
    }
}
