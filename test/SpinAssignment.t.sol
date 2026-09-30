// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpinAssignment} from "../src/SpinAssignment.sol";
import {SpinBase} from "./SpinBase.t.sol";

/// @dev Unit coverage. Each section maps to one of the locked design decisions, so a
///      future change that quietly removes a guarantee fails a test that says why.
contract SpinAssignmentTest is SpinBase {
    // =========================================================================
    // Stage 1: the VRF request is atomic with the commitment
    // =========================================================================

    function test_commitStage1_requestsSeedInSameTx() public {
        uint256 requestId = _stage1(CONTEST);

        SpinAssignment.Contest memory c = spin.getContest(CONTEST);
        assertEq(uint8(c.status), uint8(SpinAssignment.ContestStatus.STAGE1));
        assertEq(c.buildSeedRequestId, requestId, "request id must be recorded at commit time");
        assertEq(c.vrfBuildSeed, bytes32(0), "seed cannot exist yet");
        assertTrue(requestId != 0, "a request must actually have been issued");
    }

    /// @dev The grinding defence. A contest gets one build seed and there is no second path.
    function test_commitStage1_cannotBeRepeated() public {
        _stage1(CONTEST);
        vm.prank(operator);
        vm.expectRevert(SpinAssignment.ContestExists.selector);
        spin.commitStage1(CONTEST, keccak256("s"), keccak256("sc"), keccak256("b"), keccak256("salt2"));
    }

    /// @dev Still refused after the seed arrives, which is when re-rolling would pay off.
    function test_commitStage1_cannotBeRepeatedAfterFulfilment() public {
        uint256 rid = _stage1(CONTEST);
        _fulfill(rid, 12345);

        vm.prank(operator);
        vm.expectRevert(SpinAssignment.ContestExists.selector);
        spin.commitStage1(CONTEST, keccak256("s"), keccak256("sc"), keccak256("b"), keccak256("salt2"));
    }

    function test_commitStage1_rejectsEmptySaltCommitment() public {
        vm.prank(operator);
        vm.expectRevert(SpinAssignment.SaltCommitmentRequired.selector);
        spin.commitStage1(CONTEST, keccak256("s"), keccak256("sc"), keccak256("b"), bytes32(0));
    }

    function test_commitStage1_onlyOperator() public {
        vm.prank(stranger);
        vm.expectRevert(SpinAssignment.NotOperator.selector);
        spin.commitStage1(CONTEST, keccak256("s"), keccak256("sc"), keccak256("b"), keccak256("salt"));
    }

    // =========================================================================
    // Stage 2
    // =========================================================================

    function test_stage2_requiresSeed() public {
        _stage1(CONTEST);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(SpinAssignment.WrongContestStatus.selector, SpinAssignment.ContestStatus.STAGE1)
        );
        spin.commitStage2(CONTEST, keccak256("r"), keccak256("d"), 10, keccak256("p"), 5, uint64(block.timestamp + 1));
    }

    function test_stage2_storesBothSegmentRoots() public {
        _openContest(CONTEST, 100, 25);

        SpinAssignment.Segment memory d = spin.getSegment(CONTEST, DIRECT);
        SpinAssignment.Segment memory p = spin.getSegment(CONTEST, PROMO);

        assertEq(d.root, keccak256("directRoot"));
        assertEq(d.size, 100);
        assertEq(d.remaining, 100);
        assertEq(p.root, keccak256("promoRoot"));
        assertEq(p.size, 25);
        assertEq(p.remaining, 25);
    }

    function test_stage2_rejectsZeroSegment() public {
        uint256 rid = _stage1(CONTEST);
        _fulfill(rid, 1);
        vm.prank(operator);
        vm.expectRevert(SpinAssignment.SegmentSizeZero.selector);
        spin.commitStage2(CONTEST, keccak256("r"), keccak256("d"), 0, keccak256("p"), 5, uint64(block.timestamp + 1));
    }

    function test_stage2_rejectsLockInPast() public {
        uint256 rid = _stage1(CONTEST);
        _fulfill(rid, 1);
        vm.prank(operator);
        vm.expectRevert(SpinAssignment.LockInPast.selector);
        spin.commitStage2(CONTEST, keccak256("r"), keccak256("d"), 10, keccak256("p"), 5, uint64(block.timestamp));
    }

    // =========================================================================
    // The VRF callback must never revert
    // =========================================================================

    /// @dev A reverting callback consumes and destroys the seed with no recovery on an
    ///      immutable contract, so unknown request ids must be ignored, not rejected.
    function test_callback_unknownRequestIdDoesNotRevert() public {
        uint256[] memory words = new uint256[](1);
        words[0] = 42;

        vm.prank(address(coordinator));
        spin.rawFulfillRandomWords(999_999, words); // must not revert
    }

    function test_callback_emptyWordsDoesNotRevert() public {
        uint256 rid = _stage1(CONTEST);
        uint256[] memory empty = new uint256[](0);

        vm.prank(address(coordinator));
        spin.rawFulfillRandomWords(rid, empty); // must not revert

        assertEq(uint8(spin.getContest(CONTEST).status), uint8(SpinAssignment.ContestStatus.STAGE1));
    }

    function test_callback_secondFulfilmentIsIgnoredNotReverted() public {
        uint256 rid = _stage1(CONTEST);
        _fulfill(rid, 111);
        bytes32 first = spin.getContest(CONTEST).vrfBuildSeed;

        uint256[] memory words = new uint256[](1);
        words[0] = 222;
        vm.prank(address(coordinator));
        spin.rawFulfillRandomWords(rid, words); // must not revert

        assertEq(spin.getContest(CONTEST).vrfBuildSeed, first, "seed must never be overwritten");
    }

    // =========================================================================
    // Batches: one request each, forever
    // =========================================================================

    function test_commitBatch_enforcesSequence() public {
        _openContest(CONTEST, 100, 25);
        bytes32[] memory ids = _entryIds(3, 1);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SpinAssignment.BadSequence.selector, uint64(0)));
        spin.commitBatch(CONTEST, DIRECT, 1, ids);
    }

    /// @dev Sequence is consumed even across a revert-free retry, so the same batchId can
    ///      never be committed twice and therefore never gets a second VRF request.
    function test_commitBatch_sequenceIsConsumedOnce() public {
        _openContest(CONTEST, 100, 25);

        vm.startPrank(operator);
        spin.commitBatch(CONTEST, DIRECT, 0, _entryIds(3, 1));
        vm.expectRevert(abi.encodeWithSelector(SpinAssignment.BadSequence.selector, uint64(1)));
        spin.commitBatch(CONTEST, DIRECT, 0, _entryIds(3, 2));
        vm.stopPrank();

        assertEq(spin.nextBatchSequence(CONTEST, DIRECT), 1);
    }

    function test_commitBatch_rejectsEmptyAndOversized() public {
        _openContest(CONTEST, 1000, 25);

        vm.startPrank(operator);
        vm.expectRevert(SpinAssignment.EmptyBatch.selector);
        spin.commitBatch(CONTEST, DIRECT, 0, _entryIds(0, 1));

        vm.expectRevert(SpinAssignment.BatchTooLarge.selector);
        spin.commitBatch(CONTEST, DIRECT, 0, _entryIds(257, 1));
        vm.stopPrank();
    }

    function test_commitBatch_rejectsAfterLock() public {
        _openContest(CONTEST, 100, 25);
        vm.warp(block.timestamp + 2 days);

        vm.prank(operator);
        vm.expectRevert(SpinAssignment.ContestLocked.selector);
        spin.commitBatch(CONTEST, DIRECT, 0, _entryIds(3, 1));
    }

    function test_commitBatch_rejectsOversubscribedSegment() public {
        _openContest(CONTEST, 5, 25);

        vm.prank(operator);
        vm.expectRevert(SpinAssignment.SegmentExhausted.selector);
        spin.commitBatch(CONTEST, DIRECT, 0, _entryIds(6, 1));
    }

    // =========================================================================
    // Finalization: permissionless, chunked, resumable
    // =========================================================================

    function test_finalize_isPermissionless() public {
        (bytes32 batchId, bytes32[] memory ids) = _seededBatch(CONTEST, DIRECT, 5);

        vm.prank(stranger); // not the operator, not the admin
        uint32 processed = spin.finalize(batchId, ids, 128);

        assertEq(processed, 5);
        assertTrue(spin.isBatchFinalized(batchId));
    }

    /// @dev The censorship property: finalization still works with the operator rotated
    ///      away and the contract paused, i.e. after a total operator failure.
    function test_finalize_worksWhenPausedAndOperatorRevoked() public {
        (bytes32 batchId, bytes32[] memory ids) = _seededBatch(CONTEST, DIRECT, 4);

        vm.startPrank(admin);
        spin.setPaused(true);
        spin.setOperator(address(0xdead));
        vm.stopPrank();

        vm.prank(stranger);
        spin.finalize(batchId, ids, 128);

        assertTrue(spin.isBatchFinalized(batchId), "a user must be able to force their own reveal");
    }

    function test_finalize_resumesFromCursor() public {
        (bytes32 batchId, bytes32[] memory ids) = _seededBatch(CONTEST, DIRECT, 10);

        assertEq(spin.finalize(batchId, ids, 4), 4);
        assertEq(spin.getBatch(batchId).cursor, 4);
        assertFalse(spin.isBatchFinalized(batchId));

        assertEq(spin.finalize(batchId, ids, 4), 4);
        assertEq(spin.finalize(batchId, ids, 100), 2, "final chunk clamps to batch size");
        assertTrue(spin.isBatchFinalized(batchId));

        vm.expectRevert(SpinAssignment.BatchAlreadyFinalized.selector);
        spin.finalize(batchId, ids, 4);
    }

    function test_finalize_rejectsTamperedEntryList() public {
        (bytes32 batchId, bytes32[] memory ids) = _seededBatch(CONTEST, DIRECT, 5);

        bytes32[] memory swapped = new bytes32[](5);
        for (uint256 i = 0; i < 5; ++i) {
            swapped[i] = ids[i];
        }
        (swapped[0], swapped[1]) = (swapped[1], swapped[0]); // reorder only

        vm.expectRevert(SpinAssignment.EntriesHashMismatch.selector);
        spin.finalize(batchId, swapped, 128);
    }

    function test_finalize_rejectsWrongLength() public {
        (bytes32 batchId,) = _seededBatch(CONTEST, DIRECT, 5);

        vm.expectRevert(SpinAssignment.EntriesHashMismatch.selector);
        spin.finalize(batchId, _entryIds(4, 1), 128);
    }

    function test_finalize_requiresSeed() public {
        _openContest(CONTEST, 100, 25);
        bytes32[] memory ids = _entryIds(5, 1);
        vm.prank(operator);
        (bytes32 batchId,) = spin.commitBatch(CONTEST, DIRECT, 0, ids);

        vm.expectRevert(SpinAssignment.BatchNotSeeded.selector);
        spin.finalize(batchId, ids, 128);
    }

    function test_finalize_rejectsOversizedChunk() public {
        (bytes32 batchId, bytes32[] memory ids) = _seededBatch(CONTEST, DIRECT, 5);

        vm.expectRevert(SpinAssignment.ChunkTooLarge.selector);
        spin.finalize(batchId, ids, 129);

        vm.expectRevert(SpinAssignment.ChunkTooLarge.selector);
        spin.finalize(batchId, ids, 0);
    }

    /// @dev Chunking must not change the outcome: the *same* batch finalized in one call
    ///      and in four must produce identical assignments.
    ///
    ///      Compared against itself via a state snapshot, deliberately. Two separate
    ///      contests would diverge legitimately, because `contestId` is an input to the
    ///      §24 entropy derivation, so comparing them would prove nothing.
    function test_finalize_chunkingDoesNotChangeOutcome() public {
        (bytes32 batchId, bytes32[] memory ids) = _seededBatch(CONTEST, DIRECT, 12);

        uint256 snap = vm.snapshotState();

        spin.finalize(batchId, ids, 128);
        uint32[] memory oneShot = new uint32[](12);
        for (uint32 i = 0; i < 12; ++i) {
            (, oneShot[i]) = spin.getAssignment(batchId, i);
        }

        vm.revertToState(snap);

        spin.finalize(batchId, ids, 3);
        spin.finalize(batchId, ids, 3);
        spin.finalize(batchId, ids, 3);
        spin.finalize(batchId, ids, 3);

        assertTrue(spin.isBatchFinalized(batchId));
        for (uint32 i = 0; i < 12; ++i) {
            (bool assigned, uint32 chunked) = spin.getAssignment(batchId, i);
            assertTrue(assigned);
            assertEq(chunked, oneShot[i], "chunk size must not affect assignment");
        }
    }

    // =========================================================================
    // Pause stops work entering, never work finishing
    // =========================================================================

    function test_pause_blocksIntake() public {
        vm.prank(admin);
        spin.setPaused(true);

        vm.prank(operator);
        vm.expectRevert(SpinAssignment.Paused.selector);
        spin.commitStage1(CONTEST, keccak256("s"), keccak256("sc"), keccak256("b"), keccak256("salt"));
    }

    function test_pause_doesNotBlockFulfilment() public {
        uint256 rid = _stage1(CONTEST);

        vm.prank(admin);
        spin.setPaused(true);

        _fulfill(rid, 777);
        assertEq(uint8(spin.getContest(CONTEST).status), uint8(SpinAssignment.ContestStatus.SEEDED));
    }

    function test_pause_doesNotBlockRevealSalt() public {
        _openContest(CONTEST, 10, 5);
        vm.warp(block.timestamp + 2 days);

        vm.prank(admin);
        spin.setPaused(true);

        spin.revealSalt(CONTEST, SALT);
        assertEq(uint8(spin.getContest(CONTEST).status), uint8(SpinAssignment.ContestStatus.REVEALED));
    }

    function test_pause_onlyOwner() public {
        vm.prank(operator);
        vm.expectRevert();
        spin.setPaused(true);
    }

    // =========================================================================
    // Salt: reveal timing, correctness, and the settlement gate
    // =========================================================================

    function test_revealSalt_rejectedBeforeLock() public {
        _openContest(CONTEST, 10, 5);

        vm.expectRevert(SpinAssignment.NotLockedYet.selector);
        spin.revealSalt(CONTEST, SALT);
    }

    function test_revealSalt_rejectsWrongSalt() public {
        _openContest(CONTEST, 10, 5);
        vm.warp(block.timestamp + 2 days);

        vm.expectRevert(SpinAssignment.SaltMismatch.selector);
        spin.revealSalt(CONTEST, keccak256("wrong"));
    }

    function test_revealSalt_isPermissionless() public {
        _openContest(CONTEST, 10, 5);
        vm.warp(block.timestamp + 2 days);

        vm.prank(stranger);
        spin.revealSalt(CONTEST, SALT);

        assertEq(uint8(spin.getContest(CONTEST).status), uint8(SpinAssignment.ContestStatus.REVEALED));
    }

    /// @dev The build seed the deck actually used is unavailable until reveal. This is the
    ///      whole point of correction 0.12.
    function test_effectiveBuildSeed_hiddenUntilReveal() public {
        _openContest(CONTEST, 10, 5);
        assertEq(spin.effectiveBuildSeed(CONTEST), bytes32(0), "must not leak before lock");

        vm.warp(block.timestamp + 2 days);
        spin.revealSalt(CONTEST, SALT);

        bytes32 vrfSeed = spin.getContest(CONTEST).vrfBuildSeed;
        assertEq(spin.effectiveBuildSeed(CONTEST), keccak256(abi.encodePacked(vrfSeed, SALT)));
    }

    function test_markSettled_requiresReveal() public {
        _openContest(CONTEST, 10, 5);
        vm.warp(block.timestamp + 2 days);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(SpinAssignment.WrongContestStatus.selector, SpinAssignment.ContestStatus.COMMITTED)
        );
        spin.markSettled(CONTEST);

        spin.revealSalt(CONTEST, SALT);
        vm.prank(operator);
        spin.markSettled(CONTEST);

        assertEq(uint8(spin.getContest(CONTEST).status), uint8(SpinAssignment.ContestStatus.SETTLED));
    }

    // =========================================================================
    // Abandonment is public, and only before entries can exist
    // =========================================================================

    function test_abandon_onlyBeforeStage2() public {
        _openContest(CONTEST, 10, 5);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(SpinAssignment.WrongContestStatus.selector, SpinAssignment.ContestStatus.COMMITTED)
        );
        spin.abandonContest(CONTEST, "too late");
    }

    function test_abandon_isTerminal() public {
        uint256 rid = _stage1(CONTEST);
        _fulfill(rid, 5);

        vm.warp(block.timestamp + spin.ABANDON_DELAY());
        vm.prank(admin);
        spin.abandonContest(CONTEST, "capacity gate failed");

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(SpinAssignment.WrongContestStatus.selector, SpinAssignment.ContestStatus.ABANDONED)
        );
        spin.commitStage2(CONTEST, keccak256("r"), keccak256("d"), 10, keccak256("p"), 5, uint64(block.timestamp + 1));
    }

    // =========================================================================
    // Draw correctness
    // =========================================================================

    /// @dev Exhaustive: draw an entire segment and assert a perfect permutation.
    function test_draw_consumesEachIndexExactlyOnce() public {
        uint32 size = 64;
        _openContest(CONTEST, size, 1);

        bool[] memory seen = new bool[](size);
        uint32 drawn;

        for (uint64 seq = 0; seq < 4; ++seq) {
            bytes32[] memory ids = _entryIds(16, seq);
            vm.prank(operator);
            (bytes32 batchId, uint256 rid) = spin.commitBatch(CONTEST, DIRECT, seq, ids);
            _fulfill(rid, uint256(keccak256(abi.encode("seed", seq))));
            spin.finalize(batchId, ids, 128);

            for (uint32 i = 0; i < 16; ++i) {
                (bool assigned, uint32 deckIndex) = spin.getAssignment(batchId, i);
                assertTrue(assigned);
                assertLt(deckIndex, size, "index must stay inside the segment");
                assertFalse(seen[deckIndex], "duplicate deck index assigned");
                seen[deckIndex] = true;
                drawn++;
            }
        }

        assertEq(drawn, size);
        assertEq(spin.getSegment(CONTEST, DIRECT).remaining, 0);
        for (uint32 i = 0; i < size; ++i) {
            assertTrue(seen[i], "every index must be handed out exactly once");
        }
    }

    function test_draw_segmentsAreIndependent() public {
        _openContest(CONTEST, 8, 8);

        (bytes32 dBatch, bytes32[] memory dIds) = _seedBatchOn(CONTEST, DIRECT, 0, 8);
        (bytes32 pBatch, bytes32[] memory pIds) = _seedBatchOn(CONTEST, PROMO, 0, 8);

        spin.finalize(dBatch, dIds, 128);
        spin.finalize(pBatch, pIds, 128);

        assertEq(spin.getSegment(CONTEST, DIRECT).remaining, 0);
        assertEq(spin.getSegment(CONTEST, PROMO).remaining, 0);
    }

    // =========================================================================
    // Admin surface
    // =========================================================================

    function test_setOperator_rotates() public {
        address newOp = makeAddr("newOp");
        vm.prank(admin);
        spin.setOperator(newOp);
        assertEq(spin.operator(), newOp);

        vm.prank(operator);
        vm.expectRevert(SpinAssignment.NotOperator.selector);
        spin.commitStage1(CONTEST, keccak256("s"), keccak256("sc"), keccak256("b"), keccak256("salt"));
    }

    function test_adminFunctions_rejectNonOwner() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        spin.setOperator(stranger);
        vm.expectRevert();
        spin.setPaused(true);
        vm.expectRevert();
        spin.abandonContest(CONTEST, "nope");
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- helpers

    function _seededBatch(bytes32 contestId, uint8 segment, uint32 n)
        internal
        returns (bytes32 batchId, bytes32[] memory ids)
    {
        _openContest(contestId, 500, 500);
        return _seedBatchOn(contestId, segment, 0, n);
    }

    function _seedBatchOn(bytes32 contestId, uint8 segment, uint64 sequence, uint32 n)
        internal
        returns (bytes32 batchId, bytes32[] memory ids)
    {
        // Distinct per segment as well as per sequence: an entry id may be committed
        // once per contest (WebThree M-08).
        ids = _entryIds(n, (uint256(segment) << 64) | sequence);
        vm.prank(operator);
        uint256 rid;
        (batchId, rid) = spin.commitBatch(contestId, segment, sequence, ids);
        _fulfill(rid, uint256(keccak256(abi.encode("batch-seed", contestId, segment, sequence))));
    }
}
