import { describe, expect, it } from "vitest";
import { decodeFunctionData, toFunctionSelector } from "viem";
import { buildPlaceOrderV3Action, type OrderRequestV3 } from "../src/orderV3.js";
import { orderRouterV3TraderAbi } from "../src/orderV3Abi.js";
import { buildProtectedOpenAction } from "../src/protection.js";
import signatures from "./compatibility/order-v3-signatures.json";

const account = "0x1111111111111111111111111111111111111111";
const target = "0x2222222222222222222222222222222222222222";
const request: OrderRequestV3 = {
  clientOrderId: `0x${"11".repeat(32)}`, side: 0, sizeDelta: 100n, marginDelta: 20n, targetPrice: 80_000_000n, isClose: false,
  bounds: { submitBy: 1_700_000_120n, executionWindowSeconds: 60, allowedExecutionModes: 1,
    expectedConfigHash: `0x${"22".repeat(32)}`, maxExecutionBountyUsdc: 1n, maxExecutionNotionalUsdc: 100n,
    maxGrossAccountDebitUsdc: 5n, maxActionChargeUsdc: 2n, maxExplicitFeesUsdc: 2n, maxPostPositionSize: 100n,
    minPostSettlementBalanceUsdc: 1n, minPostPositionEquityUsdc: 10n, maxPostLeverageBps: 50_000 },
};

describe("V3 signed timing", () => {
  it("encodes the canonical Solidity selector and preserves both signed clocks and economic bounds", () => {
    const action = buildPlaceOrderV3Action({ account, orderRouter: target, request });
    expect(action.calls[0].data.slice(0, 10)).toBe(toFunctionSelector(signatures.commitOrder));
    expect(decodeFunctionData({ abi: orderRouterV3TraderAbi, data: action.calls[0].data }).args).toEqual([request]);
    expect(action.submissionDeadline).toBe(1_700_000_120n);
    const protectedAction = buildProtectedOpenAction({ account, book: target, request, params: { takeProfitTriggerPrice: 70_000_000n, stopLossTriggerPrice: 90_000_000n } });
    expect(protectedAction.calls[0].data.slice(0, 10)).toBe(toFunctionSelector(signatures.commitOpenOrderWithProtection));
    expect(protectedAction.submissionDeadline).toBe(action.submissionDeadline);
  });
  it.each([0, -1, 3601, 1.5])("rejects invalid duration %s", executionWindowSeconds => {
    expect(() => buildPlaceOrderV3Action({ account, orderRouter: target, request: { ...request, bounds: { ...request.bounds, executionWindowSeconds } } })).toThrow();
  });
  it("changing either timing authority changes the signed calldata", () => {
    const encode = (bounds: OrderRequestV3["bounds"]) => buildPlaceOrderV3Action({ account, orderRouter: target, request: { ...request, bounds } }).calls[0].data;
    expect(encode({ ...request.bounds, submitBy: request.bounds.submitBy + 1n })).not.toBe(encode(request.bounds));
    expect(encode({ ...request.bounds, executionWindowSeconds: 59 })).not.toBe(encode(request.bounds));
  });
});
