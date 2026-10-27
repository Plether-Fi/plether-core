import { describe, expect, it } from "vitest";
import { decodeFunctionData, maxUint256 } from "viem";
import { buildCreateProtectionAction, buildReplaceProtectionAction, buildCancelProtectionAction, buildCancelProtectionAndCloseAction, buildAmendLatchedProtectionCloseLimitsAction, buildProtectedOpenAction } from "../src/protection.js";
import type { OrderRequestV3 } from "../src/orderV3.js";
import { positionProtectionBookAbi } from "../src/protectionAbi.js";

const account = "0x1111111111111111111111111111111111111111";
const book = "0x2222222222222222222222222222222222222222";
const closeLimits = {
  maxExecutionNotionalAssets: 20_000_000n,
  maxGrossAccountDebitAssets: 2_000_000n,
  maxActionChargeAssets: 100_000n,
  maxExplicitFeesAssets: 300_000n,
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
    expect(() => buildCreateProtectionAction({ account, book, params: { ...params, closeLimits: undefined as never } })).toThrow("closeLimits.maxExecutionNotionalAssets");
    for (const field of Object.keys(closeLimits) as (keyof typeof closeLimits)[]) {
      for (const invalid of [undefined, -1n, 1n << 256n]) {
        const changed = { ...closeLimits, [field]: invalid } as typeof closeLimits;
        expect(() => buildReplaceProtectionAction({ account, book, protectionId: 1n, params: { ...params, closeLimits: changed } })).toThrow(`closeLimits.${field}`);
        expect(() => buildAmendLatchedProtectionCloseLimitsAction({ account, book, protectionId: 1n, closeLimits: changed })).toThrow(`closeLimits.${field}`);
      }
    }
  });
});

describe("atomic protection cancellation and close", () => {
  const request: OrderRequestV3 = {
    clientOrderId: `0x${"ab".repeat(32)}`, side: 0, sizeDelta: 200n * 10n ** 18n,
    marginDelta: 0n, targetPrice: 80_000_000n, isClose: true,
    bounds: {
      submitBy: 1_900_000_000n, executionWindowSeconds: 60, allowedExecutionModes: 7,
      expectedConfigHash: `0x${"cd".repeat(32)}`, maxExecutionBountyAssets: 0n,
      ...closeLimits, maxPostPositionSize: 0n, minPostSettlementBalanceAssets: 0n,
      minPostPositionEquityAssets: 500_000n, maxPostLeverageBps: 50_000,
    },
  };
  const build = (changed: OrderRequestV3 = request, protectionId = 42n) =>
    buildCancelProtectionAndCloseAction({ account, book, protectionId, request: changed });

  it("encodes one zero-value Book call preserving the full request and submission deadline", () => {
    const plan = build();
    expect(plan.kind).toBe("cancel-protection-and-close");
    expect(plan.account).toBe(account);
    expect(plan.submissionDeadline).toBe(request.bounds.submitBy);
    expect(plan.calls).toHaveLength(1);
    expect(plan.calls[0].to).toBe(book);
    expect(plan.calls[0].value).toBe(0n);
    expect(decodeFunctionData({ abi: positionProtectionBookAbi, data: plan.calls[0].data })).toEqual({
      functionName: "cancelPositionProtectionAndCommitClose", args: [42n, request],
    });
  });

  it.each([1, 2, 3, 4, 5, 6, 7])("accepts the authorized execution mode mask %s", allowedExecutionModes => {
    const changed = { ...request, side: 1 as const, bounds: { ...request.bounds, allowedExecutionModes } };
    expect(decodeFunctionData({ abi: positionProtectionBookAbi, data: build(changed).calls[0].data }).args).toEqual([42n, changed]);
  });

  it("retains explicit unlimited ceilings and the maximum uint64 protection ID", () => {
    const changed = { ...request, bounds: { ...request.bounds, maxExecutionNotionalAssets: maxUint256,
      maxGrossAccountDebitAssets: maxUint256, maxActionChargeAssets: 0n, maxExplicitFeesAssets: maxUint256 } };
    const protectionId = (1n << 64n) - 1n;
    expect(decodeFunctionData({ abi: positionProtectionBookAbi, data: build(changed, protectionId).calls[0].data }).args).toEqual([protectionId, changed]);
  });

  it.each([0n, -1n, 1n << 64n, 42 as never])("rejects invalid protection ID %s", protectionId => {
    expect(() => build(request, protectionId)).toThrow("Invalid protection ID");
  });

  it.each([
    { isClose: false }, { marginDelta: 1n }, { sizeDelta: 0n }, { sizeDelta: -100n * 10n ** 18n },
    { sizeDelta: 10n ** 18n }, { sizeDelta: 200n * 10n ** 18n + 1n },
  ])("rejects a non-close, nonzero margin or invalid lot size: %o", change => {
    expect(() => build({ ...request, ...change })).toThrow("positive lot-aligned size and zero marginDelta");
  });

  it.each([
    { side: 2 }, { targetPrice: 0n }, { targetPrice: -1n },
    { clientOrderId: `0x${"00".repeat(32)}` },
    { clientOrderId: `0x504c455448455221${"01".repeat(24)}` },
    { clientOrderId: "0xab" },
  ])("rejects malformed or reserved order authority: %o", change => {
    expect(() => build({ ...request, ...change } as OrderRequestV3)).toThrow("fresh bounded V3 closing request");
  });

  it.each([
    { submitBy: 0n }, { submitBy: 1n << 64n },
    { executionWindowSeconds: 0 }, { executionWindowSeconds: 3601 }, { executionWindowSeconds: 1.5 },
    { allowedExecutionModes: 0 }, { allowedExecutionModes: 8 }, { allowedExecutionModes: -1 }, { allowedExecutionModes: 1.5 },
    { expectedConfigHash: `0x${"00".repeat(32)}` }, { expectedConfigHash: "0xcd" },
    { maxPostLeverageBps: 0 }, { maxPostLeverageBps: 0x1_0000_0000 },
  ])("rejects invalid bounded authority: %o", change => {
    expect(() => build({ ...request, bounds: { ...request.bounds, ...change } } as OrderRequestV3)).toThrow("fresh bounded V3 closing request");
  });

  it("rejects a positive settlement floor without clearing it", () => {
    const changed = { ...request, bounds: { ...request.bounds, minPostSettlementBalanceAssets: 1n } };
    expect(() => build(changed)).toThrow("zero settlement balance floor");
    expect(changed.bounds.minPostSettlementBalanceAssets).toBe(1n);
  });

  it("requires explicit uint256 financial bounds without inserting defaults", () => {
    for (const field of ["maxExecutionBountyAssets", ...Object.keys(closeLimits), "maxPostPositionSize", "minPostPositionEquityAssets"]) {
      for (const invalid of [undefined, -1n, 1n << 256n]) {
        expect(() => build({ ...request, bounds: { ...request.bounds, [field]: invalid } } as OrderRequestV3)).toThrow(`bounds.${field}`);
      }
    }
  });
});
