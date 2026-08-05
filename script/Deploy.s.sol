// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpinAssignment} from "../src/SpinAssignment.sol";
import {SpinRegistry} from "../src/SpinRegistry.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Deploys the Clubz Spin on-chain surface.
///
/// @dev Ownership handover is intentionally NOT automatic. The deployer keeps ownership
///      of the registry until a human transfers it to the Safe and the Safe accepts,
///      because a two-step handover to a wrong address is recoverable and a one-step one
///      is not. `SpinAssignment` is immutable, so a bad deploy is thrown away, not fixed.
///
/// Usage:
///   forge script script/Deploy.s.sol:Deploy --rpc-url base_sepolia --broadcast --verify
contract Deploy is Script {
    function run() external {
        address vrfCoordinator = vm.envAddress("VRF_COORDINATOR");
        address operator = vm.envAddress("SPIN_OPERATOR");
        bytes32 keyHash = vm.envBytes32("VRF_KEY_HASH");
        uint256 subId = vm.envUint("VRF_SUBSCRIPTION_ID");
        uint32 callbackGasLimit = uint32(vm.envUint("VRF_CALLBACK_GAS_LIMIT"));
        uint16 confirmations = uint16(vm.envUint("VRF_REQUEST_CONFIRMATIONS"));
        bool nativePayment = vm.envBool("VRF_NATIVE_PAYMENT");

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

        SpinRegistry registry = new SpinRegistry(msg.sender, operator);
        registry.setApproved(address(assignment), true);
        registry.setDefaultImplementation(address(assignment));

        vm.stopBroadcast();

        console2.log("SpinAssignment :", address(assignment));
        console2.log("SpinRegistry   :", address(registry));
        console2.log("operator       :", operator);
        console2.log("");
        console2.log("REMAINING MANUAL STEPS, in order:");
        console2.log("  1. Add SpinAssignment as a consumer on VRF subscription", subId);
        console2.log("  2. Fund the subscription, and wire balance alerting before going live");
        console2.log("  3. registry.transferOwnership(<safe>)   then the Safe calls acceptOwnership()");
        console2.log("  4. assignment.transferOwnership(<safe>) then the Safe calls acceptOwnership()");
    }
}
