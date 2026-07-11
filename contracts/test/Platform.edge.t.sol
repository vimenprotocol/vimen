// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VimenToken} from "../src/VimenToken.sol";
import {CuratorRegistry} from "../src/CuratorRegistry.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {BasketFactory} from "../src/BasketFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";

/// Edge-case coverage for the platform contracts. This test contract plays
/// the role of the splitter on its own registry so notifyReward paths can be
/// driven directly.
contract PlatformEdgeTest is Test {
    VimenToken vimen;
    CuratorRegistry registry;
    address treasury = makeAddr("treasury");
    address curator = makeAddr("curator");
    address delegator = makeAddr("delegator");

    function setUp() public {
        vimen = new VimenToken(address(this));
        registry = new CuratorRegistry(vimen);
        registry.initSplitter(address(this)); // this test acts as the splitter
        vimen.transfer(curator, 100_000e18);
        vimen.transfer(delegator, 100_000e18);
        vm.prank(curator);
        vimen.approve(address(registry), type(uint256).max);
        vm.prank(delegator);
        vimen.approve(address(registry), type(uint256).max);
    }

    function _notify(address token, uint256 amount) internal {
        MockERC20(token).mint(address(registry), amount);
        registry.notifyReward(curator, token, amount);
    }

    // --------------------------------------------------------- constructors

    function test_registry_revert_zeroToken() public {
        vm.expectRevert(CuratorRegistry.ZeroAddress.selector);
        new CuratorRegistry(IERC20(address(0)));
    }

    function test_registry_initSplitter_zero() public {
        CuratorRegistry r2 = new CuratorRegistry(vimen);
        vm.expectRevert(CuratorRegistry.ZeroAddress.selector);
        r2.initSplitter(address(0));
    }

    function test_factory_revert_zeroArgs() public {
        FeeSplitter s = new FeeSplitter(registry, treasury);
        vm.expectRevert(BasketFactory.ZeroAddress.selector);
        new BasketFactory(CuratorRegistry(address(0)), s, treasury);
        vm.expectRevert(BasketFactory.ZeroAddress.selector);
        new BasketFactory(registry, FeeSplitter(address(0)), treasury);
        vm.expectRevert(BasketFactory.ZeroAddress.selector);
        new BasketFactory(registry, s, address(0));
    }

    function test_splitter_revert_zeroArgs() public {
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        new FeeSplitter(CuratorRegistry(address(0)), treasury);
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        new FeeSplitter(registry, address(0));
    }

    function test_splitter_initFactory_guards() public {
        FeeSplitter s = new FeeSplitter(registry, treasury);
        vm.expectRevert(FeeSplitter.NotDeployer.selector);
        vm.prank(curator);
        s.initFactory(address(1));
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        s.initFactory(address(0));
        s.initFactory(address(1));
        vm.expectRevert(FeeSplitter.AlreadyInitialized.selector);
        s.initFactory(address(2));
    }

    // ------------------------------------------------------------- staking

    function test_stake_revert_feeOnTransferVimen() public {
        // VIMEN is an external contract: staking must reject tax/rebase tokens
        FeeOnTransferToken taxed = new FeeOnTransferToken();
        CuratorRegistry r2 = new CuratorRegistry(IERC20(address(taxed)));
        taxed.mint(curator, 100_000e18);
        vm.startPrank(curator);
        taxed.approve(address(r2), type(uint256).max);
        vm.expectRevert(CuratorRegistry.NonStandardToken.selector);
        r2.stake(curator, 10_000e18);
        vm.stopPrank();
    }

    function test_stake_revert_zeroCuratorOrAmount() public {
        vm.expectRevert(CuratorRegistry.ZeroAddress.selector);
        vm.prank(curator);
        registry.stake(address(0), 1);
        vm.expectRevert(CuratorRegistry.ZeroAmount.selector);
        vm.prank(curator);
        registry.stake(curator, 0);
    }

    function test_requestUnstake_revert_zeroAmount() public {
        vm.expectRevert(CuratorRegistry.ZeroAmount.selector);
        vm.prank(curator);
        registry.requestUnstake(curator, 0);
    }

    function test_withdraw_revert_nothingPending() public {
        vm.expectRevert(CuratorRegistry.NothingToWithdraw.selector);
        vm.prank(curator);
        registry.withdraw();
    }

    function test_unstake_mergedRequestsResetClock() public {
        vm.startPrank(curator);
        registry.stake(curator, 10_000e18);
        registry.requestUnstake(curator, 1_000e18);
        (, uint256 firstRelease) = registry.pendingWithdrawal(curator);

        vm.warp(block.timestamp + 6 days);
        registry.requestUnstake(curator, 1_000e18); // merges, resets clock
        (uint256 amount, uint256 mergedRelease) = registry.pendingWithdrawal(curator);
        assertEq(amount, 2_000e18);
        assertGt(mergedRelease, firstRelease);

        vm.warp(mergedRelease - 1);
        vm.expectRevert(CuratorRegistry.CooldownActive.selector);
        registry.withdraw();

        vm.warp(mergedRelease);
        registry.withdraw();
        vm.stopPrank();
        assertEq(vimen.balanceOf(curator), 100_000e18 - 8_000e18);
    }

    // ------------------------------------------------------------- rewards

    function test_notify_zeroAmount_noop() public {
        MockERC20 token = new MockERC20("R", "R");
        registry.notifyReward(curator, address(token), 0);
        assertEq(registry.rewardTokens(curator).length, 0);
    }

    function test_notify_maxRewardTokens() public {
        vm.prank(curator);
        registry.stake(curator, 10_000e18);
        for (uint256 i = 0; i < 64; i++) {
            _notify(address(new MockERC20("R", "R")), 1e18);
        }
        MockERC20 extra = new MockERC20("R", "R");
        extra.mint(address(registry), 1e18);
        vm.expectRevert(CuratorRegistry.TooManyRewardTokens.selector);
        registry.notifyReward(curator, address(extra), 1e18);
        // existing token still accepted
        _notify(registry.rewardTokens(curator)[0], 1e18);
    }

    function test_claim_skipsZeroBalances_andSettlesOnStakeChange() public {
        MockERC20 token = new MockERC20("R", "R");
        vm.prank(curator);
        registry.stake(curator, 10_000e18);
        vm.prank(delegator);
        registry.stake(curator, 10_000e18);

        _notify(address(token), 100e18);

        // stake change settles pro-rata rewards into `accrued`
        vm.prank(delegator);
        registry.stake(curator, 5_000e18);
        (, uint256[] memory pendingAfter) = registry.pendingRewards(curator, delegator);
        uint256 expected = ((100e18 * 8_000) / 10_000) / 2; // net 80, half pool
        assertApproxEqAbs(pendingAfter[0], expected, 2);

        // second claim right after the first transfers nothing and skips
        vm.startPrank(delegator);
        registry.claim(curator);
        uint256 balance = token.balanceOf(delegator);
        registry.claim(curator);
        vm.stopPrank();
        assertEq(token.balanceOf(delegator), balance);
        assertApproxEqAbs(balance, expected, 2);
    }

    function test_zeroCommission_allProRata() public {
        MockERC20 token = new MockERC20("R", "R");
        vm.startPrank(curator);
        registry.setCommission(0);
        registry.stake(curator, 10_000e18);
        vm.stopPrank();
        vm.warp(block.timestamp + registry.COMMISSION_TIMELOCK());
        _notify(address(token), 100e18);
        (, uint256[] memory pending) = registry.pendingRewards(curator, curator);
        assertApproxEqAbs(pending[0], 100e18, 2); // sole staker, no commission
    }

    // ------------------------------------------------------------ splitter

    function test_distribute_zeroBalance_noop() public {
        FeeSplitter s = new FeeSplitter(registry, treasury);
        s.initFactory(address(this));
        MockERC20 fakeBasket = new MockERC20("B", "B");
        s.register(address(fakeBasket), curator);
        s.distribute(address(fakeBasket)); // no revert, no transfers
        assertEq(fakeBasket.balanceOf(treasury), 0);
    }

    function test_distribute_oneWei_allToTreasury() public {
        CuratorRegistry r2 = new CuratorRegistry(vimen);
        FeeSplitter s = new FeeSplitter(r2, treasury);
        r2.initSplitter(address(s));
        s.initFactory(address(this));
        MockERC20 fakeBasket = new MockERC20("B", "B");
        s.register(address(fakeBasket), curator);
        fakeBasket.mint(address(s), 1); // 60% of 1 wei floors to 0
        s.distribute(address(fakeBasket));
        assertEq(fakeBasket.balanceOf(treasury), 1);
        assertEq(r2.rewardTokens(curator).length, 0);
    }
}
