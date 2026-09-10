import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export const packageName = '@plether-fi/perps-aa-client'
export const registry = 'https://npm.pkg.github.com'
export const repository = 'Plether-Fi/plether-core'
export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
export const packageRoot = path.join(root, 'packages/perps-aa-client')
export const run = (command, args, options = {}) => execFileSync(command, args, { encoding: 'utf8', ...options })?.trim() ?? ''
export const readJson = file => JSON.parse(readFileSync(file, 'utf8'))
export const integrity = bytes => `sha512-${createHash('sha512').update(bytes).digest('base64')}`

export function validateRelease(version, sha) {
  assert.equal(version.trim(), version, 'Version must not contain whitespace')
  assert.equal(sha.trim(), sha, 'Commit must not contain whitespace')
  assert.match(version, /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/, 'Use an exact stable SemVer version')
  assert.match(sha, /^[a-f0-9]{40}$/, 'Use a full immutable commit SHA')
}

export function verifyArtifact(directory, version, sha) {
  validateRelease(version, sha)
  const manifest = readJson(path.join(directory, 'release.json'))
  assert.equal(manifest.name, packageName)
  assert.equal(manifest.version, version)
  assert.equal(manifest.gitHead, sha)
  assert.equal(manifest.filename, `plether-fi-perps-aa-client-${version}.tgz`)
  const tarball = path.join(directory, manifest.filename)
  assert.equal(integrity(readFileSync(tarball)), manifest.integrity, 'Tarball integrity changed')
  const entries = run('tar', ['-tzf', tarball]).split('\n')
  for (const entry of entries) {
    assert.ok(/^package\/(dist\/[^/]+\.(js|js\.map|d\.ts)|package\.json|README\.md|RELEASING\.md|LICENSE)$/.test(entry), `Unexpected published file: ${entry}`)
  }
  for (const required of ['dist/index.js', 'dist/index.d.ts', 'README.md', 'LICENSE', 'package.json']) {
    assert.ok(entries.includes(`package/${required}`), `Missing ${required}`)
  }
  const metadata = JSON.parse(run('tar', ['-xOf', tarball, 'package/package.json']))
  assert.equal(metadata.name, packageName)
  assert.equal(metadata.version, version)
  assert.equal(metadata.gitHead, sha)
  assert.equal(metadata.private, false)
  assert.equal(metadata.publishConfig.registry, registry)
  assert.equal(metadata.publishConfig.access, 'public')
  assert.equal(metadata.repository.url, `git+https://github.com/${repository}.git`)
  assert.equal(metadata.repository.directory, 'packages/perps-aa-client')
  assert.equal(metadata.license, 'AGPL-3.0-only')
  for (const entry of entries.filter(name => name.endsWith('.js.map'))) {
    const map = JSON.parse(run('tar', ['-xOf', tarball, entry]))
    assert.equal(map.sourcesContent?.length, map.sources.length, `Incomplete source map: ${entry}`)
    assert.ok(map.sourcesContent.every(source => typeof source === 'string'))
  }
  return { ...manifest, tarball }
}

export function packArtifact(directory) {
  const metadata = readJson(path.join(packageRoot, 'package.json'))
  const sha = run('git', ['rev-parse', 'HEAD'], { cwd: root })
  validateRelease(metadata.version, sha)
  // A release must be reconstructible from gitHead; local development can pack
  // only after committing, just like the checkout used by CI.
  assert.equal(run('git', ['status', '--porcelain', '--untracked-files=all'], { cwd: root }), '', 'Commit all changes before packaging')
  const staging = mkdtempSync(path.join(tmpdir(), 'perps-aa-pack-'))
  for (const name of ['dist', 'README.md', 'RELEASING.md', 'LICENSE']) cpSync(path.join(packageRoot, name), path.join(staging, name), { recursive: true })
  writeFileSync(path.join(staging, 'package.json'), JSON.stringify({ ...metadata, gitHead: sha }, null, 2) + '\n')
  mkdirSync(directory, { recursive: true })
  assert.ok(!existsSync(path.join(directory, 'release.json')), 'Use a new artifact directory')
  const [packed] = JSON.parse(run('npm', ['pack', '--json', '--ignore-scripts', '--pack-destination', path.resolve(directory)], { cwd: staging }))
  const manifest = { name: packageName, version: metadata.version, gitHead: sha, filename: packed.filename, integrity: packed.integrity }
  writeFileSync(path.join(directory, 'release.json'), JSON.stringify(manifest, null, 2) + '\n')
  return verifyArtifact(directory, metadata.version, sha)
}

export function smokeArtifact(directory) {
  const manifest = readJson(path.join(directory, 'release.json'))
  const artifact = verifyArtifact(directory, manifest.version, manifest.gitHead)
  const consumer = mkdtempSync(path.join(tmpdir(), 'perps-aa-consumer-'))
  writeFileSync(path.join(consumer, 'package.json'), JSON.stringify({ private: true, type: 'module' }))
  run('npm', ['install', '--ignore-scripts', '--no-audit', '--no-fund', artifact.tarball], { cwd: consumer, stdio: ['ignore', 'inherit', 'inherit'] })
  // Exercise only the installed artifact, from outside the monorepo. No source
  // aliases, local node_modules, or unpublished test dependencies are available.
  cpSync(path.join(packageRoot, 'test/compatibility'), path.join(consumer, 'compatibility'), { recursive: true })
  run(process.execPath, ['compatibility/consumer.mjs'], { cwd: consumer, stdio: ['ignore', 'inherit', 'inherit'] })
  return artifact
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [command, directory] = process.argv.slice(2)
  assert.ok(directory, 'Usage: node scripts/perps-aa-artifact.mjs <pack|smoke> <artifact-directory>')
  const result = command === 'pack' ? packArtifact(path.resolve(directory)) : command === 'smoke' ? smokeArtifact(path.resolve(directory)) : assert.fail('Unknown command')
  console.log(JSON.stringify(result, null, 2))
}
