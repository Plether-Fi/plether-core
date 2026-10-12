import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import { bindings, contractNames, eventTopics, implementationSlot, selectors, validateFundingManifest, verifyFundingManifest } from './perps-bridge-funding-release.mjs'

const template = JSON.parse(readFileSync(new URL('../deployments/perps-bridge-funding.template.json', import.meta.url), 'utf8'))
const address = value => `0x${value.toString(16).padStart(40, '0')}`
const hash = value => `0x${value.toString(16).padStart(64, '0')}`
const word = value => hash(BigInt(value))
const clone = value => structuredClone(value)

function fixture() {
  const manifest = clone(template)
  const contracts = manifest.evidence.contracts
  contractNames.forEach((name, i) => Object.assign(contracts[name], { address: address(i + 1), runtimeCodeHash: hash(i + 101) }))
  Object.assign(manifest, { destinationChainId: 42161, releaseId: 'unit-test-only',
    clearinghouse: contracts.marginClearinghouse.address, token: contracts.settlementToken.address,
    clearinghouseCodeHash: contracts.marginClearinghouse.runtimeCodeHash,
    destinationSpokePool: contracts.destinationSpokePool.address, destinationSpokePoolCodeHash: contracts.destinationSpokePool.runtimeCodeHash,
    destinationSpokePoolImplementation: contracts.destinationSpokePoolImplementation.address,
    destinationSpokePoolImplementationCodeHash: contracts.destinationSpokePoolImplementation.runtimeCodeHash,
    multicallHandler: contracts.multicallHandler.address, multicallHandlerCodeHash: contracts.multicallHandler.runtimeCodeHash,
    confirmations: 10, startBlock: 32,
    sources: [{ chainId: 1, name: 'Test source', token: address(20), symbol: 'USDT', decimals: 6,
      transactionTargets: [address(21)], approvalSpenders: [address(21)], swapExchanges: [address(22)], spokePools: [address(23)] }],
  })
  Object.assign(manifest.evidence, { sourceCommit: '1'.repeat(40),
    depositFor: { transactionHash: hash(82), payer: address(83), beneficiary: address(84), amountUsdc: '1000000' } })
  const probe = manifest.evidence.depositFor
  const blocks = { '0x30': { number: '0x30', hash: hash(48) }, '0x40': { number: '0x40', hash: hash(64) } }
  const transactions = {
    [probe.transactionHash]: { hash: probe.transactionHash, to: manifest.clearinghouse, from: probe.payer,
      input: `${selectors['depositFor(address,uint256)']}${word(probe.beneficiary).slice(2)}${word(probe.amountUsdc).slice(2)}`,
      value: '0x0', blockNumber: '0x30', blockHash: blocks['0x30'].hash },
  }
  const event = (emitter, topic, first, second) => ({ address: emitter, topics: [topic, word(first), word(second)], data: word(probe.amountUsdc) })
  const receipts = {
    [probe.transactionHash]: { transactionHash: probe.transactionHash, contractAddress: null, status: '0x1',
      blockNumber: '0x30', blockHash: blocks['0x30'].hash, logs: [
        event(manifest.clearinghouse, eventTopics.depositFor, probe.payer, probe.beneficiary),
        event(manifest.clearinghouse, eventTopics.deposit, probe.beneficiary, manifest.token),
        event(manifest.token, eventTopics.transfer, probe.payer, manifest.clearinghouse),
      ] },
  }
  const code = Object.fromEntries(contractNames.map((name, i) => [contracts[name].address, `0x6000${(i + 1).toString(16).padStart(2, '0')}`]))
  const hashes = Object.fromEntries(contractNames.map(name => [code[contracts[name].address], contracts[name].runtimeCodeHash]))
  const calls = Object.fromEntries(bindings.map(([name, signature, target]) => [`${contracts[name].address}:${selectors[signature]}`, word(contracts[target].address)]))
  calls[`${manifest.token}:${selectors['decimals()']}`] = word(6)
  const storage = { [`${manifest.destinationSpokePool}:${implementationSlot}`]: word(manifest.destinationSpokePoolImplementation) }
  const reads = []
  const rpc = async (method, params) => {
    reads.push([method, clone(params)])
    if (method === 'eth_chainId') return '0xa4b1'
    if (method === 'eth_getBlockByNumber') return clone(blocks[params[0] === 'latest' ? '0x40' : params[0]])
    if (method === 'eth_getCode') return code[params[0]]
    if (method === 'eth_getStorageAt') return storage[`${params[0]}:${params[1]}`]
    if (method === 'eth_call') return calls[`${params[0].to}:${params[0].data}`]
    if (method === 'eth_getTransactionReceipt') return clone(receipts[params[0]])
    if (method === 'eth_getTransactionByHash') return clone(transactions[params[0]])
    assert.fail(`Unexpected RPC method ${method}`)
  }
  return { manifest, blocks, receipts, transactions, code, calls, storage, reads, rpc, hash: bytes => hashes[bytes] }
}

