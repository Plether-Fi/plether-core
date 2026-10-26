import { decodeErrorResult, encodeFunctionData, getAddress, maxUint256, parseAbi, type Hex, type Address, type ContractFunctionArgs } from "viem";
import { orderRouterV3Abi, orderRouterV3TraderAbi } from "./orderV3Abi.js";
import type { SmartAccountCall, PerpsActionPlan } from "./types.js";

export type OrderRequestV3 = ContractFunctionArgs<typeof orderRouterV3Abi, "nonpayable", "commitOrder">[0];

function validateSettlementFloor(request: OrderRequestV3): void {
  if (request.bounds.minPostSettlementBalanceAssets > 0n) {
    if (request.isClose) throw new Error("A positive settlement balance floor requires a flat opening order.");
    if (request.bounds.maxGrossAccountDebitAssets === maxUint256) {
      throw new Error("A positive settlement balance floor requires a finite maxGrossAccountDebitAssets.");
    }
  }
}

/** Builds one ordinary commitment call; no token approval, transfer, deposit or subsidy is included. */
export function buildCloseOrderV3(router: Address, request: OrderRequestV3): SmartAccountCall {
  if (!request.isClose || request.marginDelta !== 0n || request.sizeDelta <= 0n || request.sizeDelta % (100n * 10n ** 18n) !== 0n) {
    throw new Error("A close requires a positive lot-aligned size and zero marginDelta.");
  }
  validateSettlementFloor(request);
  return Object.freeze({ to: getAddress(router), value: 0n, data: encodeFunctionData({
    abi: orderRouterV3Abi, functionName: "commitOrder", args: [request],
  }) });
}

export function buildExpireOrderV3(router: Address, orderId: bigint): SmartAccountCall {
  if (orderId <= 0n) throw new Error("Order ID must be positive.");
  return Object.freeze({ to: getAddress(router), value: 0n, data: encodeFunctionData({
    abi: orderRouterV3Abi, functionName: "expireOrder", args: [orderId],
  }) });
}

/** Stable consumer copy; funding and health failures must not share the old 'underwater' message. */
export const closeFailureMessages = {
  carryFunding: "Accrued carry must be fully collected before a partial reduction. Review a full exit.",
  actionFunding: "This reduction cannot fund its charges while preserving the remaining position. Review a full exit.",
  residualHealth: "This reduction would leave the remaining position below its required margin.",
  sideMismatch: "The live position side no longer matches this close. Review the position before submitting another order.",
  reservationMismatch: "The order remains pending because its reservation does not match. After its deadline, expire it to resolve the queue entry.",
} as const;

const closeErrors = parseAbi([
  "error CfdEngine__PartialCloseCarryUnfunded(uint256 unpaidCarry)",
  "error CfdEngine__PartialCloseUnhealthy()",
  "error CfdEngine__TypedOrderFailure(uint8 category,uint8 code,bool isClose)",
  "error MarginClearinghouse__InvalidBountyReservation()",
  "error MarginClearinghouse__ActionReserveMismatch()",
  "error CfdEngineSettlementSidecar__SettlementMismatch()",
]);

/** Returns undefined for unrecognized data: unknown failures must never be treated as safe to consume. */
export function classifyCloseFailureV3(data: Hex): "carryFunding" | "actionFunding" | "residualHealth" | "sideMismatch" | "reservationMismatch" | undefined {
  try {
    const error = decodeErrorResult({ abi: closeErrors, data });
    switch (error.errorName) {
      case "CfdEngine__PartialCloseCarryUnfunded": return "carryFunding";
      case "CfdEngine__PartialCloseUnhealthy": return "residualHealth";
      case "CfdEngine__TypedOrderFailure":
        if (data.length !== 202 || error.args[0] !== 1 || !error.args[2]) return undefined;
        if (error.args[1] === 4) return "actionFunding";
        if (error.args[1] === 6) return "residualHealth";
        if (error.args[1] === 7) return "sideMismatch";
        return undefined;
      default: return "reservationMismatch";
    }
  } catch { return undefined; }
}

/** Encodes the complete immutable V3 order, including its submission and execution authority. */
export function buildPlaceOrderV3Action(input: {
  account: Address;
  orderRouter: Address;
  request: OrderRequestV3;
}): PerpsActionPlan {
  const { request } = input;
  if (request.bounds.submitBy <= 0n || request.bounds.submitBy >= 1n << 64n ||
      !Number.isInteger(request.bounds.executionWindowSeconds) || request.bounds.executionWindowSeconds <= 0 ||
      request.bounds.executionWindowSeconds > 3600 || request.sizeDelta <= 0n || request.targetPrice <= 0n ||
      (request.isClose && request.marginDelta !== 0n)) {
    throw new Error("Invalid V3 order timing or economic terms");
  }
  validateSettlementFloor(request);
  return Object.freeze({ kind: "place-order", account: getAddress(input.account), submissionDeadline: request.bounds.submitBy,
    calls: Object.freeze([Object.freeze({ to: getAddress(input.orderRouter), value: 0n,
      data: encodeFunctionData({ abi: orderRouterV3TraderAbi, functionName: "commitOrder", args: [request] }),
    })]),
  });
}
