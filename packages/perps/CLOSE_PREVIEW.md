# Reservation-aware close review

`CfdClosePreview.previewClose` is the pre-commit close-review API. `CfdOrderPolicyEvaluator.assessOrder` remains the execution-state API: its supplied bounty must already have been reserved by commitment.

For the frontend rollout after deployment, use the [implementation handoff and acceptance checklist](CLOSE_PREVIEW_FRONTEND_HANDOFF.md).

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

Use this call at each reviewed close price (current, midpoint, and adverse slippage limit). Preserve the existing open-review route. Feed these assessments into the existing bounds construction and validation policy. Continue to simulate the actual router commitment for queue admission, deadlines, configuration hashes, and other router-level requirements.

`preview.commitmentCarryUsdc` is the settlement debit projected at commitment. `assessment.preSettlementBalanceUsdc` starts after that debit. `assessment.grossAccountDebitUsdc` and `assessment.carryUsdc` describe execution from that projected state; do not count commitment carry twice. `preview.executionBountyUsdc` is the new order's configured bounty. A nonzero bounty is always reserved in addition to all existing reservations, regardless of their aggregate value. If the configured bounty is zero, the commitment projection skips carry collection, funding validation, and the commitment-specific health/mark checks, matching the engine's zero-bounty branch; the execution planner still validates and projects the close.

The preview models commitment and execution at the snapshot time, with a supplied execution price. Future carry, market/configuration changes, and an oracle refresh during commitment can change the result. Refresh the preview when relevant state changes. A stale but nonzero stored mark remains accepted for commitment, as in the engine; this is not a guarantee that an execution oracle update will be accepted.

Side and partial-close dust validation use the live position. The router instead validates against its queued position, including earlier pending opens and closes. A preview can therefore differ from commitment when other orders are pending; simulation of the actual commitment remains required. Full closes are exempt from the dust floor only relative to the position each path uses.

## Failure semantics

- Insufficient free settlement after commitment carry uses the existing `CfdEngine__InsufficientCloseOrderBountyBacking(requiredBounty, freeSettlement, unpaidCarry)` error. Decode all three arguments.
- Invalid position/size, missing stored mark, and unhealthy partial closes preserve the engine's existing commitment errors.
- Wrong-side closes use `OrderRouter__SideMismatch`; partial closes below the router's minimum notional use `OrderRouter__CommitValidation(11)`. These checks also apply when the configured bounty is zero.
- Insufficient settlement at the evaluator's terminal bounty debit uses `CfdOrderPolicyEvaluator__InsufficientBountyBacking(settlement, bounty)`. This is an accounting invariant failure, including for self-execution. It must remain retryable and must not be classified as a terminal policy constraint.
- Decode Solidity `Panic(uint256)` for older deployed evaluators; a panic is distinct from an RPC failing to provide revert data.

## Sponsored testnet closes

The current source also exposes `previewSponsoredClose(engine, account, request, executor, executionPrice, publishTime)`
and `validateSponsoredClose(engine, request, expectedSubsidyUsdc)`. These APIs are restricted to Arbitrum Sepolia
(`421614`) and the immutable `SPONSORED_ENGINE` v1.2.3 address. The ordinary `previewClose` has no such deployment gate.

`previewSponsoredClose` returns `subsidyUsdc`, `depositCarryUsdc`, `commitmentCarryUsdc`, `executionBountyUsdc`, and
`assessment`. It first projects carry against existing collateral, rejects uncovered carry, and computes only the
remaining free-settlement shortfall for the close bounty. The bounty cannot exceed `MAX_CLOSE_SUBSIDY_USDC = 200_000`
(USDC atoms, or $0.20). It then reloads the original snapshot, credits the proposed deposit before projecting its carry
hook, and projects close commitment and execution. Display deposit carry and commitment carry separately from the
execution assessment; none should be charged twice. A fully funded account previews with zero subsidy, but the guard
rejects a zero grant.

The account must have no pending orders or active protection. The request must be a close with zero margin delta,
nonzero target price, an unused nonzero client intent outside the protocol-reserved prefix, the current configuration
hash, a `submitBy` at or after the current timestamp, a positive `executionWindowSeconds` no greater than
`maxExecutionWindowSeconds`, sufficient bounty allowance, and valid execution
modes. Preview accepts nonempty combinations of the three mode bits; the final guard requires one mode. Ordinary
side, size, dust, funding, execution bounds, and partial-close charge rules still apply.

