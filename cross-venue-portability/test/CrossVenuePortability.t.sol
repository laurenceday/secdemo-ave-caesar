// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {WildcatDelinquencyTrigger} from "../src/WildcatDelinquencyTrigger.sol";
import {AaveV3DeficitTrigger} from "../src/AaveV3DeficitTrigger.sol";
import {CrossVenueConsumer} from "../src/CrossVenueConsumer.sol";
import {MockSealedRegistry, MockWildcatMarket, MockAaveV3Pool} from "./mocks/Mocks.sol";

contract CrossVenuePortabilityTest is Test {
    bytes32 constant CRED = keccak256("shared-entity-credential");
    address constant ENTITY = address(0xE471717); // one wallet, one onboarding
    address constant ATTESTOR = address(0xA77E5);
    address constant WATCHER = address(0xDE9051709);

    // Wildcat venue: 3-day grace + 90-day extension.
    uint32 constant GRACE = 3 days;
    uint32 constant EXTENSION = 90 days;
    // Aave venue: 100 WETH gross deficit.
    address constant WETH = address(0x11E7);
    uint256 constant DEFICIT_THRESHOLD = 100e18;

    MockSealedRegistry registry;
    WildcatDelinquencyTrigger wildcat;
    AaveV3DeficitTrigger aave;
    MockWildcatMarket market;
    MockAaveV3Pool pool;

    CrossVenueConsumer venueWildcat; // pins only the Wildcat class
    CrossVenueConsumer venueAave;    // pins only the Aave class
    CrossVenueConsumer venuePortable; // pins both: strict shared-consequence

    bytes32 wildcatClass;
    bytes32 aaveClass;

    function setUp() public {
        vm.warp(1_752_000_000);

        registry = new MockSealedRegistry();
        wildcat = new WildcatDelinquencyTrigger(address(registry));
        aave = new AaveV3DeficitTrigger(address(registry));
        market = new MockWildcatMarket();
        pool = new MockAaveV3Pool();
        wildcatClass = wildcat.TRIGGER_CLASS();
        aaveClass = aave.TRIGGER_CLASS();

        // ONE credential, issued once, binding BOTH venues' trigger classes.
        address[] memory trigs = new address[](2);
        trigs[0] = address(wildcat);
        trigs[1] = address(aave);
        bytes32[] memory classes = new bytes32[](2);
        classes[0] = wildcatClass;
        classes[1] = aaveClass;
        registry.setCredential(
            CRED, keccak256("entity/v1"), ATTESTOR, uint64(block.timestamp), 0, false, trigs, classes
        );
        registry.setWallet(ENTITY, CRED);

        market.setDelinquencyGracePeriod(GRACE);
        vm.startPrank(ATTESTOR);
        wildcat.configure(CRED, address(market), EXTENSION);
        aave.configure(CRED, address(pool), DEFICIT_THRESHOLD, uint64(block.timestamp), 0);
        aave.addReserve(CRED, WETH);
        vm.stopPrank();

        // Venue consumers.
        bytes32[] memory w = new bytes32[](1);
        w[0] = wildcatClass;
        venueWildcat = new CrossVenueConsumer(address(registry), w);
        bytes32[] memory a = new bytes32[](1);
        a[0] = aaveClass;
        venueAave = new CrossVenueConsumer(address(registry), a);
        bytes32[] memory both = new bytes32[](2);
        both[0] = wildcatClass;
        both[1] = aaveClass;
        venuePortable = new CrossVenueConsumer(address(registry), both);
    }

    function test_oneOnboarding_bothVenuesAccept() public {
        assertTrue(venueWildcat.accepts(ENTITY), "Wildcat venue accepts");
        assertTrue(venueAave.accepts(ENTITY), "Aave venue accepts");
        assertTrue(venuePortable.accepts(ENTITY), "portable venue accepts");
        assertEq(venuePortable.latchedClasses(CRED).length, 0, "clean everywhere");
    }

    function test_portableRequiresBothClassesBound() public {
        // A credential that binds only the Wildcat class is unusable at the
        // portable venue (which requires both) but fine at the Wildcat venue.
        bytes32 partialCred = keccak256("wildcat-only");
        address[] memory trigs = new address[](1);
        trigs[0] = address(wildcat);
        bytes32[] memory classes = new bytes32[](1);
        classes[0] = wildcatClass;
        registry.setCredential(
            partialCred, keccak256("entity/v1"), ATTESTOR, uint64(block.timestamp), 0, false, trigs, classes
        );
        address w = address(0xB0B);
        registry.setWallet(w, partialCred);
        vm.prank(ATTESTOR);
        wildcat.configure(partialCred, address(market), EXTENSION);

        assertTrue(venueWildcat.accepts(w), "Wildcat venue: one class is enough");
        assertFalse(venuePortable.accepts(w), "portable venue: needs both classes bound");
    }

    function test_wildcatDefault_isVisibleAcrossVenues() public {
        // The borrower goes delinquent past grace + extension in the Wildcat
        // venue. Nobody has latched yet — gates read projections.
        market.setTimeDelinquent(uint32(GRACE + EXTENSION + 1));
        assertTrue(wildcat.isTriggerable(CRED));

        assertFalse(venueWildcat.accepts(ENTITY), "Wildcat venue rejects its own default");
        assertTrue(venueAave.accepts(ENTITY), "Aave-only venue is isolated (its class is clean)");
        assertFalse(venuePortable.accepts(ENTITY), "portable venue sees the default (shared surface)");

        // A watcher latches in the Wildcat venue: now a permanent registry
        // fact, and it reads back through the SAME credential at the Aave
        // venue's portability-aware consumer.
        vm.prank(WATCHER);
        wildcat.latch(CRED);
        bytes32[] memory hits = venuePortable.latchedClasses(CRED);
        assertEq(hits.length, 1, "one latched class visible");
        assertEq(hits[0], wildcatClass, "it is the Wildcat class");

        // A borrower cure after the latch cannot restore acceptance anywhere
        // that reads the Wildcat class.
        market.setTimeDelinquent(0);
        assertTrue(wildcat.isTriggered(CRED), "latch is permanent");
        assertFalse(venuePortable.accepts(ENTITY), "cure does not un-latch");
        assertTrue(venueAave.accepts(ENTITY), "Aave-only venue still fine (never bound Wildcat)");
    }

    function test_aaveLoss_isVisibleAcrossVenues() public {
        // Symmetric: realised deficit in the Aave venue.
        pool.createDeficit(WETH, 150e18);
        assertTrue(aave.isTriggerable(CRED));

        assertFalse(venueAave.accepts(ENTITY), "Aave venue rejects its own loss");
        assertTrue(venueWildcat.accepts(ENTITY), "Wildcat-only venue is isolated");
        assertFalse(venuePortable.accepts(ENTITY), "portable venue sees the loss");

        vm.prank(WATCHER);
        aave.latch(CRED);
        bytes32[] memory hits = venuePortable.latchedClasses(CRED);
        assertEq(hits.length, 1);
        assertEq(hits[0], aaveClass, "the Aave class is the visible latch");
    }

    function test_bothVenuesLatch_portableSeesBoth() public {
        market.setTimeDelinquent(uint32(GRACE + EXTENSION + 1));
        pool.createDeficit(WETH, 150e18);
        vm.startPrank(WATCHER);
        wildcat.latch(CRED);
        aave.latch(CRED);
        vm.stopPrank();

        bytes32[] memory hits = venuePortable.latchedClasses(CRED);
        assertEq(hits.length, 2, "both venues' latches visible on one credential");
    }

    function test_sharedRevocationAndExpiry() public {
        // One credential's lifecycle governs every venue at once.
        registry.setRevoked(CRED, true);
        assertFalse(venueWildcat.accepts(ENTITY));
        assertFalse(venueAave.accepts(ENTITY));
        assertFalse(venuePortable.accepts(ENTITY));
        registry.setRevoked(CRED, false);
        assertTrue(venuePortable.accepts(ENTITY));
    }
}
