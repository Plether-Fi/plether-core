import { describe, expect, it, vi } from "vitest";
import { decodeFunctionData, keccak256, maxUint256, zeroAddress, type Address, type Hex } from "viem";
import {
  bridgeDepositReceiverAbi, bridgeDepositReceiverFactoryAbi, buildCreateBridgeDepositReceiverCall,
  buildDepositForCalls, buildFlushBridgeDepositReceiverCall, buildRecoverBridgeDepositReceiverCall,
  buildRecoverBridgeDepositReceiverTokenCall, erc20ApproveAbi, marginClearinghouseFundingAbi,
  resolveBridgeDepositReceiver, type BridgeFundingDeployment,
} from "../src/index.js";

// Synthetic identities exist only in tests; deployments must supply verified live release addresses.
const beneficiary = "0x1111111111111111111111111111111111111111" as Address;
const usdc = "0x2222222222222222222222222222222222222222" as Address;
const clearinghouse = "0x3333333333333333333333333333333333333333" as Address;
const factory = "0x4444444444444444444444444444444444444444" as Address;
const receiver = "0x5555555555555555555555555555555555555555" as Address;
const wrongToken = "0x6666666666666666666666666666666666666666" as Address;
const intentSalt = `0x${"ab".repeat(32)}` as Hex;
const codes = { [usdc]: "0x6001", [clearinghouse]: "0x6002", [factory]: "0x6003", [receiver]: "0x6004" } as const;
const deployment: BridgeFundingDeployment = {
  chainId: 421614, usdc, clearinghouse, factory,
  usdcRuntimeCodeHash: keccak256(codes[usdc]),
  clearinghouseRuntimeCodeHash: keccak256(codes[clearinghouse]),
  factoryRuntimeCodeHash: keccak256(codes[factory]),
};

function mockClient(options: {
  chainId?: number;
  deployed?: boolean;
  changedCode?: Address;
  replacementCode?: Hex;
  wrongBinding?: "factory" | "clearinghouse" | "receiver";
} = {}) {
  const client = {
    getChainId: vi.fn(async () => options.chainId ?? deployment.chainId),
    getBlockNumber: vi.fn(async () => 123n),
    getCode: vi.fn(async ({ address }: { address: Address }) => {
      if (address === options.changedCode) return options.replacementCode ?? "0x";
      if (address === receiver && options.deployed === false) return undefined;
      return codes[address as keyof typeof codes];
    }),
    readContract: vi.fn(async ({ address, functionName }: { address: Address; functionName: string }) => {
      if (address === factory) {
        if (functionName === "predictReceiver") return receiver;
        if (functionName === "clearinghouse") return options.wrongBinding === "factory" ? beneficiary : clearinghouse;
        if (functionName === "usdc") return usdc;
      }
      if (address === clearinghouse && functionName === "settlementAsset") return options.wrongBinding === "clearinghouse" ? wrongToken : usdc;
      if (address === receiver) {
        if (functionName === "beneficiary") return options.wrongBinding === "receiver" ? wrongToken : beneficiary;
        if (functionName === "clearinghouse") return clearinghouse;
        if (functionName === "usdc") return usdc;
      }
      throw new Error(`Unexpected read: ${address} ${functionName}`);
    }),
  };
  return { client: client as unknown as Parameters<typeof resolveBridgeDepositReceiver>[0]["client"], spies: client };
}

