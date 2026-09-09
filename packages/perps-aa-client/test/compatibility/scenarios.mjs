import assert from 'node:assert/strict'
import { concatHex, encodeFunctionData, keccak256, numberToHex, parseAbi } from 'viem'
import { getUserOperationHash } from 'viem/account-abstraction'

export const account = '0x2222222222222222222222222222222222222222'
const owner = '0x1111111111111111111111111111111111111111'
const usdc = '0x3333333333333333333333333333333333333333'
const clearinghouse = '0x4444444444444444444444444444444444444444'
const orderRouter = '0x5555555555555555555555555555555555555555'
const cfdEngine = '0x6666666666666666666666666666666666666666'
const book = '0x8888888888888888888888888888888888888888'
const word = byte => `0x${byte.repeat(32)}`
export const profile = {
  chainId: 421614,
  entryPoint: '0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108',
  paymaster: '0x7777777777777777777777777777777777777777',
  policyId: word('42'), accountCodeHash: word('24'),
  paymasterVerificationGasLimit: 100000n, paymasterPostOpGasLimit: 0n,
  maxValidityWindowSeconds: 600n,
}

export function response(signatureByte = '99') {
  return {
    paymaster: profile.paymaster,
    paymasterVerificationGasLimit: '0x186a0', paymasterPostOpGasLimit: '0x0',
    paymasterData: concatHex([
      numberToHex(1900000000n, { size: 6 }), numberToHex(1899999700n, { size: 6 }),
      numberToHex(1000000000000000n, { size: 16 }), profile.policyId, profile.accountCodeHash,
      `0x${signatureByte.repeat(65)}`,
    ]),
  }
}

export function actions(client) {
  const params = { takeProfitTriggerPrice: 70000000n, stopLossTriggerPrice: 90000000n }
  return [
    client.buildAuthorizedDepositAction({ account, usdc, clearinghouse,
      authorization: { from: owner, to: account, value: 25000000n, validAfter: 10n, validBefore: 1000n, nonce: word('ab') },
      authorizationSignature: `0x${'11'.repeat(32)}${'22'.repeat(32)}1b` }),
    client.buildSmartAccountBalanceDepositAction({ account, usdc, clearinghouse, amount: 12000000n }),
    client.buildPlaceOrderAction({ account, orderRouter, side: 'BEAR', sizeDelta: 10n ** 18n, marginDelta: 2000000n, targetPrice: 123456789n, isClose: false }),
    client.buildAddMarginAction({ account, cfdEngine, amount: 7000000n }),
    client.buildWithdrawAction({ account, clearinghouse, amount: 9000000n }),
    client.buildWithdrawToOwnerAction({ account, owner, usdc, clearinghouse, amount: 12345678n }),
    client.buildSettleTraderClaimAction({ account, cfdEngine }),
    client.buildCreateProtectionAction({ account, book, params }),
    client.buildReplaceProtectionAction({ account, book, params, protectionId: 42n }),
    client.buildCancelProtectionAction({ account, book, protectionId: 42n }),
    client.buildProtectedOpenAction({ account, book, params, request: {
      clientOrderId: word('ab'), side: 1, sizeDelta: 10n ** 18n, marginDelta: 2000000n, targetPrice: 80000000n, isClose: false,
      bounds: { validUntil: 1900000000n, allowedExecutionModes: 1, expectedConfigHash: word('cd'),
        maxExecutionBountyUsdc: 100000n, maxExecutionNotionalUsdc: 21000000n,
        maxGrossAccountDebitUsdc: 3000000n, maxActionChargeUsdc: 200000n, maxExplicitFeesUsdc: 300000n,
        maxPostPositionSize: 2n * 10n ** 18n, minPostSettlementBalanceUsdc: 400000n,
        minPostPositionEquityUsdc: 500000n, maxPostLeverageBps: 100000 },
    } }),
  ]
}

