# Plether Perps

Plether Perps is a perpetuals protocol for leveraged exposure to the strength of the US dollar.
Traders post USDG as margin, while liquidity providers supply the capital backing trades through senior
and junior vaults.

Testnet USDG can be minted whenever you need it.

The market uses a capped price range to bound potential trader payouts. Orders execute through a delayed queue,
and traders pay carry for the LP capital supporting their positions.

## How the market works

The instrument follows Plether's dollar index, derived from a basket of foreign-exchange prices supplied by Pyth.
The underlying basket mark moves inversely to dollar strength:

- **LONG** profits when the basket mark falls and the dollar strengthens.
- **SHORT** profits when the basket mark rises and the dollar weakens.

The mark is bounded between zero and `CAP_PRICE`. Before accepting new exposure, the protocol checks that pool
capital can cover the worst-case directional payout plus a settlement buffer.

Carry is based on the utilization of LP capital after deducting unpaid trader claims. It is paid by traders to the
pool rather than exchanged between long and short traders as funding. A separate skew charge or rebate, called
virtual price impact (VPI), prices the effect of a trade on directional imbalance.

## Trading

1. Deposit USDG into your margin account.
2. Submit an order with your execution limits and deadline.
3. A keeper executes the order through the queue using validated oracle data.
4. Close through the same order flow and withdraw available USDG.

Deposited cash and isolated position margin are different balances. An opening order allocates margin to a position;
`CfdEngine.addMargin` can allocate more without increasing its size. Funds reserved for orders or position obligations
are not freely withdrawable.

Each account can hold one position at a time. Orders execute in first-in, first-out order, and committed orders
cannot be cancelled by the trader. Positions must be closed before switching sides.

Optional take-profit and stop-loss protection can submit a full-position close when triggered. Execution still
passes through the order queue, so a trigger does not guarantee an immediate close or a particular price.

Ordinary and protection close attempts reserve no execution bounty. This lets traders submit a close without
funding a new keeper reward; it does not remove gas, oracle fees, carry, other action charges or admission checks.
See [Close settlement](ACCOUNTING_SPEC.md#close-settlement).

Positions that no longer meet margin requirements or have uncovered carry can be liquidated.

If the pool cannot immediately pay realized profits, the unpaid amount becomes a trader claim that can be
settled once pool cash covers all outstanding trader claims. A claim is an unpaid liability, not wallet cash.

## Providing liquidity

LPs deposit USDG through one of two vaults that share a common pool:

- **Senior:** has priority in the capital waterfall and a configured coupon funded by Junior capital.
- **Junior:** absorbs losses first and receives the residual economics after Senior obligations.

Deposits and redemptions use an asynchronous request, settlement, and claim process. Redemptions depend on
available liquidity after trader claims and required reserves. Both tranches carry risk; Senior priority does
not guarantee principal or returns.

Accepted Senior deposits are binding during normal operation and reserve backing that can limit Junior withdrawals.
Refunds remain available under the documented recovery conditions. See the
[LP integration guide](CANONICAL_ENTRYPOINTS.md#lps) and [LP risk model](SECURITY.md#housepool-and-lp-specific-risks)
for request, cancellation, claim and reserve rules.

## Main contracts

| Component | Responsibility |
| --- | --- |
| `MarginClearinghouse` | Holds traders’ USDG and manages margin balances. |
| `OrderRouter` | Queues orders and coordinates oracle-backed execution and liquidations. |
| `OrderLifecycleBook` | Retains order identity, timing, policy and authenticated outcomes. |
| `PletherOracle` | Validates signed basket data and applies live, historical and frozen price rules. |
| `PositionProtectionBook` | Tracks take-profit and stop-loss protection. |
| `CfdEngine` | Tracks positions, risk, carry, and settlement accounting. |
| `HousePool` | Holds LP capital and manages the senior/junior waterfall. |
| `TrancheVault` | Handles LP shares, deposit requests, and redemptions. |
| `PerpsPublicLens` | Provides product-facing views of accounts, queues, and protocol state. |

The contracts are non-upgradeable. Governance can adjust risk parameters through timelocks, and emergency
controls can restrict trading and LP activity. See the [security model](SECURITY.md) for trust assumptions.

## Development

For testnet funding, mint USDG to your trading account, then approve and deposit it. You’ll need testnet gas.
See [testnet funding](DEPLOYMENT.md#repeat-testnet-funding) for instructions and
[future rewards readiness](DEPLOYMENT.md#future-rewards-readiness) for GDN setup notes.

This package uses Foundry and depends on the shared package and third-party libraries. From the repository root:

```bash
git submodule update --init --recursive
forge build --root packages/perps
forge test --root packages/perps
```

Production contracts live in [`src/`](src/), and package tests live in [`test/perps/`](test/perps/).
See the [repository setup guide](../../README.md#getting-started) for toolchain requirements and the
[test map](test/perps/TEST_MAP.md) for targeted suites and test profiles.

Frontend, backend and trading-worker integration is maintained in the separate
[`plether-app`](https://github.com/Plether-Fi/plether-app) repository. Deployment and LP keeper scripts live in the repository's
[`script/`](../../script/) directory. Source documentation describes this checkout; verify release manifests
and matching ABIs before assuming a deployed address has the same behavior.

## Documentation guide

Start with the architecture map, then the accounting specification. Current behavior has one detailed home per topic:
order timing and actions in the integration guide, reservations and settlement in the accounting spec, keeper
operation in the deployment guide, and review methodology in the security guide. The white paper supplies economic
rationale and separates historical research from current contract behavior.

| Purpose | Documents |
| --- | --- |
| Understand contracts and custody | [Architecture map](INTERNAL_ARCHITECTURE_MAP.md) |
| Understand economics and accounting | [Accounting specification](ACCOUNTING_SPEC.md), [White paper](WHITEPAPER.md) |
| Integrate trading and liquidity | [Canonical entrypoints and order timing](CANONICAL_ENTRYPOINTS.md), [Close preview and frontend integration](CLOSE_PREVIEW.md) |
| Build automated trading clients | [Trading-agent integration](WORKING_WITH_AI_AGENTS.md) |
| Understand oracle pricing | [Oracle synchronization](ORACLE_SYNCHRONIZATION.md) |
| Integrate cross-chain funding | [Bridge funding](BRIDGE_FUNDING.md), [Across fixture provenance](test/fixtures/across-direct-funding/README.md) |
| Deploy, operate and respond to incidents | [Deployment and keeper operations](DEPLOYMENT.md), [Emergency response](EMERGENCY_RESPONSE_GUIDE.md) |
| Review safety and failure modes | [Security model and review guide](SECURITY.md) |
| Find and interpret tests | [Test map and integration checks](test/perps/TEST_MAP.md), [Invariant-test guide](test/perps/invariant/README.md) |
| Reproduce the paper's experiments | [Research reproduction guide](whitepaper/README.md) |
