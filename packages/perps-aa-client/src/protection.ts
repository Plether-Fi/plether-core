import { encodeFunctionData, getAddress, maxUint256, type Address, type ContractFunctionArgs } from "viem";
import { positionProtectionBookAbi } from "./protectionAbi.js";
import type { OrderRequestV3 } from "./orderV3.js";
import type { PerpsActionKind, PerpsActionPlan } from "./types.js";

export type ProtectedOpenRequest = ContractFunctionArgs<typeof positionProtectionBookAbi, "nonpayable", "commitOpenOrderWithProtection">[0];
export interface CloseFinancialLimits {
  maxExecutionNotionalUsdc: bigint;
  maxGrossAccountDebitUsdc: bigint;
  maxActionChargeUsdc: bigint;
  maxExplicitFeesUsdc: bigint;
}

export interface PositionProtectionParams {
  takeProfitTriggerPrice: bigint;
  stopLossTriggerPrice: bigint;
  closeLimits: CloseFinancialLimits;
}

function validateCloseLimits(limits: CloseFinancialLimits): void {
  for (const field of ["maxExecutionNotionalUsdc", "maxGrossAccountDebitUsdc", "maxActionChargeUsdc", "maxExplicitFeesUsdc"] as const) {
    const value = limits?.[field];
    if (typeof value !== "bigint" || value < 0n || value > maxUint256) {
      throw new Error(`Protection closeLimits.${field} must be an explicit uint256 bigint`);
    }
  }
}

function validateParams(params: PositionProtectionParams): void {
  const prices = [params.takeProfitTriggerPrice, params.stopLossTriggerPrice];
  if (prices.some(price => typeof price !== "bigint" || price < 0n || price > maxUint256) || prices.every(price => price === 0n)) {
    throw new Error("At least one valid protection trigger is required");
  }
  validateCloseLimits(params.closeLimits);
}

function validateId(id: bigint): void {
  if (typeof id !== "bigint" || id <= 0n || id >= 1n << 64n) throw new Error("Invalid protection ID");
}

function action(kind: PerpsActionKind, account: Address, book: Address, data: `0x${string}`): PerpsActionPlan {
  return Object.freeze({ kind, account: getAddress(account), calls: Object.freeze([
    Object.freeze({ to: getAddress(book), value: 0n, data }),
  ]) });
}

export function buildCreateProtectionAction(input: { account: Address; book: Address; params: PositionProtectionParams }): PerpsActionPlan {
  validateParams(input.params);
  return action("create-protection", input.account, input.book, encodeFunctionData({ abi: positionProtectionBookAbi, functionName: "createPositionProtection", args: [input.params] }));
}

export function buildReplaceProtectionAction(input: { account: Address; book: Address; protectionId: bigint; params: PositionProtectionParams }): PerpsActionPlan {
  validateId(input.protectionId);
  validateParams(input.params);
  return action("replace-protection", input.account, input.book, encodeFunctionData({ abi: positionProtectionBookAbi, functionName: "replacePositionProtection", args: [input.protectionId, input.params] }));
}

export function buildCancelProtectionAction(input: { account: Address; book: Address; protectionId: bigint }): PerpsActionPlan {
  validateId(input.protectionId);
  return action("cancel-protection", input.account, input.book, encodeFunctionData({ abi: positionProtectionBookAbi, functionName: "cancelPositionProtection", args: [input.protectionId] }));
}

/**
 * Atomically cancels an Armed protection and queues the caller's bounded full close.
 * Ownership, protection status, live side/size, client-ID freshness and the current
 * configuration are checked onchain; this pure builder does not read account state.
 */
