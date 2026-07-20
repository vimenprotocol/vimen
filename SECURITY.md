# Security

## Threat model

`BasketToken` is a single-contract, non-upgradeable, in-kind mint/redeem vault.
The design goal is to make the contract's own attack surface as close to zero
as possible and to be explicit about the risks that remain.

### What the contract guarantees

| Property | Mechanism |
|---|---|
| Full backing | Mint pulls `ceil(amount × units / 1e18)` per constituent and verifies the actual balance delta; redeem pays `floor(...)`. All rounding favors the vault. Invariant-tested (`test/BasketToken.invariant.t.sol`). |
| Redeem can never be blocked by the protocol | `redeem` has no pause, no cap, no guardian gate — verified by a dedicated test that redeems while minting is paused *and* the cap is below supply. |
| No admin control over funds | The guardian can only pause minting, move the supply cap (≤ immutable `maxSupplyCap`) and change the fee recipient. There is no withdraw, sweep, upgrade, `delegatecall` or `selfdestruct` path. |
| Reentrancy | `nonReentrant` on `mint`/`redeem`; attack mocks covering all four re-entry combinations. |
| Non-standard tokens | Balance-delta check rejects fee-on-transfer / lying constituents at mint time. |

### Risks the contract inherits and cannot remove

1. **Issuer risk (dominant risk).** Constituents are Robinhood Stock Tokens —
   debt instruments of Robinhood Assets (Jersey) Ltd. The issuer can pause or
   freeze the underlying tokens. If **any** constituent's transfers are frozen,
   `redeem` of the whole basket reverts until the freeze is lifted, because a
   redeem is all-or-nothing by design (no partial-redeem escape hatch exists —
   deliberately, to keep the contract minimal). Supply caps exist to bound
   exposure to this risk.
2. **Unaudited code.** The contract is small (~160 nSLOC) and heavily tested,
   but has not undergone a professional audit. Supply caps are the mitigation.
3. **Weight drift.** Units are fixed at deploy; weights drift with prices.
   This is documented product behavior, not a vulnerability.

## Platform contracts (WP-5: VIM + curation)

The curation platform wraps the unchanged `BasketToken` core. The curator
license is earned by **burning** VIM — there is no staking, delegation,
cooldown, or reward pool.

