import type { Address } from "viem";

import type { PerpsActionKind } from "./types.js";

export interface WalletCapabilities {
  /** EIP-712 signing is needed only when USDC starts in the owner EOA. */
  readonly canSignTypedData: boolean;
}

export interface SmartAccountCapabilities {
  readonly accountAddress: Address;
  readonly canExecuteBatch: boolean;
  readonly entryPointVersion: "0.8";
}

export interface SponsorCapabilities {
  readonly available: boolean;
  readonly sponsoredActions: ReadonlySet<PerpsActionKind>;
}

export interface TokenCapabilities {
  readonly supportsReceiveWithAuthorization: boolean;
}

export interface ActionCapability {
  readonly supported: boolean;
  readonly sponsored: boolean;
  readonly reason?: string;
}

export interface PerpsCapabilities {
  /** MetaMask/Rabby/Trust remains the owner/signature UI. */
  readonly ownerWalletRemainsConnected: true;
  /** Protocol state is keyed by the smart account because contracts use msg.sender. */
  readonly smartAccountIsCanonicalTrader: true;
  readonly firstDeposit: ActionCapability;
  readonly placeOrder: ActionCapability;
  readonly cancelOrder: ActionCapability;
  readonly addMargin: ActionCapability;
  readonly withdraw: ActionCapability;
  readonly withdrawToOwner: ActionCapability;
  readonly settleClaim: ActionCapability;
}

export function derivePerpsCapabilities(input: {
  readonly wallet: WalletCapabilities;
  readonly smartAccount: SmartAccountCapabilities;
  readonly sponsor: SponsorCapabilities;
  readonly token: TokenCapabilities;
}): PerpsCapabilities {
  const sponsorship = (action: PerpsActionKind) =>
    input.sponsor.available && input.sponsor.sponsoredActions.has(action);
  const batch = input.smartAccount.canExecuteBatch;
  const firstDepositSupported =
    batch && input.wallet.canSignTypedData && input.token.supportsReceiveWithAuthorization;

  const normal = (action: PerpsActionKind): ActionCapability => ({
    supported: true,
    sponsored: sponsorship(action),
    ...(!sponsorship(action) && {
      reason: "Gas sponsorship is currently unavailable for this action.",
    }),
  });

  return {
    ownerWalletRemainsConnected: true,
    smartAccountIsCanonicalTrader: true,
    firstDeposit: {
      supported: firstDepositSupported,
      sponsored: firstDepositSupported && sponsorship("deposit"),
      ...(!firstDepositSupported && {
        reason: !batch
          ? "The selected smart account cannot atomically batch the deposit."
          : !input.wallet.canSignTypedData
            ? "The connected wallet cannot sign the USDC EIP-3009 authorization."
            : "Configured USDC does not support receiveWithAuthorization.",
      }),
      ...(firstDepositSupported && !sponsorship("deposit") && {
        reason: "Gas sponsorship is currently unavailable for deposits.",
      }),
    },
    placeOrder: normal("place-order"),
    cancelOrder: {
      supported: false,
      sponsored: false,
      reason: "Committed orders are binding and have no trader cancellation endpoint.",
    },
    addMargin: normal("add-margin"),
    withdraw: normal("withdraw"),
    withdrawToOwner: normal("withdraw-to-owner"),
    settleClaim: normal("settle-claim"),
  };
}
