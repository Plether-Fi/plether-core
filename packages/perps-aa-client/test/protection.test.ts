import { describe, expect, it } from "vitest";
import { decodeFunctionData } from "viem";
import { buildCreateProtectionAction, buildReplaceProtectionAction, buildCancelProtectionAction, buildAmendLatchedProtectionCloseLimitsAction, buildProtectedOpenAction } from "../src/protection.js";
import { positionProtectionBookAbi } from "../src/protectionAbi.js";

const account = "0x1111111111111111111111111111111111111111";
const book = "0x2222222222222222222222222222222222222222";
const closeLimits = {
  maxExecutionNotionalUsdc: 20_000_000n,
  maxGrossAccountDebitUsdc: 2_000_000n,
  maxActionChargeUsdc: 100_000n,
  maxExplicitFeesUsdc: 300_000n,
};
const params = { takeProfitTriggerPrice: 70_000_000n, stopLossTriggerPrice: 90_000_000n, closeLimits };

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
  it("encodes an owner amendment with exactly the supplied close limits", () => {
    const plan = buildAmendLatchedProtectionCloseLimitsAction({ account, book, protectionId: 42n, closeLimits });
    expect(plan.kind).toBe("amend-protection-close-limits");
    expect(plan.calls[0].value).toBe(0n);
    expect(decodeFunctionData({ abi: positionProtectionBookAbi, data: plan.calls[0].data })).toEqual({
      functionName: "amendLatchedPositionProtectionCloseLimits", args: [42n, closeLimits],
    });
  });
  it("rejects empty triggers, invalid IDs, and unbounded opens before signing", () => {
    expect(() => buildCreateProtectionAction({ account, book, params: { ...params, takeProfitTriggerPrice: 0n, stopLossTriggerPrice: 0n } })).toThrow();
    expect(() => buildCancelProtectionAction({ account, book, protectionId: 1n << 64n })).toThrow();
    expect(() => buildAmendLatchedProtectionCloseLimitsAction({ account, book, protectionId: 1n << 64n, closeLimits })).toThrow();
    expect(() => buildProtectedOpenAction({ account, book, params, request: { isClose: true } as never })).toThrow("bounded");
  });
  it("requires four explicit uint256 close ceilings for protection creation and amendment", () => {
    expect(() => buildCreateProtectionAction({ account, book, params: { ...params, closeLimits: undefined as never } })).toThrow("closeLimits.maxExecutionNotionalUsdc");
    for (const field of Object.keys(closeLimits) as (keyof typeof closeLimits)[]) {
      for (const invalid of [undefined, -1n, 1n << 256n]) {
        const changed = { ...closeLimits, [field]: invalid } as typeof closeLimits;
        expect(() => buildReplaceProtectionAction({ account, book, protectionId: 1n, params: { ...params, closeLimits: changed } })).toThrow(`closeLimits.${field}`);
        expect(() => buildAmendLatchedProtectionCloseLimitsAction({ account, book, protectionId: 1n, closeLimits: changed })).toThrow(`closeLimits.${field}`);
      }
    }
  });
});
