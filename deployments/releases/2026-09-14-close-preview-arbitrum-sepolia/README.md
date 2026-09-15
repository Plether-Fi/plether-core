# CfdClosePreview — additive Arbitrum Sepolia deployment

Deployed and source-verified on 2026-09-14 alongside the existing perps v1.2.3 stack.

- Lens: [`0x202A2C5156563Ec4fEF7D3997771bBCa90e98117`](https://sepolia.arbiscan.io/address/0x202A2C5156563Ec4fEF7D3997771bBCa90e98117#code).
- Creation transaction: [`0x3b5d4b17e4092d00f97787be4df89d05a0b0500103551d18e71904bd4fa2baae`](https://sepolia.arbiscan.io/tx/0x3b5d4b17e4092d00f97787be4df89d05a0b0500103551d18e71904bd4fa2baae).
- Deployment block: `308934556`.
- Source commit: [`fe00a5f9be09997db7a93405f798d76392af8c7f`](https://github.com/Plether-Fi/plether-core/commit/fe00a5f9be09997db7a93405f798d76392af8c7f).
- Runtime: 20,081 bytes; Keccak-256 `0x2f8f5cf607ddcd71f3bafd166e3fa3d20980a4077eaa28b8508b2a0ac1c29b16`.
- Gas used: 4,410,777; transaction fee: 0.001147516565874 Arbitrum Sepolia ETH.
- Build: Solidity 0.8.35, optimizer 200 runs, via-IR, Prague; Forge 1.5.1-stable. No constructor arguments or linked libraries.

## Frontend packet

Use [manifest.json](manifest.json) as the supplemental deployment pin and [CfdClosePreview.abi.json](CfdClosePreview.abi.json) for bindings. ABI file SHA-256: `2964608dd3ba3001f86276260a47f233c54cde17218205153bf0725e17d8274c`.
Follow the [frontend handoff](../../../packages/perps/CLOSE_PREVIEW_FRONTEND_HANDOFF.md). The deployed frontend has not been switched by this deployment operation.

The existing v1.2.3 engine, router and execution evaluator retain their original bindings. This transaction only created the stateless preview; it transferred no ETH value and made no protocol configuration change. The historical v1.2.3 manifest is unchanged.

## Evidence and validation

- All 26 production close-preview tests passed before broadcast.
- [Preflight](preflight.json): correct chain, expected deployer, no pending nonce, enough gas balance, six existing core runtime hashes and engine/router/evaluator bindings verified.
- [Receipt](receipt.json), [creation transaction](transaction.json) and [bytecode checks](post-deployment.json): successful creation, exact compiler creation-input and runtime matches.
- [Compiler metadata](compiler-metadata.json), [verification result](source-verification.log), and independent [explorer readback](explorer-readback.json): correct contract, compiler, optimizer runs and empty constructor arguments.
- [Live smoke checks](live-smoke.json): three successful full-close calls at block `308935132`, for a live 1,200-token LONG at stored mark and ±2.5% price samples. Each returned `commitmentCarryUsdc = 100` ($0.0001), `executionBountyUsdc = 200000` ($0.20), and execution carry zero. The router's evaluator binding was checked again at that block.

The smoke checks were read-only and did not commit or execute a trader order. Deployed-bytecode fork commitment/execution parity and frontend integration acceptance remain tasks in the frontend handoff.

[SHA256SUMS](SHA256SUMS) covers the files in this packet except the checksum file itself.
