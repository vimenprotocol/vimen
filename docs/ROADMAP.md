# Deposit-cap roadmap

Caps bound the maximum damage while the protocol is unaudited and earns
trust. They rise with demonstrated volume. Governance rails:

- Every raise is a `setSupplyCap` guardian transaction (Safe), public on
  Blockscout, and requires explicit human sign-off (handoff spec §4.7–4.8).
- The contract enforces an immutable per-basket ceiling (`maxSupplyCap`,
  1M tokens ≈ $100M at launch prices). No raise can ever exceed it.
- Raises never front-run their criteria; lowering the cap is always allowed
  and never affects redeem.

| Phase | Cap per basket | Unlock criteria |
|---|---|---|
| 1 — Launch | $100K (≈1,000 tokens) | Mainnet launch. |
| 2 — Traction | $500K | Cap utilization > 80% sustained for 2 weeks **and** 250+ holders on the basket. |
| 3 — Audited | $2M | Professional security audit completed and published (findings addressed in SECURITY.md). |
| 4 — Scale | $10M+ | Progressive raises with demand; each step reviewed against issuer-risk exposure and on-chain liquidity of constituents. |

Utilization and holder counts are measured from on-chain data (Blockscout /
Dune). The roadmap is surfaced in-app on the homepage and the trust page
(mirrored in the app's config — keep the three in sync).
