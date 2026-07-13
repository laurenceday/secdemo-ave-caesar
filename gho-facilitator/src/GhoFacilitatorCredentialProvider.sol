// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRoleProvider} from "./IWildcatRoleProvider.sol";
import {
    ISealedEntityCredentialRegistry,
    IDisclosureTrigger
} from "./ISealedEntityCredential.sol";
import {GhoFacilitatorWindDownTrigger} from "./GhoFacilitatorWindDownTrigger.sol";

/// @title  GhoFacilitatorCredentialProvider
/// @notice Pull-style role provider granting a credential to any wallet bound
///         to a live `entity/v1` GHO-facilitator credential that pins the
///         GHO_FACILITATOR_WINDDOWN_V1 trigger class (configured, not
///         latched, not latchable).
///
/// @dev    Consumption point: a facilitator-listing or governance surface
///         deciding which facilitator entities remain in good standing. The
///         accountability (S1 disclosure of the responsible entity, S2 to
///         governance/counsel) rides on the trigger and works with no gate.
contract GhoFacilitatorCredentialProvider is IRoleProvider {
    bytes32 public constant REQUIRED_TRIGGER_CLASS = keccak256("GHO_FACILITATOR_WINDDOWN_V1");
    bytes32 public constant REQUIRED_SCHEMA_PROFILE = keccak256("entity/v1");

    ISealedEntityCredentialRegistry public immutable registry;

    constructor(address _registry) {
        registry = ISealedEntityCredentialRegistry(_registry);
    }

    /// @inheritdoc IRoleProvider
    function isPullProvider() external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IRoleProvider
    function getCredential(address account) public view returns (uint32 timestamp) {
        return _credentialTimestamp(account);
    }

    /// @inheritdoc IRoleProvider
    function validateCredential(
        address account,
        bytes calldata
    ) external view returns (uint32 timestamp) {
        return _credentialTimestamp(account);
    }

    function _credentialTimestamp(address account) internal view returns (uint32) {
        bytes32 id = registry.credentialOf(account);
        if (id == bytes32(0)) return 0;

        ISealedEntityCredentialRegistry.CredentialView memory c = registry.getCredential(id);

        if (c.schemaProfile != REQUIRED_SCHEMA_PROFILE) return 0;
        if (c.revoked) return 0;
        if (c.expiresAt != 0 && block.timestamp >= c.expiresAt) return 0;

        (bool bound, address trigger) = registry.boundTriggerOfClass(id, REQUIRED_TRIGGER_CLASS);
        if (!bound) return 0;

        if (!GhoFacilitatorWindDownTrigger(trigger).isConfigured(id)) return 0;

        IDisclosureTrigger t = IDisclosureTrigger(trigger);
        if (t.isTriggered(id) || t.isTriggerable(id)) return 0;

        return uint32(c.issuedAt);
    }
}
