// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {VimenZap} from "../src/VimenZap.sol";
import {IPoolManager, PoolKey} from "../src/interfaces/IUniswapV4.sol";
import {ISignatureTransfer} from "../src/interfaces/IPermit2.sol";

/// Fork tests for VimenZap against the REAL Uniswap v4 pools on Robinhood
/// Chain (chain id 4663). Self-skips unless RH_RPC is set:
///
///   RH_RPC=https://rpc.mainnet.chain.robinhood.com forge test --match-contract VimenZapForkTest -vv
///
/// The test basket holds NVDA + TSLA, the two constituents with the deepest
/// v4 liquidity (recon 2026-07-11: NVDA/USDG 0.30% and TSLA/USDG 0.30%,
/// roughly $23K / $37K of buy-side inventory). Amounts are kept tiny so the
/// tests stay robust as live liquidity moves.
contract VimenZapForkTest is Test {
    // canonical chain infrastructure (recon 2026-07-11)
    IPoolManager constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6 decimals
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    /// Robinhood batch-settlement contract: the biggest USDG holder on the
    /// chain, used purely as a faucet under vm.prank.
    address constant USDG_WHALE = 0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d;

    address user = makeAddr("zapUser");
    address feeRecipient = makeAddr("feeRecipient");
    address guardian = makeAddr("guardian");

    BasketToken basket;
    VimenZap zap;
    bool active;

    // USDG (0x5fc5…) < NVDA (0xd060…): USDG is currency0
    PoolKey nvdaKey = PoolKey({currency0: USDG, currency1: NVDA, fee: 3000, tickSpacing: 60, hooks: address(0)});
    // TSLA (0x322F…) < USDG (0x5fc5…): TSLA is currency0
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
        units[0] = 1e16; // 0.01 NVDA per basket (~$2)
        units[1] = 1e16; // 0.01 TSLA per basket (~$4)
        basket = new BasketToken(
            "Zap Test Basket", "ZTB", tokens, units, 30, feeRecipient, guardian, 1_000_000e18, 1_000e18
        );
        zap = new VimenZap(POOL_MANAGER);

        // fund the user with USDG from the settlement contract
        vm.prank(USDG_WHALE);
        IERC20(USDG).transfer(user, 10_000e6);
    }

    modifier onlyFork() {
        vm.skip(!active);
        _;
    }

    // ------------------------------------------------------------- helpers

    /// Mint path: USDG -> NVDA (zeroForOne: USDG is currency0),
    ///            USDG -> TSLA (oneForZero: USDG is currency1).
    function _mintLegs() internal view returns (VimenZap.Hop[][] memory legs) {
        legs = new VimenZap.Hop[][](2);
        legs[0] = new VimenZap.Hop[](1);
        legs[0][0] = VimenZap.Hop({key: nvdaKey, zeroForOne: true});
        legs[1] = new VimenZap.Hop[](1);
        legs[1][0] = VimenZap.Hop({key: tslaKey, zeroForOne: false});
    }

    /// Redeem path: the same pools, opposite direction.
    function _redeemLegs() internal view returns (VimenZap.Hop[][] memory legs) {
        legs = new VimenZap.Hop[][](2);
        legs[0] = new VimenZap.Hop[](1);
        legs[0][0] = VimenZap.Hop({key: nvdaKey, zeroForOne: false});
        legs[1] = new VimenZap.Hop[](1);
        legs[1][0] = VimenZap.Hop({key: tslaKey, zeroForOne: true});
    }

    function _routerIsEmpty() internal view {
        assertEq(IERC20(USDG).balanceOf(address(zap)), 0, "router holds USDG");
        assertEq(IERC20(NVDA).balanceOf(address(zap)), 0, "router holds NVDA");
        assertEq(IERC20(TSLA).balanceOf(address(zap)), 0, "router holds TSLA");
        assertEq(basket.balanceOf(address(zap)), 0, "router holds basket");
        assertEq(address(zap).balance, 0, "router holds ETH");
    }

    // --------------------------------------------------------------- tests

    /// The quote and the execution must consume the identical amount within
    /// the same block: that is the whole point of quoting via real swaps.
    function test_fork_quoteMatchesExecution() public onlyFork {
        uint256 amount = 1e18;
        (uint256 quoted, uint256[] memory legIn) = zap.quoteZapMint(address(basket), amount, USDG, _mintLegs());
        assertGt(quoted, 0);
        assertEq(legIn.length, 2);
        assertEq(legIn[0] + legIn[1], quoted, "leg amounts must sum to total");

        uint256 balBefore = IERC20(USDG).balanceOf(user);
        vm.startPrank(user);
        IERC20(USDG).approve(address(zap), quoted);
        uint256 spent = zap.zapMint(address(basket), amount, USDG, quoted, _mintLegs(), user, block.timestamp + 300);
        vm.stopPrank();

        assertEq(spent, quoted, "execution must match quote in the same block");
        assertEq(balBefore - IERC20(USDG).balanceOf(user), spent, "user debited exactly `spent`");
        // 30 bps mint fee, taken in basket tokens
        assertEq(basket.balanceOf(user), amount - (amount * 30) / 10_000);
        assertTrue(basket.isFullyBacked(), "basket must be fully backed after zap");
        _routerIsEmpty();
    }

    function test_fork_zapRedeemRoundTrip() public onlyFork {
        uint256 amount = 1e18;

        // mint first
        (uint256 quoted,) = zap.quoteZapMint(address(basket), amount, USDG, _mintLegs());
        vm.startPrank(user);
        IERC20(USDG).approve(address(zap), quoted);
        zap.zapMint(address(basket), amount, USDG, quoted, _mintLegs(), user, block.timestamp + 300);

        // redeem everything back to USDG
        uint256 net = basket.balanceOf(user);
        (uint256 quotedOut, uint256[] memory legOut) = zap.quoteZapRedeem(address(basket), net, USDG, _redeemLegs());
        assertGt(quotedOut, 0);
        assertEq(legOut[0] + legOut[1], quotedOut);

        uint256 balBefore = IERC20(USDG).balanceOf(user);
        basket.approve(address(zap), net);
        uint256 received =
            zap.zapRedeem(address(basket), net, USDG, quotedOut, _redeemLegs(), user, block.timestamp + 300);
        vm.stopPrank();

        assertEq(received, quotedOut, "redeem execution must match quote");
        assertEq(IERC20(USDG).balanceOf(user) - balBefore, received);
        assertEq(basket.balanceOf(user), 0);
        // round trip through two 0.30% pools + 30 bps mint fee: the user gets
        // strictly less back than they paid, but the same order of magnitude
        assertLt(received, quoted);
        assertGt(received, (quoted * 90) / 100, "round-trip loss should stay under ~10%");
        _routerIsEmpty();
    }

    function test_fork_revertsWhenQuoteExceedsMaxSpend() public onlyFork {
        uint256 amount = 1e18;
        (uint256 quoted,) = zap.quoteZapMint(address(basket), amount, USDG, _mintLegs());

        vm.startPrank(user);
        IERC20(USDG).approve(address(zap), quoted);
        vm.expectRevert(abi.encodeWithSelector(VimenZap.MaxSpendExceeded.selector, quoted, quoted - 1));
        zap.zapMint(address(basket), amount, USDG, quoted - 1, _mintLegs(), user, block.timestamp + 300);
        vm.stopPrank();
        _routerIsEmpty();
    }

    function test_fork_revertsOnExpiredDeadline() public onlyFork {
        vm.expectRevert(VimenZap.Expired.selector);
        vm.prank(user);
        zap.zapMint(address(basket), 1e18, USDG, 1_000e6, _mintLegs(), user, block.timestamp - 1);
    }

    function test_fork_revertsOnWrongPath() public onlyFork {
        // NVDA leg pointed at the TSLA pool: path output != constituent
        VimenZap.Hop[][] memory legs = _mintLegs();
        legs[0][0] = VimenZap.Hop({key: tslaKey, zeroForOne: false});

        vm.startPrank(user);
        IERC20(USDG).approve(address(zap), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(VimenZap.PathOutputMismatch.selector, 0));
        zap.zapMint(address(basket), 1e18, USDG, 1_000e6, legs, user, block.timestamp + 300);
        vm.stopPrank();
    }

    /// Buying far beyond the pool's inventory must revert (v4 fills partially
    /// at the price limit instead of reverting; the router rejects that).
    function test_fork_revertsWhenLiquidityRunsOut() public onlyFork {
        // ~10,000 NVDA ≈ $2.1M against a ~$23K pool: cannot fill
        vm.expectRevert(); // LegUnderfilled or a v4 core failure, depending on pool state
        zap.quoteZapMint(address(basket), 1_000_000e18, USDG, _mintLegs());
    }

    /// The quote path must not move state: two consecutive quotes agree.
    function test_fork_quoteIsIdempotent() public onlyFork {
        (uint256 q1,) = zap.quoteZapMint(address(basket), 1e18, USDG, _mintLegs());
        (uint256 q2,) = zap.quoteZapMint(address(basket), 1e18, USDG, _mintLegs());
        assertEq(q1, q2, "quoting must not perturb pool state");
    }

    // ------------------------------------------------------------- permit2

    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 constant PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    /// The no-approve-transaction path: sign a Permit2 SignatureTransfer for
    /// maxSpend, send one transaction, own the basket. Uses the canonical
    /// Permit2 already deployed on the chain.
    function test_fork_zapMintPermit2_singleTransaction() public onlyFork {
        (address signer, uint256 pk) = makeAddrAndKey("permitUser");
        vm.prank(USDG_WHALE);
        IERC20(USDG).transfer(signer, 1_000e6);
        // once-ever ERC-20 approval of USDG to Permit2 (most wallets already have it)
        ISignatureTransfer permit2 = zap.PERMIT2();
        vm.prank(signer);
        IERC20(USDG).approve(address(permit2), type(uint256).max);

        uint256 amount = 1e18;
        (uint256 quoted,) = zap.quoteZapMint(address(basket), amount, USDG, _mintLegs());
        uint256 nonce = 0xC0FFEE;
        uint256 deadline = block.timestamp + 300;

        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TRANSFER_FROM_TYPEHASH,
                keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, USDG, quoted)),
                address(zap),
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", permit2.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        uint256 balBefore = IERC20(USDG).balanceOf(signer);
        vm.prank(signer);
        uint256 spent = zap.zapMintPermit2(
            address(basket),
            amount,
            USDG,
            quoted,
            _mintLegs(),
            signer,
            deadline,
            VimenZap.Permit2Data({nonce: nonce, deadline: deadline, signature: abi.encodePacked(r, s, v)})
        );

        assertEq(spent, quoted, "permit2 execution must match quote");
        assertEq(balBefore - IERC20(USDG).balanceOf(signer), spent);
        assertEq(basket.balanceOf(signer), amount - (amount * 30) / 10_000);
        // the router never received an allowance from the signer
        assertEq(IERC20(USDG).allowance(signer, address(zap)), 0);
        assertTrue(basket.isFullyBacked());
        _routerIsEmpty();
    }

    /// A reused nonce must be rejected by Permit2 (replay protection).
    function test_fork_permit2NonceCannotBeReplayed() public onlyFork {
        (address signer, uint256 pk) = makeAddrAndKey("permitUser2");
        vm.prank(USDG_WHALE);
        IERC20(USDG).transfer(signer, 1_000e6);
        ISignatureTransfer permit2 = zap.PERMIT2();
        vm.prank(signer);
        IERC20(USDG).approve(address(permit2), type(uint256).max);

        uint256 amount = 1e17; // 0.1 basket, leaves budget for a second try
        (uint256 quoted,) = zap.quoteZapMint(address(basket), amount, USDG, _mintLegs());
        uint256 maxSpend = quoted * 2; // sign a budget covering both attempts
        uint256 nonce = 0xBEEF;
        uint256 deadline = block.timestamp + 300;

        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TRANSFER_FROM_TYPEHASH,
                keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, USDG, maxSpend)),
                address(zap),
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", permit2.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        VimenZap.Permit2Data memory permit =
            VimenZap.Permit2Data({nonce: nonce, deadline: deadline, signature: abi.encodePacked(r, s, v)});

        vm.prank(signer);
        zap.zapMintPermit2(address(basket), amount, USDG, maxSpend, _mintLegs(), signer, deadline, permit);

        vm.expectRevert(); // Permit2 InvalidNonce
        vm.prank(signer);
        zap.zapMintPermit2(address(basket), amount, USDG, maxSpend, _mintLegs(), signer, deadline, permit);
    }
}
