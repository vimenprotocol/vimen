// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VimenToken} from "./mocks/VimenToken.sol";
import {CuratorRegistry, IVimBurnable} from "../src/CuratorRegistry.sol";
import {CuratorRegistry2, ILegacyRegistry} from "../src/CuratorRegistry2.sol";
import {CuratorGuardian, IBasketCap} from "../src/CuratorGuardian.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {MakerRegistry} from "../src/MakerRegistry.sol";
import {BasketFactory2} from "../src/BasketFactory2.sol";
import {BasketTokenDeployer} from "../src/BasketTokenDeployer.sol";
import {BasketToken2, IAggregatorV3} from "../src/BasketToken2.sol";
import {BasketDistributor} from "../src/BasketDistributor.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUSDG, MockFeed, MockMaker} from "./mocks/AgenticMocks.sol";

/// The whole V2 shelf, end to end: burn the 25k license, publish an agentic
/// basket through the factory, mint, let the agent harvest income, run a
/// distributor cycle, split the mint fees 60/40 — and check the V1 promises
/// (redeem, backing) held the whole way through.
contract PlatformV2Test is Test {
    VimenToken vim;
    CuratorRegistry legacyRegistry;
    CuratorRegistry2 registry;
    CuratorGuardian guardian;
    FeeSplitter splitter;
    AssetRegistry assets;
    MakerRegistry makers;
    BasketFactory2 factory;

    MockERC20 tokenA; // $100
    MockERC20 tokenB; // $200
    MockUSDG usdg;
    MockFeed feedA;
    MockFeed feedB;
    MockFeed usdgFeed;
    MockMaker maker;

    address treasury = makeAddr("treasury");
    address safe = makeAddr("safe");
    address curator = makeAddr("curator");
    address agent = makeAddr("agent");
    address minter = makeAddr("minter");

    BasketToken2 basket;
    BasketDistributor dist;

    function setUp() public {
        vim = new VimenToken(address(this));
        legacyRegistry = new CuratorRegistry(IVimBurnable(address(vim)));
        registry = new CuratorRegistry2(IVimBurnable(address(vim)), ILegacyRegistry(address(legacyRegistry)));
        guardian = new CuratorGuardian(safe);
        splitter = new FeeSplitter(treasury);
        assets = new AssetRegistry(safe);
        makers = new MakerRegistry(safe);

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        usdg = new MockUSDG();
        feedA = new MockFeed(100e8);
        feedB = new MockFeed(200e8);
        usdgFeed = new MockFeed(1e8);
        maker = new MockMaker();

        vm.startPrank(safe);
        assets.addAsset(address(tokenA), address(feedA), 86400);
        assets.addAsset(address(tokenB), address(feedB), 86400);
        makers.addMaker(address(maker), "honest");
        vm.stopPrank();

        factory = new BasketFactory2(
            registry,
            splitter,
            guardian,
            assets,
            makers,
            IERC20(address(usdg)),
            IAggregatorV3(address(usdgFeed)),
            86400,
            new BasketTokenDeployer()
        );
        splitter.initFactory(address(factory));

        // curator burns the 25k V2 license and publishes
        vim.transfer(curator, 25_000e18);
        vm.startPrank(curator);
        vim.approve(address(registry), 25_000e18);
        registry.burnForLicenseV2();

        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory units = new uint256[](2);
        units[0] = 1e18;
        units[1] = 5e17;
        (address b, address d) = factory.createBasket(
            "Agentic Income",
            "VINC",
            tokens,
            units,
            30,
            1_000e18,
            agent,
            BasketToken2.Policy({
                rebalanceCooldown: 1 days,
                maxTurnoverBps: 2_500,
                maxSlippageBps: 100,
                minShareBalance: 1e18
            }),
            7 days
        );
        vm.stopPrank();
        basket = BasketToken2(b);
        dist = BasketDistributor(d);

        // mint 100 baskets
        (, uint256[] memory required) = basket.getRequiredUnits(100e18);
        tokenA.mint(minter, required[0]);
        tokenB.mint(minter, required[1]);
        vm.startPrank(minter);
        tokenA.approve(address(basket), required[0]);
        tokenB.approve(address(basket), required[1]);
        basket.mint(100e18, minter);
        vm.stopPrank();
    }

    function test_wiring() public view {
        assertEq(factory.curatorOf(address(basket)), curator);
        assertEq(factory.distributorOf(address(basket)), address(dist));
        assertEq(basket.curator(), curator);
        assertEq(basket.agent(), agent);
        assertEq(basket.guardian(), address(guardian));
        assertEq(basket.feeRecipient(), address(splitter));
        assertEq(basket.distributor(), address(dist));
        assertEq(dist.admin(), safe);
        assertTrue(dist.excluded(address(splitter)));
        assertTrue(dist.excluded(address(basket)));
    }

    function test_unlicensed_and_v1Licensee_cannotPublish() public {
        address v1only = makeAddr("v1only");
        vim.transfer(v1only, 10_000e18);
        vm.startPrank(v1only);
        vim.approve(address(registry), 10_000e18);
        registry.burnForLicense(); // V1 tier only
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory units = new uint256[](2);
        units[0] = 1e18;
        units[1] = 1e18;
        vm.expectRevert(BasketFactory2.NotLicensed.selector);
        factory.createBasket(
            "X",
            "X",
            tokens,
            units,
            30,
            1_000e18,
            agent,
            BasketToken2.Policy({
                rebalanceCooldown: 1 days,
                maxTurnoverBps: 2_500,
                maxSlippageBps: 100,
                minShareBalance: 1e18
            }),
            7 days
        );
        vm.stopPrank();
    }

    function test_endToEnd_income_paysHolders_feesSplit() public {
        // agent harvests: sells 10 A ($1000) for 1000 USDG, no re-buy
        vm.warp(block.timestamp + 1 days + 1);
        feedA.set(100e8, block.timestamp);
        feedB.set(200e8, block.timestamp);
        usdgFeed.set(1e8, block.timestamp);
        usdg.mint(address(maker), 1_000e6);

        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](1);
        legs[0] = BasketToken2.TradeLeg({
            isBuy: false,
            token: address(tokenA),
            amount: 10e18,
            usdgAmount: 1_000e6,
            maker: address(maker),
            data: abi.encodeCall(MockMaker.swap, (address(tokenA), 10e18, address(usdg), 1_000e6))
        });
        address[] memory keep = new address[](2);
        keep[0] = address(tokenA);
        keep[1] = address(tokenB);
        vm.prank(agent);
        basket.rebalance(legs, keep);

        assertEq(usdg.balanceOf(address(dist)), 1_000e6);
        assertTrue(basket.isFullyBacked());

        // distributor cycle: minter is the only registered holder (the fee
        // at the splitter is excluded infra)
        dist.startCycle();
        while (dist.phase() == BasketDistributor.Phase.Snapshotting) {
            dist.snapshotBatch(50);
        }
        while (dist.phase() == BasketDistributor.Phase.Paying) {
            dist.distributeBatch(50);
        }
        assertEq(usdg.balanceOf(minter), 1_000e6); // all income to the holder

        // mint fees split 60/40 through the same splitter as V1
        splitter.distribute(address(basket));
        uint256 fee = (100e18 * 30) / 10_000;
        assertEq(basket.balanceOf(curator), (fee * 6_000) / 10_000);
        assertEq(basket.balanceOf(treasury), fee - (fee * 6_000) / 10_000);

        // and the exit stayed unlocked the whole time
        vm.prank(minter);
        basket.redeem(50e18, minter);
        assertTrue(basket.isFullyBacked());
    }

    function test_guardian_raisesCap_onV2Basket() public {
        // the SAME live-guardian code guards V2: cap is its only lever (it
        // simply has no other function that reaches the basket)
        vm.prank(safe);
        guardian.raiseCap(IBasketCap(address(basket)), 5_000e18);
        assertEq(basket.supplyCap(), 5_000e18);

        vm.prank(safe);
        vm.expectRevert(CuratorGuardian.CapNotIncreasing.selector);
        guardian.raiseCap(IBasketCap(address(basket)), 4_000e18); // never down
    }

    function test_factory_minShareBounds() public {
        vm.startPrank(curator);
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory units = new uint256[](2);
        units[0] = 1e18;
        units[1] = 1e18;
        vm.expectRevert(BasketFactory2.MinShareOutOfBounds.selector);
        factory.createBasket(
            "X",
            "X",
            tokens,
            units,
            30,
            1_000e18,
            agent,
            BasketToken2.Policy({
                rebalanceCooldown: 1 days,
                maxTurnoverBps: 2_500,
                maxSlippageBps: 100,
                minShareBalance: 1 // dust threshold: registry bloat vector
            }),
            7 days
        );
        vm.stopPrank();
    }
}
