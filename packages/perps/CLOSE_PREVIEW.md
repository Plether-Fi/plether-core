# Close preview and integration

`CfdClosePreview` reviews a prospective close by projecting commitment carry, then execution at a supplied price. It is read-only and has no constructor arguments. Use it before submitting a new close; use `CfdOrderPolicyEvaluator.assessCommittedOrder` for an existing pending order.

This page describes the current source: V3 requests/intents and V5 receipt/configuration domains. Current closes have zero execution bounty. See the [close settlement rules](ACCOUNTING_SPEC.md#close-settlement) for protocol economics and [keeper operations](DEPLOYMENT.md#order-keeper-operations) for execution, funding and fallback procedures. The integration checks below are requirements, not evidence that an external frontend is deployed or has passed acceptance.

## Deployment and bindings

Use the ABI and runtime hash from the exact deployed build. Verify the chain, code hashes and engine/Router/Book bindings. Keep distinct addresses for the close preview, execution policy evaluator, engine lens and public lens; a preview address equal to the execution evaluator is invalid. `CfdEngineLens.previewClose` has a different interface and is not a substitute for commitment-aware review.

## Calling the preview

The contract exposes two five-argument overloads:

```text
previewClose(engineAddress, account, request, executor, executionPrice)
previewClose(engineAddress, closeOrder, executor, executionPrice, bounds)
```

Prefer the first overload for ordinary user submission. It accepts the exact `OrderV3Types.OrderRequest` intended for `Router.commitOrder` and resolves permanent client identity before checking fresh admission:

- An unused client ID proceeds through request validation, queued-position side/size/dust checks, commitment carry, and execution assessment.
- An exact replay returns the existing `replayOrderId` with empty commitment and assessment fields. This also works after expiry, configuration changes or terminalization. It is an identity lookup, not a zero-cost execution quote.
- Reusing the client ID for different request contents reverts with `OrderLifecycleBook__ClientIdConflict`.

The second overload accepts a synthetic `CfdTypes.Order`. It checks side and partial-close dust against the **live** position and projects commitment/execution. It does not resolve client identity or validate request timing, configuration hash, protection lock or queued-position admission. Its `replayOrderId` is always zero.

Both overloads read canonical pool depth from the supplied engine's pool and share the commitment calculation used by the engine. Neither takes a bounty, pool-depth or `publishTime` argument. Neither verifies that the supplied execution price came from an admissible oracle payload, or applies the Router's target-price/slippage check. The actual execution path performs those checks.

```typescript
// closePreviewAbi must come from the build matching the selected deployment.
const preview = await publicClient.readContract({
  address: closePreviewAddress,
  abi: closePreviewAbi,
  functionName: 'previewClose',
  args: [engineAddress, tradingAccount, request, executorAddress, reviewedPrice],
  blockNumber,
})

if (preview.replayOrderId !== 0n) {
  // Load the existing order's lifecycle; do not display the empty assessment.
} else {
  const assessment = preview.assessment
  // Use the assessment as returned, including its commitment carry.
}
```

## Review and submit

1. Read the trading account, live position, pending orders, protection state, current configuration and block timestamp/number at one block. Build the bounded close request using the admission rules below. For a smart account, the position owner is that account, not its owner EOA.
2. Review the request at that block using the bounded five-argument overload. Sample the current price and adverse slippage limit, plus intermediate scenarios needed by the client. If `replayOrderId` is nonzero, resume the existing order instead of displaying the empty assessment.
3. Derive financial bounds from the fresh assessments and the user's tolerances, then repeat review with the final bounds. Check target-price/slippage separately. Keep opening-order preparation on its own route.
4. Simulate the actual `commitOrder(request)` from the trading account. This checks the complete submission path, including queue capacity. Earlier queued orders can change the eventual position; preview does not execute them hypothetically. Refresh context and review before submission if state has changed.
5. Persist the exact submitted request and client ID. After an ambiguous submission, reconcile its transaction and permanent client-intent record before creating another request. An exact retry returns the same ID; changing any request field, including bounds, under a committed ID conflicts.
6. Track the returned order through execution or terminal failure. Use `assessCommittedOrder(engine, orderId, executor, executionPrice)` for an authenticated pending-order assessment, and verified lifecycle receipts for history. Commitment, a paid protection trigger or a queued retry does not prove the position closed.

Use a fresh unused client ID for a new order and preserve the original request/ID for recovery. Final bounds can change during preparation before submission. Refresh on account, chain, size, target, configuration, position, queue or protection changes; an older asynchronous review must not overwrite a newer one or survive an aborted request. If review fails, report it as unavailable rather than silently using a stale assessment or the raw evaluator.

## Result and accounting

Generate types from [CfdClosePreview.sol](src/CfdClosePreview.sol) and [OrderV3Types.sol](src/OrderV3Types.sol), rather than copying an archived tuple.

| Field | Meaning |
| --- | --- |
| `replayOrderId` | Existing order ID for an exact request replay; zero for a new preview. Check this first. |
| `commitment` | Collected/outstanding carry and settlement before/after commitment. `bountyFromFreeAssets` is zero for a close. |
| `commitmentCarryAssets` | Alias of `commitment.carryCollectedAssets`, useful for explaining the commitment checkpoint. |
| `assessment` | Projected execution and post-state, with commitment carry already included in the aggregate charge and debit fields. |

There is no `executionBountyAssets` result. Close execution earns zero bounty; native gas and oracle update fees remain separate. Do not add a close-bounty deposit requirement to the review flow.

Commitment collects carry even though the close bounty is zero. The projected execution starts from the resulting account state. In particular:

- `assessment.preSettlementBalanceAssets` is custody **after** commitment carry. `commitment.settlementBeforeAssets` is the pre-commitment balance.
- `grossAccountDebitAssets`, `actionChargeAssessedAssets`, `actionChargeCollectedAssets`, and `carryAssets` already include collected commitment carry. Do not add `commitmentCarryAssets` again when displaying totals or deriving bounds.
- `carryAssets` is assessed carry, not necessarily the cash collected. A full close can leave uncollectible carry to the full-close settlement rules. Gross debit also includes trader-claim consumption, so it is not the same as a wallet payment or net cash loss.
- `postSettlementBalanceAssets` is total internal custody, including locked funds. `assessment.close.postFreeSettlementAssets` is projected free settlement. `assessment.postTraderClaimAssets` is a separate claim balance, not immediately spendable USDG.
- `safeMarginReleaseAssets` is the pledge that may be released while preserving residual health. `actionChargeFromReleasedMarginAssets` and `netReleasedMarginAssets` explain how much of that release pays charges and how much remains.

USDG amounts use 6 decimals, prices 8, and sizes 18. Valid sizes are multiples of `1e20` (100 tokens). PnL, VPI and post-position equity are signed; retain integer precision in clients.

## Admission and bound checks

A fresh public close needs a nonzero, unused client ID outside the protocol-reserved prefix; matching side; a valid size; zero `marginDelta`; a nonzero target price; the current nonzero configuration hash; a valid submission cutoff and execution window; and valid execution modes. Active protection and certain pending-order policies may block ordinary submission. The bounded-request preview uses the Router's admission checks for these rules.

`submitBy` must be at or after the reviewed timestamp. `executionWindowSeconds` must be positive and no greater than the Router's configured maximum. At execution, a LONG close accepts a price at or below its target; a SHORT close accepts a price at or above it. See [order timing](CANONICAL_ENTRYPOINTS.md#order-timing) for the delayed execution window.

Set `maxExecutionBountyAssets = 0` for the zero-bounty close and `minPostSettlementBalanceAssets = 0`: positive settlement floors are unsupported on closes. Bounds are inclusive; zero maximum bounds are real zero allowances. Full closes skip residual equity/leverage checks during assessment, but fresh public requests still require a nonzero `maxPostLeverageBps`. Execution modes are enum values `None=0, Live=1, Fad=2, Frozen=3`; allowed-mode bits are `Live=1, Fad=2, Frozen=4`.

Partial closes must fund outstanding carry at commitment and meet commitment health checks. Execution independently requires a healthy residual position and collectible partial-close charges. Full closes have no residual-position health requirement. Both still require valid mark/price inputs and the user's other bounds.

The stored commitment mark must be nonzero with a nonzero timestamp; commitment does not impose a mark-age freshness limit. This does not establish that an execution oracle update will be accepted. Preview models the current timestamp, so later carry, oracle/mode changes, pool state and configuration changes can alter execution.

## Failure semantics

| Error or result | Interpretation |
| --- | --- |
| `replayOrderId != 0` | Resume the existing order's lifecycle. No new assessment was produced. |
| `OrderLifecycleBook__ClientIdConflict` | The same account/client ID is bound to different request contents. |
| `OrderRouter__SettlementFloorUnsupported` | A fresh close requested a positive settlement floor. |
| `OrderRouter__SideMismatch`, `OrderRouter__CommitValidation(11)` | Side mismatch or a partial close below the minimum notional. A full close's dust exemption depends on the position used by that path. |
| `CfdEngine__PartialCloseCarryUnfunded`, `CfdEngine__PartialCloseUnhealthy` | The proposed partial close fails a commitment carry/health check. |
| `CfdEngine__TypedOrderFailure` | Execution planning rejected the proposed close; preserve category and code. |
| `CfdOrderPolicyEvaluator__ConstraintViolation`, `CfdOrderPolicyEvaluator__ExecutionModeDisallowed` | The projected execution violates a user bound or allowed mode. |
| Panic, unexpected invariant error, or missing RPC revert data | Review unavailable; keep diagnostics and refresh. Do not replace it with a zero assessment. |

Import the complete current error ABI. The removed close-bounty funding errors and sponsored-grant errors are not current close admission rules.

Preserve constraint actual/limit values, typed planner category/code, and raw revert data. Distinguish a Solidity panic from an RPC response with no revert data. Keep chain, contract address, block/hash, account and reviewed price with diagnostics. A preview failure describes current admission or hypothetical execution; commitment simulation and terminal receipts establish what happened on-chain. A generic failure is not evidence that a deposit is required.

## Acceptance checks

- Correct-chain ABI/runtime and binding checks pass; a mismatched preview is rejected. Initial and final close reviews use the bounded five-argument overload.
- Exact replay resumes an existing pending or terminal ID without presenting empty economics; changed request contents conflict.
- Commitment carry is counted once in totals and bounds, including when pledge pays it and free settlement is zero.
- Full/partial, LONG/SHORT, gains/losses, self/external execution, Live/FAD/Frozen and deferred claims display correctly.
- Positive close settlement floors fail; zero maximum bounds, the full-close dust exemption and partial-close health checks behave as documented.
- Final simulation checks pending orders, queue capacity, active protection, configuration and submission timing. Changed inputs, failed requests and aborted reviews leave no actionable stale quote.
- Completion uses verified lifecycle evidence. A successful transaction alone is insufficient to show that a position closed.

Run the consuming frontend's tests/build and integration tests against the intended deployment. The [close integration checks](test/perps/TEST_MAP.md#close-integration-checks) map current source coverage and its limits; local mock-based parity does not prove compatibility with older deployed bytecode.

## Release boundaries

The current lens is separate from the Router's execution evaluator and exposes neither `assessOrder` nor the evaluator's pure wrappers. Deploying a lens does not replace the Router, evaluator or engine, and current planner/receipt tuples cannot be mixed with an archived stack.

Historical v1.2.3 integration details, addresses and ABI/runtime pins remain in the [2026-09-14 preview release](../../deployments/releases/2026-09-14-close-preview-arbitrum-sepolia/README.md) and [2026-09-15 sponsored-close release](../../deployments/releases/2026-09-15-sponsored-close-arbitrum-sepolia/README.md). Those releases used different close-bounty behavior and a six-argument preview. `previewSponsoredClose` and `validateSponsoredClose` are absent from current source. Use each archived deployment's own artifacts when servicing it.
