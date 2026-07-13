#!/usr/bin/env python3
"""Runtime verification on a local EVM (py-evm via eth-tester).

Deploys the compiled artifacts and executes the core flows end-to-end:
NAV drawdown (HWM ratchet, floor-rounded bps, no cure after observation),
the feed-darkness limb, redemption liveness (dry clock, capped pause
carve-out, alternation resistance), and the provider's two-limb grant
lifecycle including the NAV-only issuer shape.

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
OWNER, ATTESTOR, ISSUER, WATCHER = w3.eth.accounts[:4]

THRESHOLD_BPS = 500
STALENESS = 2 * 86400
STALE_CAP = 10 * 86400
FLOOR = 100_000 * 10**6
DRY = 7 * 86400
PAUSE_CAP = 30 * 86400
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
NAV_CLASS = kek("RWA_NAV_DRAWDOWN_BPS_V1")
LIVE_CLASS = kek("USTB_REDEMPTION_LIVENESS_V1")

registry = deploy("MockSealedRegistry")
nav = deploy("NavDrawdownTrigger", registry.address)
liveness = deploy("RedemptionLivenessTrigger", registry.address)
provider = deploy("RWAIssuerCredentialProvider", registry.address)
feed = deploy("MockNavFeed")
redemption = deploy("MockRedemption")

CRED = kek("rwa-issuer-credential")
registry.functions.setCredential(
    CRED, kek("entity/v1"), ATTESTOR, now(), 0, False,
    [nav.address, liveness.address], [NAV_CLASS, LIVE_CLASS],
).transact({"from": OWNER})
registry.functions.setWallet(ISSUER, CRED).transact({"from": OWNER})

# Healthy world: USTB-like NAV at $11.144444, capacity 394,617 USTB.
feed.functions.set(11_144_444, now()).transact({"from": OWNER})
redemption.functions.setCapacity(394_617 * 10**6).transact({"from": OWNER})

expect_revert("configure gated to attestor",
              lambda: nav.functions.configure(CRED, feed.address, THRESHOLD_BPS, STALENESS,
                                              STALE_CAP, now(), 0).transact({"from": ISSUER}))
nav.functions.configure(CRED, feed.address, THRESHOLD_BPS, STALENESS, STALE_CAP, now(), 0)\
    .transact({"from": ATTESTOR})
liveness.functions.configure(CRED, redemption.address, FLOOR, DRY, PAUSE_CAP, now(), 0)\
    .transact({"from": ATTESTOR})
nav.functions.checkpoint(CRED).transact({"from": WATCHER})
liveness.functions.checkpoint(CRED).transact({"from": WATCHER})

# ------------------------------------------------------------ NAV drawdown
print("== NavDrawdownTrigger: drawdown limb ==")
check("HWM baselined at first fresh checkpoint",
      nav.functions.highWaterNav(CRED).call() == 11_144_444)
check("both limbs healthy: provider grants", provider.functions.getCredential(ISSUER).call() > 0)

feed.functions.set(11_500_000, now()).transact({"from": OWNER})
nav.functions.checkpoint(CRED).transact({"from": WATCHER})
check("HWM ratchets up", nav.functions.highWaterNav(CRED).call() == 11_500_000)

# 4.99..%: (574999 * 10000) / 11500000 = 499.99 -> floor 499: not latchable.
feed.functions.set(10_925_001, now()).transact({"from": OWNER})
nav.functions.checkpoint(CRED).transact({"from": WATCHER})
check("floor rounding biases toward subject (499 bps)",
      nav.functions.maxDrawdownBpsObserved(CRED).call() == 499)
check("sub-threshold: not triggerable", not nav.functions.isTriggerable(CRED).call())

# Exactly 5%: inclusive, and the grant dies on the live print (projection).
feed.functions.set(10_925_000, now()).transact({"from": OWNER})
check("projection sees the live print (500 bps)",
      nav.functions.projectedDrawdownBps(CRED).call() == 500)
check("grant dies while merely latchable", provider.functions.getCredential(ISSUER).call() == 0)

# Full recovery after a checkpointed observation cannot cure.
nav.functions.checkpoint(CRED).transact({"from": WATCHER})
feed.functions.set(12_000_000, now()).transact({"from": OWNER})
nav.functions.checkpoint(CRED).transact({"from": WATCHER})
check("observed drawdown is permanent (no cure)",
      nav.functions.maxDrawdownBpsObserved(CRED).call() == 500)
nav.functions.latch(CRED).transact({"from": WATCHER})
check("permissionless latch after recovery", nav.functions.isTriggered(CRED).call())
expect_revert("double latch reverts",
              lambda: nav.functions.latch(CRED).transact({"from": WATCHER}))

# ------------------------------------------------------------ darkness limb
print("== NavDrawdownTrigger: darkness limb ==")
CRED_D = kek("darkness-credential")
registry.functions.setCredential(
    CRED_D, kek("entity/v1"), ATTESTOR, now(), 0, False, [nav.address], [NAV_CLASS],
).transact({"from": OWNER})
feed2 = deploy("MockNavFeed")
feed2.functions.set(10_000_000, now()).transact({"from": OWNER})
nav.functions.configure(CRED_D, feed2.address, THRESHOLD_BPS, STALENESS, STALE_CAP, now(), 0)\
    .transact({"from": ATTESTOR})
nav.functions.checkpoint(CRED_D).transact({"from": WATCHER})

warp(3 * 86400)
nav.functions.checkpoint(CRED_D).transact({"from": WATCHER})
check("stale checkpoint arms the darkness clock", nav.functions.staleSince(CRED_D).call() > 0)
check("stale print records nothing", nav.functions.highWaterNav(CRED_D).call() == 10_000_000)

feed2.functions.set(10_100_000, now()).transact({"from": OWNER})
nav.functions.checkpoint(CRED_D).transact({"from": WATCHER})
check("fresh print clears the clock", nav.functions.staleSince(CRED_D).call() == 0)

warp(3 * 86400)
nav.functions.checkpoint(CRED_D).transact({"from": WATCHER})
warp(STALE_CAP + 10)
check("darkness past the cap is provable", nav.functions.darknessProvable(CRED_D).call())
nav.functions.latch(CRED_D).transact({"from": WATCHER})
check("a permanently dark feed latches", nav.functions.isTriggered(CRED_D).call())

# ------------------------------------------------------- redemption liveness
print("== RedemptionLivenessTrigger ==")
redemption.functions.setCapacity(50_000 * 10**6).transact({"from": OWNER})
liveness.functions.checkpoint(CRED).transact({"from": WATCHER})
check("dry armed below the floor", liveness.functions.dryFirstObserved(CRED).call() > 0)
check("within refill window: not triggerable", not liveness.functions.isTriggerable(CRED).call())

redemption.functions.setCapacity(200_000 * 10**6).transact({"from": OWNER})
liveness.functions.checkpoint(CRED).transact({"from": WATCHER})
check("healthy observation clears the dry clock",
      liveness.functions.dryFirstObserved(CRED).call() == 0)

# Compliance pause: carve-out holds, but is capped.
redemption.functions.setPaused(True).transact({"from": OWNER})
liveness.functions.checkpoint(CRED).transact({"from": WATCHER})
check("pause armed, dry clock excused",
      liveness.functions.pauseFirstObserved(CRED).call() > 0
      and liveness.functions.dryFirstObserved(CRED).call() == 0)
warp(DRY + 86400)
check("carve-out holds within the cap", not liveness.functions.isTriggerable(CRED).call())
warp(PAUSE_CAP)
check("unbounded pause cannot dodge the latch", liveness.functions.isTriggerable(CRED).call())

# Alternation resistance: unpause into dry does not clear the pause clock.
p0 = liveness.functions.pauseFirstObserved(CRED).call()
redemption.functions.setPaused(False).transact({"from": OWNER})
redemption.functions.setCapacity(10_000 * 10**6).transact({"from": OWNER})
liveness.functions.checkpoint(CRED).transact({"from": WATCHER})
check("unpause-into-dry keeps the pause clock",
      liveness.functions.pauseFirstObserved(CRED).call() == p0
      and liveness.functions.dryFirstObserved(CRED).call() > 0)

# Healthy clears everything; then a real dry stretch latches.
redemption.functions.setCapacity(500_000 * 10**6).transact({"from": OWNER})
liveness.functions.checkpoint(CRED).transact({"from": WATCHER})
check("healthy clears both clocks",
      liveness.functions.pauseFirstObserved(CRED).call() == 0
      and liveness.functions.dryFirstObserved(CRED).call() == 0)

redemption.functions.setCapacity(10_000 * 10**6).transact({"from": OWNER})
liveness.functions.checkpoint(CRED).transact({"from": WATCHER})
warp(DRY + 10)
check("dry past the bound is provable", liveness.functions.livenessFailureProvable(CRED).call())
check("liveness limb kills the grant", provider.functions.getCredential(ISSUER).call() == 0)
liveness.functions.latch(CRED).transact({"from": WATCHER})
check("permissionless latch on the dry facility", liveness.functions.isTriggered(CRED).call())
redemption.functions.setCapacity(500_000 * 10**6).transact({"from": OWNER})
liveness.functions.checkpoint(CRED).transact({"from": WATCHER})
check("refill after latch: grant stays dead",
      provider.functions.getCredential(ISSUER).call() == 0)

# ------------------------------------------------------------- provider shapes
print("== RWAIssuerCredentialProvider shapes ==")
CRED_N = kek("nav-only-issuer")
registry.functions.setCredential(
    CRED_N, kek("entity/v1"), ATTESTOR, now(), 0, False, [nav.address], [NAV_CLASS],
).transact({"from": OWNER})
W2 = w3.eth.accounts[5]
registry.functions.setWallet(W2, CRED_N).transact({"from": OWNER})
check("unconfigured NAV mandate refused", provider.functions.getCredential(W2).call() == 0)
feed3 = deploy("MockNavFeed")
feed3.functions.set(10_000_000, now()).transact({"from": OWNER})
nav.functions.configure(CRED_N, feed3.address, THRESHOLD_BPS, STALENESS, STALE_CAP, now(), 0)\
    .transact({"from": ATTESTOR})
check("NAV-only issuer granted (liveness gap disclosed, not faked)",
      provider.functions.getCredential(W2).call() > 0)

CRED_H = kek("half-configured")
registry.functions.setCredential(
    CRED_H, kek("entity/v1"), ATTESTOR, now(), 0, False,
    [nav.address, liveness.address], [NAV_CLASS, LIVE_CLASS],
).transact({"from": OWNER})
W3_ = w3.eth.accounts[6]
registry.functions.setWallet(W3_, CRED_H).transact({"from": OWNER})
nav.functions.configure(CRED_H, feed3.address, THRESHOLD_BPS, STALENESS, STALE_CAP, now(), 0)\
    .transact({"from": ATTESTOR})
check("liveness bound-but-unconfigured refused",
      provider.functions.getCredential(W3_).call() == 0)

wrong = deploy("MockLatchTrigger", kek("WILDCAT_DELINQ_90D_V1"))
CRED_W = kek("borrower-credential")
registry.functions.setCredential(
    CRED_W, kek("entity/v1"), ATTESTOR, now(), 0, False,
    [wrong.address], [kek("WILDCAT_DELINQ_90D_V1")],
).transact({"from": OWNER})
W4 = w3.eth.accounts[7]
registry.functions.setWallet(W4, CRED_W).transact({"from": OWNER})
check("wrong-class credential unusable here",
      provider.functions.getCredential(W4).call() == 0)

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
