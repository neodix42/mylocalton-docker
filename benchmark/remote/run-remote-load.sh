#!/usr/bin/env bash
# Standalone generator-only runner for an installed native remote-client bundle.
set -Eeuo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: run-remote-load.sh [--connections 10 50 100] [--directory CLIENT_ROOT]
       [--duration SECONDS] [--warmup SECONDS] [--drain SECONDS]
       [--profile server48|preset] [--source-policy reuse|isolated]
       [--cpus COUNT] [--memory LIMIT]
       [--workers COUNT] [--signers COUNT]
       [--initial-cwnd LOGICAL_TRANSFERS] [--max-cwnd LOGICAL_TRANSFERS]
       [--submit-coalesce-ms 1..100]
       [--output NEW_DIRECTORY] [--image LOCAL_IMAGE]

CLIENT_ROOT defaults to this script's directory. It must contain remote-load.env,
client-data/global.config.json and client-data/wallets. The inspected local image
is fixed across every arm; this script never pulls/builds images or starts a
validator. Linux host networking is required. Exited workload containers and all
artifacts are retained. The default measurement lasts at least 600 seconds,
in addition to warmup/readiness/drain; --duration explicitly permits shorter runs.
Progress is printed every 30 seconds. Capacity-only rejections are reported and do not abort;
An invalid arm keeps a failing result. Sources are reused only after exact final
proof/cohort reconciliation; otherwise the default reuse policy stops the sweep.
Optional isolated policy gives every setup an equal, disjoint source partition
and can continue after an exited failed arm. Later arms are observation-only
if an earlier partition remains unresolved; old traffic may still reach the chain.

The default server48 profile uses 40 CPUs/48g, ten workers and 32 signers on
a dedicated 48-CPU server B, including older imported presets. Small source
exports cap workers/signers to the source count. --profile preset retains the
imported worker/signer values and uses the earlier 4 CPUs/8g resource defaults.
Explicit CPU/memory/worker/signer/window overrides always win; remote-load.env
remains unchanged. Both profiles preserve the preset admission/backlog limits.
The updated native binary supports 1..1024 connections. Counts above 256 require
a generator image containing that native change; updating this script alone is
insufficient. The container gets a 65,536-descriptor open-file limit.
Windows count logical transfers globally and are shared across workers/clients;
more connections do not increase that budget. Explicit window values must be
positive, fit the existing inflight limit, and permit complete signed runs.

The default connection setup is 10 only. Keep credits fixed until measurement
shows a binding limit; --connections explicitly enables a sweep.

Examples (server48 is the default; select preset for smaller client hosts):
  bash run-remote-load.sh --connections 50 100 --duration 600
  bash run-remote-load.sh --connections 50 100 --duration 600 \
    --initial-cwnd 65536 --max-cwnd 131072
  # Historical six-worker control, including with a newly exported preset:
  bash run-remote-load.sh --profile preset --workers 6 --signers 6
  # Each connection count must cover all effective workers.
EOF
}
fail() { printf 'remote-load: %s\n' "$*" >&2; exit 2; }
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
directory=$script_dir
output=
image_override=
duration_override=
warmup_override=
drain_override=
workers_override=
signers_override=
initial_cwnd_override=
max_cwnd_override=
coalesce_override=
profile=server48
source_policy=reuse
cpus=
memory=
connections=(10)
connections_seen=0
declare -A options_seen=()
while (($#)); do
  option=$1
  shift
  case "$option" in
    --help|-h) usage; exit 0 ;;
    --connections)
      ((connections_seen == 0)) || fail 'duplicate --connections'
      connections_seen=1
      connections=()
      while (($#)) && [[ $1 != --* ]]; do connections+=("$1"); shift; done
      ((${#connections[@]})) || fail '--connections requires at least one count'
      ;;
    --directory|--duration|--warmup|--drain|--profile|--source-policy|--cpus|--memory|--output|--image|--workers|--signers|--initial-cwnd|--max-cwnd|--submit-coalesce-ms)
      [[ ! ${options_seen[$option]+yes} ]] || fail "duplicate $option"
      options_seen[$option]=1
      (($#)) && [[ $1 != --* && -n $1 ]] || fail "$option requires a value"
      case "$option" in
        --directory) directory=$1 ;; --duration) duration_override=$1 ;;
        --warmup) warmup_override=$1 ;; --drain) drain_override=$1 ;;
        --profile) profile=$1 ;; --source-policy) source_policy=$1 ;;
        --cpus) cpus=$1 ;; --memory) memory=$1 ;;
        --output) output=$1 ;; --image) image_override=$1 ;;
        --workers) workers_override=$1 ;; --signers) signers_override=$1 ;;
        --initial-cwnd) initial_cwnd_override=$1 ;; --max-cwnd) max_cwnd_override=$1 ;;
        --submit-coalesce-ms) coalesce_override=$1 ;;
      esac
      shift
      ;;
    *) fail "unknown argument: $option" ;;
  esac
done
case "$profile" in
  server48) cpus=${cpus:-40}; memory=${memory:-48g} ;;
  preset) cpus=${cpus:-4}; memory=${memory:-8g} ;;
  *) fail '--profile must be server48 or preset' ;;
esac
[[ $source_policy == reuse || $source_policy == isolated ]] || fail '--source-policy must be reuse or isolated'
[[ $(uname -s) == Linux ]] || fail 'Linux is required for --network host'
for command in docker python3 flock timeout; do command -v "$command" >/dev/null || fail "missing command: $command"; done
[[ -d $directory ]] || fail "client directory does not exist: $directory"
directory=$(cd -- "$directory" && pwd -P)
[[ -d $directory/client-data ]] || fail 'client-data directory is missing'
client_data=$(cd -- "$directory/client-data" && pwd -P)
# The lock follows the actual mounted data directory, including directory aliases.
exec 9>"$client_data/.remote-load.lock"
flock -n 9 || fail 'another remote run holds this client-data lock'
if [[ -z $output ]]; then output="$directory/remote-results/$(date -u +%Y%m%dT%H%M%SZ)-$$"; fi
[[ ! -e $output ]] || fail "output already exists: $output"
mkdir -p -- "$(dirname -- "$output")"
mkdir -- "$output"
output=$(cd -- "$output" && pwd -P)
active_container=
active_arm=
wait_pid=
interrupt_reason=

