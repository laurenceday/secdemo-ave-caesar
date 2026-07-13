#!/usr/bin/env python3
"""Runtime verification on a local EVM (py-evm via eth-tester).

Deploys the compiled artifacts and executes the core flows end-to-end:
the wind-down clock (arms on capacity==0 && level>0, self-clears on wind-down
or re-onboard), the sustained-past-window latch, projection/permanence, and
the provider's grant lifecycle.

Complements the forge suite; proves execution without the foundry toolchain.
"""
import json
import sys

from eth_tester import EthereumTester, PyEVMBackend
from web3 import Web3, EthereumTesterProvider

ARTIFACTS = json.load(open("script/artifacts.json"))

tester = EthereumTester(PyEVMBackend())
w3 = Web3(EthereumTesterProvider(tester))
OWNER, ATTESTOR, SUBJECT, WATCHER = w3.eth.accounts[:4]

WINDDOWN = 30 * 86400
FACILITATOR = Web3.to_checksum_address("0x000000000000000000000000000000000000fac1")
E18 = 10**18
PASS = FAIL = 0


def deploy(name, *args):
    a = ARTIFACTS[name]
    c = w3.eth.contract(abi=a["abi"], bytecode=a["bin"])
    rcpt = w3.eth.wait_for_transaction_receipt(c.constructor(*args).transact({"from": OWNER}))
    return w3.eth.contract(address=rcpt.contractAddress, abi=a["abi"])


def check(label, cond):
    global PASS, FAIL
    PASS, FAIL = (PASS + 1, FAIL) if cond else (PASS, FAIL + 1)
    print(f"  {'PASS' if cond else 'FAIL'}  {label}")


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


def warp(dt):
    tester.time_travel(now() + dt)
    tester.mine_block()


kek = lambda s: Web3.keccak(text=s)
CLASS = kek("GHO_FACILITATOR_WINDDOWN_V1")

registry = deploy("MockSealedRegistry")
trigger = deploy("GhoFacilitatorWindDownTrigger", registry.address)
provider = deploy("GhoFacilitatorCredentialProvider", registry.address)
gho = deploy("MockGhoToken")

CRED = kek("gho-facilitator-credential")
registry.functions.setCredential(
    CRED, kek("entity/v1"), ATTESTOR, now(), 0, False, [trigger.address], [CLASS],
).transact({"from": OWNER})
registry.functions.setWallet(SUBJECT, CRED).transact({"from": OWNER})

# Healthy, active facilitator: 175M capacity, 45M minted (a real mainnet
# facilitator shape observed on GhoToken).
gho.functions.setCapacity(FACILITATOR, 175_000_000 * E18).transact({"from": OWNER})
gho.functions.setLevel(FACILITATOR, 45_000_000 * E18).transact({"from": OWNER})

print("== GhoFacilitatorWindDownTrigger ==")
expect_revert("configure gated to attestor",
              lambda: trigger.functions.configure(CRED, gho.address, FACILITATOR, WINDDOWN, now(), 0)
              .transact({"from": SUBJECT}))
trigger.functions.configure(CRED, gho.address, FACILITATOR, WINDDOWN, now(), 0).transact({"from": ATTESTOR})

trigger.functions.checkpoint(CRED).transact({"from": WATCHER})
check("healthy facilitator: condition false", not trigger.functions.conditionHolds(CRED).call())
check("healthy: granted", provider.functions.getCredential(SUBJECT).call() > 0)

# Fully wound down + offboarded (level 0): duty discharged, does not arm.
gho.functions.setCapacity(FACILITATOR, 0).transact({"from": OWNER})
gho.functions.setLevel(FACILITATOR, 0).transact({"from": OWNER})
trigger.functions.checkpoint(CRED).transact({"from": WATCHER})
check("capacity 0 but level 0 does not arm", trigger.functions.windDownFirstObserved(CRED).call() == 0)

# Offboarded with GHO still outstanding: arms.
gho.functions.setLevel(FACILITATOR, 45_000_000 * E18).transact({"from": OWNER})
trigger.functions.checkpoint(CRED).transact({"from": WATCHER})
check("offboarded + outstanding arms", trigger.functions.windDownFirstObserved(CRED).call() > 0)
check("within window: not triggerable", not trigger.functions.isTriggerable(CRED).call())
check("still granted within window", provider.functions.getCredential(SUBJECT).call() > 0)

# Wind down in time clears the clock.
warp(10 * 86400)
gho.functions.setLevel(FACILITATOR, 0).transact({"from": OWNER})
trigger.functions.checkpoint(CRED).transact({"from": WATCHER})
check("wind-down in time clears the clock", trigger.functions.windDownFirstObserved(CRED).call() == 0)

# Re-offboard with outstanding, this time nobody winds down: latches.
gho.functions.setLevel(FACILITATOR, 20_000_000 * E18).transact({"from": OWNER})
trigger.functions.checkpoint(CRED).transact({"from": WATCHER})  # re-arm
warp(WINDDOWN + 1)
check("sustained past window is provable", trigger.functions.windDownProvable(CRED).call())
check("grant withdrawn once latchable", provider.functions.getCredential(SUBJECT).call() == 0)
trigger.functions.latch(CRED).transact({"from": WATCHER})
check("permissionless latch", trigger.functions.isTriggered(CRED).call())

# Belated wind-down after latch cannot un-latch.
gho.functions.setLevel(FACILITATOR, 0).transact({"from": OWNER})
check("no un-latch on late wind-down", trigger.functions.isTriggered(CRED).call())
check("grant stays withdrawn", provider.functions.getCredential(SUBJECT).call() == 0)
expect_revert("double latch reverts",
              lambda: trigger.functions.latch(CRED).transact({"from": WATCHER}))

# ------------------------------------------------------------- provider
print("== GhoFacilitatorCredentialProvider ==")
CRED2 = kek("second-facilitator")
registry.functions.setCredential(
    CRED2, kek("entity/v1"), ATTESTOR, now(), 0, False, [trigger.address], [CLASS],
).transact({"from": OWNER})
W2 = w3.eth.accounts[5]
registry.functions.setWallet(W2, CRED2).transact({"from": OWNER})
check("unconfigured mandate refused", provider.functions.getCredential(W2).call() == 0)

wrong = deploy("MockLatchTrigger", kek("WILDCAT_DELINQ_90D_V1"))
CRED3 = kek("borrower")
registry.functions.setCredential(
    CRED3, kek("entity/v1"), ATTESTOR, now(), 0, False, [wrong.address], [kek("WILDCAT_DELINQ_90D_V1")],
).transact({"from": OWNER})
W3_ = w3.eth.accounts[6]
registry.functions.setWallet(W3_, CRED3).transact({"from": OWNER})
check("wrong-class credential unusable", provider.functions.getCredential(W3_).call() == 0)

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
