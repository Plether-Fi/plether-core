# Sponsored close lens — Arbitrum Sepolia

Read-only lens for exact bounty-shortfall assistance. Protocol v1.2.3 and all protocol configuration remain unchanged. The new lens preserves `previewClose` and adds funded previews and the first-call guard for the atomic mint/approve/deposit/commit batch. Assistance has no automatic expiry; order and paymaster validity remain enforced.

Use `manifest.json` for immutable bindings and `CfdClosePreview.abi.json` for integration. Arbiscan source verification passed. Creation input and onchain runtime match the compiled production artifact; evidence is included. The source commit identifies Solidity sources, not a subsequent release-documentation commit.

Validation: 62 preview unit tests passed before the additional Max-open tests; the four Max-open/full-or-partial-close cases pass separately, including the carry-enabled fixture. Three local-fork tests pass against the deployed SimpleAccount implementation and v1.2.3 protocol. Runtime is 20,765 bytes (EIP-170 limit 24,576). Full perps CI and operator canary records are tracked in PR #100 and app PR #284. Deployment of the lens alone does not enable assistance.

An earlier candidate at `0xA1E188928FE0b310e334A58f780492518DE64B7f` was deployed and verified before the fast-compiler compatibility refactor. It was never enabled for close assistance. Integrations must use this release manifest's final lens and runtime hash.