**The VIM token is external and third-party.** VIM was launched on Virtuals
Protocol — a Virtuals `AgentTokenV4` at
[`0x43E7…47aF`](https://robinhoodchain.blockscout.com/token/0x43E7Cb9984aD95aA808ac21998cc8D5f909e47aF):
a 1,000,000,000-supply ERC-20 whose owner controls a 1% buy/sell tax and an
address blacklist. It is **not** any contract in `src/`: the repo's
`VimenToken.sol` lives under `test/mocks/` and is a reference/test stand-in
only, never deployed. The platform integrates VIM through exactly ONE
call — `burnFrom`, in `CuratorRegistry` — and that surface is verified safe
against the deployed token's bytecode:

- The token's `burnFrom` routes to `_burn`, which **skips the blacklist**
  (`_beforeTokenTransfer` exempts burns, `to == address(0)`) and **skips the
  1% tax** (burns never enter the taxed `_transfer` path), and reduces
  `totalSupply`. So the token owner can neither block nor tax a license burn.
- The platform touches VIM nowhere else — `FeeSplitter` pays curators in
  basket tokens, never VIM — so VIM's tax / blacklist / owner cannot reach
  anything beyond the (safe) license burn.

- `CuratorRegistry` — `burnForLicense()` burns `LICENSE_BURN`, a **fixed
  constant of 25,000 VIM**, from the caller (via `burnFrom`) for a permanent,
  non-revocable license. Same amount for everyone, forever — **no admin, no
  owner, no tunable knob**. Holds no funds; `_licensed` set before the external
  `burnFrom` (CEI); `nonReentrant`; `AlreadyLicensed` guard.
- `FeeSplitter` — `feeRecipient` of every factory basket; the 60/40 split are
  constants. The curator's 60% is transferred **directly to their wallet** in
  one hop — no pool, no claim step. Permissionless `distribute`. The factory
  link is a one-shot deployer-only `initFactory`, frozen afterwards.
- `CuratorGuardian` — the restricted guardian of every curated basket.
  Curated baskets are wired with THIS contract as their `guardian`, not the
  protocol Safe directly. It exposes only `raiseCap` (advance a basket's
  supply cap, admin-only, strictly upward, bounded by the basket's immutable
  `maxSupplyCap`) and has NO `setFeeRecipient` / `setMintPaused` path. Its
  `admin` (the Safe) is immutable; no owner, no upgrade, no admin transfer.
- `BasketFactory` — permissionless creation gated on `registry.isLicensed`;
  wires every basket with `feeRecipient = splitter` and `guardian =
  CuratorGuardian`, so curators can neither redirect fees nor touch caps, and
  the *protocol* can only advance caps.

Trust properties: after deployment wiring the platform has exactly **one
bounded lever** — the protocol Safe can raise a curated basket's supply cap
(upward-only, via `CuratorGuardian`), and nothing else. The registry has no
admin at all; the license burn is a fixed constant. Everything is immutable.
Burning is irreversible
and idempotent-guarded; a license can never be revoked, and existing baskets
are immutable `BasketToken` instances unaffected by anything a curator does
afterward. `distribute` rounds the curator's 60% down, so at most the
remaining ≤1 wei of a distribution goes to the treasury; a 1-wei fee balance
floors the curator share to 0 and pays the single wei to treasury (tested).
The curator's share cannot be inflated or redirected: the 60% constant and the
destination (`curatorOf[basket]`, set factory-only at publish) are both frozen.

**Un-chokeable curated fee stream.** Because a curated basket's guardian is
the `CuratorGuardian` contract — which lacks any `setFeeRecipient` /
`setMintPaused` function — no caller, not even the protocol Safe, can redirect
or pause a curated basket's mint fees. The Safe is only the guardian's admin
and can do exactly one thing: raise the cap, upward, never down. This is what
makes "burn 25,000 VIM for a non-revocable license, 60% of fees forever"
enforceable rather than merely promised. (First-party baskets keep the Safe as
their direct guardian; only factory-published baskets use the restricted one.)

Coverage: the burn redesign removed the staking/delegation/reward machinery
and added the restricted `CuratorGuardian`. Platform tests: 35 (`Platform.t.sol`
+ `Platform.edge.t.sol`), including an explicit proof that neither the Safe nor
anyone else can `setFeeRecipient`/`setMintPaused` a curated basket, and a proof
that `burnForLicense` works against the real token's tax + blacklist (both
exempt burns); the full suite has since grown past 230 tests with the V2
platform, all green. Additional accepted Slither finding: benign `== 0`
early-return in `distribute`.

