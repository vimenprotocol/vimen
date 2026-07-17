// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VimenToken} from "./mocks/VimenToken.sol";
import {CuratorRegistry, IVimBurnable} from "../src/CuratorRegistry.sol";
import {CuratorRegistry2, ILegacyRegistry} from "../src/CuratorRegistry2.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {BasketFactory} from "../src/BasketFactory.sol";
import {CuratorGuardian, IBasketCap} from "../src/CuratorGuardian.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// Repriced curation platform: CuratorRegistry2 (10k V1 / 25k V2, legacy 25k
/// grandfathered into V2) + second FeeSplitter/BasketFactory instances around
/// the ORIGINAL platform, which stays live throughout.
contract Platform2Test is Test {
    VimenToken vim;

    // original platform (stays live)
    CuratorRegistry legacyRegistry;
    FeeSplitter legacySplitter;
    CuratorGuardian curatorGuardian; // REUSED by the new factory
    BasketFactory legacyFactory;

    // repriced platform
    CuratorRegistry2 registry;
    FeeSplitter splitter;
    BasketFactory factory;

    address treasury = makeAddr("treasury");
    address protocolSafe = makeAddr("protocolSafe");
    address legacyCurator = makeAddr("legacyCurator"); // burned 25k pre-repricing
    address curator = makeAddr("curator"); // new V1 curator
    address curatorV2 = makeAddr("curatorV2"); // new V2 curator
    address minter = makeAddr("minter");

    MockERC20 tokenA;
    MockERC20 tokenB;

    uint256 constant V1 = 10_000e18;
    uint256 constant V2 = 25_000e18;

    event LicenseBurned(address indexed curator, uint256 amount);

    function setUp() public {
        vim = new VimenToken(address(this));

        // original platform, exactly as deployed
        legacyRegistry = new CuratorRegistry(IVimBurnable(address(vim)));
        legacySplitter = new FeeSplitter(treasury);
        curatorGuardian = new CuratorGuardian(protocolSafe);
        legacyFactory = new BasketFactory(legacyRegistry, legacySplitter, address(curatorGuardian));
        legacySplitter.initFactory(address(legacyFactory));

        // a curator licensed at the old 25k price, before the repricing
        vim.transfer(legacyCurator, 100_000e18);
        vm.startPrank(legacyCurator);
        vim.approve(address(legacyRegistry), 25_000e18);
        legacyRegistry.burnForLicense();
        vm.stopPrank();

        // repriced platform, wired the way DeployPlatform2 does
        registry = new CuratorRegistry2(IVimBurnable(address(vim)), ILegacyRegistry(address(legacyRegistry)));
        splitter = new FeeSplitter(treasury);
        factory = new BasketFactory(CuratorRegistry(address(registry)), splitter, address(curatorGuardian));
        splitter.initFactory(address(factory));

        vim.transfer(curator, 100_000e18);
        vim.transfer(curatorV2, 100_000e18);

        tokenA = new MockERC20("Token A", "A");
        tokenB = new MockERC20("Token B", "B");
    }

    function _burnV1(address who) internal {
        vm.startPrank(who);
        vim.approve(address(registry), V1);
        registry.burnForLicense();
        vm.stopPrank();
    }

    function _burnV2(address who) internal {
        vm.startPrank(who);
        vim.approve(address(registry), V2);
        registry.burnForLicenseV2();
        vm.stopPrank();
    }

    function _createBasket(BasketFactory f, address who) internal returns (BasketToken basket) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory units = new uint256[](2);
        units[0] = 1e18;
        units[1] = 5e17;
        vm.prank(who);
        basket = BasketToken(f.createBasket("Chip War", "CHIPW", tokens, units, 30, 1_000e18));
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

    // ------------------------------------------------------------- constants

    function test_constants() public view {
        assertEq(registry.LICENSE_BURN_V1(), 10_000e18);
        assertEq(registry.LICENSE_BURN_V2(), 25_000e18);
    }

    function test_constructor_revert_zeroAddress() public {
        vm.expectRevert(CuratorRegistry2.ZeroAddress.selector);
        new CuratorRegistry2(IVimBurnable(address(0)), ILegacyRegistry(address(legacyRegistry)));
        vm.expectRevert(CuratorRegistry2.ZeroAddress.selector);
        new CuratorRegistry2(IVimBurnable(address(vim)), ILegacyRegistry(address(0)));
    }

    // --------------------------------------------------------------- V1 tier

    function test_burnV1_burnsExactly10k() public {
        uint256 supplyBefore = vim.totalSupply();
        vm.startPrank(curator);
        vim.approve(address(registry), V1);
        vm.expectEmit(true, false, false, true);
        emit LicenseBurned(curator, V1);
        registry.burnForLicense();
        vm.stopPrank();
        assertEq(vim.totalSupply(), supplyBefore - V1);
        assertTrue(registry.isLicensed(curator));
        assertFalse(registry.isLicensedV2(curator));
    }

    function test_burnV1_revert_withoutApproval() public {
        vm.prank(curator);
        vm.expectRevert(); // ERC20InsufficientAllowance
        registry.burnForLicense();
        assertFalse(registry.isLicensed(curator));
    }

    function test_burnV1_revert_double() public {
        _burnV1(curator);
        vm.startPrank(curator);
        vim.approve(address(registry), V1);
        vm.expectRevert(CuratorRegistry2.AlreadyLicensed.selector);
        registry.burnForLicense();
        vm.stopPrank();
    }

    function test_burnV1_revert_whenAlreadyV2() public {
        _burnV2(curatorV2);
        vm.startPrank(curatorV2);
        vim.approve(address(registry), V1);
        vm.expectRevert(CuratorRegistry2.AlreadyLicensed.selector);
        registry.burnForLicense();
        vm.stopPrank();
    }

    function test_burnV1_revert_whenLegacyLicensed() public {
        // a legacy licensee already holds V1 (and V2): the 10k burn would buy nothing
        vm.startPrank(legacyCurator);
        vim.approve(address(registry), V1);
        vm.expectRevert(CuratorRegistry2.AlreadyLicensed.selector);
        registry.burnForLicense();
        vm.stopPrank();
    }

    // --------------------------------------------------------------- V2 tier

    function test_burnV2_burnsExactly25k_impliesV1() public {
        uint256 supplyBefore = vim.totalSupply();
        vm.startPrank(curatorV2);
        vim.approve(address(registry), V2);
        vm.expectEmit(true, false, false, true);
        emit LicenseBurned(curatorV2, V2);
        registry.burnForLicenseV2();
        vm.stopPrank();
        assertEq(vim.totalSupply(), supplyBefore - V2);
        assertTrue(registry.isLicensedV2(curatorV2));
        assertTrue(registry.isLicensed(curatorV2)); // V2 includes V1
    }

    function test_burnV2_afterV1_burnsFull25k() public {
        // tiers are flat constants, not a top-up: V1 then V2 = 35k total
        _burnV1(curator);
        uint256 supplyBefore = vim.totalSupply();
        _burnV2(curator);
        assertEq(vim.totalSupply(), supplyBefore - V2);
        assertTrue(registry.isLicensedV2(curator));
    }

    function test_burnV2_revert_double() public {
        _burnV2(curatorV2);
        vm.startPrank(curatorV2);
        vim.approve(address(registry), V2);
        vm.expectRevert(CuratorRegistry2.AlreadyLicensed.selector);
        registry.burnForLicenseV2();
        vm.stopPrank();
    }

    function test_burnV2_revert_whenLegacyLicensed() public {
        vm.startPrank(legacyCurator);
        vim.approve(address(registry), V2);
        vm.expectRevert(CuratorRegistry2.AlreadyLicensed.selector);
        registry.burnForLicenseV2();
        vm.stopPrank();
    }

    // -------------------------------------------------------- grandfathering

    function test_legacyLicensee_hasBothTiers_withoutBurning() public view {
        assertTrue(registry.isLicensed(legacyCurator));
        assertTrue(registry.isLicensedV2(legacyCurator)); // paid 25k = today's V2 price
    }

    function test_unlicensed_hasNeitherTier() public view {
        assertFalse(registry.isLicensed(curator));
        assertFalse(registry.isLicensedV2(curator));
    }

    // ------------------------------------------------- publishing (new factory)

    function test_newV1Curator_publishesOnNewFactory() public {
        _burnV1(curator);
        BasketToken basket = _createBasket(factory, curator);
        assertEq(factory.curatorOf(address(basket)), curator);
        assertEq(basket.guardian(), address(curatorGuardian));
        assertEq(basket.feeRecipient(), address(splitter));
    }

    function test_newV2Curator_publishesOnNewFactory() public {
        _burnV2(curatorV2);
        _createBasket(factory, curatorV2);
    }

    function test_legacyCurator_publishesOnNewFactory_withoutNewBurn() public {
        _createBasket(factory, legacyCurator);
    }

    function test_unlicensed_revert_onNewFactory() public {
        vm.expectRevert(BasketFactory.NotLicensed.selector);
        _createBasket(factory, curator);
    }

    function test_newV1Curator_revert_onLegacyFactory() public {
        // a 10k license does NOT open the old 25k-gated factory
        _burnV1(curator);
        vm.expectRevert(BasketFactory.NotLicensed.selector);
        _createBasket(legacyFactory, curator);
    }

    function test_legacyFactory_keepsWorking() public {
        BasketToken basket = _createBasket(legacyFactory, legacyCurator);
        assertEq(legacyFactory.curatorOf(address(basket)), legacyCurator);
    }

    // ------------------------------------------------------ fees & guardian

    function test_newSplitter_pays60_40() public {
        _burnV1(curator);
        BasketToken basket = _createBasket(factory, curator);
        _mint(basket, minter, 100e18);

        uint256 fee = (100e18 * 30) / 10_000;
        assertEq(basket.balanceOf(address(splitter)), fee);

        splitter.distribute(address(basket));
        assertEq(basket.balanceOf(curator), (fee * 6_000) / 10_000);
        assertEq(basket.balanceOf(treasury), fee - (fee * 6_000) / 10_000);
    }

    function test_sharedGuardian_raisesCapOnBothFactories() public {
        _burnV1(curator);
        BasketToken newBasket = _createBasket(factory, curator);
        BasketToken oldBasket = _createBasket(legacyFactory, legacyCurator);

        vm.startPrank(protocolSafe);
        curatorGuardian.raiseCap(IBasketCap(address(newBasket)), 5_000e18);
        curatorGuardian.raiseCap(IBasketCap(address(oldBasket)), 5_000e18);
        vm.stopPrank();

        assertEq(newBasket.supplyCap(), 5_000e18);
        assertEq(oldBasket.supplyCap(), 5_000e18);
    }

    // registry holds no funds, ever
    function test_registry_neverHoldsVim() public {
        _burnV1(curator);
        _burnV2(curatorV2);
        assertEq(vim.balanceOf(address(registry)), 0);
    }
}
