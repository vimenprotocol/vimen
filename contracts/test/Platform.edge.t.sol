// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VimenToken} from "./mocks/VimenToken.sol";
import {CuratorRegistry, IVimBurnable} from "../src/CuratorRegistry.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {BasketFactory} from "../src/BasketFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// Edge-case coverage for the burn-for-license platform contracts:
/// constructor guards, one-shot wiring, and fee-split rounding.
contract PlatformEdgeTest is Test {
    VimenToken vim;
    CuratorRegistry registry;
    address treasury = makeAddr("treasury");
    address guardian = makeAddr("guardian");
    address curator = makeAddr("curator");

    function setUp() public {
        vim = new VimenToken(address(this));
        registry = new CuratorRegistry(IVimBurnable(address(vim)));
        vim.transfer(curator, 100_000e18);
    }

    // --------------------------------------------------------- constructors

    function test_registry_revert_zeroToken() public {
        vm.expectRevert(CuratorRegistry.ZeroAddress.selector);
        new CuratorRegistry(IVimBurnable(address(0)));
    }

    function test_splitter_revert_zeroTreasury() public {
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        new FeeSplitter(address(0));
    }

    function test_factory_revert_zeroArgs() public {
        FeeSplitter s = new FeeSplitter(treasury);
        vm.expectRevert(BasketFactory.ZeroAddress.selector);
        new BasketFactory(CuratorRegistry(address(0)), s, guardian);
        vm.expectRevert(BasketFactory.ZeroAddress.selector);
        new BasketFactory(registry, FeeSplitter(address(0)), guardian);
        vm.expectRevert(BasketFactory.ZeroAddress.selector);
        new BasketFactory(registry, s, address(0));
    }

    // ------------------------------------------------------------ wiring

    function test_splitter_initFactory_guards() public {
        FeeSplitter s = new FeeSplitter(treasury);
        vm.expectRevert(FeeSplitter.NotDeployer.selector);
        vm.prank(curator);
        s.initFactory(address(1));
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        s.initFactory(address(0));
        s.initFactory(address(1));
        vm.expectRevert(FeeSplitter.AlreadyInitialized.selector);
        s.initFactory(address(2));
    }

    function test_splitter_register_onlyFactory() public {
        FeeSplitter s = new FeeSplitter(treasury);
        s.initFactory(address(this)); // act as the factory
        s.register(address(0xB1), curator);
        assertEq(s.curatorOf(address(0xB1)), curator);
        vm.expectRevert(FeeSplitter.NotFactory.selector);
        vm.prank(curator);
        s.register(address(0xB2), curator);
    }

    // ------------------------------------------------------------ splitter

    function test_distribute_zeroBalance_noop() public {
        FeeSplitter s = new FeeSplitter(treasury);
        s.initFactory(address(this));
        MockERC20 fakeBasket = new MockERC20("B", "B");
        s.register(address(fakeBasket), curator);
        s.distribute(address(fakeBasket)); // no revert, no transfers
        assertEq(fakeBasket.balanceOf(treasury), 0);
        assertEq(fakeBasket.balanceOf(curator), 0);
    }

    function test_distribute_oneWei_allToTreasury() public {
        FeeSplitter s = new FeeSplitter(treasury);
        s.initFactory(address(this));
        MockERC20 fakeBasket = new MockERC20("B", "B");
        s.register(address(fakeBasket), curator);
        fakeBasket.mint(address(s), 1); // 60% of 1 wei floors to 0
        s.distribute(address(fakeBasket));
        assertEq(fakeBasket.balanceOf(curator), 0);
        assertEq(fakeBasket.balanceOf(treasury), 1);
    }

    function test_distribute_unknownBasket_reverts() public {
        FeeSplitter s = new FeeSplitter(treasury);
        s.initFactory(address(this));
        vm.expectRevert(FeeSplitter.UnknownBasket.selector);
        s.distribute(address(0xDEAD));
    }

    // ------------------------------------------------------------ license

    function test_burnForLicense_burnsExactAndIsPermanent() public {
        uint256 supplyBefore = vim.totalSupply();
        vm.startPrank(curator);
        vim.approve(address(registry), type(uint256).max);
        registry.burnForLicense();
        vm.stopPrank();
        assertTrue(registry.isLicensed(curator));
        assertEq(vim.totalSupply(), supplyBefore - registry.LICENSE_BURN());
        // allowance left over cannot be used to burn again
        vm.expectRevert(CuratorRegistry.AlreadyLicensed.selector);
        vm.prank(curator);
        registry.burnForLicense();
    }
}
