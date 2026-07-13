// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    ISealedEntityCredentialRegistry,
    IDisclosureTrigger
} from "./ISealedEntityCredential.sol";

/// @dev Minimal GhoToken surface consumed by the trigger. VERIFIED live on
///      Ethereum mainnet (GhoToken 0x40D1…6C2f, docs/GHO-READ.md):
///      `getFacilitatorBucket` returns the facilitator's bucket
///      (capacity, level); the on-chain fields are uint128 but ABI-decode
///      cleanly into uint256.
interface IGhoTokenLike {
    function getFacilitatorBucket(address facilitator)
        external
        view
        returns (uint256 capacity, uint256 level);
}

/// @title  GhoFacilitatorWindDownTrigger
/// @notice IDisclosureTrigger implementing the class
///         keccak256("GHO_FACILITATOR_WINDDOWN_V1"):
///         latches for a GHO-facilitator credential when governance has
///         offboarded the facilitator — set its bucket `capacity` to zero —
///         while it still has `level > 0` GHO outstanding (minted and not
///         wound down), and that state has PERSISTED continuously for longer
///         than `windDownPeriod`.
///
/// @dev    THE MISSED-DUTY FAMILY, ZERO PROXIES. GhoToken tracks each
///         facilitator's bucket as first-class state: `capacity` is the
///         governance-set mint ceiling, `level` is the amount currently
///         minted. `capacity == 0` is the unambiguous offboarding signal —
///         governance has told the facilitator to stop — and `level > 0`
///         means it has not discharged its wind-down duty: outstanding GHO
///         it was supposed to retire is still in circulation. No oracle, no
///         accumulator, no high-water mark; the token does the accounting,
///         the trigger reads two words.
///
///         SUSTAINED, NOT INSTANTANEOUS. A facilitator mid-wind-down will
///         briefly show `(capacity == 0, level > 0)` as it burns down its
///         level — that is the duty being performed, not breached. The
///         predicate therefore requires the condition to hold continuously
///         for `windDownPeriod` (the facilitator's own documented wind-down
///         terms plus honest slack — a design conversation, not a number the
///         trigger picks). `checkpoint` records the first timestamp the
///         condition was observed; it SELF-CLEARS the moment a later
///         checkpoint sees `level == 0` (wound down) or `capacity > 0`
///         (re-onboarded). Only a condition that never clears, held past the
///         period, latches.
///
///         POKE CADENCE. Arming is observation-bound: the condition must
///         have been checkpointed at its start to prove persistence.
///         A missed poke only delays the earliest provable latch — offboarding
///         is a slow, governance-visible act, so the window is generous, but
///         watchtowers SHOULD checkpoint when a facilitator's capacity is
///         zeroed. Elapsed time is capped at `mandateEnd`.
///
///         The latch proves the predicate — an offboarded facilitator with
///         undischarged outstanding GHO past its wind-down window — not
///         fault, insolvency, or bad faith. The wind-down may be slow for
///         legitimate reasons; the latch discloses, the S1 narrative
///         explains.
contract GhoFacilitatorWindDownTrigger is IDisclosureTrigger {
    bytes32 public constant TRIGGER_CLASS = keccak256("GHO_FACILITATOR_WINDDOWN_V1");

    ISealedEntityCredentialRegistry public immutable registry;

    struct Mandate {
        address ghoToken;      // canonical GhoToken, pinned at configure
        address facilitator;   // the offboardable facilitator entity, pinned
        uint32 windDownPeriod; // seconds the (capacity==0 && level>0) state must persist
        uint64 mandateStart;
        uint64 mandateEnd;     // 0 = open-ended
    }

    mapping(bytes32 => Mandate) internal _mandates;
    mapping(bytes32 => uint64) public windDownFirstObserved; // 0 = condition not currently armed
    mapping(bytes32 => uint64) internal _triggeredAt;

    event MandateConfigured(
        bytes32 indexed credentialId,
        address indexed ghoToken,
        address indexed facilitator,
        uint32 windDownPeriod,
        uint64 mandateStart,
        uint64 mandateEnd
    );
    event WindDownCheckpointed(
        bytes32 indexed credentialId, uint256 capacity, uint256 level, uint64 windDownFirstObserved
    );

    error NotAttestor();
    error AlreadyConfigured();
    error NotConfigured();
    error InvalidMandate();
    error NotTriggerable();

    constructor(address _registry) {
        registry = ISealedEntityCredentialRegistry(_registry);
    }

    // ------------------------------------------------------------- binding

    /// @notice Pin the mandate: GhoToken, facilitator, wind-down period,
    ///         window. Attestor-only, one-shot.
    function configure(
        bytes32 credentialId,
        address ghoToken,
        address facilitator,
        uint32 windDownPeriod,
        uint64 mandateStart,
        uint64 mandateEnd
    ) external {
        if (msg.sender != registry.getCredential(credentialId).attestor) revert NotAttestor();
        if (_mandates[credentialId].ghoToken != address(0)) revert AlreadyConfigured();
        if (ghoToken == address(0) || facilitator == address(0) || windDownPeriod == 0) {
            revert InvalidMandate();
        }
        if (mandateEnd != 0 && mandateEnd <= mandateStart) revert InvalidMandate();

        _mandates[credentialId] = Mandate({
            ghoToken: ghoToken,
            facilitator: facilitator,
            windDownPeriod: windDownPeriod,
            mandateStart: mandateStart,
            mandateEnd: mandateEnd
        });
        emit MandateConfigured(credentialId, ghoToken, facilitator, windDownPeriod, mandateStart, mandateEnd);
    }

    // ---------------------------------------------------------- checkpoint

    /// @notice Permissionless. Arms the wind-down clock (in-window) the first
    ///         time `(capacity == 0 && level > 0)` is observed; clears it the
    ///         moment the condition breaks (level wound to zero, or capacity
    ///         restored).
    function checkpoint(bytes32 credentialId) public {
        if (_mandates[credentialId].ghoToken == address(0)) revert NotConfigured();
        _checkpoint(credentialId);
    }

    function _checkpoint(bytes32 credentialId) internal {
        Mandate storage m = _mandates[credentialId];
        (uint256 capacity, uint256 level) = IGhoTokenLike(m.ghoToken).getFacilitatorBucket(m.facilitator);
        bool condition = (capacity == 0 && level > 0);

        if (!condition) {
            windDownFirstObserved[credentialId] = 0;
        } else if (windDownFirstObserved[credentialId] == 0 && _inWindow(m)) {
            windDownFirstObserved[credentialId] = uint64(block.timestamp);
        }
        emit WindDownCheckpointed(credentialId, capacity, level, windDownFirstObserved[credentialId]);
    }

    function _inWindow(Mandate storage m) internal view returns (bool) {
        return block.timestamp >= m.mandateStart
            && (m.mandateEnd == 0 || block.timestamp <= m.mandateEnd);
    }

    /// @dev In-window elapsed since arming, capped at mandateEnd.
    function _elapsedPast(Mandate storage m, uint64 since) internal view returns (bool) {
        if (since == 0) return false;
        uint256 until = block.timestamp;
        if (m.mandateEnd != 0 && m.mandateEnd < until) until = m.mandateEnd;
        return until > since && until - since > m.windDownPeriod;
    }

    // ------------------------------------------------------------ predicate

    /// @notice The (capacity==0 && level>0) state, read live.
    function conditionHolds(bytes32 credentialId) public view returns (bool) {
        Mandate storage m = _mandates[credentialId];
        if (m.ghoToken == address(0)) return false;
        (uint256 capacity, uint256 level) = IGhoTokenLike(m.ghoToken).getFacilitatorBucket(m.facilitator);
        return capacity == 0 && level > 0;
    }

    /// @notice Provable now: the condition holds live AND an armed clock has
    ///         run past `windDownPeriod`. A recovered facility (condition no
    ///         longer live) is never provable, even with a stale armed clock.
    function windDownProvable(bytes32 credentialId) public view returns (bool) {
        if (!conditionHolds(credentialId)) return false;
        return _elapsedPast(_mandates[credentialId], windDownFirstObserved[credentialId]);
    }

    function isConfigured(bytes32 credentialId) public view returns (bool) {
        return _mandates[credentialId].ghoToken != address(0);
    }

    function mandate(bytes32 credentialId) external view returns (Mandate memory) {
        return _mandates[credentialId];
    }

    /// @notice Immutable binding data, ITriggerClass-shape: chain id, pinned
    ///         GhoToken + facilitator, wind-down period in seconds, window in
    ///         unix seconds.
    function binding(bytes32 credentialId) external view returns (bytes memory) {
        Mandate storage m = _mandates[credentialId];
        return abi.encode(
            block.chainid, m.ghoToken, m.facilitator, m.windDownPeriod, m.mandateStart, m.mandateEnd
        );
    }

    // ------------------------------------------------- IDisclosureTrigger

    /// @inheritdoc IDisclosureTrigger
    function isTriggerable(bytes32 credentialId) public view returns (bool) {
        if (_triggeredAt[credentialId] != 0) return false;
        return windDownProvable(credentialId);
    }

    /// @inheritdoc IDisclosureTrigger
    function isTriggered(bytes32 credentialId) external view returns (bool) {
        return _triggeredAt[credentialId] != 0;
    }

    /// @inheritdoc IDisclosureTrigger
    function triggeredAt(bytes32 credentialId) external view returns (uint64) {
        return _triggeredAt[credentialId];
    }

    /// @inheritdoc IDisclosureTrigger
    /// @dev Latch materialises: it runs a checkpoint first, so the observation
    ///      it latches on is recorded in the same permissionless call.
    function latch(bytes32 credentialId) external {
        if (!isTriggerable(credentialId)) revert NotTriggerable();
        _checkpoint(credentialId);
        _triggeredAt[credentialId] = uint64(block.timestamp);
        emit DisclosureTriggered(credentialId, uint64(block.timestamp));
    }

    /// @inheritdoc IDisclosureTrigger
    function triggerClass() external pure returns (bytes32) {
        return TRIGGER_CLASS;
    }
}