test('an empty template is explicitly inspectable but never accepted as a release', () => {
  validateFundingManifest(template, { template: true })
  assert.throws(() => validateFundingManifest(template), /Invalid destinationChainId/)
  assert.throws(() => validateFundingManifest(JSON.parse(readFileSync(new URL('../deployments/arbitrum-sepolia-perps-aa.template.json', import.meta.url), 'utf8'))), /manifest has missing or unknown fields/)
})

test('runtime fields, schema, pins, and source allowlists fail closed', () => {
  const changes = [
    m => { m.version = 'perps-aa-v1' }, m => { m.provider = 'privy' }, m => { m.destinationChainId = '42161' },
    m => { m.confirmations = 0 }, m => { m.confirmations = 1001 }, m => { m.releaseId = 'x'.repeat(129) },
    m => { m.startBlock = -1 },
    m => { m.receiverFactory = address(99) }, m => { m.factoryCodeHash = hash(99) },
    m => { m.evidence.deployer = address(99) }, m => { m.evidence.factoryDeploymentTransaction = hash(99) },
    m => { delete m.clearinghouseCodeHash }, m => { m.clearinghouseCodeHash = null },
    m => { m.clearinghouseCodeHash = hash(0) }, m => { m.clearinghouseCodeHash = '0x1234' },
    m => { m.clearinghouseCodeHash = hash(999) },
    m => { m.clearinghouse = address(0) }, m => { m.clearinghouse = address(99) },
    m => { m.evidence.contracts.cfdEngine.address = m.token },
    m => { m.evidence.contracts.marginClearinghouse.runtimeCodeHash = hash(0) },
    m => { m.evidence.sourceCommit = 'main' }, m => { m.evidence.extra = true },
    m => { m.sources = [] }, m => { m.sources[0].approvalSpenders = [] },
    m => { m.sources[0].transactionTargets = [address(0)] },
    m => { m.sources[0].spokePools.push(...m.sources[0].spokePools) },
    m => { m.sources.push(clone(m.sources[0])) }, m => { m.sources[0].chainId = m.destinationChainId },
    m => { m.evidence.depositFor.payer = m.evidence.depositFor.beneficiary },
    m => { m.evidence.depositFor.amountUsdc = '0' }, m => { m.evidence.depositFor.amountUsdc = `${1n << 256n}` },
  ]
  for (const change of changes) {
    const { manifest } = fixture()
    change(manifest)
    assert.throws(() => validateFundingManifest(manifest), change.toString())
  }
  const { manifest } = fixture()
  manifest.sources[0].swapExchanges = []
  validateFundingManifest(manifest)
})

test('verifies all pinned contracts and reciprocal funding bindings at one block with mined depositFor evidence', async () => {
  const f = fixture()
  const result = await verifyFundingManifest(f.manifest, f)
  assert.equal(result.contractsChecked, 10)
  assert.equal(result.bindingsChecked, bindings.length)
  assert.equal(result.verifiedAtBlockHash, f.blocks['0x40'].hash)
  assert.ok(f.reads.filter(([method]) => method === 'eth_call').every(([, params]) => params[1] === '0x40'))
  assert.deepEqual(f.reads.filter(([method]) => method === 'eth_getStorageAt'), [
    ['eth_getStorageAt', [f.manifest.destinationSpokePool, implementationSlot, '0x40']],
  ])
  assert.ok(f.reads.some(([method, params]) => method === 'eth_getCode' && params[0] === f.manifest.clearinghouse && params[1] === '0x30'))
  assert.ok(f.reads.every(([method]) => !method.startsWith('eth_send')))
})

test('requires matching explicit clearinghouse and provider pins before any RPC verification', async () => {
  for (const field of ['clearinghouseCodeHash', 'destinationSpokePoolCodeHash', 'destinationSpokePoolImplementationCodeHash', 'multicallHandlerCodeHash']) {
    for (const value of [undefined, null, hash(0), '0x1234', hash(999)]) {
      const f = fixture()
      if (value === undefined) delete f.manifest[field]
      else f.manifest[field] = value
      await assert.rejects(verifyFundingManifest(f.manifest, f), /missing or unknown fields|Invalid .*CodeHash|disagrees with release evidence/)
      assert.deepEqual(f.reads, [])
    }
  }
  for (const field of ['destinationSpokePool', 'destinationSpokePoolImplementation', 'multicallHandler']) {
    for (const value of [null, address(0), address(999)]) {
      const f = fixture()
      f.manifest[field] = value
      await assert.rejects(verifyFundingManifest(f.manifest, f), /Invalid|disagrees with release evidence/)
      assert.deepEqual(f.reads, [])
    }
  }
})

