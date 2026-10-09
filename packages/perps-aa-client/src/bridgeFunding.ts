import {
  encodeFunctionData, getAddress, keccak256, maxUint256, zeroAddress,
  type Address, type Hex, type PublicClient,
} from "viem";
import { erc20ApproveAbi } from "./abis.js";
import {
  bridgeDepositReceiverAbi, bridgeDepositReceiverFactoryAbi, marginClearinghouseFundingAbi,
} from "./bridgeFundingAbi.js";
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
  readonly factory: Address;
  readonly usdcRuntimeCodeHash: Hex;
  readonly clearinghouseRuntimeCodeHash: Hex;
  readonly factoryRuntimeCodeHash: Hex;
}

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
  if (!/^0x[0-9a-fA-F]{64}$/.test(value)) {
    throw new InvalidPerpsActionError(`${label} must be exactly 32 bytes.`);
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
  return Object.freeze([
    call(usdc, encodeFunctionData({ abi: erc20ApproveAbi, functionName: "approve", args: [clearinghouse, input.amount] })),
    call(clearinghouse, encodeFunctionData({ abi: marginClearinghouseFundingAbi, functionName: "depositFor", args: [beneficiary, input.amount] })),
  ]);
}

/** Permissionless, idempotent CREATE2 deployment; persist the beneficiary and salt with the funding intent. */
export function buildCreateBridgeDepositReceiverCall(input: {
  readonly factory: Address;
  readonly beneficiary: Address;
  readonly intentSalt: Hex;
}): BridgeFundingCall {
  return call(address(input.factory, "Receiver factory"), encodeFunctionData({
    abi: bridgeDepositReceiverFactoryAbi, functionName: "createReceiver",
    args: [address(input.beneficiary, "Beneficiary"), word(input.intentSalt, "Intent salt")],
  }));
}

/** Permissionlessly deposits the receiver's current canonical-USDC balance into its immutable beneficiary. */
export function buildFlushBridgeDepositReceiverCall(receiver: Address): BridgeFundingCall {
  return call(address(receiver, "Receiver"), encodeFunctionData({ abi: bridgeDepositReceiverAbi, functionName: "flush" }));
}

/** Must execute as the immutable beneficiary; returns canonical USDC to that beneficiary's wallet. */
export function buildRecoverBridgeDepositReceiverCall(receiver: Address): BridgeFundingCall {
  return call(address(receiver, "Receiver"), encodeFunctionData({ abi: bridgeDepositReceiverAbi, functionName: "recover" }));
}

/** Must execute as the beneficiary; wrong-token recovery cannot redirect funds to another recipient. */
export function buildRecoverBridgeDepositReceiverTokenCall(input: {
  readonly receiver: Address;
  readonly token: Address;
  readonly usdc: Address;
}): BridgeFundingCall {
  const token = address(input.token, "Recovery token");
  if (token === address(input.usdc, "USDC")) {
    throw new InvalidPerpsActionError("Use recover() for canonical USDC.");
  }
  return call(address(input.receiver, "Receiver"), encodeFunctionData({
    abi: bridgeDepositReceiverAbi, functionName: "recoverToken", args: [token],
  }));
}

export interface ResolvedBridgeDepositReceiver {
  readonly chainId: number;
  readonly blockNumber: bigint;
  readonly beneficiary: Address;
  readonly receiver: Address;
  readonly deployed: boolean;
}

/**
 * Reads at one block and rejects wrong-chain, changed-code, or cross-stack receiver wiring.
 * A counterfactual address is not provider compatibility or proof of delivery/credit. The release
 * must independently prove depositFor support and the full core graph; this is a client recheck.
 */
