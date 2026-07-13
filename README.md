# secdemos-ave-caesar

Aave-flavoured demos for the draft ERC **Sealed Entity Credentials**:
disclosure triggers over Aave protocol state, each paired with a
trigger-class-pinned role provider. Sibling repos carry the same pattern
for other venues — `roleprovider-gateaccess` (Wildcat gate + Morpho curator
bad-debt trigger) and `roleprovider-earnmanager` (Euler Earn manager
lost-assets trigger).

Those about to risk-manage salute you.

## Demos

| Directory | Subject | Trigger family | Status |
| --- | --- | --- | --- |
| [`aave-v3-kelp/`](./aave-v3-kelp/) | Risk service provider under a DAO reserve mandate | Realised loss: gross protocol deficit (Aave v3.3 native counter), incl. the Kelp rsETH backtest against real mainnet history | **Built + verified** |
| [`aave-v4-spoke/`](./aave-v4-spoke/) | Spoke operator (hub→spoke credit lines) | Realised loss (per-spoke deficit) + guarded hub-sanction limb; consumer freezes new exposure only; incl. the spec-mandated [V4 codebase read](./aave-v4-spoke/docs/V4-READ.md) | **Built + verified** |
| [`gho-facilitator/`](./gho-facilitator/) | GHO facilitator entity | Missed duty: offboarded (`capacity==0`) with undischarged outstanding GHO (`level>0`) sustained past a wind-down window; zero proxies; incl. the live [GhoToken read](./gho-facilitator/docs/GHO-READ.md) | **Built + verified** |
| [`horizon-rwa/`](./horizon-rwa/) | RWA token issuer (Superstate USTB reference shape) | NAV drawdown + feed darkness (NAVLink-pinned, the deliberate oracle exception) + redemption liveness with capped pause carve-out; incl. the [live-contract read](./horizon-rwa/docs/HORIZON-READ.md) | **Built + verified** |
| [`cross-venue-portability/`](./cross-venue-portability/) | A single borrower/issuer entity active in two venues | **The thesis demo:** reusable KYB + shared consequence surface — one credential, `WILDCAT_DELINQ_V1` + `AAVE_V3_GROSS_DEFICIT_V1` OR-composed; a latch in either venue is visible to both | **Built + verified** |
| _V4 Reinvestment Module strategy operator_ | Treasury strategy operator | Mandate-policy breach + realised loss | **Deferred — [read complete](./docs/reinvestment-module-read.md)** |

Demos 1–5 above are the pitch-priority set from the build spec, all built
and verified. Demo 6 (Reinvestment Module) was gated on a read of whether
the module exposes sweep destinations as readable state; it does not (and
strategy P&L settles off-chain), so per the spec it is deferred rather than
built on events — see the [read](./docs/reinvestment-module-read.md).

Each demo directory is a self-contained Foundry project (vendored
`forge-std`, own README, unit + fork suites) plus a solc-js/py-evm harness
for environments without the Foundry toolchain. Run commands from inside
the demo directory.

## Shared shape

Every trigger implements `IDisclosureTrigger` from the ERC draft — a
permanent, permissionless latch over an objective on-chain predicate —
plus the build spec's `ITriggerClass` conventions: per-credential binding
data (`binding()` returns chain id, pinned protocol addresses, thresholds
with units, windows in seconds, append-only scope) and a permissionless
`checkpoint()` where the predicate needs observation history. Every README
states what the latch does and does not prove: the latch proves the
predicate, never fault, negligence, causation, or legal default.
