import test from 'node:test'
import assert from 'node:assert/strict'
import { assertProtectedEnvironment, assertRegistryMatch } from './release-perps-aa-client.mjs'
import { integrity, packageName, validateRelease } from './perps-aa-artifact.mjs'

const artifact = { version: '0.1.0', gitHead: '1'.repeat(40), integrity: integrity(Buffer.from('tested tarball')) }
const published = { name: packageName, version: artifact.version, gitHead: artifact.gitHead, dist: { integrity: artifact.integrity } }

test('a named environment without required reviewers cannot publish', () => {
  assert.throws(() => assertProtectedEnvironment({}))
  assert.throws(() => assertProtectedEnvironment({ protection_rules: [{ type: 'wait_timer' }] }))
  assert.throws(() => assertProtectedEnvironment({ protection_rules: [{ type: 'required_reviewers', reviewers: [] }] }))
  assertProtectedEnvironment({ protection_rules: [{ type: 'required_reviewers', reviewers: [{ type: 'Team', reviewer: { id: 1 } }] }] })
})

test('release accepts only stable exact versions and immutable commit IDs', () => {
  validateRelease(artifact.version, artifact.gitHead)
  for (const version of ['latest', '^0.1.0', '0.1.0-beta.1', '01.1.0', '0.1.0\n', '../0.1.0']) {
    assert.throws(() => validateRelease(version, artifact.gitHead), version)
  }
  assert.throws(() => validateRelease('0.1.0', 'master'))
})

test('recovery accepts the exact tested artifact and refuses version, commit, or byte substitutions', () => {
  assertRegistryMatch(published, artifact)
  for (const change of [
    { name: '@someone-else/perps-aa-client' }, { version: '0.2.0' }, { gitHead: '2'.repeat(40) },
    { dist: { integrity: integrity(Buffer.from('rebuilt tarball')) } }, { gitHead: undefined },
  ]) assert.throws(() => assertRegistryMatch({ ...published, ...change }, artifact))
})
