import { describe, expect, it, vi } from "vitest";
import { decodeFunctionData, keccak256, maxUint256, zeroAddress, type Address, type Hex } from "viem";
import {
  buildDepositForCalls, erc20ApproveAbi, marginClearinghouseFundingAbi,
  verifyBridgeFundingDeployment, type BridgeFundingDeployment,
} from "../src/index.js";

// Synthetic identities exist only in tests; deployments must supply verified live release addresses.
const beneficiary = "0x1111111111111111111111111111111111111111" as Address;
const usdc = "0x2222222222222222222222222222222222222222" as Address;
const clearinghouse = "0x3333333333333333333333333333333333333333" as Address;
const destinationSpokePool = "0x4444444444444444444444444444444444444444" as Address;
const multicallHandler = "0x5555555555555555555555555555555555555555" as Address;
const destinationSpokePoolImplementation = "0x6666666666666666666666666666666666666666" as Address;
const codes = {
  [usdc]: "0x6001", [clearinghouse]: "0x6002", [destinationSpokePool]: "0x6003",
  [multicallHandler]: "0x6004", [destinationSpokePoolImplementation]: "0x6005",
} as const;
const deployment: BridgeFundingDeployment = {
  chainId: 42161, usdc, clearinghouse, destinationSpokePool, destinationSpokePoolImplementation, multicallHandler,
  usdcRuntimeCodeHash: keccak256(codes[usdc]),
  clearinghouseRuntimeCodeHash: keccak256(codes[clearinghouse]),
  destinationSpokePoolRuntimeCodeHash: keccak256(codes[destinationSpokePool]),
  destinationSpokePoolImplementationRuntimeCodeHash: keccak256(codes[destinationSpokePoolImplementation]),
  multicallHandlerRuntimeCodeHash: keccak256(codes[multicallHandler]),
};
const implementationWord = `0x${destinationSpokePoolImplementation.slice(2).padStart(64, "0")}` as Hex;

function mockClient(options: {
  chainId?: number;
  changedCode?: Address;
  replacementCode?: Hex;
  wrongSettlementAsset?: boolean;
  implementation?: Hex;
} = {}) {
  const client = {
    getChainId: vi.fn(async () => options.chainId ?? deployment.chainId),
    getBlockNumber: vi.fn(async () => 123n),
    getCode: vi.fn(async ({ address }: { address: Address }) => {
      if (address === options.changedCode) return options.replacementCode ?? "0x";
      return codes[address as keyof typeof codes];
    }),
    getStorageAt: vi.fn(async () => options.implementation ?? implementationWord),
    readContract: vi.fn(async ({ address, functionName }: { address: Address; functionName: string }) => {
      if (address === clearinghouse && functionName === "settlementAsset") return options.wrongSettlementAsset ? beneficiary : usdc;
      throw new Error(`Unexpected read: ${address} ${functionName}`);
    }),
  };
  return { client: client as unknown as Parameters<typeof verifyBridgeFundingDeployment>[0]["client"], spies: client };
}

describe("direct third-party funding calls", () => {
  it.each([12_000_000n, maxUint256])("approves and credits exactly %s to the intended beneficiary", amount => {
    const calls = buildDepositForCalls({ usdc, clearinghouse, beneficiary, amount });
    expect(calls.map(item => item.to)).toEqual([usdc, clearinghouse]);
    expect(calls.every(item => item.value === 0n && Object.isFrozen(item))).toBe(true);
    expect(decodeFunctionData({ abi: erc20ApproveAbi, data: calls[0]!.data }).args).toEqual([clearinghouse, amount]);
    expect(decodeFunctionData({ abi: marginClearinghouseFundingAbi, data: calls[1]!.data })).toMatchObject({
      functionName: "depositFor", args: [beneficiary, amount],
    });
    expect(Object.isFrozen(calls)).toBe(true);
  });

  it("rejects invalid addresses, aliased token/spender, and amounts outside the exact uint256 domain", () => {
    for (const field of ["usdc", "clearinghouse", "beneficiary"] as const) {
      expect(() => buildDepositForCalls({ usdc, clearinghouse, beneficiary, amount: 1n, [field]: zeroAddress })).toThrow(/nonzero address/);
    }
    for (const amount of [0n, -1n, maxUint256 + 1n]) {
      expect(() => buildDepositForCalls({ usdc, clearinghouse, beneficiary, amount })).toThrow(/positive uint256/);
    }
    expect(() => buildDepositForCalls({ usdc, clearinghouse: usdc, beneficiary, amount: 1n })).toThrow(/distinct/);
  });
});

