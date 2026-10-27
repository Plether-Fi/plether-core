import { encodeFunctionData, getAddress, type Address, type Hex } from "viem";

import {
  cfdEngineTraderAbi,
  eip3009ReceiveWithAuthorizationAbi,
  erc20ApproveAbi,
  erc20TransferAbi,
  marginClearinghouseTraderAbi,
  orderRouterTraderAbi,
} from "./abis.js";
import {
  splitEip3009Signature,
  validateAuthorization,
  type ReceiveWithAuthorization,
} from "./eip3009.js";
import {
  InvalidPerpsActionError,
  UnsupportedPerpsActionError,
} from "./errors.js";
import type { PerpsActionKind, PerpsActionPlan, SmartAccountCall } from "./types.js";

export type PerpsSide = "BULL" | "BEAR";

function address(value: Address, label: string): Address {
  try {
    return getAddress(value);
  } catch (cause) {
    throw new InvalidPerpsActionError(`${label} is not a valid address.`, cause);
  }
}

function positive(value: bigint, label: string): void {
  if (value <= 0n) {
    throw new InvalidPerpsActionError(`${label} must be greater than zero.`);
  }
}

function nonNegative(value: bigint, label: string): void {
  if (value < 0n) {
    throw new InvalidPerpsActionError(`${label} cannot be negative.`);
  }
}

function call(to: Address, data: Hex): SmartAccountCall {
  return Object.freeze({ to, value: 0n, data });
}

function plan(
  kind: PerpsActionKind,
  account: Address,
  calls: readonly SmartAccountCall[],
): PerpsActionPlan {
  return Object.freeze({ kind, account: address(account, "Smart account"), calls });
}

export interface BuildAuthorizedDepositInput {
  readonly account: Address;
  /** The configured six-decimal settlement token. */
  readonly settlementToken: Address;
  readonly clearinghouse: Address;
  readonly authorization: ReceiveWithAuthorization;
  readonly authorizationSignature: Hex;
}

/**
 * Creates one atomic smart-account batch:
 * settlementToken.receiveWithAuthorization(owner -> account), approve, depositMargin.
 * Requires verified EIP-3009 support; MockUSDG does not support this route.
 */
export function buildAuthorizedDepositAction(
  input: BuildAuthorizedDepositInput,
): PerpsActionPlan {
  const account = address(input.account, "Smart account");
  const settlementToken = address(input.settlementToken, "Settlement token");
  const clearinghouse = address(input.clearinghouse, "Clearinghouse");
  validateAuthorization(input.authorization);

  if (address(input.authorization.to, "Authorization recipient") !== account) {
    throw new InvalidPerpsActionError(
      "EIP-3009 authorization recipient must be the canonical smart account.",
    );
  }

  const { v, r, s } = splitEip3009Signature(input.authorizationSignature);
  const amount = input.authorization.value;

  return plan("deposit", account, [
    call(
      settlementToken,
      encodeFunctionData({
        abi: eip3009ReceiveWithAuthorizationAbi,
        functionName: "receiveWithAuthorization",
        args: [
          address(input.authorization.from, "Authorization owner"),
          account,
          amount,
          input.authorization.validAfter,
          input.authorization.validBefore,
          input.authorization.nonce,
          v,
          r,
          s,
        ],
      }),
    ),
    call(
      settlementToken,
      encodeFunctionData({
        abi: erc20ApproveAbi,
        functionName: "approve",
        args: [clearinghouse, amount],
      }),
    ),
    call(
      clearinghouse,
      encodeFunctionData({
        abi: marginClearinghouseTraderAbi,
        functionName: "depositMargin",
        args: [amount],
      }),
    ),
  ]);
}

/** Deposit settlement tokens already held by the smart account, without a token authorization signature. */
export function buildSmartAccountBalanceDepositAction(input: {
  readonly account: Address;
  /** The configured six-decimal settlement token. */
  readonly settlementToken: Address;
  readonly clearinghouse: Address;
  readonly amount: bigint;
}): PerpsActionPlan {
  positive(input.amount, "Deposit amount");
  const account = address(input.account, "Smart account");
  const settlementToken = address(input.settlementToken, "Settlement token");
  const clearinghouse = address(input.clearinghouse, "Clearinghouse");

  return plan("deposit", account, [
    call(
      settlementToken,
      encodeFunctionData({
        abi: erc20ApproveAbi,
        functionName: "approve",
        args: [clearinghouse, input.amount],
      }),
    ),
    call(
      clearinghouse,
      encodeFunctionData({
        abi: marginClearinghouseTraderAbi,
        functionName: "depositMargin",
        args: [input.amount],
      }),
    ),
  ]);
}

