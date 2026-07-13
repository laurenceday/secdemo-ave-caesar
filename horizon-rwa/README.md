# horizon-rwa

Part of the `roleproviders-ave-caesar` demo suite — run all commands below
from this directory.

The Horizon RWA issuer instance for the draft ERC Sealed Entity
Credentials: the institutional-audience demo. Subject: an RWA token
issuer (Superstate USTB is the live reference shape). Two limbs, two
trigger classes, OR-composed at the registry layer by binding both to
one credential — with the liveness limb carried only by issuers whose
redemption path is actually observable on-chain.

Built strictly on top of the live-contract read in
[`docs/HORIZON-READ.md`](./docs/HORIZON-READ.md): every consumed surface
was exercised by eth_call against mainnet on 2026-07-13, including the
two findings that shaped the design — the Horizon oracle adapters are
NOT AggregatorV3 (so the triggers pin the NAVLink aggregator, which also
provides `updatedAt` for staleness), and the USTB instant-redemption
facility exposes both its capacity and its pause state.

## Layout

```
docs/HORIZON-READ.md               the live-contract read (deliverable)
src/
  ISealedEntityCredential.sol      CC0 consolidated ERC interfaces (registry + trigger)
  IWildcatRoleProvider.sol         Apache-2.0 mirror of Wildcat IRoleProvider
  NavDrawdownTrigger.sol           limb A+B: HWM drawdown (bps) + feed darkness
  RedemptionLivenessTrigger.sol    capacity floor + capped compliance-pause carve-out
  RWAIssuerCredentialProvider.sol  pins NAV class; checks liveness class when bound
test/
  *.t.sol                          forge unit suites
  mocks/Mocks.sol                  registry / latch / NAV-feed / redemption mocks
script/
  compile_all.js + runtime_check.py  solc-js + py-evm harness
```

## `keccak256("RWA_NAV_DRAWDOWN_BPS_V1")`

**The deliberate oracle exception.** Base ERC triggers avoid oracles.
This class pins Chainlink NAVLink — Horizon's canonical valuation
source, which the venue itself liquidates against. Pinning the same feed
inherits a trust assumption the venue already carries rather than adding
one. That rationale is stated verbatim in the contract natspec because
it is the exception's boundary: a consumer that does not already trust
the pinned feed should not accept this class.

- **Drawdown limb, with confirmation:** HWM ratchets up at fresh
  in-window checkpoints; drawdown is integer bps of HWM with floor
  rounding (biases toward the subject). A threshold breach does not latch
  on a single print — NAV is a *reported* figure and a lone misprint must
  not become a permanent fact. A breach **arms**, recording the feed
  round (`updatedAt`) that armed it, and is **confirmed** only by a
  second, *distinct* fresh round — `updatedAt` strictly greater than the
  arming round and at least `confirmationWindow` seconds later **in the
  feed's own clock** (not the observer's: a watcher cannot confirm early
  by waiting, and re-checkpointing the same round never confirms). A
  fresh round back above threshold before confirmation **clears** the arm
  (corrected misprint / genuine recovery). Once *confirmed*, the fact is
  permanent — recovery, revision, or a new all-time high cannot cure it.
  An issuer who silences the feed to avoid printing the second round
  walks into the darkness limb instead. Decimals cancel out of the ratio;
  they are recorded in binding data for reference only.
- **Darkness limb:** a checkpoint that finds the feed stale (`updatedAt`
  older than `stalenessBound`, or a non-positive answer) records nothing
  toward valuation — it arms a darkness clock instead. Darkness longer
  than `staleCap` latches: a permanently dark valuation feed is itself a
  disclosure-worthy failure for an RWA. Fresh prints clear the clock;
  darkness accrued after `mandateEnd` is not attributed.
- **Feed pinning:** one immutable feed address per binding. The USTB
  NAVLink feed `0x289B…5AAC` is a Chainlink proxy (phase 2); the
  reference binding pins the underlying aggregator
  `0xd5bC4E3c7E77a5776FD9D0Dde8471B8B4aec10f5`. A phase rotation or feed
  migration is a new trust object → new credential binding. This trigger
  never follows proxies silently.

## `keccak256("USTB_REDEMPTION_LIVENESS_V1")`

The spec's queue-age predicate needs an onchain request queue; USTB's
instant path (`RedemptionIdle` `0x4c21…54Cf`) has none, and the ordinary
path settles offchain — which must NOT be faked with an attestation. The
honest observable is the facility itself:

- **Dry clock:** `maxUstbRedemptionAmount()` below `capacityFloor`
  (unpaused), observed continuously for longer than `dryDuration`,
  latches. The floor and duration come from the issuer's own documented
  settlement/refill terms plus honest operational slack — a design
  conversation with the issuer, not numbers the trigger picks.
