// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpinAssignment} from "../src/SpinAssignment.sol";
import {SpinRegistry} from "../src/SpinRegistry.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Move the SPINZ admin roles to another wallet.
///
/// @dev OWNER AND OPERATOR ARE DIFFERENT JOBS, and confusing them is the way to break
///      this vertical. Read this before running anything.
///
///      **operator** signs `commitStage1`, `commitBatch`, `finalize` and `revealSalt`.
///      It is the wallet that PAYS GAS, on every batch, forever. Whoever holds this role
///      must have its private key in the backend's `SPIN_OPERATOR_PRIVATE_KEY`, or the
///      worker cannot sign and every spin stops resolving.
///
///      **owner** signs `setOperator`, `setVrfConfig`, `setPaused` and `abandonContest`.
///      These are rare admin actions. The owner pays gas only when it performs one, which
///      is close to never. Moving ownership does NOT move where routine gas comes from.
///
///      So: to change which wallet funds day-to-day gas, change the OPERATOR and give the
///      backend that key. Changing the owner alone accomplishes nothing on that front.
///
///      Ownership uses Chainlink `ConfirmedOwner`, which is a TWO-STEP handover: this
///      proposes, and the new owner must call `acceptOwnership()` itself. Nothing changes
///      until it does, which is what makes a wrong address recoverable. `setOperator` is
///      immediate and single-step, so it is the dangerous one.
///
///      NO RESIDUAL PRIVILEGE (WebThree M-08). Rotating the operator used to change it on
///      the live SpinAssignment only, so the old hot key stayed operator of the
///      superseded v1 and stayed the registry's binder, and v1 stayed approved. A key
///      being retired must lose every role it held, in one run:
///
///      - the registry's binder moves with the operator;
///      - every superseded SpinAssignment listed in SPIN_SUPERSEDED_ASSIGNMENTS is paused,
///        its operator moved too, and its registry approval withdrawn.
///
///      And the two roles stay on two keys (WebThree H-07): the script refuses to make
///      the owner the operator or the other way round.
///
/// Usage (nothing broadcasts without --broadcast):
///   SPIN_NEW_OWNER=0x...    forge script script/TransferRoles.s.sol:TransferRoles --rpc-url base
///   SPIN_NEW_OPERATOR=0x... forge script script/TransferRoles.s.sol:TransferRoles --rpc-url base
///   SPIN_SUPERSEDED_ASSIGNMENTS=0x6Bb0d32dCa4F58cb89191dDEc4b47481C028f753   (comma-separated)
contract TransferRoles is Script {
    error NotOwner(address owner, address caller);
    error NewOperatorHasNoBalance(address operator);
    error OwnerAndOperatorMustDiffer(address key);
    error SupersededIsLive(address implementation);

    function run() external {
        address assignmentAddr = vm.envAddress("SPIN_ASSIGNMENT_ADDRESS");
        address registryAddr = vm.envAddress("SPIN_REGISTRY_ADDRESS");
        address newOwner = vm.envOr("SPIN_NEW_OWNER", address(0));
        address newOperator = vm.envOr("SPIN_NEW_OPERATOR", address(0));
        address[] memory superseded = vm.envOr("SPIN_SUPERSEDED_ASSIGNMENTS", ",", new address[](0));

        SpinAssignment assignment = SpinAssignment(assignmentAddr);
        SpinRegistry registry = SpinRegistry(registryAddr);

        address currentOwner = assignment.owner();
        address currentOperator = assignment.operator();

        console2.log("SpinAssignment   :", assignmentAddr);
        console2.log("  current owner  :", currentOwner);
        console2.log("  current operator:", currentOperator);
        console2.log("  operator balance (wei):", currentOperator.balance);
        console2.log("SpinRegistry owner:", registry.owner());
        console2.log("");

        if (newOwner == address(0) && newOperator == address(0) && superseded.length == 0) {
            console2.log("Nothing to do. Set SPIN_NEW_OWNER, SPIN_NEW_OPERATOR and/or");
            console2.log("SPIN_SUPERSEDED_ASSIGNMENTS.");
            return;
        }

        if (msg.sender != currentOwner) revert NotOwner(currentOwner, msg.sender);

        address finalOwner = newOwner != address(0) ? newOwner : currentOwner;
        address finalOperator = newOperator != address(0) ? newOperator : currentOperator;
        if (finalOwner == finalOperator) revert OwnerAndOperatorMustDiffer(finalOwner);
        for (uint256 i = 0; i < superseded.length; ++i) {
            if (superseded[i] == assignmentAddr || superseded[i] == registry.defaultImplementation()) {
                revert SupersededIsLive(superseded[i]);
            }
        }

        vm.startBroadcast();

        if (newOperator != address(0) && newOperator != currentOperator) {
            /// A drained operator cannot sign anything, so pointing the contract at one
            /// stops every spin resolving the moment it takes effect. `setOperator` is
            /// immediate and single-step, so there is no window to notice and undo.
            if (newOperator.balance == 0) revert NewOperatorHasNoBalance(newOperator);

            assignment.setOperator(newOperator);
            console2.log("OPERATOR SET to:", newOperator);

            // The binder is the worker's key too; the old one must not keep it.
            if (registry.binder() != newOperator) {
                registry.setBinder(newOperator);
                console2.log("REGISTRY BINDER SET to:", newOperator);
            }
            console2.log("  ^ the backend's SPIN_OPERATOR_PRIVATE_KEY MUST now be this");
            console2.log("    wallet's key, or the worker cannot sign and spins stall.");
        }

        // Superseded implementations: stop intake, move the hot key off them, and stop
        // the registry binding anything new to them. Contests already bound keep
        // settling there, because finalize and revealSalt are permissionless and pause
        // never blocks work finishing.
        for (uint256 i = 0; i < superseded.length; ++i) {
            SpinAssignment old = SpinAssignment(superseded[i]);
            if (!old.paused()) old.setPaused(true);
            if (newOperator != address(0) && old.operator() != newOperator) old.setOperator(newOperator);
            if (registry.approved(superseded[i])) registry.setApproved(superseded[i], false);
            console2.log("RETIRED superseded implementation:", superseded[i]);
            console2.log("  paused, operator:", old.operator(), " approved:", registry.approved(superseded[i]));
        }

        if (newOwner != address(0) && newOwner != currentOwner) {
            assignment.transferOwnership(newOwner);
            registry.transferOwnership(newOwner);
            for (uint256 i = 0; i < superseded.length; ++i) {
                SpinAssignment(superseded[i]).transferOwnership(newOwner);
            }
            console2.log("OWNERSHIP PROPOSED to:", newOwner);
            console2.log("  ^ nothing has changed yet. The new owner must call");
            console2.log("    acceptOwnership() on BOTH contracts:");
            console2.log("      to:", assignmentAddr);
            console2.log("      to:", registryAddr);
            console2.log("      data: 0x79ba5097   // acceptOwnership()");
        }

        vm.stopBroadcast();
    }
}
