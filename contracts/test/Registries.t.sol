// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {MakerRegistry} from "../src/MakerRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeed} from "./mocks/AgenticMocks.sol";

/// The two V2 platform gates: the asset universe agents may trade
/// (AssetRegistry, add + disable-only) and the settlement contracts RFQ
/// legs may call (MakerRegistry). Both immutable-admin, no path to funds.
contract RegistriesTest is Test {
    AssetRegistry assets;
    MakerRegistry makers;

    address safe = makeAddr("safe");
    address rando = makeAddr("rando");

    MockERC20 token;
    MockFeed feed; // Chainlink-shaped: addAsset sanity-checks latestRoundData
    MockERC20 maker; // any contract works as a stand-in settlement contract

    function setUp() public {
        assets = new AssetRegistry(safe);
        makers = new MakerRegistry(safe);
        token = new MockERC20("Token", "T");
        feed = new MockFeed(1e8); // live answer, fresh updatedAt
        maker = new MockERC20("Maker", "M");
    }

    // -------------------------------------------------------- AssetRegistry

    function test_assets_constructor_revert_zeroAdmin() public {
        vm.expectRevert(AssetRegistry.ZeroAddress.selector);
        new AssetRegistry(address(0));
    }

    function test_assets_add_registersEnabled() public {
        vm.prank(safe);
        assets.addAsset(address(token), address(feed), 86400);

        assertTrue(assets.isRegistered(address(token)));
        assertTrue(assets.isBuyable(address(token)));
        (address f, uint32 hb, bool enabled) = assets.assetOf(address(token));
        assertEq(f, address(feed));
        assertEq(hb, 86400);
        assertTrue(enabled);
        assertEq(assets.assetCount(), 1);
        assertEq(assets.assetAt(0), address(token));
    }

    function test_assets_add_revert_notAdmin() public {
        vm.prank(rando);
        vm.expectRevert(AssetRegistry.NotAdmin.selector);
        assets.addAsset(address(token), address(feed), 86400);
    }

    function test_assets_add_revert_duplicate() public {
        vm.startPrank(safe);
        assets.addAsset(address(token), address(feed), 86400);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.AlreadyRegistered.selector, address(token)));
        assets.addAsset(address(token), address(feed), 86400);
        vm.stopPrank();
    }

    function test_assets_add_revert_eoaOrZero() public {
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.NotAContract.selector, rando));
        assets.addAsset(rando, address(feed), 86400);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.NotAContract.selector, rando));
        assets.addAsset(address(token), rando, 86400);
        vm.expectRevert(AssetRegistry.ZeroAddress.selector);
        assets.addAsset(address(0), address(feed), 86400);
        vm.expectRevert(AssetRegistry.ZeroHeartbeat.selector);
        assets.addAsset(address(token), address(feed), 0);
        vm.stopPrank();
    }

    function test_assets_add_revert_deadOrStaleFeed() public {
        vm.startPrank(safe);
        // answer <= 0: a feed that reports no price is rejected
        MockFeed dead = new MockFeed(0);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.FeedNotLive.selector, address(dead)));
        assets.addAsset(address(token), address(dead), 86400);
        // stale: last update older than the heartbeat is rejected
        vm.warp(block.timestamp + 100_000);
        MockFeed stale = new MockFeed(1e8);
        stale.set(1e8, block.timestamp - 90_000); // beyond the 86400 heartbeat
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.FeedNotLive.selector, address(stale)));
        assets.addAsset(address(token), address(stale), 86400);
        vm.stopPrank();
    }

    function test_assets_disable_blocksBuys_keepsRegistration() public {
        vm.startPrank(safe);
        assets.addAsset(address(token), address(feed), 86400);
        assets.setEnabled(address(token), false);
        vm.stopPrank();

        assertFalse(assets.isBuyable(address(token)));
        assertTrue(assets.isRegistered(address(token))); // still sellable/pricable
        (,, bool enabled) = assets.assetOf(address(token));
        assertFalse(enabled);

        vm.prank(safe);
        assets.setEnabled(address(token), true);
        assertTrue(assets.isBuyable(address(token)));
    }

    function test_assets_setEnabled_revert_unregistered() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.NotRegistered.selector, address(token)));
        assets.setEnabled(address(token), false);
    }

    function test_assets_unregistered_notBuyable() public {
        assertFalse(assets.isBuyable(address(token)));
        assertFalse(assets.isRegistered(address(token)));
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.NotRegistered.selector, address(token)));
        assets.assetOf(address(token));
    }

    // -------------------------------------------------------- MakerRegistry

    function test_makers_constructor_revert_zeroAdmin() public {
        vm.expectRevert(MakerRegistry.ZeroAddress.selector);
        new MakerRegistry(address(0));
    }

    function test_makers_add_registersEnabled() public {
        vm.prank(safe);
        makers.addMaker(address(maker), "rialto-router-v2");
        assertTrue(makers.isMaker(address(maker)));
        assertEq(makers.makerCount(), 1);
        assertEq(makers.makerAt(0), address(maker));
    }

    function test_makers_add_revert_notAdmin() public {
        vm.prank(rando);
        vm.expectRevert(MakerRegistry.NotAdmin.selector);
        makers.addMaker(address(maker), "x");
    }

    function test_makers_add_revert_eoaAndDuplicate() public {
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(MakerRegistry.NotAContract.selector, rando));
        makers.addMaker(rando, "eoa");
        makers.addMaker(address(maker), "ok");
        vm.expectRevert(abi.encodeWithSelector(MakerRegistry.AlreadyRegistered.selector, address(maker)));
        makers.addMaker(address(maker), "dup");
        vm.stopPrank();
    }

    function test_makers_disable_isInstant_andReversible() public {
        vm.startPrank(safe);
        makers.addMaker(address(maker), "ok");
        makers.setEnabled(address(maker), false);
        vm.stopPrank();
        assertFalse(makers.isMaker(address(maker)));

        vm.prank(safe);
        makers.setEnabled(address(maker), true);
        assertTrue(makers.isMaker(address(maker)));
    }

    function test_makers_setEnabled_revert_unregistered() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(MakerRegistry.NotRegistered.selector, address(maker)));
        makers.setEnabled(address(maker), false);
    }

    function test_makers_unregistered_notMaker() public view {
        assertFalse(makers.isMaker(address(maker)));
    }
}