export async function resolveBridgeDepositReceiver(input: {
  readonly client: Pick<PublicClient, "getChainId" | "getBlockNumber" | "getCode" | "readContract">;
  readonly deployment: BridgeFundingDeployment;
  readonly beneficiary: Address;
  readonly intentSalt: Hex;
}): Promise<ResolvedBridgeDepositReceiver> {
  const { client } = input;
  const chainId = input.deployment.chainId;
  if (!Number.isSafeInteger(chainId) || chainId <= 0) {
    throw new InvalidPerpsActionError("Deployment chain id must be a positive safe integer.");
  }
  const usdc = address(input.deployment.usdc, "USDC");
  const clearinghouse = address(input.deployment.clearinghouse, "Clearinghouse");
  const factory = address(input.deployment.factory, "Receiver factory");
  if (new Set([usdc, clearinghouse, factory]).size !== 3) {
    throw new InvalidPerpsActionError("Funding deployment contracts must be distinct.");
  }
  const beneficiary = address(input.beneficiary, "Beneficiary");
  const intentSalt = word(input.intentSalt, "Intent salt");
  const hashes = [
    word(input.deployment.usdcRuntimeCodeHash, "USDC runtime hash"),
    word(input.deployment.clearinghouseRuntimeCodeHash, "Clearinghouse runtime hash"),
    word(input.deployment.factoryRuntimeCodeHash, "Factory runtime hash"),
  ];
  if (await client.getChainId() !== chainId) {
    throw new InvalidPerpsActionError("RPC chain does not match the funding release.");
  }
  const blockNumber = await client.getBlockNumber();
  const targets = [usdc, clearinghouse, factory];
  const codes = await Promise.all(targets.map(target => client.getCode({ address: target, blockNumber })));
  for (let i = 0; i < codes.length; i++) {
    const code = codes[i];
    if (!code || code === "0x" || keccak256(code).toLowerCase() !== hashes[i]!.toLowerCase()) {
      throw new InvalidPerpsActionError(`Funding deployment code mismatch at ${targets[i]}.`);
    }
  }
  const [factoryUsdc, factoryClearinghouse, settlementAsset, predicted] = await Promise.all([
    client.readContract({ address: factory, abi: bridgeDepositReceiverFactoryAbi, functionName: "usdc", blockNumber }),
    client.readContract({ address: factory, abi: bridgeDepositReceiverFactoryAbi, functionName: "clearinghouse", blockNumber }),
    client.readContract({ address: clearinghouse, abi: marginClearinghouseFundingAbi, functionName: "settlementAsset", blockNumber }),
    client.readContract({ address: factory, abi: bridgeDepositReceiverFactoryAbi, functionName: "predictReceiver", args: [beneficiary, intentSalt], blockNumber }),
  ]);
  if (getAddress(factoryUsdc) !== usdc || getAddress(factoryClearinghouse) !== clearinghouse || getAddress(settlementAsset) !== usdc) {
    throw new InvalidPerpsActionError("Factory or clearinghouse bindings do not match the funding release.");
  }
  const receiver = address(predicted, "Predicted receiver");
  const receiverCode = await client.getCode({ address: receiver, blockNumber });
  const deployed = !!receiverCode && receiverCode !== "0x";
  if (deployed) {
    const [actualBeneficiary, actualClearinghouse, actualUsdc] = await Promise.all([
      client.readContract({ address: receiver, abi: bridgeDepositReceiverAbi, functionName: "beneficiary", blockNumber }),
      client.readContract({ address: receiver, abi: bridgeDepositReceiverAbi, functionName: "clearinghouse", blockNumber }),
      client.readContract({ address: receiver, abi: bridgeDepositReceiverAbi, functionName: "usdc", blockNumber }),
    ]);
    if (getAddress(actualBeneficiary) !== beneficiary || getAddress(actualClearinghouse) !== clearinghouse || getAddress(actualUsdc) !== usdc) {
      throw new InvalidPerpsActionError("Deployed receiver does not match the funding intent.");
    }
  }
  return Object.freeze({ chainId, blockNumber, beneficiary, receiver, deployed });
}
