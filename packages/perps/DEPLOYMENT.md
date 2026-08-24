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

- setting pausers
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
8. `HousePool`
9. `TrancheVault` senior
10. `TrancheVault` junior
11. `CfdEngineAccountLens`
12. `CfdEngineLens`
13. `OrderRouter`
14. `PositionProtectionBook`, deployed internally and immutably bound by the Router constructor
15. `PerpsPublicLens`

It then performs the required set-once wiring:

- `CfdEngine.setDependencies(...)`
- `CfdEngine.setTerminalNavBook(...)`
- `HousePool.setSeniorVault(...)`
- `HousePool.setJuniorVault(...)`
- `CfdEngine.setPool(...)`
- `CfdEngine.setOrderRouter(...)`
- `MarginClearinghouse.setEngine(...)`

The position-protection Book requires no separate deployment transaction or mutable wiring. Discover its address from
`OrderRouter.positionProtectionBook()` and verify that its immutable `ROUTER()` and `ENGINE()` values match the newly
deployed Router and engine. Besides retained protection state, its runtime carries stateless orchestration used by the
Router's mark-refresh/trigger-oracle, single-liquidation, liquidation-batch, and LP-epoch entrypoints to preserve
EIP-170 headroom. Those selectors remain public only on the Router: direct calls to their matching Book selectors must
revert. Under Router `delegatecall`, the Router remains `address(this)` and the direct-event address, downstream
contracts see it as caller, and the entrypoint's `msg.sender` is preserved. External-callee events remain at the callee;
the Book-trigger route carries the keeper/protection id in authenticated trailing data.

Important:

- `HousePool` remains inactive after deployment.
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
- `OrderRouter` is non-upgradeable and `CfdEngine.setOrderRouter(...)` is one-time. A release containing position
  protection therefore requires a fresh complete perps stack; do not point a new router at an existing engine or
  migrate live positions into the new release.
- The position-protection fields expand `OrderRouterAdmin.RouterConfig` from 15 to 17 fields. This changes the
  `proposeRouterConfig` selector from `0xf8eb837c` to `0xbe6e421a`, the Router's `applyRouterConfig` selector from
  `0xf2444582` to `0x5f3838b0`, and both configuration event topics. Although `pendingRouterConfig()` keeps its
  selector, its return tuple is longer, so an old decoder can silently misinterpret the final fields. Regenerate and
  version Router/Admin ABIs, retain the old event topics for historical deployments, and update every governance,
  indexer, keeper, and product consumer before proposing configuration on the new stack.
- Treat the Router and its immutable Book as one bytecode release. The Book-carried delegated logic reads integrations
  through Router external getters, does not read or write Router storage by layout, and changes Router-owned state only
  through authorized external self/item calls. Verify both runtimes from the same source commit and test that direct
  helper calls fail. Because the Router constructor deploys the Book, Book creation bytecode is also embedded in Router
  initcode: moving runtime logic out of the Router does not make the EIP-3860 initcode limit free. Verify Router initcode
  as well as both EIP-170 runtimes with explicit safety margin.
- Position-protection creation is disabled on a fresh router. Ordinary trading can be bootstrapped independently while
  the trigger worker, indexer, and product integrations are verified. Do not enable the flag until the product has the
  Book ABI and attached-open/existing-position flows, the trigger worker is live, and every offchain oracle-policy
  reader uses `basketMaxConfidenceRatioBps()` rather than the retired `pythMaxConfidenceRatioBps()` getter.

## Oracle Configuration

The Arbitrum Sepolia deploy script uses Pyth at:

- `0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF`

Pre-broadcast blocker: the current `plether-app` Arbitrum Sepolia configuration instead names
`0x0B73614636C855Bf23F342F307FB981A3e47f42B`. Confirm the authoritative Pyth endpoint and align both repositories before
deploying; this guide intentionally does not choose between the conflicting addresses.

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
| `closeOrderExecutionBountyUsdc` | `200_000` (`0.20 USDC`) |
| `positionProtectionTriggerBountyUsdc` | `200_000` (`0.20 USDC`) |
| `positionProtectionCommitsEnabled` | `false` |
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

The script prints the deployed addresses and position-protection defaults to the console. Save the complete output,
including at least:

- `MockUSDC`
- `MarginClearinghouse`
- `CfdEngine`
- `TerminalNavBookV2`
- `CfdEnginePlanner`, `CfdEngineSettlementSidecar`, `CfdEngineAdmin`, and the engine lenses
- `HousePool`
- both tranche vaults
- `PletherOracle`
- `OrderRouter`
- `PositionProtectionBook` returned by `OrderRouter.positionProtectionBook()`
- `OrderRouterAdmin`
- `PerpsPublicLens`

