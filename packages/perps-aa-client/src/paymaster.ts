import {
  concatHex,
  getAddress,
  hexToBigInt,
  numberToHex,
  size,
  slice,
  type Hex,
} from "viem";

import { InvalidPerpsActionError } from "./errors.js";
import type {
  Eip7677PaymasterResponse,
  ParsedPaymasterEnvelope,
  PletherPaymasterProfile,
} from "./types.js";

export const PAYMASTER_HEADER_BYTES = 52;
export const PLETHER_PAYMASTER_DATA_BYTES = 157;
export const PLETHER_PAYMASTER_AND_DATA_BYTES = 209;
export const DEFAULT_MAX_VALIDITY_WINDOW_SECONDS = 600n;

const UINT128_MAX = (1n << 128n) - 1n;

function quantity(value: bigint | Hex, label: string): bigint {
  const parsed = typeof value === "bigint" ? value : hexToBigInt(value);
  if (parsed < 0n || parsed > UINT128_MAX) {
    throw new InvalidPerpsActionError(`${label} must fit uint128.`);
  }
  return parsed;
}

/** Accepts either an EIP-7677 split response or a fully packed v0.8 response. */
export function normalizePaymasterResponse(
  response: Eip7677PaymasterResponse,
  fallback?: ParsedPaymasterEnvelope,
): ParsedPaymasterEnvelope {
  let packed = response.paymasterAndData;

  if (!packed) {
    if (
      !response.paymaster ||
      !response.paymasterData
    ) {
      throw new InvalidPerpsActionError(
        "Paymaster response must include paymaster and paymasterData.",
      );
    }
    if (fallback && getAddress(response.paymaster) !== fallback.paymaster) {
      throw new InvalidPerpsActionError(
        "Final sponsorship response cannot change the paymaster selected by the stub.",
      );
    }
    if (size(response.paymasterData) !== PLETHER_PAYMASTER_DATA_BYTES) {
      throw new InvalidPerpsActionError(
        `Plether paymasterData must be ${PLETHER_PAYMASTER_DATA_BYTES} bytes.`,
      );
    }

    const verificationGas =
      response.paymasterVerificationGasLimit ?? fallback?.paymasterVerificationGasLimit;
    const postOpGas =
      response.paymasterPostOpGasLimit ?? fallback?.paymasterPostOpGasLimit;
    if (verificationGas == null || postOpGas == null) {
      throw new InvalidPerpsActionError(
        "Initial paymaster response must include both paymaster gas limits.",
      );
    }

    packed = concatHex([
      getAddress(response.paymaster),
      numberToHex(
        quantity(verificationGas, "Paymaster verification gas limit"),
        { size: 16 },
      ),
      numberToHex(
        quantity(postOpGas, "Paymaster postOp gas limit"),
        { size: 16 },
      ),
      response.paymasterData,
    ]);
  }

  const parsed = parsePaymasterAndData(packed);
  if (fallback && parsed.paymaster !== fallback.paymaster) {
    throw new InvalidPerpsActionError(
      "Final sponsorship response cannot change the paymaster selected by the stub.",
    );
  }
  if (
    fallback &&
    (parsed.paymasterVerificationGasLimit !==
      fallback.paymasterVerificationGasLimit ||
      parsed.paymasterPostOpGasLimit !== fallback.paymasterPostOpGasLimit)
  ) {
    throw new InvalidPerpsActionError(
      "Final sponsorship response cannot change paymaster gas limits after estimation.",
    );
  }
  return parsed;
}

/**
 * Parses the fixed v0.8 envelope:
 * paymaster(20) | verificationGas(16) | postOpGas(16) | validUntil(6) |
 * validAfter(6) | maxCost(16) | policyId(32) | accountCodeHash(32) |
 * signature(65).
 */
export function parsePaymasterAndData(
  paymasterAndData: Hex,
): ParsedPaymasterEnvelope {
  if (size(paymasterAndData) !== PLETHER_PAYMASTER_AND_DATA_BYTES) {
    throw new InvalidPerpsActionError(
      `Plether paymasterAndData must be ${PLETHER_PAYMASTER_AND_DATA_BYTES} bytes.`,
    );
  }

  const paymasterData = slice(paymasterAndData, 52, 209);
  return {
    paymasterAndData,
    paymaster: getAddress(slice(paymasterAndData, 0, 20)),
    paymasterVerificationGasLimit: hexToBigInt(slice(paymasterAndData, 20, 36)),
    paymasterPostOpGasLimit: hexToBigInt(slice(paymasterAndData, 36, 52)),
    paymasterData,
    validUntil: hexToBigInt(slice(paymasterAndData, 52, 58)),
    validAfter: hexToBigInt(slice(paymasterAndData, 58, 64)),
    maxCost: hexToBigInt(slice(paymasterAndData, 64, 80)),
    policyId: slice(paymasterAndData, 80, 112),
    accountCodeHash: slice(paymasterAndData, 112, 144),
    signature: slice(paymasterAndData, 144, 209),
  };
}

/** Applies the chain-manifest profile after structurally parsing a Plether envelope. */
export function validatePletherPaymasterEnvelope(
  envelope: ParsedPaymasterEnvelope,
  profile: PletherPaymasterProfile,
): ParsedPaymasterEnvelope {
  if (envelope.paymaster !== getAddress(profile.paymaster)) {
    throw new InvalidPerpsActionError(
      "Sponsorship response uses an unapproved paymaster.",
    );
  }
  if (envelope.policyId.toLowerCase() !== profile.policyId.toLowerCase()) {
    throw new InvalidPerpsActionError(
      "Sponsorship response uses an unapproved policy.",
    );
  }
  if (
    envelope.accountCodeHash.toLowerCase() !==
    profile.accountCodeHash.toLowerCase()
  ) {
    throw new InvalidPerpsActionError(
      "Sponsorship response uses an unapproved account runtime.",
    );
  }
  if (envelope.validUntil === 0n || envelope.validUntil <= envelope.validAfter) {
    throw new InvalidPerpsActionError(
      "Sponsorship response has an invalid validity window.",
    );
  }

  const maximumWindow = profile.maxValidityWindowSeconds;
  if (
    maximumWindow <= 0n ||
    maximumWindow > DEFAULT_MAX_VALIDITY_WINDOW_SECONDS
  ) {
    throw new InvalidPerpsActionError(
      "Paymaster profile maximum validity window must be between 1 and 600 seconds.",
    );
  }
  if (envelope.validUntil - envelope.validAfter > maximumWindow) {
    throw new InvalidPerpsActionError(
      "Sponsorship response validity window exceeds the approved maximum.",
    );
  }
  if (
    profile.paymasterVerificationGasLimit <= 0n ||
    profile.paymasterVerificationGasLimit > UINT128_MAX
  ) {
    throw new InvalidPerpsActionError(
      "Paymaster profile verification gas must fit a nonzero uint128.",
    );
  }
  if (
    envelope.paymasterVerificationGasLimit !==
    profile.paymasterVerificationGasLimit
  ) {
    throw new InvalidPerpsActionError(
      "Sponsorship response changed the approved paymaster verification gas.",
    );
  }
  if (profile.paymasterPostOpGasLimit !== 0n) {
    throw new InvalidPerpsActionError(
      "Plether paymaster profile must use zero postOp gas.",
    );
  }
  if (envelope.paymasterPostOpGasLimit !== profile.paymasterPostOpGasLimit) {
    throw new InvalidPerpsActionError(
      "Sponsorship response changed the approved paymaster postOp gas.",
    );
  }
  return envelope;
}
