#!/usr/bin/env bash
# Install a verified server-A export into a new server-B client directory.
set -euo pipefail
exec python3 - "$0" "$@" <<'PY'
import argparse
import base64
import ctypes
import errno
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile

os.umask(0o077)
script = Path(sys.argv[1]).resolve()
parser = argparse.ArgumentParser(prog=script.name, description="Import a native client export on Linux server B; never starts load.")
parser.add_argument('--bundle', type=Path, help='export directory (default: directory containing this script)')
parser.add_argument('--output', type=Path, help='new client directory (default: ~/native-remote-client)')
parser.add_argument('--non-interactive', action='store_true', help='use options/defaults without prompts')
load = parser.add_mutually_exclusive_group()
load.add_argument('--load-image', dest='load_image', action='store_true', help='load the bundled image if missing locally')
load.add_argument('--no-load-image', dest='load_image', action='store_false', help='require the exact image to be present locally')
parser.set_defaults(load_image=None)
args = parser.parse_args(sys.argv[2:])


def require(condition, message):
    if not condition:
        raise ValueError(message)


def prompt(label, default):
    try:
        with open('/dev/tty', 'r') as tty_input, open('/dev/tty', 'w') as tty_output:
            tty_output.write(f'{label} [{default}]: ')
            tty_output.flush()
            line = tty_input.readline()
            require(line != '', 'Input ended; use --non-interactive for scripted operation')
            return line.strip() or str(default)
    except OSError as error:
        raise ValueError('Interactive input needs a terminal; pass --non-interactive with your options') from error


def checksum(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def uint(value, label, minimum=0, maximum=2**32 - 1):
    require(type(value) is int and minimum <= value <= maximum, f'Invalid {label}')
    return value


def inspect_image(image_id):
    result = subprocess.run(['docker', 'image', 'inspect', image_id], capture_output=True, text=True, timeout=60)
    if result.returncode:
        return None
    rows = json.loads(result.stdout)
    require(isinstance(rows, list) and len(rows) == 1, 'Unexpected Docker image inspection result')
    require(rows[0].get('Id') == image_id, 'Local image identity differs from the export')
    return rows[0]


def require_local_docker():
    context = os.environ.get('DOCKER_CONTEXT')
    host = os.environ.get('DOCKER_HOST')
    if context or not host:
        command = ['docker', 'context', 'inspect', '--format', '{{.Endpoints.docker.Host}}']
        if context:
            command.append(context)
        result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=30)
        host = result.stdout.strip()
    require(host.startswith('unix://'), 'Use the local Linux Docker daemon on server B, not a remote Docker context')


def parse_env(path):
    result = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        key, separator, value = line.partition('=')
        require(separator and re.fullmatch(r'[A-Z][A-Z0-9_]*', key), 'Invalid environment-file line')
        require(key not in result, f'Duplicate environment setting: {key}')
        result[key] = value
    return result


def publish_without_overwrite(source, destination):
    libc = ctypes.CDLL(None, use_errno=True)
    rename = getattr(libc, 'renameat2', None)
    require(rename is not None, 'Atomic client installation requires Linux renameat2')
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(-100, os.fsencode(source), -100, os.fsencode(destination), 1) != 0:
        code = ctypes.get_errno()
        if code in (errno.EEXIST, errno.ENOTEMPTY):
            raise ValueError('Output appeared during import; existing destination preserved')
        raise OSError(code, 'Cannot publish completed client installation')


