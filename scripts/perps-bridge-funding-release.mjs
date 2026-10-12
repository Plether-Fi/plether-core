import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

// This schema is independent of the AA/paymaster manifest. All hashes must come
// from reviewed release artifacts; verification checks the supplied pins against
// chain state, but cannot establish the provenance of an untrusted manifest.
// The destination SpokePool's runtime pin is supplemented by an explicit
// EIP-1967 implementation address and runtime pin at the same captured block.
export const contractNames = Object.freeze([
  'settlementToken', 'marginClearinghouse', 'cfdEngine', 'housePool',
  'orderRouter', 'pletherOracle', 'orderLifecycleBook', 'destinationSpokePool',
  'destinationSpokePoolImplementation', 'multicallHandler',
])

export const implementationSlot = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'

export const selectors = Object.freeze({
  'settlementAsset()': '0xd3781d58', 'engine()': '0xc9d4623f',
  'USDC()': '0x89a30271', 'clearinghouse()': '0x5d4f5f97',
  'orderRouter()': '0xcd41f0c6', 'pool()': '0x16f0115b',
  'ENGINE()': '0x4785e8d4', 'housePool()': '0x281c9cbf',
  'decimals()': '0x313ce567',
  'pletherOracle()': '0xae98f6f2', 'lifecycleBook()': '0x76a6b6f2',
  'ROUTER()': '0x32fe7b26', 'CLEARINGHOUSE()': '0x9b0de7a0',
  'HOUSE_POOL()': '0x9ceb4408', 'depositFor(address,uint256)': '0x2f4f21e2',
})

export const eventTopics = Object.freeze({
  depositFor: '0x6b64443f4cc3aac2df66fff76675a29dc321ce9efebffb006f528db1690179a0',
  deposit: '0x5548c837ab068cf56a2c2479df0882a4922fd203edb7517321831d95078c5f62',
  transfer: '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef',
})

export const bindings = Object.freeze([
  ['marginClearinghouse', 'settlementAsset()', 'settlementToken'],
  ['marginClearinghouse', 'engine()', 'cfdEngine'],
  ['cfdEngine', 'USDC()', 'settlementToken'],
  ['cfdEngine', 'clearinghouse()', 'marginClearinghouse'],
  ['cfdEngine', 'pool()', 'housePool'],
  ['cfdEngine', 'orderRouter()', 'orderRouter'],
  ['housePool', 'USDC()', 'settlementToken'],
  ['housePool', 'ENGINE()', 'cfdEngine'],
  ['orderRouter', 'engine()', 'cfdEngine'],
  ['orderRouter', 'pletherOracle()', 'pletherOracle'],
  ['orderRouter', 'lifecycleBook()', 'orderLifecycleBook'],
  ['pletherOracle', 'engine()', 'cfdEngine'],
  ['pletherOracle', 'housePool()', 'housePool'],
  ['orderLifecycleBook', 'ROUTER()', 'orderRouter'],
  ['orderLifecycleBook', 'ENGINE()', 'cfdEngine'],
  ['orderLifecycleBook', 'CLEARINGHOUSE()', 'marginClearinghouse'],
  ['orderLifecycleBook', 'HOUSE_POOL()', 'housePool'],
])

const addressPattern = /^0x[0-9a-fA-F]{40}$/
const hashPattern = /^0x[0-9a-fA-F]{64}$/
const lower = value => typeof value === 'string' ? value.toLowerCase() : value
const word = value => BigInt(value).toString(16).padStart(64, '0')
const addressWord = value => `0x${value.slice(2).toLowerCase().padStart(64, '0')}`
const uint256Max = (1n << 256n) - 1n

function keys(value, expected, label) {
  assert.ok(value && typeof value === 'object' && !Array.isArray(value), `${label} must be an object`)
  assert.deepEqual(Object.keys(value).sort(), [...expected].sort(), `${label} has missing or unknown fields`)
}

