// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    ISealedEntityCredentialRegistry,
    IDisclosureTrigger
} from "./ISealedEntityCredential.sol";

/// @dev Minimal Wildcat market surface consumed by the trigger. Mirrored from
///      wildcat-finance/v2-protocol (`WildcatMarketBase.currentState()` +
///      the immutable `delinquencyGracePeriod`). The `MarketState` struct is
///      reproduced field-for-field so this interface decodes a real market's
///      return on a fork; the trigger reads only `timeDelinquent`.
///
///      `currentState()` returns the market's state accrued to the current
///      block — `timeDelinquent` reflects elapsed delinquency without any
///      poking transaction — so this trigger needs no checkpoint of its own.
interface IWildcatMarketLike {
    struct MarketState {
        bool isClosed;
        uint128 maxTotalSupply;
        uint128 accruedProtocolFees;
        uint128 normalizedUnclaimedWithdrawals;
        uint104 scaledTotalSupply;
        uint104 scaledPendingWithdrawals;
        uint32 pendingWithdrawalExpiry;
        bool isDelinquent;
        uint32 timeDelinquent;
        uint16 protocolFeeBips;
        uint16 annualInterestBips;
        uint16 reserveRatioBips;
        uint112 scaleFactor;
        uint32 lastInterestAccruedTimestamp;
    }

    function currentState() external view returns (MarketState memory);
    function delinquencyGracePeriod() external view returns (uint256);
}

/// @title  WildcatDelinquencyTrigger
/// @notice IDisclosureTrigger implementing the class
///         keccak256("WILDCAT_DELINQ_V1"):
///         latches for a borrower credential when the bound Wildcat market's
///         penalised delinquency — `timeDelinquent` beyond the market's
///         `delinquencyGracePeriod` — has run for a further `graceExtension`
///         seconds. The canonical "90 days past grace" predicate the ERC
///         cites as `WILDCAT_DELINQ_90D_V1` is this class with
///         `graceExtension = 90 days`.
///
/// @dev    A PURE-READ TRIGGER — the simplest shape in the suite. Wildcat
///         maintains `timeDelinquent` as first-class market state: it counts
///         up while the market sits below its liquidity requirement and
///         decays while healthy, and `currentState()` projects it to the
///         current block. The predicate is therefore a single live read:
///         `timeDelinquent > delinquencyGracePeriod + graceExtension`. No
///         accumulator, no checkpoint, no oracle.
///
///         NOT MONOTONE — AND THAT IS CORRECT. Unlike the realised-loss
///         triggers, `timeDelinquent` falls when the borrower cures. A
///         borrower who returns the market to health before crossing
///         `grace + graceExtension` is never triggerable — curing in time is
///         exactly not-defaulting, and the predicate must let them off. Once
///         the threshold IS crossed and anyone latches, the latch is
///         permanent: a later cure cannot un-disclose a default that already
///         happened. The gap between "provable" and "latched" is closed the
///         usual way — the latch is permissionless, so any watcher fixes the
///         fact the moment it is true.
///
///         NO MANDATE WINDOW. The other triggers window loss attribution to
///         a mandate period; a borrower default is not a windowed metric but
///         a live condition over the life of the obligation, so this trigger
///         has none — the credential's own expiry/supersession bounds it,
///         per the ERC's continuing-eligibility rule.
///
///         The latch proves the predicate — penalised delinquency past the
///         configured extension — not insolvency, cause, or legal default.
contract WildcatDelinquencyTrigger is IDisclosureTrigger {
    bytes32 public constant TRIGGER_CLASS = keccak256("WILDCAT_DELINQ_V1");

    ISealedEntityCredentialRegistry public immutable registry;

    struct Mandate {
        address market;         // canonical Wildcat market, pinned at configure
        uint32 graceExtension;  // seconds past delinquencyGracePeriod that latch
    }

    mapping(bytes32 => Mandate) internal _mandates;
    mapping(bytes32 => uint64) internal _triggeredAt;

    event MandateConfigured(bytes32 indexed credentialId, address indexed market, uint32 graceExtension);

    error NotAttestor();
    error AlreadyConfigured();
    error InvalidMandate();
    error NotTriggerable();

    constructor(address _registry) {
        registry = ISealedEntityCredentialRegistry(_registry);
    }

    // ------------------------------------------------------------- binding

    /// @notice Pin the mandate: the market and the grace extension.
    ///         Attestor-only, one-shot. `graceExtension` MAY be zero (latch
    ///         the instant delinquency passes the market's own grace period).
    function configure(bytes32 credentialId, address market, uint32 graceExtension) external {
        if (msg.sender != registry.getCredential(credentialId).attestor) revert NotAttestor();
        if (_mandates[credentialId].market != address(0)) revert AlreadyConfigured();
        if (market == address(0)) revert InvalidMandate();
        _mandates[credentialId] = Mandate({market: market, graceExtension: graceExtension});
        emit MandateConfigured(credentialId, market, graceExtension);
    }

    // ------------------------------------------------------------ predicate

    /// @notice Current penalised-delinquency seconds and the latch threshold,
    ///         both read live from the market.
    function delinquency(bytes32 credentialId)
        public
        view
        returns (uint256 timeDelinquent, uint256 threshold)
    {
        Mandate storage m = _mandates[credentialId];
        if (m.market == address(0)) return (0, 0);
        IWildcatMarketLike mkt = IWildcatMarketLike(m.market);
        timeDelinquent = mkt.currentState().timeDelinquent;
        threshold = mkt.delinquencyGracePeriod() + m.graceExtension;
    }

    function isConfigured(bytes32 credentialId) public view returns (bool) {
        return _mandates[credentialId].market != address(0);
    }

    function mandate(bytes32 credentialId) external view returns (Mandate memory) {
        return _mandates[credentialId];
    }

    /// @notice Immutable binding data, ITriggerClass-shape: chain id, pinned
    ///         market, grace extension in seconds.
    function binding(bytes32 credentialId) external view returns (bytes memory) {
        Mandate storage m = _mandates[credentialId];
        return abi.encode(block.chainid, m.market, m.graceExtension);
    }

    // ------------------------------------------------- IDisclosureTrigger

    /// @inheritdoc IDisclosureTrigger
    function isTriggerable(bytes32 credentialId) public view returns (bool) {
        if (_triggeredAt[credentialId] != 0) return false;
        if (!isConfigured(credentialId)) return false;
        (uint256 timeDelinquent, uint256 threshold) = delinquency(credentialId);
        return timeDelinquent > threshold;
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
    function latch(bytes32 credentialId) external {
        if (!isTriggerable(credentialId)) revert NotTriggerable();
        _triggeredAt[credentialId] = uint64(block.timestamp);
        emit DisclosureTriggered(credentialId, uint64(block.timestamp));
    }

    /// @inheritdoc IDisclosureTrigger
    function triggerClass() external pure returns (bytes32) {
        return TRIGGER_CLASS;
    }
}