Note: `via_ir = true` is now enabled — the 9-argument `BasketToken`
constructor call in `BasketFactory` exceeds legacy-codegen stack depth
(NFR-1's "unless needed" clause). The full suite passes under via-IR.

## Agentic baskets (V2: BasketToken2 + oracle/payout layer)

`BasketToken2` keeps mint/redeem byte-for-byte V1 (in-kind, price-free,
ungated) and adds exactly one mutation: `rebalance`, callable only by the
per-basket agent key. The security claims, each enforced in code and tested:

- **Policy bounds are unbypassable constants**: cooldown ≥ 1 day, turnover
  ≤ 25% of NAV, slippage ≤ 1% of NAV per rebalance, validated in the
  constructor; a curator can only choose stricter values.
- **The agent is caged**: `onlyAgent` protects only `rebalance`; no path to
  mint, redeem, fees or custody. The only outflows are to `MakerRegistry`-
  whitelisted settlement contracts (delta-checked to the exact amount) and
  the sweep to the immutable per-basket `BasketDistributor`. Worst-case
  compromised agent key ≈ the slippage budget of NAV per cooldown window.
- **Backing survives every trade**: units are recomputed as
  `floor(balance × 1e18 / supply)` after each rebalance, so redemption
  never depends on the oracle being right.
- **Oracles are fail-safe and frozen**: each registered asset's feed is
  fixed at registration and can never be repointed; a stale feed reverts
  the rebalance, an uncovered TWAP window reports stale rather than a
  guessable price. No feed is ever read on mint or redeem.
- **The distributor cannot double-pay, over-pay, or brick**: paginated
  snapshot deduped per cycle, Σ floor ≤ pot, revert-on-transfer skips the
  wallet instead of failing the cycle; the interval is immutable and there
  is no owner.

Before the immutable V2 deploy the layer went through two adversarial
internal reviews; blocking findings (constructor validation, oracle
storage-layout verification against the live PoolManager) were fixed or
verified before deployment.

## Deviations from the handoff spec

- **FR-2:** constructor takes an extra final parameter `initialSupplyCap`
  (validated `0 < initialSupplyCap <= maxSupplyCap`). The spec had the deploy
  script call `setSupplyCap` post-deploy, but that call is guardian-gated and
  the guardian is a Safe, not the deploy key — the call would revert. Setting
  the initial cap in the constructor removes the extra transaction and the
  window where the cap is unset. Approved by the project owner on 2026-07-10.

## Static analysis

### Slither (v0.11.x)

Zero findings of any severity in `src/BasketToken.sol` other than:

- `calls-loop` (Low): `mint`/`redeem`/`isFullyBacked` call constituent ERC-20s
  in a loop. **Accepted** — inherent to an in-kind multi-token vault; the
  constituent set is bounded (2–20) and fixed at deploy.
- `cyclomatic-complexity` (Informational): constructor validation ladder.
  **Accepted** — it is a sequence of independent input checks.
- The reported High (`incorrect-exp`) and Medium (`divide-before-multiply`)
  findings are all inside OpenZeppelin `Math.mulDiv` (v5.6.1) — well-known
  false positives on the Remco Bloemen mulDiv implementation (the `^` is an
  intentional XOR in the Newton–Raphson inverse). Not our code; unmodified
  audited library.

### Aderyn (0.6.x, full `src/` scan — all contracts + interfaces)

3 High, all triaged as false positives / intentional:

- **H-1 "state change after external call"** (`BasketFactory.createBasket`,
  lines 62/78) — the external calls are to protocol-owned, trusted contracts:
  `new BasketToken(...)` (its constructor only does `code.length` reads, no
  callback into the caller) and `splitter.register` (factory-gated, writes a
  mapping, no callback). No attacker-controlled reentrancy path exists, so the
  post-call writes (`curatorOf`, `_baskets.push`, event) are safe. In the burn
  redesign `CuratorRegistry.burnForLicense` sets `_licensed` *before* the
  external `burnFrom` (CEI) and is `nonReentrant`, so it is not flagged.
  **Accepted.**
- **H-2 contract name reused** (`VimenZap`/`VimenZap2`/`VimenZap3` share the
  `VimenZap` type name across files) — deliberate: each is an independently
  deployed, immutable router version; only the latest is wired in the UI.
  **Accepted.**
- **H-3 unsafe int cast** (`IUniswapV4.sol` BalanceDelta unpacking) — the
  truncation to the low 128 bits is the defined encoding of Uniswap v4's
  `BalanceDelta` (two int128s packed in an int256); the cast is the decoder.
  **Accepted.**

Low findings (costly-op/require in loop, large literals `10_000` bps,
state-change-without-event on internal accounting, "could be immutable" on
guardian-settable fields, unchecked return on the quoter's revert-trick call,
unused error) — same rationales as the Slither triage above; all accepted.

Full report: `contracts/aderyn-report.md`.

## Reporting a vulnerability

No formal bug bounty yet. Please report privately via
[GitHub private vulnerability reporting](https://github.com/vimenprotocol/vimen/security/advisories/new)
before any public disclosure. Good-faith reports will be acknowledged within
48 hours, and rewards for critical findings will be negotiated case by case.