function field(value, predicate, label, template) {
  if (template && value === null) return
  assert.ok(predicate(value), `Invalid ${label}`)
}

const validAddress = value => typeof value === 'string' && addressPattern.test(value) && BigInt(value) !== 0n
const validHash = value => typeof value === 'string' && hashPattern.test(value) && BigInt(value) !== 0n

/** Checks a template only with explicit template:true; normal validation rejects every unfilled field. */
export function validateFundingManifest(manifest, { template = false } = {}) {
  keys(manifest, ['version', 'provider', 'destinationChainId', 'releaseId', 'clearinghouse', 'clearinghouseCodeHash', 'token',
    'destinationSpokePool', 'destinationSpokePoolCodeHash', 'multicallHandler', 'multicallHandlerCodeHash',
    'destinationSpokePoolImplementation', 'destinationSpokePoolImplementationCodeHash',
    'confirmations', 'startBlock', 'sources', 'evidence'], 'manifest')
  assert.equal(manifest.version, 'perps-funding-v1', 'Unsupported runtime manifest version')
  assert.equal(manifest.provider, 'across', 'Unsupported funding provider')
  field(manifest.destinationChainId, value => Number.isSafeInteger(value) && value > 0, 'destinationChainId', template)
  field(manifest.releaseId, value => typeof value === 'string' && value.length <= 128 && /^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(value), 'releaseId', template)
  field(manifest.confirmations, value => Number.isSafeInteger(value) && value > 0 && value <= 1000, 'confirmations', template)
  field(manifest.startBlock, value => Number.isSafeInteger(value) && value >= 0, 'startBlock', template)
  for (const name of ['clearinghouse', 'token', 'destinationSpokePool', 'destinationSpokePoolImplementation', 'multicallHandler']) field(manifest[name], validAddress, name, template)
  for (const name of ['clearinghouseCodeHash', 'destinationSpokePoolCodeHash', 'destinationSpokePoolImplementationCodeHash', 'multicallHandlerCodeHash']) field(manifest[name], validHash, name, template)
  assert.ok(Array.isArray(manifest.sources) && manifest.sources.length > 0, 'Manifest requires explicit source routes')
  const routes = new Set()
  for (const source of manifest.sources) {
    keys(source, ['chainId', 'name', 'token', 'symbol', 'decimals', 'transactionTargets', 'approvalSpenders', 'swapExchanges', 'spokePools'], 'source')
    field(source.chainId, value => Number.isSafeInteger(value) && value > 0 && value !== manifest.destinationChainId, 'source.chainId', template)
    field(source.name, value => typeof value === 'string' && value.trim() === value && value.length > 0, 'source.name', template)
    field(source.token, validAddress, 'source.token', template)
    field(source.symbol, value => typeof value === 'string' && /^[A-Za-z0-9._-]{1,32}$/.test(value), 'source.symbol', template)
    field(source.decimals, value => Number.isSafeInteger(value) && value >= 0 && value <= 255, 'source.decimals', template)
    if (source.chainId !== null && source.token !== null) {
      const route = `${source.chainId}:${lower(source.token)}`
      assert.ok(!routes.has(route), 'Duplicate source chain/token route')
      routes.add(route)
    }
    // These are reviewed source-chain allowlists, not addresses learned from a
    // quote. This destination-chain verifier checks their shape, not their code.
    for (const name of ['transactionTargets', 'approvalSpenders', 'swapExchanges', 'spokePools']) {
      const entries = source[name]
      assert.ok(Array.isArray(entries) && (template || name === 'swapExchanges' || entries.length > 0), `Missing source.${name} allowlist`)
      assert.ok(entries.every(validAddress), `Invalid source.${name} allowlist address`)
      assert.equal(new Set(entries.map(lower)).size, entries.length, `Duplicate source.${name} allowlist address`)
    }
  }
  const evidence = manifest.evidence
  keys(evidence, ['schema', 'schemaVersion', 'sourceCommit', 'contracts', 'depositFor'], 'evidence')
  assert.equal(evidence.schema, 'plether-perps-bridge-funding', 'Wrong manifest schema')
  assert.equal(evidence.schemaVersion, 1, 'Unsupported funding schema version')
  field(evidence.sourceCommit, value => typeof value === 'string' && /^[a-f0-9]{40}$/.test(value) && /[1-9a-f]/.test(value), 'evidence.sourceCommit', template)
  keys(evidence.contracts, contractNames, 'evidence.contracts')
  const seen = new Set()
  for (const name of contractNames) {
    const contract = evidence.contracts[name]
    keys(contract, name === 'settlementToken' ? ['address', 'runtimeCodeHash', 'decimals'] : ['address', 'runtimeCodeHash'], `contracts.${name}`)
    field(contract.address, validAddress, `${name}.address`, template)
    field(contract.runtimeCodeHash, validHash, `${name}.runtimeCodeHash`, template)
    if (contract.address !== null) {
      assert.ok(!seen.has(lower(contract.address)), `Aliased contract address: ${name}`)
      seen.add(lower(contract.address))
    }
  }
  assert.equal(evidence.contracts.settlementToken.decimals, 6, 'Funding requires six-decimal settlement USDC')
  const probe = manifest.evidence.depositFor
  keys(probe, ['transactionHash', 'payer', 'beneficiary', 'amountUsdc'], 'evidence.depositFor')
  field(probe.transactionHash, validHash, 'depositFor.transactionHash', template)
  field(probe.payer, validAddress, 'depositFor.payer', template)
  field(probe.beneficiary, validAddress, 'depositFor.beneficiary', template)
  field(probe.amountUsdc, value => typeof value === 'string' && /^[1-9][0-9]*$/.test(value) && BigInt(value) <= uint256Max, 'depositFor.amountUsdc', template)
  if (probe.payer !== null && probe.beneficiary !== null) {
    assert.notEqual(lower(probe.payer), lower(probe.beneficiary), 'Probe must demonstrate a third-party deposit')
  }
  for (const [runtimeField, contractName] of [['clearinghouse', 'marginClearinghouse'], ['token', 'settlementToken'],
    ['destinationSpokePool', 'destinationSpokePool'], ['destinationSpokePoolImplementation', 'destinationSpokePoolImplementation'],
    ['multicallHandler', 'multicallHandler']]) {
    assert.equal(lower(manifest[runtimeField]), lower(evidence.contracts[contractName].address), `${runtimeField} disagrees with release evidence`)
  }
  for (const [runtimeField, contractName] of [['clearinghouseCodeHash', 'marginClearinghouse'],
    ['destinationSpokePoolCodeHash', 'destinationSpokePool'],
    ['destinationSpokePoolImplementationCodeHash', 'destinationSpokePoolImplementation'], ['multicallHandlerCodeHash', 'multicallHandler']]) {
    assert.equal(lower(manifest[runtimeField]), lower(evidence.contracts[contractName].runtimeCodeHash), `${runtimeField} disagrees with release evidence`)
  }
  return manifest
}

