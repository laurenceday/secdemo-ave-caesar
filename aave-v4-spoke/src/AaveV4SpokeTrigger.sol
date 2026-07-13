// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    ISealedEntityCredentialRegistry,
    IDisclosureTrigger
} from "./ISealedEntityCredential.sol";

/// @dev Minimal Aave V4 Hub surface consumed by the trigger. Mirrored from
///      the aave-v4 codebase (IHub/IHubBase, July 2026 read — see
///      docs/V4-READ.md); diff before integrating.
interface IAaveV4HubLike {
    /// @dev Field order and types must match IHub.SpokeConfig exactly.
    struct SpokeConfig {
        uint40 addCap;
        uint40 drawCap; // whole assets (not scaled by decimals); type(uint40).max = uncapped
        uint24 riskPremiumThreshold;
        bool active;
        bool halted;
    }

    /// @notice Per-(asset, spoke) deficit, in asset units scaled by RAY.
    function getSpokeDeficitRay(uint256 assetId, address spoke) external view returns (uint256);

    function getSpokeConfig(uint256 assetId, address spoke)
        external
        view
        returns (SpokeConfig memory);
}

/// @title  AaveV4SpokeTrigger
/// @notice IDisclosureTrigger implementing the class
///         keccak256("AAVE_V4_SPOKE_GROSS_DEFICIT_V1"):
///         latches for a spoke-operator credential when EITHER
///         limb 1 — the gross deficit the bound spoke incurred against the
///         Hub, within the mandate window and across the mandate's asset
///         scope, reaches the threshold; OR
///         limb 2 — the Hub's credit line (`drawCap`) for the spoke is
///         observed at zero on an in-scope asset that previously had a
///         positive line, at a time when the spoke's gross deficit has
///         already reached a configured floor (the hub-side sanction limb).
///
/// @dev    LIMB 1 is Demo 1's checkpointed monotonic accumulator verbatim,
///         pointed at V4's finer-grained counter: the Hub tracks deficit per
///         (asset, spoke) pair (`getSpokeDeficitRay`), spokes report their
///         own liquidation write-offs (`reportDeficit`), and a role-gated
///         `eliminateDeficit` reduces the counter — so the trigger
///         accumulates observed INCREASES and a cure before the latch
///         changes nothing already checkpointed. All deficit quantities and
///         thresholds are in asset units scaled by RAY (1e27), the Hub's own
///         precision; no rounding occurs anywhere in the predicate.
///
///         LIMB 2 exists because a DAO that zeroes a bleeding spoke's credit
///         line is making exactly the judgement this credential family wants
///         to surface — but `drawCap == 0` alone is NOT that judgement:
///         fee-receiver spokes live at zero drawCap by construction, add-only
///         spokes can be configured that way, and a benign wind-down zeroes
///         lines with no fault implied. Three guards make the limb honest:
///         (i) a positive drawCap must have been observed on that asset
///         earlier in the credential's history — a line that never existed
///         cannot be "reduced to zero"; (ii) the spoke's gross deficit must
///         have reached `deficitFloorRay` by the time the zero line is
///         observed (deficits observed in the same checkpoint count — the
///         DAO may sanction in the same block the loss lands); (iii) both
///         observations must fall inside the mandate window. The residual
///         ambiguity — a DAO zeroing a line for unrelated reasons after the
///         floor was crossed — is documented, not hidden: raise the floor to
///         calibrate it, and remember the latch proves the predicate, not
///         fault. Once armed, the sanction observation is permanent: a later
///         cap restoration must not disarm a pre-latch fact (same
///         cure-before-latch reasoning as the deficit accumulator).
///
///         ATTRIBUTION: V4 has no per-spoke operator address on-chain
///         (AccessManager role sets — see docs/V4-READ.md §4). The binding
///         pins hub + spoke contract addresses; entity→spoke operatorship is
///         an attested registry-level fact. The mandate window bounds
///         attribution at operator transitions; ambiguity biases toward the
///         subject exactly as in the V3 instance.
contract AaveV4SpokeTrigger is IDisclosureTrigger {
    bytes32 public constant TRIGGER_CLASS = keccak256("AAVE_V4_SPOKE_GROSS_DEFICIT_V1");

    ISealedEntityCredentialRegistry public immutable registry;

    /// @notice Cap on bound assets per credential, bounding checkpoint/latch gas.
    uint256 public constant MAX_ASSETS = 16;

    struct Mandate {
        address hub;             // canonical V4 Hub, pinned at configure
        address spoke;           // the operated spoke, pinned at configure
        uint64 mandateStart;     // observations attribute only inside the window
        uint64 mandateEnd;       // 0 = open-ended
        uint256 thresholdRay;    // limb-1 gross-deficit threshold, asset units × RAY
        uint256 deficitFloorRay; // limb-2 floor: sanction counts only past this, asset units × RAY
    }

    mapping(bytes32 => Mandate) internal _mandates;
    mapping(bytes32 => uint256[]) internal _assetIds;                          // append-only scope
    mapping(bytes32 => mapping(uint256 => bool)) public isBound;               // credentialId => assetId => bound
    mapping(bytes32 => mapping(uint256 => uint256)) public lastObservedDeficitRay;
    mapping(bytes32 => mapping(uint256 => bool)) public capEverPositive;       // credentialId => assetId => drawCap > 0 seen
    mapping(bytes32 => uint256) public grossDeficitAccumulatedRay;
    mapping(bytes32 => uint64) public sanctionObservedAt;                      // limb-2 armed timestamp (0 = never)
    mapping(bytes32 => uint64) internal _triggeredAt;

    event MandateConfigured(
        bytes32 indexed credentialId,
        address indexed hub,
        address indexed spoke,
        uint256 thresholdRay,
        uint256 deficitFloorRay,
        uint64 mandateStart,
        uint64 mandateEnd
    );
    event AssetBound(bytes32 indexed credentialId, uint256 indexed assetId, uint256 baselineDeficitRay);
    event DeficitCheckpointed(bytes32 indexed credentialId, uint256 grossDeficitAccumulatedRay);
    event SanctionObserved(bytes32 indexed credentialId, uint256 indexed assetId, uint256 grossDeficitAccumulatedRay);

    error NotAttestor();
    error NotSubjectOrAttestor();
    error AlreadyConfigured();
    error NotConfigured();
    error InvalidMandate();
    error AssetLimit();
    error AlreadyBound();
    error AlreadyLatched();
    error NotTriggerable();

    constructor(address _registry) {
        registry = ISealedEntityCredentialRegistry(_registry);
    }

    // ------------------------------------------------------------- binding

    /// @notice Pin the mandate binding: hub, spoke, both limbs' thresholds,
    ///         and the mandate window. Attestor-only, one-shot.
    function configure(
        bytes32 credentialId,
        address hub,
        address spoke,
        uint256 thresholdRay,
        uint256 deficitFloorRay,
        uint64 mandateStart,
        uint64 mandateEnd
    ) external {
        if (msg.sender != registry.getCredential(credentialId).attestor) revert NotAttestor();
        if (_mandates[credentialId].hub != address(0)) revert AlreadyConfigured();
        if (hub == address(0) || spoke == address(0)) revert InvalidMandate();
        if (thresholdRay == 0 || deficitFloorRay == 0) revert InvalidMandate();
        if (mandateEnd != 0 && mandateEnd <= mandateStart) revert InvalidMandate();

        _mandates[credentialId] = Mandate({
            hub: hub,
            spoke: spoke,
            mandateStart: mandateStart,
            mandateEnd: mandateEnd,
            thresholdRay: thresholdRay,
            deficitFloorRay: deficitFloorRay
        });
        emit MandateConfigured(
            credentialId, hub, spoke, thresholdRay, deficitFloorRay, mandateStart, mandateEnd
        );
    }

    /// @notice Bind a hub asset into the mandate's scope. Append-only,
    ///         attestor or bound subject wallet, pre-latch only. Deficit
    ///         accumulation for the asset starts from its value at add-time.
    function addAsset(bytes32 credentialId, uint256 assetId) external {
        if (
            msg.sender != registry.getCredential(credentialId).attestor
                && registry.credentialOf(msg.sender) != credentialId
        ) revert NotSubjectOrAttestor();
        Mandate storage m = _mandates[credentialId];
        if (m.hub == address(0)) revert NotConfigured();
        if (_triggeredAt[credentialId] != 0) revert AlreadyLatched();
        uint256[] storage set = _assetIds[credentialId];
        if (set.length >= MAX_ASSETS) revert AssetLimit();
        if (isBound[credentialId][assetId]) revert AlreadyBound();

        uint256 baseline = IAaveV4HubLike(m.hub).getSpokeDeficitRay(assetId, m.spoke);
        set.push(assetId);
        isBound[credentialId][assetId] = true;
        lastObservedDeficitRay[credentialId][assetId] = baseline;
        emit AssetBound(credentialId, assetId, baseline);
    }

    // ---------------------------------------------------------- checkpoint

    /// @notice Permissionless. Limb 1: record every in-scope asset's deficit,
    ///         accumulating in-window increases. Limb 2: after accumulation,
    ///         arm the sanction if any in-scope asset whose line was
    ///         previously positive now reads drawCap == 0 while the gross
    ///         accumulator stands at/above the floor (in-window only).
    ///         `capEverPositive` and an armed sanction never un-set.
    function checkpoint(bytes32 credentialId) public {
        if (_mandates[credentialId].hub == address(0)) revert NotConfigured();
        _checkpoint(credentialId);
    }

    function _checkpoint(bytes32 credentialId) internal {
        Mandate storage m = _mandates[credentialId];
        IAaveV4HubLike hub = IAaveV4HubLike(m.hub);
        bool inWindow = _inWindow(m);

        uint256[] storage set = _assetIds[credentialId];
        uint256 gross = grossDeficitAccumulatedRay[credentialId];
        uint256 n = set.length;

        for (uint256 i; i < n; ++i) {
            uint256 assetId = set[i];
            uint256 d = hub.getSpokeDeficitRay(assetId, m.spoke);
            uint256 last = lastObservedDeficitRay[credentialId][assetId];
            if (d != last) {
                if (d > last && inWindow) gross += d - last;
                lastObservedDeficitRay[credentialId][assetId] = d;
            }
        }
        if (gross != grossDeficitAccumulatedRay[credentialId]) {
            grossDeficitAccumulatedRay[credentialId] = gross;
        }
        emit DeficitCheckpointed(credentialId, gross);

        // Limb 2, evaluated on post-accumulation gross: the DAO may zero the
        // line in the same block the loss lands.
        for (uint256 i; i < n; ++i) {
            uint256 assetId = set[i];
            uint256 drawCap = hub.getSpokeConfig(assetId, m.spoke).drawCap;
            if (drawCap > 0) {
                if (!capEverPositive[credentialId][assetId]) {
                    capEverPositive[credentialId][assetId] = true;
                }
            } else if (
                inWindow && sanctionObservedAt[credentialId] == 0
                    && capEverPositive[credentialId][assetId] && gross >= m.deficitFloorRay
            ) {
                sanctionObservedAt[credentialId] = uint64(block.timestamp);
                emit SanctionObserved(credentialId, assetId, gross);
            }
        }
    }

    function _inWindow(Mandate storage m) internal view returns (bool) {
        return block.timestamp >= m.mandateStart
            && (m.mandateEnd == 0 || block.timestamp <= m.mandateEnd);
    }

    // ------------------------------------------------------------ predicate

    /// @notice Gross deficit provable right now: the checkpointed accumulator
    ///         plus, while inside the mandate window, un-checkpointed
    ///         increases visible on the hub.
    function projectedGrossDeficitRay(bytes32 credentialId) public view returns (uint256 gross) {
        Mandate storage m = _mandates[credentialId];
        gross = grossDeficitAccumulatedRay[credentialId];
        if (m.hub == address(0) || !_inWindow(m)) return gross;

        IAaveV4HubLike hub = IAaveV4HubLike(m.hub);
        uint256[] storage set = _assetIds[credentialId];
        uint256 n = set.length;
        for (uint256 i; i < n; ++i) {
            uint256 d = hub.getSpokeDeficitRay(set[i], m.spoke);
            uint256 last = lastObservedDeficitRay[credentialId][set[i]];
            if (d > last) gross += d - last;
        }
    }

    /// @notice Limb-2 projection: sanction provable right now — a recorded
    ///         armed sanction, or (in-window) a live zero drawCap on an asset
    ///         whose line was previously observed positive while the
    ///         projected gross stands at/above the floor. The ever-positive
    ///         record comes only from checkpoints: a line that was zeroed
    ///         before any observation cannot arm the limb.
    function sanctionProvable(bytes32 credentialId) public view returns (bool) {
        if (sanctionObservedAt[credentialId] != 0) return true;
        Mandate storage m = _mandates[credentialId];
        if (m.hub == address(0) || !_inWindow(m)) return false;
        if (projectedGrossDeficitRay(credentialId) < m.deficitFloorRay) return false;

        IAaveV4HubLike hub = IAaveV4HubLike(m.hub);
        uint256[] storage set = _assetIds[credentialId];
        uint256 n = set.length;
        for (uint256 i; i < n; ++i) {
            if (
                capEverPositive[credentialId][set[i]]
                    && hub.getSpokeConfig(set[i], m.spoke).drawCap == 0
            ) return true;
        }
        return false;
    }

    /// @notice True once the credential has a pinned hub/spoke and a nonempty
    ///         asset scope. Consumers SHOULD require this — an unconfigured
    ///         trigger of this class can never latch.
    function isConfigured(bytes32 credentialId) public view returns (bool) {
        return _mandates[credentialId].hub != address(0) && _assetIds[credentialId].length != 0;
    }

    function mandate(bytes32 credentialId) external view returns (Mandate memory) {
        return _mandates[credentialId];
    }

    function assetIds(bytes32 credentialId) external view returns (uint256[] memory) {
        return _assetIds[credentialId];
    }

    /// @notice Immutable binding data, ITriggerClass-shape: chain id, pinned
    ///         hub + spoke, both limbs' thresholds (asset units × RAY, no
    ///         rounding), window in unix seconds, append-only asset scope.
    function binding(bytes32 credentialId) external view returns (bytes memory) {
        Mandate storage m = _mandates[credentialId];
        return abi.encode(
            block.chainid,
            m.hub,
            m.spoke,
            m.thresholdRay,
            m.deficitFloorRay,
            m.mandateStart,
            m.mandateEnd,
            _assetIds[credentialId]
        );
    }

    // ------------------------------------------------- IDisclosureTrigger

    /// @inheritdoc IDisclosureTrigger
    function isTriggerable(bytes32 credentialId) public view returns (bool) {
        if (_triggeredAt[credentialId] != 0) return false; // already latched
        if (!isConfigured(credentialId)) return false;
        if (projectedGrossDeficitRay(credentialId) >= _mandates[credentialId].thresholdRay) {
            return true;
        }
        return sanctionProvable(credentialId);
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
    /// @dev Latch materialises: it runs a checkpoint first (which may itself
    ///      arm limb 2), so a single permissionless call proves and latches.
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
