# Perps Deployment

This document covers the current deployment flow for the perps stack in `packages/perps/src/`.

The current target network is Arbitrum Sepolia with:

- mock USDC as the settlement asset
- Pyth as the router oracle source
- a separate deploy phase and bootstrap phase

## Scripts

- Deploy script: `script/DeployPerpsArbitrumSepolia.s.sol`
- Bootstrap script: `script/BootstrapPerpsArbitrumSepolia.s.sol`
- Read-only verifier: `script/VerifyPerpsArbitrumSepolia.s.sol`
- Preflight and no-broadcast dry run: `scripts/prepare-perps-arbitrum-sepolia-release.sh`
- Environment template: `.env.arbitrum-sepolia-perps.example`
- Manifest template: `deployments/arbitrum-sepolia-perps.template.json`

The deploy script handles contract creation and one-time wiring.

The bootstrap script handles operator actions after deploy:

- verifying the shared emergency coordinator and configuring its guardian
- fail-closing on the constructor-initialized HousePool senior limits and Router opening/oracle parameters
- verifying the constructor-initialized Junior maintenance fee and treasury snapshot
- seeding the junior tranche and then the senior tranche
- minting mock USDC to test users
- activating trading

LP deposits and redemptions share the vaults' deterministic round-hour epoch clock and fixed 300-second request
cutoff. Before each cutoff they target the next epoch; during the final five minutes, beginning at exact cutoff
equality, they remain valid but target the following epoch. The numeric target does not change at the intervening
round-hour boundary. After bootstrap, any account may clear matured epochs through
the route reported by `SettlementMonitorLens.requiredExecutionPath`; no privileged keeper role is required. The
`CachedMark` route calls `HousePool` directly, while `AtomicOracleRefresh` calls `OrderRouter` with a valid
`PoolReconcile` Pyth basket. Outside oracle-frozen mode, live open-position settlement requires the atomic route and a
basket published at or after the round-hour boundary, not the request cutoff. Frozen mode also selects atomic refresh
when its cached mark is stale under the applicable frozen-mode limit. Each call examines at most 16 nonempty epochs in
each tranche phase. Each atomic-refresh pass must be repeated with a freshly validated update when older backlog
remains; cached-mark passes require no Pyth update. A no-progress or oracle-rejected call retains no Pyth, Engine,
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
9. `ArbitrumSepoliaReleaseHousePool`, a constructor-only `HousePool` wrapper built with the redemption-math sidecar
   and the exact `$40M/80%` release limits
10. `TrancheVault` senior
11. `TrancheVault` junior
12. `CfdEngineAccountLens`
13. `CfdEngineLens`
14. `ArbitrumSepoliaReleaseOracle`, a constructor-only `PletherOracle` wrapper with the `2,500`-bps multiplier
15. `CfdOrderPolicyEvaluator`
16. `OrderRouterV2ExecutionSidecar`
17. `OrderLifecycleBook`, separately deployed and immutable-bound to the predicted Router, Engine,
    MarginClearinghouse, and HousePool
18. `OrderRouterLiquidationBatchSidecar`, separately deployed with the same predicted Router address
19. `ArbitrumSepoliaReleaseRouter`, a constructor-only `OrderRouter` wrapper deployed immediately after those two
    Router-bound dependencies with the `$1,000` opening minimum. Its eighth and final base-constructor dependency is
    the predeployed lifecycle Book; its base constructor deploys the immutable RouterAdmin and stateful
    position-protection Book
20. `PositionProtectionBook`, deployed internally and immutably bound by the Router constructor
21. `PerpsPublicLens`
22. `SettlementMonitorLens` (the facade deploys its monitor-bound `SettlementMonitorLensSidecar` internally)
23. `EmergencyPauseCoordinator`

It then performs the required set-once wiring:

- `CfdEngine.setDependencies(...)`
- `CfdEngine.setTerminalNavBook(...)`
- `HousePool.setSeniorVault(...)`
- `HousePool.setJuniorVault(...)`
- `CfdEngine.setPool(...)`
- `CfdEngine.setOrderRouter(...)`
- `MarginClearinghouse.setEngine(...)`

Vault ordering is deliberate: construct Senior with `0/address(0)`, call `HousePool.setSeniorVault`, snapshot
`CfdEngine.protocolTreasury()`, construct Junior with `100` bps and that recipient, then call
`HousePool.setJuniorVault`. Both values and the empty fee-proposal state are verified immediately. This ordering lets
the Junior constructor enforce the existing forbidden-recipient rules against the already canonical Senior vault.

The lifecycle Book, stateless keeper sidecar, and Router form a strict three-`CREATE` deployment sequence. Let `n` be
the deployer's nonce immediately before deploying `OrderLifecycleBook`. Compute the expected Router address at nonce
`n + 2`; deploy the lifecycle Book at `n` with that Router plus the exact Engine, MarginClearinghouse, and HousePool;
deploy `OrderRouterLiquidationBatchSidecar` at `n + 1` with the same Router; then deploy `OrderRouter` at `n + 2` as
the deployer's next creation. No intervening nonce-consuming transaction or contract creation may break this order.
The Router receives the lifecycle Book as its eighth and final constructor dependency and rejects it unless code is
present and its immutable `ROUTER()`, `ENGINE()`, `CLEARINGHOUSE()`, and `HOUSE_POOL()` values exactly match the Router
being constructed and its supplied core dependencies. It separately rejects a keeper sidecar without code or whose
immutable `ROUTER()` is not `address(this)`. The deploy script also verifies the actual Router address equals the
prediction. If the deployer nonce changes during the sequence, discard both orphaned Router-bound dependencies,
recompute the prediction, and redeploy them; neither immutable binding can be repaired.

