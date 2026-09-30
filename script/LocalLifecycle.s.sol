// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpinAssignment} from "../src/SpinAssignment.sol";
import {SpinRegistry} from "../src/SpinRegistry.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Full contest lifecycle against a local chain with a mock VRF coordinator.
///
/// @dev This is the reference transaction sequence for the Spin worker. Every call the
///      worker will make in production appears here in order, so it doubles as an
///      integration smoke test and as executable documentation of the flow.
///
/// Usage:
///   anvil                                  # in one terminal
///   forge script script/LocalLifecycle.s.sol:LocalLifecycle --rpc-url http://127.0.0.1:8545 --broadcast
///
/// Or with no node at all, since a script run has its own EVM:
///   forge script script/LocalLifecycle.s.sol:LocalLifecycle
///
/// The owner (the default sender) and the operator are DIFFERENT accounts, because the
/// contract refuses to let one key hold both roles (WebThree H-07). The operator
/// defaults to anvil's second well-known dev key; override with SPIN_LOCAL_OPERATOR_PK.
contract LocalLifecycle is Script {
    bytes32 constant CONTEST = keccak256("local-contest-1");
    bytes32 constant SALT = keccak256("local-salt-keep-this-secret");

    uint32 constant DIRECT_SIZE = 200;
    uint32 constant PROMO_SIZE = 50;
    uint32 constant BATCH_SIZE = 12;

    /// @dev anvil's account #1. A public development key; never fund it on a real chain.
    uint256 constant ANVIL_KEY_1 = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;

    function run() external {
        uint256 operatorPk = vm.envOr("SPIN_LOCAL_OPERATOR_PK", ANVIL_KEY_1);
        address operator = vm.addr(operatorPk);

        // ------------------------------------------------ deploy, as the owner
        vm.startBroadcast();

        // ---------------------------------------------------------- deploy
        VRFCoordinatorV2_5Mock coordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 4e15);
        uint256 subId = coordinator.createSubscription();
        coordinator.fundSubscription(subId, 1000 ether);

        // The registry first: the assignment contract only commits contests the
        // registry binds to it. The operator is the registry's binder.
        SpinRegistry registry = new SpinRegistry(msg.sender, operator);

        SpinAssignment spin = new SpinAssignment(
            address(coordinator),
            operator,
            address(registry),
            SpinAssignment.VrfConfig({
                keyHash: keccak256("local-lane"),
                subId: subId,
                callbackGasLimit: 500_000,
                requestConfirmations: 3,
                nativePayment: false
            })
        );
        coordinator.addConsumer(subId, address(spin));

        registry.setApproved(address(spin), true);
        registry.setDefaultImplementation(address(spin));
        vm.stopBroadcast();

        // ------------------------------------------- everything else, as the operator
        vm.startBroadcast(operatorPk);
        registry.bind(CONTEST);

        console2.log("coordinator :", address(coordinator));
        console2.log("assignment  :", address(spin));
        console2.log("registry    :", address(registry));

        // ------------------------------------------- stage 1 + build seed
        // The salt is generated off-chain from a CSPRNG and held until after lock.
        uint256 buildRequest = spin.commitStage1(
            CONTEST,
            keccak256("snapshot-canonical-json"),
            keccak256("scoring-ruleset-v1"),
            keccak256("builder-source-digest"),
            keccak256(abi.encodePacked(SALT))
        );
        console2.log("stage1 committed, build seed request:", buildRequest);

        _fulfill(coordinator, spin, buildRequest, uint256(keccak256("chainlink-build-word")));
        console2.log("build seed fulfilled");

        // ------------------------------------------------------- stage 2
        // Off-chain between these two calls: calibrate the band using
        // keccak256(effectiveBuildSeed, "CALIBRATION"), build the master deck, split it
        // with keccak256(effectiveBuildSeed, "SPLIT"), and build both Merkle trees.
        spin.commitStage2(
            CONTEST,
            keccak256("rules-with-calibrated-band"),
            keccak256("direct-merkle-root"),
            DIRECT_SIZE,
            keccak256("promo-merkle-root"),
            PROMO_SIZE,
            uint64(block.timestamp + 2 hours)
        );
        console2.log("stage2 committed, contest open");

        // -------------------------------------------------- a batch of entries
        bytes32[] memory entries = new bytes32[](BATCH_SIZE);
        for (uint32 i = 0; i < BATCH_SIZE; ++i) {
            entries[i] = keccak256(abi.encode("entry-uuid", i));
        }

        (bytes32 batchId, uint256 batchRequest) = spin.commitBatch(CONTEST, 0, 0, entries);
        console2.log("batch committed, seed request:", batchRequest);

        _fulfill(coordinator, spin, batchRequest, uint256(keccak256("chainlink-batch-word")));

        // Chunked deliberately, to exercise the resumable path the worker relies on.
        spin.finalize(batchId, entries, 5);
        spin.finalize(batchId, entries, 5);
        spin.finalize(batchId, entries, 5);

        require(spin.isBatchFinalized(batchId), "batch did not finalize");
        console2.log("batch finalized, assignments:");
        for (uint32 i = 0; i < BATCH_SIZE; ++i) {
            (, uint32 deckIndex) = spin.getAssignment(batchId, i);
            console2.log("   position", i, "-> deck index", deckIndex);
        }

        // ------------------------------------------------- lock, reveal, settle
        require(spin.effectiveBuildSeed(CONTEST) == bytes32(0), "seed leaked before reveal");

        vm.warp(block.timestamp + 3 hours);
        spin.revealSalt(CONTEST, SALT);
        spin.markSettled(CONTEST);

        console2.log("contest settled");
        console2.log("effective build seed now public, deck is reproducible off-chain");
        console2.logBytes32(spin.effectiveBuildSeed(CONTEST));

        vm.stopBroadcast();
    }

    function _fulfill(VRFCoordinatorV2_5Mock coordinator, SpinAssignment spin, uint256 requestId, uint256 word)
        private
    {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        coordinator.fulfillRandomWordsWithOverride(requestId, address(spin), words);
    }
}
