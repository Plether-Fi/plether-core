import {
  encodeFunctionData, getAddress, keccak256, maxUint256, zeroAddress,
  type Address, type Hex, type PublicClient,
} from "viem";
import { erc20ApproveAbi } from "./abis.js";
import { marginClearinghouseFundingAbi } from "./bridgeFundingAbi.js";
import { InvalidPerpsActionError } from "./errors.js";

/** A raw destination-chain transaction; no smart-account or sponsorship support is implied. */
export interface BridgeFundingCall {
  readonly to: Address;
  readonly value: 0n;
  readonly data: Hex;
}

/** Values pinned by a separately validated bridge-funding release, never inferred from a wallet/provider. */
export interface BridgeFundingDeployment {
  readonly chainId: number;
  readonly usdc: Address;
  readonly clearinghouse: Address;
  readonly destinationSpokePool: Address;
  readonly destinationSpokePoolImplementation: Address;
  readonly multicallHandler: Address;
  readonly usdcRuntimeCodeHash: Hex;
  readonly clearinghouseRuntimeCodeHash: Hex;
  readonly destinationSpokePoolRuntimeCodeHash: Hex;
  readonly destinationSpokePoolImplementationRuntimeCodeHash: Hex;
  readonly multicallHandlerRuntimeCodeHash: Hex;
}

const implementationSlot = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

function address(value: Address, label: string): Address {
  try {
    const result = getAddress(value);
    if (result === zeroAddress) throw new Error("zero address");
    return result;
  } catch (cause) {
    throw new InvalidPerpsActionError(`${label} must be a valid nonzero address.`, cause);
  }
}

function word(value: Hex, label: string): Hex {
  if (!/^0x[0-9a-fA-F]{64}$/.test(value) || BigInt(value) === 0n) {
    throw new InvalidPerpsActionError(`${label} must be a nonzero 32-byte hash.`);
  }
  return value;
}

function call(to: Address, data: Hex): BridgeFundingCall {
  return Object.freeze({ to, value: 0n, data });
}

/**
 * Caller-funded approval and third-party credit. Execute both calls from the same payer.
 * Beneficiary receives free settlement, without position margin allocation or carry collection.
 * This never changes account authority and is not an existing paymaster-approved action.
 */
export function buildDepositForCalls(input: {
  readonly usdc: Address;
  readonly clearinghouse: Address;
  readonly beneficiary: Address;
  readonly amount: bigint;
}): readonly BridgeFundingCall[] {
  if (input.amount <= 0n || input.amount > maxUint256) {
    throw new InvalidPerpsActionError("Deposit amount must be a positive uint256.");
  }
  const usdc = address(input.usdc, "USDC");
  const clearinghouse = address(input.clearinghouse, "Clearinghouse");
  const beneficiary = address(input.beneficiary, "Beneficiary");
  if (usdc === clearinghouse) {
    throw new InvalidPerpsActionError("USDC and clearinghouse must be distinct.");
  }
  return Object.freeze([
    call(usdc, encodeFunctionData({ abi: erc20ApproveAbi, functionName: "approve", args: [clearinghouse, input.amount] })),
    call(clearinghouse, encodeFunctionData({ abi: marginClearinghouseFundingAbi, functionName: "depositFor", args: [beneficiary, input.amount] })),
  ]);
}

export interface VerifiedBridgeFundingDeployment {
  readonly chainId: number;
  readonly blockNumber: bigint;
  readonly usdc: Address;
  readonly clearinghouse: Address;
  readonly destinationSpokePool: Address;
  readonly destinationSpokePoolImplementation: Address;
  readonly multicallHandler: Address;
}

/**
 * Rechecks release code pins, the SpokePool implementation, and clearinghouse/token binding at one block.
 * The shared handler is permissionless and has no immutable SpokePool binding. These checks
 * establish contract identities, not route authorization or proof of delivery/credit. The release
 * must independently prove depositFor support, provider compatibility, and the full core graph.
 */
export async function verifyBridgeFundingDeployment(input: {
  readonly client: Pick<PublicClient, "getChainId" | "getBlockNumber" | "getCode" | "getStorageAt" | "readContract">;
  readonly deployment: BridgeFundingDeployment;
}): Promise<VerifiedBridgeFundingDeployment> {
  const { client } = input;
  const chainId = input.deployment.chainId;
  if (!Number.isSafeInteger(chainId) || chainId <= 0) {
    throw new InvalidPerpsActionError("Deployment chain id must be a positive safe integer.");
  }
  const usdc = address(input.deployment.usdc, "USDC");
  const clearinghouse = address(input.deployment.clearinghouse, "Clearinghouse");
  const destinationSpokePool = address(input.deployment.destinationSpokePool, "Destination SpokePool");
  const destinationSpokePoolImplementation = address(input.deployment.destinationSpokePoolImplementation, "SpokePool implementation");
  const multicallHandler = address(input.deployment.multicallHandler, "Multicall handler");
  const targets = [usdc, clearinghouse, destinationSpokePool, destinationSpokePoolImplementation, multicallHandler];
  if (new Set(targets).size !== targets.length) {
    throw new InvalidPerpsActionError("Funding deployment contracts must be distinct.");
  }
  const hashes = [
    word(input.deployment.usdcRuntimeCodeHash, "USDC runtime hash"),
    word(input.deployment.clearinghouseRuntimeCodeHash, "Clearinghouse runtime hash"),
    word(input.deployment.destinationSpokePoolRuntimeCodeHash, "SpokePool runtime hash"),
    word(input.deployment.destinationSpokePoolImplementationRuntimeCodeHash, "SpokePool implementation runtime hash"),
    word(input.deployment.multicallHandlerRuntimeCodeHash, "Handler runtime hash"),
  ];
  if (await client.getChainId() !== chainId) {
    throw new InvalidPerpsActionError("RPC chain does not match the funding release.");
  }
  const blockNumber = await client.getBlockNumber();
  const codes = await Promise.all(targets.map(target => client.getCode({ address: target, blockNumber })));
  for (let i = 0; i < codes.length; i++) {
    const code = codes[i];
    if (!code || code === "0x" || keccak256(code).toLowerCase() !== hashes[i]!.toLowerCase()) {
      throw new InvalidPerpsActionError(`Funding deployment code mismatch at ${targets[i]}.`);
    }
  }
  const [settlementAsset, implementation] = await Promise.all([
    client.readContract({
      address: clearinghouse, abi: marginClearinghouseFundingAbi, functionName: "settlementAsset", blockNumber,
    }),
    client.getStorageAt({ address: destinationSpokePool, slot: implementationSlot, blockNumber }),
  ]);
  if (getAddress(settlementAsset) !== usdc) {
    throw new InvalidPerpsActionError("Clearinghouse settlement asset does not match the funding release.");
  }
  if (implementation?.toLowerCase() !== `0x${destinationSpokePoolImplementation.slice(2).toLowerCase().padStart(64, "0")}`) {
    throw new InvalidPerpsActionError("SpokePool implementation does not match the funding release.");
  }
  return Object.freeze({ chainId, blockNumber, usdc, clearinghouse, destinationSpokePool, destinationSpokePoolImplementation, multicallHandler });
}