The three Arbitrum Sepolia wrappers modify constructor state only and add no post-deployment setter. The shared
HousePool, PletherOracle, and OrderRouter constructors and generic defaults remain unchanged. The release Router
constructor also rejects an oracle that does not already expose the exact `2,500`-bps adverse multiplier. After
construction, all configuration changes use the unchanged HousePool and RouterAdmin 48-hour governance paths.

The Router constructor creates only the stateful position-protection Book. That Book requires no separate deployment
transaction or mutable wiring. Discover it from `OrderRouter.positionProtectionBook()` and verify its immutable
`ROUTER()` and `ENGINE()` values against the new Router and Engine. Discover the separately deployed lifecycle Book
through `OrderRouter.lifecycleBook()` and the stateless keeper sidecar through
`OrderRouter.liquidationBatchSidecar()`. Require all three to contain code and be pairwise distinct. The keeper
sidecar's runtime carries the Router's mark-refresh, protection-trigger oracle and orchestration,
single-liquidation, risk-off-aware liquidation-batch, and atomic-refresh LP-epoch implementations to preserve EIP-170
and EIP-3860 headroom. Those selectors remain public only on the Router: direct and foreign-context
sidecar calls must revert. Under Router `delegatecall`, the Router remains `address(this)` and the direct-event address,
downstream contracts see it as caller, and the entrypoint's `msg.sender` is preserved. External-callee events remain at
the callee; the Book-trigger route carries the keeper/protection id in authenticated trailing data.

Important:

- `HousePool` remains inactive after deployment.
- `HousePoolRedemptionMathSidecar` is deployed before `HousePool`. It is stateless pure size-management code with no
  storage, setter, delegatecall, upgrade path, custody, or settlement authority. The deploy and bootstrap scripts
  require code and `implementationId() == keccak256("Plether.HousePoolRedemptionMathSidecar.v1")`; HousePool stores
  the validated address immutably. Record it as a first-class deployment artifact even though users never call it.
- This is a fresh V2 stack deployment. Deploy the evaluator and V2 execution sidecar before the Router-bound
  three-`CREATE` sequence, and pass their exact addresses together with the predeployed keeper sidecar and lifecycle
  Book to the eight-argument `OrderRouter` constructor. Do not mix any Router, Book, evaluator, sidecar, Engine,
  clearinghouse, or pool from another deployment generation. There is no V1-to-V2 order or lifecycle migration path.
- `OrderLifecycleBook` is independently predeployed and permanently binds the predicted Router, Engine,
  MarginClearinghouse, and HousePool. Deployment must check all four immutable bindings before accepting the Router,
  verify that `router.lifecycleBook()` returns the exact predeployed instance, and confirm
  `currentExecutionConfigHash()` is nonzero after core wiring. The Book is
  the authoritative source for permanent client-intent identity and terminal order outcomes; it has no independent
  owner, setter, or mutable wiring.
- `CfdOrderPolicyEvaluator` and `OrderRouterV2ExecutionSidecar` are separately deployed contracts whose exact
  addresses are pinned immutably in the Router. Deployment must verify code at both addresses and equality with the
  Router's `policyEvaluator()` and `executionSidecar()` getters. The execution sidecar is stateless and rejects direct
  stateful use; keepers call the Router. Record both addresses independently for bytecode verification. Bootstrap
  rediscovers both modules and the Book through the Router and repeats their code, self-binding, immutable-binding,
  and nonzero-config-hash checks; it takes no separate operator-supplied address for any of them.
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
  because it embeds the sidecar creation code. The pre-maintenance-fee V2 baseline had a 23,339-byte facade runtime,
  48,794-byte creation code, and 48,826-byte creation input including the 32-byte Router constructor argument, leaving
  326 bytes of EIP-3860 headroom. Its monitor sidecar was 19,114 bytes at runtime with 20,488-byte initcode. The
  maintenance-fee release is monitor schema/domain V3 because its observable configuration digest also commits to the
  active Junior fee rate and recipient. With optimizer 200, V3 measures 23,339 bytes of facade runtime, 49,010 bytes
  of facade creation input (142 bytes below EIP-3860), and 19,298 bytes of sidecar runtime. The combined V4 release
  also commits the Engine settlement buffer and measures 23,339 bytes of facade runtime, 49,057 bytes of facade
  creation input (95 bytes below EIP-3860), and 19,345 bytes of sidecar runtime. Keep the dedicated runtime and
  creation-input size regressions green and remeasure the exact release commit before deployment.
- `EmergencyPauseCoordinator` is deployed after the monitor and immutable-bound to the exact RouterAdmin and
  HousePool. The deploy transaction verifies its code, bindings, owner, disabled initial guardian, zero initial
  `riskOffOrderCutoff`, unpaused children, and inactive LP settlement hold, then installs it as both pausers. It has
  three fixed guardian actions—risk-off plus LP entry, LP-settlement-only, and full containment—but no unpause,
  arbitrary mask, pricing, configuration, fund-transfer, or arbitrary-call surface. Its later reason/evidence hashes
  remain advisory and are not derived or authenticated by the Lens.
