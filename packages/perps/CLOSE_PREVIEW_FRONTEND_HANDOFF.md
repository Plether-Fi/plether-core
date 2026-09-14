# Frontend handoff: reservation-aware close review

Status: ready for frontend implementation; activation requires the completed deployment record below.

Deploy `CfdClosePreview` alongside perps v1.2.3, then route prospective close/reduce reviews through its `previewClose` method. It projects commitment carry and reserves the new close bounty before assessing execution. This corrects the current frontend's use of unreserved account state with `CfdOrderPolicyEvaluator.assessOrder`.

Protocol source: [PR #99](https://github.com/Plether-Fi/plether-core/pull/99), implementation reviewed at `a3828cd191ed0371056dac8d5daca60b89c8deac`. Frontend file map checked against `plether-app` commit `2967aa5ea348c5314ae6adbce5abf4c5bb49c43a`; reconcile paths if that branch has moved. See [accounting and release notes](CLOSE_PREVIEW.md) and [contract source](src/CfdClosePreview.sol).

## 1. Deployment packet required before activation

The deployment owner should complete and publish this record with the exact deployed artifact. `TBA` values are deliberately unusable as application configuration.

| Field | Value |
| --- | --- |
| Network / chain ID | Arbitrum Sepolia / `421614` |
| Existing protocol release | `v1.2.3` |
| Contract | `packages/perps/src/CfdClosePreview.sol:CfdClosePreview` |
| Constructor arguments | None |
| New `cfdClosePreview` address | **TBA after deployment** |
| Creation transaction / deployment block | **TBA after deployment** |
| Actual deployed source commit | **TBA; record the deployment build revision** |
| Compiler / optimizer / build settings | **TBA; attach deployment build metadata** |
| Runtime code hash | **TBA; `keccak256(eth_getCode(address))`, checked against the deployment artifact** |
| ABI artifact / SHA-256 of delivered ABI file | **TBA; attach ABI from the deployment build** |
| Verified explorer source URL | **TBA after verification** |

The existing release is pinned in [the v1.2.3 manifest](../../deployments/releases/2026-09-10-perps-arbitrum-sepolia-v1.2.3/manifest.json). Its engine is `0xafece93321be41aa73474457e2f47cf7b2fb738f`, router is `0x6215d36fcbd610ca1525252eebcbfd8b223a6072`, and execution evaluator is `0x43c93d3028fcd4c1f578a50639750b8fbfdee799`. These are manifest references, not a fresh onchain verification.

For this additive rollout, deploy only the constructor-free preview. The full protocol deployment script creates an entire new deployment and is not the rollout command for the existing v1.2.3 graph. Publish a supplemental lens deployment record; preserve the historical v1.2.3 artifact and its provenance hash.

The frontend must verify chain ID, nonempty runtime bytecode, and its exact expected runtime hash before enabling this close-review route. Keep existing engine/router/evaluator binding checks. Also reject an address equal to the router's execution evaluator. The preview inherits `assessOrder`, `evaluateOpen`, and `evaluateClose`; none of those inherited methods is the prospective-close API. There is no router rebinding or state migration in this rollout.

## 2. Frontend implementation map

All paths below are relative to the `plether-app` repository.

| Location | Required change |
| --- | --- |
| `config/perps/` | Add a supplemental close-preview deployment pin containing the packet's chain, address, runtime hash, source revision and ABI provenance. Keep `arbitrum-sepolia-v2.json`'s historical release identity intact. |
| `apps/frontend/src/contracts/perpsAddresses.ts` | Expose a distinct close-preview address from the supplemental pin. Keep `policyEvaluator`, `cfdEngineLens`, and `perpsPublicLens` mapped to their current contracts. |
| `apps/frontend/src/contracts/verifyPerpsV2Bindings.ts` | Add close-route verification for the new pin at the reviewed block, including code hash and evaluator separation. Scope missing/invalid preview configuration to close review so open preparation still works. |
| `apps/frontend/src/contracts/abis/Perps.ts` and ABI barrel | Add `PERPS_CFD_CLOSE_PREVIEW_ABI` from the actual deployed artifact. Preserve tuple field names and signed types. |
| `apps/frontend/src/contracts/preparePerpsOrderV2.ts` | Branch inside `assessAtReviewedPrices`: close uses the six-argument `previewClose` call below; open keeps its existing `assessOrder` call and margin-adjustment loop. Apply the branch to both initial and final-bounds assessments. |
| `apps/frontend/src/contracts/perpsOrderV2.ts` | Add the nested preview return type and carry `commitmentCarryUsdc` into the review summary. Keep `currentAssessment` as the nested execution assessment. Update fixtures/persisted optional summaries as needed. |
| `apps/frontend/src/components/PerpsTradeTicket.tsx` | Display commitment carry separately; source reviewed execution costs and post-state from the new assessment. Invalidate stale reviews when inputs/state change and block confirmation until refreshed. |
| `apps/frontend/src/utils/perpsErrors.ts` | Correct the funding error's three-argument signature, add the typed bounty invariant error, and distinguish Solidity panic from missing RPC revert data. |
| `apps/frontend/src/contracts/__tests__/preparePerpsOrderV2.test.ts`, `perpsRelease.test.ts`, and `apps/frontend/src/components/__tests__/PerpsTradeTicketRegimes.test.tsx` | Update nested-result mocks, deployment verification, route selection, carry display, and acceptance scenarios below. |

Prefer a frontend-only supplemental pin for this read-only dependency. The public AA manifest's `policyEvaluator` remains the execution evaluator; adding this lens does not require changing the AA manifest version, signing payloads, backend execution bindings, or the protocol release version. If implementation instead extends a shared manifest schema, update all its parsers and fixtures together without relabeling the evaluator.

There is already a different `CfdEngineLens.previewClose(account, size, oraclePrice)` call in frontend diagnostics, including `apps/frontend/src/hooks/usePerpsTrading.ts`. Its signature and return type differ. Do not globally replace calls or types named `previewClose`. Instantaneous engine-lens data can still support sizing/risk fields absent from the new result; it must not stand in for the confirmed commitment-aware review after a new-lens error.

## 3. Exact call and result handling

Use the ABI from the deployment build's `CfdClosePreview.sol/CfdClosePreview.json` artifact, `abi` field. Generate frontend bindings from that artifact instead of transcribing tuple layouts. The function accepts six arguments in this order:

```typescript
// Inside close review; context reads and every price sample use this same block.
const closeOrder = {
  account,                       // canonical position account (AA account when used)
  sizeDelta,                     // 18 decimals, multiple of 1e20 (100 tokens)
  marginDelta: 0n,
  targetPrice,                   // existing close slippage target, 8 decimals
  commitTime: blockTimestamp,    // uint64, timestamp of the reviewed block
  commitBlock: blockNumber,      // uint64
  orderId: 0n,                   // prospective, uncommitted order
  side,                         // LONG = 0, SHORT = 1; match the live position
  isClose: true,
}

const preview = await client.readContract({
  address: closePreviewAddress,
  abi: PERPS_CFD_CLOSE_PREVIEW_ABI,
  functionName: 'previewClose',
  args: [
    manifest.cfdEngine,
    closeOrder,
    manifest.orderRouter,        // current frontend's non-self executor sentinel
    reviewedPrice,              // current / midpoint / adverse limit, 8 decimals
    blockTimestamp,             // publishTime: hypothetical execution at review time
    bounds,                     // existing PerpsExecutionBounds tuple
  ],
  blockNumber,
})

// Return tuple order: commitmentCarryUsdc, executionBountyUsdc, assessment.
const { commitmentCarryUsdc, executionBountyUsdc, assessment } = preview
```

For keeper execution, preserve the current non-self executor convention shown above. For an explicitly self-executed close, use `account` as executor: the bounty returns to that account. An EOA owner of an AA account is not the position account. Do not pass `account` unconditionally.

The nested `assessment` has the same named fields as the existing `PerpsExecutionAssessment`. `realizedPnlUsdc`, `vpiUsdc`, and `postPositionEquityUsdc` are signed `int256`; other amount fields are unsigned. Keep amounts as `bigint`. USDC uses 6 decimals, prices 8, size 18. The assessment's mode enum is `None=0, Live=1, Fad=2, Frozen=3`; the allowed-modes bitmask is `Live=1, Fad=2, Frozen=4`.

Remove caller-supplied pool depth and execution bounty from the close assessment call: the new lens reads the engine's pool and configured router bounty itself. Use the returned `executionBountyUsdc` for the close summary and bound construction. If retaining the context's bounty read, require agreement at the same block; treat disagreement as an invalid review. No local reserve or balance adjustment is needed.

Run this for every deduplicated current/midpoint/adverse price and again with final bounds when that pass is enabled. Feed the nested assessments into the existing `relaxedWebPerpsExecutionBounds` / `derivePerpsExecutionBounds` review policy without changing that policy's financial limits as part of this fix. Maximum bounds of zero mean zero allowance, not “unset.” Keep the submitted router `OrderRequest` shape unchanged.

Always preserve `simulateReviewedPerpsOrderV2` against the actual `commitOrder(request)`, with the canonical account and reviewed block. Refresh context, preview and simulation before submission when the reviewed state is stale. The preview omits queue admission, deadline/config-hash enforcement, future carry and oracle refresh during commitment. Its side/dust checks use the live position; the router uses queued position state after preceding orders. Pending opens or closes can make their answers differ, so preview success alone cannot authorize submission.

This API always projects one **new** bounty reservation, even if pending orders already reserve bounties. Use it only before commitment. Existing committed-order assessment/execution routes remain on the execution-state API.

## 4. Accounting rules for review and funding UI

| Value | Meaning / display rule |
| --- | --- |
| `preview.commitmentCarryUsdc` | Carry paid at the projected commitment checkpoint. Display separately as commitment carry. |
| `preview.executionBountyUsdc` | The new order's bounty, reserved during commitment and accounted for during execution. Include it once. |
| `assessment.preSettlementBalanceUsdc` | Total internal settlement **after** projected commitment carry. |
| `assessment.carryUsdc` | Execution-stage carry from that projected state; commitment carry is separate. |
| `assessment.grossAccountDebitUsdc` | Execution-stage gross debit, including claim consumption and bounty. Use this baseline for the corresponding execution bound. |
| `assessment.postSettlementBalanceUsdc` | Resulting total internal custody, including locked funds; not withdrawable/free balance. Do not subtract commitment carry or bounty again. |
| `assessment.postTraderClaimUsdc` | Remaining/deferred trader claim. Do not present claims as immediately available USDC. |

Do not add `commitmentCarryUsdc` to `maxGrossAccountDebitUsdc` when deriving execution bounds. A separately labeled lifecycle gross-debit metric may add commitment carry to execution gross debit, but it is not net cash loss or an external-wallet debit; self-execution returns the bounty and gross debit can include claims.

Commitment pays carry from position margin first, then free settlement. The close bounty must fit in the **remaining free settlement**. Therefore `free >= bounty + commitmentCarry` is not a valid general funding gate. The lens and actual commitment simulation are authoritative. Its funding error reports remaining free settlement and unpaid carry.

The current summary's `requiredFundingUsdc = marginDelta + bounty` / `availableFundingUsdc = freeBuyingPower` predates this projection. For closes, present the bounty as a reserve requirement and carry as a separate debit, and avoid treating this pair as a complete projected funding test. Preserve the existing open-only funding gate. If showing a close deposit shortfall, use decoded post-carry funding evidence rather than subtracting total carry from free balance locally.

## 5. Error handling

Import all custom errors from the new contract artifact. Important signatures and behavior:

| Error | Frontend behavior |
| --- | --- |
| `CfdEngine__InsufficientCloseOrderBountyBacking(uint256 requiredBountyUsdc, uint256 availableFreeSettlementUsdc, uint256 unpaidCarryUsdc)` | Explain that free settlement after carry cannot fund the close reserve. Decode all three values. The current frontend incorrectly declares this with no arguments. |
| `CfdOrderPolicyEvaluator__InsufficientBountyBacking(uint256 settlementUsdc, uint256 bountyUsdc)` | Accounting invariant failure. Block the review, refresh and retain diagnostics. Do not turn this into an ordinary deposit hint, terminal policy failure, zero-valued result, or fallback to the old evaluator. |
| `OrderRouter__SideMismatch()` | Position side changed or the requested reduce side is invalid; refresh/review. |
| `OrderRouter__CommitValidation(uint8 code)` with `code=11` | Partial close is below the router's minimum notional. Full-close exemption depends on the position used by each path. |
| Existing no-position, invalid-size/quantum, missing-mark and unhealthy-partial-close errors | Preserve actionable engine/router messages; refresh stale state before another review. |
| `CfdOrderPolicyEvaluator__ConstraintViolation(uint8 constraint, uint256 actual, uint256 limit)` / `ExecutionModeDisallowed(uint8,uint8)` | Keep existing bound/mode handling with the nested assessment route. |
| `CfdEngine__TypedOrderFailure(uint8 failureCategory, uint8 failureCode, bool isClose)` | Preserve typed planner failure diagnostics and prevent submission of the failed review. |
| `Panic(uint256 code)` | Add standard Solidity panic decoding, including arithmetic `0x11` from older contracts. Treat as an internal failure, distinct from unavailable revert data. |

Unwrap nested RPC/viem causes using the existing error pipeline. For no-data RPC failures, report review unavailable and allow refresh; do not invent a Solidity reason. Retain chain, lens address, block number/hash, account, sample price, decoded error/arguments and raw revert data when available for debugging. Do not attribute historical panics to this bug without a reproduction against that deployed state.

## 6. Acceptance checks before frontend activation

- [ ] Deployment pin is complete; correct-chain runtime hash and existing bindings pass. Missing code, wrong chain, wrong hash or evaluator alias blocks close review while open preparation remains usable.
- [ ] Close current/midpoint/adverse samples and final-bounds pass call the new address with exactly six arguments. Open samples still call the original evaluator. Every review read uses the same block; stale results cannot survive account/chain/size/price/config changes or an aborted request.
- [ ] Nonzero commitment carry appears separately and is not charged again in bounds or post-settlement UI. Include carry funded from position margin to catch an incorrect free-balance gate.
- [ ] Exact bounty backing succeeds; one USDC atomic unit short decodes the three-argument funding error. Existing pending bounty/action/VPI reserves cannot satisfy the new reservation twice.
- [ ] Full and partial closes on both sides cover gains, losses, keeper and self-execution, frozen mode and deferred trader claims. Self-executor uses the canonical account.
- [ ] Wrong side and below-minimum partial size fail; a full close below the dust floor remains valid when it matches the applicable position. Pending-order cases still run actual commitment simulation and surface disagreement.
- [ ] Typed invariant error, arithmetic panic and no-data RPC error remain distinct; none yields a successful stale/zero review or silently falls back to unreserved `assessOrder`.
- [ ] Confirmed review costs use the new assessment. Other engine-lens preview fields and story fixtures are not accidentally decoded as the new tuple.
- [ ] Run frontend unit tests and build, plus the project's relevant perps integration/fork tests. Exercise both ordinary and AA account review paths.
- [ ] Against the deployed lens and v1.2.3 bytecode on a local fork, reproduce the reservation regression and compare preview with actual commitment/execution. Record chain/block, addresses, inputs and results. Core source tests are supporting evidence, not a substitute for this deployed compatibility check.

The core fixture [test_AdverseFullConsumptionRegression](test/perps/CfdClosePreview.t.sol) opens a 10,000-token LONG at raw price `1.0` with $250 margin and exactly $0.20 free settlement, then reviews a full close at `1.025`. The old unreserved assessment collects $0.20 in action charges and subtracts the bounty again; the new assessment collects zero action charges and reports $0.20 more post-settlement balance. Actual commitment/execution matches the new preview within the fixture's one-second carry drift. Reproduce equivalent conditions on a fork with controlled state; do not add a blanket UI rounding tolerance. The raw basket price moves inversely to USD strength, so `1.025` is adverse for LONG.

## 7. Activation and completion record

1. Deployment owner supplies the completed packet and verified ABI.
2. Frontend PR implements the route, decoding and UI changes, with all acceptance checks recorded.
3. Verify a production frontend build points to the supplemental lens and the original v1.2.3 graph; deploy through the frontend repository's existing workflow.
4. Smoke-test close/reduce reviews on the target chain and check error diagnostics. Record the frontend commit/build and smoke-test block alongside the deployment packet.
5. If the new route is unavailable or fails verification, disable close confirmation with a refresh/unavailable message while investigating. Reverting to the old unreserved review would restore the accounting bug and is not a validated fallback.

Completion means the deployed frontend uses this lens for every prospective-close review pass, displays carry/bounty once, and still simulates router commitment. The protocol execution evaluator remains v1.2.3; hardening or refactoring it belongs to a separate protocol release.
