# aave-v3-gross-deficit

The Aave V3 risk-service-provider instance of the realised-loss trigger
family for the draft ERC Sealed Entity Credentials: a gross-deficit trigger
over an Aave v3.3+ reserve mandate, read straight from the protocol's native
per-reserve deficit counter — plus the Kelp backtest, replaying the April
2026 rsETH exploit to show the credential latching on real history with no
human judgement involved.

Aave v3.3 introduced protocol-native deficit accounting: bad debt burned
during liquidation is recorded as a per-reserve deficit in underlying units
(`Pool.getReserveDeficit(asset)`), with elimination restricted to the
Umbrella coverage path. That is the native cumulative-loss counter the
Morpho and Euler Earn instances of this family lack: no oracle, no
high-water-mark share-price proxy, no event indexing on the loss measure
itself. One complication, and it is the heart of this instance: the counter
is **net** — eliminations reduce it — so the trigger keeps a checkpointed
monotonic accumulator of **gross** deficit incurred. A subject (or a
friendly third party) curing the counter before anyone latches changes
nothing that was already observed.

## Layout

```
src/
  ISealedEntityCredential.sol         CC0 consolidated ERC interfaces (registry + trigger)
  IWildcatRoleProvider.sol            Apache-2.0 mirror of Wildcat IRoleProvider (deposit-hook branch)
  AaveV3DeficitTrigger.sol            the trigger: gross-deficit accumulator over a mandate's reserve set
  RiskProviderCredentialProvider.sol  provider, pins AAVE_V3_GROSS_DEFICIT_V1 + a configured mandate
test/
  *.t.sol                             forge unit suites (trigger, provider incl. loss lifecycle)
  fork/*.fork.t.sol                   env-gated mainnet fork test: the Kelp backtest
  mocks/Mocks.sol                     registry / latch-trigger / Aave-pool mocks
script/
  compile_all.js + runtime_check.py   solc-js + py-evm harness for foundry-less environments
  deficit_scan.py                     pins DeficitCreated/DeficitCovered blocks for the backtest
  artifacts.json                      compiled artifacts consumed by runtime_check.py
.github/workflows/ci.yml              forge build + unit tests on push; fork job gated on RPC secret
```

## The trigger class

`keccak256("AAVE_V3_GROSS_DEFICIT_V1")`

