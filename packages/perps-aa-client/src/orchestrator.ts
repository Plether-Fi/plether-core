import { getAddress, type Address, type Hex } from "viem";

import {
  InvalidPerpsActionError,
  PerpsClientError,
  mapPerpsExecutionError,
} from "./errors.js";
import {
  normalizePaymasterResponse,
  validatePletherPaymasterEnvelope,
} from "./paymaster.js";
import type {
  BundlerAdapter,
  PerpsActionPlan,
  PletherPaymasterProfile,
  SmartAccountAdapter,
  SponsorAdapter,
  SponsoredExecutionResult,
  SponsoredExecutionStatus,
} from "./types.js";

export interface SendSponsoredActionInput<TOperation, TGasEstimate, TReceipt> {
  readonly chainId: number;
  readonly action: PerpsActionPlan;
  readonly account: SmartAccountAdapter<TOperation, TGasEstimate>;
  readonly sponsor: SponsorAdapter<TOperation>;
  readonly bundler: BundlerAdapter<TOperation, TGasEstimate, TReceipt>;
  readonly paymasterProfile: PletherPaymasterProfile;
  /**
   * Must durably persist the exact signed operation before resolving. It returns
   * the locally computed EntryPoint v0.8 UserOperation hash.
   */
  readonly journalSignedUserOperation: (input: {
    readonly operation: TOperation;
    readonly entryPoint: Address;
  }) => Promise<Hex>;
  readonly waitForReceipt?: boolean;
  readonly onStatus?: (status: SponsoredExecutionStatus) => void;
}

/**
 * Executes the ERC-7677/ERC-4337 sequence in signature-safe order. The final
 * paymaster data is installed before the owner signs the UserOperation.
 */
export async function sendSponsoredAction<TOperation, TGasEstimate, TReceipt>(
  input: SendSponsoredActionInput<TOperation, TGasEstimate, TReceipt>,
): Promise<SponsoredExecutionResult<TReceipt>> {
  const status = (next: SponsoredExecutionStatus) => input.onStatus?.(next);

  try {
    const planAccount = getAddress(input.action.account);
    const adapterAccount = getAddress(input.account.accountAddress);
    if (planAccount !== adapterAccount) {
      throw new PerpsClientError({
        code: "ACCOUNT_MISMATCH",
        message: `Action is bound to ${planAccount}, but adapter executes as ${adapterAccount}.`,
        userMessage: "Switch back to the smart account that owns this perps account.",
      });
    }
    if (input.chainId !== input.paymasterProfile.chainId) {
      throw new InvalidPerpsActionError(
        "Action chain does not match the approved paymaster profile.",
      );
    }
    if (
      getAddress(input.account.entryPoint) !==
      getAddress(input.paymasterProfile.entryPoint)
    ) {
      throw new InvalidPerpsActionError(
        "Smart-account EntryPoint does not match the approved paymaster profile.",
      );
    }
    if (input.waitForReceipt && !input.bundler.waitForUserOperationReceipt) {
      throw new InvalidPerpsActionError(
        "waitForReceipt requires a bundler receipt adapter.",
      );
    }

    status("building");
    // `TOperation` represents a concrete adapter payload, not a nested Promise.
    // It may retain a dummy account signature for bundler estimation; the
    // SponsorAdapter must omit that field from its unsigned ERC-7677 requests.
    // The assertion prevents TypeScript's generic `Awaited<T>` from widening it.
    let operation = (await input.account.buildUserOperation({
      chainId: input.chainId,
      calls: input.action.calls,
    })) as TOperation;

    status("requesting-stub");
    const stub = validatePletherPaymasterEnvelope(
      normalizePaymasterResponse(
        await input.sponsor.getPaymasterStubData({
          chainId: input.chainId,
          entryPoint: input.account.entryPoint,
          account: adapterAccount,
          action: input.action.kind,
          operation,
        }),
      ),
      input.paymasterProfile,
    );
    operation = input.account.applyPaymaster(operation, stub);

    status("estimating");
    const estimate = await input.bundler.estimateUserOperationGas({
      operation,
      entryPoint: input.account.entryPoint,
    });
    operation = input.account.applyGasEstimate(operation, estimate);

    status("requesting-sponsorship");
    const sponsorship = validatePletherPaymasterEnvelope(
      normalizePaymasterResponse(
        await input.sponsor.getPaymasterData({
          chainId: input.chainId,
          entryPoint: input.account.entryPoint,
          account: adapterAccount,
          action: input.action.kind,
          operation,
        }),
        stub,
      ),
      input.paymasterProfile,
    );
    operation = input.account.applyPaymaster(operation, sponsorship);

    status("awaiting-signature");
    const signedOperation = await input.account.signUserOperation(operation);

    status("journaling");
    const expectedUserOperationHash = await input.journalSignedUserOperation({
      operation: signedOperation,
      entryPoint: input.account.entryPoint,
    });

    status("submitting");
    const userOperationHash: Hex = await input.bundler.sendUserOperation({
      operation: signedOperation,
      entryPoint: input.account.entryPoint,
    });
    if (userOperationHash.toLowerCase() !== expectedUserOperationHash.toLowerCase()) {
      throw new InvalidPerpsActionError(
        "Bundler returned a UserOperation hash that does not match the journaled operation.",
      );
    }

    if (!input.waitForReceipt) return { userOperationHash };

    status("confirming");
    const receipt = await input.bundler.waitForUserOperationReceipt!({
      userOperationHash,
    });
    status("confirmed");
    return { userOperationHash, receipt };
  } catch (error) {
    throw mapPerpsExecutionError(error);
  }
}