# One embedded standard-library helper keeps the installed runner self-contained.
helper() {
  python3 - "$@" <<'PY'
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
import time


def check(condition, message):
    if not condition:
        raise ValueError(message)


def pairs(items):
    result = {}
    for key, value in items:
        check(key not in result, 'duplicate JSON field: ' + key)
        result[key] = value
    return result


def finite(value):
    if isinstance(value, float):
        check(math.isfinite(value), 'nonfinite JSON value')
    elif isinstance(value, dict):
        for item in value.values(): finite(item)
    elif isinstance(value, list):
        for item in value: finite(item)
    return value


def read(path):
    return finite(json.loads(Path(path).read_text(), object_pairs_hook=pairs))


def save(path, value):
    Path(path).write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')


def uint(text, name, minimum=0, maximum=2**32-1):
    check(isinstance(text, str) and re.fullmatch(r'0|[1-9][0-9]*', text), name + ' must be an unsigned decimal integer')
    value = int(text)
    check(minimum <= value <= maximum, name + ' is out of range')
    return value


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024*1024), b''): h.update(chunk)
    return h.hexdigest()


def environment(path):
    result = {}
    for line in Path(path).read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'): continue
        key, separator, value = line.partition('=')
        check(separator and re.fullmatch(r'[A-Z][A-Z0-9_]*', key), 'invalid env-file assignment')
        check(key not in result, 'duplicate env-file key: ' + key)
        check(key.startswith('NATIVE_LOAD_') or key.startswith('NATIVE_PAYMENT_') or key == 'REMOTE_LOAD_IMAGE',
              'unexpected env-file key: ' + key)
        check('\x00' not in value and value == value.strip(), 'invalid env-file value for ' + key)
        result[key] = value
    return result


def write_env(path, env):
    Path(path).write_text(''.join(k + '=' + v + '\n' for k, v in sorted(env.items()) if k != 'REMOTE_LOAD_IMAGE'))