For assistance, the smart account must call `validateSponsoredClose` first in an atomic reverting batch, immediately
followed by the authorized test-token mint, approval, clearinghouse deposit, and router commitment. The guard checks
`msg.sender` as the beneficiary and requires the exact positive shortfall. It does not mint funds, consume the client
intent, validate every execution bound, or guarantee queue admission; the actual commitment must succeed in the same
batch. Successful commitment consumes the intent, so a replay fails before another mint. There is no campaign expiry
in the lens; order validity and external issuance/paymaster policy remain separate checks.

## Release boundaries

The original preview was deployed and source-verified alongside the existing v1.2.3 engine on Arbitrum Sepolia on 2026-09-14 at `0x202A2C5156563Ec4fEF7D3997771bBCa90e98117`. See the [deployment packet](../../deployments/releases/2026-09-14-close-preview-arbitrum-sepolia/README.md) for its exact ABI, runtime hash and recorded validation evidence. That deployment did not switch the frontend; the dated [handoff](CLOSE_PREVIEW_FRONTEND_HANDOFF.md) records the required integration work, not a live verification of the frontend's current status.

The [2026-09-15 sponsored-close release](../../deployments/releases/2026-09-15-sponsored-close-arbitrum-sepolia/README.md)
preserves `previewClose` and adds the sponsored methods at `0xC8Ad43019D371DEe7784C06dFa1A2F1538E0D7cf`. Its
[manifest](../../deployments/releases/2026-09-15-sponsored-close-arbitrum-sepolia/manifest.json) pins the final lens,
runtime hash, ABI checksum, and v1.2.3 bindings. It records issuance disabled by default. Use that release's ABI and
runtime pin for sponsored integration; the earlier candidate identified in its README was never enabled. Deployment
alone does not enable assistance, and repository source is not evidence that either deployed lens has been upgraded.

For a new full protocol deployment, `DeployPerpsArbitrumSepolia` deploys and logs `CfdClosePreview` before the router CREATE-address nonce snapshot. The deployment template records it as `cfdClosePreview`; supply its address as `PERPS_CLOSE_PREVIEW` to the release verifier. For an existing v1.2.3 deployment, deploy only the constructor-free preview contract, record its verified address/runtime hash separately, and update frontend close-review calls; do not run the full protocol deployment script for this additive rollout.

The current preview and execution evaluator share internal snapshot construction and normalization through
`CfdOrderPolicyEvaluatorBase`. The current preview does not expose `assessOrder`, `evaluateOpen`, or `evaluateClose`;
those public wrappers belong to `CfdOrderPolicyEvaluator`. The historical 2026-09-14 preview ABI did inherit those
methods, but they were never prospective-close APIs. Keep the preview separate from the execution evaluator: the
release verifier rejects `router.policyEvaluator() == closePreview`, including a manifest that labels the execution
evaluator as the preview. Deploying a hardened execution evaluator remains an explicit protocol-release decision.

For the recorded v1.2.3 rollout, evaluator hardening requires a separate execution-contract release. The existing router's evaluator is immutable, and the engine's router binding is set once. Do not replace the router's evaluator address in a manifest, attach a new router to the existing engine, or assume deploying this preview upgrades execution.

The real-stack adverse full-consumption regression opens a 10,000-token LONG with $250 margin and exactly $0.20 free settlement, then reviews a full close at 1.025. Unreserved `assessOrder` spends that $0.20 on action charges and subtracts the bounty again. It succeeds but understates the reservation-aware result by exactly $0.20; actual router commitment and execution match the new preview within one second of carry drift. This exercises the successful arithmetic path shared with v1.2.3; it does not replay the deployed evaluator bytecode.

Under the default configuration, the liquidation reserve is floored at `riskParams.minBountyUsdc` ($1), while the close bounty defaults to $0.20 and is capped at $1. Price loss, carry, and action charges cannot consume the liquidation-reserve bucket. The plain open-to-close lifecycle therefore demonstrates mispricing rather than a panic. The panic form appears unreachable under these conditions; attributing a deployed panic to this mechanism would require evidence that the protected reserve was below the bounty or another assumption differed.

The synthetic regression demonstrates the underflow state shape with no liquidation reserve; the hardened evaluator reports the typed invariant error there. Neither that fixture nor the real-stack regression identifies the historical screenshot account or establishes a panic in a properly reserved deployed order.
