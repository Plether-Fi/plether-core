import { describe, expect, it } from "vitest";
import { decodeFunctionData, maxUint256, toFunctionSelector } from "viem";
import { buildPlaceOrderV3Action, type OrderRequestV3 } from "../src/orderV3.js";
import { orderRouterV3TraderAbi } from "../src/orderV3Abi.js";
import { buildProtectedOpenAction } from "../src/protection.js";
import { positionProtectionBookAbi } from "../src/protectionAbi.js";
import signatures from "./compatibility/order-v3-signatures.json";

const account = "0x1111111111111111111111111111111111111111";
const target = "0x2222222222222222222222222222222222222222";
const params = { takeProfitTriggerPrice: 70_000_000n, stopLossTriggerPrice: 90_000_000n,
  closeLimits: { maxExecutionNotionalAssets: 100n, maxGrossAccountDebitAssets: 5n, maxActionChargeAssets: 2n, maxExplicitFeesAssets: 2n } };
const request: OrderRequestV3 = {
  clientOrderId: `0x${"11".repeat(32)}`, side: 0, sizeDelta: 100n, marginDelta: 20n, targetPrice: 80_000_000n, isClose: false,
  bounds: { submitBy: 1_700_000_120n, executionWindowSeconds: 60, allowedExecutionModes: 1,
    expectedConfigHash: `0x${"22".repeat(32)}`, maxExecutionBountyAssets: 1n, maxExecutionNotionalAssets: 100n,
    maxGrossAccountDebitAssets: 5n, maxActionChargeAssets: 2n, maxExplicitFeesAssets: 2n, maxPostPositionSize: 100n,
    minPostSettlementBalanceAssets: 1n, minPostPositionEquityAssets: 10n, maxPostLeverageBps: 50_000 },
};

describe("V3 signed timing", () => {
  it("encodes the canonical Solidity selector and preserves both signed clocks and economic bounds", () => {
    const action = buildPlaceOrderV3Action({ account, orderRouter: target, request });
    expect(action.calls[0].data.slice(0, 10)).toBe(toFunctionSelector(signatures.commitOrder));
    expect(decodeFunctionData({ abi: orderRouterV3TraderAbi, data: action.calls[0].data }).args).toEqual([request]);
    expect(action.submissionDeadline).toBe(1_700_000_120n);
    const protectedAction = buildProtectedOpenAction({ account, book: target, request, params });
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

describe("V3 settlement floor admission", () => {
  it.each([1n, maxUint256])("rejects a closing request with settlement floor %s without silently clearing it", minPostSettlementBalanceAssets => {
    const input = { ...request, isClose: true, marginDelta: 0n,
      bounds: { ...request.bounds, minPostSettlementBalanceAssets } };
    expect(() => buildPlaceOrderV3Action({ account, orderRouter: target, request: input })).toThrow("flat opening order");
    expect(input.bounds.minPostSettlementBalanceAssets).toBe(minPostSettlementBalanceAssets);
  });
  it.each([false, true])("rejects an unlimited gross ceiling with a positive floor (protected=%s)", protectedOpen => {
    const input = { ...request, bounds: { ...request.bounds, maxGrossAccountDebitAssets: maxUint256 } };
    const build = () => protectedOpen
      ? buildProtectedOpenAction({ account, book: target, request: input, params })
      : buildPlaceOrderV3Action({ account, orderRouter: target, request: input });
    expect(build).toThrow("finite maxGrossAccountDebitAssets");
    expect(input.bounds.minPostSettlementBalanceAssets).toBe(1n);
  });
  it.each([false, true])("preserves finite opening floors without an RPC dependency (protected=%s)", protectedOpen => {
    const input = { ...request, bounds: { ...request.bounds, minPostSettlementBalanceAssets: 700n, maxGrossAccountDebitAssets: 200n } };
    if (protectedOpen) {
      const action = buildProtectedOpenAction({ account, book: target, request: input, params });
      expect(decodeFunctionData({ abi: positionProtectionBookAbi, data: action.calls[0].data }).args).toEqual([input, params]);
    } else {
      const action = buildPlaceOrderV3Action({ account, orderRouter: target, request: input });
      expect(decodeFunctionData({ abi: orderRouterV3TraderAbi, data: action.calls[0].data }).args).toEqual([input]);
    }
  });
  it.each([false, true])("preserves unlimited gross ceilings when the floor is zero (protected=%s)", protectedOpen => {
    const input = { ...request, bounds: { ...request.bounds, minPostSettlementBalanceAssets: 0n, maxGrossAccountDebitAssets: maxUint256 } };
    if (protectedOpen) {
      const action = buildProtectedOpenAction({ account, book: target, request: input, params });
      expect(decodeFunctionData({ abi: positionProtectionBookAbi, data: action.calls[0].data }).args).toEqual([input, params]);
    } else {
      const action = buildPlaceOrderV3Action({ account, orderRouter: target, request: input });
      expect(decodeFunctionData({ abi: orderRouterV3TraderAbi, data: action.calls[0].data }).args).toEqual([input]);
    }
  });
});