mode = sys.argv[1]
try:
    if mode == 'prepare':
        directory, data, output, duration, warmup, drain, cpus, memory, image_arg = sys.argv[2:11]
        directory, data, output = Path(directory), Path(data), Path(output)
        env = environment(directory / 'remote-load.env')
        profile, source_policy = sys.argv[12:14]
        check(source_policy in ('reuse', 'isolated'), 'invalid source policy')
        counts = [uint(x, 'connections', 1, 1024) for x in sys.argv[19:]]
        check(counts and len(counts) == len(set(counts)), 'empty or duplicate connection count')
        exported_sources = uint(env.get('NATIVE_LOAD_SOURCES', ''), 'NATIVE_LOAD_SOURCES', 1, 1000000)
        exported_offset = uint(env.get('NATIVE_LOAD_SOURCE_OFFSET', '0'), 'NATIVE_LOAD_SOURCE_OFFSET')
        check(exported_offset + exported_sources <= 2**32-1, 'source interval overflows supported uint32 range')
        partition_sources = exported_sources
        if source_policy == 'isolated':
            lanes = 1 << uint(env.get('NATIVE_LOAD_PAYMENT_LANE_DEPTH', ''), 'payment lane depth', 1, 3)
            partition_sources = exported_sources // len(counts) // lanes * lanes
            check(partition_sources >= lanes, 'isolated policy needs at least one complete lane set per setup')
            env['NATIVE_LOAD_SOURCES'] = str(partition_sources)
        source_partitions = [{'source_offset': exported_offset + (i * partition_sources if source_policy == 'isolated' else 0),
                              'sources': partition_sources} for i in range(len(counts))]
        check(profile in ('server48', 'preset'), 'invalid resource profile')
        if profile == 'server48':
            # The profile is a visible treatment, recorded per arm. Upgrading the
            # host runner upgrades old bundles without rewriting keys/pinned images
            # or silently inheriting their six-worker small-host signing budget.
            available_sources = uint(env.get('NATIVE_LOAD_SOURCES', ''), 'NATIVE_LOAD_SOURCES', 1, 1000000)
            env['NATIVE_LOAD_WORKERS'] = str(min(10, available_sources))
            env['NATIVE_LOAD_SIGNERS'] = str(min(32, available_sources))
        for key, value in zip(['NATIVE_LOAD_WORKERS', 'NATIVE_LOAD_SIGNERS',
                               'NATIVE_LOAD_ADAPTIVE_INITIAL_CWND', 'NATIVE_LOAD_ADAPTIVE_MAX_CWND'],
                              sys.argv[14:18]):
            if value:
                uint(value, key + ' override', 1, 256 if key in ('NATIVE_LOAD_WORKERS', 'NATIVE_LOAD_SIGNERS') else 2**32-1)
                env[key] = value
        if sys.argv[18]:
            env['NATIVE_LOAD_SUBMIT_COALESCE_MS'] = str(uint(sys.argv[18], 'submit coalesce ms', 1, 100))
        coalesce_ms = uint(env.get('NATIVE_LOAD_SUBMIT_COALESCE_MS', '20'), 'submit coalesce ms', 1, 100)
        env['NATIVE_LOAD_SUBMIT_COALESCE_MS'] = str(coalesce_ms)
        if not duration:
            # Upgrade previously exported 180-second presets without requiring keys
            # or the pinned image to be exported/imported again. Explicit CLI
            # durations retain their exact meaning, including short smoke tests.
            duration = str(max(600, uint(env.get('NATIVE_LOAD_DURATION_SECONDS', '600'), 'duration', 1, 86400)))
        for key, value in [('NATIVE_LOAD_DURATION_SECONDS', duration), ('NATIVE_LOAD_WARMUP_SECONDS', warmup),
                           ('NATIVE_LOAD_DRAIN_TIMEOUT_SECONDS', drain)]:
            if value: env[key] = value
        workers = uint(env.get('NATIVE_LOAD_WORKERS', ''), 'NATIVE_LOAD_WORKERS', 1, 256)
        sources = uint(env.get('NATIVE_LOAD_SOURCES', ''), 'NATIVE_LOAD_SOURCES', workers, 1000000)
        signers = uint(env.get('NATIVE_LOAD_SIGNERS', ''), 'NATIVE_LOAD_SIGNERS', workers, min(sources, 256))
        offset = uint(env.get('NATIVE_LOAD_SOURCE_OFFSET', '0'), 'NATIVE_LOAD_SOURCE_OFFSET')
        check(offset + sources <= 2**32-1, 'source interval overflows supported uint32 range')
        runner_path = Path(sys.argv[11])
        check(min(counts) >= workers, 'connections is out of range for effective workers')
        duration = uint(env.get('NATIVE_LOAD_DURATION_SECONDS', ''), 'duration', 1, 86400)
        warmup = uint(env.get('NATIVE_LOAD_WARMUP_SECONDS', '0'), 'warmup', 0, 86400)
        ramp = uint(env.get('NATIVE_LOAD_RAMP_SECONDS', '0'), 'ramp', 0, 86400)
        drain = uint(env.get('NATIVE_LOAD_DRAIN_TIMEOUT_SECONDS', ''), 'drain', 1, 86400)
        check(re.fullmatch(r'(?:[0-9]+)(?:\.[0-9]+)?', cpus) and 0 < float(cpus) <= 256, 'invalid CPU limit')
        check(re.fullmatch(r'[1-9][0-9]*(?:[bBkKmMgG])?', memory), 'invalid memory limit')
        for key in ['NATIVE_LOAD_AUTO_NONCE', 'NATIVE_LOAD_CANONICAL_BLOCK_FOLLOWER',
                    'NATIVE_LOAD_NATIVE_TRANSFER_RUNS', 'NATIVE_PAYMENT_LANES_ENABLED']:
            check(env.get(key) == '1', key + '=1 is required for this native proof-checked runner')
        quantum = uint(env.get('NATIVE_LOAD_NATIVE_TRANSFER_RUN_SIZE', ''), 'signed run size', 1, 16)
        depth = uint(env.get('NATIVE_LOAD_PAYMENT_LANE_DEPTH', ''), 'payment lane depth', 1, 3)
        check(env.get('NATIVE_PAYMENT_LANE_DEPTH') == str(depth), 'payment lane depth mismatch')
        for key in ['NATIVE_LOAD_INFLIGHT', 'NATIVE_LOAD_MAX_CANONICAL_BACKLOG', 'NATIVE_LOAD_MAX_SOURCE_CANONICAL_BACKLOG']:
            uint(env.get(key, ''), key, 1)
        inflight = uint(env['NATIVE_LOAD_INFLIGHT'], 'NATIVE_LOAD_INFLIGHT', max(workers, max(counts)))
        uint(env['NATIVE_LOAD_MAX_CANONICAL_BACKLOG'], 'NATIVE_LOAD_MAX_CANONICAL_BACKLOG', workers)
        initial_cwnd = uint(env.get('NATIVE_LOAD_ADAPTIVE_INITIAL_CWND', '0'), 'initial cwnd')
        max_cwnd = uint(env.get('NATIVE_LOAD_ADAPTIVE_MAX_CWND', '0'), 'max cwnd')
        check(initial_cwnd == 0 or env.get('NATIVE_LOAD_ADAPTIVE_INFLIGHT') == '1',
              'positive initial cwnd requires NATIVE_LOAD_ADAPTIVE_INFLIGHT=1')
        check(max_cwnd == 0 or max(counts) <= max_cwnd <= inflight,
              'max cwnd must be zero or between every connection count and inflight')
        check(initial_cwnd <= (max_cwnd or inflight) <= inflight,
              'initial cwnd must not exceed max cwnd or inflight')
        # Match the native coordinator/worker's two-stage distribution; a global
        # initial >= connections * quantum alone misses uneven worker fanout.
        def share(total, index, count):
            return total // count + (index < total % count)
        if initial_cwnd:
            for count in counts:
                for worker in range(workers):
                    clients = share(count, worker, workers)
                    initial_share = share(initial_cwnd, worker, workers)
                    hard_share = share(inflight, worker, workers)
                    cap_share = share(max_cwnd or inflight, worker, workers)
                    for client in range(clients):
                        initial = share(initial_share, client, clients)
                        check(quantum <= initial <= min(share(hard_share, client, clients),
                                                         share(cap_share, client, clients)),
                              'initial cwnd cannot fit a complete signed run within each distributed client ceiling '
                              + '(connections=' + str(count) + ', workers=' + str(workers) + ')')
        check(env.get('NATIVE_LOAD_NATIVE_RUN_BATCHING', '0') in ('0', '1'), 'invalid batching flag')
        expected_paths = {'NATIVE_LOAD_GLOBAL_CONFIG': '/client/global.config.json',
                          'NATIVE_LOAD_WALLET_DIR': '/client/wallets',
                          'NATIVE_LOAD_PAYMENT_LANE_MANIFEST': '/client/wallets/native-payment-lanes.manifest'}
        for key, value in expected_paths.items():
            check(env.get(key, value) == value, key + ' must use the installed /client mount')
            env[key] = value
        config_path = data / 'global.config.json'
        config = read(config_path)
        servers = config.get('liteservers')
        check(isinstance(servers, list) and len(servers) == 1, 'global config must contain exactly one liteserver')
        server = servers[0]
        check(type(server.get('ip')) is int and -(2**31) <= server['ip'] < 2**31, 'liteserver IP must be signed int32')
        check(type(server.get('port')) is int and 1 <= server['port'] <= 65535, 'invalid liteserver port')
        check(server.get('id', {}).get('@type') == 'pub.ed25519'
              and len(base64.b64decode(server['id']['key'], validate=True)) == 32, 'invalid liteserver public key')
        zero = config.get('validator', {}).get('zero_state', {})
        for field in ('root_hash', 'file_hash'):
            check(len(base64.b64decode(zero.get(field, ''), validate=True)) == 32, 'invalid zerostate ' + field)
        wallet_dir = data / 'wallets'
        manifest = wallet_dir / 'native-payment-lanes.manifest'
        check(manifest.is_file() and not manifest.is_symlink() and manifest.stat().st_size > 0, 'lane manifest missing/empty')
        if source_policy == 'isolated':
            lines = manifest.read_text().splitlines()
            header = lines[0].split() if lines else []
            check(len(header) == 4 and header[:3] == ['NATIVE_PAYMENT_LANES_MANIFEST_V1', str(depth), str(1 << depth)],
                  'isolated source manifest header/depth mismatch')
            check(uint(header[3], 'manifest sources', 1) >= exported_offset + exported_sources,
                  'manifest does not cover exported sources')
            selected_lanes = {}
            for line in lines[1:]:
                if not line.strip() or line.lstrip().startswith('#'): continue
                fields = line.split()
                check(len(fields) == 4, 'malformed source manifest row')
                index = uint(fields[0], 'manifest source index')
                if not exported_offset <= index < exported_offset + exported_sources: continue
                check(index not in selected_lanes, 'duplicate selected manifest source')
                lane = uint(fields[1], 'manifest lane', 0, (1 << depth)-1)
                check(lane == index % (1 << depth), 'manifest sources are not in balanced lane order')
                selected_lanes[index] = lane
            check(len(selected_lanes) == exported_sources, 'manifest is missing an exported source')
            for partition in source_partitions:
                observed = [0] * (1 << depth)
                for index in range(partition['source_offset'], partition['source_offset'] + partition['sources']):
                    observed[selected_lanes[index]] += 1
                check(len(set(observed)) == 1, 'source partition is not balanced across lanes')
        for index in range(exported_offset, exported_offset + exported_sources):
            for label, suffix, size in [('source', 'pk', 32), ('source', 'pub', 32), ('source', 'addr', None),
                                         ('dest', 'pub', 32), ('dest', 'addr', None)]:
                path = wallet_dir / (label + '-' + str(index) + '.' + suffix)
                check(path.is_file() and not path.is_symlink() and path.stat().st_size > 0,
                      'missing/empty selected wallet file: ' + path.name)
                if size: check(path.stat().st_size == size, 'wrong selected wallet file size: ' + path.name)
        image = image_arg
        if not image and (directory / 'runtime-image-id.txt').is_file(): image = (directory / 'runtime-image-id.txt').read_text().strip()
        if not image: image = env.get('REMOTE_LOAD_IMAGE', '')
        if not image and (directory / 'export-manifest.json').is_file(): image = read(directory / 'export-manifest.json').get('image', {}).get('id', '')
        check(isinstance(image, str) and image and '\n' not in image and '\x00' not in image and not image.startswith('-'), 'local image reference is missing/invalid')
        watchdog = duration + warmup + ramp + drain + uint(env.get('NATIVE_LOAD_PAYMENT_LANE_READY_TIMEOUT_SECONDS', '900'), 'ready timeout', 1, 86400) + 600
        settings = {'schema': 'native-remote-run-v1', 'client_directory': str(directory), 'client_data': str(data),
                    'profile': profile, 'source_policy': source_policy, 'source_partitions': source_partitions,
                    'exported_sources': exported_sources, 'exported_source_offset': exported_offset,
                    'nofile_limit': 65536, 'connections': counts, 'workers': workers, 'signers': signers, 'sources': sources, 'source_offset': offset,
                    'lane_depth': depth, 'quantum': quantum, 'cpus': cpus, 'memory': memory, 'duration': duration,
                    'warmup': warmup, 'ramp': ramp, 'drain': drain, 'watchdog_seconds': watchdog,
                    'initial_cwnd': initial_cwnd, 'max_cwnd': max_cwnd, 'inflight': inflight, 'submit_coalesce_ms': coalesce_ms, 'submit_coalesce_override': bool(sys.argv[18]),
                    'requested_image': image, 'environment': env, 'config_sha256': digest(config_path),
                    'wallet_manifest_sha256': digest(manifest), 'runner_sha256': digest(runner_path),
                    'runner_path': str(runner_path), 'created_unix_s': time.time(),
                    'semantics': 'Only generator containers run here. Remote validator cleanup/resources and strict validator-process identity are not independently observed.'}
        (output / 'run-remote-load.sh').write_bytes(runner_path.read_bytes())
        save(output / 'settings.json', settings)
        write_env(output / 'runtime.env', env)
        (output / 'remote-load.env').write_bytes((directory / 'remote-load.env').read_bytes())
        (output / 'global.config.json').write_bytes(config_path.read_bytes())
        (output / 'image-reference.txt').write_text(image + '\n')
        print(watchdog)
    elif mode == 'image':
        output = Path(sys.argv[2]); records = read(output / 'image-inspect.json')
        check(isinstance(records, list) and len(records) == 1, 'ambiguous image metadata')
        image = records[0]
        image_id = image.get('Id', '')
        check(re.fullmatch(r'sha256:[0-9a-f]{64}', image_id), 'image inspect did not return an immutable ID')
        check(image.get('Os') == 'linux', 'generator image must be Linux')
        requested = (output / 'image-reference.txt').read_text().strip()
        if requested.startswith('sha256:'): check(image_id == requested, 'inspected image differs from requested immutable ID')
        (output / 'image-id.txt').write_text(image_id + '\n')
        print(image_id)
    elif mode == 'capability':
        output = Path(sys.argv[2]); image_id = sys.argv[3]
        status = int(sys.argv[4]); settings = read(output / 'settings.json')
        help_path = output / 'native-load-generator-help.txt'
        help_text = help_path.read_text(errors='replace')
        advertised = re.findall(r'^\s*(?:-[A-Za-z0-9],\s*)?--connections(?:<[^>\n]+>)?\s+[^\n]*\(1\.\.([1-9][0-9]*)\)',
                               help_text, re.MULTILINE)
        maximum = int(advertised[0]) if len(advertised) == 1 else None
        requested = max(settings['connections'])
        supported = status == 0 and maximum is not None and maximum >= requested
        capability = {'schema': 'native-remote-connection-capability-v1', 'image_id': image_id,
                      'requested_max_connections': requested, 'advertised_max_connections': maximum,
                      'probe_exit_code': status, 'supported': supported, 'help_sha256': digest(help_path),
                      'entrypoint': '/usr/local/bin/native-load-generator', 'network': 'none',
                      'wallets_mounted': False}
        save(output / 'connection-capability.json', capability)
        check(supported, 'frozen generator image does not advertise support for ' + str(requested)
              + ' connections (advertised maximum=' + str(maximum) + ', help exit=' + str(status)
              + '). Install the updated native generator image before this sweep; no load setup was started.')
    elif mode == 'arm':
        output, arm, connections, image_id, name = sys.argv[2:7]
        settings = read(Path(output) / 'settings.json')
        partition = settings['source_partitions'][settings['connections'].index(int(connections))]
        settings.update(partition)
        settings['environment']['NATIVE_LOAD_SOURCES'] = str(partition['sources'])
        settings['environment']['NATIVE_LOAD_SOURCE_OFFSET'] = str(partition['source_offset'])
        settings['prior_unresolved_arms'] = [str(path.parent.name) for path in sorted(Path(output).glob('*-connections/summary.json'))
                                             if read(path).get('source_reuse_safe') is not True]
        settings['connections'] = int(connections)
        settings['image_id'] = image_id; settings['container_name'] = name
        settings['environment']['NATIVE_LOAD_CONNECTIONS'] = connections
        save(Path(arm) / 'runtime-settings.json', settings)
        write_env(Path(arm) / 'runtime.env', settings['environment'])
    elif mode == 'progress':
        arm = Path(sys.argv[2]); elapsed = int(sys.argv[3])
        settings = read(arm / 'runtime-settings.json')
        row = None
        for line in (arm / 'progress-tail.log').read_text(errors='replace').splitlines():
            if not line.lstrip().startswith('{'): continue
            try:
                value = finite(json.loads(line, object_pairs_hook=pairs))
                if isinstance(value, dict) and ('phase' in value or 'offered_tps' in value): row = value
            except (ValueError, TypeError):
                pass
        sample = {'event': 'progress', 'connections': settings['connections'], 'wall_elapsed_s': elapsed,
                  'measurement_target_s': settings['duration'], 'phase': 'waiting_for_generator_report',
                  'provisional': True, 'observed_unix_s': time.time(),
                  'load_settings': {key: settings[key] for key in
                      ['profile', 'workers', 'signers', 'initial_cwnd', 'max_cwnd', 'inflight', 'cpus', 'memory']}}
        if row is not None:
            for key in ['phase', 'elapsed_s', 'measure_elapsed_s', 'offered_tps', 'mempool_accept_tps',
                        'canonical_chain_measure_transfers', 'canonical_gen_utime_bucket_duration_s',
                        'canonical_backlog', 'canonical_follower_errors', 'steady_offered_avg_tps',
                        'steady_mempool_accept_avg_tps', 'congestion_window', 'congestion_window_sampled_peak',
                        'cwnd_cap_limited_acks', 'clients_at_query_cap', 'query_credit_stalls',
                        'rtt_ms', 'wire_batch_avg_size', 'not_ready_by_reason',
                        'native_signed_run_issue_holds', 'sources_at_canonical_backlog_cap',
                        'measure_canonical_backpressure_fraction']:
                if key in row: sample[key] = row[key]
            if 'canonical_chain_measure_avg_tps' in row:
                # The native field divides by the entire planned block-time
                # measurement window even while only its first seconds exist.
                # Label that denominator honestly; it is not a live TPS ramp.
                sample['canonical_chain_measure_planned_window_avg_tps'] = row['canonical_chain_measure_avg_tps']
        with (arm / 'progress.jsonl').open('a') as handle:
            handle.write(json.dumps(sample, allow_nan=False) + '\n')
        print(json.dumps(sample, allow_nan=False))
    elif mode == 'announce':
        settings = read(Path(sys.argv[2]) / 'settings.json')
        print('Each setup: measurement={duration}s, warmup={warmup}s, ramp={ramp}s, drain limit={drain}s; '
              'profile={profile}, source policy={source_policy}, sources/setup={sources}; generator budget={cpus} CPUs/{memory}, workers={workers}, signers={signers}; '
              'global logical windows: initial={initial_cwnd}, max={max_cwnd}, inflight={inflight}; '
              'coalesce={submit_coalesce_ms}ms; watchdog={watchdog_seconds}s (includes readiness).'.format(**settings))
    elif mode == 'owns':
        arm = Path(sys.argv[2]); settings = read(arm / 'runtime-settings.json')
        inspected = read(arm / 'ownership-inspect.json')
        check(isinstance(inspected, list) and len(inspected) == 1, 'missing ownership inspection')
        check(inspected[0].get('Config', {}).get('Labels', {}).get('io.ton.native-remote-owner') == settings['container_name'], 'container ownership label mismatch')
    elif mode == 'summarize':
        arm = Path(sys.argv[2]); forced = sys.argv[3]
        summary = {'schema': 'native-remote-arm-summary-v1', 'valid_run': False, 'invalid_reasons': [],
                   'capacity_classification': 'invalid', 'remote_validator_cleanup_valid': None,
                   'remote_validator_process_identity_valid': None, 'remote_validator_resources': None,
                   'semantics': 'Generator proof/completion gates are checked locally. Remote validator pool cleanup, process identity and resources require a separate server-A observer; they are not inferred.'}
        errors = summary['invalid_reasons']
        try:
            settings = read(arm / 'runtime-settings.json'); summary['connections'] = settings['connections']
            summary['image_id'] = settings['image_id']
            summary['source_partition'] = {key: settings[key] for key in ['source_policy', 'source_offset', 'sources']}
            summary['prior_unresolved_arms'] = settings.get('prior_unresolved_arms', [])
            summary['load_settings'] = {key: settings[key] for key in
                ['profile', 'workers', 'signers', 'initial_cwnd', 'max_cwnd', 'inflight', 'cpus', 'memory']}
            if forced: errors.append(forced)
            inspected = read(arm / 'container.json')
            check(isinstance(inspected, list) and len(inspected) == 1, 'missing/ambiguous container inspection')
            container = inspected[0]; state = container.get('State', {})
            wait_status_path = arm / 'wait-status.txt'
            execution = {key: state.get(key) for key in ['Status', 'Running', 'ExitCode', 'OOMKilled', 'Error', 'StartedAt', 'FinishedAt']}
            execution['RestartCount'] = container.get('RestartCount')
            execution['docker_wait_status'] = int(wait_status_path.read_text().strip()) if wait_status_path.is_file() else None
            execution['docker_wait_output'] = (arm / 'wait.log').read_text(errors='replace').strip() if (arm / 'wait.log').is_file() else None
            execution['watchdog_expired'] = None if forced == 'docker_wait_or_watchdog_killed_exit_137' else forced.startswith('watchdog_expired_')
            execution['runner_failure'] = forced or None
            summary['execution'] = execution
            save(arm / 'execution.json', execution)
            # Preserve the generator's own diagnosis even on exit 2 (incomplete),
            # exit 3 (correctness), OOM, signal, or an interrupted docker wait.
            rows = []
            parse_error = None
            for line in (arm / 'generator.log').read_text(errors='replace').splitlines():
                if line.lstrip().startswith('{'):
                    try:
                        row = finite(json.loads(line, object_pairs_hook=pairs))
                        if isinstance(row, dict) and row.get('final') is True: rows.append(row)
                    except (ValueError, TypeError) as error:
                        parse_error = str(error)
            final = rows[0] if len(rows) == 1 else None
            if final is not None:
                save(arm / 'generator-final.json', final)
                summary['final'] = final
                summary['generator_failure_reasons'] = {key: final.get(key) for key in
                    ['run_incomplete_reasons', 'correctness_invalid_reasons', 'invalid_reasons'] if final.get(key)}
            check(container.get('Image') == settings['image_id'], 'container image differs from frozen image')
            check(container.get('Id') == (arm / 'container-id.txt').read_text().strip(), 'container identity changed')
            check(container.get('RestartCount') == 0 and state.get('Running') is False
                  and state.get('OOMKilled') is False and state.get('ExitCode') == 0,
                  'container did not exit cleanly: ' + json.dumps(execution, allow_nan=False))
            check(container.get('HostConfig', {}).get('NetworkMode') == 'host', 'container does not use host networking')
            check(parse_error is None, 'invalid generator JSON record: ' + str(parse_error))
            check(final is not None, 'missing or ambiguous final generator record')
            if settings.get('submit_coalesce_override'):
                check(final.get('native_run_batching_coalesce_ms') == settings['submit_coalesce_ms'],
                      'generator did not confirm requested coalesce interval')
            for key in ['benchmark_result_valid', 'canonical_result_valid', 'chain_correctness_valid',
                        'canonical_follower_enabled', 'canonical_follower_final_catchup_complete']:
                check(final.get(key) is True, key + ' is not true')
            for key in ['canonical_backlog', 'canonical_backlog_after_drain', 'canonical_total_backlog_after_drain',
                        'canonical_follower_errors', 'canonical_follower_retry_exhausted', 'canonical_hash_conflicts',
                        'duplicate_nonce_conflicts', 'external_nonce_conflicts']:
                check(type(final.get(key)) is int and final[key] == 0, key + ' is not zero')
            for key in ['correctness_invalid_reasons', 'run_incomplete_reasons']:
                check(final.get(key) == [], key + ' is not empty')
            for key, expected in [('configured_connections', settings['connections']), ('configured_workers', settings['workers']),
                                  ('configured_signers', settings['signers']), ('configured_sources', settings['sources']),
                                  ('adaptive_initial_cwnd', settings['initial_cwnd']), ('adaptive_max_cwnd', settings['max_cwnd'])]:
                check(type(final.get(key)) is int and final[key] == expected, key + ' mismatch')
            for cohort, offered in [('canonical_total_after_drain', 'offered'), ('canonical_measured_offers_after_drain', 'steady_offered')]:
                check(type(final.get(cohort)) is int and type(final.get(offered)) is int and final[cohort] == final[offered], cohort + ' does not reconcile')
            quantum = settings['quantum']
            check(final.get('native_signed_runs_enabled') is True, 'signed native runs not enabled')
            for key in ['native_signed_run_target_size', 'native_signed_run_effective_quantum_min', 'native_signed_run_effective_quantum_max']:
                check(final.get(key) == quantum, key + ' mismatch')
            parents = final.get('native_signed_run_normal_messages'); logical = final.get('native_signed_run_normal_logical_transfers')
            check(type(parents) is int and parents > 0 and logical == parents * quantum, 'normal signed-run density mismatch')
            check(final.get('native_signed_run_normal_quantum_violations') == 0, 'normal quantum violations')
            check(final.get('native_signed_run_terminal_tail_messages') == 0 and final.get('native_signed_run_terminal_tail_logical_transfers') == 0, 'terminal nonce tails are outside this benchmark profile')
            for suffix in ['messages', 'logical_transfers']:
                values = [final.get('native_signed_run_' + category + suffix) for category in ['', 'normal_', 'repair_', 'terminal_tail_']]
                check(all(type(x) is int and x >= 0 for x in values) and values[0] == sum(values[1:]), 'signed-run counter reconciliation failed')
            check(final.get('native_signed_run_proof_resolutions') == final.get('native_signed_run_messages'), 'not every signed parent has a proof resolution')
            batching = settings['environment'].get('NATIVE_LOAD_NATIVE_RUN_BATCHING', '0') == '1'
            check(final.get('native_run_batching_requested') is batching and final.get('native_run_batching_enabled') is batching, 'requested/effective batching mismatch')
            lanes = final.get('canonical_lane_balance', {})
            for key in ['enabled', 'required', 'valid', 'topology_complete', 'totals_reconcile', 'every_lane_active', 'within_tolerance']:
                check(lanes.get(key) is True, 'canonical lane ' + key + ' is not true')
            check(lanes.get('depth') == settings['lane_depth'] and lanes.get('expected_lanes') == 1 << settings['lane_depth'], 'canonical lane depth mismatch')
            duration = final.get('measure_elapsed_s')
            check(type(duration) in (int, float) and duration > 0 and abs(duration - settings['duration']) <= 0.01, 'measurement duration mismatch')
            canonical_duration = final.get('canonical_gen_utime_bucket_duration_s')
            check(type(canonical_duration) is int and canonical_duration > 0, 'empty canonical block-time window')
            rates = {'offered_logical_tps': final.get('steady_offered_avg_tps'), 'admission_logical_tps': final.get('steady_mempool_accept_avg_tps'),
                     'canonical_logical_tps': final.get('canonical_chain_measure_avg_tps')}
            for value in rates.values(): check(type(value) in (int, float) and math.isfinite(value) and value > 0, 'invalid measured rate')
            for field, counter, elapsed in [('offered_logical_tps', 'steady_offered', duration), ('admission_logical_tps', 'steady_mempool_accepted', duration), ('canonical_logical_tps', 'canonical_chain_measure_transfers', canonical_duration)]:
                check(type(final.get(counter)) is int and math.isclose(rates[field], final[counter]/elapsed, rel_tol=1e-8, abs_tol=1e-8), 'measured rate/counter mismatch')
            summary['measured'] = dict(rates, offer_duration_s=duration, canonical_bucket_duration_s=canonical_duration)
            check(type(final.get('retry_exhausted')) is int and final['retry_exhausted'] >= 0, 'invalid retry_exhausted counter')
            for key in ['ingress_capacity_valid', 'chain_capacity_valid']:
                check(type(final.get(key)) is bool, 'missing capacity gate: ' + key)
            above = rates['offered_logical_tps'] > rates['canonical_logical_tps']
            summary['generator_capacity_gates'] = {key: final.get(key) for key in ['ingress_capacity_valid', 'chain_capacity_valid', 'ingress_capacity_invalid_reasons', 'chain_capacity_invalid_reasons']}
            summary['offered_above_canonical'] = above
            summary['valid_run'] = not errors
            if summary['valid_run']:
                summary['capacity_classification'] = 'generator_capacity_eligible' if above and final['ingress_capacity_valid'] and final['chain_capacity_valid'] and not summary['prior_unresolved_arms'] and final.get('retry_exhausted') == 0 else 'observation_only'
                observation_reasons = []
                if summary['prior_unresolved_arms']:
                    observation_reasons.append('prior_arm_source_cohorts_unresolved')
                if final['retry_exhausted']:
                    observation_reasons.append('recovered_retry_exhaustion')
                if observation_reasons: summary['capacity_observation_reasons'] = observation_reasons
            summary['full_independent_capacity_claim_allowed'] = False
        except (ValueError, OSError, KeyError, TypeError, ArithmeticError, AttributeError) as error:
            errors.append(str(error))
        # All proof/completion gates and exit code zero remain mandatory before
        # reusing a source cohort. Retry exhaustion belongs to capacity validity:
        # successful drain recovery can still produce a complete observation.
        summary['source_reuse_safe'] = summary['valid_run']
        summary['source_reuse_invalid_reasons'] = list(errors)
        summary['container_stopped_verified'] = False
        try:
            check(not forced, 'runner was interrupted or failed externally')
            check(container.get('Image') == settings['image_id']
                  and container.get('Id') == (arm / 'container-id.txt').read_text().strip(),
                  'container image/identity was not verified')
            check(container.get('RestartCount') == 0 and state.get('Running') is False
                  and container.get('HostConfig', {}).get('NetworkMode') == 'host',
                  'owned workload is not verified stopped without restart')
            summary['container_stopped_verified'] = True
        except (ValueError, OSError, KeyError, TypeError, ArithmeticError, AttributeError, NameError):
            pass
        if errors and summary.get('final') is not None:
            final = summary['final']
            summary['generator_diagnostics'] = {key: final[key] for key in [
                'phase', 'drain_timed_out', 'canonical_backlog', 'canonical_backlog_after_drain',
                'canonical_total_backlog_after_drain', 'canonical_follower_final_catchup_complete',
                'canonical_follower_errors', 'canonical_hash_conflicts', 'retry_exhausted',
                'retry_exhausted_sources', 'task_errors_by_reason', 'not_ready_by_reason', 'retries_by_reason', 'resigned',
                'native_signed_run_repair_messages', 'native_signed_run_repair_logical_transfers',
                'native_signed_run_proof_resolutions', 'native_signed_run_messages',
                'repair_offered', 'repair_accepted', 'active_tasks', 'ready', 'retry_wait', 'inflight']
                if key in final}
        # Diagnostic observations never relax correctness, capacity or reuse gates.
        final = summary.get('final') or {}
        observed = {key: final[key] for key in [
            'steady_offered_avg_tps', 'steady_mempool_accept_avg_tps', 'canonical_chain_measure_avg_tps',
            'congestion_window', 'congestion_window_sampled_peak', 'effective_cwnd_cap',
            'cwnd_cap_limited_acks', 'query_credit_stalls', 'clients_at_query_cap_sampled_peak',
            'rtt_ms', 'wire_batch_avg_size', 'not_ready_by_reason', 'canonical_backlog_at_measure_end',
            'canonical_backlog_after_drain', 'canonical_backlog_sampled_peak',
            'native_signed_run_issue_holds', 'measure_canonical_backpressure_fraction'] if key in final}
        signals = []
        def positive(value): return type(value) in (int, float) and value > 0
        if positive(observed.get('cwnd_cap_limited_acks')): signals.append('admission_window_cap_encountered')
        if positive(observed.get('query_credit_stalls')): signals.append('query_credit_stalls_observed')
        if positive(observed.get('measure_canonical_backpressure_fraction')) and observed['measure_canonical_backpressure_fraction'] > 0.01: signals.append('canonical_backpressure_above_one_percent')
        if isinstance(observed.get('not_ready_by_reason'), dict) and any(positive(v) for v in observed['not_ready_by_reason'].values()): signals.append('not_ready_retries_observed')
        summary['client_limits'] = {'observed': observed, 'signals': signals,
            'semantics': 'Diagnostic clues, not a bottleneck verdict or capacity pass. Final congestion window may reflect drain; use measure-phase progress samples. Counters are lifetime unless named measure/steady.'}
        save(arm / 'client-limits.json', summary['client_limits'])
        summary['finished_unix_s'] = time.time()
        save(arm / 'summary.json', summary)
        print(json.dumps({key: summary.get(key) for key in ['connections', 'load_settings', 'source_partition', 'source_reuse_safe', 'valid_run', 'capacity_classification', 'capacity_observation_reasons', 'measured', 'invalid_reasons', 'execution', 'generator_failure_reasons', 'generator_diagnostics', 'client_limits']}))
        if errors and not summary['source_reuse_safe']:
            print('Stopped before reusing source accounts. Inspect ' + str(arm / 'execution.json') + ', ' + str(arm / 'generator.log') + ' and ' + str(arm / 'generator.stderr.log') + '.', file=sys.stderr)
        sys.exit(0 if summary['valid_run'] else 4 if summary.get('container_stopped_verified') and settings.get('source_policy') == 'isolated' else 1)
    elif mode == 'suite':
        output = Path(sys.argv[2]); exit_code = int(sys.argv[3])
        settings = read(output / 'settings.json') if (output / 'settings.json').is_file() else {}
        arms = []
        for path in sorted(output.glob('*-connections/summary.json')): arms.append(read(path))
        save(output / 'summary.json', {'schema': 'native-remote-sweep-v1', 'exit_code': exit_code,
             'completed': exit_code == 0 and len(arms) == len(settings.get('connections', [])) and bool(arms) and all(a['valid_run'] for a in arms),
             'all_setups_attempted': bool(arms) and len(arms) == len(settings.get('connections', [])),
             'requested_connections': settings.get('connections'), 'arms': arms,
             'semantics': 'Capacity-only observation arms are retained. No remote validator cleanup, process identity or resource claims are inferred.'})
    else:
        raise ValueError('unknown helper mode')
