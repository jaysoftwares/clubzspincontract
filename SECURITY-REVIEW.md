# SPINZ — Internal Security Review

> **This is an internal review by the development team, not an independent
> third-party audit.**
>
> It is published for transparency, so anyone can see what analysis was run and
> what it found. It must not be described as an external audit, and it must not
> be submitted to Basescan's Security Audit form with a third-party name in the
> "Security Audit Provider" field. Doing so would misrepresent the assurance
> level to users.
>
> An independent audit is planned before any real-money contest is bound.

| | |
|---|---|
| **Project** | SPINZ (clubz.fun) |
| **Review date** | 2026-08-06 |
| **Reviewed by** | clubz.fun development team |
| **Chain** | Base mainnet (8453) |
| **Commit** | see `git rev-parse HEAD` in the contracts repository |

---

## Contracts in scope

| Contract | Address | Verified |
|---|---|---|
| `SpinAssignment` | [`0xaCb6b6827948f75A7d81f00551e5De3390243259`](https://basescan.org/address/0xaCb6b6827948f75A7d81f00551e5De3390243259#code) | Basescan |
| `SpinRegistry` | [`0x74CEf46279AeAa7A08973B4a8090a9fdDf6db832`](https://basescan.org/address/0x74CEf46279AeAa7A08973B4a8090a9fdDf6db832#code) | Basescan + Sourcify |

**Superseded, do not use:** `0x6Bb0d32dCa4F58cb89191dDEc4b47481C028f753`. It
shipped the checks-effects-interactions issue described below and was replaced.
Nothing was ever bound to it.

`SpinAssignment` is ~385 SLOC with 14 external/public functions.
`SpinRegistry` is ~58 SLOC with 5.

---

## Risk context

**The contracts hold no funds.** Entry fees are locked in an off-chain ledger
and never touch the chain. There is no withdraw path, no token, no balance, and
no approval flow. The worst outcome from a contract bug is a stuck or incorrect
lineup assignment, which is refundable off-chain.

This materially changes the risk profile. The threat model is not theft; it is
**unfairness**: an operator influencing outcomes, a user receiving a duplicate
lineup, or a result being withheld.

---

## Analysis performed

### Static analysis — Slither v0.10+

All 100 detectors run against both contracts, excluding dependencies and tests.

| Severity | Before fixes | After fixes |
|---|---:|---:|
| High | 0 | 0 |
| Medium | 2 | 0 (2 triaged, documented) |
| Low | 7 | 0 (all triaged, documented) |

Configuration is committed at `slither.config.json` with written justification
for every exclusion. Slither also runs in CI on every push with
`fail-on: medium`.

### Dynamic analysis — Foundry

- **58 tests**, all passing.
- **6 invariants**, each exercised over 16,384 randomized call sequences with
  arbitrary batch sizes, both segments, out-of-order VRF fulfillment, partial
  finalization, arbitrary callers, and the admin pausing mid-flight.
- Fuzz runs raised to 20,000 in CI.
- Gas snapshots enforced, so a change that pushes finalization past its budget
  fails the build.

The headline invariant is **no deck index is ever assigned twice within a
segment**. If that ever failed, two users would hold the same lineup, which
breaks the single guarantee the whole architecture exists to provide.

---

## Findings

### F-1 · Medium · Checks-effects-interactions violation · **FIXED**

`commitStage1` and `commitBatch` each called the Chainlink VRF coordinator
**before** writing their own state.

**Impact.** A reentrant call during the coordinator call could have started a
second contest under the same `contestId`, or committed a second batch over the
same `entryIds`. The latter would consume two deck indexes per entry, corrupting
the without-replacement accounting the uniqueness guarantee depends on.

**Mitigating factor.** The Chainlink VRF coordinator is a trusted contract that
issues no callback during `requestRandomWords`, so this was not exploitable in
practice with the configured coordinator. It was fixed regardless, because
relying on an external contract's behaviour for a safety property is exactly the
assumption that breaks when a dependency changes.

**Fix.** The storage slot is now claimed before the external call.
`commitStage1` sets `status = STAGE1` first, so reentry reverts with
`ContestExists`. `commitBatch` writes the batch record and burns the sequence
number first, so reentry reverts with `BatchExists` or `BadSequence`.

The only writes remaining after the call are `c.buildSeedRequestId` and
`_batches[batchId].requestId`. These are structurally irreducible: `requestId`
is the *return value* of the coordinator call and cannot be known beforehand.
They are safe because the slot is already claimed.

**Status.** Fixed and redeployed as
`0xaCb6b6827948f75A7d81f00551e5De3390243259`.

### F-2 · Low · `block.timestamp` used in comparisons · **Accepted**

Three comparisons against `lockAt` in `commitStage2`, `commitBatch` and
`revealSalt`.

Lock times are hour-scale and Base sequencer timestamp drift is seconds. A
manipulation of a few seconds cannot move a contest across its lock boundary in
any meaningful way. Accepted.

### F-3 · Low · Reentrancy-benign and reentrancy-events · **Accepted**

Same two call sites as F-1. After the fix, the only post-call writes and event
emissions concern `requestId`, which cannot exist before the call. No state that
gates access or affects an outcome is written after an external call.

---

## Design properties reviewed

Each of these was reviewed specifically, since each underpins a user-facing
claim.

| Claim | Mechanism | Reviewed |
|---|---|---|
| No two users get the same lineup | Sparse Fisher-Yates, draw without replacement, per-segment `remaining` counter | Invariant-tested over 16,384 call sequences |
| The operator cannot influence outcomes | VRF requested atomically inside `commitStage1`; no re-request path anywhere | Code review, no second path exists |
| The deck was fixed before entries opened | Two-stage commitment; `rulesHash` and both Merkle roots on chain before `open` | Code review |
| Nobody can withhold your result | `finalize` and `revealSalt` are permissionless | Tested with operator revoked and contract paused |
| Admins cannot alter an in-flight spin | `pause()` gates intake only, never `fulfillRandomWords` / `finalize` / `revealSalt` | Explicitly tested |
| The undrawn deck cannot be reconstructed early | `effectiveBuildSeed = keccak256(vrfSeed, salt)`, salt revealed only after lock | Code review; contract enforces `lockAt` |

---

## Known limitations

Stated plainly rather than omitted.

1. **No independent audit has been performed.** This is a self-review.
2. **The owner is currently a single EOA** (`0xdC95…C04A`) which is also the
   operator hot key. A worker compromise is therefore also an admin compromise.
   Migration to a Safe multisig is planned before real-money use. The contract
   supports this as a two-step state change, requiring no redeployment.
3. **Modulo bias in the draw** is bounded by `remaining / 2**256`. With
   `remaining` at most `2**32`, bias is below `2**-224`. Not material.
4. **A stuck batch is refunded, not retried.** There is deliberately no
   re-request path, because one would let an operator observe assignments and
   roll again. If VRF never fulfills, those entries are refunded off-chain.
5. **The off-chain deck generator is out of scope here.** It is reviewed
   separately. The contracts treat the deck as two opaque Merkle roots.

---

## Reproducing this review

```bash
git clone <contracts repo> && cd contracts
forge install
forge build
forge test                        # 58 tests
FOUNDRY_PROFILE=ci forge test     # 20k fuzz runs, invariant depth 256

pip install slither-analyzer
slither .                         # uses slither.config.json
```

Deployed bytecode is reproducible: `bytecode_hash = "none"` and
`cbor_metadata = false` are set, so a local build matches the chain byte for
byte. Both contracts are verified, so this is independently checkable by anyone.
