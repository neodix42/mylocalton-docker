#!/usr/bin/env python3
"""Sequential persistent ADNL/TCP submission connection sweep; never provisions a chain."""
import argparse
import copy
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
SERVICES = ('genesis', 'native-load-generator', 'session-stats')
QUANTUM = 16
PROCESS_PROBE = r'''for process in /proc/[0-9]*; do
 executable=$(readlink "$process/exe" 2>/dev/null) || continue
 case "$executable" in */validator-engine|*/validator-engine\ \(deleted\)) ;; *) continue;; esac
 process_stat=$(cat "$process/stat" 2>/dev/null) || continue
 stat_tail=${process_stat##*) }; set -- $stat_tail
 [ "$#" -ge 20 ] || continue; shift 19
 printf '%s\t%s\n' "${process##*/}" "$1"
done'''
PROFILE_COMMAND = ('source benchmark/native-payment-lanes-profile.sh; '
                   'depth=$1; shift; native_payment_lanes_profile_env "$depth" env -u BENCHMARK_EXT_MESSAGES_BROADCAST_DISABLED "$@"')


class EvidenceError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def digest(value):
    return sha(json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode())


def write_json(path, value):
    # Every public report replaces only its own temporary file, never another run.
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n')
    temp.replace(path)


def share(total, index, count):
    return total // count + (index < total % count)


def connection_list(values):
    result = []
    for value in values:
        for token in value.split(','):
            require(re.fullmatch(r'[1-9][0-9]*', token) is not None,
                    'connections must be positive integers separated by spaces or commas')
            result.append(int(token))
    require(result and len(result) == len(set(result)), 'connection counts must be nonempty and unique')
    return result


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--connections', nargs='+', default=['10,50,100'])
    p.add_argument('--env-file', type=Path, default=ROOT / '.env.physical')
    p.add_argument('--output', type=Path)
    p.add_argument('--plan-only', action='store_true', help='validate and print plan without Docker or workload')
    p.add_argument('--global-config', default='/usr/share/data/global.config.json',
                   help='single-local-validator config in the shared /usr/share/data mount')
    for flag, default in [('workers', 6), ('signers', 6), ('sources', 24576),
                          ('initial-cwnd', 32768), ('max-cwnd', 65536), ('inflight', 262144),
                          ('backlog', 2097120), ('source-backlog', 128), ('query-cap', 64),
                          ('batch-size', 64), ('coalesce-ms', 20), ('duration', 180),
                          ('warmup', 60), ('ramp', 0), ('drain', 180)]:
        p.add_argument('--' + flag, type=int, default=default)
    p.add_argument('--target-tps', type=float, default=0)
    p.add_argument('--initial-rtt', type=float, default=0.5)
    p.add_argument('--lane-depth', type=int, choices=[1, 2, 3], default=2)
    p.add_argument('--arm-timeout', type=int, default=0,
                   help='wall-clock watchdog; 0 derives readiness + phases + 10 minute setup/report allowance')
    return p


def validate_options(a):
    a.connections = connection_list(a.connections)
    for name in ['workers', 'signers', 'sources', 'initial_cwnd', 'max_cwnd', 'inflight',
                 'backlog', 'source_backlog', 'query_cap', 'batch_size', 'duration', 'drain']:
        require(0 < getattr(a, name) <= 4294967295, name + ' must be a positive uint32')
    for name in ['warmup', 'ramp', 'coalesce_ms', 'arm_timeout']:
        require(0 <= getattr(a, name) <= 4294967295, name + ' must be a nonnegative uint32')
    require(math.isfinite(a.target_tps) and a.target_tps >= 0, 'target TPS must be finite and nonnegative')
    require(math.isfinite(a.initial_rtt) and a.initial_rtt > 0, 'initial RTT must be positive and finite')
    require(1 < a.batch_size <= 1024, 'native batching requires 2..1024 physical parents per batch')
    require(a.initial_cwnd <= a.max_cwnd <= a.inflight, 'require initial cwnd <= max cwnd <= inflight')
    require(a.source_backlog >= QUANTUM, 'source backlog must admit one whole 16-transfer parent')
    a.effective_workers = min(a.workers, min(a.connections))
    require(a.sources >= a.effective_workers and a.signers >= a.effective_workers,
            'each worker needs at least one disjoint source and signer')
    path = PurePosixPath(a.global_config)
    require(path.is_absolute() and '..' not in path.parts and path.is_relative_to('/usr/share/data')
            and str(path) != '/usr/share/data', 'global config must be under the existing /usr/share/data mount')
    a.global_config = str(path)
    a.env_file = a.env_file.resolve()
    require(a.env_file.is_file(), 'env file does not exist')
    a.arm_timeout = a.arm_timeout or ({1: 360, 2: 900, 3: 1800}[a.lane_depth] + a.ramp + a.warmup +
                                      a.duration + a.drain + 600)
    require(a.arm_timeout >= a.ramp + a.warmup + a.duration + a.drain,
            'arm timeout must allow all configured phases and drain')
    return a


