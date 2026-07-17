// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {VimenZap4, IUniswapV2Pair, IUniswapV3PoolMinimal, IWETH9} from "../src/VimenZap4.sol";
import {IPoolManager, PoolKey, V4TickMath} from "../src/interfaces/IUniswapV4.sol";

/// Mainnet-fork proof of VimenZap4's new venues, against the REAL pools of
/// the tokens being onboarded:
///   HAN    — Virtuals agent, v2 pair quoted in VIRTUAL, tax-on-swap token
///   SUIT   — Noxa meme, v3 pool quoted in WETH (1% fee)
///   KINDRA — Virtuals agent, v3 pool quoted directly in USDG (0.3% fee)
/// One zapMint4 buys all three across two bridges (VIRTUAL bought on v4,
/// WETH bought as native ETH on v4 and wrapped) and mints the basket; one
/// zapRedeem4 sells everything back to USDG. Fees and the agent tax are
/// DISCOVERED empirically with snapshot-reverted probe swaps, so the test
/// keeps passing when the token owner moves the tax.
///
///   RH_RPC=... forge test --match-contract VimenZap4Fork --fork-url $RH_RPC -vv
contract VimenZap4Fork is Test {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant VIRTUAL = 0xc6911796042b15d7Fa4F6CDe69e245DdCd3d9c31;

    address constant HAN = 0x3746a5ebCA295Dee695dd1bcba50A8626Df3099C;
    address constant HAN_PAIR = 0x5Ae5c378d28637311A66a7AAA52111397822ABDd; // v2, HAN/VIRTUAL
    address constant SUIT = 0xeaa9abB805Db03b6859662354aBfE0C2A30902ae;
    address constant SUIT_POOL = 0xd91355fc43F92Ef1F128D0c551885560Ed5B1634; // v3, WETH/SUIT 1%
    address constant KINDRA = 0xE44951407D2ed8E73dce4b7002908732BC0d0bC3;
    address constant KINDRA_POOL = 0xE767167E739344d2257dDdaE3192343bBBA29dbE; // v3, USDG/KINDRA 0.3%

    VimenZap4 zap;
    BasketToken basket;
    address user = makeAddr("zapUser");

    // v2 discovery results
    uint256 feeNum;
    uint256 feeDen;
    uint256 taxBps; // HAN tax on the pair->buyer hop, measured

    function setUp() public {
        zap = new VimenZap4(IPoolManager(POOL_MANAGER), IWETH9(WETH));

        address[] memory toks = new address[](3);
        toks[0] = HAN;
        toks[1] = SUIT;
        toks[2] = KINDRA;
        uint256[] memory units = new uint256[](3);
        units[0] = 100e18; // ~ $0.9 of HAN
        units[1] = 1000e18; // ~ $0.7 of SUIT
        units[2] = 1000e18; // ~ $0.5 of KINDRA
        basket = new BasketToken("Zap4 Probe", "Z4P", toks, units, 0, address(this), address(this), 1_000e18, 1_000e18);

        _discoverV2(HAN_PAIR, HAN, VIRTUAL);
    }

    // -------------------------------------------------------- v2 discovery

    /// Probe the pair once (snapshot-reverted): find the pair's swap fee from
    /// the candidates used by v2 forks, and the token's buy-side tax.
    function _discoverV2(address pair, address token, address quote) internal {
        deal(quote, address(this), 1_000e18);
        (uint112 r0, uint112 r1,) = _reserves(pair);
        bool tIs0 = IUniswapV2Pair(pair).token0() == token;
        (uint256 rT, uint256 rQ) = tIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        uint256 wantOut = 10e18;
        uint256[2] memory nums = [uint256(997), uint256(99)];
        uint256[2] memory dens = [uint256(1000), uint256(100)];
        for (uint256 f = 0; f < 2; f++) {
            uint256 amtIn = _getAmountIn(wantOut, rQ, rT, nums[f], dens[f]);
            uint256 snap = vm.snapshotState();
            IERC20(quote).transfer(pair, amtIn);
            (uint256 a0, uint256 a1) = tIs0 ? (wantOut, uint256(0)) : (uint256(0), wantOut);
            try IUniswapV2Pair(pair).swap(a0, a1, address(this), "") {
                uint256 got = IERC20(token).balanceOf(address(this));
                // read results into locals BEFORE the state revert wipes them
                uint256 measuredTax = 10_000 - (got * 10_000) / wantOut;
                vm.revertToState(snap);
                feeNum = nums[f];
                feeDen = dens[f];
                taxBps = measuredTax;
                console.log("v2 discovery: pair fee %s/%s, token tax %s bps", feeNum, feeDen, taxBps);
                return;
            } catch {
                vm.revertToState(snap);
            }
        }
        revert("v2 fee discovery failed");
    }

    function _reserves(address pair) internal view returns (uint112 r0, uint112 r1, uint32 ts) {
        (bool ok, bytes memory ret) = pair.staticcall(abi.encodeWithSignature("getReserves()"));
        require(ok, "getReserves");
        return abi.decode(ret, (uint112, uint112, uint32));
    }

    function _getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint256 num, uint256 den)
        internal
        pure
        returns (uint256)
    {
        return (reserveIn * amountOut * den) / ((reserveOut - amountOut) * num) + 1;
    }

    // ------------------------------------------------------ v3 probe quote

    /// Executes the exact-output swap for real, measures the input paid, and
    /// reverts the state: an execution-grade quote for any v3 pool.
    uint256 private _probePaid;

    function _probeV3ExactOut(address pool, bool tokenIs0, address payCurrency, uint256 out)
        internal
        returns (uint256 paid)
    {
        uint256 snap = vm.snapshotState();
        if (payCurrency == WETH) {
            vm.deal(address(this), 100 ether);
            IWETH9(WETH).deposit{value: 100 ether}();
        } else {
            deal(payCurrency, address(this), 1_000_000e6);
        }
        _probePaid = 0;
        _probePool = pool;
        _probePay = payCurrency;
        IUniswapV3PoolMinimal(pool).swap(
            address(this),
            !tokenIs0,
            -int256(out),
            !tokenIs0 ? V4TickMath.MIN_SQRT_PRICE_PLUS_ONE : V4TickMath.MAX_SQRT_PRICE_MINUS_ONE,
            ""
        );
        paid = _probePaid;
        vm.revertToState(snap);
    }

    address private _probePool;
    address private _probePay;

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        require(msg.sender == _probePool, "probe cb");
        uint256 pay = uint256(a0 > 0 ? a0 : a1);
        _probePaid = pay;
        IERC20(_probePay).transfer(msg.sender, pay);
    }

    // ---------------------------------------------------------------- keys

    function _virtualKey() internal pure returns (PoolKey memory) {
        return PoolKey({currency0: USDG, currency1: VIRTUAL, fee: 3000, tickSpacing: 60, hooks: address(0)});
    }

    function _ethUsdgKey() internal pure returns (PoolKey memory) {
        return PoolKey({currency0: address(0), currency1: USDG, fee: 500, tickSpacing: 10, hooks: address(0)});
    }

    // ---------------------------------------------------------------- tests

    function test_zapMint4_and_redeem4_acrossV2V3Bridges() public {
        (address[] memory toks, uint256[] memory req) = basket.getRequiredUnits(1e18);

        // --- build the HAN v2 leg from live reserves + measured tax
        uint256 hanGross = (req[0] * 10_000) / (10_000 - taxBps) + 2;
        (uint112 r0, uint112 r1,) = _reserves(HAN_PAIR);
        // HAN is token0 (0x3746... < 0xc691...)
        uint256 virtIn = _getAmountIn(hanGross, uint256(r1), uint256(r0), feeNum, feeDen);

        // --- v3 legs: execution-grade probes
        uint256 wethIn = (_probeV3ExactOut(SUIT_POOL, false, WETH, req[1]) * 101) / 100;
        uint256 usdgInKindra = (_probeV3ExactOut(KINDRA_POOL, false, USDG, req[2]) * 101) / 100;

        VimenZap4.ExtCall[] memory ext = new VimenZap4.ExtCall[](3);
        ext[0] = VimenZap4.ExtCall(2, 0, HAN_PAIR, true, VIRTUAL, virtIn, hanGross);
        ext[1] = VimenZap4.ExtCall(3, 1, SUIT_POOL, false, WETH, wethIn, req[1]);
        ext[2] = VimenZap4.ExtCall(3, 2, KINDRA_POOL, false, USDG, usdgInKindra, req[2]);

        VimenZap4.BridgeLeg[] memory bridges = new VimenZap4.BridgeLeg[](2);
        VimenZap4.Hop[] memory toVirtual = new VimenZap4.Hop[](1);
        toVirtual[0] = VimenZap4.Hop(_virtualKey(), true); // USDG -> VIRTUAL
        bridges[0] = VimenZap4.BridgeLeg(VIRTUAL, virtIn, toVirtual);
        VimenZap4.Hop[] memory toEth = new VimenZap4.Hop[](1);
        toEth[0] = VimenZap4.Hop(_ethUsdgKey(), false); // USDG -> native ETH
        bridges[1] = VimenZap4.BridgeLeg(WETH, wethIn, toEth);

        VimenZap4.Hop[][] memory legs = new VimenZap4.Hop[][](3); // all ext-covered
        VimenZap4.RialtoCall[] memory noRialto = new VimenZap4.RialtoCall[](0);

        deal(USDG, user, 50e6);
        vm.startPrank(user);
        IERC20(USDG).approve(address(zap), type(uint256).max);
        uint256 spent = zap.zapMint4(
            address(basket),
            1e18,
            USDG,
            50e6,
            legs,
            noRialto,
            ext,
            bridges,
            user,
            block.timestamp + 300,
            VimenZap4.Permit2Data(0, 0, "")
        );
        vm.stopPrank();

        assertEq(basket.balanceOf(user), 1e18, "basket minted");
        assertLt(spent, 50e6, "spent under budget");
        assertGt(spent, 1e6, "spent something plausible");
        // zero-balance invariant: nothing strands in the zap
        assertEq(IERC20(USDG).balanceOf(address(zap)), 0);
        assertEq(IERC20(VIRTUAL).balanceOf(address(zap)), 0);
        assertEq(IERC20(WETH).balanceOf(address(zap)), 0);
        assertEq(IERC20(HAN).balanceOf(address(zap)), 0);
        assertEq(IERC20(SUIT).balanceOf(address(zap)), 0);
        assertEq(IERC20(KINDRA).balanceOf(address(zap)), 0);
        assertEq(address(zap).balance, 0);
        console.log("zapMint4 spent %s USDG (budget 50e6)", spent);

        // ---------------- redeem the basket back to USDG
        (, uint256[] memory back) = basket.backingOf(1e18);
        // v2 sell: HAN -> VIRTUAL. The user->pair hop is taxed, the pair
        // credits net; quote the output from net-credited reserves.
        (r0, r1,) = _reserves(HAN_PAIR);
        uint256 hanNet = back[0] - (back[0] * taxBps) / 10_000;
        uint256 virtOut = (hanNet * feeNum * uint256(r1)) / (uint256(r0) * feeDen + hanNet * feeNum);
        virtOut = (virtOut * 999) / 1000; // rounding headroom

        VimenZap4.ExtCall[] memory extR = new VimenZap4.ExtCall[](3);
        extR[0] = VimenZap4.ExtCall(2, 0, HAN_PAIR, true, VIRTUAL, 0, virtOut);
        extR[1] = VimenZap4.ExtCall(3, 1, SUIT_POOL, false, WETH, 0, 1); // exact-input sell, floor enforced globally
        extR[2] = VimenZap4.ExtCall(3, 2, KINDRA_POOL, false, USDG, 0, 1);

        VimenZap4.BridgeLeg[] memory bridgesR = new VimenZap4.BridgeLeg[](2);
        VimenZap4.Hop[] memory fromVirtual = new VimenZap4.Hop[](1);
        fromVirtual[0] = VimenZap4.Hop(_virtualKey(), false); // VIRTUAL -> USDG
        bridgesR[0] = VimenZap4.BridgeLeg(VIRTUAL, 0, fromVirtual);
        VimenZap4.Hop[] memory fromEth = new VimenZap4.Hop[](1);
        fromEth[0] = VimenZap4.Hop(_ethUsdgKey(), true); // native ETH -> USDG
        bridgesR[1] = VimenZap4.BridgeLeg(WETH, 0, fromEth);

        vm.startPrank(user);
        basket.approve(address(zap), 1e18);
        uint256 received = zap.zapRedeem4(
            address(basket), 1e18, USDG, 1e6, legs, noRialto, extR, bridgesR, user, block.timestamp + 300
        );
        vm.stopPrank();

        assertEq(basket.balanceOf(user), 0, "basket burned");
        assertGt(received, 1e6, "got USDG back");
        assertEq(IERC20(USDG).balanceOf(address(zap)), 0);
        assertEq(IERC20(VIRTUAL).balanceOf(address(zap)), 0);
        assertEq(IERC20(WETH).balanceOf(address(zap)), 0);
        assertEq(address(zap).balance, 0);
        console.log("zapRedeem4 returned %s USDG (mint had spent %s)", received, spent);
        // round-trip cost sanity: fees+tax+spread should stay under 15%
        assertGt(received, (spent * 85) / 100, "round-trip cost sane");
    }

    function test_zapMint4_underfilledTaxedLeg_reverts() public {
        (, uint256[] memory req) = basket.getRequiredUnits(1e18);
        // ask the pair for exactly the required units: the tax shaves the
        // delivery below requirement -> LegUnderfilled
        (uint112 r0, uint112 r1,) = _reserves(HAN_PAIR);
        uint256 virtIn = _getAmountIn(req[0], uint256(r1), uint256(r0), feeNum, feeDen);
        uint256 wethIn = (_probeV3ExactOut(SUIT_POOL, false, WETH, req[1]) * 101) / 100;
        uint256 usdgInKindra = (_probeV3ExactOut(KINDRA_POOL, false, USDG, req[2]) * 101) / 100;

        VimenZap4.ExtCall[] memory ext = new VimenZap4.ExtCall[](3);
        ext[0] = VimenZap4.ExtCall(2, 0, HAN_PAIR, true, VIRTUAL, virtIn, req[0]); // no tax headroom
        ext[1] = VimenZap4.ExtCall(3, 1, SUIT_POOL, false, WETH, wethIn, req[1]);
        ext[2] = VimenZap4.ExtCall(3, 2, KINDRA_POOL, false, USDG, usdgInKindra, req[2]);
        VimenZap4.BridgeLeg[] memory bridges = new VimenZap4.BridgeLeg[](2);
        VimenZap4.Hop[] memory toVirtual = new VimenZap4.Hop[](1);
        toVirtual[0] = VimenZap4.Hop(_virtualKey(), true);
        bridges[0] = VimenZap4.BridgeLeg(VIRTUAL, virtIn, toVirtual);
        VimenZap4.Hop[] memory toEth = new VimenZap4.Hop[](1);
        toEth[0] = VimenZap4.Hop(_ethUsdgKey(), false);
        bridges[1] = VimenZap4.BridgeLeg(WETH, wethIn, toEth);
        VimenZap4.Hop[][] memory legs = new VimenZap4.Hop[][](3);
        VimenZap4.RialtoCall[] memory noRialto = new VimenZap4.RialtoCall[](0);

        deal(USDG, user, 50e6);
        vm.startPrank(user);
        IERC20(USDG).approve(address(zap), type(uint256).max);
        if (taxBps > 0) {
            vm.expectRevert(abi.encodeWithSelector(VimenZap4.LegUnderfilled.selector, 0));
        }
        zap.zapMint4(
            address(basket), 1e18, USDG, 50e6, legs, noRialto, ext, bridges, user, block.timestamp + 300,
            VimenZap4.Permit2Data(0, 0, "")
        );
        vm.stopPrank();
    }

    function test_v3Callback_rejectsStrangers() public {
        vm.expectRevert(VimenZap4.V3CallbackNotPool.selector);
        zap.uniswapV3SwapCallback(1e18, 0, "");
    }

    function test_bridgeSums_enforced() public {
        (, uint256[] memory req) = basket.getRequiredUnits(1e18);
        VimenZap4.ExtCall[] memory ext = new VimenZap4.ExtCall[](3);
        ext[0] = VimenZap4.ExtCall(2, 0, HAN_PAIR, true, VIRTUAL, 5e18, req[0]);
        ext[1] = VimenZap4.ExtCall(3, 1, SUIT_POOL, false, WETH, 1e15, req[1]);
        ext[2] = VimenZap4.ExtCall(3, 2, KINDRA_POOL, false, USDG, 2e6, req[2]);
        // VIRTUAL bridge declares a DIFFERENT amount than the legs consume
        VimenZap4.BridgeLeg[] memory bridges = new VimenZap4.BridgeLeg[](2);
        VimenZap4.Hop[] memory toVirtual = new VimenZap4.Hop[](1);
        toVirtual[0] = VimenZap4.Hop(_virtualKey(), true);
        bridges[0] = VimenZap4.BridgeLeg(VIRTUAL, 4e18, toVirtual);
        VimenZap4.Hop[] memory toEth = new VimenZap4.Hop[](1);
        toEth[0] = VimenZap4.Hop(_ethUsdgKey(), false);
        bridges[1] = VimenZap4.BridgeLeg(WETH, 1e15, toEth);
        VimenZap4.Hop[][] memory legs = new VimenZap4.Hop[][](3);
        VimenZap4.RialtoCall[] memory noRialto = new VimenZap4.RialtoCall[](0);

        deal(USDG, user, 50e6);
        vm.startPrank(user);
        IERC20(USDG).approve(address(zap), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(VimenZap4.ExtBridgeMismatch.selector, VIRTUAL));
        zap.zapMint4(
            address(basket), 1e18, USDG, 50e6, legs, noRialto, ext, bridges, user, block.timestamp + 300,
            VimenZap4.Permit2Data(0, 0, "")
        );
        vm.stopPrank();
    }
}

