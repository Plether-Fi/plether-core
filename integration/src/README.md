# Aggregate integration source

The root Foundry project is an integration harness. Production contracts live in
`packages/*/src` and are imported through the `@plether/*` remappings. Keeping the
root source directory narrow prevents package-local tests from being compiled as
aggregate production sources.