def distribution(a, connections):
    workers, cursor = [], 0
    for w in range(a.effective_workers):
        count = share(connections, w, a.effective_workers)
        totals = {name: share(getattr(a, name), w, a.effective_workers)
                  for name in ['initial_cwnd', 'max_cwnd', 'inflight']}
        clients = []
        for c in range(count):
            limits = {name: share(value, c, count) for name, value in totals.items()}
            require(QUANTUM <= limits['initial_cwnd'] <= limits['max_cwnd'] <= limits['inflight'],
                    f'{connections} connections: worker {w} client {c} cannot preserve whole-run credit limits')
            clients.append(limits)
        source_count = share(a.sources, w, a.effective_workers)
        require(share(a.backlog, w, a.effective_workers) >= QUANTUM,
                'every worker needs one whole parent of canonical backlog')
        workers.append({'worker': w, 'source_offset': cursor, 'sources': source_count,
                        'connections': count, 'signers': share(a.signers, w, a.effective_workers),
                        'clients': clients})
        cursor += source_count
    return workers


def settings(a, count):
    return {key: str(value) for key, value in {
        'BENCHMARK_IMAGES_PREBUILT': 1, 'BENCHMARK_STRICT_IMAGE_REUSE': 1,
        'BENCHMARK_STRICT_GENESIS_REUSE': 1, 'BENCHMARK_RECREATE_GENESIS': 0,
        'TON_BUILD_PULL': 'false', 'COMPOSE_PROFILES': '',
        'NATIVE_LOAD_GLOBAL_CONFIG': a.global_config,
        'NATIVE_LOAD_CONNECTIONS': count, 'NATIVE_LOAD_WORKERS': a.effective_workers,
        'NATIVE_LOAD_SIGNERS': a.signers, 'NATIVE_LOAD_SOURCES': a.sources,
        'NATIVE_LOAD_SOURCE_OFFSET': 0, 'NATIVE_LOAD_INFLIGHT': a.inflight,
        'NATIVE_LOAD_ADAPTIVE_INFLIGHT': 1, 'NATIVE_LOAD_ADAPTIVE_INITIAL_CWND': a.initial_cwnd,
        'NATIVE_LOAD_ADAPTIVE_INITIAL_RTT_SECONDS': a.initial_rtt,
        'NATIVE_LOAD_ADAPTIVE_MAX_CWND': a.max_cwnd,
        'NATIVE_LOAD_NATIVE_TRANSFER_RUNS': 1, 'NATIVE_LOAD_NATIVE_TRANSFER_RUN_SIZE': QUANTUM,
        'NATIVE_LOAD_NATIVE_RUN_BATCHING': 1, 'NATIVE_LOAD_SUBMIT_BATCH_SIZE': a.batch_size,
        'NATIVE_LOAD_SUBMIT_SOURCE_RUN_SIZE': 1, 'NATIVE_LOAD_SUBMIT_COALESCE_MS': a.coalesce_ms,
        'NATIVE_LOAD_SUBMIT_MAX_QUERIES_PER_CLIENT': a.query_cap,
        'NATIVE_LOAD_MAX_CANONICAL_BACKLOG': a.backlog,
        'NATIVE_LOAD_MAX_SOURCE_CANONICAL_BACKLOG': a.source_backlog,
        'NATIVE_LOAD_TARGET_TPS': a.target_tps, 'NATIVE_LOAD_RAMP_SECONDS': a.ramp,
        'NATIVE_LOAD_WARMUP_SECONDS': a.warmup, 'NATIVE_LOAD_DURATION_SECONDS': a.duration,
        'NATIVE_LOAD_DRAIN_TIMEOUT_SECONDS': a.drain,
        'NATIVE_LOAD_AUTO_NONCE': 1, 'NATIVE_LOAD_CANONICAL_BLOCK_FOLLOWER': 1,
    }.items()}


