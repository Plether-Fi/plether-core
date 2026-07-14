# Spot Contracts

The spot package contains the original Plether synthetic-token protocol and its supporting contracts:

- `src/core`: paired synthetic tokens, splitter, and INVAR
- `src/staking`: ERC-4626 staking and reward distribution
- `src/routers`: spot, bear-leverage, and bull-leverage routers
- `src/adapters`: yield adapters
- `src/oracles`: spot and Morpho pricing adapters
- `src/interfaces`, `src/libraries`, and `src/base`: spot-owned support code

Spot depends only on the `shared` workspace package and third-party libraries. Build it independently from the repository
root with:

```bash
forge build --root packages/spot
forge test --root packages/spot
```

Spot unit, fuzz, invariant, security, and intra-package integration tests live under `test/`. RPC-backed fork tests and
deployment scripts remain in the repository-level `test/fork/` and `script/` integration harness.
