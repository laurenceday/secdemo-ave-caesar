#!/usr/bin/env python3
"""Runtime verification on a local EVM (py-evm via eth-tester).

Deploys the compiled artifacts and executes the thesis demo: ONE entity/v1
credential, issued once, bound to a Wildcat delinquency trigger and an Aave
V3 deficit trigger. Two venue consumers pin their own class; a portable
consumer pins both. Shows venue-local isolation, cross-venue visibility of a
latch on the shared credential, latch permanence, and shared lifecycle.

Complements the forge suite; proves execution without the foundry toolchain.
"""
import json
import sys

from eth_tester import EthereumTester, PyEVMBackend
from web3 import Web3, EthereumTesterProvider

ARTIFACTS = json.load(open("script/artifacts.json"))

tester = EthereumTester(PyEVMBackend())
w3 = Web3(EthereumTesterProvider(tester))
OWNER, ATTESTOR, ENTITY, WATCHER = w3.eth.accounts[:4]

GRACE = 3 * 86400
EXTENSION = 90 * 86400
WETH = Web3.to_checksum_address("0x00000000000000000000000000000000000011e7")
DEFICIT_THRESHOLD = 100 * 10**18
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


def now():
    return w3.eth.get_block("latest")["timestamp"]


kek = lambda s: Web3.keccak(text=s)

registry = deploy("MockSealedRegistry")
wildcat = deploy("WildcatDelinquencyTrigger", registry.address)
aave = deploy("AaveV3DeficitTrigger", registry.address)
market = deploy("MockWildcatMarket")
pool = deploy("MockAaveV3Pool")

W_CLASS = kek("WILDCAT_DELINQ_V1")
A_CLASS = kek("AAVE_V3_GROSS_DEFICIT_V1")
CRED = kek("shared-entity-credential")

# ONE credential, bound to BOTH venues' trigger classes.
registry.functions.setCredential(
    CRED, kek("entity/v1"), ATTESTOR, now(), 0, False,
    [wildcat.address, aave.address], [W_CLASS, A_CLASS],
).transact({"from": OWNER})
registry.functions.setWallet(ENTITY, CRED).transact({"from": OWNER})

market.functions.setDelinquencyGracePeriod(GRACE).transact({"from": OWNER})
wildcat.functions.configure(CRED, market.address, EXTENSION).transact({"from": ATTESTOR})
aave.functions.configure(CRED, pool.address, DEFICIT_THRESHOLD, now(), 0).transact({"from": ATTESTOR})
aave.functions.addReserve(CRED, WETH).transact({"from": ATTESTOR})

venueWildcat = deploy("CrossVenueConsumer", registry.address, [W_CLASS])
venueAave = deploy("CrossVenueConsumer", registry.address, [A_CLASS])
venuePortable = deploy("CrossVenueConsumer", registry.address, [W_CLASS, A_CLASS])

print("== one onboarding, two venues ==")
check("Wildcat venue accepts", venueWildcat.functions.accepts(ENTITY).call())
check("Aave venue accepts", venueAave.functions.accepts(ENTITY).call())
check("portable venue accepts", venuePortable.functions.accepts(ENTITY).call())
check("clean everywhere", len(venuePortable.functions.latchedClasses(CRED).call()) == 0)

print("== Wildcat default: isolation + cross-venue visibility ==")
market.functions.setTimeDelinquent(GRACE + EXTENSION + 1).transact({"from": OWNER})
check("Wildcat trigger latchable", wildcat.functions.isTriggerable(CRED).call())
check("Wildcat venue rejects its own default", not venueWildcat.functions.accepts(ENTITY).call())
check("Aave-only venue isolated (its class clean)", venueAave.functions.accepts(ENTITY).call())
check("portable venue sees the default (shared surface)",
      not venuePortable.functions.accepts(ENTITY).call())

wildcat.functions.latch(CRED).transact({"from": WATCHER})
hits = venuePortable.functions.latchedClasses(CRED).call()
check("one latched class visible on the shared credential",
      len(hits) == 1 and Web3.to_bytes(hits[0]) == W_CLASS)

# Borrower cures after the latch: cannot un-latch.
market.functions.setTimeDelinquent(0).transact({"from": OWNER})
check("latch is permanent (cure does not un-latch)", wildcat.functions.isTriggered(CRED).call())
check("portable still rejects after cure", not venuePortable.functions.accepts(ENTITY).call())
check("Aave-only venue still fine", venueAave.functions.accepts(ENTITY).call())

print("== symmetric: Aave loss on a fresh shared credential ==")
CRED2 = kek("second-shared-credential")
registry.functions.setCredential(
    CRED2, kek("entity/v1"), ATTESTOR, now(), 0, False,
    [wildcat.address, aave.address], [W_CLASS, A_CLASS],
).transact({"from": OWNER})
E2 = w3.eth.accounts[5]
registry.functions.setWallet(E2, CRED2).transact({"from": OWNER})
market2 = deploy("MockWildcatMarket")
market2.functions.setDelinquencyGracePeriod(GRACE).transact({"from": OWNER})
wildcat.functions.configure(CRED2, market2.address, EXTENSION).transact({"from": ATTESTOR})
aave.functions.configure(CRED2, pool.address, DEFICIT_THRESHOLD, now(), 0).transact({"from": ATTESTOR})
aave.functions.addReserve(CRED2, WETH).transact({"from": ATTESTOR})

pool.functions.createDeficit(WETH, 150 * 10**18).transact({"from": OWNER})
check("Aave trigger latchable", aave.functions.isTriggerable(CRED2).call())
check("Aave venue rejects its own loss", not venueAave.functions.accepts(E2).call())
check("Wildcat-only venue isolated", venueWildcat.functions.accepts(E2).call())
check("portable venue sees the loss", not venuePortable.functions.accepts(E2).call())
aave.functions.latch(CRED2).transact({"from": WATCHER})
hits2 = venuePortable.functions.latchedClasses(CRED2).call()
check("the Aave class is the visible latch",
      len(hits2) == 1 and Web3.to_bytes(hits2[0]) == A_CLASS)

print("== shared lifecycle ==")
registry.functions.setRevoked(CRED2, True).transact({"from": OWNER})
check("one revocation disables every venue at once",
      not venueWildcat.functions.accepts(E2).call()
      and not venueAave.functions.accepts(E2).call()
      and not venuePortable.functions.accepts(E2).call())

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
