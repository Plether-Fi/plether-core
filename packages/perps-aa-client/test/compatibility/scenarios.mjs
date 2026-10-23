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
  const closeLimits = { maxExecutionNotionalUsdc: 21000000n, maxGrossAccountDebitUsdc: 3000000n,
    maxActionChargeUsdc: 200000n, maxExplicitFeesUsdc: 300000n }
  const params = { takeProfitTriggerPrice: 70000000n, stopLossTriggerPrice: 90000000n, closeLimits }
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
      bounds: { submitBy: 1900000000n, executionWindowSeconds: 60, allowedExecutionModes: 1, expectedConfigHash: word('cd'),
        maxExecutionBountyUsdc: 100000n, maxExecutionNotionalUsdc: 21000000n,
        maxGrossAccountDebitUsdc: 3000000n, maxActionChargeUsdc: 200000n, maxExplicitFeesUsdc: 300000n,
        maxPostPositionSize: 2n * 10n ** 18n, minPostSettlementBalanceUsdc: 400000n,
        minPostPositionEquityUsdc: 500000n, maxPostLeverageBps: 100000 },
    } }),
    client.buildAmendLatchedProtectionCloseLimitsAction({ account, book, protectionId: 42n, closeLimits }),
    client.buildCancelProtectionAndCloseAction({ account, book, protectionId: 42n, request: {
      clientOrderId: word('ef'), side: 1, sizeDelta: 200n * 10n ** 18n, marginDelta: 0n, targetPrice: 80000000n, isClose: true,
      bounds: { submitBy: 1900000000n, executionWindowSeconds: 60, allowedExecutionModes: 7, expectedConfigHash: word('cd'),
        maxExecutionBountyUsdc: 0n, ...closeLimits, maxPostPositionSize: 0n, minPostSettlementBalanceUsdc: 0n,
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

export async function assertCompatibility(client, fixture, currentSchema) {
  const current = captureCompatibility(client)
  assert.equal(currentSchema.schema, 'current-v5', 'Wrong current schema golden')
  assert.equal(fixture.protectionAbiHash, currentSchema.historicalProtectionAbiHash,
    'Immutable historical protection ABI baseline changed')
  assert.equal(fixture.actions.length, 11, 'Immutable historical action baseline changed')
  // The immutable 0.2 baseline guards unaffected action calldata and hashes.
  // MED-9/MED-30 protection actions and the V5 receipt/view are reviewed current-schema changes.
  const expectedExports = fixture.exports.filter(name => name !== 'hashOrderReceiptV4')
    .concat('hashOrderReceiptV5', 'buildAmendLatchedProtectionCloseLimitsAction', 'buildCancelProtectionAndCloseAction').sort()
  assert.deepEqual(current.exports, expectedExports, 'Only the reviewed current-receipt and protection exports may change')
  assert.deepEqual(current.envelope, fixture.envelope, 'Native sponsorship envelope changed')
  assert.deepEqual(current.actions.slice(0, 7), fixture.actions.slice(0, 7),
    'Retained non-protection action calldata or sponsorship hashes changed')
  assert.deepEqual(current.actions.slice(7), currentSchema.protectionActions,
    'Current protection action calldata or sponsorship hashes changed')
  assert.equal(current.protectionAbiHash, currentSchema.protectionAbiHash, 'Current protection ABI changed')
  const closeLimitNames = ['maxExecutionNotionalUsdc', 'maxGrossAccountDebitUsdc',
    'maxActionChargeUsdc', 'maxExplicitFeesUsdc']
  const requireCloseLimitsTuple = tuple => {
    assert.equal(tuple?.type, 'tuple', 'Close limits must be one tuple')
    assert.deepEqual(tuple.components.map(({ name, type }) => [name, type]),
      closeLimitNames.map(name => [name, 'uint256']), 'Close limits tuple changed')
  }
  const bookFunction = name => {
    const item = client.positionProtectionBookAbi.find(entry => entry.type === 'function' && entry.name === name)
    assert(item, `Current Book function ${name} is missing`)
    return item
  }
  for (const [name, paramsIndex] of [
    ['commitOpenOrderWithProtection', 1], ['createPositionProtection', 0], ['replacePositionProtection', 1],
  ]) {
    const params = bookFunction(name).inputs[paramsIndex]
    assert.deepEqual(params.components.map(({ name }) => name),
      ['takeProfitTriggerPrice', 'stopLossTriggerPrice', 'closeLimits'], `${name} parameters changed`)
    requireCloseLimitsTuple(params.components[2])
  }
  requireCloseLimitsTuple(bookFunction('closeFinancialLimits').outputs[0])
  requireCloseLimitsTuple(bookFunction('amendLatchedPositionProtectionCloseLimits').inputs[1])
  const cancelAndClose = bookFunction('cancelPositionProtectionAndCommitClose')
  assert.equal(cancelAndClose.stateMutability, 'nonpayable', 'Atomic protection close must carry no native value')
  assert.equal(cancelAndClose.inputs.length, 2, 'Atomic protection close must bind one protection ID and one request')
  assert.equal(cancelAndClose.inputs[0].type, 'uint64', 'Atomic protection close ID type changed')
  assert.deepEqual(cancelAndClose.inputs[1], bookFunction('commitOpenOrderWithProtection').inputs[0],
    'Atomic protection close must preserve the complete bounded V3 request tuple')
  for (const [name, abi] of Object.entries({
    closePreviewV3Abi: client.closePreviewV3Abi,
    committedOrderV3Abi: client.committedOrderV3Abi,
    orderLifecycleV5Abi: client.orderLifecycleV5Abi,
    orderRouterV3Abi: client.orderRouterV3Abi,
  })) {
    assert.equal(keccak256(new TextEncoder().encode(JSON.stringify(abi))), currentSchema.abiHashes[name],
      `${name} differs from the reviewed V5 schema`)
  }
  assert.equal(keccak256(new TextEncoder().encode(JSON.stringify(client.orderLifecycleV4Abi))),
    currentSchema.historicalOrderLifecycleV4AbiHash, 'Archived V4 Book ABI changed')
  const preview = client.closePreviewV3Abi.find(item => item.type === 'function' && item.name === 'previewClose')
  assert(preview, 'Current close preview is missing')
  assert.equal(preview.inputs.some(item => item.name === 'publishTime'), false,
    'Current close preview retains an unused publish-time argument')
  assert.equal(preview.outputs[0].components.some(item => item.name === 'executionBountyUsdc'), false,
    'Current close preview must not expose a zero-only bounty output')
  const protectionCreated = client.positionProtectionBookAbi.find(item => item.type === 'event' && item.name === 'PositionProtectionCreated')
  assert(protectionCreated, 'Current protection-created event is missing')
  assert.deepEqual(protectionCreated.inputs.map(item => item.name),
    ['protectionId', 'account', 'parentOrderId', 'takeProfitTriggerPrice', 'stopLossTriggerPrice', 'triggerBountyUsdc'],
    'Current protection-created event still includes the zero-only execution bounty')
  const protectionCreatedSignature = `${protectionCreated.name}(${protectionCreated.inputs.map(item => item.type).join(',')})`
  assert.equal(keccak256(new TextEncoder().encode(protectionCreatedSignature)),
    currentSchema.positionProtectionCreatedTopic0, 'Protection-created topic0 changed')
  const committedAssessment = client.committedOrderV3Abi.find(item => item.type === 'function' && item.name === 'assessCommittedOrder')
  assert(committedAssessment, 'Committed-order evaluator is missing')
  assert.equal(committedAssessment.inputs.some(item => item.name === 'publishTime'), false,
    'Current committed-order evaluator retains an unused publish-time argument')
  const finalized = client.orderLifecycleV5Abi.find(item => item.type === 'event' && item.name === 'OrderFinalized')
  assert(finalized, 'Current terminal event is missing')
  const receipt = finalized.inputs.find(item => item.name === 'receipt')
  assert(receipt, 'Current receipt is missing')
  for (const retired of ['bountyFromPledgeUsdc', 'bountyRetainedUsdc', 'sourcePositionEpoch']) {
    assert.equal(JSON.stringify(receipt).includes(`"${retired}"`), false,
      `Current receipt retains retired field ${retired}`)
  }
  const finalEnvelope = client.normalizePaymasterResponse(response())
  const stubEnvelope = client.normalizePaymasterResponse(response('00'))
  // Every protection action traverses the hardened native-sponsorship path.
  for (const action of actions(client).slice(7)) {
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
    assert.equal(result.userOperationHash, currentSchema.protectionActions.find(item => item.plan.kind === action.kind).userOperationHash)
    events.length = 0
    await assert.rejects(client.sendSponsoredAction({ ...input, async journalSignedUserOperation() { throw new Error('Persistence failed') } }))
    assert.deepEqual(events, ['sign'], 'A failed journal must prevent submission')
  }
}
