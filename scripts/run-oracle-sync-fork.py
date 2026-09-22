#!/usr/bin/env python3
"""Run one signed fixture against the recorded baseline and candidate; never broadcasts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixture', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if not args.fixture.is_file():
        parser.error('Signed fixture is required; real-Pyth release gate remains blocked')
    fixture = json.loads(args.fixture.read_text())
    digest = hashlib.sha256(json.dumps(fixture['updateData'], separators=(',', ':')).encode()).hexdigest()
    if digest != fixture['payloadSha256']:
        parser.error('Signed payload checksum mismatch')
    if len(fixture['feedIds']) != 6 or len(set(fixture['feedIds'])) != 6 or fixture['chainId'] != 421614:
        parser.error('Expected six distinct Arbitrum Sepolia feeds')
    baseline = subprocess.check_output(['git', 'rev-parse', fixture['baselineSourceCommit'] + '^{commit}'], cwd=root, text=True).strip()
    if baseline != fixture['baselineSourceCommit']:
        parser.error('Baseline must be an immutable full commit')
    if not os.environ.get('ARB_SEPOLIA_RPC_URL'):
        parser.error('ARB_SEPOLIA_RPC_URL is required; no skip fallback')
    if subprocess.check_output(['git', 'status', '--porcelain'], cwd=root, text=True).strip():
        parser.error('Commit the candidate and signed fixture before replay; dirty source cannot qualify a release')
    candidate_commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    if args.output.exists():
        parser.error('Evidence output already exists')
    args.output.mkdir(parents=True)
    results = {}
    with tempfile.TemporaryDirectory(prefix='oracle-sync-baseline-') as directory:
        old = Path(directory)
        archive = old / 'source.tar'
        with archive.open('wb') as target:
            subprocess.run(['git', 'archive', baseline], cwd=root, stdout=target, check=True)
        with tarfile.open(archive) as source:
            source.extractall(old, filter='data')
        for name in ['forge-std', 'openzeppelin-contracts', 'morpho-blue']:
            destination = old / 'lib' / name
            if destination.exists():
                destination.rmdir()
            destination.symlink_to(root / 'lib' / name, target_is_directory=True)
        test = Path('test/fork/OracleSynchronizationFork.t.sol')
        shutil.copy(root / test, old / test)
        config = old / 'foundry.toml'
        config.write_text(config.read_text().replace('path = "script/bytecode/" }]', 'path = "script/bytecode/" }, { access = "read", path = "test/fixtures/" }]'))
        for name, checkout, fixed in [('baseline', old, False), ('candidate', root, True)]:
            local_fixture = checkout / 'test/fixtures/oracle-sync/run.json'
            local_fixture.parent.mkdir(parents=True, exist_ok=True)
            if local_fixture.exists():
                parser.error('Reserved run.json fixture already exists')
            local_fixture.write_text(json.dumps(fixture))
            try:
                env = dict(os.environ, FOUNDRY_PROFILE='ci', FOUNDRY_VIA_IR='true',
                           ORACLE_SYNC_FIXTURE=str(local_fixture), ORACLE_SYNC_EXPECT_FIXED=str(fixed).lower())
                command = ['forge', 'test', '--offline', '--match-path', str(test), '--match-test', 'test_RealPythBaselineVersusAtomicSynchronization', '-vv']
                result = subprocess.run(command, cwd=checkout, env=env, capture_output=True, text=True)
                output = result.stdout + result.stderr
                for key in ['ARB_SEPOLIA_RPC_URL', 'PYTH_API_KEY']:
                    if env.get(key): output = output.replace(env[key], '[REDACTED]')
                (args.output / (name + '.log')).write_text(output)
                passed = result.returncode == 0 and '[PASS] test_RealPythBaselineVersusAtomicSynchronization' in output and '0 skipped' in output
                values = {}
                for line in output.splitlines():
                    for field in ['historical fill', 'neutral mark']:
                        if line.strip().startswith(field + ':'):
                            values[field] = line.strip().split(':', 1)[1].strip()
                results[name] = dict(passed=passed, prices=values)
            finally:
                local_fixture.unlink()
        passed = all(r['passed'] for r in results.values()) and bool(results['baseline']['prices']) and results['baseline']['prices'] == results['candidate']['prices']
        dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=root, text=True).strip())
        current_commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
        passed = passed and not dirty and current_commit == candidate_commit
        report = dict(passed=passed, baselineSourceCommit=baseline, candidateSourceCommit=None if dirty else candidate_commit,
                      candidateHasUncommittedChanges=dirty, payloadSha256=digest, forkBlockHash=fixture['forkBlockHash'], results=results)
        (args.output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        if not passed:
            raise SystemExit('Fork regression failed; see sanitized evidence logs')
        print('Baseline reproduced ordering failure; candidate synchronized all feeds with identical historical prices')


if __name__ == '__main__':
    main()
