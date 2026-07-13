# gho-facilitator

Part of the `roleproviders-ave-caesar` demo suite — run all commands below
from this directory.

The GHO facilitator wind-down instance for the draft ERC Sealed Entity
Credentials: the missed-duty trigger family (#4) with zero proxies. Subject:
a GHO facilitator entity. The smallest demo in the suite and a deliberate
one — it shows the missed-duty family against a real permissioned-entity
subject using nothing but two reads of first-class token state.

Built on the live read in [`docs/GHO-READ.md`](./docs/GHO-READ.md): the
GhoToken facilitator-bucket accessor and the six live facilitators, verified
by eth_call on mainnet.

## Layout

```
docs/GHO-READ.md                     the live GhoToken read (deliverable)
src/
  ISealedEntityCredential.sol        CC0 consolidated ERC interfaces
  IWildcatRoleProvider.sol           Apache-2.0 mirror of Wildcat IRoleProvider
  GhoFacilitatorWindDownTrigger.sol  capacity==0 && level>0, sustained > N
  GhoFacilitatorCredentialProvider.sol  provider, pins GHO_FACILITATOR_WINDDOWN_V1
test/
  *.t.sol                            forge unit suite
  mocks/Mocks.sol                    registry / latch / GhoToken mocks
script/
  compile_all.js + runtime_check.py  solc-js + py-evm harness
```

## The trigger class

`keccak256("GHO_FACILITATOR_WINDDOWN_V1")`

GhoToken tracks each facilitator's bucket as first-class state: `capacity`
(the governance-set mint ceiling) and `level` (the amount currently minted).
The predicate:

- `capacity == 0` is the unambiguous **offboarding signal** — governance has
  told the facilitator to stop minting.
- `level > 0` means the wind-down **duty is undischarged** — GHO it was
  supposed to retire is still outstanding.
- The state must **persist** continuously for longer than `windDownPeriod`
  (the facilitator's documented wind-down terms plus honest slack — a
  mandate-design conversation, not a number the trigger picks). A
  facilitator burning its level down is performing the duty, not breaching
  it; `checkpoint` self-clears the moment a later observation sees
  `level == 0` (wound down) or `capacity > 0` (re-onboarded).

No oracle, no accumulator, no high-water mark, no event indexing — the token
does the accounting, the trigger reads two words and runs a persistence
clock. `binding()`: chain id, GhoToken, facilitator, wind-down period
(seconds), window (unix seconds).

## Running the tests

```bash
forge build --sizes && forge test -vvv          # canonical
# or, foundry-less:
npm install solc@0.8.24 && pip install eth-tester py-evm web3
node script/compile_all.js && python3 script/runtime_check.py
```

## What the tests assert

- Attestor-only one-shot mandate (degenerate mandates rejected); a healthy
  facilitator never arms; an offboarded-and-fully-wound-down facilitator
  (`level == 0`) never arms; a wind-down in progress arms but is not
  latchable within the window; winding down in time or being re-onboarded
  clears the clock; a sustained offboard past the window is provable,
  latchable permissionlessly, and permanent (a belated wind-down after the
  latch cannot un-latch); a last-moment recovery before the latch cannot be
  projected; window attribution (arming in-window only, elapsed capped at
  `mandateEnd`); `binding()` round-trips.
- Provider: grant = `issuedAt`; standard refusals (no credential,
  revocation, unconfigured mandate, wrong class).

## Verification status (as shipped)

- Executed: sources compile clean under solc 0.8.24 (solc-js); the py-evm
  runtime harness passes 16/16 checks. The forge suite runs on CI.
- Verified live (docs/GHO-READ.md): `getFacilitatorBucket` /
  `getFacilitatorsList` on GhoToken `0x40D1…6C2f`, the six live facilitators
  and their buckets, and the absence of the wind-down shape today (the
  benign `capacity>0, level 0` and the fully-wound `capacity 0, level 0`
  end states the trigger must not fire on).

## Honest limits

The latch proves the predicate — an offboarded facilitator with undischarged
outstanding GHO past its wind-down window — not fault, insolvency, or bad
faith; a slow wind-down may be legitimate, and the latch discloses rather
than adjudicates. Arming is observation-bound: persistence must be
checkpointed at its start, so a missed poke delays the earliest provable
latch (offboarding is slow and governance-visible, so the window is
generous). The facilitator entity → credential mapping is attested at the
registry level; on-chain there is only the address governance registered.
Not audited.
