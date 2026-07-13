// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRoleProvider} from "./IWildcatRoleProvider.sol";
import {
    ISealedEntityCredentialRegistry,
    IDisclosureTrigger
} from "./ISealedEntityCredential.sol";
import {AaveV4SpokeTrigger} from "./AaveV4SpokeTrigger.sol";

/// @title  SpokeOperatorCredentialProvider
/// @notice Pull-style role provider granting a credential to any wallet bound
///         to a live `entity/v1` spoke-operator credential that pins the
///         AAVE_V4_SPOKE_GROSS_DEFICIT_V1 trigger class, carries a CONFIGURED
///         mandate on it, and has not latched (nor become latchable) on
///         either limb.
///
/// @dev    This is the admissibility rail for permissionless spokes: today
///         spoke creation is DAO-gated; the stated direction is
///         permissionless creation, and the question becomes which spokes a
///         venue treats as ADMISSIBLE. A consumer that requires this
///         credential gets: a verified legal entity behind the spoke
///         (registry), a realised-loss latch no one can cure away (limb 1),
///         the DAO-sanction latch (limb 2), and sealed recourse tiers behind
///         both. The provider is venue furniture — the accountability rides
///         on the trigger and works with no gate anywhere.
contract SpokeOperatorCredentialProvider is IRoleProvider {
    bytes32 public constant REQUIRED_TRIGGER_CLASS = keccak256("AAVE_V4_SPOKE_GROSS_DEFICIT_V1");
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

        if (!AaveV4SpokeTrigger(trigger).isConfigured(id)) return 0;

        IDisclosureTrigger t = IDisclosureTrigger(trigger);
        if (t.isTriggered(id) || t.isTriggerable(id)) return 0;

        return uint32(c.issuedAt);
    }
}
