# Vimen — the market, woven into one token

*On-chain index baskets on Robinhood Chain — [app.vimen.org](https://app.vimen.org) · [@vimenprotocol](https://x.com/vimenprotocol)*

[![CI](https://github.com/vimenprotocol/vimen/actions/workflows/ci.yml/badge.svg)](https://github.com/vimenprotocol/vimen/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-teal.svg)](LICENSE)
[![Solidity 0.8.24](https://img.shields.io/badge/Solidity-0.8.24-2b247c.svg)](contracts/)

This repository contains the on-chain protocol: contracts, tests, deploy
tooling and documentation. The hosted app lives at
[app.vimen.org](https://app.vimen.org).

Permissionless "mini-ETFs" on [Robinhood Chain](https://docs.robinhood.com/chain) (chain id 4663).
A basket token is an ERC-20 fully backed by fixed raw quantities of Robinhood
Stock Tokens held by its own immutable contract. Mint deposits the constituents
in-kind; redeem burns and returns them. **No oracles in the core. No admin keys
over funds. Redeem always works.**

| Basket | Symbol | Constituents | Contract (Robinhood Chain) |
|---|---|---|---|
| Magnificent 7 | `MAG7` | AAPL MSFT GOOGL AMZN META NVDA TSLA | [`0xe1c1ADAD813736427B334e798fd2EbC7d2C7A9DF`](https://robinhoodchain.blockscout.com/address/0xe1c1ADAD813736427B334e798fd2EbC7d2C7A9DF) |
| The Hood Six | `HOOD6` | CASHCAT ARROW HOODRAT VIBECAT VEX VIRTUAL | [`0x0CE04932513Fa1768B5b9444c6A21Ae0DdA005C5`](https://robinhoodchain.blockscout.com/address/0x0CE04932513Fa1768B5b9444c6A21Ae0DdA005C5) |
| The AI Six | `AI6` | NVDA AMD MU PLTR GOOGL SPCX | [`0x8fF1d77a09A3292b34457175710Bb0C0A1C22601`](https://robinhoodchain.blockscout.com/address/0x8fF1d77a09A3292b34457175710Bb0C0A1C22601) |

All three deployed 2026-07-12 with source verified on Blockscout, plus
[`VimenZap2`](https://robinhoodchain.blockscout.com/address/0x7cE8cC58746cf16d415B6244FC178A67f3ABc776)
(`0x7cE8cC58746cf16d415B6244FC178A67f3ABc776`), the single-transaction
mint/redeem router over Uniswap v4 and Rialto (supersedes
[`v1`](https://robinhoodchain.blockscout.com/address/0x0bFE35e6C22aDB35139841c8c9BeA367bc627458), which
remains live and functional). Guardian and fee recipient of every basket is
the protocol Safe
[`0xc7aBc67fBB12B69240A4C213c39547C8a345Ec02`](https://robinhoodchain.blockscout.com/address/0xc7aBc67fBB12B69240A4C213c39547C8a345Ec02).

Alongside the baskets ships **VimenZap** — a stateless Uniswap v4 router that
mints or redeems a basket in a single transaction from one asset — and a
curator platform (VIMEN staking, permissionless basket publishing) slated for
a later phase.

## V2 — agentic baskets (platform live 2026-07-18)

The second shelf: baskets whose recipe an **agent** rotates over time, inside
a policy the contract enforces — while mint/redeem stay byte-for-byte V1.
`BasketToken2` allows exactly one new mutation, `rebalance`, bounded by
immutable ceilings: cooldown ≥ 1 day, turnover ≤ 25% of NAV, slippage ≤ 1% of
NAV per rebalance, buys only from a Safe-curated asset registry (sells always
allowed), and full backing recomputed from real balances after every trade.
Rebalance surplus is swept to a per-basket `BasketDistributor` and pushed to
holders in USDG. A worst-case agent key can cost at most the slippage budget
per cooldown window — it can never touch custody, block redemption, or route
value anywhere but the holders' distributor.

Chain natives are priced through manipulation-resistant TWAP adapters
(`PoolTwapObserver` median for v4 pools, cumulative-price windows for v2
pairs) that answer with the same `latestRoundData` shape as Chainlink — and
report *stale* rather than a guessable price when a window is uncovered.

| Contract | Address (Robinhood Chain) |
|---|---|
| `BasketFactory2` | [`0x1A3e4B71c58f77a995c1a4C7D76A4296CFDDd489`](https://robinhoodchain.blockscout.com/address/0x1A3e4B71c58f77a995c1a4C7D76A4296CFDDd489) |
| `BasketTokenDeployer` | [`0x42E65A72AF9FeB459C2ab5CDfd506EAD18014bd8`](https://robinhoodchain.blockscout.com/address/0x42E65A72AF9FeB459C2ab5CDfd506EAD18014bd8) |
| `AssetRegistry` | [`0x53B255bff87450979c459cC91aFA47A3B93f81fb`](https://robinhoodchain.blockscout.com/address/0x53B255bff87450979c459cC91aFA47A3B93f81fb) |
| `MakerRegistry` | [`0x4Ce4CAC5439B5aB758B8F156f93D1B8cD8E45779`](https://robinhoodchain.blockscout.com/address/0x4Ce4CAC5439B5aB758B8F156f93D1B8cD8E45779) |
| `FeeSplitter` (V2) | [`0x659d5A6aA4017f034FBee9778B3541A2dcc17653`](https://robinhoodchain.blockscout.com/address/0x659d5A6aA4017f034FBee9778B3541A2dcc17653) |
| `PoolTwapObserver` | [`0x4E03522f038F4d0dEA65e72a8A1eD22c06d05AAE`](https://robinhoodchain.blockscout.com/address/0x4E03522f038F4d0dEA65e72a8A1eD22c06d05AAE) |
| `PoolMaker` | [`0x915c32c68CD501587E701Bf344791f5d90078C64`](https://robinhoodchain.blockscout.com/address/0x915c32c68CD501587E701Bf344791f5d90078C64) |

Plus fifteen per-asset TWAP feeds (six v4, nine v2), all source-verified on
Blockscout. Curation is two-tier and burn-gated: 10,000 VIM for frozen
baskets, 25,000 VIM for agentic ones (legacy 25k burns are grandfathered).
The first agentic baskets are opening now; docs:
[docs.vimen.org/docs/agentic](https://docs.vimen.org/docs/agentic).

## How it works

- Units are fixed **raw** ERC-20 amounts per 1e18 basket wei, computed once at
  deploy from live Chainlink prices (equal USD weight, ≈$100/token target).
  Weights drift with prices afterwards, like an unrebalanced ETF.
- Stock Tokens implement ERC-8056 (scaled UI amounts). Corporate actions change
  the display multiplier, never raw balances — so the contract ignores the
  multiplier entirely and stays exact through splits and reinvested dividends.
- Rounding always favors the vault: deposits round up, redemptions round down
  (≤1 wei per constituent per operation).
- Mint fee 0.30% (hard-capped at 0.50% in code), taken in basket tokens so the
  backing invariant stays exact. **Redeem is free and ungated, forever.**
- A guardian (Safe) can only: pause minting, move the supply cap under an
  immutable ceiling, and change the fee recipient. Nothing else exists.

Full threat model, accepted static-analysis findings and spec deviations:
[SECURITY.md](SECURITY.md).

## Repository layout

```
contracts/   Foundry — BasketToken, VimenZap (Uniswap v4 router), curator
             platform (CuratorRegistry, BasketFactory, FeeSplitter, VimenToken)
             + unit/fuzz/invariant/fork tests
scripts/     computeUnits.ts — converts equal weights into raw units at deploy
docs/        architecture, deploy runbook, tokenomics, zap design, roadmap
```

## Development

```bash
# clone with the OpenZeppelin submodule (pinned to v5.6.1)
git clone --recurse-submodules https://github.com/vimenprotocol/vimen.git

# contracts — 107 tests: unit, fuzz, invariant + fork suites
cd contracts && forge test

# fork tests against Robinhood Chain mainnet (self-skip when RH_RPC is unset)
RH_RPC=https://rpc.mainnet.chain.robinhood.com forge test --match-contract Fork
```

CI runs `forge fmt --check`, the full test suite and scripts typecheck on
every push ([ci.yml](.github/workflows/ci.yml)).

## Deposit-cap roadmap

Deposits are capped per basket and the caps rise with demonstrated volume —
$100K at launch → $500K on sustained traction → $2M post-audit → $10M+ at
scale, always under the immutable on-chain ceiling. Criteria and governance
rails: [docs/ROADMAP.md](docs/ROADMAP.md).

## Deployment

See [docs/DEPLOY.md](docs/DEPLOY.md) — units computation must run during US
market hours (feeds are 24/5), and mainnet broadcast is gated behind an
explicit human confirmation (`CONFIRM_DEPLOY=yes`).

## Risk — read this

- The underlying Stock Tokens are **debt instruments of Robinhood Assets
  (Jersey) Ltd** and carry issuer risk. The issuer can pause or freeze the
  underlying tokens; this protocol **inherits that risk and cannot remove it**.
  If any constituent is frozen, redeeming the whole basket reverts until the
  freeze lifts.
- The contracts are **unaudited**. Supply caps are deliberately low at launch
  for exactly this reason.
- Not available to US, UK, Canadian, Swiss or UAE persons. The hosted frontend
  is geoblocked accordingly. Nothing here is investment advice.

## License

[MIT](LICENSE)
