#!/usr/bin/env python3
"""Capture public signed Pyth baskets across an LP epoch boundary. Never broadcasts.

Reads two mined router transactions and untouched Pyth storage from Arbitrum
Sepolia. The mixed basket selects intact messages and Merkle proofs using the
existing accumulator subset helper. No credentials or Hermes access are needed.
Real Pyth signature verification is performed by the consuming fork tests.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
RPC = 'https://arbitrum-sepolia.gateway.tenderly.co'
FORK_BLOCK = 311799811
FORK_HASH = '0x9bed2bbe389aaba3ccdfd0981e96353cadcd7937fa829b5c98daa39e22f143d2'
EPOCH_START = 1790143200
ROUTER = '0x6215d36fcbd610ca1525252eebcbfd8b223a6072'
SOURCES = {
    'before': ('0xdbcdfb4edd0b08dcfbf023f2a8ad25bd9f806d3fccdf73ecf0c8c18f9a921cf8',
               'executeLiquidationBatch(address[],bytes[])', '0x07f4f6cf', 1),
    'after': ('0xbcb40d23b06260d3f0e5874c953b8c74e8b062f20495d4e478609a903dcd029e',
              'updateMarkPrice(bytes[])', '0x2efdaf14', 0),
}


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def call(method, params):
    data = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode()
    request = urllib.request.Request(RPC, data=data, headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=60) as response:
        result = json.load(response)
    if 'error' in result:
        raise ValueError('Public RPC rejected ' + method)
    return result['result']


def payload_hash(payload):
    return hashlib.sha256(b''.join(bytes.fromhex(value.removeprefix('0x')) for value in payload)).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Refusing to overwrite a fixture; capture to a temporary file and compare')
    capture = module('oracle_capture', 'capture-oracle-sync-fixture.py')
    derive = module('oracle_subset', 'derive-live-watermark-fixture.py')
    base = json.loads((ROOT / 'test/fixtures/oracle-sync/arbitrum-sepolia.json').read_text())
    fixture = {key: base[key] for key in (
        'schemaVersion', 'chainId', 'pyth', 'feedIds', 'quantities', 'basePrices', 'inversions')}
    if int(call('eth_chainId', []), 16) != fixture['chainId']:
        raise ValueError('Wrong chain')
    block = call('eth_getBlockByNumber', [hex(FORK_BLOCK), False])
    if block['hash'] != FORK_HASH or int(block['timestamp'], 16) > EPOCH_START - 600:
        raise ValueError('Pinned pre-epoch block mismatch')
    if call('eth_getCode', [fixture['pyth'], block['number']]) == '0x':
        raise ValueError('Pyth is absent at the pinned block')
    fixture.update(
        epochStart=EPOCH_START,
        description='Exact signed Pyth FX baskets before and after an LP whole-hour epoch boundary.',
        payloadHashEncoding='SHA-256 of concatenated decoded updateData bytes, in array order',
        captureScript='scripts/capture-pool-epoch-fixture.py',
        forkBlockNumber=FORK_BLOCK,
        forkBlockHash=FORK_HASH,
        forkTimestamp=int(block['timestamp'], 16),
        initialStoredPublishTimes=[],
    )
    selector = subprocess.check_output(['cast', 'sig', 'getPriceUnsafe(bytes32)'], text=True).strip()
    for feed in fixture['feedIds']:
        response = call('eth_call', [{'to': fixture['pyth'], 'data': selector + feed[2:]}, block['number']])
        if len(response) != 2 + 4 * 64:
            raise ValueError('Malformed stored Pyth price')
        fixture['initialStoredPublishTimes'].append(int(response[-64:], 16))
    fixture['updates'] = {}
    for name, (transaction_hash, signature, selector, argument) in SOURCES.items():
        tx = call('eth_getTransactionByHash', [transaction_hash])
        receipt = call('eth_getTransactionReceipt', [transaction_hash])
        if (not tx or tx['to'].lower() != ROUTER or tx['input'][:10] != selector
                or tx['blockNumber'] is None or receipt['status'] != '0x1'):
            raise ValueError('Unexpected source transaction')
        decoded = json.loads(subprocess.check_output(
            ['cast', 'calldata-decode', signature, tx['input'], '--json'], text=True))
        payload = decoded[argument]
        parsed = capture.public_price_messages(payload)
        if set(parsed) != set(fixture['feedIds']) or len(payload) != 1:
            raise ValueError('Expected one complete six-feed accumulator')
        fixture['updates'][name] = {
            'updateData': payload,
            'publishTimes': [parsed[feed]['price']['publish_time'] for feed in fixture['feedIds']],
            'previousPublishTimes': [parsed[feed]['metadata']['prev_publish_time'] for feed in fixture['feedIds']],
            'payloadSha256': payload_hash(payload),
            'payloadSource': {
                'transactionHash': tx['hash'], 'transactionBlock': int(tx['blockNumber'], 16),
                'destination': tx['to'], 'selector': selector, 'publicRpc': RPC,
                'description': 'Exact bytes[] from public ' + signature + ' calldata; no Hermes credential used',
            },
        }
    before, after = fixture['updates']['before'], fixture['updates']['after']
    if not (max(before['previousPublishTimes']) < min(before['publishTimes'])
            and max(before['publishTimes']) < EPOCH_START <= min(after['publishTimes'])
            and max(after['publishTimes']) - min(before['publishTimes']) <= 15):
        raise ValueError('Source ticks cannot exercise the epoch boundary within the live window')
    payload = [derive.select_feeds(before['updateData'][0], set(fixture['feedIds'][:1])),
               derive.select_feeds(after['updateData'][0], set(fixture['feedIds'][1:]))]
    parsed = capture.public_price_messages(payload)
    fixture['updates']['mixed'] = {
        'updateData': payload,
        'publishTimes': [parsed[feed]['price']['publish_time'] for feed in fixture['feedIds']],
        'previousPublishTimes': [parsed[feed]['metadata']['prev_publish_time'] for feed in fixture['feedIds']],
        'payloadSha256': payload_hash(payload),
        'payloadSource': {
            'method': 'derive-live-watermark-fixture.py.select_feeds; before feedIds[0], after feedIds[1:6]',
            'description': 'Signed messages, Merkle proofs and guardian-signed roots copied unchanged; only unsigned message counts and selected entries differ',
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(fixture, indent=2) + '\n')
    print('Captured signed pool epoch fixture; replay against real Pyth is still required')


if __name__ == '__main__':
    main()
