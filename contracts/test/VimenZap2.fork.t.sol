// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {VimenZap2, IRialtoRegistry} from "../src/VimenZap2.sol";
import {IPoolManager, PoolKey} from "../src/interfaces/IUniswapV4.sol";

/// Fork tests for VimenZap2 against live Robinhood Chain. Two areas:
///
/// 1. v1-parity for the Uniswap-only paths through the NEW entry points
///    (`zapMint2`/`zapRedeem2` with no Rialto calls), which exercise the
///    v2-only "budget pulled upfront, pay the PoolManager from self" branch
///    against real pools.
/// 2. The live Rialto registry (feature 2 resolves to a non-paused router
///    with code).
///
/// Rialto-leg execution itself needs quote calldata from their keyed API and
/// is covered by unit tests with a mock router until the key exists.
contract VimenZap2ForkTest is Test {
    IPoolManager constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant USDG_WHALE = 0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d;

    address user = makeAddr("zap2User");
    address feeRecipient = makeAddr("feeRecipient");
    address guardian = makeAddr("guardian");

    BasketToken basket;
    VimenZap2 zap;
    bool active;

    PoolKey nvdaKey = PoolKey({currency0: USDG, currency1: NVDA, fee: 3000, tickSpacing: 60, hooks: address(0)});
    PoolKey tslaKey = PoolKey({currency0: TSLA, currency1: USDG, fee: 3000, tickSpacing: 60, hooks: address(0)});

    function setUp() public {
        string memory rpc = vm.envOr("RH_RPC", string(""));
        if (bytes(rpc).length == 0) return; // self-skip
        vm.createSelectFork(rpc);
        active = true;
        assertEq(block.chainid, 4663, "not Robinhood Chain");

        address[] memory tokens = new address[](2);
        tokens[0] = NVDA;
        tokens[1] = TSLA;
        uint256[] memory units = new uint256[](2);
        units[0] = 1e16;
        units[1] = 1e16;
        basket = new BasketToken(
            "Zap2 Test Basket", "Z2TB", tokens, units, 30, feeRecipient, guardian, 1_000_000e18, 1_000e18
        );
        zap = new VimenZap2(POOL_MANAGER);

        vm.prank(USDG_WHALE);
        IERC20(USDG).transfer(user, 10_000e6);
        vm.prank(user);
        IERC20(USDG).approve(address(zap), type(uint256).max);
    }

    modifier onlyFork() {
        vm.skip(!active);
        _;
    }

    function _mintLegs() internal view returns (VimenZap2.Hop[][] memory legs) {
        legs = new VimenZap2.Hop[][](2);
        legs[0] = new VimenZap2.Hop[](1);
        legs[0][0] = VimenZap2.Hop({key: nvdaKey, zeroForOne: true});
        legs[1] = new VimenZap2.Hop[](1);
        legs[1][0] = VimenZap2.Hop({key: tslaKey, zeroForOne: false});
    }

    function _redeemLegs() internal view returns (VimenZap2.Hop[][] memory legs) {
        legs = new VimenZap2.Hop[][](2);
        legs[0] = new VimenZap2.Hop[](1);
        legs[0][0] = VimenZap2.Hop({key: nvdaKey, zeroForOne: false});
        legs[1] = new VimenZap2.Hop[](1);
        legs[1][0] = VimenZap2.Hop({key: tslaKey, zeroForOne: true});
    }

    function _noRialto() internal pure returns (VimenZap2.RialtoCall[] memory calls) {
        calls = new VimenZap2.RialtoCall[](0);
    }

    function _noPermit() internal pure returns (VimenZap2.Permit2Data memory) {
        return VimenZap2.Permit2Data({nonce: 0, deadline: 0, signature: ""});
    }

    // ------------------------------------------------------------ registry

    function test_fork_rialtoRegistry_resolvesActiveRouter() public onlyFork {
        (, address current,, bool paused) = IRialtoRegistry(address(zap.RIALTO_REGISTRY())).getFeature(2);
        assertFalse(paused, "rialto swap feature is paused");
        assertTrue(current != address(0), "no active rialto router");
        assertTrue(current.code.length > 0, "router has no code");
    }

    // ------------------------------------------------- v1-parity via v2 path

    function test_fork_mint2_uniswapOnly_roundTrip() public onlyFork {
        uint256 amount = 1e18; // ~ $6 of NVDA+TSLA
        uint256 maxSpend = 20e6;
        uint256 balBefore = IERC20(USDG).balanceOf(user);

        vm.prank(user);
        uint256 spent = zap.zapMint2(
            address(basket), amount, USDG, maxSpend, _mintLegs(), _noRialto(), user, block.timestamp + 300, _noPermit()
        );

        uint256 held = basket.balanceOf(user);
        assertEq(held, amount - (amount * 30) / 10_000);
        assertTrue(basket.isFullyBacked());
        assertLt(spent, maxSpend, "spent the whole budget?");
        // unspent budget refunded: user paid exactly `spent`
        assertEq(balBefore - IERC20(USDG).balanceOf(user), spent);
        assertEq(IERC20(USDG).balanceOf(address(zap)), 0, "router not empty");
        assertEq(IERC20(NVDA).balanceOf(address(zap)), 0);
        assertEq(IERC20(TSLA).balanceOf(address(zap)), 0);

        // redeem the whole position back to USDG through the v2 path
        vm.startPrank(user);
        basket.approve(address(zap), held);
        uint256 received =
            zap.zapRedeem2(address(basket), held, USDG, 1e6, _redeemLegs(), _noRialto(), user, block.timestamp + 300);
        vm.stopPrank();

        assertGt(received, 0);
        assertEq(basket.balanceOf(user), 0);
        assertTrue(basket.isFullyBacked());
        assertEq(IERC20(USDG).balanceOf(address(zap)), 0);
        // round-trip cost stays sane (fees + spread on ~$6)
        uint256 netCost = spent - received;
        assertLt(netCost, spent / 5, "round trip lost more than 20%");
    }

    function test_fork_quoteLegs_matchesExecution() public onlyFork {
        uint256 amount = 1e18;
        (address[] memory tokens, uint256[] memory required) = basket.getRequiredUnits(amount);
        (uint256 quoted,) = zap.quoteLegs(tokens, required, USDG, _mintLegs());

        vm.prank(user);
        uint256 spent = zap.zapMint2(
            address(basket),
            amount,
            USDG,
            quoted + 1e6,
            _mintLegs(),
            _noRialto(),
            user,
            block.timestamp + 300,
            _noPermit()
        );
        assertEq(spent, quoted, "quote != execution");
    }

    function test_fork_mint2_maxSpendTooLow_reverts() public onlyFork {
        vm.prank(user);
        vm.expectRevert();
        zap.zapMint2(
            address(basket), 1e18, USDG, 1e6, _mintLegs(), _noRialto(), user, block.timestamp + 300, _noPermit()
        );
    }
}
