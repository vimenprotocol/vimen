// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VimenToken} from "./mocks/VimenToken.sol";
import {CuratorRegistry, IVimBurnable} from "../src/CuratorRegistry.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {BasketFactory} from "../src/BasketFactory.sol";
import {CuratorGuardian, IBasketCap} from "../src/CuratorGuardian.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAgentToken} from "./mocks/MockAgentToken.sol";

/// Burn-for-license curation platform: burn 25k VIM -> permanent license ->
/// publish baskets -> 60% of every mint fee goes straight to the curator.
contract PlatformTest is Test {
    VimenToken vim;
    CuratorRegistry registry;
    FeeSplitter splitter;
    CuratorGuardian curatorGuardian;
    BasketFactory factory;

    address treasury = makeAddr("treasury");
    address protocolSafe = makeAddr("protocolSafe"); // the CuratorGuardian admin
    address curator = makeAddr("curator");
    address minter = makeAddr("minter");

    MockERC20 tokenA;
    MockERC20 tokenB;

    uint256 constant LICENSE = 25_000e18;

    function setUp() public {
        vim = new VimenToken(address(this));
        registry = new CuratorRegistry(IVimBurnable(address(vim)));
        splitter = new FeeSplitter(treasury);
        curatorGuardian = new CuratorGuardian(protocolSafe);
        factory = new BasketFactory(registry, splitter, address(curatorGuardian));
        splitter.initFactory(address(factory));

        vim.transfer(curator, 100_000e18);

        tokenA = new MockERC20("Token A", "A");
        tokenB = new MockERC20("Token B", "B");
    }

    function _license(address who) internal {
        vm.startPrank(who);
        vim.approve(address(registry), LICENSE);
        registry.burnForLicense();
        vm.stopPrank();
    }

    function _createBasket() internal returns (BasketToken basket) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory units = new uint256[](2);
        units[0] = 1e18;
        units[1] = 5e17;
        vm.prank(curator);
        basket = BasketToken(factory.createBasket("Chip War", "CHIPW", tokens, units, 30, 1_000e18));
    }

    function _mint(BasketToken basket, address user, uint256 amount) internal {
        (, uint256[] memory required) = basket.getRequiredUnits(amount);
        tokenA.mint(user, required[0]);
        tokenB.mint(user, required[1]);
        vm.startPrank(user);
        tokenA.approve(address(basket), required[0]);
        tokenB.approve(address(basket), required[1]);
        basket.mint(amount, user);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ VIM token

    function test_token_fixedSupplyAndSymbol() public {
        VimenToken t = new VimenToken(treasury);
        assertEq(t.totalSupply(), 100_000_000e18);
        assertEq(t.balanceOf(treasury), 100_000_000e18);
        assertEq(t.symbol(), "VIM");
        assertEq(t.name(), "Vimen");
    }

    function test_token_revert_zeroDistributor() public {
        vm.expectRevert(VimenToken.ZeroAddress.selector);
        new VimenToken(address(0));
    }

    function test_token_isBurnable() public {
        uint256 supplyBefore = vim.totalSupply();
        vm.prank(curator);
        vim.burn(1_000e18);
        assertEq(vim.totalSupply(), supplyBefore - 1_000e18);
    }

    // ---------------------------------------------------------- burn license

    function test_burnForLicense_burnsAndLicenses() public {
        uint256 supplyBefore = vim.totalSupply();
        uint256 curatorBefore = vim.balanceOf(curator);
        assertFalse(registry.isLicensed(curator));

        vm.startPrank(curator);
        vim.approve(address(registry), LICENSE);
        vm.expectEmit(true, false, false, true);
        emit CuratorRegistry.LicenseBurned(curator, LICENSE);
        registry.burnForLicense();
        vm.stopPrank();

        assertTrue(registry.isLicensed(curator));
        // VIM is truly burned: supply and the curator's balance both drop
        assertEq(vim.totalSupply(), supplyBefore - LICENSE);
        assertEq(vim.balanceOf(curator), curatorBefore - LICENSE);
        // registry never holds the token
        assertEq(vim.balanceOf(address(registry)), 0);
    }

    function test_burnForLicense_alreadyLicensed_reverts() public {
        _license(curator);
        vm.startPrank(curator);
        vim.approve(address(registry), LICENSE);
        vm.expectRevert(CuratorRegistry.AlreadyLicensed.selector);
        registry.burnForLicense();
        vm.stopPrank();
    }

    function test_burnForLicense_noApproval_reverts() public {
        vm.prank(curator);
        vm.expectRevert(); // ERC20 insufficient allowance
        registry.burnForLicense();
        assertFalse(registry.isLicensed(curator));
    }

    function test_burnForLicense_insufficientBalance_reverts() public {
        address broke = makeAddr("broke");
        vim.transfer(broke, LICENSE - 1);
        vm.startPrank(broke);
        vim.approve(address(registry), LICENSE);
        vm.expectRevert(); // ERC20 insufficient balance
        registry.burnForLicense();
        vm.stopPrank();
        assertFalse(registry.isLicensed(broke));
    }

    function test_registry_revert_zeroToken() public {
        vm.expectRevert(CuratorRegistry.ZeroAddress.selector);
        new CuratorRegistry(IVimBurnable(address(0)));
    }

    function test_licenseBurn_isFixedConstant() public view {
        assertEq(registry.LICENSE_BURN(), LICENSE);
    }

    /// Verify against the REAL token's semantics (Virtuals AgentTokenV4): a 1%
    /// transfer tax and a blacklist, but burns are exempt from both.
    function test_burnForLicense_againstRealTokenSemantics() public {
        MockAgentToken vimReal = new MockAgentToken(curator, 1_000_000_000e18);
        CuratorRegistry reg = new CuratorRegistry(IVimBurnable(address(vimReal)));

        // even a BLACKLISTED curator can still burn for a license
        vimReal.setBlacklist(curator, true);

        uint256 supplyBefore = vimReal.totalSupply();
        uint256 balBefore = vimReal.balanceOf(curator);
        vm.startPrank(curator);
        vimReal.approve(address(reg), LICENSE);
        reg.burnForLicense();
        vm.stopPrank();

        assertTrue(reg.isLicensed(curator));
        // exactly LICENSE burned — the 1% tax never touches a burn
        assertEq(vimReal.totalSupply(), supplyBefore - LICENSE);
        assertEq(vimReal.balanceOf(curator), balBefore - LICENSE);
        assertEq(vimReal.balanceOf(vimReal.TAX_RECIPIENT()), 0);
    }

    // --------------------------------------------------------- factory gating

    function test_factory_unlicensed_cannotPublish() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory units = new uint256[](2);
        units[0] = 1e18;
        units[1] = 5e17;
        vm.prank(curator); // not licensed yet
        vm.expectRevert(BasketFactory.NotLicensed.selector);
        factory.createBasket("Chip War", "CHIPW", tokens, units, 30, 1_000e18);
    }

    function test_factory_licensed_publishes_wiredCorrectly() public {
        _license(curator);
        BasketToken basket = _createBasket();

        assertEq(basket.feeRecipient(), address(splitter));
        assertEq(basket.guardian(), address(curatorGuardian));
        assertEq(basket.supplyCap(), 1_000e18);
        assertEq(splitter.curatorOf(address(basket)), curator);
        assertEq(factory.curatorOf(address(basket)), curator);
        assertEq(factory.basketCount(), 1);
    }

    function test_factory_capAboveStarter_reverts() public {
        _license(curator);
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory units = new uint256[](2);
        units[0] = 1e18;
        units[1] = 5e17;
        vm.prank(curator);
        vm.expectRevert(BasketFactory.CapAboveFactoryLimit.selector);
        factory.createBasket("Chip War", "CHIPW", tokens, units, 30, 2_000e18);
    }

    // --------------------------------------------------- fee flow (60/40)

    function test_feeFlow_sixtyToCuratorFortyToTreasury() public {
        _license(curator);
        BasketToken basket = _createBasket();
        _mint(basket, minter, 100e18); // 0.30% fee = 0.3 basket to the splitter

        uint256 fee = basket.balanceOf(address(splitter));
        assertGt(fee, 0);

        splitter.distribute(address(basket));

        uint256 toCurator = (fee * 6_000) / 10_000;
        assertEq(basket.balanceOf(curator), toCurator);
        assertEq(basket.balanceOf(treasury), fee - toCurator);
        assertEq(basket.balanceOf(address(splitter)), 0);
    }

    function test_distribute_unknownBasket_reverts() public {
        vm.expectRevert(FeeSplitter.UnknownBasket.selector);
        splitter.distribute(address(0xBEEF));
    }

    function test_distribute_emptyBalance_noop() public {
        _license(curator);
        BasketToken basket = _createBasket();
        splitter.distribute(address(basket)); // no fees yet: returns cleanly
        assertEq(basket.balanceOf(curator), 0);
    }

    function test_splitter_register_onlyFactory() public {
        vm.expectRevert(FeeSplitter.NotFactory.selector);
        splitter.register(address(0xBEEF), curator);
    }

    function test_splitter_initFactory_onceOnly() public {
        vm.expectRevert(FeeSplitter.AlreadyInitialized.selector);
        splitter.initFactory(address(0xBEEF));
    }

    // ----------------------------------------------- restricted guardian

    function test_guardian_revert_zeroAdmin() public {
        vm.expectRevert(CuratorGuardian.ZeroAddress.selector);
        new CuratorGuardian(address(0));
    }

    function test_guardian_adminIsSafe() public view {
        assertEq(curatorGuardian.admin(), protocolSafe);
    }

    function test_guardian_raiseCap_byAdmin() public {
        _license(curator);
        BasketToken basket = _createBasket();
        vm.prank(protocolSafe);
        curatorGuardian.raiseCap(IBasketCap(address(basket)), 5_000e18);
        assertEq(basket.supplyCap(), 5_000e18);
    }

    function test_guardian_raiseCap_notAdmin_reverts() public {
        _license(curator);
        BasketToken basket = _createBasket();
        vm.prank(curator);
        vm.expectRevert(CuratorGuardian.NotAdmin.selector);
        curatorGuardian.raiseCap(IBasketCap(address(basket)), 5_000e18);
    }

    function test_guardian_raiseCap_notIncreasing_reverts() public {
        _license(curator);
        BasketToken basket = _createBasket(); // cap 1_000e18
        vm.startPrank(protocolSafe);
        vm.expectRevert(CuratorGuardian.CapNotIncreasing.selector);
        curatorGuardian.raiseCap(IBasketCap(address(basket)), 1_000e18); // equal
        vm.expectRevert(CuratorGuardian.CapNotIncreasing.selector);
        curatorGuardian.raiseCap(IBasketCap(address(basket)), 500e18); // lower
        vm.stopPrank();
        assertEq(basket.supplyCap(), 1_000e18);
    }

    function test_guardian_raiseCap_aboveCeiling_reverts() public {
        _license(curator);
        BasketToken basket = _createBasket();
        vm.prank(protocolSafe);
        vm.expectRevert(BasketToken.CapExceedsMax.selector);
        curatorGuardian.raiseCap(IBasketCap(address(basket)), 2_000_000e18); // > CEILING (1M)
    }

    /// The heart of the "non-revocable, un-chokeable" guarantee: because the
    /// curated basket's guardian is the CuratorGuardian contract (which has no
    /// setFeeRecipient / setMintPaused path), NO caller — not even the protocol
    /// Safe — can redirect fees or pause minting on a curated basket.
    function test_guardian_cannotRedirectOrPauseFees() public {
        _license(curator);
        BasketToken basket = _createBasket();

        // the Safe is only the guardian's admin, not the basket's guardian
        vm.startPrank(protocolSafe);
        vm.expectRevert(BasketToken.NotGuardian.selector);
        basket.setFeeRecipient(address(0xBEEF));
        vm.expectRevert(BasketToken.NotGuardian.selector);
        basket.setMintPaused(true);
        vm.stopPrank();

        // and the guardian contract exposes no such function, so the powers are
        // permanently unreachable: fee recipient stays the splitter, mint open
        assertEq(basket.feeRecipient(), address(splitter));
        assertFalse(basket.mintPaused());
    }

    // ----------------------------------------------------------- end to end

    function test_endToEnd_burnPublishMintDistribute() public {
        _license(curator);
        BasketToken basket = _createBasket();
        assertTrue(basket.isFullyBacked());

        _mint(basket, minter, 500e18);
        assertTrue(basket.isFullyBacked());

        uint256 fee = basket.balanceOf(address(splitter));
        splitter.distribute(address(basket));

        // curator earns 60% of the fee directly, in one hop, no staking
        assertEq(basket.balanceOf(curator), (fee * 6_000) / 10_000);
        assertTrue(basket.isFullyBacked());
    }
}
