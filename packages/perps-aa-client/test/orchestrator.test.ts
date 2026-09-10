import { describe, expect, it } from "vitest";
import { concatHex, numberToHex, slice, type Address, type Hex } from "viem";

import {
  sendSponsoredAction,
  type BundlerAdapter,
  type ParsedPaymasterEnvelope,
  type PerpsActionPlan,
  type SmartAccountAdapter,
  type SponsorAdapter,
} from "../src/index.js";

const accountAddress = "0x2222222222222222222222222222222222222222" as Address;
const entryPoint = "0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108" as Address;
const target = "0x4444444444444444444444444444444444444444" as Address;
const paymaster = "0x7777777777777777777777777777777777777777" as Address;
const operationHash = `0x${"aa".repeat(32)}` as Hex;
const policyId = `0x${"55".repeat(32)}` as Hex;
const accountCodeHash = `0x${"44".repeat(32)}` as Hex;
const paymasterProfile = {
  chainId: 421_614,
  entryPoint,
  paymaster,
  policyId,
  accountCodeHash,
  paymasterVerificationGasLimit: 100_000n,
  paymasterPostOpGasLimit: 0n,
  maxValidityWindowSeconds: 600n,
};

interface Operation {
  readonly marker: string;
  readonly paymaster?: ParsedPaymasterEnvelope;
  readonly estimated?: boolean;
  readonly signed?: boolean;
}

function packedResponse(validUntil: bigint) {
  return {
    paymasterAndData: concatHex([
      paymaster,
      numberToHex(100_000n, { size: 16 }),
      numberToHex(0n, { size: 16 }),
      numberToHex(validUntil, { size: 6 }),
      numberToHex(validUntil > 300n ? validUntil - 300n : 0n, { size: 6 }),
      numberToHex(1_000_000n, { size: 16 }),
      policyId,
      accountCodeHash,
      `0x${"66".repeat(65)}` as Hex,
    ]),
  } as const;
}

