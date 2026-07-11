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

## Platform contracts (WP-5: VIMEN + curation)

The curation platform wraps the unchanged `BasketToken` core:

- `VimenToken` — fixed 100M supply, minted once, no owner/mint/hooks.
- `CuratorRegistry` — staking pools (license + delegation), MultiRewards-style
  fee accounting, 7-day unstake cooldown. No admin; the splitter link is a
  one-shot deployer-only init, frozen afterwards.
- `FeeSplitter` — `feeRecipient` of every factory basket; 60/40 split are
  constants. Permissionless `distribute`.
- `BasketFactory` — permissionless creation gated on the stake license;
  wires every basket with `feeRecipient = splitter` and `guardian =
  protocol Safe`, so curators can neither redirect fees nor touch caps.

Trust properties: after deployment wiring there is no privileged function in
the platform. Reward accounting rounds down; dust bound is
`totalStake/1e18` wei per distribution plus 1 wei per staker settlement
(fuzz-tested). A curator unstaking below the threshold only loses the ability
to publish *new* baskets — existing baskets are immutable and unaffected.

Commission changes are timelocked (resolved former phase-1 limitation):
`setCommission` only *announces* a change (`CommissionAnnounced` with its
`effectiveAt`); it activates after `COMMISSION_TIMELOCK` (7 days, aligned
with `UNSTAKE_COOLDOWN`), so a delegator who exits at the announcement is out
before the new rate applies. `commissionBps` reflects a matured announcement
lazily — no keeper needed — and re-announcing before maturity restarts the
clock. The old grief (raise to the 50% cap and call the permissionless
`distribute` in the same transaction, capturing up to half of pending pool
fees with no notice) is closed: fees distributed inside the window still pay
the old rate.

Coverage: 100% lines/statements/branches/functions across all five contracts
(107 tests). Additional accepted Slither findings: `timestamp` comparison in
the cooldown (standard), benign `== 0` early-return in `distribute`.

Note: `via_ir = true` is now enabled — the 9-argument `BasketToken`
constructor call in `BasketFactory` exceeds legacy-codegen stack depth
(NFR-1's "unless needed" clause). The full suite passes under via-IR.

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

### Aderyn (0.6.x, full `src/` scan — all six contracts + interfaces)

2 High, both triaged as false positives / intentional:

- **H-1 "state change after external call"** (BasketFactory.createBasket,
  CuratorRegistry.stake) — the external calls are to protocol-owned contracts
  wired at deployment (registry/splitter) or are the deliberate balance-delta
  read pattern that rejects fee-on-transfer VIMEN; every flagged function is
  `nonReentrant`. **Accepted.**
- **H-2 unsafe int cast** (`IUniswapV4.sol` BalanceDelta unpacking) — the
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
