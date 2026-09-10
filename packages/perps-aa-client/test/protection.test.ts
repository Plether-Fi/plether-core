import { describe, expect, it } from "vitest";
import { decodeFunctionData } from "viem";
import { buildCreateProtectionAction, buildReplaceProtectionAction, buildCancelProtectionAction, buildProtectedOpenAction } from "../src/protection.js";
import { positionProtectionBookAbi } from "../src/protectionAbi.js";

const account = "0x1111111111111111111111111111111111111111";
const book = "0x2222222222222222222222222222222222222222";
const params = { takeProfitTriggerPrice: 70_000_000n, stopLossTriggerPrice: 90_000_000n };

describe("v1.2.1 protection actions", () => {
  it("encodes an account-owned OCO with zero ETH", () => {
    const plan = buildCreateProtectionAction({ account, book, params });
    expect(plan.kind).toBe("create-protection");
    expect(plan.calls[0].to).toBe(book);
    expect(plan.calls[0].value).toBe(0n);
    expect(decodeFunctionData({ abi: positionProtectionBookAbi, data: plan.calls[0].data })).toEqual({ functionName: "createPositionProtection", args: [params] });
  });
  it("retains the protection ID when replacing or cancelling", () => {
    for (const plan of [buildReplaceProtectionAction({ account, book, params, protectionId: 42n }), buildCancelProtectionAction({ account, book, protectionId: 42n })]) {
      expect(decodeFunctionData({ abi: positionProtectionBookAbi, data: plan.calls[0].data }).args?.[0]).toBe(42n);
    }
  });
  it("rejects empty triggers, invalid IDs, and unbounded opens before signing", () => {
    expect(() => buildCreateProtectionAction({ account, book, params: { takeProfitTriggerPrice: 0n, stopLossTriggerPrice: 0n } })).toThrow();
    expect(() => buildCancelProtectionAction({ account, book, protectionId: 1n << 64n })).toThrow();
    expect(() => buildProtectedOpenAction({ account, book, params, request: { isClose: true } as never })).toThrow("bounded");
  });
});
