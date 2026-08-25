# Perps Deployment

This document covers the current deployment flow for the perps stack in `packages/perps/src/`.

The current target network is Arbitrum Sepolia with:

- mock USDC as the settlement asset
- Pyth as the router oracle source
- a separate deploy phase and bootstrap phase

## Scripts

- Deploy script: `script/DeployPerpsArbitrumSepolia.s.sol`
- Bootstrap script: `script/BootstrapPerpsArbitrumSepolia.s.sol`

The deploy script handles contract creation and one-time wiring.

The bootstrap script handles operator actions after deploy:

- verifying the shared emergency coordinator and configuring its guardian
- proposing or finalizing finite senior-exposure limits
- seeding the junior tranche and then the senior tranche
- minting mock USDC to test users
- activating trading

LP deposits and redemptions share the vaults' deterministic round-hour epoch clock and fixed 300-second request
cutoff. Before each cutoff they target the next epoch; during the final five minutes, beginning at exact cutoff
equality, they remain valid but target the following epoch. The numeric target does not change at the intervening
round-hour boundary. After bootstrap, any account may clear matured epochs through
`OrderRouter.settleLpEpoch(bytes[])`; no privileged keeper role is required. Outside oracle-frozen mode, live
open-position settlement requires a valid `PoolReconcile` Pyth basket published at or after the round-hour boundary,
not the request cutoff. Each call examines at most 16 nonempty epochs in each tranche phase and must be repeated with
a freshly validated update when older backlog remains. A no-progress or oracle-rejected call retains no Pyth, Engine,
pool, or vault side effect.

## Deployment Shape

The deploy script creates and wires:

1. `MockUSDC`
2. `MarginClearinghouse`
3. `CfdEngine`
4. `TerminalNavBookV2`
5. `CfdEnginePlanner`
6. `CfdEngineSettlementSidecar`
7. `CfdEngineAdmin`
8. `HousePoolRedemptionMathSidecar`
9. `HousePool`, constructed with the redemption-math sidecar
10. `TrancheVault` senior
11. `TrancheVault` junior
12. `CfdEngineAccountLens`
13. `CfdEngineLens`
14. `OrderRouter` (constructor-deploys its immutable `OrderRouterLiquidationBatchSidecar`)
15. `PerpsPublicLens`
16. `SettlementMonitorLens` (the facade deploys its monitor-bound `SettlementMonitorLensSidecar` internally)
17. `EmergencyPauseCoordinator`

It then performs the required set-once wiring:

- `CfdEngine.setDependencies(...)`
- `CfdEngine.setTerminalNavBook(...)`
- `HousePool.setSeniorVault(...)`
- `HousePool.setJuniorVault(...)`
- `CfdEngine.setPool(...)`
- `CfdEngine.setOrderRouter(...)`
- `MarginClearinghouse.setEngine(...)`

Important:

- `HousePool` remains inactive after deployment.
- `HousePoolRedemptionMathSidecar` is deployed before `HousePool`. It is stateless pure size-management code with no
  storage, setter, delegatecall, upgrade path, custody, or settlement authority. The deploy and bootstrap scripts
  require code and `implementationId() == keccak256("Plether.HousePoolRedemptionMathSidecar.v1")`; HousePool stores
  the validated address immutably. Record it as a first-class deployment artifact even though users never call it.
- `SettlementMonitorLens` is deployed after every settlement dependency is wired. It is the read-only operator/security
  facade bound to the canonical Router deployment; adding it does not shift any earlier deployment address or grant
  settlement authority. Its constructor deploys a size-management `SettlementMonitorLensSidecar` that accepts calls
  only from that facade. Deployment verifies that the facade's `SIDECAR` has code, the sidecar's `MONITOR` is the
  facade, and both contracts' Router, Engine, HousePool, Engine protocol lens, clearinghouse, terminal-book, vault,
  and USDC bindings match the deployed stack. The sidecar is an implementation detail, not a second integration
  address or canonical monitoring surface. Facade construction rejects missing or mismatched required one-time core
  wiring, including equality between the Router's immutable settlement pool and `Engine.pool()`, and the health view
  rechecks those reciprocal bindings rather than assuming deployment stayed correct.
  The sidecar also pins the Engine planner address and code hash at construction and probes its settlement-critical
  carry-index and market-calendar ABIs at runtime. The facade's creation input is close to the EIP-3860 ceiling
  because it embeds the sidecar creation code. The verified V2 build has a 23,339-byte facade runtime, 48,794-byte
  creation code, and 48,826-byte creation input including the 32-byte Router constructor argument, leaving 326 bytes
  of EIP-3860 headroom. The monitor sidecar is 19,114 bytes at runtime with 20,488-byte initcode. Keep the dedicated
  runtime and creation-input size regressions green when changing either contract.
