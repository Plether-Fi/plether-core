export type PerpsClientErrorCode =
  | "INVALID_ACTION"
  | "ACTION_UNSUPPORTED"
  | "ACCOUNT_MISMATCH"
  | "USER_REJECTED"
  | "WALLET_UNSUPPORTED"
  | "SPONSOR_POLICY_DENIED"
  | "PAYMASTER_REJECTED"
  | "INSUFFICIENT_MARGIN"
  | "NO_OPEN_POSITION"
  | "NO_TRADER_CLAIM"
  | "TOO_MANY_PENDING_ORDERS"
  | "ORDER_INVALID"
  | "AUTHORIZATION_INVALID"
  | "BUNDLER_REJECTED"
  | "NETWORK_ERROR"
  | "UNKNOWN";

export class PerpsClientError extends Error {
  readonly code: PerpsClientErrorCode;
  readonly userMessage: string;
  readonly retryable: boolean;
  override readonly cause: unknown;

  constructor(input: {
    code: PerpsClientErrorCode;
    message: string;
    userMessage: string;
    retryable?: boolean;
    cause?: unknown;
  }) {
    super(input.message);
    this.name = "PerpsClientError";
    this.code = input.code;
    this.userMessage = input.userMessage;
    this.retryable = input.retryable ?? false;
    this.cause = input.cause;
  }
}

export class InvalidPerpsActionError extends PerpsClientError {
  constructor(message: string, cause?: unknown) {
    super({
      code: "INVALID_ACTION",
      message,
      userMessage: message,
      cause,
    });
    this.name = "InvalidPerpsActionError";
  }
}

export class UnsupportedPerpsActionError extends PerpsClientError {
  constructor(message: string) {
    super({
      code: "ACTION_UNSUPPORTED",
      message,
      userMessage: message,
    });
    this.name = "UnsupportedPerpsActionError";
  }
}

function errorText(value: unknown, depth = 0, seen = new Set<object>()): string {
  if (depth > 5 || value == null) return "";
  if (typeof value === "string" || typeof value === "number") return String(value);
  if (typeof value !== "object" || seen.has(value)) return "";

  seen.add(value);
  const record = value as Record<string, unknown>;
  return [
    record["name"],
    record["message"],
    record["shortMessage"],
    record["details"],
    record["code"],
    errorText(record["data"], depth + 1, seen),
    errorText(record["cause"], depth + 1, seen),
  ]
    .filter(Boolean)
    .join(" ");
}

/** Converts wallet, bundler, paymaster, and protocol failures into UI-safe errors. */
export function mapPerpsExecutionError(error: unknown): PerpsClientError {
  if (error instanceof PerpsClientError) return error;

  const text = errorText(error);
  const normalized = text.toLowerCase();
  const mapped = (
    code: PerpsClientErrorCode,
    userMessage: string,
    retryable = false,
  ) =>
    new PerpsClientError({
      code,
      message: text || "Unknown perps execution error",
      userMessage,
      retryable,
      cause: error,
    });

  if (/\b4001\b|user rejected|user denied|action_rejected/.test(normalized)) {
    return mapped("USER_REJECTED", "Signature request cancelled.");
  }
  if (/sign.?typed.?data.*(unsupported|not supported)|method not found.*typed/.test(normalized)) {
    return mapped(
      "WALLET_UNSUPPORTED",
      "This wallet cannot sign the USDC authorization required for a gasless first deposit.",
    );
  }
  if (/sponsor(ship)? (policy )?(denied|rejected)|policy_denied|not eligible/.test(normalized)) {
    return mapped(
      "SPONSOR_POLICY_DENIED",
      "This action is not eligible for sponsored gas. Check the action details or try again later.",
    );
  }
  if (/insufficientfreeequity|insufficientbalance|insufficient initial margin|insufficient margin/.test(normalized)) {
    return mapped(
      "INSUFFICIENT_MARGIN",
      "Not enough available USDC margin for this action.",
    );
  }
  if (/noopenposition|no open position/.test(normalized)) {
    return mapped("NO_OPEN_POSITION", "There is no open position to add margin to.");
  }
  if (/notraderclaim|no trader claim/.test(normalized)) {
    return mapped("NO_TRADER_CLAIM", "There is no trader claim available to settle.");
  }
  if (/toomanypendingorders|too many pending orders/.test(normalized)) {
    return mapped(
      "TOO_MANY_PENDING_ORDERS",
      "Pending-order limit reached. Wait for an order to be finalized before placing another.",
      true,
    );
  }
  if (/orderrouter__|commitvalidation|predictableopeninvalid|zero.?size/.test(normalized)) {
    return mapped(
      "ORDER_INVALID",
      "The order does not pass current market or risk checks. Review size, margin, side, and price limit.",
    );
  }
  if (/authorization.*(expired|used|invalid)|invalid.*authorization|eip.?3009/.test(normalized)) {
    return mapped(
      "AUTHORIZATION_INVALID",
      "The USDC authorization is invalid or expired. Sign a new deposit authorization.",
      true,
    );
  }
  if (/\baa3\d\b|paymaster|invalid sponsorship signature/.test(normalized)) {
    return mapped(
      "PAYMASTER_REJECTED",
      "Gas sponsorship could not be validated. Refresh the quote and try again.",
      true,
    );
  }
  if (/\baa\d\d\b|useroperation|bundler|entrypoint/.test(normalized)) {
    return mapped(
      "BUNDLER_REJECTED",
      "The sponsored transaction could not be submitted. Refresh and try again.",
      true,
    );
  }
  if (/network|fetch failed|timeout|timed out|connection/.test(normalized)) {
    return mapped("NETWORK_ERROR", "Network unavailable. Check your connection and try again.", true);
  }

  return mapped("UNKNOWN", "Something went wrong while submitting the action. Try again.", true);
}
