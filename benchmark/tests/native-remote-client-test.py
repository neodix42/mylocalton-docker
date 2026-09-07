#!/usr/bin/env python3
"""Offline subprocess integration: fake Docker on PATH; only temporary fixtures."""
import base64
import errno
import hashlib
import io
import ipaddress
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import tarfile
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
REMOTE = ROOT / 'benchmark' / 'remote'
IMAGE_ID = 'sha256:' + 'a' * 64
IMAGE_REF = 'native-client:offline-fixture'
CONFIGURED_IMAGE_REF = 'native-client:compose-fixture'
BUILT_IMAGE_ID = 'sha256:' + 'e' * 64
BASE_REFERENCE = 'ghcr.io/corton-nommander/ton:master'
BASE_DIGEST = 'ghcr.io/corton-nommander/ton@sha256:' + '9' * 64
BASE_IMAGE_ID = 'sha256:' + '8' * 64
SOURCE_REVISION = 'c' * 40
SOURCE_OFFSET, SOURCES, ALL_SOURCES = 4, 12, 24

FAKE_DOCKER = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time
root = pathlib.Path(os.environ['FAKE_DOCKER_ROOT'])
args = sys.argv[1:]
with (root/'calls.jsonl').open('a') as out: out.write(json.dumps(args)+'\n')
scenario = json.loads((root/'scenario.json').read_text())
image_id = 'sha256:' + ('b' if scenario.get('wrong_image') else ('e' if scenario.get('build_new_id') and (root/'built').exists() else 'a'))*64
configured_image='native-client:compose-fixture'
base_reference='ghcr.io/corton-nommander/ton:master'
base_digest='ghcr.io/corton-nommander/ton@sha256:'+'9'*64
base_id='sha256:'+'8'*64
revision='c'*40
if args[:1]==['pull']:
 if scenario.get('pull_fails'):raise SystemExit('synthetic registry pull failure')
 (root/'pulled').touch();print('Digest: '+base_digest.split('@',1)[1]);sys.exit()
if args[:1]==['compose']:
 with (root/'compose-environment.jsonl').open('a') as out:out.write(json.dumps({'command':args,'TON_BUILD_PULL':os.environ.get('TON_BUILD_PULL'),'TON_BASE_IMAGE':os.environ.get('TON_BASE_IMAGE')})+'\n')
 if 'config' in args:
  build_args={'TON_IMAGE':'ghcr.io/corton-nommander/ton','TON_BRANCH':'master','TON_BASE_IMAGE':os.environ.get('TON_BASE_IMAGE',base_reference)}
  services={'genesis':{'image':'validator:compose-fixture','build':{'args':dict(build_args)}},'native-load-generator':{'image':configured_image,'build':{'args':dict(build_args)}}}
  if scenario.get('different_service_base'):services['native-load-generator']['build']['args']['TON_IMAGE']='ghcr.io/other/ton'
  print(json.dumps({'services':services}));sys.exit()
 if 'build' in args:
  if scenario.get('build_fails'):raise SystemExit('synthetic generator build failure')
  (root/'built').touch();(root/'built-services.json').write_text(json.dumps([x for x in args[args.index('build')+1:] if x in ('genesis','native-load-generator')]))
  print('offline generator build complete');sys.exit()
 if 'up' in args:print('offline genesis start');sys.exit()
 raise SystemExit('unexpected Compose action: '+repr(args))
image = {'Id':image_id,'Architecture':'amd64','Os':'linux','Config':{'Labels':{'org.opencontainers.image.revision':'c'*40}}}
if args[:2] == ['image','inspect'] or args[:1] == ['inspect']:
 if args[:2] == ['image','inspect']:
  if scenario.get('image_inspect_error'):raise SystemExit('permission denied accessing Docker daemon')
  if scenario.get('missing_image') or (scenario.get('image_missing_before_load') and not (root/'loaded').exists()):raise SystemExit('Error response from daemon: No such image: '+args[-1])
  if args[-1]==configured_image and scenario.get('missing_configured_image') and not (root/'built').exists():raise SystemExit('Error response from daemon: No such image: '+args[-1])
  if args[-1].startswith('sha256:') and not scenario.get('wrong_image'):image['Id']=args[-1]
  if args[-1] in (base_reference,base_digest):
   image={'Id':base_id,'Architecture':'amd64','Os':'linux','RepoDigests':[base_digest],'Config':{'Labels':{'org.opencontainers.image.revision':scenario.get('base_revision',revision)}}}
   if scenario.get('missing_base_digest'):image['RepoDigests']=[]
   if scenario.get('base_digest_identity_mismatch') and args[-1]==base_digest:image['Id']='sha256:'+'7'*64
  elif args[-1] in (configured_image,'validator:compose-fixture') and (root/'built').exists():
   image['Config']['Labels']['org.opencontainers.image.revision']=scenario.get('derived_revision',revision)
  print(json.dumps([image])); sys.exit()
 container = {'Id':'d'*64,'Name':'/fixture-genesis','Image':'sha256:'+'a'*64,'RestartCount':0,
  'State':{'Running':True,'ExitCode':0,'StartedAt':'2026-09-07T00:00:00Z'},
  'Config':{'Image':'native-client:offline-fixture','Env':['NATIVE_PAYMENT_LANE_DEPTH=2']}}
 runs = json.loads((root/'runs.json').read_text()) if (root/'runs.json').exists() else []
 for run in runs:
  if args[-1] in (run['name'],run['id']):
   container = run['inspect']
   container['State']['Running'] = False
   container['State']['ExitCode'] = scenario.get('container_exit',0)
 if '--format' in args or '-f' in args:
  form = args[(args.index('--format') if '--format' in args else args.index('-f'))+1]
  if 'Running' in form: print('true' if container['State']['Running'] else 'false')
  elif 'ExitCode' in form: print(container['State']['ExitCode'])
  else: print(json.dumps(container))
 else: print(json.dumps([container]))
 sys.exit()
