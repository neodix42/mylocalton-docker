#!/usr/bin/env bash
# Fetch the current configured TON registry image, then build local wrappers from one immutable digest.
# Preparation never starts or recreates containers. Keep benchmark runs on the resulting image IDs.
set -euo pipefail
command -v python3 >/dev/null 2>&1 || { echo 'python3 is required' >&2; exit 2; }
exec python3 - "${BASH_SOURCE[0]}" "$@" <<'PYPREPARE'
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SCRIPT = Path(sys.argv.pop(1)).resolve()
ROOT = SCRIPT.parent
REVISION = re.compile(r'[0-9a-f]{40}')
IMAGE_ID = re.compile(r'sha256:[0-9a-f]{64}')


def require(ok, message):
    if not ok:
        raise ValueError(message)


def run(arguments, env=None, capture=True, timeout=120):
    result = subprocess.run(arguments, cwd=ROOT, env=env, text=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None, timeout=timeout)
    if result.returncode:
        detail = (result.stderr or result.stdout or '').strip()
        raise ValueError(f'{arguments[0]} {arguments[1]} failed' + (f': {detail}' if detail else ''))
    return result.stdout.strip() if capture else ''


def inspect(reference):
    rows = json.loads(run(['docker', 'image', 'inspect', reference]))
    require(isinstance(rows, list) and len(rows) == 1 and isinstance(rows[0], dict),
            f'expected exactly one local image for {reference}')
    record = rows[0]
    require(IMAGE_ID.fullmatch(str(record.get('Id', ''))), f'invalid image ID for {reference}')
    labels = (record.get('Config') or {}).get('Labels') or {}
    revision = labels.get('org.opencontainers.image.revision', '')
    require(isinstance(revision, str) and REVISION.fullmatch(revision),
            f'{reference} has no full org.opencontainers.image.revision label; '
            'use the TON image published by the updated GitHub workflow')
    require(record.get('Os') == 'linux', f'{reference} must be a Linux image')
    require(isinstance(record.get('Architecture'), str) and record['Architecture'],
            f'{reference} has no architecture metadata')
    return record, revision


def local_docker():
    context = os.environ.get('DOCKER_CONTEXT')
    if context:
        endpoint = run(['docker', 'context', 'inspect', '--format', '{{.Endpoints.docker.Host}}', context])
    elif os.environ.get('DOCKER_HOST'):
        endpoint = os.environ['DOCKER_HOST']
    else:
        context = run(['docker', 'context', 'show'])
        endpoint = run(['docker', 'context', 'inspect', '--format', '{{.Endpoints.docker.Host}}', context])
    require(endpoint.startswith('unix://'),
            'a local Docker daemon is required; select a local context (DOCKER_CONTEXT takes precedence over DOCKER_HOST)')
    require(run(['docker', 'info', '--format', '{{.OSType}}']) == 'linux', 'Docker must run Linux containers')


