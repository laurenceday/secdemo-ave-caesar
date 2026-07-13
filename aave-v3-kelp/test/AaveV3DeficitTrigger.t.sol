// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AaveV3DeficitTrigger} from "../src/AaveV3DeficitTrigger.sol";
import {MockSealedRegistry, MockAaveV3Pool} from "./mocks/Mocks.sol";

contract AaveV3DeficitTriggerTest is Test {
    // WETH-denominated mandate: 100 WETH of gross deficit latches.
    uint256 constant THRESHOLD = 100e18;
    bytes32 constant CRED = keccak256("risk-provider-credential");
    address constant WETH = address(0x11E7);
    address constant WSTETH = address(0x11E8);
    address constant ATTESTOR = address(0xA77E5);
    address constant SUBJECT = address(0x5AB);

    MockSealedRegistry registry;
    AaveV3DeficitTrigger trigger;
    MockAaveV3Pool pool;

    uint64 mandateStart;

    function setUp() public {
        registry = new MockSealedRegistry();
        trigger = new AaveV3DeficitTrigger(address(registry));
        pool = new MockAaveV3Pool();

        address[] memory trigs = new address[](1);
        trigs[0] = address(trigger);
        bytes32[] memory classes = new bytes32[](1);
        classes[0] = trigger.TRIGGER_CLASS();
        registry.setCredential(
            CRED, keccak256("entity/v1"), ATTESTOR, uint64(block.timestamp), 0, false, trigs, classes
        );
        registry.setWallet(SUBJECT, CRED);

        mandateStart = uint64(block.timestamp);
    }

    /// @dev Configure an open-ended mandate starting now and bind WETH.
    function _configureAndBind() internal {
        vm.startPrank(ATTESTOR);
        trigger.configure(CRED, address(pool), THRESHOLD, mandateStart, 0);
        trigger.addReserve(CRED, WETH);
        vm.stopPrank();
    }

    // --------------------------------------------------------- configuring

    function test_configure_onlyAttestor() public {
        vm.expectRevert(AaveV3DeficitTrigger.NotAttestor.selector);
        trigger.configure(CRED, address(pool), THRESHOLD, mandateStart, 0);

        vm.prank(ATTESTOR);
        trigger.configure(CRED, address(pool), THRESHOLD, mandateStart, 0);
        assertEq(trigger.mandate(CRED).pool, address(pool));
        assertEq(trigger.mandate(CRED).threshold, THRESHOLD);
    }

    function test_configure_oneShot() public {
        vm.startPrank(ATTESTOR);
        trigger.configure(CRED, address(pool), THRESHOLD, mandateStart, 0);
        vm.expectRevert(AaveV3DeficitTrigger.AlreadyConfigured.selector);
        trigger.configure(CRED, address(pool), THRESHOLD + 1, mandateStart, 0);
        vm.stopPrank();
    }

    function test_configure_rejectsDegenerateMandates() public {
        vm.startPrank(ATTESTOR);
        vm.expectRevert(AaveV3DeficitTrigger.InvalidMandate.selector);
        trigger.configure(CRED, address(0), THRESHOLD, mandateStart, 0);
        vm.expectRevert(AaveV3DeficitTrigger.InvalidMandate.selector);
        trigger.configure(CRED, address(pool), 0, mandateStart, 0);
        vm.expectRevert(AaveV3DeficitTrigger.InvalidMandate.selector);
        trigger.configure(CRED, address(pool), THRESHOLD, mandateStart, mandateStart);
        vm.stopPrank();
    }

    function test_unconfigured_isInertAndUnlatchable() public {
        assertFalse(trigger.isConfigured(CRED));
        assertFalse(trigger.isTriggerable(CRED));
        vm.expectRevert(AaveV3DeficitTrigger.NotConfigured.selector);
        trigger.checkpoint(CRED);
        vm.expectRevert(AaveV3DeficitTrigger.NotTriggerable.selector);
        trigger.latch(CRED);
    }

    // -------------------------------------------------------- scope binding

    function test_addReserve_subjectOrAttestor() public {
        vm.prank(ATTESTOR);
        trigger.configure(CRED, address(pool), THRESHOLD, mandateStart, 0);

        vm.expectRevert(AaveV3DeficitTrigger.NotSubjectOrAttestor.selector);
        trigger.addReserve(CRED, WETH);

        vm.prank(ATTESTOR);
        trigger.addReserve(CRED, WETH);
        assertTrue(trigger.isBound(CRED, WETH));

        // The subject can widen its own accountability (additions only).
        vm.prank(SUBJECT);
        trigger.addReserve(CRED, WSTETH);
        assertTrue(trigger.isBound(CRED, WSTETH));
        assertEq(trigger.reserves(CRED).length, 2);
    }

    function test_addReserve_requiresConfigure_noDuplicates_capped() public {
        vm.expectRevert(AaveV3DeficitTrigger.NotConfigured.selector);
        vm.prank(ATTESTOR);
        trigger.addReserve(CRED, WETH);

        vm.startPrank(ATTESTOR);
        trigger.configure(CRED, address(pool), THRESHOLD, mandateStart, 0);
        trigger.addReserve(CRED, WETH);
        vm.expectRevert(AaveV3DeficitTrigger.AlreadyBound.selector);
        trigger.addReserve(CRED, WETH);

        for (uint256 i = 1; i < trigger.MAX_RESERVES(); ++i) {
            trigger.addReserve(CRED, address(uint160(0xFF00 + i)));
        }
        vm.expectRevert(AaveV3DeficitTrigger.ReserveLimit.selector);
        trigger.addReserve(CRED, address(0xFEED));
        vm.stopPrank();
    }

    function test_addReserve_baselineExcludesPriorDeficit() public {
        // The reserve carries 500 WETH of historical deficit before this
        // subject's mandate binds it.
        pool.createDeficit(WETH, 500e18);
        _configureAndBind();

        assertEq(trigger.lastObservedDeficit(CRED, WETH), 500e18, "baseline = live counter");
        assertEq(trigger.projectedGrossDeficit(CRED), 0, "history does not count");
        assertFalse(trigger.isTriggerable(CRED));

        // Only post-bind increases accrue to the subject.
        pool.createDeficit(WETH, 99e18);
        assertEq(trigger.projectedGrossDeficit(CRED), 99e18, "post-bind only");
        assertFalse(trigger.isTriggerable(CRED));
    }

    function test_addReserve_midMandate_baselinesAtAddTime() public {
        _configureAndBind();

        // wstETH books deficit BEFORE it enters scope: not attributable.
        pool.createDeficit(WSTETH, 40e18);
        vm.prank(ATTESTOR);
        trigger.addReserve(CRED, WSTETH);
        assertEq(trigger.lastObservedDeficit(CRED, WSTETH), 40e18);
        assertEq(trigger.projectedGrossDeficit(CRED), 0, "add-time baseline, not zero");

        pool.createDeficit(WSTETH, 10e18);
        assertEq(trigger.projectedGrossDeficit(CRED), 10e18, "post-add increase counts");
    }

    // ------------------------------------------------- accumulator (gross)

    function test_checkpoint_accumulatesIncreases_exactly() public {
        _configureAndBind();

        pool.createDeficit(WETH, 42_123456789012345678);
        trigger.checkpoint(CRED);
        assertEq(trigger.grossDeficitAccumulated(CRED), 42_123456789012345678, "exact passthrough");

        pool.createDeficit(WETH, 7e18);
        trigger.checkpoint(CRED);
        assertEq(trigger.grossDeficitAccumulated(CRED), 49_123456789012345678, "increments sum");
    }

    function test_grossNotNet_eliminationCannotCureTheCounter() public {
        // THE core case: deficit is booked, checkpointed, then Umbrella (or a
        // friendly third party) eliminates it before anyone latches. The
        // gross accumulator must still latch — the loss was incurred.
        _configureAndBind();

        pool.createDeficit(WETH, 150e18);
        trigger.checkpoint(CRED);
        assertEq(trigger.grossDeficitAccumulated(CRED), 150e18);

        pool.eliminateDeficit(WETH, 150e18);
        trigger.checkpoint(CRED);
        assertEq(pool.getReserveDeficit(WETH), 0, "net deficit fully cured");
        assertEq(trigger.grossDeficitAccumulated(CRED), 150e18, "gross unmoved by cure");
        assertTrue(trigger.isTriggerable(CRED), "cure-before-latch does not disarm");

        trigger.latch(CRED);
        assertTrue(trigger.isTriggered(CRED), "latched on a fully cured counter");
    }

    function test_elimination_lowersBase_newDebtCountsAgain() public {
        // lastObserved follows the counter DOWN on elimination, so bad debt
        // booked after a cure is new gross deficit — no phantom suppression.
        _configureAndBind();

        pool.createDeficit(WETH, 60e18);
        trigger.checkpoint(CRED);
        pool.eliminateDeficit(WETH, 60e18);
        trigger.checkpoint(CRED);
        assertEq(trigger.lastObservedDeficit(CRED, WETH), 0, "base follows cure down");

        pool.createDeficit(WETH, 60e18);
        trigger.checkpoint(CRED);
        assertEq(trigger.grossDeficitAccumulated(CRED), 120e18, "re-incurred debt counts in full");
        assertTrue(trigger.isTriggerable(CRED));
    }

    function test_riseAndCureBetweenCheckpoints_isMissed_documentedLimit() public {
        // Poke-cadence caveat, stated honestly: a rise fully eliminated
        // before ANY checkpoint observes it cannot be attributed.
        _configureAndBind();

        pool.createDeficit(WETH, 150e18);
        pool.eliminateDeficit(WETH, 150e18); // cured before any observation
        trigger.checkpoint(CRED);
        assertEq(trigger.grossDeficitAccumulated(CRED), 0, "unobserved rise is lost");
        assertFalse(trigger.isTriggerable(CRED));
    }

    function test_multiReserve_sameDenomination_sums() public {
        _configureAndBind();
        vm.prank(ATTESTOR);
        trigger.addReserve(CRED, WSTETH);

        pool.createDeficit(WETH, 55e18);
        pool.createDeficit(WSTETH, 45e18);
        assertEq(trigger.projectedGrossDeficit(CRED), 100e18, "cross-reserve sum");
        assertTrue(trigger.isTriggerable(CRED), "inclusive at threshold");
    }

    // ------------------------------------------------------ mandate window

    function test_window_preStartIncreases_observedNotAttributed() public {
        // Mandate starts in the future; deficit booked and checkpointed
        // before the start moves the base but never the accumulator.
        vm.startPrank(ATTESTOR);
        trigger.configure(
            CRED, address(pool), THRESHOLD, uint64(block.timestamp + 1 days), 0
        );
        trigger.addReserve(CRED, WETH);
        vm.stopPrank();

        pool.createDeficit(WETH, 200e18);
        trigger.checkpoint(CRED);
        assertEq(trigger.grossDeficitAccumulated(CRED), 0, "pre-mandate: not attributed");
        assertEq(trigger.lastObservedDeficit(CRED, WETH), 200e18, "but the base moved");
        assertFalse(trigger.isTriggerable(CRED), "projection also excluded pre-window");

        // Inside the window the same reserve's NEW increases count.
        vm.warp(block.timestamp + 1 days);
        pool.createDeficit(WETH, 100e18);
        trigger.checkpoint(CRED);
        assertEq(trigger.grossDeficitAccumulated(CRED), 100e18, "in-window increase counts");
        assertTrue(trigger.isTriggerable(CRED));
    }

    function test_window_postEnd_observesButDoesNotAccumulate() public {
        uint64 end = uint64(block.timestamp + 30 days);
        vm.startPrank(ATTESTOR);
        trigger.configure(CRED, address(pool), THRESHOLD, mandateStart, end);
        trigger.addReserve(CRED, WETH);
        vm.stopPrank();

        pool.createDeficit(WETH, 60e18);
        trigger.checkpoint(CRED);
        assertEq(trigger.grossDeficitAccumulated(CRED), 60e18);

        // Mandate expires; a later deficit is somebody else's problem.
        vm.warp(end + 1);
        pool.createDeficit(WETH, 500e18);
        trigger.checkpoint(CRED);
        assertEq(trigger.grossDeficitAccumulated(CRED), 60e18, "post-mandate: not attributed");
        assertEq(trigger.lastObservedDeficit(CRED, WETH), 560e18, "base still tracks");
        assertFalse(trigger.isTriggerable(CRED));
    }

    function test_window_unpokedIncreaseAtExpiry_isLost_biasToSubject() public {
        // An increase nobody checkpointed before mandateEnd cannot be proven
        // to be in-window; the projection excludes it and the accumulator
        // never sees it. Watchtowers checkpoint before the window closes.
        uint64 end = uint64(block.timestamp + 30 days);
        vm.startPrank(ATTESTOR);
        trigger.configure(CRED, address(pool), THRESHOLD, mandateStart, end);
        trigger.addReserve(CRED, WETH);
        vm.stopPrank();

        pool.createDeficit(WETH, 300e18); // in-window rise, never poked
        vm.warp(end + 1);
        assertFalse(trigger.isTriggerable(CRED), "unattributable after expiry");
        trigger.checkpoint(CRED);
        assertEq(trigger.grossDeficitAccumulated(CRED), 0);
    }

    function test_window_accumulatedFactSurvivesExpiry() public {
        // A threshold crossing checkpointed in-window stays latchable after
        // the mandate ends: the fact was recorded while it was attributable.
        uint64 end = uint64(block.timestamp + 30 days);
        vm.startPrank(ATTESTOR);
        trigger.configure(CRED, address(pool), THRESHOLD, mandateStart, end);
        trigger.addReserve(CRED, WETH);
        vm.stopPrank();

        pool.createDeficit(WETH, 150e18);
        trigger.checkpoint(CRED);
        vm.warp(end + 365 days);
        assertTrue(trigger.isTriggerable(CRED), "recorded fact survives expiry");
        trigger.latch(CRED);
        assertTrue(trigger.isTriggered(CRED));
    }

    // ----------------------------------------------- projection + latching

    function test_projection_isTriggerableWithoutCheckpoint_latchMaterialises() public {
        // Nobody has poked, but the pool state proves the predicate: gates
        // read the projection, and a single permissionless latch call both
        // records the observation and latches on it.
        _configureAndBind();
        pool.createDeficit(WETH, 150e18);

        assertEq(trigger.grossDeficitAccumulated(CRED), 0, "nothing checkpointed yet");
        assertTrue(trigger.isTriggerable(CRED), "projection sees the pool live");

        vm.prank(address(0xDE9051709)); // any watcher
        trigger.latch(CRED);
        assertTrue(trigger.isTriggered(CRED));
        assertEq(trigger.grossDeficitAccumulated(CRED), 150e18, "latch materialised the observation");
        assertEq(trigger.triggeredAt(CRED), uint64(block.timestamp));
    }

    function test_thresholdBoundary_inclusive_belowReverts() public {
        _configureAndBind();

        pool.createDeficit(WETH, THRESHOLD - 1);
        assertFalse(trigger.isTriggerable(CRED));
        vm.expectRevert(AaveV3DeficitTrigger.NotTriggerable.selector);
        trigger.latch(CRED);

        pool.createDeficit(WETH, 1);
        assertTrue(trigger.isTriggerable(CRED), ">= threshold must be triggerable");
        trigger.latch(CRED);
    }

    function test_latch_permanent_doubleLatchReverts_scopeFrozen() public {
        _configureAndBind();
        pool.createDeficit(WETH, 150e18);
        trigger.latch(CRED);

        // Full cure after the latch changes nothing.
        pool.eliminateDeficit(WETH, 150e18);
        assertTrue(trigger.isTriggered(CRED), "no un-latch on cure");
        assertFalse(trigger.isTriggerable(CRED), "latched excludes triggerable");

        vm.expectRevert(AaveV3DeficitTrigger.NotTriggerable.selector);
        trigger.latch(CRED);

        // Scope is frozen at latch: the record the latch proved is final.
        vm.prank(ATTESTOR);
        vm.expectRevert(AaveV3DeficitTrigger.AlreadyLatched.selector);
        trigger.addReserve(CRED, WSTETH);
    }

    // -------------------------------------------------------- binding view

    function test_binding_encodesTheFullMandate() public {
        _configureAndBind();
        (
            uint256 chainId,
            address boundPool,
            uint256 threshold,
            uint64 start,
            uint64 end,
            address[] memory scope
        ) = abi.decode(
            trigger.binding(CRED), (uint256, address, uint256, uint64, uint64, address[])
        );
        assertEq(chainId, block.chainid);
        assertEq(boundPool, address(pool));
        assertEq(threshold, THRESHOLD);
        assertEq(start, mandateStart);
        assertEq(end, 0);
        assertEq(scope.length, 1);
        assertEq(scope[0], WETH);
    }
}
