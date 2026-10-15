import { describe, expect, it, vi } from "vitest";
import { decodeFunctionData, parseAbi, maxUint256, type Hex, type PublicClient } from "viem";
import { buildOwnerAccountClose, buildExecuteOrderV3, buildExecuteOrderBatchV3, buildRiskOffCleanupV3, buildTriggerProtection, buildRetryProtection, classifyKeeperHead, quoteExecutionNativeValue, orderRouterV3Abi, positionProtectionBookAbi, type OrderRequestV3 } from "../src/index.js";
const account = "0x1111111111111111111111111111111111111111";
const router = "0x2222222222222222222222222222222222222222";
const data: Hex[] = ["0xabcd"];
const request: OrderRequestV3 = { clientOrderId: `0x${"12".repeat(32)}`, side: 0, sizeDelta: 100n * 10n ** 18n, marginDelta: 0n, targetPrice: 100_000_000n, isClose: true,
  bounds: { submitBy: 100n, executionWindowSeconds: 60, allowedExecutionModes: 1, expectedConfigHash: `0x${"34".repeat(32)}`, maxExecutionBountyUsdc: 0n, maxExecutionNotionalUsdc: maxUint256, maxGrossAccountDebitUsdc: maxUint256, maxActionChargeUsdc: maxUint256, maxExplicitFeesUsdc: maxUint256, maxPostPositionSize: maxUint256, minPostSettlementBalanceUsdc: 0n, minPostPositionEquityUsdc: 0n, maxPostLeverageBps: 100_000 } };
describe("unpaid execution primitives", () => {
  it("keeps owner commitment at the original smart account and contains no funding call", () => {
    const outer = buildOwnerAccountClose(account, router, request);
    expect(outer.to).toBe(account); expect(outer.value).toBe(0n);
    const decoded = decodeFunctionData({ abi: parseAbi(["function execute(address dest,uint256 value,bytes data)"]), data: outer.data });
    expect(decoded.args.slice(0, 2)).toEqual([router, 0n]);
    expect(decodeFunctionData({ abi: orderRouterV3Abi, data: decoded.args[2] })).toMatchObject({ functionName: "commitOrder", args: [request] });
    expect(() => buildOwnerAccountClose(account, router, { ...request, isClose: false })).toThrow();
  });
  it("retains reward-independent head processing and strict expiry", () => {
    const input = { head: 1n, nextCommit: 2n, status: 1, now: 100n, deadline: 100n };
    expect(classifyKeeperHead(input)).toBe("simulate");
    expect(classifyKeeperHead({ ...input, now: 101n })).toBe("expire");
    expect(classifyKeeperHead({ ...input, nextCommit: 1n })).toBe("empty");
    expect(classifyKeeperHead({ ...input, head: 0n })).toBe("empty");
    expect(classifyKeeperHead({ ...input, status: 0 })).toBe("reconcile");
    expect(classifyKeeperHead({ ...input, deadline: 0n })).toBe("reconcile");
  });
  it("quotes execution and trigger policies separately without confusing USDC with native value", async () => {
    const readContract = vi.fn(async () => 13n);
    const client = { readContract } as unknown as Pick<PublicClient, "readContract">;
    expect(await quoteExecutionNativeValue(client, account, data)).toBe(13n);
    expect(readContract).toHaveBeenLastCalledWith(expect.objectContaining({ address: account, functionName: "getOrderExecutionFee", args: [data] }));
    await quoteExecutionNativeValue(client, account, data, true);
    expect(readContract).toHaveBeenLastCalledWith(expect.objectContaining({ functionName: "getUpdateFee" }));
    const call = buildExecuteOrderV3(router, 7n, data, 13n);
    expect(call.value).toBe(13n);
    expect(decodeFunctionData({ abi: orderRouterV3Abi, data: call.data })).toMatchObject({ functionName: "executeOrder", args: [7n, data] });
  });
  it("uses an inclusive last-order ID for batches and exact risk-off/trigger/retry selectors", () => {
    const batch = buildExecuteOrderBatchV3(router, 12n, data, 26n);
    expect(decodeFunctionData({ abi: parseAbi(["function executeOrderBatch(uint64 maxOrderId,bytes[] data) payable"]), data: batch.data }).args).toEqual([12n, data]);
    const cleanup = buildRiskOffCleanupV3(router, 7n);
    expect(cleanup.value).toBe(0n);
    expect(decodeFunctionData({ abi: parseAbi(["function clearRiskOffOrder(uint64 orderId)"]), data: cleanup.data }).args).toEqual([7n]);
    expect(decodeFunctionData({ abi: positionProtectionBookAbi, data: buildTriggerProtection(account, 4n, data, 13n).data })).toMatchObject({ functionName: "triggerPositionProtection", args: [4n, data] });
    expect(decodeFunctionData({ abi: positionProtectionBookAbi, data: buildRetryProtection(account, 4n).data })).toMatchObject({ functionName: "retryPositionProtectionClose", args: [4n] });
    expect(buildRetryProtection(account, 4n).value).toBe(0n);
  });
  it("rejects malformed IDs and negative oracle value", () => {
    for (const id of [-1n, 0n, 1n << 64n]) expect(() => buildExecuteOrderV3(router, id, [], 0n)).toThrow();
    expect(() => buildExecuteOrderV3(router, 1n, [], -1n)).toThrow();
  });
});
