#!/usr/bin/env python3
"""Runtime verification on a local EVM (py-evm via eth-tester).

Deploys the compiled artifacts and executes the core flows end-to-end:
mandate configuration, both trigger limbs (gross-deficit accumulator and
the guarded hub-sanction limb), the provider's grant lifecycle, and the
allocator's freeze-new-exposure-only consequence — the full demo script:
toy spoke healthy → bad debt → latch → new allocation refused while a
withdrawal still succeeds.

This complements (does not replace) the forge test suite: forge-std
cheatcode tests run under `forge test`; this file proves execution in
environments without the foundry toolchain.
"""
import json
import sys

from eth_tester import EthereumTester, PyEVMBackend
from web3 import Web3, EthereumTesterProvider

ARTIFACTS = json.load(open("script/artifacts.json"))

tester = EthereumTester(PyEVMBackend())
w3 = Web3(EthereumTesterProvider(tester))
OWNER, ATTESTOR, SUBJECT, WATCHER, MANAGER, DEPOSITOR = w3.eth.accounts[:6]

RAY = 10**27
THRESHOLD_RAY = 100 * 10**18 * RAY  # 100 WETH
FLOOR_RAY = 1 * 10**18 * RAY        # 1 WETH sanction floor
WETH_ID = 1
SPOKE = Web3.to_checksum_address("0x000000000000000000000000000000000005903e")
PASS = FAIL = 0


def deploy(name, *args, frm=None):
    a = ARTIFACTS[name]
    c = w3.eth.contract(abi=a["abi"], bytecode=a["bin"])
    tx = c.constructor(*args).transact({"from": frm or OWNER})
    rcpt = w3.eth.wait_for_transaction_receipt(tx)
    return w3.eth.contract(address=rcpt.contractAddress, abi=a["abi"])


