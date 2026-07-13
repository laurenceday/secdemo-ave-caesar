// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    ISealedEntityCredentialRegistry,
    IDisclosureTrigger
} from "./ISealedEntityCredential.sol";

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title  SpokeAllocator
/// @notice The consumer half of the V4 demo: a minimal depositor-facing
///         allocator that routes idle liquidity toward registered spokes and
///         consumes the spoke-operator credential as its admissibility rail.
///
///         THE LINE THAT MATTERS: on latch (or the moment the predicate is
///         provable — gates read projections), this contract freezes growth
///         of NEW exposure only. `allocate` and `approveCreditIncrease`
///         refuse the latched spoke; existing positions are untouched —
///         there is deliberately NO function that claws back an allocation,
///         and depositor `withdraw` of idle liquidity keeps working. The
///         credential registry never confiscates; consumers choose
///         consequences, and this consumer's chosen consequence is
///         remove-new-exposure-only.
///
/// @dev    Demo-grade: balances are 1:1, no yield accounting, allocations
///         transfer tokens to the spoke address and are recalled by the
///         spoke pushing tokens back. Production shape would be an ERC-4626
///         wrapper; the credential-consumption surface would be identical.
contract SpokeAllocator {
    bytes32 public constant REQUIRED_TRIGGER_CLASS = keccak256("AAVE_V4_SPOKE_GROSS_DEFICIT_V1");

    ISealedEntityCredentialRegistry public immutable registry;
    IERC20Like public immutable asset;
    address public immutable manager;

    struct SpokeRecord {
        bytes32 credentialId;
        address trigger;   // the bound AAVE_V4_SPOKE_GROSS_DEFICIT_V1 trigger
        uint256 exposure;  // allocated and not yet returned
    }

    mapping(address => SpokeRecord) public spokes;   // spoke => record
    mapping(address => uint256) public balanceOf;    // depositor => idle claim
    uint256 public idleLiquidity;

    event SpokeRegistered(address indexed spoke, bytes32 indexed credentialId, address trigger);
    event Deposited(address indexed depositor, uint256 amount);
    event Withdrawn(address indexed depositor, uint256 amount);
    event Allocated(address indexed spoke, uint256 amount);
    event Returned(address indexed spoke, uint256 amount);
    event CreditIncreaseApproved(address indexed spoke, uint256 newCap);

    error NotManager();
    error SpokeNotRegistered();
    error CredentialNotConsequenceBearing();
    error SpokeLatchedOrLatchable();
    error InsufficientIdle();
    error InsufficientBalance();

    constructor(address _registry, address _asset, address _manager) {
        registry = ISealedEntityCredentialRegistry(_registry);
        asset = IERC20Like(_asset);
        manager = _manager;
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert NotManager();
        _;
    }

    // ---------------------------------------------------------- registration

    /// @notice Register a spoke as an allocation target by pointing at its
    ///         operator's credential. The credential must bind a trigger of
    ///         the required class — that is this venue's pinned requirement.
    function registerSpoke(address spoke, bytes32 credentialId) external onlyManager {
        (bool bound, address trigger) =
            registry.boundTriggerOfClass(credentialId, REQUIRED_TRIGGER_CLASS);
        if (!bound) revert CredentialNotConsequenceBearing();
        spokes[spoke] = SpokeRecord({credentialId: credentialId, trigger: trigger, exposure: 0});
        emit SpokeRegistered(spoke, credentialId, trigger);
    }

    /// @notice True while the spoke's credential has neither latched nor
    ///         become latchable on either limb. Gates read projections: the
    ///         answer flips the block the predicate is provable, before
    ///         anyone has called `latch`.
    function spokeHealthy(address spoke) public view returns (bool) {
        SpokeRecord storage r = spokes[spoke];
        if (r.trigger == address(0)) return false;
        IDisclosureTrigger t = IDisclosureTrigger(r.trigger);
        return !t.isTriggered(r.credentialId) && !t.isTriggerable(r.credentialId);
    }

    // ------------------------------------------------------------ depositors

    function deposit(uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender] += amount;
        idleLiquidity += amount;
        emit Deposited(msg.sender, amount);
    }

    /// @notice Withdraw idle liquidity. Works regardless of any spoke's latch
    ///         state — the consequence of a latch is on NEW exposure, never
    ///         on depositors leaving.
    function withdraw(uint256 amount) external {
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        if (idleLiquidity < amount) revert InsufficientIdle();
        balanceOf[msg.sender] -= amount;
        idleLiquidity -= amount;
        asset.transfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ------------------------------------------------------------ allocation

    /// @notice Route idle liquidity to a registered spoke. Refused the moment
    ///         the spoke's credential is latched or latchable.
    function allocate(address spoke, uint256 amount) external onlyManager {
        SpokeRecord storage r = spokes[spoke];
        if (r.trigger == address(0)) revert SpokeNotRegistered();
        if (!spokeHealthy(spoke)) revert SpokeLatchedOrLatchable();
        if (idleLiquidity < amount) revert InsufficientIdle();

        idleLiquidity -= amount;
        r.exposure += amount;
        asset.transfer(spoke, amount);
        emit Allocated(spoke, amount);
    }

    /// @notice Signal approval of a hub credit-line increase proposal for the
    ///         spoke (offchain/governance consumption). Same gate as
    ///         `allocate`: a latched spoke gets no new credit endorsement.
    function approveCreditIncrease(address spoke, uint256 newCap)
        external
        onlyManager
        returns (bool)
    {
        SpokeRecord storage r = spokes[spoke];
        if (r.trigger == address(0)) revert SpokeNotRegistered();
        if (!spokeHealthy(spoke)) revert SpokeLatchedOrLatchable();
        emit CreditIncreaseApproved(spoke, newCap);
        return true;
    }

    /// @notice A spoke returning previously allocated liquidity. Always
    ///         accepted — latched spokes repaying is strictly good. Tokens
    ///         must be transferred to this contract before invocation.
    function onReturned(address spoke, uint256 amount) external onlyManager {
        SpokeRecord storage r = spokes[spoke];
        if (r.trigger == address(0)) revert SpokeNotRegistered();
        r.exposure = r.exposure > amount ? r.exposure - amount : 0;
        idleLiquidity += amount;
        emit Returned(spoke, amount);
    }
}