describe("Across deployment verification against a pinned release", () => {
  it("checks all code, proxy implementation, and settlement-token reads at one block", async () => {
    const { client, spies } = mockClient();
    const result = await verifyBridgeFundingDeployment({ client, deployment });
    expect(result).toEqual({ chainId: 42161, blockNumber: 123n, usdc, clearinghouse, destinationSpokePool, destinationSpokePoolImplementation, multicallHandler });
    for (const [request] of [...spies.getCode.mock.calls, ...spies.readContract.mock.calls]) {
      expect(request).toMatchObject({ blockNumber: 123n });
    }
    expect(spies.getStorageAt).toHaveBeenCalledExactlyOnceWith({
      address: destinationSpokePool,
      slot: "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc",
      blockNumber: 123n,
    });
    // The permissionless handler exposes no immutable SpokePool binding getter.
    expect(spies.readContract).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({
      address: clearinghouse, functionName: "settlementAsset",
    }));
  });

  it("rejects the wrong chain before reading any deployment code", async () => {
    const { client, spies } = mockClient({ chainId: 1 });
    await expect(verifyBridgeFundingDeployment({ client, deployment })).rejects.toThrow(/RPC chain/);
    expect(spies.getCode).not.toHaveBeenCalled();
    expect(spies.getStorageAt).not.toHaveBeenCalled();
    expect(spies.readContract).not.toHaveBeenCalled();
  });

  it.each([usdc, clearinghouse, destinationSpokePool, destinationSpokePoolImplementation, multicallHandler])("fails closed on missing code at %s", async changedCode => {
    const { client, spies } = mockClient({ changedCode });
    await expect(verifyBridgeFundingDeployment({ client, deployment })).rejects.toThrow(/code mismatch/);
    expect(spies.readContract).not.toHaveBeenCalled();
    expect(spies.getStorageAt).not.toHaveBeenCalled();
  });

  it.each([usdc, clearinghouse, destinationSpokePool, destinationSpokePoolImplementation, multicallHandler])("rejects changed runtime code at %s", async changedCode => {
    const { client } = mockClient({ changedCode, replacementCode: "0x6099" });
    await expect(verifyBridgeFundingDeployment({ client, deployment })).rejects.toThrow(/code mismatch/);
  });

  it("rejects a different clearinghouse settlement token", async () => {
    const { client } = mockClient({ wrongSettlementAsset: true });
    await expect(verifyBridgeFundingDeployment({ client, deployment })).rejects.toThrow(/settlement asset/);
  });

  it.each(["0x", `0x${"00".repeat(32)}`, `0x${beneficiary.slice(2).padStart(64, "0")}`] as Hex[])("rejects an absent or changed EIP-1967 implementation slot (%s)", async implementation => {
    const { client } = mockClient({ implementation });
    await expect(verifyBridgeFundingDeployment({ client, deployment })).rejects.toThrow(/SpokePool implementation/);
  });

  it("rejects malformed release profiles before querying the RPC", async () => {
    const invalidProfiles = [
      { chainId: 0 }, { chainId: Number.MAX_SAFE_INTEGER + 1 }, { multicallHandler: zeroAddress },
      { destinationSpokePool: clearinghouse }, { destinationSpokePoolImplementation: destinationSpokePool },
      { clearinghouseRuntimeCodeHash: "0x12" as Hex },
      { multicallHandlerRuntimeCodeHash: `0x${"00".repeat(32)}` as Hex },
    ];
    for (const override of invalidProfiles) {
      const { client, spies } = mockClient();
      await expect(verifyBridgeFundingDeployment({ client, deployment: { ...deployment, ...override } })).rejects.toThrow();
      expect(spies.getChainId).not.toHaveBeenCalled();
    }
  });
});
