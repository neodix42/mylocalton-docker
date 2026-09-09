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
import re
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
GENESIS_IMAGE_ID = 'sha256:' + 'f' * 64
SOURCE_REVISION = 'c' * 40
SOURCE_OFFSET, SOURCES, ALL_SOURCES = 4, 32, 40

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
genesis_image_id='sha256:'+'f'*64
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
  elif args[-1]==genesis_image_id:
   image['Config']['Labels']['org.opencontainers.image.revision']=scenario.get('source_revision',revision)
  else:
   image['Config']['Labels']['org.opencontainers.image.revision']=scenario.get('client_revision',revision)
   if scenario.get('missing_client_revision'):image['Config']['Labels'].pop('org.opencontainers.image.revision')
  print(json.dumps([image])); sys.exit()
 container = {'Id':'d'*64,'Name':'/fixture-genesis','Image':genesis_image_id,'RestartCount':0,
  'State':{'Running':True,'ExitCode':0,'StartedAt':'2026-09-07T00:00:00Z'},
  'Config':{'Image':'native-client:offline-fixture','Env':['NATIVE_PAYMENT_LANE_DEPTH=2']}}
 runs = json.loads((root/'runs.json').read_text()) if (root/'runs.json').exists() else []
 for run in runs:
  if args[-1] in (run['name'],run['id']):
   container = run['inspect']
   container['State']['Running'] = False
   failed = scenario.get('failed_connections') in (None, int(run['env']['NATIVE_LOAD_CONNECTIONS']))
   container['State']['ExitCode'] = scenario.get('container_exit',0) if failed else 0
   container['State']['OOMKilled'] = scenario.get('oom_killed',False) if failed else False
   container['State']['Error'] = scenario.get('container_error','') if failed else ''
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
if args[:1] == ['run'] and '--entrypoint' in args and args[args.index('--entrypoint')+1]=='/bin/sh':
 with (root/'lane-capability-calls.jsonl').open('a') as out:out.write(json.dumps(args)+'\n')
 if args[-2]!='-ec' or '--mount' in args or '--env-file' in args or '--read-only' not in args or args[args.index('--network')+1]!='none':
  raise SystemExit('unsafe lane capability probe arguments')
 script=args[-1].replace('/usr/local/lib/native-load-generator/payment-lanes.sh',str(root/'image-payment-lanes.sh'))
 proc=subprocess.run(['/bin/sh','-ec',script])
 sys.exit(proc.returncode)
if args[:1] == ['run'] and '--entrypoint' in args and args[args.index('--entrypoint')+1]=='/usr/local/bin/native-load-generator':
 with (root/'capability-calls.jsonl').open('a') as out:out.write(json.dumps(args)+'\n')
 if args[-1]!='--help' or '--mount' in args or '--env-file' in args or args[args.index('--network')+1]!='none':
  raise SystemExit('unsafe capability probe arguments')
 if scenario.get('capability_help_exit'):raise SystemExit(scenario['capability_help_exit'])
 print(scenario.get('capability_help','  -c, --connections<arg>     persistent ADNL/TCP connections (1..1024)'));sys.exit()
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
 if scenario.get('wait_command_exit'):sys.exit(scenario['wait_command_exit'])
 runs=json.loads((root/'runs.json').read_text());run=next(x for x in runs if args[-1] in (x['name'],x['id']))
 failed=scenario.get('failed_connections') in (None,int(run['env']['NATIVE_LOAD_CONNECTIONS']))
 print(scenario.get('container_exit',0) if failed else 0);sys.exit()
if args[:1] in (['stop'],['kill']):
 (root/'stopped').touch();print(args[-1]);sys.exit()