def profile_command(a, env, command):
    return ['bash', '-c', PROFILE_COMMAND, 'native-connections-sweep', str(a.lane_depth),
            *[f'{k}={v}' for k, v in sorted(env.items())], *map(str, command)]


def compose_command(a, env):
    return profile_command(a, env, ['docker', 'compose', '-f', ROOT / 'docker-compose.yaml',
                           '--project-directory', ROOT, '--project-name', 'mylocalton-desktop',
                           '--env-file', a.env_file, '--profile', 'native-load-generator',
                           '--profile', 'session-stats', 'config', '--format', 'json'])


def normalized_config(config):
    services = {name: copy.deepcopy(config['services'][name]) for name in SERVICES}
    services['native-load-generator']['environment'].pop('NATIVE_LOAD_CONNECTIONS', None)
    return {'services': services, 'volumes': config.get('volumes', {}), 'networks': config.get('networks', {})}


def public_process(rows):
    entries = [line.split('\t') for line in rows.splitlines() if line]
    require(len(entries) == 1 and len(entries[0]) == 2 and
            all(re.fullmatch(r'[1-9][0-9]*', v) for v in entries[0]),
            'expected exactly one live validator-engine PID/start-tick identity')
    return dict(zip(('pid', 'start_ticks'), map(int, entries[0])))


def endpoint(config, expected=None):
    servers = config.get('liteservers')
    require(isinstance(servers, list) and len(servers) == 1, 'global config must contain exactly one liteserver')
    server = servers[0]
    require(isinstance(server, dict) and isinstance(server.get('id'), dict) and
            isinstance(server['id'].get('key'), str) and server['id']['key'] and
            type(server.get('ip')) is int and type(server.get('port')) is int and
            0 < server['port'] <= 65535, 'invalid single-liteserver endpoint')
    if expected is not None:
        require(server == expected, 'selected endpoint differs from the prepared local validator endpoint')
    return server


class Host:
    def text(self, command):
        return subprocess.check_output(command, cwd=ROOT, text=True, timeout=45)

    def json(self, command):
        return json.loads(self.text(command))

    def validator(self):
        raw = self.json(['docker', 'inspect', 'genesis'])
        require(isinstance(raw, list) and len(raw) == 1, 'missing genesis container')
        c = raw[0]
        require(c['State']['Running'] is True and c['State'].get('Health', {}).get('Status') == 'healthy',
                'prepare one healthy validator at the requested lane depth before this sweep; no provisioning is performed')
        identity = {'container_id': c['Id'], 'image_id': c['Image'], 'started_at': c['State']['StartedAt'],
                    'restart_count': c['RestartCount'], 'running': True,
                    'validator_process': public_process(self.text(['docker', 'exec', 'genesis', 'sh', '-c', PROCESS_PROBE]))}
        require(all(identity[k] for k in ['container_id', 'image_id', 'started_at']), 'incomplete validator identity')
        resource = {key: c['HostConfig'].get(key) for key in ['NanoCpus', 'CpuQuota', 'CpuPeriod', 'CpusetCpus', 'Memory']}
        resource['mounts'] = sorted([{k: m.get(k) for k in ['Type', 'Name', 'Source', 'Destination', 'RW']}
                                     for m in c['Mounts']], key=lambda m: m['Destination'])
        resource['environment_sha256'] = digest(sorted(c['Config']['Env']))
        resource['command_sha256'] = digest([c['Config'].get('Entrypoint'), c['Config'].get('Cmd')])
        return {'identity': identity, 'resources': resource}

    def images(self, config):
        result = {}
        for name in SERVICES:
            image = config['services'][name].get('image')
            require(isinstance(image, str) and image, f'missing exact service image: {name}')
            rows = self.json(['docker', 'image', 'inspect', image])
            require(len(rows) == 1 and re.fullmatch(r'sha256:[0-9a-f]{64}', rows[0]['Id']), 'missing immutable image ID')
            result[name] = {'reference': image, 'image_id': rows[0]['Id'],
                            'revision': (rows[0]['Config'].get('Labels') or {}).get('org.opencontainers.image.revision')}
        require(result['genesis']['revision'] and
                result['genesis']['revision'] == result['native-load-generator']['revision'],
                'prebuilt validator and generator must have matching source revision labels')
        return result

    def topology(self, a, config, validator):
        # Both services must see the same named volume at this path. Read-only
        # exec in genesis checks public JSON; no generator process is launched.
        def mount(service):
            values = [v for v in config['services'][service].get('volumes', [])
                      if v.get('target') == '/usr/share/data']
            require(len(values) == 1 and values[0].get('type') == 'volume', 'shared data must be one named volume')
            return values[0]['source']
        require(mount('genesis') == mount('native-load-generator'), 'generator and validator config volumes differ')
        live = [m for m in validator['resources']['mounts'] if m['Destination'] == '/usr/share/data']
        volume = config.get('volumes', {}).get(mount('genesis'), {})
        require(len(live) == 1 and volume.get('name') and live[0].get('Name') == volume['name'],
                'running validator config volume differs from requested Compose volume')
        default_bytes = self.text(['docker', 'exec', 'genesis', 'cat', '/usr/share/data/global.config.json'])
        selected_bytes = (default_bytes if a.global_config == '/usr/share/data/global.config.json' else
                          self.text(['docker', 'exec', 'genesis', 'cat', a.global_config]))
        default = endpoint(json.loads(default_bytes))
        selected = endpoint(json.loads(selected_bytes), default)
        return {'config_path': a.global_config, 'config_sha256': sha(selected_bytes.encode()),
                'liteserver_count': 1, 'liteserver': selected,
                'semantics': 'local validator public key; configured connections are submission clients; canonical follower uses additional connections'}


