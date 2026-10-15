import { describe, expect, it } from "vitest";
import { decodeFunctionData, encodeErrorResult, maxUint256, parseAbi } from "viem";
import { buildCloseOrderV3, buildExpireOrderV3, classifyCloseFailureV3, orderRouterV3Abi, type OrderRequestV3 } from "../src/index.js";
const router = "0x5555555555555555555555555555555555555555";
const hash = `0x${"11".repeat(32)}` as const;
const request: OrderRequestV3 = {
  clientOrderId: hash, side: 0, sizeDelta: 10_000n * 10n ** 18n, marginDelta: 0n,
  targetPrice: 100_000_000n, isClose: true,
  bounds: { submitBy: 1_900_000_000n, executionWindowSeconds: 60, allowedExecutionModes: 7, expectedConfigHash: hash,
    maxExecutionBountyUsdc: 200_000n, maxExecutionNotionalUsdc: 10_000_000_000n,
    maxGrossAccountDebitUsdc: 1_000_000n, maxActionChargeUsdc: 500_000n, maxExplicitFeesUsdc: 400_000n,
    maxPostPositionSize: 0n, minPostSettlementBalanceUsdc: 0n, minPostPositionEquityUsdc: 0n,
    maxPostLeverageBps: 100_000 },
};
describe("new-stack close calls", () => {
  for (const maxPostPositionSize of [0n, 5_000n * 10n ** 18n]) {
    it(`encodes a close with a ${maxPostPositionSize} post-size bound as one deposit-free call`, () => {
      const input = { ...request, sizeDelta: request.sizeDelta - maxPostPositionSize,
        bounds: { ...request.bounds, maxPostPositionSize } };
      const call = buildCloseOrderV3(router, input);
      expect(call.to).toBe(router);
      expect(call.value).toBe(0n);
      const decoded = decodeFunctionData({ abi: orderRouterV3Abi, data: call.data });
      expect(decoded.functionName).toBe("commitOrder");
      expect(decoded.args).toEqual([input]);
    });
  }
  it("encodes permissionless expiry without price data or funds", () => {
    const call = buildExpireOrderV3(router, 7n);
    expect(call.value).toBe(0n);
    expect(decodeFunctionData({ abi: orderRouterV3Abi, data: call.data })).toEqual({ functionName: "expireOrder", args: [7n] });
  });
  it.each([1n, maxUint256])("rejects a close with settlement floor %s without changing the request", minPostSettlementBalanceUsdc => {
    const input = { ...request, bounds: { ...request.bounds, minPostSettlementBalanceUsdc } };
    expect(() => buildCloseOrderV3(router, input)).toThrow("flat opening order");
    expect(input.bounds.minPostSettlementBalanceUsdc).toBe(minPostSettlementBalanceUsdc);
  });
  it("preserves an unlimited gross debit ceiling for a close without a settlement floor", () => {
    const input = { ...request, bounds: { ...request.bounds, maxGrossAccountDebitUsdc: maxUint256 } };
    const call = buildCloseOrderV3(router, input);
    expect(decodeFunctionData({ abi: orderRouterV3Abi, data: call.data }).args).toEqual([input]);
  });
});

it("keeps funding and health errors distinct and leaves unknown failures unclassified", () => {
  const abi = parseAbi(["error CfdEngine__TypedOrderFailure(uint8 category,uint8 code,bool isClose)"]);
  expect(classifyCloseFailureV3(encodeErrorResult({ abi, errorName: "CfdEngine__TypedOrderFailure", args: [1, 4, true] }))).toBe("actionFunding");
  expect(classifyCloseFailureV3(encodeErrorResult({ abi, errorName: "CfdEngine__TypedOrderFailure", args: [1, 6, true] }))).toBe("residualHealth");
  expect(classifyCloseFailureV3(encodeErrorResult({ abi, errorName: "CfdEngine__TypedOrderFailure", args: [1, 7, true] }))).toBe("sideMismatch");
  expect(classifyCloseFailureV3(encodeErrorResult({ abi, errorName: "CfdEngine__TypedOrderFailure", args: [2, 6, true] }))).toBeUndefined();
  expect(classifyCloseFailureV3(encodeErrorResult({ abi, errorName: "CfdEngine__TypedOrderFailure", args: [1, 6, false] }))).toBeUndefined();
  expect(classifyCloseFailureV3("0xdeadbeef")).toBeUndefined();
});

it("requires exact typed evidence for a close side mismatch and leaves open numeric failures unknown", () => {
  const abi = parseAbi(["error CfdEngine__TypedOrderFailure(uint8 category,uint8 code,bool isClose)"]);
  for (const args of [[2, 7, true], [1, 7, false], [1, 8, true], [2, 11, false]] as const) {
    expect(classifyCloseFailureV3(encodeErrorResult({ abi, errorName: "CfdEngine__TypedOrderFailure", args }))).toBeUndefined();
  }
  const mismatch = encodeErrorResult({ abi, errorName: "CfdEngine__TypedOrderFailure", args: [1, 7, true] });
  expect(classifyCloseFailureV3(`${mismatch}00`)).toBeUndefined();
  expect(classifyCloseFailureV3(mismatch.slice(0, -2) as typeof mismatch)).toBeUndefined();
});

it("leaves retired pledge-bounty admission and funding errors unclassified", () => {
  const queueAbi = parseAbi(["error OrderRouter__PledgeBountyRequiresEmptyQueue()"]);
  const queueError = encodeErrorResult({ abi: queueAbi, errorName: "OrderRouter__PledgeBountyRequiresEmptyQueue" });
  expect(classifyCloseFailureV3(queueError)).toBeUndefined();
  expect(classifyCloseFailureV3(`${queueError}00`)).toBeUndefined();
  expect(classifyCloseFailureV3(queueError.slice(0, -2) as typeof queueError)).toBeUndefined();
  const fundingAbi = parseAbi(["error CfdEngine__InsufficientCloseOrderBountyBacking(uint256 required,uint256 available,uint256 unpaidCarry)"]);
  const fundingError = encodeErrorResult({ abi: fundingAbi, errorName: "CfdEngine__InsufficientCloseOrderBountyBacking", args: [1n, 0n, 0n] });
  expect(classifyCloseFailureV3(fundingError)).toBeUndefined();
});
