#!/usr/bin/env python3
"""Parse the exact CellDb durability getstats family without contacting Docker."""

import argparse
import json
import math
from pathlib import Path
import re


PREFIX = 'db.celldb.durability.'
CONFIG_FIELDS = {
    PREFIX + 'enabled': 'enabled',
    PREFIX + 'sync_writes': 'sync_writes',
    PREFIX + 'wal_enabled': 'wal_enabled',
    PREFIX + 'periodic_reset_enabled': 'periodic_reset_enabled',
}
COUNTER_FIELDS = {
    PREFIX + 'queue_wait.count': 'queue_wait_count',
    PREFIX + 'commit.calls': 'commit_calls',
    PREFIX + 'write_batch.operations': 'write_batch_operations',
    PREFIX + 'write_batch.serialized_bytes': 'write_batch_serialized_bytes',
    PREFIX + 'rocksdb.db_write.count': 'rocksdb_db_write_count',
    PREFIX + 'rocksdb.wal_write.count': 'rocksdb_wal_write_count',
    PREFIX + 'rocksdb.wal.bytes': 'rocksdb_wal_bytes',
    PREFIX + 'rocksdb.wal_sync.count': 'rocksdb_wal_sync_count',
    PREFIX + 'rocksdb.stall.micros': 'rocksdb_stall_micros',
}
GAUGE_FIELDS = {
    PREFIX + 'queue.max_depth': 'queue_max_depth',
    PREFIX + 'reset_generation': 'reset_generation',
}
HISTOGRAM_FIELDS = {
    PREFIX + 'queue_wait.micros': 'queue_wait',
    PREFIX + 'prepare.wall.micros': 'prepare_wall',
    PREFIX + 'prepare.cpu.micros': 'prepare_cpu',
    PREFIX + 'prepare.caller_cpu.micros': 'prepare_caller_cpu',
    PREFIX + 'prepare.async_cpu.micros': 'prepare_async_cpu',
    PREFIX + 'write_batch.wall.micros': 'write_batch_wall',
    PREFIX + 'write_batch.cpu.micros': 'write_batch_cpu',
    PREFIX + 'commit.wall.micros': 'commit_wall',
    PREFIX + 'commit.cpu.micros': 'commit_cpu',
    PREFIX + 'rocksdb.db_write.micros': 'rocksdb_db_write',
    PREFIX + 'rocksdb.wal_sync.micros': 'rocksdb_wal_sync',
    PREFIX + 'completion.wall.micros': 'completion_wall',
}
ALL_FIELDS = CONFIG_FIELDS | COUNTER_FIELDS | GAUGE_FIELDS | HISTOGRAM_FIELDS
NONNEGATIVE_NUMBER = r'(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?'
HISTOGRAM_RE = re.compile(
    rf'P50\s*:\s*(?P<p50>{NONNEGATIVE_NUMBER})\s+'
    rf'P95\s*:\s*(?P<p95>{NONNEGATIVE_NUMBER})\s+'
    rf'P99\s*:\s*(?P<p99>{NONNEGATIVE_NUMBER})\s+'
    rf'P100\s*:\s*(?P<p100>{NONNEGATIVE_NUMBER})\s+'
    rf'COUNT\s*:\s*(?P<count>[0-9]+)\s+'
    rf'SUM\s*:\s*(?P<sum>{NONNEGATIVE_NUMBER})\Z'
)


def _number(text):
    value = float(text)
    if not math.isfinite(value) or value < 0:
        raise ValueError('number must be finite and nonnegative')
    return value


def _histogram(payload):
    match = HISTOGRAM_RE.fullmatch(payload)
    if match is None:
        raise ValueError('invalid histogram')
    values = {
        'p50_us': _number(match.group('p50')),
        'p95_us': _number(match.group('p95')),
        'p99_us': _number(match.group('p99')),
        'p100_us': _number(match.group('p100')),
        'count': int(match.group('count')),
        'sum_us': _number(match.group('sum')),
    }
    if not (values['p50_us'] <= values['p95_us'] <= values['p99_us'] <= values['p100_us']):
        raise ValueError('histogram percentiles out of order')
    if values['count'] == 0 and any(values[key] != 0 for key in
                                     ('p50_us', 'p95_us', 'p99_us', 'p100_us', 'sum_us')):
        raise ValueError('empty histogram has nonzero values')
    if values['count'] > 0:
        tolerance = max(1e-6, values['count'] * 1e-6)
        if (values['sum_us'] + tolerance < values['p100_us'] or
                values['sum_us'] > values['count'] * values['p100_us'] + tolerance):
            raise ValueError('histogram sum inconsistent with maximum')
    return values


def parse_stats_text(text):
    """Select the last exact-key line and return a stable validation envelope."""
    last_payload = {}
    for line in text.splitlines():
        fields = line.strip().split(None, 1)
        if not fields or fields[0] not in ALL_FIELDS:
            continue
        last_payload[fields[0]] = fields[1].strip() if len(fields) == 2 else ''

    result = {
        'telemetry_available': bool(last_payload),
        'capture_complete': False,
        'missing_fields': [],
        'invalid_fields': [],
        'config': {name: None for name in CONFIG_FIELDS.values()},
        'counters': {name: None for name in COUNTER_FIELDS.values()},
        'gauges': {name: None for name in GAUGE_FIELDS.values()},
        'histograms': {name: None for name in HISTOGRAM_FIELDS.values()},
    }
    for key in ALL_FIELDS:
        if key not in last_payload:
            result['missing_fields'].append(key)
            continue
        payload = last_payload[key]
        try:
            if key in CONFIG_FIELDS:
                if payload not in ('true', 'false'):
                    raise ValueError('invalid boolean')
                result['config'][CONFIG_FIELDS[key]] = payload == 'true'
            elif key in COUNTER_FIELDS:
                if re.fullmatch(r'[0-9]+', payload) is None:
                    raise ValueError('invalid counter')
                result['counters'][COUNTER_FIELDS[key]] = int(payload)
            elif key in GAUGE_FIELDS:
                if re.fullmatch(r'[0-9]+', payload) is None:
                    raise ValueError('invalid gauge')
                result['gauges'][GAUGE_FIELDS[key]] = int(payload)
            else:
                result['histograms'][HISTOGRAM_FIELDS[key]] = _histogram(payload)
        except (OverflowError, ValueError):
            result['invalid_fields'].append(key)
    result['missing_fields'].sort()
    result['invalid_fields'].sort()
    result['capture_complete'] = not result['missing_fields'] and not result['invalid_fields']
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', required=True, type=Path)
    args = parser.parse_args()
    text = args.input.read_text(encoding='utf-8', errors='replace') if args.input.exists() else ''
    print(json.dumps(parse_stats_text(text), sort_keys=True, separators=(',', ':')))


if __name__ == '__main__':
    main()
