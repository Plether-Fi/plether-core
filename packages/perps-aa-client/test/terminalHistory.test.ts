import { describe, expect, it } from "vitest";
import { encodeAbiParameters, encodeEventTopics, sha256, toHex, type AbiParameter, type Hex } from "viem";
import {
  decodeVerifiedOrderFinalized, hashOrderReceiptV4, orderLifecycleV4Abi, orderLifecycleV5Abi,
  type OrderReceiptV4, type TerminalOutcomeV5,
} from "../src/index.js";

const book = "0x1111111111111111111111111111111111111111";
const router = "0x2222222222222222222222222222222222222222";
const account = "0x3333333333333333333333333333333333333333";
const zeroHash = `0x${"00".repeat(32)}` as Hex;
const event = orderLifecycleV5Abi.find((x) => x.type === "event" && x.name === "OrderFinalized")!;
function zero(parameter: AbiParameter): unknown {
  if (parameter.type === "tuple" && "components" in parameter) return Object.fromEntries(parameter.components.map((p) => [p.name, zero(p)]));
  if (parameter.type === "address") return `0x${"00".repeat(20)}`;
  if (parameter.type === "bool") return false;
  if (parameter.type.startsWith("bytes")) return `0x${"00".repeat(Number(parameter.type.slice(5)))}`;
  return Number(parameter.type.replace(/\D/g, "")) <= 48 ? 0 : 0n;
}
const receipt: OrderReceiptV4 = {
  ...(zero(event.inputs[6]) as OrderReceiptV4), orderId: 7n, account, status: 2, reason: 1,
};
const context = { chainId: 421614n, book, router, terminalBlock: 123n, terminalTime: 1_900_000_000n, receipt } as const;
const receiptHash = hashOrderReceiptV4(context);
const summary: TerminalOutcomeV5 = { account, status: 2, reason: 1, terminalBlock: context.terminalBlock, receiptHash };
function logFor(value = receipt) {
  return {
    address: book,
    topics: encodeEventTopics({ abi: orderLifecycleV5Abi, eventName: "OrderFinalized", args: { orderId: value.orderId, account: value.account, clientOrderId: value.clientOrderId } }) as [Hex, ...Hex[]],
    data: encodeAbiParameters(event.inputs.filter((p) => !p.indexed), [receiptHash, context.terminalBlock, context.terminalTime, value]),
  };
}
const input = { ...context, summary, log: logFor() };
describe("authenticated terminal history", () => {
  it("retains the historical read ABI and unchanged V4 event", () => {
    expect(orderLifecycleV4Abi.some((x) => x.type === "function" && x.name === "outcome")).toBe(true);
    expect(orderLifecycleV5Abi.some((x) => x.type === "function" && (x.name as string) === "outcome")).toBe(false);
    expect(sha256(toHex(JSON.stringify(orderLifecycleV4Abi)))).toBe("0x63e62da0b44d682fb7528a7a6b21b49854ae60f4e3e5c34f1c8ce94b4390bfc1");
    expect(event).toEqual(orderLifecycleV4Abi.find((x) => x.type === "event" && x.name === "OrderFinalized"));
  });
  it("matches the independent Solidity golden receipt hash", () => {
    expect(receiptHash).toBe("0xca7de82d4a264ebae62485a3db72e94cff8d7ca629914cfa5fd9df75c3c4d07b");
  });
  it("returns complete receipt history after verification", () => {
    expect(decodeVerifiedOrderFinalized(input).receipt).toEqual(receipt);
  });
  it("rejects altered economics, commitment, bounty and indexed identity", () => {
    for (const changed of [
      { ...receipt, economics: { ...receipt.economics, postSettlementBalanceUsdc: 1n } },
      { ...receipt, commitment: { ...receipt.commitment, carryCollectedUsdc: 1n } },
      { ...receipt, bounty: { ...receipt.bounty, bountyRefundedUsdc: 1n } },
    ]) expect(() => decodeVerifiedOrderFinalized({ ...input, log: logFor(changed) })).toThrow(/authenticated history/);
    const log = logFor();
    log.topics[1] = `0x${"00".repeat(31)}08`;
    expect(() => decodeVerifiedOrderFinalized({ ...input, log })).toThrow(/authenticated history/);
  });
  it("rejects wrong emitter, chain, router and terminal summary", () => {
    expect(() => decodeVerifiedOrderFinalized({ ...input, log: { ...input.log, address: router } })).toThrow(/emitter/);
    expect(() => decodeVerifiedOrderFinalized({ ...input, chainId: 1n })).toThrow(/authenticated history/);
    expect(() => decodeVerifiedOrderFinalized({ ...input, router: book })).toThrow(/authenticated history/);
    for (const changed of [
      { ...summary, status: 1 }, { ...summary, terminalBlock: 124n }, { ...summary, receiptHash: zeroHash },
      { ...summary, reason: 2 }, { ...summary, account: book },
    ]) expect(() => decodeVerifiedOrderFinalized({ ...input, summary: changed })).toThrow(/authenticated history/);
  });
});
