// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VimenToken} from "../src/VimenToken.sol";
import {CuratorRegistry} from "../src/CuratorRegistry.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {BasketFactory} from "../src/BasketFactory.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PlatformTest is Test {
    VimenToken vimen;
    CuratorRegistry registry;
    FeeSplitter splitter;
    BasketFactory factory;

    address treasury = makeAddr("treasury");
    address protocolGuardian = makeAddr("protocolGuardian");
    address curator = makeAddr("curator");
    address delegator = makeAddr("delegator");
    address minter = makeAddr("minter");

    MockERC20 tokenA;
    MockERC20 tokenB;

    uint256 constant LICENSE = 25_000e18;
    // accPerShare floors once per pool: max dust = poolStake / 1e18 wei
    uint256 constant DUST = (LICENSE + 40_000e18) / 1e18 + 2;

    function setUp() public {
        vimen = new VimenToken(address(this));
        registry = new CuratorRegistry(vimen);
        splitter = new FeeSplitter(registry, treasury);
        factory = new BasketFactory(registry, splitter, protocolGuardian);
        registry.initSplitter(address(splitter));
        splitter.initFactory(address(factory));

        vimen.transfer(curator, 100_000e18);
        vimen.transfer(delegator, 100_000e18);

        tokenA = new MockERC20("Token A", "A");
        tokenB = new MockERC20("Token B", "B");
    }

    function _license(address who, uint256 amount) internal {
        vm.startPrank(who);
        vimen.approve(address(registry), type(uint256).max);
        registry.stake(who, amount);
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

    // ------------------------------------------------------------ VimenToken

    function test_token_fixedSupplyToDistributor() public {
        VimenToken t = new VimenToken(treasury);
        assertEq(t.totalSupply(), 100_000_000e18);
        assertEq(t.balanceOf(treasury), 100_000_000e18);
        assertEq(t.symbol(), "VIMEN");
    }

    function test_token_revert_zeroDistributor() public {
        vm.expectRevert(VimenToken.ZeroAddress.selector);
        new VimenToken(address(0));
    }

    // ---------------------------------------------------------- license/stake

    function test_license_thresholdExact() public {
        _license(curator, LICENSE - 1);
        assertFalse(registry.isLicensed(curator));
        vm.prank(curator);
        registry.stake(curator, 1);
        assertTrue(registry.isLicensed(curator));
    }

    function test_delegation_ranking() public {
        _license(curator, LICENSE);
        vm.startPrank(delegator);
        vimen.approve(address(registry), type(uint256).max);
        registry.stake(curator, 40_000e18);
        vm.stopPrank();
        assertEq(registry.effectiveStake(curator), LICENSE + 40_000e18);
        assertFalse(registry.isLicensed(delegator));
        // delegation alone never licenses the curator
        assertEq(registry.stakeOf(curator, curator), LICENSE);
    }

    function test_unstake_cooldown() public {
        _license(curator, LICENSE);
        vm.prank(curator);
        registry.requestUnstake(curator, LICENSE);
        assertFalse(registry.isLicensed(curator));
        assertEq(registry.effectiveStake(curator), 0);

        vm.expectRevert(CuratorRegistry.CooldownActive.selector);
        vm.prank(curator);
        registry.withdraw();

        vm.warp(block.timestamp + 7 days);
        uint256 before = vimen.balanceOf(curator);
        vm.prank(curator);
        registry.withdraw();
        assertEq(vimen.balanceOf(curator) - before, LICENSE);
    }

    function test_unstake_revert_insufficient() public {
        _license(curator, LICENSE);
        vm.expectRevert(CuratorRegistry.InsufficientStake.selector);
        vm.prank(curator);
        registry.requestUnstake(curator, LICENSE + 1);
    }

    function test_commission_defaultAndBounds() public {
        assertEq(registry.commissionBps(curator), 2_000);
        vm.expectEmit(true, false, false, true);
        emit CuratorRegistry.CommissionAnnounced(curator, 0, block.timestamp + 7 days);
        vm.prank(curator);
        registry.setCommission(0);
        // announcement only: nothing changes until the timelock elapses
        assertEq(registry.commissionBps(curator), 2_000);
        (uint16 pendingBps, uint64 effectiveAt) = registry.pendingCommission(curator);
        assertEq(pendingBps, 0);
        assertEq(effectiveAt, block.timestamp + registry.COMMISSION_TIMELOCK());
        vm.warp(effectiveAt);
        assertEq(registry.commissionBps(curator), 0);
        vm.expectRevert(CuratorRegistry.CommissionTooHigh.selector);
        vm.prank(curator);
        registry.setCommission(5_001);
    }

    function test_commission_timelock_feeFlowUsesOldRateInWindow() public {
        _license(curator, LICENSE);
        vm.prank(curator);
        registry.setCommission(5_000);

        // fees distributed inside the window still pay the old 20%
        tokenA.mint(address(registry), 100e18);
        vm.prank(address(splitter));
        registry.notifyReward(curator, address(tokenA), 100e18);
        (, uint256[] memory pending) = registry.pendingRewards(curator, curator);
        assertEq(pending[0], 100e18); // sole staker: 20% commission + 80% pro-rata

        // after the timelock the announced 50% applies, without another call
        vm.warp(block.timestamp + registry.COMMISSION_TIMELOCK());
        assertEq(registry.commissionBps(curator), 5_000);
    }

    function test_commission_reannounceRestartsClock() public {
        // literal base time: via-IR rematerializes `block.timestamp` reads at
        // their use sites, so a t0 captured from it goes stale across vm.warp
        uint256 t0 = 1_000_000;
        vm.warp(t0);
        vm.startPrank(curator);
        registry.setCommission(5_000);
        // replacing the announcement before it matures restarts the clock
        vm.warp(t0 + 6 days);
        registry.setCommission(4_000);
        vm.warp(t0 + 7 days); // first announcement would be live now
        assertEq(registry.commissionBps(curator), 2_000);
        vm.warp(t0 + 13 days);
        assertEq(registry.commissionBps(curator), 4_000);

        // a matured announcement is folded into storage (CommissionSet) and
        // survives being replaced by a new pending one
        vm.expectEmit(true, false, false, true);
        emit CuratorRegistry.CommissionSet(curator, 4_000);
        registry.setCommission(1_000);
        assertEq(registry.commissionBps(curator), 4_000);
        vm.stopPrank();
    }

    function testFuzz_commission_window(uint16 newBps, uint256 elapsed) public {
        newBps = uint16(bound(newBps, 0, registry.MAX_COMMISSION_BPS()));
        elapsed = bound(elapsed, 0, 30 days);
        uint256 announcedAt = block.timestamp;
        vm.prank(curator);
        registry.setCommission(newBps);
        vm.warp(announcedAt + elapsed);
        if (elapsed < registry.COMMISSION_TIMELOCK()) {
            assertEq(registry.commissionBps(curator), 2_000);
        } else {
            assertEq(registry.commissionBps(curator), newBps);
        }
    }

    function test_wiring_oneShotInits() public {
        CuratorRegistry r2 = new CuratorRegistry(vimen);
        vm.expectRevert(CuratorRegistry.NotDeployer.selector);
        vm.prank(curator);
        r2.initSplitter(address(1));
        r2.initSplitter(address(1));
        vm.expectRevert(CuratorRegistry.AlreadyInitialized.selector);
        r2.initSplitter(address(2));
    }

    function test_notifyReward_onlySplitter() public {
        vm.expectRevert(CuratorRegistry.NotSplitter.selector);
        registry.notifyReward(curator, address(tokenA), 1e18);
    }

    // -------------------------------------------------------------- factory

    function test_createBasket_requiresLicense() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory units = new uint256[](2);
        units[0] = 1e18;
        units[1] = 1e18;
        vm.expectRevert(BasketFactory.NotLicensed.selector);
        vm.prank(curator);
        factory.createBasket("X", "X", tokens, units, 30, 100e18);
    }

    function test_createBasket_capLimit() public {
        _license(curator, LICENSE);
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory units = new uint256[](2);
        units[0] = 1e18;
        units[1] = 1e18;
        uint256 tooHigh = factory.STARTER_CAP() + 1;
        vm.expectRevert(BasketFactory.CapAboveFactoryLimit.selector);
        vm.prank(curator);
        factory.createBasket("X", "X", tokens, units, 30, tooHigh);
    }

    function test_createBasket_wiring() public {
        _license(curator, LICENSE);
        BasketToken basket = _createBasket();

        assertEq(basket.feeRecipient(), address(splitter));
        assertEq(basket.guardian(), protocolGuardian);
        assertEq(basket.maxSupplyCap(), factory.CEILING());
        assertEq(basket.supplyCap(), 1_000e18);
        assertEq(splitter.curatorOf(address(basket)), curator);
        assertEq(factory.curatorOf(address(basket)), curator);
        assertEq(factory.basketCount(), 1);
        assertEq(factory.allBaskets()[0], address(basket));
    }

    function test_curatedBasket_guardianIsProtocol() public {
        _license(curator, LICENSE);
        BasketToken basket = _createBasket();
        // curator has no guardian powers on their own basket
        vm.expectRevert(BasketToken.NotGuardian.selector);
        vm.prank(curator);
        basket.setMintPaused(true);
        // protocol guardian does
        vm.prank(protocolGuardian);
        basket.setMintPaused(true);
        assertTrue(basket.mintPaused());
    }

    // ------------------------------------------------------------- splitter

    function test_distribute_revert_unknownBasket() public {
        vm.expectRevert(FeeSplitter.UnknownBasket.selector);
        splitter.distribute(address(tokenA));
    }

    function test_register_onlyFactory() public {
        vm.expectRevert(FeeSplitter.NotFactory.selector);
        splitter.register(address(tokenA), curator);
    }

    // ---------------------------------------------------------- end-to-end

    function test_endToEnd_feeFlow() public {
        // curator licenses and publishes; delegator joins the pool 1:4
        _license(curator, LICENSE); // 25k self
        vm.startPrank(delegator);
        vimen.approve(address(registry), type(uint256).max);
        registry.stake(curator, 40_000e18); // pool: 65k total
        vm.stopPrank();

        BasketToken basket = _createBasket();

        // a user mints 1000 baskets → fee = 0.30% = 3e18 basket tokens
        _mint(basket, minter, 1_000e18);
        uint256 fee = (1_000e18 * 30) / 10_000;
        assertEq(basket.balanceOf(address(splitter)), fee);

        uint256 toPool = _assertSplit(basket, fee);
        _assertClaims(basket, toPool);
        _assertRedeemable(basket);
    }

    function _assertSplit(BasketToken basket, uint256 fee) internal returns (uint256 toPool) {
        // permissionless distribution: 60% pool / 40% treasury
        splitter.distribute(address(basket));
        toPool = (fee * 6_000) / 10_000;
        assertEq(basket.balanceOf(treasury), fee - toPool);
        assertEq(basket.balanceOf(address(registry)), toPool);
    }

    function _assertClaims(BasketToken basket, uint256 toPool) internal {
        // curator: 20% commission + 20% of the remaining pro-rata
        uint256 commission = (toPool * 2_000) / 10_000;
        uint256 net = toPool - commission;

        (address[] memory tokens, uint256[] memory pendingCurator) = registry.pendingRewards(curator, curator);
        assertEq(tokens[0], address(basket));
        assertApproxEqAbs(pendingCurator[0], commission + (net * LICENSE) / (LICENSE + 40_000e18), DUST);

        vm.prank(curator);
        registry.claim(curator);
        assertApproxEqAbs(basket.balanceOf(curator), commission + (net * LICENSE) / (LICENSE + 40_000e18), DUST);

        vm.prank(delegator);
        registry.claim(curator);
        assertApproxEqAbs(basket.balanceOf(delegator), (net * 40_000e18) / (LICENSE + 40_000e18), DUST);

        // conservation: nothing minted from thin air, dust stays in registry
        assertLe(basket.balanceOf(curator) + basket.balanceOf(delegator), toPool);
    }

    function _assertRedeemable(BasketToken basket) internal {
        // curator's claimed fee tokens are real backed baskets — redeemable
        uint256 bal = basket.balanceOf(curator);
        vm.prank(curator);
        basket.redeem(bal, curator);
        assertTrue(basket.isFullyBacked());
    }

    function test_lateStaker_getsNothingFromPastFees() public {
        _license(curator, LICENSE);
        BasketToken basket = _createBasket();
        _mint(basket, minter, 1_000e18);
        splitter.distribute(address(basket));

        // delegator arrives after the fees
        vm.startPrank(delegator);
        vimen.approve(address(registry), type(uint256).max);
        registry.stake(curator, 40_000e18);
        vm.stopPrank();

        (, uint256[] memory pending) = registry.pendingRewards(curator, delegator);
        assertEq(pending[0], 0);
    }

    function test_emptyPool_allFeesToCurator() public {
        _license(curator, LICENSE);
        BasketToken basket = _createBasket();
        _mint(basket, minter, 1_000e18);

        // curator exits the pool entirely before distribution
        vm.prank(curator);
        registry.requestUnstake(curator, LICENSE);

        splitter.distribute(address(basket));
        uint256 toPool = ((1_000e18 * 30) / 10_000) * 6_000 / 10_000;
        (, uint256[] memory pending) = registry.pendingRewards(curator, curator);
        assertEq(pending[0], toPool);
    }

    function testFuzz_rewardConservation(uint256 selfStake, uint256 delegated, uint256 mintAmount) public {
        selfStake = bound(selfStake, LICENSE, 90_000e18);
        delegated = bound(delegated, 1, 90_000e18);
        mintAmount = bound(mintAmount, 1e18, 1_000e18);

        _license(curator, selfStake);
        vm.startPrank(delegator);
        vimen.approve(address(registry), type(uint256).max);
        registry.stake(curator, delegated);
        vm.stopPrank();

        BasketToken basket = _createBasket();
        _mint(basket, minter, mintAmount);
        splitter.distribute(address(basket));

        uint256 registryBalance = basket.balanceOf(address(registry));
        vm.prank(curator);
        registry.claim(curator);
        vm.prank(delegator);
        registry.claim(curator);

        uint256 claimed = basket.balanceOf(curator) + basket.balanceOf(delegator);
        assertLe(claimed, registryBalance, "claimed more than distributed");
        // accPerShare floors once per notification (< pool/1e18 wei) and each
        // staker's settlement floors once more — that is the whole dust budget.
        assertLe(registryBalance - claimed, (selfStake + delegated) / 1e18 + 2, "dust above rounding bound");
    }
}