def load_hashed(path):
    raw = path.read_bytes()
    return json.loads(raw), sha(raw)


def assess(summary, a, count, frozen, wrapper_exit):
    errors = []
    def check(value, reason):
        if not value:
            errors.append(reason)
    def section(value, name):
        check(isinstance(value, dict), 'missing_or_malformed_' + name)
        return value if isinstance(value, dict) else {}
    summary = section(summary, 'summary')
    run = section(summary.get('run'), 'run')
    g = section(summary.get('generator'), 'generator')
    f = section(g.get('final'), 'generator_final')
    acceptance = section(summary.get('acceptance'), 'acceptance')
    strict = section(summary.get('strict_image_reuse'), 'strict_image_reuse')
    load = section(summary.get('load_level_acceptance'), 'load_level_acceptance')
    check(wrapper_exit == 0 and run.get('benchmark_exit_code') == 0 and
          run.get('interrupted') is False, 'wrapper_or_generator_failed')
    for field in ['chain_correctness_valid', 'run_complete', 'native_signed_run_quantum_valid',
                  'canonical_lane_balance_valid', 'native_run_batching_valid', 'validator_cleanup_valid']:
        check(acceptance.get(field) is True, field)
    if a.lane_depth == 3:
        # Re-evaluate the concrete eight-lane proof telemetry with the same
        # policy as the wrapper. An old or forged summary may otherwise mark
        # depth 3 as not applicable while claiming a successful capacity arm.
        try:
            result = subprocess.run(
                ['jq', '-c', '-L', str(ROOT / 'benchmark' / 'jq'),
                 'include "native-benchmark-lib"; canonical_lane_balance_acceptance(.)'],
                input=json.dumps(f, allow_nan=False), text=True, capture_output=True, check=True)
            lane_balance = json.loads(result.stdout)
            check(lane_balance.get('canonical_lane_balance_required') is True and
                  lane_balance.get('canonical_lane_balance_valid') is True,
                  'canonical_eight_lane_evidence_invalid')
        except (OSError, subprocess.CalledProcessError, ValueError, TypeError):
            check(False, 'canonical_eight_lane_evidence_unavailable')
    check(acceptance.get('correctness_invalid_reasons') == [] and
          acceptance.get('run_incomplete_reasons') == [], 'correctness_or_completion_reasons')
    check(g.get('valid_canonical_run') is True and f.get('canonical_backlog_after_drain') == 0,
          'canonical_proof_or_drain_incomplete')
    check(strict.get('required') is True and strict.get('valid') is True and
          strict.get('validator_before') == frozen['validator']['identity'] and
          strict.get('validator_after') == frozen['validator']['identity'], 'strict_validator_identity')
    generator_id = frozen['images']['native-load-generator']['image_id']
    check(strict.get('generator_image_before') == generator_id and strict.get('generator_image_after') == generator_id and
          bool(strict.get('generator_container_before')) and
          strict.get('generator_container_before') == strict.get('generator_container_after'), 'strict_generator_identity')
    expected = {'load_mode': 'bounded_unpaced' if a.target_tps == 0 else 'paced',
                'rate_limit_enabled': a.target_tps > 0, 'target_tps_applicable': a.target_tps > 0,
                'configured_connections': count, 'configured_workers': a.effective_workers,
                'configured_signers': a.signers, 'configured_sources': a.sources,
                'adaptive_initial_cwnd': a.initial_cwnd, 'initial_congestion_window': a.initial_cwnd,
                'target_tps': a.target_tps}
    if a.lane_depth == 3:
        expected.update(native_payment_lane_depth=3, canonical_follower_basechain_leaf_shards=8)
    for key, value in expected.items():
        actual = f.get(key)
        valid_type = (type(actual) is bool if isinstance(value, bool) else
                      type(actual) in (int, float) if isinstance(value, (int, float)) else type(actual) is type(value))
        check(valid_type and actual == value, 'effective_' + key)
    rates = {name: f.get(key) for name, key in [('offered_logical_tps', 'steady_offered_avg_tps'),
              ('admitted_logical_tps', 'steady_mempool_accept_avg_tps'),
              ('canonical_logical_tps', 'canonical_chain_measure_avg_tps')]}
    check(all(type(v) in (int, float) and math.isfinite(v) and v > 0 for v in rates.values()), 'missing_or_invalid_rates')
    elapsed = f.get('measure_elapsed_s')
    check(type(elapsed) in (int, float) and elapsed == a.duration, 'measurement_duration')
    for count_key, rate_key in [('steady_offered', 'steady_offered_avg_tps'),
                                ('steady_mempool_accepted', 'steady_mempool_accept_avg_tps')]:
        logical, rate = f.get(count_key), f.get(rate_key)
        check(type(logical) is int and logical >= 0 and type(elapsed) in (int, float) and elapsed > 0 and
              type(rate) in (int, float) and math.isfinite(rate) and
              math.isclose(logical / elapsed, rate, rel_tol=1e-8, abs_tol=1e-6), 'arithmetic_' + count_key)
    runtime = run.get('containers')
    check(isinstance(runtime, list), 'runtime_containers_missing')
    by_name = {}
    if isinstance(runtime, list):
        for container in runtime:
            valid_name = isinstance(container, dict) and isinstance(container.get('name'), str)
            check(valid_name, 'malformed_runtime_container')
            if valid_name:
                check(container['name'] not in by_name, 'duplicate_runtime_container_' + container['name'])
                by_name[container['name']] = container
    for name in SERVICES:
        check(by_name.get(name, {}).get('image_id') == frozen['images'][name]['image_id'], 'runtime_image_' + name)
    entries = by_name.get('native-load-generator', {}).get('benchmark_environment', [])
    actual_env = {}
    if isinstance(entries, list):
        for entry in entries:
            if isinstance(entry, str) and '=' in entry:
                k, v = entry.split('=', 1)
                check(k not in actual_env, 'duplicate_generator_environment_' + k)
                actual_env[k] = v
    for key, value in settings(a, count).items():
        if key.startswith('NATIVE_LOAD_'):
            check(actual_env.get(key) == value, 'runtime_environment_' + key)
    capacity = (not errors and load.get('capacity_claim_allowed') is True and
                load.get('classification') == 'capacity_eligible' and load.get('valid') is True and
                acceptance.get('chain_capacity_valid') is True and acceptance.get('ingress_capacity_valid') is True and
                acceptance.get('chain_capacity_invalid_reasons') == [] and
                rates['offered_logical_tps'] > rates['canonical_logical_tps'])
    return {'connections': count, **rates, 'target_tps': a.target_tps,
            'target_attainment': 'not_applicable' if a.target_tps == 0 else g.get('offer_target_attainment_ratio'),
            'load_mode': expected['load_mode'], 'continue_safe': not errors, 'stop_reasons': errors,
            'capacity_claim_allowed': capacity, 'original_load_level_acceptance': summary.get('load_level_acceptance'),
            'original_acceptance': summary.get('acceptance'),
            'classification': 'capacity_eligible' if capacity else ('observation_only' if not errors else 'rejected'),
            'measured_offered_logical_transfers': f.get('steady_offered'),
            'measured_admitted_logical_transfers': f.get('steady_mempool_accepted'),
            'measure_elapsed_s': elapsed,
            'canonical_backlog_at_measure_end': f.get('canonical_backlog_at_measure_end'),
            'canonical_backlog_sampled_peak': f.get('canonical_backlog_sampled_peak')}


