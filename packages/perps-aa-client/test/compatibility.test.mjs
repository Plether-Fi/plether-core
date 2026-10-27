import { readFileSync } from 'node:fs'
import { expect, it } from 'vitest'
import * as client from '../src/index.ts'
import { assertCompatibility } from './compatibility/scenarios.mjs'

it('preserves the app baseline encodings and native sponsorship for protection actions', async () => {
  const fixture = JSON.parse(readFileSync(new URL('./compatibility/baseline.json', import.meta.url), 'utf8'))
  const schema = JSON.parse(readFileSync(new URL('./compatibility/current-assets-v5-schema.json', import.meta.url), 'utf8'))
  await assertCompatibility(client, fixture, schema)
})

it('rejects unreviewed current ABI changes and retired public exports', async () => {
  const fixture = JSON.parse(readFileSync(new URL('./compatibility/baseline.json', import.meta.url), 'utf8'))
  const schema = JSON.parse(readFileSync(new URL('./compatibility/current-assets-v5-schema.json', import.meta.url), 'utf8'))
  const abi = client.positionProtectionBookAbi
  for (const changed of [
    abi.filter(item => item.name !== 'commitOpenOrderWithProtection'),
    [...abi, { type: 'error', name: 'UnreviewedError', inputs: [] }],
  ]) await expect(assertCompatibility({ ...client, positionProtectionBookAbi: changed }, fixture, schema)).rejects.toThrow()
  await expect(assertCompatibility({ ...client, orderLifecycleV4Abi: [] }, fixture, schema)).rejects.toThrow()
  await expect(assertCompatibility({ ...client, hashOrderReceiptV4() {} }, fixture, schema)).rejects.toThrow()
})
