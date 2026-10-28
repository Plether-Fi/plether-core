# Perps deployment and operation

The checked-in scripts deploy a fresh Arbitrum Sepolia stack with mock USDG, a six-feed Pyth basket, and separate
deployment, seeding, and activation phases. Paths to scripts, environment files, and release artifacts below are
relative to the repository root; run commands there.

The earlier oracle-synchronization candidate is recorded as deployed and inactive under
`deployments/releases/atomic-oracle-sync-candidate/`. The new
[v2.0.0 release](../../deployments/releases/2026-10-28-perps-arbitrum-sepolia-v2.0.0/README.md) is the first with
USDG as the settlement token and is deployed and seeded on Arbitrum Sepolia, with trading active.
Complete the qualification gates in
[Oracle synchronization](ORACLE_SYNCHRONIZATION.md) before considering a separate activation release. The bootstrap
instructions below describe the later supported phases; they are not part of candidate qualification.

Historical records under `deployments/releases/` describe their recorded deployments. They do not establish current
chain state or compatibility with this source revision. Never overwrite a historical manifest to describe a new stack.

## Release compatibility

Deploy the Engine, Clearinghouse, Router, Books, Oracle, Pool, vaults, and sidecars from one reviewed source revision.
Immutable and one-time bindings prevent a Router-only replacement or an in-place upgrade of a populated deployment.
There is no live-state migration tool. Cutover needs a separate plan for existing positions, queued orders,
protections, balances, claims, and LP obligations.

