// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    ISealedEntityCredentialRegistry,
    IDisclosureTrigger
} from "./ISealedEntityCredential.sol";

/// @dev Minimal Aave V3 (v3.3+) Pool surface consumed by the trigger.
///      `getReserveDeficit` is the protocol-native cumulative bad-debt
///      counter introduced in v3.3: liquidations that burn unrecoverable
///      variable debt record it as a per-reserve deficit in underlying
///      units (LiquidationLogic: `debtReserve.deficit += outstandingDebt`).
///      Verified against aave-dao/aave-v3-origin, July 2026.
interface IAaveV3PoolLike {
    function getReserveDeficit(address asset) external view returns (uint256);
}

/// @title  AaveV3DeficitTrigger
/// @notice IDisclosureTrigger implementing the class
///         keccak256("AAVE_V3_GROSS_DEFICIT_V1"):
///         latches for a risk-service-provider credential when the GROSS
///         protocol deficit incurred across the mandate's reserve set,
///         within the mandate window, reaches the mandate's threshold.
///
/// @dev    WHY THE DEFICIT COUNTER: Aave v3.3 records bad debt burned during
///         liquidation as a per-reserve deficit readable on-chain — a native
///         realised-loss counter with no oracle, no high-water-mark proxy,
///         and no event indexing. The pool does the accounting; the trigger
///         reads it.
///
///         WHY GROSS, NOT NET: `getReserveDeficit` is reduced when the
///         deficit is eliminated (Umbrella / governance coverage via
///         `eliminateReserveDeficit`). A credential measuring the live value
///         could be cured back under threshold before anyone latches — by
///         the subject or a friendly third party. This trigger therefore
///         keeps a checkpointed monotonic accumulator of deficit INCREASES:
///         `checkpoint` adds `d - lastObserved` whenever the counter rose,
///         and updates `lastObserved` in all cases — including decreases, so
///         an elimination never erases accumulated history, and a later rise
///         from the lowered base counts as the new bad debt it is.
///
///         POKE CADENCE: a rise that is fully eliminated before anyone
///         checkpoints is not counted — the accumulator can only attribute
///         what a checkpoint observed. Deficit elimination is a slow,
///         governance-visible path (aToken-funded coverage restricted to the
///         Umbrella/coverage entity), so the observation window is generous;
///         watchtowers SHOULD checkpoint on every DeficitCreated event and at
///         mandate boundaries. A missed poke only ever UNDERSTATES the
///         subject's gross deficit — delay degrades timing, never truth.
///
///         MANDATE WINDOW: increases accumulate only when observed inside
///         [mandateStart, mandateEnd] (mandateEnd = 0 means open-ended).
///         Checkpoints outside the window still update `lastObserved` —
///         pre-mandate and post-mandate deficits move the base but are never
///         attributed to the subject. Ambiguity at the boundary therefore
///         biases toward the subject on entry (pre-start rises are swallowed
///         into the base) and against un-poked exit (an increase not
///         checkpointed before mandateEnd is unattributable and lost) —
///         checkpoint just before the window closes.
///
///         NORMALISATION: deficits are denominated in each reserve's
///         underlying units. The trigger does NOT convert across assets via
///         an oracle. A conforming mandate binds same-denomination reserves
///         only (one credential per denomination; e.g. the WETH reserve, or
///         a same-peg stablecoin set under a documented 1:1 assumption) with
///         the threshold in that denomination's smallest unit.
contract AaveV3DeficitTrigger is IDisclosureTrigger {
    bytes32 public constant TRIGGER_CLASS = keccak256("AAVE_V3_GROSS_DEFICIT_V1");

    ISealedEntityCredentialRegistry public immutable registry;

    /// @notice Cap on bound reserves per credential, bounding checkpoint/latch gas.
    uint256 public constant MAX_RESERVES = 16;

    struct Mandate {
        address pool;         // canonical Aave V3 (v3.3+) Pool, pinned at configure
        uint64 mandateStart;  // losses accumulate only when observed at/after this
        uint64 mandateEnd;    // ... and at/before this; 0 = open-ended
        uint256 threshold;    // gross-deficit threshold, scope-denomination base units
    }

    mapping(bytes32 => Mandate) internal _mandates;                          // credentialId => mandate binding
    mapping(bytes32 => address[]) internal _reserves;                        // credentialId => bound reserve underlyings
    mapping(bytes32 => mapping(address => bool)) public isBound;             // credentialId => reserve => bound
    mapping(bytes32 => mapping(address => uint256)) public lastObservedDeficit; // credentialId => reserve => last checkpointed deficit
    mapping(bytes32 => uint256) public grossDeficitAccumulated;              // credentialId => checkpointed gross deficit
    mapping(bytes32 => uint64) internal _triggeredAt;

    event MandateConfigured(
        bytes32 indexed credentialId,
        address indexed pool,
        uint256 threshold,
        uint64 mandateStart,
        uint64 mandateEnd
    );
    event ReserveBound(bytes32 indexed credentialId, address indexed reserve, uint256 baselineDeficit);
    event DeficitCheckpointed(bytes32 indexed credentialId, uint256 grossDeficitAccumulated);

    error NotAttestor();
    error NotSubjectOrAttestor();
    error AlreadyConfigured();
    error NotConfigured();
    error InvalidMandate();
    error ReserveLimit();
    error AlreadyBound();
    error AlreadyLatched();
    error NotTriggerable();

    constructor(address _registry) {
        registry = ISealedEntityCredentialRegistry(_registry);
    }

    // ------------------------------------------------------------- binding

    /// @notice Pin the mandate binding for a credential: the pool, the
    ///         threshold, and the mandate window. Attestor-only (the attestor
    ///         verified the DAO mandate at issuance), one-shot — none of it
    ///         can be re-pointed after the fact.
    function configure(
        bytes32 credentialId,
        address pool,
        uint256 threshold,
        uint64 mandateStart,
        uint64 mandateEnd
    ) external {
        if (msg.sender != registry.getCredential(credentialId).attestor) revert NotAttestor();
        if (_mandates[credentialId].pool != address(0)) revert AlreadyConfigured();
        if (pool == address(0) || threshold == 0) revert InvalidMandate();
        if (mandateEnd != 0 && mandateEnd <= mandateStart) revert InvalidMandate();

        _mandates[credentialId] =
            Mandate({pool: pool, mandateStart: mandateStart, mandateEnd: mandateEnd, threshold: threshold});
        emit MandateConfigured(credentialId, pool, threshold, mandateStart, mandateEnd);
    }

    /// @notice Bind a reserve (underlying asset) into the mandate's scope.
    ///         Append-only — reserves are never unbound, so the subject
    ///         cannot rotate a sick reserve out of scope. Callable by the
    ///         attestor or by a wallet bound to the credential (the subject
    ///         widening its own accountability), pre-latch only. Accumulation
    ///         for the reserve starts from its deficit at add-time, not zero.
    function addReserve(bytes32 credentialId, address reserve) external {
        if (
            msg.sender != registry.getCredential(credentialId).attestor
                && registry.credentialOf(msg.sender) != credentialId
        ) revert NotSubjectOrAttestor();
        Mandate storage m = _mandates[credentialId];
        if (m.pool == address(0)) revert NotConfigured();
        if (_triggeredAt[credentialId] != 0) revert AlreadyLatched();
        address[] storage set = _reserves[credentialId];
        if (set.length >= MAX_RESERVES) revert ReserveLimit();
        if (isBound[credentialId][reserve]) revert AlreadyBound();

        uint256 baseline = IAaveV3PoolLike(m.pool).getReserveDeficit(reserve);
        set.push(reserve);
        isBound[credentialId][reserve] = true;
        lastObservedDeficit[credentialId][reserve] = baseline;
        emit ReserveBound(credentialId, reserve, baseline);
    }

    // ---------------------------------------------------------- checkpoint

    /// @notice Permissionless. Records the current deficit of every bound
    ///         reserve; increases observed inside the mandate window are
    ///         added to the gross accumulator. `lastObservedDeficit` is
    ///         updated in ALL cases — on decreases too, so an elimination
    ///         neither erases accumulated history nor suppresses the counting
    ///         of new bad debt from the lowered base.
    function checkpoint(bytes32 credentialId) public {
        if (_mandates[credentialId].pool == address(0)) revert NotConfigured();
        _checkpoint(credentialId);
    }

    function _checkpoint(bytes32 credentialId) internal {
        Mandate storage m = _mandates[credentialId];
        IAaveV3PoolLike pool = IAaveV3PoolLike(m.pool);
        bool inWindow = _inWindow(m);

        address[] storage set = _reserves[credentialId];
        uint256 gross = grossDeficitAccumulated[credentialId];
        uint256 n = set.length;
        for (uint256 i; i < n; ++i) {
            address reserve = set[i];
            uint256 d = pool.getReserveDeficit(reserve);
            uint256 last = lastObservedDeficit[credentialId][reserve];
            if (d != last) {
                if (d > last && inWindow) gross += d - last;
                lastObservedDeficit[credentialId][reserve] = d;
            }
        }
        if (gross != grossDeficitAccumulated[credentialId]) {
            grossDeficitAccumulated[credentialId] = gross;
        }
        emit DeficitCheckpointed(credentialId, gross);
    }

    function _inWindow(Mandate storage m) internal view returns (bool) {
        return block.timestamp >= m.mandateStart
            && (m.mandateEnd == 0 || block.timestamp <= m.mandateEnd);
    }

    // ------------------------------------------------------------ predicate

    /// @notice Gross deficit provable right now: the checkpointed accumulator
    ///         plus, while inside the mandate window, any un-checkpointed
    ///         increases visible on the pool. Outside the window the live
    ///         projection is excluded — an increase that was never
    ///         checkpointed in-window cannot be attributed to the mandate.
    function projectedGrossDeficit(bytes32 credentialId) public view returns (uint256 gross) {
        Mandate storage m = _mandates[credentialId];
        gross = grossDeficitAccumulated[credentialId];
        if (m.pool == address(0) || !_inWindow(m)) return gross;

        IAaveV3PoolLike pool = IAaveV3PoolLike(m.pool);
        address[] storage set = _reserves[credentialId];
        uint256 n = set.length;
        for (uint256 i; i < n; ++i) {
            address reserve = set[i];
            uint256 d = pool.getReserveDeficit(reserve);
            uint256 last = lastObservedDeficit[credentialId][reserve];
            if (d > last) gross += d - last;
        }
    }

    /// @notice True once the credential has a pinned pool, a nonzero
    ///         threshold, and at least one reserve in scope. Consumers SHOULD
    ///         require this: a bound-but-unconfigured trigger of this class
    ///         is toothless and MUST NOT be accepted as consequence-bearing.
    function isConfigured(bytes32 credentialId) public view returns (bool) {
        return _mandates[credentialId].pool != address(0) && _reserves[credentialId].length != 0;
    }

    function mandate(bytes32 credentialId) external view returns (Mandate memory) {
        return _mandates[credentialId];
    }

    function reserves(bytes32 credentialId) external view returns (address[] memory) {
        return _reserves[credentialId];
    }

    /// @notice Immutable binding data, ITriggerClass-shape: chain id, pinned
    ///         pool, threshold + units (scope-denomination base units),
    ///         window in unix seconds, and the (append-only) scope set.
    function binding(bytes32 credentialId) external view returns (bytes memory) {
        Mandate storage m = _mandates[credentialId];
        return abi.encode(
            block.chainid, m.pool, m.threshold, m.mandateStart, m.mandateEnd, _reserves[credentialId]
        );
    }

    // ------------------------------------------------- IDisclosureTrigger

    /// @inheritdoc IDisclosureTrigger
    function isTriggerable(bytes32 credentialId) public view returns (bool) {
        if (_triggeredAt[credentialId] != 0) return false; // already latched
        if (!isConfigured(credentialId)) return false;
        return projectedGrossDeficit(credentialId) >= _mandates[credentialId].threshold;
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
    /// @dev Latch materialises: it runs a checkpoint first, so the latch
    ///      transaction itself records the observation it latches on — a
    ///      single permissionless call both proves and latches.
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