- `EmergencyPauseCoordinator` is deployed after the monitor and immutable-bound to the exact RouterAdmin and
  HousePool. The deploy transaction verifies its code, bindings, owner, disabled initial guardian, zero initial
  `riskOffOrderCutoff`, unpaused children, and inactive LP settlement hold, then installs it as both pausers. It has
  three fixed guardian actions—risk-off plus LP entry, LP-settlement-only, and full containment—but no unpause,
  arbitrary mask, pricing, configuration, fund-transfer, or arbitrary-call surface. Its later reason/evidence hashes
  remain advisory and are not derived or authenticated by the Lens.
- `OrderRouterLiquidationBatchSidecar` is a stateless EIP-170 size split, not an independently operated contract.
  Deploy and bootstrap both require its address to contain code and its immutable `ROUTER()` binding to equal the
  deployed Router. Its entrypoint rejects direct calls and works only through Router delegatecall; it has no mutable
  storage, setter, proxy, or upgrade path. Record the address for verification, but keepers must call the Router.
- An already deployed compatible stack may add the lens independently against its Router; there is no storage
  migration and no core-contract redeployment requirement. Replacing a faulty lens likewise does not move protocol
  authority, but integrations must pin the intended facade address. Full current-feed diagnostics require the
  configured oracle to implement the updated `PletherOracle.getLatestPoolReconcilePrice()` return ABI. A lens bound
  to an older oracle remains read-only and reports that current-feed section as an unknown dependency;
  `observationComplete` stays false and `completeObservationDigest` stays zero until the Router is timelock-rotated to
  a compatible oracle.
- `TerminalNavBookV2` must be deployed empty, immutable-bound to the new Engine, and wired before any position
  exposure. `CfdEngine.setTerminalNavBook(...)` validates matching Engine, `CAP_PRICE`, `SIZE_QUANTUM = 1e20`, and
  zero book version/totals before accepting it once.
- Trading does not go live until a finite capacity configuration completes its 48-hour timelock, both seed positions
  exist within those limits, and `activateTrading()` is called.
- Both configured vaults must report the same pool binding and fixed `LP_REQUEST_CUTOFF_DURATION` of `300` seconds.
  At the same block they must return identical `(nextRequestEpoch, nextRequestCutoffTime)` values from
  `getRequestEpochWindow()`, consistent with the pool's round-hour clock; the cutoff timestamp must be future.
  The pool must also expose the expected shared epoch clock and per-phase bound. Deployment verification must reject a
  mixed old/new vault pair because direct legacy finalization would bypass synchronized Senior/Junior ordering.
- Deploy and bootstrap verification require each vault to report itself from `share()`, map its configured asset back
  to itself through the ERC-7575 share lookup, and advertise ERC-165 plus the ERC-7540 operator (`0xe3bc4e65`),
  async-deposit (`0xce3bbe50`), async-redeem (`0x620ee8e4`), ERC-7575 vault (`0x2f0a18c5`), and ERC-7575 share-token
  (`0xf815c03d`) interface ids. The added custom timing view changes the custom `IAsyncTrancheVault` interface id but
  does not change these standard ids. Both deploy and bootstrap verification must assert
  `supportsInterface(type(IAsyncTrancheVault).interfaceId)` for the rebuilt custom interface; regenerate the custom
  vault and lens ABIs for frontend, keeper, and indexer use.

## Oracle Configuration

The Arbitrum Sepolia deploy script uses Pyth at:

- `0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF`

The router basket uses 6 FX feeds with DXY weights:

- `EUR/USD` direct
- `USD/JPY` inverted
- `GBP/USD` direct
- `USD/CAD` inverted
- `USD/SEK` inverted
- `USD/CHF` inverted

Base prices and weights are currently hardcoded in the script to match the existing perps basket assumptions.

### Arbitrum Sepolia Release Parameters

The next Arbitrum Sepolia perps deployment uses these initial defaults:

