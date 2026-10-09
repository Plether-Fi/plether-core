/** Destination-chain funding APIs. These are separate from the sponsored trader action allowlist. */
export const marginClearinghouseFundingAbi = [
  { type: "function", name: "depositFor", stateMutability: "nonpayable", inputs: [
    { name: "account", type: "address" }, { name: "amount", type: "uint256" },
  ], outputs: [] },
  { type: "function", name: "settlementAsset", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  { type: "event", name: "DepositFor", inputs: [
    { name: "payer", type: "address", indexed: true },
    { name: "account", type: "address", indexed: true },
    { name: "amount", type: "uint256", indexed: false },
  ] },
] as const;

export const bridgeDepositReceiverFactoryAbi = [
  { type: "function", name: "clearinghouse", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  { type: "function", name: "usdc", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  { type: "function", name: "predictReceiver", stateMutability: "view", inputs: [
    { name: "beneficiary", type: "address" }, { name: "intentSalt", type: "bytes32" },
  ], outputs: [{ name: "receiver", type: "address" }] },
  { type: "function", name: "createReceiver", stateMutability: "nonpayable", inputs: [
    { name: "beneficiary", type: "address" }, { name: "intentSalt", type: "bytes32" },
  ], outputs: [{ name: "receiver", type: "address" }] },
  { type: "event", name: "ReceiverCreated", inputs: [
    { name: "beneficiary", type: "address", indexed: true },
    { name: "intentSalt", type: "bytes32", indexed: true },
    { name: "receiver", type: "address", indexed: true },
  ] },
] as const;

export const bridgeDepositReceiverAbi = [
  { type: "function", name: "beneficiary", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  { type: "function", name: "clearinghouse", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  { type: "function", name: "usdc", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  { type: "function", name: "flush", stateMutability: "nonpayable", inputs: [], outputs: [{ name: "deposited", type: "uint256" }] },
  { type: "function", name: "recover", stateMutability: "nonpayable", inputs: [], outputs: [{ name: "recovered", type: "uint256" }] },
  { type: "function", name: "recoverToken", stateMutability: "nonpayable", inputs: [{ name: "token", type: "address" }], outputs: [{ name: "recovered", type: "uint256" }] },
  { type: "event", name: "Deposited", inputs: [
    { name: "beneficiary", type: "address", indexed: true }, { name: "amount", type: "uint256", indexed: false },
  ] },
  { type: "event", name: "Recovered", inputs: [
    { name: "token", type: "address", indexed: true }, { name: "beneficiary", type: "address", indexed: true },
    { name: "amount", type: "uint256", indexed: false },
  ] },
] as const;
