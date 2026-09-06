#!/usr/bin/env python3
"""Offline tests: no Docker daemon, network, generator or validator workload."""
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[1] / 'run-native-connections-sweep.py'
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('sweep', PATH)
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)


def options(*args):
    return sweep.validate_options(sweep.parser().parse_args(list(args)))


def images():
    return {name: {'reference': name + ':fixture', 'image_id': 'sha256:' + str(i + 1) * 64,
                   'revision': 'a' * 40} for i, name in enumerate(sweep.SERVICES)}


def validator():
    return {'identity': {'container_id': 'container', 'image_id': images()['genesis']['image_id'],
                        'started_at': '2026-09-06T00:00:00Z', 'restart_count': 0, 'running': True,
                        'validator_process': {'pid': 31, 'start_ticks': 12345}},
            'resources': {'mounts': [{'Name': 'fixture_shared', 'Destination': '/usr/share/data'}]}}


def config(a, count):
    return {'services': {name: {'image': name + ':fixture',
                               'environment': sweep.settings(a, count) if name == 'native-load-generator' else {},
                               'volumes': [{'type': 'volume', 'source': 'shared', 'target': '/usr/share/data'}]}
                         for name in sweep.SERVICES}, 'volumes': {'shared': {'name': 'fixture_shared'}}}


def summary(a, count):
    strict = {'required': True, 'valid': True,
              'validator_before': validator()['identity'], 'validator_after': validator()['identity'],
              'generator_image_before': images()['native-load-generator']['image_id'],
              'generator_image_after': images()['native-load-generator']['image_id'],
              'generator_container_before': 'generator', 'generator_container_after': 'generator'}
    final = {'load_mode': 'bounded_unpaced' if a.target_tps == 0 else 'paced',
             'rate_limit_enabled': a.target_tps > 0, 'target_tps_applicable': a.target_tps > 0,
             'configured_connections': count, 'configured_workers': a.effective_workers,
             'configured_signers': a.signers, 'configured_sources': a.sources,
             'adaptive_initial_cwnd': a.initial_cwnd, 'initial_congestion_window': a.initial_cwnd,
             'target_tps': a.target_tps, 'canonical_backlog_after_drain': 0,
             'steady_offered_avg_tps': 110, 'steady_mempool_accept_avg_tps': 109,
             'canonical_chain_measure_avg_tps': 100, 'measure_elapsed_s': a.duration,
             'steady_offered': 110 * a.duration, 'steady_mempool_accepted': 109 * a.duration}
    accepted = {key: True for key in ['chain_correctness_valid', 'run_complete',
                'native_signed_run_quantum_valid', 'canonical_lane_balance_valid', 'native_run_batching_valid',
                'validator_cleanup_valid', 'chain_capacity_valid', 'ingress_capacity_valid']}
    accepted.update({'correctness_invalid_reasons': [], 'run_incomplete_reasons': [],
                     'chain_capacity_invalid_reasons': []})
    runtime = [{'name': name, 'image_id': images()[name]['image_id'],
                'benchmark_environment': [f'{k}={v}' for k, v in sweep.settings(a, count).items()
                                          if k.startswith('NATIVE_LOAD_')] if name == 'native-load-generator' else []}
               for name in sweep.SERVICES]
    return {'run': {'benchmark_exit_code': 0, 'interrupted': False, 'containers': runtime},
            'generator': {'final': final, 'valid_canonical_run': True},
            'strict_image_reuse': strict, 'acceptance': accepted,
            'load_level_acceptance': {'valid': True, 'classification': 'capacity_eligible',
                                      'capacity_claim_allowed': True}}


