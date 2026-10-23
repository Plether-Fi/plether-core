import { readFileSync } from 'node:fs'
import * as client from '@plether-fi/perps-aa-client'
import { assertCompatibility } from './scenarios.mjs'

const fixture = JSON.parse(readFileSync(new URL('./baseline.json', import.meta.url), 'utf8'))
const schema = JSON.parse(readFileSync(new URL('./current-v5-schema.json', import.meta.url), 'utf8'))
await assertCompatibility(client, fixture, schema)
console.log('Installed package: reviewed current ABI, archived V4 ABI, seven retained plus five current protection action encodings, sponsorship/UserOperation hashes, and protection journaling passed.')
