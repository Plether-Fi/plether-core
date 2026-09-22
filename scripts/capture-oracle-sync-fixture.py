#!/usr/bin/env python3
"""Capture signed six-feed history and pinned, untouched Pyth storage. Never broadcasts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.parse
import urllib.request

PYTH = '0x0B73614636C855Bf23F342F307FB981A3e47f42B'
FEEDS = [
    '0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b',
    '0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52',
    '0x84c2dde9633d93d1bcad84e7dc41c9d56578b7ec52fabedc1f335d673df0a7c1',
    '0x3112b03a41c910ed446852aacf67118cb1bec67b2cd0b9a214c58cc0eaa2ecca',
    '0x8ccb376aa871517e807358d4e3cf0bc7fe4950474dbe6c9ffc21ef64e43fc676',
    '0x0b1e3297e69f162877b577b0d6a47a0d63b2392bc8499e6540da4187a63e28f8',
]


def request(url, body=None, headers=None):
    req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(),
                                 headers={'Content-Type': 'application/json', 'User-Agent': 'plether-release-validation/1.0', **(headers or {})})
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)


def public_price_messages(payload):
    """Read timestamps from exact accumulator bytes; the real Pyth fork verifies their signatures.

    Format: pyth-crosschain/target_chains/ethereum/contracts/contracts/pyth/PythAccumulator.sol,
    parsePriceFeedMessage and extractAndValidateEncodedMessage. No payload bytes are rewritten.
    """
    parsed = {}
    for value in payload:
        data = bytes.fromhex(value.removeprefix('0x'))
        if data[:4] != b'PNAU' or data[4] != 1:
            raise ValueError('Unsupported accumulator format')
        offset = 7 + data[6]
        if data[offset] != 0:
            raise ValueError('Unsupported accumulator proof type')
        offset += 1
        proof_size = int.from_bytes(data[offset:offset+2], 'big')
        offset += 2 + proof_size
        count = data[offset]
        offset += 1
        for _ in range(count):
            size = int.from_bytes(data[offset:offset+2], 'big')
            offset += 2
            message = data[offset:offset+size]
            offset += size
            if len(message) != 85 or message[0] != 0:
                raise ValueError('Unsupported price message')
            feed = '0x' + message[1:33].hex()
            if feed in parsed:
                raise ValueError('Ambiguous duplicate feed in captured payload')
            parsed[feed] = dict(price={'publish_time': int.from_bytes(message[53:61], 'big')},
                                metadata={'prev_publish_time': int.from_bytes(message[61:69], 'big')})
            proof_count = data[offset]
            offset += 1 + 20 * proof_count
        if offset != len(data):
            raise ValueError('Malformed accumulator bounds')
    return parsed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--baseline', required=True, help='Immutable pre-change core commit')
    parser.add_argument('--source-transaction', help='Public updateMarkPrice(bytes[]) transaction; bypasses Hermes entirely')
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Refusing to overwrite a fixture')
    baseline = subprocess.check_output(['git', 'rev-parse', args.baseline + '^{commit}'], text=True).strip()
    rpc = os.environ['ARB_SEPOLIA_RPC_URL']

    def call(method, params):
        response = request(rpc, {'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params})
        if 'error' in response:
            raise ValueError('RPC rejected ' + method)
        return response['result']

    if int(call('eth_chainId', []), 16) != 421614:
        raise ValueError('Wrong chain')
    provenance = None
    if args.source_transaction:
        tx = call('eth_getTransactionByHash', [args.source_transaction])
        selector = subprocess.check_output(['cast', 'sig', 'updateMarkPrice(bytes[])'], text=True).strip()
        if not tx or tx['input'][:10] != selector or tx['blockNumber'] is None:
            raise ValueError('Expected a mined updateMarkPrice(bytes[]) transaction')
        payload = json.loads(subprocess.check_output(
            ['cast', 'calldata-decode', 'updateMarkPrice(bytes[])', tx['input'], '--json'], text=True))[0]
        parsed = public_price_messages(payload)
        upper = int(tx['blockNumber'], 16) - 1
        provenance = dict(transactionHash=tx['hash'], transactionBlock=int(tx['blockNumber'], 16),
                          destination=tx['to'], selector=selector,
                          description='Exact bytes[] from public updateMarkPrice calldata; no Hermes credential used')
    else:
        upper = int(call('eth_blockNumber', []), 16)
        endpoint = os.environ.get('HERMES_BASE_URL', 'https://pyth.dourolabs.app/hermes/v2/updates/price/latest')
        # Never forward an API key to an arbitrary endpoint supplied by a fixture or environment override.
        if urllib.parse.urlparse(endpoint).hostname != 'pyth.dourolabs.app' or not endpoint.startswith('https://pyth.dourolabs.app/hermes/'):
            raise ValueError('Use the configured HTTPS Pyth Hermes endpoint')
        headers = {'Authorization': 'Bearer ' + os.environ['PYTH_API_KEY']} if os.environ.get('PYTH_API_KEY') else {}
        query = urllib.parse.urlencode([('ids[]', f[2:]) for f in FEEDS] + [('encoding', 'hex'), ('parsed', 'true')])
        response = request(endpoint + '?' + query, headers=headers)
        parsed = {'0x' + f['id'].removeprefix('0x'): f for f in response['parsed']}
        payload = ['0x' + value.removeprefix('0x') for value in response['binary']['data']]
    times = [int(parsed[f]['price']['publish_time']) for f in FEEDS]
    previous = [int(parsed[f]['metadata']['prev_publish_time']) for f in FEEDS]
    commit = min(times) - 1
    execution = max(times) + 1
    if not all(prev <= commit < tick for prev, tick in zip(previous, times)):
        raise ValueError('No shared unique-tick commit window; capture another fixture')
    if execution - commit > 15 or max(times) - min(times) > 5:
        raise ValueError('Fixture violates release settlement/divergence bounds')
    if not payload:
        raise ValueError('Missing signed bytes')

    # Preserve chronology: pick untouched chain state no later than the simulated order commit.
    def block_at(number):
        return call('eth_getBlockByNumber', [hex(number), False])
    lower = max(0, upper - 256)
    while lower > 0 and int(block_at(lower)['timestamp'], 16) > commit:
        lower = max(0, lower - 256)
        if upper - lower > 65536:
            raise ValueError('No recent pre-commit fork block; do not qualify frozen/old data')
    while lower < upper:
        middle = (lower + upper + 1) // 2
        if int(block_at(middle)['timestamp'], 16) <= commit:
            lower = middle
        else:
            upper = middle - 1
    block = block_at(lower)
    if int(block['timestamp'], 16) > commit or call('eth_getCode', [PYTH, block['number']]) == '0x':
        raise ValueError('Invalid fork chronology or missing supported Pyth deployment')
    selector = subprocess.check_output(['cast', 'sig', 'getPriceUnsafe(bytes32)'], text=True).strip()
    stored = []
    for feed in FEEDS:
        result = call('eth_call', [{'to': PYTH, 'data': selector + feed[2:]}, block['number']])
        if len(result) != 2 + 4 * 64:
            raise ValueError('Malformed Pyth price response')
        stored.append(int(result[-64:], 16))
    if min(stored) >= min(times) or execution - min(stored) > 60:
        raise ValueError('Storage must reproduce ordering failure while remaining eligible for a live read')
    fixture = dict(schemaVersion=1, baselineSourceCommit=baseline, chainId=421614, pyth=PYTH,
                   forkBlockNumber=int(block['number'], 16), forkBlockHash=block['hash'],
                   forkTimestamp=int(block['timestamp'], 16), feedIds=FEEDS,
                   quantities=[576*10**15,136*10**15,119*10**15,91*10**15,42*10**15,36*10**15],
                   basePrices=[117500000,638000,134480000,72880000,10860000,126100000],
                   inversions=[False,True,False,True,True,True], initialStoredPublishTimes=stored,
                   publishTimes=times, previousPublishTimes=previous, commitTimestamp=commit,
                   executionTimestamp=execution, executionBlock=int(block['number'],16)+1, updateData=payload,
                   payloadSha256=hashlib.sha256(json.dumps(payload,separators=(',',':')).encode()).hexdigest())
    if provenance is not None:
        fixture['payloadSource'] = provenance
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(fixture, indent=2) + '\n')
    print(f'Captured fixture at block {fixture["forkBlockNumber"]}; real-Pyth validation still required')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # HTTP/RPC exceptions may embed credential-bearing URLs. Do not print their messages.
        print('Fixture capture failed: ' + type(error).__name__ + '; no release gate passed', file=sys.stderr)
        sys.exit(1)
