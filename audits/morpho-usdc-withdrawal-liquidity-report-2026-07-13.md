# Validated Morpho USDC Withdrawal Report

**Date:** 2026-07-13  
**Scope:** Deployed Plether `SyntheticSplitter` -> Plether `VaultAdapter` -> Morpho Vault V2 -> Morpho Blue  
**Verdict:** The deployed adapter can withdraw its USDC claim at the tested mainnet states. It is not unconditionally withdrawable at every future state.

## Executive conclusion

The claim that Plether's USDC is currently frozen is disproven for two pinned Ethereum states:

- At block [`25,523,545`](https://etherscan.io/block/25523545), an executable Foundry fork test called the actual deployed, owner-only `SyntheticSplitter.ejectLiquidity()` and recovered exactly `92,358.972355 USDC` into the splitter.
- At block [`25,523,645`](https://etherscan.io/block/25523645), an independent `eth_call` plus execution trace recovered exactly `92,359.166751 USDC` through the same deployed contracts.
- At block [`25,523,751`](https://etherscan.io/block/25523751), the final latest-state replay also succeeded with an explicit `2,000,000` gas cap and would redeem `92,359.382990 USDC`.

No mocks replaced the deployed Plether, Morpho Vault V2, Morpho liquidity-adapter, Morpho Blue, or USDC contracts. No transaction was broadcast.

One correction to the earlier report is important: “the full position was withdrawn” was slightly too broad. All Plether outer-adapter shares were redeemed, but nested ERC-4626 rounding left underlying-vault shares worth exactly one USDC base unit (`0.000001 USDC`) at block `25,523,545`. The economically withdrawable amount was therefore one micro-USDC below the adapter's pre-call `totalAssets()`.

That one-micro-USDC remainder is not directly extractable through the current outer adapter after the splitter's complete outer-share balance is burned, and [`rescueToken`](../src/VaultAdapter.sol#L177) deliberately prevents rescuing the protected underlying-vault share token. A later deposit could reincorporate the dust into share accounting. It is economically negligible but is disclosed here so “all” is not used imprecisely.

The future-state guarantee has a hard boundary. In a negative-control fork test, the selected Morpho market was driven to 100% utilization. The identical deployed `ejectLiquidity()` call then reverted with `insufficient liquidity` and moved no USDC or shares. After `200,000 USDC` was repaid, the same call succeeded. This proves both the working withdrawal path and its dependency on market liquidity.

Accordingly:

- **100% certain at the three pinned states:** the adapter's claim, minus one micro-USDC of rounding dust, was executable.
- **Not honestly guaranteeable for an arbitrary future block:** a transaction can fail if the configured liquidity market loses sufficient free USDC before execution.
- **Correct classification:** point-in-time withdrawable with a real external-liquidity availability risk; not a current freeze and not evidence of capital loss.

## Deployed contracts and selected market

| Component | Address / identifier | Verified relationship |
|---|---|---|
| Plether `SyntheticSplitter` | [`0x81D7...c2DF`](https://etherscan.io/address/0x81D7f6eE951f5272043de05E6EE25c58a440c2DF) | `owner()` and `yieldAdapter()` checked on the fork |
| Plether `VaultAdapter` | [`0x6E58...F682`](https://etherscan.io/address/0x6E58FC11d1fe09d7A2dfE60789d420b4D804F682) | `SPLITTER`, `VAULT`, `asset`, and `owner` checked |
| Morpho Vault V2 | [`0xbeef...a757`](https://etherscan.io/address/0xbeeff2C5bF38f90e3482a8b19F12E5a6D2FCa757) | Underlying vault held by Plether adapter |
| Vault V2 liquidity adapter | [`0xBfE7...6284`](https://etherscan.io/address/0xBfE734bAAb130048E20a64e800C4C2EC25756284) | Returned by `liquidityAdapter()` |
| Morpho Blue core | [`0xBBBB...FFCb`](https://etherscan.io/address/0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb) | Final source of the withdrawn USDC |
| USDC | [`0xA0b8...eB48`](https://etherscan.io/address/0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48) | Loan token and adapter asset |
| Splitter/adapter owner | [`0x5a71...0D6B`](https://etherscan.io/address/0x5a71a4094Ec81165Ada48AA4c27dA48ec27E0d6B) | Impersonated only inside the local fork |
| Selected liquidity market | `0xe83d72...36f52` | Encoded in Vault V2 `liquidityData()` |

The selected market parameters decoded from `liquidityData()` are:

| Parameter | Value |
|---|---|
| Loan token | USDC `0xA0b8...eB48` |
| Collateral | `0xC26A6Fa2C37b38E549a4a1807543801Db684f99C` |
| Oracle | `0x52eA2C12734B5bB61e1edf52Bb0f01D9206493Fc` |
| IRM | `0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC` |
| LLTV | `77%` |

The Vault V2 had 14 market positions, but its ordinary withdrawal path uses this one configured liquidity market. It does not automatically fall through to the other 13 positions if this market cannot supply the requested amount.

## Exactly how the USDC is withdrawn

For a complete emergency exit, the live call sequence is:

```text
Splitter owner
  -> SyntheticSplitter.ejectLiquidity()
  -> Plether VaultAdapter.redeem(all outer shares, splitter, splitter)
  -> Plether VaultAdapter._withdraw()
  -> Morpho VaultV2.withdraw(assets, Plether adapter, Plether adapter)
  -> VaultV2 deallocateInternal(configured liquidity adapter, shortfall)
  -> MorphoMarketV1AdapterV2.deallocate()
  -> Morpho Blue withdraw(selected market, assets)
  -> USDC: Morpho Blue -> liquidity adapter -> VaultV2
           -> Plether adapter -> SyntheticSplitter
```

The individual mechanics are:

1. `ejectLiquidity()` reads every Plether adapter share owned by the splitter and calls `redeem`. See [`SyntheticSplitter.ejectLiquidity`](../src/SyntheticSplitter.sol#L425).
2. OpenZeppelin ERC-4626 calculates the assets represented by those outer shares and enters Plether's [`VaultAdapter._withdraw`](../src/VaultAdapter.sol#L140).
3. Plether's adapter calls `VAULT.withdraw(assets, address(this), address(this))` before burning the outer shares and forwarding USDC to the splitter.
4. The Morpho Vault V2 first checks its send/receive gates. Both relevant checks returned `true` at the pinned states.
5. The vault had `0` raw USDC, so its `exit` path called `deallocateInternal` for the entire shortage.
6. `deallocateInternal` called the configured liquidity adapter. That adapter withdrew USDC from market `0xe83d72...36f52` on Morpho Blue and approved/returned it to Vault V2.
7. Vault V2 transferred USDC to the Plether adapter; the outer ERC-4626 then transferred it to the splitter and burned all Plether adapter shares.
8. `ejectLiquidity()` paused the splitter and emitted `EmergencyEjected(recovered)`. If redemption reverts, the transaction is atomic: no shares or USDC move, and the later pause is not reached.

This behavior matches Morpho's official [`VaultV2.sol`](https://github.com/morpho-org/vault-v2/blob/main/src/VaultV2.sol): its exit path deallocates a withdrawal shortfall through the configured liquidity adapter, and then transfers the assets to the receiver. Morpho's [liquidity-curation documentation](https://docs.morpho.org/curate/tutorials-v2/liquidity-curation/) describes the selected-liquidity-market model and its utilization constraint.

## Positive proof on deployed bytecode

### Four successful withdrawals actually mined on Ethereum

The live Plether adapter emitted four ERC-4626 `Withdraw` events before this investigation. In every event, `sender`, `receiver`, and `owner` are the deployed splitter. These are real transactions, not simulations:

| UTC time | Transaction | Assets withdrawn | Adapter shares burned |
|---|---|---:|---:|
| 2026-06-07 11:04:11 | [`0x9d0f...0e5e`](https://etherscan.io/tx/0x9d0f6e6528e2a6b3bc8254bf6d56c423f48806b04f00f47fc293607f6bc60e5e) | `121.005400 USDC` | `120.850915` |
| 2026-06-15 05:56:47 | [`0x48cc...9660`](https://etherscan.io/tx/0x48ccdd930dd2af4bbe0acccdab01a795f932f883db15e009a453656037959660) | `7.828806 USDC` | `7.809331` |
| 2026-06-27 20:33:11 | [`0xa31d...5325`](https://etherscan.io/tx/0xa31d7b46c31b6b69d36dd8257ba43202fd767a6667ee840a5822e0ce57e25325) | `151.103361 USDC` | `150.481123` |
| 2026-07-09 08:27:11 | [`0x5785...2a51`](https://etherscan.io/tx/0x5785d3cc002bae9e14cc94b4cfd38f37178e4bf4ad73a144ced317f92a3f2a51) | `146.003660 USDC` | `145.172790` |

The latest transaction's trace used the exact same route as the full-exit simulation. Every hop carried exactly `146.003660 USDC`: Morpho Blue -> liquidity adapter -> Vault V2 -> Plether adapter -> splitter. Historical small withdrawals alone would not prove that today's complete claim is liquid, which is why the full-position fork execution below remains necessary.

### Fork block 25,523,545

Pre-call state:

| Check | Result |
|---|---:|
| Splitter local USDC | `10,255.857723` |
| Plether adapter `totalAssets()` | `92,358.972356` |
| Plether adapter shares owned by splitter | `91,777.447531` |
| Raw USDC at Morpho Vault V2 | `0` |
| Underlying Vault V2 `maxWithdraw(Plether adapter)` | `0` |
| Plether adapter `maxWithdraw(splitter)` | Greater than zero |
| Selected-market free liquidity after accrual | `4,676,032.761028 USDC` |

The test impersonated the actual owner and called the actual deployed `ejectLiquidity()`. Post-call assertions proved:

| Assertion | Observed result |
|---|---:|
| USDC increase at splitter | `92,358.972355` |
| USDC decrease at Morpho Blue core | `92,358.972355` |
| Plether outer-adapter shares remaining | `0` |
| Raw USDC remaining at Plether adapter | `0` |
| Raw USDC remaining at Vault V2 | `0` |
| Underlying-vault share dust value | `0.000001 USDC` |
| Splitter paused | `true` |

The equal splitter inflow and Morpho-core outflow prove that the USDC was not fabricated by a test balance mutation and did not come from the splitter's pre-existing local buffer.

The repository's pre-existing fork tests were not sufficient evidence for this question: they instantiate fresh Plether contracts and/or target different Morpho vault addresses. The standalone validation therefore resolved the path from the deployed splitter and executed the live addresses listed above.

The execution trace included these exact calls for the `92,358.972355 USDC` withdrawal:

```text
VaultAdapter.redeem(91,777.447531 shares, splitter, splitter)
VaultV2.withdraw(92,358.972355 USDC, Plether adapter, Plether adapter)
LiquidityAdapter.deallocate(..., 92,358.972355 USDC, ...)
Morpho.withdraw(selected market, 92,358.972355 USDC, ..., liquidity adapter)
USDC.transfer: Morpho -> liquidity adapter -> VaultV2 -> Plether adapter -> splitter
```

### Independent later-state trace

At block `25,523,645`, a separate trace repeated the deployed exit and returned `92,359.166751 USDC`. After interest accrual, the selected market had:

| Metric | Amount |
|---|---:|
| Total supplied | `48,353,692.304433 USDC` |
| Total borrowed | `43,629,487.109128 USDC` |
| Selected liquidity adapter's supply position | `9,799,045.616505 USDC` |
| Market-wide free liquidity | `4,724,205.195305 USDC` |
| Executable ordinary-withdrawal liquidity, `min(position, free liquidity)` | `4,724,205.195305 USDC` |
| Plether adapter claim | `92,359.166752 USDC` |
| Executable-liquidity headroom over claim | `51.15x` |
| Claim as share of executable liquidity | `1.955%` |

Again, both Vault V2 and its liquidity adapter started with zero idle USDC. The selected adapter's own Morpho supply position exceeded market-wide free liquidity, so market cash—not adapter ownership—was the binding limit. The successful trace therefore necessarily sourced the requested USDC from Morpho Blue.

### Final latest-state replay

Immediately before this report was finalized, the complete owner call was replayed at block `25,523,751`, hash `0xf01f01bb38815032afa78056f8c8a91bc80428d0d67e6d381302f3922723a743` (2026-07-13 12:37:11 UTC):

| Check | Result |
|---|---:|
| Plether outer shares | `91,777.447531` |
| Adapter `totalAssets()` | `92,359.382991 USDC` |
| `previewRedeem(all shares)` | `92,359.382990 USDC` |
| Full owner `ejectLiquidity()` with 2,000,000 gas | Success |
| Estimated gas | `724,230` |
| Selected liquidity-adapter position | `9,799,068.479640 USDC` |

This final replay was an `eth_call`; it did not broadcast or mutate mainnet.

## Negative control: when the same withdrawal fails

To test causality rather than merely observe one successful call, the fork test:

1. accrued the selected market;
2. created a well-collateralized test borrower;
3. borrowed all `4,676,032.761028 USDC` of available liquidity, making supplied assets equal borrowed assets;
4. called the same deployed `ejectLiquidity()` from the same owner;
5. observed Morpho's `insufficient liquidity` revert;
6. verified that splitter USDC and adapter shares were unchanged;
7. repaid `200,000 USDC`; and
8. observed the same full ejection succeed.

This negative control rules out the mistaken interpretations that the successful exit came from hidden vault cash, that `maxWithdraw = 0` blocks all withdrawals, or that Vault V2 can always pull from another market. It also proves the precise failure condition: insufficient free USDC in the configured liquidity market at execution time.

## Why Morpho reports `maxWithdraw = 0`

Morpho Vault V2 deliberately returns zero from all four ERC-4626 `max*` functions. Its [official repository](https://github.com/morpho-org/vault-v2) documents this gate-related design. Therefore, `VaultV2.maxWithdraw(...) == 0` is not a live-liquidity quote and did not prevent either successful exit.

Plether's adapter instead returns the accounting value of the owner's outer shares from [`maxWithdraw`](../src/VaultAdapter.sol#L76). This has the opposite limitation: it can report the full accounting claim even when the selected market is temporarily illiquid. The only authoritative point-in-time answer is a fresh simulation or execution against the exact intended state.

## USDC issuer-freeze check

At block `25,523,545`, `USDC.isBlacklisted(address)` returned `false` for the splitter, Plether adapter, Vault V2, liquidity adapter, and Morpho Blue core. There was no Circle blacklist freeze on the custody path.

## User-redemption and operator implications

- User burns covered by the splitter's local USDC do not touch Morpho.
- A larger burn invokes [`SyntheticSplitter._withdrawFromAdapter`](../src/SyntheticSplitter.sol#L347), first trying `withdraw` and then a share-adjusted `redeem` fallback. Both ultimately depend on the same Vault V2 liquidity path.
- `ejectLiquidity()` is atomic and asks for the complete outer-adapter position. If the selected market cannot cover it, the call reverts.
- While paused, the owner can call [`withdrawFromAdapter(amount)`](../src/SyntheticSplitter.sol#L447) for smaller extractions, but the reported `maxWithdraw` is an accounting value rather than guaranteed executable liquidity.
- An adapter migration also redeems the old position atomically before depositing into the replacement, so migration can be delayed by the same condition.
- Borrower repayment, liquidation, new supply, or curator/allocator action can restore liquidity. Morpho V2 also documents `forceDeallocate` and in-kind exits, but Plether's current adapter does not expose those as a Plether-native recovery flow. See Morpho's [Vault V2 concepts](https://docs.morpho.org/learn/concepts/vault-v2/).

Temporary illiquidity is an availability problem, not by itself a loss of USDC. A solvency finding would require separate evidence such as bad debt, a broken market/adapter, or a realized write-off.

## Reproducible validation

The standalone fork suite contains three tests:

```text
test_IdentityAndWithdrawalPreconditions
test_FullEmergencyEjectMovesUSDCFromMorphoAndBurnsShares
test_WithdrawalFailsAtFullUtilizationAndRecoversAfterRepayment
```

Run result: **3 passed, 0 failed**.

Validation artifact:

```text
/private/tmp/codex-security-scans/plether-core/
  c785b4d1d2c0_20260713T121523Z/artifacts/05_findings/
  MORPHO-WITHDRAW-001/validation_artifacts/fork-proof/
```

Reproduction command from that directory:

```bash
MAINNET_RPC_URL=<archive-capable Ethereum RPC> \
  forge test --match-path test/DeployedWithdrawalValidation.t.sol -vv
```

## Chat-history finding

The earlier discussion was in Codex task `019e4f45-bbe8-7113-88ea-28d8f0225b1a`, titled **“Audit src/perps dex”**, on 2026-05-29. It included the request:

> make sure that we can safely deploy all funds to the adapter and we will be able to withdraw them later

That discussion tested `deployToAdapter()` followed by `ejectLiquidity()` on a mainnet fork and warned that later withdrawals still depend on Morpho liquidity. It did not document a confirmed frozen balance. A separate perps discussion involving `withdrawable = 0` concerned an oracle-freshness condition and was unrelated to this yield adapter.

## Operational metadata issue

The repository's deployment metadata does not describe the live path correctly:

- `deployments/mainnet.json` records adapter `0x9945E377...` and external vault `0x9a1D6bd5...`;
- `script/PoolDashboard.s.sol` also hard-codes adapter `0x9945E377...`;
- the deployed splitter returns adapter `0x6E58FC11...`, which points to Vault V2 `0xbeeff2C5...`.

This drift does not freeze funds, but monitoring or incident simulations can inspect the wrong contracts. The live `splitter.yieldAdapter()` value should be authoritative until the records are reconciled.

## Recommendations

1. Monitor a fresh `eth_call` of representative redemption, partial adapter withdrawal, and complete `ejectLiquidity()` against the latest block.
2. Alert on selected-market free liquidity versus the full Plether claim, not on Vault V2's intentionally-zero `maxWithdraw`.
3. Stop additional deployments and consider pausing if the headroom approaches the amount needed for expected redemptions.
4. Add an operator runbook for partial withdrawals, curator coordination, and Morpho's alternative deallocation/in-kind mechanisms.
5. Reconcile the stale deployed-address metadata.
6. Preserve the adversarial mainnet-fork test as a regression test if this operational dependency is accepted.

## Assurance boundary

This report establishes executable withdrawability at blocks `25,523,545`, `25,523,645`, and `25,523,751`, with actual deployed code and a causal negative control. It cannot establish permanent future liquidity because market utilization, gates, allocations, share price, and transaction ordering are mutable. “Always withdrawable regardless of future Morpho state” is false by construction and was disproven by the 100%-utilization test.

No historical failed transaction hash was supplied or found in the relevant task history, so this report does not rule out a short-lived failure at an unspecified earlier block. It does rule out the assertion that the position was unwithdrawable at the three tested states.
