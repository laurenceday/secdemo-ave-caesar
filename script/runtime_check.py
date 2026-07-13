#!/usr/bin/env python3
"""Runtime verification on a local EVM (py-evm via eth-tester).

Deploys the compiled artifacts and executes the core flows end-to-end:
mandate configuration gating, append-only scope with add-time baselines,
the gross-vs-net accumulator (cure-before-latch must still latch), mandate
window attribution, projection-materialising latch, and the trigger-pinned
provider's grant lifecycle.

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
OWNER, ATTESTOR, SUBJECT, WATCHER = w3.eth.accounts[:4]

THRESHOLD = 100 * 10**18  # 100 WETH
WETH = Web3.to_checksum_address("0x00000000000000000000000000000000000011e7")
WSTETH = Web3.to_checksum_address("0x00000000000000000000000000000000000011e8")
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


def warp(dt):
    tester.time_travel(now() + dt)
    tester.mine_block()


kek = lambda s: Web3.keccak(text=s)


def issue(registry, trigger, cred, wallet=None, expires=0):
    registry.functions.setCredential(
        cred, kek("entity/v1"), ATTESTOR, now(), expires, False,
        [trigger.address], [kek("AAVE_V3_GROSS_DEFICIT_V1")],
    ).transact({"from": OWNER})
    if wallet:
        registry.functions.setWallet(wallet, cred).transact({"from": OWNER})


# ------------------------------------------------- configuration + scope
print("== AaveV3DeficitTrigger: mandate + scope ==")
registry = deploy("MockSealedRegistry")
trigger = deploy("AaveV3DeficitTrigger", registry.address)
pool = deploy("MockAaveV3Pool")
CRED = kek("risk-provider-credential")
issue(registry, trigger, CRED, wallet=SUBJECT)

expect_revert("configure gated to attestor",
              lambda: trigger.functions.configure(CRED, pool.address, THRESHOLD, now(), 0)
              .transact({"from": SUBJECT}))
trigger.functions.configure(CRED, pool.address, THRESHOLD, now(), 0).transact({"from": ATTESTOR})
expect_revert("configure is one-shot",
              lambda: trigger.functions.configure(CRED, pool.address, THRESHOLD + 1, now(), 0)
              .transact({"from": ATTESTOR}))

# Pre-existing deficit history is swallowed by the add-time baseline.
pool.functions.createDeficit(WETH, 500 * 10**18).transact({"from": OWNER})
expect_revert("addReserve gated to subject/attestor",
              lambda: trigger.functions.addReserve(CRED, WETH).transact({"from": WATCHER}))
trigger.functions.addReserve(CRED, WETH).transact({"from": ATTESTOR})
check("baseline = live counter at add",
      trigger.functions.lastObservedDeficit(CRED, WETH).call() == 500 * 10**18)
check("history does not count", trigger.functions.projectedGrossDeficit(CRED).call() == 0)
trigger.functions.addReserve(CRED, WSTETH).transact({"from": SUBJECT})
check("subject can widen its own scope", trigger.functions.isBound(CRED, WSTETH).call())
expect_revert("scope is append-only (no duplicates)",
              lambda: trigger.functions.addReserve(CRED, WETH).transact({"from": ATTESTOR}))

# ----------------------------------------------------- gross-vs-net core
print("== gross accumulator: cure-before-latch still latches ==")
pool.functions.createDeficit(WETH, 150 * 10**18).transact({"from": OWNER})
trigger.functions.checkpoint(CRED).transact({"from": WATCHER})
check("increase checkpointed exactly",
      trigger.functions.grossDeficitAccumulated(CRED).call() == 150 * 10**18)

pool.functions.eliminateDeficit(WETH, 150 * 10**18).transact({"from": OWNER})
trigger.functions.checkpoint(CRED).transact({"from": WATCHER})
check("net deficit cured back to baseline",
      pool.functions.getReserveDeficit(WETH).call() == 500 * 10**18)
check("gross unmoved by cure",
      trigger.functions.grossDeficitAccumulated(CRED).call() == 150 * 10**18)
check("cure-before-latch does not disarm", trigger.functions.isTriggerable(CRED).call())

pool.functions.createDeficit(WETH, 60 * 10**18).transact({"from": OWNER})
trigger.functions.checkpoint(CRED).transact({"from": WATCHER})
check("re-incurred debt counts from the lowered base",
      trigger.functions.grossDeficitAccumulated(CRED).call() == 210 * 10**18)

trigger.functions.latch(CRED).transact({"from": WATCHER})
check("permissionless latch on a cured counter", trigger.functions.isTriggered(CRED).call())
expect_revert("double latch reverts",
              lambda: trigger.functions.latch(CRED).transact({"from": WATCHER}))
expect_revert("scope frozen post-latch",
              lambda: trigger.functions.addReserve(CRED, Web3.to_checksum_address(
                  "0x00000000000000000000000000000000000011e9")).transact({"from": ATTESTOR}))

# ------------------------------------------------------- mandate window
print("== mandate window attribution ==")
CRED_W = kek("windowed-credential")
issue(registry, trigger, CRED_W)
start = now() + 86400
end = start + 30 * 86400
trigger.functions.configure(CRED_W, pool.address, THRESHOLD, start, end).transact({"from": ATTESTOR})
trigger.functions.addReserve(CRED_W, WSTETH).transact({"from": ATTESTOR})

pool.functions.createDeficit(WSTETH, 200 * 10**18).transact({"from": OWNER})
trigger.functions.checkpoint(CRED_W).transact({"from": WATCHER})
check("pre-mandate rise observed, not attributed",
      trigger.functions.grossDeficitAccumulated(CRED_W).call() == 0)
check("pre-window projection excluded", not trigger.functions.isTriggerable(CRED_W).call())

warp(86400 + 10)
pool.functions.createDeficit(WSTETH, 120 * 10**18).transact({"from": OWNER})
check("in-window projection provable without checkpoint",
      trigger.functions.isTriggerable(CRED_W).call())
trigger.functions.checkpoint(CRED_W).transact({"from": WATCHER})
check("in-window rise attributed",
      trigger.functions.grossDeficitAccumulated(CRED_W).call() == 120 * 10**18)

warp(31 * 86400)
pool.functions.createDeficit(WSTETH, 500 * 10**18).transact({"from": OWNER})
trigger.functions.checkpoint(CRED_W).transact({"from": WATCHER})
check("post-mandate rise observed, not attributed",
      trigger.functions.grossDeficitAccumulated(CRED_W).call() == 120 * 10**18)
check("recorded fact survives expiry (still latchable)",
      trigger.functions.isTriggerable(CRED_W).call())
trigger.functions.latch(CRED_W).transact({"from": WATCHER})
check("latch after expiry on in-window record", trigger.functions.isTriggered(CRED_W).call())

# --------------------------------------------------------- provider
print("== RiskProviderCredentialProvider ==")
registry2 = deploy("MockSealedRegistry")
trigger2 = deploy("AaveV3DeficitTrigger", registry2.address)
pool2 = deploy("MockAaveV3Pool")
provider = deploy("RiskProviderCredentialProvider", registry2.address)
CRED2 = kek("provider-credential")
issue(registry2, trigger2, CRED2, wallet=SUBJECT)

check("unconfigured mandate refused (not consequence-bearing)",
      provider.functions.getCredential(SUBJECT).call() == 0)
trigger2.functions.configure(CRED2, pool2.address, THRESHOLD, now(), 0).transact({"from": ATTESTOR})
check("empty scope refused", provider.functions.getCredential(SUBJECT).call() == 0)
trigger2.functions.addReserve(CRED2, WETH).transact({"from": ATTESTOR})
check("granted once consequence-bearing (issuedAt)",
      provider.functions.getCredential(SUBJECT).call() > 0)

wrong = deploy("MockLatchTrigger", kek("WILDCAT_DELINQ_90D_V1"))
CRED3 = kek("borrower-credential")
registry2.functions.setCredential(
    CRED3, kek("entity/v1"), ATTESTOR, now(), 0, False,
    [wrong.address], [kek("WILDCAT_DELINQ_90D_V1")],
).transact({"from": OWNER})
registry2.functions.setWallet(WATCHER, CRED3).transact({"from": OWNER})
check("wrong-class credential unusable here",
      provider.functions.getCredential(WATCHER).call() == 0)

pool2.functions.createDeficit(WETH, THRESHOLD - 1).transact({"from": OWNER})
check("sub-threshold loss tolerated", provider.functions.getCredential(SUBJECT).call() > 0)
pool2.functions.createDeficit(WETH, 1).transact({"from": OWNER})
check("one more wei: latchable alone withdraws grant (projections)",
      provider.functions.getCredential(SUBJECT).call() == 0)
trigger2.functions.latch(CRED2).transact({"from": WATCHER})
pool2.functions.eliminateDeficit(WETH, THRESHOLD).transact({"from": OWNER})
check("latched + cured: grant stays withdrawn",
      provider.functions.getCredential(SUBJECT).call() == 0)

registry2.functions.setRevoked(CRED2, True).transact({"from": OWNER})
check("revoked: no grant", provider.functions.getCredential(SUBJECT).call() == 0)

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
