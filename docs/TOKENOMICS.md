# VIMEN — tokenomics

> Status: the VIMEN token contract is deployed and distributed BY THE OWNER
> (external to this repo). `src/VimenToken.sol` remains as a reference
> implementation only. The platform (CuratorRegistry, FeeSplitter,
> BasketFactory) deploys via `script/DeployPlatform.s.sol` pointing at the
> owner's token address, which must be a standard ERC20 (no transfer tax,
> no rebasing, 18 decimals) and FINAL before wiring: the registry stores it
> immutably, and staking rejects non-standard transfers at runtime.

## The job of the token

VIMEN is a license, not a lottery. Three functions, all live in code:

1. **Access** — publishing a basket through the `BasketFactory` requires
   self-staking ≥ 25,000 VIMEN in the `CuratorRegistry` (structural demand).
2. **Shelf space** — the frontend ranks baskets by the curator's total pool
   stake (`effectiveStake`): a continuous auction for visibility.
3. **Income** — non-curators delegate stake to curators and share their fee
   income pro-rata (curator commission: default 20%, hard cap 50%).

Fee flow per curated basket, enforced by constants (no admin can change it):

```
mint fee (basket tokens, ≤0.50%)
  └─ FeeSplitter (feeRecipient of every factory basket)
       ├─ 60% → curator's staking pool (CuratorRegistry, pro-rata to stakers
       │        after curator commission)
       └─ 40% → protocol treasury
```

Value anchor: a curator attracting $2M TVL at 0.30% mint fee and monthly
rotation ≈ $1,800/month of fee income. Thirty such curators = a real,
measurable economy backing the token — not a narrative.

## Supply & allocation (proposal)

Fixed supply **100,000,000 VIMEN**, minted once, no mint function, no owner.

| Bucket | % | Vehicle | Notes |
|---|---|---|---|
| Airdrop to real chain users | 10% | Merkle distributor | Snapshot criteria TBD (early Vimen minters + active RH-chain addresses, anti-sybil). |
| Liquidity | 20% | DEX pool, LP tokens **burned** | Locked forever, verifiable on-chain. |
| Founder | 25% | OpenZeppelin `VestingWallet`, **36-month linear, on-chain** | Zero liquid at TGE. Address published. |
| Curator & ecosystem incentives | 30% | Treasury Safe, streamed programs | Grants for early curators, delegation incentives, buildathon co-marketing. |
| Protocol treasury / runway | 15% | Treasury Safe | Ops, audit budget (unlocks cap Phase 3), listings. |

**Zero private sales. Zero investor unlocks. Bubblemaps-clean by design.**

## Deployment wiring (trust-minimized)

Order: `VimenToken(distributor)` → `CuratorRegistry(vimen)` →
`FeeSplitter(registry, treasury)` → `BasketFactory(registry, splitter,
protocolGuardian)` → `registry.initSplitter(splitter)` →
`splitter.initFactory(factory)`. The two `init*` calls are one-shot,
deployer-only, and frozen afterwards — after wiring there is **no privileged
function anywhere in the platform** except the basket guardian's three
powers (pause-mint / cap under ceiling / fee-recipient, all Safe-held).

Curated baskets are wired so curators can never rug:
- `feeRecipient` = FeeSplitter (curator cannot redirect fees);
- `guardian` = protocol Safe (cap roadmap applies to every basket);
- basket contracts are the same immutable `BasketToken` as first-party ones.

## Parameters (constants in code)

| Parameter | Value | Where |
|---|---|---|
| License threshold | 25,000 VIMEN self-stake | `CuratorRegistry.MIN_SELF_STAKE` |
| Unstake cooldown | 7 days | `CuratorRegistry.UNSTAKE_COOLDOWN` |
| Curator fee share | 60% forever | `FeeSplitter.CURATOR_SHARE_BPS` |
| Default / max commission | 20% / 50% | `CuratorRegistry` |
| New-basket starter cap | 1,000 tokens (≈$100K) | `BasketFactory.STARTER_CAP` |
| Per-basket ceiling | 1M tokens | `BasketFactory.CEILING` |

## Open items before TGE

- [ ] Owner sign-off on allocation table and license threshold
- [ ] Airdrop snapshot criteria + Merkle tree generation
- [ ] DEX choice for the locked liquidity pool
- [ ] VestingWallet deployment (founder address)
- [ ] Legal review of token distribution (jurisdictions, geoblock parity)
