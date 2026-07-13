# Horizon read — what the live contracts expose vs. what the triggers need

Deliverable-grade verification for the Horizon RWA issuer credential
(SEC build spec demo 3). Every claim below was established by eth_call
against Ethereum mainnet on 2026-07-13, using the Aave address book's
Horizon entries and Superstate's published contract set.

## Addresses (Ethereum mainnet, checked 2026-07-13)

Horizon core: Pool `0xAe05Cd22df81871bc7cC2a04BeCfb516bFe332C8`,
oracle `0x985BcfAB7e0f4EF2606CC5b64FC1A16311880442` (plus
addresses-provider / configurator / ACL / data-provider per the address
book). RWA reserves probed: USTB `0x4341…1C4e`, USCC `0x14d6…020c`,
JTRSY `0x8c21…4b86`, mGLOBAL `0x7433…98A8`, each with a Horizon-facing
oracle adapter.

## 1. The Horizon oracle adapters are NOT AggregatorV3 — pin NAVLink

The spec said "assume AggregatorV3-shape until confirmed". Confirmed
FALSE for the adapters that matter:

- USTB adapter `0x5Ae4…5F44`, USCC adapter `0x14CB…7230`, JTRSY adapter
  `0xfAB6…e7A0`: `decimals()` = 8 and `latestAnswer()` works (USTB:
  1114148300 = $11.141483 at 8dp), but **`latestRoundData()` reverts**.
  No `updatedAt` → no staleness detection possible on the adapter.
- mGLOBAL adapter `0xe034…E939` IS V3-shaped (8dp, fresh `updatedAt`,
  description "mGlobal NAV - Aave Llamaguard").

The NAVLink sources behind USTB are V3-shaped and live:

- Chainlink NAVLink feed `0x289B…5AAC` "USTB NAV per Share": 6dp,
  answer 11141483, fresh `updatedAt`. It is a Chainlink
  **AggregatorProxy** — `aggregator()` = `0xd5bC4E3c7E77a5776FD9D0Dde8471B8B4aec10f5`,
  `phaseId()` = 2. Per the spec's rule (pin the aggregator, do not
  follow proxies silently), the reference binding pins the underlying
  phase-2 aggregator; a phase rotation is a feed migration and requires
  a new credential binding.
- Superstate realtime NAV oracle `0xe4fa…28a8` "Realtime USTB Net Asset
  Value per Share (NAV/S) Oracle": 6dp, answer 11144444, V3-shaped.
  This is the source the redemption contract itself prices against.

**Trigger consequence:** `NavDrawdownTrigger` consumes any V3-shaped
feed (`latestRoundData`). For USTB the reference binding is the NAVLink
aggregator (the venue's canonical valuation lineage — Horizon liquidates
against NAVLink-derived pricing, so pinning it inherits a trust
assumption the venue already carries rather than adding one). Drawdown
is measured in integer bps of the checkpointed high-water mark, so feed
decimals cancel out of the predicate; decimals are recorded in binding
data for reference only.

## 2. USTB instant redemption — fully observable state, pause included

`RedemptionIdle` proxy `0x4c21…54Cf` (Superstate's instant USTB→USDC
redemption facility), all verified live:

- `maxUstbRedemptionAmount()` → `(394617687961, 11144444)` =
  394,617.69 USTB redeemable at $11.144444 — cross-checks exactly
  against the contract's 4,398,838.68 USDC balance. This is the
  **capacity view** the liveness trigger reads.
- `paused()` → false. Pausability is exposed on-chain, so the spec's
  preferred compliance-pause design — carve-out with a hard cap — is
  implementable, not hypothetical.
- `redemptionFee()` = 0; `USDC()`, `SUPERSTATE_TOKEN()` (= USTB), and
  `CHAINLINK_FEED_ADDRESS()` (= the realtime NAV oracle `0xe4fa…`) all
  as expected; `calculateUsdcOut(1e6)` = 11144444.
- Entry point for actual redemption: `redeem(uint256)`; eligibility is
  permissioned and the contract is upgradeable (owner
  `0x8cf4…0765`) — both stated as trust assumptions in the README.

**Trigger consequence:** the spec's queue-age predicate (oldest
unfulfilled request older than N) does not apply — instant redemption
has no onchain request queue, and the ordinary route (`offchainRedeem`
on the token) is offchain-settled, which per catalogue §12 must NOT be
faked with an attestation. The honest onchain liveness predicate for
this issuer is **facility capacity**: the instant-redemption contract
unable to serve redemptions (capacity below a floor, or paused)
continuously beyond configured bounds. That is what
`RedemptionLivenessTrigger` implements, with the pause carve-out capped.

## What the triggers consume (complete list)

| Need | Live surface | Form |
| --- | --- | --- |
| NAV per share + timestamp | NAVLink aggregator `latestRoundData()` | view, 6dp answer, unix `updatedAt` |
| Feed identity | pinned aggregator address (proxy resolved at binding) | binding data |
| Redemption capacity | `maxUstbRedemptionAmount()` first return | view, USTB base units |
| Compliance pause | `paused()` | view, bool |

No events, no offchain data, no attestation enters either predicate.
The Horizon Pool itself is not consumed by these triggers (the issuer,
not the venue, is the credential subject); Horizon is the reference
consumer that would pin these trigger classes.