Unlike its siblings, this class carries per-credential binding data (the
ERC build spec's `ITriggerClass.binding()` shape) rather than pinning one
threshold in the class name:

- The credential's attestor pins the mandate one-shot: the canonical V3
  Pool, the threshold (base units of the scope's denomination), and the
  mandate window `[mandateStart, mandateEnd]` (`mandateEnd = 0` =
  open-ended). `binding()` returns
  `abi.encode(chainid, pool, threshold, mandateStart, mandateEnd, reserves)`.
- Reserves are append-only, capped at 16, addable by the attestor or by a
  wallet bound to the credential (the subject widening its own
  accountability), pre-latch only. Each reserve baselines at its deficit at
  add-time — history never counts, additions mid-mandate start from the
  live counter.
- `checkpoint` is permissionless: increases observed inside the mandate
  window accumulate into `grossDeficitAccumulated`; `lastObservedDeficit`
  updates in **all** cases, including decreases, so an elimination neither
  erases accumulated history nor suppresses the counting of new bad debt
  from the lowered base.
- `isTriggerable` reads the projection (accumulator + live un-checkpointed
  in-window increases); `latch` is permissionless, materialises its own
  checkpoint in the same transaction, and is permanent and inclusive at the
  threshold.

### Normalisation

Deficits are denominated per-reserve in underlying units and the trigger
never converts across assets via an oracle. A conforming mandate binds
same-denomination reserves only: one credential per denomination is the
base mode (the Kelp backtest binds the WETH reserve alone); a same-peg
stablecoin set under a documented 1:1 assumption is the convenience mode.

### Window attribution

Attribution is by checkpoint time. Rises checkpointed before `mandateStart`
or after `mandateEnd` move the observation base but are never attributed to
the subject — which biases **toward** the subject at both boundaries: a
pre-start rise is swallowed into the base, and an in-window rise nobody
checkpointed before expiry becomes unattributable. Watchtowers SHOULD
checkpoint on every `DeficitCreated` event and just before the window
closes. Once a threshold crossing is checkpointed in-window, the fact
survives mandate expiry and stays latchable forever.

## The Kelp backtest

`test/fork/AaveV3DeficitTrigger.fork.t.sol` replays the April 2026 KelpDAO
rsETH bridge exploit (~116,500 rsETH drained via the LayerZero bridge
18–19 April; public reporting put Aave's resulting bad-debt exposure in the
$123M–$230M range, WETH being the principal borrowed reserve) against the
real mainnet Pool:

1. Fork at a block shortly before the event; bind a WETH mandate with a
   1,000 WETH threshold; checkpoint — accumulator is exactly zero (the
   bind-time baseline swallows all prior deficit history); the provider
   grants.
2. `rollFork` past the event's bad-debt liquidations; checkpoint; the gross
   accumulator clears threshold; the grant is already dead (gates read
   projections); a random watcher latches. *This credential, had it existed
   on 17 April, latches on 18 April with no human judgement involved.*
3. The counter-run: a second credential bound at the same pre-event block
   with a 200,000 WETH threshold observes the same gross figure and does
   **not** latch — calibration matters in both directions.

```bash
MAINNET_RPC_URL=<archive node> forge test --match-path "test/fork/**" -vvv
# override once verified: FORK_BLOCK_PRE / FORK_BLOCK_POST / KELP_THRESHOLD /
#                         KELP_THRESHOLD_HIGH / KELP_RESERVE
```

The default block numbers (24,530,000 / 24,600,000) are timestamp
**estimates, not verified event blocks**. Before treating a green run as
the canonical backtest, pin the real bookings:

```bash
python3 script/deficit_scan.py --rpc $MAINNET_RPC_URL --find-block 2026-04-17T00:00:00Z
python3 script/deficit_scan.py --rpc $MAINNET_RPC_URL --from-block <pre> --to-block <post>
```

The scanner lists every `DeficitCreated`/`DeficitCovered` on the Pool with
per-asset gross totals. Choose `FORK_BLOCK_POST` after the bookings and —
for the full gross figure — before any coverage events: the two-checkpoint
replay understates gross if eliminations land between the checkpoints,
which is itself the poke-cadence caveat made visible.

## Running the tests

Foundry (canonical path):

```bash
forge build --sizes
forge test --no-match-path "test/fork/**" -vvv
```

No-foundry path (proves execution on py-evm; used where the toolchain
can't be installed):

```bash
npm install solc@0.8.24 && pip install eth-tester py-evm web3
node script/compile_all.js && python3 script/runtime_check.py
```

## What the tests assert

- Trigger: attestor-only one-shot mandate configuration (degenerate
  mandates rejected); subject-or-attestor append-only scope with a hard
  cap; add-time baselines exclude prior deficit history (at bind and
  mid-mandate); exact accumulation of checkpointed increases; **gross not
  net** — a deficit checkpointed then fully eliminated still latches, and
  re-incurred debt after a cure counts in full from the lowered base; a
  rise fully cured before any checkpoint is lost (documented poke-cadence
  limit); window attribution on both boundaries including the
  bias-toward-subject cases; projection-based `isTriggerable` with a
  latch that materialises its own observation; inclusive threshold;
  permanence, double-latch revert, scope frozen post-latch; `binding()`
  round-trips the full mandate.
- Provider: grant = credential `issuedAt`; profile mismatch, revocation,
  expiry, missing trigger class ⇒ no grant; a wrong-class credential (e.g.
  a Wildcat borrower's) is unusable here; **unconfigured or empty-scope
  mandates are refused** — a trigger that can never latch is not a
  consequence-bearing credential; sub-threshold loss tolerated, one more
  wei kills the grant while merely latchable, latch-then-cure keeps it
  dead.
- Fork: the backtest and counter-run above, against the real Pool's
  deficit counter at real April 2026 state.

## Verification status (as shipped)

- Executed: all sources compile clean under solc 0.8.24 (solc-js); the
  py-evm runtime harness passes 30/30 checks covering the flows above.
  The forge suites are written to the same house style as the sibling
  repos but were NOT executed in the build environment (no GitHub egress
  for the foundry toolchain) — CI runs them on push.
- Not executed: the fork backtest (needs an archive RPC with April 2026
  state). Its default blocks are estimates; pin them with
  `script/deficit_scan.py` before the first canonical run.
- Verified against aave-dao/aave-v3-origin (July 2026):
  `getReserveDeficit(address) returns (uint256)`; deficit incremented in
  underlying debt-asset units (`debtReserve.deficit += outstandingDebt` in
  LiquidationLogic); `DeficitCreated(address indexed user, address indexed
  debtAsset, uint256 amountCreated)` / `DeficitCovered(address indexed
  reserve, address caller, uint256 amountCovered)`;
  `eliminateReserveDeficit` is the aToken-burning coverage path (access
  restricted in the deployed configuration — the Umbrella entity). Diff
  before integrating; import the originals in an integration repo.

## Honest limits

The latch proves the predicate — gross deficit ≥ threshold observed within
the mandate window over the pinned scope — not fault, negligence,
causation, or legal default. A deficit can be booked by market chaos no
risk provider could have prevented; the credential discloses, the S1
narrative explains. Cross-reserve summation assumes a same-denomination
scope (this repo's reference deployment binds a single WETH reserve).
Gross accumulation is observation-bound: a rise fully eliminated before any
checkpoint is not counted — elimination is a slow, governance-visible path,
so the observation window is generous, but the dependency exists and is
stated. Attribution of a deficit to the mandated entity is a
registry/attestor-level fact (the mandate binding), not something the Pool
exposes on-chain. Mandate-window entry/exit ambiguity biases toward the
subject; checkpoint at the boundaries. Not audited.
