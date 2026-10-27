#!/usr/bin/env python3
"""Select unchanged signed feed proofs from the committed Hermes accumulator batches.

The accumulator envelope's unsigned message count changes; each signed price message,
Merkle proof and guardian-signed root is copied verbatim. The real Pyth fork verifies
all signatures and proofs when this fixture is replayed. No credentials or RPC needed.
"""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'test/fixtures/oracle-sync/live-watermark-sep22.json'
OUTPUT = ROOT / 'test/fixtures/oracle-sync/live-watermark-uneven.json'


def select_feeds(value, wanted):
    data = bytes.fromhex(value.removeprefix('0x'))
    if data[:4] != b'PNAU' or data[4] != 1:
        raise ValueError('Unsupported accumulator version')
    offset = 7 + data[6]
    if data[offset] != 0:
        raise ValueError('Unsupported proof type')
    offset += 1
    proof_size = int.from_bytes(data[offset:offset + 2], 'big')
    offset += 2 + proof_size
    header = data[:offset]
    count = data[offset]
    offset += 1
    selected = []
    found = set()
    for _ in range(count):
        start = offset
        size = int.from_bytes(data[offset:offset + 2], 'big')
        offset += 2
        message = data[offset:offset + size]
        offset += size
        if len(message) != 85 or message[0] != 0:
            raise ValueError('Unsupported price message')
        feed = '0x' + message[1:33].hex()
        proof_count = data[offset]
        offset += 1 + 20 * proof_count
        if feed in wanted:
            if feed in found:
                raise ValueError('Duplicate selected feed')
            found.add(feed)
            selected.append(data[start:offset])
    if offset != len(data) or found != wanted:
        raise ValueError('Malformed bounds or missing selected feed')
    return '0x' + (header + bytes([len(selected)]) + b''.join(selected)).hex()


def main():
    source = json.loads(SOURCE.read_text())
    ids = source['feedIds']
    result = {key: value for key, value in source.items()
              if key not in ('source', 'capturedAt', 'updates')}
    result['source'] = {
        'file': str(SOURCE.relative_to(ROOT)),
        'sha256': hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        'method': 'Subset selection; signed messages, Merkle proofs and guardian-signed roots unchanged',
    }
    result['updates'] = {}
    for name, original, selected in [('lagging', 'initial', ids[1:]),
                                     ('fast', 'next', ids[:1]),
                                     ('caughtUp', 'skipped', ids[1:])]:
        batch = source['updates'][original]
        if len(batch['updateData']) != 1:
            raise ValueError('Expected one source accumulator per batch')
        payload = select_feeds(batch['updateData'][0], set(selected))
        result['updates'][name] = {
            'sourceBatch': original,
            'feedIds': selected,
            'publishTimes': [batch['publishTimes'][ids.index(feed)] for feed in selected],
            'updateData': [payload],
            'payloadSha256': hashlib.sha256(bytes.fromhex(payload[2:])).hexdigest(),
        }
    OUTPUT.write_text(json.dumps(result, indent=2) + '\n')
    print(OUTPUT.relative_to(ROOT))


if __name__ == '__main__':
    main()