Also record the source commit, deployment block, transaction hashes, and verified-bytecode status. `MockUSDC`,
`HousePool`, and `OrderRouter` are needed by the bootstrap script; the other addresses are required by product,
indexer, keeper, monitoring, and audit tooling.

### Bootstrap

Required:

```bash
TEST_PRIVATE_KEY=...
ARB_SEPOLIA_RPC_URL=...

PERPS_USDC=0x...
PERPS_HOUSE_POOL=0x...
PERPS_ORDER_ROUTER=0x...

MAX_SENIOR_EXPOSURE_USDC=...
MAX_SENIOR_SHARE_BPS=...
```

Optional:

```bash
PERPS_PAUSER=0x...

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
- it skips pauser updates if already set
- it skips a seed if that side is already initialized
- it skips activation if trading is already active

Before proposing limits, seeding, or activation, bootstrap derives the Engine from `HousePool.ENGINE()` and verifies
that a code-bearing `TerminalNavBookV2` is wired with matching Engine, cap, and 100-token quantum. A partial or
misbound V2 stack fails closed.

Test-user funding is intentionally not idempotent: each ready-state rerun mints the configured amounts again. Remove
the test-user recipient/amount inputs after the intended funding run.

This is useful if the first bootstrap attempt completes only partially.

Bootstrap does not enable position protection or propose router configuration. Its final output reports the discovered
Book address, current feature flag, and trigger bounty so operators can verify that ordinary trading was activated
without exposing an unprepared conditional-order surface.

## Position Protection Activation

Position protection has a two-stage keeper model:

1. A permissionless trigger worker evaluates an armed TP/SL condition with a current Pyth update and, when a condition
   is met, appends a full-position market-style close to the ordinary global FIFO tail.
2. The ordinary order keeper executes that linked close using the normal post-commit historical Pyth rule.

Trader calls that create, replace, or attach protection are nonpayable and validate against the engine's cached fresh
mark. They target the `PositionProtectionBook` discovered through `OrderRouter.positionProtectionBook()`, as does the
payable `triggerPositionProtection(...)` keeper call. The Router does not forward these public selectors. Only the
trigger call ingests payable Pyth update data. This keeps the trader flow compatible with zero-native-value sponsored
accounts while retaining an independently verified trigger observation.

Before enabling the feature, verify the existing-position post-reservation gate against boundary tests. The Book locks
both bounties first, then calls the Engine-configured planner's canonical V2 exact-price predicate with exact entry cost
and price equity composed only of PnL pledge plus the same-account trader claim plus exact capped unrealized PnL. Free
settlement and generic action/reservation buckets are excluded; uncovered carry and an underfunded negative-VPI reserve
fail closed; and equality at the stricter of initial or active normal/FAD margin is rejected. Attached opens lock
protection value before the ordinary open planner evaluates the parent. Reusing the configured planner is both the
single source of risk semantics and an initcode constraint: do not re-embed a local copy of the exact-price kernel in
the internally deployed Book.

Protection lifecycle events originate from the Book. Indexers and trigger workers must subscribe at the Book address;
the generated close's ordinary `OrderCommitted` and terminal-order events originate from the Router.

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
liquidation remain live.

## Operational Notes

- Perps contracts are non-upgradeable. Synchronized async LP settlement therefore requires a coordinated replacement
  stack; an existing `HousePool` cannot replace its set-once vaults and an existing engine cannot replace its pool.
- This Terminal NAV V2 rollout is testnet-only and deliberately has no compatibility or migration path. Deploy a fresh
  complete stack and leave the old instance untouched; importing old positions, shares, pending requests, or claim
  escrow is out of scope.
- Never wire one replacement vault to an old pool or one old vault to a replacement pool. Deploy and verify the engine,
  terminal NAV book, clearinghouse, pool, both vaults, router/oracle, sidecars, and lenses as a single versioned unit.
- `TerminalNavBookV2` has no owner repair or import function. Do not activate trading unless its Engine binding,
  price cap, size quantum, and empty initial state were verified by the deploy transaction.
- The bootstrap script only mints mock USDC. It does not fund users with ETH.
- Test users still need Arbitrum Sepolia ETH from a faucet to submit transactions.
- The deploy and bootstrap scripts currently assume the broadcaster owns the deployed contracts.
- The router admin is deployed internally by `OrderRouter`; bootstrap uses `router.admin()` to reach it.
- The position-protection Book is deployed internally by `OrderRouter`; bootstrap logs
  `router.positionProtectionBook()` for discovery and consistency checks.
- All ownership-bearing perps contracts use `Ownable2Step`: the current owner initiates a handoff and the pending
  owner must call `acceptOwnership()` before authority changes.

## Recommended Flow

1. Run formatting, package tests, integration script tests, and `forge build --sizes`; do not deploy an oversized Router
   or Book, and retain reviewed safety margin below the EIP-170 runtime and EIP-3860 initcode limits rather than
   accepting a byte-exact boundary.
2. Simulate and then run the deploy script for a fresh complete stack.
3. Record the exact commit, deployment block, transaction hashes, addresses, and verification status.
4. Verify every set-once and immutable binding, including `TerminalNavBookV2`; record the protection Book returned by
   `positionProtectionBook()` and confirm protection creation is disabled with a `200_000` trigger bounty and
   `200_000` linked-close execution bounty. Exercise direct-call rejection for the Book-carried Router helpers and the
   canonical Router success paths for mark refresh, protection-trigger oracle resolution, single liquidation, batch
   liquidation, and LP-epoch settlement.
5. Set bootstrap environment variables, including both explicit senior limits, and run bootstrap to propose them.
6. Wait for the 48-hour `HousePool` timelock, then rerun the same bootstrap command to finalize the limits, seed Junior
   then Senior, and activate trading.
7. Fund test wallets with Arbitrum Sepolia ETH as needed.
8. Point the frontend, public lens consumers, indexer, ordinary order keeper, LP epoch keeper, trigger worker, and
   monitoring at the new release. Protection clients and event subscriptions use the Book; ordinary FIFO and LP epoch
   services use the Router. Start all offchain services from the deployment block.
9. Submit deposit and redemption requests on both vaults, advance to a matured epoch, fetch a post-boundary Hermes
   update, call `OrderRouter.settleLpEpoch(bytes[])`, and verify that funded claims can be pulled independently.
10. Exercise trigger-worker discovery and dry-run/simulation paths while protection creation remains disabled.
11. Propose, wait 48 hours, verify, and finalize the complete router configuration that enables protection commits.
12. Test attached-open activation, existing-position protection, both trigger directions, cancellation/replacement,
    linked-order execution and expiry, frozen-oracle behavior, and liquidation end to end.
13. Run a limited-TVL soak for at least seven days before broader use. Monitor armed and triggered counts,
    trigger-to-FIFO and FIFO-to-terminal latency, linked-close failure/expiry, keeper profitability, liquidation before
    fill, exact reservation reconciliation, LP queue backlog, and epoch-settlement progress.

Frontend and keeper integrations should read `TrancheVault.getRequestEpochWindow()` or the selected
`PerpsPublicLens.getTrancheQueues(bool)` response immediately before constructing timing-sensitive UI or preflight
state. `nextRequestCutoffTime` is the next future timestamp at which the advertised target changes; derive the active
final-five-minute state as `nextRequestEpoch > currentEpoch + 1`. Do not cache a permanently active state across the
round-hour boundary. Senior and Junior responses must match at the same block.

The included transaction, not its submission time, determines the request id. A transaction pending across the exact
cutoff intentionally rolls forward, so integrations must index the returned id or emitted request event rather than
predicting membership from wall-clock submission time. Keepers may use the five-minute interval for simulation and
alerting, but must treat the locked epoch totals as upper bounds because cancellations and all non-request protocol
state remain live. Oracle payload selection and settlement eligibility continue to use the round-hour maturity
boundary.

For a keeper broadcast, ABI-encode the Hermes payload as `bytes[]`, set `PERPS_ORDER_ROUTER`, `KEEPER_PRIVATE_KEY`,
and `PYTH_UPDATE_DATA`, then run:

```bash
forge script script/LpEpochKeeper.s.sol \
  --tc LpEpochKeeper \
  --rpc-url "$ARB_SEPOLIA_RPC_URL" \
  --broadcast
```

The script quotes and sends the exact Pyth fee. Preflight `PerpsPublicLens` queue state before broadcasting: a call
with no matured progress deliberately reverts, and every bounded backlog pass needs another validated Pyth update.

Create a new dated release note after deployment. Do not edit historical release notes. The new note must identify the
old stack as lacking position protection and state clearly that a trigger queues a close; it does not guarantee execution
time, execution price, or execution before liquidation.
