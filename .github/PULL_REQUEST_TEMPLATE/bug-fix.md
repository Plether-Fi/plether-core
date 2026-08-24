<!--
Use this template for a production or runtime defect correction with an identifiable
symptom and root cause. Use maintenance.md for defects confined to documentation,
tests, CI, or developer tooling. Use protocol-change.md when the fix materially
redesigns protocol, economic, accounting, oracle, authorization, storage, or
cross-contract behavior.

Replace every prompt below. Preserve all impact sections; write `None` when an
item does not apply.

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

<!-- State what was broken, who or what was affected, and the resulting fix. -->

## Symptoms and impact

<!-- Describe observable symptoms, severity, affected states/users, and blast radius. -->

## Reproduction

<!-- Give the smallest reliable reproduction or failing test. Include prerequisites. -->

## Root cause

<!-- Explain the causal path from the triggering state/input to the failure. -->

## Fix and why it is correct

<!-- Explain the correction, why it addresses the root cause, and why nearby paths remain safe. -->

## Regression safety

<!-- Describe the before/after regression test and relevant boundary or failure cases. -->

## Compatibility, deployment, and security impact

<!-- Address every item. Write `None` when it does not apply. -->

- Compatibility:
- Deployment or migration:
- Security, economic, or operational impact:

## Validation

<!-- List exact commands/checks and results, including the failing-before/passing-after evidence when available. -->

## Reviewer focus

<!-- Identify the risky assumptions, adjacent paths reviewed, limitations, and any follow-up work. -->