describe("bridge funding calls", () => {
  it("credits the immutable intended beneficiary without turning that beneficiary into the payer", () => {
    const calls = buildDepositForCalls({ usdc, clearinghouse, beneficiary, amount: 12_000_000n });
    expect(calls.map(item => item.to)).toEqual([usdc, clearinghouse]);
    expect(calls.every(item => item.value === 0n)).toBe(true);
    expect(decodeFunctionData({ abi: erc20ApproveAbi, data: calls[0]!.data }).args).toEqual([clearinghouse, 12_000_000n]);
    expect(decodeFunctionData({ abi: marginClearinghouseFundingAbi, data: calls[1]!.data })).toMatchObject({
      functionName: "depositFor", args: [beneficiary, 12_000_000n],
    });
    expect(Object.isFrozen(calls)).toBe(true);
  });

  it("uses the same intent identity for deterministic creation and exposes recovery without a redirect recipient", () => {
    const create = buildCreateBridgeDepositReceiverCall({ factory, beneficiary, intentSalt });
    expect(decodeFunctionData({ abi: bridgeDepositReceiverFactoryAbi, data: create.data }).args).toEqual([beneficiary, intentSalt]);
    const flush = buildFlushBridgeDepositReceiverCall(receiver);
    const recover = buildRecoverBridgeDepositReceiverCall(receiver);
    expect(decodeFunctionData({ abi: bridgeDepositReceiverAbi, data: flush.data }).functionName).toBe("flush");
    expect(decodeFunctionData({ abi: bridgeDepositReceiverAbi, data: recover.data }).functionName).toBe("recover");
    const recoverToken = buildRecoverBridgeDepositReceiverTokenCall({ receiver, token: wrongToken, usdc });
    expect(decodeFunctionData({ abi: bridgeDepositReceiverAbi, data: recoverToken.data }).args).toEqual([wrongToken]);
    expect(() => buildRecoverBridgeDepositReceiverTokenCall({ receiver, token: usdc, usdc })).toThrow(/recover\(\)/);
  });

  it("rejects zero beneficiaries, malformed salts, and amounts outside the exact uint256 domain", () => {
    expect(() => buildDepositForCalls({ usdc, clearinghouse, beneficiary: zeroAddress, amount: 1n })).toThrow(/nonzero address/);
    for (const amount of [0n, -1n, maxUint256 + 1n]) {
      expect(() => buildDepositForCalls({ usdc, clearinghouse, beneficiary, amount })).toThrow(/positive uint256/);
    }
    expect(() => buildCreateBridgeDepositReceiverCall({ factory, beneficiary, intentSalt: "0xab" })).toThrow(/32 bytes/);
    expect(() => buildCreateBridgeDepositReceiverCall({ factory, beneficiary, intentSalt: `0x${"a".repeat(63)}` })).toThrow(/32 bytes/);
    expect(() => buildFlushBridgeDepositReceiverCall(zeroAddress)).toThrow(/nonzero address/);
  });
});

describe("receiver resolution against a pinned release", () => {
  it("verifies deployed beneficiary bindings and pins every code and contract read to one block", async () => {
    const { client, spies } = mockClient();
    const result = await resolveBridgeDepositReceiver({ client, deployment, beneficiary, intentSalt });
    expect(result).toEqual({ chainId: 421614, blockNumber: 123n, beneficiary, receiver, deployed: true });
    for (const [request] of [...spies.getCode.mock.calls, ...spies.readContract.mock.calls]) {
      expect(request).toMatchObject({ blockNumber: 123n });
    }
    expect(spies.readContract.mock.calls).toContainEqual([expect.objectContaining({ functionName: "predictReceiver", args: [beneficiary, intentSalt] })]);
  });

  it("distinguishes a counterfactual address from an already deployed receiver", async () => {
    const { client, spies } = mockClient({ deployed: false });
    const result = await resolveBridgeDepositReceiver({ client, deployment, beneficiary, intentSalt });
    expect(result.deployed).toBe(false);
    expect(spies.readContract.mock.calls.some(([request]) => request.address === receiver)).toBe(false);
  });

  it("rejects the wrong chain before reading or predicting any funding address", async () => {
    const { client, spies } = mockClient({ chainId: 1 });
    await expect(resolveBridgeDepositReceiver({ client, deployment, beneficiary, intentSalt })).rejects.toThrow(/RPC chain/);
    expect(spies.getCode).not.toHaveBeenCalled();
    expect(spies.readContract).not.toHaveBeenCalled();
  });

  it.each([usdc, clearinghouse, factory])("fails closed on missing code at %s", async changedCode => {
    const { client, spies } = mockClient({ changedCode });
    await expect(resolveBridgeDepositReceiver({ client, deployment, beneficiary, intentSalt })).rejects.toThrow(/code mismatch/);
    expect(spies.readContract).not.toHaveBeenCalled();
  });

  it("rejects nonempty factory bytecode that differs from the release pin", async () => {
    const { client, spies } = mockClient({ changedCode: factory, replacementCode: "0x6005" });
    await expect(resolveBridgeDepositReceiver({ client, deployment, beneficiary, intentSalt })).rejects.toThrow(/code mismatch/);
    expect(spies.readContract).not.toHaveBeenCalled();
  });

  it.each(["factory", "clearinghouse", "receiver"] as const)("rejects a cross-stack %s binding", async wrongBinding => {
    const { client } = mockClient({ wrongBinding });
    await expect(resolveBridgeDepositReceiver({ client, deployment, beneficiary, intentSalt })).rejects.toThrow(/bindings|funding intent/);
  });
});
