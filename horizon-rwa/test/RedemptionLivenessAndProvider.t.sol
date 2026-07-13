// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NavDrawdownTrigger} from "../src/NavDrawdownTrigger.sol";
import {RedemptionLivenessTrigger} from "../src/RedemptionLivenessTrigger.sol";
import {RWAIssuerCredentialProvider} from "../src/RWAIssuerCredentialProvider.sol";
import {
    MockSealedRegistry,
    MockNavFeed,
    MockRedemption,
    MockLatchTrigger
} from "./mocks/Mocks.sol";

contract RedemptionLivenessAndProviderTest is Test {
    // Facility must hold ≥ 100,000 USTB of instant capacity; dry longer than
    // 7 days latches; paused longer than 30 days latches regardless.
    uint256 constant FLOOR = 100_000e6;
    uint32 constant DRY_DURATION = 7 days;
    uint32 constant PAUSE_CAP = 30 days;
    uint32 constant CONFIRMATION = 1 hours;

    bytes32 constant CRED = keccak256("rwa-issuer-credential");
    address constant ATTESTOR = address(0xA77E5);
    address constant ISSUER_WALLET = address(0xC0FFEE);
    address constant WATCHER = address(0xDE9051709);

    MockSealedRegistry registry;
    RedemptionLivenessTrigger liveness;
    NavDrawdownTrigger nav;
    RWAIssuerCredentialProvider provider;
    MockRedemption redemption;
    MockNavFeed feed;

    uint64 issuedAt;

    function setUp() public {
        vm.warp(1_752_000_000);

        registry = new MockSealedRegistry();
        liveness = new RedemptionLivenessTrigger(address(registry));
        nav = new NavDrawdownTrigger(address(registry));
        provider = new RWAIssuerCredentialProvider(address(registry));
        redemption = new MockRedemption();
        feed = new MockNavFeed();

        issuedAt = uint64(block.timestamp);
        // Credential binds BOTH classes (the Superstate shape).
        address[] memory trigs = new address[](2);
        trigs[0] = address(nav);
        trigs[1] = address(liveness);
        bytes32[] memory classes = new bytes32[](2);
        classes[0] = nav.TRIGGER_CLASS();
        classes[1] = liveness.TRIGGER_CLASS();
        registry.setCredential(
            CRED, keccak256("entity/v1"), ATTESTOR, issuedAt, 0, false, trigs, classes
        );
        registry.setWallet(ISSUER_WALLET, CRED);

        // Healthy world: fresh NAV, capacity comfortably above the floor.
        feed.set(11_144_444, block.timestamp);
        redemption.setCapacity(394_617e6);
        vm.startPrank(ATTESTOR);
        nav.configure(CRED, address(feed), 500, CONFIRMATION, 2 days, 10 days, issuedAt, 0);
        liveness.configure(CRED, address(redemption), FLOOR, DRY_DURATION, PAUSE_CAP, issuedAt, 0);
        vm.stopPrank();
        nav.checkpoint(CRED);
        liveness.checkpoint(CRED);
    }

    // ---------------------------------------------------------- dry clock

    function test_dry_armsSelfClearsAndLatches() public {
        // Capacity drains below the floor (big redemption day).
        redemption.setCapacity(50_000e6);
        liveness.checkpoint(CRED);
        assertGt(liveness.dryFirstObserved(CRED), 0, "dry armed");
        assertFalse(liveness.isTriggerable(CRED), "within the refill window");

        // Issuer tops the facility up: a healthy checkpoint clears.
        redemption.setCapacity(200_000e6);
        liveness.checkpoint(CRED);
        assertEq(liveness.dryFirstObserved(CRED), 0, "healthy observation clears");

        // Dry again — and this time nobody refills.
        redemption.setCapacity(10_000e6);
        liveness.checkpoint(CRED);
        vm.warp(block.timestamp + DRY_DURATION + 1);
        assertTrue(liveness.livenessFailureProvable(CRED), "dry past the bound");
        vm.prank(WATCHER);
        liveness.latch(CRED);
        assertTrue(liveness.isTriggered(CRED));
    }

    function test_dry_recoveredFacilityCannotBeProjectedFailed() public {
        redemption.setCapacity(10_000e6);
        liveness.checkpoint(CRED);
        vm.warp(block.timestamp + DRY_DURATION + 1);
        assertTrue(liveness.isTriggerable(CRED));

        // Facility refills before anyone latches: projection flips off even
        // though no checkpoint cleared the clock yet.
        redemption.setCapacity(150_000e6);
        assertFalse(liveness.isTriggerable(CRED), "live health defeats projection");
    }

    // -------------------------------------------------- pause carve-out

    function test_pause_carveOut_dryClockDoesNotRunWhilePaused() public {
        // A compliance pause arms the pause clock, not the dry clock.
        redemption.setPaused(true);
        liveness.checkpoint(CRED);
        assertGt(liveness.pauseFirstObserved(CRED), 0, "pause armed");
        assertEq(liveness.dryFirstObserved(CRED), 0, "dry clock excused while paused");

        // Longer than the dry bound but within the pause cap: not latchable.
        vm.warp(block.timestamp + DRY_DURATION + 1 days);
        assertFalse(liveness.isTriggerable(CRED), "carve-out holds within the cap");

        // But the carve-out is capped: pause past PAUSE_CAP latches anyway.
        vm.warp(block.timestamp + PAUSE_CAP);
        assertTrue(liveness.isTriggerable(CRED), "unbounded pause cannot dodge the latch");
        vm.prank(WATCHER);
        liveness.latch(CRED);
        assertTrue(liveness.isTriggered(CRED));
    }

    function test_pause_alternationCannotResetClocks() public {
        // Pause → unpause-into-dry → pause again, never healthy: neither
        // clock clears (clearing requires a HEALTHY observation), so the
        // alternation game fails.
        redemption.setPaused(true);
        liveness.checkpoint(CRED);
        uint64 pausedAt = liveness.pauseFirstObserved(CRED);

        vm.warp(block.timestamp + 2 days);
        redemption.setPaused(false);
        redemption.setCapacity(10_000e6); // unpaused but dry
        liveness.checkpoint(CRED);
        assertGt(liveness.dryFirstObserved(CRED), 0, "dry armed on unpause-into-dry");
        assertEq(liveness.pauseFirstObserved(CRED), pausedAt, "pause clock NOT cleared by dryness");

        vm.warp(block.timestamp + 2 days);
        redemption.setPaused(true);
        liveness.checkpoint(CRED);
        assertGt(liveness.dryFirstObserved(CRED), 0, "dry clock NOT cleared by re-pause");

        // The dry clock (armed at day 2) runs through the later pause: at
        // day 2 + 7d + 1s the failure is provable even though the facility
        // spent most of that time flipping states.
        vm.warp(uint256(liveness.dryFirstObserved(CRED)) + DRY_DURATION + 1);
        assertTrue(liveness.isTriggerable(CRED), "alternation does not reset the clocks");

        // A genuinely healthy observation clears everything.
        redemption.setPaused(false);
        redemption.setCapacity(500_000e6);
        liveness.checkpoint(CRED);
        assertEq(liveness.dryFirstObserved(CRED), 0);
        assertEq(liveness.pauseFirstObserved(CRED), 0);
        assertFalse(liveness.isTriggerable(CRED));
    }

    function test_window_armingOnlyInWindow_elapsedCappedAtEnd() public {
        bytes32 cred2 = keccak256("windowed");
        address[] memory trigs = new address[](1);
        trigs[0] = address(liveness);
        bytes32[] memory classes = new bytes32[](1);
        classes[0] = liveness.TRIGGER_CLASS();
        registry.setCredential(
            cred2, keccak256("entity/v1"), ATTESTOR, issuedAt, 0, false, trigs, classes
        );
        uint64 end = uint64(block.timestamp + 30 days);
        vm.prank(ATTESTOR);
        liveness.configure(cred2, address(redemption), FLOOR, DRY_DURATION, PAUSE_CAP, issuedAt, end);

        // Facility goes dry 3 days before expiry; dry bound is 7 days. The
        // in-window dryness can never exceed 3 days: not the subject's.
        vm.warp(end - 3 days);
        redemption.setCapacity(10_000e6);
        liveness.checkpoint(cred2);
        assertGt(liveness.dryFirstObserved(cred2), 0);
        vm.warp(end + 365 days);
        assertFalse(liveness.isTriggerable(cred2), "post-expiry dryness not attributed");

        // Post-window observations cannot arm anything.
        bytes32 cred3 = keccak256("windowed-late");
        registry.setCredential(
            cred3, keccak256("entity/v1"), ATTESTOR, issuedAt, 0, false, trigs, classes
        );
        vm.prank(ATTESTOR);
        liveness.configure(cred3, address(redemption), FLOOR, DRY_DURATION, PAUSE_CAP, issuedAt, end);
        liveness.checkpoint(cred3);
        assertEq(liveness.dryFirstObserved(cred3), 0, "post-window: observed, not armed");
    }

    // ------------------------------------------------------------- provider

    function test_provider_grantsWhileBothLimbsHealthy() public {
        assertEq(provider.getCredential(ISSUER_WALLET), uint32(issuedAt));
    }

    function test_provider_navOnlyCredential_granted_gapDisclosed() public {
        // An issuer with no onchain redemption path binds NAV alone — the
        // provider accepts it; the liveness gap lives in the credential's
        // terms, not in a faked attestation.
        bytes32 navOnly = keccak256("nav-only-issuer");
        address[] memory trigs = new address[](1);
        trigs[0] = address(nav);
        bytes32[] memory classes = new bytes32[](1);
        classes[0] = nav.TRIGGER_CLASS();
        registry.setCredential(
            navOnly, keccak256("entity/v1"), ATTESTOR, issuedAt, 0, false, trigs, classes
        );
        address w = address(0xBEEF);
        registry.setWallet(w, navOnly);

        assertEq(provider.getCredential(w), 0, "unconfigured NAV mandate refused");
        vm.prank(ATTESTOR);
        nav.configure(navOnly, address(feed), 500, CONFIRMATION, 2 days, 10 days, issuedAt, 0);
        assertGt(provider.getCredential(w), 0, "NAV-only issuer granted");
    }

    function test_provider_livenessBoundButUnconfigured_refused() public {
        bytes32 half = keccak256("half-configured");
        address[] memory trigs = new address[](2);
        trigs[0] = address(nav);
        trigs[1] = address(liveness);
        bytes32[] memory classes = new bytes32[](2);
        classes[0] = nav.TRIGGER_CLASS();
        classes[1] = liveness.TRIGGER_CLASS();
        registry.setCredential(
            half, keccak256("entity/v1"), ATTESTOR, issuedAt, 0, false, trigs, classes
        );
        address w = address(0xBEEF);
        registry.setWallet(w, half);
        vm.prank(ATTESTOR);
        nav.configure(half, address(feed), 500, CONFIRMATION, 2 days, 10 days, issuedAt, 0);

        assertEq(provider.getCredential(w), 0, "bound-but-toothless liveness refused");
    }

    function test_provider_navLimbKillsTheGrant() public {
        // Arm a breach (a single checkpoint does not kill the grant), then
        // bring the confirming round live: the grant dies via projection
        // before any confirming checkpoint.
        feed.set(10_000_000, block.timestamp); // ~-10.3% from 11.144444 HWM
        nav.checkpoint(CRED); // arm
        assertGt(provider.getCredential(ISSUER_WALLET), 0, "armed-only: still granted");

        vm.warp(block.timestamp + CONFIRMATION);
        feed.set(10_000_000, block.timestamp); // confirming round is live
        assertEq(provider.getCredential(ISSUER_WALLET), 0, "NAV limb kills grant on confirmation");

        // Corrected before any confirming checkpoint recorded it: grant back.
        feed.set(11_144_444, block.timestamp);
        nav.checkpoint(CRED); // clears the arm
        assertGt(provider.getCredential(ISSUER_WALLET), 0, "recovery restores the grant");
    }

    function test_provider_livenessLimbKillsTheGrant() public {
        feed.set(11_144_444, block.timestamp); // NAV healthy and fresh throughout
        redemption.setCapacity(10_000e6);
        liveness.checkpoint(CRED);
        vm.warp(block.timestamp + DRY_DURATION + 1);
        feed.set(11_144_444, block.timestamp); // keep NAV fresh across the warp
        assertEq(provider.getCredential(ISSUER_WALLET), 0, "liveness limb kills grant");

        // Latch it: dead forever, even after the facility refills.
        vm.prank(WATCHER);
        liveness.latch(CRED);
        redemption.setCapacity(500_000e6);
        liveness.checkpoint(CRED);
        assertEq(provider.getCredential(ISSUER_WALLET), 0, "latched: grant stays dead");
    }

    function test_provider_standardRefusals() public {
        assertEq(provider.getCredential(address(0xDEAD)), 0, "no credential");

        registry.setRevoked(CRED, true);
        assertEq(provider.getCredential(ISSUER_WALLET), 0, "revoked");
        registry.setRevoked(CRED, false);

        bytes32 borrower = keccak256("borrower-credential");
        MockLatchTrigger wrong = new MockLatchTrigger(keccak256("WILDCAT_DELINQ_90D_V1"));
        address[] memory trigs = new address[](1);
        trigs[0] = address(wrong);
        bytes32[] memory classes = new bytes32[](1);
        classes[0] = wrong.klass();
        registry.setCredential(
            borrower, keccak256("entity/v1"), ATTESTOR, issuedAt, 0, false, trigs, classes
        );
        address w = address(0xBEEF);
        registry.setWallet(w, borrower);
        assertEq(provider.getCredential(w), 0, "wrong class");
    }
}