- `OrderRouter.liquidationBatchSidecar()` returns the separately deployed stateless keeper module, not either Book.
  Deploy and bootstrap must require the sidecar, lifecycle Book, and position-protection Book
  addresses to contain code and be pairwise distinct. They must verify the sidecar's immutable `ROUTER()`, the
  lifecycle Book's full core bindings, and the protection Book's immutable `ROUTER()` and `ENGINE()` bindings. The
  sidecar rejects direct and foreign-context calls, reads the RouterAdmin's persistent risk-off cutoff through the
  Router-bound execution context, and works only through Router delegatecall. It is an EIP-170 size split with no
  mutable storage, setter, proxy, upgrade path, custody, or independent operational surface. Record the address for
  verification, but keepers must call the Router.
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
- Trading does not go live until the constructor-installed finite capacity and Router policy are verified, both seed
  positions exist within those limits, and `activateTrading()` is called.
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
- Deploy verification and the release-default regression fail closed unless Senior reports `0/address(0)` and Junior
  reports `maintenanceFeeAprBps() == 100` with the deployment-time `CfdEngine.protocolTreasury()` snapshot. Neither
  vault may have a pending fee proposal or pending fee shares before seeding. Bootstrap enforces the same snapshot and
  does not contain a fee-configuration transaction.
- `OrderRouter` is non-upgradeable and `CfdEngine.setOrderRouter(...)` is one-time. A release containing position
  protection therefore requires a fresh complete perps stack; do not point a new router at an existing engine or
  migrate live positions into the new release.
- The position-protection fields expand `OrderRouterAdmin.RouterConfig` from 15 to 17 fields. This changes the
  `proposeRouterConfig` selector from `0xf8eb837c` to `0xbe6e421a`, the Router's `applyRouterConfig` selector from
  `0xf2444582` to `0x5f3838b0`, and both configuration event topics. Although `pendingRouterConfig()` keeps its
  selector, its return tuple is longer, so an old decoder can silently misinterpret the final fields. Regenerate and
  version Router/Admin ABIs, retain the old event topics for historical deployments, and update every governance,
  indexer, keeper, and product consumer before proposing configuration on the new stack.
- Treat the Router, its two predeployed Router-bound dependencies, and its internally created protection Book as one
  bytecode release. The delegated sidecar logic reads integrations through Router external getters, does not read or
  write Router storage by layout, and changes Router-owned state only through authorized external self/item calls.
  Verify all components from the same source commit and test that direct and foreign-context helper calls fail.
  Neither lifecycle-Book nor keeper-sidecar creation code is embedded in Router initcode; position-protection Book
  creation code remains embedded because the Router constructor deploys it. Verify the creation inputs and EIP-170
  runtimes of the Router, both Books, the keeper sidecar, and the V2 execution sidecar with explicit safety margin.
- Position-protection creation is disabled on a fresh router. Ordinary trading can be bootstrapped independently while
  the trigger worker, indexer, and product integrations are verified. Do not enable the flag until the product has the
  Book ABI and attached-open/existing-position flows, the trigger worker is live, and every offchain oracle-policy
  reader uses `basketMaxConfidenceRatioBps()` rather than the retired `pythMaxConfidenceRatioBps()` getter.

## Oracle Configuration

The Arbitrum Sepolia deploy script uses upgraded Pyth at:

- `0x0B73614636C855Bf23F342F307FB981A3e47f42B`

Preflight fetches all six feeds through authenticated `https://pyth.dourolabs.app/hermes`, verifies the returned update
payload against this contract's `getUpdateFee(bytes[])`, and performs a no-broadcast deployment simulation.

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
| `vpiFactor` | `0.01e18` |
| `frozenCloseSpreadBps` | `50` |
| `maxSkewRatio` | `0.4e18` |
| `maintMarginBps` | `10` |
| `initMarginBps` | `20` |
| `fadMarginBps` | `300` |
| `baseCarryBps` | `500` |
| `minBountyUsdc` | `1e6` |
| `bountyBps` | `10` total liquidation-charge rate |
| `keeperShareBps` | `5_000` (50% of collected charge to keeper) |
| `protocolShareBps` | `0` (protocol liquidation fee disabled; remaining 50% goes to LPs) |
| `executionFeeBps` | `4` |
| `settlementBufferBps` | `25` (0.25% of maximum directional liability) |
| `positionSizeQuantum` | `1e20` raw units (100 synthetic tokens) |
| `fadRunwaySeconds` | `1 hours` |
| `basketMaxConfidenceRatioBps` | `10` |
| `adverseConfidenceMultiplierBps` | `2_500` (release-oracle constructor initialization) |
| `minOpenNotionalUsdc` | `1_000e6` (release-Router constructor initialization) |
| `maxPendingOrders` | `5` (unchanged) |
| `closeOrderExecutionBountyUsdc` | `200_000` (`0.20 USDC`) |
| `positionProtectionTriggerBountyUsdc` | `200_000` (`0.20 USDC`) |
| `positionProtectionCommitsEnabled` | `false` |
| `juniorMaintenanceFeeAprBps` | `100` nominal APR |
| `juniorMaintenanceFeeRecipient` | deployment-time `protocolTreasury()` snapshot |
| `maxSeniorExposureUsdc` | `40_000_000e6` (release-HousePool constructor initialization) |
| `maxSeniorShareBps` | `8_000` (release-HousePool constructor initialization) |
| Senior / Junior seed | `10_000_000e6` each |

