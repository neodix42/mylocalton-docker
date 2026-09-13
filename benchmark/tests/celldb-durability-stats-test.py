#!/usr/bin/env python3

import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True

path = Path(__file__).resolve().parents[1] / 'remote/celldb_durability_stats.py'
spec = importlib.util.spec_from_file_location('celldb_durability_stats', path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def histogram(p50=1, p95=2, p99=3, p100=4, count=5, total=6):
    return f'P50 : {p50} P95 : {p95} P99 : {p99} P100 : {p100} COUNT : {count} SUM : {total}'


def complete_stats(*, sync=True):
    rows = [
        f'{m.PREFIX}enabled true',
        f'{m.PREFIX}sync_writes {str(sync).lower()}',
        f'{m.PREFIX}wal_enabled true',
        f'{m.PREFIX}periodic_reset_enabled false',
    ]
    for index, key in enumerate(m.COUNTER_FIELDS, 1):
        rows.append(f'{key} {index}')
    rows.append(f'{m.PREFIX}queue.max_depth 17')
    rows.append(f'{m.PREFIX}reset_generation 0')
    for key in m.HISTOGRAM_FIELDS:
        rows.append(f'{key}\t\t{histogram()}')
    return '\n'.join(rows)


def replace_payload(text, key, payload):
    rows = text.splitlines()
    for index, row in enumerate(rows):
        if row.split(None, 1)[0] == key:
            rows[index] = f'{key} {payload}'
            return '\n'.join(rows)
    raise AssertionError(f'missing fixture key: {key}')


class CellDbDurabilityStatsTests(unittest.TestCase):
    def test_absent_profile_is_unavailable(self):
        result = m.parse_stats_text('db.celldb.store_cell.micros P50 : 1\n')
        self.assertFalse(result['telemetry_available'])
        self.assertFalse(result['capture_complete'])
        self.assertEqual(result['invalid_fields'], [])
        self.assertEqual(len(result['missing_fields']), len(m.ALL_FIELDS))

    def test_complete_profile_parses_exact_schema(self):
        result = m.parse_stats_text(complete_stats(sync=False))
        self.assertTrue(result['telemetry_available'])
        self.assertTrue(result['capture_complete'])
        self.assertEqual(result['missing_fields'], [])
        self.assertEqual(result['invalid_fields'], [])
        self.assertEqual(result['config'], {
            'enabled': True, 'sync_writes': False, 'wal_enabled': True,
            'periodic_reset_enabled': False,
        })
        self.assertEqual(result['gauges']['queue_max_depth'], 17)
        self.assertEqual(result['gauges']['reset_generation'], 0)
        self.assertEqual(result['counters']['queue_wait_count'], 1)
        self.assertEqual(result['histograms']['commit_wall']['count'], 5)
        self.assertEqual(result['histograms']['commit_wall']['sum_us'], 6)

    def test_last_exact_sample_wins_and_near_prefix_is_ignored(self):
        text = '\n'.join([
            f'near_{m.PREFIX}sync_writes false',
            f'{m.PREFIX}sync_writes_extra false',
            complete_stats(sync=True),
            f'{m.PREFIX}sync_writes false',
        ])
        result = m.parse_stats_text(text)
        self.assertTrue(result['capture_complete'])
        self.assertFalse(result['config']['sync_writes'])

    def test_later_empty_or_malformed_exact_sample_fails(self):
        key = m.PREFIX + 'commit.calls'
        for suffix in (f'\n{key}', f'\n{key} -1', f'\n{key} 0.5', f'\n{key} NaN'):
            with self.subTest(suffix=suffix):
                result = m.parse_stats_text(complete_stats() + suffix)
                self.assertTrue(result['telemetry_available'])
                self.assertFalse(result['capture_complete'])
                self.assertIn(key, result['invalid_fields'])

    def test_partial_profile_distinguishes_missing_from_invalid(self):
        result = m.parse_stats_text(f'{m.PREFIX}enabled true\n{m.PREFIX}sync_writes 1')
        self.assertTrue(result['telemetry_available'])
        self.assertFalse(result['capture_complete'])
        self.assertIn(m.PREFIX + 'wal_enabled', result['missing_fields'])
        self.assertIn(m.PREFIX + 'sync_writes', result['invalid_fields'])

    def test_histogram_contract_rejects_malformed_values(self):
        key = m.PREFIX + 'commit.wall.micros'
        malformed = (
            'P50 : 1 P95 : 2 P99 : 3 P100 : 4 COUNT : 5',
            'P50 : 1 P50 : 1 P95 : 2 P99 : 3 P100 : 4 COUNT : 5 SUM : 6',
            'P50 : 1 P95 : 2 P99 : 3 P100 : 4 COUNT : 0.5 SUM : 6',
            'P50 : -1 P95 : 2 P99 : 3 P100 : 4 COUNT : 5 SUM : 6',
            'P50 : 1 P95 : 2 P99 : 3 P100 : 1e999 COUNT : 5 SUM : 6',
            'P50 : 2 P95 : 1 P99 : 3 P100 : 4 COUNT : 5 SUM : 6',
            'P50 : 0 P95 : 0 P99 : 0 P100 : 1 COUNT : 0 SUM : 0',
            'P50 : 1 P95 : 2 P99 : 3 P100 : 1000 COUNT : 20 SUM : 200',
            'P50 : 1 P95 : 2 P99 : 3 P100 : 4 COUNT : 5 SUM : 21',
            'P50 : 1 P95 : 2 P99 : 3 P100 : 4 COUNT : 5 SUM : 6 trailing',
        )
        for payload in malformed:
            with self.subTest(payload=payload):
                result = m.parse_stats_text(replace_payload(complete_stats(), key, payload))
                self.assertFalse(result['capture_complete'])
                self.assertIn(key, result['invalid_fields'])

    def test_zero_histogram_and_scientific_notation_are_valid(self):
        key = m.PREFIX + 'rocksdb.wal_sync.micros'
        payload = 'P50:0 P95:0 P99:0 P100:0 COUNT:7 SUM:0e+0'
        result = m.parse_stats_text(replace_payload(complete_stats(sync=False), key, payload))
        self.assertTrue(result['capture_complete'])
        self.assertEqual(result['histograms']['rocksdb_wal_sync']['count'], 7)
        self.assertEqual(result['histograms']['rocksdb_wal_sync']['sum_us'], 0)


if __name__ == '__main__':
    unittest.main()
