# roleproviders-ave-caesar

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
| `aave-v4-spoke/` | Spoke operator (hub→spoke credit lines) | Realised loss + hub-side sanction; consumer freezes new exposure only | Planned |
| `horizon-rwa/` | RWA token issuer | Redemption liveness + NAV drawdown (NAVLink-pinned) | Planned |

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
