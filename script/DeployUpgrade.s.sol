// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpinAssignment} from "../src/SpinAssignment.sol";
import {SpinRegistry} from "../src/SpinRegistry.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Deploy a new SpinAssignment and register it in the EXISTING registry.
///
/// @dev This is the upgrade path the architecture was designed around, exercised
///      for real. `SpinAssignment` is immutable, so a fix means a new deployment;
///      `SpinRegistry` is the indirection that makes that survivable. The old
///      implementation stays approved and keeps governing any contest already
///      bound to it, while new contests bind to the new default.
///
///      Nothing is bound yet, so this particular rollover costs nothing.
///
/// Usage:
///   forge script script/DeployUpgrade.s.sol:DeployUpgrade \
///     --rpc-url base --private-key $PK --broadcast
contract DeployUpgrade is Script {
    function run() external {
        address registryAddr = vm.envAddress("SPIN_REGISTRY_ADDRESS");
        address vrfCoordinator = vm.envAddress("VRF_COORDINATOR");
        address operator = vm.envAddress("SPIN_OPERATOR");
        bytes32 keyHash = vm.envBytes32("VRF_KEY_HASH");
        uint256 subId = vm.envUint("VRF_SUBSCRIPTION_ID");
        uint32 callbackGasLimit = uint32(vm.envUint("VRF_CALLBACK_GAS_LIMIT"));
        uint16 confirmations = uint16(vm.envUint("VRF_REQUEST_CONFIRMATIONS"));
        bool nativePayment = vm.envBool("VRF_NATIVE_PAYMENT");

        SpinRegistry registry = SpinRegistry(registryAddr);
        address previous = registry.defaultImplementation();

        vm.startBroadcast();

        SpinAssignment assignment = new SpinAssignment(
            vrfCoordinator,
            operator,
            SpinAssignment.VrfConfig({
                keyHash: keyHash,
                subId: subId,
                callbackGasLimit: callbackGasLimit,
                requestConfirmations: confirmations,
                nativePayment: nativePayment
            })
        );

        // Approve, then make default. The registry refuses a default that is not
        // already approved, so the order matters.
        registry.setApproved(address(assignment), true);
        registry.setDefaultImplementation(address(assignment));

        vm.stopBroadcast();

        console2.log("previous implementation :", previous);
        console2.log("NEW SpinAssignment      :", address(assignment));
        console2.log("registry                :", registryAddr);
        console2.log("");
        console2.log("Update SPIN_ASSIGNMENT_ADDRESS on the worker AND clubzapi.");
        console2.log("Add the NEW address as a VRF consumer; the old one can be removed.");
    }
}
