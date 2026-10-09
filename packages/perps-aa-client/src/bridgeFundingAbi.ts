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
