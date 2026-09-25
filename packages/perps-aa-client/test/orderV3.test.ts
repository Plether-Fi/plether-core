import { describe, expect, it } from "vitest";
import { decodeFunctionData, encodeErrorResult, parseAbi } from "viem";
import { buildCloseOrderV3, buildExpireOrderV3, classifyCloseFailureV3, CloseMode, orderRouterV3Abi, type OrderRequestV3 } from "../src/index.js";
const router = "0x5555555555555555555555555555555555555555";
const hash = `0x${"11".repeat(32)}` as const;
const request: OrderRequestV3 = {
  clientOrderId: hash, side: 0, sizeDelta: 10_000n * 10n ** 18n, marginDelta: 0n,
  targetPrice: 100_000_000n, isClose: true, closeMode: CloseMode.Standard,
  bounds: { validUntil: 1_900_000_000n, allowedExecutionModes: 7, expectedConfigHash: hash,
    maxExecutionBountyUsdc: 200_000n, maxExecutionNotionalUsdc: 10_000_000_000n,
    maxGrossAccountDebitUsdc: 1_000_000n, maxActionChargeUsdc: 500_000n, maxExplicitFeesUsdc: 400_000n,
    maxPostPositionSize: 0n, minPostSettlementBalanceUsdc: 0n, minPostPositionEquityUsdc: 0n,
    maxPostLeverageBps: 100_000 },
};
describe("new-stack close calls", () => {
  for (const closeMode of [CloseMode.Standard, CloseMode.CallerPaidFullExit]) {
    it(`encodes mode ${closeMode} as one deposit-free call with exact bounds`, () => {
      const input = { ...request, closeMode };
      const call = buildCloseOrderV3(router, input);
      expect(call.to).toBe(router);
      expect(call.value).toBe(0n);
      const decoded = decodeFunctionData({ abi: orderRouterV3Abi, data: call.data });
      expect(decoded.functionName).toBe("commitOrder");
      expect(decoded.args).toEqual([input]);
    });
  }
  it("rejects a caller-paid request allowing remaining exposure", () => {
    expect(() => buildCloseOrderV3(router, { ...request, closeMode: CloseMode.CallerPaidFullExit,
      bounds: { ...request.bounds, maxPostPositionSize: 1n } })).toThrow(/post-position-size/);
  });
  it("encodes permissionless expiry without price data or funds", () => {
    const call = buildExpireOrderV3(router, 7n);
    expect(call.value).toBe(0n);
    expect(decodeFunctionData({ abi: orderRouterV3Abi, data: call.data })).toEqual({ functionName: "expireOrder", args: [7n] });
  });
});

it("keeps funding and health errors distinct and leaves unknown failures unclassified", () => {
  const abi = parseAbi(["error CfdEngine__TypedOrderFailure(uint8 category,uint8 code,bool isClose)"]);
  expect(classifyCloseFailureV3(encodeErrorResult({ abi, errorName: "CfdEngine__TypedOrderFailure", args: [1, 4, true] }))).toBe("actionFunding");
  expect(classifyCloseFailureV3(encodeErrorResult({ abi, errorName: "CfdEngine__TypedOrderFailure", args: [1, 6, true] }))).toBe("residualHealth");
  expect(classifyCloseFailureV3(encodeErrorResult({ abi, errorName: "CfdEngine__TypedOrderFailure", args: [2, 6, true] }))).toBeUndefined();
  expect(classifyCloseFailureV3(encodeErrorResult({ abi, errorName: "CfdEngine__TypedOrderFailure", args: [1, 6, false] }))).toBeUndefined();
  expect(classifyCloseFailureV3("0xdeadbeef")).toBeUndefined();
});