const simpleAccountAbi = parseAbi(['function execute(address target, uint256 value, bytes data)', 'function executeBatch((address target, uint256 value, bytes data)[] calls)'])
export function operationFor(action, envelope) {
  const calls = action.calls.map(call => ({ target: call.to, value: call.value, data: call.data }))
  const callData = calls.length === 1
    ? encodeFunctionData({ abi: simpleAccountAbi, functionName: 'execute', args: [calls[0].target, calls[0].value, calls[0].data] })
    : encodeFunctionData({ abi: simpleAccountAbi, functionName: 'executeBatch', args: [calls] })
  return { sender: account, nonce: 7n, callData, callGasLimit: 500000n, verificationGasLimit: 250000n,
    preVerificationGas: 75000n, maxPriorityFeePerGas: 1000000000n, maxFeePerGas: 2000000000n,
    paymaster: envelope.paymaster, paymasterData: envelope.paymasterData,
    paymasterVerificationGasLimit: envelope.paymasterVerificationGasLimit,
    paymasterPostOpGasLimit: envelope.paymasterPostOpGasLimit, signature: '0x' }
}

export const operationHash = userOperation => getUserOperationHash({ userOperation, entryPointAddress: profile.entryPoint, entryPointVersion: '0.8', chainId: profile.chainId })
const serializable = value => JSON.parse(JSON.stringify(value, (_, v) => typeof v === 'bigint' ? v.toString() : v))

export function captureCompatibility(client) {
  const envelope = client.normalizePaymasterResponse(response())
  const plans = actions(client)
  return serializable({
    exports: Object.keys(client).sort(), envelope,
    actions: plans.map(plan => {
      const operation = operationFor(plan, envelope)
      const sponsorshipHash = client.hashPletherSponsorship({ chainId: profile.chainId, entryPoint: profile.entryPoint,
        userOperation: { sender: operation.sender, nonce: operation.nonce, initCode: '0x', callData: operation.callData,
          accountGasLimits: numberToHex((operation.verificationGasLimit << 128n) | operation.callGasLimit, { size: 32 }),
          preVerificationGas: operation.preVerificationGas,
          gasFees: numberToHex((operation.maxPriorityFeePerGas << 128n) | operation.maxFeePerGas, { size: 32 }),
          paymasterAndData: envelope.paymasterAndData } })
      return { plan, accountCallData: operation.callData, sponsorshipHash, userOperationHash: operationHash(operation) }
    }),
    protectionAbiHash: keccak256(new TextEncoder().encode(JSON.stringify(client.positionProtectionBookAbi))),
  })
}

export async function assertCompatibility(client, fixture) {
  assert.deepEqual(captureCompatibility(client), fixture, 'Published package changed the baseline encoding, hashes, ABI, or exports')
  const finalEnvelope = client.normalizePaymasterResponse(response())
  const stubEnvelope = client.normalizePaymasterResponse(response('00'))
  // Every protection action traverses the hardened native-sponsorship path.
  for (const action of actions(client).slice(-4)) {
    let journaled
    const events = []
    const input = {
      chainId: profile.chainId, action, paymasterProfile: profile,
      account: { accountAddress: account, entryPoint: profile.entryPoint,
        async buildUserOperation() { return operationFor(action, stubEnvelope) },
        applyPaymaster(op, envelope) { return { ...op, paymasterData: envelope.paymasterData } },
        applyGasEstimate(op) { return op },
        async signUserOperation(op) {
          assert.equal(op.paymasterData, finalEnvelope.paymasterData)
          events.push('sign')
          return { ...op, signature: `0x${'12'.repeat(65)}` }
        } },
      sponsor: { async getPaymasterStubData() { return response('00') }, async getPaymasterData() { return response() } },
      bundler: { async estimateUserOperationGas() { return {} }, async sendUserOperation({ operation }) {
        assert.strictEqual(operation, journaled, 'Submission must use the exact journaled object')
        events.push('send')
        return operationHash(operation)
      } },
      async journalSignedUserOperation({ operation }) { events.push('journal'); journaled = operation; return operationHash(operation) },
    }
    const result = await client.sendSponsoredAction(input)
    assert.deepEqual(events, ['sign', 'journal', 'send'])
    assert.equal(result.userOperationHash, fixture.actions.find(item => item.plan.kind === action.kind).userOperationHash)
    events.length = 0
    await assert.rejects(client.sendSponsoredAction({ ...input, async journalSignedUserOperation() { throw new Error('Persistence failed') } }))
    assert.deepEqual(events, ['sign'], 'A failed journal must prevent submission')
  }
}