function quantity(value, label) {
  assert.ok(typeof value === 'string' && /^0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)$/.test(value), `Invalid RPC ${label}`)
  return BigInt(value)
}

/** Read-only verification of the funding graph at a single captured head, including mined release evidence. */
export async function verifyFundingManifest(manifest, { rpc, hash = castKeccak }) {
  validateFundingManifest(manifest)
  assert.equal(quantity(await rpc('eth_chainId', []), 'chainId'), BigInt(manifest.destinationChainId), 'RPC chain does not match manifest')
  const snapshot = await rpc('eth_getBlockByNumber', ['latest', false])
  assert.ok(snapshot && validHash(snapshot.hash), 'RPC did not return a mined head')
  const snapshotNumber = quantity(snapshot.number, 'head block number')
  const contracts = manifest.evidence.contracts
  const checkedBlocks = new Map([[snapshot.number, snapshot.hash]])
  const checkCode = async (name, block) => {
    const code = await rpc('eth_getCode', [contracts[name].address, block])
    assert.ok(typeof code === 'string' && /^0x(?:[0-9a-fA-F]{2})+$/.test(code), `${name} has no contract code`)
    assert.equal(lower(await hash(code)), lower(contracts[name].runtimeCodeHash), `${name} runtime code hash mismatch`)
  }
  await Promise.all(contractNames.map(name => checkCode(name, snapshot.number)))
  const implementation = await rpc('eth_getStorageAt', [contracts.destinationSpokePool.address, implementationSlot, snapshot.number])
  assert.equal(lower(implementation), addressWord(contracts.destinationSpokePoolImplementation.address), 'Destination SpokePool implementation mismatch')
  await Promise.all(bindings.map(async ([name, signature, target]) => {
    const result = await rpc('eth_call', [{ to: contracts[name].address, data: selectors[signature] }, snapshot.number])
    assert.equal(lower(result), addressWord(contracts[target].address), `${name}.${signature} binding mismatch`)
  }))
  const decimals = await rpc('eth_call', [{ to: contracts.settlementToken.address, data: selectors['decimals()'] }, snapshot.number])
  assert.equal(lower(decimals), `0x${word(6)}`, 'Settlement token decimals mismatch')

  const evidence = async transactionHash => {
    const [receipt, transaction] = await Promise.all([
      rpc('eth_getTransactionReceipt', [transactionHash]), rpc('eth_getTransactionByHash', [transactionHash]),
    ])
    assert.ok(receipt && transaction, `Missing mined release evidence: ${transactionHash}`)
    assert.equal(receipt.status, '0x1', 'Release evidence transaction failed')
    assert.equal(lower(receipt.transactionHash), lower(transactionHash), 'Receipt transaction hash mismatch')
    assert.equal(lower(transaction.hash), lower(transactionHash), 'Evidence transaction hash mismatch')
    assert.equal(lower(transaction.blockHash), lower(receipt.blockHash), 'Evidence transaction block mismatch')
    assert.equal(transaction.blockNumber, receipt.blockNumber, 'Evidence transaction block number mismatch')
    const minedAt = quantity(receipt.blockNumber, 'receipt block number')
    assert.ok(minedAt + BigInt(manifest.confirmations) - 1n <= snapshotNumber, 'Release evidence has insufficient confirmations')
    assert.ok(validHash(receipt.blockHash), 'Invalid receipt block hash')
    const priorHash = checkedBlocks.get(receipt.blockNumber)
    if (priorHash) assert.equal(lower(priorHash), lower(receipt.blockHash), 'Conflicting release evidence blocks')
    checkedBlocks.set(receipt.blockNumber, receipt.blockHash)
    return { receipt, transaction }
  }

  const probe = manifest.evidence.depositFor
  const { receipt, transaction } = await evidence(probe.transactionHash)
  assert.ok(BigInt(manifest.startBlock) <= quantity(receipt.blockNumber, 'deposit probe block'), 'startBlock would skip depositFor probe')
  const clearinghouse = contracts.marginClearinghouse.address
  const token = contracts.settlementToken.address
  assert.equal(lower(transaction.to), lower(clearinghouse), 'Probe must directly call the clearinghouse')
  assert.equal(lower(transaction.from), lower(probe.payer), 'Probe payer mismatch')
  assert.equal(lower(transaction.input), `${selectors['depositFor(address,uint256)']}${addressWord(probe.beneficiary).slice(2)}${word(probe.amountUsdc)}`, 'Probe must call depositFor with the recorded beneficiary and amount')
  assert.equal(quantity(transaction.value, 'probe value'), 0n, 'Probe must not send native value')
  await Promise.all(['marginClearinghouse', 'settlementToken'].map(name => checkCode(name, receipt.blockNumber)))
  const requireEvent = (emitter, topic, from, to, label) => {
    assert.ok(Array.isArray(receipt.logs), 'Probe receipt has no logs')
    const matches = receipt.logs.filter(log => lower(log.address) === lower(emitter)
      && Array.isArray(log.topics) && log.topics.length === 3
      && lower(log.topics[0]) === topic && lower(log.topics[1]) === addressWord(from)
      && lower(log.topics[2]) === addressWord(to) && lower(log.data) === `0x${word(probe.amountUsdc)}`
      && log.removed !== true)
    assert.equal(matches.length, 1, `Expected exactly one matching ${label} event`)
  }
  requireEvent(clearinghouse, eventTopics.depositFor, probe.payer, probe.beneficiary, 'DepositFor')
  requireEvent(clearinghouse, eventTopics.deposit, probe.beneficiary, token, 'Deposit')
  requireEvent(token, eventTopics.transfer, probe.payer, clearinghouse, 'USDC Transfer')

  // Recheck every evidence block after all reads so a reorg cannot silently mix
  // receipts and code from different canonical histories during this run.
  await Promise.all([...checkedBlocks].map(async ([number, blockHash]) => {
    const block = await rpc('eth_getBlockByNumber', [number, false])
    assert.ok(block, 'Verification block disappeared')
    assert.equal(block.number, number, 'Verification block number mismatch')
    assert.equal(lower(block.hash), lower(blockHash), 'Verification block was reorganized')
  }))
  return { schema: manifest.evidence.schema, destinationChainId: manifest.destinationChainId, releaseId: manifest.releaseId, sourceCommit: manifest.evidence.sourceCommit,
    verifiedAtBlock: snapshot.number, verifiedAtBlockHash: snapshot.hash, contractsChecked: contractNames.length,
    bindingsChecked: bindings.length, depositForTransaction: probe.transactionHash }
}

