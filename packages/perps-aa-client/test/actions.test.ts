import { describe, expect, it } from "vitest";
import { decodeFunctionData, type Address, type Hex } from "viem";

import {
  buildAddMarginAction,
  buildAuthorizedDepositAction,
  buildCancelOrderAction,
  buildPlaceOrderAction,
  buildReceiveWithAuthorizationTypedData,
  buildSettleTraderClaimAction,
  buildWithdrawAction,
  buildWithdrawToOwnerAction,
  cfdEngineTraderAbi,
  eip3009ReceiveWithAuthorizationAbi,
  erc20ApproveAbi,
  erc20TransferAbi,
  marginClearinghouseTraderAbi,
  orderRouterTraderAbi,
  PerpsClientError,
} from "../src/index.js";

const owner = "0x1111111111111111111111111111111111111111" as Address;
const account = "0x2222222222222222222222222222222222222222" as Address;
const usdc = "0x3333333333333333333333333333333333333333" as Address;
const clearinghouse = "0x4444444444444444444444444444444444444444" as Address;
const router = "0x5555555555555555555555555555555555555555" as Address;
const engine = "0x6666666666666666666666666666666666666666" as Address;
const nonce = `0x${"ab".repeat(32)}` as Hex;
const signature = `0x${"11".repeat(32)}${"22".repeat(32)}1b` as Hex;

describe("perps action builders", () => {
  it("builds the atomic authorized-deposit batch", () => {
    const action = buildAuthorizedDepositAction({
      account,
      usdc,
      clearinghouse,
      authorization: {
        from: owner,
        to: account,
        value: 25_000_000n,
        validAfter: 10n,
        validBefore: 1_000n,
        nonce,
      },
      authorizationSignature: signature,
    });

    expect(action.kind).toBe("deposit");
    expect(action.account).toBe(account);
    expect(action.calls).toHaveLength(3);
    expect(action.calls.map((item) => item.to)).toEqual([usdc, usdc, clearinghouse]);
    expect(action.calls.every((item) => item.value === 0n)).toBe(true);

    const receive = decodeFunctionData({
      abi: eip3009ReceiveWithAuthorizationAbi,
      data: action.calls[0]!.data,
    });
    expect(receive.functionName).toBe("receiveWithAuthorization");
    expect(receive.args?.slice(0, 6)).toEqual([
      owner,
      account,
      25_000_000n,
      10n,
      1_000n,
      nonce,
    ]);
    expect(receive.args?.[6]).toBe(27);

    const approve = decodeFunctionData({
      abi: erc20ApproveAbi,
      data: action.calls[1]!.data,
    });
    expect(approve.args).toEqual([clearinghouse, 25_000_000n]);

    const deposit = decodeFunctionData({
      abi: marginClearinghouseTraderAbi,
      data: action.calls[2]!.data,
    });
    expect(deposit.functionName).toBe("depositMargin");
    expect(deposit.args).toEqual([25_000_000n]);
  });

  it("rejects an authorization sent to an EOA instead of the canonical account", () => {
    expect(() =>
      buildAuthorizedDepositAction({
        account,
        usdc,
        clearinghouse,
        authorization: {
          from: owner,
          to: owner,
          value: 1n,
          validAfter: 0n,
          validBefore: 10n,
          nonce,
        },
        authorizationSignature: signature,
      }),
    ).toThrow(/recipient must be the canonical smart account/i);
  });

  it("builds the Circle-compatible typed data without assuming token domain values", () => {
    const typedData = buildReceiveWithAuthorizationTypedData(
      {
        name: "USD Coin",
        version: "2",
        chainId: 421614,
        verifyingContract: usdc,
      },
      {
        from: owner,
        to: account,
        value: 5_000_000n,
        validAfter: 0n,
        validBefore: 100n,
        nonce,
      },
    );

    expect(typedData.primaryType).toBe("ReceiveWithAuthorization");
    expect(typedData.domain.verifyingContract).toBe(usdc);
    expect(typedData.message.to).toBe(account);
  });

  it("encodes order, margin, withdrawal, and claim actions for smart-account execution", () => {
    const order = buildPlaceOrderAction({
      account,
      orderRouter: router,
      side: "BEAR",
      sizeDelta: 10n ** 18n,
      marginDelta: 2_000_000n,
      targetPrice: 123_456_789n,
      isClose: false,
    });
    expect(
      decodeFunctionData({ abi: orderRouterTraderAbi, data: order.calls[0]!.data }).args,
    ).toEqual([1, 10n ** 18n, 2_000_000n, 123_456_789n, false]);

    const addMargin = buildAddMarginAction({ account, cfdEngine: engine, amount: 7n });
    expect(
      decodeFunctionData({ abi: cfdEngineTraderAbi, data: addMargin.calls[0]!.data }).args,
    ).toEqual([account, 7n]);

    const withdraw = buildWithdrawAction({ account, clearinghouse, amount: 9n });
    expect(
      decodeFunctionData({
        abi: marginClearinghouseTraderAbi,
        data: withdraw.calls[0]!.data,
      }).args,
    ).toEqual([9n]);

    const claim = buildSettleTraderClaimAction({ account, cfdEngine: engine });
    expect(
      decodeFunctionData({ abi: cfdEngineTraderAbi, data: claim.calls[0]!.data }).args,
    ).toEqual([account]);
  });

  it("rejects close orders with positive margin before sponsorship", () => {
    expect(() =>
      buildPlaceOrderAction({
        account,
        orderRouter: router,
        side: "BULL",
        sizeDelta: 1n,
        marginDelta: 1n,
        targetPrice: 0n,
        isClose: true,
      }),
    ).toThrow(/close orders must use zero margin/i);
  });

  it("atomically withdraws the exact amount and transfers it to the owner", () => {
    const action = buildWithdrawToOwnerAction({
      account,
      owner,
      usdc,
      clearinghouse,
      amount: 12_345_678n,
    });

    expect(action.kind).toBe("withdraw-to-owner");
    expect(action.calls).toHaveLength(2);
    expect(action.calls.map((item) => item.value)).toEqual([0n, 0n]);
    expect(action.calls.map((item) => item.to)).toEqual([clearinghouse, usdc]);
    expect(
      decodeFunctionData({
        abi: marginClearinghouseTraderAbi,
        data: action.calls[0]!.data,
      }).args,
    ).toEqual([12_345_678n]);
    expect(
      decodeFunctionData({ abi: erc20TransferAbi, data: action.calls[1]!.data }).args,
    ).toEqual([owner, 12_345_678n]);
  });

  it("keeps EIP-7702 same-address withdrawals on the simple path", () => {
    expect(() =>
      buildWithdrawToOwnerAction({
        account,
        owner: account,
        usdc,
        clearinghouse,
        amount: 1n,
      }),
    ).toThrow(/same-address mode/i);
  });

  it("represents order cancellation as an explicit unsupported protocol capability", () => {
    try {
      buildCancelOrderAction({ account, orderRouter: router, orderId: 1n });
      expect.fail("expected cancellation to be rejected");
    } catch (error) {
      expect(error).toBeInstanceOf(PerpsClientError);
      expect((error as PerpsClientError).code).toBe("ACTION_UNSUPPORTED");
      expect((error as Error).message).toMatch(/binding/i);
    }
  });
});