if args[:2] == ['image','save']:
 out = args[args.index('--output')+1] if '--output' in args else args[args.index('-o')+1]
 pathlib.Path(out).write_bytes(b'offline-image-archive\n'); sys.exit()
if args[:2] == ['image','load'] or args[:1] == ['load']:
 (root/'loaded').touch();print('Loaded image: native-client:offline-fixture'); sys.exit()
if args[:1] == ['info']:
 print('linux'); sys.exit()
if args[:2] == ['context','show']:
 print('default');sys.exit()
if args[:2] == ['context','inspect']:
 print('tcp://remote.invalid:2375' if scenario.get('remote_context') else 'unix:///var/run/docker.sock'); sys.exit()
if args[:1] == ['version']:
 print('offline'); sys.exit()
if args[:1] == ['exec']:
 tail=args[1:]
 while tail and tail[0].startswith('-'): tail.pop(0)
 tail.pop(0) # selected fixture container
 if tail[0] != 'python3': raise SystemExit('fake docker refuses non-Python exec')
 stdin=sys.stdin.buffer.read() if '-i' in args else None
 tail=[x.replace('/usr/share/data',str(root/'data')).replace('/var/ton-work/db/native-spam/wallets',str(root/'data'/'test-wallets')) for x in tail]
 if stdin: stdin=stdin.replace(b'/usr/share/data',str(root/'data').encode()).replace(b'/var/ton-work/db/native-spam/wallets',str(root/'data'/'test-wallets').encode())
 proc=subprocess.run([sys.executable,*tail[1:]],input=stdin)
 sys.exit(proc.returncode)
if args[:1] == ['run']:
 if scenario.get('run_name_collision'):sys.exit(125)
 def flag(k,default=None):
  if k in args:return args[args.index(k)+1]
  return next((x.split('=',1)[1] for x in args if x.startswith(k+'=')),default)
 labels={}
 for i,arg in enumerate(args[:-1]):
  if arg=='--label':
   k,v=args[i+1].split('=',1);labels[k]=v
 env={}
 for line in pathlib.Path(flag('--env-file')).read_text().splitlines():
  if line and not line.startswith('#'):
   k,v=line.split('=',1);env[k]=v
 runs=json.loads((root/'runs.json').read_text()) if (root/'runs.json').exists() else []
 ident=format(len(runs)+1,'064x');name=flag('--name')
 run={'id':ident,'name':name,'env':env,'inspect':{'Id':ident,'Name':'/'+name,
  'Image':image_id,'Config':{'Image':image_id,'Env':[k+'='+v for k,v in env.items()],'Labels':labels},
  'RestartCount':0,'State':{'Running':False,'ExitCode':0,'OOMKilled':False,'StartedAt':'2026-09-07T00:00:00Z'},
  'HostConfig':{'NetworkMode':'host'}}}
 runs.append(run);(root/'runs.json').write_text(json.dumps(runs));print(ident);sys.exit()
if args[:1] == ['wait']:
 if scenario.get('wait_for_stop'):
  end=time.monotonic()+20
  while not (root/'stopped').exists() and time.monotonic()<end:time.sleep(.02)
 print(scenario.get('container_exit',0));sys.exit()
if args[:1] in (['stop'],['kill']):
 (root/'stopped').touch();print(args[-1]);sys.exit()
if args[:1] == ['logs']:
 runs=json.loads((root/'runs.json').read_text());run=next(x for x in runs if args[-1] in (x['name'],x['id']))
 fixture=root/'final.json'
 if not fixture.exists():raise SystemExit('runner final fixture not installed')
 final=json.loads(fixture.read_text());env=run['env']
 for field,key in {'configured_connections':'NATIVE_LOAD_CONNECTIONS','configured_workers':'NATIVE_LOAD_WORKERS',
   'configured_signers':'NATIVE_LOAD_SIGNERS','configured_sources':'NATIVE_LOAD_SOURCES',
   'adaptive_initial_cwnd':'NATIVE_LOAD_ADAPTIVE_INITIAL_CWND'}.items():final[field]=int(env[key])
 if scenario.get('incomplete'):
  final['run_incomplete_reasons']=['canonical_backlog_after_drain'];final['canonical_backlog_after_drain']=16
 if scenario.get('capacity_rejected'):
  final['chain_capacity_valid']=False
  final['invalid_reasons']=['offered_load_not_above_canonical_throughput']
 final.update(scenario.get('final_overrides',{}))
 print(json.dumps(final));sys.exit()
