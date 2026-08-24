<!--
Use this template for documentation, tests, CI, developer tooling, defects confined
to non-runtime infrastructure, dependency upkeep without material runtime effects,
or other low-risk upkeep. Use another template if runtime behavior or protocol
semantics change materially.

Replace every prompt below. Preserve all impact items; write `None` when an item
does not apply.

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

<!-- State the result of this maintenance change. -->

## Motivation

<!-- Explain why the upkeep is needed and what cost or risk it removes. -->

## Changes

<!-- List the meaningful changes by concern rather than by file. -->

## Impact

<!-- Address every item. Write `None` when it does not apply. -->

- Runtime behavior:
- Dependencies, tooling, CI, or operations:
- Compatibility:
- Deployment or migration:
- Security or economic behavior:

## Validation

<!-- List the exact relevant commands/checks and their results. Explain omitted tests. -->

## Reviewer notes

<!-- Call out non-obvious choices, generated changes, limitations, or follow-up work. -->