describe("sponsored UserOperation orchestration", () => {
  it("installs stub, estimates, installs final sponsorship, then obtains owner signature", async () => {
    const events: string[] = [];
    const action: PerpsActionPlan = {
      kind: "place-order",
      account: accountAddress,
      calls: [{ to: target, value: 0n, data: "0x1234" }],
    };

    const account: SmartAccountAdapter<Operation, { gas: bigint }> = {
      accountAddress,
      entryPoint,
      async buildUserOperation() {
        events.push("build");
        return { marker: "operation" };
      },
      applyPaymaster(operation, sponsorship) {
        events.push(`apply-paymaster-${sponsorship.validUntil}`);
        return { ...operation, paymaster: sponsorship };
      },
      applyGasEstimate(operation) {
        events.push("apply-estimate");
        return { ...operation, estimated: true };
      },
      async signUserOperation(operation) {
        events.push("sign");
        expect(operation.estimated).toBe(true);
        expect(operation.paymaster?.validUntil).toBe(2_000n);
        return { ...operation, signed: true };
      },
    };

    const sponsor: SponsorAdapter<Operation> = {
      async getPaymasterStubData() {
        events.push("stub");
        return packedResponse(1_000n);
      },
      async getPaymasterData({ operation }) {
        events.push("final");
        expect(operation.estimated).toBe(true);
        expect(operation.paymaster?.validUntil).toBe(1_000n);
        return {
          paymaster,
          // ERC-7677 permits final data to omit the gas fields returned by the stub.
          paymasterData: slice(packedResponse(2_000n).paymasterAndData, 52),
        };
      },
    };

    const bundler: BundlerAdapter<Operation, { gas: bigint }, { success: true }> = {
      async estimateUserOperationGas({ operation }) {
        events.push("estimate");
        expect(operation.paymaster?.validUntil).toBe(1_000n);
        return { gas: 123n };
      },
      async sendUserOperation({ operation }) {
        events.push("send");
        expect(operation.signed).toBe(true);
        expect(operation.paymaster?.validUntil).toBe(2_000n);
        return operationHash;
      },
      async waitForUserOperationReceipt() {
        events.push("wait");
        return { success: true };
      },
    };

    const statuses: string[] = [];
    const result = await sendSponsoredAction({
      chainId: 421614,
      action,
      account,
      sponsor,
      bundler,
      paymasterProfile,
      journalSignedUserOperation: async ({ operation }) => {
        events.push("journal");
        expect(operation.signed).toBe(true);
        return operationHash;
      },
      waitForReceipt: true,
      onStatus: (status) => statuses.push(status),
    });

    expect(result).toEqual({ userOperationHash: operationHash, receipt: { success: true } });
    expect(events).toEqual([
      "build",
      "stub",
      "apply-paymaster-1000",
      "estimate",
      "apply-estimate",
      "final",
      "apply-paymaster-2000",
      "sign",
      "journal",
      "send",
      "wait",
    ]);
    expect(statuses.at(-1)).toBe("confirmed");
  });

  it("blocks execution when a plan is bound to a different smart account", async () => {
    const wrong = "0x9999999999999999999999999999999999999999" as Address;
    const inert = {} as never;

    await expect(
      sendSponsoredAction({
        chainId: 1,
        action: { kind: "withdraw", account: wrong, calls: [] },
        account: {
          accountAddress,
          entryPoint,
          buildUserOperation: async () => inert,
          applyPaymaster: () => inert,
          applyGasEstimate: () => inert,
          signUserOperation: async () => inert,
        },
        sponsor: {
          getPaymasterStubData: async () => packedResponse(1n),
          getPaymasterData: async () => packedResponse(2n),
        },
        bundler: {
          estimateUserOperationGas: async () => inert,
          sendUserOperation: async () => operationHash,
        },
        paymasterProfile,
        journalSignedUserOperation: async () => operationHash,
      }),
    ).rejects.toMatchObject({ code: "ACCOUNT_MISMATCH" });
  });

  it("rejects a chain or EntryPoint outside the manifest profile before building", async () => {
    const buildEvents: string[] = [];
    const common = {
      chainId: 421_614,
      action: { kind: "withdraw" as const, account: accountAddress, calls: [] },
      account: {
        accountAddress,
        entryPoint,
        buildUserOperation: async () => {
          buildEvents.push("build");
          return { marker: "operation" };
        },
        applyPaymaster: (operation: Operation) => operation,
        applyGasEstimate: (operation: Operation) => operation,
        signUserOperation: async (operation: Operation) => operation,
      },
      sponsor: {} as SponsorAdapter<Operation>,
      bundler: {} as BundlerAdapter<Operation, never, never>,
      journalSignedUserOperation: async () => operationHash,
    };

    await expect(
      sendSponsoredAction({
        ...common,
        chainId: 1,
        paymasterProfile,
      }),
    ).rejects.toThrow(/chain does not match/i);
    await expect(
      sendSponsoredAction({
        ...common,
        paymasterProfile: {
          ...paymasterProfile,
          entryPoint: "0x9999999999999999999999999999999999999999",
        },
      }),
    ).rejects.toThrow(/EntryPoint does not match/i);

    expect(buildEvents).toEqual([]);
  });

  it("rejects a stub outside the manifest-pinned policy before estimation", async () => {
    const events: string[] = [];

    await expect(
      sendSponsoredAction({
        chainId: 421_614,
        action: {
          kind: "withdraw",
          account: accountAddress,
          calls: [{ to: target, value: 0n, data: "0x1234" }],
        },
        account: {
          accountAddress,
          entryPoint,
          async buildUserOperation() {
            events.push("build");
            return { marker: "operation" };
          },
          applyPaymaster(operation, sponsorship) {
            return { ...operation, paymaster: sponsorship };
          },
          applyGasEstimate(operation) {
            return operation;
          },
          async signUserOperation(operation) {
            return operation;
          },
        },
        sponsor: {
          async getPaymasterStubData() {
            events.push("stub");
            return packedResponse(1_000n);
          },
          async getPaymasterData() {
            throw new Error("final sponsorship must not be requested");
          },
        },
        bundler: {
          async estimateUserOperationGas() {
            events.push("estimate");
            return { gas: 1n };
          },
          async sendUserOperation() {
            throw new Error("operation must not be submitted");
          },
        },
        paymasterProfile: {
          ...paymasterProfile,
          policyId: `0x${"11".repeat(32)}`,
        },
        journalSignedUserOperation: async () => operationHash,
      }),
    ).rejects.toMatchObject({ code: "INVALID_ACTION" });

    expect(events).toEqual(["build", "stub"]);
  });

  it("rejects a bundler hash that does not match the durable signed-operation journal", async () => {
    const returnedHash = `0x${"bb".repeat(32)}` as Hex;
    const action: PerpsActionPlan = {
      kind: "place-order",
      account: accountAddress,
      calls: [{ to: target, value: 0n, data: "0x1234" }],
    };
    const account: SmartAccountAdapter<Operation, { gas: bigint }> = {
      accountAddress,
      entryPoint,
      buildUserOperation: async () => ({ marker: "operation" }),
      applyPaymaster: (operation, sponsorship) => ({
        ...operation,
        paymaster: sponsorship,
      }),
      applyGasEstimate: (operation) => ({ ...operation, estimated: true }),
      signUserOperation: async (operation) => ({ ...operation, signed: true }),
    };
    const sponsor: SponsorAdapter<Operation> = {
      getPaymasterStubData: async () => packedResponse(1_000n),
      getPaymasterData: async () => packedResponse(2_000n),
    };
    const bundler: BundlerAdapter<Operation, { gas: bigint }, never> = {
      estimateUserOperationGas: async () => ({ gas: 1n }),
      sendUserOperation: async () => returnedHash,
    };

    await expect(
      sendSponsoredAction({
        chainId: 421_614,
        action,
        account,
        sponsor,
        bundler,
        paymasterProfile,
        journalSignedUserOperation: async () => operationHash,
      }),
    ).rejects.toMatchObject({
      code: "INVALID_ACTION",
      message: expect.stringMatching(/does not match the journaled operation/i),
    });
  });
});
