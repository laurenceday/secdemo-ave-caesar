#!/usr/bin/env python3
"""The Kelp backtest, executed: real chain data through the real trigger.

Reads the Aave V3 mainnet Pool's ACTUAL WETH reserve deficit at the
pre-exploit block and at a block after the 6 May 2026 bad-debt booking
(archive RPC), then replays those observations through the compiled
AaveV3DeficitTrigger + RiskProviderCredentialProvider bytecode on a local
py-evm chain via a pool stub fed the real values.

This is the same scenario as test/fork/AaveV3DeficitTrigger.fork.t.sol for
environments without the foundry toolchain: the deficit numbers are the
chain's, the trigger/provider execution is the real compiled artifacts',
only the Pool is a relay. Run compile_all.js first.

    MAINNET_RPC_URL=<archive node> python3 script/kelp_backtest.py

Verified timeline this replays (script/deficit_scan.py, 2026-07-13):
exploit 18-19 April 2026; mainnet core books NO event deficit while the
rsETH markets stay frozen; on 6 May 2026 18:12:23 UTC (block 25,037,701)
two DeficitCreated events burn 52,964.4395 WETH of bad debt into the WETH
reserve in one transaction.
"""
import json
import os
import sys
import urllib.request

from eth_hash.auto import keccak
from eth_tester import EthereumTester, PyEVMBackend
from web3 import Web3, EthereumTesterProvider

RPC = os.environ.get("MAINNET_RPC_URL")
if not RPC:
    sys.exit("set MAINNET_RPC_URL to an archive node with April-May 2026 state")

POOL = "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2"
WETH = Web3.to_checksum_address("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")
BLOCK_PRE = int(os.environ.get("FORK_BLOCK_PRE", 24_895_842))    # 2026-04-17T00:00:11Z
BLOCK_POST = int(os.environ.get("FORK_BLOCK_POST", 25_038_000))  # after the 6 May booking
THRESHOLD = int(os.environ.get("KELP_THRESHOLD", 1_000 * 10**18))
THRESHOLD_HIGH = int(os.environ.get("KELP_THRESHOLD_HIGH", 200_000 * 10**18))


def rpc_call(method, params):
    req = urllib.request.Request(
        RPC,
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers={"Content-Type": "application/json"},
    )
    out = json.load(urllib.request.urlopen(req, timeout=60))
    if "error" in out:
        raise RuntimeError(f"{method}: {out['error']}")
    return out["result"]


def real_deficit(block):
    sel = "0x" + keccak(b"getReserveDeficit(address)")[:4].hex()
    data = sel + WETH[2:].lower().rjust(64, "0")
    return int(rpc_call("eth_call", [{"to": POOL, "data": data}, hex(block)]), 16)


# ---------------------------------------------------- real chain observations
pre = real_deficit(BLOCK_PRE)
post = real_deficit(BLOCK_POST)
print(f"REAL WETH reserve deficit @ block {BLOCK_PRE} (pre-exploit):  {pre}")
print(f"REAL WETH reserve deficit @ block {BLOCK_POST} (post-booking): {post}")
print(f"event gross: {post - pre} wei = {(post - pre) / 10**18:,.4f} WETH\n")

# ------------------------------------------------------------- local replay
ARTIFACTS = json.load(open("script/artifacts.json"))
tester = EthereumTester(PyEVMBackend())
w3 = Web3(EthereumTesterProvider(tester))
OWNER, ATTESTOR, SUBJECT, WATCHER = w3.eth.accounts[:4]
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


kek = lambda s: Web3.keccak(text=s)
now = lambda: w3.eth.get_block("latest")["timestamp"]

registry = deploy("MockSealedRegistry")
trigger = deploy("AaveV3DeficitTrigger", registry.address)
provider = deploy("RiskProviderCredentialProvider", registry.address)
pool = deploy("MockAaveV3Pool")  # relay carrying the REAL observed values

CRED, CRED_HIGH = kek("kelp-mandate"), kek("kelp-mandate-high-threshold")
for cred in (CRED, CRED_HIGH):
    registry.functions.setCredential(
        cred, kek("entity/v1"), ATTESTOR, now(), 0, False,
        [trigger.address], [kek("AAVE_V3_GROSS_DEFICIT_V1")],
    ).transact({"from": OWNER})
registry.functions.setWallet(SUBJECT, CRED).transact({"from": OWNER})

# ---- 17 April: the world before the event -------------------------------
pool.functions.createDeficit(WETH, pre).transact({"from": OWNER})
for cred, thr in ((CRED, THRESHOLD), (CRED_HIGH, THRESHOLD_HIGH)):
    trigger.functions.configure(cred, pool.address, thr, now(), 0).transact({"from": ATTESTOR})
    trigger.functions.addReserve(cred, WETH).transact({"from": ATTESTOR})
    trigger.functions.checkpoint(cred).transact({"from": WATCHER})

print(f"== bound 17 April (block {BLOCK_PRE}), threshold {THRESHOLD / 10**18:,.0f} WETH ==")
check("pre-event accumulator is zero (baseline swallows history)",
      trigger.functions.grossDeficitAccumulated(CRED).call() == 0)
check("healthy world: not triggerable", not trigger.functions.isTriggerable(CRED).call())
check("healthy world: provider grants", provider.functions.getCredential(SUBJECT).call() > 0)

# ---- 6 May: the protocol books the rsETH bad debt ------------------------
pool.functions.createDeficit(WETH, post - pre).transact({"from": OWNER})

print(f"== 6 May booking replayed (block {BLOCK_POST}) ==")
trigger.functions.checkpoint(CRED).transact({"from": WATCHER})
gross = trigger.functions.grossDeficitAccumulated(CRED).call()
check(f"gross attributed exactly ({gross / 10**18:,.4f} WETH)", gross == post - pre)
check("gross clears the 1,000 WETH threshold", gross >= THRESHOLD)
check("grant withdrawn on the booking (gates read projections)",
      provider.functions.getCredential(SUBJECT).call() == 0)
trigger.functions.latch(CRED).transact({"from": WATCHER})
check("latched by a random watcher, no human judgement involved",
      trigger.functions.isTriggered(CRED).call())

# ---- counter-run: calibration matters ------------------------------------
print(f"== counter-run, threshold {THRESHOLD_HIGH / 10**18:,.0f} WETH ==")
trigger.functions.checkpoint(CRED_HIGH).transact({"from": WATCHER})
gross_high = trigger.functions.grossDeficitAccumulated(CRED_HIGH).call()
check("same scope, same observation", gross_high == gross)
check("event loss sits below the high threshold", gross_high < THRESHOLD_HIGH)
check("threshold above the loss: not triggerable",
      not trigger.functions.isTriggerable(CRED_HIGH).call())
expect_revert("threshold above the loss: latch reverts",
              lambda: trigger.functions.latch(CRED_HIGH).transact({"from": WATCHER}))

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
