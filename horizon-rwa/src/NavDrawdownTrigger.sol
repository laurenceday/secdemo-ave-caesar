// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    ISealedEntityCredentialRegistry,
    IDisclosureTrigger
} from "./ISealedEntityCredential.sol";

/// @dev AggregatorV3 read surface. VERIFIED (docs/HORIZON-READ.md): the
///      Chainlink NAVLink feeds and Superstate's realtime NAV oracle expose
///      this; the Horizon oracle ADAPTERS do not (latestRoundData reverts) —
///      bind the NAVLink aggregator, not the adapter.
interface IAggregatorV3Like {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

/// @title  NavDrawdownTrigger
/// @notice IDisclosureTrigger implementing the class
///         keccak256("RWA_NAV_DRAWDOWN_BPS_V1"):
///         latches for an RWA issuer credential when EITHER
///         limb A — NAV per share, read from the pinned feed, breaches a
///         drawdown from the checkpointed high-water mark of at least the
///         threshold (integer basis points of HWM, floor rounding) AND the
///         feed CONFIRMS the breach with a later print at least
///         `confirmationWindow` seconds after the breach was first observed;
///         OR
///         limb B — the pinned feed goes dark: no fresh update for longer
///         than `staleCap`, measured from an in-window observation of
///         staleness. A permanently dark valuation feed is itself a
///         disclosure-worthy failure for an RWA.
///
/// @dev    ORACLE EXCEPTION, STATED DELIBERATELY: base ERC triggers avoid
///         oracles. This class pins Chainlink NAVLink — Horizon's canonical
///         valuation source, which the venue itself liquidates against.
///         Pinning the same feed inherits a trust assumption the venue
///         already carries rather than adding one. That is the rationale,
///         verbatim, and it is the exception's boundary: a consumer that
///         does not already trust the pinned feed should not accept this
///         class.
///
///         CONFIRMATION, NOT INSTANT PERMANENCE: NAV is a reported figure,
///         and a single misprint should not become a permanent latchable
///         fact the moment one checkpoint sees it. A threshold breach
///         therefore ARMS rather than latches, recording the feed round
///         (`updatedAt`) that armed it. It is confirmed only by a SECOND,
///         DISTINCT fresh in-window round — `updatedAt` strictly greater
///         than the arming round and at least `confirmationWindow` seconds
///         later IN THE FEED'S OWN CLOCK — still at/below the threshold.
///         Confirmation is thus feed-timestamp-based, not observer-clock
///         based: a watcher cannot confirm early by waiting, and the same
///         round re-checkpointed never confirms; the feed itself must print
///         the breach a second time. A fresh round back above the threshold
///         before confirmation clears the arm — a corrected misprint or a
///         genuine recovery never latches. ONCE CONFIRMED the fact is
///         permanent: recovery, revision, or a new all-time high cannot cure
///         a confirmed drawdown pre-latch, exactly like the deficit
///         accumulators in the sibling projects. And the dodge is covered:
///         an issuer who silences the feed to avoid printing the second
///         round walks into limb B — darkness — instead.
///
///         FEED PINNING: the binding stores one immutable feed address. For
///         Chainlink proxies, pin the UNDERLYING aggregator (proxy
///         `aggregator()` at binding time) — a phase rotation or feed
///         migration is a new trust object and requires a new credential
///         binding; this trigger never follows proxies silently.
///
///         MEASUREMENT: drawdown is a ratio, so feed decimals cancel out of
///         the predicate entirely; decimals are recorded in binding data for
///         reference. HWM ratchets upward at in-window checkpoints. Floor
///         rounding on the bps division biases toward the subject. A dip
///         that recovers before ANY checkpoint observes it is missed — the
///         poke-cadence caveat; watchtowers SHOULD checkpoint on every feed
///         update (arming, confirming, and clearing are all
///         observation-bound).
///
///         STALENESS: a checkpoint that finds the feed stale (`updatedAt`
///         older than `stalenessBound`, or a non-positive answer) records
///         nothing toward HWM, breach, or confirmation — a stale print is
///         not a valuation. It arms the darkness clock instead; a fresh
///         observation clears the clock. Darkness duration is capped at
///         `mandateEnd`: a feed that goes dark near expiry can only accrue
///         in-window darkness.
contract NavDrawdownTrigger is IDisclosureTrigger {
    bytes32 public constant TRIGGER_CLASS = keccak256("RWA_NAV_DRAWDOWN_BPS_V1");
    uint256 internal constant BPS = 10_000;

    ISealedEntityCredentialRegistry public immutable registry;

    struct Mandate {
        address feed;              // pinned aggregator (NOT a proxy), AggregatorV3 shape
        uint16 thresholdBps;       // limb-A drawdown threshold, integer bps of HWM
        uint32 confirmationWindow; // min feed-clock seconds between arming round and confirming round
        uint32 stalenessBound;     // seconds after which a print no longer counts as fresh
        uint32 staleCap;           // limb-B: darkness longer than this latches
        uint64 mandateStart;
        uint64 mandateEnd;         // 0 = open-ended
        uint8 feedDecimals;        // recorded at configure, reference only (bps cancels decimals)
    }

    mapping(bytes32 => Mandate) internal _mandates;
    mapping(bytes32 => uint256) public highWaterNav;           // HWM, feed units
    mapping(bytes32 => uint256) public maxDrawdownBpsObserved; // reporting ratchet
    mapping(bytes32 => uint256) public armedRoundUpdatedAt;    // arming round's updatedAt (0 = not armed)
    mapping(bytes32 => bool) public drawdownConfirmed;         // limb A confirmed permanently
    mapping(bytes32 => uint64) public staleSince;              // darkness clock (0 = feed alive)
    mapping(bytes32 => bool) public darknessObserved;          // limb B armed permanently
    mapping(bytes32 => uint64) internal _triggeredAt;

    event MandateConfigured(
        bytes32 indexed credentialId,
        address indexed feed,
        uint16 thresholdBps,
        uint32 confirmationWindow,
        uint32 stalenessBound,
        uint32 staleCap,
        uint64 mandateStart,
        uint64 mandateEnd
    );
    event NavCheckpointed(
        bytes32 indexed credentialId, uint256 nav, uint256 highWaterNav, uint256 maxDrawdownBpsObserved
    );
    event DrawdownBreachArmed(bytes32 indexed credentialId, uint256 drawdownBps, uint256 armedRoundUpdatedAt);
    event DrawdownBreachCleared(bytes32 indexed credentialId);
    event DrawdownConfirmed(bytes32 indexed credentialId, uint256 drawdownBps);
    event FeedDarknessArmed(bytes32 indexed credentialId, uint64 staleSince);

    error NotAttestor();
    error AlreadyConfigured();
    error NotConfigured();
    error InvalidMandate();
    error NotTriggerable();

    constructor(address _registry) {
        registry = ISealedEntityCredentialRegistry(_registry);
    }

    // ------------------------------------------------------------- binding

    /// @notice Pin the mandate: feed, drawdown threshold, confirmation
    ///         window, staleness bound, darkness cap, window. Attestor-only,
    ///         one-shot. The HWM baselines at the first fresh in-window
    ///         checkpoint — attestors SHOULD checkpoint immediately after
    ///         configuring. `confirmationWindow` MAY be zero: confirmation
    ///         then requires only that the feed prints the breach in a
    ///         SECOND, distinct round (`updatedAt` strictly greater than the
    ///         arming round).
    function configure(
        bytes32 credentialId,
        address feed,
        uint16 thresholdBps,
        uint32 confirmationWindow,
        uint32 stalenessBound,
        uint32 staleCap,
        uint64 mandateStart,
        uint64 mandateEnd
    ) external {
        if (msg.sender != registry.getCredential(credentialId).attestor) revert NotAttestor();
        if (_mandates[credentialId].feed != address(0)) revert AlreadyConfigured();
        if (feed == address(0)) revert InvalidMandate();
        if (thresholdBps == 0 || thresholdBps >= BPS) revert InvalidMandate();
        if (stalenessBound == 0 || staleCap == 0) revert InvalidMandate();
        if (mandateEnd != 0 && mandateEnd <= mandateStart) revert InvalidMandate();

        _mandates[credentialId] = Mandate({
            feed: feed,
            thresholdBps: thresholdBps,
            confirmationWindow: confirmationWindow,
            stalenessBound: stalenessBound,
            staleCap: staleCap,
            mandateStart: mandateStart,
            mandateEnd: mandateEnd,
            feedDecimals: IAggregatorV3Like(feed).decimals()
        });
        emit MandateConfigured(
            credentialId,
            feed,
            thresholdBps,
            confirmationWindow,
            stalenessBound,
            staleCap,
            mandateStart,
            mandateEnd
        );
    }

    // ---------------------------------------------------------- checkpoint

    /// @notice Permissionless. Fresh in-window print: ratchet HWM, arm /
    ///         confirm / clear the breach, clear the darkness clock. Stale
    ///         print: record nothing toward valuation, arm the darkness
    ///         clock, and set the permanent limb-B fact once in-window
    ///         darkness exceeds the cap. Out-of-window checkpoints observe
    ///         nothing except feed recovery (clearing darkness only ever
    ///         helps the subject).
    function checkpoint(bytes32 credentialId) public {
        if (_mandates[credentialId].feed == address(0)) revert NotConfigured();
        _checkpoint(credentialId);
    }

    function _checkpoint(bytes32 credentialId) internal {
        Mandate storage m = _mandates[credentialId];
        (bool fresh, uint256 nav, uint256 updatedAt) = _read(m);

        if (!fresh) {
            uint64 since = staleSince[credentialId];
            if (since == 0) {
                if (_inWindow(m)) {
                    staleSince[credentialId] = uint64(block.timestamp);
                    emit FeedDarknessArmed(credentialId, uint64(block.timestamp));
                }
            } else if (!darknessObserved[credentialId] && _darkPastCap(m, since)) {
                darknessObserved[credentialId] = true;
            }
            return;
        }

        staleSince[credentialId] = 0; // feed alive again; armed darknessObserved stays

        if (!_inWindow(m)) return;

        uint256 hwm = highWaterNav[credentialId];
        uint256 dd;
        if (nav > hwm) {
            highWaterNav[credentialId] = nav;
            hwm = nav;
        } else if (hwm != 0) {
            dd = ((hwm - nav) * BPS) / hwm; // floor: biases toward the subject
            if (dd > maxDrawdownBpsObserved[credentialId]) {
                maxDrawdownBpsObserved[credentialId] = dd;
            }
        }
        emit NavCheckpointed(credentialId, nav, hwm, maxDrawdownBpsObserved[credentialId]);

        if (dd >= m.thresholdBps) {
            uint256 armedRound = armedRoundUpdatedAt[credentialId];
            if (armedRound == 0) {
                armedRoundUpdatedAt[credentialId] = updatedAt;
                emit DrawdownBreachArmed(credentialId, dd, updatedAt);
            } else if (
                !drawdownConfirmed[credentialId]
                    && _confirms(m.confirmationWindow, armedRound, updatedAt)
            ) {
                drawdownConfirmed[credentialId] = true;
                emit DrawdownConfirmed(credentialId, dd);
            }
        } else if (armedRoundUpdatedAt[credentialId] != 0 && !drawdownConfirmed[credentialId]) {
            // A fresh round back above the threshold before confirmation: a
            // corrected misprint or a genuine recovery. The arm clears.
            armedRoundUpdatedAt[credentialId] = 0;
            emit DrawdownBreachCleared(credentialId);
        }
    }

    /// @dev A round confirms an armed breach iff it is a STRICTLY LATER feed
    ///      round than the arming round (the feed printed the breach twice)
    ///      and the two rounds are at least `confirmationWindow` apart in the
    ///      feed's own clock. When `confirmationWindow` is zero this reduces
    ///      to "a distinct later round".
    function _confirms(uint32 confirmationWindow, uint256 armedRound, uint256 updatedAt)
        internal
        pure
        returns (bool)
    {
        return updatedAt > armedRound && updatedAt - armedRound >= confirmationWindow;
    }

    function _read(Mandate storage m)
        internal
        view
        returns (bool fresh, uint256 nav, uint256 updatedAt)
    {
        int256 answer;
        (, answer,, updatedAt,) = IAggregatorV3Like(m.feed).latestRoundData();
        if (answer <= 0 || updatedAt + m.stalenessBound < block.timestamp) return (false, 0, updatedAt);
        return (true, uint256(answer), updatedAt);
    }

    function _inWindow(Mandate storage m) internal view returns (bool) {
        return block.timestamp >= m.mandateStart
            && (m.mandateEnd == 0 || block.timestamp <= m.mandateEnd);
    }

    /// @dev In-window darkness duration: from `since` to now, capped at
    ///      mandateEnd — darkness accrued after expiry is not the subject's.
    function _darkPastCap(Mandate storage m, uint64 since) internal view returns (bool) {
        uint256 until = block.timestamp;
        if (m.mandateEnd != 0 && m.mandateEnd < until) until = m.mandateEnd;
        return until > since && until - since > m.staleCap;
    }

    // ------------------------------------------------------------ predicate

    /// @notice Reporting view: the recorded maximum drawdown, or the current
    ///         fresh in-window print against the stored HWM if larger.
    function projectedDrawdownBps(bytes32 credentialId) public view returns (uint256 dd) {
        Mandate storage m = _mandates[credentialId];
        dd = maxDrawdownBpsObserved[credentialId];
        if (m.feed == address(0) || !_inWindow(m)) return dd;
        uint256 hwm = highWaterNav[credentialId];
        if (hwm == 0) return dd;
        (bool fresh, uint256 nav,) = _read(m);
        if (fresh && nav < hwm) {
            uint256 live = ((hwm - nav) * BPS) / hwm;
            if (live > dd) dd = live;
        }
    }

    /// @notice Limb-A projection: a confirmed breach, or an armed breach that
    ///         the live round confirms right now (fresh, in-window, a
    ///         strictly later round at least `confirmationWindow` past the
    ///         arming round, still at/below threshold). An unarmed or cleared
    ///         breach is never provable — arming is observation-bound.
    function drawdownProvable(bytes32 credentialId) public view returns (bool) {
        if (drawdownConfirmed[credentialId]) return true;
        Mandate storage m = _mandates[credentialId];
        uint256 armedRound = armedRoundUpdatedAt[credentialId];
        if (m.feed == address(0) || armedRound == 0 || !_inWindow(m)) return false;
        uint256 hwm = highWaterNav[credentialId];
        if (hwm == 0) return false;
        (bool fresh, uint256 nav, uint256 updatedAt) = _read(m);
        if (!fresh || nav >= hwm) return false;
        if (((hwm - nav) * BPS) / hwm < m.thresholdBps) return false;
        return _confirms(m.confirmationWindow, armedRound, updatedAt);
    }

    /// @notice Limb-B projection: recorded darkness, or an armed clock whose
    ///         in-window duration exceeds the cap while the feed is still
    ///         stale right now (a recovered feed cannot be projected dark).
    function darknessProvable(bytes32 credentialId) public view returns (bool) {
        if (darknessObserved[credentialId]) return true;
        Mandate storage m = _mandates[credentialId];
        uint64 since = staleSince[credentialId];
        if (m.feed == address(0) || since == 0) return false;
        (bool fresh,,) = _read(m);
        return !fresh && _darkPastCap(m, since);
    }

    function isConfigured(bytes32 credentialId) public view returns (bool) {
        return _mandates[credentialId].feed != address(0);
    }

    function mandate(bytes32 credentialId) external view returns (Mandate memory) {
        return _mandates[credentialId];
    }

    /// @notice Immutable binding data, ITriggerClass-shape: chain id, pinned
    ///         feed + its decimals (reference), threshold in integer bps
    ///         (floor rounding), confirmation window and staleness bounds in
    ///         seconds, window in unix seconds.
    function binding(bytes32 credentialId) external view returns (bytes memory) {
        Mandate storage m = _mandates[credentialId];
        return abi.encode(
            block.chainid,
            m.feed,
            m.feedDecimals,
            m.thresholdBps,
            m.confirmationWindow,
            m.stalenessBound,
            m.staleCap,
            m.mandateStart,
            m.mandateEnd
        );
    }

    // ------------------------------------------------- IDisclosureTrigger

    /// @inheritdoc IDisclosureTrigger
    function isTriggerable(bytes32 credentialId) public view returns (bool) {
        if (_triggeredAt[credentialId] != 0) return false;
        if (_mandates[credentialId].feed == address(0)) return false;
        if (drawdownProvable(credentialId)) return true;
        return darknessProvable(credentialId);
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
    /// @dev Latch materialises: it runs a checkpoint first, so a single
    ///      permissionless call records the confirming (or darkness)
    ///      observation it latches on.
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