| Parameter | Value |
| --- | --- |
| `vpiFactor` | `0.005e18` |
| `frozenCloseSpreadBps` | `50` |
| `maxSkewRatio` | `0.4e18` |
| `maintMarginBps` | `30` |
| `initMarginBps` | `45` |
| `fadMarginBps` | `300` |
| `baseCarryBps` | `500` |
| `minBountyUsdc` | `1e6` |
| `bountyBps` | `10` total liquidation-charge rate |
| `keeperShareBps` | `5_000` (50% of collected charge to keeper) |
| `protocolShareBps` | `0` (protocol liquidation fee disabled; remaining 50% goes to LPs) |
| `executionFeeBps` | `4` |
| `positionSizeQuantum` | `1e20` raw units (100 synthetic tokens) |
| `fadRunwaySeconds` | `1 hours` |
| `basketMaxConfidenceRatioBps` | `10` |
| `adverseConfidenceMultiplierBps` | `2_000` |
| `maxSeniorExposureUsdc` | Operator-supplied finite USDC amount |
| `maxSeniorShareBps` | Operator-supplied value below `10_000` |

`frozenCloseSpreadBps = 50` charges a fixed 0.50% spread on reduced notional for voluntary close/reduce execution only while `oracleFrozen`. Normal signed VPI and its lifetime rebate clamp remain active. For oracle-frozen voluntary closes, the spread replaces rather than compounds with the Pyth adverse-confidence adjustment; live/FAD-only closes and liquidations retain that adjustment. The spread belongs to LPs rather than protocol treasury and does not apply to liquidations. A terminal full close waives any uncollectible portion without creating a protocol liability or terminal deficit, while a partial close must settle this separate spread obligation in full. Price loss beyond the terminal collectible cap is a diagnostic write-off and does not block the partial close.

`frozenCloseSpreadBps` is part of `CfdEngineAdmin.EngineRiskConfig` and therefore uses the 48-hour propose/finalize timelock. Deployments and updates reject zero and values above `1_000` bps (10%). `keeperShareBps` and `protocolShareBps` use the same timelock; both may be zero, but their sum must not exceed `10_000`. Each configured allocation rounds down and LPs receive the exact liquidation-charge remainder.

Terminal NAV V2 changes position storage, clearinghouse bucket semantics, Engine and HousePool snapshot ABIs, and
share-pricing economics. Deploy the Engine, book, clearinghouse, pool, vaults, router, sidecars, oracle, and lenses from
the same build on a fresh testnet deployment. There is no backward-compatibility or in-place migration path, and no V2
contract may be wired to an older stack. This build also includes the dedicated VPI rebate sub-reserve and its planner,
sidecar, lens, and clearinghouse ABI fields; mixing contracts across that boundary can make a live negative VPI balance
under-backed and must be rejected. The `RiskParams` tuple remains a ten-field ABI.

`basketMaxConfidenceRatioBps = 10` accepts the neutral, pre-cap basket only when its weighted aggregate Pyth
confidence is at most `0.10%` of its price:

```text
basketConfidence * 10_000 <= basketPrice * basketMaxConfidenceRatioBps
```

Each component contributes its normalized basket value multiplied by its raw confidence-to-price ratio, with
the contribution floored before summation. Equality passes. There is no separate per-component confidence
ceiling, so a wide low-weight feed can remain usable when its weighted uncertainty keeps the full basket within
the configured limit. Positive-price, staleness, and component publish-time-divergence checks remain per feed.
`PletherOracle.getLatestPoolReconcilePrice()` returns the current validated neutral snapshot plus that aggregate
8-decimal confidence without updating Pyth; `SettlementMonitorLens` consumes it through a fail-soft diagnostic call.
This is an additive monitoring ABI requirement: an older `PletherOracle` can still serve its existing Router paths,
but the monitor cannot decode the current-feed observation and deliberately reports the Oracle dependency as unknown.
The confidence is measured against the neutral pre-cap basket while the returned mark may be capped, so a monitor
cannot always independently reconstruct the configured ratio from `confidence / markPrice`. Treat `policyValid` as
the feed-policy result instead of using that post-cap quotient as a second policy check.

`adverseConfidenceMultiplierBps = 2_000` applies `0.2x` of Pyth's confidence interval when shifting live/FAD
order execution and all liquidation prices in the adverse direction. Oracle-frozen voluntary closes bypass the
shift and use `frozenCloseSpreadBps` instead; aggregate basket confidence-width validation remains active.

