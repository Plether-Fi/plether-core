# Zero-close execution operations

## Policy and deployment boundary

Ordinary and protection close attempts reserve an authenticated **zero** execution bounty. They never consume free settlement or position pledge for an execution reward. Opens/increases still pay their configured bounty. Protection creation still reserves the positive trigger reward, paid once on the original trigger. Liquidation rewards and trading charges are unchanged. Zero bounty does not waive carry, partial-close health, size, market-mode, oracle, configuration or execution bounds.

Deploy a coherent fresh stack. This is not an in-place storage-compatible upgrade: collectible-pledge storage and internal entrypoints were removed. Preserve old manifests, decoders and service for old deployments until their orders, protections and balances are drained. Never point old components at new reservation accounting. Existing receipt tuple fields and enum numbers remain decodable; new close receipts have zero source amounts, source epoch zero, disposition `None` and zero payee. Missing reservation records are invalid even when the expected amount is zero.

The core changes are paired with `plether-app` branch `codex/zero-close-bounties`. Its existing Haskell order keeper and independent protection worker remain the production services. The SDK CLI below is a one-shot diagnostic/operator tool, not another daemon.

## Keeper operation and funding

Fund operator wallets with native gas from a separately managed operating budget. No contract draws a close subsidy from LP assets, and no contract promises reimbursement. Closing remains permissionless when those wallets are empty; automatic service does not.

- Order keeper: configure a positive `KEEPER_MAX_TX_COST_WEI` in addition to its existing signing, deployment and execution settings.
- Protection worker: configure a positive `PROTECTION_WORKER_MAX_TX_COST_WEI` in addition to its existing settings.
- Both caps bound `transaction value + gas limit × maximum gas price` before signing. The default zero cap disables new spending. Caps are per transaction, not a daily budget or proof of sustainable funding. The normal wallet runway monitor and operational treasury controls remain necessary.
- Use separate funded primary and standby identities. Existing durable nonce/transaction journals are authoritative. After ambiguous submission, rebroadcast only recorded bytes; reconcile canonical inclusion and reorgs before creating a replacement attempt. Do not run two uncontrolled writers for one signer.
- Re-read the canonical Router head. Never filter a head by bounty or skip an unpaid close to reach a paid opening order. A stale indexer must catch up or alert, not invent queue progress.

A successful transaction alone is insufficient. Authenticate each lifecycle receipt, distinguish execution from terminal failure, and use batch terminal count, next ID and stop reason to decide what remains. A partial batch is partial progress. Never change its denominator to report complete success.

## Queue cleanup and protection retry

At strict `timestamp > executionDeadline`, call `expireOrder(id)` without oracle data. Equality is still live. Non-head expiry is allowed by the Router. Before historical oracle work, simulate the individual head with empty data: only a confirmed terminal result permits oracle-independent execution. Never extend that optimization across a live price-dependent successor. Submit cleanup separately when its progress must survive oracle preparation failure.

Matching failed protection attempts settle their old zero reservation and leave the protection latched. Retry creates a fresh order, deadline and active zero reservation. It neither reserves another execution reward nor pays the trigger reward again. The worker retries eligible expiry failures conservatively, considering pending account orders, queue size and oracle availability. Other failure reasons require review. It continues monitoring a triggered close until its actual linked order finalizes; a paid trigger is not completion.

When the keeper is unavailable, users can execute or expire existing IDs through the same public entrypoints. If another live head precedes their order, it must execute or become eligible for cleanup first. No user or operator can skip it. Repeated abandoned closes cost native transaction gas and consume bounded queue capacity; zero bounty is not an unlimited-load liveness guarantee.

## Same-account fallback

The app offers an explicit native-gas close path for the already-deployed permissionless SimpleAccount v0.8 profile. It verifies the owner, predicted factory address, EntryPoint, implementation slot and coherent deployment bindings. The owner wallet calls `SimpleAccount.execute(Router, 0, commitOrder(request))`; the Router still sees the original Trading Account. It does not submit the close as the owner EOA, switch accounts, approve USDC or deposit USDC.

Execution is a separate permissionless transaction. The owner wallet pays native gas and the exact oracle update fee. Historical six-feed data comes directly from public Hermes for the committed interval, independently of the protocol API, keeper, sponsor and bundler. Latest prices cannot substitute for unavailable historical data. Frozen/oracle-independent terminal paths use their existing contract rules. Expiry cleanup does not require Hermes.

The ticket exposes preceding-head processing explicitly and waits for authenticated terminal evidence. The protection panel offers owner-authorized cancellation while armed and permissionless retry/finalization after triggering. Cancellation leaves the position open. Retry only queues another attempt; it does not prove the position closed.

Limitations: the owner needs native gas and working chain RPC access; live execution also needs an admissible historical oracle payload. This implementation supports the pinned SimpleAccount profile and six-feed oracle, not arbitrary smart wallets or baskets. A new account cannot use this fallback before deployment. RPC/chain failures cannot be bypassed by client code. An unknown submission result must be reconciled by transaction hash/client intent before another order is authorized.

## Reference CLI

Build `packages/perps-aa-client` with `npm ci && npm run build`. Run `node scripts/close-operator.mjs --help` from that package. Supply `PERPS_RELEASE_MANIFEST` and `PERPS_RPC_URL`; the tool verifies chain, runtime hashes and Router bindings. `inspect` and `verify TX_HASH` are read-only. Other commands simulate by default using `EXECUTOR_ADDRESS`.

Commands: `execute ID PYTH_JSON`, `expire ID`, `riskoff ID`, `batch MAX_ID PYTH_JSON`, `trigger PROTECTION_ID PYTH_JSON`, `retry PROTECTION_ID`. JSON contains the exact `bytes[]` update payload. Batch native value must be explicitly provided in `ORACLE_VALUE_WEI`; single execution/trigger fees are quoted from the bound oracle. Sending requires both `--send` and `OPERATOR_PRIVATE_KEY`, with a sufficient `MAX_TX_COST_WEI`. The CLI does not retry automatically or log signer material/RPC URLs.

## Activation and outage drill

Before activating a fresh manifest, verify deployed runtime bindings, fund primary and standby wallets, set positive spending caps, and rehearse keeper/sponsor/API shutdown with the same-account fallback. Test a live FIFO predecessor, strict expiry, protection trigger without an executor, ambiguous nonce submission and a reorg. Keep old-stack service running independently.

Use measured transaction gas and oracle value for successes, failures, expiries and retries. For each workload, native cost is the sum of actual gas used × effective gas price plus unrecovered oracle value; maximum signed exposure uses the configured caps. Compare that cost against an explicitly allocated operating budget, not gross trader fees or LP principal. Measure normal, peak-close, high-fee, low-new-volume and repeated-invalid-close workloads. Set wallet alerts, standby response time and sustainable throughput from deployment-specific measurements. No funding threshold, latency guarantee or claim of economic sustainability is implied by passing local tests.

If funding dries up, alert, switch to a funded standby or replenish the operator wallet, and expose native fallback. Do not re-enable mandatory close bounties. If the chain or historical oracle is unavailable, wait for lawful recovery/expiry rather than weakening validation. After new orders exist, rollback requires a separately reviewed drain/migration; swapping components under live reservations is unsafe.
