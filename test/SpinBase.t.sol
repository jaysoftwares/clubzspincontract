// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpinAssignment} from "../src/SpinAssignment.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Shared fixture. Wires a real Chainlink VRF 2.5 mock coordinator so the tests
///      exercise the actual consumer path, including the callback, rather than a stub.
abstract contract SpinBase is Test {
    SpinAssignment internal spin;
    VRFCoordinatorV2_5Mock internal coordinator;

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal stranger = makeAddr("stranger");

    uint256 internal subId;
    bytes32 internal constant KEY_HASH = keccak256("base-gas-lane");

    bytes32 internal constant CONTEST = keccak256("contest-1");
    bytes32 internal constant SALT = keccak256("a-very-secret-salt");

    uint8 internal constant DIRECT = 0;
    uint8 internal constant PROMO = 1;

    function setUp() public virtual {
        coordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 4e15);
        subId = coordinator.createSubscription();
        coordinator.fundSubscription(subId, 1000 ether);

        vm.prank(admin);
        spin = new SpinAssignment(
            address(coordinator),
            operator,
            SpinAssignment.VrfConfig({
                keyHash: KEY_HASH,
                subId: subId,
                callbackGasLimit: 500_000,
                requestConfirmations: 3,
                nativePayment: false
            })
        );

        coordinator.addConsumer(subId, address(spin));
    }

    // ---------------------------------------------------------------- helpers

    function _stage1(bytes32 contestId) internal returns (uint256 requestId) {
        vm.prank(operator);
        requestId = spin.commitStage1(
            contestId,
            keccak256("snapshot"),
            keccak256("scoring"),
            keccak256("builder"),
            keccak256(abi.encodePacked(SALT))
        );
    }

    function _fulfill(uint256 requestId, uint256 word) internal {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        coordinator.fulfillRandomWordsWithOverride(requestId, address(spin), words);
    }

    function _stage2(bytes32 contestId, uint32 directSize, uint32 promoSize, uint64 lockAt) internal {
        vm.prank(operator);
        spin.commitStage2(
            contestId,
            keccak256("rules"),
            keccak256("directRoot"),
            directSize,
            keccak256("promoRoot"),
            promoSize,
            lockAt
        );
    }

    /// @dev Contest taken all the way to COMMITTED and ready to accept batches.
    function _openContest(bytes32 contestId, uint32 directSize, uint32 promoSize) internal {
        uint256 rid = _stage1(contestId);
        _fulfill(rid, uint256(keccak256("build-seed")));
        _stage2(contestId, directSize, promoSize, uint64(block.timestamp + 1 days));
    }

    function _entryIds(uint32 n, uint256 nonce) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](n);
        for (uint32 i = 0; i < n; ++i) {
            ids[i] = keccak256(abi.encode("entry", nonce, i));
        }
    }
}
