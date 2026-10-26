import { describe, expect, it } from "vitest";
import { decodeFunctionData, type Address } from "viem";

import {
  buildSmartAccountBalanceDepositAction,
  derivePerpsCapabilities,
  erc20ApproveAbi,
  marginClearinghouseTraderAbi,
  mapPerpsExecutionError,
  type PerpsActionKind,
} from "../src/index.js";

const account = "0x2222222222222222222222222222222222222222" as Address;

describe("UI capability and error mapping", () => {
  it("keeps the owner wallet while identifying the smart account as the trader", () => {
    const sponsoredActions = new Set<PerpsActionKind>([
      "deposit",
      "place-order",
      "add-margin",
      "withdraw",
      "withdraw-to-owner",
      "settle-claim",
    ]);
    const capabilities = derivePerpsCapabilities({
      wallet: { canSignTypedData: true },
      smartAccount: { accountAddress: account, canExecuteBatch: true, entryPointVersion: "0.8" },
      sponsor: { available: true, sponsoredActions },
      token: { supportsReceiveWithAuthorization: true },
    });

    expect(capabilities.ownerWalletRemainsConnected).toBe(true);
    expect(capabilities.smartAccountIsCanonicalTrader).toBe(true);
    expect(capabilities.firstDeposit).toEqual({ supported: true, sponsored: true });
    expect(capabilities.placeOrder.sponsored).toBe(true);
    expect(capabilities.withdrawToOwner.sponsored).toBe(true);
    expect(capabilities.cancelOrder).toMatchObject({ supported: false, sponsored: false });
  });

  it("explains why first-deposit batching is unavailable", () => {
    const capabilities = derivePerpsCapabilities({
      wallet: { canSignTypedData: false },
      smartAccount: { accountAddress: account, canExecuteBatch: true, entryPointVersion: "0.8" },
      sponsor: { available: true, sponsoredActions: new Set(["deposit"]) },
      token: { supportsReceiveWithAuthorization: true },
    });
    expect(capabilities.firstDeposit.supported).toBe(false);
    expect(capabilities.firstDeposit.reason).toMatch(/cannot sign/i);
  });

  it.each([true, false])("keeps MockUSDG account-balance deposits usable when wallet typed-data signing is %s", (canSignTypedData) => {
    const settlementToken = "0x3333333333333333333333333333333333333333" as Address;
    const clearinghouse = "0x4444444444444444444444444444444444444444" as Address;
    const capabilities = derivePerpsCapabilities({
      wallet: { canSignTypedData },
      smartAccount: { accountAddress: account, canExecuteBatch: true, entryPointVersion: "0.8" },
      sponsor: { available: true, sponsoredActions: new Set(["deposit"]) },
      token: { supportsReceiveWithAuthorization: false },
    });

    expect(capabilities.firstDeposit).toMatchObject({ supported: false, sponsored: false });
    if (canSignTypedData) {
      expect(capabilities.firstDeposit.reason).toMatch(/settlement token does not support receiveWithAuthorization/);
    }

    // Testnet funding mints to the canonical account; this route needs neither
    // receiveWithAuthorization nor a token-domain signature from its owner.
    const action = buildSmartAccountBalanceDepositAction({
      account,
      settlementToken: settlementToken,
      clearinghouse,
      amount: 25_000_000n,
    });
    expect(action.kind).toBe("deposit");
    expect(action.account).toBe(account);
    expect(action.calls.map(({ to, value }) => ({ to, value }))).toEqual([
      { to: settlementToken, value: 0n },
      { to: clearinghouse, value: 0n },
    ]);
    expect(decodeFunctionData({ abi: erc20ApproveAbi, data: action.calls[0]!.data })).toEqual({
      functionName: "approve", args: [clearinghouse, 25_000_000n],
    });
    expect(decodeFunctionData({ abi: marginClearinghouseTraderAbi, data: action.calls[1]!.data })).toEqual({
      functionName: "depositMargin", args: [25_000_000n],
    });
  });

  it("maps nested protocol, sponsor, and wallet failures to actionable UI errors", () => {
    expect(mapPerpsExecutionError({ code: 4001, message: "User rejected" }).code).toBe(
      "USER_REJECTED",
    );
    expect(
      mapPerpsExecutionError({ cause: { message: "MarginClearinghouse__InsufficientFreeEquity" } })
        .code,
    ).toBe("INSUFFICIENT_MARGIN");
    expect(mapPerpsExecutionError(new Error("sponsorship policy denied")).code).toBe(
      "SPONSOR_POLICY_DENIED",
    );
    expect(mapPerpsExecutionError(new Error("AA33 paymaster signature invalid")).code).toBe(
      "PAYMASTER_REJECTED",
    );
  });
});
