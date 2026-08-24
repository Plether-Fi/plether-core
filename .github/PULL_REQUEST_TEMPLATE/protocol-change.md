<!--
Use this template for protocol, architecture, economic, accounting, oracle,
authorization, storage, migration, or cross-contract changes.

Replace every prompt below. Preserve all impact and security sections; write
`None` when an item does not apply.

Risk guide:
- Low: documentation, tests, tooling, or a localized behavior-preserving change.
- Medium: a bounded runtime or integration change with a limited blast radius.
- High: accounting, economic, oracle, authorization, storage or migration,
  cross-contract, or other broad protocol behavior. Use High by default for these.
-->

## Change profile

- Change type: <!-- Feature / bug fix / refactor / security / docs / CI / maintenance -->
- Risk: <!-- Low / Medium / High -->
- Affected packages/components:
- Breaking change: <!-- Describe it, or write `None`. -->
- Deployment or migration required: <!-- Describe it, or write `None`. -->

## Summary

<!-- Lead with the resulting behavior and the reason for the change. -->

## Context and existing problem

<!--
Describe the current behavior, the flaw or limitation, why it matters, and the
constraints the solution must respect. Include concrete examples when useful.
-->

## Design decision

### Chosen approach

<!-- Explain the design and why it solves the underlying problem. -->

### Alternatives considered

<!-- Describe credible alternatives, why they were rejected, and their trade-offs. -->

## What changes

<!--
Describe behavioral and data/control-flow changes by subsystem. Add a short flow,
sequence diagram, or before/after table when ordering or ownership matters.
-->

## Consequences

### User, product, and economic behavior

<!-- Describe observable behavior, incentives, pricing, accounting, or fund-flow effects. Write `None` if absent. -->

### Integration and compatibility

<!-- Cover APIs, ABIs, events, indexers, keepers, frontends, SDKs, and downstream assumptions. Write `None` if absent. -->

### Deployment and migration

<!-- Cover redeployment, upgrades, initialization, configuration, and state migration. Write `None` if absent. -->

## Security properties and invariants

<!--
State the properties that must hold, new or changed trust assumptions, failure
behavior, rollback/atomicity guarantees, and relevant pause or recovery paths.
Write `None` only when the change genuinely has no security or invariant impact.
-->

## Operational liveness and bounded work

<!--
Cover progress guarantees, per-call work or gas bounds, resumability, keeper or
operator responsibilities, queue/backlog behavior, and griefing or denial-of-service
risks. Write `None` only when none of these properties are affected.
-->

## Accepted trade-offs and known limitations

<!-- State the costs or limitations accepted by this design. Write `None` if absent. -->

## Scope

### In scope

<!-- List the behaviors intentionally changed by this PR. -->

### Out of scope

<!-- List adjacent work deliberately deferred or unchanged. Write `None` if absent. -->

## Validation

<!--
Record exact commands and results. Cover the applicable categories below and
explain every omission.
-->

- Formatting, lint, and static checks:
- Unit and regression tests:
- Fuzz and invariant tests:
- Coverage:
- Gas and contract size:
- Integration or manual checks:

## Reviewer guide

<!-- Identify the highest-risk paths, suggested review order, and deliberately unchanged behavior. -->
