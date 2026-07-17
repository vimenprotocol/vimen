// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    IPoolManager,
    IUnlockCallback,
    PoolKey,
    SwapParams,
    V4TickMath,
    BalanceDeltaLib
} from "./interfaces/IUniswapV4.sol";
import {ISignatureTransfer} from "./interfaces/IPermit2.sol";

interface IBasketToken {
    function getRequiredUnits(uint256 basketAmount)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts);
    function backingOf(uint256 basketAmount) external view returns (address[] memory tokens, uint256[] memory amounts);
    function mint(uint256 basketAmount, address to) external;
    function redeem(uint256 basketAmount, address to) external;
}

/// @title VimenZap4 — single-transaction basket mint/redeem against Uniswap
///        v4, v2 pairs, v3 pools and Rialto, venue-selectable per constituent
/// @notice `zapMint`: pay one currency (USDG, or native ETH), the router buys
///         the exact constituent amounts on Uniswap v4 (exact-output, so zero
///         dust) and mints the basket to you, atomically. If any leg cannot
///         be filled, everything reverts: no partial state, ever.
///         `zapRedeem`: burn basket tokens and receive one currency back.
///
///         Trust model, same as BasketToken: no owner, no admin, no pause,
///         no upgradability, holds no funds between transactions. The swap
///         path for every constituent is chosen by the caller; the contract
///         only enforces that each path starts at the payment currency, ends
///         at the right constituent, and fills exactly.
///
///         Quoting: `quoteZapMint` / `quoteZapRedeem` execute the real swaps
///         inside a v4 unlock and revert with the amounts (the v4 Quoter
///         trick), so an `eth_call` returns the exact execution numbers with
///         no token balance needed. They are not `view` on paper, but never
///         change state when called.
interface IRialtoRegistry {
    function getFeature(uint128 featureId)
        external
        view
        returns (address previous, address current, address next, bool paused);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IUniswapV3PoolMinimal {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

contract VimenZap4 is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using BalanceDeltaLib for int256;

    // ---------------------------------------------------------------- errors

    error Expired();
    error NotPoolManager();
    error LegCountMismatch();
    error EmptyPath();
    error PathDiscontinuous();
    error PathInputMismatch(uint256 leg);
    error PathOutputMismatch(uint256 leg);
    error LegUnderfilled(uint256 leg);
    error MaxSpendExceeded(uint256 required, uint256 maxSpend);
    error MinOutNotMet(uint256 out, uint256 minOut);
    error WrongMsgValue();
    error NativeRefundFailed();
    error UnexpectedQuoteSuccess();
    error RialtoRouterPaused();
    error RialtoTargetNotRouter();
    error LegNotCovered(uint256 leg);
    error LegDoublyCovered(uint256 leg);
    error RialtoSellMismatch(uint256 leg);
    /// @dev Never surfaces to callers: carries quote results out of the
    ///      reverted unlock. `total` is spend (mint) or proceeds (redeem).
    error QuoteResult(uint256 total, uint256[] perLeg);

    // ---------------------------------------------------------------- events

    event ZapMinted(
        address indexed sender, address indexed basket, address inputCurrency, uint256 basketAmount, uint256 spent
    );
    event ZapRedeemed(
        address indexed sender, address indexed basket, address outputCurrency, uint256 basketAmount, uint256 received
    );

    // ----------------------------------------------------------------- types

    /// @notice One Rialto-filled constituent. `data` is the quote API's tx.data,
    ///         verbatim; the call target is NOT taken from the quote but always
    ///         resolved from Rialto's on-chain router registry, so this contract
    ///         can never be pointed at an arbitrary address. Approvals are exact
    ///         and reset to zero around the call; if the constituent balance
    ///         does not grow by the required amount, the whole zap reverts.
    struct RialtoCall {
        uint256 legIndex; // which constituent this call fills (mint) / sells (redeem)
        uint256 sellAmount; // exact input from the quote (payment currency on mint, constituent on redeem)
        address spender; // issues.allowance.spender from the quote
        bytes data; // tx.data from the quote, unmodified
    }

    /// @notice One pool traversal. `zeroForOne = true` means the hop consumes
    ///         `key.currency0` and produces `key.currency1`.
    struct Hop {
        PoolKey key;
        bool zeroForOne;
    }

    enum Action {
        MINT,
        REDEEM,
        QUOTE_MINT,
        QUOTE_REDEEM
    }

    /// @notice Permit2 SignatureTransfer payload: the user signs
    ///         (token = paymentCurrency, amount = maxSpend, spender = this
    ///         router) off-chain, and the approve transaction disappears.
    struct Permit2Data {
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    struct ZapData {
        Action action;
        address paymentCurrency; // mint: what the payer spends; redeem: what the recipient gets
        address payer; // mint execution only: constituent settlement pulls from them
        address recipient; // redeem execution only: receives the output currency
        uint256 limit; // mint: maxSpend; redeem: minOut (ignored for quotes)
        address[] tokens; // basket constituents, in basket order
        uint256[] amounts; // mint: exact amounts to buy; redeem: exact amounts to sell
        Hop[][] legs; // legs[i] = path for tokens[i], aligned with `tokens`
        Permit2Data permit; // empty signature = classic allowance path
    }

    // --------------------------------------------------------------- storage

    /// @dev Canonical Permit2, verified deployed on Robinhood Chain.
    ISignatureTransfer public constant PERMIT2 = ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    /// @dev Rialto router registry on Robinhood Chain; feature 2 is the
    ///      taker-submitted swap router. The active router is resolved from
    ///      here at execution time — never trusted from calldata.
    IRialtoRegistry public constant RIALTO_REGISTRY = IRialtoRegistry(0x71a120CbBf3Ce7cD910a3c50fF77aFc62735687E);
    uint128 public constant RIALTO_SWAP_FEATURE = 2;

    IPoolManager public immutable poolManager;

    /// @dev Canonical wrapped native on Robinhood Chain; v3 pools quote in
    ///      WETH while v4 uses native ETH, so the ext-venue bridge wraps.
    IWETH9 public immutable weth;

    constructor(IPoolManager poolManager_, IWETH9 weth_) {
        poolManager = poolManager_;
        weth = weth_;
    }

    /// @dev Accept native ETH: the PoolManager sends it here via `take` on the
    ///      ETH-output redeem paths, and native-ETH mints refund through here.
    ///      Only the PoolManager and refunds ever pay in; the contract holds no
    ///      ETH between transactions.
    receive() external payable {}
    // ---------------------------------------------------------------- quotes

    /// @notice Exact execution quote for `zapMint`, callable via eth_call.
    /// @return totalIn Total `paymentCurrency` a zapMint would consume now.
    /// @return legIn Per-constituent spend, aligned with `constituents()`.
    function quoteZapMint(address basket, uint256 basketAmount, address paymentCurrency, Hop[][] calldata legs)
        external
        returns (uint256 totalIn, uint256[] memory legIn)
    {
        (address[] memory tokens, uint256[] memory required) = IBasketToken(basket).getRequiredUnits(basketAmount);
        return _quote(
            ZapData({
                action: Action.QUOTE_MINT,
                paymentCurrency: paymentCurrency,
                payer: address(0),
                recipient: address(0),
                limit: type(uint256).max,
                tokens: tokens,
                amounts: required,
                legs: legs,
                permit: Permit2Data({nonce: 0, deadline: 0, signature: ""})
            })
        );
    }

    /// @notice Exact execution quote for `zapRedeem`, callable via eth_call.
    function quoteZapRedeem(address basket, uint256 basketAmount, address outputCurrency, Hop[][] calldata legs)
        external
        returns (uint256 totalOut, uint256[] memory legOut)
    {
        (address[] memory tokens, uint256[] memory amounts) = IBasketToken(basket).backingOf(basketAmount);
        return _quote(
            ZapData({
                action: Action.QUOTE_REDEEM,
                paymentCurrency: outputCurrency,
                payer: address(0),
                recipient: address(0),
                limit: 0,
                tokens: tokens,
                amounts: amounts,
                legs: legs,
                permit: Permit2Data({nonce: 0, deadline: 0, signature: ""})
            })
        );
    }

    function _quote(ZapData memory data) private returns (uint256, uint256[] memory) {
        try poolManager.unlock(abi.encode(data)) {
            revert UnexpectedQuoteSuccess();
        } catch (bytes memory reason) {
            if (reason.length < 4 || bytes4(reason) != QuoteResult.selector) {
                // a real failure (bad path, no liquidity): bubble it up
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
            assembly ("memory-safe") {
                // strip the 4-byte selector in place
                let len := mload(reason)
                reason := add(reason, 4)
                mstore(reason, sub(len, 4))
            }
            return abi.decode(reason, (uint256, uint256[]));
        }
    }
    // ------------------------------------------------- native-ETH mixed (v3)

    /// @dev Global Dollar (USDG), the intermediary currency for Rialto legs on
    ///      the native-ETH paths. Canonical on Robinhood Chain, verified.
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    /// @notice Generic exact-output quote for an arbitrary set of legs,
    ///         basket-free: the frontend uses it to price the Uniswap side of
    ///         a mixed-venue mint (Rialto legs are quoted by Rialto's API).
    ///         Legs with an empty path return zero. eth_call only.
    function quoteLegs(
        address[] calldata tokens,
        uint256[] calldata amounts,
        address paymentCurrency,
        Hop[][] calldata legs
    ) external returns (uint256 totalIn, uint256[] memory legIn) {
        return _quote(
            ZapData({
                action: Action.QUOTE_MINT,
                paymentCurrency: paymentCurrency,
                payer: address(0),
                recipient: address(0),
                limit: type(uint256).max,
                tokens: tokens,
                amounts: amounts,
                legs: legs,
                permit: Permit2Data({nonce: 0, deadline: 0, signature: ""})
            })
        );
    }

    // ---------------------------------------------------- Rialto internals

    function _activeRialtoRouter() private view returns (address router) {
        (, address current,, bool paused) = RIALTO_REGISTRY.getFeature(RIALTO_SWAP_FEATURE);
        if (paused) revert RialtoRouterPaused();
        if (current == address(0)) revert RialtoTargetNotRouter();
        return current;
    }

    /// @dev Executes all Rialto mint legs and returns the total input budget
    ///      they were allowed to draw (actual spend can be lower; the router
    ///      refunds unspent input and the final sweep returns it to the payer).
    function _fillOnRialto(
        address paymentCurrency,
        address[] memory tokens,
        uint256[] memory required,
        RialtoCall[] calldata rialtoCalls,
        uint256 maxSpend
    ) private returns (uint256 budget) {
        if (rialtoCalls.length == 0) return 0;
        // the whole Rialto budget must fit under maxSpend BEFORE any call runs
        for (uint256 c = 0; c < rialtoCalls.length; c++) {
            budget += rialtoCalls[c].sellAmount;
        }
        if (budget > maxSpend) revert MaxSpendExceeded(budget, maxSpend);
        address router = _activeRialtoRouter();
        for (uint256 c = 0; c < rialtoCalls.length; c++) {
            RialtoCall calldata call_ = rialtoCalls[c];
            uint256 i = call_.legIndex;
            uint256 before = IERC20(tokens[i]).balanceOf(address(this));
            _rialtoApproveCallReset(router, paymentCurrency, call_);
            if (IERC20(tokens[i]).balanceOf(address(this)) - before < required[i]) revert LegUnderfilled(i);
        }
    }

    /// @dev Redeem-side single Rialto sale of a constituent.
    function _rialtoSwap(address router, address sellToken, RialtoCall calldata call_) private {
        _rialtoApproveCallReset(router, sellToken, call_);
    }

    /// @dev The Rialto integration boundary, per their executor spec: approve
    ///      the quoted spender for exactly `sellAmount`, execute the quote's
    ///      calldata against the registry-resolved router, reset the approval.
    ///      Any revert bubbles up untouched.
    function _rialtoApproveCallReset(address router, address sellToken, RialtoCall calldata call_) private {
        IERC20(sellToken).forceApprove(call_.spender, call_.sellAmount);
        (bool ok, bytes memory ret) = router.call(call_.data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        IERC20(sellToken).forceApprove(call_.spender, 0);
    }
    function _hasUniswapLegs(Hop[][] calldata legs) private pure returns (bool) {
        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].length > 0) return true;
        }
        return false;
    }
    // ------------------------------------------------------------ v4 callback

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        ZapData memory data = abi.decode(rawData, (ZapData));

        uint256 n = data.tokens.length;
        if (data.legs.length != n) revert LegCountMismatch();

        if (data.action == Action.MINT || data.action == Action.QUOTE_MINT) {
            uint256 totalIn = 0;
            uint256[] memory legIn = new uint256[](n);
            for (uint256 i = 0; i < n; i++) {
                if (data.legs[i].length == 0) continue; // leg filled on Rialto before the unlock
                legIn[i] = _swapExactOut(data.legs[i], data.paymentCurrency, data.tokens[i], data.amounts[i], i);
                totalIn += legIn[i];
            }

            if (data.action == Action.QUOTE_MINT) revert QuoteResult(totalIn, legIn);
            if (totalIn > data.limit) revert MaxSpendExceeded(totalIn, data.limit);

            // collect the constituents, then pay the pools once
            for (uint256 i = 0; i < n; i++) {
                if (data.legs[i].length == 0) continue;
                poolManager.take(data.tokens[i], address(this), data.amounts[i]);
            }
            if (data.paymentCurrency == address(0)) {
                poolManager.settle{value: totalIn}();
            } else if (data.permit.signature.length > 0) {
                // Permit2 path: the signed amount is maxSpend, only the
                // actual cost is pulled, straight into the PoolManager
                poolManager.sync(data.paymentCurrency);
                PERMIT2.permitTransferFrom(
                    ISignatureTransfer.PermitTransferFrom({
                        permitted: ISignatureTransfer.TokenPermissions({
                            token: data.paymentCurrency, amount: data.limit
                        }),
                        nonce: data.permit.nonce,
                        deadline: data.permit.deadline
                    }),
                    ISignatureTransfer.SignatureTransferDetails({to: address(poolManager), requestedAmount: totalIn}),
                    data.payer,
                    data.permit.signature
                );
                poolManager.settle();
            } else if (data.payer == address(this)) {
                // v2 mixed-venue path: the payment budget already sits in this
                // contract, so pay the PoolManager directly
                poolManager.sync(data.paymentCurrency);
                IERC20(data.paymentCurrency).safeTransfer(address(poolManager), totalIn);
                poolManager.settle();
            } else {
                poolManager.sync(data.paymentCurrency);
                IERC20(data.paymentCurrency).safeTransferFrom(data.payer, address(poolManager), totalIn);
                poolManager.settle();
            }
            return abi.encode(totalIn);
        }

        // REDEEM / QUOTE_REDEEM
        uint256 totalOut = 0;
        uint256[] memory legOut = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            if (data.legs[i].length == 0) continue; // leg sold on Rialto after the unlock
            legOut[i] = _swapExactIn(data.legs[i], data.tokens[i], data.paymentCurrency, data.amounts[i], i);
            totalOut += legOut[i];
        }