`frozenCloseSpreadBps = 50` charges a fixed 0.50% spread on reduced notional for voluntary close/reduce execution only while `oracleFrozen`. Normal signed VPI and its lifetime rebate clamp remain active. For oracle-frozen voluntary closes, the spread replaces rather than compounds with the Pyth adverse-confidence adjustment; live/FAD-only closes and liquidations retain that adjustment. The spread belongs to LPs rather than protocol treasury and does not apply to liquidations. A terminal full close waives any uncollectible portion without creating a protocol liability or terminal deficit, while a partial close must settle this separate spread obligation in full. Price loss beyond the terminal collectible cap is a diagnostic write-off and does not block the partial close.

`frozenCloseSpreadBps` is part of `CfdEngineAdmin.EngineRiskConfig` and therefore uses the 48-hour propose/finalize timelock. Deployments and updates reject zero and values above `1_000` bps (10%). `keeperShareBps` and `protocolShareBps` use the same timelock; both may be zero, but their sum must not exceed `10_000`. Each configured allocation rounds down and LPs receive the exact liquidation-charge remainder.

The Junior maintenance fee is initialized in the Junior vault constructor at `100` bps with the Engine's current
protocol treasury. Senior is constructed with `0/address(0)` and registered first so the Junior constructor can reject
all canonical forbidden recipients. `MaintenanceFeeConfigInitialized` records the rate, recipient, and first hourly
checkpoint boundary. The recipient is a snapshot, not a dynamic pointer; an Engine treasury rotation must be paired
with a separately timelocked Junior recipient rotation.

After deployment, the current HousePool owner may propose a rate/recipient pair, wait 48 hours, verify the exact pending
values, and finalize it. Rates are
capped at `1,000 bps` nominal APR and a nonzero rate requires a valid nonzero recipient. Finalization crystallizes
elapsed completed-hour fees under the old pair before applying the new pair. The recipient receives ordinary Junior
shares, not USDC, and must use the normal asynchronous redemption lifecycle. There is no public fee checkpoint;
materialization occurs before an actual Junior supply mutation or during configuration finalization. Each checkpoint
charges at most 8,760 hours and explicitly forgives older elapsed hours. Accrual continues during settlement holds,
oracle freeze, and zero NAV.

Fee configuration is available only after HousePool has registered both tranche vaults and the caller is operating on
the registered Junior vault. This makes recipient validation against the Pool and both canonical vaults independent of
deployment ordering.

The first Junior seed receives no retroactive dilution: when raw supply is zero, the checkpoint boundary advances
without minting fee shares. Completed hours after supply exists accrue through the existing effective-supply and
checkpoint paths. Fee payment remains Junior-share dilution only, with no USDC transfer, principal mutation, or Senior
charge.

`PerpsViewTypes.TrancheView` now includes raw/effective supply and Junior fee fields before `sharePrice`. Its tuple ABI
is intentionally incompatible with older lens decoders under the fresh-deployment assumption. Regenerate frontend,
indexer, and integration bindings from this build and deploy the matching Public Lens with the new vault pair.

`settlementBufferBps` is also part of the complete `EngineRiskConfig`. It defaults to `25` bps and accepts the
inclusive governance range `0..1,000` bps. With `P = HousePool.totalAssets()`, `C = totalTraderClaimBalance`,
`E = max(P-C, 0)`, `L = max(bullMaxProfit, bearMaxProfit)`, and
`B = ceil(L * settlementBufferBps / 10_000)`, open/increase admission requires `E >= L + B` and the LP base
withdrawal reserve is `C + L + B`. The buffer is not terminal NAV, yield, or a separately custodied balance. Closes
and liquidations may consume it; raw degraded mode remains `E < L` and may be cleared at `E >= L`. A proposal that
changes another Engine risk field must copy the intended active buffer value into the complete replacement config.
Off-chain governance tooling must accept the same `0..1,000` bps range. Because the Engine's Admin dependency is
one-time-bound, an already deployed stack with the old Admin ceiling cannot gain the wider range without redeployment.

Terminal NAV V2 changes position storage, clearinghouse bucket semantics, Engine and HousePool snapshot ABIs, and
share-pricing economics. Deploy the Engine, book, clearinghouse, pool, vaults, router, sidecars, oracle, and lenses from
the same build on a fresh testnet deployment. There is no backward-compatibility or in-place migration path, and no V2
contract may be wired to an older stack. This build also includes the dedicated VPI rebate sub-reserve and its planner,
sidecar, lens, and clearinghouse ABI fields, plus the settlement-buffer risk-config and snapshot fields. Mixing
contracts across either boundary can produce inconsistent admission or reserve decisions and must be rejected. The
`RiskParams` tuple remains a ten-field ABI.

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

`adverseConfidenceMultiplierBps = 2_500` applies `0.25x` of Pyth's confidence interval when shifting live/FAD
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

Before any broadcast, copy `.env.arbitrum-sepolia-perps.example` to an ignored local release env file, populate it,
and run:

```bash
PERPS_RELEASE_ENV_FILE=.env.arbitrum-sepolia-perps \
  scripts/prepare-perps-arbitrum-sepolia-release.sh
```

