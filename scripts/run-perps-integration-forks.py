#!/usr/bin/env python3
"""Run every perps fork lane, require zero skips, and record selection/results.

Requires MAINNET_RPC_URL and ARB_SEPOLIA_RPC_URL. Optional PYTH_API_KEY authenticates
the fresh Hermes fixture fetch; a complete preloaded PYTH_REAL_UPDATE_* fixture is
also accepted. No transaction is broadcast and no spot test is selected.
"""
import json
import os
import datetime
from pathlib import Path
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ROOT_FORKS = (
    'PerpsFork.t.sol', 'OracleSynchronizationFork.t.sol', 'LiveBasketWatermarkFork.t.sol',
    'PerpsAccountAbstractionFork.t.sol', 'PerpsPoolEpochFork.t.sol',
    'PerpsLiquidationFork.t.sol', 'PerpsNativeArbSysFork.t.sol',
)
PYTH_FIELDS = ('PYTH_REAL_UPDATE_DATA', 'PYTH_REAL_UPDATE_PUBLISH_TIME', 'PYTH_REAL_UPDATE_PREV_PUBLISH_TIME')
SELECTION_FIELDS = ('match_test', 'no_match_test', 'match_contract', 'no_match_contract',
                    'match_path', 'no_match_path', 'skip')


def fixture_exports(output):
    result = {}
    for line in output.splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        parts = shlex.split(line)
        if len(parts) != 2 or parts[0] != 'export' or '=' not in parts[1]:
            raise ValueError('Unexpected Pyth fixture output')
        key, value = parts[1].split('=', 1)
        if key not in PYTH_FIELDS or key in result:
            raise ValueError('Unexpected or duplicate Pyth fixture field')
        pattern = r'0x(?:[0-9a-fA-F]{2})+' if key.endswith('_DATA') else r'[0-9]+'
        if re.fullmatch(pattern, value) is None:
            raise ValueError('Invalid Pyth fixture field encoding')
        result[key] = value
    if set(result) != set(PYTH_FIELDS):
        raise ValueError('Incomplete Pyth fixture')
    if not 0 < int(result[PYTH_FIELDS[2]]) < int(result[PYTH_FIELDS[1]]):
        raise ValueError('Pyth fixture must contain a distinct previous tick')
    return result


def require_unfiltered_config(project, env):
    # Checking the resolved config also catches global/local TOML and DAPP_* aliases.
    # Entrypoint checks alone cannot catch an omitted test within a selected file.
    result = subprocess.run(['forge', 'config', '--json', '--root', str(project)],
                            cwd=ROOT, env=env, text=True, capture_output=True)
    if result.returncode:
        raise ValueError('Cannot verify unfiltered Forge configuration')
    try:
        config = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ValueError('Invalid Forge configuration') from error
    filters = [field for field in SELECTION_FIELDS if config.get(field)]
    if filters:
        raise ValueError('Complete fork run requires unfiltered Forge configuration; remove: ' + ', '.join(filters))
    test_root = Path(config.get('test', 'test'))
    if not test_root.is_absolute():
        test_root = project / test_root
    if test_root.resolve() != (project / 'test').resolve():
        raise ValueError('Complete fork run requires the checked-in test directory')


def load_fixture(path):
    value = json.loads(Path(path).read_text())
    if not isinstance(value, dict) or set(value) != set(PYTH_FIELDS) or any(
            not isinstance(item, str) for item in value.values()):
        raise ValueError('Invalid saved Pyth fixture')
    return fixture_exports('\n'.join('export ' + key + '=' + shlex.quote(value[key]) for key in PYTH_FIELDS))


