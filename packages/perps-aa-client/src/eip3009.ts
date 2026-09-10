import {
  getAddress,
  hexToNumber,
  size,
  slice,
  type Address,
  type Hex,
} from "viem";

import { InvalidPerpsActionError } from "./errors.js";

export const receiveWithAuthorizationTypes = {
  ReceiveWithAuthorization: [
    { name: "from", type: "address" },
    { name: "to", type: "address" },
    { name: "value", type: "uint256" },
    { name: "validAfter", type: "uint256" },
    { name: "validBefore", type: "uint256" },
    { name: "nonce", type: "bytes32" },
  ],
} as const;

export interface ReceiveWithAuthorization {
  readonly from: Address;
  readonly to: Address;
  readonly value: bigint;
  readonly validAfter: bigint;
  readonly validBefore: bigint;
  readonly nonce: Hex;
}

export interface Eip3009Domain {
  readonly name: string;
  readonly version: string;
  readonly chainId: number;
  readonly verifyingContract: Address;
}

/** Builds the exact EIP-712 payload the owner wallet must sign. */
export function buildReceiveWithAuthorizationTypedData(
  domain: Eip3009Domain,
  authorization: ReceiveWithAuthorization,
) {
  validateAuthorization(authorization);

  return {
    domain: {
      name: domain.name,
      version: domain.version,
      chainId: domain.chainId,
      verifyingContract: getAddress(domain.verifyingContract),
    },
    types: receiveWithAuthorizationTypes,
    primaryType: "ReceiveWithAuthorization" as const,
    message: {
      ...authorization,
      from: getAddress(authorization.from),
      to: getAddress(authorization.to),
    },
  } as const;
}

/** Browser-safe random nonce helper. Callers may persist and supply their own nonce instead. */
export function createAuthorizationNonce(): Hex {
  const cryptoApi = globalThis.crypto;
  if (!cryptoApi) {
    throw new InvalidPerpsActionError(
      "Secure randomness is unavailable; supply a persisted random bytes32 authorization nonce.",
    );
  }

  const bytes = new Uint8Array(32);
  cryptoApi.getRandomValues(bytes);
  return `0x${Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

export function splitEip3009Signature(signature: Hex): {
  readonly v: number;
  readonly r: Hex;
  readonly s: Hex;
} {
  if (size(signature) !== 65) {
    throw new InvalidPerpsActionError(
      "EIP-3009 requires a canonical 65-byte wallet signature.",
    );
  }

  const r = slice(signature, 0, 32);
  const s = slice(signature, 32, 64);
  const rawV = hexToNumber(slice(signature, 64, 65));
  const v = rawV <= 1 ? rawV + 27 : rawV;

  if (v !== 27 && v !== 28) {
    throw new InvalidPerpsActionError(
      "EIP-3009 signature recovery id must be 0, 1, 27, or 28.",
    );
  }

  return { v, r, s };
}

export function validateAuthorization(
  authorization: ReceiveWithAuthorization,
): void {
  getAddress(authorization.from);
  getAddress(authorization.to);

  if (authorization.value <= 0n) {
    throw new InvalidPerpsActionError("Authorization value must be greater than zero.");
  }
  if (authorization.validAfter < 0n) {
    throw new InvalidPerpsActionError("Authorization validAfter cannot be negative.");
  }
  if (authorization.validBefore <= authorization.validAfter) {
    throw new InvalidPerpsActionError(
      "Authorization validBefore must be later than validAfter.",
    );
  }
  if (size(authorization.nonce) !== 32) {
    throw new InvalidPerpsActionError("Authorization nonce must be exactly bytes32.");
  }
}
