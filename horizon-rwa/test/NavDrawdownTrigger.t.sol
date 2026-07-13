// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NavDrawdownTrigger} from "../src/NavDrawdownTrigger.sol";
import {MockSealedRegistry, MockNavFeed} from "./mocks/Mocks.sol";

contract NavDrawdownTriggerTest is Test {
    // 500 bps (5%) drawdown; a breach must be confirmed by a second feed
    // round at least 1 hour later; a print is fresh for 2 days; a feed dark
    // for more than 10 days latches on the darkness limb.
    uint16 constant THRESHOLD_BPS = 500;
    uint32 constant CONFIRMATION = 1 hours;
    uint32 constant STALENESS = 2 days;
    uint32 constant STALE_CAP = 10 days;

    bytes32 constant CRED = keccak256("rwa-issuer-credential");
    address constant ATTESTOR = address(0xA77E5);

    MockSealedRegistry registry;
    NavDrawdownTrigger trigger;
    MockNavFeed feed;

    uint64 mandateStart;

    function setUp() public {
        vm.warp(1_752_000_000); // sane clock for staleness/confirmation arithmetic

        registry = new MockSealedRegistry();
        trigger = new NavDrawdownTrigger(address(registry));
        feed = new MockNavFeed();

        address[] memory trigs = new address[](1);
        trigs[0] = address(trigger);
        bytes32[] memory classes = new bytes32[](1);
        classes[0] = trigger.TRIGGER_CLASS();
        registry.setCredential(
            CRED, keccak256("entity/v1"), ATTESTOR, uint64(block.timestamp), 0, false, trigs, classes
        );

        mandateStart = uint64(block.timestamp);
        // USTB-like NAV: $10.000000 at 6 decimals, freshly printed.
        feed.set(10_000_000, block.timestamp);
    }

    function _configure(uint64 start, uint64 end) internal {
        vm.prank(ATTESTOR);
        trigger.configure(
            CRED, address(feed), THRESHOLD_BPS, CONFIRMATION, STALENESS, STALE_CAP, start, end
        );
    }

    /// @dev Print `nav` fresh at the current block time.
    function _print(uint256 nav) internal {
        feed.set(int256(nav), block.timestamp);
    }

    // --------------------------------------------------------- configuring

    function test_configure_gating_oneShot_degenerates() public {
        vm.expectRevert(NavDrawdownTrigger.NotAttestor.selector);
        trigger.configure(
            CRED, address(feed), THRESHOLD_BPS, CONFIRMATION, STALENESS, STALE_CAP, mandateStart, 0
        );

        vm.startPrank(ATTESTOR);
        vm.expectRevert(NavDrawdownTrigger.InvalidMandate.selector);
        trigger.configure(CRED, address(0), THRESHOLD_BPS, CONFIRMATION, STALENESS, STALE_CAP, mandateStart, 0);
        vm.expectRevert(NavDrawdownTrigger.InvalidMandate.selector);
        trigger.configure(CRED, address(feed), 0, CONFIRMATION, STALENESS, STALE_CAP, mandateStart, 0);
        vm.expectRevert(NavDrawdownTrigger.InvalidMandate.selector);
        trigger.configure(CRED, address(feed), 10_000, CONFIRMATION, STALENESS, STALE_CAP, mandateStart, 0);
        vm.expectRevert(NavDrawdownTrigger.InvalidMandate.selector);
        trigger.configure(CRED, address(feed), THRESHOLD_BPS, CONFIRMATION, 0, STALE_CAP, mandateStart, 0);
        vm.expectRevert(NavDrawdownTrigger.InvalidMandate.selector);
        trigger.configure(CRED, address(feed), THRESHOLD_BPS, CONFIRMATION, STALENESS, 0, mandateStart, 0);

        trigger.configure(
            CRED, address(feed), THRESHOLD_BPS, CONFIRMATION, STALENESS, STALE_CAP, mandateStart, 0
        );
        assertEq(trigger.mandate(CRED).feedDecimals, 6, "decimals recorded at configure");
        vm.expectRevert(NavDrawdownTrigger.AlreadyConfigured.selector);
        trigger.configure(
            CRED, address(feed), THRESHOLD_BPS, CONFIRMATION, STALENESS, STALE_CAP, mandateStart, 0
        );
        vm.stopPrank();
    }

    function test_unconfigured_isInert() public {
        assertFalse(trigger.isConfigured(CRED));
        assertFalse(trigger.isTriggerable(CRED));
        vm.expectRevert(NavDrawdownTrigger.NotConfigured.selector);
        trigger.checkpoint(CRED);
        vm.expectRevert(NavDrawdownTrigger.NotTriggerable.selector);
        trigger.latch(CRED);
    }

    // ------------------------------------------------------- HWM + drawdown

    function test_hwm_baselinesAtFirstFreshCheckpoint_ratchetsUpOnly() public {
        _configure(mandateStart, 0);
        trigger.checkpoint(CRED);
        assertEq(trigger.highWaterNav(CRED), 10_000_000, "baseline at first fresh print");

        _print(10_500_000);
        trigger.checkpoint(CRED);
        assertEq(trigger.highWaterNav(CRED), 10_500_000, "ratchets up");

        _print(10_200_000);
        trigger.checkpoint(CRED);
        assertEq(trigger.highWaterNav(CRED), 10_500_000, "never down");
    }

    function test_drawdown_exactMath_floorRounding() public {
        _configure(mandateStart, 0);
        trigger.checkpoint(CRED); // HWM = 10.000000

        // 4.99..% down: (499999 * 10000) / 10000000 = 499.999 -> floor 499.
        _print(9_500_001);
        trigger.checkpoint(CRED);
        assertEq(trigger.maxDrawdownBpsObserved(CRED), 499, "floor biases toward subject");
        assertEq(trigger.armedRoundUpdatedAt(CRED), 0, "sub-threshold does not arm");
        assertFalse(trigger.isTriggerable(CRED));

        // Exactly 5% arms (but does not yet latch — see confirmation tests).
        _print(9_500_000);
        trigger.checkpoint(CRED);
        assertEq(trigger.maxDrawdownBpsObserved(CRED), 500);
        assertGt(trigger.armedRoundUpdatedAt(CRED), 0, "5% arms");
    }

    // ---------------------------------------------- confirmation semantics

    function test_breach_armsButDoesNotLatchAlone() public {
        _configure(mandateStart, 0);
        trigger.checkpoint(CRED); // HWM = 10.000000

        _print(9_000_000); // -10%
        trigger.checkpoint(CRED);
        assertGt(trigger.armedRoundUpdatedAt(CRED), 0, "armed");
        assertFalse(trigger.drawdownConfirmed(CRED), "not confirmed on one round");
        assertFalse(trigger.isTriggerable(CRED), "a single breach round cannot latch");
        vm.expectRevert(NavDrawdownTrigger.NotTriggerable.selector);
        trigger.latch(CRED);
    }

    function test_confirmation_secondDistinctRoundWindowApart_confirms() public {
        _configure(mandateStart, 0);
        trigger.checkpoint(CRED);

        _print(9_000_000); // arm at round updatedAt = T0
        trigger.checkpoint(CRED);
        uint256 armedRound = trigger.armedRoundUpdatedAt(CRED);

        // A second round, exactly CONFIRMATION later in the feed's clock,
        // still in breach: confirms.
        vm.warp(block.timestamp + CONFIRMATION);
        _print(9_000_000);
        assertGt(block.timestamp, armedRound);
        assertTrue(trigger.drawdownProvable(CRED), "provable on the confirming round (projection)");
        trigger.checkpoint(CRED);
        assertTrue(trigger.drawdownConfirmed(CRED), "confirmed");
        assertTrue(trigger.isTriggerable(CRED));
    }

    function test_confirmation_sameRoundNeverConfirms_feedClockNotObserverClock() public {
        _configure(mandateStart, 0);
        trigger.checkpoint(CRED);

        _print(9_000_000); // arm; updatedAt = T0, and the feed does not print again
        trigger.checkpoint(CRED);

        // Time passes and watchers re-checkpoint the SAME round repeatedly.
        // Observer-clock would confirm; feed-clock must not.
        vm.warp(block.timestamp + CONFIRMATION + 1 days);
        trigger.checkpoint(CRED);
        assertFalse(trigger.drawdownConfirmed(CRED), "same round cannot confirm itself");
        assertFalse(trigger.isTriggerable(CRED), "the feed must speak a second time");
    }

    function test_confirmation_belowWindow_doesNotConfirm() public {
        _configure(mandateStart, 0);
        trigger.checkpoint(CRED);

        _print(9_000_000); // arm at T0
        trigger.checkpoint(CRED);

        // A distinct later round, but less than CONFIRMATION apart: no confirm.
        vm.warp(block.timestamp + CONFIRMATION / 2);
        _print(9_000_000);
        trigger.checkpoint(CRED);
        assertFalse(trigger.drawdownConfirmed(CRED), "too soon after the arming round");
        assertFalse(trigger.isTriggerable(CRED));

        // A further round past the window confirms.
        vm.warp(block.timestamp + CONFIRMATION);
        _print(9_000_000);
        trigger.checkpoint(CRED);
        assertTrue(trigger.drawdownConfirmed(CRED));
    }

    function test_misprint_recoveryBeforeConfirmation_clearsTheArm() public {
        _configure(mandateStart, 0);
        trigger.checkpoint(CRED);

        _print(9_000_000); // arm — a transient bad print
        trigger.checkpoint(CRED);
        assertGt(trigger.armedRoundUpdatedAt(CRED), 0);

        // Next round corrects back above threshold: the arm clears.
        vm.warp(block.timestamp + CONFIRMATION);
        _print(10_050_000);
        trigger.checkpoint(CRED);
        assertEq(trigger.armedRoundUpdatedAt(CRED), 0, "corrected misprint clears the arm");
        assertFalse(trigger.isTriggerable(CRED));

        // A genuine sustained breach later re-arms from scratch and confirms.
        _print(9_000_000);
        trigger.checkpoint(CRED);
        vm.warp(block.timestamp + CONFIRMATION);
        _print(9_000_000);
        trigger.checkpoint(CRED);
        assertTrue(trigger.drawdownConfirmed(CRED), "a real breach still confirms");
    }

    function test_recoveryAfterConfirmation_cannotCure() public {
        _configure(mandateStart, 0);
        trigger.checkpoint(CRED);

        _print(9_000_000);
        trigger.checkpoint(CRED); // arm
        vm.warp(block.timestamp + CONFIRMATION);
        _print(9_000_000);
        trigger.checkpoint(CRED); // confirm
        assertTrue(trigger.drawdownConfirmed(CRED));

        // Full recovery — even a new all-time high — cannot cure a CONFIRMED
        // drawdown.
        _print(12_000_000);
        trigger.checkpoint(CRED);
        assertTrue(trigger.isTriggerable(CRED), "confirmed drawdown is permanent");
        trigger.latch(CRED);
        assertTrue(trigger.isTriggered(CRED), "latched after full recovery");
    }

    function test_silenceToDodgeConfirmation_walksIntoDarkness() public {
        _configure(mandateStart, 0);
        trigger.checkpoint(CRED);

        _print(9_000_000); // arm, then go silent to avoid printing round two
        trigger.checkpoint(CRED);
        assertFalse(trigger.drawdownConfirmed(CRED));

        // Silence past the staleness bound arms the darkness clock...
        vm.warp(block.timestamp + STALENESS + 1);
        trigger.checkpoint(CRED);
        assertGt(trigger.staleSince(CRED), 0, "darkness armed by the silence");
        assertFalse(trigger.drawdownConfirmed(CRED), "drawdown still cannot confirm without a round");

        // ...and past the cap, the darkness limb latches: the dodge fails.
        vm.warp(block.timestamp + STALE_CAP + 1);
        assertTrue(trigger.isTriggerable(CRED), "silence latches via darkness");
        trigger.latch(CRED);
        assertTrue(trigger.isTriggered(CRED));
    }

    function test_unobservedDip_isMissed_documentedLimit() public {
        _configure(mandateStart, 0);
        trigger.checkpoint(CRED);

        // NAV dips 10% and recovers with no checkpoint in between.
        feed.set(9_000_000, block.timestamp);
        feed.set(10_000_000, block.timestamp);
        trigger.checkpoint(CRED);
        assertEq(trigger.armedRoundUpdatedAt(CRED), 0, "unobserved dip never armed");
        assertFalse(trigger.isTriggerable(CRED));
    }

    function test_window_outsideObservationsDoNotAttribute() public {
        uint64 end = uint64(block.timestamp + 30 days);
        _configure(mandateStart, end);
        trigger.checkpoint(CRED);

        vm.warp(end + 1);
        feed.set(8_000_000, block.timestamp); // -20% after mandate expiry
        trigger.checkpoint(CRED);
        assertEq(trigger.armedRoundUpdatedAt(CRED), 0, "post-mandate drawdown not armed");
        assertFalse(trigger.isTriggerable(CRED));
    }

    // ------------------------------------------------------ darkness limb

    function test_darkness_armsClearsAndLatches() public {
        _configure(mandateStart, 0);
        trigger.checkpoint(CRED);

        vm.warp(block.timestamp + 3 days); // last print now 3d old > 2d bound
        trigger.checkpoint(CRED);
        assertGt(trigger.staleSince(CRED), 0, "darkness armed");
        assertEq(trigger.highWaterNav(CRED), 10_000_000, "stale print moved nothing");
        assertFalse(trigger.isTriggerable(CRED), "not dark long enough yet");

        _print(10_100_000);
        trigger.checkpoint(CRED);
        assertEq(trigger.staleSince(CRED), 0, "fresh print clears the clock");

        vm.warp(block.timestamp + 3 days);
        trigger.checkpoint(CRED); // arms
        vm.warp(block.timestamp + STALE_CAP + 1);
        assertTrue(trigger.darknessProvable(CRED), "provable live");
        assertTrue(trigger.isTriggerable(CRED));
        vm.prank(address(0xDE9051709));
        trigger.latch(CRED);
        assertTrue(trigger.isTriggered(CRED), "a permanently dark feed is disclosure-worthy");
        assertTrue(trigger.darknessObserved(CRED), "latch materialised the darkness fact");
    }

    function test_darkness_recoveredFeedCannotBeProjectedDark() public {
        _configure(mandateStart, 0);
        trigger.checkpoint(CRED);
        vm.warp(block.timestamp + 3 days);
        trigger.checkpoint(CRED); // armed
        vm.warp(block.timestamp + STALE_CAP + 1);

        _print(10_050_000); // feed comes back before anyone latched
        assertFalse(trigger.darknessProvable(CRED), "live recovery defeats projection");
        assertFalse(trigger.isTriggerable(CRED));
    }

    function test_darkness_durationCappedAtMandateEnd() public {
        uint64 end = uint64(block.timestamp + 30 days);
        _configure(mandateStart, end);
        trigger.checkpoint(CRED);

        // Feed dies 5 days before expiry; cap is 10 days. Even a year later
        // the in-window darkness is only 5 days: not the subject's failure.
        vm.warp(end - 5 days);
        trigger.checkpoint(CRED); // stale (last print ~25d old), arms
        assertGt(trigger.staleSince(CRED), 0);
        vm.warp(end + 365 days);
        assertFalse(trigger.darknessProvable(CRED), "post-expiry darkness not attributed");
        assertFalse(trigger.isTriggerable(CRED));
    }

    // ------------------------------------------------------------- latching

    function test_latch_materialises_permanent() public {
        _configure(mandateStart, 0);
        trigger.checkpoint(CRED);

        _print(9_000_000);
        trigger.checkpoint(CRED); // arm
        vm.warp(block.timestamp + CONFIRMATION);
        _print(9_000_000); // confirming round is live but no confirming checkpoint yet

        assertFalse(trigger.drawdownConfirmed(CRED), "nothing checkpointed the confirm yet");
        assertTrue(trigger.isTriggerable(CRED), "projection sees the confirming round");
        vm.prank(address(0xDE9051709));
        trigger.latch(CRED);
        assertTrue(trigger.drawdownConfirmed(CRED), "latch materialised the confirmation");

        _print(12_000_000);
        assertTrue(trigger.isTriggered(CRED), "no un-latch on recovery");
        vm.expectRevert(NavDrawdownTrigger.NotTriggerable.selector);
        trigger.latch(CRED);
    }

    // -------------------------------------------------------- binding view

    function test_binding_encodesTheFullMandate() public {
        _configure(mandateStart, 0);
        (
            uint256 chainId,
            address boundFeed,
            uint8 dec,
            uint16 thresholdBps,
            uint32 confirmation,
            uint32 staleness,
            uint32 staleCap,
            uint64 start,
            uint64 end
        ) = abi.decode(
            trigger.binding(CRED),
            (uint256, address, uint8, uint16, uint32, uint32, uint32, uint64, uint64)
        );
        assertEq(chainId, block.chainid);
        assertEq(boundFeed, address(feed));
        assertEq(dec, 6);
        assertEq(thresholdBps, THRESHOLD_BPS);
        assertEq(confirmation, CONFIRMATION);
        assertEq(staleness, STALENESS);
        assertEq(staleCap, STALE_CAP);
        assertEq(start, mandateStart);
        assertEq(end, 0);
    }
}
