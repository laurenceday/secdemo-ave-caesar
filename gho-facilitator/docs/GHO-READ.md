# GHO read — GhoToken facilitator bucket state

Live verification for the GHO facilitator wind-down trigger (SEC build spec
demo 4). eth_call against Ethereum mainnet, 2026-07-13.

## Accessor

GhoToken `0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f` exposes per-facilitator
bucket state:

```solidity
function getFacilitatorBucket(address facilitator)
    external view returns (uint256 capacity, uint256 level);
function getFacilitatorsList() external view returns (address[] memory);
```

The on-chain bucket fields are `uint128` (`capacity`, `level`); they
ABI-decode cleanly into `uint256`. `capacity` is the governance-set mint
ceiling; `level` is the amount of GHO the facilitator currently has minted.

## Live snapshot (6 facilitators)

| Facilitator | capacity (GHO) | level (GHO) |
| --- | --- | --- |
| `0x5513…fa05` | 250,000,000 | 135,000,000 |
| `0xb639…62b8` | 2,000,000 | 0 |
| `0x2bd0…66e9` | 50,000,000 | 50,000,000 |
| `0xe9ac…27d2` | 310,000,000 | 310,000,000 |
| `0x2ce0…7285` | 175,000,000 | 45,000,000 |
| `0xe10c…b9ea` | 80,000,000 | 59,000,000 |

None currently exhibits the wind-down shape the trigger watches for —
`capacity == 0 && level > 0` — which is the point: it is the offboarding
signal (governance has zeroed the ceiling) combined with an undischarged
duty (GHO still minted). `0xb639…` shows the benign end state the trigger
must NOT fire on (capacity nonzero, level 0); a fully wound-down offboard
would read `capacity == 0 && level == 0`, which also does not fire.

## What the trigger consumes

| Need | Surface | Form |
| --- | --- | --- |
| Offboarding signal | `getFacilitatorBucket(f).capacity == 0` | view |
| Undischarged duty | `getFacilitatorBucket(f).level > 0` | view |
| Subject identity | pinned facilitator address | binding data |

No oracle, no accumulator, no events. The predicate is two reads plus a
persistence clock. The facilitator entity → credential mapping is an
attested registry-level fact (there is no on-chain "facilitator entity"
beyond the address governance registered).
