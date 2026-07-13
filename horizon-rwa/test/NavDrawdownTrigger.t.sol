// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NavDrawdownTrigger} from "../src/NavDrawdownTrigger.sol";
import {MockSealedRegistry, MockNavFeed} from "./mocks/Mocks.sol";

contract NavDrawdownTriggerTest is Test {
    // 500 bps (5%) drawdown latches; a print is fresh for 2 days; a feed
    // dark for more than 10 days latches on the darkness limb.
    uint16 constant THRESHOLD_BPS = 500;
    uint32 constant STALENESS = 2 days;
    uint32 constant STALE_CAP = 10 days;

    bytes32 constant CRED = keccak256("rwa-issuer-credential");
    address constant ATTESTOR = address(0xA77E5);

    MockSealedRegistry registry;
    NavDrawdownTrigger trigger;
    MockNavFeed feed;

    uint64 mandateStart;

    function setUp() public {
        vm.warp(1_752_000_000); // sane clock for staleness arithmetic

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
        trigger.configure(CRED, address(feed), THRESHOLD_BPS, STALENESS, STALE_CAP, start, end);
    }

    // --------------------------------------------------------- configuring

    function test_configure_gating_oneShot_degenerates() public {
        vm.expectRevert(NavDrawdownTrigger.NotAttestor.selector);
        trigger.configure(CRED, address(feed), THRESHOLD_BPS, STALENESS, STALE_CAP, mandateStart, 0);

        vm.startPrank(ATTESTOR);
        vm.expectRevert(NavDrawdownTrigger.InvalidMandate.selector);
        trigger.configure(CRED, address(0), THRESHOLD_BPS, STALENESS, STALE_CAP, mandateStart, 0);
        vm.expectRevert(NavDrawdownTrigger.InvalidMandate.selector);
        trigger.configure(CRED, address(feed), 0, STALENESS, STALE_CAP, mandateStart, 0);
        vm.expectRevert(NavDrawdownTrigger.InvalidMandate.selector);
        trigger.configure(CRED, address(feed), 10_000, STALENESS, STALE_CAP, mandateStart, 0);
        vm.expectRevert(NavDrawdownTrigger.InvalidMandate.selector);
        trigger.configure(CRED, address(feed), THRESHOLD_BPS, 0, STALE_CAP, mandateStart, 0);
        vm.expectRevert(NavDrawdownTrigger.InvalidMandate.selector);
        trigger.configure(CRED, address(feed), THRESHOLD_BPS, STALENESS, 0, mandateStart, 0);

        trigger.configure(CRED, address(feed), THRESHOLD_BPS, STALENESS, STALE_CAP, mandateStart, 0);
        assertEq(trigger.mandate(CRED).feedDecimals, 6, "decimals recorded at configure");
        vm.expectRevert(NavDrawdownTrigger.AlreadyConfigured.selector);
        trigger.configure(CRED, address(feed), THRESHOLD_BPS, STALENESS, STALE_CAP, mandateStart, 0);
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

        feed.set(10_500_000, block.timestamp);
        trigger.checkpoint(CRED);
        assertEq(trigger.highWaterNav(CRED), 10_500_000, "ratchets up");

        feed.set(10_200_000, block.timestamp);
        trigger.checkpoint(CRED);
        assertEq(trigger.highWaterNav(CRED), 10_500_000, "never down");
    }

    function test_drawdown_exactMath_floorRounding_inclusiveThreshold() public {
        _configure(mandateStart, 0);
        trigger.checkpoint(CRED); // HWM = 10.000000

        // 4.99..% down: (499999 * 10000) / 10000000 = 499.999 -> floor 499.
        feed.set(9_500_001, block.timestamp);
        trigger.checkpoint(CRED);
        assertEq(trigger.maxDrawdownBpsObserved(CRED), 499, "floor biases toward subject");
        assertFalse(trigger.isTriggerable(CRED));
        vm.expectRevert(NavDrawdownTrigger.NotTriggerable.selector);
        trigger.latch(CRED);

        // Exactly 5%: 500 bps, inclusive.
        feed.set(9_500_000, block.timestamp);
        assertEq(trigger.projectedDrawdownBps(CRED), 500, "projection sees the live print");
        assertTrue(trigger.isTriggerable(CRED));
    }

    function test_recoveryAfterCheckpoint_cannotCure() public {
        _configure(mandateStart, 0);
        trigger.checkpoint(CRED);

        feed.set(9_000_000, block.timestamp); // -10%
        trigger.checkpoint(CRED);
        assertEq(trigger.maxDrawdownBpsObserved(CRED), 1000);

        // Full recovery — even a new all-time high — does not cure the
        // observed fact.
        feed.set(11_000_000, block.timestamp);
        trigger.checkpoint(CRED);
        assertEq(trigger.maxDrawdownBpsObserved(CRED), 1000, "observed drawdown is permanent");
        assertTrue(trigger.isTriggerable(CRED));
        trigger.latch(CRED);
        assertTrue(trigger.isTriggered(CRED), "latched after full recovery");
    }

    function test_unobservedDip_isMissed_documentedLimit() public {
        _configure(mandateStart, 0);
        trigger.checkpoint(CRED);

        // NAV dips 10% and recovers with no checkpoint in between.
        feed.set(9_000_000, block.timestamp);
        feed.set(10_000_000, block.timestamp);
        trigger.checkpoint(CRED);
        assertEq(trigger.maxDrawdownBpsObserved(CRED), 0, "unobserved dip is lost");
        assertFalse(trigger.isTriggerable(CRED));
    }

    function test_window_outsideObservationsDoNotAttribute() public {
        uint64 end = uint64(block.timestamp + 30 days);
        _configure(mandateStart, end);
        trigger.checkpoint(CRED);

        vm.warp(end + 1);
        feed.set(8_000_000, block.timestamp); // -20% after mandate expiry
        trigger.checkpoint(CRED);
        assertEq(trigger.maxDrawdownBpsObserved(CRED), 0, "post-mandate drawdown not attributed");
        assertFalse(trigger.isTriggerable(CRED));
    }

    // ------------------------------------------------------ darkness limb

    function test_darkness_armsClearsAndLatches() public {
        _configure(mandateStart, 0);
        trigger.checkpoint(CRED);

        // Feed goes dark: stale checkpoint arms the clock, records nothing
        // toward valuation.
        vm.warp(block.timestamp + 3 days); // last print now 3d old > 2d bound
        trigger.checkpoint(CRED);
        assertGt(trigger.staleSince(CRED), 0, "darkness armed");
        assertEq(trigger.highWaterNav(CRED), 10_000_000, "stale print moved nothing");
        assertFalse(trigger.isTriggerable(CRED), "not dark long enough yet");

        // Feed recovers: clock clears.
        feed.set(10_100_000, block.timestamp);
        trigger.checkpoint(CRED);
        assertEq(trigger.staleSince(CRED), 0, "fresh print clears the clock");

        // Dark again, past the cap this time.
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

        // The feed comes back before anyone latched: projection must flip
        // off even though no checkpoint has cleared the clock yet.
        feed.set(10_050_000, block.timestamp);
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

        feed.set(9_000_000, block.timestamp);
        assertEq(trigger.maxDrawdownBpsObserved(CRED), 0, "nothing checkpointed yet");
        assertTrue(trigger.isTriggerable(CRED), "projection sees the live print");
        vm.prank(address(0xDE9051709));
        trigger.latch(CRED);
        assertEq(trigger.maxDrawdownBpsObserved(CRED), 1000, "latch materialised");

        feed.set(12_000_000, block.timestamp);
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
            uint32 staleness,
            uint32 staleCap,
            uint64 start,
            uint64 end
        ) = abi.decode(
            trigger.binding(CRED),
            (uint256, address, uint8, uint16, uint32, uint32, uint64, uint64)
        );
        assertEq(chainId, block.chainid);
        assertEq(boundFeed, address(feed));
        assertEq(dec, 6);
        assertEq(thresholdBps, THRESHOLD_BPS);
        assertEq(staleness, STALENESS);
        assertEq(staleCap, STALE_CAP);
        assertEq(start, mandateStart);
        assertEq(end, 0);
    }
}
