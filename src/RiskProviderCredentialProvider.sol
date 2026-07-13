// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRoleProvider} from "./IWildcatRoleProvider.sol";
import {
    ISealedEntityCredentialRegistry,
    IDisclosureTrigger
} from "./ISealedEntityCredential.sol";
import {AaveV3DeficitTrigger} from "./AaveV3DeficitTrigger.sol";

/// @title  RiskProviderCredentialProvider
/// @notice Pull-style role provider granting a credential to any wallet bound
///         to a live `entity/v1` risk-service-provider credential that pins
///         the AAVE_V3_GROSS_DEFICIT_V1 trigger class, carries a CONFIGURED
///         mandate on it, and has not latched (nor become latchable) on it.
///
/// @dev    Consumption points, day one: a DAO deciding which risk providers
///         to seat over a reserve set (the mandate this trigger measures); a
///         WildcatRoleProviderGate slot on any market wanting credentialed
///         counterparties; any venue's "credentialed risk-provider only"
///         listing surface. The provider is venue furniture — the
///         accountability (stake burn, S1 disclosure, S2 to affected
///         parties' counsel) rides on the trigger itself and works with no
///         gate anywhere.
///
///         Unlike its sibling providers, this one additionally requires
///         `isConfigured` on the trigger: this class carries per-credential
///         binding data (pool, threshold, window, scope), and a credential
///         whose mandate was never configured — or has an empty scope — binds
///         a trigger that can never latch. That is not a consequence-bearing
///         credential and is refused outright.
contract RiskProviderCredentialProvider is IRoleProvider {
    bytes32 public constant REQUIRED_TRIGGER_CLASS = keccak256("AAVE_V3_GROSS_DEFICIT_V1");
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

        if (!AaveV3DeficitTrigger(trigger).isConfigured(id)) return 0;

        IDisclosureTrigger t = IDisclosureTrigger(trigger);
        if (t.isTriggered(id) || t.isTriggerable(id)) return 0;

        return uint32(c.issuedAt);
    }
}
