# Across direct-funding validation fixture

`AcrossDirectFunding.t.sol` executes the **exact deployed Arbitrum MulticallHandler and AcrossEventEmitter runtimes**,
installed at their public addresses with `vm.etch`. The clearinghouse is the local production implementation; the settlement token is a controlled
USDC-behavior mock. This is an offline handler integration test, not a mainnet fork, live quote, or SpokePool fill test.

## Provenance

- Handler: `0x0F7Ae28dE1C8532170AD4ee566B5801485c13a0E`, chain 42161.
- Runtime keccak256: `0x2a70f9d1b1c80cc0430bbffe16283cf067d915bee05f9812715cd94ad082b76a` (3,758 bytes).
- Official Arbitrum RPC returned that runtime at block 513212465, hash
  `0x8e8ddbe6f595d1cdfb50e2d41cccf4adef6b685756cd25b46ebaac9dca4715b8`.
- The [official deployment registry](https://github.com/across-protocol/contracts/blob/950e9154f3d61e59590eb7d4403fae5d3cae84f8/broadcast/deployed-addresses.json)
  and [contract address documentation](https://docs.across.to/chains-and-contracts) identify this handler.
- `MulticallHandler.deployed.sol.txt` is the unmodified verified main source, identical to the
  [official source at commit d7c4413](https://github.com/across-protocol/contracts/blob/d7c441300c65a4590d1b0288cbe4eb97c4eea549/contracts/handlers/MulticallHandler.sol).
  The runtime matches both the on-chain and recompiled bytecode in the Sourcify exact-match record.
- `provenance.json` records compiler settings, source hash, deployment transaction, and evidence URLs. The test
  initializes the verified storage layout's sole constructor state, `ReentrancyGuard._status` in slot zero, to 1.
- Emitter: `0xBF75133b48b0a42AB9374027902E83C5E2949034`; runtime keccak256
  `0x833b49ceddf001f197603e23297ddc21147b7d9e61adbe812e1167b3a7fe2fe5` (302 bytes). Official Arbitrum RPC returned
  that runtime at block 513217007, hash `0x5a34ad0c35414c86e7529d77f14279d4554c46673f7f519ab224555131deaa82`.
  It equals Sourcify's on-chain and recompiled bytecode. `AcrossEventEmitter.deployed.sol.txt` equals the
  [official source at commit e628982](https://github.com/across-protocol/contracts/blob/e628982ea5043f77708bc416b65a3ec7bc0c0575/contracts/AcrossEventEmitter.sol).
  `emitter-provenance.json` records its source, compiler and deployment evidence. The emitter has no constructor state.

Do not substitute the older handler address shown in some embedded-action examples or recompile the latest source
and describe it as this deployed runtime. The pinned deployed version supports both fallback and dynamic balances.

## Message validated by the tests

ABI-encode one `Instructions` tuple:

```text
((address target, bytes callData, uint256 value)[] calls, address fallbackRecipient)
```

The four mandatory calls are:

1. Call the handler's `makeCallWithBalance` targeting USDC `approve(clearinghouse, 0)`.
2. Call the handler's `makeCallWithBalance` targeting `clearinghouse.depositFor(beneficiary, 0)`.
3. Call USDC `approve(clearinghouse, 0)` directly to clear any remaining allowance.
4. Call the pinned emitter's `emitData(bytes)` with the unique 32-byte quote ID as its sole argument.

Each dynamic wrapper uses `value = 0` and one replacement `(USDC, 36)`: byte offset 36 is the second argument after
the four-byte selector and first 32-byte argument. Those amount words must be zero because the handler injects the
balance using bitwise OR. All outer call values are zero. Set `fallbackRecipient` to the **destination trading
account**, which can differ from the source wallet and its origin refund recipient.

`message-vector.json` contains the independently generated viem encoding vector shared with the backend parser tests,
and the documented four-action JSON shape. The Solidity test independently rebuilds the 1,760-byte message and checks
its hash. Its clearinghouse, beneficiary, and quote ID are fixture values, not deployed integrations. It is **not a
returned API quote**. The marker follows margin credit and is only useful together with a verified source relay and
canonical destination fill; the emitter itself is permissionless.

## Results and limits

Run:

```sh
forge test --offline --root packages/perps --match-contract AcrossDirectFundingTest -vv

# Check the same tests with CI's regular no-IR compiler configuration.
FOUNDRY_PROFILE=ci FOUNDRY_VIA_IR=false FOUNDRY_OUT=out-ci-fast FOUNDRY_CACHE_PATH=cache-ci-fast \
  forge test --offline --root packages/perps --match-contract AcrossDirectFundingTest -vv

# Check real receipt logs after compiling the default artifacts above.
python3 packages/perps/test/fixtures/across-direct-funding/verify-receipts.py
```

The twelve tests cover dynamic full-balance credit and the unique marker; exact payer attribution and cleared
allowance; failed deposit; failure of the final allowance reset after the deposit has run; deliberate failure after
the marker; fallback including preexisting dust; successful partial consumption and leftover drain; failed fallback
transfer; zero fallback; empty replay; self-only dynamic helper; the independent message vector; and amount
conservation over 256 fuzz cases. Late-failure tests use final custody, account balances, and allowance to prove
rollback. Foundry's `recordLogs` records attempted logs from reverted nested calls, so it must not be confused with a
transaction receipt. The deliberate fifth-call fault is an empty `emitData` call and is not an accepted funding message.

`verify-receipts.py` starts a fresh local Anvil without a fork and uses the pinned runtimes plus the compiled local
token and clearinghouse. It verifies actual receipts for success, failed deposit, failed allowance reset, and failure
after the marker. Success retains the canonical deposit pair and marker; all three failure receipts contain neither
deposit event nor marker, and return the full actual balance to the beneficiary with zero remaining allowance.
The script requires Python, `cast`, and `anvil`, uses only a loopback RPC, and writes its report to
`/tmp/across-marker-receipt-proof.json` by default. It never submits transactions to an external chain.

With a nonzero fallback, action failures roll back together, then remaining callback-token USDC goes to the trading
account wallet. This is **not margin credit**. A failure to transfer the fallback still reverts the outer callback;
malformed message decoding also occurs outside the catch. Only the callback token is automatically drained. The
handler is permissionless and has no per-intent custody or replay protection; bridge-fill identity and canonical
clearinghouse events must establish credit. A successful bridge fill alone is insufficient.

The Swap API integration boundary remains separate: a returned quote must encode these calls and the nonzero
beneficiary fallback while preserving the source wallet's origin refund. During this validation, the available
public POST request was rejected by Cloudflare before API processing, and no authenticated quote with this message
was captured. The existing GET quote captures have zero fallback. Contract tests establish the recipe's execution
semantics; they do not establish that `/swap/approval` will produce this exact recipe.
