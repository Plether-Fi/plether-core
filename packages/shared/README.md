# Shared Contracts

Cross-product Solidity building blocks used by two or more Plether products.

The package intentionally stays small: external integration interfaces, decimal and oracle helpers, and the common
flash-loan callback base. Product-owned APIs such as `ISyntheticSplitter` remain in their product package even when another
product consumes them.

Dependency rule: `shared` may import third-party libraries, but it must not import `spot`, `options`, or `perps`.

Product-neutral test doubles live in `test-support/` and are exposed to package tests through the test-only
`@plether/test-utils/` remapping. Production package sources are forbidden from importing that alias.

Build this package independently from the repository root:

```bash
forge build --root packages/shared
```

The shared package currently has no direct test suite; its source is exercised by the product packages that consume it.