export function buildCancelProtectionAndCloseAction(input: { account: Address; book: Address; protectionId: bigint; request: OrderRequestV3 }): PerpsActionPlan {
  validateId(input.protectionId);
  const { request } = input;
  if (request.isClose !== true || request.marginDelta !== 0n ||
      typeof request.sizeDelta !== "bigint" || request.sizeDelta <= 0n || request.sizeDelta > maxUint256 ||
      request.sizeDelta % (100n * 10n ** 18n) !== 0n) {
    throw new Error("A protection close requires a positive lot-aligned size and zero marginDelta.");
  }
  const { bounds } = request;
  if ((request.side !== 0 && request.side !== 1) ||
      typeof request.targetPrice !== "bigint" || request.targetPrice <= 0n || request.targetPrice > maxUint256 ||
      !/^0x[0-9a-f]{64}$/i.test(request.clientOrderId) || /^0x0{64}$/i.test(request.clientOrderId) ||
      request.clientOrderId.toLowerCase().startsWith("0x504c455448455221") ||
      !/^0x[0-9a-f]{64}$/i.test(bounds.expectedConfigHash) || /^0x0{64}$/i.test(bounds.expectedConfigHash) ||
      typeof bounds.submitBy !== "bigint" || bounds.submitBy <= 0n || bounds.submitBy >= 1n << 64n ||
      !Number.isInteger(bounds.executionWindowSeconds) || bounds.executionWindowSeconds <= 0 || bounds.executionWindowSeconds > 3600 ||
      !Number.isInteger(bounds.allowedExecutionModes) || bounds.allowedExecutionModes < 1 || bounds.allowedExecutionModes > 7 ||
      !Number.isInteger(bounds.maxPostLeverageBps) || bounds.maxPostLeverageBps <= 0 || bounds.maxPostLeverageBps > 0xffff_ffff) {
    throw new Error("Protection cancellation and close requires a fresh bounded V3 closing request.");
  }
  if (bounds.minPostSettlementBalanceUsdc !== 0n) {
    throw new Error("A protection close requires a zero settlement balance floor.");
  }
  for (const field of ["maxExecutionBountyUsdc", "maxExecutionNotionalUsdc", "maxGrossAccountDebitUsdc",
    "maxActionChargeUsdc", "maxExplicitFeesUsdc", "maxPostPositionSize", "minPostPositionEquityUsdc"] as const) {
    const value = bounds[field];
    if (typeof value !== "bigint" || value < 0n || value > maxUint256) {
      throw new Error(`Protection close bounds.${field} must be an explicit uint256 bigint`);
    }
  }
  return Object.freeze({ ...action("cancel-protection-and-close", input.account, input.book, encodeFunctionData({
    abi: positionProtectionBookAbi, functionName: "cancelPositionProtectionAndCommitClose", args: [input.protectionId, request],
  })), submissionDeadline: bounds.submitBy });
}

export function buildAmendLatchedProtectionCloseLimitsAction(input: { account: Address; book: Address; protectionId: bigint; closeLimits: CloseFinancialLimits }): PerpsActionPlan {
  validateId(input.protectionId);
  validateCloseLimits(input.closeLimits);
  return action("amend-protection-close-limits", input.account, input.book, encodeFunctionData({ abi: positionProtectionBookAbi, functionName: "amendLatchedPositionProtectionCloseLimits", args: [input.protectionId, input.closeLimits] }));
}

export function buildProtectedOpenAction(input: { account: Address; book: Address; request: ProtectedOpenRequest; params: PositionProtectionParams }): PerpsActionPlan {
  validateParams(input.params);
  const { request } = input;
  if (request.isClose || request.sizeDelta <= 0n || request.targetPrice <= 0n ||
      (request.side !== 0 && request.side !== 1) ||
      /^0x0{64}$/i.test(request.clientOrderId) || request.clientOrderId.toLowerCase().startsWith("0x504c455448455221") ||
      /^0x0{64}$/i.test(request.bounds.expectedConfigHash) || request.bounds.submitBy <= 0n ||
      !Number.isInteger(request.bounds.executionWindowSeconds) || request.bounds.executionWindowSeconds <= 0 || request.bounds.executionWindowSeconds > 3600 ||
      ![1, 2, 4].includes(request.bounds.allowedExecutionModes) || request.bounds.maxPostLeverageBps <= 0) {
    throw new Error("Protected opens require a fresh bounded V3 opening request");
  }
  if (request.bounds.minPostSettlementBalanceUsdc > 0n && request.bounds.maxGrossAccountDebitUsdc === maxUint256) {
    throw new Error("A positive settlement balance floor requires a finite maxGrossAccountDebitUsdc.");
  }
  return Object.freeze({ ...action("place-protected-order", input.account, input.book, encodeFunctionData({ abi: positionProtectionBookAbi, functionName: "commitOpenOrderWithProtection", args: [request, input.params] })), submissionDeadline: request.bounds.submitBy });
}