### FX Market Calendar

The oracle-frozen regime follows Pyth's recurring FX market boundary at 17:00 New York time. The contracts calculate
the US daylight-saving transition on-chain, so the boundary is 21:00 UTC during daylight time and 22:00 UTC during
standard time. FAD begins 30 minutes before Friday close and ends 15 minutes after Sunday open. On the spring and fall
transition weekends, Friday and Sunday intentionally use different UTC offsets.

`CfdEngine` delegates this deterministic classification to the deployed `CfdEnginePlanner` sidecar to remain below
the EIP-170 runtime-size limit, and `PletherOracle` reads the engine's canonical frozen status. Deploy the engine,
planner, and oracle from the same build; mixing calendar versions can split execution and risk policy.

Before every deployment:

1. Run `forge test --root packages/perps --match-contract MarketCalendarLibTest`.
2. Run `forge test --root packages/perps --match-contract PerpOracleBoundaryInvariantTest`.
3. Confirm the frontend countdown uses the same New York-time rule instead of fixed UTC constants.
4. Configure governance UTC-day overrides for known FX holidays or provider-specific schedule changes.

## Environment

### Deploy

Required:

```bash
TEST_PRIVATE_KEY=...
ARB_SEPOLIA_RPC_URL=...
```

Run:

```bash
source .env && forge script script/DeployPerpsArbitrumSepolia.s.sol:DeployPerpsArbitrumSepolia --rpc-url $ARB_SEPOLIA_RPC_URL --broadcast
```

The script prints the deployed addresses to the console. Save at least:

- `MockUSDC`
- `CfdEngine`
- `TerminalNavBookV2`
- `HousePool`
- `HousePoolRedemptionMathSidecar`
- `OrderRouter`
- `OrderRouterLiquidationBatchSidecar`
- `EmergencyPauseCoordinator`

Bootstrap directly consumes the USDC, HousePool, redemption-math sidecar, Router, and coordinator addresses and
derives the RouterAdmin and liquidation sidecar from the Router. Record every listed address for independent
deployment verification.

### Bootstrap

Required:

```bash
TEST_PRIVATE_KEY=...
ARB_SEPOLIA_RPC_URL=...

PERPS_USDC=0x...
PERPS_HOUSE_POOL=0x...
PERPS_HOUSE_POOL_REDEMPTION_MATH_SIDECAR=0x...
PERPS_ORDER_ROUTER=0x...
PERPS_EMERGENCY_COORDINATOR=0x...
PERPS_GUARDIAN=0x...

MAX_SENIOR_EXPOSURE_USDC=...
MAX_SENIOR_SHARE_BPS=...
```

Optional:

```bash
SENIOR_SEED_USDC=50000000000000
JUNIOR_SEED_USDC=50000000000000

SENIOR_SEED_RECEIVER=0x...
JUNIOR_SEED_RECEIVER=0x...

ACTIVATE_TRADING=true

TEST_USER_RECIPIENTS=0xabc...,0xdef...
TEST_USER_AMOUNTS=1000000000000,500000000000
```

Notes:

- USDC amounts are raw 6-decimal values.
- `50000000000000` means `50_000_000e6`, or 50,000,000 mock USDC.
- Both senior-limit variables are mandatory. The exposure limit must be finite and the share limit must be below
  `10_000` bps; the script deliberately refuses the constructor's uncapped bootstrap values.
- `PERPS_HOUSE_POOL_REDEMPTION_MATH_SIDECAR`, `PERPS_EMERGENCY_COORDINATOR`, and `PERPS_GUARDIAN` are mandatory, and
  the guardian must be nonzero. Bootstrap verifies the supplied released sidecar's code and implementation id for
  rerun inspection; HousePool's internal immutable binding was fixed by its constructor and the deploy script and has
  no runtime getter by design. Bootstrap then verifies that the coordinator has code, is bound to this exact
  RouterAdmin and HousePool, and is already installed as both pausers. It fails closed rather than repairing partial
  or cross-deployment coordinator wiring.
- Choose limits that admit the intended seeds. For symmetric `50_000_000e6` seeds, the exposure cap must be at least
  `50_000_000e6` and the senior-share cap must be at least `5_000` bps.
- `TEST_USER_RECIPIENTS` and `TEST_USER_AMOUNTS` must have the same length.

