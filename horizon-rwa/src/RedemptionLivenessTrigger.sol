// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    ISealedEntityCredentialRegistry,
    IDisclosureTrigger
} from "./ISealedEntityCredential.sol";

/// @dev Superstate instant-redemption surface consumed by the trigger.
///      VERIFIED live (docs/HORIZON-READ.md): RedemptionIdle exposes both,
///      capacity cross-checked against the contract's USDC balance.
interface ISuperstateRedemptionLike {
    /// @notice How much superstate token can currently be redeemed, plus the
    ///         chainlink price used. Capacity in token base units.
    function maxUstbRedemptionAmount()
        external
        view
        returns (uint256 superstateTokenAmount, uint256 usdPerUstbChainlinkRaw);

    function paused() external view returns (bool);
}

/// @title  RedemptionLivenessTrigger
/// @notice IDisclosureTrigger implementing the class
///         keccak256("USTB_REDEMPTION_LIVENESS_V1"):
///         latches for an RWA issuer credential when the issuer's instant
///         redemption facility is observed unable to serve redemptions —
///         EITHER capacity below the floor (unpaused) continuously for
///         longer than `dryDuration`, OR paused continuously for longer than
///         `pauseCap`.
///
/// @dev    WHY CAPACITY, NOT QUEUE AGE: the spec's base predicate (oldest
///         unfulfilled request older than N) requires an onchain request
///         queue. USTB's instant path (RedemptionIdle) has none — it either
///         serves a redemption now or it cannot — and the ordinary path
///         (`offchainRedeem`) settles offchain, which per catalogue §12 must
///         not be faked with an attestation. The honest onchain observable
///         is the facility itself: `maxUstbRedemptionAmount()` says exactly
///         how much the issuer can redeem right now. A facility below its
///         floor for longer than the issuer's own documented refill terms
///         (plus honest operational slack — `dryDuration` is a design
///         conversation with the issuer, not a number this contract picks)
///         is a redemption-liveness failure.
///
///         PAUSE CARVE-OUT, CAPPED: a legally-required compliance pause
///         satisfies a naive liveness predicate. `paused()` is exposed
///         onchain, so the carve-out is real: the dry clock runs only while
///         unpaused. But an unbounded carve-out would let the issuer pause
///         forever to dodge the latch — so pause itself has a hard cap
///         (`pauseCap`), after which the latch fires anyway.
///
///         CLOCKS CLEAR ONLY ON A HEALTHY OBSERVATION: a checkpoint that
///         finds the facility unpaused AND at/above the floor clears both
///         clocks. Nothing else clears anything — in particular, pausing
///         does not clear the dry clock and unpausing into a dry facility
///         does not clear the pause clock. Alternating pause/dry therefore
///         never resets either clock, and that game is closed; an honest
///         issuer clears everything the moment its facility is actually
///         serving again. Between checkpoints the condition is assumed to
///         persist — the issuer is the party incentivised to checkpoint its
///         own recovery, and `checkpoint` is permissionless.
///
///         Durations are measured from the arming observation to now, capped
///         at `mandateEnd` — unhealthiness accrued after expiry is not the
///         subject's.
contract RedemptionLivenessTrigger is IDisclosureTrigger {
    bytes32 public constant TRIGGER_CLASS = keccak256("USTB_REDEMPTION_LIVENESS_V1");

    ISealedEntityCredentialRegistry public immutable registry;

    struct Mandate {
        address redemption;    // pinned RedemptionIdle (or equivalent) contract
        uint256 capacityFloor; // token base units; capacity below this = dry
        uint32 dryDuration;    // seconds of unpaused dryness that latch
        uint32 pauseCap;       // seconds of pause that latch regardless
        uint64 mandateStart;
        uint64 mandateEnd;     // 0 = open-ended
    }

    mapping(bytes32 => Mandate) internal _mandates;
    mapping(bytes32 => uint64) public dryFirstObserved;    // 0 = clear
    mapping(bytes32 => uint64) public pauseFirstObserved;  // 0 = clear
    mapping(bytes32 => uint64) internal _triggeredAt;

    event MandateConfigured(
        bytes32 indexed credentialId,
        address indexed redemption,
        uint256 capacityFloor,
        uint32 dryDuration,
        uint32 pauseCap,
        uint64 mandateStart,
        uint64 mandateEnd
    );
    event LivenessCheckpointed(
        bytes32 indexed credentialId,
        uint256 capacity,
        bool paused,
        uint64 dryFirstObserved,
        uint64 pauseFirstObserved
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

    function configure(
        bytes32 credentialId,
        address redemption,
        uint256 capacityFloor,
        uint32 dryDuration,
        uint32 pauseCap,
        uint64 mandateStart,
        uint64 mandateEnd
    ) external {
        if (msg.sender != registry.getCredential(credentialId).attestor) revert NotAttestor();
        if (_mandates[credentialId].redemption != address(0)) revert AlreadyConfigured();
        if (redemption == address(0) || capacityFloor == 0) revert InvalidMandate();
        if (dryDuration == 0 || pauseCap == 0) revert InvalidMandate();
        if (mandateEnd != 0 && mandateEnd <= mandateStart) revert InvalidMandate();

        _mandates[credentialId] = Mandate({
            redemption: redemption,
            capacityFloor: capacityFloor,
            dryDuration: dryDuration,
            pauseCap: pauseCap,
            mandateStart: mandateStart,
            mandateEnd: mandateEnd
        });
        emit MandateConfigured(
            credentialId, redemption, capacityFloor, dryDuration, pauseCap, mandateStart, mandateEnd
        );
    }

    // ---------------------------------------------------------- checkpoint

    /// @notice Permissionless. Healthy (unpaused, capacity at/above floor):
    ///         both clocks clear. Paused: the pause clock arms (in-window).
    ///         Dry (unpaused, below floor): the dry clock arms (in-window).
    ///         Arming is first-observation; clearing requires health.
    function checkpoint(bytes32 credentialId) public {
        if (_mandates[credentialId].redemption == address(0)) revert NotConfigured();
        _checkpoint(credentialId);
    }

    function _checkpoint(bytes32 credentialId) internal {
        Mandate storage m = _mandates[credentialId];
        (bool isPaused, uint256 capacity) = _read(m);
        bool healthy = !isPaused && capacity >= m.capacityFloor;

        if (healthy) {
            dryFirstObserved[credentialId] = 0;
            pauseFirstObserved[credentialId] = 0;
        } else if (_inWindow(m)) {
            if (isPaused) {
                if (pauseFirstObserved[credentialId] == 0) {
                    pauseFirstObserved[credentialId] = uint64(block.timestamp);
                }
            } else if (dryFirstObserved[credentialId] == 0) {
                dryFirstObserved[credentialId] = uint64(block.timestamp);
            }
        }
        emit LivenessCheckpointed(
            credentialId,
            capacity,
            isPaused,
            dryFirstObserved[credentialId],
            pauseFirstObserved[credentialId]
        );
    }

    function _read(Mandate storage m) internal view returns (bool isPaused, uint256 capacity) {
        ISuperstateRedemptionLike r = ISuperstateRedemptionLike(m.redemption);
        isPaused = r.paused();
        if (!isPaused) {
            (capacity,) = r.maxUstbRedemptionAmount();
        }
    }

    function _inWindow(Mandate storage m) internal view returns (bool) {
        return block.timestamp >= m.mandateStart
            && (m.mandateEnd == 0 || block.timestamp <= m.mandateEnd);
    }

    /// @dev In-window duration since an arming observation, capped at
    ///      mandateEnd.
    function _elapsedPast(Mandate storage m, uint64 since, uint32 bound)
        internal
        view
        returns (bool)
    {
        if (since == 0) return false;
        uint256 until = block.timestamp;
        if (m.mandateEnd != 0 && m.mandateEnd < until) until = m.mandateEnd;
        return until > since && until - since > bound;
    }

    // ------------------------------------------------------------ predicate

    /// @notice Liveness failure provable right now: an armed clock past its
    ///         bound while the corresponding condition still holds live (a
    ///         recovered facility cannot be projected failed — but only a
    ///         HEALTHY observation actually clears the clocks).
    function livenessFailureProvable(bytes32 credentialId) public view returns (bool) {
        Mandate storage m = _mandates[credentialId];
        if (m.redemption == address(0)) return false;
        (bool isPaused, uint256 capacity) = _read(m);
        bool healthy = !isPaused && capacity >= m.capacityFloor;
        if (healthy) return false;

        if (_elapsedPast(m, pauseFirstObserved[credentialId], m.pauseCap)) return true;
        return _elapsedPast(m, dryFirstObserved[credentialId], m.dryDuration);
    }

    function isConfigured(bytes32 credentialId) public view returns (bool) {
        return _mandates[credentialId].redemption != address(0);
    }

    function mandate(bytes32 credentialId) external view returns (Mandate memory) {
        return _mandates[credentialId];
    }

    /// @notice Immutable binding data, ITriggerClass-shape: chain id, pinned
    ///         redemption contract, capacity floor in token base units,
    ///         durations in seconds, window in unix seconds.
    function binding(bytes32 credentialId) external view returns (bytes memory) {
        Mandate storage m = _mandates[credentialId];
        return abi.encode(
            block.chainid,
            m.redemption,
            m.capacityFloor,
            m.dryDuration,
            m.pauseCap,
            m.mandateStart,
            m.mandateEnd
        );
    }

    // ------------------------------------------------- IDisclosureTrigger

    /// @inheritdoc IDisclosureTrigger
    function isTriggerable(bytes32 credentialId) public view returns (bool) {
        if (_triggeredAt[credentialId] != 0) return false;
        return livenessFailureProvable(credentialId);
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
    /// @dev Latch materialises: the latch transaction runs a checkpoint, so
    ///      the failing observation it latches on is recorded.
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
