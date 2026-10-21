# Plether Perps

Plether Perps is a perpetuals protocol for leveraged exposure to the strength of the US dollar.
Traders post USDC margin, while liquidity providers supply the capital backing trades through senior and junior vaults.

The market uses a capped price range to bound potential trader payouts. Orders execute through a delayed queue,
and traders pay carry for the LP capital supporting their positions.

## How the market works

The instrument follows Plether's dollar index, derived from a basket of foreign-exchange prices supplied by Pyth.
The underlying basket mark moves inversely to dollar strength:

- **LONG** profits when the basket mark falls and the dollar strengthens.
- **SHORT** profits when the basket mark rises and the dollar weakens.

The mark is bounded between zero and `CAP_PRICE`. Before accepting new exposure, the protocol checks that pool
capital can cover the worst-case directional payout plus a settlement buffer.

Carry is based on the utilization of LP capital. It is paid by traders to the pool rather than exchanged between
long and short traders as funding.

## Trading

1. Deposit USDC into your margin account.
2. Submit an order with your execution limits and deadline.
3. A keeper executes the order through the queue using validated oracle data.
4. Close through the same order flow and withdraw available USDC.

Each account can hold one position at a time. Orders execute in first-in, first-out order, and committed orders
cannot be cancelled by the trader. Positions must be closed before switching sides.

Optional take-profit and stop-loss protection can submit a full-position close when triggered. Execution still
passes through the order queue, so a trigger does not guarantee an immediate close or a particular price.
Positions that no longer meet margin requirements can be liquidated.

If the pool cannot immediately pay realized profits, the unpaid amount becomes a trader claim that can be
settled as cash becomes available.

## Providing liquidity

LPs deposit USDC through one of two vaults that share a common pool:

- **Senior:** has priority in the capital waterfall and a configured coupon funded by Junior capital.
- **Junior:** absorbs losses first and receives the residual economics after Senior obligations.

Deposits and redemptions use an asynchronous request, settlement, and claim process. Redemptions depend on
available liquidity after trader claims and required reserves. Both tranches carry risk; Senior priority does
not guarantee principal or returns.

## Main contracts

| Component | Responsibility |
| --- | --- |
| `MarginClearinghouse` | Holds trader USDC and manages margin balances. |
| `OrderRouter` | Queues orders and coordinates oracle-backed execution and liquidations. |
| `PositionProtectionBook` | Tracks take-profit and stop-loss protection. |
| `CfdEngine` | Tracks positions, risk, carry, and settlement accounting. |
| `HousePool` | Holds LP capital and manages the senior/junior waterfall. |
| `TrancheVault` | Handles LP shares, deposit requests, and redemptions. |
| `PerpsPublicLens` | Provides product-facing views of accounts, queues, and protocol state. |

The contracts are non-upgradeable. Governance can adjust risk parameters through timelocks, and emergency
controls can restrict trading and LP activity. See the [security model](SECURITY.md) for trust assumptions.

## Development

This package uses Foundry and depends on the shared package and third-party libraries. From the repository root:

```bash
git submodule update --init --recursive
forge build --root packages/perps
forge test --root packages/perps
```

Production contracts live in [`src/`](src/), and package tests live in [`test/perps/`](test/perps/).
See the [repository setup guide](../../README.md#getting-started) for toolchain requirements and the
[test map](test/perps/TEST_MAP.md) for targeted suites and test profiles.

The frontend, backend, and keeper services live in the separate
[`plether-app`](https://github.com/Plether-Fi/plether-app) repository.

## Learn more

- [White paper](WHITEPAPER.md) — market design, economic rationale, and research.
- [Accounting specification](ACCOUNTING_SPEC.md) — margin, carry, solvency, claims, and LP accounting.
- [Integration guide](CANONICAL_ENTRYPOINTS.md) — supported trader, LP, keeper, and read interfaces.
- [Order timing](ORDER_V3_TIMING.md) — order commitments, deadlines, and execution rules.
- [Oracle synchronization](ORACLE_SYNCHRONIZATION.md) — signed basket updates, timing limits, and keeper integration.
- [Architecture map](INTERNAL_ARCHITECTURE_MAP.md) — component boundaries and custody flows.
- [Security model](SECURITY.md) — trust assumptions, invariants, and known limitations.
- [Pre-audit guide](PRE_AUDIT_GUIDE.md) — review scope, policy tables, and transaction walkthroughs.
- [Deployment guide](DEPLOYMENT.md) — deployment setup and operations.
- [Emergency response guide](EMERGENCY_RESPONSE_GUIDE.md) — pause controls and recovery procedures.
