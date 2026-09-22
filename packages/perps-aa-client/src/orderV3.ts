import { encodeFunctionData, getAddress, type Address, type ContractFunctionArgs } from "viem";
import { orderRouterV3TraderAbi } from "./orderV3Abi.js";
import type { PerpsActionPlan } from "./types.js";

export type OrderRequestV3 = ContractFunctionArgs<typeof orderRouterV3TraderAbi, "nonpayable", "commitOrder">[0];

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
  return Object.freeze({ kind: "place-order", account: getAddress(input.account), submissionDeadline: request.bounds.submitBy,
    calls: Object.freeze([Object.freeze({ to: getAddress(input.orderRouter), value: 0n,
      data: encodeFunctionData({ abi: orderRouterV3TraderAbi, functionName: "commitOrder", args: [request] }),
    })]),
  });
}