Run:

```bash
source .env && forge script script/BootstrapPerpsArbitrumSepolia.s.sol:BootstrapPerpsArbitrumSepolia --rpc-url $ARB_SEPOLIA_RPC_URL --broadcast
```

The first run proposes the exact finite limits through `HousePool.proposePoolConfig(...)` and then exits without
seeding, funding test users, or activating trading. Wait at least 48 hours and rerun the same command with the same
environment. The second run verifies the pending proposal, finalizes it, initializes junior before senior, funds test
users, and optionally activates trading. An unrelated outstanding `HousePool` proposal makes the script revert rather
than silently overwrite or finalize it.

## Bootstrap Behavior

The configuration, seed, and activation phases of the bootstrap script are designed to be partial-rerun safe:

- it separates the required limit proposal and finalization across the `HousePool` 48-hour timelock
- it refuses to seed while the requested finite limits are not active
- it rotates the coordinator guardian only when the requested address differs; a matching rerun is a no-op
- it skips a seed if that side is already initialized
- it skips activation if trading is already active

Before proposing limits, seeding, or activation, bootstrap derives the Engine from `HousePool.ENGINE()` and verifies
that a code-bearing `TerminalNavBookV2` is wired with matching Engine, cap, and 100-token quantum and that the supplied
redemption-math sidecar has the expected implementation id. Observable core and coordinator binding mismatches fail
closed. The supplied sidecar check is inspection-only because bootstrap cannot read back HousePool's internal
immutable binding; the canonical deployment transaction and manifest establish that exact binding. Before a first
trading activation bootstrap additionally requires a nonzero live guardian, both exact coordinator pauser bindings,
unpaused RouterAdmin/HousePool entry, and an inactive LP settlement hold. Inspection-safe reruns after activation may
observe active containment but never unpause any component or clear/rewrite the historical risk-off cutoff.

Test-user funding is intentionally not idempotent: each ready-state rerun mints the configured amounts again. Remove
the test-user recipient/amount inputs after the intended funding run.

This is useful if the first bootstrap attempt completes only partially.

## Operational Notes

- Perps contracts are non-upgradeable. Synchronized async LP settlement therefore requires a coordinated replacement
  stack; an existing `HousePool` cannot replace its set-once vaults and an existing engine cannot replace its pool.
- This Terminal NAV V2 rollout is testnet-only and deliberately has no compatibility or migration path. Deploy a fresh
  complete stack and leave the old instance untouched; importing old positions, shares, pending requests, or claim
  escrow is out of scope.
- Never wire one replacement vault to an old pool or one old vault to a replacement pool. Deploy and verify the engine,
  terminal NAV book, clearinghouse, pool, both vaults, router/oracle, sidecars, coordinator, and lenses as a single
  versioned unit.
- `TerminalNavBookV2` has no owner repair or import function. Do not activate trading unless its Engine binding,
  price cap, size quantum, and empty initial state were verified by the deploy transaction.
- The bootstrap script only mints mock USDC. It does not fund users with ETH.
- Test users still need Arbitrum Sepolia ETH from a faucet to submit transactions.
- The deploy and bootstrap scripts currently assume the broadcaster owns the deployed contracts.
- The router admin is deployed internally by `OrderRouter`; bootstrap uses `router.admin()` to reach it.
- The deploy script installs `EmergencyPauseCoordinator` as the pauser on both RouterAdmin and HousePool. Do not set
  the guardian address directly as either pauser: doing so would reintroduce a partial-containment race.
- All ownership-bearing perps contracts use `Ownable2Step`: the current owner initiates a handoff and the pending
  owner must call `acceptOwnership()` before authority changes.

## Recommended Flow

1. Run the deploy script.
2. Record the deployed addresses.
3. Set bootstrap env vars, including the printed redemption-math sidecar and coordinator, a nonzero guardian, and both
   explicit senior limits.
4. Run the bootstrap script to propose the finite limits.
5. Wait for the 48-hour `HousePool` timelock.
6. Rerun the same bootstrap command to finalize, seed junior then senior, and activate trading.
7. Fund any test wallets with Arbitrum Sepolia ETH.
8. Start product integration testing against `PerpsPublicLens`, `MarginClearinghouse`, `OrderRouter`, and `HousePool`,
   and operator monitoring against `SettlementMonitorLens`.