test('rejects wrong chain, empty code, substituted code, and a legacy clearinghouse at the probe block', async () => {
  for (const name of contractNames) {
    const f = fixture()
    f.code[f.manifest.evidence.contracts[name].address] = '0x'
    await assert.rejects(verifyFundingManifest(f.manifest, f), /has no contract code/)
  }
  const chain = fixture()
  await assert.rejects(verifyFundingManifest(chain.manifest, { ...chain, rpc: (method, params) => method === 'eth_chainId' ? '0x1' : chain.rpc(method, params) }), /RPC chain/)
  for (const [contractName, field] of [['marginClearinghouse', 'clearinghouseCodeHash'],
    ['destinationSpokePool', 'destinationSpokePoolCodeHash'],
    ['destinationSpokePoolImplementation', 'destinationSpokePoolImplementationCodeHash'], ['multicallHandler', 'multicallHandlerCodeHash']]) {
    const changed = fixture()
    changed.manifest.evidence.contracts[contractName].runtimeCodeHash = hash(999)
    changed.manifest[field] = hash(999)
    await assert.rejects(verifyFundingManifest(changed.manifest, changed), /runtime code hash mismatch/)
  }
  const legacy = fixture()
  await assert.rejects(verifyFundingManifest(legacy.manifest, { ...legacy, rpc: (method, params) => method === 'eth_getCode' && params[0] === legacy.manifest.clearinghouse && params[1] === '0x30' ? '0x600099' : legacy.rpc(method, params) }), /runtime code hash mismatch/)
})

test('rejects a changed or invalid proxy implementation slot even when all code pins match', async () => {
  for (const value of [undefined, '0x', word(0), word(address(999)), `0x01${'00'.repeat(11)}${address(9).slice(2)}`]) {
    const f = fixture()
    f.storage[`${f.manifest.destinationSpokePool}:${implementationSlot}`] = value
    await assert.rejects(verifyFundingManifest(f.manifest, f), /SpokePool implementation mismatch/)
  }
})

test('rejects every mixed-deployment binding and wrong token decimals', async () => {
  for (const [name, signature] of bindings) {
    const f = fixture()
    f.calls[`${f.manifest.evidence.contracts[name].address}:${selectors[signature]}`] = word(address(999))
    await assert.rejects(verifyFundingManifest(f.manifest, f), /binding mismatch/)
  }
  const f = fixture()
  f.calls[`${f.manifest.token}:${selectors['decimals()']}`] = word(18)
  await assert.rejects(verifyFundingManifest(f.manifest, f), /decimals mismatch/)
})

test('requires successful direct third-party depositFor evidence, not an arbitrary success receipt', async () => {
  const changes = [
    f => { f.receipts[f.manifest.evidence.depositFor.transactionHash].status = '0x0' },
    f => { f.transactions[f.manifest.evidence.depositFor.transactionHash].to = address(999) },
    f => { f.transactions[f.manifest.evidence.depositFor.transactionHash].from = address(999) },
    f => { f.transactions[f.manifest.evidence.depositFor.transactionHash].input = '0x' },
    f => { f.transactions[f.manifest.evidence.depositFor.transactionHash].value = '0x1' },
    f => { f.receipts[f.manifest.evidence.depositFor.transactionHash].logs.pop() },
    f => { f.receipts[f.manifest.evidence.depositFor.transactionHash].logs[0].address = address(999) },
    f => { f.receipts[f.manifest.evidence.depositFor.transactionHash].logs[0].topics[2] = word(address(999)) },
    f => { f.receipts[f.manifest.evidence.depositFor.transactionHash].logs[0].data = word(999) },
    f => { f.receipts[f.manifest.evidence.depositFor.transactionHash].logs[0].removed = true },
    f => { f.receipts[f.manifest.evidence.depositFor.transactionHash].logs.push(clone(f.receipts[f.manifest.evidence.depositFor.transactionHash].logs[0])) },
  ]
  for (const change of changes) {
    const f = fixture()
    change(f)
    await assert.rejects(verifyFundingManifest(f.manifest, f), change.toString())
  }
})

test('rejects an indexing gap, insufficient confirmations, and reorganized evidence', async () => {
  const changes = [
    f => { f.manifest.startBlock = 49 },
    f => { f.manifest.confirmations = 18 },
    f => { f.blocks['0x30'].hash = hash(999) },
  ]
  for (const change of changes) {
    const f = fixture()
    change(f)
    await assert.rejects(verifyFundingManifest(f.manifest, f), change.toString())
  }
  const boundary = fixture()
  boundary.manifest.startBlock = 48
  await verifyFundingManifest(boundary.manifest, boundary)
  const f = fixture()
  await assert.rejects(verifyFundingManifest(f.manifest, { ...f, rpc: async (method, params) => {
    const result = await f.rpc(method, params)
    return method === 'eth_getBlockByNumber' && params[0] === '0x40' ? { ...result, hash: hash(999) } : result
  } }), /reorganized/)
})
