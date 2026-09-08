#!/usr/bin/env python3
"""Read-only server-A sampler. Never builds, restarts, or changes a validator."""
import argparse
import datetime
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import urllib.parse
import urllib.request

KEYS = ('total.ext_msg_batch_admission', 'total.ext_msg_batch_diagnostics',
        'total.native_signature_executor')
ENV_KEYS = {'TON_NATIVE_ADMISSION_CONFIG_CACHE', 'TON_NATIVE_EXECUTOR_THREADS',
            'TON_NATIVE_VALIDATION_SIGNATURE_THREADS',
            'TON_NATIVE_COLLATOR_QUEUE_LIMIT', 'TON_SIMPLEX_MAX_TPS', 'SIMPLEX_TARGET_RATE_MS',
            'TON_SIMPLEX_MAX_TPS_CANDIDATE_TIMEOUT_MS', 'TON_SIMPLEX_MAX_TPS_FINALIZE_RESERVE_MS',
            'TON_NATIVE_CHECKPOINT_RETAIN_INGRESS', 'NATIVE_PAYMENT_LANE_DEPTH',
            'ACTUAL_MIN_SPLIT', 'MIN_SPLIT', 'MAX_SPLIT', 'CUSTOM_PARAMETERS'}
CONTROL = '''
config=/var/ton-work/db/config.json
internal_ip=$(hostname -I); internal_ip=${internal_ip%% *}
control_port=$(jq -r '.control[0].port // empty' "$config")
test -n "$internal_ip" && test -n "$control_port" || exit 2
exec timeout --signal=TERM --kill-after=1s 10s validator-engine-console \
  -k /var/ton-work/db/client -p /var/ton-work/db/server.pub \
  -a "$internal_ip:$control_port" -c getstats
'''


def command(args, timeout=15):
    return subprocess.run(args, text=True, capture_output=True, timeout=timeout, check=True).stdout