def check(label, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {label}")
    else:
        FAIL += 1
        print(f"  FAIL  {label}")


def expect_revert(label, fn):
    global PASS, FAIL
    try:
        fn()
        FAIL += 1
        print(f"  FAIL  {label} (no revert)")
    except Exception:
        PASS += 1
        print(f"  PASS  {label} (reverted)")


def now():
    return w3.eth.get_block("latest")["timestamp"]


kek = lambda s: Web3.keccak(text=s)
CLASS = kek("AAVE_V4_SPOKE_GROSS_DEFICIT_V1")


def issue(registry, trigger_addr, cred, klass, wallet=None):
    registry.functions.setCredential(
        cred, kek("entity/v1"), ATTESTOR, now(), 0, False, [trigger_addr], [klass]
    ).transact({"from": OWNER})
    if wallet:
        registry.functions.setWallet(wallet, cred).transact({"from": OWNER})


# ---------------------------------------------------------------- limb 1
print("== AaveV4SpokeTrigger: limb 1 (gross deficit) ==")
registry = deploy("MockSealedRegistry")
trigger = deploy("AaveV4SpokeTrigger", registry.address)
hub = deploy("MockAaveV4Hub")
CRED = kek("spoke-operator-credential")
issue(registry, trigger.address, CRED, CLASS, wallet=SUBJECT)

hub.functions.setSpokeConfig(WETH_ID, SPOKE, 1_000_000, 500_000, True).transact({"from": OWNER})
expect_revert("configure gated to attestor",
              lambda: trigger.functions.configure(
                  CRED, hub.address, SPOKE, THRESHOLD_RAY, FLOOR_RAY, now(), 0
              ).transact({"from": SUBJECT}))
trigger.functions.configure(CRED, hub.address, SPOKE, THRESHOLD_RAY, FLOOR_RAY, now(), 0)\
    .transact({"from": ATTESTOR})

# Pre-existing deficit swallowed by add-time baseline.
hub.functions.reportDeficit(WETH_ID, SPOKE, 500 * 10**18 * RAY).transact({"from": OWNER})
trigger.functions.addAsset(CRED, WETH_ID).transact({"from": ATTESTOR})
check("baseline = live counter at add",
      trigger.functions.lastObservedDeficitRay(CRED, WETH_ID).call() == 500 * 10**18 * RAY)
check("history does not count", trigger.functions.projectedGrossDeficitRay(CRED).call() == 0)
trigger.functions.checkpoint(CRED).transact({"from": WATCHER})  # records capEverPositive

hub.functions.reportDeficit(WETH_ID, SPOKE, 150 * 10**18 * RAY).transact({"from": OWNER})
trigger.functions.checkpoint(CRED).transact({"from": WATCHER})
check("increase checkpointed exactly",
      trigger.functions.grossDeficitAccumulatedRay(CRED).call() == 150 * 10**18 * RAY)

hub.functions.eliminateDeficit(WETH_ID, SPOKE, 150 * 10**18 * RAY).transact({"from": OWNER})
trigger.functions.checkpoint(CRED).transact({"from": WATCHER})
check("gross unmoved by role-gated elimination",
      trigger.functions.grossDeficitAccumulatedRay(CRED).call() == 150 * 10**18 * RAY)
check("cure-before-latch does not disarm", trigger.functions.isTriggerable(CRED).call())
trigger.functions.latch(CRED).transact({"from": WATCHER})
check("permissionless latch on a cured counter", trigger.functions.isTriggered(CRED).call())
expect_revert("double latch reverts",
              lambda: trigger.functions.latch(CRED).transact({"from": WATCHER}))
expect_revert("scope frozen post-latch",
              lambda: trigger.functions.addAsset(CRED, 2).transact({"from": ATTESTOR}))

# ---------------------------------------------------------------- limb 2
print("== AaveV4SpokeTrigger: limb 2 (guarded hub sanction) ==")
CRED2 = kek("limb2-credential")
issue(registry, trigger.address, CRED2, CLASS)
SPOKE2 = Web3.to_checksum_address("0x000000000000000000000000000000000005903f")
hub.functions.setSpokeConfig(WETH_ID, SPOKE2, 1_000_000, 0, True).transact({"from": OWNER})
trigger.functions.configure(CRED2, hub.address, SPOKE2, THRESHOLD_RAY, FLOOR_RAY, now(), 0)\
    .transact({"from": ATTESTOR})
trigger.functions.addAsset(CRED2, WETH_ID).transact({"from": ATTESTOR})
trigger.functions.checkpoint(CRED2).transact({"from": WATCHER})

# Fee-receiver shape: line never positive; floor-clearing deficit alone must not arm.
hub.functions.reportDeficit(WETH_ID, SPOKE2, 50 * 10**18 * RAY).transact({"from": OWNER})
trigger.functions.checkpoint(CRED2).transact({"from": WATCHER})
check("never-positive line cannot arm the sanction",
      trigger.functions.sanctionObservedAt(CRED2).call() == 0
      and not trigger.functions.isTriggerable(CRED2).call())

# Line becomes positive (observed), then benign wind-down BELOW floor on a
# fresh credential: not armed either.
CRED3 = kek("limb2-credential-armed")
issue(registry, trigger.address, CRED3, CLASS)
SPOKE3 = Web3.to_checksum_address("0x0000000000000000000000000000000000059040")
hub.functions.setSpokeConfig(WETH_ID, SPOKE3, 1_000_000, 500_000, True).transact({"from": OWNER})
trigger.functions.configure(CRED3, hub.address, SPOKE3, THRESHOLD_RAY, FLOOR_RAY, now(), 0)\
    .transact({"from": ATTESTOR})
trigger.functions.addAsset(CRED3, WETH_ID).transact({"from": ATTESTOR})
trigger.functions.checkpoint(CRED3).transact({"from": WATCHER})

hub.functions.setSpokeConfig(WETH_ID, SPOKE3, 1_000_000, 0, True).transact({"from": OWNER})
trigger.functions.checkpoint(CRED3).transact({"from": WATCHER})
check("benign wind-down below floor: not armed",
      trigger.functions.sanctionObservedAt(CRED3).call() == 0)

# Deficit crosses the floor while the line is zero: arms, latches below limb-1.
hub.functions.reportDeficit(WETH_ID, SPOKE3, 50 * 10**18 * RAY).transact({"from": OWNER})
check("sanction provable live before checkpoint",
      trigger.functions.sanctionProvable(CRED3).call())
trigger.functions.checkpoint(CRED3).transact({"from": WATCHER})
check("sanction armed at checkpoint", trigger.functions.sanctionObservedAt(CRED3).call() > 0)

hub.functions.setSpokeConfig(WETH_ID, SPOKE3, 1_000_000, 500_000, True).transact({"from": OWNER})
check("cap restoration does not disarm", trigger.functions.isTriggerable(CRED3).call())
trigger.functions.latch(CRED3).transact({"from": WATCHER})
check("latched on limb 2 below limb-1 threshold", trigger.functions.isTriggered(CRED3).call())

# --------------------------------------------------- provider + allocator
print("== SpokeOperatorCredentialProvider + SpokeAllocator demo flow ==")
registry2 = deploy("MockSealedRegistry")
trigger2 = deploy("AaveV4SpokeTrigger", registry2.address)
hub2 = deploy("MockAaveV4Hub")
provider = deploy("SpokeOperatorCredentialProvider", registry2.address)
weth = deploy("MockERC20")
allocator = deploy("SpokeAllocator", registry2.address, weth.address, MANAGER)

CRED4 = kek("demo-credential")
issue(registry2, trigger2.address, CRED4, CLASS, wallet=SUBJECT)
hub2.functions.setSpokeConfig(WETH_ID, SPOKE, 1_000_000, 500_000, True).transact({"from": OWNER})

check("unconfigured mandate refused by provider",
      provider.functions.getCredential(SUBJECT).call() == 0)
trigger2.functions.configure(CRED4, hub2.address, SPOKE, THRESHOLD_RAY, FLOOR_RAY, now(), 0)\
    .transact({"from": ATTESTOR})
trigger2.functions.addAsset(CRED4, WETH_ID).transact({"from": ATTESTOR})
trigger2.functions.checkpoint(CRED4).transact({"from": WATCHER})
check("granted once consequence-bearing", provider.functions.getCredential(SUBJECT).call() > 0)

wrong = deploy("MockLatchTrigger", kek("WILDCAT_DELINQ_90D_V1"))
CRED5 = kek("borrower-credential")
registry2.functions.setCredential(
    CRED5, kek("entity/v1"), ATTESTOR, now(), 0, False, [wrong.address],
    [kek("WILDCAT_DELINQ_90D_V1")],
).transact({"from": OWNER})
expect_revert("allocator refuses wrong-class credential at registration",
              lambda: allocator.functions.registerSpoke(SPOKE, CRED5).transact({"from": MANAGER}))
allocator.functions.registerSpoke(SPOKE, CRED4).transact({"from": MANAGER})
check("spoke healthy after registration", allocator.functions.spokeHealthy(SPOKE).call())

weth.functions.mint(DEPOSITOR, 100 * 10**18).transact({"from": OWNER})
weth.functions.approve(allocator.address, 2**256 - 1).transact({"from": DEPOSITOR})
allocator.functions.deposit(100 * 10**18).transact({"from": DEPOSITOR})
allocator.functions.allocate(SPOKE, 60 * 10**18).transact({"from": MANAGER})
check("healthy allocation routed", weth.functions.balanceOf(SPOKE).call() == 60 * 10**18)
check("healthy credit endorsement",
      allocator.functions.approveCreditIncrease(SPOKE, 600_000).call({"from": MANAGER}))

# The spoke books threshold-clearing bad debt; nothing checkpointed or latched.
hub2.functions.reportDeficit(WETH_ID, SPOKE, 150 * 10**18 * RAY).transact({"from": OWNER})
check("operator grant dies the block the loss is provable",
      provider.functions.getCredential(SUBJECT).call() == 0)
check("spoke unhealthy before any latch (gates read projections)",
      not allocator.functions.spokeHealthy(SPOKE).call())
expect_revert("new allocation refused pre-latch",
              lambda: allocator.functions.allocate(SPOKE, 10 * 10**18).transact({"from": MANAGER}))

trigger2.functions.latch(CRED4).transact({"from": WATCHER})
expect_revert("new allocation refused post-latch",
              lambda: allocator.functions.allocate(SPOKE, 10 * 10**18).transact({"from": MANAGER}))
expect_revert("credit endorsement refused post-latch",
              lambda: allocator.functions.approveCreditIncrease(SPOKE, 700_000)
              .transact({"from": MANAGER}))

check("existing exposure not confiscated",
      allocator.functions.spokes(SPOKE).call()[2] == 60 * 10**18)
allocator.functions.withdraw(40 * 10**18).transact({"from": DEPOSITOR})
check("depositor withdrawal succeeds post-latch",
      weth.functions.balanceOf(DEPOSITOR).call() == 40 * 10**18)

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