/** @deprecated Historical scalar-router helper. V3 deployments require buildPlaceOrderV3Action. */
export function buildPlaceOrderAction(input: {
  readonly account: Address;
  readonly orderRouter: Address;
  readonly side: PerpsSide;
  readonly sizeDelta: bigint;
  readonly marginDelta: bigint;
  readonly targetPrice: bigint;
  readonly isClose: boolean;
}): PerpsActionPlan {
  positive(input.sizeDelta, "Order size");
  nonNegative(input.marginDelta, "Order margin");
  nonNegative(input.targetPrice, "Target price");
  if (input.isClose && input.marginDelta !== 0n) {
    throw new InvalidPerpsActionError(
      "Close orders must use zero margin delta.",
    );
  }

  const account = address(input.account, "Smart account");
  const orderRouter = address(input.orderRouter, "Order router");
  const side = input.side === "BULL" ? 0 : input.side === "BEAR" ? 1 : undefined;
  if (side === undefined) {
    throw new InvalidPerpsActionError("Order side must be BULL or BEAR.");
  }

  return plan("place-order", account, [
    call(
      orderRouter,
      encodeFunctionData({
        abi: orderRouterTraderAbi,
        functionName: "commitOrder",
        args: [side, input.sizeDelta, input.marginDelta, input.targetPrice, input.isClose],
      }),
    ),
  ]);
}

/**
 * The current delayed-order protocol intentionally exposes no trader cancellation.
 * Keep this function so product code cannot accidentally invent a direct-call path.
 */
export function buildCancelOrderAction(_input: {
  readonly account: Address;
  readonly orderRouter: Address;
  readonly orderId: bigint;
}): never {
  throw new UnsupportedPerpsActionError(
    "Committed perps orders are binding and cannot be cancelled by traders. Wait for keeper finalization.",
  );
}

export function buildAddMarginAction(input: {
  readonly account: Address;
  readonly cfdEngine: Address;
  readonly amount: bigint;
}): PerpsActionPlan {
  positive(input.amount, "Margin amount");
  const account = address(input.account, "Smart account");
  const cfdEngine = address(input.cfdEngine, "CFD engine");

  return plan("add-margin", account, [
    call(
      cfdEngine,
      encodeFunctionData({
        abi: cfdEngineTraderAbi,
        functionName: "addMargin",
        args: [account, input.amount],
      }),
    ),
  ]);
}

export function buildWithdrawAction(input: {
  readonly account: Address;
  readonly clearinghouse: Address;
  readonly amount: bigint;
}): PerpsActionPlan {
  positive(input.amount, "Withdrawal amount");
  const account = address(input.account, "Smart account");
  const clearinghouse = address(input.clearinghouse, "Clearinghouse");

  return plan("withdraw", account, [
    call(
      clearinghouse,
      encodeFunctionData({
        abi: marginClearinghouseTraderAbi,
        functionName: "withdrawMargin",
        args: [input.amount],
      }),
    ),
  ]);
}

/**
 * Atomically withdraws from the clearinghouse to the smart account, then sends
 * that exact settlement-token amount to the account's externally owned wallet.
 *
 * The sponsor backend must independently prove `owner` is the registered owner
 * of `account`; accepting an arbitrary recipient would create a sponsored token
 * transfer primitive.
 */
export function buildWithdrawToOwnerAction(input: {
  readonly account: Address;
  readonly owner: Address;
  /** The configured six-decimal settlement token. */
  readonly settlementToken: Address;
  readonly clearinghouse: Address;
  readonly amount: bigint;
}): PerpsActionPlan {
  positive(input.amount, "Withdrawal amount");
  const account = address(input.account, "Smart account");
  const owner = address(input.owner, "Smart-account owner");
  const settlementToken = address(input.settlementToken, "Settlement token");
  const clearinghouse = address(input.clearinghouse, "Clearinghouse");

  if (account === owner) {
    throw new InvalidPerpsActionError(
      "Owner and account share one address; use buildWithdrawAction for EIP-7702 same-address mode.",
    );
  }

  return plan("withdraw-to-owner", account, [
    call(
      clearinghouse,
      encodeFunctionData({
        abi: marginClearinghouseTraderAbi,
        functionName: "withdrawMargin",
        args: [input.amount],
      }),
    ),
    call(
      settlementToken,
      encodeFunctionData({
        abi: erc20TransferAbi,
        functionName: "transfer",
        args: [owner, input.amount],
      }),
    ),
  ]);
}

export function buildSettleTraderClaimAction(input: {
  readonly account: Address;
  readonly cfdEngine: Address;
}): PerpsActionPlan {
  const account = address(input.account, "Smart account");
  const cfdEngine = address(input.cfdEngine, "CFD engine");

  return plan("settle-claim", account, [
    call(
      cfdEngine,
      encodeFunctionData({
        abi: cfdEngineTraderAbi,
        functionName: "settleTraderClaim",
        args: [account],
      }),
    ),
  ]);
}
