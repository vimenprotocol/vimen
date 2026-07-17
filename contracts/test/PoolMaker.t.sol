// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolMaker} from "../src/PoolMaker.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams} from "../src/interfaces/IUniswapV4.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUSDG} from "./mocks/AgenticMocks.sol";

/// @dev v4 PoolManager stand-in: fixed-price pools, real ERC20 movement on
///      take, callback-driven unlock — enough to exercise every PoolMaker
///      path end to end (the real manager is exercised by the fork tests).
contract MockPoolManager {
    // price of currency1 per currency0, 1e18-scaled, keyed by pool key hash
    mapping(bytes32 => uint256) public price18;

    function setPrice(PoolKey calldata key, uint256 p18) external {
        price18[keccak256(abi.encode(key))] = p18;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        returns (int256 delta)
    {
        uint256 p = price18[keccak256(abi.encode(key))];
        require(p != 0, "mock: pool unset");
        require(params.amountSpecified < 0, "mock: exact-in only");
        uint256 amtIn = uint256(-params.amountSpecified);
        uint256 amtOut = params.zeroForOne ? (amtIn * p) / 1e18 : (amtIn * 1e18) / p;
        int128 d0;
        int128 d1;
        if (params.zeroForOne) {
            d0 = -int128(int256(amtIn));
            d1 = int128(int256(amtOut));
        } else {
            d1 = -int128(int256(amtIn));
            d0 = int128(int256(amtOut));
        }
        delta = (int256(d0) << 128) | int256(int128(d1)) & int256(uint256(type(uint128).max));
    }

    function sync(address) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function take(address currency, address to, uint256 amount) external {
        IERC20(currency).transfer(to, amount);
    }
}

/// @dev Constant-payout v2 pair: pays whatever swap() asks from inventory.
contract SimplePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        if (amount0Out > 0) IERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).transfer(to, amount1Out);
    }

    address public token0;
    address public token1;

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }
}

