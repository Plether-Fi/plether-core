# Reservation-aware close review

`CfdClosePreview.previewClose` is the pre-commit close-review API. `CfdOrderPolicyEvaluator.assessOrder` remains the execution-state API: its supplied bounty must already have been reserved by commitment.

## Calling the preview

Deploy `CfdClosePreview` as an additive, stateless read-only contract. It has no constructor arguments. Pin its address and runtime bytecode independently from the existing release's engine, router, planner, and execution evaluator. The preview reads the engine's configured router to obtain the close bounty and its configured pool for canonical depth.

```typescript
const preview = await publicClient.readContract({
  address: closePreviewAddress,
  abi: closePreviewAbi,
  functionName: 'previewClose',
  args: [engineAddress, closeOrder, executorAddress, reviewedPrice, publishTime, executionBounds],
  blockNumber,
})
const assessment = preview.assessment
```

Use this call at each reviewed close price (current, midpoint, and adverse slippage limit). Preserve the existing open-review route. Rebuild reviewed bounds from these assessments. Continue to simulate the actual router commitment for queue admission, deadlines, configuration hashes, and other router-level requirements.

`preview.commitmentCarryUsdc` is the settlement debit projected at commitment. `assessment.preSettlementBalanceUsdc` starts after that debit. `assessment.grossAccountDebitUsdc` and `assessment.carryUsdc` describe execution from that projected state; do not count commitment carry twice. `preview.executionBountyUsdc` is the new order's configured bounty. The preview always reserves it in addition to all existing reservations, regardless of their aggregate value.

The preview models commitment and execution at the snapshot time, with a supplied execution price. Future carry, market/configuration changes, and an oracle refresh during commitment can change the result. Refresh the preview when relevant state changes. A stale but nonzero stored mark remains accepted for commitment, as in the engine; this is not a guarantee that an execution oracle update will be accepted.

## Failure semantics

- Insufficient free settlement after commitment carry uses the existing `CfdEngine__InsufficientCloseOrderBountyBacking(requiredBounty, freeSettlement, unpaidCarry)` error. Decode all three arguments.
- Invalid position/size, missing stored mark, and unhealthy partial closes preserve the engine's existing commitment errors.
- Insufficient settlement at the evaluator's terminal bounty debit uses `CfdOrderPolicyEvaluator__InsufficientBountyBacking(settlement, bounty)`. This is an accounting invariant failure, including for self-execution. It must remain retryable and must not be classified as a terminal policy constraint.
- Decode Solidity `Panic(uint256)` for older deployed evaluators; a panic is distinct from an RPC failing to provide revert data.

## Release boundaries

The new preview can be deployed alongside the existing v1.2.3 engine. Updating frontend close-review calls to its verified address is required to change the deployed UI's behavior. This source patch does not deploy the contract or update another repository's frontend manifest.

The evaluator hardening is for a future execution-contract release. The existing router's evaluator is immutable, and the engine's router binding is set once. Do not replace the router's evaluator address in a manifest, attach a new router to the existing engine, or assume deploying this preview upgrades execution.

The synthetic reservation regression demonstrates the panic mechanism. The normal router lifecycle regressions independently demonstrate the precommit accounting mismatch and parity after reservation. Neither identifies the historical screenshot account or establishes a panic in a properly reserved deployed order.
