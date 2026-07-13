// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AaveV3DeficitTrigger, IAaveV3PoolLike} from "../../src/AaveV3DeficitTrigger.sol";
import {RiskProviderCredentialProvider} from "../../src/RiskProviderCredentialProvider.sol";
import {MockSealedRegistry} from "../mocks/Mocks.sol";

/// @notice The Kelp backtest: replays the April 2026 KelpDAO rsETH bridge
///         exploit against the REAL Aave V3 mainnet Pool's deficit counter.
///
///         "This credential, had it existed on 17 April, latches on 18 April
///         with no human judgement involved."
///
///         The test forks mainnet at a block shortly before the exploit
///         (2026-04-18 ~17:38 UTC per public reporting), binds a
///         WETH-denominated risk mandate, checkpoints (accumulator = 0: the
///         bind-time baseline swallows any pre-event deficit history), rolls
///         the fork past the event's bad-debt liquidations, checkpoints
///         again, and asserts the latch. A counter-credential with a
///         threshold above the realised loss binds at the same pre-event
///         block and does NOT latch — calibration matters in both directions.
///
///         Skipped unless MAINNET_RPC_URL is set (needs an ARCHIVE node for
///         April 2026 state). The default block numbers are timestamp
///         ESTIMATES — pin the exact deficit-booking blocks with
///         script/deficit_scan.py (DeficitCreated events on the Pool) and
///         override via FORK_BLOCK_PRE / FORK_BLOCK_POST before treating a
///         green run as the canonical backtest. If the WETH deficit was
///         partially eliminated (Umbrella / DeFi United recapitalisation)
///         before FORK_BLOCK_POST, the two-checkpoint gross UNDERSTATES the
///         true gross — choose FORK_BLOCK_POST after the bookings but before
///         eliminations for the full figure.
contract AaveV3DeficitTriggerKelpForkTest is Test {
    // Aave V3 Ethereum core Pool (proxy) + WETH underlying. VERIFY against
    // current address book before relying on a green run.
    address constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Timestamp estimates for ~2026-04-17 (pre) and ~2026-04-27 (post).
    // NOT verified block numbers — see the contract natspec.
    uint256 constant DEFAULT_BLOCK_PRE = 24_530_000;
    uint256 constant DEFAULT_BLOCK_POST = 24_600_000;

    // 1,000 WETH: far below the reported event loss (est. tens of thousands
    // of WETH), comfortably above background deficit noise.
    uint256 constant DEFAULT_THRESHOLD = 1_000e18;
    // 200,000 WETH: far above any reported figure for the event — the
    // counter-run credential must NOT latch.
    uint256 constant DEFAULT_THRESHOLD_HIGH = 200_000e18;

    bytes32 constant CRED = keccak256("kelp-mandate");
    bytes32 constant CRED_HIGH = keccak256("kelp-mandate-high-threshold");
    address constant ATTESTOR = address(0xA77E5);
    address constant PROVIDER_WALLET = address(0xC0FFEE);

    function test_fork_kelpBacktest_grossDeficitLatches() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 blockPre = vm.envOr("FORK_BLOCK_PRE", DEFAULT_BLOCK_PRE);
        uint256 blockPost = vm.envOr("FORK_BLOCK_POST", DEFAULT_BLOCK_POST);
        uint256 threshold = vm.envOr("KELP_THRESHOLD", DEFAULT_THRESHOLD);
        uint256 thresholdHigh = vm.envOr("KELP_THRESHOLD_HIGH", DEFAULT_THRESHOLD_HIGH);
        address reserve = vm.envOr("KELP_RESERVE", WETH);

        // ---------------- 17 April: the world before the event ----------------
        vm.createSelectFork(rpc, blockPre);
        emit log_named_uint("PRE  block", block.number);
        emit log_named_uint("PRE  timestamp", block.timestamp);

        MockSealedRegistry registry = new MockSealedRegistry();
        AaveV3DeficitTrigger trigger = new AaveV3DeficitTrigger(address(registry));
        RiskProviderCredentialProvider provider =
            new RiskProviderCredentialProvider(address(registry));
        vm.makePersistent(address(registry));
        vm.makePersistent(address(trigger));
        vm.makePersistent(address(provider));

        address[] memory trigs = new address[](1);
        trigs[0] = address(trigger);
        bytes32[] memory classes = new bytes32[](1);
        classes[0] = trigger.TRIGGER_CLASS();
        registry.setCredential(
            CRED, keccak256("entity/v1"), ATTESTOR, uint64(block.timestamp), 0, false, trigs, classes
        );
        registry.setCredential(
            CRED_HIGH, keccak256("entity/v1"), ATTESTOR, uint64(block.timestamp), 0, false, trigs, classes
        );
        registry.setWallet(PROVIDER_WALLET, CRED);

        // Bind both mandates against live pre-event state.
        vm.startPrank(ATTESTOR);
        trigger.configure(CRED, AAVE_V3_POOL, threshold, uint64(block.timestamp), 0);
        trigger.addReserve(CRED, reserve);
        trigger.configure(CRED_HIGH, AAVE_V3_POOL, thresholdHigh, uint64(block.timestamp), 0);
        trigger.addReserve(CRED_HIGH, reserve);
        vm.stopPrank();

        uint256 preDeficit = IAaveV3PoolLike(AAVE_V3_POOL).getReserveDeficit(reserve);
        emit log_named_uint("PRE  reserve deficit (wei)", preDeficit);

        // Pre-event checkpoint: whatever deficit history the reserve carries
        // was swallowed by the bind-time baseline. Accumulator == 0.
        trigger.checkpoint(CRED);
        trigger.checkpoint(CRED_HIGH);
        assertEq(trigger.grossDeficitAccumulated(CRED), 0, "pre-event accumulator must be zero");
        assertFalse(trigger.isTriggerable(CRED), "healthy world: not triggerable");
        assertGt(provider.getCredential(PROVIDER_WALLET), 0, "healthy world: granted");

        // ---------------- 18 April and after: the event books ----------------
        vm.rollFork(blockPost);
        emit log_named_uint("POST block", block.number);
        emit log_named_uint("POST timestamp", block.timestamp);

        uint256 postDeficit = IAaveV3PoolLike(AAVE_V3_POOL).getReserveDeficit(reserve);
        emit log_named_uint("POST reserve deficit (wei)", postDeficit);

        trigger.checkpoint(CRED);
        uint256 gross = trigger.grossDeficitAccumulated(CRED);
        emit log_named_uint("gross deficit attributed (wei)", gross);
        assertGe(
            gross,
            threshold,
            "no threshold-clearing deficit delta between the fork blocks: verify blocks with script/deficit_scan.py"
        );

        // The grant died with the event; the latch is permissionless.
        assertTrue(trigger.isTriggerable(CRED));
        assertEq(provider.getCredential(PROVIDER_WALLET), 0, "grant withdrawn on the event");
        vm.prank(address(0xDE9051709)); // any watcher
        trigger.latch(CRED);
        assertTrue(trigger.isTriggered(CRED), "latched with no human judgement involved");

        // ---------------- counter-run: calibration matters ----------------
        trigger.checkpoint(CRED_HIGH);
        uint256 grossHigh = trigger.grossDeficitAccumulated(CRED_HIGH);
        assertEq(grossHigh, gross, "same scope, same observation");
        assertLt(grossHigh, thresholdHigh, "event loss must sit below the high threshold");
        assertFalse(trigger.isTriggerable(CRED_HIGH), "threshold above the loss: no latch");
        vm.expectRevert(AaveV3DeficitTrigger.NotTriggerable.selector);
        trigger.latch(CRED_HIGH);
    }
}
