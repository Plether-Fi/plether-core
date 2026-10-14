#!/usr/bin/env node
// One-shot reference tool, not a daemon. Build the SDK first. Never logs signer material or RPC URLs.
import fs from 'node:fs'
import { createPublicClient, createWalletClient, defineChain, encodeEventTopics, http, isAddressEqual, keccak256, parseAbi } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { buildExecuteOrderV3, buildExecuteOrderBatchV3, buildExpireOrderV3, buildRiskOffCleanupV3, buildTriggerProtection, buildRetryProtection, classifyKeeperHead, quoteExecutionNativeValue, orderLifecycleV5Abi, decodeVerifiedOrderFinalized } from '../dist/index.js'

const [command, idText, payloadFile] = process.argv.slice(2).filter(x => x !== '--send')
if (!command || command === '--help') {
  console.log('close-operator.mjs inspect | verify TX_HASH | execute|expire|riskoff|batch|trigger|retry ID [PYTH_JSON] [--send]\nRequired: PERPS_RELEASE_MANIFEST, PERPS_RPC_URL. Simulation: EXECUTOR_ADDRESS. Sending: OPERATOR_PRIVATE_KEY and MAX_TX_COST_WEI. Batch: ORACLE_VALUE_WEI. No background retries.')
  process.exit(0)
}
const readAbi = parseAbi(['function nextExecuteId() view returns (uint64)', 'function nextCommitId() view returns (uint64)', 'function lifecycleBook() view returns (address)', 'function pletherOracle() view returns (address)', 'function positionProtectionBook() view returns (address)'])
async function main() {
  const manifest = JSON.parse(fs.readFileSync(process.env.PERPS_RELEASE_MANIFEST, 'utf8'))
  if (manifest.orderInterfaceVersion !== 3) throw new Error('A current V3 release manifest is required')
  const chain = defineChain({ id: manifest.network.chainId, name: 'Reviewed perps chain', nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [process.env.PERPS_RPC_URL] } } })
  const transport = http(process.env.PERPS_RPC_URL)
  const client = createPublicClient({ chain, transport })
  if (await client.getChainId() !== chain.id) throw new Error('RPC chain mismatch')
  const contracts = manifest.contracts
  for (const name of ['orderRouter', 'orderLifecycleBook', 'positionProtectionBook', 'pletherOracle']) {
    const binding = contracts[name]
    const code = await client.getCode({ address: binding.address })
    if (!code || keccak256(code).toLowerCase() !== binding.runtimeCodeHash.toLowerCase()) throw new Error('Runtime binding mismatch')
  }
  const router = contracts.orderRouter.address, book = contracts.orderLifecycleBook.address, oracle = contracts.pletherOracle.address, protection = contracts.positionProtectionBook.address
  for (const [getter, expected] of [['lifecycleBook', book], ['pletherOracle', oracle], ['positionProtectionBook', protection]]) {
    if (!isAddressEqual(await client.readContract({ address: router, abi: readAbi, functionName: getter }), expected)) throw new Error('Router graph mismatch')
  }
  const block = await client.getBlock()
  const read = (address, abi, functionName, args = []) => client.readContract({ address, abi, functionName, args, blockNumber: block.number })
  async function verify(hash) {
    const tx = await client.getTransactionReceipt({ hash })
    if (tx.status !== 'success' || (await client.getBlock({ blockNumber: tx.blockNumber })).hash !== tx.blockHash) throw new Error('Reverted or orphaned transaction')
    let count = 0
    const terminalTopic = encodeEventTopics({ abi: orderLifecycleV5Abi, eventName: 'OrderFinalized' })[0]
    for (const log of tx.logs.filter(log => isAddressEqual(log.address, book) && log.topics[0] === terminalTopic)) {
      // Only canonical OrderFinalized logs authenticate order outcomes.
        const id = BigInt(log.topics[1])
        const summary = await client.readContract({ address: book, abi: orderLifecycleV5Abi, functionName: 'terminalOutcome', args: [id], blockNumber: tx.blockNumber })
        const event = decodeVerifiedOrderFinalized({ chainId: BigInt(chain.id), book, router, summary, log })
        console.log(JSON.stringify({ orderId: id.toString(), status: event.receipt.status, reason: event.receipt.reason, receiptHash: event.receiptHash }))
        count++
    }
    console.log(JSON.stringify({ hash, authenticatedTerminalOrders: count, note: 'Zero receipts does not mean an order executed. Inspect pending/protection state before retrying.' }))
  }
  if (command === 'verify') return verify(idText)
  const head = await read(router, readAbi, 'nextExecuteId'), nextCommit = await read(router, readAbi, 'nextCommitId')
  if (command === 'inspect') {
    const status = head > 0n && head < nextCommit ? await read(book, orderLifecycleV5Abi, 'lifecycleStatus', [head]) : 0
    const timing = status === 1 ? await read(book, orderLifecycleV5Abi, 'orderTiming', [head]) : { executionDeadline: 0n }
    console.log(JSON.stringify({ head: head.toString(), nextCommit: nextCommit.toString(), status, deadline: timing.executionDeadline.toString(), decision: classifyKeeperHead({ head, nextCommit, status, now: block.timestamp, deadline: timing.executionDeadline }) }))
    return
  }
  const id = BigInt(idText)
  const data = payloadFile ? JSON.parse(fs.readFileSync(payloadFile, 'utf8')) : []
  const signer = process.env.OPERATOR_PRIVATE_KEY ? privateKeyToAccount(process.env.OPERATOR_PRIVATE_KEY) : process.env.EXECUTOR_ADDRESS
  if (!signer) throw new Error('An explicit simulation executor is required')
  let call
  if (command === 'expire') {
    const timing = await read(book, orderLifecycleV5Abi, 'orderTiming', [id])
    if (!timing.executionDeadline || block.timestamp <= timing.executionDeadline) throw new Error('Not strictly expired')
    call = buildExpireOrderV3(router, id)
  } else if (command === 'riskoff') call = buildRiskOffCleanupV3(router, id)
  else if (command === 'retry') call = buildRetryProtection(protection, id)
  else if (command === 'trigger') call = buildTriggerProtection(protection, id, data, await quoteExecutionNativeValue(client, oracle, data, true))
  else if (command === 'execute') {
    if (id !== head || id >= nextCommit) throw new Error('Not a committed canonical head')
    call = buildExecuteOrderV3(router, id, data, await quoteExecutionNativeValue(client, oracle, data))
  } else if (command === 'batch') call = buildExecuteOrderBatchV3(router, id, data, BigInt(process.env.ORACLE_VALUE_WEI))
  else throw new Error('Unknown command')
  const simulation = await client.call({ account: signer, ...call })
  const gas = (await client.estimateGas({ account: signer, ...call })) * 125n / 100n
  const fees = await client.estimateFeesPerGas()
  const maximumCost = call.value + gas * fees.maxFeePerGas
  console.log(JSON.stringify({ command, id: id.toString(), value: call.value.toString(), gas: gas.toString(), maximumCost: maximumCost.toString(), simulation: simulation.data, note: 'Simulation can report Pending or partial batch progress; recheck authenticated outcomes after inclusion.' }))
  if (!process.argv.includes('--send')) return
  if (typeof signer === 'string' || !signer || maximumCost > BigInt(process.env.MAX_TX_COST_WEI ?? '0')) throw new Error('Explicit signer and sufficient spending cap required')
  const wallet = createWalletClient({ chain, account: signer, transport })
  const hash = await wallet.sendTransaction({ ...call, gas, ...fees })
  console.log(JSON.stringify({ hash }))
  await client.waitForTransactionReceipt({ hash })
  await verify(hash)
}
await main().catch(error => { console.error(`Operator check failed (${error.name}); no automatic retry. Inspect configuration, canonical queue and RPC access.`); process.exitCode = 1 })