This requires a clean reviewed `origin/master`, pinned submodules, Forge `1.5.1-stable`, a funded deployer, chain id
`421614`, upgraded-Pyth bytecode, an authenticated six-feed Hermes payload, and payload/contract compatibility. Its
Forge simulation omits `--broadcast`.

Required:

```bash
TEST_PRIVATE_KEY=...
ARB_SEPOLIA_RPC_URL=...
```

Run:

```bash
source .env && forge script script/DeployPerpsArbitrumSepolia.s.sol:DeployPerpsArbitrumSepolia --rpc-url $ARB_SEPOLIA_RPC_URL --broadcast
```

The script prints the deployed addresses and position-protection defaults to the console. Save the complete output,
including at least:

- `MockUSDC`
- `MarginClearinghouse`
- `CfdEngine`
- `TerminalNavBookV2`
- `CfdEnginePlanner`, `CfdEngineSettlementSidecar`, `CfdEngineAdmin`, and the engine lenses
- `HousePool`
- `HousePoolRedemptionMathSidecar`
- both tranche vaults
- `PletherOracle`
- `CfdOrderPolicyEvaluator`
- `OrderRouterV2ExecutionSidecar`
- `OrderRouter`
- the separately deployed `OrderRouterLiquidationBatchSidecar` returned by
  `OrderRouter.liquidationBatchSidecar()`
- the separately deployed `OrderLifecycleBook` returned by `OrderRouter.lifecycleBook()`
- the internally deployed `PositionProtectionBook` returned by `OrderRouter.positionProtectionBook()`
- `OrderRouterAdmin`
- `PerpsPublicLens`
- `SettlementMonitorLens` and its internally deployed `SettlementMonitorLensSidecar`
- `EmergencyPauseCoordinator`

Also record the active V3 execution-config hash, source commit, deployment block, transaction hashes, and
verified-bytecode status. `MockUSDC`,
`HousePool`, `HousePoolRedemptionMathSidecar`, `OrderRouter`, and `EmergencyPauseCoordinator` are consumed directly by
the bootstrap script. Bootstrap derives the RouterAdmin, policy evaluator, V2 execution sidecar, lifecycle Book,
stateful protection Book, and stateless keeper sidecar from the Router; it verifies the supplied redemption-math
sidecar's identity for rerun inspection and verifies that both Books and the keeper sidecar are distinct code-bearing
contracts with exact immutable bindings. The deploy transaction is
the evidence for HousePool's immutable redemption-math-sidecar constructor binding because the Pool deliberately has
no runtime getter for it. The remaining addresses are needed by product, indexer, keeper, monitoring, audit, and
independent deployment-verification tooling.

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

SENIOR_SEED_USDC=10000000000000
JUNIOR_SEED_USDC=10000000000000

SENIOR_SEED_RECEIVER=0x...
JUNIOR_SEED_RECEIVER=0x...

# Keep false until the seeded verifier passes; set true only for the activation rerun.
ACTIVATE_TRADING=false