9. Submit deposit and redemption requests on both vaults, advance to a matured epoch, follow the route reported by
   `SettlementMonitorLens`, and verify that funded claims can be pulled independently.
10. Dry-run all three guardian actions on the fresh testnet stack. Verify restriction masks/states, the emitted cutoff
    for risk-off actions, settlement rollback, and deliberately live closes/funded claims; clear invalidated opens,
    then have governance perform independent recovery of every active restriction.

## Emergency Containment Runbook

This section is the transaction-level deployment runbook. The complete action matrix, monitor trigger policy,
limitations, and off-chain guardian architecture are maintained in
[EMERGENCY_RESPONSE_GUIDE.md](EMERGENCY_RESPONSE_GUIDE.md). Operators must understand that the coordinator cannot
pause trader closes/reductions or already-funded claims and does not create a global protocol freeze.

1. Archive the monitor observation, RPC block/hash, external oracle evidence, and incident rationale. Compute stable
   `reasonHash` and `evidenceHash` values; zero is accepted when metadata is unavailable because containment must not
   be blocked by evidence collection.
2. Choose and simulate the minimum fixed action: `triggerEmergencyPause(reasonHash,evidenceHash)` for Router risk-off
   plus LP entry, `triggerLpEpochSettlementHold(reasonHash,evidenceHash)` for isolated epoch clearing, or
   `triggerFullContainment(reasonHash,evidenceHash)` for all restrictions atomically. The coordinator does not query
   the advisory Lens and no Lens condition trips it permissionlessly.
3. Confirm `EmergencyContainmentTriggered`, its action and previous/new masks, and every targeted state. When risk-off
   is included, confirm the inclusive cutoff; covered opens remain invalid forever, including after recovery.
4. Keep closes, liquidations, LP redemption requests, existing cancellation paths, recapitalization/reconciliation,
   and funded claims operating. Under settlement-only, new deposits and Senior reservations remain accepted but cannot
   activate; assets can accumulate under unchanged cancellation rules. Stop settlement broadcasts while held.
5. Have the protocol incident keeper call permissionless risk-off cleanup for invalidated opens. Cleanup requires no
   Pyth payload, refunds full remaining margin and bounty to the trader's internal settlement, and pays no caller, so
   the protocol pays gas.
6. After remediation and exact route simulation, governance—not the guardian—calls the relevant `unpause()` and/or
   `unpauseLpEpochSettlement()` functions. There is no expiry. Never attempt to reset the historical cutoff. Release
   restores eligibility but does not repair state or guarantee success. Rotate/disable an implicated guardian.

This runbook does not provide redemption-request-off or a global all-LP-request freeze, corrupted-queue quarantine,
an arbitrary restriction mask, emergency pricing, discretionary close-off, or off-chain automatic triggering.

Frontend and keeper integrations should read `TrancheVault.getRequestEpochWindow()` or the selected
`PerpsPublicLens.getTrancheQueues(bool)` response immediately before constructing timing-sensitive UI or preflight
state. `nextRequestCutoffTime` is the next future timestamp at which the advertised target changes; derive the active
final-five-minute state as `nextRequestEpoch > currentEpoch + 1`. Do not cache a permanently active state across the
round-hour boundary. Senior and Junior responses must match at the same block.

The included transaction, not its submission time, determines the request id. A transaction pending across the exact
cutoff intentionally rolls forward, so integrations must index the returned id or emitted request event rather than
predicting membership from wall-clock submission time. Keepers may use the five-minute interval for simulation and
alerting, but must treat the locked epoch totals as upper bounds because cancellations and all non-request protocol
state remain live. `SettlementMonitorLens` therefore reads an explicit observation target: once requests roll
forward, continue observing the locked `currentEpoch + 1` batch rather than blindly following the newly advertised
request target. This argument does not select what the Router settles; the Router still processes eligible FIFO
heads. Oracle payload selection and settlement eligibility continue to use the round-hour maturity boundary.

For a keeper broadcast, set `SETTLEMENT_MONITOR_LENS`, `PERPS_ORDER_ROUTER`, `OBSERVED_EPOCH`, and
`KEEPER_PRIVATE_KEY`. ABI-encode a Hermes payload as `bytes[]` and set `PYTH_UPDATE_DATA` only when the Lens reports
`AtomicOracleRefresh`, then run:

```bash
forge script script/LpEpochKeeper.s.sol \
  --tc LpEpochKeeper \
  --rpc-url "$ARB_SEPOLIA_RPC_URL" \
  --broadcast
```

The script verifies that the Lens is bound to the supplied Router, rejects an active settlement hold before decoding
the payload or quoting fees, refuses unknown or no-work routing, and selects the reported execution path. `CachedMark`
calls the bound `HousePool` directly without Pyth data or ETH.
`AtomicOracleRefresh` quotes the active `PletherOracle` and calls the Router with the exact Pyth fee. Poll the lighter
`SettlementMonitorLens.getSettlementStatus(observedEpoch)` view during normal operation. The composite
`getSettlementObservation(observedEpoch)` is an intentional checkpoint/alert read with a roughly 6 KB ABI return and
about 0.8–1.3 million gas of representative `eth_call` execution, so the recommended keeper sequence is:

1. Call `SettlementMonitorLens.getSettlementObservation(observedEpoch)` and record the first block-pinned post-cutoff
   observation for that epoch together with its RPC block number and block hash. Apply the operator's confirmation-depth
   policy before treating that checkpoint as final; re-read after any reorg. This does not select the Router's
   settlement epoch.
2. For `CachedMark`, simulate the exact direct
   `HousePool.settleLpEpoch(status.cachedMarkPrice,status.cachedMarkTime)` call with zero ETH. No Hermes payload is
   required. For `AtomicOracleRefresh`, fetch a Pyth/Hermes payload, quote its fee through the active `PletherOracle`,
   and simulate the exact `OrderRouter.settleLpEpoch(bytes[])` calldata and `msg.value`. If
   `status.clock.minimumAtomicPublishTime` is nonzero, the payload must be published at or after that boundary. Frozen
   stale-mark recovery reports zero and instead relies on the frozen PoolReconcile freshness policy.
3. Do not broadcast for `Unknown`, `NoMaturedWork`, or a nonzero `executionPathDependencyMask`.
4. Broadcast only if the exact selected transaction simulation succeeds, then confirm `LpEpochSettled` from the
   receipt. `--skip-simulation` is not an approved keeper procedure.

Use `getSettlementStatus(observedEpoch)` for operational blocker, warning, deposit-deferral, and execution-path
diagnostics. Its `executionPathDependencyMask` is the subset of read failures that prevents selecting cached-mark
versus atomic-oracle-refresh routing; the broader `dependencyFailureMask` can also include unknown optional
diagnostics. A readable active hold sets `lpEpochSettlementPaused`,
`OperationalBlocker.LpEpochSettlementPaused`, and `DepositDeferral.LpEpochSettlementPaused` without erasing the
post-recovery route; it is intentional complete state, not a critical fault. A failed hold read is an unknown Pool
dependency and makes the observation incomplete. The canonical matured-head getters are the route-selection evidence;
malformed auxiliary queue bookkeeping is surfaced as unknown health or a critical queue fault without fabricating a
different route.
`ActivationNotConfirmed` combines the projected `HousePool.canSettleDepositEntries()` common gate with canonical
redemption evidence. The Pool view projects post-reconcile state, including residual pending claimants, while the Lens
remains conservative when matured Senior funding can still change principal/HWM rounding before either tranche
activates, and when matured Junior funding can reduce capacity before Senior activation. HousePool rechecks the exact
live gates after redemption funding. Senior deposit deferrals describe pending activation and existing-reservation-limit conditions, not the
amount that a new request may reserve; read the vault admission view or `HousePool.getSeniorDepositCapacity()` for
new admission capacity. Use `getSettlementHealth()` for critical-fault and dependency-failure masks, and
`getPoolReconcileOracleStatus()` for a fail-soft view of feeds readable now. `observableConfigDigest()` and the
composite `observationDigest` are advisory comparison aids only. `completeObservationDigest` equals that observation
hash when `observationComplete` and is zero otherwise. Completeness requires every Oracle dependency read even on a
cached/no-work route, while Oracle policy validity is required only for atomic-refresh routing. The digest is still
unauthenticated and unenforced. The monitor
deliberately exposes no authoritative `canSettle` decision. A live transaction can still race cancellations, trading,
configuration, cash, or oracle state. The exact selected-transaction simulation is authoritative; a call with no
matured progress deliberately reverts, and every atomic-refresh backlog pass needs another validated Pyth update.
