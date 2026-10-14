import { readFileSync } from 'node:fs'
import { expect, it } from 'vitest'
import * as client from '../src/index.ts'
import { assertCompatibility } from './compatibility/scenarios.mjs'

it('preserves the app baseline encodings and native sponsorship for protection actions', async () => {
  const fixture = JSON.parse(readFileSync(new URL('./compatibility/baseline.json', import.meta.url), 'utf8'))
  await assertCompatibility(client, fixture)
})

it('rejects any protection ABI change beyond the exact reviewed bounty and settlement-floor errors', async () => {
  const fixture = JSON.parse(readFileSync(new URL('./compatibility/baseline.json', import.meta.url), 'utf8'))
  const abi = client.positionProtectionBookAbi
  const reviewedNames = [
    'OrderRouter__PledgeBountyRequiresEmptyQueue',
    'OrderRouter__RestoredPledgeMadeSolvent',
    'OrderRouter__SettlementFloorFunding',
    'OrderRouter__SettlementFloorOrderPending',
    'OrderRouter__SettlementFloorUnsupported',
    'OrderRouter__SettlementFloorWithdrawal',
  ]
  for (const name of reviewedNames) {
    for (const changed of [
      abi.filter(item => item.name !== name),
      abi.map(item => item.name === name ? { ...item, inputs: [{ name: 'amount', type: 'uint256' }] } : item),
    ]) await expect(assertCompatibility({ ...client, positionProtectionBookAbi: changed }, fixture)).rejects.toThrow()
  }
  for (const changed of [
    [...abi, { type: 'error', name: 'UnreviewedError', inputs: [] }],
    abi.filter(item => item.name !== 'commitOpenOrderWithProtection'),
  ]) await expect(assertCompatibility({ ...client, positionProtectionBookAbi: changed }, fixture)).rejects.toThrow()
})
