# Deploy runbook — MAG7 + HOOD6 + AI6 + VimenZap

Canonical deploy procedure. Launch set: **MAG7** (the Magnificent Seven —
AAPL MSFT GOOGL AMZN META NVDA TSLA), **HOOD6** (Hood Six — pool-priced
chain-native tokens) and **AI6** (AI Six — NVDA AMD MU PLTR GOOGL SPCX),
plus the **VimenZap** router.

## 0. Prerequisites (hard requirements)

- [ ] **Guardian Safe deployed on chain 4663.** Guardian and feeRecipient
      must be contracts — `Deploy.s.sol` hard-refuses EOAs, and the guardian
      address is immutable per basket. Never use a throwaway EOA.
      `export SAFE=0x…`
- [ ] **Deployer EOA funded** with ETH on Robinhood Chain (bridgeable in
      seconds via https://relay.link/bridge/robinhood — ~0.01 ETH covers all
      deploys plus the smoke test). `export DEPLOY_KEY=0x…` — keep the key in
      an encrypted keystore (`cast wallet import`), never in a plaintext file.
- [ ] `export RH_RPC=https://rpc.mainnet.chain.robinhood.com`
      (or a dedicated endpoint if available)
- [ ] **Fresh Chainlink feeds.** Stock feeds heartbeat every 24h (24/5, they
      re-publish the Friday close over the weekend). `compute-units` aborts on
      any feed older than its heartbeat; if it does, wait for the tick and
      re-run. Pool-priced constituents (HOOD6) trade 24/7 and are always fresh.
- [ ] **Re-verify token addresses** against
      https://docs.robinhood.com/chain/contracts (fake tokens with identical
      tickers exist). The tooling re-reads `symbol()`/`decimals()` on-chain and
      aborts on mismatch, but the docs check is on you. If the docs are
      unreachable or disagree with the config: **halt**.

## 1. Regenerate units with fresh prices (~2 min)

```bash
cd scripts
BASKETS=MAG7,HOOD6,AI6 RH_RPC=$RH_RPC \
  GUARDIAN=$SAFE FEE_RECIPIENT=$SAFE \
  npm run compute-units
# interactive prompt: type "verified" after the docs check above.
# Writes contracts/baskets/mag7.json, hood6.json and ai6.json.
```

Sanity: open all three JSONs — constituent USD legs equal, total ≈ $100,
`_meta.pricesUsd8` consistent with the app's Markets page,
`guardian`/`feeRecipient` == the Safe.

## 2. Dry-run the three baskets (no broadcast, ~1 min)

```bash
cd ../contracts
forge script script/Deploy.s.sol --sig "run(string)" baskets/mag7.json --rpc-url $RH_RPC
forge script script/Deploy.s.sol --sig "run(string)" baskets/hood6.json --rpc-url $RH_RPC
forge script script/Deploy.s.sol --sig "run(string)" baskets/ai6.json --rpc-url $RH_RPC
```

Read the printed config line by line: on-chain symbols, units, caps, Safe.
**Human sign-off of this output is the gate for step 3.**

## 3. Broadcast + verify (~4 min, 3 txs)

```bash
CONFIRM_DEPLOY=yes forge script script/Deploy.s.sol \
  --sig "run(string)" baskets/mag7.json \
  --rpc-url $RH_RPC --broadcast --private-key $DEPLOY_KEY \
  --verify --verifier blockscout \
  --verifier-url https://robinhoodchain.blockscout.com/api

CONFIRM_DEPLOY=yes forge script script/Deploy.s.sol \
  --sig "run(string)" baskets/hood6.json \
  --rpc-url $RH_RPC --broadcast --private-key $DEPLOY_KEY \
  --verify --verifier blockscout \
  --verifier-url https://robinhoodchain.blockscout.com/api

CONFIRM_DEPLOY=yes forge script script/Deploy.s.sol \
  --sig "run(string)" baskets/ai6.json \
  --rpc-url $RH_RPC --broadcast --private-key $DEPLOY_KEY \
  --verify --verifier blockscout \
  --verifier-url https://robinhoodchain.blockscout.com/api
```

Note all three deployed addresses. The script asserts `isFullyBacked()`
post-deploy. **Do not re-run a broadcast that already succeeded** — the
scripts are not idempotent and a second run deploys a duplicate.

## 4. Deploy the zap router (~1 min, 1 tx)

Recommended right before broadcasting — re-run the router fork tests against
live state: `RH_RPC=$RH_RPC forge test --match-contract VimenZapForkTest`.

```bash
CONFIRM_DEPLOY=yes forge script script/DeployZap.s.sol \
  --rpc-url $RH_RPC --broadcast --private-key $DEPLOY_KEY \
  --verify --verifier blockscout \
  --verifier-url https://robinhoodchain.blockscout.com/api
```

## 5. Point the frontend at the contracts (~2 min)

In Vercel project settings (or `.env.local`):

```
NEXT_PUBLIC_MAG7_ADDRESS=0x…    # from step 3
NEXT_PUBLIC_HOOD6_ADDRESS=0x…   # from step 3
NEXT_PUBLIC_AI6_ADDRESS=0x…     # from step 3
NEXT_PUBLIC_ZAP_ADDRESS=0x…     # from step 4
# optional: NEXT_PUBLIC_RH_RPC=…  # dedicated RPC kills the 429s
```

Redeploy the frontend. The zap panel, stats, activity feed and mint widget
all switch on automatically when these are set.

## 6. Smoke test (~5 min, ~$25 of real money)

- [ ] `/basket/mag7`, `/basket/hood6` and `/basket/ai6` show live NAV, chart, composition
- [ ] Zap-mint ~$10 of each with a fresh email account (full funnel:
      email → Get USDG via Relay → Enable USDG → Mint)
- [ ] Redeem a fraction in-kind; constituents arrive in the wallet
- [ ] `isFullyBacked()` true on all three (Blockscout read tab)
- [ ] Markets page badges flip as expected
- [ ] Record the mint/redeem tx hashes in the README
- [ ] From a mobile browser: geoblock via VPN (expect HTTP 451),
      staleness badge on a weekend read

## Post-launch guardian ops

Every guardian transaction (cap raises included) requires explicit human
sign-off (spec §4.7–4.8). Phase-1 cap stays at 1,000 baskets (≈$100K) until
the owner decides otherwise.

## Rollback stance

There is no upgrade path by design. If a deployed basket has wrong units:
pause minting via the Safe (`setMintPaused(true)`), deploy a corrected
basket, point the frontend at it. Redeem on the wrong one keeps working
forever, so nobody's funds are ever stuck.
