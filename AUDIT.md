# SPINZ contracts — audit scope

Hand this document to an auditor along with read access to this repository.

---

## 1. What the system does

SPINZ is a gacha-style daily fantasy sports product. Instead of drafting a
lineup, a user pays an entry fee and is **dealt** a complete, pre-validated,
unique lineup from a deck that was committed on-chain *before* the contest
opened. Randomness comes from Chainlink VRF 2.5 on Base.

The contracts exist to make four claims verifiable rather than trusted:

1. No two users in a contest can receive the same lineup.
2. The operator cannot choose, re-roll, or influence any assignment.
3. The deck was fixed before entries opened and cannot be edited afterwards.
4. Nobody, including the operator, can withhold a user's result.

**The contracts hold no funds.** Entry fees are locked in an off-chain ledger
and never touch the chain. The worst case for a contract bug is a stuck or
incorrect assignment, which is refundable off-chain. There is no drain path.

---

## 2. Scope

| File | Lines | ~SLOC | Runtime size | Mutable? |
|---|---:|---:|---:|---|
| `src/SpinAssignment.sol` | 649 | ~385 | 11,737 B | **No — immutable, no proxy** |
| `src/SpinRegistry.sol` | 111 | ~58 | 2,018 B | Yes, minimally |

19 external/public functions total. Everything else in the repo (`test/`,
`script/`) is out of scope except as evidence of intent.

**Out of scope:** the off-chain worker, the deck-generation algorithm, the
Node.js API, and the ledger. Those live in a separate private repository and are
reviewed separately. The auditor only needs to know that the deck is generated
off-chain and committed here as two Merkle roots.

### Deployed instances (Base mainnet, chain ID 8453)

| Contract | Address | Verified |
|---|---|---|
| SpinAssignment | `0x6Bb0d32dCa4F58cb89191dDEc4b47481C028f753` | Basescan + Sourcify (full match) |
| SpinRegistry | `0x74CEf46279AeAa7A08973B4a8090a9fdDf6db832` | Basescan + Sourcify (full match) |

No contest has been bound yet, so neither contract is live in any economic
sense. Deployment alone is inert: `SpinRegistry` gates which implementation a
contest binds to, and **real exposure begins at binding, not at deployment.**

### Build

- Solidity **0.8.28**, pinned. No floating pragma.
- Optimizer **on**, 1000 runs, `via_ir` off.
- `bytecode_hash = "none"`, `cbor_metadata = false`, for reproducible bytecode.
- Dependencies: OpenZeppelin `v5.1.0`, `chainlink-brownie-contracts` `1.3.0`.
- `forge test` — 58 tests, including 6 invariants over 16,384 randomized calls each.
- CI runs `forge fmt --check`, `forge build --sizes`, fuzz at 20k runs, gas
  snapshots, and Slither with `fail-on: medium`.

---

## 3. Protocol flow

```
commitStage1(contestId, snapshotHash, scoringHash, builderHash, saltCommitment)
    └─ requests a VRF build seed IN THE SAME TRANSACTION
fulfillRandomWords  →  contest status SEEDED, build seed stored
    ── off-chain: calibrate band, generate deck, split into two segments ──
commitStage2(contestId, rulesHash, directRoot, directSize, promoRoot, promoSize, lockAt)
    └─ contest is now open for entries

per batch of entries:
commitBatch(contestId, segment, sequence, entryIds)
    └─ requests ONE VRF seed for that batch
fulfillRandomWords  →  batch seeded
finalize(batchId, entryIds, maxCount)     ← PERMISSIONLESS, chunked, resumable
    └─ sparse Fisher-Yates draw without replacement, emits EntryAssigned

after lockAt:
revealSalt(contestId, salt)   ← PERMISSIONLESS, checked against the commitment
markSettled(contestId)        ← operator, gated on the salt reveal
```

---

## 4. Design decisions that are intentional

An auditor may reasonably flag these as odd. Each one closes a specific attack,
so please treat "simplify this" as a finding only if the attack is also
addressed.

### 4.1 The build seed is `keccak256(vrfBuildSeed, salt)`, not the raw VRF output

