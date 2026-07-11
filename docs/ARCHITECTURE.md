# Architecture

```
                     ┌─────────────────────────────┐
   Chainlink feeds ──┤  scripts/computeUnits.ts    │   deploy-time only
   (off-chain read)  │  equal weights → raw units  │
                     └──────────────┬──────────────┘
                                    │ baskets/*.json
                                    ▼
                     ┌─────────────────────────────┐
        user ──────► │  BasketToken (per basket)   │ ◄────── guardian (Safe)
   mint / redeem     │  immutable, no oracles      │   pause-mint / cap /
   (in-kind, ERC-20) │  holds constituents 1:1     │   fee recipient ONLY
                     └──────────────┬──────────────┘
                                    │ reads (units, supply, events)
                                    ▼
                     ┌─────────────────────────────┐
   Chainlink feeds ──┤  frontend (Next.js, edge)   │   display-time only
   (client read)     │  NAV, drift, badges, geoblk │
                     └─────────────────────────────┘
```

## Design invariants

1. **Full backing.** For every constituent *i*:
   `balanceOf(vault) ≥ ceil(totalSupply × units[i] / 1e18)` after any call
   sequence. Enforced by ceil-on-mint + balance-delta checks + floor-on-redeem;
   proven by the invariant suite.
2. **Redeem is ungated.** No state (pause, cap, guardian action) can make
   `redeem` revert for a solvent holder. The only external failure mode is a
   constituent token itself reverting transfers (issuer freeze).
3. **Zero oracle dependence on-chain.** Prices exist only (a) off-chain at
   deploy to pick units, (b) in the frontend for display with staleness rules.
4. **Raw amounts only.** ERC-8056 `uiMultiplier` is never read on-chain;
   corporate actions cannot desync the vault.

## Why fee-in-basket-tokens

Taking the mint fee in basket tokens (not by skimming constituents) means every
outstanding basket wei — user's or fee recipient's — is backed by the same
deposit that minted it. The invariant needs no special case for fees.

## Rounding budget

Mint rounds each deposit up by <1 wei/constituent; redeem rounds each payout
down by <1 wei/constituent. A full roundtrip costs a user at most
`nConstituents` wei of constituents — economically nil at 18 decimals — and the
dust accrues to the vault, never the other way. Fuzz-tested bound: exactly
`[required − 1 wei, required]` per token.

## Chain specifics

- Robinhood Chain is Arbitrum Orbit/Nitro; standard EVM, ~100ms blocks,
  single sequencer. Finality: soft on sequencer, hard on Ethereum.
- Stock Tokens: ERC-20, 18 decimals, freely transferable by contracts;
  "indices & baskets" is an explicitly invited use case in the official docs.
- Fake tokens with identical tickers exist — addresses are always re-verified
  against the docs page and on-chain `symbol()`/`decimals()` before deploy.
