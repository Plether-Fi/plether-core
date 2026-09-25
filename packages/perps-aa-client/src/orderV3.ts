import { decodeErrorResult, encodeFunctionData, getAddress, parseAbi, type Hex, type Address, type ContractFunctionArgs } from "viem";
import { orderRouterV3Abi } from "./orderV3Abi.js";
import type { SmartAccountCall } from "./types.js";

export const CloseMode = { Standard: 0, CallerPaidFullExit: 1 } as const;
export type OrderRequestV3 = ContractFunctionArgs<typeof orderRouterV3Abi, "nonpayable", "commitOrder">[0];

/** Builds one ordinary commitment call; no token approval, transfer, deposit or subsidy is included. */
export function buildCloseOrderV3(router: Address, request: OrderRequestV3): SmartAccountCall {
  if (!request.isClose || request.marginDelta !== 0n || request.sizeDelta <= 0n || request.sizeDelta % (100n * 10n ** 18n) !== 0n) {
    throw new Error("A close requires a positive lot-aligned size and zero marginDelta.");
  }
  if (request.closeMode !== CloseMode.Standard && request.closeMode !== CloseMode.CallerPaidFullExit) {
    throw new Error("Unknown close mode.");
  }
  if (request.closeMode === CloseMode.CallerPaidFullExit && request.bounds.maxPostPositionSize !== 0n) {
    throw new Error("Caller-paid full exit requires a zero post-position-size bound.");
  }
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
  bountyFunding: "Eligible collateral cannot back the keeper reward. Prepare a caller-paid full exit.",
  carryFunding: "Accrued carry must be fully collected before a partial reduction. Review a full exit.",
  actionFunding: "This reduction cannot fund its charges while preserving the remaining position. Review a full exit.",
  residualHealth: "This reduction would leave the remaining position below its required margin.",
  callerPaid: "No keeper reward is reserved. You or another executor must pay transaction gas and oracle fees; automatic execution is not guaranteed.",
  reservationMismatch: "The order remains pending because its reservation does not match. After its deadline, expire it to resolve the queue entry.",
} as const;

const closeErrors = parseAbi([
  "error CfdEngine__InsufficientCloseOrderBountyBacking(uint256 required,uint256 available,uint256 unpaidCarry)",
  "error CfdEngine__PartialCloseCarryUnfunded(uint256 unpaidCarry)",
  "error CfdEngine__PartialCloseUnhealthy()",
  "error CfdEngine__TypedOrderFailure(uint8 category,uint8 code,bool isClose)",
  "error MarginClearinghouse__InvalidBountyReservation()",
  "error MarginClearinghouse__ActionReserveMismatch()",
  "error CfdEngineSettlementSidecar__SettlementMismatch()",
]);

/** Returns undefined for unrecognized data: unknown failures must never be treated as safe to consume. */
export function classifyCloseFailureV3(data: Hex): "bountyFunding" | "carryFunding" | "actionFunding" | "residualHealth" | "reservationMismatch" | undefined {
  try {
    const error = decodeErrorResult({ abi: closeErrors, data });
    switch (error.errorName) {
      case "CfdEngine__InsufficientCloseOrderBountyBacking": return "bountyFunding";
      case "CfdEngine__PartialCloseCarryUnfunded": return "carryFunding";
      case "CfdEngine__PartialCloseUnhealthy": return "residualHealth";
      case "CfdEngine__TypedOrderFailure":
        if (data.length !== 202 || error.args[0] !== 1 || !error.args[2]) return undefined;
        if (error.args[1] === 4) return "actionFunding";
        if (error.args[1] === 6) return "residualHealth";
        return undefined;
      default: return "reservationMismatch";
    }
  } catch { return undefined; }
}
