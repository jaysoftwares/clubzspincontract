// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @title SpinAssignment
/// @notice Commitment and randomized lineup assignment for Clubz Spin.
/// @dev Deliberately minimal, and **immutable**: there is no proxy and no upgrade path.
///
///      An upgradeable fairness contract is a contradiction. The guarantees below
///      ("no duplicate assignment, no operator reroll, no manual override") are only
///      guarantees if nobody can replace the code that enforces them. Versioning is
///      handled by deploying a new instance and pointing new contests at it through
///      `SpinRegistry`; contests already committed here settle here.
///
///      Safe to freeze because this contract **holds no funds**. Entry fees never leave
///      the off-chain ledger, so the worst case for any bug is a stuck assignment, which
///      is refundable off-chain, not a drain.
///
///      Design notes that an auditor should not "simplify" away:
///
///      1. `effectiveBuildSeed = keccak256(vrfBuildSeed, salt)`. VRF alone stops the
///         operator grinding decks, but VRF output is public on fulfillment, which would
///         let anyone regenerate the undrawn deck before entries open and enter only when
///         the residual pool is favourable. The salt (committed at stage 1, revealed after
///         lock) closes that. Both halves are load-bearing.
///      2. One Merkle root **per segment**. The draw yields a segment-local index, and
///         mapping that to a master-tree leaf would require the split permutation, which
///         requires the salt. A single tree would make live verification impossible.
///      3. `fulfillRandomWords` can never revert. A reverting VRF callback destroys the
///         seed permanently and bricks the batch.
///      4. `finalize` is permissionless. After fulfillment the result is a pure function
///         of public on-chain data, so nobody has discretion left and there is no reason
///         to let the operator withhold a reveal.
///      5. `pause()` stops work entering, never work finishing. It must not be able to
///         delay or alter an in-flight assignment.
contract SpinAssignment is VRFConsumerBaseV2Plus {
    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    enum ContestStatus {
        NONE, // never committed
        STAGE1, // snapshot/scoring/builder/salt committed, build seed requested
        SEEDED, // VRF build seed fulfilled, deck may be built off-chain
        COMMITTED, // stage 2 in: rules hash, per-segment roots and sizes, lock time
        REVEALED, // salt revealed after lock, deck fully reproducible
        SETTLED, // operator marked the contest finished
        ABANDONED // admin abandoned before stage 2; can never be revived
    }

    enum RequestKind {
        NONE,
        BUILD_SEED,
        BATCH_SEED
    }

    uint8 internal constant SEGMENT_DIRECT = 0;
    uint8 internal constant SEGMENT_PROMO = 1;
    uint8 internal constant SEGMENT_COUNT = 2;

    /// @dev Bounds a single finalize call. Matches the 100-entry batch policy with
    ///      headroom, and keeps any one transaction inside a comfortable gas envelope.
    uint32 public constant MAX_FINALIZE_CHUNK = 128;

    /// @dev Hard ceiling on entries per batch, enforced at commit time so that a batch
    ///      can always be finalized. Chosen with the 4s/100-entry trigger policy.
    uint32 public constant MAX_BATCH_SIZE = 256;

    struct Contest {
        bytes32 snapshotHash;
        bytes32 scoringHash;
        bytes32 builderHash;
        bytes32 saltCommitment;
        bytes32 rulesHash;
        bytes32 vrfBuildSeed;
        bytes32 salt;
        uint256 buildSeedRequestId;
        uint64 lockAt;
        ContestStatus status;
    }

    struct Segment {
        bytes32 root;
        uint32 size;
        uint32 remaining;
    }

    struct Batch {
        bytes32 contestId;
        bytes32 entriesHash;
        bytes32 seed;
        uint256 requestId;
        uint32 size;
        uint32 cursor;
        uint64 sequence;
        uint8 segment;
        bool seeded;
    }

    struct PendingRequest {
        RequestKind kind;
        bytes32 targetId;
    }

    /// @dev Loop context for `_assignRange`. Exists to keep `finalize` off the stack limit.
    struct FinalizeCtx {
        bytes32 batchId;
        bytes32 contestId;
        bytes32 seed;
        uint64 sequence;
        uint8 segment;
    }

    struct VrfConfig {
        bytes32 keyHash;
        uint256 subId;
        uint32 callbackGasLimit;
        uint16 requestConfirmations;
        bool nativePayment;
    }

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Address permitted to commit contests and batches. Hot key, held by the worker.
    address public operator;

    /// @notice Blocks new work entering. Never blocks fulfillment, finalization or reveal.
    bool public paused;

    VrfConfig public vrfConfig;

    mapping(bytes32 contestId => Contest) private _contests;
    mapping(bytes32 contestId => mapping(uint8 segment => Segment)) private _segments;

    /// @dev Sparse Fisher-Yates state. `_swaps[c][s][k] == 0` means the virtual array
    ///      still holds its identity value `k`; otherwise it holds `value + 1`.
    mapping(bytes32 contestId => mapping(uint8 segment => mapping(uint32 slot => uint32 valuePlusOne))) private _swaps;

    mapping(bytes32 contestId => mapping(uint8 segment => uint64 next)) public nextBatchSequence;

    mapping(bytes32 batchId => Batch) private _batches;

    /// @dev batchId => position within batch => assigned deck index, stored as value+1
    ///      so that 0 unambiguously means "not yet assigned".
    mapping(bytes32 batchId => mapping(uint32 position => uint32 deckIndexPlusOne)) private _assignments;

    mapping(uint256 requestId => PendingRequest) private _requests;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event OperatorChanged(address indexed previousOperator, address indexed newOperator);
    event PausedSet(bool paused);
    event VrfConfigSet(bytes32 keyHash, uint256 subId, uint32 callbackGasLimit, uint16 confirmations, bool native);

    event Stage1Committed(
        bytes32 indexed contestId,
        bytes32 snapshotHash,
        bytes32 scoringHash,
        bytes32 builderHash,
        bytes32 saltCommitment,
        uint256 requestId
    );
    event BuildSeedFulfilled(bytes32 indexed contestId, uint256 indexed requestId, bytes32 vrfBuildSeed);
    event Stage2Committed(
        bytes32 indexed contestId,
        bytes32 rulesHash,
        bytes32 directRoot,
        uint32 directSize,
        bytes32 promoRoot,
        uint32 promoSize,
        uint64 lockAt
    );
    event SaltRevealed(bytes32 indexed contestId, bytes32 salt, bytes32 effectiveBuildSeed);
    event ContestSettled(bytes32 indexed contestId);
    event ContestAbandoned(bytes32 indexed contestId, string reason);

    /// @dev `entryIds` is emitted in full so that anyone can reconstruct the batch and
    ///      call `finalize` without the operator's cooperation. This is what makes
    ///      permissionless finalization usable in practice rather than in theory.
    event BatchCommitted(
        bytes32 indexed batchId,
        bytes32 indexed contestId,
        uint8 segment,
        uint64 sequence,
        bytes32 entriesHash,
        bytes32[] entryIds,
        uint256 requestId
    );
    event BatchSeedFulfilled(bytes32 indexed batchId, uint256 indexed requestId, bytes32 seed);
    event EntryAssigned(
        bytes32 indexed batchId, bytes32 indexed entryId, uint32 position, uint8 segment, uint32 deckIndex
    );
    event BatchFinalized(bytes32 indexed batchId, uint32 assigned);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotOperator();
    error Paused();
    // NOTE: `ZeroAddress` is inherited from VRFConsumerBaseV2Plus; redeclaring it here
    // is a compile error, so this contract intentionally reuses the base's error.
    error ContestExists();
    error ContestNotFound();
    error WrongContestStatus(ContestStatus actual);
    error SaltCommitmentRequired();
    error SegmentSizeZero();
    error LockInPast();
    error NotLockedYet();
    error SaltMismatch();
    error BatchExists();
    error BadSequence(uint64 expected);
    error EmptyBatch();
    error BatchTooLarge();
    error BatchNotFound();
    error BatchNotSeeded();
    error BatchAlreadyFinalized();
    error EntriesHashMismatch();
    error SegmentExhausted();
    error UnknownSegment();
    error ContestLocked();
    error ChunkTooLarge();

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    /// @dev Applied ONLY to functions that let new work in. Deliberately absent from
    ///      `fulfillRandomWords`, `finalize`, `revealSalt` and `markSettled`.
    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    // -------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------

    constructor(address vrfCoordinator, address initialOperator, VrfConfig memory config)
        VRFConsumerBaseV2Plus(vrfCoordinator)
    {
        if (initialOperator == address(0)) revert ZeroAddress();
        operator = initialOperator;
        vrfConfig = config;
        emit OperatorChanged(address(0), initialOperator);
        emit VrfConfigSet(
            config.keyHash, config.subId, config.callbackGasLimit, config.requestConfirmations, config.nativePayment
        );
    }

    // -------------------------------------------------------------------------
    // Admin (owner is the Safe; ConfirmedOwner gives a two-step handover)
    // -------------------------------------------------------------------------

    /// @notice Rotate the operator hot key. State only, never code.
    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();
        emit OperatorChanged(operator, newOperator);
        operator = newOperator;
    }

    /// @notice Stop new contests and batches being committed.
    /// @dev Cannot stop a committed batch from being seeded, finalized or revealed. That
    ///      is the whole point: admins may halt intake, never outcomes.
    function setPaused(bool value) external onlyOwner {
        paused = value;
        emit PausedSet(value);
    }

    function setVrfConfig(VrfConfig calldata config) external onlyOwner {
        vrfConfig = config;
        emit VrfConfigSet(
            config.keyHash, config.subId, config.callbackGasLimit, config.requestConfirmations, config.nativePayment
        );
    }

    /// @notice Abandon a contest that never reached stage 2.
    /// @dev Exists so that a failed build is an explicit, publicly visible on-chain event
    ///      rather than a silent gap. A contest that reached COMMITTED can never be
    ///      abandoned, because entrants may already hold assignments.
    function abandonContest(bytes32 contestId, string calldata reason) external onlyOwner {
        Contest storage c = _contests[contestId];
        if (c.status == ContestStatus.NONE) revert ContestNotFound();
        if (c.status != ContestStatus.STAGE1 && c.status != ContestStatus.SEEDED) {
            revert WrongContestStatus(c.status);
        }
        c.status = ContestStatus.ABANDONED;
        emit ContestAbandoned(contestId, reason);
    }

    // -------------------------------------------------------------------------
    // Stage 1: freeze inputs and request the build seed, atomically
    // -------------------------------------------------------------------------

    /// @notice Commit the frozen build inputs and request the contest's build seed.
    /// @dev The VRF request is issued in the *same transaction* as the commitment, on
    ///      purpose. If the operator could commit and then choose when to request, it
    ///      could request, inspect the seed, dislike the resulting deck, and abandon and
    ///      retry until a favourable seed appeared. One contest gets one build seed and
    ///      there is no path to a second.
    /// @param saltCommitment keccak256(salt). The salt itself stays secret until after lock.
    function commitStage1(
        bytes32 contestId,
        bytes32 snapshotHash,
        bytes32 scoringHash,
        bytes32 builderHash,
        bytes32 saltCommitment
    ) external onlyOperator whenNotPaused returns (uint256 requestId) {
        Contest storage c = _contests[contestId];
        if (c.status != ContestStatus.NONE) revert ContestExists();
        if (saltCommitment == bytes32(0)) revert SaltCommitmentRequired();

        requestId = _requestRandomWord();

        c.snapshotHash = snapshotHash;
        c.scoringHash = scoringHash;
        c.builderHash = builderHash;
        c.saltCommitment = saltCommitment;
        c.buildSeedRequestId = requestId;
        c.status = ContestStatus.STAGE1;

        _requests[requestId] = PendingRequest({kind: RequestKind.BUILD_SEED, targetId: contestId});

        emit Stage1Committed(contestId, snapshotHash, scoringHash, builderHash, saltCommitment, requestId);
    }

    // -------------------------------------------------------------------------
    // Stage 2: commit the calibrated rules and the per-segment deck roots
    // -------------------------------------------------------------------------

    /// @notice Commit the calibrated rules hash and both segment roots.
    /// @dev Two stages exist because `rulesHash` contains the calibrated band, which can
    ///      only be computed once the build seed is known.
    function commitStage2(
        bytes32 contestId,
        bytes32 rulesHash,
        bytes32 directRoot,
        uint32 directSize,
        bytes32 promoRoot,
        uint32 promoSize,
        uint64 lockAt
    ) external onlyOperator whenNotPaused {
        Contest storage c = _contests[contestId];
        if (c.status != ContestStatus.SEEDED) revert WrongContestStatus(c.status);
        if (directSize == 0 || promoSize == 0) revert SegmentSizeZero();
        if (lockAt <= block.timestamp) revert LockInPast();

        c.rulesHash = rulesHash;
        c.lockAt = lockAt;
        c.status = ContestStatus.COMMITTED;

        _segments[contestId][SEGMENT_DIRECT] = Segment({root: directRoot, size: directSize, remaining: directSize});
        _segments[contestId][SEGMENT_PROMO] = Segment({root: promoRoot, size: promoSize, remaining: promoSize});

        emit Stage2Committed(contestId, rulesHash, directRoot, directSize, promoRoot, promoSize, lockAt);
    }

    // -------------------------------------------------------------------------
    // Batches
    // -------------------------------------------------------------------------

    /// @notice Commit an ordered batch of entries and request its seed.
    /// @dev The ordered entry list is committed *before* the seed exists, which is what
    ///      makes the assignment binding. Only the hash is stored; the array is emitted
    ///      so anyone can reconstruct it for `finalize`.
    ///
    ///      A batch gets exactly one VRF request, permanently. `sequence` must equal the
    ///      next expected value, so a `batchId` can never be reused, and there is no code
    ///      path anywhere that issues a second request for an existing batch. Without that
    ///      the operator could observe a batch's assignments, dislike them, and roll again.
    ///      A batch whose request never fulfills stays stuck on purpose, and those entries
    ///      are refunded off-chain where the money actually lives.
    function commitBatch(bytes32 contestId, uint8 segment, uint64 sequence, bytes32[] calldata entryIds)
        external
        onlyOperator
        whenNotPaused
        returns (bytes32 batchId, uint256 requestId)
    {
        if (segment >= SEGMENT_COUNT) revert UnknownSegment();

        Contest storage c = _contests[contestId];
        if (c.status != ContestStatus.COMMITTED) revert WrongContestStatus(c.status);
        if (block.timestamp >= c.lockAt) revert ContestLocked();

        uint32 size = uint32(entryIds.length);
        if (size == 0) revert EmptyBatch();
        if (size > MAX_BATCH_SIZE) revert BatchTooLarge();

        Segment storage seg = _segments[contestId][segment];
        if (seg.remaining < size) revert SegmentExhausted();

        uint64 expected = nextBatchSequence[contestId][segment];
        if (sequence != expected) revert BadSequence(expected);

        batchId = computeBatchId(contestId, segment, sequence);
        if (_batches[batchId].contestId != bytes32(0)) revert BatchExists();

        bytes32 entriesHash = keccak256(abi.encodePacked(entryIds));
        requestId = _requestRandomWord();

        _batches[batchId] = Batch({
            contestId: contestId,
            entriesHash: entriesHash,
            seed: bytes32(0),
            requestId: requestId,
            size: size,
            cursor: 0,
            sequence: sequence,
            segment: segment,
            seeded: false
        });

        nextBatchSequence[contestId][segment] = expected + 1;
        _requests[requestId] = PendingRequest({kind: RequestKind.BATCH_SEED, targetId: batchId});

        emit BatchCommitted(batchId, contestId, segment, sequence, entriesHash, entryIds, requestId);
    }

    // -------------------------------------------------------------------------
    // VRF callback
    // -------------------------------------------------------------------------

    /// @dev MUST NOT REVERT, under any input, ever.
    ///
    ///      Chainlink calls this from `rawFulfillRandomWords`. If it reverts, the seed is
    ///      consumed and lost forever and the batch is permanently unfinalizable, with no
    ///      recovery path on an immutable contract. Every branch here is therefore a
    ///      silent return rather than a revert, and no external calls are made.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        if (randomWords.length == 0) return;

        PendingRequest memory req = _requests[requestId];
        if (req.kind == RequestKind.NONE) return;

        delete _requests[requestId];
        bytes32 word = bytes32(randomWords[0]);

        if (req.kind == RequestKind.BUILD_SEED) {
            Contest storage c = _contests[req.targetId];
            // Only a contest still awaiting its build seed may accept one.
            if (c.status != ContestStatus.STAGE1) return;
            c.vrfBuildSeed = word;
            c.status = ContestStatus.SEEDED;
            emit BuildSeedFulfilled(req.targetId, requestId, word);
        } else {
            Batch storage b = _batches[req.targetId];
            if (b.contestId == bytes32(0)) return;
            if (b.seeded) return;
            b.seed = word;
            b.seeded = true;
            emit BatchSeedFulfilled(req.targetId, requestId, word);
        }
    }

    // -------------------------------------------------------------------------
    // Finalization: permissionless, chunked, resumable, idempotent
    // -------------------------------------------------------------------------

    /// @notice Assign deck indexes to a seeded batch. Callable by anyone.
    /// @dev Deliberately unpermissioned. Once the seed lands the outcome is a pure
    ///      function of public on-chain state, so nobody, including the operator, has any
    ///      discretion left to exercise. Leaving it open means a user whose reveal is
    ///      being withheld, by a dead worker or a hostile one, can pay gas and force it
    ///      themselves. Censorship becomes impossible rather than merely discouraged.
    ///
    ///      The full ordered `entryIds` array is supplied and hash-checked on every call,
    ///      so a caller cannot substitute or reorder entries. Only the window
    ///      `[cursor, cursor + maxCount)` is processed, letting a large batch finish
    ///      across several transactions and resume cleanly after a revert or a crash.
    /// @param maxCount Upper bound on entries processed in this call.
    /// @return processed Number of entries assigned by this call. Zero if already complete.
    function finalize(bytes32 batchId, bytes32[] calldata entryIds, uint32 maxCount)
        external
        returns (uint32 processed)
    {
        if (maxCount == 0 || maxCount > MAX_FINALIZE_CHUNK) revert ChunkTooLarge();

        Batch storage b = _batches[batchId];
        if (b.contestId == bytes32(0)) revert BatchNotFound();
        if (!b.seeded) revert BatchNotSeeded();
        if (b.cursor >= b.size) revert BatchAlreadyFinalized();
        if (uint32(entryIds.length) != b.size) revert EntriesHashMismatch();
        if (keccak256(abi.encodePacked(entryIds)) != b.entriesHash) revert EntriesHashMismatch();

        uint32 start = b.cursor;
        uint32 end = start + maxCount;
        if (end > b.size) end = b.size;

        _assignRange(
            FinalizeCtx({
                batchId: batchId, contestId: b.contestId, seed: b.seed, sequence: b.sequence, segment: b.segment
            }),
            entryIds,
            start,
            end
        );

        b.cursor = end;
        processed = end - start;

        if (end == b.size) emit BatchFinalized(batchId, b.size);
    }

    /// @dev Split out of `finalize` purely to keep the stack shallow. Holds no logic of
    ///      its own beyond the §24 entropy derivation and the draw.
    function _assignRange(FinalizeCtx memory ctx, bytes32[] calldata entryIds, uint32 start, uint32 end) private {
        Segment storage seg = _segments[ctx.contestId][ctx.segment];

        for (uint32 i = start; i < end; ++i) {
            bytes32 entryId = entryIds[i];

            // §24 of the PRD. Every component is frozen before the seed exists.
            bytes32 entropy = keccak256(abi.encode(ctx.seed, ctx.contestId, ctx.segment, ctx.sequence, i, entryId));

            uint32 deckIndex = _draw(ctx.contestId, ctx.segment, seg, entropy);
            _assignments[ctx.batchId][i] = deckIndex + 1;

            emit EntryAssigned(ctx.batchId, entryId, i, ctx.segment, deckIndex);
        }
    }

    /// @dev Sparse Fisher-Yates over a virtual array `A` where `A[k] == k` until written.
    ///      O(1) time and O(draws) storage, so the deck is never materialized on chain.
    ///      Slots hold `value + 1` so that a zero slot means "untouched" rather than
    ///      "holds index 0".
    ///
    ///      Modulo bias is bounded by `remaining / 2**256` and is therefore negligible:
    ///      `remaining` is at most 2**32, leaving bias below 2**-224.
    function _draw(bytes32 contestId, uint8 segment, Segment storage seg, bytes32 entropy)
        private
        returns (uint32 index)
    {
        uint32 remaining = seg.remaining;
        if (remaining == 0) revert SegmentExhausted();

        mapping(uint32 => uint32) storage swaps = _swaps[contestId][segment];

        uint32 j = uint32(uint256(entropy) % remaining);
        uint32 jVal = swaps[j];
        index = jVal == 0 ? j : jVal - 1;

        uint32 lastSlot = remaining - 1;
        uint32 lastVal = swaps[lastSlot];
        uint32 last = lastVal == 0 ? lastSlot : lastVal - 1;

        swaps[j] = last + 1;
        seg.remaining = lastSlot;
    }

    // -------------------------------------------------------------------------
    // Reveal and settlement
    // -------------------------------------------------------------------------

    /// @notice Reveal the salt after lock, making the whole deck reproducible.
    /// @dev Permissionless: the check is the commitment, not the caller, so a correct
    ///      salt from anyone is as good as one from the operator, and the operator cannot
    ///      censor its own contest's verification. Enforced to be after `lockAt` so the
    ///      undrawn pool cannot leak while entries are still open.
    function revealSalt(bytes32 contestId, bytes32 salt) external {
        Contest storage c = _contests[contestId];
        if (c.status != ContestStatus.COMMITTED) revert WrongContestStatus(c.status);
        if (block.timestamp < c.lockAt) revert NotLockedYet();
        if (keccak256(abi.encodePacked(salt)) != c.saltCommitment) revert SaltMismatch();

        c.salt = salt;
        c.status = ContestStatus.REVEALED;

        emit SaltRevealed(contestId, salt, keccak256(abi.encodePacked(c.vrfBuildSeed, salt)));
    }

    /// @notice Mark a contest finished. Gated on the salt reveal.
    /// @dev Withholding the salt therefore cannot be used to escape scrutiny; it only
    ///      strands the operator's own contest short of settlement.
    function markSettled(bytes32 contestId) external onlyOperator {
        Contest storage c = _contests[contestId];
        if (c.status != ContestStatus.REVEALED) revert WrongContestStatus(c.status);
        c.status = ContestStatus.SETTLED;
        emit ContestSettled(contestId);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function computeBatchId(bytes32 contestId, uint8 segment, uint64 sequence) public pure returns (bytes32) {
        return keccak256(abi.encode(contestId, segment, sequence));
    }

    function getContest(bytes32 contestId) external view returns (Contest memory) {
        return _contests[contestId];
    }

    function getSegment(bytes32 contestId, uint8 segment) external view returns (Segment memory) {
        return _segments[contestId][segment];
    }

    function getBatch(bytes32 batchId) external view returns (Batch memory) {
        return _batches[batchId];
    }

    /// @notice Assigned deck index for a position in a batch.
    /// @return assigned Whether the position has been finalized yet.
    /// @return deckIndex The segment-local deck index, meaningful only when `assigned`.
    function getAssignment(bytes32 batchId, uint32 position) external view returns (bool assigned, uint32 deckIndex) {
        uint32 raw = _assignments[batchId][position];
        return (raw != 0, raw == 0 ? 0 : raw - 1);
    }

    /// @notice The seed the deck builder actually uses. Zero until the salt is revealed.
    function effectiveBuildSeed(bytes32 contestId) external view returns (bytes32) {
        Contest storage c = _contests[contestId];
        if (c.status != ContestStatus.REVEALED && c.status != ContestStatus.SETTLED) return bytes32(0);
        return keccak256(abi.encodePacked(c.vrfBuildSeed, c.salt));
    }

    function isBatchFinalized(bytes32 batchId) external view returns (bool) {
        Batch storage b = _batches[batchId];
        return b.contestId != bytes32(0) && b.cursor == b.size;
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _requestRandomWord() private returns (uint256) {
        VrfConfig memory cfg = vrfConfig;
        return s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: cfg.keyHash,
                subId: cfg.subId,
                requestConfirmations: cfg.requestConfirmations,
                callbackGasLimit: cfg.callbackGasLimit,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: cfg.nativePayment}))
            })
        );
    }
}
