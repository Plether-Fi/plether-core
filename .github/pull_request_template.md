<!--
This is the fallback template for changes that do not fit a specialized template.

Specialized templates:
- Protocol, architecture, economic, or security changes: protocol-change.md
- Production or runtime defect corrections: bug-fix.md
- Documentation, tests, CI, developer tooling, non-runtime defects, dependency
  upkeep without material runtime effects, or other low-risk upkeep: maintenance.md

GitHub web: add `template=<filename>` to the compare URL query string, using `?`
for the first query parameter or `&` after an existing parameter. Example:
`?template=protocol-change.md`.

GitHub CLI example:
`gh pr create --template .github/PULL_REQUEST_TEMPLATE/protocol-change.md`

Replace every prompt below. Do not delete compatibility, deployment, or security
items; write `None` when an item does not apply.

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

<!-- State the outcome of this PR in a few sentences. -->

## Motivation

<!-- Explain the problem, need, or opportunity and why it matters now. -->

## Material changes

<!-- Group meaningful behavioral changes by subsystem; avoid a file-by-file list. -->

## Impact and risk

<!-- Address every item. Write `None` when it does not apply. -->

- Compatibility:
- Deployment or migration:
- Security, economic, or operational impact:

## Validation

<!-- List the exact commands/checks run and their results. Explain any omitted coverage. -->

## Reviewer notes

<!-- Identify the highest-risk areas, useful review order, and known limitations. -->