raise SystemExit('Unexpected fake docker command: '+repr(args))
'''


def sha(data):
    return hashlib.sha256(data).hexdigest()


class RemoteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='native-remote-offline-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.fake = self.root / 'fake'
        self.fake.mkdir()
        self.data = self.fake / 'data'
        self.wallets = self.data / 'test-wallets'
        self.wallets.mkdir(parents=True)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        executable = self.bin / 'docker'
        executable.write_text(FAKE_DOCKER)
        executable.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ.get('PATH',''),
                        FAKE_DOCKER_ROOT=str(self.fake), DOCKER_HOST='unix:///var/run/docker.sock',
                        PYTHONDONTWRITEBYTECODE='1')
        self.env.pop('DOCKER_CONTEXT',None)
        self.scenario()
        enc = lambda x: base64.b64encode(bytes([x])*32).decode()
        self.config = {'@type':'config.global', 'validator':{'@type':'validator.config.global',
             'zero_state':{'workchain':-1,'shard':-9223372036854775808,'seqno':0,
                           'root_hash':enc(1),'file_hash':enc(2)}},
             'liteservers':[{'ip':2130706433,'port':40004,'id':{'@type':'pub.ed25519','key':enc(3)}}],
             'dht':{'@type':'dht.config.global','k':6,'a':3,'static_nodes':{'nodes':[]}}}
        (self.data/'global.config.json').write_text(json.dumps(self.config))
        rows=[f'NATIVE_PAYMENT_LANES_MANIFEST_V1 2 4 {ALL_SOURCES}']
        for i in range(ALL_SOURCES):
            addresses={}
            for kind in ['source','dest']:
                address=bytes([(i%4)<<6])+hashlib.sha256(f'{kind}-{i}'.encode()).digest()[1:]
                addresses[kind]=address
                (self.wallets/f'{kind}-{i}.addr').write_bytes(address)
                (self.wallets/f'{kind}-{i}.pub').write_bytes(address)
                (self.wallets/f'{kind}-{i}.pk').write_bytes(hashlib.sha256(f'private-{kind}-{i}'.encode()).digest())
            rows.append(f'{i} {i%4} {addresses["source"].hex()} {addresses["dest"].hex()}')
        (self.wallets/'native-payment-lanes.manifest').write_text('\n'.join(rows)+'\n')
        (self.wallets/'private-unrelated.key').write_text('must never export')
        self.bundle=self.root/'bundle'
        self.client=self.root/'client'
        self.fixture_repo=self.root/'repository'
        self.fixture_remote=self.fixture_repo/'benchmark/remote'
        self.fixture_remote.mkdir(parents=True)
        for name in ['export-native-client.sh','import-native-client.sh','run-remote-load.sh','native-remote-load.env']:
            shutil.copy2(REMOTE/name,self.fixture_remote/name)
        (self.fixture_repo/'docker-compose.yaml').write_text('services:\n  native-load-generator:\n    image: '+CONFIGURED_IMAGE_REF+'\n')
        (self.fixture_repo/'.env.physical').write_text('NATIVE_LOAD_IMAGE='+CONFIGURED_IMAGE_REF+'\n')
        (self.fixture_repo/'.env').write_text('NATIVE_LOAD_IMAGE='+CONFIGURED_IMAGE_REF+'\nTON_IMAGE=ghcr.io/corton-nommander/ton\nTON_BRANCH=master\n')
        for name in ['prepare-native-images.sh','start-native-genesis.sh']:
            if (ROOT/name).is_file():shutil.copy2(ROOT/name,self.fixture_repo/name)

    def scenario(self, **settings):
        (self.fake/'scenario.json').write_text(json.dumps(settings))

    def calls(self):
        path=self.fake/'calls.jsonl'
        return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []

    def invoke(self, script, *args, success=True):
        result=subprocess.run([str(REMOTE/script),*map(str,args)],env=self.env,text=True,
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20)
        if success:
            self.assertEqual(result.returncode,0,result.stdout+'\n'+result.stderr)
        else:
            self.assertNotEqual(result.returncode,0,result.stdout+'\n'+result.stderr)
        return result

    def interact_no_args(self, script, exchanges):
        # pty.fork supplies a controlling terminal: piping stdin alone does not
        # exercise scripts which explicitly read and write /dev/tty.
        pid, terminal = pty.fork()
        if pid == 0:
            try:
                os.chdir(self.root)
                os.execve(str(script), [str(script)], self.env)
            except BaseException:
                os._exit(127)
        transcript = bytearray()
        pending, cursor, status = 0, 0, None
        deadline = time.monotonic() + 20
        try:
            while time.monotonic() < deadline:
                readable, _, _ = select.select([terminal], [], [], .05)
                if readable:
                    try:
                        chunk = os.read(terminal, 16384)
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                        chunk = b''
                    transcript.extend(chunk)
                while pending < len(exchanges):
                    prompt, answer = exchanges[pending]
                    found = transcript.find(prompt.encode(), cursor)
                    if found < 0:
                        break
                    os.write(terminal, (answer + '\n').encode())
                    cursor = found + len(prompt.encode())
                    pending += 1
                if status is None:
                    done, result = os.waitpid(pid, os.WNOHANG)
                    if done:
                        status = result
                if status is not None and (not readable or not chunk):
                    break
            self.assertIsNotNone(status, 'interactive script exceeded 20s:\n' + transcript.decode(errors='replace'))
            self.assertEqual(pending, len(exchanges), 'missing interactive prompt:\n' + transcript.decode(errors='replace'))
            self.assertEqual(os.waitstatus_to_exitcode(status), 0, transcript.decode(errors='replace'))
            return transcript.decode(errors='replace')
        finally:
            if status is None:
                try:
                    os.killpg(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                os.waitpid(pid, 0)
            os.close(terminal)

    def export(self, *args, success=True):
        return self.invoke('export-native-client.sh','--non-interactive','--server-ip','203.0.113.7',
             '--port','41004','--container','fixture-genesis','--sources',SOURCES,
             '--source-offset',SOURCE_OFFSET,'--output',self.bundle,'--image',IMAGE_REF,*args,success=success)

    def export_detected_image(self, *args, success=True):
        return self.invoke(self.fixture_remote/'export-native-client.sh','--non-interactive',
                           '--server-ip','203.0.113.7','--port','41004','--container','fixture-genesis',
                           '--sources',SOURCES,'--source-offset',SOURCE_OFFSET,'--output',self.bundle,
                           '--no-image',*args,success=success)

    def compose_calls(self, action):
        return [call for call in self.calls() if call[:1]==['compose'] and action in call]

    def assert_only_generator_builds(self):
        builds=self.compose_calls('build')
        self.assertEqual(len(builds),1)
        self.assertEqual(builds[0][-1],'native-load-generator')
        environments=[json.loads(line) for line in (self.fake/'compose-environment.jsonl').read_text().splitlines()]
        self.assertTrue(environments)
        builds_environment=[row for row in environments if 'build' in row['command']]
        self.assertTrue(all(row['TON_BUILD_PULL']=='true' and row['TON_BASE_IMAGE']==BASE_DIGEST for row in builds_environment))
        self.assertEqual(builds[0][builds[0].index('--build-arg')+1],'TON_BASE_IMAGE='+BASE_DIGEST)
        pulls=[call for call in self.calls() if call[:1]==['pull']]
        self.assertEqual(pulls,[['pull',BASE_REFERENCE]])
        self.assertLess(self.calls().index(pulls[0]),self.calls().index(builds[0]))
        for call in self.calls():
            self.assertFalse(any(token in call for token in ['up','restart','start','run','stop','kill']))
            if call[:1]==['compose']:
                self.assertEqual(call[call.index('--project-directory')+1],str(self.fixture_repo))
                if '-f' in call:self.assertEqual(call[call.index('-f')+1],str(self.fixture_repo/'docker-compose.yaml'))
                self.assertEqual(call[call.index('--profile')+1],'native-load-generator')
                self.assertNotIn('genesis',call)

    def import_bundle(self, *args, success=True):
        return self.invoke('import-native-client.sh','--non-interactive','--bundle',self.bundle,
                           '--output',self.client,*args,success=success)

    def rewrite_inventory(self, name):
        path=self.bundle/'export-manifest.json'; manifest=json.loads(path.read_text())
        data=(self.bundle/name).read_bytes()
        manifest['files'][name]={'sha256':sha(data),'size':len(data)}
        path.write_text(json.dumps(manifest))

    def test_detected_existing_image_is_refreshed_from_registry(self):
        self.scenario(build_new_id=True)
        self.export_detected_image()
        manifest=json.loads((self.bundle/'export-manifest.json').read_text())
        self.assertEqual(manifest['image']['reference'],CONFIGURED_IMAGE_REF)
        self.assertEqual(manifest['image']['id'],BUILT_IMAGE_ID)
        configs=self.compose_calls('config')
        self.assertTrue(configs)
        for call in configs:
            self.assertEqual(call[call.index('--project-directory')+1],str(self.fixture_repo))
            if '-f' in call:self.assertEqual(call[call.index('-f')+1],str(self.fixture_repo/'docker-compose.yaml'))
            self.assertEqual(call[call.index('--profile')+1],'native-load-generator')
            self.assertEqual(call[call.index('--format')+1],'json')
            self.assertTrue(Path(call[call.index('--env-file')+1]).is_absolute())
        self.assert_only_generator_builds()
        self.assertFalse(any(call[:1] in (['run'],['build']) for call in self.calls()))

    def test_missing_configured_image_builds_generator_only_and_exports_new_identity(self):
        self.scenario(missing_configured_image=True,build_new_id=True)
        self.export_detected_image()
        self.assert_only_generator_builds()
        self.assertEqual(json.loads((self.bundle/'export-manifest.json').read_text())['image']['id'],BUILT_IMAGE_ID)
        self.assertTrue((self.fake/'built').exists())

    def test_force_build_rebuilds_existing_configured_image(self):
        self.env['TON_BUILD_PULL']='true'
        self.scenario(build_new_id=True)
        self.export_detected_image('--build-image')
        self.assert_only_generator_builds()
        self.assertEqual(json.loads((self.bundle/'export-manifest.json').read_text())['image']['id'],BUILT_IMAGE_ID)

    def test_strict_no_build_rejects_missing_configured_image_without_partial_export(self):
        self.scenario(missing_configured_image=True)
        self.export_detected_image('--no-build-image',success=False)
        self.assertEqual(self.compose_calls('build'),[])
        self.assertFalse(self.bundle.exists())
        self.assertEqual(list(self.root.glob('.bundle*')),[])

    def test_failed_generator_build_cleans_up_without_export(self):
        self.scenario(missing_configured_image=True,build_fails=True)
        self.export_detected_image(success=False)
        self.assert_only_generator_builds()
        self.assertFalse(self.bundle.exists())
        self.assertEqual(list(self.root.glob('.bundle*')),[])
        self.assertFalse((self.fake/'built').exists())

    def test_custom_env_file_is_preserved_for_config_and_build(self):
        custom=self.root/'custom config'/'client.env'
        custom.parent.mkdir();custom.write_text('NATIVE_LOAD_IMAGE='+CONFIGURED_IMAGE_REF+'\n')
        self.scenario(missing_configured_image=True)
        self.export_detected_image('--env-file',custom)
        self.assert_only_generator_builds()
        calls=self.compose_calls('config')+self.compose_calls('build')
        self.assertTrue(calls)
        for call in calls:
            self.assertEqual(call[call.index('--env-file')+1],str(custom.resolve()))

    def test_explicit_missing_image_never_falls_back_to_compose_or_build(self):
        self.scenario(missing_image=True)
        self.export('--no-image',success=False)
        self.assertFalse(any(call[:1]==['compose'] for call in self.calls()))
        self.assertFalse(self.bundle.exists())

    def test_image_inspection_permission_error_never_triggers_a_build(self):
        self.scenario(image_inspect_error=True)
        self.export_detected_image(success=False)
        self.assertEqual(self.compose_calls('build'),[])
        self.assertFalse(self.bundle.exists())

    def test_explicit_existing_image_does_not_require_a_compose_env_file(self):
        self.export('--no-image','--env-file',self.root/'does-not-exist.env')
        self.assertFalse(any(call[:1]==['compose'] for call in self.calls()))
        self.assertEqual(json.loads((self.bundle/'export-manifest.json').read_text())['image']['reference'],IMAGE_REF)

    def test_explicit_image_and_force_build_are_rejected_without_compose(self):
        self.export('--no-image','--build-image',success=False)
        self.assertFalse(any(call[:1]==['compose'] for call in self.calls()))
        self.assertFalse(self.bundle.exists())

    def test_remote_docker_context_prevents_automatic_generator_build(self):
        self.scenario(missing_configured_image=True,remote_context=True)
        self.env['DOCKER_CONTEXT']='remote-context-fixture'
        self.export_detected_image(success=False)
        self.assertEqual(self.compose_calls('build'),[])
        self.assertFalse(self.bundle.exists())
        self.assertFalse(any(call[:1] in (['run'],['pull']) for call in self.calls()))

    def test_no_argument_exporter_prompts_on_controlling_terminal(self):
        transcript = self.interact_no_args(self.fixture_remote/'export-native-client.sh', [
            ('Server A IPv4 address reachable from B', '203.0.113.7'),
            ('Liteserver TCP port', '41004'),
            ('Source validator container', 'fixture-genesis'),
            ('Number of source accounts', str(SOURCES)),
            ('First source index', str(SOURCE_OFFSET)),
            ('New export directory', str(self.bundle)),
            ('Include the prebuilt generator image? yes/no', 'no'),
        ])
        manifest=json.loads((self.bundle/'export-manifest.json').read_text())
        self.assertEqual(manifest['endpoint'], {'ip':'203.0.113.7','port':41004})
        self.assertEqual(manifest['wallets']['source_offset'], SOURCE_OFFSET)
        self.assertEqual(manifest['wallets']['sources'], SOURCES)
        self.assertEqual(manifest['image']['id'], IMAGE_ID)
        self.assertFalse(manifest['image']['included'])
        self.assertEqual(manifest['image']['reference'],CONFIGURED_IMAGE_REF)
        self.assertNotIn('Existing local generator image',transcript)
        self.assertFalse((self.bundle/'generator-image.tar').exists())
        for name in ('import-native-client.sh','run-remote-load.sh'):
            self.assertEqual((self.bundle/name).stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.bundle/'test-wallets.tar.gz').stat().st_mode & 0o777, 0o600)
        self.assertIn(str(self.bundle), transcript)

    def test_no_argument_copied_importer_prompts_and_installs_selected_output(self):
        self.export('--include-image')
        self.scenario(image_missing_before_load=True)
        transcript = self.interact_no_args(self.bundle/'import-native-client.sh', [
            # Accept the copied helper's own directory as its bundle default.
            ('Export bundle directory', ''),
            ('New client directory', str(self.client)),
            ('Load the included prebuilt generator image? (yes/no)', 'yes'),
        ])
        self.assertIn(str(self.bundle), transcript)
        self.assertEqual((self.client/'runtime-image-id.txt').read_text().strip(), IMAGE_ID)
        self.assertEqual((self.client/'client-data/global.config.json').read_bytes(),
                         (self.bundle/'external.global.config.json').read_bytes())
        self.assertEqual((self.client/f'client-data/wallets/source-{SOURCE_OFFSET}.pk').read_bytes(),
                         (self.wallets/f'source-{SOURCE_OFFSET}.pk').read_bytes())
        self.assertEqual((self.client/'run-remote-load.sh').stat().st_mode & 0o777, 0o700)
        self.assertTrue(any(c[:2]==['image','load'] for c in self.calls()))
        self.assertFalse(any(c[:1]==['run'] for c in self.calls()))

    def test_rehashed_archive_rejects_wrong_public_key_size_or_address(self):
        for mutation in ('short_public_key', 'mismatched_public_key'):
            with self.subTest(mutation=mutation):
                if self.bundle.exists():
                    shutil.rmtree(self.bundle)
                self.export('--no-image')
                path=self.bundle/'test-wallets.tar.gz'
                with tarfile.open(path) as archive:
                    entries=[(m,archive.extractfile(m).read()) for m in archive]
                with tarfile.open(path,'w:gz') as archive:
                    for member, data in entries:
                        if member.name==f'source-{SOURCE_OFFSET}.pub':
                            data=data[:-1] if mutation=='short_public_key' else data[:-1]+bytes([data[-1]^1])
                            member.size=len(data)
                        archive.addfile(member,io.BytesIO(data))
                self.rewrite_inventory('test-wallets.tar.gz')
                self.import_bundle('--no-load-image',success=False)
                self.assertFalse(self.client.exists())
                self.assertEqual(list(self.root.glob('.client.import-*')),[])

    def test_export_signed_ipv4_selected_keys_and_immutable_image(self):
        self.export('--include-image')
        exported=json.loads((self.bundle/'external.global.config.json').read_text())
        expected=json.loads(json.dumps(self.config))
        expected['liteservers'][0]['ip']=int(ipaddress.IPv4Address('203.0.113.7'))-(1<<32)
        expected['liteservers'][0]['port']=41004
        self.assertEqual(exported,expected)
        manifest=json.loads((self.bundle/'export-manifest.json').read_text())
        self.assertEqual(manifest['schema'],'native-remote-client-export-v1')
        self.assertEqual(manifest['image']['id'],IMAGE_ID)
        self.assertTrue(manifest['image']['included'])
        self.assertEqual(manifest['wallets']['source_offset'],SOURCE_OFFSET)
        self.assertEqual(manifest['wallets']['sources'],SOURCES)
        for name,entry in manifest['files'].items():
            blob=(self.bundle/name).read_bytes()
            self.assertEqual(entry,{'sha256':sha(blob),'size':len(blob)})
        with tarfile.open(self.bundle/'test-wallets.tar.gz') as archive:
            names={Path(m.name).name for m in archive if m.isfile()}
        for i in range(SOURCE_OFFSET,SOURCE_OFFSET+SOURCES):
            self.assertIn(f'source-{i}.pk',names)
            self.assertIn(f'source-{i}.pub',names)
            self.assertIn(f'dest-{i}.pub',names)
        self.assertNotIn('source-0.pk',names)
        self.assertFalse(any(name.startswith('dest-') and name.endswith('.pk') for name in names))
        self.assertNotIn('private-unrelated.key',names)
        saves=[c for c in self.calls() if c[:2]==['image','save']]
        self.assertEqual(len(saves),1)
        self.assertEqual(saves[0][-1],IMAGE_ID)

    def test_export_no_image_and_end_to_end_preloaded_import(self):
        self.export('--no-image')
        self.assertFalse((self.bundle/'generator-image.tar').exists())
        self.import_bundle('--no-load-image')
        self.assertEqual((self.client/'runtime-image-id.txt').read_text().strip(),IMAGE_ID)
        self.assertEqual(json.loads((self.client/'client-data/global.config.json').read_text()),
                         json.loads((self.bundle/'external.global.config.json').read_text()))
        for i in range(SOURCE_OFFSET,SOURCE_OFFSET+SOURCES):
            self.assertEqual((self.client/f'client-data/wallets/source-{i}.pk').read_bytes(),
                             (self.wallets/f'source-{i}.pk').read_bytes())
        self.assertFalse(any(c[:1] in (['run'],['load']) or c[:2]==['image','load'] for c in self.calls()))

    def test_optional_image_load_uses_verified_archive(self):
        self.export('--include-image')
        self.scenario(image_missing_before_load=True)
        self.import_bundle('--load-image')
        loads=[c for c in self.calls() if c[:2]==['image','load'] or c[:1]==['load']]
        self.assertEqual(len(loads),1)
        self.assertEqual((self.client/'runtime-image-id.txt').read_text().strip(),IMAGE_ID)

    def test_corrupt_checksum_rejected_before_import_or_docker_load(self):
        self.export('--include-image')
        (self.bundle/'test-wallets.tar.gz').write_bytes(b'corrupt')
        self.import_bundle('--load-image',success=False)
        self.assertFalse(self.client.exists())
        self.assertFalse(any(c[:2]==['image','load'] or c[:1]==['load'] for c in self.calls()))

    def test_unsafe_tar_members_rejected_even_with_matching_checksum(self):
        for kind in ['traversal','absolute','symlink','hardlink','duplicate']:
            with self.subTest(kind=kind):
                if self.bundle.exists():shutil.rmtree(self.bundle)
                self.export('--no-image')
                path=self.bundle/'test-wallets.tar.gz'
                with tarfile.open(path) as old:
                    members=[(m,old.extractfile(m).read() if m.isfile() else None) for m in old]
                with tarfile.open(path,'w:gz') as out:
                    for member,data in members:out.addfile(member,io.BytesIO(data) if data is not None else None)
                    bad=tarfile.TarInfo({'traversal':'../escaped','absolute':str(self.root/'absolute-escaped'),
                                        'symlink':'evil-link','hardlink':'evil-hardlink',
                                        'duplicate':members[0][0].name}[kind])
                    if kind in ('symlink','hardlink'):
                        bad.type=tarfile.SYMTYPE if kind=='symlink' else tarfile.LNKTYPE;bad.linkname='../escaped'
                        out.addfile(bad)
                    else:
                        bad.size=1;out.addfile(bad,io.BytesIO(b'x'))
                self.rewrite_inventory('test-wallets.tar.gz')
                self.import_bundle('--no-load-image',success=False)
                self.assertFalse(self.client.exists())
                self.assertFalse((self.root/'escaped').exists())
                self.assertFalse((self.root/'absolute-escaped').exists())

    def test_missing_selected_key_export_has_no_partial_output(self):
        (self.wallets/f'source-{SOURCE_OFFSET}.pk').unlink()
        self.export('--no-image',success=False)
        self.assertFalse(self.bundle.exists())
        self.assertEqual(list(self.root.glob('.bundle*')),[])

    def test_existing_destinations_never_overwritten(self):
        self.export('--no-image')
        original=(self.bundle/'export-manifest.json').read_bytes()
        self.export('--no-image',success=False)
        self.assertEqual((self.bundle/'export-manifest.json').read_bytes(),original)
        self.client.mkdir();(self.client/'keep').write_text('untouched')
        self.import_bundle('--no-load-image',success=False)
        self.assertEqual((self.client/'keep').read_text(),'untouched')

    def test_import_image_identity_mismatch_cleans_partial_output(self):
        self.export('--no-image')
        self.scenario(wrong_image=True)
        self.import_bundle('--no-load-image',success=False)
        self.assertFalse(self.client.exists())


    def prepare_runner(self):
        self.export('--no-image')
        self.import_bundle('--no-load-image')
        final = {'final':True, 'offered':1920, 'steady_offered':1600, 'steady_mempool_accepted':1600,
                 'canonical_total_after_drain':1920, 'canonical_measured_offers_after_drain':1600,
                 'measure_elapsed_s':10, 'canonical_gen_utime_bucket_duration_s':10,
                 'canonical_chain_measure_transfers':1440, 'steady_offered_avg_tps':160.0,
                 'steady_mempool_accept_avg_tps':160.0, 'canonical_chain_measure_avg_tps':144.0,
                 'native_signed_run_target_size':16, 'native_signed_run_effective_quantum_min':16,
                 'native_signed_run_effective_quantum_max':16,
                 'canonical_lane_balance':{key:True for key in ['enabled','required','valid','topology_complete',
                                                              'totals_reconcile','every_lane_active','within_tolerance']}}
        final['canonical_lane_balance'].update(depth=2,expected_lanes=4)
        for key in ['benchmark_result_valid','canonical_result_valid','chain_correctness_valid',
                    'canonical_follower_enabled','canonical_follower_final_catchup_complete',
                    'native_signed_runs_enabled','native_run_batching_requested','native_run_batching_enabled',
                    'ingress_capacity_valid','chain_capacity_valid']:
            final[key]=True
        for key in ['canonical_backlog','canonical_backlog_after_drain','canonical_total_backlog_after_drain',
                    'canonical_follower_errors','canonical_follower_retry_exhausted','canonical_hash_conflicts',
                    'duplicate_nonce_conflicts','external_nonce_conflicts','retry_exhausted',
                    'native_signed_run_normal_quantum_violations']:
            final[key]=0
        for key in ['correctness_invalid_reasons','run_incomplete_reasons','ingress_capacity_invalid_reasons',
                    'chain_capacity_invalid_reasons','invalid_reasons']:
            final[key]=[]
        for category in ['', 'normal_', 'repair_', 'terminal_tail_']:
            final['native_signed_run_'+category+'messages']=120 if category in ('','normal_') else 0
            final['native_signed_run_'+category+'logical_transfers']=1920 if category in ('','normal_') else 0
        final['native_signed_run_proof_resolutions']=120
        (self.fake/'final.json').write_text(json.dumps(final))
        self.results=self.root/'results'

    def run_load(self,*args,success=True):
        return self.invoke('run-remote-load.sh','--directory',self.client,'--output',self.results,
                           '--duration',10,'--warmup',1,'--drain',1,*args,success=success)

    def test_runner_order_fixed_budgets_and_immutable_local_image(self):
        self.prepare_runner()
        self.run_load('--connections',10,50,100,'--cpus',4,'--memory','8g')
        runs=json.loads((self.fake/'runs.json').read_text())
        self.assertEqual([int(r['env']['NATIVE_LOAD_CONNECTIONS']) for r in runs],[10,50,100])
        for run in runs:
            for key,value in {'NATIVE_LOAD_WORKERS':'6','NATIVE_LOAD_SIGNERS':'6','NATIVE_LOAD_SOURCES':str(SOURCES),
                              'NATIVE_LOAD_SOURCE_OFFSET':str(SOURCE_OFFSET),'NATIVE_LOAD_TARGET_TPS':'0',
                              'NATIVE_LOAD_ADAPTIVE_INITIAL_CWND':'32768','NATIVE_LOAD_ADAPTIVE_MAX_CWND':'65536',
                              'NATIVE_LOAD_INFLIGHT':'262144','NATIVE_LOAD_DURATION_SECONDS':'10',
                              'NATIVE_LOAD_WARMUP_SECONDS':'1','NATIVE_LOAD_DRAIN_TIMEOUT_SECONDS':'1'}.items():
                self.assertEqual(run['env'][key],value)
        commands=[c for c in self.calls() if c[:1]==['run']]
        self.assertEqual(len(commands),3)
        for cmd in commands:
            self.assertEqual(cmd[-1],IMAGE_ID)
            self.assertEqual(cmd[cmd.index('--pull')+1],'never')
            self.assertEqual(cmd[cmd.index('--network')+1],'host')
            self.assertEqual(cmd[cmd.index('--cpus')+1],'4')
            self.assertEqual(cmd[cmd.index('--memory')+1],'8g')
            self.assertIn('readonly',cmd[cmd.index('--mount')+1])
        summary=json.loads((self.results/'summary.json').read_text())
        self.assertTrue(summary['completed'])
        self.assertEqual([a['connections'] for a in summary['arms']],[10,50,100])
        for arm in summary['arms']:
            self.assertTrue(arm['valid_run'])
            self.assertEqual(arm['capacity_classification'],'generator_capacity_eligible')
            self.assertFalse(arm['full_independent_capacity_claim_allowed'])
            self.assertIsNone(arm['remote_validator_cleanup_valid'])
        self.assertFalse(any(c[:1] in (['build'],['pull'],['compose'],['rm']) for c in self.calls()))

    def test_runner_capacity_rejection_retains_all_observations(self):
        self.prepare_runner();self.scenario(capacity_rejected=True)
        self.run_load('--connections',10,50,100)
        summary=json.loads((self.results/'summary.json').read_text())
        self.assertTrue(summary['completed'])
        self.assertEqual(len(summary['arms']),3)
        for arm in summary['arms']:
            self.assertTrue(arm['valid_run'])
            self.assertEqual(arm['capacity_classification'],'observation_only')
            self.assertFalse(arm['full_independent_capacity_claim_allowed'])
            self.assertEqual(arm['final']['invalid_reasons'],['offered_load_not_above_canonical_throughput'])

    def test_runner_incomplete_run_stops_before_reusing_sources(self):
        self.prepare_runner();self.scenario(incomplete=True)
        self.run_load('--connections',10,50,100,success=False)
        self.assertEqual(len(json.loads((self.fake/'runs.json').read_text())),1)
        summary=json.loads((self.results/'summary.json').read_text())
        self.assertFalse(summary['completed'])
        self.assertFalse(summary['arms'][0]['valid_run'])
        self.assertTrue((self.results/'01-10-connections/generator.log').is_file())
        self.assertFalse((self.results/'02-50-connections').exists())

    def test_runner_rejects_count_proof_density_and_rate_mismatches(self):
        self.prepare_runner()
        for mutation in [{'configured_connections':11}, {'canonical_hash_conflicts':1},
                         {'native_signed_run_normal_logical_transfers':1919},
                         {'native_signed_run_proof_resolutions':119}, {'steady_offered_avg_tps':159},
                         {'canonical_follower_final_catchup_complete':False}, {'steady_offered_avg_tps':float('nan')}]:
            with self.subTest(mutation=mutation):
                self.scenario(final_overrides=mutation)
                self.results=self.root/('rejected-'+str(len(self.calls())))
                before=len([c for c in self.calls() if c[:1]==['run']])
                self.run_load('--connections',10,50,success=False)
                self.assertEqual(len([c for c in self.calls() if c[:1]==['run']])-before,1)
                summary=json.loads((self.results/'summary.json').read_text())
                self.assertFalse(summary['completed'])
                self.assertTrue(summary['arms'][0]['invalid_reasons'])



    def test_import_missing_selected_key_removes_staging(self):
        self.export('--no-image')
        archive_path=self.bundle/'test-wallets.tar.gz'
        missing=f'source-{SOURCE_OFFSET}.pk'
        with tarfile.open(archive_path) as archive:
            entries=[(m,archive.extractfile(m).read()) for m in archive if m.name!=missing]
        with tarfile.open(archive_path,'w:gz') as archive:
            for member,data in entries:archive.addfile(member,io.BytesIO(data))
        self.rewrite_inventory('test-wallets.tar.gz')
        self.import_bundle('--no-load-image',success=False)
        self.assertFalse(self.client.exists())
        self.assertEqual(list(self.root.glob('.client.import-*')),[])

    def test_runner_nonzero_container_exit_stops_sequence(self):
        self.prepare_runner();self.scenario(container_exit=137)
        self.run_load('--connections',10,50,success=False)
        self.assertEqual(len([c for c in self.calls() if c[:1]==['run']]),1)
        summary=json.loads((self.results/'summary.json').read_text())
        self.assertFalse(summary['completed'])
        self.assertFalse(summary['arms'][0]['valid_run'])
        self.assertTrue((self.results/'01-10-connections/container.json').is_file())

    def test_runner_existing_output_is_never_overwritten(self):
        self.prepare_runner()
        self.results.mkdir();(self.results/'keep').write_text('untouched')
        self.run_load('--connections',10,success=False)
        self.assertEqual((self.results/'keep').read_text(),'untouched')
        self.assertFalse(any(c[:1]==['run'] for c in self.calls()))

    def test_runner_remote_context_overrides_local_host_and_is_rejected(self):
        self.prepare_runner();self.scenario(remote_context=True)
        self.env['DOCKER_CONTEXT']='remote-context-fixture'
        self.run_load('--connections',10,success=False)
        self.assertTrue(any(c[:2]==['context','inspect'] for c in self.calls()))
        self.assertFalse(any(c[:1]==['run'] for c in self.calls()))

    def test_runner_immutable_image_mismatch_fails_before_launch(self):
        self.prepare_runner();self.scenario(wrong_image=True)
        self.run_load('--connections',10,success=False)
        self.assertFalse(any(c[:1]==['run'] for c in self.calls()))

    def test_runner_failed_name_collision_does_not_stop_an_unowned_container(self):
        self.prepare_runner();self.scenario(run_name_collision=True)
        self.run_load('--connections',10,50,success=False)
        self.assertEqual(len([c for c in self.calls() if c[:1]==['run']]),1)
        self.assertFalse(any(c[:1] in (['stop'],['kill'],['rm']) for c in self.calls()))

    def test_runner_sigterm_stops_owned_container_and_preserves_evidence(self):
        self.prepare_runner();self.scenario(wait_for_stop=True)
        command=[str(REMOTE/'run-remote-load.sh'),'--directory',str(self.client),'--output',str(self.results),
                 '--duration','10','--warmup','1','--drain','1','--connections','10','50']
        with (self.root/'runner.stdout').open('w') as stdout, (self.root/'runner.stderr').open('w') as stderr:
            process=subprocess.Popen(command,env=self.env,stdout=stdout,stderr=stderr,start_new_session=True)
            try:
                deadline=time.monotonic()+10
                while not any(c[:1]==['wait'] for c in self.calls()) and process.poll() is None and time.monotonic()<deadline:
                    time.sleep(.02)
                self.assertTrue(any(c[:1]==['wait'] for c in self.calls()),'runner never reached fake docker wait')
                process.send_signal(signal.SIGTERM)
                self.assertNotEqual(process.wait(timeout=10),0)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid,signal.SIGKILL);process.wait()
        self.assertEqual(len([c for c in self.calls() if c[:1]==['run']]),1)
        self.assertTrue(any(c[:1]==['stop'] for c in self.calls()))
        self.assertFalse(any(c[:1]==['rm'] for c in self.calls()))
        summary=json.loads((self.results/'summary.json').read_text())
        self.assertFalse(summary['completed'])
        self.assertTrue((self.results/'01-10-connections/generator.log').is_file())


if __name__=='__main__':
    unittest.main(verbosity=2)