        if (data.action == Action.QUOTE_REDEEM) revert QuoteResult(totalOut, legOut);
        if (totalOut < data.limit) revert MinOutNotMet(totalOut, data.limit);

        for (uint256 i = 0; i < n; i++) {
            if (data.legs[i].length == 0) continue;
            if (data.tokens[i] == address(0)) {
                // native input (the WETH-bridge disposal of zapRedeem4,
                // unwrapped to ETH): settle by value, no ERC20 sync
                poolManager.settle{value: data.amounts[i]}();
            } else {
                poolManager.sync(data.tokens[i]);
                IERC20(data.tokens[i]).safeTransfer(address(poolManager), data.amounts[i]);
                poolManager.settle();
            }
        }
        poolManager.take(data.paymentCurrency, data.recipient, totalOut);
        return abi.encode(totalOut);
    }

    // ------------------------------------------------------------- internals

    /// @dev Walks the path forward to validate it, then executes the hops in
    ///      reverse as chained exact-output swaps. Intermediate currencies
    ///      net to zero inside the unlock; the return value is the exact
    ///      amount of `inputCurrency` owed at the start of the path.
    function _swapExactOut(
        Hop[] memory hops,
        address inputCurrency,
        address outputToken,
        uint256 amountOut,
        uint256 legIndex
    ) private returns (uint256 amountIn) {
        _validatePath(hops, inputCurrency, outputToken, legIndex);

        uint256 need = amountOut;
        for (uint256 j = hops.length; j > 0; j--) {
            Hop memory hop = hops[j - 1];
            int256 delta = poolManager.swap(
                hop.key,
                SwapParams({
                    zeroForOne: hop.zeroForOne,
                    amountSpecified: int256(need), // positive = exact output
                    sqrtPriceLimitX96: hop.zeroForOne
                        ? V4TickMath.MIN_SQRT_PRICE_PLUS_ONE
                        : V4TickMath.MAX_SQRT_PRICE_MINUS_ONE
                }),
                ""
            );
            int128 dOut = hop.zeroForOne ? delta.amount1() : delta.amount0();
            int128 dIn = hop.zeroForOne ? delta.amount0() : delta.amount1();
            // an unlimited-price exact-output swap that runs out of range
            // liquidity fills partially instead of reverting: reject it
            if (dOut < 0 || uint256(uint128(dOut)) != need) revert LegUnderfilled(legIndex);
            need = uint256(uint128(-dIn));
        }
        return need;
    }

    /// @dev Executes the hops forward as chained exact-input swaps and
    ///      returns the amount of the final currency produced.
    function _swapExactIn(
        Hop[] memory hops,
        address inputToken,
        address outputCurrency,
        uint256 amountIn,
        uint256 legIndex
    ) private returns (uint256 amountOut) {
        _validatePath(hops, inputToken, outputCurrency, legIndex);

        uint256 carry = amountIn;
        for (uint256 j = 0; j < hops.length; j++) {
            Hop memory hop = hops[j];
            int256 delta = poolManager.swap(
                hop.key,
                SwapParams({
                    zeroForOne: hop.zeroForOne,
                    amountSpecified: -int256(carry), // negative = exact input
                    sqrtPriceLimitX96: hop.zeroForOne
                        ? V4TickMath.MIN_SQRT_PRICE_PLUS_ONE
                        : V4TickMath.MAX_SQRT_PRICE_MINUS_ONE
                }),
                ""
            );
            int128 dIn = hop.zeroForOne ? delta.amount0() : delta.amount1();
            int128 dOut = hop.zeroForOne ? delta.amount1() : delta.amount0();
            // partial fill = pool ran dry mid-path; the leftover input would
            // strand as an unresolvable delta, so reject
            if (uint256(uint128(-dIn)) != carry) revert LegUnderfilled(legIndex);
            carry = uint256(uint128(dOut));
        }
        return carry;
    }

    function _validatePath(Hop[] memory hops, address from, address to, uint256 legIndex) private pure {
        if (hops.length == 0) revert EmptyPath();
        address current = from;
        for (uint256 j = 0; j < hops.length; j++) {
            address hopIn = hops[j].zeroForOne ? hops[j].key.currency0 : hops[j].key.currency1;
            address hopOut = hops[j].zeroForOne ? hops[j].key.currency1 : hops[j].key.currency0;
            if (hopIn != current) {
                if (j == 0) revert PathInputMismatch(legIndex);
                revert PathDiscontinuous();
            }
            current = hopOut;
        }
        if (current != to) revert PathOutputMismatch(legIndex);
    }

    // ----------------------------------------- v2 pairs & v3 pools (zap v4)

    error ExtBadVenue(uint256 leg);
    error ExtBridgeMismatch(address currency);
    error ExtBridgeDuplicated(address currency);
    error V3CallbackNotPool();

    /// @notice One constituent filled on a Uniswap v2 pair or v3 pool.
    ///         On mint, `amountIn` of `bridge` buys at least the required
    ///         units of the constituent (`grossOut` is the pool-side amount
    ///         to request — above the units for tax-on-swap tokens; the
    ///         constituent balance delta is what is actually enforced).
    ///         On redeem, the redeemed constituent amount is sold for at
    ///         least `grossOut` of `bridge` (`amountIn` is ignored).
    struct ExtCall {
        uint8 venue; // 2 = v2 pair, 3 = v3 pool
        uint256 legIndex;
        address pool;
        bool tokenIs0; // constituent is token0 of the pool
        address bridge; // ERC20 the leg consumes (mint) / produces (redeem)
        uint256 amountIn;
        uint256 grossOut;
    }

    /// @notice Acquisition (mint) / disposal (redeem) of one bridge currency
    ///         on v4. WETH is special-cased: it is bought as native ETH and
    ///         wrapped (mint), or unwrapped and sold as native (redeem). An
    ///         empty route is only valid for WETH when the payment currency
    ///         itself is native ETH (pure wrap from the budget).
    struct BridgeLeg {
        address currency;
        uint256 amount; // mint only: exact amount to buy; redeem sells the measured gain
        Hop[] route;
    }

    /// @dev v3 swap-callback expectations for the one in-flight pool call.
    address private _v3Pool;
    address private _v3PayCurrency;
    uint256 private _v3MaxPay;

    /// @notice Mint `basketAmount` of `basket` to `to`, paying `maxSpend` of
    ///         USDG-like ERC20 or native ETH (paymentCurrency = address(0)),
    ///         with per-constituent venue choice across Uniswap v4 (`legs`),
    ///         Rialto (`rialtoCalls`) and v2/v3 pools (`extCalls`, funded by
    ///         `bridgeLegs`). Same invariants as every other entry point:
    ///         exact fill or revert, refunds in the same transaction, the
    ///         contract holds nothing afterwards.
    function zapMint4(
        address basket,
        uint256 basketAmount,
        address paymentCurrency,
        uint256 maxSpend,
        Hop[][] calldata legs,
        RialtoCall[] calldata rialtoCalls,
        ExtCall[] calldata extCalls,
        BridgeLeg[] calldata bridgeLegs,
        address to,
        uint256 deadline,
        Permit2Data calldata permit
    ) external payable nonReentrant returns (uint256 spent) {
        if (block.timestamp > deadline) revert Expired();
        bool native = paymentCurrency == address(0);
        if (native ? msg.value != maxSpend : msg.value != 0) revert WrongMsgValue();

        (address[] memory tokens, uint256[] memory required) = IBasketToken(basket).getRequiredUnits(basketAmount);
        _checkCoverage4(tokens.length, legs, rialtoCalls, extCalls);
        _checkBridgeSums(paymentCurrency, rialtoCalls, extCalls, bridgeLegs);

        // measure pre-balances so refunds return exactly this tx's leftovers
        uint256 prePay = native ? address(this).balance - msg.value : IERC20(paymentCurrency).balanceOf(address(this));
        if (!native) _pullBudget(paymentCurrency, maxSpend, permit);

        // 1. buy every bridge currency on v4 (or wrap, for WETH paid in ETH)
        uint256 unlockSpent = _buyBridges(paymentCurrency, maxSpend, bridgeLegs);

        // 2. fill the v2/v3 legs from the bridged (or budget) currencies
        _fillExtMint(tokens, required, extCalls);

        // 3. Rialto legs. Their quotes always sell USDG for the constituent,
        //    so the currency they spend is USDG regardless of how the user
        //    paid: the payment budget when paying USDG, or a USDG bridge
        //    bought from ETH above (`_checkBridgeSums` guarantees one exists).
        if (rialtoCalls.length > 0) {
            uint256 rialtoBudget = 0;
            for (uint256 c = 0; c < rialtoCalls.length; c++) {
                rialtoBudget += rialtoCalls[c].sellAmount;
            }
            _fillOnRialto(USDG, tokens, required, rialtoCalls, rialtoBudget);
        }

        // 4. remaining legs on v4
        if (_hasUniswapLegs(legs)) {
            bytes memory r = poolManager.unlock(
                abi.encode(
                    ZapData({
                        action: Action.MINT,
                        paymentCurrency: paymentCurrency,
                        payer: address(this),
                        recipient: address(0),
                        limit: native ? maxSpend - unlockSpent : maxSpend,
                        tokens: tokens,
                        amounts: required,
                        legs: legs,
                        permit: Permit2Data({nonce: 0, deadline: 0, signature: ""})
                    })
                )
            );
            unlockSpent += abi.decode(r, (uint256));
        }

        // 5. mint, then sweep and refund: constituent overshoot (taxed v2 legs
        //    overbuy by design) to the recipient, unspent bridge currencies and
        //    payment budget back to the payer.
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).forceApprove(basket, required[i]);
        }
        IBasketToken(basket).mint(basketAmount, to);

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 bal = IERC20(tokens[i]).balanceOf(address(this));
            if (bal > 0) IERC20(tokens[i]).safeTransfer(to, bal);
        }
        for (uint256 b = 0; b < bridgeLegs.length; b++) {
            uint256 bal = IERC20(bridgeLegs[b].currency).balanceOf(address(this));
            if (bal > 0) IERC20(bridgeLegs[b].currency).safeTransfer(msg.sender, bal);
        }
        if (native) {
            uint256 leftover = address(this).balance - prePay;
            spent = maxSpend - leftover;
            if (leftover > 0) {
                (bool ok,) = msg.sender.call{value: leftover}("");
                if (!ok) revert NativeRefundFailed();
            }
        } else {
            uint256 leftover = IERC20(paymentCurrency).balanceOf(address(this)) - prePay;
            spent = maxSpend - leftover;
            if (leftover > 0) IERC20(paymentCurrency).safeTransfer(msg.sender, leftover);
        }

        emit ZapMinted(msg.sender, basket, paymentCurrency, basketAmount, spent);
    }

    /// @notice Redeem `basketAmount` of `basket`, selling constituents across
    ///         v4 / Rialto / v2 / v3, and deliver at least `minOut` of the
    ///         output currency (ERC20, or native ETH as address(0)) to `to`.
    ///         `bridgeLegs.route` here runs bridge -> output; WETH bridges are
    ///         unwrapped and (if the output is not ETH) sold as native.
    function zapRedeem4(
        address basket,
        uint256 basketAmount,
        address outputCurrency,
        uint256 minOut,
        Hop[][] calldata legs,
        RialtoCall[] calldata rialtoCalls,
        ExtCall[] calldata extCalls,
        BridgeLeg[] calldata bridgeLegs,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256 received) {
        if (block.timestamp > deadline) revert Expired();
        bool native = outputCurrency == address(0);

        uint256 prePay = native ? address(this).balance : IERC20(outputCurrency).balanceOf(address(this));
        uint256[] memory preBridge = new uint256[](bridgeLegs.length);
        for (uint256 b = 0; b < bridgeLegs.length; b++) {
            preBridge[b] = IERC20(bridgeLegs[b].currency).balanceOf(address(this));
        }

        IERC20(basket).safeTransferFrom(msg.sender, address(this), basketAmount);
        (address[] memory tokens, uint256[] memory amounts) = IBasketToken(basket).backingOf(basketAmount);
        _checkCoverage4(tokens.length, legs, rialtoCalls, extCalls);
        IBasketToken(basket).redeem(basketAmount, address(this));

        // Rialto legs sell each constituent for USDG. When the output is USDG
        // that IS the proceeds; otherwise the caller passes a USDG bridge leg
        // and the disposal loop below sells the USDG into the output currency
        // (native ETH included).
        if (rialtoCalls.length > 0) {
            address router = _activeRialtoRouter();
            for (uint256 c = 0; c < rialtoCalls.length; c++) {
                RialtoCall calldata call_ = rialtoCalls[c];
                if (call_.sellAmount != amounts[call_.legIndex]) revert RialtoSellMismatch(call_.legIndex);
                _rialtoSwap(router, tokens[call_.legIndex], call_);
            }
        }

        _fillExtRedeem(tokens, amounts, extCalls);

        if (_hasUniswapLegs(legs)) {
            poolManager.unlock(
                abi.encode(
                    ZapData({
                        action: Action.REDEEM,
                        paymentCurrency: outputCurrency,
                        payer: address(0),
                        recipient: address(this),
                        limit: 0,
                        tokens: tokens,
                        amounts: amounts,
                        legs: legs,
                        permit: Permit2Data({nonce: 0, deadline: 0, signature: ""})
                    })
                )
            );
        }

        // dispose the bridge gains into the output currency
        for (uint256 b = 0; b < bridgeLegs.length; b++) {
            BridgeLeg calldata bl = bridgeLegs[b];
            uint256 gain = IERC20(bl.currency).balanceOf(address(this)) - preBridge[b];
            if (gain == 0) continue;
            if (bl.currency == address(weth)) {
                weth.withdraw(gain);
                if (native) continue; // output is ETH: the unwrap IS the disposal
                _sellViaUnlock(address(0), gain, outputCurrency, bl.route);
            } else {
                if (bl.currency == outputCurrency) continue; // already the output
                _sellViaUnlock(bl.currency, gain, outputCurrency, bl.route);
            }
        }

        received = native
            ? address(this).balance - prePay
            : IERC20(outputCurrency).balanceOf(address(this)) - prePay;
        if (received < minOut) revert MinOutNotMet(received, minOut);
        if (native) {
            (bool ok,) = to.call{value: received}("");
            if (!ok) revert NativeRefundFailed();
        } else {
            IERC20(outputCurrency).safeTransfer(to, received);
        }

        // sweep any constituent or bridge residue to the recipient
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == outputCurrency) continue;
            uint256 dust = IERC20(tokens[i]).balanceOf(address(this));
            if (dust > 0) IERC20(tokens[i]).safeTransfer(to, dust);
        }
        for (uint256 b = 0; b < bridgeLegs.length; b++) {
            if (bridgeLegs[b].currency == outputCurrency) continue;
            uint256 dust = IERC20(bridgeLegs[b].currency).balanceOf(address(this)) - preBridge[b];
            if (dust > 0) IERC20(bridgeLegs[b].currency).safeTransfer(to, dust);
        }

        emit ZapRedeemed(msg.sender, basket, outputCurrency, basketAmount, received);
    }

    // ------------------------------------------------------- ext internals

    function _pullBudget(address currency, uint256 amount, Permit2Data calldata permit) private {
        if (permit.signature.length > 0) {
            PERMIT2.permitTransferFrom(
                ISignatureTransfer.PermitTransferFrom({
                    permitted: ISignatureTransfer.TokenPermissions({token: currency, amount: amount}),
                    nonce: permit.nonce,
                    deadline: permit.deadline
                }),
                ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: amount}),
                msg.sender,
                permit.signature
            );
        } else {
            IERC20(currency).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    /// @dev Buys every bridge currency with the payment budget through the
    ///      audited MINT callback and returns the payment spent. WETH is
    ///      bought as native ETH then wrapped; when the payment itself is
    ///      native ETH an empty route wraps straight from the budget.
    function _buyBridges(address paymentCurrency, uint256 maxSpend, BridgeLeg[] calldata bridgeLegs)
        private
        returns (uint256 unlockSpent)
    {
        for (uint256 b = 0; b < bridgeLegs.length; b++) {
            BridgeLeg calldata bl = bridgeLegs[b];
            bool isWeth = bl.currency == address(weth);
            if (bl.route.length == 0) {
                // pure wrap: only WETH from a native budget qualifies
                if (!isWeth || paymentCurrency != address(0)) revert ExtBridgeMismatch(bl.currency);
                weth.deposit{value: bl.amount}();
                unlockSpent += bl.amount;
                continue;
            }
            address target = isWeth ? address(0) : bl.currency;
            address[] memory tok = new address[](1);
            tok[0] = target;
            uint256[] memory amt = new uint256[](1);
            amt[0] = bl.amount;
            Hop[][] memory oneLeg = new Hop[][](1);
            oneLeg[0] = bl.route;
            bytes memory r = poolManager.unlock(
                abi.encode(
                    ZapData({
                        action: Action.MINT,
                        paymentCurrency: paymentCurrency,
                        payer: address(this),
                        recipient: address(0),
                        limit: maxSpend - unlockSpent,
                        tokens: tok,
                        amounts: amt,
                        legs: oneLeg,
                        permit: Permit2Data({nonce: 0, deadline: 0, signature: ""})
                    })
                )
            );
            unlockSpent += abi.decode(r, (uint256));
            if (isWeth) weth.deposit{value: bl.amount}();
        }
    }

    /// @dev Sells `amount` of `currency` (address(0) = native) for the output
    ///      currency through the audited REDEEM callback, delivered here.
    function _sellViaUnlock(address currency, uint256 amount, address outputCurrency, Hop[] calldata route)
        private
    {
        address[] memory tok = new address[](1);
        tok[0] = currency;
        uint256[] memory amt = new uint256[](1);
        amt[0] = amount;
        Hop[][] memory oneLeg = new Hop[][](1);
        oneLeg[0] = route;
        poolManager.unlock(
            abi.encode(
                ZapData({
                    action: Action.REDEEM,
                    paymentCurrency: outputCurrency,
                    payer: address(0),
                    recipient: address(this),
                    limit: 0,
                    tokens: tok,
                    amounts: amt,
                    legs: oneLeg,
                    permit: Permit2Data({nonce: 0, deadline: 0, signature: ""})
                })
            )
        );
    }

    /// @dev Executes the v2/v3 buy legs. Each leg's constituent delta is
    ///      enforced against the required units — tax-on-swap tokens deliver
    ///      net of tax, which is why `grossOut` may exceed the requirement.
    function _fillExtMint(address[] memory tokens, uint256[] memory required, ExtCall[] calldata extCalls) private {
        for (uint256 c = 0; c < extCalls.length; c++) {
            ExtCall calldata e = extCalls[c];
            uint256 i = e.legIndex;
            uint256 before = IERC20(tokens[i]).balanceOf(address(this));
            if (e.venue == 2) {
                IERC20(e.bridge).safeTransfer(e.pool, e.amountIn);
                (uint256 a0, uint256 a1) = e.tokenIs0 ? (e.grossOut, uint256(0)) : (uint256(0), e.grossOut);
                IUniswapV2Pair(e.pool).swap(a0, a1, address(this), "");
            } else if (e.venue == 3) {
                _v3Pool = e.pool;
                _v3PayCurrency = e.bridge;
                _v3MaxPay = e.amountIn;
                IUniswapV3PoolMinimal(e.pool).swap(
                    address(this),
                    !e.tokenIs0, // paying the non-constituent side
                    -int256(e.grossOut), // exact output in v3
                    !e.tokenIs0 ? V4TickMath.MIN_SQRT_PRICE_PLUS_ONE : V4TickMath.MAX_SQRT_PRICE_MINUS_ONE,
                    ""
                );
                _v3Pool = address(0);
            } else {
                revert ExtBadVenue(i);
            }
            if (IERC20(tokens[i]).balanceOf(address(this)) - before < required[i]) revert LegUnderfilled(i);
        }
    }

    /// @dev Executes the v2/v3 sell legs: the redeemed constituent amounts go
    ///      out, the bridge currencies come back (delta-checked >= grossOut).
    function _fillExtRedeem(address[] memory tokens, uint256[] memory amounts, ExtCall[] calldata extCalls) private {
        for (uint256 c = 0; c < extCalls.length; c++) {
            ExtCall calldata e = extCalls[c];
            uint256 i = e.legIndex;
            uint256 before = IERC20(e.bridge).balanceOf(address(this));
            if (e.venue == 2) {
                IERC20(tokens[i]).safeTransfer(e.pool, amounts[i]);
                (uint256 a0, uint256 a1) = e.tokenIs0 ? (uint256(0), e.grossOut) : (e.grossOut, uint256(0));
                IUniswapV2Pair(e.pool).swap(a0, a1, address(this), "");
            } else if (e.venue == 3) {
                _v3Pool = e.pool;
                _v3PayCurrency = tokens[i];
                _v3MaxPay = amounts[i];
                IUniswapV3PoolMinimal(e.pool).swap(
                    address(this),
                    e.tokenIs0, // paying the constituent side
                    int256(amounts[i]), // exact input in v3
                    e.tokenIs0 ? V4TickMath.MIN_SQRT_PRICE_PLUS_ONE : V4TickMath.MAX_SQRT_PRICE_MINUS_ONE,
                    ""
                );
                _v3Pool = address(0);
            } else {
                revert ExtBadVenue(i);
            }
            if (IERC20(e.bridge).balanceOf(address(this)) - before < e.grossOut) revert LegUnderfilled(i);
        }
    }

    /// @notice Uniswap v3 swap callback: pays the in-flight pool exactly what
    ///         it is owed, in the currency armed by the calling leg, bounded
    ///         by that leg's budget. Reverts for any caller that is not the
    ///         armed pool, so it cannot be used to drain residue.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != _v3Pool || _v3Pool == address(0)) revert V3CallbackNotPool();
        uint256 pay = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        if (pay > _v3MaxPay) revert MaxSpendExceeded(pay, _v3MaxPay);
        IERC20(_v3PayCurrency).safeTransfer(msg.sender, pay);
    }

    /// @dev Every constituent covered by exactly one of: v4 path, Rialto
    ///      call, ext (v2/v3) call.
    function _checkCoverage4(
        uint256 n,
        Hop[][] calldata legs,
        RialtoCall[] calldata rialtoCalls,
        ExtCall[] calldata extCalls
    ) private pure {
        if (legs.length != n) revert LegCountMismatch();
        bool[] memory covered = new bool[](n);
        for (uint256 c = 0; c < rialtoCalls.length; c++) {
            uint256 i = rialtoCalls[c].legIndex;
            if (i >= n || covered[i]) revert LegDoublyCovered(i);
            covered[i] = true;
        }
        for (uint256 c = 0; c < extCalls.length; c++) {
            uint256 i = extCalls[c].legIndex;
            if (i >= n || covered[i]) revert LegDoublyCovered(i);
            covered[i] = true;
        }
        for (uint256 i = 0; i < n; i++) {
            bool uni = legs[i].length > 0;
            if (uni && covered[i]) revert LegDoublyCovered(i);
            if (!uni && !covered[i]) revert LegNotCovered(i);
        }
    }

    /// @dev Each bridge currency appears once and funds exactly the legs
    ///      drawing on it: the ext (v2/v3) legs bridged to it, plus — for USDG
    ///      when paying native ETH — the Rialto legs, whose quotes always sell
    ///      USDG. Legs whose bridge IS the payment currency draw on the main
    ///      budget and need no BridgeLeg (Rialto quotes are USDG, so paying an
    ///      ERC20 other than USDG cannot fund them — rejected).
    function _checkBridgeSums(
        address paymentCurrency,
        RialtoCall[] calldata rialtoCalls,
        ExtCall[] calldata extCalls,
        BridgeLeg[] calldata bridgeLegs
    ) private view {
        bool native = paymentCurrency == address(0);
        uint256 rialtoTotal = 0;
        for (uint256 c = 0; c < rialtoCalls.length; c++) {
            rialtoTotal += rialtoCalls[c].sellAmount;
        }
        // Rialto spends USDG: paying USDG draws from the budget; paying ETH
        // needs a USDG bridge; any other ERC20 payment cannot fund Rialto.
        if (rialtoTotal > 0 && !native && paymentCurrency != USDG) revert ExtBridgeMismatch(USDG);

        for (uint256 b = 0; b < bridgeLegs.length; b++) {
            address cur = bridgeLegs[b].currency;
            if (cur == paymentCurrency || cur == address(0)) revert ExtBridgeMismatch(cur);
            for (uint256 q = 0; q < b; q++) {
                if (bridgeLegs[q].currency == cur) revert ExtBridgeDuplicated(cur);
            }
            uint256 sum = 0;
            for (uint256 c = 0; c < extCalls.length; c++) {
                if (extCalls[c].bridge == cur) sum += extCalls[c].amountIn;
            }
            if (cur == USDG && native) sum += rialtoTotal; // USDG bridge also funds Rialto
            if (sum != bridgeLegs[b].amount) revert ExtBridgeMismatch(cur);
        }
        // every ext bridge is either the payment currency or has a BridgeLeg
        for (uint256 c = 0; c < extCalls.length; c++) {
            address cur = extCalls[c].bridge;
            if (cur == paymentCurrency) continue;
            bool found = false;
            for (uint256 b = 0; b < bridgeLegs.length; b++) {
                if (bridgeLegs[b].currency == cur) {
                    found = true;
                    break;
                }
            }
            if (!found) revert ExtBridgeMismatch(cur);
        }
        // native + Rialto requires a USDG bridge to source the Rialto USDG
        if (rialtoTotal > 0 && native) {
            bool found = false;
            for (uint256 b = 0; b < bridgeLegs.length; b++) {
                if (bridgeLegs[b].currency == USDG) {
                    found = true;
                    break;
                }
            }
            if (!found) revert ExtBridgeMismatch(USDG);
        }
    }
}