function castKeccak(code) {
  return execFileSync('cast', ['keccak', code], { encoding: 'utf8' }).trim()
}

export function jsonRpc(url) {
  const parsed = new URL(url)
  assert.ok(['http:', 'https:'].includes(parsed.protocol), 'RPC URL must use HTTP or HTTPS')
  let id = 0
  return async (method, params) => {
    const requestId = ++id
    const response = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: requestId, method, params }), signal: AbortSignal.timeout(30_000) })
    assert.ok(response.ok, `RPC HTTP error ${response.status}`)
    const payload = await response.json()
    assert.equal(payload.id, requestId, 'RPC response ID mismatch')
    assert.ok(!payload.error, `RPC ${method} failed: ${payload.error?.message}`)
    assert.ok(Object.hasOwn(payload, 'result'), 'RPC response has no result')
    return payload.result
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [command, file, ...extra] = process.argv.slice(2)
    assert.ok(['template', 'validate', 'verify'].includes(command) && file && extra.length === 0,
      'Usage: node scripts/perps-bridge-funding-release.mjs <template|validate|verify> <manifest.json>; verify requires FUNDING_RPC_URL and cast')
    const manifest = JSON.parse(readFileSync(file, 'utf8'))
    if (command === 'verify') {
      assert.ok(process.env.FUNDING_RPC_URL, 'Set FUNDING_RPC_URL explicitly; no chain is selected by default')
      console.log(JSON.stringify(await verifyFundingManifest(manifest, { rpc: jsonRpc(process.env.FUNDING_RPC_URL) }), null, 2))
    } else {
      validateFundingManifest(manifest, { template: command === 'template' })
      console.log(command === 'template' ? 'Template structure valid; not a deployable release.' : 'Manifest structure valid; run verify for on-chain evidence.')
    }
  } catch (error) {
    console.error(error.message)
    process.exitCode = 1
  }
}