VRF alone stops the operator grinding decks, but **VRF output is public the
moment it is fulfilled**. Deck generation is deterministic, so anyone who
reconstructs the participant snapshot could regenerate the entire undrawn deck
before entries open, watch `EntryAssigned` events, and enter only when the
residual pool is favourable. On small decks that is a practical positive-EV
attack against paying users.

Commit-reveal alone stops that leak but **not** the grinding, because the
operator picks the seed and can search offline before committing.

Both halves are required. The salt commitment is published at stage 1, before
the VRF seed exists, so the operator cannot grind the salt either.

### 4.2 The VRF request is issued inside `commitStage1`, atomically

If committing and requesting were separate calls, an operator could request,
inspect the seed, dislike the resulting deck, abandon, and retry. One contest
gets one build seed and there is no second code path.

### 4.3 One Merkle root **per segment**

The draw yields a *segment-local* index. Mapping that to a leaf in a single
master tree would require the split permutation, which requires the salt, which
stays secret until lock. A single tree would make live verification impossible
for the entire life of every contest.

### 4.4 `fulfillRandomWords` can never revert

A reverting VRF callback consumes and destroys the seed permanently, and on an
immutable contract there is no recovery. Every branch is a silent `return`, and
no external calls are made. **Please attack this specifically.**

### 4.5 `finalize` and `revealSalt` are permissionless

After fulfillment the outcome is a pure function of public on-chain state, so
nobody, including the operator, has discretion left. Leaving them open means a
user whose reveal is withheld can force it themselves for a few cents of gas.
The full ordered `entryIds` array is hash-checked on every call, so a caller
cannot substitute or reorder entries.

### 4.6 `pause()` blocks intake only

It must not be able to block `fulfillRandomWords`, `finalize`, `revealSalt` or
`markSettled`. Admins may halt new work; they must never be able to delay or
alter an in-flight assignment.

### 4.7 Immutable, with a registry for versioning

No proxy and no upgrade path, because an upgradeable fairness contract is a
contradiction: "no duplicate assignment, no operator reroll, no manual override"
are only guarantees if nobody can replace the enforcing code. Versioning happens
by deploying a new instance and pointing new contests at it via `SpinRegistry`.
Contests already bound keep the exact bytecode that committed them.

---

## 5. Where we most want scrutiny

Ranked by our own assessment of risk.

1. **The sparse Fisher-Yates draw** (`_draw`). Storage encodes `value + 1` so a
   zero slot means "untouched". The safety property is *no deck index is ever
   assigned twice, across any interleaving of calls, across both segments*. We
   test this with Foundry invariants but it is the single place a subtle bug
   would silently hand two users the same lineup.
2. **`fulfillRandomWords` reverting under any input.** See 4.4.
3. **Request-ID collision or confusion** between `BUILD_SEED` and `BATCH_SEED`
   kinds in the `_requests` mapping.
4. **Finalization idempotency.** `finalize` is chunked, resumable, and callable
   by anyone. Can a crafted call double-assign, skip, or corrupt the cursor?
5. **`markSettled` / `revealSalt` ordering.** Can settlement be reached without
   a valid salt reveal? Can a salt be revealed before `lockAt`?
6. **Registry write-once binding.** `implementationOf` must never be
   re-pointable, including by the owner.
7. **Gas griefing on `finalize`.** `MAX_BATCH_SIZE` is 256 and
   `MAX_FINALIZE_CHUNK` is 128. Can a batch be made unfinalizable?

---

## 6. Known and accepted

Please confirm these rather than re-report them, unless our reasoning is wrong.

- **`block.timestamp` comparisons.** Lock times are hour-scale; Base sequencer
  drift is seconds. Not exploitable at this granularity.
- **Modulo bias in `_draw`.** Bounded by `remaining / 2**256`. With `remaining`
  at most `2**32`, bias is below `2**-224`.
- **A stuck batch is a refund, not a retry.** There is deliberately no
  re-request path; one would let an operator observe assignments and roll again.
- **Owner currently equals operator.** A single EOA (`0xdC95…C04A`) is both. We
  know this is wrong for production and will move ownership to a Safe before any
  real-money contest is bound. Flag it if you think the mitigation is
  insufficient, but it is not news.
- **`ZeroAddress` is inherited** from `VRFConsumerBaseV2Plus` rather than
  redeclared; redeclaring is a compile error.