/// Mock Rialto router + registry (mirrors the VimenZap3 fork mocks): a firm
/// quote is `transferFrom(sellIn)` then `transfer(buyOut)`.
contract MockRialtoRouter4 {
    function swap(address sellToken, uint256 sellIn, address buyToken, uint256 buyOut) external {
        IERC20(sellToken).transferFrom(msg.sender, address(this), sellIn);
        IERC20(buyToken).transfer(msg.sender, buyOut);
    }
}

contract MockRegistry4 {
    address public current;

    function set(address c) external {
        current = c;
    }

    function getFeature(uint128) external view returns (address, address, address, bool) {
        return (address(0), current, address(0), false);
    }
}

/// Consolidation proof: the universal zapMint4/zapRedeem4 must preserve the
/// ETH+Rialto capability the retired zapMintEth/zapRedeemEth used to provide.
/// A basket of NVDA (Uniswap v4, ETH-routed) + TSLA (Rialto, mock) is minted
/// and redeemed paying/receiving native ETH; the Rialto USDG is sourced and
/// disposed through a USDG bridge leg — the mechanism the consolidation adds.
contract VimenZap4RialtoFork is Test {
    IPoolManager constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant REGISTRY = 0x71a120CbBf3Ce7cD910a3c50fF77aFc62735687E;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant USDG_WHALE = 0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d;

    PoolKey ethUsdg = PoolKey({currency0: address(0), currency1: USDG, fee: 500, tickSpacing: 10, hooks: address(0)});
    PoolKey usdgNvda = PoolKey({currency0: USDG, currency1: NVDA, fee: 3000, tickSpacing: 60, hooks: address(0)});

    VimenZap4 zap;
    BasketToken basket;
    address user = makeAddr("ethRialtoUser");

    function setUp() public {
        zap = new VimenZap4(IPoolManager(POOL_MANAGER), IWETH9(WETH));
        address[] memory toks = new address[](2);
        toks[0] = NVDA;
        toks[1] = TSLA;
        uint256[] memory units = new uint256[](2);
        units[0] = 1e16;
        units[1] = 1e16;
        basket = new BasketToken("Eth Rialto", "ETHR", toks, units, 0, address(this), address(this), 1_000e18, 1_000e18);
    }

    modifier onlyFork() {
        if (block.chainid != 4663) return;
        _;
    }

    function _ethNvda() internal view returns (VimenZap4.Hop[] memory r) {
        r = new VimenZap4.Hop[](2);
        r[0] = VimenZap4.Hop({key: ethUsdg, zeroForOne: true});
        r[1] = VimenZap4.Hop({key: usdgNvda, zeroForOne: true});
    }

    function _nvdaEth() internal view returns (VimenZap4.Hop[] memory r) {
        r = new VimenZap4.Hop[](2);
        r[0] = VimenZap4.Hop({key: usdgNvda, zeroForOne: false}); // NVDA->USDG
        r[1] = VimenZap4.Hop({key: ethUsdg, zeroForOne: false}); // USDG->ETH
    }

    function _usdgBridge(uint256 amount, bool mintSide) internal view returns (VimenZap4.BridgeLeg memory bl) {
        VimenZap4.Hop[] memory route = new VimenZap4.Hop[](1);
        // mint: ETH->USDG (zeroForOne); redeem: USDG->ETH (oneForZero)
        route[0] = VimenZap4.Hop({key: ethUsdg, zeroForOne: mintSide});
        bl = VimenZap4.BridgeLeg({currency: USDG, amount: amount, route: route});
    }

    function _installMock() internal returns (MockRialtoRouter4 router) {
        MockRegistry4 reg = new MockRegistry4();
        router = new MockRialtoRouter4();
        reg.set(address(router));
        vm.etch(REGISTRY, address(reg).code);
        MockRegistry4(REGISTRY).set(address(router));
    }

    function test_fork_zapMint4_ethPlusRialto() public onlyFork {
        MockRialtoRouter4 router = _installMock();
        uint256 amount = 1e18;
        (, uint256[] memory req) = basket.getRequiredUnits(amount);

        vm.prank(USDG_WHALE);
        IERC20(TSLA).transfer(address(router), req[1] * 2);

        uint256 usdgForTsla = 5e6;
        VimenZap4.RialtoCall[] memory rcalls = new VimenZap4.RialtoCall[](1);
        rcalls[0] = VimenZap4.RialtoCall({
            legIndex: 1,
            sellAmount: usdgForTsla,
            spender: address(router),
            data: abi.encodeCall(MockRialtoRouter4.swap, (USDG, usdgForTsla, TSLA, req[1]))
        });

        VimenZap4.Hop[][] memory legs = new VimenZap4.Hop[][](2);
        legs[0] = _ethNvda();
        legs[1] = new VimenZap4.Hop[](0);
        VimenZap4.ExtCall[] memory ext = new VimenZap4.ExtCall[](0);
        VimenZap4.BridgeLeg[] memory bridges = new VimenZap4.BridgeLeg[](1);
        bridges[0] = _usdgBridge(usdgForTsla, true);

        vm.deal(user, 1 ether);
        uint256 balBefore = user.balance;
        vm.prank(user);
        uint256 spent = zap.zapMint4{value: 0.05 ether}(
            address(basket), amount, address(0), 0.05 ether, legs, rcalls, ext, bridges, user, block.timestamp + 300,
            VimenZap4.Permit2Data(0, 0, "")
        );

        assertEq(basket.balanceOf(user), amount, "minted");
        assertTrue(basket.isFullyBacked(), "backed");
        assertEq(balBefore - user.balance, spent, "ETH spent == returned");
        assertEq(address(zap).balance, 0, "no ETH stranded");
        assertEq(IERC20(USDG).balanceOf(address(zap)), 0, "no USDG stranded");
        assertEq(IERC20(NVDA).balanceOf(address(zap)), 0);
        assertEq(IERC20(TSLA).balanceOf(address(zap)), 0);
    }

    function test_fork_zapRedeem4_ethPlusRialto() public onlyFork {
        MockRialtoRouter4 router = _installMock();
        uint256 amount = 1e18;

        // mint first (ETH+Rialto) so the user holds a basket to redeem
        (, uint256[] memory req) = basket.getRequiredUnits(amount);
        vm.prank(USDG_WHALE);
        IERC20(TSLA).transfer(address(router), req[1] * 2);
        {
            uint256 usdgForTsla = 5e6;
            VimenZap4.RialtoCall[] memory rc = new VimenZap4.RialtoCall[](1);
            rc[0] = VimenZap4.RialtoCall(1, usdgForTsla, address(router),
                abi.encodeCall(MockRialtoRouter4.swap, (USDG, usdgForTsla, TSLA, req[1])));
            VimenZap4.Hop[][] memory ml = new VimenZap4.Hop[][](2);
            ml[0] = _ethNvda();
            ml[1] = new VimenZap4.Hop[](0);
            VimenZap4.ExtCall[] memory me = new VimenZap4.ExtCall[](0);
            VimenZap4.BridgeLeg[] memory mb = new VimenZap4.BridgeLeg[](1);
            mb[0] = _usdgBridge(usdgForTsla, true);
            vm.deal(user, 1 ether);
            vm.prank(user);
            zap.zapMint4{value: 0.05 ether}(
                address(basket), amount, address(0), 0.05 ether, ml, rc, me, mb, user, block.timestamp + 300,
                VimenZap4.Permit2Data(0, 0, "")
            );
        }

        // fund the mock with USDG so it can buy the redeemed TSLA
        vm.prank(USDG_WHALE);
        IERC20(USDG).transfer(address(router), 100e6);

        (, uint256[] memory backing) = basket.backingOf(amount);
        uint256 usdgFromTsla = 3e6; // mock pays this USDG for the TSLA
        VimenZap4.RialtoCall[] memory rcalls = new VimenZap4.RialtoCall[](1);
        rcalls[0] = VimenZap4.RialtoCall({
            legIndex: 1,
            sellAmount: backing[1],
            spender: address(router),
            data: abi.encodeCall(MockRialtoRouter4.swap, (TSLA, backing[1], USDG, usdgFromTsla))
        });

        VimenZap4.Hop[][] memory legs = new VimenZap4.Hop[][](2);
        legs[0] = _nvdaEth(); // NVDA -> ETH on v4
        legs[1] = new VimenZap4.Hop[](0); // TSLA on Rialto
        VimenZap4.ExtCall[] memory ext = new VimenZap4.ExtCall[](0);
        VimenZap4.BridgeLeg[] memory bridges = new VimenZap4.BridgeLeg[](1);
        bridges[0] = _usdgBridge(0, false); // USDG (from Rialto) -> ETH

        uint256 ethBefore = user.balance;
        vm.startPrank(user);
        basket.approve(address(zap), amount);
        uint256 received = zap.zapRedeem4(
            address(basket), amount, address(0), 1, legs, rcalls, ext, bridges, user, block.timestamp + 300
        );
        vm.stopPrank();

        assertEq(basket.balanceOf(user), 0, "burned");
        assertGt(received, 0, "got ETH");
        assertEq(user.balance - ethBefore, received, "ETH delivered");
        assertEq(address(zap).balance, 0, "no ETH stranded");
        assertEq(IERC20(USDG).balanceOf(address(zap)), 0, "no USDG stranded");
        assertEq(IERC20(NVDA).balanceOf(address(zap)), 0);
        assertEq(IERC20(TSLA).balanceOf(address(zap)), 0);
    }
}
