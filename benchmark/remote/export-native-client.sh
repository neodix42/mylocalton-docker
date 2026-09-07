#!/usr/bin/env bash
# Export client materials and prepare the configured generator image; never start services or submit load.
set -euo pipefail
command -v python3 >/dev/null 2>&1 || { echo 'python3 is required' >&2; exit 2; }
export NATIVE_EXPORT_SCRIPT_DIR
NATIVE_EXPORT_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec python3 - "$@" <<'PYEXPORT'
import argparse
import base64
import ctypes
import datetime
import errno
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile

WALLET_ROOT = '/var/ton-work/db/native-spam/wallets'
SCRIPT_DIR = Path(os.environ['NATIVE_EXPORT_SCRIPT_DIR'])
REPO_DIR = SCRIPT_DIR.parents[1]
MANIFEST_NAME = 'native-payment-lanes.manifest'
SCHEMA = 'native-remote-client-export-v1'


class ExportError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ExportError(message)


def uint(value, label, minimum=0, maximum=4294967295):
    text = str(value)
    require(re.fullmatch(r'[0-9]+', text) is not None, label + ' must be an unsigned integer')
    number = int(text)
    require(minimum <= number <= maximum, f'{label} must be in [{minimum}, {maximum}]')
    return number


def ask(label, default=None):
    try:
        with open('/dev/tty', 'r') as tty_input, open('/dev/tty', 'w') as tty_output:
            tty_output.write(label + (f' [{default}]' if default is not None else '') + ': ')
            tty_output.flush()
            answer = tty_input.readline()
    except OSError as exc:
        raise ExportError('interactive input unavailable; provide --server-ip, --output and --non-interactive') from exc
    require(answer != '', 'input closed before export configuration was complete')
    return answer.strip() or (str(default) if default is not None else '')