TEST_USER_RECIPIENTS=0xabc...,0xdef...
TEST_USER_AMOUNTS=1000000000000,500000000000
```

Notes:

- USDC amounts are raw 6-decimal values.
- `10000000000000` means `10_000_000e6`, or 10,000,000 mock USDC.
- Seed amounts, seed receivers, guardian, and activation intent are explicit mandatory inputs. Bootstrap accepts only
  the approved `$10M/$10M` seed values and independently reads and verifies the constructor-installed `$40M/80%`
  HousePool and `$1,000/2,500` Router values.
- `PERPS_HOUSE_POOL_REDEMPTION_MATH_SIDECAR`, `PERPS_EMERGENCY_COORDINATOR`, and `PERPS_GUARDIAN` are mandatory, and
  the guardian must be nonzero. Bootstrap verifies the supplied released sidecar's code and implementation id for
  rerun inspection; HousePool's internal immutable binding was fixed by its constructor and the deploy script and has
  no runtime getter by design. Bootstrap then verifies that the coordinator has code, is bound to this exact
  RouterAdmin and HousePool, and is already installed as both pausers. It fails closed rather than repairing partial
  or cross-deployment coordinator wiring.
- `TEST_USER_RECIPIENTS` and `TEST_USER_AMOUNTS` must have the same length.

Run:

```bash
source .env && forge script script/BootstrapPerpsArbitrumSepolia.s.sol:BootstrapPerpsArbitrumSepolia --rpc-url $ARB_SEPOLIA_RPC_URL --broadcast
```

Run the standalone verifier without `--broadcast` after every phase and record each successful result in the manifest:

```bash
VERIFY_PHASE=deployed forge script script/VerifyPerpsArbitrumSepolia.s.sol:VerifyPerpsArbitrumSepolia --rpc-url "$ARB_SEPOLIA_RPC_URL"
VERIFY_PHASE=seeded forge script script/VerifyPerpsArbitrumSepolia.s.sol:VerifyPerpsArbitrumSepolia --rpc-url "$ARB_SEPOLIA_RPC_URL"
VERIFY_PHASE=active forge script script/VerifyPerpsArbitrumSepolia.s.sol:VerifyPerpsArbitrumSepolia --rpc-url "$ARB_SEPOLIA_RPC_URL"
```

The deployment transaction installs exact HousePool `$40M/80%` limits and Router `$1,000/2,500` values. Run the
`deployed` verifier, then bootstrap with `ACTIVATE_TRADING=false`; bootstrap verifies the live values, requires no
outstanding HousePool or Router proposal, initializes Junior then Senior, and funds any configured test users. Run the
`seeded` verifier, change `ACTIVATE_TRADING=true`, rerun bootstrap once more, and run the `active` verifier. There is no
initial configuration proposal or 48-hour release wait.

## Bootstrap Behavior

The seed and activation phases of the bootstrap script are designed to be partial-rerun safe:

- it never proposes or finalizes initial HousePool or Router configuration
- it refuses to seed unless the exact constructor-installed HousePool and Router values are active and neither admin
  has an outstanding proposal
- it refuses to seed unless Junior already has the constructor-initialized `100`-bps fee, the deployment treasury
  snapshot, no outstanding fee proposal, and zero pending fee shares before its first supply
- it rotates the coordinator guardian only when the requested address differs; a matching rerun is a no-op
- it skips a seed if that side is already initialized
- it skips activation if trading is already active

Before seeding or activation, bootstrap derives the Engine from `HousePool.ENGINE()` and verifies
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

Bootstrap does not enable position protection or submit any Router proposal. It verifies the constructor-installed
minimum opening notional and adverse-confidence multiplier plus the unchanged `10`-bps basket confidence and
pending-order limit `5`. Final output reports the Book address, current feature flag, and trigger bounty so operators
can verify ordinary trading without exposing an unprepared conditional-order surface.

## Position Protection Activation

Position protection has a trigger/attempt/retry keeper model:

1. A permissionless trigger worker evaluates an armed TP/SL condition with a current Pyth update and, when a condition
   is met, irreversibly latches the trigger and appends the first full-position market-style close attempt to the
   ordinary global FIFO tail.
2. The ordinary order keeper executes the live attempt using its own post-commit historical Pyth rule.
3. A non-liquidation failure relatches the protection when the exact protected position remains, retains the one close
   bounty, and pays no cleanup keeper. A permissionless retry worker then submits
   `retryPositionProtectionClose(...)` without Pyth data; the fresh attempt receives a new id, commit clock, deadline,
   and live/FAD oracle window at the current FIFO tail. Retry requires that exact side/size and zero pending Router
   orders for the account. This loop continues until execution, liquidation, or terminal position mismatch.

The protocol-operated worker automatically retries only an `Expired` latest attempt. It must first prune an expired
sole FIFO head in a separate transaction, funded from the operator gas budget, then re-check the Book and receipt. It
queues a retry only when live Pyth data (or frozen-close execution) is available and projected head-arrival is no more
than `maxOrderAge - 15 seconds` (45 seconds with the default TTL). `PlannerRejected`, `ConstraintViolation`, and other
non-expiry terminal reasons remain latched and page operators with the reason and failure fingerprint; the official
worker does not hot-loop them before remediation. Permissionless third parties remain free to retry.

Trader calls that create, replace, or attach protection are nonpayable and validate against the engine's cached fresh
mark. They target the `PositionProtectionBook` discovered through `OrderRouter.positionProtectionBook()`, as does the
payable `triggerPositionProtection(...)` keeper call. The Router does not forward these public selectors. Only the
trigger call ingests payable Pyth update data. This keeps the trader flow compatible with zero-native-value sponsored
accounts while retaining an independently verified trigger observation. The nonpayable retry selector remains live
while new protection commits are paused or disabled and while the Engine is degraded or the oracle is frozen.

The protected parent open is a caller-authored bounded V2 request and must pin the active lifecycle-Book digest. Only
Router-authenticated triggered or retried close attempts set `expectedConfigHash == bytes32(0)`, which is an unpinned
internal marker rather than a public wildcard. Deploy, bootstrap, and integration tests must verify both sides of that
boundary: external zero-hash commits, including Book-forwarded parents, fail; valid bounded parents and authenticated
attempt creation succeed; and terminal receipts retain the expected and observed config hashes. The request ABI and
intent hash remain V2, but this release uses the V3 receipt and execution-config domains because registered protection
attempts may authenticate `RetainedForProtectionRetry` with a zero bounty recipient.

The bounded protected-open selector replaces the former scalar selector without a compatibility overload. Ship it
only as part of a fresh complete perps-stack deployment, regenerate consumer ABIs from the new
`IPositionProtectionActions` interface, and update integrations to the newly discovered Book address. Live-state
migration and mixed old/new Router-Book stacks are unsupported.

Before enabling the feature, verify the existing-position post-reservation gate against boundary tests. The Book locks
both bounties first, then calls the Engine-configured planner's canonical V2 exact-price predicate with exact entry cost
and price equity composed only of PnL pledge plus the same-account trader claim plus exact capped unrealized PnL. Free
settlement and generic action/reservation buckets are excluded; uncovered carry and an underfunded negative-VPI reserve
fail closed; and equality at the stricter of initial or active normal/FAD margin is rejected. Attached opens lock
protection value before the ordinary open planner evaluates the parent. Reusing the configured planner is both the
single source of risk semantics and an initcode constraint: do not re-embed a local copy of the exact-price kernel in
the internally deployed position-protection Book.

Protection lifecycle events originate from the Book. Indexers and trigger/retry workers must subscribe at the Book
address, including `PositionProtectionCloseAttemptQueued` and `PositionProtectionCloseAttemptFailed`; every generated
attempt's ordinary `OrderCommitted` and terminal-order events originate from the Router. `linkedOrderId` is only the
latest attempt, while each queued event names the previous attempt id (`0` initially), so durable integrations must
retain the one-to-many attempt history. They must also index the lifecycle Book's
`ProtectionAttemptRegistered` event because `isProtectionAttempt(orderId)` becomes false when finalization consumes the
pending marker.

Regenerate frontend, keeper, governance, and indexer bindings from this release. The ABI adds the permissionless retry
action, lifecycle-Book registration/view surface, and close-attempt events. `PositionProtectionStatus.Latched` and
`BountyDisposition.RetainedForProtectionRetry` are appended, preserving prior numeric ordinals, but old enum decoders
will not know the new values. The receipt and execution-config hash domains are V3 even though the request/intent ABI
remains V2; do not compare their hashes with an earlier stack.

The feature flag and trigger bounty are members of the 48-hour timelocked `OrderRouterAdmin.RouterConfig`. Enabling the
feature must use the normal proposal/finalization path:

1. Read every current router and oracle-policy field onchain.
2. Build a complete `RouterConfig` from those current values, changing only the intended protection fields.
3. Propose the configuration through `OrderRouterAdmin` and record the proposal transaction and activation timestamp.
4. Wait the full 48-hour delay.
5. Re-read the pending configuration, verify every field, and finalize it.
6. Confirm `positionProtectionCommitsEnabled() == true` and the expected snapshotted bounty values on the router.

Do not reconstruct unrelated fields from old release notes or hardcoded defaults: finalizing `RouterConfig` replaces the
complete router configuration. Disabling new protection commits follows the same timelocked path. Disabling or pausing
must not strand existing records: cancellation, valid triggering, linked FIFO execution, terminal cleanup, and
latched retry, and liquidation remain live.

## Operational Notes

- Perps contracts are non-upgradeable. Synchronized async LP settlement therefore requires a coordinated replacement
  stack; an existing `HousePool` cannot replace its set-once vaults and an existing engine cannot replace its pool.
- This Terminal NAV V2 rollout is testnet-only and deliberately has no compatibility or migration path. Deploy a fresh
  complete stack and leave the old instance untouched; importing old positions, shares, pending requests, or claim
  escrow is out of scope.
- The latched-retry protection lifecycle is also not an in-place Book update. Before cutover, stop new admission on the
  old stack and resolve or explicitly inventory every active old protection and pending order. Deploy the Router,
  lifecycle Book, constructor-created protection Book, and sidecars as one fresh compatible graph; then switch frontend,
  keeper, indexer, and monitoring manifests together. Old attempt history and bounty attribution are not imported.
- Never wire one replacement vault to an old pool or one old vault to a replacement pool. Deploy and verify the engine,
  terminal NAV book, clearinghouse, pool, both vaults, router/oracle, sidecars, coordinator, and lenses as a single
  versioned unit.
- Deploy Junior with the approved `100`-bps fee and the exact deployment-time protocol-treasury recipient. Do not add a
  bootstrap fee transaction. Any later rate or recipient change is a separate 48-hour governance operation.
- `TerminalNavBookV2` has no owner repair or import function. Do not activate trading unless its Engine binding,
  price cap, size quantum, and empty initial state were verified by the deploy transaction.
- The bootstrap script only mints mock USDC. It does not fund users with ETH.
- Test users still need Arbitrum Sepolia ETH from a faucet to submit transactions.
- The deploy and bootstrap scripts currently assume the broadcaster owns the deployed contracts.
- The router admin is deployed internally by `OrderRouter`; bootstrap uses `router.admin()` to reach it.
- The position-protection Book is deployed internally by `OrderRouter`; bootstrap logs
  `router.positionProtectionBook()` for discovery and consistency checks.
- The deploy script installs `EmergencyPauseCoordinator` as the pauser on both RouterAdmin and HousePool. Do not set
  the guardian address directly as either pauser: doing so would reintroduce a partial-containment race.
- All ownership-bearing perps contracts use `Ownable2Step`: the current owner initiates a handoff and the pending
  owner must call `acceptOwnership()` before authority changes.

## Recommended Flow

1. Run formatting, package tests, integration script tests, and `forge build --sizes`; do not deploy an oversized Router
   or helper module, and retain reviewed safety margin below the EIP-170 runtime and EIP-3860 initcode limits rather
   than accepting a byte-exact boundary. Keep the dedicated Router, predeployed lifecycle Book, stateful protection
   Book, stateless keeper sidecar, redemption-math sidecar, HousePool, and `SettlementMonitorLens` size regressions
   green.
2. Simulate and then run the deploy script for a fresh complete stack.
3. Record the exact commit, deployment block, transaction hashes, addresses, and verification status.
4. Verify every set-once and immutable binding, including `TerminalNavBookV2` and the redemption-math sidecar; record
   the lifecycle Book returned by `lifecycleBook()`, the protection Book returned by `positionProtectionBook()`, and
   the distinct stateless helper returned by `liquidationBatchSidecar()`. Confirm the redemption-math sidecar
   implementation id and HousePool constructor input, all four lifecycle-Book bindings, the keeper sidecar's
   `ROUTER()` binding, the protection Book's `ROUTER()` and `ENGINE()` bindings, and that protection creation
   is disabled with a `200_000` trigger bounty and `200_000` linked-close execution bounty. Exercise direct and
   foreign-context rejection for the sidecar-carried Router helpers, including the risk-off-aware batch entrypoint,
   plus the canonical Router success paths for mark refresh, protection-trigger oracle resolution, single liquidation,
   batch liquidation, and atomic-refresh LP-epoch settlement, and the direct-Pool cached settlement path. Verify the
   `SettlementMonitorLens` facade and its internal sidecar are bound to the same Router, Engine, pool, terminal book,
   clearinghouse, vaults, USDC, protocol lens, and planner version. Confirm Junior maintenance-fee rate, recipient,
   pending shares, and effective supply read back as `100`, the deployment-time protocol-treasury snapshot, `0`, and
   raw supply respectively. Also verify the constructor-installed HousePool `$40M/80%` and Router `$1,000/2,500`
   values with zero active configuration proposals. Verify the
   `EmergencyPauseCoordinator` is bound to the exact RouterAdmin and HousePool, installed as pauser on both, and starts
   with no active settlement hold.
5. Set bootstrap environment variables, including the printed redemption-math sidecar and coordinator, a nonzero
   guardian, both explicit seed receivers, and exact `$10M/$10M` seeds. Run bootstrap with `ACTIVATE_TRADING=false` to
   configure the guardian and seed Junior then Senior without an initial governance wait.
6. Run the seeded verifier, set `ACTIVATE_TRADING=true`, rerun bootstrap, and run the active verifier.
7. Fund test wallets with Arbitrum Sepolia ETH as needed.
8. Point the frontend, public lens consumers, indexer, ordinary order keeper, LP epoch keeper, trigger/retry workers, and
   monitoring at the new release. Configure the guardian monitor and protocol-funded incident keeper. Protection
   clients and event subscriptions use the Book; ordinary FIFO and LP epoch services use their canonical endpoints,
   with the LP keeper following the Lens-selected direct-Pool or Router route; operator and security monitoring use the
   canonical `SettlementMonitorLens` facade, never its sidecar. Start all offchain services from the deployment block.
9. Submit deposit and redemption requests on both vaults, advance to a matured epoch, and follow the route reported by
   `SettlementMonitorLens`. When it selects `AtomicOracleRefresh`, fetch a Hermes update that satisfies the reported
   `minimumAtomicPublishTime` and frozen/live oracle policy. Verify that funded claims can be pulled independently.
10. Dry-run all three fixed guardian actions on the fresh testnet stack. Verify restriction masks/states, the emitted
    cutoff for risk-off actions, settlement rollback, and deliberately live closes, protection lifecycle paths, and
    funded claims; clear invalidated opens with the protocol incident keeper, then have governance perform independent
    recovery of every active restriction.
11. Exercise trigger- and retry-worker discovery and dry-run/simulation paths while protection creation remains disabled.
12. Propose, wait 48 hours, verify, and finalize the complete router configuration that enables protection commits.
13. Test attached-open activation, existing-position protection, both trigger directions, cancellation/replacement,
    first-attempt execution, failure-to-latch, repeated retry with fresh oracle windows, frozen-oracle retry/execution,
    emergency-pause cancellation/trigger/retry liveness, exact bounty recycling, and liquidation from both `Latched`
    and `Triggered` end to end.
14. Run a limited-TVL soak for at least seven days before broader use. Monitor armed, latched, and triggered counts;
    time latched without a live attempt; retry count; trigger-to-first-attempt and per-attempt FIFO-to-terminal latency;
    unpaid failed-attempt cleanup; keeper profitability; liquidation before fill; exact Book-versus-Router reservation
    reconciliation; LP queue backlog; epoch-settlement progress; monitor dependency/critical masks; observation
    completeness; cached-mark versus atomic-refresh routing; LP settlement-hold state; guardian availability; and
    risk-off cleanup backlog.

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
4. Keep closes, liquidations, protection cancellation and valid trigger/retry/linked-attempt processing, LP redemption
   requests, existing cancellation paths, recapitalization/reconciliation, and funded claims operating. Risk-off's
   HousePool pause blocks new deposit requests and activation. Under settlement-only, new deposits and Senior
   reservations remain accepted but cannot activate; assets can accumulate under unchanged cancellation rules. A
   matured pending deposit is not automatically cancellable merely because either restriction is active; use only its
   existing escape conditions or wait for recovery. Stop settlement broadcasts while held.
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
unauthenticated and unenforced. V3 added the active Junior maintenance-fee APR and recipient; V4 also includes the
Engine settlement-buffer policy. Inability to read any required field makes that digest unavailable. The monitor
deliberately exposes no authoritative `canSettle` decision. A live transaction can still race cancellations, trading,
configuration, cash, or oracle state. The exact selected-transaction simulation is authoritative; a call with no
matured progress deliberately reverts, and every atomic-refresh backlog pass needs another validated Pyth update.

Cross-check `PerpsPublicLens` queue state immediately before broadcasting, but use the monitor's canonical matured-head
evidence and selected execution route for keeper preflight. Each bounded `AtomicOracleRefresh` backlog pass requires a
new validated Pyth update; a `CachedMark` pass requires neither a Hermes payload nor ETH.

Create a new dated release note after deployment. Do not edit historical release notes. The new note must identify the
old stack as lacking position protection and state clearly that a trigger queues a close; it does not guarantee
execution time, execution price, or execution before liquidation.
