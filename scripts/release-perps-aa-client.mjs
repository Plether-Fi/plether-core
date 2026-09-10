import assert from 'node:assert/strict'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { packageName, registry, repository, run, validateRelease, verifyArtifact } from './perps-aa-artifact.mjs'

export function assertRegistryMatch(published, artifact) {
  assert.equal(published.name, packageName)
  assert.equal(published.version, artifact.version)
  assert.equal(published.gitHead, artifact.gitHead, 'Published version belongs to another commit')
  assert.equal(published.dist?.integrity, artifact.integrity, 'Published version contains different bytes')
}

export function assertProtectedEnvironment(environment) {
  assert.ok(environment.protection_rules?.some(rule => rule.type === 'required_reviewers' && rule.reviewers?.length > 0),
    'Configure required reviewers for the github-packages environment before publishing')
}

export async function github(endpoint, { method = 'GET', body, optional = false } = {}) {
  const response = await fetch(`https://api.github.com/repos/${repository}/${endpoint}`, {
    method,
    headers: { Authorization: `Bearer ${process.env.GH_TOKEN}`, Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28', 'Content-Type': 'application/json' },
    ...(body ? { body: JSON.stringify(body) } : {}),
  })
  if (optional && response.status === 404) return null
  assert.ok(response.ok, `GitHub ${method} ${endpoint} failed: HTTP ${response.status}`)
  return response.status === 204 ? null : response.json()
}

export async function registryVersion(version) {
  const response = await fetch(`${registry}/${packageName.replace('/', '%2f')}`, {
    headers: { Authorization: `Bearer ${process.env.NODE_AUTH_TOKEN}` },
  })
  if (response.status === 404) return null
  assert.ok(response.ok, `Registry lookup failed: HTTP ${response.status}`)
  const metadata = await response.json()
  return metadata.versions?.[version] ?? null
}

export async function release(directory, version, sha) {
  validateRelease(version, sha)
  assert.equal(process.env.GITHUB_REPOSITORY, repository)
  assert.equal(process.env.GITHUB_REF, 'refs/heads/master', 'Dispatch the workflow from master')
  assert.equal(process.env.GITHUB_SHA, sha)
  assert.equal(run('git', ['rev-parse', 'HEAD']), sha)
  assert.ok(process.env.NODE_AUTH_TOKEN && process.env.GH_TOKEN, 'Release tokens are required')
  assertProtectedEnvironment(await github('environments/github-packages'))
  const artifact = verifyArtifact(directory, version, sha)
  const tag = `perps-aa-client-v${version}`
  const published = await registryVersion(version)
  if (published) assertRegistryMatch(published, artifact)
  const existingTag = await github(`git/ref/tags/${tag}`, { optional: true })
  if (existingTag) {
    const object = existingTag.object.type === 'tag' ? (await github(`git/tags/${existingTag.object.sha}`)).object : existingTag.object
    assert.equal(object.type, 'commit')
    assert.equal(object.sha, sha, 'Release tag points at a different commit')
    assert.ok(published, 'A tag exists without a publication; investigate before releasing')
  }
  const existingRelease = await github(`releases/tags/${tag}`, { optional: true })
  if (existingRelease) assert.ok(published && existingTag, 'Release exists without a matching package and tag')

  if (!published) {
    assert.equal((await github('commits/master')).sha, sha, 'master advanced; dispatch from the new head')
    // npm receives the verified tarball, never a rebuilt package directory.
    run('npm', ['publish', artifact.tarball, '--ignore-scripts', '--registry', registry, '--access', 'public'], { stdio: ['ignore', 'inherit', 'inherit'] })
  }
  // Fail closed on an unavailable readback. Rerun the SAME workflow run to reuse
  // its immutable artifact; never delete/recreate a published version.
  const readback = await registryVersion(version)
  assert.ok(readback, 'Registry readback is not available yet; rerun the publish job')
  assertRegistryMatch(readback, artifact)
  if (!existingTag) {
    const annotation = await github('git/tags', { method: 'POST', body: { tag, message: `${packageName}@${version}\n${artifact.integrity}`, object: sha, type: 'commit' } })
    await github('git/refs', { method: 'POST', body: { ref: `refs/tags/${tag}`, sha: annotation.sha } })
  }
  const body = `${packageName}@${version}\n\nCore commit: ${sha}\n\nRegistry: ${registry}\n\nTarball integrity: ${artifact.integrity}\n\nInstall: npm install --save-exact ${packageName}@${version}\n\nGitHub Packages authentication is required. See the package release runbook for visibility and Actions access setup.`
  if (existingRelease) {
    assert.equal(existingRelease.draft, false)
    assert.equal(existingRelease.prerelease, false)
    assert.equal(existingRelease.body, body, 'Existing release metadata differs; investigate without overwriting')
  } else {
    await github('releases', { method: 'POST', body: { tag_name: tag, name: `${packageName}@${version}`, body, draft: false, prerelease: false, make_latest: 'false' } })
  }
  console.log(`Verified ${tag} at ${sha} (${artifact.integrity})`)
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [directory, version, sha] = process.argv.slice(2)
  await release(path.resolve(directory), version, sha)
}
