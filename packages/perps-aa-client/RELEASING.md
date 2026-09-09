# Releasing the perps AA client

Core owns the client sources, protection ABI, paymaster contract, tests, and
deployment tooling. npm package versions use their own immutable
`perps-aa-client-vX.Y.Z` tags; they do not move or replace protocol deployment
tags. Publishing a client does not deploy a contract or enable sponsorship.

## One-time administration

Before the first release, configure the Core `github-packages` environment with
at least one required reviewer. The publish script reads back the environment
and rejects an unprotected environment, including one automatically created by
GitHub. Configure the environment to allow `master`. The workflow also requires
`refs/heads/master` and checks the current remote head before first publication.

After publication, verify that `perps-aa-client` is public in the `Plether-Fi`
organization, linked to `Plether-Fi/plether-core`, and grants
`Plether-Fi/plether-app` Actions read access. First publication can default to
private despite publish access metadata; an administrator must verify/change
visibility. Public visibility does not remove npm authentication requirements.
See [GitHub's npm registry documentation](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-npm-registry).

## Before merging

```bash
npm ci --prefix packages/perps-aa-client
npm run typecheck --prefix packages/perps-aa-client
npm test --prefix packages/perps-aa-client
npm run build --prefix packages/perps-aa-client
forge test --root packages/perps-aa
node --test scripts/perps-aa-release.test.mjs
```

CI packs from a clean committed checkout, verifies the file allowlist, license,
exports, embedded `gitHead`, and self-contained source maps, then installs the
tarball in a temporary consumer outside Core. The consumer runs the same fixed
compatibility vectors as the source tests, including all four protection actions
through the native sponsorship/journaling path. Solidity consumes the same JSON
fixture and independently checks all eleven sponsorship hashes.

The opt-in Arbitrum Sepolia fork test must also pass before approving the first
release. Run it with an authenticated read-only RPC if the public endpoint is
unavailable; no broadcasts or real funding are involved:

```bash
ARBITRUM_SEPOLIA_RPC_URL=https://sepolia-rollup.arbitrum.io/rpc \
  forge test --root packages/perps-aa --match-contract PletherVerifyingPaymasterForkTest -vv
```

## Publish the merged version

Commit the exact stable version and lockfile; initial version is `0.1.0`. Merge
the reviewed Core PR first. Use the GitHub CLI for dispatch and monitoring:

```bash
gh auth status
gh api user --jq .login
gh api repos/Plether-Fi/plether-core/commits/master --jq .sha
gh run list --repo Plether-Fi/plether-core --workflow publish-perps-aa-client.yml --limit 10
gh workflow run publish-perps-aa-client.yml --repo Plether-Fi/plether-core --ref master -f version=0.1.0
```

Confirm the run's `headSha`, inspect its build/test results, then approve the
protected `github-packages` job. The read-only build job uploads one tarball and
`release.json`; the protected job downloads that exact artifact and verifies its
SHA-512 integrity. It performs no install, build, lifecycle scripts, or repack.
Only that job has package-write and tag/release-write permissions.

Publishing is followed by registry `gitHead`/integrity readback, an annotated
`perps-aa-client-v0.1.0` tag at that commit, and a GitHub Release containing the
integrity and commit. The package release is never marked the repository's latest
protocol release. Use `gh run view` and `gh run watch --exit-status` for completion.

## Recovery

If publication succeeded but readback/tag/release creation failed, rerun only the
failed publish job from that same workflow run (`gh run rerun RUN_ID --failed`).
It reuses the uploaded artifact. An existing version is accepted only when its
`gitHead` and integrity match, and an existing tag must point to the same commit.
Existing release metadata must match exactly. A mismatch requires investigation;
never delete, overwrite, or republish the version. Artifact retention is 30 days;
resolve partial releases within that window.

## Consumer upgrade gate

Only after public visibility and app Actions access are verified should
plether-app replace its vendor dependency with the exact registry version.
Its lockfile must record the returned registry tarball URL and integrity. Verify
a clean `npm ci` using the app workflow's `GITHUB_TOKEN`, then run the frontend,
Storybook, and AA integration checks. Record the Core PR, merged SHA, package tag,
version, and integrity in the app's runbook. An install against a locally built
tarball proves compatibility but does not satisfy the registry-access gate.
