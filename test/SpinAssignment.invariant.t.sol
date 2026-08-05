// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpinAssignment} from "../src/SpinAssignment.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Drives the contract through randomized call sequences: arbitrary batch sizes,
///      arbitrary segments, out-of-order VRF fulfillment, partial finalization, and
///      finalization by arbitrary callers.
///
///      This handler is the point of choosing Foundry. The safety property of the draw is
///      not a property of any single call, it is a property of every possible interleaving
///      of calls, which is exactly what example-based tests cannot reach.
contract SpinHandler is Test {
    SpinAssignment public spin;
    VRFCoordinatorV2_5Mock public coordinator;

    address public operator;
    bytes32 public constant CONTEST = keccak256("invariant-contest");
    bytes32 public constant SALT = keccak256("invariant-salt");

    uint32 public constant DIRECT_SIZE = 400;
    uint32 public constant PROMO_SIZE = 200;

    bytes32[] public batchIds;
    mapping(bytes32 batchId => bytes32[]) public entriesOf;
    mapping(bytes32 batchId => uint256 requestId) public requestOf;
    mapping(bytes32 batchId => bool) public seeded;

    // Mirror of every deck index handed out, per segment, for duplicate detection.
    mapping(uint8 segment => mapping(uint32 deckIndex => uint256 count)) public timesAssigned;
    mapping(uint8 segment => uint256) public totalAssigned;

    uint256 public duplicateAssignments;
    uint256 public outOfRangeAssignments;

    constructor(SpinAssignment _spin, VRFCoordinatorV2_5Mock _coordinator, address _operator) {
        spin = _spin;
        coordinator = _coordinator;
        operator = _operator;
    }

    // ------------------------------------------------------------------ actions

    /// @notice Commit a batch of a fuzzed size on a fuzzed segment.
    function commitBatch(uint256 sizeSeed, uint256 segmentSeed) external {
        uint8 segment = uint8(segmentSeed % 2);
        SpinAssignment.Segment memory seg = spin.getSegment(CONTEST, segment);
        if (seg.remaining == 0) return;

        uint32 size = uint32(bound(sizeSeed, 1, 40));
        if (size > seg.remaining) size = seg.remaining;

        uint64 sequence = spin.nextBatchSequence(CONTEST, segment);
        bytes32[] memory ids = new bytes32[](size);
        for (uint32 i = 0; i < size; ++i) {
            ids[i] = keccak256(abi.encode(segment, sequence, i, block.number));
        }

        vm.prank(operator);
        (bytes32 batchId,) = spin.commitBatch(CONTEST, segment, sequence, ids);

        batchIds.push(batchId);
        entriesOf[batchId] = ids;
        requestOf[batchId] = spin.getBatch(batchId).requestId;
    }

    /// @notice Fulfill some pending batch, chosen by the fuzzer. Deliberately allows
    ///         fulfillment out of commit order, which is what really happens on chain.
    function fulfill(uint256 pick, uint256 word) external {
        if (batchIds.length == 0) return;
        bytes32 batchId = batchIds[pick % batchIds.length];
        if (seeded[batchId]) return;

        uint256[] memory words = new uint256[](1);
        words[0] = word;
        coordinator.fulfillRandomWordsWithOverride(requestOf[batchId], address(spin), words);
        seeded[batchId] = true;
    }

    /// @notice Finalize part of some seeded batch, as an arbitrary caller.
    function finalize(uint256 pick, uint256 chunkSeed, uint256 callerSeed) external {
        if (batchIds.length == 0) return;
        bytes32 batchId = batchIds[pick % batchIds.length];

        SpinAssignment.Batch memory b = spin.getBatch(batchId);
        if (!b.seeded || b.cursor >= b.size) return;

        uint32 chunk = uint32(bound(chunkSeed, 1, 128));
        uint32 start = b.cursor;

        // Anyone at all may call this. That is the censorship-resistance property.
        vm.prank(address(uint160(uint256(keccak256(abi.encode(callerSeed))))));
        spin.finalize(batchId, entriesOf[batchId], chunk);

        uint32 end = spin.getBatch(batchId).cursor;
        for (uint32 i = start; i < end; ++i) {
            (bool assigned, uint32 deckIndex) = spin.getAssignment(batchId, i);
            if (!assigned) continue;

            uint32 segSize = b.segment == 0 ? DIRECT_SIZE : PROMO_SIZE;
            if (deckIndex >= segSize) outOfRangeAssignments++;

            timesAssigned[b.segment][deckIndex] += 1;
            if (timesAssigned[b.segment][deckIndex] > 1) duplicateAssignments++;
            totalAssigned[b.segment] += 1;
        }
    }

    /// @notice Admin pausing mid-flight must never affect outcomes.
    function togglePause(uint256 seed) external {
        vm.prank(spin.owner());
        spin.setPaused(seed % 2 == 0);
    }

    function batchCount() external view returns (uint256) {
        return batchIds.length;
    }
}

