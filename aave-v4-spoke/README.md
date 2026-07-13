# aave-v4-spoke

Part of the `roleproviders-ave-caesar` demo suite — run all commands below
from this directory.

The Aave V4 spoke-operator instance for the draft ERC Sealed Entity
Credentials: the credential that makes permissionless spokes admissible.
V4 formalises hub→spoke credit lines; spoke creation is DAO-gated today
with permissionless creation as stated direction. When anyone can spin up
a spoke, the question a venue actually faces is which spokes are
*admissible* — and this credential is the mechanism: a verified legal
entity behind the spoke, a realised-loss latch nobody can cure away, a
hub-sanction latch, and sealed recourse tiers behind both.

Built strictly on top of the codebase read in
[`docs/V4-READ.md`](./docs/V4-READ.md) — the spec-mandated deliverable
listing what V4 exposes vs. what the trigger needs, with the four VERIFY
items answered. Everything the trigger consumes is readable state; no
oracle enters the predicate.

## Layout

```
docs/V4-READ.md                        the V4 codebase read (deliverable)
src/
  ISealedEntityCredential.sol          CC0 consolidated ERC interfaces (registry + trigger)
  IWildcatRoleProvider.sol             Apache-2.0 mirror of Wildcat IRoleProvider
  AaveV4SpokeTrigger.sol               two-limb trigger over Hub per-spoke deficit + drawCap
  SpokeOperatorCredentialProvider.sol  provider, pins AAVE_V4_SPOKE_GROSS_DEFICIT_V1
  SpokeAllocator.sol                   the consumer: freeze-new-exposure-only
test/
  *.t.sol                              forge unit suites (trigger limbs, provider, demo flow)
  mocks/Mocks.sol                      registry / V4-hub / latch-trigger / ERC20 mocks
script/
  compile_all.js + runtime_check.py    solc-js + py-evm harness for foundry-less environments
```

## The trigger class

`keccak256("AAVE_V4_SPOKE_GROSS_DEFICIT_V1")` — two limbs, OR-composed,
one latch.

**Limb 1 — realised loss.** V4 tracks deficit per (asset, spoke) pair on
the Hub (`getSpokeDeficitRay`, asset units × RAY): the spoke reports its
own liquidation write-offs, and a role-gated `eliminateDeficit`
(`HUB_DEFICIT_ELIMINATOR_ROLE`) reduces the counter. The counter is
therefore net — so this limb is the aave-v3-kelp checkpointed monotonic
gross accumulator verbatim, scoped to the spoke and an append-only
`assetId` set: increases observed in the mandate window accumulate; a cure
before the latch changes nothing already checkpointed; re-incurred debt
counts in full from the lowered base. Thresholds stay in the Hub's own RAY
precision — no rounding anywhere in the predicate.

**Limb 2 — hub-side sanction.** A DAO that zeroes a bleeding spoke's
credit line (`drawCap`) is making exactly the judgement this credential
family wants to surface. But `drawCap == 0` alone is not that judgement —
fee-receiver spokes live at zero by construction, and benign wind-downs
zero lines with no fault implied. Three guards:

1. a **positive** drawCap must have been observed on that asset earlier in
   the credential's history (a line that never existed cannot be "reduced
   to zero");
2. gross deficit must have reached `deficitFloorRay` by the time the zero
   line is observed (same-checkpoint counts — the DAO may sanction in the
   block the loss lands);
3. both observations must fall inside the mandate window.

Once armed, the sanction is permanent: a later cap restoration must not
disarm a pre-latch fact. The residual ambiguity — a DAO zeroing a line for
unrelated reasons after the floor was crossed — is calibrated by the
floor, not hidden; the latch proves the predicate, not fault.

Binding data (`binding()`): chain id, hub, spoke, both thresholds
(asset units × RAY), window in unix seconds, append-only asset scope.

## The consumer: freeze new exposure only

`SpokeAllocator` is the half of the demo that carries the pitch line: the
registry never confiscates; consumers choose consequences. On latch — or
the moment the predicate is provable, since gates read projections — the
allocator refuses `allocate` and `approveCreditIncrease` for that spoke.
Existing positions are untouched (there is deliberately no clawback
surface at all), depositor withdrawals of idle liquidity keep working, and
a latched spoke repaying is still accepted. The demo flow runs healthy
allocation → threshold-clearing bad debt → refusal of new exposure
pre-latch → permissionless latch → withdrawal still succeeding →
repayment making depositors whole.

