// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {VimenZap3, IRialtoRegistry} from "../src/VimenZap3.sol";
import {IPoolManager, PoolKey} from "../src/interfaces/IUniswapV4.sol";

/// Mock Rialto router used ON FORK: etched behind the registry-resolved
/// address so the ETH-mixed paths exercise a real ETH->USDG conversion on the
/// live pool while the Rialto leg is deterministic. It pulls `sellIn` USDG via
/// the zap's allowance and pays back `buyOut` of the constituent from its own
/// (test-funded) inventory.
contract MockRialtoRouter {
    uint256 public refundBps; // under-consume: refund this share of the input

    function setRefundBps(uint256 b) external {
        refundBps = b;
    }

    function swap(address sellToken, uint256 sellIn, address buyToken, uint256 buyOut) external {
        IERC20(sellToken).transferFrom(msg.sender, address(this), sellIn);
        if (refundBps > 0) {
            IERC20(sellToken).transfer(msg.sender, (sellIn * refundBps) / 10_000);
        }
        IERC20(buyToken).transfer(msg.sender, buyOut);
    }
}

contract MockRegistry {
    address public current;

    function set(address c) external {
        current = c;
    }

    function getFeature(uint128) external view returns (address, address, address, bool) {
        return (address(0), current, address(0), false);
    }
}

