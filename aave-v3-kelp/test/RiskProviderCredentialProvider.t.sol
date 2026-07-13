// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AaveV3DeficitTrigger} from "../src/AaveV3DeficitTrigger.sol";
import {RiskProviderCredentialProvider} from "../src/RiskProviderCredentialProvider.sol";
import {MockSealedRegistry, MockAaveV3Pool, MockLatchTrigger} from "./mocks/Mocks.sol";

contract RiskProviderCredentialProviderTest is Test {
    uint256 constant THRESHOLD = 100e18;
    bytes32 constant CRED = keccak256("risk-provider-credential");
    address constant WETH = address(0x11E7);
    address constant ATTESTOR = address(0xA77E5);
    address constant PROVIDER_WALLET = address(0xC0FFEE);

    MockSealedRegistry registry;
    AaveV3DeficitTrigger trigger;
    RiskProviderCredentialProvider provider;
    MockAaveV3Pool pool;

    uint64 issuedAt;

    function setUp() public {
        registry = new MockSealedRegistry();
        trigger = new AaveV3DeficitTrigger(address(registry));
        provider = new RiskProviderCredentialProvider(address(registry));
        pool = new MockAaveV3Pool();

        issuedAt = uint64(block.timestamp);
        _issue(CRED, keccak256("entity/v1"), 0, address(trigger), trigger.TRIGGER_CLASS());
        registry.setWallet(PROVIDER_WALLET, CRED);

        vm.startPrank(ATTESTOR);
        trigger.configure(CRED, address(pool), THRESHOLD, issuedAt, 0);
        trigger.addReserve(CRED, WETH);
        vm.stopPrank();
    }

    function _issue(
        bytes32 id,
        bytes32 profile,
        uint64 expiresAt,
        address trig,
        bytes32 klass
    ) internal {
        address[] memory trigs = new address[](1);
        trigs[0] = trig;
        bytes32[] memory classes = new bytes32[](1);
        classes[0] = klass;
        registry.setCredential(id, profile, ATTESTOR, issuedAt, expiresAt, false, trigs, classes);
    }

    // ------------------------------------------------------------- grants

    function test_grant_isIssuedAt_pullProvider() public {
        assertTrue(provider.isPullProvider());
        assertEq(provider.getCredential(PROVIDER_WALLET), uint32(issuedAt));
        assertEq(provider.validateCredential(PROVIDER_WALLET, ""), uint32(issuedAt));
    }

    function test_noCredential_noGrant() public {
        assertEq(provider.getCredential(address(0xDEAD)), 0);
    }

    function test_wrongProfile_noGrant() public {
        bytes32 id = keccak256("wrong-profile");
        _issue(id, keccak256("something/v9"), 0, address(trigger), trigger.TRIGGER_CLASS());
        address w = address(0xBEEF);
        registry.setWallet(w, id);
        assertEq(provider.getCredential(w), 0);
    }

    function test_revoked_noGrant() public {
        registry.setRevoked(CRED, true);
        assertEq(provider.getCredential(PROVIDER_WALLET), 0);
        registry.setRevoked(CRED, false);
        assertGt(provider.getCredential(PROVIDER_WALLET), 0);
    }

    function test_expired_noGrant() public {
        bytes32 id = keccak256("expiring");
        _issue(id, keccak256("entity/v1"), uint64(block.timestamp + 1 days), address(trigger), trigger.TRIGGER_CLASS());
        address w = address(0xBEEF);
        registry.setWallet(w, id);
        vm.startPrank(ATTESTOR);
        trigger.configure(id, address(pool), THRESHOLD, issuedAt, 0);
        trigger.addReserve(id, WETH);
        vm.stopPrank();

        assertGt(provider.getCredential(w), 0, "granted while live");
        vm.warp(block.timestamp + 1 days);
        assertEq(provider.getCredential(w), 0, "stale credential grants nothing");
    }

    function test_wrongTriggerClass_noGrant() public {
        // A Wildcat borrower's credential is not a risk-provider credential.
        bytes32 id = keccak256("borrower-credential");
        MockLatchTrigger wrong = new MockLatchTrigger(keccak256("WILDCAT_DELINQ_90D_V1"));
        _issue(id, keccak256("entity/v1"), 0, address(wrong), wrong.klass());
        address w = address(0xBEEF);
        registry.setWallet(w, id);
        assertEq(provider.getCredential(w), 0, "class pinned, not just any trigger");
    }

    function test_unconfiguredMandate_noGrant() public {
        // Bound to the right class but never configured: the trigger can
        // never latch, so the credential is not consequence-bearing.
        bytes32 id = keccak256("toothless");
        _issue(id, keccak256("entity/v1"), 0, address(trigger), trigger.TRIGGER_CLASS());
        address w = address(0xBEEF);
        registry.setWallet(w, id);
        assertEq(provider.getCredential(w), 0, "unconfigured trigger refused");

        // Configured but with an empty scope is equally toothless.
        vm.prank(ATTESTOR);
        trigger.configure(id, address(pool), THRESHOLD, issuedAt, 0);
        assertEq(provider.getCredential(w), 0, "empty scope refused");

        vm.prank(ATTESTOR);
        trigger.addReserve(id, WETH);
        assertGt(provider.getCredential(w), 0, "granted once consequence-bearing");
    }

    // ----------------------------------------------------- loss lifecycle

    function test_lifecycle_lossKillsGrant_latchConfirms() public {
        // Healthy: granted.
        assertGt(provider.getCredential(PROVIDER_WALLET), 0);

        // 99.99..: still granted — calibration matters.
        pool.createDeficit(WETH, THRESHOLD - 1);
        assertGt(provider.getCredential(PROVIDER_WALLET), 0, "sub-threshold tolerated");

        // One more wei of deficit: the grant dies the moment the predicate
        // is provable, BEFORE anyone latches (gates read projections).
        pool.createDeficit(WETH, 1);
        assertTrue(trigger.isTriggerable(CRED));
        assertEq(provider.getCredential(PROVIDER_WALLET), 0, "latchable => grant withdrawn");

        // Permissionless latch confirms; grant stays dead forever after,
        // even once the deficit is fully cured.
        vm.prank(address(0xDE9051709));
        trigger.latch(CRED);
        pool.eliminateDeficit(WETH, THRESHOLD);
        assertEq(provider.getCredential(PROVIDER_WALLET), 0, "latched => grant withdrawn");
        assertTrue(trigger.isTriggered(CRED));
    }
}
