# VimenZap — single-transaction mint/redeem via Uniswap v4

> Status: contract + fork tests + frontend integration complete (2026-07-11).
> Not yet deployed: `script/DeployZap.s.sol` is ready; the frontend activates
> when `NEXT_PUBLIC_ZAP_ADDRESS` is set and a basket has a routable pool for
> every constituent.

## What it does

`zapMint`: the user pays one currency (USDG today; native ETH supported by
the contract), the router buys the **exact** constituent amounts on Uniswap
v4 (exact-output swaps, so zero dust), approves the basket and mints, all in
one transaction. If any leg cannot fill, everything reverts: no partial
state. `zapRedeem` is the mirror: burn the basket, sell every constituent,
receive one currency, with a `minOut` floor.

Same trust model as `BasketToken`: no owner, no admin, no pause, no
upgradeability, holds nothing between transactions. The caller supplies the
swap path per constituent; the contract enforces path endpoints,
connectivity, exact fill, `maxSpend`/`minOut` and deadline.

## Quoting

`quoteZapMint` / `quoteZapRedeem` run the real swaps inside a v4 `unlock`
and revert with the amounts (the v4 Quoter trick). An `eth_call` therefore
returns the **exact execution numbers** with no token balance and no
deployed quoter dependency. The fork tests assert quote == execution in the
same block.

The frontend (`src/lib/useZapQuote.ts`) scores each leg against the
Chainlink price and gates the whole zap when any leg's execution premium
exceeds `MAX_LEG_IMPACT` (3%): thin pools disable the zap loudly instead of
overcharging quietly.

## Liquidity reality (recon 2026-07-11)

Uniswap v4 on Robinhood Chain: PoolManager
`0x8366a39CC670B4001A1121B8F6A443A643e40951`. USDG
(`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, 6 decimals) is the chain's
stablecoin; WETH/USDG is deep (≈$5.7M on v3 alone). Per-constituent v4
buy-side inventory at recon time:

| Ticker | Depth | Best sane pool (fee / tickSpacing) |
|---|---|---|
| TSLA | ≈$37K | 0.30% / 60 |
| NVDA | ≈$23K | 0.30% / 60 |
| AAPL | ≈$22K | 0.05% / 10 |
| AMD | ≈$19K | 1.00% / 200 |
| GOOGL | ≈$8K | 0.90% / 180 |
| META | ≈$2.6K | 5.00% / 1000 |
| PLTR | ≈$390 | 10.00% / 2000 |
| MSFT, AMZN, CRWV, ORCL | dust | none under 90% fee |

The launch baskets are composed around this reality (lineup finalized
2026-07-12): **MAG7**, **HOOD6** and **AI6** are fully routable — MSFT's
first sane pool (USDG, 2% fee) appeared 2026-07-12 and completed the true
Magnificent Seven; thin legs (MSFT, AMZN, PLTR, MU) rely on the 3% runtime
impact gate and get healthier as pools deepen; `zapAvailable()` keeps any not-fully-routable basket honest by
never showing the "Pay with USDG" toggle. The route map lives in
the app's route config; extend it as pools appear. No canonical
USDC/USDT/WBTC/SOL exist on the chain: accepting those means an external
bridge/onramp into USDG or ETH, not a contract change.

The deep stock inventory on-chain sits in Robinhood's own batch-settlement
contract (`0x94bAB…`, `commitBatch`/`verifyBatch`), which is not routable.
If Vimen or curators ever LP the missing stock/USDG pools around the oracle
price, the zap turns on basket-wide with zero code changes.

## Getting USDG (cross-chain funding)

Relay (relay.link) supports Robinhood Chain natively: USDG is bridgeable,
origins include Ethereum, Base, Arbitrum, Solana and Bitcoin. A test quote
(2026-07-11) moved 100 USDC on Base to 99.92 USDG on chain 4663 in ~2s for
~$0.05. The frontend deep-links into Relay with destination, recipient and
the exact shortfall prefilled (`src/config/funding.ts`); the zap panel polls
the USDG balance fast while the user is off bridging and flips to
Approve/Mint by itself when funds land. Privy card onramps (Meld, MoonPay,
Coinbase) are the fiat entry; their direct chain-4663 delivery is not yet
verified, and Relay covers the gap from any chain the user already has
funds on. Full user funnel: email signup (Privy) → "Get USDG" (Relay, any
chain or token) → Approve → Mint. After the first mint: quote → one
signature → done in about a second.

## Permit2: no approve transaction per mint

`zapMintPermit2` accepts a Permit2 SignatureTransfer: the user signs
(token = USDG, amount = maxSpend, spender = router) off-chain and the
router pulls only the actual cost straight into the PoolManager. Per mint:
one EIP-712 signature + one transaction, no allowance ever granted to the
router itself. Prerequisite is the once-ever ERC-20 approval of USDG to the
canonical Permit2 (`0x000000000022D473030F116dDEE9F6B43aC78BA3`, verified
deployed on Robinhood Chain), surfaced in the UI as a one-time "Enable
USDG" step. Fork tests cover the signed path end to end, including nonce
replay rejection.

Embedded Relay widget was evaluated and deliberately skipped for now:
`relay-kit-ui` drags React-18 typings, framer-motion, FontAwesome and a
Radix design system into a React 19 + Tailwind 4 app, and Solana/Bitcoin
origins would additionally need their wallet adapters. The prefilled deep
link covers every origin chain with zero dependencies; revisit if Relay
ships a lighter widget.

## Files

- `contracts/src/VimenZap.sol` — router (mint, redeem, both quotes)
- `contracts/src/interfaces/IUniswapV4.sol` — vendored minimal v4 interface
- `contracts/test/VimenZap.fork.t.sol` — 7 fork tests against live pools
  (`RH_RPC=… forge test --match-contract VimenZapForkTest`)
- `contracts/script/DeployZap.s.sol` — deploy (CONFIRM_DEPLOY=yes gate)
- app route map + ABI config
- `frontend/src/lib/useZapQuote.ts` — exact quote + per-leg impact gating
- app "Pay with USDG" panel

## Sharp edges to remember

- v4 sign conventions: `amountSpecified > 0` = exact output; swap deltas are
  from the router's POV (positive = credit). An unlimited-price exact-output
  swap **fills partially** instead of reverting when range liquidity runs
  out; the router rejects any under-filled leg (`LegUnderfilled`).
- Exact-output multi-hop paths execute in reverse; intermediate currencies
  net to zero inside the unlock.
- Settlement pulls the payer's USDG straight into the PoolManager
  (`sync → transferFrom → settle`), so the router never custodies input.
- `BasketToken.getRequiredUnits` rounds up and `mint` pulls exactly that:
  approvals return to zero by construction.