def parse_args():
    parser = argparse.ArgumentParser(
        prog='export-native-client.sh',
        description='Export one validator\'s selected funded native client wallets and a generator image for server B. '
                    'With no arguments, prompt interactively. Resolve the image from Compose and build it locally '
                    'only if missing, unless an image/build option overrides this. Never start services or submit traffic.')
    parser.add_argument('--server-ip', help='IPv4 address reachable from B (a public/LAN address or tunnel endpoint)')
    parser.add_argument('--port', help='published liteserver TCP port (default: 40004)')
    parser.add_argument('--container', help='existing running source container (default: genesis)')
    parser.add_argument('--sources', help='selected source count (default: 24576)')
    parser.add_argument('--source-offset', help='first source index (default: 0)')
    parser.add_argument('--output', help='new private bundle directory; existing destinations are refused')
    parser.add_argument('--image', help='explicit existing local generator image; bypass Compose and never build it')
    parser.add_argument('--env-file', default=str(REPO_DIR / '.env'),
                        help='Compose environment file (default: repository/.env; relative paths use the current directory)')
    build_group = parser.add_mutually_exclusive_group()
    build_group.add_argument('--build-image', action='store_true',
                             help='force a local build of the configured generator service; incompatible with --image')
    build_group.add_argument('--no-build-image', action='store_true',
                             help='require the configured image to exist locally; never build it')
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--include-image', dest='include_image', action='store_true', default=None,
                       help='include generator-image.tar (default)')
    group.add_argument('--no-image', dest='include_image', action='store_false',
                       help='omit the image archive; B must already have the exact image')
    parser.add_argument('--non-interactive', action='store_true', help='require explicit server IP/output; use other defaults')
    args = parser.parse_args()
    if args.image is not None and args.build_image:
        parser.error('--build-image cannot be combined with --image; omit --image to build the configured service')
    interactive = not args.non_interactive and len(sys.argv) == 1
    defaults = {'port': '40004', 'container': 'genesis', 'sources': '24576', 'source_offset': '0'}
    if args.server_ip is None and not args.non_interactive:
        args.server_ip = ask('Server A IPv4 address reachable from B')
    if interactive:
        for field, label in [('port', 'Liteserver TCP port'), ('container', 'Source validator container'),
                             ('sources', 'Number of source accounts'), ('source_offset', 'First source index')]:
            setattr(args, field, ask(label, defaults[field]))
    for field, default in defaults.items():
        if getattr(args, field) is None:
            setattr(args, field, default)
    if args.output is None and not args.non_interactive:
        args.output = ask('New export directory', str(Path.home() / ('native-client-export-' +
                          datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'))))
    if args.include_image is None:
        if interactive:
            answer = ask('Include the prebuilt generator image? yes/no', 'yes').lower()
            require(answer in ('yes', 'y', 'no', 'n'), 'answer yes or no for image inclusion')
            args.include_image = answer in ('yes', 'y')
        else:
            args.include_image = True
    require(args.server_ip and args.output, '--server-ip and --output are required with --non-interactive')
    try:
        address = ipaddress.IPv4Address(args.server_ip)
    except ipaddress.AddressValueError as exc:
        raise ExportError('--server-ip must be an IPv4 address, without scheme or hostname') from exc
    require(not address.is_unspecified and not address.is_multicast and int(address) != 4294967295,
            '--server-ip must identify a unicast endpoint, not a wildcard/multicast/broadcast address')
    args.server_ip = str(address)
    args.port = uint(args.port, 'port', 1, 65535)
    args.sources = uint(args.sources, 'sources', 1, 1000000)
    args.source_offset = uint(args.source_offset, 'source-offset')
    require(args.source_offset + args.sources <= 4294967295, 'selected source range exceeds generator uint32 limit')
    require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', args.container) is not None, 'invalid container name or ID')
    if args.image is not None:
        validate_image_reference(args.image)
    args.env_file = Path(args.env_file).expanduser().resolve()
    # Resolve the parent, not the final component: a dangling destination symlink
    # is still an existing destination and must not be overwritten.
    output = Path(args.output).expanduser().absolute()
    require(output.name not in ('', '.', '..'), 'output must name a new bundle directory')
    args.output = output.parent.resolve() / output.name
    require(not os.path.lexists(args.output), 'output already exists; select a new directory')
    return args


def docker_json(arguments):
    try:
        result = subprocess.run(['docker', *arguments], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                check=True, timeout=60)
        value = json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        # Do not echo arbitrary Docker stderr or configuration data.
        raise ExportError('Docker read failed: ' + ' '.join(arguments[:2]) +
                          '; confirm the local image/container exists and Docker is available') from exc
    require(isinstance(value, list) and len(value) == 1 and isinstance(value[0], dict),
            'Docker inspection must return exactly one object')
    return value[0]


def validate_image_reference(reference):
    require(isinstance(reference, str) and reference and not reference.startswith('-') and
            not any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in reference),
            'invalid local image reference')


def image_metadata(reference, allow_missing=False):
    try:
        result = subprocess.run(['docker', 'image', 'inspect', reference], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        raise ExportError('cannot inspect the local generator image; confirm Docker is available') from exc
    if result.returncode != 0:
        missing = b'No such image:' in result.stderr or b'No such object:' in result.stderr
        if allow_missing and missing:
            return None
        raise ExportError('generator image is unavailable locally; confirm its exact reference and Docker access')
    try:
        value = json.loads(result.stdout)
    except ValueError as exc:
        raise ExportError('invalid generator image inspection response') from exc
    require(isinstance(value, list) and len(value) == 1 and isinstance(value[0], dict),
            'generator image inspection must return exactly one object')
    raw = value[0]
    require(re.fullmatch(r'sha256:[0-9a-f]{64}', str(raw.get('Id', ''))) is not None,
            'image has no immutable SHA256 ID')
    require(isinstance(raw.get('Architecture'), str) and raw['Architecture'] and raw.get('Os') == 'linux',
            'generator image must identify its Linux OS and architecture')
    return {'reference': reference, 'id': raw['Id'], 'architecture': raw['Architecture'], 'os': raw['Os']}


def compose_configuration(args):
    require(args.env_file.is_file(), 'Compose environment file is missing: ' + str(args.env_file) +
            '; provide --env-file PATH or an explicit existing --image')
    compose_file = REPO_DIR / 'docker-compose.yaml'
    require(compose_file.is_file(), 'repository docker-compose.yaml is missing; use an explicit existing --image')
    command = ['docker', 'compose', '--project-directory', str(REPO_DIR), '--env-file', str(args.env_file),
               '-f', str(compose_file), '--profile', 'native-load-generator']
    environment = os.environ.copy()
    # Preserve normal Compose interpolation, but prefer a cached TON base when
    # building. Docker may still obtain a base that is absent.
    environment['TON_BUILD_PULL'] = 'false'
    try:
        result = subprocess.run([*command, 'config', '--format', 'json'], env=environment,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60, check=True)
        config = json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        raise ExportError('cannot resolve the generator image from Compose; check --env-file and Docker Compose '
                          'configuration locally (resolved environment is intentionally not printed)') from exc
    services = config.get('services') if isinstance(config, dict) else None
    service = services.get('native-load-generator') if isinstance(services, dict) else None
    require(isinstance(service, dict), 'Compose has no native-load-generator service')
    reference = service.get('image')
    validate_image_reference(reference)
    print('Configured generator image: ' + reference, flush=True)
    build = service.get('build')
    build_args = build.get('args') if isinstance(build, dict) else None
    if isinstance(build_args, dict):
        base_image, base_branch = build_args.get('TON_IMAGE'), build_args.get('TON_BRANCH')
        if all(isinstance(value, str) and value and
               all(32 < ord(char) < 127 for char in value) for value in (base_image, base_branch)):
            print('Configured TON base: ' + base_image + ':' + base_branch, flush=True)
    return reference, command, environment


def require_local_docker():
    # DOCKER_CONTEXT takes precedence over DOCKER_HOST. A local host variable
    # must not disguise a remote selected context before a build.
    host = os.environ.get('DOCKER_HOST')
    if os.environ.get('DOCKER_CONTEXT') or not host:
        try:
            result = subprocess.run(['docker', 'context', 'inspect', '--format', '{{.Endpoints.docker.Host}}'],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=True)
            host = result.stdout.decode('utf-8').strip()
        except (OSError, subprocess.SubprocessError, UnicodeError) as exc:
            raise ExportError('cannot establish the selected Docker endpoint; use a local Unix Docker context to build') from exc
    require(host.startswith('unix://') and len(host) > len('unix://'),
            'image builds require a local Unix Docker endpoint; select a local context or use --image with a prebuilt image')


def prepare_image(args):
    if args.image is not None:
        image = image_metadata(args.image, allow_missing=True)
        require(image is not None, 'explicit --image is missing locally; build or load that exact image separately, '
                'or omit --image to prepare the generator image configured in --env-file')
        print('Using explicit local generator image: ' + args.image, flush=True)
        return image
    reference, command, environment = compose_configuration(args)
    image = image_metadata(reference, allow_missing=True)
    if args.no_build_image:
        require(image is not None, 'configured generator image is missing locally and --no-build-image forbids building; '
                'load the exact image or rerun without --no-build-image')
    if args.build_image or (image is None and not args.no_build_image):
        require_local_docker()
        print('Building only native-load-generator with TON_BUILD_PULL=false; no services will be started. '
              'Docker may obtain a missing TON base image.', flush=True)
        try:
            # Inherit build output for operator diagnostics, without printing
            # the resolved Compose JSON or unrelated environment values.
            subprocess.run([*command, 'build', 'native-load-generator'], env=environment, check=True, timeout=3600)
        except (OSError, subprocess.SubprocessError) as exc:
            raise ExportError('generator image build failed; inspect the build output and verify the configured TON base '
                              'is cached locally or accessible from its registry, then rerun. '
                              'Alternatively, load a compatible prebuilt generator and select --image.') from exc
        image = image_metadata(reference)
    require(image is not None, 'configured generator image was not prepared')
    print('Frozen generator image ID: ' + image['id'], flush=True)
    return image


def container_identity(name):
    raw = docker_json(['inspect', name])
    state = raw.get('State', {})
    require(isinstance(state, dict) and state.get('Running') is True,
            'source container must be running for read-only config/wallet export')
    result = {'id': raw.get('Id'), 'image_id': raw.get('Image'), 'started_at': state.get('StartedAt'),
              'restart_count': raw.get('RestartCount')}
    require(all(isinstance(result[k], str) and result[k] for k in ('id', 'image_id', 'started_at')) and
            type(result['restart_count']) is int and result['restart_count'] >= 0,
            'source container identity is incomplete')
    return result


def read_global_config(container):
    code = 'import sys; sys.stdout.buffer.write(open("/usr/share/data/global.config.json", "rb").read())'
    try:
        result = subprocess.run(['docker', 'exec', container, 'python3', '-c', code],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60, check=True)
        config = json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        raise ExportError('cannot read the source container public global config') from exc
    require(isinstance(config, dict), 'global config must be an object')
    servers = config.get('liteservers')
    require(isinstance(servers, list) and len(servers) == 1 and isinstance(servers[0], dict),
            'global config must contain exactly one liteserver')
    server = servers[0]
    key = server.get('id', {})
    require(isinstance(key, dict) and key.get('@type') == 'pub.ed25519' and isinstance(key.get('key'), str),
            'global config must contain one Ed25519 liteserver public key')
    try:
        require(len(base64.b64decode(key['key'], validate=True)) == 32, 'liteserver key must decode to 32 bytes')
    except ValueError as exc:
        raise ExportError('liteserver public key is not valid base64') from exc
    validator = config.get('validator', {})
    zero = validator.get('zero_state', {}) if isinstance(validator, dict) else {}
    require(isinstance(zero, dict) and isinstance(zero.get('root_hash'), str) and zero['root_hash'],
            'global config has no zero-state signing domain')
    try:
        require(len(base64.b64decode(zero['root_hash'], validate=True)) == 32, 'zero-state root hash must decode to 32 bytes')
    except ValueError as exc:
        raise ExportError('zero-state root hash is not valid base64') from exc
    return config, hashlib.sha256(result.stdout).hexdigest()


# This code only reads known wallet paths and writes a selected tar stream to
# stdout. Never use wildcard tar/cp of the wallet or validator directory.
WALLET_EXPORT = r'''
import io, os, pathlib, stat, sys, tarfile
root = pathlib.Path('/var/ton-work/db/native-spam/wallets')
offset, count = map(int, sys.argv[1:])
def read_regular(name, limit):
    fd = os.open(root / name, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as f:
        meta = os.fstat(f.fileno())
        if not stat.S_ISREG(meta.st_mode) or meta.st_size > limit:
            raise ValueError('invalid wallet file type/size: ' + name)
        return f.read(limit + 1)
try:
    manifest = read_regular('native-payment-lanes.manifest', 64 * 1024 * 1024)
    header = manifest.decode('utf-8').splitlines()[0].split()
    if len(header) != 4 or header[0] != 'NATIVE_PAYMENT_LANES_MANIFEST_V1':
        raise ValueError('invalid lane manifest header')
    depth, lanes, available = map(int, header[1:])
    if depth not in (1, 2) or lanes != 1 << depth or offset + count > available:
        raise ValueError('lane manifest does not cover the requested depth/source range')
    with tarfile.open(fileobj=sys.stdout.buffer, mode='w|gz', format=tarfile.USTAR_FORMAT) as archive:
        def add(name, data):
            entry = tarfile.TarInfo(name)
            entry.size = len(data)
            entry.mode = 0o600
            entry.mtime = 0
            archive.addfile(entry, io.BytesIO(data))
        add('native-payment-lanes.manifest', manifest)
        for index in range(offset, offset + count):
            for name in (f'source-{index}.pk', f'source-{index}.pub', f'source-{index}.addr',
                         f'dest-{index}.pub', f'dest-{index}.addr'):
                add(name, read_regular(name, 64))
except (OSError, ValueError, IndexError) as error:
    print('Selected wallet export failed: ' + str(error), file=sys.stderr)
    sys.exit(2)
'''


def export_wallets(args, target):
    print(f'Packing {args.sources} selected source/destination sets; private key contents are never displayed.', flush=True)
    try:
        with target.open('xb') as output:
            subprocess.run(['docker', 'exec', '-i', args.container, 'python3', '-',
                            str(args.source_offset), str(args.sources)], input=WALLET_EXPORT.encode(),
                           stdout=output, stderr=subprocess.PIPE, timeout=1800, check=True)
    except (OSError, subprocess.SubprocessError) as exc:
        raise ExportError('cannot export the selected wallet files; check their existence, permissions and lane manifest range') from exc


def validate_wallet_archive(path, offset, sources):
    expected = {MANIFEST_NAME}
    for i in range(offset, offset + sources):
        expected.update((f'source-{i}.pk', f'source-{i}.pub', f'source-{i}.addr', f'dest-{i}.pub', f'dest-{i}.addr'))
    public = {}
    manifest = None
    seen = set()
    try:
        with tarfile.open(path, mode='r|gz') as archive:
            for entry in archive:
                require(entry.name in expected and entry.name not in seen and entry.isfile(),
                        'wallet archive contains an unexpected, duplicate or non-regular entry')
                require(not entry.issym() and not entry.islnk(), 'wallet archive links are prohibited')
                seen.add(entry.name)
                if entry.name == MANIFEST_NAME:
                    require(0 < entry.size <= 64 * 1024 * 1024, 'invalid lane manifest size')
                    manifest = archive.extractfile(entry).read().decode('utf-8')
                elif entry.name.endswith(('.pk', '.pub')):
                    require(entry.size == 32, 'private/public wallet key must contain exactly 32 raw bytes: ' + entry.name)
                    if entry.name.endswith('.pub'):
                        public[entry.name] = archive.extractfile(entry).read().hex()
                else:
                    require(32 <= entry.size <= 64, 'invalid binary wallet address size: ' + entry.name)
                    public[entry.name] = archive.extractfile(entry).read(32).hex()
    except (OSError, tarfile.TarError, UnicodeError) as exc:
        raise ExportError('wallet archive is unreadable or malformed') from exc
    require(seen == expected and manifest is not None, 'wallet archive does not contain every selected file')
    lines = manifest.splitlines()
    header = lines[0].split() if lines else []
    require(len(header) == 4 and header[0] == 'NATIVE_PAYMENT_LANES_MANIFEST_V1', 'invalid lane manifest header')
    depth = uint(header[1], 'manifest lane depth', 1, 2)
    require(uint(header[2], 'manifest lane count', 2, 4) == 1 << depth, 'manifest lane count/depth mismatch')
    available = uint(header[3], 'manifest source coverage', 1)
    require(offset + sources <= available, 'lane manifest does not cover selected source range')
    rows = set()
    for line in lines[1:]:
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        fields = line.split()
        require(fields and fields[0].isdigit(), 'malformed manifest row index')
        index = int(fields[0])
        if not offset <= index < offset + sources:
            continue
        require(len(fields) == 4 and index not in rows, 'duplicate or malformed selected manifest row')
        lane = uint(fields[1], 'manifest lane', 0, (1 << depth) - 1)
        require(lane == index % (1 << depth), 'selected manifest row has the wrong balanced lane')
        for prefix, address in [('source', fields[2]), ('dest', fields[3])]:
            require(re.fullmatch(r'[0-9a-fA-F]{64}', address) is not None, 'invalid manifest address')
            address = address.lower()
            require(public[f'{prefix}-{index}.pub'] == address == public[f'{prefix}-{index}.addr'],
                    'public key/address differs from selected lane manifest: ' + f'{prefix}-{index}')
            require(int(address[:2], 16) >> (8 - depth) == lane, 'selected source/destination is not in its manifest lane')
        rows.add(index)
    require(len(rows) == sources, 'lane manifest is missing selected source rows')
    return depth


def environment_text(source, args, depth, image_id):
    values = {}
    for line in source.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        require('=' in line, 'preset must contain plain KEY=value lines')
        key, value = line.split('=', 1)
        require(re.fullmatch(r'[A-Z_][A-Z0-9_]*', key) is not None and key not in values and '\x00' not in value,
                'preset contains an invalid or duplicate environment key')
        values[key] = value
    for name in ('NATIVE_LOAD_WORKERS', 'NATIVE_LOAD_SIGNERS'):
        require(name in values, 'preset is missing ' + name)
        values[name] = str(min(uint(values[name], name, 1), args.sources))
    values.update({'REMOTE_LOAD_IMAGE': image_id, 'NATIVE_LOAD_SOURCES': str(args.sources),
                   'NATIVE_LOAD_SOURCE_OFFSET': str(args.source_offset), 'NATIVE_LOAD_GLOBAL_CONFIG': '/client/global.config.json',
                   'NATIVE_LOAD_WALLET_DIR': '/client/wallets',
                   'NATIVE_LOAD_PAYMENT_LANE_MANIFEST': '/client/wallets/' + MANIFEST_NAME,
                   'NATIVE_LOAD_NATIVE_TRANSFER_RUNS': '1', 'NATIVE_LOAD_NATIVE_TRANSFER_RUN_SIZE': '16',
                   'NATIVE_PAYMENT_LANES_ENABLED': '1', 'NATIVE_PAYMENT_LANE_DEPTH': str(depth),
                   'NATIVE_LOAD_PAYMENT_LANE_DEPTH': str(depth),
                   'NATIVE_LOAD_PAYMENT_LANE_READY_TIMEOUT_SECONDS': '900' if depth == 2 else '360'})
    return '# Exported native client preset; plain values, never source this file as shell code.\n' + ''.join(
        f'{key}={value}\n' for key, value in sorted(values.items()))


def inventory(directory):
    result = {}
    for path in sorted(directory.iterdir()):
        require(path.is_file() and not path.is_symlink(), 'unexpected bundle file')
        digest = hashlib.sha256()
        with path.open('rb') as file:
            for block in iter(lambda: file.read(1024 * 1024), b''):
                digest.update(block)
        result[path.name] = {'sha256': digest.hexdigest(), 'size': path.stat().st_size}
    return result


def publish_without_overwrite(source, destination):
    # Linux renameat2 is atomic and refuses even an empty destination created
    # concurrently. A check followed by ordinary rename would replace that dir.
    libc = ctypes.CDLL(None, use_errno=True)
    rename = getattr(libc, 'renameat2', None)
    require(rename is not None, 'atomic no-overwrite publication requires Linux renameat2')
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(-100, os.fsencode(source), -100, os.fsencode(destination), 1) != 0:
        code = ctypes.get_errno()
        if code in (errno.EEXIST, errno.ENOTEMPTY):
            raise ExportError('output appeared during export; existing destination preserved')
        raise OSError(code, 'cannot publish completed export')


def main():
    os.umask(0o077)
    args = parse_args()
    require(shutil.which('docker') is not None, 'docker is required on the exporting server')
    # Bind server A before image preparation, which may take time but must not
    # restart/recreate its container or change the exported chain configuration.
    before = container_identity(args.container)
    config, original_config_hash = read_global_config(args.container)
    required = {name: SCRIPT_DIR / name for name in ('native-remote-load.env', 'import-native-client.sh', 'run-remote-load.sh')}
    for name, path in required.items():
        require(path.is_file() and not path.is_symlink(), 'export helper/preset is missing: ' + name)
    image = prepare_image(args)
    require(container_identity(args.container) == before, 'source container changed during image preparation; retry after it is stable')
    _, prepared_config_hash = read_global_config(args.container)
    require(prepared_config_hash == original_config_hash, 'source global config changed during image preparation')
    original_public_key = config['liteservers'][0]['id']
    original_zero_state = config['validator']['zero_state']
    number = int(ipaddress.IPv4Address(args.server_ip))
    config['liteservers'][0]['ip'] = number if number < 2**31 else number - 2**32
    config['liteservers'][0]['port'] = args.port
    require(config['liteservers'][0]['id'] == original_public_key and
            config['validator']['zero_state'] == original_zero_state, 'unexpected chain identity change')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    require(not os.path.lexists(args.output), 'output already exists; select a new directory')
    staging = Path(tempfile.mkdtemp(prefix='.' + args.output.name + '.staging-', dir=args.output.parent))
    try:
        (staging / 'external.global.config.json').write_text(json.dumps(config, indent=2) + '\n')
        export_wallets(args, staging / 'test-wallets.tar.gz')
        depth = validate_wallet_archive(staging / 'test-wallets.tar.gz', args.source_offset, args.sources)
        (staging / 'remote-load.env').write_text(environment_text(required['native-remote-load.env'], args, depth, image['id']))
        for name in ('import-native-client.sh', 'run-remote-load.sh'):
            shutil.copyfile(required[name], staging / name)
        if args.include_image:
            print('Saving the prepared generator image by immutable ID.', flush=True)
            try:
                subprocess.run(['docker', 'image', 'save', '--output', str(staging / 'generator-image.tar'), image['id']],
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=3600, check=True)
            except (OSError, subprocess.SubprocessError) as exc:
                raise ExportError('cannot save the selected local generator image') from exc
            require((staging / 'generator-image.tar').is_file() and (staging / 'generator-image.tar').stat().st_size > 0,
                    'saved generator image archive is missing or empty')
        require(container_identity(args.container) == before, 'source container changed while exporting; retry after it is stable')
        require(image_metadata(image['reference']) == image, 'generator image reference changed while exporting')
        _, current_config_hash = read_global_config(args.container)
        require(current_config_hash == original_config_hash, 'source global config changed while exporting')
        for path in staging.iterdir():
            path.chmod(0o700 if path.suffix == ".sh" else 0o600)
        manifest = {'schema': SCHEMA,
                    'image': {**image, 'included': args.include_image,
                              'archive': 'generator-image.tar' if args.include_image else None},
                    'wallets': {'source_offset': args.source_offset, 'sources': args.sources, 'lane_depth': depth},
                    'endpoint': {'ip': args.server_ip, 'port': args.port}, 'files': inventory(staging),
                    'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    'source_container': before, 'original_global_config_sha256': original_config_hash,
                    'wallet_manifest': 'Original public lane manifest retained; archive contains only the selected wallet file range.'}
        (staging / 'export-manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
        (staging / 'export-manifest.json').chmod(0o600)
        publish_without_overwrite(staging, args.output)
        staging = None
        print(f'Export ready: {args.output}\nCopy this private directory to server B, then run: bash import-native-client.sh', flush=True)
        return 0
    finally:
        if staging is not None:
            # Never remove the destination or any pre-existing path.
            shutil.rmtree(staging)


def interrupt_export(signum, frame):
    raise KeyboardInterrupt


signal.signal(signal.SIGTERM, interrupt_export)

try:
    sys.exit(main())
except (ExportError, OSError, ValueError, KeyError, TypeError, UnicodeError) as error:
    print('Export failed: ' + str(error), file=sys.stderr)
    sys.exit(2)
except KeyboardInterrupt:
    print('Export interrupted; temporary staging removed.', file=sys.stderr)
    sys.exit(130)
PYEXPORT
