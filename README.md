# Plether Protocol Contracts

[![CI](https://github.com/Plether-Fi/plether-core/actions/workflows/ci.yml/badge.svg)](https://github.com/Plether-Fi/plether-core/actions/workflows/ci.yml)
[![Coverage](https://codecov.io/gh/Plether-Fi/plether-core/branch/master/graph/badge.svg)](https://codecov.io/gh/Plether-Fi/plether-core)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.35-363636?logo=solidity)](https://docs.soliditylang.org/)

Plether is a Solidity monorepo for on-chain products that provide bounded, dollar-directional exposure. Spot, options, and
perpetuals are peer Foundry packages under `packages/`; product-neutral contracts and test utilities live in `shared`.

The repository root is deliberately a narrow integration, deployment, and fork-test workspace. Production contracts and
their unit, fuzz, invariant, and security tests are owned by their package.

## Packages

| Package | Scope | Direct workspace dependencies |
| --- | --- | --- |
| [`shared`](packages/shared/README.md) | Cross-product interfaces, oracle/decimal helpers, flash-loan foundations, and generic test support | None |
| [`spot`](packages/spot/README.md) | Paired plDXY synthetics, staking, leverage routers, yield adapters, Spot oracles, and INVAR | `shared` |
| [`options`](packages/options/README.md) | Fully collateralized covered calls, margin and settlement, option tokens, and DOV vaults | `shared`, Spot API |
| [`perps`](packages/perps/README.md) | Delayed-order bounded perpetuals, margin clearing, a tranched LP pool, execution routing, and lenses | `shared` |

All package imports use stable aliases:

```text
@plether/shared/  -> packages/shared/src/
@plether/spot/    -> packages/spot/src/
@plether/options/ -> packages/options/src/
@plether/perps/   -> packages/perps/src/
```

Cross-package relative imports are not allowed. Run `make check-boundaries` to validate the dependency rules.

## Repository Layout

```text
packages/
├── shared/       # Product-neutral production code and test support
├── spot/         # Spot production code and package-owned tests
├── options/      # Options production code and package-owned tests
└── perps/        # Perps production code and package-owned tests
integration/src/  # Minimal root Foundry source directory
test/             # Cross-package, deployment-script, and RPC fork tests
script/           # Deployment and operational scripts
scripts/          # Repository and CI helpers
```

Package source paths and fully qualified contract names begin with `packages/<package>/src/`. Existing deployments are
unchanged by the repository layout; verification tooling and downstream source imports must use the package paths or the
`@plether/*` remappings.

## Getting Started

CI uses Foundry v1.5.1 and Solidity 0.8.35. Clone submodules before building:

```bash
git submodule update --init --recursive
make build-packages
make test
```

### Build

```bash
make build-packages                 # Build shared, spot, options, and perps independently
make build-spot                     # Build one package through Make
forge build --root packages/perps   # Build one package directly
forge build                         # Build the root integration/script workspace
```

### Test

```bash
make test                           # Run all product packages, then root integration tests
make test-packages                  # Run spot, options, and perps package tests
make test-options                   # Run one package
make test-integration               # Run root tests, excluding RPC-backed fork tests
forge test --root packages/perps    # Run one package directly
```

The shared package currently has no standalone test suite; its code is exercised by the product packages that consume it.
See the [integration test guide](test/README.md) for package test layout, targeted test commands, fork tests, and shared
fixtures.

### Coverage, Formatting, and Boundaries

```bash
make coverage-spot
make coverage-options
make coverage-perps
make fmt-check
make check-boundaries
```

### Fork Tests

RPC-backed tests cover cross-product behavior against live protocol deployments and require `MAINNET_RPC_URL`:

```bash
(source .env && forge test --match-path "test/fork/*" \
  --no-match-path "test/fork/PythRealUpdateFork.t.sol" \
  --fork-url "$MAINNET_RPC_URL" -vvv)
```

The real Pyth update test needs an additional Hermes fixture; see the [integration test guide](test/README.md#fork-tests).

## Continuous Integration

CI keeps package failures isolated:

- `Package (shared|spot|options|perps)` builds each package independently and runs its owned suites.
- `Slither (shared|spot|options|perps)` analyzes each package as a separate job and uploads package-scoped SARIF.
- Spot, options, and perps coverage run as separate jobs with package-scoped LCOV output.
- The root `build` job checks formatting and dependency boundaries, builds the integration workspace, and runs root tests.
- Matrix jobs use `fail-fast: false`, so one package failure does not cancel results for the others.

The workflow is defined in [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## Documentation

Start with the package that owns the product:

- [Shared contracts](packages/shared/README.md)
- [Spot protocol](packages/spot/README.md)
- [Options module](packages/options/README.md)
- [Perps protocol](packages/perps/README.md)
- [Perps accounting specification](packages/perps/ACCOUNTING_SPEC.md)
- [Integration and fork tests](test/README.md)

Generate NatSpec documentation for a package with:

```bash
FOUNDRY_PROFILE=docs FOUNDRY_SRC=packages/spot/src forge doc --out docs/spot
FOUNDRY_PROFILE=docs FOUNDRY_SRC=packages/options/src forge doc --out docs/options
FOUNDRY_PROFILE=docs FOUNDRY_SRC=packages/perps/src forge doc --out docs/perps
```

## Deployment

Deployment and operational scripts live in [`script/`](script/). Product-specific starting points are:

- [Spot operations and deployment guide](packages/spot/OPERATIONS.md)
- [Perps deployment guide](packages/perps/DEPLOYMENT.md) and
  [Arbitrum Sepolia deployment packet](packages/perps/ARBITRUM_SEPOLIA_DEPLOYMENT_PACKET.md)
- [Options package architecture and operational model](packages/options/README.md)

Always simulate the exact script and deployment scope before broadcasting.

## Security

Security assumptions are product-specific:

- [Spot and shared integration assumptions](SECURITY.md)
- [Options security model](packages/options/README.md#security-model)
- [Perps security model](packages/perps/SECURITY.md)
- [Perps pre-audit guide](packages/perps/PRE_AUDIT_GUIDE.md)

Some components have undergone external security review, but audit coverage is partial and release-specific. Review the
security model, audit reports, deployment parameters, and exact bytecode before production use.

## License

[AGPL-3.0](LICENSE)

## Disclaimer

This software is provided "as is" without warranty of any kind. Use at your own risk.
