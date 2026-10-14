import { readFileSync } from 'node:fs'
import { expect, it } from 'vitest'
import * as client from '../src/index.ts'
import { assertCompatibility } from './compatibility/scenarios.mjs'

it('preserves the app baseline encodings and native sponsorship for protection actions', async () => {
  const fixture = JSON.parse(readFileSync(new URL('./compatibility/baseline.json', import.meta.url), 'utf8'))
  await assertCompatibility(client, fixture)
})

it('rejects any protection ABI change beyond the exact reviewed source-bound error extension', async () => {
  const fixture = JSON.parse(readFileSync(new URL('./compatibility/baseline.json', import.meta.url), 'utf8'))
  const abi = client.positionProtectionBookAbi
  const name = 'OrderRouter__PledgeBountyRequiresEmptyQueue'
  for (const changed of [
    abi.filter(item => item.name !== name),
    abi.map(item => item.name === name ? { ...item, inputs: [{ name: 'amount', type: 'uint256' }] } : item),
    [...abi, { type: 'error', name: 'UnreviewedError', inputs: [] }],
    abi.filter(item => item.name !== 'commitOpenOrderWithProtection'),
  ]) await expect(assertCompatibility({ ...client, positionProtectionBookAbi: changed }, fixture)).rejects.toThrow()
})
