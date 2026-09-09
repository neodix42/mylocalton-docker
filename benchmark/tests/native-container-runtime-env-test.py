#!/usr/bin/env python3
"""Exercise the actual Docker-inspect projection with synthetic data, without Docker."""
import json
from pathlib import Path
import re
import subprocess
import unittest

WRAPPER = Path(__file__).resolve().parents[2] / 'run-native-benchmark.sh'


def captured_environment(values):
    source = WRAPPER.read_text()
    marker = 'docker inspect genesis "$container_name" session-stats |'
    assert source.count(marker) == 1, 'ambiguous container runtime collector'
    section = source.split(marker, 1)[1]
    match = re.match(r"\s+jq '([\s\S]+?)' >\"\$runtime_file\"", section)
    assert match, 'container runtime jq projection not found'
    container = {'Name': '/genesis', 'Image': 'sha256:' + 'a' * 64,
                 'Config': {'Image': 'example:fixed', 'Env': values, 'Labels': {}},
                 'State': {'Status': 'running', 'Health': {'Status': 'healthy'}},
                 'HostConfig': {}, 'Mounts': []}
    result = subprocess.run(['jq', match[1]], input=json.dumps([container]),
                            text=True, capture_output=True, check=True)
    return json.loads(result.stdout)[0]['benchmark_environment']


class ContainerRuntimeEnvironmentTest(unittest.TestCase):
    def test_cpu_feature_flags_present_in_both_modes(self):
        for value in ('0', '1'):
            expected = [f'TON_KEYRING_PREPARED_SIGNING={value}',
                        f'TON_OVERLAY_LOCAL_SIGNATURE_REUSE={value}',
                        f'TON_NATIVE_CANDIDATE_METADATA_PROJECTION={value}']
            with self.subTest(value=value):
                self.assertEqual(captured_environment(expected), expected)

    def test_existing_native_workload_controls_preserved(self):
        expected = ['TON_NATIVE_ADMISSION_CONFIG_CACHE=1',
                    'TON_NATIVE_ADMISSION_SHARD_SHARING=0',
                    'TON_NATIVE_ADMISSION_SNAPSHOT_REFRESH=0',
                    'TON_NATIVE_RECONCILIATION_PROFILE=1',
                    'NATIVE_LOAD_SUBMIT_COALESCE_MS=20',
                    'NATIVE_PAYMENT_LANE_DEPTH=2', 'ACTUAL_MIN_SPLIT=2']
        self.assertEqual(captured_environment(expected), expected)

    def test_exact_new_names_only_and_unrelated_values_excluded(self):
        values = ['PREFIX_TON_KEYRING_PREPARED_SIGNING=1',
                  'TON_KEYRING_PREPARED_SIGNING_EXTRA=1',
                  'TON_OVERLAY_LOCAL_SIGNATURE_REUSE_EXTRA=1',
                  'TON_KEYRING_UNRELATED=1', 'TON_OVERLAY_UNRELATED=1',
                  'UNRELATED_SECRET=sentinel', 'PATH=/bin',
                  'TON_KEYRING_PREPARED_SIGNING=1',
                  'TON_OVERLAY_LOCAL_SIGNATURE_REUSE=0']
        self.assertEqual(captured_environment(values), values[-2:])


if __name__ == '__main__':
    unittest.main()
