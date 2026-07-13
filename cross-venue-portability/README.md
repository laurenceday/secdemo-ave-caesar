# cross-venue-portability

Part of the `secdemo-ave-caesar` demo suite — run all commands below
from this directory.

The closing demo, and the actual pitch of the ERC: **reusable KYB + a
shared consequence surface.** One `entity/v1` credential is issued once and
accepted at two venues — a Wildcat undercollateralised-credit market and an
Aave V3 reserve — each pinning its own trigger class on the same
credential. A latch in either venue is a permanent registry fact both
venues can read. No new trigger machinery: this is registry-side
composition over triggers built elsewhere in the suite.

## What is and isn't new here

- `AaveV3DeficitTrigger.sol` — reused **verbatim** from
  [`aave-v3-kelp/`](../aave-v3-kelp/) (the Kelp demo's gross-deficit
  trigger).
- `WildcatDelinquencyTrigger.sol` — the "existing Wildcat delinquency
  trigger" the build spec's Demo 5 refers to, materialised here as a real
  market-reading trigger (`timeDelinquent > gracePeriod + graceExtension`,
  a pure live read — see [`docs/WILDCAT-READ.md`](./docs/WILDCAT-READ.md)).
  It is the simplest trigger in the suite: no accumulator, no checkpoint,
  no oracle.
- `CrossVenueConsumer.sol` — the genuinely new Demo-5 code: a venue
  acceptance policy that pins a set of trigger classes and reads the shared
  credential.

## The composition

One credential binds both `WILDCAT_DELINQ_V1` and
`AAVE_V3_GROSS_DEFICIT_V1`. Three consumers model three venue policies:

- `venueWildcat` pins `[WILDCAT_DELINQ_V1]` — the Wildcat market.
- `venueAave` pins `[AAVE_V3_GROSS_DEFICIT_V1]` — the Aave venue.
- `venuePortable` pins **both** — a venue that treats an entity which
  defaulted *anywhere* as untrusted here.

`accepts(account)` grants iff the bound credential is a live `entity/v1`
and, for every pinned class, binds a trigger of that class that has neither
latched nor become latchable. `latchedClasses(credentialId)` returns which
pinned classes have *recorded* a latch — the permanent cross-venue fact.

The demo shows, in both directions:

1. **One onboarding, both venues accept** the healthy credential.
2. **Venue-local isolation:** a Wildcat delinquency latch makes the entity
   unusable at the Wildcat venue and at any portability-aware venue, but an
   Aave-only venue that never pinned the Wildcat class is unaffected.
3. **Shared consequence surface:** the latch reads back through the *same
   credentialId* — `venuePortable.latchedClasses` shows the Wildcat class
   fired, visible to the Aave-side venue that opts into portability.
4. **Permanence beats cure:** the borrower curing delinquency after the
   latch cannot restore acceptance anywhere reading that class.
5. **Shared lifecycle:** one revocation (or expiry) of the single
   credential disables the entity at every venue at once.

This is the interoperability surface the ERC proposes: an entity verified
once, a consequence surface shared across venues, each venue pinning the
classes it cares about (ERC §11 — pin classes, not addresses).

## Running the tests

```bash
forge build --sizes && forge test -vvv          # canonical
# or, foundry-less:
npm install solc@0.8.24 && pip install eth-tester py-evm web3
node script/compile_all.js && python3 script/runtime_check.py
```

## What the tests assert

- One onboarding accepted at both venues; a credential binding only one
  class is fine at that venue but rejected by the portable venue that
  requires both.
- Wildcat default: latchable → Wildcat and portable venues reject, Aave-only
  venue isolated; after latch, the class is visible via `latchedClasses` on
  the shared credential; a cure cannot un-latch.
- Symmetric for an Aave deficit; both venues latching shows both classes
  visible on one credential.
- One revocation disables every venue at once.

## Verification status (as shipped)

- Executed: sources compile clean under solc 0.8.24 (solc-js); the py-evm
  runtime harness passes 18/18 checks covering the full composition both
  directions. The forge suite runs on CI.
- Source-verified against `wildcat-finance/v2-protocol` (docs/WILDCAT-READ.md):
  `currentState()` / `delinquencyGracePeriod()` and the `MarketState`
  layout; the Aave limb inherits the live mainnet verification from the
  Kelp demo. No live Wildcat market address was in scope for an eth_call —
  the mirrored `IWildcatMarketLike` is faithful to the ABI for fork use.

## Honest limits

Each latch proves its own venue's predicate — penalised delinquency past
the extension, or gross deficit past threshold — not fault or legal
default. Portability is a *policy* choice: venues are not forced to honour
another venue's latch; the registry makes the latch visible, and a
consumer chooses whether to pin the other venue's class. The Wildcat
trigger is a live read with no persistence clock, so a borrower momentarily
delinquent past the threshold is latchable for exactly as long as the
condition holds — permissionless latching is what converts a transient
provable state into a permanent fact, so watchtowers matter. Not audited.