- **Slither `reentrancy-no-eth` on `commitStage1` and `commitBatch`.** Excluded
  in `slither.config.json`, with reasoning, and we want this specific exclusion
  challenged if you disagree.

  Both instances are the same pattern: `requestId` is the **return value** of
  `s_vrfCoordinator.requestRandomWords(...)`, so the write that records it
  cannot be hoisted above the call. It is structurally irreducible.

  What we did do is claim the storage slot **before** the external call:
  `commitStage1` sets `status = STAGE1` first, so a reentrant call reverts with
  `ContestExists`; `commitBatch` writes the batch record and burns the sequence
  number first, so a reentrant call reverts with `BatchExists` or `BadSequence`.
  The only post-call writes are `c.buildSeedRequestId` and
  `_batches[batchId].requestId`.

  The coordinator is also a trusted contract that issues no callback during
  `requestRandomWords`. **This ordering was tightened as a direct result of
  running Slither before submitting for audit**; the original code wrote all
  state after the call.

---

## 7. What to send an auditor

1. **Read-only repo access.** Per our policy, audit firms get a snapshot repo
   under the `clubz-audit` GitHub org rather than access to a personal account.
2. **This document.**
3. **The two deployed addresses** above, both verified, so they can diff
   deployed bytecode against source.
4. **Commit hash** of the exact revision to audit (`git rev-parse HEAD`).
5. Note that **the contracts are already deployed but not yet bound**, so a
   finding can still be fixed by deploying a new implementation and approving it
   in the registry. Nothing has to be migrated.

---

## 8. Where to get it audited

Options, cheapest first. A ~440 SLOC contract that holds no funds sits at the
low end of most firms' ranges.

### Competitive / marketplace

| Platform | Model | Typical cost | Turnaround |
|---|---|---|---|
| [Cantina](https://cantina.xyz) | Competition or solo via marketplace | $10k–50k | 1–3 weeks |
| [Code4rena](https://code4rena.com) | Public competition | $20k–60k | 1–2 weeks |
| [Sherlock](https://sherlock.xyz) | Contest + optional coverage | $15k–50k | 1–2 weeks |
| [Hats Finance](https://hats.finance) | Continuous / competition | Variable | ongoing |

### Boutique firms (good fit for this size)

- [Pashov Audit Group](https://www.pashov.net) — small scope, fast, well-regarded
- [Guardian](https://guardianaudits.com)
- [Zellic](https://www.zellic.io)
- [Trust Security](https://www.trust-security.xyz)

### Larger firms (more expensive, slower, strongest signal)

- [OpenZeppelin](https://www.openzeppelin.com/security-audits)
- [Trail of Bits](https://www.trailofbits.com)
- [Spearbit](https://spearbit.com)
- [Consensys Diligence](https://diligence.consensys.io)

### Static analysis already run

**Slither has been run and is clean**, with two documented exclusions covered in
section 6. Running it found a genuine checks-effects-interactions violation in
`commitStage1` and `commitBatch`, which has been fixed. That is exactly the
value of doing this before paying for an audit.

### Free / do-first, before paying anyone

Run these yourself; they cost nothing and remove the findings an auditor would
otherwise charge you to report.

```bash
# Slither — wired into CI and already run; config in slither.config.json
pip install slither-analyzer
slither .

# Aderyn — fast Rust static analyzer
cargo install aderyn && aderyn .

# Foundry's own fuzzer, cranked up
FOUNDRY_PROFILE=ci forge test

# Mythril — symbolic execution (slow, deep)
pip install mythril
myth analyze src/SpinAssignment.sol --solv 0.8.28
```

### Bug bounty (after the audit, not instead of it)

- [Immunefi](https://immunefi.com) — the standard for ongoing coverage.

---

## 9. Reproducing the build

```bash
git clone <repo> && cd contracts
forge install
forge build            # solc 0.8.28, optimizer 1000 runs, bytecode_hash none
forge test             # 58 tests
FOUNDRY_PROFILE=ci forge test   # 20k fuzz runs, invariant depth 256
```

Deployed bytecode should match a local build exactly, since metadata hashing is
disabled. Both contracts are verified on Basescan and Sourcify with full
creation and runtime matches, so this is independently checkable.
