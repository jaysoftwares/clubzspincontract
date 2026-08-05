// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title SpinRegistry
/// @notice Maps a contest to the immutable `SpinAssignment` deployment that governs it.
/// @dev This is the *only* mutable part of the Clubz Spin on-chain surface, and it is
///      deliberately tiny. `SpinAssignment` has no proxy and no upgrade path, so
///      versioning happens here: a new implementation is deployed, the Safe approves it,
///      and new contests bind to it. Contests already bound keep running on the exact
///      code that committed them, forever.
///
///      Separation of duties is the point of the two-role design:
///
///      - The **owner** (a Safe multisig) approves implementations. Rare and deliberate.
///      - The **binder** (the worker's hot key) binds a contest to an already-approved
///        implementation. Frequent and routine.
///
///      So a compromised hot key can bind contests to approved code only. It cannot
///      introduce an implementation, which would otherwise let an attacker point a contest
///      at a contract that fakes assignments.
contract SpinRegistry is Ownable2Step {
    /// @notice Implementations the Safe has approved for new contests.
    mapping(address implementation => bool) public approved;

    /// @notice Implementation new contests bind to when no explicit target is given.
    address public defaultImplementation;

    /// @notice Address permitted to bind contests. The Spin worker's key.
    address public binder;

    /// @notice contestId => the implementation that governs it. Write-once.
    mapping(bytes32 contestId => address) public implementationOf;

    event ImplementationApproved(address indexed implementation, bool approved);
    event DefaultImplementationSet(address indexed implementation);
    event BinderChanged(address indexed previousBinder, address indexed newBinder);
    event ContestBound(bytes32 indexed contestId, address indexed implementation);

    error ZeroAddress();
    error NotBinder();
    error NotApproved();
    error AlreadyBound(address existing);
    error NoDefaultImplementation();
    error StillDefault();

    modifier onlyBinder() {
        if (msg.sender != binder) revert NotBinder();
        _;
    }

    constructor(address owner_, address binder_) Ownable(owner_) {
        if (binder_ == address(0)) revert ZeroAddress();
        binder = binder_;
        emit BinderChanged(address(0), binder_);
    }

    // -------------------------------------------------------------------------
    // Owner (Safe)
    // -------------------------------------------------------------------------

    function setApproved(address implementation, bool value) external onlyOwner {
        if (implementation == address(0)) revert ZeroAddress();
        // Refuse to un-approve the live default; clear or move the default first, so a
        // single transaction can never leave the registry unable to bind anything.
        if (!value && implementation == defaultImplementation) revert StillDefault();
        approved[implementation] = value;
        emit ImplementationApproved(implementation, value);
    }

    function setDefaultImplementation(address implementation) external onlyOwner {
        if (implementation != address(0) && !approved[implementation]) revert NotApproved();
        defaultImplementation = implementation;
        emit DefaultImplementationSet(implementation);
    }

    function setBinder(address newBinder) external onlyOwner {
        if (newBinder == address(0)) revert ZeroAddress();
        emit BinderChanged(binder, newBinder);
        binder = newBinder;
    }

    // -------------------------------------------------------------------------
    // Binder (worker)
    // -------------------------------------------------------------------------

    /// @notice Bind a contest to the current default implementation.
    function bind(bytes32 contestId) external onlyBinder returns (address implementation) {
        implementation = defaultImplementation;
        if (implementation == address(0)) revert NoDefaultImplementation();
        _bind(contestId, implementation);
    }

    /// @notice Bind a contest to a specific approved implementation.
    /// @dev Used when a new version is rolling out and old and new contests coexist.
    function bindTo(bytes32 contestId, address implementation) external onlyBinder {
        if (!approved[implementation]) revert NotApproved();
        _bind(contestId, implementation);
    }

    /// @dev Write-once. A contest's governing code can never be swapped after binding,
    ///      including by the owner. Rebinding would let an entrant's assignment be
    ///      reinterpreted by different rules after the fact.
    function _bind(bytes32 contestId, address implementation) private {
        address existing = implementationOf[contestId];
        if (existing != address(0)) revert AlreadyBound(existing);
        implementationOf[contestId] = implementation;
        emit ContestBound(contestId, implementation);
    }
}