def run(env, output):
    for variable in ('MAINNET_RPC_URL', 'ARB_SEPOLIA_RPC_URL'):
        if not env.get(variable):
            raise ValueError(variable + ' is required; no partial or skipped run')
    for variable in ('SPONSORED_CLOSE_FORK_RPC_URL', 'CLOSE_REGRESSION_ARCHIVE_RPC_URL',
                     'NATIVE_CLOSE_FORK_RPC_URL', 'ARBITRUM_SEPOLIA_RPC_URL'):
        if not env.get(variable):
            env[variable] = env['ARB_SEPOLIA_RPC_URL']
    env.update(PERPS_REQUIRE_NO_SKIPS='1',
               ORACLE_SYNC_FIXTURE='test/fixtures/oracle-sync/arbitrum-sepolia.json',
               ORACLE_SYNC_EXPECT_FIXED='true',
               ORACLE_SYNC_SCENARIO_MANIFEST='test/fixtures/oracle-sync/scenarios.json',
               ORACLE_SYNC_ISOLATION_MODE='transaction')
    env.setdefault('FOUNDRY_PROFILE', 'ci')
    for project in (ROOT, ROOT / 'packages/perps', ROOT / 'packages/perps-aa'):
        require_unfiltered_config(project, env)
    env['PERPS_ARTIFACT_DIR'] = str(output)
    env['PERPS_REPLAY_COMMAND'] = ('PERPS_PYTH_FIXTURE="${replay_dir}/../pyth-fixture.json" '
                                  'python3 scripts/run-perps-integration-forks.py')

    provided = [bool(env.get(key)) for key in PYTH_FIELDS]
    if env.get('PERPS_PYTH_FIXTURE'):
        if any(provided):
            raise ValueError('Choose a saved Pyth fixture or environment payload, not both')
        values = load_fixture(env['PERPS_PYTH_FIXTURE'])
    elif any(provided):
        values = fixture_exports('\n'.join('export ' + key + '=' + shlex.quote(env.get(key, ''))
                                          for key in PYTH_FIELDS))
    else:
        fetched = subprocess.run(['bash', 'scripts/fetch-pyth-real-update-fixture.sh'],
                                 cwd=ROOT, env=env, text=True, capture_output=True)
        if fetched.returncode:
            # HTTP diagnostics can contain credentials. Keep only the exit status.
            raise ValueError('Fresh Pyth fixture fetch failed; exit=' + str(fetched.returncode))
        values = fixture_exports(fetched.stdout)
    env.update(values)
    # Signed payloads and timestamps are public and allow the exact parse to be replayed.
    (output / 'pyth-fixture.json').write_text(json.dumps(values, indent=2) + '\n')

    base = ['forge', 'test', '--offline', '--threads', '4', '-vvv']
    lanes = [
        ('current-perps', ROOT, ['fork/' + name for name in ROOT_FORKS],
         ['--match-path', 'test/fork/*', '--match-contract',
          '^(Perps.*ForkTest|OracleSynchronizationForkTest|LiveBasketWatermarkForkTest)$']),
        ('oracle-isolated', ROOT, ['fork/OracleSynchronizationGasFork.t.sol'],
         ['--isolate', '--match-contract', '^OracleSynchronizationGasForkTest$']),
        ('real-pyth', ROOT, ['fork/PythRealUpdateFork.t.sol'],
         ['--match-contract', '^PythRealUpdateForkTest$']),
        ('paymaster', ROOT / 'packages/perps-aa', ['PletherVerifyingPaymasterFork.t.sol'],
         ['--match-path', 'test/*Fork.t.sol']),
    ]
    package_forks = subprocess.check_output(
        ['python3', 'scripts/perps-test-inventory.py', '--lane', 'fork', '--format', 'paths'],
        cwd=ROOT, text=True).splitlines()
    if not package_forks:
        raise ValueError('No package fork entrypoints discovered')
    for path in package_forks:
        lanes.append(('package-' + Path(path).stem, ROOT / 'packages/perps', [path],
                      ['--match-path', 'test/' + path]))
    for _, project, expected, _ in lanes:
        for path in expected:
            if not (project / 'test' / path).is_file():
                raise ValueError('Required perps fork entrypoint is missing: ' + path)

    results = []
    for name, project, expected, selection in lanes:
        inventory = output / (name + '-entrypoints.txt')
        inventory.write_text('\n'.join(expected) + '\n')
        lane_env = dict(env, PERPS_EXPECTED_ENTRYPOINTS=str(inventory))
        command = base + ['--root', str(project)] + selection
        completed = subprocess.run(['python3', 'scripts/run-perps-recorded.py', name, '--'] + command,
                                   cwd=ROOT, env=lane_env)
        metadata_file = output / name / 'run.json'
        metadata = json.loads(metadata_file.read_text()) if metadata_file.exists() else {}
        results.append({'lane': name, 'exit_code': completed.returncode,
                        'status': metadata.get('status', 'missing'), 'counts': metadata.get('counts', {})})
    counts = {key: sum(row['counts'].get(key, 0) for row in results)
              for key in ('passed', 'failed', 'skipped')}
    failed = any(row['exit_code'] or row['status'] != 'passed' for row in results)
    summary = {'status': 'failed' if failed else 'passed', 'counts': counts, 'lanes': results}
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('Complete perps fork results:', counts, flush=True)
    return int(failed)


def main():
    env = os.environ.copy()
    output = Path(env.get('PERPS_ARTIFACT_DIR', ROOT / 'artifacts/perps/integration-forks')).resolve()
    output.mkdir(parents=True, exist_ok=True)
    summary = output / 'summary.json'
    # Invalidate a previous success before any preflight, RPC or fixture operation.
    # Interrupted/failed setup must never leave an old green summary as current evidence.
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    summary.write_text(json.dumps({'status': 'running', 'started_utc': started}) + '\n')
    try:
        return run(env, output)
    except BaseException as error:
        summary.write_text(json.dumps({'status': 'failed', 'started_utc': started,
                                       'error_type': type(error).__name__}) + '\n')
        raise


if __name__ == '__main__':
    try:
        sys.exit(main())
    except ValueError as error:
        sys.exit(str(error))
