import {
  decodeEventLog, encodeAbiParameters, getAddress, keccak256, toBytes,
  type Address, type ContractFunctionArgs, type ContractFunctionReturnType, type Hex,
} from "viem";
import { orderLifecycleV5Abi } from "./orderV3Abi.js";

export type OrderReceiptV4 = ContractFunctionArgs<typeof orderLifecycleV5Abi, "view", "verifyReceipt">[0];
export type TerminalOutcomeV5 = ContractFunctionReturnType<typeof orderLifecycleV5Abi, "view", "terminalOutcome">;

const receiptParameter = orderLifecycleV5Abi.find((item) => item.type === "function" && item.name === "verifyReceipt")!.inputs[0];
const receiptTypeHash = keccak256(toBytes(
  "PletherOrderReceiptV4(uint256 chainId,address book,address router,uint64 terminalBlock,uint64 terminalTime,OrderReceipt receipt)",
));

/** The V5 read API retains the V4 receipt hash domain and complete event schema. */
export function hashOrderReceiptV4(input: {
  chainId: bigint; book: Address; router: Address; terminalBlock: bigint; terminalTime: bigint; receipt: OrderReceiptV4;
}): Hex {
  return keccak256(encodeAbiParameters([
    { type: "bytes32" }, { type: "uint256" }, { type: "address" }, { type: "address" },
    { type: "uint64" }, { type: "uint64" }, receiptParameter,
  ], [receiptTypeHash, input.chainId, input.book, input.router, input.terminalBlock, input.terminalTime, input.receipt]));
}

/**
 * Authenticate event history against a terminal summary read from the trusted Book on the requested chain.
 * An indexer supplies availability, not authority. Resolve finality/reorg policy before caching a summary.
 * Throws for a wrong emitter, nonterminal summary, altered receipt, clocks, or indexed identity.
 */
export function decodeVerifiedOrderFinalized(input: {
  chainId: bigint; book: Address; router: Address; summary: TerminalOutcomeV5;
  log: { address: Address; data: Hex; topics: [Hex, ...Hex[]] };
}) {
  if (getAddress(input.log.address) !== getAddress(input.book)) throw new Error("Wrong lifecycle Book emitter.");
  const event = decodeEventLog({ abi: orderLifecycleV5Abi, eventName: "OrderFinalized", ...input.log, strict: true });
  const { receipt, receiptHash, terminalBlock, terminalTime, orderId, account, clientOrderId } = event.args;
  const summary = input.summary;
  if ((summary.status !== 2 && summary.status !== 3)
    || orderId !== receipt.orderId || getAddress(account) !== getAddress(receipt.account)
    || clientOrderId.toLowerCase() !== receipt.clientOrderId.toLowerCase()
    || getAddress(summary.account) !== getAddress(receipt.account)
    || summary.status !== receipt.status || summary.reason !== receipt.reason || summary.terminalBlock !== terminalBlock
    || summary.receiptHash.toLowerCase() !== receiptHash.toLowerCase()
    || hashOrderReceiptV4({ ...input, terminalBlock, terminalTime, receipt }).toLowerCase() !== receiptHash.toLowerCase()) {
    throw new Error("Terminal receipt does not match authenticated history.");
  }
  return event.args;
}
