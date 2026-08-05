// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpinRegistry} from "../src/SpinRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";

contract SpinRegistryTest is Test {
    SpinRegistry internal registry;

    address internal safe = makeAddr("safe");
    address internal binder = makeAddr("binder");
    address internal stranger = makeAddr("stranger");

    address internal implV1 = makeAddr("implV1");
    address internal implV2 = makeAddr("implV2");

    bytes32 internal constant CONTEST = keccak256("contest");

    function setUp() public {
        registry = new SpinRegistry(safe, binder);
        vm.startPrank(safe);
        registry.setApproved(implV1, true);
        registry.setDefaultImplementation(implV1);
        vm.stopPrank();
    }

    // =========================================================================
    // Separation of duties: the hot key can bind, never introduce
    // =========================================================================

    /// @dev The reason the two roles exist. A stolen binder key must not be able to point
    ///      a contest at attacker-controlled code that fakes assignments.
    function test_binder_cannotApproveImplementations() public {
        address evil = makeAddr("evil");

        vm.prank(binder);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, binder));
        registry.setApproved(evil, true);

        vm.prank(binder);
        vm.expectRevert(SpinRegistry.NotApproved.selector);
        registry.bindTo(CONTEST, evil);
    }

    function test_bind_usesDefaultImplementation() public {
        vm.prank(binder);
        address impl = registry.bind(CONTEST);

        assertEq(impl, implV1);
        assertEq(registry.implementationOf(CONTEST), implV1);
    }

    function test_bindTo_requiresApproval() public {
        vm.prank(binder);
        vm.expectRevert(SpinRegistry.NotApproved.selector);
        registry.bindTo(CONTEST, implV2);

        vm.prank(safe);
        registry.setApproved(implV2, true);

        vm.prank(binder);
        registry.bindTo(CONTEST, implV2);
        assertEq(registry.implementationOf(CONTEST), implV2);
    }

    function test_bind_onlyBinder() public {
        vm.prank(stranger);
        vm.expectRevert(SpinRegistry.NotBinder.selector);
        registry.bind(CONTEST);
    }

    // =========================================================================
    // Write-once binding
    // =========================================================================

    /// @dev A bound contest can never be re-pointed, including by the Safe. Rebinding
    ///      would let an entrant's existing assignment be reinterpreted under new rules.
    function test_bind_isWriteOnceEvenForOwner() public {
        vm.prank(binder);
        registry.bind(CONTEST);

        vm.prank(safe);
        registry.setApproved(implV2, true);

        vm.prank(binder);
        vm.expectRevert(abi.encodeWithSelector(SpinRegistry.AlreadyBound.selector, implV1));
        registry.bindTo(CONTEST, implV2);

        // No owner-only override exists either; the registry exposes no rebind path.
        assertEq(registry.implementationOf(CONTEST), implV1);
    }

    // =========================================================================
    // Version rollover
    // =========================================================================

    /// @dev The immutability story: old contests keep the code that committed them while
    ///      new contests move to v2.
    function test_versionRollover_leavesOldContestsOnOldCode() public {
        bytes32 oldContest = keccak256("old");
        bytes32 newContest = keccak256("new");

        vm.prank(binder);
        registry.bind(oldContest);

        vm.startPrank(safe);
        registry.setApproved(implV2, true);
        registry.setDefaultImplementation(implV2);
        vm.stopPrank();

        vm.prank(binder);
        registry.bind(newContest);

        assertEq(registry.implementationOf(oldContest), implV1, "old contest must not move");
        assertEq(registry.implementationOf(newContest), implV2);
    }

    // =========================================================================
    // Owner surface
    // =========================================================================

    function test_cannotUnapproveLiveDefault() public {
        vm.prank(safe);
        vm.expectRevert(SpinRegistry.StillDefault.selector);
        registry.setApproved(implV1, false);
    }

    function test_defaultMustBeApproved() public {
        vm.prank(safe);
        vm.expectRevert(SpinRegistry.NotApproved.selector);
        registry.setDefaultImplementation(implV2);
    }

    function test_bind_revertsWithoutDefault() public {
        vm.prank(safe);
        registry.setDefaultImplementation(address(0));

        vm.prank(binder);
        vm.expectRevert(SpinRegistry.NoDefaultImplementation.selector);
        registry.bind(CONTEST);
    }

    function test_setBinder_rotates() public {
        address newBinder = makeAddr("newBinder");

        vm.prank(safe);
        registry.setBinder(newBinder);

        vm.prank(binder);
        vm.expectRevert(SpinRegistry.NotBinder.selector);
        registry.bind(CONTEST);

        vm.prank(newBinder);
        registry.bind(CONTEST);
        assertEq(registry.implementationOf(CONTEST), implV1);
    }

    /// @dev Ownership handover is two-step, so a fat-fingered address cannot brick the
    ///      registry's only mutable control surface.
    function test_ownershipTransferIsTwoStep() public {
        address newSafe = makeAddr("newSafe");

        vm.prank(safe);
        registry.transferOwnership(newSafe);
        assertEq(registry.owner(), safe, "must not transfer until accepted");

        vm.prank(newSafe);
        registry.acceptOwnership();
        assertEq(registry.owner(), newSafe);
    }

    function test_rejectsZeroAddresses() public {
        vm.startPrank(safe);
        vm.expectRevert(SpinRegistry.ZeroAddress.selector);
        registry.setApproved(address(0), true);
        vm.expectRevert(SpinRegistry.ZeroAddress.selector);
        registry.setBinder(address(0));
        vm.stopPrank();
    }
}
