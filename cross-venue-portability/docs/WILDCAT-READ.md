# Wildcat market read — the delinquency surface

Source read for the Wildcat delinquency trigger, from
`wildcat-finance/v2-protocol` (uploaded 2026-07-13). No mainnet market
address was in scope for a live eth_call, so this is a source-level read;
the mirrored interface is faithful to the market's ABI for use on a fork.

## Surface

`WildcatMarketBase` exposes:

```solidity
function currentState() external view returns (MarketState memory);   // nonReentrantView
uint public immutable delinquencyGracePeriod;                          // getter: delinquencyGracePeriod()
```

`MarketState` (from `src/libraries/MarketState.sol`) carries, among 14
fields, `uint32 timeDelinquent` — "seconds borrower has been delinquent" —
and `bool isDelinquent`. The trigger reads only `timeDelinquent`.

Key property: `currentState()` returns the market state **accrued to the
current block**. `timeDelinquent` is projected forward using the elapsed
time since `lastInterestAccruedTimestamp` (see `FeeMath.sol`), so a view
call reflects ongoing delinquency without any poking transaction. The
trigger therefore needs no checkpoint of its own — `isTriggerable` is a
genuinely live read.

`timeDelinquent` is NOT monotone: `FeeMath` increments it while the market
is below its liquidity requirement and `satSub`-decays it while healthy.
This is why the trigger is a point-in-time predicate, not an accumulator: a
borrower who cures before crossing the threshold is, correctly, not in
default.

## Predicate

`timeDelinquent > delinquencyGracePeriod + graceExtension`

The ERC cites `keccak256("WILDCAT_DELINQ_90D_V1")` as an example class for
"90 days of penalised delinquency." That is this trigger's
`WILDCAT_DELINQ_V1` class with `graceExtension = 90 days`; the extension is
per-credential binding data, the market's own `delinquencyGracePeriod` is
read live.

## What the trigger consumes

| Need | Surface | Form |
| --- | --- | --- |
| Penalised delinquency | `currentState().timeDelinquent` | view, seconds, live-accrued |
| Grace period | `delinquencyGracePeriod()` | view, seconds |
| Scope | pinned market address | binding data |

No oracle, no checkpoint, no accumulator — one struct read and one
immutable read.
