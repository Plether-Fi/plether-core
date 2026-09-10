import { readFileSync } from 'node:fs'
import { it } from 'vitest'
import * as client from '../src/index.ts'
import { assertCompatibility } from './compatibility/scenarios.mjs'

it('preserves the app baseline encodings and native sponsorship for protection actions', async () => {
  const fixture = JSON.parse(readFileSync(new URL('./compatibility/baseline.json', import.meta.url), 'utf8'))
  await assertCompatibility(client, fixture)
})