class PolicyTests(unittest.TestCase):
    def test_default_disjoint_shares_and_conservation(self):
        a = options()
        self.assertEqual(a.connections, [10, 50, 100])
        for count in a.connections:
            workers = sweep.distribution(a, count)
            self.assertEqual(sum(w['connections'] for w in workers), count)
            self.assertEqual(sum(w['sources'] for w in workers), 24576)
            self.assertEqual([w['source_offset'] for w in workers], [0, 4096, 8192, 12288, 16384, 20480])
            for field, total in [('initial_cwnd', 32768), ('max_cwnd', 65536), ('inflight', 262144)]:
                self.assertEqual(sum(c[field] for w in workers for c in w['clients']), total)
            self.assertTrue(all(c['initial_cwnd'] >= 16 for w in workers for c in w['clients']))

    def test_connection_lists_and_small_worker_count(self):
        self.assertEqual(options('--connections', '10', '50,100').connections, [10, 50, 100])
        a = options('--connections', '1,10')
        self.assertEqual(a.effective_workers, 1)
        self.assertEqual(len(sweep.distribution(a, 10)), 1)
        for values in ['0', '-1', '10,10', '1,,2', 'NaN', '1.5']:
            with self.assertRaises(sweep.EvidenceError):
                options('--connections=' + values)

    def test_uneven_worker_budget_rejects_below_quantum(self):
        # Total initial credits cover two 16-runs, but 3 clients require 48.
        a = options('--connections', '3', '--initial-cwnd', '32')
        with self.assertRaises(sweep.EvidenceError):
            sweep.distribution(a, 3)
        for args in [('--target-tps', 'NaN'), ('--source-backlog', '15'),
                     ('--initial-cwnd', '65537'), ('--batch-size', '1'),
                     ('--global-config', '/tmp/config.json'), ('--global-config', '/usr/share/data/../config.json')]:
            with self.assertRaises(sweep.EvidenceError):
                options(*args)

    def test_plan_never_probes_or_loads(self):
        a = options('--plan-only')
        with patch.object(sweep.Host, 'json', side_effect=AssertionError('Docker')), \
             patch.object(sweep, 'run_arm', side_effect=AssertionError('workload')), \
             contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(sweep.execute(a), 0)
        self.assertEqual(json.loads(out.getvalue())['common_environment']['NATIVE_LOAD_TARGET_TPS'], '0')

    def test_exact_service_selection_ignores_dependency_order(self):
        class Fake(sweep.Host):
            def json(self, cmd):
                wanted = cmd[-1].split(':')[0]
                return [{'Id': images()[wanted]['image_id'], 'Config': {'Labels': {
                    'org.opencontainers.image.revision': 'a' * 40}}}]
        a = options()
        c = config(a, 10)
        for order in [sweep.SERVICES, tuple(reversed(sweep.SERVICES))]:
            c['services'] = {n: c['services'][n] for n in order}
            resolved = Fake().images(c)
            self.assertEqual(resolved['native-load-generator']['image_id'], 'sha256:' + '2' * 64)
            self.assertNotEqual(resolved['native-load-generator']['image_id'], resolved['genesis']['image_id'])

    def test_endpoint_process_and_live_volume_fail_closed(self):
        one = {'liteservers': [{'id': {'key': 'public'}, 'ip': 123, 'port': 40004}]}
        server = sweep.endpoint(one)
        for malformed in [{}, {'liteservers': []}, {'liteservers': one['liteservers'] * 2}]:
            with self.assertRaises(sweep.EvidenceError):
                sweep.endpoint(malformed)
        changed = copy.deepcopy(one)
        changed['liteservers'][0]['ip'] += 1
        with self.assertRaises(sweep.EvidenceError):
            sweep.endpoint(changed, server)
        self.assertEqual(sweep.public_process('31\t12345\n'), {'pid': 31, 'start_ticks': 12345})
        for rows in ['', '31\t12345\n32\t12346\n', '31\t0\n', '31\tgarbage\n']:
            with self.assertRaises(sweep.EvidenceError):
                sweep.public_process(rows)
        class Fake(sweep.Host):
            def text(self, cmd):
                return json.dumps(one)
        a = options()
        Fake().topology(a, config(a, 10), validator())
        bad = validator()
        bad['resources']['mounts'][0]['Name'] = 'other_volume'
        with self.assertRaises(sweep.EvidenceError):
            Fake().topology(a, config(a, 10), bad)

    def test_profile_command_cannot_build_or_recreate_validator(self):
        a = options()
        env = sweep.settings(a, 10)
        self.assertEqual(env['BENCHMARK_IMAGES_PREBUILT'], '1')
        self.assertEqual(env['BENCHMARK_STRICT_IMAGE_REUSE'], '1')
        self.assertEqual(env['BENCHMARK_RECREATE_GENESIS'], '0')
        cmd = sweep.profile_command(a, env, [sweep.ROOT / 'run-native-benchmark.sh', a.env_file, '/tmp/fixture'])
        self.assertNotIn('--build', cmd)
        self.assertNotIn('--force-recreate', cmd)
        self.assertIn('env -u BENCHMARK_EXT_MESSAGES_BROADCAST_DISABLED', cmd[2])


class AcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.a = options()
        self.s = summary(self.a, 10)
        self.frozen = {'validator': validator(), 'images': images()}

    def assess(self, s):
        return sweep.assess(s, self.a, 10, self.frozen, 0)

    def test_acceptance_and_safe_pressure_observation_are_distinct(self):
        self.assertTrue(self.assess(self.s)['capacity_claim_allowed'])
        for reason in ['offer_target_not_attained', 'canonical_backpressure',
                       'offered_load_not_above_canonical_throughput']:
            s = copy.deepcopy(self.s)
            s['acceptance']['chain_capacity_valid'] = False
            s['acceptance']['ingress_capacity_valid'] = False
            s['acceptance']['chain_capacity_invalid_reasons'] = [reason]
            s['load_level_acceptance'] = {'valid': False, 'classification': 'rejected', 'capacity_claim_allowed': False}
            r = self.assess(s)
            self.assertTrue(r['continue_safe'])
            self.assertFalse(r['capacity_claim_allowed'])
            self.assertEqual(r['original_acceptance']['chain_capacity_invalid_reasons'], [reason])
            self.assertEqual(r['target_attainment'], 'not_applicable')

    def test_every_mandatory_gate_blocks_capacity_and_continuation(self):
        mutations = [(['acceptance', key], False) for key in ['chain_correctness_valid', 'run_complete',
            'native_signed_run_quantum_valid', 'canonical_lane_balance_valid', 'native_run_batching_valid',
            'validator_cleanup_valid']]
        mutations += [(['strict_image_reuse', 'valid'], False),
            (['strict_image_reuse', 'validator_after', 'validator_process', 'start_ticks'], 12346),
            (['strict_image_reuse', 'generator_image_before'], images()['genesis']['image_id']),
            (['generator', 'final', 'configured_connections'], 12),
            (['generator', 'final', 'initial_congestion_window'], 2560),
            (['generator', 'final', 'rate_limit_enabled'], 'false'),
            (['generator', 'final', 'steady_mempool_accepted'], 1),
            (['generator', 'final', 'measure_elapsed_s'], 179),
            (['generator', 'final', 'canonical_backlog_after_drain'], 16),
            (['generator', 'final', 'canonical_chain_measure_avg_tps'], None),
            (['run', 'containers'], []), (['run', 'interrupted'], True)]
        for path, value in mutations:
            with self.subTest(path=path):
                s = copy.deepcopy(self.s)
                item = s
                for key in path[:-1]:
                    item = item[key]
                item[path[-1]] = value
                r = self.assess(s)
                self.assertFalse(r['continue_safe'])
                self.assertFalse(r['capacity_claim_allowed'])

    def test_actual_offered_must_exceed_canonical_even_with_claim_flag(self):
        self.s['generator']['final']['canonical_chain_measure_avg_tps'] = 110
        r = self.assess(self.s)
        self.assertTrue(r['continue_safe'])
        self.assertFalse(r['capacity_claim_allowed'])

    def test_completed_summary_is_hashed_before_use(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'summary.json'
            p.write_text(json.dumps(self.s))
            s, original = sweep.load_hashed(p)
            p.write_text('{}')
            self.assertEqual(s, self.s)
            self.assertNotEqual(original, sweep.sha(p.read_bytes()))


class SequentialTests(unittest.TestCase):
    def execute_fixture(self, output, failed_first=False, change_identity=False):
        a = options('--output', str(output))
        calls = []
        class FakeHost:
            def json(self, command):
                count = int(next(v.split('=', 1)[1] for v in command if v.startswith('NATIVE_LOAD_CONNECTIONS=')))
                return config(a, count)
            def validator(self):
                result = validator()
                if change_identity and calls:
                    result['identity']['validator_process']['start_ticks'] += 1
                return result
            def images(self, c):
                return images()
            def topology(self, *args):
                return {'config_sha256': 'fixed', 'liteserver_count': 1}
        def run(command, logfile, timeout):
            count = int(next(v.split('=', 1)[1] for v in command if v.startswith('NATIVE_LOAD_CONNECTIONS=')))
            calls.append(count)
            bundle = Path(command[-1])
            bundle.mkdir()
            value = summary(a, count)
            if failed_first:
                value['acceptance']['validator_cleanup_valid'] = False
            (bundle / 'benchmark-summary.json').write_text(json.dumps(value))
            logfile.write_text('fixture only')
            return 0
        with patch.object(sweep, 'run_arm', run), contextlib.redirect_stdout(io.StringIO()), \
             contextlib.redirect_stderr(io.StringIO()):
            status = sweep.execute(a, FakeHost())
        return status, calls, json.loads((output / 'sweep-summary.json').read_text())

    def test_order_and_saved_hashes(self):
        with tempfile.TemporaryDirectory() as d:
            status, calls, report = self.execute_fixture(Path(d) / 'out')
            self.assertEqual((status, calls), (0, [10, 50, 100]))
            self.assertTrue(report['complete'])
            for arm in report['arms']:
                self.assertEqual(arm['summary_sha256'], sweep.sha((Path(arm['raw_bundle']) / 'benchmark-summary.json').read_bytes()))

    def test_cleanup_failure_stops_after_first_and_retains_evidence(self):
        with tempfile.TemporaryDirectory() as d:
            status, calls, report = self.execute_fixture(Path(d) / 'out', failed_first=True)
            self.assertEqual((status, calls), (3, [10]))
            self.assertFalse(report['complete'])
            self.assertIsNone(report['capacity_winner_connections'])
            self.assertEqual(len(report['arms']), 1)

    def test_changed_process_between_arms_never_starts_next(self):
        with tempfile.TemporaryDirectory() as d:
            status, calls, report = self.execute_fixture(Path(d) / 'out', change_identity=True)
            self.assertEqual((status, calls), (3, [10]))
            self.assertIn('validator process/resources changed', report['error'])
            self.assertIsNone(report['capacity_winner_connections'])


if __name__ == '__main__':
    unittest.main()