Generate consumer ABIs from the release build. Current requests and client-intent hashes use V3; receipts and execution
configuration hashes use V5. Pin the manifest and runtime hashes with those ABIs. Keep historical manifests, decoders,
and services available until their positions and pending work are resolved; do not redirect old requests or receipt
processing to a new stack. See [Reservation ledger](ACCOUNTING_SPEC.md#reservation-ownership-and-queues) for the current custody classifications.

## Settlement-token release metadata

New manifests use schema version `4`. The canonical contract entry is `contracts.settlementToken`, with artifact
`script/DeployPerpsArbitrumSepolia.s.sol:MockUSDG`, an address, and a runtime code hash. Top-level `settlementToken`
metadata records `name: "Mock USDG"`, `symbol: "USDG"`, `decimals: 6`, `isMock: true`,
`supportsReceiveWithAuthorization: false`, and `supportsBridgeFunding: false`. Applications should display
`USDG`, use the manifest address for balances and approvals, and gate funding routes by those capabilities.
Do not relabel an address from an older USDC deployment or route it through the new ABI. Historical
`contracts.mockUsdc` manifests and their ABI exports remain historical evidence. The current runtime uses a fresh
schema-4 prepared manifest with addresses unset and funding disabled until a reviewed deployment is supplied.
Export new artifacts into a fresh directory from the reviewed source revision.

Bootstrap and verification read `PERPS_SETTLEMENT_TOKEN`; seed inputs are `SENIOR_SEED_ASSETS` and
`JUNIOR_SEED_ASSETS`. Do not put the new token into `PERPS_USDC`: spot scripts may inherit that old setting.
The verifier checks code, six decimals, expected mock name/symbol, and matching asset bindings. Metadata checks
identify this test release and do not authenticate official USDG. Prepared manifests keep unknown addresses and
transaction evidence unset and must not be marked deployed or active.

## Scripts and artifacts

| Purpose | Repository-root path |
| --- | --- |
| Deploy and wire an inactive stack | `script/DeployPerpsArbitrumSepolia.s.sol` |
| Set guardian, seed, optionally activate and fund test users | `script/BootstrapPerpsArbitrumSepolia.s.sol` |
| Read-only deployed/seeded/active verification | `script/VerifyPerpsArbitrumSepolia.s.sol` |
| Preflight and deployment simulation without broadcast | `scripts/prepare-perps-arbitrum-sepolia-release.sh` |
| Environment template | `.env.arbitrum-sepolia-perps.example` |
| Full-stack manifest template | `deployments/arbitrum-sepolia-perps.template.json` |
| Consumer ABI and build-evidence export | `scripts/export-perps-release.py` |
| One bounded LP settlement pass | `script/LpEpochKeeper.s.sol` |

The full-stack manifest includes 29 contracts, including constructor-created children. Save the exact source commit,
compiler settings, deployment block, transaction receipts, addresses, runtime hashes, creation inputs, and active
execution-config hash. The standalone verifier checks the deployment graph and release state; it does not replace
comparison of every deployed bytecode artifact with the release build.

## Deployment graph and ordering

The deploy script performs creation and one-time wiring in this order:

1. Deploy MockUSDG, MarginClearinghouse, CfdEngine, and the empty Engine-bound TerminalNavBookV2. Wire the Book before
   any exposure. Deploy and wire the Engine planner, settlement sidecar, and admin.
2. Deploy HousePoolRedemptionMathSidecar, then the release HousePool. The Pool constructor also creates
   CfdEngineProtocolLens. Deploy Senior with a zero maintenance fee and zero recipient, register it, snapshot
   `Engine.protocolTreasury()`, then deploy Junior with a zero fee and that recipient. Register Junior and wire the
   Engine to the Pool.
3. Deploy the account lens, Engine lens, release Oracle, policy evaluator, CfdClosePreview, and execution sidecar.
   CfdEngineLens internally creates CfdEngineOpenQuoter; the execution sidecar creates OrderRecoverySidecar.
4. Deploy the lifecycle Book, liquidation/keeper sidecar, and Router in the strict nonce sequence below. The Router
   constructor creates RouterAdmin and PositionProtectionBook. Complete Engine/Router/Clearinghouse wiring.
5. Deploy PerpsPublicLens and SettlementMonitorLens. The monitor creates its own monitor-only sidecar.
6. Deploy EmergencyPauseCoordinator bound to the exact RouterAdmin and HousePool and install it as pauser on both.
   It starts with its guardian disabled. Trading remains inactive and all three restrictions start released.

The lifecycle Book and keeper sidecar must know the Router address before it exists. If the deployer's nonce is `n`
before the lifecycle Book creation, predict the Router at `n + 2`, then create:

| Nonce | Contract | Required immutable binding |
| --- | --- | --- |
| `n` | OrderLifecycleBook | Predicted Router, Engine, Clearinghouse, HousePool |
| `n + 1` | OrderRouterLiquidationBatchSidecar | Predicted Router |
| `n + 2` | ArbitrumSepoliaReleaseRouter | Both dependencies above, plus the other six constructor dependencies |

Do not insert a nonce-consuming transaction into this sequence. The Router validates the dependencies and the script
checks the actual Router address against the prediction. If the sequence breaks, recompute the prediction and deploy
new dependencies; their immutable bindings cannot be repaired.

The release wrappers initialize HousePool's `$40M/80%` Senior limits, the Oracle's `2,500`-bps adverse multiplier,
and the Router's `$1,000` opening minimum. The deploy script checks the Oracle multiplier before creating the Router.
These wrappers add no post-deployment configuration surface. Later economic configuration changes use the applicable
72-hour governance paths.

Record and verify children as well as top-level deployments:

| Child or dependency | Discovery / verification |
| --- | --- |
| Engine protocol lens | `HousePool.ENGINE_PROTOCOL_LENS()`; verify Engine binding |
| Engine open quoter | Recover from the Engine-lens creation trace; its internal immutable has no public getter |
| Recovery sidecar | `OrderRouterExecutionSidecar.recoverySidecar()` |
| RouterAdmin | `OrderRouter.admin()` |
| Position-protection Book | `OrderRouter.positionProtectionBook()`; verify Router and Engine |
| Lifecycle Book | `OrderRouter.lifecycleBook()`; verify Router, Engine, Clearinghouse, and HousePool |
| Keeper sidecar | `OrderRouter.liquidationBatchSidecar()`; verify Router |
| Monitor sidecar | `SettlementMonitorLens.SIDECAR()`; verify `MONITOR()` and the shared core graph |

The lifecycle Book, protection Book, and keeper sidecar must be distinct code-bearing contracts. Keepers call Router
entrypoints; users never call the delegate sidecars directly. Monitoring clients call the monitor facade.
CfdClosePreview is a separate stateless contract, not the policy evaluator or a constructor-created child.

HousePool deliberately has no getter for its immutable redemption-math sidecar. Preserve its constructor input and
creation evidence. Bootstrap's supplied-sidecar check proves code and
`implementationId() == keccak256("Plether.HousePoolRedemptionMathSidecar.v1")`, not the Pool's hidden binding.

## Initial release parameters

These are the checked-in script and constructor defaults, not a claim about any live deployment. USDG values use
six decimals; basis points use `10,000 = 100%`.

| Parameter | Value |
| --- | --- |
| `CAP_PRICE` | `2e8` (2.00 in eight-decimal price units) |
| `vpiFactor` | `0.01e18` |
| `frozenCloseSpreadBps` | `50` |
| `maxSkewRatio` | `0.4e18` |
| `maintMarginBps` | `10` |
| `initMarginBps` | `20` |
| `fadMarginBps` | `300` |
| `baseCarryBps` | `500` |
| `minBountyAssets` | `1e6` |
| `bountyBps` | `10` total liquidation-charge rate |
| `keeperShareBps` | `5_000` (50% of collected charge to keeper) |
| `protocolShareBps` | `0` (protocol liquidation fee disabled; remaining 50% goes to LPs) |
| `executionFeeBps` | `4` |
| `settlementBufferBps` | `25` (0.25% of maximum directional liability) |
| `positionSizeQuantum` | `1e20` raw units (100 synthetic tokens) |
| `fadRunwaySeconds` | `1 hours` |
| `basketMaxConfidenceRatioBps` | `10` |
| `adverseConfidenceMultiplierBps` | `2_500` (release-oracle constructor initialization) |
| `minOpenNotionalAssets` | `1_000e6` (release-Router constructor initialization) |
| `maxPendingOrders` | `5` |
| Close execution bounty | Always zero; no configuration field or getter |
| `positionProtectionTriggerBountyAssets` | `200_000` (`0.20 USDG`) |
| `juniorMaintenanceFeeAprBps` | `0` nominal APR (disabled at deployment) |
| `juniorMaintenanceFeeRecipient` | deployment-time `protocolTreasury()` snapshot |
| `maxSeniorExposureAssets` | `40_000_000e6` (release-HousePool constructor initialization) |
| `maxSeniorShareBps` | `8_000` (release-HousePool constructor initialization) |
| Senior / Junior seed | `1e6` each |

Read [Accounting specification](ACCOUNTING_SPEC.md) for fee, reserve, margin, and tranche economics. In particular:

- The settlement buffer reserves additional withdrawal capacity and gates new risk. Raw degraded mode still uses
  `E < L`, with `E = max(Pool assets - trader claims, 0)` and `L` the larger directional liability.
- Junior maintenance fees mint Junior shares. The zero-rate treasury recipient is a deployment-time snapshot;
  changing the Engine treasury does not rotate it automatically.
- The frozen close spread applies to voluntary reductions during `oracleFrozen`. Pricing and live/frozen Pyth fee
  rules are defined in [Oracle synchronization](ORACLE_SYNCHRONIZATION.md).

The script pins Pyth to `0x0B73614636C855Bf23F342F307FB981A3e47f42B` and configures EUR/USD and GBP/USD directly,
plus inverted USD/JPY, USD/CAD, USD/SEK, and USD/CHF feeds. Feed IDs, quantities, and base prices are in the deploy
script. Calendar classification follows 17:00 New York FX close/open, including daylight saving; integrations must
use the same rule and the Engine's configured overrides.

## Preflight and deploy

Start from a reviewed release checkout. Run package tests, root script tests, formatting and package-boundary checks,
and the full deployment size regression. Runtime bytecode must fit EIP-170 and complete creation input, including
constructor arguments and embedded child creation code, must fit EIP-3860. Historical size measurements are not
release evidence. Use the [test map](test/perps/TEST_MAP.md) and the revision-bound exporter for exact build evidence.

Copy the environment template to an ignored local file and populate:

```bash
TEST_PRIVATE_KEY=...
ARB_SEPOLIA_RPC_URL=...
PYTH_API_KEY=...
RELEASE_COMMIT=...
```

Run the preparation script without broadcasting:

```bash
PERPS_RELEASE_ENV_FILE=.env.arbitrum-sepolia-perps \
  scripts/prepare-perps-arbitrum-sepolia-release.sh
```

It requires a clean checkout matching fetched `origin/master` and `RELEASE_COMMIT`, pinned submodules, Forge
`1.5.1-stable`, chain `421614`, a funded deployer, code at the pinned Pyth address, and an authenticated six-feed Hermes
response. It checks `getUpdateFee(bytes[])` and simulates deployment. This is not the signed-data fork qualification
required by the oracle-synchronization release.

After release qualification and deployment authorization, load the environment and run:

```bash
set -a
source "${PERPS_RELEASE_ENV_FILE:-.env.arbitrum-sepolia-perps}"
set +a
forge script script/DeployPerpsArbitrumSepolia.s.sol:DeployPerpsArbitrumSepolia \
  --rpc-url "$ARB_SEPOLIA_RPC_URL" --broadcast
```

Populate every deployment-address field in the environment template, including `PERPS_OWNER`,
`PERPS_CLOSE_PREVIEW`, and `PERPS_ORDER_RECOVERY_SIDECAR`. Set `PERPS_GUARDIAN` to the intended nonzero guardian even
for deployed-phase verification: the verifier requires this input before the on-chain guardian is configured.
Independently confirm the deploy script's disabled-guardian and unpaused initial state. Save the printed addresses and
discover the children listed above.

Run the deployed verifier without `--broadcast`:

```bash
VERIFY_PHASE=deployed forge script script/VerifyPerpsArbitrumSepolia.s.sol:VerifyPerpsArbitrumSepolia \
  --rpc-url "$ARB_SEPOLIA_RPC_URL"
```

For the current candidate, also set `ORACLE_SYNC_FIXTURE` and `PERPS_EXECUTION_CONFIG_HASH` and run the read-only
`verifyOracleSynchronization()` gate described in [Oracle synchronization](ORACLE_SYNCHRONIZATION.md). Keep this
candidate inactive and its manifest separate.

## Bootstrap after release approval

Bootstrap assumes the broadcaster owns the deployed contracts. It verifies exact release parameters and wiring;
it does not repair mismatched components or propose initial configuration. No initial 72-hour configuration wait is
required because the release constructors set those values.

The required bootstrap inputs, in addition to the private key and RPC, are:

```bash
PERPS_SETTLEMENT_TOKEN=0x...
PERPS_HOUSE_POOL=0x...
PERPS_HOUSE_POOL_REDEMPTION_MATH_SIDECAR=0x...
PERPS_ORDER_ROUTER=0x...
PERPS_EMERGENCY_COORDINATOR=0x...
PERPS_GUARDIAN=0x...
SENIOR_SEED_ASSETS=1000000
JUNIOR_SEED_ASSETS=1000000
SENIOR_SEED_RECEIVER=0x...
JUNIOR_SEED_RECEIVER=0x...
ACTIVATE_TRADING=false
```

Both seed amounts must be exactly 1 mock USDG (`1e6`). Both receivers and the guardian must be explicitly set and
nonzero. The deployment template contains the other addresses needed by the standalone verifier.

1. Reload the environment using `set -a`, `source`, and `set +a` after editing it.
2. Run bootstrap with activation disabled. It configures the guardian, seeds Junior first, then Senior:

   ```bash
   forge script script/BootstrapPerpsArbitrumSepolia.s.sol:BootstrapPerpsArbitrumSepolia \
     --rpc-url "$ARB_SEPOLIA_RPC_URL" --broadcast
   ```

3. Verify the seeded but inactive state:

   ```bash
   VERIFY_PHASE=seeded forge script script/VerifyPerpsArbitrumSepolia.s.sol:VerifyPerpsArbitrumSepolia \
     --rpc-url "$ARB_SEPOLIA_RPC_URL"
   ```

4. For the activation run, set `ACTIVATE_TRADING=true`. If the Engine mark is unset, also set `PYTH_UPDATE_DATA` to an
   ABI-encoded `bytes[]` containing a policy-valid signed basket. Bootstrap calls `OrderRouter.updateMarkPrice` and
   pays the Pyth fee before activation. A pre-existing mark skips this update, so independently check its policy and
   freshness before release. Reload the environment and rerun the same bootstrap command.
5. Verify active state:

   ```bash
   VERIFY_PHASE=active forge script script/VerifyPerpsArbitrumSepolia.s.sol:VerifyPerpsArbitrumSepolia \
     --rpc-url "$ARB_SEPOLIA_RPC_URL"
   ```

Bootstrap skips already-initialized seeds and an already-active trading flag, and changes the guardian only when it
differs. It never unpauses components or resets the risk-off cutoff. First activation requires a nonzero guardian,
correct coordinator pauser bindings, and all restrictions released.

Optional `TEST_USER_RECIPIENTS` and `TEST_USER_AMOUNTS` are comma-separated arrays of equal length. Every ready-state
rerun mints those mock-USDG amounts again, so remove them after the intended funding run. Bootstrap does not fund ETH;
test users and keepers need their own Arbitrum Sepolia gas funds.

## Verify integrations before broader use

- Preserve deploy, seeded, and active verifier evidence for their respective phases. Verify the empty initial
  Terminal NAV Book, all one-time/immutable bindings, both vaults' async interfaces and shared epoch clock, initial
  Junior fee state, coordinator authorities, and zero pending configuration proposals.
- Publish matching ABIs and manifests to frontend, indexer, ordinary-order keeper, protection trigger/retry workers,
  LP keeper, and monitoring. Index from the deployment block. Historical deployments retain their own consumers.
- Fund execution and cleanup, verify spending caps, and test the account owner's fallback path using the
  [keeper operations](#order-keeper-operations) and [activation/outage drill](#activation-and-outage-drill) below.
- Exercise LP requests, matured settlement, and separate claims for both tranches. Exercise protection trigger,
  execution, failure, retry, and liquidation paths. A trigger queues a close; it promises neither its execution price
  nor execution before liquidation.
- Rehearse all three guardian actions and separate governance releases. Verify the restrictions and persistent order
  cutoff, plus the intended liveness of closes, liquidations, refunds, and funded claims. Follow the
  [Emergency response guide](EMERGENCY_RESPONSE_GUIDE.md).

Ownership-bearing contracts use `Ownable2Step`: a proposed new owner must call `acceptOwnership()`. Record the final
owners and guardian in the release; do not confuse pending ownership with effective authority.

## Repeat testnet funding

After a separately authorized deployment, fund a tester directly without rerunning deployment, bootstrap, or
activation. Resolve and check the tester's canonical trading smart-account address for that release, then mint to
that address. An owner EOA and its trading account are different beneficiaries. For example, to mint 1,000 Mock USDG:

```bash
# Future operator command: submits a transaction and requires Arbitrum Sepolia ETH.
PERPS_TRADING_ACCOUNT=0x...
cast send "$PERPS_SETTLEMENT_TOKEN" 'mint(address,uint256)' "$PERPS_TRADING_ACCOUNT" 1000000000 \
  --rpc-url "$ARB_SEPOLIA_RPC_URL" --account testnet-funder
```

`testnet-funder` is a locally configured Foundry keystore account. Any gas-funded account may mint; no token-owner
role, faucet allowance, daily limit, or deployment rerun is required. Minting adds tokens only to the recipient's
wallet balance, not its clearinghouse margin balance. Use `buildSmartAccountBalanceDepositAction` with the
configured token passed through its `settlementToken` input to approve and call `depositMargin` from the trading
account. If tokens were minted to an owner EOA instead, transfer them to the canonical trading account first.
Do not mint or transfer directly to the clearinghouse to fund an account.

MockUSDG cannot execute the signed owner-wallet `receiveWithAuthorization` first-deposit route. Keep that route
disabled while allowing the ordinary account-balance deposit; gas sponsorship may cover that supported flow when
configured and simulated against this exact stack. Update sponsor token targets and code hashes with the new
release. External bridge funding remains disabled; an old USDC bridge manifest is not a MockUSDG route.

## Future rewards readiness

Top-level manifest `rewards` records `status: "not_applicable"`,
`holdingContracts: ["marginClearinghouse", "housePool"]`, `payoutAddress: null`, and `payoutController: null`.
The holding entries resolve through the same manifest's contract inventory; the manifest's chain id supplies the
network. MockUSDG has no reward entitlement or accrual, and leaving the destination unconfigured is intentional.

For a future production USDG deployment, onboarding is a separate operator task:

1. Confirm the supported network, token, eligible holding contracts/balances, registration requirements, and claim
   authority with the production Paxos configuration. Register the actual clearinghouse and HousePool addresses
   only after eligibility and control verification are established.
2. Choose a separate treasury or multisig payout address. Record its address and controlling party; verify that the
   controller can move received tokens. Reject a destination equal to the clearinghouse, Engine, HousePool, or either
   tranche vault, and check it against the complete deployment inventory before configuring production payouts.
3. Configure that destination with the reward provider, record registration status and verification evidence, and
   monitor receipts. Reconfirm the provider's current payout and claim process at activation.
4. Decide and implement any subsequent reward allocation separately. An external distributor can pay traders or LPs
   without adding a reward claim hook or settlement-token rescue authority to the clearinghouse.

Unsolicited transfers to the clearinghouse credit no account and cannot be rescued as settlement assets. HousePool
excess becomes accounted capital only through its explicit owner-controlled recognition path. Therefore rewards
should not be sent to collateral custody contracts. Unclaimed rewards never increase margin or LP NAV; receipts in
the separate treasury also have no accounting effect until deliberately allocated through supported protocol flows.
This readiness metadata introduces no reward contract, principal-withdrawal permission, APY promise, or change to
the tranche waterfall.

## Order keeper operations

Service the canonical Router head regardless of its reward. The queue is empty when `nextExecuteId == 0` or
`nextExecuteId == nextCommitId`: it starts at `1 == 1`, then uses head zero after draining. `globalTailOrderId` is zero
in both empty states. Never attempt to execute id zero; reconcile stale indexer state against the on-chain queue
before acting.

Ordinary and protection close attempts have no execution bounty. Their operators pay native gas and oracle fees from
a separate operating budget; the contracts neither draw a close subsidy from LP assets nor promise reimbursement.
Opening/increase bounties, the one-time protection trigger reward, and liquidation rewards have separate policies.
Zero close bounty does not remove carry, trading charges, partial-close health, size, mode, deadline, oracle, or
financial-limit checks. See [Canonical entrypoints](CANONICAL_ENTRYPOINTS.md) and
[Accounting specification](ACCOUNTING_SPEC.md).

Bound native exposure before signing:

```text
maximum transaction cost = transaction value + gas limit * maximum gas price
```

Use funded primary and standby identities, one controlled nonce writer per signer, and durable transaction/nonce
journals. Per-transaction caps do not replace wallet-runway alerts or a total operating budget. Reconcile uncertain
inclusion and reorgs before replacing an attempt. For external services that expose them, configure positive
`KEEPER_MAX_TX_COST_WEI` and `PROTECTION_WORKER_MAX_TX_COST_WEI`, and verify enforcement in the deployed service
revision. The [reference CLI](#operator-cli) independently uses `MAX_TX_COST_WEI`, with a zero default send cap.

Authenticate lifecycle receipts and distinguish execution from terminal failure. Current close receipts have zero
bounty amounts, disposition `None`, and a zero payee; an absent reservation is still invalid. For batches, inspect
terminal count, next order ID, and stop reason. A successful transaction or partially processed batch does not prove
all requested positions closed. This repository supplies an SDK and one-shot operator CLI; verify the external
application's keeper, protection workers, funding, and deployment status in their own release records.

### Queue cleanup

At strict `block.timestamp > executionDeadline`, anyone may call `OrderRouter.expireOrder(id)` without oracle data,
including for a non-head order. Equality is still live. `clearInvalidOrders(ids)` also removes eligible expired or
configuration-invalid entries; risk-off opens have the separate `clearRiskOffOrder(id)` path. See
[keeper entrypoints](CANONICAL_ENTRYPOINTS.md#keepers) for bounds and result handling.

Before preparing historical oracle data, simulate the individual head with empty data to determine whether an
oracle-independent terminal path applies. This says nothing about a live successor. Submit cleanup separately when
its progress must survive failure to prepare or validate a later order's oracle input.

Live/FAD execution needs the qualifying historical tick for the committed interval; arbitrary latest data cannot
replace it. Frozen replay and terminal cleanup follow their own rules in
[Oracle synchronization](ORACLE_SYNCHRONIZATION.md). Users can execute or expire existing IDs through the same public
entrypoints, but a preceding live FIFO head must execute or become eligible for cleanup before their order can
execute. Repeated abandoned closes still consume native gas and bounded account queue capacity.

### Position protection keepers

Trader create/replace/attach actions and permissionless triggers target the Router's `PositionProtectionBook`.
Only the payable trigger accepts Pyth data; retry is nonpayable. A valid trigger latches the protection and queues a
full-position close at the ordinary Router FIFO tail. The ordinary keeper then uses the attempt's execution window.

If a non-liquidation failure leaves the exact protected position intact, the protection returns to `Latched` and may
queue a new attempt through `retryPositionProtectionClose(...)`. Retry requires the same side/size and no pending
Router orders for the account. Each attempt has its own ID, commit time, deadline, and authenticated zero bounty
record. The trigger reward is paid once; it is not paid again on retry. A paid trigger is not a completed close.

Subscribe to Book lifecycle events and Router order events, and retain the full attempt history: `linkedOrderId`
identifies only the latest attempt. Index `OrderLifecycleBook.ProtectionAttemptRegistered`; its pending marker is
consumed at terminal settlement. A conservative worker retries expiry failures only after confirming the account has
no pending orders, queue capacity is available, and valid execution data is obtainable. Investigate planner,
constraint, or other persistent failures before retrying; do not continuously queue the same failing attempt.

## Same-account fallback

If a keeper, sponsor, or application API is unavailable, the owner of a supported, already-deployed SimpleAccount
v0.8 can submit a close through the original trading account:

```text
SimpleAccount.execute(Router, 0, abi.encodeCall(Router.commitOrder, request))
```

The Router sees the smart account as the trader. A direct `commitOrder` from its owner EOA would address a different
account. This path needs no USDG approval or deposit for a close bounty. The SDK's `buildOwnerAccountClose` encodes
the call, but the client must independently verify the owner, factory/predicted address, EntryPoint, implementation,
and release bindings before signing. The request still needs valid timing, financial bounds, execution modes, and
the current configuration hash.

Execution is a separate permissionless transaction. Pay native gas and quote the exact update value from the bound
Oracle. Live execution on the configured six-feed market requires admissible historical data for the committed
interval, obtained from an available Hermes service. Expiry needs no Hermes data. Expose preceding-head processing
and wait for authenticated outcomes rather than treating commitment or transaction inclusion as a completed close.

For an armed protection, use the owner-authorized protection cancellation/close action where appropriate. Cancellation
alone leaves the position open. After a triggered attempt fails and protection is latched, permissionless retry only
queues a new attempt. Do not submit an ordinary close through an active protection lock; use the
[protection-aware entrypoints](CANONICAL_ENTRYPOINTS.md#position-protection).

Fallback requires an existing supported account, native gas, a working chain RPC and, for live execution, admissible
historical data. It does not deploy a missing account or establish support for arbitrary smart wallets. Reconcile an
unknown submission by transaction and client-intent identity before authorizing another order.

## Operator CLI

The source-tree CLI is at `packages/perps-aa-client/scripts/close-operator.mjs`. Install and build the SDK, then inspect
the tool from the repository root:

```bash
npm --prefix packages/perps-aa-client ci
npm --prefix packages/perps-aa-client run build
node packages/perps-aa-client/scripts/close-operator.mjs --help
```

Set `PERPS_RELEASE_MANIFEST` to the reviewed manifest file and `PERPS_RPC_URL` to its chain RPC. The CLI requires
`orderInterfaceVersion: 3`, checks chain ID and runtime hashes for the Router, lifecycle Book, protection Book and
Oracle, and checks the Router's bindings to those three dependencies. It does not verify the complete graph; perform
the broader release verification separately.

Invoke each command as `node packages/perps-aa-client/scripts/close-operator.mjs COMMAND ...`:

| Command | Purpose |
| --- | --- |
| `inspect` | Read the canonical queue head, lifecycle status, and deadline. |
| `verify TX_HASH` | Authenticate terminal events in a canonical successful transaction. Zero events does not prove execution. |
| `execute ID PYTH_JSON` | Execute the canonical head. |
| `expire ID` | Remove a strictly expired pending order, including a non-head entry. |
| `riskoff ID` | Clean an eligible risk-off order. |
| `batch MAX_ID PYTH_JSON` | Process through an inclusive order-ID bound, not a count. |
| `trigger PROTECTION_ID PYTH_JSON` | Trigger eligible protection. |
| `retry PROTECTION_ID` | Queue a new attempt for latched protection. |

`PYTH_JSON` is a **file path** whose contents are a JSON array of hex-encoded Pyth update bytes. An omitted file defaults
to `[]`. Single `execute` and `trigger` commands quote native value from the bound Oracle; `batch` requires explicit
`ORACLE_VALUE_WEI`. The `execute` command quotes before simulation, so an empty live payload can fail at fee quoting
even when a direct Router call could take a cleanup path. Use `expire` or `riskoff` for those oracle-free operations;
selected invalid-order cleanup remains available directly on the Router.

Mutating commands simulate by default with `EXECUTOR_ADDRESS` or the configured signer. Sending also requires
`--send`, `OPERATOR_PRIVATE_KEY`, and sufficient `MAX_TX_COST_WEI`. The CLI adds 25% to estimated gas and caps value
plus maximum gas exposure before signing. It waits for inclusion and authenticates terminal receipt events. It has
no automatic retry, durable nonce journal, or finality/reorg monitor; it is a one-shot operator tool, not a production
keeper service.

## Activation and outage drill

Before activation, verify the complete deployed graph and matching schemas, fund primary/standby wallets, enforce
spending caps, and rehearse keeper/sponsor/API outages with [same-account fallback](#same-account-fallback). Cover a
live FIFO predecessor, the strict expiry boundary, triggered protection awaiting execution, ambiguous submission,
a reorg, and a historical-oracle outage. Keep historical-stack service independent.

Measure execution, failure, expiry and retry costs under normal, peak-close, high-fee, and repeated-invalid-close
workloads. Actual native cost is gas used times effective gas price plus unrecovered oracle value; maximum signed
exposure is a separate limit. Set wallet alerts, standby response time, and sustainable throughput against the
operating budget. Local tests do not establish these deployment-specific limits.

If funding runs out, alert, replenish or switch to a funded standby, and expose the native fallback. Permissionless
close actions remain available, but automatic service depends on funded operators. If chain or historical-oracle
access fails, restore access or wait for valid expiry; do not bypass validation. Component changes after orders exist
require the reviewed drain/migration plan described above.

## LP epoch keeper

LP requests use a shared round-hour clock and a 300-second cutoff. Before cutoff, requests target the next epoch;
at cutoff equality and during the final five minutes, they target the following epoch. At the hour boundary the
numeric request target stays the same. Read `getRequestEpochWindow()` and index the emitted request ID, because
inclusion time determines membership.

Poll `SettlementMonitorLens.getSettlementStatus(observedEpoch)`. The observed epoch selects diagnostics, not the
FIFO heads the Pool settles. After cutoff, keep observing the locked batch even though new requests target a later
epoch. Record block/hash-pinned composite observations at checkpoints; the larger
`getSettlementObservation(observedEpoch)` is not intended for every polling tick.

| Required path | Transaction |
| --- | --- |
| `CachedMark` | `HousePool.settleLpEpoch(cachedMarkPrice,cachedMarkTime)` with zero ETH |
| `AtomicOracleRefresh` | `OrderRouter.settleLpEpoch(bytes[])` with a policy-valid basket and Oracle-quoted fee |
| `Unknown` / `NoMaturedWork` | Do not submit settlement |

An active settlement hold or nonzero `executionPathDependencyMask` also stops submission. A selected path is
advisory: simulate the exact transaction before broadcast. Live open-position settlement requires the atomic route
and every basket component to meet the current epoch boundary. Frozen replay uses the cached Engine mark and cannot
repair a mark older than the frozen freshness limit. See [Oracle synchronization](ORACLE_SYNCHRONIZATION.md).

For the keeper script, set `SETTLEMENT_MONITOR_LENS`, `PERPS_ORDER_ROUTER`, `OBSERVED_EPOCH`, and
`KEEPER_PRIVATE_KEY`. For the atomic route, also set `PYTH_UPDATE_DATA` as an ABI-encoded `bytes[]`; an empty array is
usable only when accepted-basket or frozen replay policy permits it. Then run:

```bash
forge script script/LpEpochKeeper.s.sol --tc LpEpochKeeper \
  --rpc-url "$ARB_SEPOLIA_RPC_URL" --broadcast
```

The script checks monitor/Router binding and the hold before decoding payloads or quoting fees. Do not use
`--skip-simulation`. Confirm `LpEpochSettled`, re-read remaining work, and repeat as needed. Each tranche phase is
bounded to 16 nonempty epochs per call; every atomic pass revalidates its oracle input. A no-progress or
oracle-rejected call rolls back the transaction's state changes.
