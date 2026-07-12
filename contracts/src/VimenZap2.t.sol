// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VimenZap2, IRialtoRegistry} from "../src/VimenZap2.sol";
import {IPoolManager} from "../src/interfaces/IUniswapV4.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// Minimal Rialto registry mock, etched at the real registry address.
contract MockRegistry {
    address public current;
    bool public paused;

    function set(address current_, bool paused_) external {
        current = current_;
        paused = paused_;
    }

    function getFeature(uint128) external view returns (address, address, address, bool) {
        return (address(0), current, address(0), paused);
    }
}

/// Mock Rialto router: pulls `sellIn` of `sellToken` from the caller via its
/// allowance to `spender` (this contract doubles as the spender) and sends
/// back `buyOut` of `buyToken` from its own inventory. Behaviour knobs mimic
/// the failure modes the integration must survive.
contract MockRialtoRouter {
    bool public deliverShort; // deliver 1 wei less than promised
    bool public stealOnly; // pull input, deliver nothing
    uint256 public refundBps; // refund part of the pulled input (router refunds unspent)

    function setBehaviour(bool short_, bool steal_, uint256 refundBps_) external {
        deliverShort = short_;
        stealOnly = steal_;
        refundBps = refundBps_;
    }

    function swap(address sellToken, uint256 sellIn, address buyToken, uint256 buyOut) external {
        MockERC20(sellToken).transferFrom(msg.sender, address(this), sellIn);
        if (refundBps > 0) {
            MockERC20(sellToken).transfer(msg.sender, (sellIn * refundBps) / 10_000);
        }
        if (stealOnly) return;
        MockERC20(buyToken).transfer(msg.sender, deliverShort ? buyOut - 1 : buyOut);
    }
}

