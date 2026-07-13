// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRoleProvider} from "./IWildcatRoleProvider.sol";
import {
    ISealedEntityCredentialRegistry,
    IDisclosureTrigger
} from "./ISealedEntityCredential.sol";
import {NavDrawdownTrigger} from "./NavDrawdownTrigger.sol";
import {RedemptionLivenessTrigger} from "./RedemptionLivenessTrigger.sol";

/// @title  RWAIssuerCredentialProvider
/// @notice Pull-style role provider granting a credential to any wallet bound
///         to a live `entity/v1` RWA-issuer credential that pins the
///         RWA_NAV_DRAWDOWN_BPS_V1 trigger class (configured, not latched,
///         not latchable) — and, IF the credential also binds a
///         USTB_REDEMPTION_LIVENESS_V1 trigger, that one must be configured
///         and healthy too.
///
/// @dev    The liveness limb is per-issuer: issuers with an onchain
///         redemption facility (Superstate USTB shape) carry it; issuers
///         whose redemption flow is events-only or fully offchain do NOT get
///         a fake attestation-backed substitute — they bind NAV drawdown
///         alone, and the gap is disclosed in the credential's terms rather
///         than papered over. A consumer wanting to REQUIRE the liveness
///         limb pins that class itself; this provider models the
///         accept-either-shape venue.
contract RWAIssuerCredentialProvider is IRoleProvider {
    bytes32 public constant REQUIRED_TRIGGER_CLASS = keccak256("RWA_NAV_DRAWDOWN_BPS_V1");
    bytes32 public constant OPTIONAL_TRIGGER_CLASS = keccak256("USTB_REDEMPTION_LIVENESS_V1");
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

        (bool bound, address nav) = registry.boundTriggerOfClass(id, REQUIRED_TRIGGER_CLASS);
        if (!bound) return 0;
        if (!NavDrawdownTrigger(nav).isConfigured(id)) return 0;
        IDisclosureTrigger navT = IDisclosureTrigger(nav);
        if (navT.isTriggered(id) || navT.isTriggerable(id)) return 0;

        (bool liveBound, address live) = registry.boundTriggerOfClass(id, OPTIONAL_TRIGGER_CLASS);
        if (liveBound) {
            // Bound but unconfigured is toothless — refused, same as the
            // sibling providers.
            if (!RedemptionLivenessTrigger(live).isConfigured(id)) return 0;
            IDisclosureTrigger liveT = IDisclosureTrigger(live);
            if (liveT.isTriggered(id) || liveT.isTriggerable(id)) return 0;
        }

        return uint32(c.issuedAt);
    }
}