contract SpinAssignmentInvariantTest is StdInvariant, Test {
    SpinAssignment internal spin;
    VRFCoordinatorV2_5Mock internal coordinator;
    SpinHandler internal handler;

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");

    function setUp() public {
        coordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 4e15);
        uint256 subId = coordinator.createSubscription();
        coordinator.fundSubscription(subId, 100_000 ether);

        vm.prank(admin);
        spin = new SpinAssignment(
            address(coordinator),
            operator,
            SpinAssignment.VrfConfig({
                keyHash: keccak256("lane"),
                subId: subId,
                callbackGasLimit: 500_000,
                requestConfirmations: 3,
                nativePayment: false
            })
        );
        coordinator.addConsumer(subId, address(spin));

        // Take one contest all the way to COMMITTED so the handler can churn on it.
        vm.prank(operator);
        uint256 rid = spin.commitStage1(
            handler_CONTEST(),
            keccak256("snapshot"),
            keccak256("scoring"),
            keccak256("builder"),
            keccak256(abi.encodePacked(keccak256("invariant-salt")))
        );
        uint256[] memory words = new uint256[](1);
        words[0] = uint256(keccak256("build"));
        coordinator.fulfillRandomWordsWithOverride(rid, address(spin), words);

        vm.prank(operator);
        spin.commitStage2(
            handler_CONTEST(),
            keccak256("rules"),
            keccak256("directRoot"),
            400,
            keccak256("promoRoot"),
            200,
            uint64(block.timestamp + 3650 days)
        );

        handler = new SpinHandler(spin, coordinator, operator);
        targetContract(address(handler));
    }

    function handler_CONTEST() internal pure returns (bytes32) {
        return keccak256("invariant-contest");
    }

    // =========================================================================
    // The headline invariant
    // =========================================================================

    /// @notice No deck index is ever assigned twice within a segment.
    /// @dev If this ever fails, two users hold the same lineup, which breaks the single
    ///      promise the whole architecture exists to make.
    function invariant_noDeckIndexAssignedTwice() public view {
        assertEq(handler.duplicateAssignments(), 0, "a deck index was assigned more than once");
    }

    /// @notice Every assigned index falls inside its segment.
    function invariant_assignmentsStayInsideSegment() public view {
        assertEq(handler.outOfRangeAssignments(), 0, "assignment escaped its segment bounds");
    }

    /// @notice `remaining` always equals size minus the number handed out, per segment.
    /// @dev Catches any drift between the sparse Fisher-Yates bookkeeping and reality.
    function invariant_remainingMatchesAssignedCount() public view {
        SpinAssignment.Segment memory d = spin.getSegment(handler_CONTEST(), 0);
        SpinAssignment.Segment memory p = spin.getSegment(handler_CONTEST(), 1);

        assertEq(uint256(d.size) - uint256(d.remaining), handler.totalAssigned(0), "direct segment accounting drifted");
        assertEq(uint256(p.size) - uint256(p.remaining), handler.totalAssigned(1), "promo segment accounting drifted");
    }

    /// @notice A segment can never oversell itself.
    function invariant_segmentNeverOversold() public view {
        assertLe(handler.totalAssigned(0), 400, "direct segment oversold");
        assertLe(handler.totalAssigned(1), 200, "promo segment oversold");
    }

    /// @notice A batch cursor never exceeds its committed size.
    function invariant_cursorNeverExceedsSize() public view {
        uint256 n = handler.batchCount();
        for (uint256 i = 0; i < n; ++i) {
            SpinAssignment.Batch memory b = spin.getBatch(handler.batchIds(i));
            assertLe(b.cursor, b.size, "cursor overran the batch");
        }
    }

    /// @notice The build seed stays hidden while the contest is unrevealed, no matter what
    ///         sequence of calls the fuzzer found.
    function invariant_effectiveSeedHiddenBeforeReveal() public view {
        assertEq(spin.effectiveBuildSeed(handler_CONTEST()), bytes32(0), "effective build seed leaked pre-reveal");
    }
}
