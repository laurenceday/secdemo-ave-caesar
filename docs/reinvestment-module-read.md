# Demo 6 (V4 Reinvestment Module strategy operator) — read & deferral

The build spec lists Demo 6 as backlog, gated: *"VERIFY how the module
exposes destinations and accounting — if destinations are not readable
state, defer this demo entirely rather than building on events."* This is
that read. Verified against the `aave-v4` codebase (main) and the deployed
mainnet hubs, 2026-07-13.

## Decision: DEFER

Both limbs the spec proposed fail the readable-state gate. Building either
would require indexing events or trusting an off-chain attestation, which
the catalogue's standardisation rules (and the base-ERC no-oracle /
no-events posture) forbid. No trigger code was written.

## Limb (#6) — strategy-envelope / destination compliance: NOT BUILDABLE

The proposed predicate compares the module's *current sweep destinations*
against a hash-committed envelope of allowed venues. The Hub does not expose
destinations:

- The reinvestment path is `Hub.sweep(assetId, amount)` — callable only by
  `asset.reinvestmentController` — which transfers `amount` of the
  underlying to the controller, increments `asset.swept`, and emits
  `Sweep(assetId, caller, amount)`. `reclaim` reverses it. Where the
  controller then deploys those funds is **entirely off the Hub's books**.
- `reinvestmentController` is a bare `address` field on the `Asset` struct
  (set via `HubConfigurator.updateReinvestmentController`). There is **no
  in-tree `IReinvestmentController` interface** and no controller contract
  in the repo — it is a separately-deployed module the DAO points the Hub
  at. Any destination accounting it keeps lives in that external contract,
  out of scope of this codebase and unstandardised.
- The Hub therefore has no readable notion of "which venues the swept
  liquidity is in." The only destination signal on-chain is the `Sweep`
  event's `caller` (the controller itself), not the downstream venues.

A destination-compliance trigger would have to index `Sweep`/`reclaim`
events and then inspect a non-standard external controller — exactly the
"build on events" path the spec says to avoid.

## Limb (#2) — realised loss on swept principal: PARTIAL, and blocked

- Principal out IS readable: `getAssetSwept(assetId) returns (uint256)`
  (the `Asset.swept` field, asset units). A monotonic accumulator over
  swept-vs-reclaimed could track principal exposure.
- But strategy P&L is not on-chain: `IHub` (the `reclaim` natspec) states
  **"All accrued interest is distributed offchain."** The controller can
  only `reclaim` up to `swept` (principal); gains and losses on the swept
  liquidity settle off-chain. So a *realised strategy loss* is not a clean
  on-chain observable — `swept` minus `reclaimed` measures outstanding
  principal, not loss, and the loss itself is an off-chain distribution
  fact. Faking it with an attestation is precisely what catalogue §12 and
  the base-ERC posture rule out.

## Live state (2026-07-13)

`getAssetConfig(0).reinvestmentController` on all three deployed hubs:

| Hub | reinvestmentController (asset 0) |
| --- | --- |
| Core `0xCca8…26c9` | `0x0000…0000` |
| Plus `0x0600…536A` | `0x0000…0000` |
| Prime `0x9438…F931` | `0x0000…0000` |

The module is unconfigured (matches the codebase default and the
security-first activation AIP). There is nothing live to bind against even
if the surface allowed it.

## Revisit criteria

Reconsider Demo 6 only if a future V4 release (or the deployed reinvestment
controller) exposes, as readable on-chain state: (a) the set of destinations
the swept liquidity currently sits in, and (b) realised strategy P&L (not an
off-chain distribution). Until both hold, the mandate-policy-breach family
for this subject cannot be built within the ERC's no-events / no-oracle
base rules. The Aave-side realised-loss family is already well served by
the V3 (aave-v3-kelp) and V4 spoke (aave-v4-spoke) deficit triggers, which
read first-class on-chain counters.