def run_arm(command, log_path, timeout):
    """Forward interruption to the existing wrapper, which stops only its generator."""
    with log_path.open('xb') as log:
        process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        old_handlers = {}
        interrupted = False
        def terminate(signum, frame):
            nonlocal interrupted
            interrupted = True
            # Signal the wrapper, not all collectors; its traps own cleanup.
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
        for sig in [signal.SIGINT, signal.SIGTERM]:
            old_handlers[sig] = signal.signal(sig, terminate)
        deadline = time.monotonic() + timeout
        cleanup_deadline = None
        try:
            while process.poll() is None:
                if (interrupted or time.monotonic() >= deadline) and cleanup_deadline is None:
                    terminate(signal.SIGTERM, None)
                    cleanup_deadline = time.monotonic() + 120
                if cleanup_deadline is not None and time.monotonic() >= cleanup_deadline:
                    # The wrapper normally stops it in its signal trap. Bound a
                    # wedged wrapper as well; no validator/service/volume mutation.
                    try:
                        subprocess.run(['docker', 'stop', '--timeout', '10', 'native-load-generator'],
                                       stdout=log, stderr=log, timeout=30, check=False)
                    finally:
                        if process.poll() is None:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.wait(timeout=10)
                    return 124
                time.sleep(0.5)
            return 130 if interrupted else process.returncode
        finally:
            for sig, handler in old_handlers.items():
                signal.signal(sig, handler)


