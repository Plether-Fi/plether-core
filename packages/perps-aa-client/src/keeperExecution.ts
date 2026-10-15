import { encodeFunctionData, getAddress, parseAbi, type Address, type Hex, type PublicClient } from "viem";
import { orderRouterV3Abi } from "./orderV3Abi.js";
import { positionProtectionBookAbi } from "./protectionAbi.js";
import { buildCloseOrderV3, type OrderRequestV3 } from "./orderV3.js";
import type { SmartAccountCall } from "./types.js";

const executionAbi = parseAbi([
  "function executeOrderBatch(uint64 maxOrderId,bytes[] updateData) payable returns ((uint64 nextOrderId,uint32 terminalCount,uint8 stopReason))",
  "function clearRiskOffOrder(uint64 orderId)",
]);
const oracleAbi = parseAbi(["function getOrderExecutionFee(bytes[] updateData) view returns (uint256)", "function getUpdateFee(bytes[] updateData) view returns (uint256)"]);
const accountAbi = parseAbi(["function execute(address dest,uint256 value,bytes data)"]);
function id(value: bigint): void {
  if (value <= 0n || value >= 1n << 64n) throw new Error("Expected a positive uint64 ID or count.");
}
function call(to: Address, value: bigint, data: Hex): SmartAccountCall {
  if (value < 0n) throw new Error("Native value cannot be negative.");
  return Object.freeze({ to: getAddress(to), value, data });
}

/** No reward filter. The initial head=nextCommit=1 sentinel is an empty queue. */
export function classifyKeeperHead(input: {
  head: bigint; nextCommit: bigint; status: number; now: bigint; deadline: bigint;
}): "empty" | "reconcile" | "expire" | "simulate" {
  if (input.head === 0n || input.head >= input.nextCommit) return "empty";
  if (input.status !== 1 || input.deadline === 0n) return "reconcile";
  return input.now > input.deadline ? "expire" : "simulate";
}

/** Caller must verify the deployed account's owner, factory, implementation and chain before signing. */
export function buildOwnerAccountClose(account: Address, router: Address, request: OrderRequestV3): SmartAccountCall {
  const inner = buildCloseOrderV3(router, request);
  return call(account, 0n, encodeFunctionData({ abi: accountAbi, functionName: "execute", args: [inner.to, inner.value, inner.data] }));
}

/** Quote against the actual bound oracle. Fee policy and caller gas caps remain separate. */
export async function quoteExecutionNativeValue(client: Pick<PublicClient, "readContract">, oracle: Address, data: readonly Hex[], trigger = false): Promise<bigint> {
  return client.readContract({ address: oracle, abi: oracleAbi, functionName: trigger ? "getUpdateFee" : "getOrderExecutionFee", args: [data] });
}
export function buildExecuteOrderV3(router: Address, orderId: bigint, data: readonly Hex[], nativeValue: bigint): SmartAccountCall {
  id(orderId);
  return call(router, nativeValue, encodeFunctionData({ abi: orderRouterV3Abi, functionName: "executeOrder", args: [orderId, data] }));
}
export function buildExecuteOrderBatchV3(router: Address, maxOrderId: bigint, data: readonly Hex[], nativeValue: bigint): SmartAccountCall {
  id(maxOrderId);
  return call(router, nativeValue, encodeFunctionData({ abi: executionAbi, functionName: "executeOrderBatch", args: [maxOrderId, data] }));
}
export function buildRiskOffCleanupV3(router: Address, maxOrderId: bigint): SmartAccountCall {
  id(maxOrderId);
  return call(router, 0n, encodeFunctionData({ abi: executionAbi, functionName: "clearRiskOffOrder", args: [maxOrderId] }));
}
export function buildTriggerProtection(book: Address, protectionId: bigint, data: readonly Hex[], nativeValue: bigint): SmartAccountCall {
  id(protectionId);
  return call(book, nativeValue, encodeFunctionData({ abi: positionProtectionBookAbi, functionName: "triggerPositionProtection", args: [protectionId, data] }));
}
export function buildRetryProtection(book: Address, protectionId: bigint): SmartAccountCall {
  id(protectionId);
  return call(book, 0n, encodeFunctionData({ abi: positionProtectionBookAbi, functionName: "retryPositionProtectionClose", args: [protectionId] }));
}
