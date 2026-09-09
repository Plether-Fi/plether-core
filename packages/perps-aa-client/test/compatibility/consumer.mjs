import { readFileSync } from 'node:fs'
import * as client from '@plether-fi/perps-aa-client'
import { assertCompatibility } from './scenarios.mjs'

const fixture = JSON.parse(readFileSync(new URL('./baseline.json', import.meta.url), 'utf8'))
await assertCompatibility(client, fixture)
console.log('Installed package: all exports, 11 action encodings, sponsorship/UserOperation hashes, and protection journaling passed.')
