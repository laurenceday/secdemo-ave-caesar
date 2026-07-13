// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AaveV4SpokeTrigger} from "../src/AaveV4SpokeTrigger.sol";
import {SpokeOperatorCredentialProvider} from "../src/SpokeOperatorCredentialProvider.sol";
import {SpokeAllocator} from "../src/SpokeAllocator.sol";
import {MockSealedRegistry, MockAaveV4Hub, MockLatchTrigger, MockERC20} from "./mocks/Mocks.sol";

contract SpokeOperatorProviderAndAllocatorTest is Test {
    uint256 constant RAY = 1e27;
    uint256 constant THRESHOLD_RAY = 100e18 * RAY;
    uint256 constant FLOOR_RAY = 1e18 * RAY;

    bytes32 constant CRED = keccak256("spoke-operator-credential");
    uint256 constant WETH_ID = 1;
    address constant SPOKE = address(0x590CE);
    address constant ATTESTOR = address(0xA77E5);
    address constant OPERATOR_WALLET = address(0xC0FFEE);
    address constant MANAGER = address(0xA110);
    address constant DEPOSITOR = address(0xDE905);

    MockSealedRegistry registry;
    AaveV4SpokeTrigger trigger;
    SpokeOperatorCredentialProvider provider;
    MockAaveV4Hub hub;
    MockERC20 weth;
    SpokeAllocator allocator;

    uint64 issuedAt;

    function setUp() public {
        registry = new MockSealedRegistry();
        trigger = new AaveV4SpokeTrigger(address(registry));
        provider = new SpokeOperatorCredentialProvider(address(registry));
        hub = new MockAaveV4Hub();
        weth = new MockERC20();
        allocator = new SpokeAllocator(address(registry), address(weth), MANAGER);

        issuedAt = uint64(block.timestamp);
        _issue(CRED, keccak256("entity/v1"), 0, address(trigger), trigger.TRIGGER_CLASS());
        registry.setWallet(OPERATOR_WALLET, CRED);

        hub.setSpokeConfig(WETH_ID, SPOKE, 1_000_000, 500_000, true);
        vm.startPrank(ATTESTOR);
        trigger.configure(CRED, address(hub), SPOKE, THRESHOLD_RAY, FLOOR_RAY, issuedAt, 0);
        trigger.addAsset(CRED, WETH_ID);
        vm.stopPrank();
        trigger.checkpoint(CRED);

        weth.mint(DEPOSITOR, 100e18);
        vm.prank(DEPOSITOR);
        weth.approve(address(allocator), type(uint256).max);
    }

    function _issue(bytes32 id, bytes32 profile, uint64 expiresAt, address trig, bytes32 klass)
        internal
    {
        address[] memory trigs = new address[](1);
        trigs[0] = trig;
        bytes32[] memory classes = new bytes32[](1);
        classes[0] = klass;
        registry.setCredential(id, profile, ATTESTOR, issuedAt, expiresAt, false, trigs, classes);
    }

    // ------------------------------------------------------------- provider

    function test_provider_grantAndStandardRefusals() public {
        assertTrue(provider.isPullProvider());
        assertEq(provider.getCredential(OPERATOR_WALLET), uint32(issuedAt));
        assertEq(provider.getCredential(address(0xDEAD)), 0, "no credential, no grant");

        registry.setRevoked(CRED, true);
        assertEq(provider.getCredential(OPERATOR_WALLET), 0, "revoked");
        registry.setRevoked(CRED, false);

        bytes32 wrongProfile = keccak256("wrong-profile");
        _issue(wrongProfile, keccak256("something/v9"), 0, address(trigger), trigger.TRIGGER_CLASS());
        address w = address(0xBEEF);
        registry.setWallet(w, wrongProfile);
        assertEq(provider.getCredential(w), 0, "profile pinned");
    }

    function test_provider_wrongClassAndUnconfiguredRefused() public {
        bytes32 borrower = keccak256("borrower-credential");
        MockLatchTrigger wrong = new MockLatchTrigger(keccak256("WILDCAT_DELINQ_90D_V1"));
        _issue(borrower, keccak256("entity/v1"), 0, address(wrong), wrong.klass());
        address w = address(0xBEEF);
        registry.setWallet(w, borrower);
        assertEq(provider.getCredential(w), 0, "class pinned");

        bytes32 toothless = keccak256("toothless");
        _issue(toothless, keccak256("entity/v1"), 0, address(trigger), trigger.TRIGGER_CLASS());
        address w2 = address(0xFEED);
        registry.setWallet(w2, toothless);
        assertEq(provider.getCredential(w2), 0, "unconfigured mandate refused");
    }

    function test_provider_bothLimbsKillTheGrant() public {
        assertGt(provider.getCredential(OPERATOR_WALLET), 0);

        // Limb 2: floor-clearing deficit + zeroed line.
        hub.reportDeficit(WETH_ID, SPOKE, 50e18 * RAY);
        assertGt(provider.getCredential(OPERATOR_WALLET), 0, "below limb-1 threshold: granted");
        hub.setSpokeConfig(WETH_ID, SPOKE, 1_000_000, 0, true);
        assertEq(provider.getCredential(OPERATOR_WALLET), 0, "sanction provable: grant dies");

        // Un-sanction (below any checkpoint): grant returns — then limb 1.
        hub.setSpokeConfig(WETH_ID, SPOKE, 1_000_000, 500_000, true);
        assertGt(provider.getCredential(OPERATOR_WALLET), 0);
        hub.reportDeficit(WETH_ID, SPOKE, 50e18 * RAY); // total 100 = threshold
        assertEq(provider.getCredential(OPERATOR_WALLET), 0, "limb 1 reached: grant dies");
    }

    // ------------------------------------------------------------ allocator

    function test_allocator_registerRequiresClass() public {
        bytes32 borrower = keccak256("borrower-credential");
        MockLatchTrigger wrong = new MockLatchTrigger(keccak256("WILDCAT_DELINQ_90D_V1"));
        _issue(borrower, keccak256("entity/v1"), 0, address(wrong), wrong.klass());

        vm.startPrank(MANAGER);
        vm.expectRevert(SpokeAllocator.CredentialNotConsequenceBearing.selector);
        allocator.registerSpoke(SPOKE, borrower);
        allocator.registerSpoke(SPOKE, CRED);
        vm.stopPrank();
        assertTrue(allocator.spokeHealthy(SPOKE));
    }

    function test_allocator_demoFlow_freezeNewExposureOnly() public {
        // The demo script, end to end: healthy allocation → bad debt →
        // refusal of NEW exposure while a withdrawal still succeeds.
        vm.prank(MANAGER);
        allocator.registerSpoke(SPOKE, CRED);

        vm.prank(DEPOSITOR);
        allocator.deposit(100e18);

        vm.startPrank(MANAGER);
        allocator.allocate(SPOKE, 60e18);
        assertTrue(allocator.approveCreditIncrease(SPOKE, 600_000), "healthy: endorsed");
        vm.stopPrank();
        assertEq(weth.balanceOf(SPOKE), 60e18);
        (,, uint256 exposure) = allocator.spokes(SPOKE);
        assertEq(exposure, 60e18);

        // The spoke books threshold-clearing bad debt on the hub. NOTHING has
        // been checkpointed or latched — gates read projections.
        hub.reportDeficit(WETH_ID, SPOKE, 150e18 * RAY);
        assertFalse(allocator.spokeHealthy(SPOKE));

        vm.startPrank(MANAGER);
        vm.expectRevert(SpokeAllocator.SpokeLatchedOrLatchable.selector);
        allocator.allocate(SPOKE, 10e18);
        vm.expectRevert(SpokeAllocator.SpokeLatchedOrLatchable.selector);
        allocator.approveCreditIncrease(SPOKE, 700_000);
        vm.stopPrank();

        // A random watcher latches; refusals persist.
        vm.prank(address(0xDE9051709));
        trigger.latch(CRED);
        vm.prank(MANAGER);
        vm.expectRevert(SpokeAllocator.SpokeLatchedOrLatchable.selector);
        allocator.allocate(SPOKE, 10e18);

        // Existing exposure untouched — there is no clawback surface at all —
        // and the depositor's withdrawal of idle liquidity succeeds.
        (,, uint256 exposureAfter) = allocator.spokes(SPOKE);
        assertEq(exposureAfter, 60e18, "existing position not confiscated");
        vm.prank(DEPOSITOR);
        allocator.withdraw(40e18);
        assertEq(weth.balanceOf(DEPOSITOR), 40e18, "withdrawal succeeds post-latch");

        // A latched spoke repaying is still accepted.
        vm.prank(SPOKE);
        weth.transfer(address(allocator), 60e18);
        vm.prank(MANAGER);
        allocator.onReturned(SPOKE, 60e18);
        (,, uint256 exposureFinal) = allocator.spokes(SPOKE);
        assertEq(exposureFinal, 0);
        vm.prank(DEPOSITOR);
        allocator.withdraw(60e18);
        assertEq(weth.balanceOf(DEPOSITOR), 100e18, "made whole from repayment");
    }

    function test_allocator_managerGating() public {
        vm.expectRevert(SpokeAllocator.NotManager.selector);
        allocator.registerSpoke(SPOKE, CRED);
        vm.expectRevert(SpokeAllocator.NotManager.selector);
        allocator.allocate(SPOKE, 1);
    }
}