def install():
    require(sys.platform.startswith('linux'), 'Run this importer on Linux server B')
    bundle = args.bundle or script.parent
    output = args.output or Path.home() / 'native-remote-client'
    if not args.non_interactive:
        if args.bundle is None:
            bundle = Path(prompt('Export bundle directory', bundle)).expanduser()
        if args.output is None:
            output = Path(prompt('New client directory', output)).expanduser()
    bundle = bundle.expanduser().resolve()
    output = output.expanduser().absolute()
    require(bundle.is_dir(), f'Bundle directory does not exist: {bundle}')
    require(not output.exists() and not output.is_symlink(), f'Refusing to overwrite existing output: {output}')
    manifest_path = bundle / 'export-manifest.json'
    require(manifest_path.is_file() and not manifest_path.is_symlink(), 'Missing regular export-manifest.json')
    require(manifest_path.stat().st_size <= 1024 * 1024, 'Export manifest is unexpectedly large')
    manifest = json.loads(manifest_path.read_text())
    require(manifest.get('schema') == 'native-remote-client-export-v1', 'Unsupported export manifest schema')
    image = manifest['image']
    image_id = image['id']
    require(isinstance(image_id, str) and re.fullmatch(r'sha256:[0-9a-f]{64}', image_id), 'Invalid immutable image ID')
    require(image.get('os') == 'linux', 'This client workflow requires a Linux generator image')
    require(type(image.get('included')) is bool, 'Invalid image inclusion flag')
    require(image.get('archive') == ('generator-image.tar' if image['included'] else None), 'Invalid image archive path')
    wallets = manifest['wallets']
    sources = uint(wallets['sources'], 'source count', 1, 1000000)
    offset = uint(wallets['source_offset'], 'source offset')
    require(offset + sources <= 2**32 - 1, 'Source range overflows uint32')
    depth = uint(wallets['lane_depth'], 'lane depth', 1, 3)
    endpoint = manifest['endpoint']
    address = ipaddress.IPv4Address(endpoint['ip'])
    port = uint(endpoint['port'], 'liteserver port', 1, 65535)
    required = {'external.global.config.json', 'test-wallets.tar.gz', 'remote-load.env',
                'import-native-client.sh', 'run-remote-load.sh'}
    if image['included']:
        required.add('generator-image.tar')
    files = manifest['files']
    require(isinstance(files, dict) and set(files) == required, 'Bundle file inventory is incomplete or unexpected')
    print('Verifying exported files and checksums...', flush=True)
    for name in sorted(required):
        path = bundle / name
        metadata = files[name]
        require(path.is_file() and not path.is_symlink(), f'Missing regular bundle file: {name}')
        require(type(metadata.get('size')) is int and metadata['size'] >= 0, f'Invalid size for {name}')
        require(path.stat().st_size == metadata['size'], f'Size mismatch: {name}')
        require(isinstance(metadata.get('sha256'), str) and re.fullmatch(r'[0-9a-f]{64}', metadata['sha256']),
                f'Invalid checksum for {name}')
        require(checksum(path) == metadata['sha256'], f'Checksum mismatch: {name}')
    config = json.loads((bundle / 'external.global.config.json').read_text())
    require(isinstance(config.get('liteservers'), list) and len(config['liteservers']) == 1,
            'Expected exactly one liteserver')
    server = config['liteservers'][0]
    signed_ip = int(address) if int(address) < 2**31 else int(address) - 2**32
    require(type(server.get('ip')) is int and server['ip'] == signed_ip and server.get('port') == port,
            'Exported endpoint differs from its manifest')
    require(len(base64.b64decode(server['id']['key'], validate=True)) == 32, 'Invalid liteserver public key')
    require(len(base64.b64decode(config['validator']['zero_state']['root_hash'], validate=True)) == 32,
            'Invalid zero-state signing domain')
    env = parse_env(bundle / 'remote-load.env')
    expected_env = {'NATIVE_LOAD_GLOBAL_CONFIG': '/client/global.config.json',
                    'NATIVE_LOAD_WALLET_DIR': '/client/wallets',
                    'NATIVE_LOAD_PAYMENT_LANE_MANIFEST': '/client/wallets/native-payment-lanes.manifest',
                    'NATIVE_LOAD_SOURCES': str(sources), 'NATIVE_LOAD_SOURCE_OFFSET': str(offset),
                    'NATIVE_PAYMENT_LANES_ENABLED': '1', 'NATIVE_PAYMENT_LANE_DEPTH': str(depth),
                    'NATIVE_LOAD_PAYMENT_LANE_DEPTH': str(depth), 'NATIVE_LOAD_NATIVE_TRANSFER_RUNS': '1'}
    for key, value in expected_env.items():
        require(env.get(key) == value, f'Client preset differs from manifest: {key}')
    require(env.get('REMOTE_LOAD_IMAGE', image_id) == image_id, 'Client preset uses a different image')
    workers = int(env.get('NATIVE_LOAD_WORKERS', '0'))
    signers = int(env.get('NATIVE_LOAD_SIGNERS', '0'))
    require(1 <= workers <= min(sources, signers, 256), 'Invalid worker/signer count for exported sources')
    expected_wallets = {'native-payment-lanes.manifest'}
    for index in range(offset, offset + sources):
        expected_wallets.update((f'source-{index}.pk', f'source-{index}.pub', f'source-{index}.addr',
                                 f'dest-{index}.pub', f'dest-{index}.addr'))
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=f'.{output.name}.import-', dir=output.parent))
    try:
        wallet_dir = stage / 'client-data' / 'wallets'
        wallet_dir.mkdir(parents=True, mode=0o700)
        print(f'Checking and extracting {sources} selected test-account pairs...', flush=True)
        seen = set()
        with tarfile.open(bundle / 'test-wallets.tar.gz', 'r:gz') as archive:
            for member in archive:
                name = member.name
                require(name in expected_wallets and name not in seen, 'Unexpected or duplicate wallet archive entry')
                require(member.isfile(), 'Wallet archive must contain regular files only')
                limit = 64 * 1024 * 1024 if name == 'native-payment-lanes.manifest' else 4096
                require(0 < member.size <= limit, 'Invalid wallet archive entry size')
                if name.endswith(('.pk', '.pub')):
                    require(member.size == 32, 'Source signing keys and public keys must contain 32 raw bytes')
                stream = archive.extractfile(member)
                require(stream is not None, 'Unreadable wallet archive entry')
                with stream, (wallet_dir / name).open('xb') as target:
                    shutil.copyfileobj(stream, target)
                seen.add(name)
        require(seen == expected_wallets, 'Wallet archive is missing selected source/destination files')
        lines = (wallet_dir / 'native-payment-lanes.manifest').read_text().splitlines()
        header = lines[0].split() if lines else []
        require(len(header) == 4 and header[0] == 'NATIVE_PAYMENT_LANES_MANIFEST_V1', 'Invalid lane manifest header')
        require(int(header[1]) == depth and int(header[2]) == 1 << depth and int(header[3]) >= offset + sources,
                'Lane manifest does not cover the exported topology/source range')
        selected = set()
        for line in lines[1:]:
            if not line.strip() or line.lstrip().startswith('#'):
                continue
            row = line.split()
            require(len(row) == 4 and row[0].isdigit(), 'Malformed lane manifest row')
            index = int(row[0])
            if not offset <= index < offset + sources:
                continue
            require(index not in selected, 'Duplicate selected lane manifest row')
            lane = int(row[1])
            require(lane == index % (1 << depth), 'Lane manifest does not preserve the balanced source assignment')
            for prefix, recorded_hex in [('source', row[2]), ('dest', row[3])]:
                data = (wallet_dir / f'{prefix}-{index}.addr').read_bytes()
                require(len(data) >= 32 and re.fullmatch(r'[0-9a-fA-F]{64}', recorded_hex), 'Invalid lane address')
                public = (wallet_dir / f'{prefix}-{index}.pub').read_bytes()
                require(public == data[:32] and data[:32].hex() == recorded_hex.lower(),
                        'Lane manifest does not match exported public keys and wallet addresses')
                require(data[0] >> (8 - depth) == lane, 'Exported source/destination pair is not in its declared lane')
            selected.add(index)
        require(len(selected) == sources, 'Lane manifest is missing selected source indices')
        require_local_docker()
        local_image = inspect_image(image_id)
        allow_load = args.load_image
        if local_image is None:
            if allow_load is None:
                allow_load = image['included']
                if not args.non_interactive and image['included']:
                    answer = prompt('Load the included prebuilt generator image? (yes/no)', 'yes').lower()
                    require(answer in ('yes', 'y', 'no', 'n'), 'Expected yes or no')
                    allow_load = answer in ('yes', 'y')
            require(allow_load and image['included'],
                    f'Exact generator image is missing: {image_id}. Load it first or export with --include-image.')
            print('Loading the verified generator image...', flush=True)
            subprocess.run(['docker', 'image', 'load', '--input', str(bundle / 'generator-image.tar')], check=True, timeout=3600)
            local_image = inspect_image(image_id)
        require(local_image is not None, 'Docker did not load the expected generator image')
        require(local_image.get('Os') == image['os'] and local_image.get('Architecture') == image['architecture'],
                'Local image platform differs from export metadata')
        shutil.copyfile(bundle / 'external.global.config.json', stage / 'client-data' / 'global.config.json')
        for name in ('remote-load.env', 'run-remote-load.sh', 'import-native-client.sh', 'export-manifest.json'):
            shutil.copyfile(bundle / name, stage / name)
            if name.endswith('.sh'):
                (stage / name).chmod(0o700)
        (stage / 'runtime-image-id.txt').write_text(image_id + '\n')
        require(not output.exists() and not output.is_symlink(), f'Output appeared during import: {output}')
        publish_without_overwrite(stage, output)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    print(f'Client materials installed: {output}')
    print(f'Pinned image: {image_id}')
    print('Run from that directory: bash run-remote-load.sh --connections 10 --duration 600')
    print('Import is complete; load generation has not started.')


def interrupt_import(signum, frame):
    raise KeyboardInterrupt


signal.signal(signal.SIGTERM, interrupt_import)

try:
    install()
except (ValueError, KeyError, TypeError, OSError, tarfile.TarError, subprocess.SubprocessError) as error:
    print(f'Import failed: {error}', file=sys.stderr)
    sys.exit(1)
except KeyboardInterrupt:
    print('Import interrupted.', file=sys.stderr)
    sys.exit(130)
PY
