// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BasketToken2, IAggregatorV3} from "../src/BasketToken2.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {MakerRegistry} from "../src/MakerRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {
    MockUSDG, MockFeed, MockMaker, PartialPullMaker, ThiefMaker, ReentrantMaker
} from "./mocks/AgenticMocks.sol";

/// BasketToken2: V1's mint/redeem core plus the policy-bounded agentic
/// rebalance. The suite drives the happy paths, then attacks every policy
/// line with hostile makers, hostile agents and dead feeds.
contract Basket2Test is Test {
    AssetRegistry registry;
    MakerRegistry makers;
    BasketToken2 basket;

    MockERC20 tokenA; // $100
    MockERC20 tokenB; // $200
    MockERC20 tokenC; // $50
    MockUSDG usdg; // $1, 6 decimals
    MockFeed feedA;
    MockFeed feedB;
    MockFeed feedC;
    MockFeed usdgFeed;
    MockMaker maker;

    address safe = makeAddr("safe");
    address guardian = makeAddr("guardian");
    address curator = makeAddr("curator");
    address agent = makeAddr("agent");
    address minter = makeAddr("minter");
    address feeSink = makeAddr("feeSink");
    address distributor = makeAddr("distributor");

    uint256 constant SUPPLY = 100e18; // minted in setUp
    // units: 1 A + 0.5 B per basket => $100 + $100 = $200 NAV/basket, $20k total

    function setUp() public {
        registry = new AssetRegistry(safe);
        makers = new MakerRegistry(safe);

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        tokenC = new MockERC20("C", "C");
        usdg = new MockUSDG();
        feedA = new MockFeed(100e8);
        feedB = new MockFeed(200e8);
        feedC = new MockFeed(50e8);
        usdgFeed = new MockFeed(1e8);
        maker = new MockMaker();

        vm.startPrank(safe);
        registry.addAsset(address(tokenA), address(feedA), 86400);
        registry.addAsset(address(tokenB), address(feedB), 86400);
        registry.addAsset(address(tokenC), address(feedC), 86400);
        makers.addMaker(address(maker), "honest");
        vm.stopPrank();

        basket = _deploy();
        basket.initDistributor(distributor);
        _mintBasket(minter, SUPPLY);
    }

    function _deploy() internal returns (BasketToken2) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory units = new uint256[](2);
        units[0] = 1e18;
        units[1] = 5e17;
        return new BasketToken2(
            BasketToken2.Init({
                name: "Agentic",
                symbol: "AGNT",
                tokens: tokens,
                unitsPerBasket: units,
                mintFeeBps: 30,
                feeRecipient: feeSink,
                guardian: guardian,
                maxSupplyCap: 1_000_000e18,
                initialSupplyCap: 1_000e18,
                curator: curator,
                agent: agent
            }),
            _wiring(),
            _policy()
        );
    }

    function _wiring() internal view returns (BasketToken2.Wiring memory) {
        return BasketToken2.Wiring({
            assetRegistry: registry,
            makerRegistry: makers,
            usdg: IERC20(address(usdg)),
            usdgFeed: IAggregatorV3(address(usdgFeed)),
            usdgHeartbeat: 86400
        });
    }

    function _policy() internal pure returns (BasketToken2.Policy memory) {
        return BasketToken2.Policy({
            rebalanceCooldown: 1 days,
            maxTurnoverBps: 2_500, // 25% of NAV
            maxSlippageBps: 100, // 1% of NAV
            minShareBalance: 1e18
        });
    }

    function _mintBasket(address user, uint256 amount) internal {
        (, uint256[] memory required) = basket.getRequiredUnits(amount);
        tokenA.mint(user, required[0]);
        tokenB.mint(user, required[1]);
        vm.startPrank(user);
        tokenA.approve(address(basket), required[0]);
        tokenB.approve(address(basket), required[1]);
        basket.mint(amount, user);
        vm.stopPrank();
    }

    function _sell(address token, uint256 amount, uint256 usdgOut, address mkr)
        internal
        pure
        returns (BasketToken2.TradeLeg memory)
    {
        return BasketToken2.TradeLeg({
            isBuy: false,
            token: token,
            amount: amount,
            usdgAmount: usdgOut,
            maker: mkr,
            data: abi.encodeCall(MockMaker.swap, (token, amount, address(0), usdgOut))
        });
    }

    // data must name the real token addresses; helper for correct calldata
    function _sellData(address token, uint256 amount, uint256 usdgOut, address mkr)
        internal
        view
        returns (BasketToken2.TradeLeg memory leg)
    {
        leg = _sell(token, amount, usdgOut, mkr);
        leg.data = abi.encodeCall(MockMaker.swap, (token, amount, address(usdg), usdgOut));
    }

    function _buyData(address token, uint256 amountOut, uint256 usdgIn, address mkr)
        internal
        view
        returns (BasketToken2.TradeLeg memory)
    {
        return BasketToken2.TradeLeg({
            isBuy: true,
            token: token,
            amount: amountOut,
            usdgAmount: usdgIn,
            maker: mkr,
            data: abi.encodeCall(MockMaker.swap, (address(usdg), usdgIn, token, amountOut))
        });
    }

    function _tokensOf(address a, address b) internal pure returns (address[] memory t) {
        t = new address[](2);
        t[0] = a;
        t[1] = b;
    }

    function _tokensOf(address a, address b, address c) internal pure returns (address[] memory t) {
        t = new address[](3);
        t[0] = a;
        t[1] = b;
        t[2] = c;
    }

    function _warp() internal {
        vm.warp(block.timestamp + 1 days + 1);
        // keep the feeds fresh after warping past their heartbeat
        feedA.set(100e8, block.timestamp);
        feedB.set(200e8, block.timestamp);
        feedC.set(50e8, block.timestamp);
        usdgFeed.set(1e8, block.timestamp);
    }

    // --------------------------------------------------------- V1 semantics

    function test_mint_and_redeem_v1Semantics() public {
        uint256 fee = (10e18 * 30) / 10_000;
        _mintBasket(minter, 10e18);
        assertEq(basket.balanceOf(feeSink) > 0, true);

        uint256 aBefore = tokenA.balanceOf(minter);
        vm.prank(minter);
        basket.redeem(10e18 - fee, minter);
        assertEq(tokenA.balanceOf(minter) - aBefore, 10e18 - fee); // 1 unit A per basket
        assertTrue(basket.isFullyBacked());
    }

    function test_redeem_works_with_dead_feeds_and_paused_mint() public {
        // every trust property of V1 must survive: kill all feeds, pause mint
        feedA.set(0, 1);
        feedB.set(0, 1);
        usdgFeed.set(0, 1);
        vm.prank(guardian);
        basket.setMintPaused(true);

        vm.prank(minter);
        basket.redeem(1e18, minter); // no oracle involved, no gate
        assertTrue(basket.isFullyBacked());
    }

    // ------------------------------------------------------------ happy path

    function test_rebalance_sellBuy_adoptsRecipe() public {
        _warp();
        // sell 10 A ($1000) -> 1000 USDG -> buy 20 C ($1000)
        usdg.mint(address(maker), 1_000e6);
        tokenC.mint(address(maker), 20e18);

        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](2);
        legs[0] = _sellData(address(tokenA), 10e18, 1_000e6, address(maker));
        legs[1] = _buyData(address(tokenC), 20e18, 1_000e6, address(maker));

        vm.prank(agent);
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB), address(tokenC)));

        address[] memory tokens = basket.constituents();
        uint256[] memory units = basket.units();
        assertEq(tokens.length, 3);
        assertEq(units[0], 9e17); // 90 A / 100 supply
        assertEq(units[1], 5e17);
        assertEq(units[2], 2e17); // 20 C / 100 supply
        assertTrue(basket.isFullyBacked());
        assertEq(usdg.balanceOf(address(basket)), 0);

        // redeem against the NEW recipe
        vm.prank(minter);
        basket.redeem(10e18, minter);
        assertEq(tokenC.balanceOf(minter), 2e18);
    }

    function test_rebalance_incomeSweep_fundsDistributor() public {
        _warp();
        usdg.mint(address(maker), 1_000e6);

        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](1);
        legs[0] = _sellData(address(tokenA), 10e18, 1_000e6, address(maker));

        vm.prank(agent);
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB)));

        assertEq(usdg.balanceOf(distributor), 1_000e6); // surplus belongs to holders
        assertEq(usdg.balanceOf(address(basket)), 0);
        assertTrue(basket.isFullyBacked());
    }

    function test_rebalance_dropToken_afterFullExit() public {
        // acquire a small C position, then drop it entirely next epoch
        // (the first scenario ends with a 10-basket redeem, so 18 C remain)
        test_rebalance_sellBuy_adoptsRecipe();
        _warp();
        usdg.mint(address(maker), 900e6);

        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](1);
        legs[0] = _sellData(address(tokenC), 18e18, 900e6, address(maker));

        vm.prank(agent);
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB)));
        assertEq(basket.constituents().length, 2);
        assertEq(tokenC.balanceOf(address(basket)), 0);
    }

    function test_rebalance_preexistingUsdgDonation_notSwept() public {
        usdg.mint(address(basket), 500e6); // donation: sits, is not holder income
        _warp();
        usdg.mint(address(maker), 1_000e6);

        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](1);
        legs[0] = _sellData(address(tokenA), 10e18, 1_000e6, address(maker));
        vm.prank(agent);
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB)));

        assertEq(usdg.balanceOf(distributor), 1_000e6); // only the surplus
        assertEq(usdg.balanceOf(address(basket)), 500e6);
    }

    // ---------------------------------------------------------------- policy

    function test_rebalance_revert_beforeCooldown() public {
        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](0);
        vm.prank(agent);
        vm.expectRevert(BasketToken2.CooldownActive.selector);
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB)));
    }

    function test_rebalance_revert_turnoverExceeded() public {
        _warp();
        usdg.mint(address(maker), 6_000e6);
        // NAV $20k, cap 25% = $5k; selling 60 A = $6k
        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](1);
        legs[0] = _sellData(address(tokenA), 60e18, 6_000e6, address(maker));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(BasketToken2.TurnoverExceeded.selector, 6_000e18, 5_000e18));
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB)));
    }

    function test_rebalance_revert_navInvariant() public {
        _warp();
        // sell $5000 of A for $4700: $300 loss > 1% of $20k NAV ($200)
        usdg.mint(address(maker), 4_700e6);
        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](1);
        legs[0] = _sellData(address(tokenA), 50e18, 4_700e6, address(maker));
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(BasketToken2.NavInvariantBroken.selector, 20_000e18, 15_000e18, 4_700e6)
        );
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB)));
    }

    function test_rebalance_slippageWithinBudget_passes() public {
        _warp();
        // $150 loss on a $5000 sale: within the $200 NAV budget
        usdg.mint(address(maker), 4_850e6);
        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](1);
        legs[0] = _sellData(address(tokenA), 50e18, 4_850e6, address(maker));
        vm.prank(agent);
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB)));
        assertEq(usdg.balanceOf(distributor), 4_850e6);
    }

    function test_rebalance_revert_removedTokenHasBalance() public {
        _warp();
        usdg.mint(address(maker), 1_000e6);
        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](1);
        legs[0] = _sellData(address(tokenA), 10e18, 1_000e6, address(maker));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(BasketToken2.RemovedTokenHasBalance.selector, address(tokenA)));
        basket.rebalance(legs, _tokensOf(address(tokenB), address(tokenC)));
    }

    function test_rebalance_revert_sellNonConstituent() public {
        _warp();
        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](1);
        legs[0] = _sellData(address(tokenC), 1e18, 50e6, address(maker));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(BasketToken2.NotAConstituent.selector, address(tokenC)));
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB)));
    }

    function test_rebalance_revert_buyDisabledAsset_sellStillAllowed() public {
        _warp();
        vm.prank(safe);
        registry.setEnabled(address(tokenC), false);

        usdg.mint(address(maker), 1_000e6);
        tokenC.mint(address(maker), 20e18);
        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](2);
        legs[0] = _sellData(address(tokenA), 10e18, 1_000e6, address(maker));
        legs[1] = _buyData(address(tokenC), 20e18, 1_000e6, address(maker));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(BasketToken2.AssetNotBuyable.selector, address(tokenC)));
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB), address(tokenC)));

        // selling OUT of a disabled asset must stay open: disable A, sell A
        vm.prank(safe);
        registry.setEnabled(address(tokenA), false);
        BasketToken2.TradeLeg[] memory sellOnly = new BasketToken2.TradeLeg[](1);
        sellOnly[0] = _sellData(address(tokenA), 10e18, 1_000e6, address(maker));
        vm.prank(agent);
        basket.rebalance(sellOnly, _tokensOf(address(tokenA), address(tokenB)));
    }

    function test_rebalance_revert_unregisteredMakerOrDisabled() public {
        _warp();
        MockMaker rogue = new MockMaker();
        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](1);
        legs[0] = _sellData(address(tokenA), 10e18, 1_000e6, address(rogue));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(BasketToken2.MakerNotRegistered.selector, address(rogue)));
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB)));

        vm.prank(safe);
        makers.setEnabled(address(maker), false);
        legs[0] = _sellData(address(tokenA), 10e18, 1_000e6, address(maker));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(BasketToken2.MakerNotRegistered.selector, address(maker)));
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB)));
    }

    function test_rebalance_revert_staleFeed() public {
        // past heartbeat (1d) plus the 1h grace, feeds NOT refreshed
        vm.warp(block.timestamp + 1 days + 1 hours + 2);
        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](0);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(BasketToken2.StalePrice.selector, address(feedA)));
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB)));
    }

    // ------------------------------------------------------ hostile makers

    function test_rebalance_revert_partialPullMaker() public {
        _warp();
        PartialPullMaker bad = new PartialPullMaker();
        vm.prank(safe);
        makers.addMaker(address(bad), "partial");
        usdg.mint(address(bad), 1_000e6);

        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](1);
        legs[0] = _sellData(address(tokenA), 10e18, 1_000e6, address(bad));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(BasketToken2.LegUnderfilled.selector, 0));
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB)));
    }

    function test_rebalance_revert_thiefMaker_viaMinOut() public {
        _warp();
        ThiefMaker thief = new ThiefMaker();
        vm.prank(safe);
        makers.addMaker(address(thief), "thief");

        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](1);
        legs[0] = _sellData(address(tokenA), 10e18, 1_000e6, address(thief));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(BasketToken2.LegUnderfilled.selector, 0));
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB)));
    }

    function test_rebalance_revert_thiefMaker_viaNavInvariant_whenMinOutZero() public {
        _warp();
        ThiefMaker thief = new ThiefMaker();
        vm.prank(safe);
        makers.addMaker(address(thief), "thief");

        // colluding agent sets minOut=0: the theft must still die on the NAV floor
        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](1);
        legs[0] = _sellData(address(tokenA), 10e18, 0, address(thief));
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(BasketToken2.NavInvariantBroken.selector, 20_000e18, 19_000e18, 0)
        );
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB)));
    }

    function test_rebalance_revert_reentrantMaker() public {
        _warp();
        ReentrantMaker reentrant = new ReentrantMaker();
        vm.prank(safe);
        makers.addMaker(address(reentrant), "reentrant");
        usdg.mint(address(reentrant), 1_000e6);

        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](1);
        legs[0] = _sellData(address(tokenA), 10e18, 1_000e6, address(reentrant));
        legs[0].data = abi.encodeCall(MockMaker.swap, (address(tokenA), 10e18, address(usdg), 1_000e6));

        reentrant.setMode(ReentrantMaker.Mode.REDEEM);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(BasketToken2.MakerCallFailed.selector, 0));
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB)));

        reentrant.setMode(ReentrantMaker.Mode.REBALANCE);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(BasketToken2.MakerCallFailed.selector, 0));
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB)));
    }

    // ----------------------------------------------------------------- roles

    function test_rebalance_revert_notAgent() public {
        _warp();
        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](0);
        vm.prank(curator);
        vm.expectRevert(BasketToken2.NotAgent.selector);
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB)));
    }

    function test_setAgent_onlyCurator_andRotates() public {
        address newAgent = makeAddr("newAgent");
        vm.prank(agent);
        vm.expectRevert(BasketToken2.NotCurator.selector);
        basket.setAgent(newAgent);

        vm.prank(curator);
        basket.setAgent(newAgent);

        _warp();
        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](0);
        vm.prank(agent); // the OLD key is dead
        vm.expectRevert(BasketToken2.NotAgent.selector);
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB)));
        vm.prank(newAgent);
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB)));
    }

    function test_initDistributor_onceAndDeployerOnly() public {
        BasketToken2 fresh = _deploy();
        vm.prank(curator);
        vm.expectRevert(BasketToken2.NotDeployer.selector);
        fresh.initDistributor(distributor);

        fresh.initDistributor(distributor); // this test contract deployed it
        vm.expectRevert(BasketToken2.AlreadyInitialized.selector);
        fresh.initDistributor(distributor);
    }

    function test_rebalance_revert_zeroSupplyOrNoDistributor() public {
        BasketToken2 fresh = _deploy();
        fresh.initDistributor(distributor);
        vm.warp(block.timestamp + 1 days + 1);
        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](0);
        vm.prank(agent);
        vm.expectRevert(BasketToken2.ZeroSupply.selector);
        fresh.rebalance(legs, _tokensOf(address(tokenA), address(tokenB)));
    }

    // ------------------------------------------------------- holder registry

    function test_holderRegistry_tracksAboveThreshold() public view {
        // minter only: the 0.3 fee at feeSink sits below the 1.0 minShare
        assertEq(basket.holderCount(), 1);
        assertEq(basket.holderAt(0), minter);
    }

    function test_holderRegistry_addAndRemove() public {
        address a = makeAddr("walletA");
        vm.prank(minter);
        basket.transfer(a, 2e18);
        uint256 before = basket.holderCount();
        vm.prank(a);
        basket.transfer(minter, 2e18); // drops below minShare
        assertEq(basket.holderCount(), before - 1);
    }

    // -------------------------------------------------------------- guardian

    function test_guardian_powers_matchV1() public {
        vm.prank(guardian);
        basket.setSupplyCap(2_000e18);
        assertEq(basket.supplyCap(), 2_000e18);

        vm.prank(guardian);
        vm.expectRevert(BasketToken2.CapExceedsMax.selector);
        basket.setSupplyCap(2_000_000e18);

        vm.prank(minter);
        vm.expectRevert(BasketToken2.NotGuardian.selector);
        basket.setMintPaused(true);
    }

    // ---------------------------------------------------------- constructor

    function test_constructor_revert_unregisteredToken() public {
        MockERC20 rogue = new MockERC20("R", "R");
        address[] memory tokens = _tokensOf(address(tokenA), address(rogue));
        uint256[] memory units = new uint256[](2);
        units[0] = 1e18;
        units[1] = 1e18;
        vm.expectRevert(abi.encodeWithSelector(BasketToken2.AssetNotRegistered.selector, address(rogue)));
        new BasketToken2(
            BasketToken2.Init({
                name: "X",
                symbol: "X",
                tokens: tokens,
                unitsPerBasket: units,
                mintFeeBps: 30,
                feeRecipient: feeSink,
                guardian: guardian,
                maxSupplyCap: 1e24,
                initialSupplyCap: 1e21,
                curator: curator,
                agent: agent
            }),
            _wiring(),
            _policy()
        );
    }

    // ------------------------------------------------------------------ fuzz

    /// After ANY policy-passing rebalance, the basket is fully backed and
    /// redeem returns the recomputed pro-rata backing — for every trade size
    /// and every spread inside the budget.
    function testFuzz_rebalance_backingAndRedeemAlwaysHold(uint256 sellA, uint256 spreadBps) public {
        sellA = bound(sellA, 1e15, 45e18); // up to $4.5k of A (turnover cap $5k)
        spreadBps = bound(spreadBps, 0, 90); // up to 0.9% of traded value

        _warp();
        // fair proceeds $100/A minus the spread, half re-bought into C
        uint256 fair6 = (sellA * 100e6) / 1e18;
        uint256 out6 = fair6 - (fair6 * spreadBps) / 10_000;
        uint256 buyUsdg = out6 / 2;
        uint256 cOut = (buyUsdg * 1e18) / 50e6; // C at $50, priced exactly fair
        vm.assume(buyUsdg > 0 && cOut > 0);
        usdg.mint(address(maker), out6);
        tokenC.mint(address(maker), cOut);

        BasketToken2.TradeLeg[] memory legs = new BasketToken2.TradeLeg[](2);
        legs[0] = _sellData(address(tokenA), sellA, out6, address(maker));
        legs[1] = _buyData(address(tokenC), cOut, buyUsdg, address(maker));
        vm.prank(agent);
        basket.rebalance(legs, _tokensOf(address(tokenA), address(tokenB), address(tokenC)));

        assertTrue(basket.isFullyBacked());
        // the un-bought USDG half went to holders, not into limbo
        assertEq(usdg.balanceOf(distributor), out6 - buyUsdg);
        assertEq(usdg.balanceOf(address(basket)), 0);

        // redeem still works and pays the NEW backing
        (, uint256[] memory backing) = basket.backingOf(10e18);
        uint256 cBefore = tokenC.balanceOf(minter);
        vm.prank(minter);
        basket.redeem(10e18, minter);
        assertEq(tokenC.balanceOf(minter) - cBefore, backing[2]);
        assertTrue(basket.isFullyBacked());
    }

    function test_constructor_revert_policyOutOfBounds() public {
        address[] memory tokens = _tokensOf(address(tokenA), address(tokenB));
        uint256[] memory units = new uint256[](2);
        units[0] = 1e18;
        units[1] = 1e18;
        BasketToken2.Policy memory loose = _policy();
        loose.maxTurnoverBps = 5_000; // above the 2500 ceiling
        vm.expectRevert(BasketToken2.PolicyOutOfBounds.selector);
        new BasketToken2(
            BasketToken2.Init({
                name: "X",
                symbol: "X",
                tokens: tokens,
                unitsPerBasket: units,
                mintFeeBps: 30,
                feeRecipient: feeSink,
                guardian: guardian,
                maxSupplyCap: 1e24,
                initialSupplyCap: 1e21,
                curator: curator,
                agent: agent
            }),
            _wiring(),
            loose
        );
    }
}
