#!/usr/bin/env python3
"""Registry/start integration with fake Docker, temporary repos, and no network."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('remote_fixture', Path(__file__).with_name('native-remote-client-test.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class RegistryImagesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='native-registry-offline-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root/'repository'
        self.repo.mkdir()
        for name in ('prepare-native-images.sh','start-native-genesis.sh'):
            shutil.copy2(ROOT/name, self.repo/name)
        (self.repo/'docker-compose.yaml').write_text('services:\n  genesis: {}\n  native-load-generator: {}\n')
        self.env_file = self.root/'custom client.env'
        self.env_file.write_text('TON_IMAGE=ghcr.io/corton-nommander/ton\nTON_BRANCH=master\n')
        (self.repo/'.env').write_bytes(self.env_file.read_bytes())
        self.fake = self.root/'fake'
        self.fake.mkdir()
        self.bin = self.root/'bin'
        self.bin.mkdir()
        docker = self.bin/'docker'
        docker.write_text(fixture.FAKE_DOCKER)
        docker.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ.get('PATH',''),
                        FAKE_DOCKER_ROOT=str(self.fake), DOCKER_HOST='unix:///var/run/docker.sock',
                        PYTHONDONTWRITEBYTECODE='1')
        self.env.pop('DOCKER_CONTEXT',None)
        self.receipt = self.root/'images.json'
        self.scenario(build_new_id=True)

    def scenario(self, **settings):
        (self.fake/'scenario.json').write_text(json.dumps(settings))

    def calls(self):
        path=self.fake/'calls.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def invoke(self, script, *args, success=True):
        result=subprocess.run([str(self.repo/script), '--env-file', str(self.env_file), '--receipt', str(self.receipt),
                               *map(str,args)], env=self.env, cwd=self.root, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
        self.assertEqual(result.returncode==0,success,result.stdout+'\n'+result.stderr)
        return result

    def builds(self):
        return [call for call in self.calls() if call[:1]==['compose'] and 'build' in call]

    def starts(self):
        return [call for call in self.calls() if call[:1]==['compose'] and 'up' in call]

    def assert_frozen_build(self, services):
        calls=self.calls()
        pulls=[call for call in calls if call[:1]==['pull']]
        self.assertEqual(pulls,[['pull',fixture.BASE_REFERENCE]])
        builds=self.builds()
        self.assertEqual(len(builds),1)
        build=builds[0]
        self.assertLess(calls.index(pulls[0]),calls.index(build))
        self.assertEqual(build[-len(services):],services)
        self.assertEqual(build[build.index('--build-arg')+1],'TON_BASE_IMAGE='+fixture.BASE_DIGEST)
        self.assertIn('--pull',build)
        self.assertEqual(build[build.index('--env-file')+1],str(self.env_file))
        self.assertEqual(build[build.index('--project-directory')+1],str(self.repo))
        snapshots=[json.loads(line) for line in (self.fake/'compose-environment.jsonl').read_text().splitlines()]
        built=next(row for row in snapshots if 'build' in row['command'])
        self.assertEqual(built['TON_BASE_IMAGE'],fixture.BASE_DIGEST)
        self.assertEqual(built['TON_BUILD_PULL'],'true')
        receipt=json.loads(self.receipt.read_text())
        self.assertEqual(receipt['schema'],'native-images-v1')
        self.assertEqual(receipt['base']['reference'],fixture.BASE_REFERENCE)
        self.assertEqual(receipt['base']['digest'],fixture.BASE_DIGEST)
        self.assertEqual(receipt['base']['id'],fixture.BASE_IMAGE_ID)
        self.assertEqual(receipt['base']['revision'],fixture.SOURCE_REVISION)
        self.assertEqual(set(receipt['services']),set(services))
        for service in services:
            self.assertEqual(receipt['services'][service]['id'],fixture.BUILT_IMAGE_ID)
            self.assertEqual(receipt['services'][service]['revision'],fixture.SOURCE_REVISION)
        return receipt

    def test_default_preparation_refreshes_existing_images_from_one_digest(self):
        # Fake derived tags already resolve before preparation; they must still rebuild.
        self.invoke('prepare-native-images.sh')
        receipt=self.assert_frozen_build(['genesis','native-load-generator'])
        self.assertEqual(receipt['services']['genesis']['reference'],'validator:compose-fixture')
        self.assertEqual(receipt['services']['native-load-generator']['reference'],fixture.CONFIGURED_IMAGE_REF)
        self.assertEqual(self.starts(),[])
        self.assertFalse(any(call[:1] in (['run'],['start'],['restart']) for call in self.calls()))

    def test_selected_generator_preparation_never_builds_or_starts_genesis(self):
        self.invoke('prepare-native-images.sh','--services','native-load-generator')
        self.assert_frozen_build(['native-load-generator'])
        self.assertEqual(self.starts(),[])
        self.assertNotIn('genesis',self.builds()[0])

    def test_start_prepares_both_then_starts_only_genesis_without_reset(self):
        self.invoke('start-native-genesis.sh')
        self.assert_frozen_build(['genesis','native-load-generator'])
        starts=self.starts()
        self.assertEqual(len(starts),1)
        self.assertEqual(starts[0][starts[0].index('up'):],['up','-d','--no-deps','--no-build','--pull','never','genesis'])
        self.assertLess(self.calls().index(self.builds()[0]),self.calls().index(starts[0]))
        self.assertEqual(starts[0][starts[0].index('--env-file')+1],str(self.env_file))
        for call in self.calls():
            self.assertFalse(any(token in call for token in ('down','rm','volume','--renew-anon-volumes','--force-recreate')))

    def test_pull_failure_cannot_use_stale_local_images_or_start(self):
        self.scenario(pull_fails=True)
        self.invoke('start-native-genesis.sh',success=False)
        self.assertEqual(self.builds(),[])
        self.assertEqual(self.starts(),[])
        self.assertFalse(self.receipt.exists())

    def test_build_failure_cannot_publish_receipt_or_start(self):
        self.scenario(build_fails=True)
        self.invoke('start-native-genesis.sh',success=False)
        self.assertEqual(len(self.builds()),1)
        self.assertEqual(self.starts(),[])
        self.assertFalse(self.receipt.exists())

    def test_derived_revision_mismatch_cannot_publish_receipt_or_start(self):
        self.scenario(derived_revision='d'*40)
        self.invoke('start-native-genesis.sh',success=False)
        self.assertEqual(len(self.builds()),1)
        self.assertEqual(self.starts(),[])
        self.assertFalse(self.receipt.exists())

    def test_missing_base_revision_fails_before_build(self):
        self.scenario(base_revision='')
        self.invoke('start-native-genesis.sh',success=False)
        self.assertEqual(self.builds(),[])
        self.assertEqual(self.starts(),[])
        self.assertFalse(self.receipt.exists())

    def test_expected_running_revision_mismatch_fails_before_build(self):
        self.scenario(base_revision='d'*40)
        self.invoke('prepare-native-images.sh','--services','native-load-generator',
                    '--expected-revision',fixture.SOURCE_REVISION,success=False)
        self.assertEqual(self.builds(),[])
        self.assertFalse(self.receipt.exists())

    def test_digest_absence_or_identity_mismatch_fails_before_build(self):
        for scenario in ({'missing_base_digest':True},{'base_digest_identity_mismatch':True}):
            with self.subTest(scenario=scenario):
                self.scenario(**scenario)
                self.invoke('start-native-genesis.sh',success=False)
                self.assertEqual(self.builds(),[])
                self.assertEqual(self.starts(),[])
                self.assertFalse(self.receipt.exists())

    def test_service_base_mismatch_is_rejected_before_registry_pull(self):
        self.scenario(different_service_base=True)
        self.invoke('prepare-native-images.sh',success=False)
        self.assertFalse(any(call[:1]==['pull'] for call in self.calls()))
        self.assertEqual(self.builds(),[])
        self.assertFalse(self.receipt.exists())

    def test_remote_context_cannot_pull_build_or_start(self):
        self.scenario(remote_context=True)
        self.env['DOCKER_CONTEXT']='remote-fixture'
        self.invoke('start-native-genesis.sh',success=False)
        self.assertFalse(any(call[:1]==['pull'] for call in self.calls()))
        self.assertEqual(self.builds(),[])
        self.assertEqual(self.starts(),[])

    def test_real_dockerfiles_consume_the_digest_argument(self):
        for relative in ('Dockerfile','native-load-generator/Dockerfile'):
            with self.subTest(dockerfile=relative):
                lines=(ROOT/relative).read_text().splitlines()
                self.assertIn('ARG TON_BASE_IMAGE=${TON_IMAGE}:${TON_BRANCH}',lines)
                self.assertEqual([line for line in lines if line.startswith('FROM ')],['FROM ${TON_BASE_IMAGE}'])


if __name__=='__main__':
    unittest.main(verbosity=2)
