import { describe, expect, it } from "vitest";
import type { Address } from "viem";

import {
  derivePerpsCapabilities,
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