def main():
    parser = argparse.ArgumentParser(prog=SCRIPT.name,
        description='Pull the current configured TON registry image and build the local genesis/generator images '
                    'from its immutable digest. Never start containers or generate traffic.')
    parser.add_argument('--env-file', default=str(ROOT / '.env'), help='Compose environment file (default: repository/.env)')
    parser.add_argument('--services', nargs='+', choices=('genesis', 'native-load-generator'),
                        default=['genesis', 'native-load-generator'], help='services to build (default: both)')
    parser.add_argument('--receipt', default=str(ROOT / '.native-images.json'), help='JSON preparation receipt path')
    parser.add_argument('--expected-revision', help='require this 40-character TON revision before building (used by export)')
    args = parser.parse_args()
    require(sys.platform.startswith('linux'), 'this helper requires Linux')
    require(shutil.which('docker'), 'docker with the Compose plugin is required')
    require(args.expected_revision is None or REVISION.fullmatch(args.expected_revision),
            '--expected-revision must be a full lowercase 40-character Git revision')
    env_file = Path(args.env_file).expanduser().resolve()
    require(env_file.is_file(), f'Compose environment file does not exist: {env_file}')
    receipt_path = Path(args.receipt).expanduser().absolute()
    require(receipt_path.parent.is_dir(), f'receipt parent directory does not exist: {receipt_path.parent}')
    require(receipt_path != env_file and not receipt_path.is_dir(), 'receipt must be a file separate from the environment file')
    services = list(dict.fromkeys(args.services))
    local_docker()
    compose = ['docker', 'compose', '--project-directory', str(ROOT), '--env-file', str(env_file),
               '--profile', 'native-load-generator']
    config = json.loads(run(compose + ['config', '--format', 'json']))
    service_config = config.get('services', {})
    bases, references = set(), {}
    for service in services:
        item = service_config.get(service, {})
        build = item.get('build') or {}
        require(isinstance(build, dict), f'{service} must have a local Compose build definition')
        arguments = build.get('args') or {}
        require(isinstance(arguments, dict), f'{service} build arguments must be a mapping')
        repository = arguments.get('TON_IMAGE') or 'ghcr.io/corton-nommander/ton'
        branch = arguments.get('TON_BRANCH') or 'master'
        require(isinstance(repository, str) and re.fullmatch(r'[a-z0-9][a-z0-9._:/-]*', repository)
                and '@' not in repository, f'invalid TON_IMAGE for {service}')
        require(isinstance(branch, str) and re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}', branch),
                f'invalid TON_BRANCH image tag for {service}')
        bases.add((repository, f'{repository}:{branch}'))
        reference = item.get('image')
        require(isinstance(reference, str) and reference and not reference.startswith('-')
                and not any(c.isspace() for c in reference), f'{service} needs an explicit local image reference')
        references[service] = reference
    require(len(bases) == 1, 'genesis and generator must use the same configured TON image and tag')
    require(len(set(references.values())) == len(references), 'each derived service needs a distinct image reference')
    repository, base_reference = next(iter(bases))
    print(f'Pulling current TON image: {base_reference}', flush=True)
    try:
        run(['docker', 'pull', base_reference], capture=False, timeout=3600)
    except (ValueError, subprocess.TimeoutExpired) as error:
        raise ValueError(f'could not pull {base_reference}. Ensure the GitHub TON image workflow has succeeded '
                         'for this branch and the registry package is readable; no local fallback was used') from error
    base, revision = inspect(base_reference)
    digests = [entry for entry in base.get('RepoDigests', [])
               if isinstance(entry, str) and entry.startswith(repository + '@')
               and IMAGE_ID.fullmatch(entry.rsplit('@', 1)[-1])]
    require(len(set(digests)) == 1, f'{base_reference} has no unambiguous registry digest after pull')
    digest = digests[0]
    pinned, pinned_revision = inspect(digest)
    require(pinned['Id'] == base['Id'] and pinned_revision == revision,
            'registry digest does not resolve to the pulled TON image')
    if args.expected_revision is not None:
        require(revision == args.expected_revision,
                f'latest registry TON revision {revision} differs from running genesis {args.expected_revision}; '
                'run start-native-genesis.sh before exporting, then wait for genesis to be healthy')
    print(f'Building {", ".join(services)} from {digest}\nTON revision: {revision}', flush=True)
    build_env = dict(os.environ, TON_BASE_IMAGE=digest, TON_BUILD_PULL='true')
    run(compose + ['build', '--pull', '--build-arg', f'TON_BASE_IMAGE={digest}', *services],
        env=build_env, capture=False, timeout=7200)
    receipt = {'schema': 'native-images-v1',
               'created_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
               'base': {'reference': base_reference, 'digest': digest, 'id': base['Id'],
                        'revision': revision, 'architecture': base['Architecture'], 'os': base['Os']},
               'services': {}}
    for service, reference in references.items():
        derived, derived_revision = inspect(reference)
        require(derived_revision == revision, f'{service} image revision does not match the pulled TON image')
        require(derived['Architecture'] == base['Architecture'], f'{service} architecture differs from the TON base')
        receipt['services'][service] = {'reference': reference, 'id': derived['Id'], 'revision': derived_revision}
    final_base, final_revision = inspect(digest)
    require(final_base['Id'] == base['Id'] and final_revision == revision,
            'TON base changed during preparation; refusing to publish a receipt')
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', dir=receipt_path.parent,
                                         prefix='.' + receipt_path.name + '-', delete=False) as output:
            temporary = Path(output.name)
            json.dump(receipt, output, indent=2)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, receipt_path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print(f'Prepared current registry revision {revision}. Receipt: {receipt_path}', flush=True)


try:
    main()
except (ValueError, OSError, subprocess.SubprocessError, TypeError, KeyError) as error:
    print(f'Error: {error}', file=sys.stderr)
    sys.exit(1)
except KeyboardInterrupt:
    print('Image preparation interrupted; no services were started.', file=sys.stderr)
    sys.exit(130)
PYPREPARE
