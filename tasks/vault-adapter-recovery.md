# Recovery of ~$109k from Bricked VaultAdapter

## Status: BLOCKED — Awaiting Morpho Team Response

## Key Addresses
| Role | Address |
|------|---------|
| VaultAdapter (stuck) | `0x9Bc4D704975a067979512bcE24fB54479F415122` |
| Morpho Vault V2 | `0x9a1D6bd5b8642C41F25e0958129B85f8E1176F3e` |
| Adapter owner (Safe) | `0x715251c1e0f98955c982aa7b1EFc273c57Cc67CB` |
| V2 shares held | 106,296e18 (~$108,941 USDC) |

## Root Cause
Morpho Vault V2's `maxWithdraw()`/`maxRedeem()` are `pure` functions returning 0 (documented design choice). OpenZeppelin's ERC4626 base class enforces `maxWithdraw` check before `_withdraw()`, creating a deadlock. V2's actual `withdraw()` works fine — the block is purely our OZ wrapper guard.

## Exhaustive Path Analysis — All Blocked

**Direct adapter calls**: OZ guard, `CannotRescueUnderlying`, `CannotRescueVaultShares`, `ForbiddenTarget`
**claimRewards indirect**: Can't call V2 (ForbiddenTarget), can't approve third parties (same reason)
**Splitter paths**: `ejectLiquidity` → OZ guard, `withdrawFromAdapter` → maxWithdraw=0, `finalizeAdapter` → OZ guard
**Cryptographic**: V2 permit uses ecrecover (no EIP-1271), adapter can't sign ECDSA
**Protocol-level**: V2 is immutable (no proxy), adapter is immutable, V2 roles can't move shareholder funds

## Verdict
No on-chain self-rescue path exists. Funds are safe and earning yield, but inaccessible.

## Action Item: Contact Morpho Team
Send the message below via Morpho Discord or direct contact.

---

## Draft Message to Morpho Team

**Subject: ~$109k stuck in ERC4626 wrapper due to Vault V2 maxWithdraw() returning 0**

Hi Morpho team,

We're the Plether protocol team. We have ~$109k in USDC stuck in our ERC4626 VaultAdapter contract that wraps your Morpho Vault V2 at `0x9a1D6bd5b8642C41F25e0958129B85f8E1176F3e`.

**What happened:**
Our VaultAdapter is an OpenZeppelin ERC4626 wrapper around your vault. It was deployed when the underlying was V1 (MetaMorpho), where `maxWithdraw()` returned actual values. After the vault upgraded to V2, `maxWithdraw()` became `pure` returning 0. OpenZeppelin's ERC4626 `withdraw()`/`redeem()` check `maxWithdraw()`/`maxRedeem()` before executing `_withdraw()`, so all withdrawals now revert.

**On-chain proof that the withdrawal would work:**

```
# V2's withdraw succeeds in static call (adapter as msg.sender):
cast call 0x9a1D6bd5b8642C41F25e0958129B85f8E1176F3e \
  "withdraw(uint256,address,address)(uint256)" 1000000 \
  0x715251c1e0f98955c982aa7b1EFc273c57Cc67CB \
  0x9Bc4D704975a067979512bcE24fB54479F415122 \
  --from 0x9Bc4D704975a067979512bcE24fB54479F415122
# Returns: 975720009379350382 (valid shares to burn)

# Gates are open:
canSendShares(adapter) = true
canReceiveAssets(receiver) = true
sendSharesGate = address(0)
```

V2's `withdraw()` doesn't check `maxWithdraw()` internally — it goes straight to `exit()`. The block is purely our wrapper's OZ guard.

**Why we can't self-rescue:**
Our adapter has a `claimRewards(target, data)` function for arbitrary external calls, but it blocks `target == address(VAULT)` as a safety measure. This prevents us from calling V2's `withdraw()`, `transfer()`, or `approve()` directly. We've exhausted every indirect path (helper contracts, Permit2, reentrancy, EIP-2612 permit — all blocked by the same restriction or by V2's allowance requirements).

**Key addresses:**
- VaultAdapter (stuck): `0x9Bc4D704975a067979512bcE24fB54479F415122`
- Morpho Vault V2: `0x9a1D6bd5b8642C41F25e0958129B85f8E1176F3e`
- V2 shares held: 106,296e18 (~$108,941 USDC)
- Adapter owner (Safe multisig): `0x715251c1e0f98955c982aa7b1EFc273c57Cc67CB`

**What we're asking:**
1. Is there any V2 mechanism we've missed that could help (a bundler, migration tool, admin function)?
2. Are you aware of other integrators affected by `maxWithdraw()=0` breaking ERC4626 composability?
3. If a V3 vault is planned, would there be a migration path that could unblock stuck wrappers?

The funds are safe and earning yield — we just can't withdraw them. Any guidance would be appreciated.

---

## Fallback
Accept that the ~$109k is trapped but earning yield. Not lost, just inaccessible until Morpho provides a path.
