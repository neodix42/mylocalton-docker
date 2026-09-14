#!/usr/bin/env python3
"""Validate the real Compose profile and the pre-bootstrap disk-fallback guard."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / 'docker/scripts/require-ram-storage.sh'


class RamProfileTest(unittest.TestCase):
    def compose(self, profile, all_profiles=False):
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('COMPOSE_', 'NATIVE_', 'TON_', 'GENESIS_', 'SESSION_STATS_', 'MLT_'))}
        return json.loads(subprocess.check_output([
            'docker', 'compose', '-f', str(ROOT / 'docker-compose.yaml'),
            '--project-directory', str(ROOT), '--env-file', str(ROOT / profile),
            '--profile', '*' if all_profiles else 'native-load-generator', '--profile', 'session-stats',
            'config', '--format', 'json'], env=env, text=True))

    def test_physical_profile_accounts_for_swap_and_stats_volume_tree(self):
        config = self.compose('.env.physical')
        services = config['services']
        for name in ('genesis', 'native-load-generator', 'session-stats'):
            item = services[name]
            memory = int(item['deploy']['resources']['limits']['memory'])
            self.assertGreater(memory, 0)
            self.assertEqual(memory, int(item['memswap_limit']))
        self.assertEqual(services['genesis']['environment']['NATIVE_RAM_ENABLED'], '1')
        self.assertIn('--celldb-in-memory', services['genesis']['environment']['CUSTOM_PARAMETERS'])
        self.assertTrue(all(m['type'] == 'volume' for m in services['genesis']['volumes']))
        root = '/mnt/mylocalton-ram'
        volumes = {v['target']: v['source'] for v in services['session-stats']['volumes']}
        self.assertEqual(volumes['/docker-volumes'], root + '/data/volumes')
        self.assertEqual(volumes['/hostfs'], root)
        self.assertEqual(services['session-stats']['environment']['TON_WORK_DOCKER_VOLUME'],
                         config['name'] + '_ton-db-val0')
        load = services['native-load-generator']['environment']
        for key, expected in {'NATIVE_LOAD_TARGET_TPS': '0', 'NATIVE_LOAD_DURATION_SECONDS': '600',
                              'NATIVE_LOAD_WARMUP_SECONDS': '60', 'NATIVE_LOAD_DRAIN_TIMEOUT_SECONDS': '180',
                              'NATIVE_LOAD_NATIVE_RUN_BATCHING': '1',
                              'NATIVE_LOAD_NATIVE_TRANSFER_RUN_SIZE': '16'}.items():
            self.assertEqual(load[key], expected)
        self.assertEqual(load['NATIVE_LOAD_PAYMENT_LANE_DEPTH'], '3')

    def test_default_keeps_disk_volumes_and_no_new_memory_limit(self):
        config = self.compose('.env')
        services = config['services']
        self.assertEqual(config['networks']['main']['ipam']['config'], [{'subnet': '172.28.1.0/24'}])
        self.assertEqual(config['networks']['main']['name'], 'mylocalton-network')
        self.assertEqual(config['networks']['main']['driver_opts']['com.docker.network.bridge.name'], '')
        genesis = services['genesis']
        self.assertEqual(genesis['environment']['NATIVE_RAM_ENABLED'], '0')
        self.assertEqual(int(genesis['deploy']['resources']['limits'].get('memory', 0)), 0)
        self.assertEqual(genesis.get('memswap_limit', 0), 0)
        db = next(v for v in genesis['volumes'] if v['target'] == '/var/ton-work/db')
        self.assertEqual((db['type'], db['source']), ('volume', 'ton-db-val0'))

    def test_physical_network_remaps_addresses_and_service_endpoints(self):
        config = self.compose('.env.physical', all_profiles=True)
        network = config['networks']['main']
        self.assertEqual(network['ipam']['config'], [{'subnet': '10.203.1.0/24'}])
        self.assertEqual(network['name'], 'mylocalton-ram-network')
        self.assertEqual(network['driver_opts']['com.docker.network.bridge.name'], 'tonram1')
        self.assertNotIn('172.28.1.', json.dumps(config))
        for name, service in config['services'].items():
            for attachment in service.get('networks', {}).values():
                address = (attachment or {}).get('ipv4_address', '')
                if address:
                    self.assertTrue(address.startswith('10.203.1.'), (name, address))

    def run_guard(self, enabled, bad_path=None):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)
            stat = p/'stat'
            stat.write_text('#!/bin/bash\nprintf "%s\\n" "${@: -1}" >> "$TRACE"\n'
                            'if [[ "${@: -1}" == "${BAD_PATH:-never}" ]]; then echo ext2/ext3; '
                            'else echo tmpfs; fi\n')
            stat.chmod(0o755)
            trace = p/'trace'
            env = dict(os.environ, PATH=str(p) + ':' + os.environ['PATH'], TRACE=str(trace),
                       NATIVE_RAM_ENABLED=enabled, BAD_PATH=bad_path or 'never')
            run = subprocess.run(['bash', str(GUARD)], env=env, capture_output=True, text=True)
            paths = trace.read_text().splitlines() if trace.exists() else []
            return run, paths

    def test_guard_rejects_disk_even_when_celldb_would_be_in_memory(self):
        for bad in ('/', '/usr/local/bin', '/var/ton-work/db', '/usr/share/data',
                    '/var/ton-work/db/native-spam/wallets', '/tmp', '/var/tmp', '/var/log'):
            run, paths = self.run_guard('1', bad)
            self.assertEqual(run.returncode, 2, bad)
            self.assertIn(bad, run.stderr)
            self.assertEqual(paths[-1], bad)

    def test_guard_accepts_all_ram_and_leaves_default_untouched(self):
        run, paths = self.run_guard('1')
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(len(paths), 8)
        for disabled in ('0', ''):
            run, paths = self.run_guard(disabled)
            self.assertEqual(run.returncode, 0)
            self.assertEqual(paths, [])
        run, paths = self.run_guard('true')
        self.assertEqual(run.returncode, 2)
        self.assertEqual(paths, [])


if __name__ == '__main__':
    unittest.main()