/// Fork tests for VimenZap3's native-ETH paths against live Robinhood Chain.
/// Pure-Uniswap ETH mints/redeems run entirely on real pools; the ETH+Rialto
/// mixed test converts ETH->USDG on the real main pair and fills the Rialto
/// leg through an etched mock router.
contract VimenZap3ForkTest is Test {
    IPoolManager constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant REGISTRY = 0x71a120CbBf3Ce7cD910a3c50fF77aFc62735687E;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant USDG_WHALE = 0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d;

    address user = makeAddr("zap3User");
    address feeRecipient = makeAddr("feeRecipient");
    address guardian = makeAddr("guardian");

    BasketToken basket;
    VimenZap3 zap;
    bool active;

    // ETH is currency0 on the main pair; USDG is currency0 vs NVDA; TSLA is
    // currency0 vs USDG.
    PoolKey ethUsdg = PoolKey({currency0: address(0), currency1: USDG, fee: 500, tickSpacing: 10, hooks: address(0)});
    PoolKey usdgNvda = PoolKey({currency0: USDG, currency1: NVDA, fee: 3000, tickSpacing: 60, hooks: address(0)});
    PoolKey tslaUsdg = PoolKey({currency0: TSLA, currency1: USDG, fee: 3000, tickSpacing: 60, hooks: address(0)});

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
            "Zap3 Test Basket", "Z3TB", tokens, units, 30, feeRecipient, guardian, 1_000_000e18, 1_000e18
        );
        zap = new VimenZap3(POOL_MANAGER);
        vm.deal(user, 100 ether);
    }

    modifier onlyFork() {
        vm.skip(!active);
        _;
    }

    // ETH -> USDG -> NVDA (USDG->NVDA is zeroForOne, USDG is currency0)
    function _ethNvda() internal view returns (VimenZap3.Hop[] memory r) {
        r = new VimenZap3.Hop[](2);
        r[0] = VimenZap3.Hop({key: ethUsdg, zeroForOne: true});
        r[1] = VimenZap3.Hop({key: usdgNvda, zeroForOne: true});
    }

    // ETH -> USDG -> TSLA (USDG->TSLA is oneForZero, TSLA is currency0)
    function _ethTsla() internal view returns (VimenZap3.Hop[] memory r) {
        r = new VimenZap3.Hop[](2);
        r[0] = VimenZap3.Hop({key: ethUsdg, zeroForOne: true});
        r[1] = VimenZap3.Hop({key: tslaUsdg, zeroForOne: false});
    }

    function _ethUsdgRoute() internal view returns (VimenZap3.Hop[] memory r) {
        r = new VimenZap3.Hop[](1);
        r[0] = VimenZap3.Hop({key: ethUsdg, zeroForOne: true});
    }

    function _bothUniLegs() internal view returns (VimenZap3.Hop[][] memory legs) {
        legs = new VimenZap3.Hop[][](2);
        legs[0] = _ethNvda();
        legs[1] = _ethTsla();
    }

    function _noRialto() internal pure returns (VimenZap3.RialtoCall[] memory calls) {
        calls = new VimenZap3.RialtoCall[](0);
    }

    function _emptyRoute() internal pure returns (VimenZap3.Hop[] memory r) {
        r = new VimenZap3.Hop[](0);
    }

    // ----------------------------------------- pure-Uniswap ETH round trip

    function test_fork_mintEth_uniswapOnly_roundTrip() public onlyFork {
        uint256 amount = 1e18; // ~$6 of NVDA+TSLA
        uint256 maxSpendEth = 0.02 ether;
        uint256 balBefore = user.balance;

        vm.prank(user);
        uint256 spent = zap.zapMintEth{value: maxSpendEth}(
            address(basket),
            amount,
            maxSpendEth,
            _bothUniLegs(),
            _noRialto(),
            _emptyRoute(),
            user,
            block.timestamp + 300
        );

        uint256 held = basket.balanceOf(user);
        assertEq(held, amount - (amount * 30) / 10_000);
        assertTrue(basket.isFullyBacked());
        assertLt(spent, maxSpendEth, "spent whole budget?");
        // exact refund: user paid exactly `spent` in ETH
        assertEq(balBefore - user.balance, spent);
        assertEq(address(zap).balance, 0, "zap holds ETH");
        assertEq(IERC20(NVDA).balanceOf(address(zap)), 0);
        assertEq(IERC20(TSLA).balanceOf(address(zap)), 0);

        // redeem back to native ETH
        VimenZap3.Hop[][] memory rlegs = new VimenZap3.Hop[][](2);
        rlegs[0] = new VimenZap3.Hop[](2);
        rlegs[0][0] = VimenZap3.Hop({key: usdgNvda, zeroForOne: false}); // NVDA->USDG
        rlegs[0][1] = VimenZap3.Hop({key: ethUsdg, zeroForOne: false}); // USDG->ETH
        rlegs[1] = new VimenZap3.Hop[](2);
        rlegs[1][0] = VimenZap3.Hop({key: tslaUsdg, zeroForOne: true}); // TSLA->USDG
        rlegs[1][1] = VimenZap3.Hop({key: ethUsdg, zeroForOne: false}); // USDG->ETH

        vm.startPrank(user);
        basket.approve(address(zap), held);
        uint256 got =
            zap.zapRedeemEth(address(basket), held, 1, rlegs, _noRialto(), _emptyRoute(), user, block.timestamp + 300);
        vm.stopPrank();

        assertGt(got, 0);
        assertEq(basket.balanceOf(user), 0);
        assertTrue(basket.isFullyBacked());
        assertEq(address(zap).balance, 0);
    }

    // ---------------------------------------- mixed ETH + Rialto (hybrid)

    function test_fork_mintEth_mixedRialto() public onlyFork {
        // NVDA leg via Uniswap (ETH), TSLA leg via a mock Rialto router
        // (ETH->USDG on the real pool, then USDG->TSLA on the mock).
        MockRegistry reg = new MockRegistry();
        MockRialtoRouter router = new MockRialtoRouter();
        reg.set(address(router));
        vm.etch(REGISTRY, address(reg).code);
        // re-point the etched storage: set current via the etched contract
        MockRegistry(REGISTRY).set(address(router));

        // fund the mock router with TSLA from the settlement whale
        uint256 amount = 1e18;
        (, uint256[] memory req) = basket.getRequiredUnits(amount);
        // tks[1] == TSLA, req[1] == needed TSLA
        vm.prank(USDG_WHALE);
        IERC20(TSLA).transfer(address(router), req[1] * 2);

        // Rialto call: sell 20 USDG -> deliver exactly req[1] TSLA
        uint256 usdgForTsla = 20e6;
        VimenZap3.RialtoCall[] memory rcalls = new VimenZap3.RialtoCall[](1);
        rcalls[0] = VimenZap3.RialtoCall({
            legIndex: 1,
            sellAmount: usdgForTsla,
            spender: address(router),
            data: abi.encodeCall(MockRialtoRouter.swap, (USDG, usdgForTsla, TSLA, req[1]))
        });

        // only NVDA has a Uniswap leg; TSLA slot is empty (Rialto-covered)
        VimenZap3.Hop[][] memory legs = new VimenZap3.Hop[][](2);
        legs[0] = _ethNvda();
        legs[1] = new VimenZap3.Hop[](0);

        uint256 maxSpendEth = 0.03 ether;
        uint256 balBefore = user.balance;
        vm.prank(user);
        uint256 spent = zap.zapMintEth{value: maxSpendEth}(
            address(basket), amount, maxSpendEth, legs, rcalls, _ethUsdgRoute(), user, block.timestamp + 300
        );

        assertEq(basket.balanceOf(user), amount - (amount * 30) / 10_000);
        assertTrue(basket.isFullyBacked());
        assertEq(balBefore - user.balance, spent);
        assertEq(address(zap).balance, 0, "zap holds ETH");
        assertEq(IERC20(USDG).balanceOf(address(zap)), 0, "zap holds USDG");
        assertEq(IERC20(NVDA).balanceOf(address(zap)), 0);
        assertEq(IERC20(TSLA).balanceOf(address(zap)), 0);
    }

    function test_fork_mintEth_rialtoUnderConsumesUsdg_noStranding() public onlyFork {
        // regression for the audit MEDIUM: a Rialto router that keeps only part
        // of the approved USDG must leave ZERO USDG stranded in the zap.
        MockRegistry reg = new MockRegistry();
        MockRialtoRouter router = new MockRialtoRouter();
        reg.set(address(router));
        vm.etch(REGISTRY, address(reg).code);
        MockRegistry(REGISTRY).set(address(router));
        router.setRefundBps(2_000); // consume only 80% of the approved USDG

        uint256 amount = 1e18;
        (, uint256[] memory req) = basket.getRequiredUnits(amount);
        vm.prank(USDG_WHALE);
        IERC20(TSLA).transfer(address(router), req[1] * 2);

        uint256 usdgForTsla = 20e6;
        VimenZap3.RialtoCall[] memory rcalls = new VimenZap3.RialtoCall[](1);
        rcalls[0] = VimenZap3.RialtoCall({
            legIndex: 1,
            sellAmount: usdgForTsla,
            spender: address(router),
            data: abi.encodeCall(MockRialtoRouter.swap, (USDG, usdgForTsla, TSLA, req[1]))
        });
        VimenZap3.Hop[][] memory legs = new VimenZap3.Hop[][](2);
        legs[0] = _ethNvda();
        legs[1] = new VimenZap3.Hop[](0);

        uint256 usdgUserBefore = IERC20(USDG).balanceOf(user);
        vm.prank(user);
        zap.zapMintEth{value: 0.03 ether}(
            address(basket), amount, 0.03 ether, legs, rcalls, _ethUsdgRoute(), user, block.timestamp + 300
        );

        assertTrue(basket.isFullyBacked());
        assertEq(IERC20(USDG).balanceOf(address(zap)), 0, "USDG stranded in zap");
        // the 20% the router refunded came back to the payer, not stranded
        assertEq(IERC20(USDG).balanceOf(user) - usdgUserBefore, (usdgForTsla * 2_000) / 10_000);
    }

    // --------------------------------------------------------- guards

    function test_fork_mintEth_valueMismatch_reverts() public onlyFork {
        vm.prank(user);
        vm.expectRevert(VimenZap3.WrongMsgValue.selector);
        zap.zapMintEth{value: 0.01 ether}(
            address(basket), 1e18, 0.02 ether, _bothUniLegs(), _noRialto(), _emptyRoute(), user, block.timestamp + 300
        );
    }

    function test_fork_mintEth_expired_reverts() public onlyFork {
        vm.prank(user);
        vm.expectRevert(VimenZap3.Expired.selector);
        zap.zapMintEth{value: 0.02 ether}(
            address(basket), 1e18, 0.02 ether, _bothUniLegs(), _noRialto(), _emptyRoute(), user, block.timestamp - 1
        );
    }
}
