// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VimenToken} from "./mocks/VimenToken.sol";
import {CuratorRegistry, IVimBurnable} from "../src/CuratorRegistry.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {BasketFactory} from "../src/BasketFactory.sol";
import {CuratorGuardian} from "../src/CuratorGuardian.sol";
import {LogoRegistry} from "../src/LogoRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// LogoRegistry: the curator of a factory basket can point it at a logo URI;
/// nobody else can, and the registry has no other surface at all.
contract LogoRegistryTest is Test {
    VimenToken vim;
    CuratorRegistry registry;
    FeeSplitter splitter;
    CuratorGuardian curatorGuardian;
    BasketFactory factory;
    LogoRegistry logos;

    address treasury = makeAddr("treasury");
    address protocolSafe = makeAddr("protocolSafe");
    address curator = makeAddr("curator");
    address stranger = makeAddr("stranger");

    MockERC20 tokenA;
    MockERC20 tokenB;

    address basket;

    string constant URI = "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";

    function setUp() public {
        vim = new VimenToken(address(this));
        registry = new CuratorRegistry(IVimBurnable(address(vim)));
        splitter = new FeeSplitter(treasury);
        curatorGuardian = new CuratorGuardian(protocolSafe);
        factory = new BasketFactory(registry, splitter, address(curatorGuardian));
        splitter.initFactory(address(factory));
        logos = new LogoRegistry(factory);

        vim.transfer(curator, 25_000e18);
        vm.startPrank(curator);
        vim.approve(address(registry), 25_000e18);
        registry.burnForLicense();
        vm.stopPrank();

        tokenA = new MockERC20("Token A", "A");
        tokenB = new MockERC20("Token B", "B");
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory units = new uint256[](2);
        units[0] = 1e18;
        units[1] = 5e17;
        vm.prank(curator);
        basket = factory.createBasket("Chip War", "CHIPW", tokens, units, 30, 1_000e18);
    }

    function test_constructor_rejectsZeroFactory() public {
        vm.expectRevert(LogoRegistry.ZeroAddress.selector);
        new LogoRegistry(BasketFactory(address(0)));
    }

    function test_curator_setsLogo() public {
        vm.expectEmit(true, true, false, true);
        emit LogoRegistry.LogoSet(basket, curator, URI);
        vm.prank(curator);
        logos.setLogoURI(basket, URI);
        assertEq(logos.logoURI(basket), URI);
    }

    function test_curator_overwritesAndClears() public {
        vm.startPrank(curator);
        logos.setLogoURI(basket, URI);
        logos.setLogoURI(basket, "https://example.com/logo.png");
        assertEq(logos.logoURI(basket), "https://example.com/logo.png");
        logos.setLogoURI(basket, "");
        assertEq(logos.logoURI(basket), "");
        vm.stopPrank();
    }

    function test_stranger_cannotSet() public {
        vm.expectRevert(LogoRegistry.NotCurator.selector);
        vm.prank(stranger);
        logos.setLogoURI(basket, URI);
    }

    function test_unknownBasket_nobodyCanSet() public {
        // curatorOf(random) is zero, and address(0) can never be msg.sender
        vm.expectRevert(LogoRegistry.NotCurator.selector);
        vm.prank(curator);
        logos.setLogoURI(makeAddr("notABasket"), URI);
    }

    function test_uriTooLong_reverts() public {
        bytes memory long = new bytes(logos.MAX_URI_LENGTH() + 1);
        for (uint256 i = 0; i < long.length; i++) long[i] = "a";
        vm.expectRevert(LogoRegistry.UriTooLong.selector);
        vm.prank(curator);
        logos.setLogoURI(basket, string(long));
    }

    function test_uriAtMaxLength_ok() public {
        bytes memory max = new bytes(logos.MAX_URI_LENGTH());
        for (uint256 i = 0; i < max.length; i++) max[i] = "a";
        vm.prank(curator);
        logos.setLogoURI(basket, string(max));
        assertEq(bytes(logos.logoURI(basket)).length, logos.MAX_URI_LENGTH());
    }

    function test_emptyByDefault() public view {
        assertEq(logos.logoURI(basket), "");
    }
}