def save(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')


def parse_stats(text):
    result = {}
    for line in text.splitlines():
        fields = line.split(None, 1)
        if len(fields) != 2 or fields[0] not in KEYS:
            continue
        if fields[0] in result:
            raise ValueError('duplicate statistics key')
        values = {}
        for item in fields[1].split():
            name, sep, value = item.partition(':')
            if not sep or name in values:
                raise ValueError('invalid or duplicate counter')
            number = int(value) if re.fullmatch(r'[0-9]+', value) else float(value)
            if not math.isfinite(number) or number < 0:
                raise ValueError('invalid counter value')
            values[name] = number
        result[fields[0]] = values
    return result


def deltas(before, after):
    """Compare counters, never subtract lifetime maxima or current gauges."""
    changes, errors = {}, []
    for group in KEYS:
        if group not in before or group not in after:
            errors.append('missing:' + group)
            continue
        values = {}
        for key, old in before[group].items():
            if key in ('active_batches', 'config_cache_enabled') or 'peak' in key or 'max_' in key or key.endswith('_max_s'):
                continue
            # Only documented admission/executor counters, not sequence numbers
            # or gauges in the broader pool-admission statistics key.
            if group == KEYS[0] and key not in ('batches', 'messages', 'accepted', 'rejected'):
                continue
            new = after[group].get(key)
            if new is None or new < old:
                errors.append('counter_reset_or_missing:' + group + '.' + key)
            else:
                values[key] = new - old
        changes[group] = values
    return changes, errors


def summarize(samples):
    usable = [x for x in samples if x.get('stats')]
    result = {'schema': 'native-validator-profile-v1', 'samples': len(samples),
              'statistics_samples': len(usable), 'diagnostics_available': False,
              'errors': [e for x in samples for e in x.get('errors', [])],
              'semantics': 'Observation only. Match timestamps to B measurement; startup/drain may be included. '
                           'Stage wall times overlap. Maxima are lifetime values. Executor counters are concurrent snapshots. '
                           'Thread CPU excludes vanished threads; network counters cover the network namespace.'}
    if len(usable) < 2:
        result['errors'].append('fewer_than_two_statistics_samples')
        return result
    changes, errors = deltas(usable[0]['stats'], usable[-1]['stats'])
    result.update(start_unix_s=usable[0]['stats_started_unix_s'],
                  end_unix_s=usable[-1]['stats_finished_unix_s'], counter_deltas=changes)
    result['errors'].extend(errors)
    diagnostic = changes.get(KEYS[1], {})
    result['diagnostics_available'] = all(k in usable[0]['stats'] and k in usable[-1]['stats'] for k in KEYS)
    result['stage_mean_ms'] = {k[:-8]: diagnostic.get(k[:-8] + '_sum_s', 0) * 1000 / n
                               for k, n in diagnostic.items() if k.endswith('_samples') and n > 0}
    hits, misses = diagnostic.get('config_cache_hits', 0), diagnostic.get('config_cache_misses', 0)
    result['config_cache_hit_fraction'] = hits / (hits + misses) if hits + misses else None
    not_ready = diagnostic.get('not_ready_total', 0)
    result['snapshot_changed_fraction_of_not_ready'] = (
        diagnostic.get('not_ready_snapshot_changed', 0) / not_ready if not_ready else None)
    admissions = changes.get(KEYS[0], {})
    completed = admissions.get('accepted', 0) + admissions.get('rejected', 0)
    result['snapshot_changed_fraction_of_completed_inputs'] = (
        diagnostic.get('not_ready_snapshot_changed', 0) / completed if completed else None)
    if errors:
        # A reset/partial schema must never appear to be a valid attribution.
        result['stage_mean_ms'] = {}
        result['config_cache_hit_fraction'] = None
        result['snapshot_changed_fraction_of_not_ready'] = None
        result['snapshot_changed_fraction_of_completed_inputs'] = None
    return result


def thread_intervals(samples, hz):
    result = []
    for old, new in zip(samples, samples[1:]):
        if 'resources' not in old or 'resources' not in new:
            continue
        elapsed = new['observed_unix_s'] - old['observed_unix_s']
        if elapsed <= 0:
            continue
        rows = []
        for tid, current in new['resources']['threads'].items():
            previous = old['resources']['threads'].get(tid)
            if not previous or previous['start_ticks'] != current['start_ticks']:
                continue
            cpu = current['cpu_ticks'] - previous['cpu_ticks']
            wait = current['schedstat'][1] - previous['schedstat'][1]
            if cpu < 0 or wait < 0:
                continue
            rows.append({'tid': tid, 'comm': current['comm'], 'cpu_cores': cpu / hz / elapsed,
                         'runqueue_wait_s': wait / 1e9})
        result.append({'start_unix_s': old['observed_unix_s'], 'end_unix_s': new['observed_unix_s'],
                       'sampled_cpu_cores': sum(x['cpu_cores'] for x in rows),
                       'sampled_runqueue_wait_s': sum(x['runqueue_wait_s'] for x in rows),
                       'top_threads': sorted(rows, key=lambda x: x['cpu_cores'], reverse=True)[:20]})
    return result


def capture_dashboard(base, start, end, output):
    groups = {
        'canonical': ('rate', ['BLOCK_APPLIED_native_transfers', 'BLOCK_APPLIED_transactions', 'BLOCK_APPLIED_blocks']),
        'packing': ('avg', ['BLOCK_native_transfers', 'BLOCK_size', 'BLOCK_native_bytes_per_transfer']),
        'collation': ('avg', ['BLOCK_collate_work_time_real_' + x for x in
                              ('native_execute', 'native_commit', 'state_merkle_update')]),
        'validation': ('avg', ['BLOCK_validate_work_time_real_' + x for x in
                               ('native_signature_verify', 'native_state_replay', 'native_account_load',
                                'native_account_materialize', 'native_state_dictionary_check', 'state_merkle_update')])}
    errors = []
    for name, (mode, stats) in groups.items():
        query = urllib.parse.urlencode({'wc': 0, 'stats': ','.join(stats), 'mode': mode, 'window_size': 60,
            'start': datetime.datetime.fromtimestamp(start, datetime.timezone.utc).isoformat(),
            'end': datetime.datetime.fromtimestamp(end, datetime.timezone.utc).isoformat()})
        try:
            with urllib.request.urlopen(base.rstrip('/') + '/api/stats?' + query, timeout=5) as response:
                data = json.load(response)
            save(output / ('dashboard-' + name + '.json'), data)
        except (OSError, ValueError) as exc:
            errors.append(name + ':' + type(exc).__name__)
    return errors


def identity(container):
    records = json.loads(command(['docker', 'inspect', container]))
    if len(records) != 1 or not records[0]['State']['Running']:
        raise ValueError('expected one running validator container')
    c = records[0]
    return {'container_id': c['Id'], 'image_id': c['Image'], 'started_at': c['State']['StartedAt'],
            'restart_count': c['RestartCount'], 'init_pid': c['State']['Pid'],
            'limits': {k: c['HostConfig'].get(k) for k in ('NanoCpus', 'CpuQuota', 'CpuPeriod', 'CpusetCpus', 'Memory')},
            'environment': {k: v for entry in c['Config'].get('Env', [])
                            for k, sep, v in [entry.partition('=')] if sep and k in ENV_KEYS}}


def engine_pid(container):
    found = []
    for line in command(['docker', 'top', container, '-eo', 'pid,comm']).splitlines()[1:]:
        fields = line.split()
        if fields and fields[0].isdigit():
            pid = int(fields[0])
            try:
                if Path(os.readlink(f'/proc/{pid}/exe')).name == 'validator-engine':
                    found.append(pid)
            except OSError:
                pass
    if len(found) != 1:
        raise ValueError('cannot identify one host validator-engine PID; run sampler with host /proc access')
    return found[0]


def proc_stat(path):
    text = path.read_text()
    # comm may contain spaces and parentheses; numeric fields follow its last ).
    fields = text[text.rfind(')') + 2:].split()
    return {'cpu_ticks': int(fields[11]) + int(fields[12]), 'start_ticks': int(fields[19]),
            'state': fields[0], 'comm': text[text.find('(')+1:text.rfind(')')]}


def resources(pid):
    root = Path('/proc') / str(pid)
    result = {'process': proc_stat(root / 'stat'), 'threads': {}, 'errors': []}
    for task in (root / 'task').iterdir():
        try:
            record = proc_stat(task / 'stat')
            record['schedstat'] = [int(x) for x in (task / 'schedstat').read_text().split()]
            result['threads'][task.name] = record
        except (OSError, ValueError):
            result['errors'].append('thread_disappeared_or_unreadable:' + task.name)
    for name in ('io', 'status', 'net/dev'):
        try:
            result[name] = (root / name).read_text()
        except OSError:
            result['errors'].append('unreadable:' + name)
    try:
        cgroup = next(line[3:] for line in (root / 'cgroup').read_text().splitlines() if line.startswith('0::'))
        base = Path('/sys/fs/cgroup') / cgroup.lstrip('/')
        for name in ('cpu.stat', 'cpu.pressure', 'memory.current', 'memory.pressure', 'io.pressure'):
            try:
                result[name] = (base / name).read_text()
            except OSError:
                result['errors'].append('unreadable_cgroup:' + name)
    except (OSError, StopIteration):
        result['errors'].append('cgroup_v2_unavailable')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', default='genesis')
    parser.add_argument('--duration', type=int, default=1200)
    parser.add_argument('--interval', type=int, default=30)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--dashboard-url', default='', help='optional Session Stats URL, e.g. http://127.0.0.1:18000')
    a = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', a.container) or not 1 <= a.duration <= 86400 or not 15 <= a.interval <= 600:
        parser.error('invalid container, duration (1..86400), or interval (15..600)')
    if a.dashboard_url:
        url = urllib.parse.urlsplit(a.dashboard_url)
        if url.scheme not in ('http', 'https') or not url.netloc or url.username or url.password:
            parser.error('dashboard URL must be HTTP(S) without credentials')
    # /proc sampling is valid only for a local Docker daemon, never an SSH/TCP context.
    context = json.loads(command(['docker', 'context', 'inspect']))
    endpoints = [context[0]['Endpoints']['docker']['Host']]
    if os.environ.get('DOCKER_HOST'):
        endpoints.append(os.environ['DOCKER_HOST'])
    if any(not x.startswith('unix://') for x in endpoints):
        parser.error('local Unix-socket Docker context required for host /proc sampling')
    os.umask(0o077)
    output = a.output or Path('validator-profiles') / datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    output.mkdir(parents=True, exist_ok=False)
    samples = []
    stopped = False
    def stop(*_):
        nonlocal stopped
        stopped = True
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    initial = identity(a.container)
    pid = engine_pid(a.container)
    start_ticks = proc_stat(Path(f'/proc/{pid}/stat'))['start_ticks']
    save(output / 'identity.json', dict(initial, engine_pid=pid, engine_start_ticks=start_ticks,
                                       cpu_tick_hz=os.sysconf('SC_CLK_TCK'), interval_s=a.interval))
    started = time.monotonic()
    try:
        while not stopped:
            row = {'observed_unix_s': time.time(), 'errors': []}
            if identity(a.container) != initial or proc_stat(Path(f'/proc/{pid}/stat'))['start_ticks'] != start_ticks:
                raise ValueError('validator identity/configuration changed during profiling')
            row['resources'] = resources(pid)
            row['stats_started_unix_s'] = time.time()
            try:
                raw = command(['docker', 'exec', a.container, 'sh', '-c', CONTROL])
                (output / f'stats-{len(samples):04}.txt').write_text(raw)
                row['stats'] = parse_stats(raw)
                if not row['stats']:
                    row['errors'].append('no_recognized_statistics')
            except (subprocess.SubprocessError, OSError, ValueError) as exc:
                row['errors'].append('statistics_query_failed:' + type(exc).__name__)
            row['stats_finished_unix_s'] = time.time()
            samples.append(row)
            with (output / 'samples.jsonl').open('a') as f:
                f.write(json.dumps(row, allow_nan=False) + '\n')
            print(json.dumps({'event': 'validator_profile', 'samples': len(samples),
                              'elapsed_s': round(time.monotonic()-started), 'errors': row['errors']}), flush=True)
            if time.monotonic() - started >= a.duration:
                break
            next_sample = min(started + a.duration, time.monotonic() + a.interval)
            while not stopped and time.monotonic() < next_sample:
                time.sleep(min(1, max(0, next_sample - time.monotonic())))
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        samples.append({'errors': [str(exc)]})
    finally:
        summary = summarize(samples)
        summary['thread_cpu_intervals'] = thread_intervals(samples, os.sysconf('SC_CLK_TCK'))
        summary['interrupted'] = stopped
        if a.dashboard_url and samples and 'observed_unix_s' in samples[0]:
            summary['dashboard_errors'] = capture_dashboard(a.dashboard_url, samples[0]['observed_unix_s'], time.time(), output)
        save(output / 'summary.json', summary)
        print('Profile saved: ' + str(output), flush=True)
    return 0 if summary['diagnostics_available'] and not summary['errors'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
