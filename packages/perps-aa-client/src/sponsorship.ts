import {
  getAddress,
  hashTypedData,
  hexToBigInt,
  keccak256,
  size,
  type Address,
  type Hex,
} from "viem";

import { InvalidPerpsActionError } from "./errors.js";
import { parsePaymasterAndData } from "./paymaster.js";
import type { SponsorshipUserOperation } from "./types.js";

export const PLETHER_SPONSORSHIP_DOMAIN_NAME = "PletherVerifyingPaymaster";
export const PLETHER_SPONSORSHIP_DOMAIN_VERSION = "1";
export const PLETHER_SPONSORSHIP_TYPEHASH =
  "0x5835c142c681b663470a1a53c34b0ba256a8283b7b9f9560aadb85711d252918" as Hex;

export const PLETHER_SPONSORSHIP_TYPES = {
  Sponsorship: [
    { name: "sender", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "initCodeHash", type: "bytes32" },
    { name: "callDataHash", type: "bytes32" },
    { name: "accountGasLimits", type: "bytes32" },
    { name: "preVerificationGas", type: "uint256" },
    { name: "gasFees", type: "bytes32" },
    { name: "paymasterVerificationGasLimit", type: "uint128" },
    { name: "paymasterPostOpGasLimit", type: "uint128" },
    { name: "validUntil", type: "uint48" },
    { name: "validAfter", type: "uint48" },
    { name: "maxCost", type: "uint128" },
    { name: "policyId", type: "bytes32" },
    { name: "accountCodeHash", type: "bytes32" },
    { name: "entryPoint", type: "address" },
  ],
} as const;

function quantity(value: bigint | Hex): bigint {
  return typeof value === "bigint" ? value : hexToBigInt(value);
}

function bytes32(value: Hex, label: string): Hex {
  if (size(value) !== 32) {
    throw new InvalidPerpsActionError(`${label} must be exactly 32 bytes.`);
  }
  return value;
}

export function getPletherSponsorshipTypedData(input: {
  readonly chainId: number;
  readonly entryPoint: Address;
  readonly userOperation: SponsorshipUserOperation;
}) {
  const envelope = parsePaymasterAndData(input.userOperation.paymasterAndData);

  return {
    domain: {
      name: PLETHER_SPONSORSHIP_DOMAIN_NAME,
      version: PLETHER_SPONSORSHIP_DOMAIN_VERSION,
      chainId: input.chainId,
      verifyingContract: envelope.paymaster,
    },
    types: PLETHER_SPONSORSHIP_TYPES,
    primaryType: "Sponsorship",
    message: {
      sender: getAddress(input.userOperation.sender),
      nonce: quantity(input.userOperation.nonce),
      initCodeHash: keccak256(input.userOperation.initCode),
      callDataHash: keccak256(input.userOperation.callData),
      accountGasLimits: bytes32(
        input.userOperation.accountGasLimits,
        "accountGasLimits",
      ),
      preVerificationGas: quantity(
        input.userOperation.preVerificationGas,
      ),
      gasFees: bytes32(input.userOperation.gasFees, "gasFees"),
      paymasterVerificationGasLimit:
        envelope.paymasterVerificationGasLimit,
      paymasterPostOpGasLimit: envelope.paymasterPostOpGasLimit,
      validUntil: Number(envelope.validUntil),
      validAfter: Number(envelope.validAfter),
      maxCost: envelope.maxCost,
      policyId: envelope.policyId,
      accountCodeHash: envelope.accountCodeHash,
      entryPoint: getAddress(input.entryPoint),
    },
  } as const;
}

export function hashPletherSponsorship(input: {
  readonly chainId: number;
  readonly entryPoint: Address;
  readonly userOperation: SponsorshipUserOperation;
}): Hex {
  return hashTypedData(getPletherSponsorshipTypedData(input));
}
