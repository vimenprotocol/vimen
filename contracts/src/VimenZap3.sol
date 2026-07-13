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

/// @title VimenZap3 — single-transaction basket mint/redeem against Uniswap v4
///        and Rialto (PropAMM spot exchange), venue-selectable per constituent
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

contract VimenZap3 is IUnlockCallback, ReentrancyGuard {
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
    error NativeNotSupported();
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

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    /// @dev Accept native ETH: the PoolManager sends it here via `take` on the
    ///      ETH-output redeem paths, and native-ETH mints refund through here.
    ///      Only the PoolManager and refunds ever pay in; the contract holds no
    ///      ETH between transactions.
    receive() external payable {}

    // ------------------------------------------------------------------ mint

    /// @notice Buy every constituent of `basket` for exactly `basketAmount`
    ///         and mint it to `to`, paying at most `maxSpend` of
    ///         `paymentCurrency` (address(0) = native ETH, sent as msg.value).
    /// @param legs One swap path per constituent, in `constituents()` order.
    /// @return spent The exact amount of `paymentCurrency` consumed.
    function zapMint(
        address basket,
        uint256 basketAmount,
        address paymentCurrency,
        uint256 maxSpend,
        Hop[][] calldata legs,
        address to,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 spent) {
        if (block.timestamp > deadline) revert Expired();
        if (paymentCurrency == address(0)) {
            if (msg.value != maxSpend) revert WrongMsgValue();
        } else {
            if (msg.value != 0) revert WrongMsgValue();
        }

        (address[] memory tokens, uint256[] memory required) = IBasketToken(basket).getRequiredUnits(basketAmount);

        spent = _runMint(
            basket,
            basketAmount,
            paymentCurrency,
            maxSpend,
            legs,
            to,
            tokens,
            required,
            Permit2Data({nonce: 0, deadline: 0, signature: ""})
        );

        if (paymentCurrency == address(0) && msg.value > spent) {
            (bool ok,) = msg.sender.call{value: msg.value - spent}("");
            if (!ok) revert NativeRefundFailed();
        }
    }

    /// @notice `zapMint` without the approve transaction: the payer signs a
    ///         Permit2 SignatureTransfer for (paymentCurrency, maxSpend,
    ///         spender = this router) and USDG flows straight into the
    ///         PoolManager. One signature, one transaction, no allowance
    ///         left behind. Requires the once-ever ERC-20 approval of the
    ///         payment token to Permit2 itself.
    function zapMintPermit2(
        address basket,
        uint256 basketAmount,
        address paymentCurrency,
        uint256 maxSpend,
        Hop[][] calldata legs,
        address to,
        uint256 deadline,
        Permit2Data calldata permit
    ) external nonReentrant returns (uint256 spent) {
        if (block.timestamp > deadline) revert Expired();
        if (paymentCurrency == address(0) || permit.signature.length == 0) revert WrongMsgValue();

        (address[] memory tokens, uint256[] memory required) = IBasketToken(basket).getRequiredUnits(basketAmount);
        spent = _runMint(basket, basketAmount, paymentCurrency, maxSpend, legs, to, tokens, required, permit);
    }

    function _runMint(
        address basket,
        uint256 basketAmount,
        address paymentCurrency,
        uint256 maxSpend,
        Hop[][] calldata legs,
        address to,
        address[] memory tokens,
        uint256[] memory required,
        Permit2Data memory permit
    ) private returns (uint256 spent) {
        // v1 entry points cover every leg on Uniswap; only the v2 mixed-venue
        // paths (guarded by _checkCoverage) may leave a leg empty. Reject empty
        // legs here so the callback's mixed-venue skip can never strand a
        // constituent on a single-venue mint.
        _requireAllPaths(legs);
        bytes memory result = poolManager.unlock(
            abi.encode(
                ZapData({
                    action: Action.MINT,
                    paymentCurrency: paymentCurrency,
                    payer: msg.sender,
                    recipient: address(0),
                    limit: maxSpend,
                    tokens: tokens,
                    amounts: required,
                    legs: legs,
                    permit: permit
                })
            )
        );
        spent = abi.decode(result, (uint256));

        // The swaps delivered the exact required amounts; the basket pulls
        // them all, so allowances return to zero by construction.
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).forceApprove(basket, required[i]);
        }
        IBasketToken(basket).mint(basketAmount, to);

        emit ZapMinted(msg.sender, basket, paymentCurrency, basketAmount, spent);
    }

    // ---------------------------------------------------------------- redeem

    /// @notice Burn `basketAmount` of `basket` (caller must approve this
    ///         contract), sell every constituent along `legs` and send at
    ///         least `minOut` of `outputCurrency` to `to`.
    /// @return received The exact amount of `outputCurrency` delivered.
    function zapRedeem(
        address basket,
        uint256 basketAmount,
        address outputCurrency,
        uint256 minOut,
        Hop[][] calldata legs,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256 received) {
        if (block.timestamp > deadline) revert Expired();
        _requireAllPaths(legs); // single-venue redeem: every leg sells on Uniswap

        IERC20(basket).safeTransferFrom(msg.sender, address(this), basketAmount);
        (address[] memory tokens, uint256[] memory amounts) = IBasketToken(basket).backingOf(basketAmount);
        IBasketToken(basket).redeem(basketAmount, address(this));

        bytes memory result = poolManager.unlock(
            abi.encode(
                ZapData({
                    action: Action.REDEEM,
                    paymentCurrency: outputCurrency,
                    payer: address(0),
                    recipient: to,
                    limit: minOut,
                    tokens: tokens,
                    amounts: amounts,
                    legs: legs,
                    permit: Permit2Data({nonce: 0, deadline: 0, signature: ""})
                })
            )
        );
        received = abi.decode(result, (uint256));

        emit ZapRedeemed(msg.sender, basket, outputCurrency, basketAmount, received);
    }

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

    // -------------------------------------------------------- mixed-venue v2

    /// @notice `zapMint` with per-constituent venue choice: legs with a
    ///         non-empty Uniswap path fill on v4 exactly as v1; legs listed in
    ///         `rialtoCalls` fill on Rialto with calldata from its quote API.
    ///         ERC20 payment only. The whole budget (`maxSpend`) moves into
    ///         this contract first, both venues draw from it, and whatever is
    ///         left flows back to the payer in the same transaction — the
    ///         contract holds nothing afterwards, as always.
    /// @dev    Every constituent must be covered by exactly one venue. The
    ///         Rialto call target is always the router resolved from Rialto's
    ///         on-chain registry, never an address from calldata.
    function zapMint2(
        address basket,
        uint256 basketAmount,
        address paymentCurrency,
        uint256 maxSpend,
        Hop[][] calldata legs,
        RialtoCall[] calldata rialtoCalls,
        address to,
        uint256 deadline,
        Permit2Data calldata permit
    ) external nonReentrant returns (uint256 spent) {
        if (block.timestamp > deadline) revert Expired();
        if (paymentCurrency == address(0)) revert NativeNotSupported();

        (address[] memory tokens, uint256[] memory required) = IBasketToken(basket).getRequiredUnits(basketAmount);
        _checkCoverage(tokens.length, legs, rialtoCalls);

        // measure the payment balance BEFORE pulling the budget, so the final
        // refund returns exactly this tx's unspent amount even if someone has
        // donated payment currency to the contract (no donation-driven
        // under/overflow of `spent`, no accidental sweep of foreign residue).
        uint256 prePay = IERC20(paymentCurrency).balanceOf(address(this));

        // pull the whole budget in, from allowance or via one Permit2 signature
        if (permit.signature.length > 0) {
            PERMIT2.permitTransferFrom(
                ISignatureTransfer.PermitTransferFrom({
                    permitted: ISignatureTransfer.TokenPermissions({token: paymentCurrency, amount: maxSpend}),
                    nonce: permit.nonce,
                    deadline: permit.deadline
                }),
                ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: maxSpend}),
                msg.sender,
                permit.signature
            );
        } else {
            IERC20(paymentCurrency).safeTransferFrom(msg.sender, address(this), maxSpend);
        }

        // Rialto legs first: plain ERC20 world, exact approvals, delta-checked
        uint256 rialtoBudget = _fillOnRialto(paymentCurrency, tokens, required, rialtoCalls, maxSpend);

        // Uniswap legs inside the unlock, paying from this contract's balance
        uint256 uniIn = 0;
        if (_hasUniswapLegs(legs)) {
            bytes memory result = poolManager.unlock(
                abi.encode(
                    ZapData({
                        action: Action.MINT,
                        paymentCurrency: paymentCurrency,
                        payer: address(this),
                        recipient: address(0),
                        limit: maxSpend - rialtoBudget,
                        tokens: tokens,
                        amounts: required,
                        legs: legs,
                        permit: Permit2Data({nonce: 0, deadline: 0, signature: ""})
                    })
                )
            );
            uniIn = abi.decode(result, (uint256));
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).forceApprove(basket, required[i]);
        }
        IBasketToken(basket).mint(basketAmount, to);

        // Rialto legs are exact-input: any constituent overshoot goes to the
        // recipient, and the unspent payment budget (this tx's, measured
        // against the pre-pull balance) returns to the payer.
        _sweepSurplus(tokens, rialtoCalls, to);
        uint256 leftover = IERC20(paymentCurrency).balanceOf(address(this)) - prePay;
        if (leftover > 0) IERC20(paymentCurrency).safeTransfer(msg.sender, leftover);
        spent = maxSpend - leftover;

        emit ZapMinted(msg.sender, basket, paymentCurrency, basketAmount, spent);
    }

    /// @notice `zapRedeem` with per-constituent venue choice. Constituents
    ///         listed in `rialtoCalls` are sold on Rialto (exact-input fits a
    ///         redeem natively: `sellAmount` must equal the redeemed amount);
    ///         the rest sell on Uniswap v4 as v1. ERC20 output only.
    function zapRedeem2(
        address basket,
        uint256 basketAmount,
        address outputCurrency,
        uint256 minOut,
        Hop[][] calldata legs,
        RialtoCall[] calldata rialtoCalls,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256 received) {
        if (block.timestamp > deadline) revert Expired();
        if (outputCurrency == address(0)) revert NativeNotSupported();

        IERC20(basket).safeTransferFrom(msg.sender, address(this), basketAmount);
        (address[] memory tokens, uint256[] memory amounts) = IBasketToken(basket).backingOf(basketAmount);
        _checkCoverage(tokens.length, legs, rialtoCalls);
        IBasketToken(basket).redeem(basketAmount, address(this));

        // Rialto legs: sell the exact redeemed constituent amounts
        address router = _activeRialtoRouter();
        for (uint256 c = 0; c < rialtoCalls.length; c++) {
            RialtoCall calldata call_ = rialtoCalls[c];
            if (call_.sellAmount != amounts[call_.legIndex]) revert RialtoSellMismatch(call_.legIndex);
            _rialtoSwap(router, tokens[call_.legIndex], call_);
        }

        if (_hasUniswapLegs(legs)) {
            poolManager.unlock(
                abi.encode(
                    ZapData({
                        action: Action.REDEEM,
                        paymentCurrency: outputCurrency,
                        payer: address(0),
                        recipient: address(this),
                        limit: 0, // enforced on the combined total below
                        tokens: tokens,
                        amounts: amounts,
                        legs: legs,
                        permit: Permit2Data({nonce: 0, deadline: 0, signature: ""})
                    })
                )
            );
        }

        received = IERC20(outputCurrency).balanceOf(address(this));
        if (received < minOut) revert MinOutNotMet(received, minOut);
        IERC20(outputCurrency).safeTransfer(to, received);

        // Defence-in-depth: an exact-input Rialto router should consume the
        // whole approved sellAmount, but if a leg leaves constituent wei
        // behind, sweep it to the recipient rather than let it strand in the
        // (immutable, zero-balance-invariant) contract for the next caller.
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == outputCurrency) continue; // already delivered above
            uint256 dust = IERC20(tokens[i]).balanceOf(address(this));
            if (dust > 0) IERC20(tokens[i]).safeTransfer(to, dust);
        }

        emit ZapRedeemed(msg.sender, basket, outputCurrency, basketAmount, received);
    }

    // ------------------------------------------------- native-ETH mixed (v3)

    /// @dev Global Dollar (USDG), the intermediary currency for Rialto legs on
    ///      the native-ETH paths. Canonical on Robinhood Chain, verified.
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    /// @notice Mint paying native ETH, mixing Uniswap v4 and Rialto per leg.
    ///         Rialto only quotes USDG->stock, so the exact USDG the Rialto
    ///         legs need is bought first with ETH on the deep ETH/USDG pair
    ///         (`ethToUsdgRoute`), then spent on Rialto; the Uniswap legs are
    ///         paid straight in ETH. Both ETH swaps reuse the audited MINT
    ///         callback. Whatever ETH is left returns to the payer; the
    ///         contract holds nothing of this tx afterwards.
    /// @dev    `ethToUsdgRoute` must end at USDG (enforced by the callback's
    ///         path check); every constituent must be covered by exactly one
    ///         venue (`_checkCoverage`). Rialto call targets are always the
    ///         registry-resolved router, never from calldata.
    function zapMintEth(
        address basket,
        uint256 basketAmount,
        uint256 maxSpendEth,
        Hop[][] calldata legs,
        RialtoCall[] calldata rialtoCalls,
        Hop[] calldata ethToUsdgRoute,
        address to,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 spent) {
        if (block.timestamp > deadline) revert Expired();
        if (msg.value != maxSpendEth) revert WrongMsgValue();

        (address[] memory tokens, uint256[] memory required) = IBasketToken(basket).getRequiredUnits(basketAmount);
        _checkCoverage(tokens.length, legs, rialtoCalls);

        // measure USDG before buying any, so a Rialto router that under-consumes
        // its approved input leaves no strandable USDG (mirrors v2 zapMint2's
        // payment-currency refund; keeps the zero-balance invariant intact).
        uint256 preUsdg = IERC20(USDG).balanceOf(address(this));
        uint256 ethSpent = 0;

        // 1. Buy exactly the USDG the Rialto legs need, paying ETH, through the
        //    MINT callback (USDG treated as the single "constituent" to buy).
        uint256 rialtoBudget = 0;
        for (uint256 c = 0; c < rialtoCalls.length; c++) {
            rialtoBudget += rialtoCalls[c].sellAmount;
        }
        if (rialtoBudget > 0) {
            address[] memory usdgTok = new address[](1);
            usdgTok[0] = USDG;
            uint256[] memory usdgAmt = new uint256[](1);
            usdgAmt[0] = rialtoBudget;
            Hop[][] memory usdgLeg = new Hop[][](1);
            usdgLeg[0] = ethToUsdgRoute;
            bytes memory r = poolManager.unlock(
                abi.encode(
                    ZapData({
                        action: Action.MINT,
                        paymentCurrency: address(0),
                        payer: address(this),
                        recipient: address(0),
                        limit: maxSpendEth,
                        tokens: usdgTok,
                        amounts: usdgAmt,
                        legs: usdgLeg,
                        permit: Permit2Data({nonce: 0, deadline: 0, signature: ""})
                    })
                )
            );
            ethSpent += abi.decode(r, (uint256));

            // 2. Rialto legs from the USDG just bought (approve USDG, exact,
            //    reset, per-leg constituent delta check — unchanged from v2).
            _fillOnRialto(USDG, tokens, required, rialtoCalls, rialtoBudget);
        }

        // 3. Uniswap legs, paid straight in ETH, through the MINT callback.
        if (_hasUniswapLegs(legs)) {
            bytes memory r2 = poolManager.unlock(
                abi.encode(
                    ZapData({
                        action: Action.MINT,
                        paymentCurrency: address(0),
                        payer: address(this),
                        recipient: address(0),
                        limit: maxSpendEth - ethSpent,
                        tokens: tokens,
                        amounts: required,
                        legs: legs,
                        permit: Permit2Data({nonce: 0, deadline: 0, signature: ""})
                    })
                )
            );
            ethSpent += abi.decode(r2, (uint256));
        }

        // 4. Mint the basket to the recipient.
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).forceApprove(basket, required[i]);
        }
        IBasketToken(basket).mint(basketAmount, to);

        // 5. Constituent overshoot to the recipient; any USDG a Rialto router
        //    left unconsumed back to the payer; unspent ETH to the payer.
        //    `ethSpent` is summed from the unlock returns (not a balance diff),
        //    so a native donation to the contract cannot inflate the refund.
        _sweepSurplus(tokens, rialtoCalls, to);
        uint256 usdgLeft = IERC20(USDG).balanceOf(address(this)) - preUsdg;
        if (usdgLeft > 0) IERC20(USDG).safeTransfer(msg.sender, usdgLeft);
        uint256 leftover = maxSpendEth - ethSpent;
        if (leftover > 0) {
            (bool ok,) = msg.sender.call{value: leftover}("");
            if (!ok) revert NativeRefundFailed();
        }
        spent = ethSpent;

        emit ZapMinted(msg.sender, basket, address(0), basketAmount, spent);
    }

    /// @notice Redeem receiving native ETH, mixing Uniswap and Rialto per leg.
    ///         Rialto legs sell the constituent for USDG; the Uniswap legs sell
    ///         straight to ETH; the USDG from Rialto is then swapped to ETH on
    ///         the deep pair (`usdgToEthRoute`), and the combined ETH, floored
    ///         by `minOutEth`, goes to `to`.
    function zapRedeemEth(
        address basket,
        uint256 basketAmount,
        uint256 minOutEth,
        Hop[][] calldata legs,
        RialtoCall[] calldata rialtoCalls,
        Hop[] calldata usdgToEthRoute,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256 received) {
        if (block.timestamp > deadline) revert Expired();

        // isolate this tx's ETH gain from any pre-existing/donated balance
        uint256 preEth = address(this).balance;

        IERC20(basket).safeTransferFrom(msg.sender, address(this), basketAmount);
        (address[] memory tokens, uint256[] memory amounts) = IBasketToken(basket).backingOf(basketAmount);
        _checkCoverage(tokens.length, legs, rialtoCalls);
        IBasketToken(basket).redeem(basketAmount, address(this));

        // Rialto legs: sell the exact redeemed constituent amounts for USDG.
        address router = _activeRialtoRouter();
        uint256 preUsdg = IERC20(USDG).balanceOf(address(this));
        for (uint256 c = 0; c < rialtoCalls.length; c++) {
            RialtoCall calldata call_ = rialtoCalls[c];
            if (call_.sellAmount != amounts[call_.legIndex]) revert RialtoSellMismatch(call_.legIndex);
            _rialtoSwap(router, tokens[call_.legIndex], call_);
        }

        // Uniswap legs: sell straight to native ETH, delivered to this contract.
        if (_hasUniswapLegs(legs)) {
            poolManager.unlock(
                abi.encode(
                    ZapData({
                        action: Action.REDEEM,
                        paymentCurrency: address(0),
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

        // Swap the USDG the Rialto legs produced (this tx only) into ETH.
        uint256 usdgGained = IERC20(USDG).balanceOf(address(this)) - preUsdg;
        if (usdgGained > 0) {
            address[] memory usdgTok = new address[](1);
            usdgTok[0] = USDG;
            uint256[] memory usdgAmt = new uint256[](1);
            usdgAmt[0] = usdgGained;
            Hop[][] memory usdgLeg = new Hop[][](1);
            usdgLeg[0] = usdgToEthRoute;
            poolManager.unlock(
                abi.encode(
                    ZapData({
                        action: Action.REDEEM,
                        paymentCurrency: address(0),
                        payer: address(0),
                        recipient: address(this),
                        limit: 0,
                        tokens: usdgTok,
                        amounts: usdgAmt,
                        legs: usdgLeg,
                        permit: Permit2Data({nonce: 0, deadline: 0, signature: ""})
                    })
                )
            );
        }

        received = address(this).balance - preEth;
        if (received < minOutEth) revert MinOutNotMet(received, minOutEth);
        (bool ok,) = to.call{value: received}("");
        if (!ok) revert NativeRefundFailed();

        // Defence-in-depth: sweep any unsold constituent wei AND any USDG the
        // conversion left behind (e.g. an empty/under-consuming usdgToEthRoute)
        // to the recipient, so nothing strands in the zero-balance contract.
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 dust = IERC20(tokens[i]).balanceOf(address(this));
            if (dust > 0) IERC20(tokens[i]).safeTransfer(to, dust);
        }
        uint256 usdgDust = IERC20(USDG).balanceOf(address(this)) - preUsdg;
        if (usdgDust > 0) IERC20(USDG).safeTransfer(to, usdgDust);

        emit ZapRedeemed(msg.sender, basket, address(0), basketAmount, received);
    }

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

    /// @dev Every leg is covered by exactly one venue: a non-empty Uniswap
    ///      path XOR a Rialto call.
    function _checkCoverage(uint256 n, Hop[][] calldata legs, RialtoCall[] calldata rialtoCalls) private pure {
        if (legs.length != n) revert LegCountMismatch();
        bool[] memory rialto = new bool[](n);
        for (uint256 c = 0; c < rialtoCalls.length; c++) {
            uint256 i = rialtoCalls[c].legIndex;
            if (i >= n || rialto[i]) revert LegDoublyCovered(i);
            rialto[i] = true;
        }
        for (uint256 i = 0; i < n; i++) {
            bool uni = legs[i].length > 0;
            if (uni && rialto[i]) revert LegDoublyCovered(i);
            if (!uni && !rialto[i]) revert LegNotCovered(i);
        }
    }

    function _hasUniswapLegs(Hop[][] calldata legs) private pure returns (bool) {
        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].length > 0) return true;
        }
        return false;
    }

    /// @dev Rejects any empty leg. The callback silently skips empty legs (they
    ///      are the Rialto-covered slots of a v2 mixed-venue zap); the v1
    ///      single-venue entry points call this first so a stray empty leg can
    ///      never reach the callback and strand an unswapped constituent.
    function _requireAllPaths(Hop[][] calldata legs) private pure {
        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].length == 0) revert EmptyPath();
        }
    }

    function _sweepSurplus(address[] memory tokens, RialtoCall[] calldata rialtoCalls, address to) private {
        for (uint256 c = 0; c < rialtoCalls.length; c++) {
            IERC20 t = IERC20(tokens[rialtoCalls[c].legIndex]);
            uint256 bal = t.balanceOf(address(this));
            if (bal > 0) t.safeTransfer(to, bal);
        }
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
            poolManager.sync(data.tokens[i]);
            IERC20(data.tokens[i]).safeTransfer(address(poolManager), data.amounts[i]);
            poolManager.settle();
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
}