def plan(a):
    return {'schema': 'native-connections-sweep-plan-v1', 'connection_counts': a.connections,
            'requested_workers': a.workers, 'effective_workers': a.effective_workers,
            'load_mode': 'bounded_unpaced' if a.target_tps == 0 else 'paced',
            'env_file': str(a.env_file), 'env_sha256': sha(a.env_file.read_bytes()),
            'lane_depth': a.lane_depth, 'arm_timeout_seconds': a.arm_timeout,
            'common_environment': {k: v for k, v in settings(a, a.connections[0]).items()
                                   if k != 'NATIVE_LOAD_CONNECTIONS'},
            'arms': [{'connections': count, 'distribution': distribution(a, count),
                      'environment': settings(a, count)} for count in a.connections],
            'limitations': ['Sequential ascending sweep, not a randomized or statistically significant comparison.',
                'Same local validator and liteserver; loopback/container networking does not establish remote-client capacity.',
                'Query credits are per submission connection and therefore their aggregate limit grows with connection count.',
                'All windows/backlogs are logical transfers; batches count intact physical signed parents (normally 16 transfers each).',
                'Cache/database age and chain history advance between arms; canonical follower connections are additional.',
                'Admission is a pending acknowledgment; capacity claims require every unchanged existing acceptance gate.']}


