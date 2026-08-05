# Clubz Spin contracts

On-chain commitment and randomized lineup assignment for Clubz Spin.

Spec: `docs/clubz-spin-prd-v2.md` in the main workspace, corrected PRD v2.0. Sections
20.1a, 21.1 and 24 are the ones this code implements directly.

## What is and is not on chain

**On chain:** input commitments, VRF requests, draw-without-replacement assignment,
verification events.

**Off chain:** salary import, deck generation, scoring, leaderboards, and **all money**.

The contract never holds funds. Entry fees are locked in the existing clubz ledger,
inside the same database transaction that records the entry. The worst case for a bug
here is a stuck assignment, which is refunded off chain. There is nothing to drain.

## Contracts

| Contract | Mutable? | Role |
|---|---|---|
| `SpinAssignment` | **No.** No proxy, no upgrade path | Commitments, VRF, assignment |
| `SpinRegistry` | Yes, minimally | Maps a contest to the implementation governing it |

`SpinAssignment` is immutable on purpose. It claims to enforce "no duplicate assignment,
no operator reroll, no manual override", and those are only guarantees if nobody can
replace the code enforcing them. Versioning happens through the registry: deploy a new
implementation, have the Safe approve it, point new contests at it. Contests already
bound keep running on the exact bytecode that committed them.

## The five things not to "simplify"

Each closes a specific attack. They look like extra ceremony until you know which one.

**1. The build seed is `keccak256(vrfBuildSeed, salt)`, not the raw VRF output.**
VRF alone stops the operator grinding decks, but VRF output is public on fulfillment,
which would let anyone regenerate the undrawn deck before entries open and enter only
when the residual pool is favourable. On the measured small decks (F1 at 7,398, NBA
showdown at 2,590) that is a practical positive-EV attack. Commit-reveal alone stops the
leak but not the grinding, because the operator picks the seed. Both halves are required.

**2. The build seed is requested inside `commitStage1`, atomically.**
If committing and requesting were separate, the operator could request, inspect the seed,
dislike the resulting deck, abandon, and retry. One contest gets one build seed and there
is no second code path.

**3. One Merkle root per segment.**
The draw yields a *segment-local* index. Mapping that to a master-tree leaf would need the
split permutation, which needs the salt, which is secret until lock. A single tree would
make live verification impossible for the entire life of every contest.

**4. `fulfillRandomWords` never reverts.**
A reverting VRF callback consumes and destroys the seed, permanently bricking the batch
with no recovery on an immutable contract. Every branch is a silent return.

**5. `pause()` blocks intake only.**
It cannot block `fulfillRandomWords`, `finalize`, `revealSalt` or `markSettled`. Admins
may halt new work; they may never delay or alter an in-flight assignment.

## Permissionless finalization

`finalize` is callable by anyone, deliberately.

Once VRF has fulfilled, the assignment is a pure function of public on-chain data and
nobody has discretion left. So a user whose reveal is being withheld, by a dead worker, a
compromised key, or an operator acting in bad faith, can pay a few cents of gas and force
their own assignment. Censorship is impossible rather than merely discouraged. The full
ordered entry list is hash-checked on every call, so a caller cannot substitute or reorder
entries, and the result is byte-identical regardless of who calls or how they chunk it.

`revealSalt` is permissionless for the same reason: the check is the commitment, not the
caller.

## Layout

```
src/SpinAssignment.sol                immutable core
src/SpinRegistry.sol                  thin, Safe-owned version registry
test/SpinBase.t.sol                   fixture wired to the real Chainlink VRF 2.5 mock
test/SpinAssignment.t.sol             unit coverage, one section per design decision
test/SpinAssignment.invariant.t.sol   randomized call sequences
test/SpinRegistry.t.sol               separation of duties, write-once binding
script/Deploy.s.sol                   Base Sepolia / Base mainnet
script/LocalLifecycle.s.sol           full lifecycle, reference sequence for the worker
```

## Running it

```bash
forge build
forge test                      # 58 tests
FOUNDRY_PROFILE=ci forge test   # 20k fuzz runs, invariant depth 256

# Full lifecycle end to end, no node required
forge script script/LocalLifecycle.s.sol:LocalLifecycle
```

`LocalLifecycle` is the reference transaction sequence for the Spin worker. Every call the
worker makes in production appears there in order.

### The invariant suite

This is why the project uses Foundry. The safety property of the draw is not a property of
any single call, it is a property of every interleaving: arbitrary batch sizes, arbitrary
segments, out-of-order VRF fulfillment, partial finalization, arbitrary callers, and the
admin pausing mid-flight.

Headline invariant: **no deck index is ever assigned twice within a segment.** If that ever
fails, two users hold the same lineup, which breaks the single promise the whole
architecture exists to make.

## Deployment

```bash
cp .env.example .env      # fill in, take VRF values from the subscription page
forge script script/Deploy.s.sol:Deploy --rpc-url base_sepolia --broadcast --verify
```

Ownership handover is deliberately manual. The deployer keeps ownership until a human
transfers it to the Safe and the Safe accepts, because a two-step handover to a wrong
address is recoverable and a one-step one is not.

After deploying:

1. Add `SpinAssignment` as a consumer on the VRF subscription.
2. Fund the subscription, and wire balance alerting into `SystemAlertService` **before**
   going live. A dry subscription presents as every user's spin hanging at once.
3. `registry.transferOwnership(safe)`, then the Safe calls `acceptOwnership()`.
4. `assignment.transferOwnership(safe)`, then the Safe calls `acceptOwnership()`.

**Base Sepolia and a full internal cycle first, then an external audit, then mainnet.**
Immutability means an audit cannot be applied retroactively.

## Known and accepted

**`block.timestamp` comparisons.** Lock times are hour-scale; sequencer timestamp drift is
seconds. Not exploitable at this granularity.

**Modulo bias in the draw.** Bounded by `remaining / 2**256`. With `remaining` at most
`2**32`, bias is below `2**-224`.

**A stuck batch is a refund, not a retry.** There is no re-request path by design, since
one would let an operator observe assignments and roll again. If VRF never fulfills,
usually an underfunded subscription, the fix is funding the subscription. If a batch is
genuinely unrecoverable, those entries are refunded off chain.
