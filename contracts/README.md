# Vimen contracts

Foundry project. Solidity 0.8.24 (pinned), OpenZeppelin v5.6.1 (submodule),
`via_ir`, optimizer 10k runs. No proxies, no upgradeability, no admin keys
over funds anywhere.

## Contracts

| Contract | Purpose |
|---|---|
| `BasketToken.sol` | ERC-20 index token fully backed by fixed raw units of its constituents. In-kind mint/redeem; fee taken in basket tokens so backing stays exact. Guardian can only pause mint, move the cap under an immutable ceiling, and change the fee recipient. Redeem is ungated forever. |
| `VimenZap.sol` | Stateless Uniswap v4 router: single-tx zap mint/redeem via `poolManager.unlock`, revert-based quoter, Permit2 single-signature entry. Holds no funds between txs, no admin. |
| `CuratorRegistry.sol` | VIMEN staking + per-curator reward pools. Self-stake ≥ 25,000 VIMEN = publishing license; 7-day unstake cooldown; curator commission capped at 50%. |
| `BasketFactory.sol` | Permissionless basket publishing for licensed curators (starter cap 1,000 baskets, immutable 1M ceiling). |
| `FeeSplitter.sol` | Receives basket-token fees; splits 60% to the curator's reward pool, 40% to treasury. Permissionless `distribute`. |
| `VimenToken.sol` | Fixed 100M supply ERC-20 + ERC20Permit. Minted once, no owner. |

Minimal vendored interfaces for Uniswap v4 and Permit2 live in
`src/interfaces/`.

## Build & test

```bash
forge build
forge test                 # 104 tests: unit, fuzz (1024 runs), invariant (256x64)
RH_RPC=https://rpc.mainnet.chain.robinhood.com forge test --match-contract Fork
forge fmt                  # enforced in CI with --check
```

Fork suites (`Fork.t.sol`, `VimenZap.fork.t.sol`) run against Robinhood Chain
mainnet (chain id 4663) and self-skip when `RH_RPC` is unset. CI runs them
when the `RH_RPC` secret is configured.

## Deploy

See [../docs/DEPLOY.md](../docs/DEPLOY.md). All scripts are gated by
chain-id checks and an explicit `CONFIRM_DEPLOY=yes`; basket deploys verify
guardian/feeRecipient are contracts and re-read constituent
`symbol()`/`decimals()` on-chain before broadcasting.

## Security

Threat model, accepted static-analysis findings and spec deviations:
[../SECURITY.md](../SECURITY.md). The contracts are unaudited; launch supply
caps are deliberately low.
