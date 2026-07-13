// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AaveV4SpokeTrigger} from "../src/AaveV4SpokeTrigger.sol";
import {MockSealedRegistry, MockAaveV4Hub} from "./mocks/Mocks.sol";

contract AaveV4SpokeTriggerTest is Test {
    uint256 constant RAY = 1e27;
    // WETH-denominated spoke mandate: limb 1 latches at 100 WETH gross
    // deficit; limb 2's sanction floor is 1 WETH.
    uint256 constant THRESHOLD_RAY = 100e18 * RAY;
    uint256 constant FLOOR_RAY = 1e18 * RAY;

    bytes32 constant CRED = keccak256("spoke-operator-credential");
    uint256 constant WETH_ID = 1;
    uint256 constant WSTETH_ID = 2;
    address constant SPOKE = address(0x590CE);
    address constant ATTESTOR = address(0xA77E5);
    address constant SUBJECT = address(0x5AB);

    MockSealedRegistry registry;
    AaveV4SpokeTrigger trigger;
    MockAaveV4Hub hub;

    uint64 mandateStart;

    function setUp() public {
        registry = new MockSealedRegistry();
        trigger = new AaveV4SpokeTrigger(address(registry));
        hub = new MockAaveV4Hub();

        address[] memory trigs = new address[](1);
        trigs[0] = address(trigger);
        bytes32[] memory classes = new bytes32[](1);
        classes[0] = trigger.TRIGGER_CLASS();
        registry.setCredential(
            CRED, keccak256("entity/v1"), ATTESTOR, uint64(block.timestamp), 0, false, trigs, classes
        );
        registry.setWallet(SUBJECT, CRED);

        mandateStart = uint64(block.timestamp);
        // The spoke starts life with a real credit line.
        hub.setSpokeConfig(WETH_ID, SPOKE, 1_000_000, 500_000, true);
    }

    function _configureAndBind() internal {
        vm.startPrank(ATTESTOR);
        trigger.configure(CRED, address(hub), SPOKE, THRESHOLD_RAY, FLOOR_RAY, mandateStart, 0);
        trigger.addAsset(CRED, WETH_ID);
        vm.stopPrank();
        trigger.checkpoint(CRED); // records capEverPositive for WETH_ID
    }

    // --------------------------------------------------------- configuring

    function test_configure_gating_oneShot_degenerates() public {
        vm.expectRevert(AaveV4SpokeTrigger.NotAttestor.selector);
        trigger.configure(CRED, address(hub), SPOKE, THRESHOLD_RAY, FLOOR_RAY, mandateStart, 0);

        vm.startPrank(ATTESTOR);
        vm.expectRevert(AaveV4SpokeTrigger.InvalidMandate.selector);
        trigger.configure(CRED, address(0), SPOKE, THRESHOLD_RAY, FLOOR_RAY, mandateStart, 0);
        vm.expectRevert(AaveV4SpokeTrigger.InvalidMandate.selector);
        trigger.configure(CRED, address(hub), address(0), THRESHOLD_RAY, FLOOR_RAY, mandateStart, 0);
        vm.expectRevert(AaveV4SpokeTrigger.InvalidMandate.selector);
        trigger.configure(CRED, address(hub), SPOKE, 0, FLOOR_RAY, mandateStart, 0);
        vm.expectRevert(AaveV4SpokeTrigger.InvalidMandate.selector);
        trigger.configure(CRED, address(hub), SPOKE, THRESHOLD_RAY, 0, mandateStart, 0);

        trigger.configure(CRED, address(hub), SPOKE, THRESHOLD_RAY, FLOOR_RAY, mandateStart, 0);
        assertEq(trigger.mandate(CRED).spoke, SPOKE);

        vm.expectRevert(AaveV4SpokeTrigger.AlreadyConfigured.selector);
        trigger.configure(CRED, address(hub), SPOKE, THRESHOLD_RAY, FLOOR_RAY, mandateStart, 0);
        vm.stopPrank();
    }

    function test_unconfigured_isInertAndUnlatchable() public {
        assertFalse(trigger.isConfigured(CRED));
        assertFalse(trigger.isTriggerable(CRED));
        vm.expectRevert(AaveV4SpokeTrigger.NotConfigured.selector);
        trigger.checkpoint(CRED);
        vm.expectRevert(AaveV4SpokeTrigger.NotTriggerable.selector);
        trigger.latch(CRED);
    }

    // -------------------------------------------------------- scope binding

    function test_addAsset_gating_baseline_appendOnly() public {
        vm.prank(ATTESTOR);
        trigger.configure(CRED, address(hub), SPOKE, THRESHOLD_RAY, FLOOR_RAY, mandateStart, 0);

        vm.expectRevert(AaveV4SpokeTrigger.NotSubjectOrAttestor.selector);
        trigger.addAsset(CRED, WETH_ID);

        // Pre-existing deficit history is swallowed by the add-time baseline.
        hub.reportDeficit(WETH_ID, SPOKE, 500e18 * RAY);
        vm.prank(ATTESTOR);
        trigger.addAsset(CRED, WETH_ID);
        assertEq(trigger.lastObservedDeficitRay(CRED, WETH_ID), 500e18 * RAY);
        assertEq(trigger.projectedGrossDeficitRay(CRED), 0, "history does not count");

        // The subject can widen its own accountability.
        vm.prank(SUBJECT);
        trigger.addAsset(CRED, WSTETH_ID);
        assertTrue(trigger.isBound(CRED, WSTETH_ID));

        vm.prank(ATTESTOR);
        vm.expectRevert(AaveV4SpokeTrigger.AlreadyBound.selector);
        trigger.addAsset(CRED, WETH_ID);
    }

    // -------------------------------------------------------------- limb 1

    function test_limb1_grossNotNet_cureBeforeLatchStillLatches() public {
        _configureAndBind();

        hub.reportDeficit(WETH_ID, SPOKE, 150e18 * RAY);
        trigger.checkpoint(CRED);
        assertEq(trigger.grossDeficitAccumulatedRay(CRED), 150e18 * RAY);

        // A friendly party eliminates the whole deficit before anyone latches.
        hub.eliminateDeficit(WETH_ID, SPOKE, 150e18 * RAY);
        trigger.checkpoint(CRED);
        assertEq(hub.getSpokeDeficitRay(WETH_ID, SPOKE), 0, "net cured");
        assertEq(trigger.grossDeficitAccumulatedRay(CRED), 150e18 * RAY, "gross unmoved");
        assertTrue(trigger.isTriggerable(CRED), "cure-before-latch does not disarm");
        trigger.latch(CRED);
        assertTrue(trigger.isTriggered(CRED));
    }

    function test_limb1_reIncurredDebtCountsFromLoweredBase() public {
        _configureAndBind();
        hub.reportDeficit(WETH_ID, SPOKE, 60e18 * RAY);
        trigger.checkpoint(CRED);
        hub.eliminateDeficit(WETH_ID, SPOKE, 60e18 * RAY);
        trigger.checkpoint(CRED);
        hub.reportDeficit(WETH_ID, SPOKE, 60e18 * RAY);
        trigger.checkpoint(CRED);
        assertEq(trigger.grossDeficitAccumulatedRay(CRED), 120e18 * RAY, "re-incurred counts in full");
    }

    function test_limb1_windowAttribution() public {
        uint64 end = uint64(block.timestamp + 30 days);
        vm.startPrank(ATTESTOR);
        trigger.configure(CRED, address(hub), SPOKE, THRESHOLD_RAY, FLOOR_RAY, mandateStart, end);
        trigger.addAsset(CRED, WETH_ID);
        vm.stopPrank();

        hub.reportDeficit(WETH_ID, SPOKE, 60e18 * RAY);
        trigger.checkpoint(CRED);
        assertEq(trigger.grossDeficitAccumulatedRay(CRED), 60e18 * RAY, "in-window attributed");

        vm.warp(end + 1);
        hub.reportDeficit(WETH_ID, SPOKE, 500e18 * RAY);
        trigger.checkpoint(CRED);
        assertEq(
            trigger.grossDeficitAccumulatedRay(CRED),
            60e18 * RAY,
            "post-mandate observed, not attributed"
        );
        assertFalse(trigger.isTriggerable(CRED), "projection excluded post-window");
    }

    function test_limb1_projection_latchMaterialises() public {
        _configureAndBind();
        hub.reportDeficit(WETH_ID, SPOKE, 150e18 * RAY);

        assertEq(trigger.grossDeficitAccumulatedRay(CRED), 0, "nothing checkpointed");
        assertTrue(trigger.isTriggerable(CRED), "projection sees the hub live");
        vm.prank(address(0xDE9051709));
        trigger.latch(CRED);
        assertEq(trigger.grossDeficitAccumulatedRay(CRED), 150e18 * RAY, "latch materialised");
    }

    function test_limb1_thresholdBoundary_inclusive() public {
        _configureAndBind();
        hub.reportDeficit(WETH_ID, SPOKE, THRESHOLD_RAY - 1);
        assertFalse(trigger.isTriggerable(CRED));
        hub.reportDeficit(WETH_ID, SPOKE, 1);
        assertTrue(trigger.isTriggerable(CRED), "inclusive at threshold");
    }

    // -------------------------------------------------------------- limb 2

    function test_limb2_neverPositiveLine_cannotArm() public {
        // Fee-receiver shape: drawCap zero from the first observation. Even
        // a floor-clearing deficit must not arm the sanction limb.
        hub.setSpokeConfig(WETH_ID, SPOKE, 1_000_000, 0, true);
        _configureAndBind();

        hub.reportDeficit(WETH_ID, SPOKE, 50e18 * RAY); // >> floor, << threshold
        trigger.checkpoint(CRED);
        assertFalse(trigger.sanctionProvable(CRED), "line never existed: no sanction");
        assertFalse(trigger.isTriggerable(CRED));
    }

    function test_limb2_benignWindDown_belowFloor_cannotArm() public {
        _configureAndBind(); // cap positive observed

        // DAO zeroes the line with only dust deficit on the books.
        hub.reportDeficit(WETH_ID, SPOKE, FLOOR_RAY - 1);
        hub.setSpokeConfig(WETH_ID, SPOKE, 1_000_000, 0, true);
        trigger.checkpoint(CRED);
        assertEq(trigger.sanctionObservedAt(CRED), 0, "wind-down below floor: not armed");
        assertFalse(trigger.isTriggerable(CRED));
    }

    function test_limb2_sanctionAfterDeficit_arms_latchesBelowThreshold() public {
        _configureAndBind();

        // 50 WETH of gross deficit: above the 1 WETH floor, far below the
        // 100 WETH limb-1 threshold.
        hub.reportDeficit(WETH_ID, SPOKE, 50e18 * RAY);
        trigger.checkpoint(CRED);
        assertFalse(trigger.isTriggerable(CRED), "limb 1 not reached");

        // The DAO zeroes the spoke's credit line.
        hub.setSpokeConfig(WETH_ID, SPOKE, 1_000_000, 0, true);
        assertTrue(trigger.sanctionProvable(CRED), "provable live before any checkpoint");
        assertTrue(trigger.isTriggerable(CRED));

        trigger.checkpoint(CRED);
        assertGt(trigger.sanctionObservedAt(CRED), 0, "armed at checkpoint");

        // Cap restoration after arming must not disarm (cure-before-latch).
        hub.setSpokeConfig(WETH_ID, SPOKE, 1_000_000, 500_000, true);
        assertTrue(trigger.isTriggerable(CRED), "armed sanction is permanent");
        vm.prank(address(0xDE9051709));
        trigger.latch(CRED);
        assertTrue(trigger.isTriggered(CRED), "latched on limb 2 below limb-1 threshold");
    }

    function test_limb2_sameCheckpoint_deficitAndSanction_arms() public {
        _configureAndBind();

        // Loss lands and the DAO sanctions before anyone checkpoints: a
        // single checkpoint observes both, and that is enough.
        hub.reportDeficit(WETH_ID, SPOKE, 50e18 * RAY);
        hub.setSpokeConfig(WETH_ID, SPOKE, 1_000_000, 0, true);
        trigger.checkpoint(CRED);
        assertGt(trigger.sanctionObservedAt(CRED), 0, "same-block sanction armed");
    }

    function test_limb2_zeroCapObservedBeforeDeficit_armsOnlyOnceFloorCrossed() public {
        _configureAndBind();

        // Sanction first (below floor): not armed.
        hub.setSpokeConfig(WETH_ID, SPOKE, 1_000_000, 0, true);
        trigger.checkpoint(CRED);
        assertEq(trigger.sanctionObservedAt(CRED), 0);

        // Deficit crosses the floor while the line is still zero: the next
        // checkpoint arms — the ordering condition is on the observation.
        hub.reportDeficit(WETH_ID, SPOKE, 50e18 * RAY);
        trigger.checkpoint(CRED);
        assertGt(trigger.sanctionObservedAt(CRED), 0, "armed once both facts hold");
    }

    function test_limb2_outsideWindow_cannotArm() public {
        uint64 end = uint64(block.timestamp + 30 days);
        vm.startPrank(ATTESTOR);
        trigger.configure(CRED, address(hub), SPOKE, THRESHOLD_RAY, FLOOR_RAY, mandateStart, end);
        trigger.addAsset(CRED, WETH_ID);
        vm.stopPrank();
        trigger.checkpoint(CRED); // capEverPositive recorded in-window

        hub.reportDeficit(WETH_ID, SPOKE, 50e18 * RAY);
        trigger.checkpoint(CRED); // gross attributed in-window

        vm.warp(end + 1);
        hub.setSpokeConfig(WETH_ID, SPOKE, 1_000_000, 0, true);
        trigger.checkpoint(CRED);
        assertEq(trigger.sanctionObservedAt(CRED), 0, "post-mandate sanction: not the subject's");
        assertFalse(trigger.sanctionProvable(CRED));
        assertFalse(trigger.isTriggerable(CRED));
    }

    // ------------------------------------------------------------- latching

    function test_latch_permanent_scopeFrozen() public {
        _configureAndBind();
        hub.reportDeficit(WETH_ID, SPOKE, 150e18 * RAY);
        trigger.latch(CRED);

        hub.eliminateDeficit(WETH_ID, SPOKE, 150e18 * RAY);
        assertTrue(trigger.isTriggered(CRED), "no un-latch on cure");
        assertFalse(trigger.isTriggerable(CRED), "latched excludes triggerable");

        vm.expectRevert(AaveV4SpokeTrigger.NotTriggerable.selector);
        trigger.latch(CRED);

        vm.prank(ATTESTOR);
        vm.expectRevert(AaveV4SpokeTrigger.AlreadyLatched.selector);
        trigger.addAsset(CRED, WSTETH_ID);
    }

    // -------------------------------------------------------- binding view

    function test_binding_encodesTheFullMandate() public {
        _configureAndBind();
        (
            uint256 chainId,
            address boundHub,
            address boundSpoke,
            uint256 thresholdRay,
            uint256 floorRay,
            uint64 start,
            uint64 end,
            uint256[] memory scope
        ) = abi.decode(
            trigger.binding(CRED),
            (uint256, address, address, uint256, uint256, uint64, uint64, uint256[])
        );
        assertEq(chainId, block.chainid);
        assertEq(boundHub, address(hub));
        assertEq(boundSpoke, SPOKE);
        assertEq(thresholdRay, THRESHOLD_RAY);
        assertEq(floorRay, FLOOR_RAY);
        assertEq(start, mandateStart);
        assertEq(end, 0);
        assertEq(scope.length, 1);
        assertEq(scope[0], WETH_ID);
    }
}