contract VimenZap2Test is Test {
    address constant REGISTRY_ADDR = 0x71a120CbBf3Ce7cD910a3c50fF77aFc62735687E;

    VimenZap2 zap;
    MockRegistry registry;
    MockRialtoRouter router;
    MockERC20 usdg;
    MockERC20 tokenA;
    MockERC20 tokenB;
    BasketToken basket;

    address user = makeAddr("user");
    address guardian;

    uint256 constant UNIT_A = 1e18;
    uint256 constant UNIT_B = 5e17;

    function setUp() public {
        // PoolManager is never touched in the all-Rialto unit paths; any
        // address with code works for the immutable. Use a dummy.
        zap = new VimenZap2(IPoolManager(address(0xDEAD)));

        MockRegistry impl = new MockRegistry();
        vm.etch(REGISTRY_ADDR, address(impl).code);
        registry = MockRegistry(REGISTRY_ADDR);

        router = new MockRialtoRouter();
        registry.set(address(router), false);

        usdg = new MockERC20("Global Dollar", "USDG");
        tokenA = new MockERC20("Token A", "A");
        tokenB = new MockERC20("Token B", "B");

        // guardian must be a contract; reuse the router for brevity
        guardian = address(router);
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory units = new uint256[](2);
        units[0] = UNIT_A;
        units[1] = UNIT_B;
        basket = new BasketToken("Test Basket", "TB", tokens, units, 30, guardian, guardian, 1_000_000e18, 1_000e18);

        // router inventory + user funds
        tokenA.mint(address(router), 1_000e18);
        tokenB.mint(address(router), 1_000e18);
        usdg.mint(user, 1_000e18);
        vm.prank(user);
        usdg.approve(address(zap), type(uint256).max);
    }

    function _call(uint256 legIndex, uint256 sellAmount, address buyToken, uint256 buyOut)
        internal
        view
        returns (VimenZap2.RialtoCall memory)
    {
        return VimenZap2.RialtoCall({
            legIndex: legIndex,
            sellAmount: sellAmount,
            spender: address(router),
            data: abi.encodeCall(MockRialtoRouter.swap, (address(usdg), sellAmount, buyToken, buyOut))
        });
    }

    function _emptyLegs() internal pure returns (VimenZap2.Hop[][] memory legs) {
        legs = new VimenZap2.Hop[][](2);
    }

    function _bothCalls(uint256 amount) internal view returns (VimenZap2.RialtoCall[] memory calls) {
        uint256 needA = (UNIT_A * amount + 1e18 - 1) / 1e18;
        uint256 needB = (UNIT_B * amount + 1e18 - 1) / 1e18;
        calls = new VimenZap2.RialtoCall[](2);
        calls[0] = _call(0, 10e18, address(tokenA), needA);
        calls[1] = _call(1, 6e18, address(tokenB), needB);
    }

    function _noPermit() internal pure returns (VimenZap2.Permit2Data memory) {
        return VimenZap2.Permit2Data({nonce: 0, deadline: 0, signature: ""});
    }

    // ------------------------------------------------------------- mint2

    function test_mint2_allRialto_happy() public {
        uint256 amount = 1e18;
        vm.prank(user);
        uint256 spent = zap.zapMint2(
            address(basket),
            amount,
            address(usdg),
            20e18,
            _emptyLegs(),
            _bothCalls(amount),
            user,
            block.timestamp + 60,
            _noPermit()
        );

        // fee is 30 bps, taken in basket tokens
        assertEq(basket.balanceOf(user), amount - (amount * 30) / 10_000);
        assertTrue(basket.isFullyBacked());
        // exact budget spent (mock router keeps all input): 16 of the 20 max
        assertEq(spent, 16e18);
        assertEq(usdg.balanceOf(user), 1_000e18 - 16e18);
        // nothing left behind
        assertEq(usdg.balanceOf(address(zap)), 0);
        assertEq(tokenA.balanceOf(address(zap)), 0);
        assertEq(tokenB.balanceOf(address(zap)), 0);
        // approvals reset
        assertEq(usdg.allowance(address(zap), address(router)), 0);
    }

    function test_mint2_routerRefund_returnsToPayer() public {
        router.setBehaviour(false, false, 5_000); // router refunds half the input
        uint256 amount = 1e18;
        vm.prank(user);
        uint256 spent = zap.zapMint2(
            address(basket),
            amount,
            address(usdg),
            20e18,
            _emptyLegs(),
            _bothCalls(amount),
            user,
            block.timestamp + 60,
            _noPermit()
        );
        assertEq(spent, 8e18); // half of 16 refunded, swept back to payer
        assertEq(usdg.balanceOf(user), 1_000e18 - 8e18);
        assertEq(usdg.balanceOf(address(zap)), 0);
    }

    function test_mint2_surplusConstituent_sweptToRecipient() public {
        uint256 amount = 1e18;
        VimenZap2.RialtoCall[] memory calls = _bothCalls(amount);
        // router overshoots leg A by 0.3 tokens (exact-in reality)
        calls[0] = _call(0, 10e18, address(tokenA), UNIT_A + 3e17);
        vm.prank(user);
        zap.zapMint2(
            address(basket), amount, address(usdg), 20e18, _emptyLegs(), calls, user, block.timestamp + 60, _noPermit()
        );
        assertEq(tokenA.balanceOf(user), 3e17);
        assertEq(tokenA.balanceOf(address(zap)), 0);
    }

    function test_mint2_underfill_reverts() public {
        router.setBehaviour(true, false, 0); // deliver 1 wei short
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(VimenZap2.LegUnderfilled.selector, 0));
        zap.zapMint2(
            address(basket),
            1e18,
            address(usdg),
            20e18,
            _emptyLegs(),
            _bothCalls(1e18),
            user,
            block.timestamp + 60,
            _noPermit()
        );
    }

    function test_mint2_maliciousRouter_takesInputDeliversNothing_reverts() public {
        router.setBehaviour(false, true, 0);
        uint256 before = usdg.balanceOf(user);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(VimenZap2.LegUnderfilled.selector, 0));
        zap.zapMint2(
            address(basket),
            1e18,
            address(usdg),
            20e18,
            _emptyLegs(),
            _bothCalls(1e18),
            user,
            block.timestamp + 60,
            _noPermit()
        );
        assertEq(usdg.balanceOf(user), before); // full revert, nothing lost
    }

    function test_mint2_budgetOverMaxSpend_reverts() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(VimenZap2.MaxSpendExceeded.selector, 16e18, 15e18));
        zap.zapMint2(
            address(basket),
            1e18,
            address(usdg),
            15e18,
            _emptyLegs(),
            _bothCalls(1e18),
            user,
            block.timestamp + 60,
            _noPermit()
        );
    }

    function test_mint2_uncoveredLeg_reverts() public {
        VimenZap2.RialtoCall[] memory calls = new VimenZap2.RialtoCall[](1);
        calls[0] = _call(0, 10e18, address(tokenA), UNIT_A);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(VimenZap2.LegNotCovered.selector, 1));
        zap.zapMint2(
            address(basket), 1e18, address(usdg), 20e18, _emptyLegs(), calls, user, block.timestamp + 60, _noPermit()
        );
    }

    function test_mint2_doublyCoveredLeg_reverts() public {
        VimenZap2.RialtoCall[] memory calls = new VimenZap2.RialtoCall[](2);
        calls[0] = _call(0, 10e18, address(tokenA), UNIT_A);
        calls[1] = _call(0, 10e18, address(tokenA), UNIT_A);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(VimenZap2.LegDoublyCovered.selector, 0));
        zap.zapMint2(
            address(basket), 1e18, address(usdg), 30e18, _emptyLegs(), calls, user, block.timestamp + 60, _noPermit()
        );
    }

    function test_mint2_registryPaused_reverts() public {
        registry.set(address(router), true);
        vm.prank(user);
        vm.expectRevert(VimenZap2.RialtoRouterPaused.selector);
        zap.zapMint2(
            address(basket),
            1e18,
            address(usdg),
            20e18,
            _emptyLegs(),
            _bothCalls(1e18),
            user,
            block.timestamp + 60,
            _noPermit()
        );
    }

    function test_mint2_registryZeroRouter_reverts() public {
        registry.set(address(0), false);
        vm.prank(user);
        vm.expectRevert(VimenZap2.RialtoTargetNotRouter.selector);
        zap.zapMint2(
            address(basket),
            1e18,
            address(usdg),
            20e18,
            _emptyLegs(),
            _bothCalls(1e18),
            user,
            block.timestamp + 60,
            _noPermit()
        );
    }

    function test_mint2_nativePayment_reverts() public {
        vm.prank(user);
        vm.expectRevert(VimenZap2.NativeNotSupported.selector);
        zap.zapMint2(
            address(basket),
            1e18,
            address(0),
            20e18,
            _emptyLegs(),
            _bothCalls(1e18),
            user,
            block.timestamp + 60,
            _noPermit()
        );
    }

    function test_mint2_expired_reverts() public {
        vm.warp(1_000_000);
        vm.prank(user);
        vm.expectRevert(VimenZap2.Expired.selector);
        zap.zapMint2(
            address(basket),
            1e18,
            address(usdg),
            20e18,
            _emptyLegs(),
            _bothCalls(1e18),
            user,
            block.timestamp - 1,
            _noPermit()
        );
    }

    // ------------------------------------------------------------ redeem2

    function _mintFirst(uint256 amount) internal returns (uint256 held) {
        vm.prank(user);
        zap.zapMint2(
            address(basket),
            amount,
            address(usdg),
            20e18,
            _emptyLegs(),
            _bothCalls(amount),
            user,
            block.timestamp + 60,
            _noPermit()
        );
        return basket.balanceOf(user);
    }

    function test_redeem2_allRialto_happy() public {
        uint256 held = _mintFirst(1e18);
        (address[] memory tokens, uint256[] memory amounts) = basket.backingOf(held);

        VimenZap2.RialtoCall[] memory calls = new VimenZap2.RialtoCall[](2);
        // sell exact redeemed amounts back for USDG (router pays 1:1 here)
        calls[0] = VimenZap2.RialtoCall({
            legIndex: 0,
            sellAmount: amounts[0],
            spender: address(router),
            data: abi.encodeCall(MockRialtoRouter.swap, (tokens[0], amounts[0], address(usdg), 5e18))
        });
        calls[1] = VimenZap2.RialtoCall({
            legIndex: 1,
            sellAmount: amounts[1],
            spender: address(router),
            data: abi.encodeCall(MockRialtoRouter.swap, (tokens[1], amounts[1], address(usdg), 3e18))
        });
        usdg.mint(address(router), 100e18);

        vm.startPrank(user);
        basket.approve(address(zap), held);
        uint256 out =
            zap.zapRedeem2(address(basket), held, address(usdg), 8e18, _emptyLegs(), calls, user, block.timestamp + 60);
        vm.stopPrank();

        assertEq(out, 8e18);
        assertEq(basket.balanceOf(user), 0);
        assertTrue(basket.isFullyBacked());
        assertEq(usdg.balanceOf(address(zap)), 0);
        assertEq(tokenA.balanceOf(address(zap)), 0);
    }

    function test_redeem2_sellMismatch_reverts() public {
        uint256 held = _mintFirst(1e18);
        (address[] memory tokens, uint256[] memory amounts) = basket.backingOf(held);
        VimenZap2.RialtoCall[] memory calls = new VimenZap2.RialtoCall[](2);
        calls[0] = VimenZap2.RialtoCall({
            legIndex: 0,
            sellAmount: amounts[0] - 1, // not the full redeemed amount
            spender: address(router),
            data: abi.encodeCall(MockRialtoRouter.swap, (tokens[0], amounts[0] - 1, address(usdg), 5e18))
        });
        calls[1] = VimenZap2.RialtoCall({
            legIndex: 1,
            sellAmount: amounts[1],
            spender: address(router),
            data: abi.encodeCall(MockRialtoRouter.swap, (tokens[1], amounts[1], address(usdg), 3e18))
        });
        vm.startPrank(user);
        basket.approve(address(zap), held);
        vm.expectRevert(abi.encodeWithSelector(VimenZap2.RialtoSellMismatch.selector, 0));
        zap.zapRedeem2(address(basket), held, address(usdg), 0, _emptyLegs(), calls, user, block.timestamp + 60);
        vm.stopPrank();
    }

    function test_redeem2_rialtoLeftoverConstituent_sweptToRecipient() public {
        uint256 held = _mintFirst(1e18);
        (address[] memory tokens, uint256[] memory amounts) = basket.backingOf(held);
        // router keeps only part of the constituent input (refunds 30%): the
        // leftover constituent wei must be swept to `to`, not stranded
        router.setBehaviour(false, false, 3_000);
        VimenZap2.RialtoCall[] memory calls = new VimenZap2.RialtoCall[](2);
        calls[0] = VimenZap2.RialtoCall({
            legIndex: 0,
            sellAmount: amounts[0],
            spender: address(router),
            data: abi.encodeCall(MockRialtoRouter.swap, (tokens[0], amounts[0], address(usdg), 5e18))
        });
        calls[1] = VimenZap2.RialtoCall({
            legIndex: 1,
            sellAmount: amounts[1],
            spender: address(router),
            data: abi.encodeCall(MockRialtoRouter.swap, (tokens[1], amounts[1], address(usdg), 3e18))
        });
        usdg.mint(address(router), 100e18);

        vm.startPrank(user);
        basket.approve(address(zap), held);
        zap.zapRedeem2(address(basket), held, address(usdg), 0, _emptyLegs(), calls, user, block.timestamp + 60);
        vm.stopPrank();

        // 30% of each constituent came back and was forwarded to the user
        assertEq(MockERC20(tokens[0]).balanceOf(user), (amounts[0] * 3_000) / 10_000);
        assertEq(MockERC20(tokens[1]).balanceOf(user), (amounts[1] * 3_000) / 10_000);
        // nothing stranded in the router
        assertEq(MockERC20(tokens[0]).balanceOf(address(zap)), 0);
        assertEq(MockERC20(tokens[1]).balanceOf(address(zap)), 0);
    }

    function test_mint2_donatedPaymentCurrency_notSweptToPayer() public {
        // a griefer donates USDG to the contract; the mint must refund only
        // THIS tx's unspent budget, leaving the donation untouched
        usdg.mint(address(zap), 50e18);
        uint256 amount = 1e18;
        vm.prank(user);
        uint256 spent = zap.zapMint2(
            address(basket),
            amount,
            address(usdg),
            20e18,
            _emptyLegs(),
            _bothCalls(amount),
            user,
            block.timestamp + 60,
            _noPermit()
        );
        assertEq(spent, 16e18);
        assertEq(usdg.balanceOf(user), 1_000e18 - 16e18); // refund excludes the donation
        assertEq(usdg.balanceOf(address(zap)), 50e18); // donation still there, not paid out
    }

    function test_redeem2_minOutNotMet_reverts() public {
        uint256 held = _mintFirst(1e18);
        (address[] memory tokens, uint256[] memory amounts) = basket.backingOf(held);
        VimenZap2.RialtoCall[] memory calls = new VimenZap2.RialtoCall[](2);
        calls[0] = VimenZap2.RialtoCall({
            legIndex: 0,
            sellAmount: amounts[0],
            spender: address(router),
            data: abi.encodeCall(MockRialtoRouter.swap, (tokens[0], amounts[0], address(usdg), 5e18))
        });
        calls[1] = VimenZap2.RialtoCall({
            legIndex: 1,
            sellAmount: amounts[1],
            spender: address(router),
            data: abi.encodeCall(MockRialtoRouter.swap, (tokens[1], amounts[1], address(usdg), 3e18))
        });
        usdg.mint(address(router), 100e18);
        vm.startPrank(user);
        basket.approve(address(zap), held);
        vm.expectRevert(abi.encodeWithSelector(VimenZap2.MinOutNotMet.selector, 8e18, 9e18));
        zap.zapRedeem2(address(basket), held, address(usdg), 9e18, _emptyLegs(), calls, user, block.timestamp + 60);
        vm.stopPrank();
    }
}