def execute(a, host=None):
    host = host or Host()
    result = plan(a)
    if a.plan_only:
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    output = (a.output or ROOT / 'benchmark-results' /
              ('connections-' + dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ'))).resolve()
    require(not output.exists(), 'output directory already exists; use a new path')
    output.mkdir(parents=True)
    write_json(output / 'plan.json', result)
    report = {'schema': 'native-connections-sweep-result-v1', 'plan_sha256': sha((output / 'plan.json').read_bytes()),
              'complete': False, 'arms': [], 'capacity_winner_connections': None,
              'limitations': result['limitations']}
    try:
        configs = [host.json(compose_command(a, settings(a, count))) for count in a.connections]
        reference_config = normalized_config(configs[0])
        require(all(normalized_config(c) == reference_config for c in configs),
                'resolved service settings differ beyond submission connection count')
        frozen = {'validator': host.validator(), 'images': host.images(configs[0]),
                  'normalized_compose_sha256': digest(reference_config),
                  'compose_sha256_by_connections': {str(n): digest(c) for n, c in zip(a.connections, configs)}}
        require(frozen['validator']['identity']['image_id'] == frozen['images']['genesis']['image_id'],
                'live validator does not use the exact prebuilt genesis service image')
        frozen['topology'] = host.topology(a, configs[0], frozen['validator'])
        frozen['harness_files'] = {str(p.relative_to(ROOT)): sha(p.read_bytes()) for p in [
            Path(__file__).resolve(), ROOT / 'run-native-benchmark.sh', ROOT / 'docker-compose.yaml',
            ROOT / 'benchmark/native-payment-lanes-profile.sh', ROOT / 'benchmark/jq/native-benchmark-lib.jq',
            ROOT / 'native-load-generator/entrypoint.sh', ROOT / 'native-load-generator/payment-lanes.sh']}
        write_json(output / 'frozen-preflight.json', frozen)
        report['preflight_sha256'] = sha((output / 'frozen-preflight.json').read_bytes())
        for index, count in enumerate(a.connections):
            require(sha(a.env_file.read_bytes()) == result['env_sha256'], 'env file changed during sweep')
            for path, expected_hash in frozen['harness_files'].items():
                require(sha((ROOT / path).read_bytes()) == expected_hash, 'harness source changed during sweep: ' + path)
            current = host.json(compose_command(a, settings(a, count)))
            require(digest(current) == frozen['compose_sha256_by_connections'][str(count)], 'effective Compose config changed')
            require(host.validator() == frozen['validator'], 'validator process/resources changed between arms')
            require(host.images(current) == frozen['images'], 'prebuilt service image identity changed')
            require(host.topology(a, current, frozen['validator']) == frozen['topology'], 'endpoint/config changed')
            bundle = output / f'{index + 1:02d}-{count}-connections'
            command = profile_command(a, settings(a, count), [ROOT / 'run-native-benchmark.sh', a.env_file, bundle])
            write_json(output / f'{index + 1:02d}-launch.json', {'command': command, 'connections': count,
                       'started_at': dt.datetime.now(dt.timezone.utc).isoformat()})
            print(f'Starting {count} persistent submission connections; raw bundle: {bundle}', flush=True)
            status = run_arm(command, output / f'{index + 1:02d}-wrapper.log', a.arm_timeout)
            # Bind saved figures to the exact completed summary bytes before interpretation.
            summary, summary_hash = load_hashed(bundle / 'benchmark-summary.json')
            arm = assess(summary, a, count, frozen, status)
            arm.update({'raw_bundle': str(bundle), 'summary_sha256': summary_hash, 'wrapper_exit': status,
                        'launch_sha256': sha((output / f'{index + 1:02d}-launch.json').read_bytes())})
            report['arms'].append(arm)
            # Save rejected evidence before any following probe can fail.
            write_json(output / 'sweep-summary.json', report)
            require(host.validator() == frozen['validator'], 'validator process/resources changed during arm')
            require(host.images(current) == frozen['images'], 'prebuilt image changed during arm')
            require(host.topology(a, current, frozen['validator']) == frozen['topology'], 'endpoint changed during arm')
            print(f"{count}: admitted={arm['admitted_logical_tps']} canonical={arm['canonical_logical_tps']} "
                  f"logical TPS; {arm['classification']}", flush=True)
            require(arm['continue_safe'], 'arm failed mandatory continuity/correctness/cleanup gates: ' + ', '.join(arm['stop_reasons']))
        report['complete'] = True
        eligible = [r for r in report['arms'] if r['capacity_claim_allowed']]
        if eligible:
            report['capacity_winner_connections'] = max(eligible, key=lambda r: r['canonical_logical_tps'])['connections']
        report['winner_semantics'] = 'highest observed capacity-eligible arm in this sweep; no repeatability or significance claim'
        write_json(output / 'sweep-summary.json', report)
        print(f'Saved sweep: {output / "sweep-summary.json"}', flush=True)
        return 0
    except (EvidenceError, OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError) as exc:
        report['error'] = str(exc)
        # No winner can survive a broken sweep identity or incomplete audit.
        report['capacity_winner_connections'] = None
        report['complete'] = False
        write_json(output / 'sweep-summary.json', report)
        print(f'Sweep stopped; evidence preserved in {output}: {exc}', file=sys.stderr)
        return 3


def main(argv=None):
    try:
        return execute(validate_options(parser().parse_args(argv)))
    except (EvidenceError, OSError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
