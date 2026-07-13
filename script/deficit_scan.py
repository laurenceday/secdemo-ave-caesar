#!/usr/bin/env python3
"""Pin the exact blocks at which Aave V3 reserve deficits were booked.

Scans the Pool for v3.3 deficit-accounting events over a block range:

    DeficitCreated(address indexed user, address indexed debtAsset, uint256 amountCreated)
    DeficitCovered(address indexed reserve, address caller, uint256 amountCovered)

Use it to verify FORK_BLOCK_PRE / FORK_BLOCK_POST for the Kelp backtest
(test/fork/AaveV3DeficitTrigger.fork.t.sol): PRE must precede the first
event-related DeficitCreated, POST must follow the bookings you want
attributed — and, for the full gross figure, precede any DeficitCovered.

Examples:
    # find a block near a timestamp (binary search)
    python3 script/deficit_scan.py --rpc $MAINNET_RPC_URL --find-block 2026-04-17T00:00:00Z

    # scan a range for deficit events on mainnet core
    python3 script/deficit_scan.py --rpc $MAINNET_RPC_URL --from-block 24500000 --to-block 24650000

stdlib-only (urllib); no third-party dependencies required.
"""
import argparse
import datetime as dt
import json
import os
import sys
import urllib.request

# keccak256 of the event signatures (precomputed; see IPool in
# aave-dao/aave-v3-origin for the declarations).
TOPIC_DEFICIT_CREATED = "0x2bccfb3fad376d59d7accf970515eb77b2f27b082c90ed0fb15583dd5a942699"
TOPIC_DEFICIT_COVERED = "0x84b203e49f1a4b553088061534231969a68ad1c81be192205e96d23a206cb26a"

# Aave V3 Ethereum core Pool (proxy). Override with --pool.
DEFAULT_POOL = "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2"

CHUNK = 5_000  # eth_getLogs block-range chunk; shrink if the node complains


def rpc_call(url, method, params):
    req = urllib.request.Request(
        url,
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        out = json.load(r)
    if "error" in out:
        raise RuntimeError(f"{method}: {out['error']}")
    return out["result"]


def block_ts(url, number):
    b = rpc_call(url, "eth_getBlockByNumber", [hex(number), False])
    return int(b["timestamp"], 16)


def find_block(url, target_ts):
    lo, hi = 1, int(rpc_call(url, "eth_blockNumber", []), 16)
    while lo < hi:
        mid = (lo + hi) // 2
        if block_ts(url, mid) < target_ts:
            lo = mid + 1
        else:
            hi = mid
    return lo


def addr(topic):
    return "0x" + topic[-40:]


def scan(url, pool, from_block, to_block):
    total_created = {}
    for start in range(from_block, to_block + 1, CHUNK):
        end = min(start + CHUNK - 1, to_block)
        logs = rpc_call(url, "eth_getLogs", [{
            "address": pool,
            "fromBlock": hex(start),
            "toBlock": hex(end),
            "topics": [[TOPIC_DEFICIT_CREATED, TOPIC_DEFICIT_COVERED]],
        }])
        for lg in logs:
            blk = int(lg["blockNumber"], 16)
            amount = int(lg["data"][:66] if len(lg["data"]) > 66 else lg["data"], 16)
            if lg["topics"][0] == TOPIC_DEFICIT_CREATED:
                asset = addr(lg["topics"][2])
                total_created[asset] = total_created.get(asset, 0) + amount
                print(f"block {blk}  CREATED  debtAsset={asset}  borrower={addr(lg['topics'][1])}  "
                      f"amount={amount}  tx={lg['transactionHash']}")
            else:
                asset = addr(lg["topics"][1])
                print(f"block {blk}  COVERED  reserve={asset}  amount={amount}  "
                      f"tx={lg['transactionHash']}")
    print("\n-- gross DeficitCreated per asset over range --")
    for asset, amount in sorted(total_created.items(), key=lambda kv: -kv[1]):
        print(f"{asset}  {amount}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--rpc", default=os.environ.get("MAINNET_RPC_URL"),
                   help="archive RPC URL (default: $MAINNET_RPC_URL)")
    p.add_argument("--pool", default=DEFAULT_POOL)
    p.add_argument("--from-block", type=int)
    p.add_argument("--to-block", type=int)
    p.add_argument("--find-block", metavar="ISO_DATETIME",
                   help="print the first block at/after this UTC time and exit")
    args = p.parse_args()
    if not args.rpc:
        sys.exit("no RPC URL: pass --rpc or set MAINNET_RPC_URL")

    if args.find_block:
        ts = int(dt.datetime.fromisoformat(args.find_block.replace("Z", "+00:00")).timestamp())
        n = find_block(args.rpc, ts)
        print(f"block {n} (timestamp {block_ts(args.rpc, n)}) is the first at/after {args.find_block}")
        return

    if args.from_block is None or args.to_block is None:
        sys.exit("scan mode needs --from-block and --to-block")
    scan(args.rpc, args.pool, args.from_block, args.to_block)


if __name__ == "__main__":
    main()
