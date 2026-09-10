import type { Address, Hex } from "viem";

export type PerpsActionKind =
  | "deposit"
  | "place-order"
  | "place-protected-order"
  | "create-protection"
  | "replace-protection"
  | "cancel-protection"
  | "cancel-order"
  | "add-margin"
  | "withdraw"
  | "withdraw-to-owner"
  | "settle-claim";

/** A call that must be executed by the smart account, never by its owner EOA. */
export interface SmartAccountCall {
  readonly to: Address;
  readonly value: bigint;
  readonly data: Hex;
}

/**
 * A complete protocol action. `account` is the canonical onchain trader identity
 * and is checked against the smart-account adapter before submission.
 */
export interface PerpsActionPlan {
  readonly kind: PerpsActionKind;
  readonly account: Address;
  readonly calls: readonly SmartAccountCall[];
}

export interface Eip7677PaymasterResponse {
  readonly paymasterAndData?: Hex;
  readonly paymaster?: Address;
  readonly paymasterData?: Hex;
  readonly paymasterVerificationGasLimit?: bigint | Hex;
  readonly paymasterPostOpGasLimit?: bigint | Hex;
}

export interface ParsedPaymasterEnvelope {
  readonly paymasterAndData: Hex;
  readonly paymaster: Address;
  readonly paymasterVerificationGasLimit: bigint;
  readonly paymasterPostOpGasLimit: bigint;
  readonly paymasterData: Hex;
  readonly validUntil: bigint;
  readonly validAfter: bigint;
  readonly maxCost: bigint;
  readonly policyId: Hex;
  readonly accountCodeHash: Hex;
  readonly signature: Hex;
}

export interface PletherPaymasterProfile {
  readonly chainId: number;
  readonly entryPoint: Address;
  readonly paymaster: Address;
  readonly policyId: Hex;
  readonly accountCodeHash: Hex;
  readonly paymasterVerificationGasLimit: bigint;
  readonly paymasterPostOpGasLimit: bigint;
  readonly maxValidityWindowSeconds: bigint;
}

/** Packed v0.8 fields committed by the Plether sponsorship signature. */
export interface SponsorshipUserOperation {
  readonly sender: Address;
  readonly nonce: bigint | Hex;
  readonly initCode: Hex;
  readonly callData: Hex;
  readonly accountGasLimits: Hex;
  readonly preVerificationGas: bigint | Hex;
  readonly gasFees: Hex;
  readonly paymasterAndData: Hex;
}

export interface SmartAccountAdapter<TOperation, TGasEstimate> {
  /** Counterfactual or deployed smart-account address used as `msg.sender`. */
  readonly accountAddress: Address;
  readonly entryPoint: Address;

  /**
   * May retain an adapter-local dummy account signature for bundler estimation.
   * Sponsor adapters must omit that field from both ERC-7677 RPC requests.
   */
  buildUserOperation(input: {
    readonly chainId: number;
    readonly calls: readonly SmartAccountCall[];
  }): Promise<TOperation>;

  applyPaymaster(
    operation: TOperation,
    sponsorship: ParsedPaymasterEnvelope,
  ): TOperation;

  applyGasEstimate(operation: TOperation, estimate: TGasEstimate): TOperation;

  /** Called only after final paymaster data and all gas fields are present. */
  signUserOperation(operation: TOperation): Promise<TOperation>;
}

export interface SponsorAdapter<TOperation> {
  /** Serialize `operation` as the unsigned ERC-7677 shape, without `signature`. */
  getPaymasterStubData(input: {
    readonly chainId: number;
    readonly entryPoint: Address;
    readonly account: Address;
    readonly action: PerpsActionKind;
    readonly operation: TOperation;
  }): Promise<Eip7677PaymasterResponse>;

  /** Serialize `operation` as the unsigned ERC-7677 shape, without `signature`. */
  getPaymasterData(input: {
    readonly chainId: number;
    readonly entryPoint: Address;
    readonly account: Address;
    readonly action: PerpsActionKind;
    readonly operation: TOperation;
  }): Promise<Eip7677PaymasterResponse>;
}

export interface BundlerAdapter<TOperation, TGasEstimate, TReceipt> {
  estimateUserOperationGas(input: {
    readonly operation: TOperation;
    readonly entryPoint: Address;
  }): Promise<TGasEstimate>;

  sendUserOperation(input: {
    readonly operation: TOperation;
    readonly entryPoint: Address;
  }): Promise<Hex>;

  waitForUserOperationReceipt?(input: {
    readonly userOperationHash: Hex;
  }): Promise<TReceipt>;
}

export type SponsoredExecutionStatus =
  | "building"
  | "requesting-stub"
  | "estimating"
  | "requesting-sponsorship"
  | "awaiting-signature"
  | "journaling"
  | "submitting"
  | "confirming"
  | "confirmed";

export interface SponsoredExecutionResult<TReceipt> {
  readonly userOperationHash: Hex;
  readonly receipt?: TReceipt;
}
