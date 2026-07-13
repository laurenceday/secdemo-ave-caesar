// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GhoFacilitatorWindDownTrigger} from "../src/GhoFacilitatorWindDownTrigger.sol";
import {GhoFacilitatorCredentialProvider} from "../src/GhoFacilitatorCredentialProvider.sol";
import {MockSealedRegistry, MockGhoToken, MockLatchTrigger} from "./mocks/Mocks.sol";

contract GhoFacilitatorWindDownTriggerTest is Test {
    // A facilitator offboarded (capacity 0) with GHO still outstanding for
    // more than 30 days latches.
    uint32 constant WINDDOWN = 30 days;

    bytes32 constant CRED = keccak256("gho-facilitator-credential");
    address constant ATTESTOR = address(0xA77E5);
    address constant FACILITATOR = address(0xFAC11);
    address constant SUBJECT = address(0x5AB);
    address constant WATCHER = address(0xDE9051709);

    MockSealedRegistry registry;
    GhoFacilitatorWindDownTrigger trigger;
    GhoFacilitatorCredentialProvider provider;
    MockGhoToken gho;

    uint64 mandateStart;

    function setUp() public {
        vm.warp(1_752_000_000);

        registry = new MockSealedRegistry();
        trigger = new GhoFacilitatorWindDownTrigger(address(registry));
        provider = new GhoFacilitatorCredentialProvider(address(registry));
        gho = new MockGhoToken();

        address[] memory trigs = new address[](1);
        trigs[0] = address(trigger);
        bytes32[] memory classes = new bytes32[](1);
        classes[0] = trigger.TRIGGER_CLASS();
        registry.setCredential(
            CRED, keccak256("entity/v1"), ATTESTOR, uint64(block.timestamp), 0, false, trigs, classes
        );
        registry.setWallet(SUBJECT, CRED);

        mandateStart = uint64(block.timestamp);
        // Healthy, active facilitator: 175M capacity, 45M minted.
        gho.setCapacity(FACILITATOR, 175_000_000e18);
        gho.setLevel(FACILITATOR, 45_000_000e18);
    }

    function _configure() internal {
        vm.prank(ATTESTOR);
        trigger.configure(CRED, address(gho), FACILITATOR, WINDDOWN, mandateStart, 0);
    }

    // --------------------------------------------------------- configuring

    function test_configure_gating_oneShot_degenerates() public {
        vm.expectRevert(GhoFacilitatorWindDownTrigger.NotAttestor.selector);
        trigger.configure(CRED, address(gho), FACILITATOR, WINDDOWN, mandateStart, 0);

        vm.startPrank(ATTESTOR);
        vm.expectRevert(GhoFacilitatorWindDownTrigger.InvalidMandate.selector);
        trigger.configure(CRED, address(0), FACILITATOR, WINDDOWN, mandateStart, 0);
        vm.expectRevert(GhoFacilitatorWindDownTrigger.InvalidMandate.selector);
        trigger.configure(CRED, address(gho), address(0), WINDDOWN, mandateStart, 0);
        vm.expectRevert(GhoFacilitatorWindDownTrigger.InvalidMandate.selector);
        trigger.configure(CRED, address(gho), FACILITATOR, 0, mandateStart, 0);

        trigger.configure(CRED, address(gho), FACILITATOR, WINDDOWN, mandateStart, 0);
        assertEq(trigger.mandate(CRED).facilitator, FACILITATOR);
        vm.expectRevert(GhoFacilitatorWindDownTrigger.AlreadyConfigured.selector);
        trigger.configure(CRED, address(gho), FACILITATOR, WINDDOWN, mandateStart, 0);
        vm.stopPrank();
    }

    function test_unconfigured_isInert() public {
        assertFalse(trigger.isConfigured(CRED));
        assertFalse(trigger.isTriggerable(CRED));
        vm.expectRevert(GhoFacilitatorWindDownTrigger.NotConfigured.selector);
        trigger.checkpoint(CRED);
        vm.expectRevert(GhoFacilitatorWindDownTrigger.NotTriggerable.selector);
        trigger.latch(CRED);
    }

    // ---------------------------------------------------- condition + clock

    function test_healthyFacilitator_neverArms() public {
        _configure();
        trigger.checkpoint(CRED);
        assertFalse(trigger.conditionHolds(CRED), "capacity>0: condition false");
        assertEq(trigger.windDownFirstObserved(CRED), 0);
        assertGt(provider.getCredential(SUBJECT), 0, "healthy: granted");
    }

    function test_capacityZeroButFullyWoundDown_neverArms() public {
        // Offboarded AND already at level 0: duty discharged, not a breach.
        _configure();
        gho.setCapacity(FACILITATOR, 0);
        gho.setLevel(FACILITATOR, 0);
        trigger.checkpoint(CRED);
        assertFalse(trigger.conditionHolds(CRED));
        assertEq(trigger.windDownFirstObserved(CRED), 0, "level 0 does not arm");
    }

    function test_windDownInProgress_armsButNotYetLatchable() public {
        _configure();
        // Governance offboards; GHO still outstanding.
        gho.setCapacity(FACILITATOR, 0);
        trigger.checkpoint(CRED);
        assertTrue(trigger.conditionHolds(CRED));
        assertGt(trigger.windDownFirstObserved(CRED), 0, "armed");
        assertFalse(trigger.isTriggerable(CRED), "within the wind-down window");
        vm.expectRevert(GhoFacilitatorWindDownTrigger.NotTriggerable.selector);
        trigger.latch(CRED);
    }

    function test_woundDownInTime_clearsTheArm() public {
        _configure();
        gho.setCapacity(FACILITATOR, 0);
        trigger.checkpoint(CRED); // arm
        assertGt(trigger.windDownFirstObserved(CRED), 0);

        // Facilitator retires its outstanding GHO before the window elapses.
        vm.warp(block.timestamp + 10 days);
        gho.setLevel(FACILITATOR, 0);
        trigger.checkpoint(CRED);
        assertEq(trigger.windDownFirstObserved(CRED), 0, "duty discharged clears the clock");
        assertFalse(trigger.isTriggerable(CRED));
    }

    function test_reonboardedClearsTheArm() public {
        _configure();
        gho.setCapacity(FACILITATOR, 0);
        trigger.checkpoint(CRED); // arm
        // Governance restores capacity (re-onboards): not an offboarding.
        gho.setCapacity(FACILITATOR, 100_000_000e18);
        trigger.checkpoint(CRED);
        assertEq(trigger.windDownFirstObserved(CRED), 0, "re-onboard clears the clock");
    }

    function test_sustainedPastWindow_latches_permissionlessAndPermanent() public {
        _configure();
        gho.setCapacity(FACILITATOR, 0); // offboarded, 45M still outstanding
        trigger.checkpoint(CRED); // arm
        assertGt(provider.getCredential(SUBJECT), 0, "still granted while within window");

        vm.warp(block.timestamp + WINDDOWN + 1);
        assertTrue(trigger.windDownProvable(CRED), "offboarded past the window");
        assertTrue(trigger.isTriggerable(CRED));
        assertEq(provider.getCredential(SUBJECT), 0, "grant withdrawn once latchable");

        vm.prank(WATCHER);
        trigger.latch(CRED);
        assertTrue(trigger.isTriggered(CRED));

        // Belated wind-down after the latch cannot un-latch.
        gho.setLevel(FACILITATOR, 0);
        assertTrue(trigger.isTriggered(CRED), "no un-latch on late wind-down");
        assertEq(provider.getCredential(SUBJECT), 0, "grant stays withdrawn");
        vm.expectRevert(GhoFacilitatorWindDownTrigger.NotTriggerable.selector);
        trigger.latch(CRED);
    }

    function test_recoveredBeforeLatch_cannotBeProjected() public {
        _configure();
        gho.setCapacity(FACILITATOR, 0);
        trigger.checkpoint(CRED); // arm
        vm.warp(block.timestamp + WINDDOWN + 1);
        assertTrue(trigger.isTriggerable(CRED));

        // Facilitator winds down at the last moment, before anyone latches:
        // the condition no longer holds live, so it cannot be projected.
        gho.setLevel(FACILITATOR, 0);
        assertFalse(trigger.isTriggerable(CRED), "live recovery defeats projection");
    }

    function test_window_armingInWindowOnly_elapsedCappedAtEnd() public {
        uint64 end = uint64(block.timestamp + 60 days);
        vm.prank(ATTESTOR);
        trigger.configure(CRED, address(gho), FACILITATOR, WINDDOWN, mandateStart, end);

        // Offboarded 20 days before expiry; window is 30 days. In-window
        // persistence can never reach 30 days: not the subject's breach.
        vm.warp(end - 20 days);
        gho.setCapacity(FACILITATOR, 0);
        trigger.checkpoint(CRED);
        assertGt(trigger.windDownFirstObserved(CRED), 0);
        vm.warp(end + 365 days);
        assertFalse(trigger.isTriggerable(CRED), "post-expiry persistence not attributed");

        // Post-window arming cannot happen at all.
        bytes32 cred2 = keccak256("late");
        address[] memory trigs = new address[](1);
        trigs[0] = address(trigger);
        bytes32[] memory classes = new bytes32[](1);
        classes[0] = trigger.TRIGGER_CLASS();
        registry.setCredential(
            cred2, keccak256("entity/v1"), ATTESTOR, uint64(block.timestamp), 0, false, trigs, classes
        );
        vm.prank(ATTESTOR);
        trigger.configure(cred2, address(gho), FACILITATOR, WINDDOWN, mandateStart, end);
        trigger.checkpoint(cred2);
        assertEq(trigger.windDownFirstObserved(cred2), 0, "post-window: observed, not armed");
    }

    // -------------------------------------------------------- binding view

    function test_binding_encodesTheFullMandate() public {
        _configure();
        (
            uint256 chainId,
            address ghoToken,
            address facilitator,
            uint32 windDownPeriod,
            uint64 start,
            uint64 end
        ) = abi.decode(
            trigger.binding(CRED), (uint256, address, address, uint32, uint64, uint64)
        );
        assertEq(chainId, block.chainid);
        assertEq(ghoToken, address(gho));
        assertEq(facilitator, FACILITATOR);
        assertEq(windDownPeriod, WINDDOWN);
        assertEq(start, mandateStart);
        assertEq(end, 0);
    }

    // ------------------------------------------------------------- provider

    function test_provider_standardRefusals() public {
        _configure();
        assertGt(provider.getCredential(SUBJECT), 0);
        assertEq(provider.getCredential(address(0xDEAD)), 0, "no credential");

        registry.setRevoked(CRED, true);
        assertEq(provider.getCredential(SUBJECT), 0, "revoked");
        registry.setRevoked(CRED, false);

        // Unconfigured mandate is refused as non-consequence-bearing.
        bytes32 toothless = keccak256("toothless");
        address[] memory trigs = new address[](1);
        trigs[0] = address(trigger);
        bytes32[] memory classes = new bytes32[](1);
        classes[0] = trigger.TRIGGER_CLASS();
        registry.setCredential(
            toothless, keccak256("entity/v1"), ATTESTOR, uint64(block.timestamp), 0, false, trigs, classes
        );
        address w = address(0xBEEF);
        registry.setWallet(w, toothless);
        assertEq(provider.getCredential(w), 0, "unconfigured mandate refused");

        // Wrong class is unusable.
        bytes32 borrower = keccak256("borrower");
        MockLatchTrigger wrong = new MockLatchTrigger(keccak256("WILDCAT_DELINQ_90D_V1"));
        address[] memory t2 = new address[](1);
        t2[0] = address(wrong);
        bytes32[] memory c2 = new bytes32[](1);
        c2[0] = wrong.klass();
        registry.setCredential(
            borrower, keccak256("entity/v1"), ATTESTOR, uint64(block.timestamp), 0, false, t2, c2
        );
        address w2 = address(0xF00D);
        registry.setWallet(w2, borrower);
        assertEq(provider.getCredential(w2), 0, "wrong class");
    }
}
