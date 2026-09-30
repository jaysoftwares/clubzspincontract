// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpinAssignment} from "../src/SpinAssignment.sol";
import {SpinRegistry} from "../src/SpinRegistry.sol";
import {SpinBase} from "./SpinBase.t.sol";

/// @dev The v3 guarantees, one per WebThree finding (H-07 and M-08).
contract SpinAssignmentV3Test is SpinBase {
    // =========================================================================
    // H-07: the coordinator cannot be swapped, so randomness cannot be chosen
    // =========================================================================

    function test_coordinator_isImmutable_noSetter() public {
        // v2 inherited Chainlink's owner-callable setCoordinator. v3 has no such function.
        vm.prank(admin);
        (bool ok,) = address(spin).call(abi.encodeWithSignature("setCoordinator(address)", stranger));
        assertFalse(ok, "setCoordinator must not exist");
        assertEq(address(spin.s_vrfCoordinator()), address(coordinator));
    }

    function test_owner_cannotFulfilRandomness() public {
        uint256 rid = _stage1(CONTEST);
        uint256[] memory words = new uint256[](1);
        words[0] = 42;

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(SpinAssignment.OnlyCoordinatorCanFulfill.selector, admin, address(coordinator))
        );
        spin.rawFulfillRandomWords(rid, words);
    }

    // =========================================================================
    // H-07: owner and operator are different keys
    // =========================================================================

    function test_constructor_refusesDeployerAsOperator() public {
        vm.prank(admin);
        vm.expectRevert(SpinAssignment.OwnerCannotOperate.selector);
        new SpinAssignment(address(coordinator), admin, address(registry), _cfg());
    }

    function test_constructor_refusesZeroRegistry() public {
        vm.prank(admin);
        vm.expectRevert(SpinAssignment.ZeroAddress.selector);
        new SpinAssignment(address(coordinator), operator, address(0), _cfg());
    }

    function test_setOperator_refusesOwnerAndPendingOwner() public {
        vm.startPrank(admin);
        vm.expectRevert(SpinAssignment.OwnerCannotOperate.selector);
        spin.setOperator(admin);

        address safe = makeAddr("safe");
        spin.transferOwnership(safe);
        vm.expectRevert(SpinAssignment.OwnerCannotOperate.selector);
        spin.setOperator(safe);
        vm.stopPrank();
    }

    function test_ownership_cannotBeProposedToOperator() public {
        vm.prank(admin);
        vm.expectRevert(SpinAssignment.OwnerCannotOperate.selector);
        spin.transferOwnership(operator);
    }

    function test_ownership_isTwoStep() public {
        address safe = makeAddr("safe");
        vm.prank(admin);
        spin.transferOwnership(safe);
        assertEq(spin.owner(), admin, "nothing changes until the Safe accepts");

        vm.prank(safe);
        spin.acceptOwnership();
        assertEq(spin.owner(), safe);
    }

    function test_ownership_cannotBeRenounced() public {
        vm.prank(admin);
        vm.expectRevert(SpinAssignment.CannotRenounce.selector);
        spin.renounceOwnership();
        assertEq(spin.owner(), admin);
    }

    // =========================================================================
    // H-07: a contest runs only on the code the registry binds it to
    // =========================================================================

    function test_stage1_refusesUnboundContest() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SpinAssignment.NotBoundHere.selector, address(0)));
        spin.commitStage1(CONTEST, keccak256("s"), keccak256("sc"), keccak256("b"), keccak256("salt"));
    }

    function test_stage1_refusesContestBoundElsewhere() public {
        address other = makeAddr("other-implementation");
        vm.prank(admin);
        registry.setApproved(other, true);
        vm.prank(operator);
        registry.bindTo(CONTEST, other);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SpinAssignment.NotBoundHere.selector, other));
        spin.commitStage1(CONTEST, keccak256("s"), keccak256("sc"), keccak256("b"), keccak256("salt"));
    }

    // =========================================================================
    // H-07: batches finalize in commit order, so nobody chooses who draws what
    // =========================================================================

    function test_finalize_refusesOutOfOrder() public {
        _openContest(CONTEST, 100, 100);
        (bytes32 b0, bytes32[] memory ids0) = _commitAndSeed(DIRECT, 0, 5);
        (bytes32 b1, bytes32[] memory ids1) = _commitAndSeed(DIRECT, 1, 5);

        vm.expectRevert(abi.encodeWithSelector(SpinAssignment.OutOfOrder.selector, uint64(0)));
        spin.finalize(b1, ids1, 128);

        spin.finalize(b0, ids0, 128);
        spin.finalize(b1, ids1, 128);
        assertTrue(spin.isBatchFinalized(b1));
        assertEq(spin.nextFinalizeSequence(CONTEST, DIRECT), 2);
    }

    function test_finalize_orderIsPerSegment() public {
        _openContest(CONTEST, 100, 100);
        _commitAndSeed(DIRECT, 0, 5);
        (bytes32 p0, bytes32[] memory pids) = _commitAndSeed(PROMO, 0, 5);

        // The direct head is unfinalized; the promo segment is not held up by it.
        spin.finalize(p0, pids, 128);
        assertTrue(spin.isBatchFinalized(p0));
    }

    function test_finalize_chunkedHeadKeepsItsPlace() public {
        _openContest(CONTEST, 100, 100);
        (bytes32 b0, bytes32[] memory ids0) = _commitAndSeed(DIRECT, 0, 10);
        (bytes32 b1, bytes32[] memory ids1) = _commitAndSeed(DIRECT, 1, 5);

        spin.finalize(b0, ids0, 4);
        vm.expectRevert(abi.encodeWithSelector(SpinAssignment.OutOfOrder.selector, uint64(0)));
        spin.finalize(b1, ids1, 128);

        spin.finalize(b0, ids0, 128);
        spin.finalize(b1, ids1, 128);
        assertTrue(spin.isBatchFinalized(b1));
    }

    /// @dev The outcome no longer depends on who calls finalize in what order: an
    ///      out-of-order attempt is refused without touching state, so the draw is the
    ///      same as if it had never been tried.
    function test_assignmentIndependentOfAttemptedOrder() public {
        _openContest(CONTEST, 50, 50);
        (bytes32 b0, bytes32[] memory ids0) = _commitAndSeed(DIRECT, 0, 7);
        (bytes32 b1, bytes32[] memory ids1) = _commitAndSeed(DIRECT, 1, 7);

        uint256 snap = vm.snapshotState();
        spin.finalize(b0, ids0, 128);
        spin.finalize(b1, ids1, 128);
        uint32[7] memory canonical;
        for (uint32 i = 0; i < 7; ++i) {
            (, canonical[i]) = spin.getAssignment(b1, i);
        }
        vm.revertToState(snap);

        vm.expectRevert(abi.encodeWithSelector(SpinAssignment.OutOfOrder.selector, uint64(0)));
        spin.finalize(b1, ids1, 3);
        spin.finalize(b0, ids0, 128);
        spin.finalize(b1, ids1, 128);
        for (uint32 i = 0; i < 7; ++i) {
            (, uint32 idx) = spin.getAssignment(b1, i);
            assertEq(idx, canonical[i], "an attempted reorder changed an assignment");
        }
    }

    // =========================================================================
    // M-08: capacity is reserved at commit
    // =========================================================================

    function test_commitBatch_capacityCountsUnfinalizedBatches() public {
        _openContest(CONTEST, 8, 8);
        vm.prank(operator);
        spin.commitBatch(CONTEST, DIRECT, 0, _ids(5, 1));
        assertEq(spin.reserved(CONTEST, DIRECT), 5);
        assertEq(spin.getSegment(CONTEST, DIRECT).remaining, 8, "nothing finalized yet");

        // v2 checked `remaining` (8) and let this in, oversubscribing the segment.
        vm.prank(operator);
        vm.expectRevert(SpinAssignment.SegmentExhausted.selector);
        spin.commitBatch(CONTEST, DIRECT, 1, _ids(4, 2));
    }

    // =========================================================================
    // M-08: an entry id is committed once per contest
    // =========================================================================

    function test_commitBatch_refusesDuplicateWithinBatch() public {
        _openContest(CONTEST, 50, 50);
        bytes32[] memory ids = _ids(3, 1);
        ids[2] = ids[0];
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SpinAssignment.DuplicateEntry.selector, ids[0]));
        spin.commitBatch(CONTEST, DIRECT, 0, ids);
    }

    function test_commitBatch_refusesDuplicateAcrossBatchesAndSegments() public {
        _openContest(CONTEST, 50, 50);
        bytes32[] memory ids = _ids(3, 1);
        vm.prank(operator);
        spin.commitBatch(CONTEST, DIRECT, 0, ids);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SpinAssignment.DuplicateEntry.selector, ids[0]));
        spin.commitBatch(CONTEST, PROMO, 0, ids);
    }

    function test_commitBatch_refusesZeroEntryId() public {
        _openContest(CONTEST, 50, 50);
        bytes32[] memory ids = new bytes32[](1);
        vm.prank(operator);
        vm.expectRevert(SpinAssignment.ZeroEntryId.selector);
        spin.commitBatch(CONTEST, DIRECT, 0, ids);
    }

    // =========================================================================
    // A lost seed cannot block the queue, and voiding discards no outcome
    // =========================================================================

    function test_void_onlyAfterDelay_thenUnblocksNextBatch() public {
        _openContest(CONTEST, 20, 20);
        vm.prank(operator);
        (bytes32 stuck, uint256 stuckRid) = spin.commitBatch(CONTEST, DIRECT, 0, _ids(5, 1));
        (bytes32 next, bytes32[] memory nextIds) = _commitAndSeed(DIRECT, 1, 5);

        uint64 allowedAt = uint64(block.timestamp) + spin.VOID_DELAY();
        vm.expectRevert(abi.encodeWithSelector(SpinAssignment.VoidTooEarly.selector, allowedAt));
        spin.voidBatch(stuck);

        vm.warp(allowedAt);
        vm.prank(stranger); // permissionless
        spin.voidBatch(stuck);

        assertTrue(spin.batchVoided(stuck));
        assertEq(spin.reserved(CONTEST, DIRECT), 5, "the voided batch's slots are released");
        spin.finalize(next, nextIds, 128);
        assertTrue(spin.isBatchFinalized(next));

        // A seed that turns up late is ignored, not applied, and does not revert.
        _fulfill(stuckRid, 7);
        assertFalse(spin.getBatch(stuck).seeded);
        vm.expectRevert(SpinAssignment.BatchVoidedError.selector);
        spin.finalize(stuck, _ids(5, 1), 128);
    }

    function test_void_refusesSeededBatch() public {
        _openContest(CONTEST, 20, 20);
        (bytes32 b0,) = _commitAndSeed(DIRECT, 0, 5);
        vm.warp(block.timestamp + spin.VOID_DELAY());
        vm.expectRevert();
        spin.voidBatch(b0);
    }

    function test_void_onlyTheHeadOfTheQueue() public {
        _openContest(CONTEST, 20, 20);
        vm.startPrank(operator);
        spin.commitBatch(CONTEST, DIRECT, 0, _ids(5, 1));
        (bytes32 b1,) = spin.commitBatch(CONTEST, DIRECT, 1, _ids(5, 2));
        vm.stopPrank();

        vm.warp(block.timestamp + spin.VOID_DELAY());
        vm.expectRevert(abi.encodeWithSelector(SpinAssignment.OutOfOrder.selector, uint64(0)));
        spin.voidBatch(b1);
    }

    // =========================================================================
    // M-07/M-08: a seeded contest cannot be abandoned to re-roll its deck
    // =========================================================================

    function test_abandon_seededOnlyAfterDelay() public {
        uint256 rid = _stage1(CONTEST);
        _fulfill(rid, 5);

        uint64 allowedAt = uint64(block.timestamp) + spin.ABANDON_DELAY();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SpinAssignment.AbandonTooEarly.selector, allowedAt));
        spin.abandonContest(CONTEST, "re-roll attempt");

        vm.warp(allowedAt);
        vm.prank(admin);
        spin.abandonContest(CONTEST, "build failed");
        assertEq(uint8(spin.getContest(CONTEST).status), uint8(SpinAssignment.ContestStatus.ABANDONED));
    }

    function test_abandon_beforeSeedIsImmediate() public {
        _stage1(CONTEST);
        vm.prank(admin);
        spin.abandonContest(CONTEST, "never seeded");
        assertEq(uint8(spin.getContest(CONTEST).status), uint8(SpinAssignment.ContestStatus.ABANDONED));
    }

    // ---------------------------------------------------------------- helpers

    function _cfg() internal view returns (SpinAssignment.VrfConfig memory) {
        return SpinAssignment.VrfConfig({
            keyHash: KEY_HASH, subId: subId, callbackGasLimit: 500_000, requestConfirmations: 3, nativePayment: false
        });
    }

    function _ids(uint32 n, uint256 nonce) internal pure returns (bytes32[] memory) {
        return _entryIds(n, nonce);
    }

    function _commitAndSeed(uint8 segment, uint64 sequence, uint32 n)
        internal
        returns (bytes32 batchId, bytes32[] memory ids)
    {
        ids = _entryIds(n, (uint256(segment) << 64) | sequence | (1 << 128));
        vm.prank(operator);
        uint256 rid;
        (batchId, rid) = spin.commitBatch(CONTEST, segment, sequence, ids);
        _fulfill(rid, uint256(keccak256(abi.encode("v3-seed", segment, sequence))));
    }
}