if args[:1] == ['logs']:
 runs=json.loads((root/'runs.json').read_text());run=next(x for x in runs if args[-1] in (x['name'],x['id']))
 fixture=root/'final.json'
 if not fixture.exists():raise SystemExit('runner final fixture not installed')
 final=json.loads(fixture.read_text());env=run['env']
 duration=int(env['NATIVE_LOAD_DURATION_SECONDS'])
 final.update(measure_elapsed_s=duration,canonical_gen_utime_bucket_duration_s=duration,
              offered=192*duration,steady_offered=160*duration,steady_mempool_accepted=160*duration,
              canonical_total_after_drain=192*duration,canonical_measured_offers_after_drain=160*duration,
              canonical_chain_measure_transfers=144*duration)
 for category in ['', 'normal_']:
  final['native_signed_run_'+category+'messages']=12*duration
  final['native_signed_run_'+category+'logical_transfers']=192*duration
 final['native_signed_run_proof_resolutions']=12*duration
 for field,key in {'configured_connections':'NATIVE_LOAD_CONNECTIONS','configured_workers':'NATIVE_LOAD_WORKERS',
   'configured_signers':'NATIVE_LOAD_SIGNERS','configured_sources':'NATIVE_LOAD_SOURCES',
   'adaptive_initial_cwnd':'NATIVE_LOAD_ADAPTIVE_INITIAL_CWND',
   'adaptive_max_cwnd':'NATIVE_LOAD_ADAPTIVE_MAX_CWND'}.items():final[field]=int(env[key])
 if scenario.get('incomplete'):
  final['run_incomplete_reasons']=['canonical_backlog_after_drain'];final['canonical_backlog_after_drain']=16
 if scenario.get('capacity_rejected'):
  final['chain_capacity_valid']=False
  final['invalid_reasons']=['offered_load_not_above_canonical_throughput']
 final.update(scenario.get('final_overrides',{}))
 final.update(scenario.get('arm_final_overrides',{}).get(env['NATIVE_LOAD_CONNECTIONS'],{}))
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
        shutil.copy2(ROOT/'native-load-generator/payment-lanes.sh', self.fake/'image-payment-lanes.sh')
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
        self.write_wallets(2)
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

    def write_wallets(self, depth):
        lanes = 1 << depth
        rows=[f'NATIVE_PAYMENT_LANES_MANIFEST_V1 {depth} {lanes} {ALL_SOURCES}']
        for i in range(ALL_SOURCES):
            addresses={}
            for kind in ['source','dest']:
                address=bytes([(i % lanes) << (8 - depth)])+hashlib.sha256(f'{kind}-{i}'.encode()).digest()[1:]
                addresses[kind]=address
                (self.wallets/f'{kind}-{i}.addr').write_bytes(address)
                (self.wallets/f'{kind}-{i}.pub').write_bytes(address)
                (self.wallets/f'{kind}-{i}.pk').write_bytes(hashlib.sha256(f'private-{kind}-{i}'.encode()).digest())
            rows.append(f'{i} {i % lanes} {addresses["source"].hex()} {addresses["dest"].hex()}')
        (self.wallets/'native-payment-lanes.manifest').write_text('\n'.join(rows)+'\n')

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

    def export_reused_image(self, mode, success=True):
        if mode == 'configured':
            return self.export_detected_image('--no-build-image', success=success)
        return self.invoke('export-native-client.sh', '--non-interactive', '--server-ip', '203.0.113.7',
                           '--container', 'fixture-genesis', '--sources', SOURCES,
                           '--source-offset', SOURCE_OFFSET, '--output', self.bundle, '--no-image',
                           '--image', IMAGE_ID if mode == 'immutable' else IMAGE_REF, success=success)

    def assert_reuse_did_not_prepare_or_publish_images(self):
        self.assertEqual(self.compose_calls('build'), [])
        self.assertFalse(any(call[:1] in (['pull'], ['build']) or call[:2] == ['image', 'save']
                             for call in self.calls()))

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

    def test_export_import_inherits_all_supported_manifest_depths(self):
        preset = (REMOTE/'native-remote-load.env').read_text()
        self.assertIn('NATIVE_PAYMENT_LANE_DEPTH=3\n', preset)
        self.assertIn('NATIVE_LOAD_PAYMENT_LANE_DEPTH=3\n', preset)
        self.assertIn('NATIVE_LOAD_SOURCES=24576\n', preset)
        for depth in (1, 2, 3):
            with self.subTest(depth=depth):
                self.write_wallets(depth)
                self.bundle = self.root/f'bundle-depth{depth}'
                self.client = self.root/f'client-depth{depth}'
                self.export('--no-image')
                manifest = json.loads((self.bundle/'export-manifest.json').read_text())
                self.assertEqual(manifest['wallets'], {'lane_depth':depth,
                    'source_offset':SOURCE_OFFSET, 'sources':SOURCES})
                exported = (self.bundle/'remote-load.env').read_text()
                self.assertIn(f'NATIVE_PAYMENT_LANE_DEPTH={depth}\n', exported)
                self.assertIn(f'NATIVE_LOAD_PAYMENT_LANE_DEPTH={depth}\n', exported)
                ready_timeout = {1:360, 2:900, 3:1800}[depth]
                self.assertIn(f'NATIVE_LOAD_PAYMENT_LANE_READY_TIMEOUT_SECONDS={ready_timeout}\n', exported)
                self.import_bundle('--no-load-image')
                self.assertEqual((self.client/'remote-load.env').read_text(), exported)
                wallet_dir = self.client/'client-data/wallets'
                self.assertEqual((wallet_dir/'native-payment-lanes.manifest').read_bytes(),
                                 (self.wallets/'native-payment-lanes.manifest').read_bytes())
                actual_lanes = [0] * (1 << depth)
                for index in range(SOURCE_OFFSET, SOURCE_OFFSET + SOURCES):
                    for kind in ('source', 'dest'):
                        address = (wallet_dir/f'{kind}-{index}.addr').read_bytes()
                        self.assertEqual(address[0] >> (8-depth), index % (1 << depth))
                    actual_lanes[index % (1 << depth)] += 1
                self.assertEqual(actual_lanes, [SOURCES // (1 << depth)] * (1 << depth))

    def test_eight_lane_export_probes_pinned_helper_without_network_or_wallets(self):
        self.write_wallets(3)
        self.export('--no-image')
        probes=[json.loads(line) for line in (self.fake/'lane-capability-calls.jsonl').read_text().splitlines()]
        self.assertEqual(len(probes), 1)
        self.assertEqual(probes[0][:-1], ['run','--rm','--pull','never','--network','none',
                                        '--read-only','--entrypoint','/bin/sh',IMAGE_ID,'-ec'])
        self.assertIn('native_payment_lanes_validate_mode 1 1 3 3', probes[0][-1])
        self.assertIn('native_payment_lanes_expected_shard_prefixes 3', probes[0][-1])
        self.assertFalse(any(c[:1] in (['pull'], ['build']) for c in self.calls()))
        self.assertTrue(self.bundle.is_dir())

    def test_eight_lane_export_rejects_legacy_image_helper_without_partial_bundle(self):
        self.write_wallets(3)
        helper=self.fake/'image-payment-lanes.sh'
        helper.write_text(helper.read_text().replace('1|2|3) return 0', '1|2) return 0'))
        result=self.export('--include-image',success=False)
        self.assertIn('does not support eight-lane client initialization', result.stderr)
        self.assertFalse(self.bundle.exists())
        self.assertEqual(list(self.root.glob('.bundle.staging-*')), [])
        self.assertFalse(any(c[:2]==['image','save'] for c in self.calls()))

    def test_eight_lane_export_rejects_helper_with_wrong_shard_prefixes(self):
        self.write_wallets(3)
        helper=self.fake/'image-payment-lanes.sh'
        original=helper.read_text()
        corrupted=original.replace('prefix=$(((2 * lane + 1) << (3 - depth)))', 'prefix=0')
        self.assertNotEqual(corrupted, original)
        helper.write_text(corrupted)
        self.export('--no-image',success=False)
        self.assertFalse(self.bundle.exists())
        self.assertEqual(list(self.root.glob('.bundle.staging-*')), [])

    def test_legacy_exports_do_not_require_eight_lane_image_helper(self):
        helper=self.fake/'image-payment-lanes.sh'
        helper.write_text(helper.read_text().replace('1|2|3) return 0', '1|2) return 0'))
        self.export('--no-image')
        self.assertFalse((self.fake/'lane-capability-calls.jsonl').exists())
        self.import_bundle('--no-load-image')

    def test_export_rejects_unsupported_or_mismatched_eight_lane_headers(self):
        self.write_wallets(3)
        path = self.wallets/'native-payment-lanes.manifest'
        original = path.read_text().splitlines()
        for header in (f'NATIVE_PAYMENT_LANES_MANIFEST_V1 4 16 {ALL_SOURCES}',
                       f'NATIVE_PAYMENT_LANES_MANIFEST_V1 3 4 {ALL_SOURCES}'):
            with self.subTest(header=header):
                path.write_text('\n'.join([header, *original[1:]])+'\n')
                self.export('--no-image', success=False)
                self.assertFalse(self.bundle.exists())
                self.assertEqual(list(self.root.glob('.bundle.staging-*')), [])

    def test_eight_lane_import_rejects_rehashed_manifest_and_cross_lane_corruption(self):
        self.write_wallets(3)
        for mutation in ('header_count', 'duplicate', 'missing', 'lane_out_of_range', 'cross_lane'):
            with self.subTest(mutation=mutation):
                if self.bundle.exists(): shutil.rmtree(self.bundle)
                self.export('--no-image')
                path = self.bundle/'test-wallets.tar.gz'
                with tarfile.open(path) as archive:
                    entries = [(member, archive.extractfile(member).read()) for member in archive]
                changed_address = bytearray((self.wallets/f'dest-{SOURCE_OFFSET}.addr').read_bytes())
                changed_address[0] ^= 0x20  # Same depth-2 lane, different depth-3 lane.
                changed_address = bytes(changed_address)
                with tarfile.open(path, 'w:gz') as archive:
                    for member, data in entries:
                        if member.name == 'native-payment-lanes.manifest':
                            lines = data.decode().splitlines()
                            row_index = SOURCE_OFFSET + 1
                            if mutation == 'header_count': lines[0] = lines[0].replace('3 8', '3 4')
                            elif mutation == 'duplicate': lines.append(lines[row_index])
                            elif mutation == 'missing': del lines[row_index]
                            else:
                                row = lines[row_index].split()
                                if mutation == 'lane_out_of_range': row[1] = '8'
                                if mutation == 'cross_lane': row[3] = changed_address.hex()
                                lines[row_index] = ' '.join(row)
                            data = ('\n'.join(lines)+'\n').encode()
                        elif mutation == 'cross_lane' and member.name in (
                                f'dest-{SOURCE_OFFSET}.pub', f'dest-{SOURCE_OFFSET}.addr'):
                            data = changed_address
                        member.size = len(data)
                        archive.addfile(member, io.BytesIO(data))
                self.rewrite_inventory('test-wallets.tar.gz')
                self.import_bundle('--no-load-image', success=False)
                self.assertFalse(self.client.exists())
                self.assertEqual(list(self.root.glob('.client.import-*')), [])

    def test_eight_lane_runner_isolates_balanced_source_ranges_and_preserves_proof_gates(self):
        self.prepare_runner(depth=3)
        self.run_load('--connections',10,50,'--source-policy','isolated')
        settings = json.loads((self.results/'settings.json').read_text())
        self.assertEqual(settings['lane_depth'], 3)
        self.assertEqual(settings['source_partitions'], [
            {'source_offset':SOURCE_OFFSET,'sources':16},
            {'source_offset':SOURCE_OFFSET+16,'sources':16}])
        summary = json.loads((self.results/'summary.json').read_text())
        self.assertTrue(summary['completed'])
        for arm in summary['arms']:
            self.assertTrue(arm['source_reuse_safe'])
            self.assertEqual(arm['final']['canonical_lane_balance']['depth'], 3)
            self.assertEqual(arm['final']['canonical_lane_balance']['expected_lanes'], 8)
        runs = json.loads((self.fake/'runs.json').read_text())
        for run in runs:
            self.assertEqual(run['env']['NATIVE_PAYMENT_LANE_DEPTH'], '3')
            self.assertEqual(run['env']['NATIVE_LOAD_PAYMENT_LANE_DEPTH'], '3')
            self.assertEqual(run['env']['NATIVE_LOAD_INFLIGHT'], '262144')

    def test_eight_lane_runner_rejects_wrong_topology_and_incomplete_cohorts(self):
        self.prepare_runner(depth=3)
        final = json.loads((self.fake/'final.json').read_text())
        lane_balance = final['canonical_lane_balance']
        for mutation in ({'canonical_lane_balance':dict(lane_balance, depth=2, expected_lanes=4)},
                         {'canonical_lane_balance':dict(lane_balance, topology_complete=False)},
                         {'canonical_backlog_after_drain':16},
                         {'canonical_follower_final_catchup_complete':False}):
            with self.subTest(mutation=mutation):
                self.scenario(final_overrides=mutation)
                self.results = self.root/('depth3-rejected-'+str(len(self.calls())))
                self.run_load('--connections',10,50,success=False)
                summary = json.loads((self.results/'summary.json').read_text())
                self.assertFalse(summary['completed'])
                self.assertEqual(len(summary['arms']), 1)
                self.assertFalse(summary['arms'][0]['source_reuse_safe'])

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

    def test_reused_images_require_matching_revision_and_record_it(self):
        for mode in ('configured', 'explicit', 'immutable'):
            with self.subTest(mode=mode):
                self.bundle = self.root / ('bundle-' + mode)
                self.export_reused_image(mode)
                manifest = json.loads((self.bundle / 'export-manifest.json').read_text())
                self.assertEqual(manifest['image']['revision'], SOURCE_REVISION)
                self.assertEqual(manifest['image']['id'], IMAGE_ID)
                self.assertEqual(manifest['source_container']['image_id'], GENESIS_IMAGE_ID)
                self.assert_reuse_did_not_prepare_or_publish_images()
        self.assertIn(['image', 'inspect', GENESIS_IMAGE_ID], self.calls())

    def test_reused_images_reject_mismatched_revision_without_partial_export(self):
        self.scenario(client_revision='b' * 40)
        for mode in ('configured', 'explicit', 'immutable'):
            with self.subTest(mode=mode):
                result = self.export_reused_image(mode, success=False)
                self.assertIn('differs from running genesis', result.stderr)
                self.assertIn('prepare-native-images.sh', result.stderr)
                self.assertIn('strict reuse never pulls or builds', result.stderr)
                self.assertFalse(self.bundle.exists())
                self.assertEqual(list(self.root.glob('.bundle*')), [])
                self.assert_reuse_did_not_prepare_or_publish_images()

    def test_reused_images_reject_missing_or_malformed_generator_revision(self):
        for label in ({'missing_client_revision': True}, {'client_revision': None},
                      {'client_revision': 'c' * 8}, {'client_revision': 'C' * 40}):
            self.scenario(**label)
            for mode in ('configured', 'explicit', 'immutable'):
                with self.subTest(label=label, mode=mode):
                    result = self.export_reused_image(mode, success=False)
                    self.assertIn('selected generator image lacks a full TON', result.stderr)
                    self.assertIn('start-native-genesis.sh', result.stderr)
                    self.assertFalse(self.bundle.exists())
                    self.assertEqual(list(self.root.glob('.bundle*')), [])
                    self.assert_reuse_did_not_prepare_or_publish_images()

    def test_reused_images_require_versioned_running_genesis(self):
        self.scenario(source_revision=None)
        for mode in ('configured', 'explicit', 'immutable'):
            with self.subTest(mode=mode):
                result = self.export_reused_image(mode, success=False)
                self.assertIn('running genesis lacks a full TON source revision', result.stderr)
                self.assertIn('start-native-genesis.sh', result.stderr)
                self.assertFalse(self.bundle.exists())
                self.assert_reuse_did_not_prepare_or_publish_images()

    def test_registry_preparation_can_replace_an_unversioned_old_generator(self):
        self.scenario(client_revision=None, build_new_id=True)
        self.export_detected_image()
        self.assert_only_generator_builds()
        manifest = json.loads((self.bundle / 'export-manifest.json').read_text())
        self.assertEqual(manifest['image']['revision'], SOURCE_REVISION)
        self.assertEqual(manifest['image']['id'], BUILT_IMAGE_ID)

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


    def prepare_runner(self, depth=2):
        self.write_wallets(depth)
        self.export('--no-image')
        self.import_bundle('--no-load-image')
        # Model an already imported six-worker bundle. The default profile must
        # upgrade it without rewriting this original environment file.
        envfile = self.client/'remote-load.env'
        envfile.write_text(re.sub(r'NATIVE_LOAD_(WORKERS|SIGNERS)=[0-9]+',
                                 lambda match: 'NATIVE_LOAD_'+match[1]+'=6', envfile.read_text()))
        final = {'final':True, 'offered':1920, 'steady_offered':1600, 'steady_mempool_accepted':1600,
                 'canonical_total_after_drain':1920, 'canonical_measured_offers_after_drain':1600,
                 'measure_elapsed_s':10, 'canonical_gen_utime_bucket_duration_s':10,
                 'canonical_chain_measure_transfers':1440, 'steady_offered_avg_tps':160.0,
                 'steady_mempool_accept_avg_tps':160.0, 'canonical_chain_measure_avg_tps':144.0,
                 'native_signed_run_target_size':16, 'native_signed_run_effective_quantum_min':16,
                 'native_signed_run_effective_quantum_max':16,
                 'canonical_lane_balance':{key:True for key in ['enabled','required','valid','topology_complete',
                                                              'totals_reconcile','every_lane_active','within_tolerance']}}
        final['canonical_lane_balance'].update(depth=depth,expected_lanes=1 << depth)
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
                           '--profile','preset','--duration',10,'--warmup',1,'--drain',1,*args,success=success)

    def test_coalesce_override_and_client_limit_evidence_preserve_acceptance(self):
        self.prepare_runner()
        self.scenario(final_overrides={'native_run_batching_coalesce_ms':10,
            'cwnd_cap_limited_acks':7, 'congestion_window':1234,
            'not_ready_by_reason':{'snapshot_revision':11, 'other':0}, 'rtt_ms':{'p95':200}})
        original=(self.client/'remote-load.env').read_bytes()
        self.run_load('--connections',10,'--submit-coalesce-ms',10)
        summary=json.loads((self.results/'01-10-connections/summary.json').read_text())
        self.assertTrue(summary['valid_run'])
        limits=json.loads((self.results/'01-10-connections/client-limits.json').read_text())
        self.assertIn('admission_window_cap_encountered',limits['signals'])
        self.assertIn('not_ready_retries_observed',limits['signals'])
        self.assertEqual(limits['observed']['rtt_ms']['p95'],200)
        self.assertEqual((self.client/'remote-load.env').read_bytes(),original)
        settings=json.loads((self.results/'settings.json').read_text())
        self.assertEqual(settings['environment']['NATIVE_LOAD_SUBMIT_COALESCE_MS'],'10')

    def test_coalesce_override_requires_generator_confirmation(self):
        self.prepare_runner()
        self.scenario(final_overrides={'native_run_batching_coalesce_ms':20})
        self.run_load('--connections',10,'--submit-coalesce-ms',10,success=False)
        arm=json.loads((self.results/'01-10-connections/summary.json').read_text())
        self.assertFalse(arm['valid_run'])
        self.assertTrue(any('coalesce' in reason for reason in arm['invalid_reasons']))
        self.assertIn('final',arm)
        self.assertEqual(arm['client_limits']['observed']['steady_offered_avg_tps'],160)

    def test_invalid_coalesce_override_starts_no_container(self):
        self.prepare_runner()
        for value in ('0','101','nan','-1'):
            self.results=self.root/('bad-coalesce-'+value)
            self.run_load('--connections',10,'--submit-coalesce-ms',value,success=False)
        self.assertFalse((self.fake/'runs.json').exists())

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
            self.assertEqual(cmd[cmd.index('--ulimit')+1],'nofile=65536:65536')
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

    def test_runner_explicit_load_tuning_is_frozen_and_reported_per_setup(self):
        self.prepare_runner()
        original=(self.client/'remote-load.env').read_bytes()
        self.scenario(final_overrides={'phase':'measure','offered_tps':160})
        result=self.run_load('--connections',50,100,'--workers',12,'--signers',12,
                             '--initial-cwnd',65536,'--max-cwnd',131072,'--cpus',12)
        self.assertEqual((self.client/'remote-load.env').read_bytes(),original)
        expected={'profile':'preset','workers':12,'signers':12,'initial_cwnd':65536,'max_cwnd':131072,
                  'inflight':262144,'cpus':'12','memory':'8g'}
        settings=json.loads((self.results/'settings.json').read_text())
        for key,value in expected.items():self.assertEqual(settings[key],value)
        runs=json.loads((self.fake/'runs.json').read_text())
        self.assertEqual(len(runs),2)
        for run in runs:
            for key,value in {'NATIVE_LOAD_WORKERS':'12','NATIVE_LOAD_SIGNERS':'12',
                              'NATIVE_LOAD_ADAPTIVE_INITIAL_CWND':'65536',
                              'NATIVE_LOAD_ADAPTIVE_MAX_CWND':'131072',
                              'NATIVE_LOAD_INFLIGHT':'262144','NATIVE_LOAD_TARGET_TPS':'0'}.items():
                self.assertEqual(run['env'][key],value)
            self.assertEqual(run['inspect']['Image'],IMAGE_ID)
        summary=json.loads((self.results/'summary.json').read_text())
        self.assertTrue(summary['completed'])
        for arm in summary['arms']:self.assertEqual(arm['load_settings'],expected)
        for arm in self.results.glob('*-connections'):
            progress=[json.loads(line) for line in (arm/'progress.jsonl').read_text().splitlines()]
            self.assertTrue(progress)
            self.assertEqual(progress[-1]['load_settings'],expected)
            final=json.loads((arm/'generator-final.json').read_text())
            self.assertEqual(final['adaptive_initial_cwnd'],65536)
            self.assertEqual(final['adaptive_max_cwnd'],131072)
        self.assertIn('workers=12, signers=12',result.stdout)
        self.assertIn('initial=65536, max=131072, inflight=262144',result.stdout)
        self.assertFalse(any(c[:1] in (['build'],['pull'],['compose'],['rm']) for c in self.calls()))

    def test_runner_default_server48_upgrades_old_bundle_without_changing_budgets(self):
        self.prepare_runner()
        original=(self.client/'remote-load.env').read_bytes()
        result=self.invoke('run-remote-load.sh','--directory',self.client,'--output',self.results,
                           '--duration',10,'--warmup',1,'--drain',1)
        self.assertEqual((self.client/'remote-load.env').read_bytes(),original)
        settings=json.loads((self.results/'settings.json').read_text())
        self.assertEqual(settings['profile'],'server48')
        self.assertEqual((settings['cpus'],settings['memory']),('40','48g'))
        self.assertEqual((settings['workers'],settings['signers']),(10,32))
        self.assertEqual((settings['initial_cwnd'],settings['max_cwnd'],settings['inflight']),
                         (32768,65536,262144))
        self.assertEqual(settings['environment']['NATIVE_LOAD_MAX_CANONICAL_BACKLOG'],'2097120')
        self.assertEqual(settings['environment']['NATIVE_LOAD_MAX_SOURCE_CANONICAL_BACKLOG'],'128')
        runs=json.loads((self.fake/'runs.json').read_text())
        self.assertEqual([int(run['env']['NATIVE_LOAD_CONNECTIONS']) for run in runs],[10])
        for run in runs:
            self.assertEqual(run['env']['NATIVE_LOAD_WORKERS'],'10')
            self.assertEqual(run['env']['NATIVE_LOAD_SIGNERS'],'32')
            self.assertEqual(run['inspect']['Image'],IMAGE_ID)
        for command in [command for command in self.calls() if command[:1]==['run']]:
            self.assertEqual(command[command.index('--cpus')+1],'40')
            self.assertEqual(command[command.index('--memory')+1],'48g')
        self.assertIn('profile=server48, source policy=reuse, sources/setup=32; generator budget=40 CPUs/48g, workers=10, signers=32',result.stdout)
        self.assertTrue(json.loads((self.results/'summary.json').read_text())['completed'])

    def test_runner_explicit_overrides_win_over_server48_defaults(self):
        self.prepare_runner()
        self.invoke('run-remote-load.sh','--directory',self.client,'--output',self.results,
                    '--profile','server48','--connections',10,'--duration',10,'--warmup',1,'--drain',1,
                    '--cpus',16,'--memory','16g','--workers',6,'--signers',16)
        settings=json.loads((self.results/'settings.json').read_text())
        self.assertEqual((settings['cpus'],settings['memory'],settings['workers'],settings['signers']),
                         ('16','16g',6,16))
        self.assertEqual(settings['profile'],'server48')
        self.assertTrue(json.loads((self.results/'summary.json').read_text())['completed'])

    def test_runner_server48_caps_actor_counts_for_small_exports(self):
        self.prepare_runner()
        envfile=self.client/'remote-load.env'
        envfile.write_text(re.sub(r'NATIVE_LOAD_SOURCES=[0-9]+','NATIVE_LOAD_SOURCES=4',envfile.read_text()))
        self.invoke('run-remote-load.sh','--directory',self.client,'--output',self.results,
                    '--connections',10,'--duration',10,'--warmup',1,'--drain',1)
        settings=json.loads((self.results/'settings.json').read_text())
        self.assertEqual((settings['workers'],settings['signers'],settings['sources']),(4,4,4))
        self.assertTrue(json.loads((self.results/'summary.json').read_text())['completed'])

    def test_runner_rejects_unknown_or_duplicate_profile_before_launch(self):
        self.prepare_runner()
        for index,arguments in enumerate([['--profile','unknown'],['--profile','server48','--profile','preset']]):
            result=self.invoke('run-remote-load.sh','--directory',self.client,'--output',self.root/('profile-'+str(index)),
                               *arguments,success=False)
            self.assertIn('--profile',result.stderr)
        self.assertFalse(any(command[:1]==['run'] for command in self.calls()))

    def test_runner_connection_counts_use_effective_worker_override(self):
        self.prepare_runner()
        self.run_load('--connections',3,'--workers',3)
        run=json.loads((self.fake/'runs.json').read_text())[0]
        self.assertEqual(run['env']['NATIVE_LOAD_WORKERS'],'3')
        self.assertEqual(run['env']['NATIVE_LOAD_SIGNERS'],'6')
        self.assertTrue(json.loads((self.results/'summary.json').read_text())['completed'])

    def test_runner_invalid_tuning_stops_before_any_container_launch(self):
        self.prepare_runner()
        cases=[(['--workers',0], 'override is out of range'),
               (['--workers',257], 'override is out of range'),
               (['--signers',257], 'override is out of range'),
               (['--signers',5], 'NATIVE_LOAD_SIGNERS is out of range'),
               (['--workers',12,'--signers',12], 'connections is out of range'),
               (['--initial-cwnd',0], 'override is out of range'),
               (['--max-cwnd',0], 'override is out of range'),
               (['--initial-cwnd','1.5'], 'unsigned decimal integer'),
               (['--initial-cwnd',131072], 'initial cwnd must not exceed'),
               (['--max-cwnd',262145], 'max cwnd must be zero or between'),
               (['--max-cwnd',9], 'max cwnd must be zero or between'),
               # Aggregate 10*16 is sufficient, but two-level 6-worker fanout is not.
               (['--initial-cwnd',160], 'complete signed run'),
               (['--initial-cwnd',65536,'--initial-cwnd',65536], 'duplicate --initial-cwnd'),
               (['--max-cwnd'], '--max-cwnd requires a value')]
        for index,(arguments,reason) in enumerate(cases):
            with self.subTest(arguments=arguments):
                self.results=self.root/('invalid-tuning-'+str(index))
                result=self.run_load('--connections',10,*arguments,success=False)
                self.assertIn(reason,result.stderr)
        self.results=self.root/'unsupported-1025-connections'
        result=self.run_load('--connections',1025,success=False)
        self.assertIn('connections is out of range',result.stderr)
        self.assertFalse(any(c[:1]==['run'] for c in self.calls()))

    def test_runner_canonical_backlog_must_cover_effective_workers(self):
        self.prepare_runner()
        envfile=self.client/'remote-load.env'
        original=envfile.read_text()
        self.assertIn('NATIVE_LOAD_MAX_CANONICAL_BACKLOG=2097120',original)
        envfile.write_text(original.replace('NATIVE_LOAD_MAX_CANONICAL_BACKLOG=2097120',
                                           'NATIVE_LOAD_MAX_CANONICAL_BACKLOG=6'))
        result=self.run_load('--connections',50,'--workers',12,'--signers',12,success=False)
        self.assertIn('NATIVE_LOAD_MAX_CANONICAL_BACKLOG is out of range',result.stderr)
        self.assertFalse(any(c[:1]==['run'] for c in self.calls()))

    def test_runner_window_partition_boundary_and_native_zero_defaults(self):
        self.prepare_runner()
        self.run_load('--connections',10,'--initial-cwnd',192)
        self.assertTrue(json.loads((self.results/'summary.json').read_text())['completed'])
        # Zero in an existing env preset retains the native heuristic/hard-limit
        # semantics, while new CLI overrides intentionally require explicit budgets.
        envfile=self.client/'remote-load.env'
        envfile.write_text(envfile.read_text().replace('NATIVE_LOAD_ADAPTIVE_INITIAL_CWND=32768',
                                                     'NATIVE_LOAD_ADAPTIVE_INITIAL_CWND=0')
                                             .replace('NATIVE_LOAD_ADAPTIVE_MAX_CWND=65536',
                                                      'NATIVE_LOAD_ADAPTIVE_MAX_CWND=0'))
        self.results=self.root/'native-zero-windows'
        self.run_load('--connections',10)
        summary=json.loads((self.results/'summary.json').read_text())
        self.assertTrue(summary['completed'])
        self.assertEqual(summary['arms'][0]['load_settings']['initial_cwnd'],0)
        self.assertEqual(summary['arms'][0]['load_settings']['max_cwnd'],0)
        envfile.write_text(envfile.read_text().replace('NATIVE_LOAD_ADAPTIVE_INFLIGHT=1',
                                                     'NATIVE_LOAD_ADAPTIVE_INFLIGHT=0'))
        self.results=self.root/'adaptive-disabled'
        before=len([c for c in self.calls() if c[:1]==['run']])
        result=self.run_load('--connections',10,'--initial-cwnd',32768,success=False)
        self.assertIn('requires NATIVE_LOAD_ADAPTIVE_INFLIGHT=1',result.stderr)
        self.assertEqual(len([c for c in self.calls() if c[:1]==['run']]),before)

    def test_runner_defaults_upgrade_old_bundle_to_ten_minutes_and_scale_watchdog(self):
        self.prepare_runner()
        self.scenario(final_overrides={'phase':'measure','offered_tps':160,'mempool_accept_tps':160})
        envfile=self.client/'remote-load.env'
        old=envfile.read_text()
        import re
        envfile.write_text(re.sub(r'NATIVE_LOAD_DURATION_SECONDS=[0-9]+', 'NATIVE_LOAD_DURATION_SECONDS=180', old))
        result=self.invoke('run-remote-load.sh','--directory',self.client,'--output',self.results,'--connections',10)
        settings=json.loads((self.results/'settings.json').read_text())
        self.assertEqual(settings['duration'],600)
        self.assertEqual(settings['environment']['NATIVE_LOAD_DURATION_SECONDS'],'600')
        self.assertEqual(settings['runner_sha256'],sha((REMOTE/'run-remote-load.sh').read_bytes()))
        self.assertEqual((self.results/'run-remote-load.sh').read_bytes(),(REMOTE/'run-remote-load.sh').read_bytes())
        self.assertEqual(settings['warmup'],60)
        self.assertEqual(settings['watchdog_seconds'],600+60+180+900+600)
        self.assertIn('measurement=600s, warmup=60s',result.stdout)
        arm=json.loads((self.results/'01-10-connections/summary.json').read_text())
        self.assertTrue(arm['valid_run'])
        self.assertEqual(arm['measured']['offer_duration_s'],600)
        progress=[json.loads(line) for line in (self.results/'01-10-connections/progress.jsonl').read_text().splitlines()]
        self.assertTrue(progress)
        self.assertEqual(progress[-1]['measurement_target_s'],600)
        self.assertEqual(progress[-1]['phase'],'measure')
        self.assertEqual(progress[-1]['offered_tps'],160)
        self.assertEqual(progress[-1]['mempool_accept_tps'],160)
        self.assertNotIn('canonical_chain_measure_avg_tps',progress[-1])
        self.assertEqual(progress[-1]['canonical_chain_measure_planned_window_avg_tps'],144)
        self.assertEqual(progress[-1]['canonical_gen_utime_bucket_duration_s'],600)
        self.assertTrue(progress[-1]['provisional'])

    def test_runner_preserves_longer_preset_and_explicit_short_or_long_duration(self):
        self.prepare_runner()
        import re
        envfile=self.client/'remote-load.env'
        envfile.write_text(re.sub(r'NATIVE_LOAD_DURATION_SECONDS=[0-9]+', 'NATIVE_LOAD_DURATION_SECONDS=900', envfile.read_text()))
        for explicit,expected in [(None,900),(600,600),(10,10)]:
            with self.subTest(explicit=explicit):
                self.results=self.root/('duration-'+str(expected))
                args=[] if explicit is None else ['--duration',explicit]
                self.invoke('run-remote-load.sh','--directory',self.client,'--output',self.results,
                            '--connections',10,'--warmup',3,'--drain',7,*args)
                settings=json.loads((self.results/'settings.json').read_text())
                self.assertEqual(settings['duration'],expected)
                self.assertEqual(settings['watchdog_seconds'],expected+3+7+900+600)
                final=json.loads((self.results/'01-10-connections/generator-final.json').read_text())
                self.assertEqual(final['measure_elapsed_s'],expected)

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
        for mutation in [{'configured_connections':11}, {'adaptive_initial_cwnd':32767},
                         {'adaptive_max_cwnd':65535}, {'canonical_hash_conflicts':1},
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

    def test_runner_oom_exit_reports_evidence_and_stops_before_next_setup(self):
        self.prepare_runner();self.scenario(container_exit=137,oom_killed=True,failed_connections=50)
        result=self.run_load('--connections',10,50,100,success=False)
        self.assertEqual(len([c for c in self.calls() if c[:1]==['run']]),2)
        summary=json.loads((self.results/'summary.json').read_text())
        self.assertFalse(summary['completed'])
        self.assertTrue(summary['arms'][0]['valid_run'])
        failed=summary['arms'][1]
        self.assertFalse(failed['valid_run'])
        self.assertEqual(failed['execution']['ExitCode'],137)
        self.assertTrue(failed['execution']['OOMKilled'])
        self.assertEqual(failed['execution']['docker_wait_status'],0)
        self.assertEqual(failed['execution']['docker_wait_output'],'137')
        self.assertFalse(failed['execution']['watchdog_expired'])
        self.assertTrue((self.results/'02-50-connections/execution.json').is_file())
        self.assertFalse((self.results/'03-100-connections').exists())
        self.assertIn('"OOMKilled": true',result.stdout)
        self.assertIn('Stopped before reusing source accounts',result.stderr)

    def test_runner_nonzero_exit_preserves_generator_diagnosis_without_inventing_oom(self):
        self.prepare_runner()
        for code,reason_field,reason in [(2,'run_incomplete_reasons','canonical_backlog_after_drain'),
                                        (3,'correctness_invalid_reasons','canonical_hash_conflicts')]:
            with self.subTest(exit_code=code):
                self.results=self.root/('exit-'+str(code))
                self.scenario(container_exit=code,container_error='fixture runtime error',
                              final_overrides={reason_field:[reason], 'canonical_backlog_after_drain':32,
                                               'resigned':39, 'task_errors_by_reason':{'timeout':39},
                                               'not_ready_by_reason':{'unspecified':7},
                                               'active_tasks':32, 'retry_wait':0})
                result=self.run_load('--connections',10,50,100,success=False)
                summary=json.loads((self.results/'01-10-connections/summary.json').read_text())
                self.assertFalse(summary['valid_run'])
                self.assertEqual(summary['execution']['ExitCode'],code)
                self.assertFalse(summary['execution']['OOMKilled'])
                self.assertEqual(summary['execution']['Error'],'fixture runtime error')
                self.assertEqual(summary['generator_failure_reasons'][reason_field],[reason])
                diagnostics=summary['generator_diagnostics']
                self.assertEqual(diagnostics['canonical_backlog_after_drain'],32)
                self.assertEqual(diagnostics['resigned'],39)
                self.assertEqual(diagnostics['task_errors_by_reason'],{'timeout':39})
                self.assertEqual(diagnostics['not_ready_by_reason'],{'unspecified':7})
                self.assertEqual(diagnostics['active_tasks'],32)
                self.assertNotIn('native_signed_run_semantics',diagnostics)
                self.assertIn('"generator_diagnostics":',result.stdout)
                final=json.loads((self.results/'01-10-connections/generator-final.json').read_text())
                self.assertEqual(final[reason_field],[reason])
                self.assertIn(reason,result.stdout)
                self.assertFalse((self.results/'02-50-connections').exists())

    def test_runner_distinguishes_watchdog_from_docker_wait_failure(self):
        self.prepare_runner()
        for status,expired,reason in [(124,True,'watchdog_expired_after_'),(1,False,'docker_wait_command_failed_exit_1'),
                                      (137,None,'docker_wait_or_watchdog_killed_exit_137')]:
            with self.subTest(wait_status=status):
                self.results=self.root/('wait-'+str(status))
                self.scenario(wait_command_exit=status)
                self.run_load('--connections',10,50,100,success=False)
                summary=json.loads((self.results/'01-10-connections/summary.json').read_text())
                self.assertFalse(summary['valid_run'])
                self.assertEqual(summary['execution']['docker_wait_status'],status)
                self.assertEqual(summary['execution']['watchdog_expired'],expired)
                self.assertIn(reason,summary['execution']['runner_failure'])
                self.assertFalse(summary['execution']['OOMKilled'])
                self.assertFalse((self.results/'02-50-connections').exists())
                self.assertTrue(any(c[:1]==['stop'] for c in self.calls()))

    def test_runner_large_sweep_keeps_global_windows_and_file_descriptor_headroom(self):
        self.prepare_runner()
        self.run_load('--connections',300,500,1024,'--workers',10,'--signers',10)
        runs=json.loads((self.fake/'runs.json').read_text())
        self.assertEqual([int(run['env']['NATIVE_LOAD_CONNECTIONS']) for run in runs],[300,500,1024])
        for run in runs:
            self.assertEqual(run['env']['NATIVE_LOAD_INFLIGHT'],'262144')
            self.assertEqual(run['env']['NATIVE_LOAD_ADAPTIVE_INITIAL_CWND'],'32768')
            self.assertEqual(run['env']['NATIVE_LOAD_ADAPTIVE_MAX_CWND'],'65536')
        for command in [command for command in self.calls() if command[:1]==['run'] and '--env-file' in command]:
            self.assertEqual(command[command.index('--ulimit')+1],'nofile=65536:65536')
        capability=json.loads((self.results/'connection-capability.json').read_text())
        self.assertTrue(capability['supported'])
        self.assertEqual(capability['advertised_max_connections'],1024)
        self.assertTrue(json.loads((self.results/'summary.json').read_text())['completed'])

    def test_runner_large_sweep_probes_frozen_image_without_network_or_wallets_before_all_arms(self):
        self.prepare_runner()
        self.run_load('--connections',50,500)
        capabilities=[json.loads(line) for line in (self.fake/'capability-calls.jsonl').read_text().splitlines()]
        self.assertEqual(len(capabilities),1)
        probe=capabilities[0]
        self.assertEqual(probe,['run','--rm','--pull','never','--network','none',
                                '--entrypoint','/usr/local/bin/native-load-generator',IMAGE_ID,'--help'])
        calls=self.calls()
        workloads=[call for call in calls if call[:1]==['run'] and '--env-file' in call]
        self.assertEqual(len(workloads),2)
        self.assertLess(calls.index(probe),calls.index(workloads[0]))
        capability=json.loads((self.results/'connection-capability.json').read_text())
        self.assertEqual(capability['image_id'],IMAGE_ID)
        self.assertEqual(capability['requested_max_connections'],500)
        self.assertEqual(capability['probe_exit_code'],0)
        self.assertEqual(capability['help_sha256'],sha((self.results/'native-load-generator-help.txt').read_bytes()))
        self.assertTrue(capability['supported'])
        self.assertFalse(capability['wallets_mounted'])

    def test_runner_old_or_ambiguous_help_refuses_mixed_sweep_before_low_connection_arm(self):
        self.prepare_runner()
        cases=['  -c, --connections<arg>     persistent ADNL/TCP connections',
               '  -c, --connections<arg>     persistent ADNL/TCP connections (1..256)',
               '  --signed-run-size<arg>     another option (1..1024)',
               '  --connections<arg>     client count (1..1024)\n  --connections<arg>     duplicate (1..1024)']
        for index,help_text in enumerate(cases):
            self.results=self.root/('old-help-'+str(index))
            self.scenario(capability_help=help_text)
            result=self.run_load('--connections',50,500,success=False)
            self.assertIn('no load setup was started',result.stderr)
            capability=json.loads((self.results/'connection-capability.json').read_text())
            self.assertFalse(capability['supported'])
            self.assertEqual(capability['probe_exit_code'],0)
            self.assertFalse((self.results/'01-50-connections').exists())
        self.assertFalse((self.fake/'runs.json').exists())
        self.assertFalse(any(call[:1]==['run'] and '--env-file' in call for call in self.calls()))

    def test_runner_failed_help_probe_is_recorded_and_starts_no_workload(self):
        self.prepare_runner()
        self.scenario(capability_help_exit=125)
        self.run_load('--connections',10,300,success=False)
        capability=json.loads((self.results/'connection-capability.json').read_text())
        self.assertFalse(capability['supported'])
        self.assertEqual(capability['probe_exit_code'],125)
        self.assertIsNone(capability['advertised_max_connections'])
        self.assertTrue((self.results/'capability.stderr.log').is_file())
        self.assertFalse((self.fake/'runs.json').exists())

    def test_runner_inflight_must_cover_every_connection(self):
        self.prepare_runner()
        envfile=self.client/'remote-load.env'
        envfile.write_text(envfile.read_text().replace('NATIVE_LOAD_INFLIGHT=262144','NATIVE_LOAD_INFLIGHT=500'))
        result=self.run_load('--connections',1024,success=False)
        self.assertIn('NATIVE_LOAD_INFLIGHT is out of range',result.stderr)
        self.assertFalse(any(command[:1]==['run'] for command in self.calls()))

    def test_runner_recovered_retry_exhaustion_is_observation_and_continues_same_sources(self):
        self.prepare_runner()
        self.scenario(arm_final_overrides={'50':{'retry_exhausted':2,'retry_exhausted_sources':2,
                      'ingress_capacity_valid':False,'chain_capacity_valid':False,
                      'ingress_capacity_invalid_reasons':['retry_exhausted'],
                      'chain_capacity_invalid_reasons':['retry_exhausted']}})
        self.run_load('--connections',10,50,100)
        summary=json.loads((self.results/'summary.json').read_text())
        self.assertTrue(summary['completed'])
        self.assertTrue(summary['all_setups_attempted'])
        arm=summary['arms'][1]
        self.assertTrue(arm['valid_run'])
        self.assertTrue(arm['source_reuse_safe'])
        self.assertEqual(arm['capacity_classification'],'observation_only')
        self.assertEqual(arm['capacity_observation_reasons'],['recovered_retry_exhaustion'])
        self.assertEqual(summary['arms'][2]['capacity_classification'],'generator_capacity_eligible')
        self.assertTrue(all(arm['source_partition']['source_offset']==SOURCE_OFFSET for arm in summary['arms']))

    def test_runner_isolated_failure_continues_disjoint_balanced_sources_as_observation(self):
        self.prepare_runner()
        self.scenario(container_exit=2,failed_connections=50,arm_final_overrides={'50':{
            'benchmark_result_valid':False,'canonical_backlog':32,'canonical_backlog_after_drain':32,
            'canonical_total_backlog_after_drain':32,'run_incomplete_reasons':['canonical_cohorts_incomplete']}})
        result=self.run_load('--source-policy','isolated','--connections',10,50,100,success=False)
        summary=json.loads((self.results/'summary.json').read_text())
        self.assertFalse(summary['completed'])
        self.assertTrue(summary['all_setups_attempted'])
        self.assertEqual(summary['exit_code'],1)
        self.assertEqual(len(summary['arms']),3)
        ranges=[arm['source_partition'] for arm in summary['arms']]
        self.assertEqual([partition['source_offset'] for partition in ranges],[SOURCE_OFFSET,SOURCE_OFFSET+8,SOURCE_OFFSET+16])
        self.assertEqual([partition['sources'] for partition in ranges],[8,8,8])
        self.assertTrue(all(partition['source_policy']=='isolated' for partition in ranges))
        self.assertFalse(summary['arms'][1]['source_reuse_safe'])
        self.assertTrue(summary['arms'][2]['valid_run'])
        self.assertEqual(summary['arms'][2]['capacity_classification'],'observation_only')
        self.assertEqual(summary['arms'][2]['prior_unresolved_arms'],['02-50-connections'])
        self.assertEqual(summary['arms'][2]['capacity_observation_reasons'],['prior_arm_source_cohorts_unresolved'])
        self.assertIn('next setup uses disjoint sources',result.stderr)
        runs=json.loads((self.fake/'runs.json').read_text())
        for run,partition in zip(runs,ranges):
            self.assertEqual(int(run['env']['NATIVE_LOAD_SOURCE_OFFSET']),partition['source_offset'])
            self.assertEqual(int(run['env']['NATIVE_LOAD_SOURCES']),partition['sources'])
        original=(self.results/'remote-load.env').read_text()
        self.assertIn('NATIVE_LOAD_SOURCES='+str(SOURCES),original)

    def test_runner_isolated_policy_refuses_unbalanced_manifest_before_launch(self):
        self.prepare_runner()
        manifest=self.client/'client-data/wallets/native-payment-lanes.manifest'
        lines=manifest.read_text().splitlines()
        for index,line in enumerate(lines):
            fields=line.split()
            if fields[0]==str(SOURCE_OFFSET):
                fields[1]=str((int(fields[1])+1)%4)
                lines[index]=' '.join(fields)
        manifest.write_text('\n'.join(lines)+'\n')
        result=self.run_load('--source-policy','isolated','--connections',10,50,100,success=False)
        self.assertIn('manifest sources are not in balanced lane order',result.stderr)
        self.assertFalse(any(command[:1]==['run'] for command in self.calls()))

    def test_runner_isolated_policy_requires_enough_sources_for_lanes_and_workers(self):
        self.prepare_runner()
        envfile=self.client/'remote-load.env'
        original=envfile.read_text()
        for total,error in [(8,'complete lane set'),(12,'NATIVE_LOAD_SOURCES is out of range')]:
            self.results=self.root/('isolated-small-'+str(total))
            envfile.write_text(re.sub(r'NATIVE_LOAD_SOURCES=[0-9]+','NATIVE_LOAD_SOURCES='+str(total),original))
            result=self.run_load('--source-policy','isolated','--connections',10,50,100,success=False)
            self.assertIn(error,result.stderr)
        self.assertFalse(any(command[:1]==['run'] for command in self.calls()))

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
