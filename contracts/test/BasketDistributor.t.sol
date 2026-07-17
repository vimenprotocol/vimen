// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BasketDistributor, IBasketHolders} from "../src/BasketDistributor.sol";
import {MockUSDG} from "./mocks/AgenticMocks.sol";

/// @dev Minimal holder-registry stand-in with test-controlled contents,
///      including mid-cycle churn (the swap-remove reordering the real
///      BasketToken2 registry performs).
contract MockRegistry is IBasketHolders {
    address[] public holders;
    mapping(address => uint256) public balances;

    function set(address holder, uint256 balance) external {
        if (balances[holder] == 0 && balance > 0) holders.push(holder);
        balances[holder] = balance;
    }

    function removeAt(uint256 i) external {
        holders[i] = holders[holders.length - 1];
        holders.pop();
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function holderAt(uint256 i) external view returns (address) {
        return holders[i];
    }

    function balanceOf(address a) external view returns (uint256) {
        return balances[a];
    }
}

/// @dev A recipient whose USDG transfers revert (frozen wallet stand-in).
contract FrozenWallet {}

/// @dev USDG variant that reverts transfers to one frozen address.
contract FreezableUSDG is MockUSDG {
    address public frozen;

    function freeze(address a) external {
        frozen = a;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(to != frozen, "frozen");
        return super.transfer(to, amount);
    }
}

contract BasketDistributorTest is Test {
    MockRegistry registry;
    FreezableUSDG usdg;
    BasketDistributor dist;

    address safe = makeAddr("safe");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address pool = makeAddr("pool"); // infra, excluded

    function setUp() public {
        registry = new MockRegistry();
        usdg = new FreezableUSDG();
        address[] memory excluded = new address[](1);
        excluded[0] = pool;
        dist = new BasketDistributor(IBasketHolders(address(registry)), IERC20(address(usdg)), 7 days, safe, excluded);

        registry.set(alice, 60e18);
        registry.set(bob, 30e18);
        registry.set(carol, 10e18);
        registry.set(pool, 900e18); // huge LP position that must NOT dilute holders
    }

    function _runCycle(uint256 snapBatch, uint256 payBatch) internal {
        dist.startCycle();
        while (dist.phase() == BasketDistributor.Phase.Snapshotting) {
            dist.snapshotBatch(snapBatch);
        }
        while (dist.phase() == BasketDistributor.Phase.Paying) {
            dist.distributeBatch(payBatch);
        }
    }

    // ------------------------------------------------------------ happy path

    function test_cycle_paysProRata_excludesInfra() public {
        usdg.mint(address(dist), 1_000e6);
        _runCycle(10, 10);

        // pool's 900 is excluded: alice/bob/carol split 60/30/10
        assertEq(usdg.balanceOf(alice), 600e6);
        assertEq(usdg.balanceOf(bob), 300e6);
        assertEq(usdg.balanceOf(carol), 100e6);
        assertEq(usdg.balanceOf(pool), 0);
        assertEq(usdg.balanceOf(address(dist)), 0);
    }

    function test_cycle_paginated_matchesSingleShot() public {
        // many holders, snapshot and pay one at a time
        for (uint256 i = 0; i < 25; i++) {
            registry.set(makeAddr(string(abi.encodePacked("h", i))), 1e18);
        }
        usdg.mint(address(dist), 2_900e6); // 29 eligible wallets, 100 total units... (60+30+10+25 = 125? no: 60e18+30e18+10e18+25e18=125e18)
        _runCycle(1, 1);
        // alice holds 60/125 of eligible
        assertEq(usdg.balanceOf(alice), (2_900e6 * 60) / 125);
        assertEq(usdg.balanceOf(address(dist)) < 30, true); // integer dust only
    }

    function test_cycle_interval_enforced() public {
        usdg.mint(address(dist), 100e6);
        _runCycle(10, 10);
        usdg.mint(address(dist), 100e6);
        vm.expectRevert(BasketDistributor.TooEarly.selector);
        dist.startCycle();
        vm.warp(block.timestamp + 7 days + 1);
        dist.startCycle(); // fine now
    }

    function test_startCycle_revert_emptyPot() public {
        vm.expectRevert(BasketDistributor.NothingToDistribute.selector);
        dist.startCycle();
    }

    function test_phase_gates() public {
        usdg.mint(address(dist), 100e6);
        vm.expectRevert(BasketDistributor.WrongPhase.selector);
        dist.snapshotBatch(1);
        dist.startCycle();
        vm.expectRevert(BasketDistributor.WrongPhase.selector);
        dist.distributeBatch(1);
        vm.expectRevert(BasketDistributor.NotIdle.selector);
        dist.startCycle();
    }

    // ------------------------------------------------------------- hardening

    function test_frozenWallet_skipped_notFatal() public {
        usdg.freeze(bob);
        usdg.mint(address(dist), 1_000e6);
        _runCycle(10, 10);

        assertEq(usdg.balanceOf(alice), 600e6);
        assertEq(usdg.balanceOf(bob), 0); // skipped, cycle survived
        assertEq(usdg.balanceOf(carol), 100e6);
        assertEq(usdg.balanceOf(address(dist)), 300e6); // bob's share rolls forward
    }

    function test_registryChurn_betweenSnapshots_neverDoublePays() public {
        usdg.mint(address(dist), 1_000e6);
        dist.startCycle();
        dist.snapshotBatch(1); // snapshots index 0 = alice

        // churn: removing index 0 swap-moves the LAST holder into alice's slot
        registry.removeAt(0);

        while (dist.phase() == BasketDistributor.Phase.Snapshotting) {
            dist.snapshotBatch(1);
        }
        while (dist.phase() == BasketDistributor.Phase.Paying) {
            dist.distributeBatch(10);
        }

        // alice was snapshotted before the churn and paid EXACTLY once;
        // nobody is paid twice; at most one churned wallet missed the cycle
        assertEq(usdg.balanceOf(alice), (1_000e6 * 60e18) / dist.eligible());
        uint256 total = usdg.balanceOf(alice) + usdg.balanceOf(bob) + usdg.balanceOf(carol);
        assertLe(total, 1_000e6);
        assertEq(usdg.balanceOf(address(dist)), 1_000e6 - total);
    }

    function test_exclusion_safeOnly_andTakesEffectNextCycle() public {
        vm.prank(alice);
        vm.expectRevert(BasketDistributor.NotAdmin.selector);
        dist.setExcluded(alice, true);

        vm.prank(safe);
        dist.setExcluded(carol, true);
        usdg.mint(address(dist), 900e6);
        _runCycle(10, 10);
        assertEq(usdg.balanceOf(carol), 0);
        assertEq(usdg.balanceOf(alice), 600e6); // 60/90 of the pot
        assertEq(usdg.balanceOf(bob), 300e6);
    }

    function test_allExcluded_cycleClosesIdle_potRolls() public {
        vm.startPrank(safe);
        dist.setExcluded(alice, true);
        dist.setExcluded(bob, true);
        dist.setExcluded(carol, true);
        vm.stopPrank();
        usdg.mint(address(dist), 100e6);
        dist.startCycle();
        while (dist.phase() == BasketDistributor.Phase.Snapshotting) {
            dist.snapshotBatch(10);
        }
        assertEq(uint256(dist.phase()), uint256(BasketDistributor.Phase.Idle));
        assertEq(usdg.balanceOf(address(dist)), 100e6); // pot waits
    }

    function test_midCycleDeposits_rollToNextCycle() public {
        usdg.mint(address(dist), 1_000e6);
        dist.startCycle();
        usdg.mint(address(dist), 500e6); // a rebalance sweep lands mid-cycle
        while (dist.phase() == BasketDistributor.Phase.Snapshotting) {
            dist.snapshotBatch(10);
        }
        while (dist.phase() == BasketDistributor.Phase.Paying) {
            dist.distributeBatch(10);
        }
        assertEq(usdg.balanceOf(address(dist)), 500e6); // untouched, next pot
    }

    function test_constructor_validation() public {
        address[] memory none = new address[](0);
        vm.expectRevert(BasketDistributor.BadInterval.selector);
        new BasketDistributor(IBasketHolders(address(registry)), IERC20(address(usdg)), 1 hours, safe, none);
        vm.expectRevert(BasketDistributor.ZeroAddress.selector);
        new BasketDistributor(IBasketHolders(address(0)), IERC20(address(usdg)), 7 days, safe, none);
    }
}