except (ValueError, OSError, KeyError, TypeError, ArithmeticError, AttributeError) as error:
    print('remote-load: ' + str(error), file=sys.stderr)
    sys.exit(2)
PY
}

capture_active() {
  timeout 30 docker logs "$active_container" >"$active_arm/generator.log" 2>"$active_arm/generator.stderr.log" || true
  timeout 15 docker inspect "$active_container" >"$active_arm/container.json" 2>"$active_arm/inspect.stderr.log" || true
}
owns_active() {
  timeout 15 docker inspect "$active_container" >"$active_arm/ownership-inspect.json" 2>"$active_arm/ownership.stderr.log" || return 1
  helper owns "$active_arm" 2>>"$active_arm/ownership.stderr.log"
}
stop_active() {
  timeout --kill-after=5 40 docker stop -t 30 "$active_container" >"$active_arm/stop.log" 2>&1 || true
  if [[ $(timeout 10 docker inspect --format '{{.State.Running}}' "$active_container" 2>/dev/null || true) == true ]]; then
    timeout --kill-after=5 10 docker kill "$active_container" >>"$active_arm/stop.log" 2>&1 || true
  fi
}
reap_wait() {
  if [[ -n $wait_pid ]]; then
    kill "$wait_pid" 2>/dev/null || true
    wait "$wait_pid" 2>/dev/null || true
    wait_pid=
  fi
}
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -n $active_container ]]; then
    if owns_active; then
      stop_active
      capture_active
    else
      printf 'No matching owned container found; cleanup will not stop another container.\n' >>"$active_arm/ownership.stderr.log"
    fi
    reap_wait
    helper summarize "$active_arm" "${interrupt_reason:-runner_failed_before_completion}" || true
  fi
  helper suite "$output" "$status" || true
  printf 'Artifacts retained: %s\n' "$output" >&2
  exit "$status"
}
trap cleanup EXIT
trap 'interrupt_reason=interrupted_SIGINT; exit 130' INT
trap 'interrupt_reason=interrupted_SIGTERM; exit 143' TERM