contract PoolMakerTest is Test {
    MockPoolManager manager;
    PoolMaker maker;
    MockERC20 meme; // v4-traded meme
    MockERC20 virt; // the VIRTUAL bridge
    MockERC20 agentToken; // v2-traded Virtuals agent
    MockUSDG usdg;
    SimplePair pair; // agent/VIRTUAL

    PoolKey memeKey; // meme/USDG on v4
    PoolKey virtKey; // VIRTUAL/USDG on v4

    function setUp() public {
        manager = new MockPoolManager();
        maker = new PoolMaker(IPoolManager(address(manager)));
        meme = new MockERC20("Meme", "MEME");
        virt = new MockERC20("Virtual", "VIRT");
        agentToken = new MockERC20("Agent", "AGT");
        usdg = new MockUSDG();
        pair = new SimplePair(address(agentToken), address(virt));

        // v4 keys: sort currencies by address like the real manager
        memeKey = _key(address(meme), address(usdg));
        virtKey = _key(address(virt), address(usdg));
        // meme at 0.05 USDG(6d)/meme(18d): c1-per-c0 units depend on sort —
        // the tests set prices per direction below instead of hardcoding
    }

    function _key(address a, address b) internal pure returns (PoolKey memory k) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        k = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: address(0)});
    }

    function _hop(PoolKey memory k, address tokenIn) internal pure returns (PoolMaker.Hop memory) {
        return PoolMaker.Hop({key: k, zeroForOne: tokenIn == k.currency0});
    }

    // -------------------------------------------------------------- v4 single

    function test_swapV4_singleHop_roundTrips() public {
        // 1 meme -> 0.05 USDG: set the directional price on the sorted key
        bool memeIs0 = address(meme) < address(usdg);
        // price18 = c1 per c0 (1e18-scaled), decimal-adjusted for the mock
        uint256 mPrice = 0.05e6;
        manager.setPrice(memeKey, memeIs0 ? mPrice : 1e36 / mPrice);
        usdg.mint(address(manager), 1_000_000e6);

        meme.mint(address(this), 10e18);
        meme.approve(address(maker), 10e18);
        PoolMaker.Hop[] memory hops = new PoolMaker.Hop[](1);
        hops[0] = _hop(memeKey, address(meme));
        maker.swapV4(hops, 10e18);

        assertEq(usdg.balanceOf(address(this)), 0.5e6); // 10 * $0.05
        assertEq(meme.balanceOf(address(maker)), 0);
        assertEq(usdg.balanceOf(address(maker)), 0);
    }

    function test_swapV4_revert_brokenPath() public {
        PoolMaker.Hop[] memory hops = new PoolMaker.Hop[](2);
        hops[0] = _hop(memeKey, address(meme));
        hops[1] = _hop(memeKey, address(meme)); // does not consume prior output
        vm.expectRevert(abi.encodeWithSelector(PoolMaker.BrokenPath.selector, 1));
        maker.swapV4(hops, 1e18);
    }

    // ---------------------------------------------------------- bridged SELL

    function test_swapV2ThenV4_sellsAgentToUsdg() public {
        bool virtIs0 = address(virt) < address(usdg);
        uint256 vPrice = 0.6e6; // VIRTUAL at $0.60 (6d quote per 18d token, 1e18-scaled)
        manager.setPrice(virtKey, virtIs0 ? vPrice : 1e36 / vPrice);
        usdg.mint(address(manager), 1_000_000e6);
        virt.mint(address(pair), 100e18); // pair inventory

        // sell 100 agents; planner says the pair pays 1.0 VIRTUAL gross
        agentToken.mint(address(this), 100e18);
        agentToken.approve(address(maker), 100e18);
        PoolMaker.Hop[] memory hops = new PoolMaker.Hop[](1);
        hops[0] = _hop(virtKey, address(virt));
        bool agentIs0 = address(agentToken) == pair.token0();
        maker.swapV2ThenV4(
            address(pair), IERC20(address(agentToken)), 100e18, IERC20(address(virt)), !agentIs0, 1e18, hops
        );

        assertEq(usdg.balanceOf(address(this)), 0.6e6); // 1 VIRTUAL * $0.60
        assertEq(agentToken.balanceOf(address(pair)), 100e18); // input went to the pair
        assertEq(virt.balanceOf(address(maker)), 0);
        assertEq(usdg.balanceOf(address(maker)), 0);
    }

    // ----------------------------------------------------------- bridged BUY

    function test_swapV4ThenV2_buysAgentWithUsdg() public {
        bool virtIs0 = address(virt) < address(usdg);
        uint256 vPrice = 0.6e6;
        manager.setPrice(virtKey, virtIs0 ? vPrice : 1e36 / vPrice);
        virt.mint(address(manager), 1_000e18); // v4 inventory pays VIRTUAL
        agentToken.mint(address(pair), 1_000e18); // pair inventory pays agents

        usdg.mint(address(this), 0.6e6);
        usdg.approve(address(maker), 0.6e6);
        PoolMaker.Hop[] memory hops = new PoolMaker.Hop[](1);
        hops[0] = _hop(virtKey, address(usdg));
        bool agentIs0 = address(agentToken) == pair.token0();
        maker.swapV4ThenV2(hops, 0.6e6, address(pair), agentIs0, 95e18);

        assertEq(agentToken.balanceOf(address(this)), 95e18); // straight to caller
        assertEq(virt.balanceOf(address(pair)) > 0, true); // bridge landed in the pair
        assertEq(virt.balanceOf(address(maker)), 0);
        assertEq(usdg.balanceOf(address(maker)), 0);
    }

    function test_swapV2ThenV4_revert_pathNotFromBridge() public {
        PoolMaker.Hop[] memory hops = new PoolMaker.Hop[](1);
        hops[0] = _hop(memeKey, address(meme)); // path starts at meme, not the bridge
        vm.expectRevert(abi.encodeWithSelector(PoolMaker.BrokenPath.selector, 0));
        maker.swapV2ThenV4(address(pair), IERC20(address(agentToken)), 1e18, IERC20(address(virt)), true, 1e18, hops);
    }
}
