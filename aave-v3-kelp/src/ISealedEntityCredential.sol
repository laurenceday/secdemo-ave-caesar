// SPDX-License-Identifier: CC0-1.0
pragma solidity >=0.8.20;

/// @title  ISealedEntityCredentialRegistry + IDisclosureTrigger
/// @notice Consolidated interfaces for ERC-XXXX (Sealed Entity Credentials with
///         On-Chain Disclosure Triggers). Matches the draft specification §3.
interface IDisclosureTrigger {
    /// @notice Latches permanently once the predicate is true. Permissionless.
    function latch(bytes32 credentialId) external;

    /// @notice Latched state (recorded).
    function isTriggered(bytes32 credentialId) external view returns (bool);

    /// @notice Projected state: predicate provably true now, latch not yet set.
    ///         Gates read projections; windows run from latches.
    function isTriggerable(bytes32 credentialId) external view returns (bool);

    /// @notice 0 if never latched.
    function triggeredAt(bytes32 credentialId) external view returns (uint64);

    /// @notice Canonical predicate class, e.g. keccak256("WILDCAT_DELINQ_90D_V1").
    ///         Consumers pin classes (semantics), not addresses.
    function triggerClass() external view returns (bytes32);

    event DisclosureTriggered(bytes32 indexed credentialId, uint64 timestamp);
}

interface ISealedEntityCredentialRegistry {
    struct SealedTier {
        bytes32 root;            // Merkle root over salted field leaves (padded, canonical order)
        string ciphertextURI;    // off-chain encrypted blob; content-addressed RECOMMENDED
        bytes32 sealingSchemeId; // pluggable scheme identifier
    }

    struct CredentialView {
        bytes32 schemaProfile;   // e.g. keccak256("entity/v1")
        address attestor;
        uint64 issuedAt;
        uint64 expiresAt;        // stale credential blocks NEW obligations only
        bool revoked;            // attestor-flagged; MUST NOT itself be a disclosure trigger
        address[] triggers;      // bound IDisclosureTrigger set (may be empty)
        bytes32[] triggerClasses; // parallel: canonical class id per trigger
        SealedTier s1;
        SealedTier s2;
    }

    event CredentialRegistered(
        bytes32 indexed credentialId, address indexed attestor, address indexed subjectWallet
    );
    event WalletBound(bytes32 indexed credentialId, address wallet);
    event WalletUnbound(bytes32 indexed credentialId, address wallet);
    event CredentialSuperseded(bytes32 indexed credentialId, bytes32 newCredentialId);
    event CredentialRevoked(bytes32 indexed credentialId);
    event FieldRevealed(bytes32 indexed credentialId, uint8 tier, bytes32 key, bytes value);

    function register(
        bytes calldata publicFields,
        SealedTier[] calldata sealedTiers,
        address[] calldata triggers,
        bytes32[] calldata triggerClasses,
        bytes calldata attestorSig,
        bytes calldata subjectWalletSig
    ) external returns (bytes32 credentialId);

    function bindWallet(bytes32 credentialId, address wallet, bytes calldata subjectSig) external;

    /// @dev MUST revert if `wallet` has live bound obligations (integrator-defined hook).
    function unbindWallet(bytes32 credentialId, address wallet, bytes calldata subjectSig) external;

    /// @notice bytes32(0) if no credential is bound to `wallet`.
    function credentialOf(address wallet) external view returns (bytes32);

    function getCredential(bytes32 credentialId) external view returns (CredentialView memory);

    function publicField(bytes32 credentialId, bytes32 key) external view returns (bytes memory);

    /// @notice True iff the credential binds at least one trigger of `triggerClass`;
    ///         returns the first matching trigger address for consumer latch reads.
    function boundTriggerOfClass(bytes32 credentialId, bytes32 triggerClass)
        external
        view
        returns (bool bound, address trigger);

    /// @notice Post-trigger verification of a plaintext against the sealed commitment.
    ///         S1: anyone; emits FieldRevealed (public broadcast). S2: verification path;
    ///         implementations SHOULD gate emission behind qualified-recipient logic.
    function revealField(
        bytes32 credentialId,
        uint8 tier,
        bytes32 key,
        bytes calldata value,
        bytes32 salt,
        bytes32[] calldata merkleProof
    ) external;
}