watchdog=$(helper prepare "$directory" "$client_data" "$output" "$duration_override" "$warmup_override" "$drain_override" "$cpus" "$memory" "$image_override" "$script_dir/${BASH_SOURCE[0]##*/}" "$profile" "$source_policy" "$workers_override" "$signers_override" "$initial_cwnd_override" "$max_cwnd_override" "$coalesce_override" "${connections[@]}" 2>"$output/preflight.stderr.log") || {
  cat "$output/preflight.stderr.log" >&2; exit 2;
}
# A remote Docker context would run the generator on the wrong server.
if [[ -z ${DOCKER_CONTEXT:-} && -n ${DOCKER_HOST:-} ]]; then
  [[ $DOCKER_HOST == unix://* ]] || fail 'DOCKER_HOST must address the local Linux Docker daemon'
else
  endpoint=$(timeout 15 docker context inspect --format '{{.Endpoints.docker.Host}}')
  [[ $endpoint == unix://* ]] || fail 'the selected Docker context is not a local Unix socket'
fi
[[ $(timeout 15 docker info --format '{{.OSType}}') == linux ]] || fail 'the Docker daemon must run Linux containers'
IFS= read -r image_reference <"$output/image-reference.txt"
timeout 20 docker image inspect "$image_reference" >"$output/image-inspect.json" 2>"$output/image-inspect.stderr.log"
image_id=$(helper image "$output")
# Check the frozen binary before even the first low-count arm in a mixed sweep.
# This short-lived help probe has no network or mounted account/config material.
for count in "${connections[@]}"; do
  if ((count > 256)); then
    capability_status=0
    timeout --kill-after=5 30 docker run --rm --pull never --network none \
      --entrypoint /usr/local/bin/native-load-generator "$image_id" --help \
      >"$output/native-load-generator-help.txt" 2>"$output/capability.stderr.log" || capability_status=$?
    helper capability "$output" "$image_id" "$capability_status" || exit 2
    break
  fi
done
helper announce "$output"
run_token="$(date -u +%Y%m%dT%H%M%SZ)-$$"
index=0
suite_status=0
for count in "${connections[@]}"; do
  ((index += 1))
  printf -v arm_name '%02d-%s-connections' "$index" "$count"
  active_arm="$output/$arm_name"
  mkdir -- "$active_arm"
  active_container="native-remote-${run_token}-${count}"
  helper arm "$output" "$active_arm" "$count" "$image_id" "$active_container"
  printf 'Running %s connections with %s; artifacts: %s\n' "$count" "$image_id" "$active_arm"
  timeout --kill-after=5 60 docker run -d --pull never --name "$active_container" \
    --label "io.ton.native-remote-owner=$active_container" \
    --network host --cpus "$cpus" --memory "$memory" --ulimit nofile=65536:65536 \
    --mount "type=bind,src=$client_data,dst=/client,readonly" \
    --env-file "$active_arm/runtime.env" \
    --entrypoint /usr/local/bin/run-native-load-generator \
    "$image_id" >"$active_arm/container-id.txt" 2>"$active_arm/start.stderr.log"
  timeout --kill-after=5 "$watchdog" docker wait "$active_container" >"$active_arm/wait.log" 2>"$active_arm/wait.stderr.log" &
  wait_pid=$!
  wait_status=0
  arm_started=$SECONDS
  next_progress=$SECONDS
  while kill -0 "$wait_pid" 2>/dev/null; do
    if ((SECONDS >= next_progress)); then
      timeout 10 docker logs --tail 200 "$active_container" >"$active_arm/progress-tail.log" 2>"$active_arm/progress.stderr.log" || true
      helper progress "$active_arm" "$((SECONDS - arm_started))" || true
      next_progress=$((SECONDS + 30))
    fi
    sleep 1
  done
  wait "$wait_pid" || wait_status=$?
  printf '%s\n' "$wait_status" >"$active_arm/wait-status.txt"
  wait_pid=
  if ((wait_status != 0)); then
    case "$wait_status" in
      124) interrupt_reason="watchdog_expired_after_${watchdog}s" ;;
      137) interrupt_reason="docker_wait_or_watchdog_killed_exit_137" ;;
      *) interrupt_reason="docker_wait_command_failed_exit_${wait_status}" ;;
    esac
    exit 1
  fi
  capture_active
  active_container=
  arm_status=0
  helper summarize "$active_arm" '' || arm_status=$?
  if ((arm_status != 0)); then
    suite_status=1
    case "$arm_status" in
      4) printf 'Arm remains invalid; the next setup uses disjoint sources and is observation-only while prior cohorts are unresolved.\n' >&2 ;;
      *) exit 1 ;;
    esac
  fi
  active_arm=
done
exit "$suite_status"
