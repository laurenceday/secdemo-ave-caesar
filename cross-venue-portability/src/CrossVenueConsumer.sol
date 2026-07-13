// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    ISealedEntityCredentialRegistry,
    IDisclosureTrigger
} from "./ISealedEntityCredential.sol";

/// @title  CrossVenueConsumer
/// @notice The thesis demo of the ERC: reusable KYB + a shared consequence
///         surface. A single `entity/v1` credential is issued once and
///         accepted at multiple venues; each venue instantiates this
///         consumer with the trigger classes IT cares about, and a latch in
///         any bound class is a permanent registry fact every venue can read.
///
/// @dev    No new trigger machinery — this is registry-side composition. The
///         consumer pins a set of required trigger classes at construction
///         (a venue's acceptance policy, per ERC §11: pin CLASSES, not
///         addresses). `accepts` grants iff the credential is a live
///         `entity/v1` and, for EVERY required class, the credential binds a
///         trigger of that class which has neither latched nor become
///         latchable.
///
///         Two venues pinning their own single class get venue-local
///         isolation: a Wildcat delinquency latch does not, by itself, make
///         the entity unusable at an Aave venue that only pins the Aave
///         class. A venue that wants the STRICT shared-consequence behaviour
///         — an entity that defaulted anywhere is untrusted here — pins both
///         classes; then a latch in either venue disqualifies the entity at
///         this one. `latchedClasses` exposes exactly which venues' triggers
///         have fired on a credential, so the cross-venue visibility is
///         legible on-chain regardless of any single venue's policy.
contract CrossVenueConsumer {
    ISealedEntityCredentialRegistry public immutable registry;
    bytes32 public constant REQUIRED_SCHEMA_PROFILE = keccak256("entity/v1");

    bytes32[] internal _requiredClasses;

    constructor(address _registry, bytes32[] memory requiredClasses) {
        registry = ISealedEntityCredentialRegistry(_registry);
        _requiredClasses = requiredClasses;
    }

    function requiredClasses() external view returns (bytes32[] memory) {
        return _requiredClasses;
    }

    /// @notice True iff `account`'s bound credential is a live `entity/v1`
    ///         that binds every required class and none of them is latched or
    ///         latchable.
    function accepts(address account) external view returns (bool) {
        bytes32 id = registry.credentialOf(account);
        if (id == bytes32(0)) return false;
        return acceptsCredential(id);
    }

    function acceptsCredential(bytes32 credentialId) public view returns (bool) {
        ISealedEntityCredentialRegistry.CredentialView memory c = registry.getCredential(credentialId);
        if (c.schemaProfile != REQUIRED_SCHEMA_PROFILE) return false;
        if (c.revoked) return false;
        if (c.expiresAt != 0 && block.timestamp >= c.expiresAt) return false;

        uint256 n = _requiredClasses.length;
        for (uint256 i; i < n; ++i) {
            (bool bound, address trigger) =
                registry.boundTriggerOfClass(credentialId, _requiredClasses[i]);
            if (!bound) return false;
            IDisclosureTrigger t = IDisclosureTrigger(trigger);
            if (t.isTriggered(credentialId) || t.isTriggerable(credentialId)) return false;
        }
        return true;
    }

    /// @notice Which of this venue's required classes have LATCHED on the
    ///         credential (recorded latches only — the permanent registry
    ///         fact, not the projection). Empty means clean here.
    function latchedClasses(bytes32 credentialId) external view returns (bytes32[] memory) {
        uint256 n = _requiredClasses.length;
        bytes32[] memory hits = new bytes32[](n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            (bool bound, address trigger) =
                registry.boundTriggerOfClass(credentialId, _requiredClasses[i]);
            if (bound && IDisclosureTrigger(trigger).isTriggered(credentialId)) {
                hits[k++] = _requiredClasses[i];
            }
        }
        assembly {
            mstore(hits, k)
        }
        return hits;
    }
}