- **Capped pause carve-out:** `paused()` is exposed on-chain, so a
  legally-required compliance pause does not run the dry clock — but the
  carve-out is capped: paused longer than `pauseCap` latches anyway. An
  unbounded carve-out would let an issuer pause forever to dodge the
  latch.
- **Clocks clear ONLY on a healthy observation** (unpaused AND at/above
  floor). Pausing does not clear the dry clock; unpausing into a dry
  facility does not clear the pause clock — alternating pause/dry never
  resets anything, and an honest issuer clears everything the moment the
  facility actually serves again. The issuer is the party incentivised
  to checkpoint its own recovery; `checkpoint` is permissionless.

## The provider

`RWAIssuerCredentialProvider` requires a configured, healthy NAV-drawdown
trigger; if the credential ALSO binds a redemption-liveness trigger, that
one must be configured and healthy too. Issuers with no onchain
redemption path bind NAV alone — the gap is disclosed in the
credential's terms, not papered over with an attestation. A venue that
wants to REQUIRE the liveness limb pins that class itself.

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

- NAV trigger: attestor-only one-shot mandate (degenerate mandates
  rejected, decimals recorded); HWM baselines at first fresh in-window
  checkpoint and ratchets up only; exact floor-rounded bps math; a single
  breach round only *arms* (cannot latch alone); confirmation needs a
  second distinct round `confirmationWindow` apart in the feed's clock;
  the same round re-observed never confirms (feed-clock, not
  observer-clock); a corrected misprint clears the arm; a *confirmed*
  drawdown survives full recovery and still latches; silencing the feed
  to dodge confirmation walks into the darkness limb; an unobserved dip
  is missed (poke-cadence caveat); out-of-window prints attribute
  nothing; darkness arms/clears/latches, a live-recovered feed cannot be
  projected dark, and darkness is capped at `mandateEnd`; latch
  materialises its own checkpoint; permanence; `binding()` round-trips.
- Liveness trigger: dry arms below floor and self-clears on health; dry
  past the bound latches; the pause carve-out excuses the dry clock but
  is itself capped; the pause/dry alternation game cannot reset either
  clock; a live-recovered facility cannot be projected failed; arming is
  in-window only and elapsed time caps at `mandateEnd`.
- Provider: two-limb grant lifecycle (either limb kills the grant while
  merely latchable; latch keeps it dead through recovery); NAV-only
  issuers granted; liveness bound-but-unconfigured refused; standard
  refusals (profile, revocation, wrong class, no credential).

## Verification status (as shipped)

- Executed: all sources compile clean under solc 0.8.24 (solc-js); the
  py-evm runtime harness passes 37/37 checks covering everything above.
  The forge suites are written to the same house style as the sibling
  projects but were NOT executed in the build environment (no GitHub
  egress for the foundry toolchain) — CI runs them on push.
- Verified live on mainnet (2026-07-13, docs/HORIZON-READ.md): the
  NAVLink feed's V3 shape, proxy→aggregator structure and fresh prints;
  the Horizon adapters' NON-V3 shape (latestRoundData reverts —
  latestAnswer only, no timestamp); RedemptionIdle's
  `maxUstbRedemptionAmount()` (capacity cross-checked against its USDC
  balance), `paused()`, fee, token/feed wiring.

## Honest limits

The latch proves the predicate — an observed NAV drawdown ≥ threshold on
the pinned feed, an observed feed-darkness past cap, or an observed
redemption-facility failure past its bounds — not fault, insolvency,
default, or breach of the issuer's offchain obligations. The NAV limb
inherits the pinned feed's trust assumptions (issuer NAV reporting with
Chainlink validation); a wrong print observed at checkpoint is a wrong
fact recorded — the same assumption Horizon itself carries at
liquidation. RedemptionIdle is upgradeable and permissioned around
eligible participants: an upgrade that changes `maxUstbRedemptionAmount`
semantics is a new trust object (rebind), and capacity says nothing
about offchain redemption service to ineligible holders. Both triggers
are observation-bound (poke cadence documented above). Compliance-pause
calibration (`pauseCap`) and dry calibration (`capacityFloor`,
`dryDuration`) are issuer-terms conversations. Not audited.

## Disclosure

Superstate contracts (USTB, RedemptionIdle) are named in this demo solely
as a **public reference subject** — used to verify live contract interfaces
against mainnet. There is no pilot, design-partner, commercial, or
investor relationship between Superstate and Wildcat Labs or its investors,
and Superstate has not participated in or endorsed these materials.

For completeness, and per the build spec's disclosure rule: Robot Ventures
is an investor in **Wildcat Labs** (the author of the draft ERC). Robot
Ventures is *not*, to Wildcat Labs' knowledge, an investor in Superstate,
and Superstate is not a Robot Ventures portfolio company. The disclosure
rule is reproduced here because it will bite if that changes: should
Superstate later join a working group, become a design partner or pilot,
or should any investor affiliation arise, this section MUST be updated
before further external use.
