# Aave V4 codebase read — what the hub exposes vs. what the trigger needs

Deliverable required by the SEC build spec before any V4 trigger code:
every claim below was verified against the `aave-v4` codebase (main, as
uploaded 2026-07-13), file/line references included. V4 is ~3.5 months on
mainnet; re-verify against the deployed instance before production binding.

## 1. Per-spoke deficit accounting — EXISTS, first-class

The v3.3 deficit lineage carries into V4 at *finer* granularity: deficits
are tracked per (asset, spoke) pair on the Hub.

- Accessor: `IHubBase.getSpokeDeficitRay(uint256 assetId, address spoke)
  returns (uint256)` — "expressed in asset units and scaled by RAY"
  (uint200 `deficitRay` field of `SpokeData`, `IHub.sol`).
  Hub-wide per-asset aggregate: `getAssetDeficitRay(assetId)`.
- Written by `reportDeficit(assetId, drawnAmount, premiumDelta)` — called
  by the spoke itself ("only callable by active spokes") when its
  liquidation path writes off unrecoverable debt (`ISpoke` /
  `LiquidationLogic`). Event: `ReportDeficit(assetId, spoke, drawnShares,
  premiumDelta, deficitAmountRay)`.
- Reduced by `eliminateDeficit(assetId, amount, spoke)` — `restricted`
  (OZ AccessManager), role `HUB_DEFICIT_ELIMINATOR_ROLE = 103` in the
  deployment roles library; the covering spoke burns its added shares and
  `coveredSpoke.deficitRay -= deficitAmountRay` (`Hub.sol`,
  `eliminateDeficit`). Event: `EliminateDeficit`.

**Consequence:** the counter is net, exactly like v3.3 — the Demo 1
checkpointed monotonic gross accumulator carries over verbatim, scoped to
(spoke, assetId[]). Units are RAY-scaled asset units (1e27 × base units);
the trigger keeps thresholds in the same RAY precision, no rounding.

## 2. Credit line — `drawCap`, readable state

The docs-level "credit line" is `SpokeData.drawCap`; the deposit-side
"debit line" is `addCap`.

- `getSpoke(assetId, spoke) returns (SpokeData)` and
  `getSpokeConfig(assetId, spoke) returns (SpokeConfig)` are public views
  (`Hub.sol`). `SpokeConfig = {addCap, drawCap, riskPremiumThreshold,
  active, halted}`.
- Caps are `uint40`, "expressed in whole assets (not scaled by decimals)";
  `MAX_ALLOWED_SPOKE_CAP = type(uint40).max` means uncapped; enforcement
  multiplies by `10**decimals` at draw time (`Hub.sol`,
  `_validateDrawCap`).
- Current drawn amount: `getSpokeDrawnShares` / `getSpokeOwed` /
  `getSpokeTotalOwed`.

**Caveat that shapes limb 2:** `drawCap == 0` is NOT inherently a
sanction. Fee-receiver spokes are registered with "maximum add cap and
zero draw cap" as their normal state, and an add-only spoke could be
configured the same way. The spec's ordering condition (zero line
observed only after gross deficit ≥ floor) is therefore load-bearing, and
the trigger additionally requires that a *positive* drawCap was observed
on that asset earlier in the credential's history — a line that never
existed cannot have been "reduced to zero".

## 3. Spoke registration / credit-line changes — readable state + events

- `addSpoke(assetId, spoke, SpokeConfig)` — reverts on re-add
  (`SpokeAlreadyListed`); event `AddSpoke(assetId, spoke)`.
- `updateSpokeConfig(assetId, spoke, SpokeConfig)` — event
  `UpdateSpokeConfig(assetId, spoke, config)`.
- There is no spoke *removal*; deactivation is `active = false` (and/or
  `halted = true`) via config update. All of it is state a view can read;
  events exist for watchtower cadence but the trigger never needs them.

## 4. Spoke operator role — NO single on-chain operator address

V4 access control is OpenZeppelin AccessManager throughout: Hub and
Spokes are `AccessManaged`, admin functions are `restricted`, and the
deployment roles library defines numbered roles (`SPOKE_DOMAIN_ADMIN_ROLE
= 300`, `SPOKE_CONFIGURATOR_ROLE = 301`, …) on a single authority per
chain. Role membership is queryable (`authority()`, `hasRole`), but
"the operator" is a role-holder set on a shared authority — there is no
per-spoke owner address to bind.

**Consequence (spec fallback applies):** the credential binding pins the
spoke contract address (and hub, chain id); the entity→spoke operatorship
mapping is an attested, registry-level fact verified by the attestor at
issuance, stated plainly in the README. The EVK windowing rule applies at
operator transitions: the mandate window bounds attribution, ambiguity
biases toward the subject.

## What the trigger consumes (complete list)

| Need | V4 surface | Form |
| --- | --- | --- |
| Realised loss per spoke | `getSpokeDeficitRay(assetId, spoke)` | view, RAY-scaled asset units |
| Credit line state | `getSpokeConfig(assetId, spoke).drawCap` (+ `active`) | view, whole assets |
| Scope pinning | hub + spoke addresses, `assetId[]` (append-only) | binding data |
| Elimination resistance | gross accumulator over checkpoints | trigger-side |
| Operator attribution | attested at issuance (no on-chain role) | registry-level |

Nothing the trigger needs is events-only. No oracle enters the predicate.

## Addendum: verified against the DEPLOYED mainnet instance (2026-07-13)

The activation AIP (AaveV4Ethereum_ActivateV4Ethereum_20260319, deployed
release 0.5.11) supplies the live addresses; every surface the trigger
consumes was exercised by eth_call against the deployed Core Hub
`0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9`:

- `MAX_ALLOWED_SPOKE_CAP()` = 1099511627775 (`type(uint40).max`) — matches.
- `getAssetId(WETH)` = 0; `getAssetUnderlyingAndDecimals(0)` round-trips
  (WETH, 18) — matches.
- `getSpokeConfig(0, spoke)` decodes exactly per the mirrored
  `SpokeConfig` layout, with live values (WETH, whole-asset caps):
  Main Spoke `0x94e7…c485` addCap 24000 / drawCap 2050; Lido Spoke
  `0xe190…35Cd` drawCap 4800; **Kelp Spoke `0x3131…B9a4` drawCap 2500**;
  all active, none halted.
- `getSpokeDeficitRay(0, spoke)` = 0 for all of the above (young system).
- Treasury Spoke `0xB9B0…3155` (the configured fee receiver) reads
  **addCap = MAX, drawCap = 0** — the zero-line-by-construction shape
  that motivates the trigger's `capEverPositive` guard, confirmed live.

The uploaded codebase read above was `main`; the deployed tag is 0.5.11.
No divergence was observed on any consumed surface.
