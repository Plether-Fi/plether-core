import { describe, expect, it } from "vitest";
import {
  concatHex,
  keccak256,
  numberToHex,
  size,
  type Address,
  type Hex,
} from "viem";

import {
  hashPletherSponsorship,
  normalizePaymasterResponse,
  parsePaymasterAndData,
  PLETHER_PAYMASTER_AND_DATA_BYTES,
  PLETHER_PAYMASTER_DATA_BYTES,
  PLETHER_SPONSORSHIP_TYPEHASH,
  validatePletherPaymasterEnvelope,
} from "../src/index.js";

const paymaster = "0x7777777777777777777777777777777777777777" as Address;
const policyId = `0x${"42".repeat(32)}` as Hex;
const accountCodeHash = `0x${"24".repeat(32)}` as Hex;
const signature = `0x${"99".repeat(65)}` as Hex;

function paymasterData(validUntil = 1_000n): Hex {
  return concatHex([
    numberToHex(validUntil, { size: 6 }),
    numberToHex(100n, { size: 6 }),
    numberToHex(500_000n, { size: 16 }),
    policyId,
    accountCodeHash,
    signature,
  ]);
}

describe("Plether v0.8 paymaster envelope", () => {
  it("normalizes the split EIP-7677 response", () => {
    const parsed = normalizePaymasterResponse({
      paymaster,
      paymasterVerificationGasLimit: "0x0186a0",
      paymasterPostOpGasLimit: 55_000n,
      paymasterData: paymasterData(),
    });

    expect(size(parsed.paymasterData)).toBe(PLETHER_PAYMASTER_DATA_BYTES);
    expect(size(parsed.paymasterAndData)).toBe(PLETHER_PAYMASTER_AND_DATA_BYTES);
    expect(parsed.paymaster).toBe(paymaster);
    expect(parsed.paymasterVerificationGasLimit).toBe(100_000n);
    expect(parsed.paymasterPostOpGasLimit).toBe(55_000n);
    expect(parsed.validUntil).toBe(1_000n);
    expect(parsed.validAfter).toBe(100n);
    expect(parsed.maxCost).toBe(500_000n);
    expect(parsed.policyId).toBe(policyId);
    expect(parsed.accountCodeHash).toBe(accountCodeHash);
    expect(parsed.signature).toBe(signature);
  });

  it("parses a pre-packed response with the identical layout", () => {
    const packed = concatHex([
      paymaster,
      numberToHex(100_000n, { size: 16 }),
      numberToHex(55_000n, { size: 16 }),
      paymasterData(2_000n),
    ]);
    expect(parsePaymasterAndData(packed).validUntil).toBe(2_000n);
    expect(normalizePaymasterResponse({ paymasterAndData: packed }).signature).toBe(signature);
  });

  it("reuses stub gas limits for a standards-compatible final response", () => {
    const stub = normalizePaymasterResponse({
      paymaster,
      paymasterVerificationGasLimit: 100_000n,
      paymasterPostOpGasLimit: 55_000n,
      paymasterData: paymasterData(1_000n),
    });
    const final = normalizePaymasterResponse(
      { paymaster, paymasterData: paymasterData(2_000n) },
      stub,
    );

    expect(final.validUntil).toBe(2_000n);
    expect(final.paymasterVerificationGasLimit).toBe(100_000n);
    expect(final.paymasterPostOpGasLimit).toBe(55_000n);

    expect(() =>
      normalizePaymasterResponse(
        {
          paymaster: "0x8888888888888888888888888888888888888888",
          paymasterData: paymasterData(2_000n),
        },
        stub,
      ),
    ).toThrow(/cannot change the paymaster/i);

    expect(() =>
      normalizePaymasterResponse(
        {
          paymaster,
          paymasterVerificationGasLimit: 100_001n,
          paymasterPostOpGasLimit: 55_000n,
          paymasterData: paymasterData(2_000n),
        },
        stub,
      ),
    ).toThrow(/cannot change paymaster gas limits/i);
  });

  it("rejects variable-length stubs that could change estimation behavior", () => {
    expect(() =>
      normalizePaymasterResponse({
        paymaster,
        paymasterVerificationGasLimit: 1n,
        paymasterPostOpGasLimit: 1n,
        paymasterData: "0x1234",
      }),
    ).toThrow(/157 bytes/);
    expect(() => parsePaymasterAndData("0x1234")).toThrow(/209 bytes/);
  });

  it("validates the manifest-pinned paymaster profile and validity ceiling", () => {
    const parsed = normalizePaymasterResponse({
      paymaster,
      paymasterVerificationGasLimit: 100_000n,
      paymasterPostOpGasLimit: 0n,
      paymasterData: paymasterData(600n),
    });
    const profile = {
      chainId: 421_614,
      entryPoint:
        "0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108" as Address,
      paymaster,
      policyId,
      accountCodeHash,
      paymasterVerificationGasLimit: 100_000n,
      paymasterPostOpGasLimit: 0n,
      maxValidityWindowSeconds: 600n,
    };

    expect(validatePletherPaymasterEnvelope(parsed, profile)).toBe(parsed);
    expect(() =>
      validatePletherPaymasterEnvelope(parsed, {
        ...profile,
        policyId: `0x${"11".repeat(32)}`,
      }),
    ).toThrow(/unapproved policy/i);

    const tooLong = normalizePaymasterResponse({
      paymaster,
      paymasterVerificationGasLimit: 100_000n,
      paymasterPostOpGasLimit: 0n,
      paymasterData: paymasterData(701n),
    });
    expect(() =>
      validatePletherPaymasterEnvelope(tooLong, profile),
    ).toThrow(/validity window exceeds/i);
    expect(() =>
      validatePletherPaymasterEnvelope(parsed, {
        ...profile,
        maxValidityWindowSeconds: 601n,
      }),
    ).toThrow(/between 1 and 600 seconds/i);
    expect(() =>
      validatePletherPaymasterEnvelope(parsed, {
        ...profile,
        paymasterPostOpGasLimit: 1n,
      }),
    ).toThrow(/zero postOp gas/i);
  });

  it("matches the independent Solidity EIP-712 digest fixture", () => {
    const fixturePaymaster =
      "0x1111111111111111111111111111111111111111" as Address;
    const fixtureAccount =
      "0x2222222222222222222222222222222222222222" as Address;
    const fixturePolicyId =
      "0x998b46b747647acb0e13177c7c5e2531452f3ac9c8b0cce56f2b0fdbfdf37781" as Hex;
    const fixtureAccountCodeHash = keccak256("0x60006000f3");
    const fixturePaymasterAndData = concatHex([
      fixturePaymaster,
      numberToHex(100_000n, { size: 16 }),
      numberToHex(40_000n, { size: 16 }),
      numberToHex(1_900_000_000n, { size: 6 }),
      numberToHex(1_800_000_000n, { size: 6 }),
      numberToHex(1_000_000_000_000_000n, { size: 16 }),
      fixturePolicyId,
      fixtureAccountCodeHash,
      `0x${"00".repeat(65)}` as Hex,
    ]);

    expect(PLETHER_SPONSORSHIP_TYPEHASH).toBe(
      "0x5835c142c681b663470a1a53c34b0ba256a8283b7b9f9560aadb85711d252918",
    );
    expect(
      hashPletherSponsorship({
        chainId: 421_614,
        entryPoint:
          "0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108",
        userOperation: {
          sender: fixtureAccount,
          nonce: 7n,
          initCode: "0x",
          callData: "0xdeadbeef",
          accountGasLimits: numberToHex(
            (250_000n << 128n) | 500_000n,
            { size: 32 },
          ),
          preVerificationGas: 75_000n,
          gasFees: numberToHex(
            (1_000_000_000n << 128n) | 2_000_000_000n,
            { size: 32 },
          ),
          paymasterAndData: fixturePaymasterAndData,
        },
      }),
    ).toBe(
      "0xd92042495de3ae32c76391a73aeb6bfaf515af2dd3da45c9a8921b5310cde1ea",
    );
  });
});