## Attribution

V4 has no per-spoke operator address on-chain: access control is an
OpenZeppelin AccessManager with numbered role sets on a shared authority
(see the read, §4). The binding pins the hub and spoke contract addresses;
the entity→spoke operatorship mapping is an **attested, registry-level
fact** verified by the attestor at issuance — stated here plainly, per the
spec. Operator transitions are bounded by the mandate window; ambiguity at
boundaries biases toward the subject (pre-window rises are swallowed into
the base, un-poked in-window rises become unattributable at expiry —
watchtowers checkpoint at the boundaries).

## Running the tests

Foundry (canonical path):

```bash
forge build --sizes
forge test -vvv
```

No-foundry path (proves execution on py-evm):

```bash
npm install solc@0.8.24 && pip install eth-tester py-evm web3
node script/compile_all.js && python3 script/runtime_check.py
```

## What the tests assert

- Trigger, limb 1: attestor-only one-shot mandate (degenerate mandates
  rejected); subject-or-attestor append-only asset scope with add-time
  baselines; exact RAY-precision accumulation; gross-not-net (checkpointed
  deficit survives full elimination and still latches; re-incurred debt
  counts from the lowered base); window attribution both sides;
  projection-based `isTriggerable` with a latch that materialises its own
  checkpoint; inclusive threshold; permanence, double-latch revert, scope
  frozen post-latch; `binding()` round-trips the mandate.
- Trigger, limb 2: a never-positive line cannot arm even past the floor
  (fee-receiver shape); a wind-down below the floor cannot arm (benign
  case); deficit-then-sanction arms and latches below the limb-1
  threshold; deficit and sanction observed in the same checkpoint arm;
  sanction-then-deficit arms only once the floor is crossed; cap
  restoration after arming does not disarm; out-of-window sanctions never
  arm.
- Provider: standard refusals (profile, revocation, expiry, wrong class,
  unconfigured/empty-scope mandate); either limb kills the grant while
  merely latchable.
- Allocator: registration pins the trigger class; the full demo flow above
  including existing-exposure non-confiscation and post-latch withdrawal.

## Verification status (as shipped)

- Executed: all sources compile clean under solc 0.8.24 (solc-js); the
  py-evm runtime harness passes 28/28 checks covering both limbs, the
  provider lifecycle, and the full allocator demo flow. The forge suites
  are written to the same house style as the sibling projects but were NOT
  executed in the build environment (no GitHub egress for the foundry
  toolchain) — CI runs them on push.
- Verified against the aave-v4 codebase (main, July 2026 read — see
  docs/V4-READ.md for file-level citations): `getSpokeDeficitRay`,
  `getSpokeConfig`/`SpokeConfig` layout, `drawCap` semantics
  (whole-asset units, `type(uint40).max` = uncapped, fee receivers at
  zero), `reportDeficit`/`eliminateDeficit` flow and role gating,
  `AddSpoke`/`UpdateSpokeConfig` events, AccessManager role structure.
- Verified against the DEPLOYED mainnet instance (Core Hub
  `0xCca8…26c9`, release 0.5.11 per the activation AIP): cap constant,
  assetId lookup, `SpokeConfig` ABI layout with live values for the
  Main/Lido/Kelp spokes, per-spoke deficit reads, and the Treasury
  fee-receiver's zero-drawCap shape — see the addendum in
  docs/V4-READ.md.

## Honest limits

The latch proves the predicate — gross spoke deficit ≥ threshold in-window,
or a guarded hub sanction following floor-clearing deficit — not fault,
negligence, causation, or legal default. Deficit attribution to the
operator entity is an attested registry-level fact, not an on-chain one.
Cross-asset summation assumes a same-denomination scope (reference
deployment: single-asset). Gross accumulation is observation-bound: a rise
fully eliminated before any checkpoint is not counted; elimination is
role-gated and governance-visible, so the window is generous, but the
dependency exists. Limb 2's residual ambiguity is calibrated by
`deficitFloorRay` and disclosed above. drawCap is uint40 whole-asset
units on the Hub — a "zero" line is exactly zero, but a dust cap of 1
whole asset defeats the limb; that is a mandate-design conversation, not a
trigger bug. The allocator is demo-grade (1:1 balances, push-based
returns). Not audited.
