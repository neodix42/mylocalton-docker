#!/usr/bin/env python3
"""Offline validation of owner-scoped native pool snapshots; never calls Docker."""
import argparse
import json
import math
from pathlib import Path
import re

HEADER = 'total.native_pool_owners'
SHARED = 'total.native_signature_executor'
OWNER_KEY = re.compile(r'native_pool\.owner\.([0-9]+)\.(identity|ext_msg_[A-Za-z0-9_]+)\Z')
HEADER_CONFIG = ('enabled', 'owners', 'prefix_bits', 'total_signature_workers')
HEADER_GAUGES = ('topology_ready', 'published_generation', 'aggregate_mempool')
IDENTITY_CONFIG = ('index', 'signature_workers')
IDENTITY_GAUGES = ('applied_generation', 'local_mempool')
IDENTITY_COUNTERS = ('routed_batches', 'routed_messages', 'fence_rejections', 'topology_rejections',
                     'router_decoded_messages', 'router_decode_samples', 'router_decode_sum_s')
IDENTITY_MAXIMA = ('router_decode_max_s',)


def is_owner_key(key):
    return key == HEADER or OWNER_KEY.fullmatch(key) is not None


def parse_stats(text, *, last_exact_sample=False):
    result = {}
    for line in text.splitlines():
        fields = line.split(None, 1)
        if len(fields) != 2:
            continue
        key, payload = fields
        if not (is_owner_key(key) or key.startswith('total.ext_msg_') or key == SHARED):
            continue
        if key in result and not last_exact_sample:
            raise ValueError('duplicate statistics key:' + key)
        values = {}
        for item in payload.split():
            name, sep, text_value = item.partition(':')
            if not sep or name in values:
                raise ValueError('invalid or duplicate field:' + key)
            value = int(text_value) if re.fullmatch(r'[0-9]+', text_value) else float(text_value)
            if (type(value) is float and not math.isfinite(value)) or value < 0:
                raise ValueError('invalid field:' + key + '.' + name)
            values[name] = value
        result[key] = values
    return result


def number(value, integer=True):
    return (type(value) is int and value >= 0) if integer else (
        type(value) in (int, float) and value >= 0 and
        (type(value) is int or math.isfinite(value)))


def snapshot(stats, expected_owners=None):
    """Validate namespaces/configuration. Unready or lagging endpoints remain gauges."""
    errors = []
    header = stats.get(HEADER)
    owned_keys = [key for key in stats if OWNER_KEY.fullmatch(key)]
    if header is None:
        if owned_keys or expected_owners not in (None, 1):
            errors.append('owner_header_missing')
        return {'valid': not errors, 'available': False, 'owners': 1,
                'header': None, 'owner_rows': {}, 'errors': errors}
    for key in HEADER_CONFIG + HEADER_GAUGES:
        if not number(header.get(key)):
            errors.append('owner_header_field_invalid:' + key)
    count = header.get('owners')
    if count not in (1, 2, 4):
        errors.append('owner_count_invalid')
    if expected_owners is not None and count != expected_owners:
        errors.append('owner_count_mismatch')
    if header.get('enabled') != int(count in (2, 4)):
        errors.append('owner_enabled_mismatch')
    if header.get('prefix_bits') != {1: 0, 2: 1, 4: 2}.get(count):
        errors.append('owner_prefix_bits_mismatch')
    if header.get('topology_ready') not in (0, 1):
        errors.append('owner_topology_flag_invalid')
    if not number(header.get('total_signature_workers')) or header.get('total_signature_workers') == 0:
        errors.append('owner_signature_worker_total_invalid')
    indices = {int(OWNER_KEY.fullmatch(key).group(1)) for key in owned_keys}
    if count == 1:
        if owned_keys:
            errors.append('single_owner_unexpected_namespace')
        return {'valid': not errors, 'available': True, 'owners': count,
                'header': header, 'owner_rows': {}, 'errors': errors}
    if count not in (2, 4):
        return {'valid': False, 'available': True, 'owners': count,
                'header': header, 'owner_rows': {}, 'errors': errors}
    if indices != set(range(count)):
        errors.append('owner_namespace_set_incomplete_or_extra')
    if any(key.startswith('total.ext_msg_') for key in stats):
        errors.append('multi_owner_root_pool_counters_ambiguous')
    rows = {}
    for index in range(count):
        prefix = f'native_pool.owner.{index}.'
        identity = stats.get(prefix + 'identity', {})
        for key in IDENTITY_CONFIG + IDENTITY_GAUGES + IDENTITY_COUNTERS + IDENTITY_MAXIMA:
            if not number(identity.get(key), integer=not key.endswith('_s')):
                errors.append(f'owner_{index}_identity_field_invalid:{key}')
        if identity.get('index') != index:
            errors.append(f'owner_{index}_identity_index_mismatch')
        if identity.get('signature_workers') == 0:
            errors.append(f'owner_{index}_signature_workers_zero')
        local_stats = {'total.' + key[len(prefix):]: value for key, value in stats.items()
                       if key.startswith(prefix) and key != prefix + 'identity'}
        rows[str(index)] = {'identity': identity, 'stats': local_stats}
    if all(number(row['identity'].get('signature_workers')) for row in rows.values()):
        if sum(row['identity']['signature_workers'] for row in rows.values()) != header.get('total_signature_workers'):
            errors.append('owner_signature_worker_distribution_mismatch')
    return {'valid': not errors, 'available': True, 'owners': count,
            'header': header, 'owner_rows': rows, 'errors': errors}


def cleanup(before, after, expected_owners):
    old, new = snapshot(before, expected_owners), snapshot(after, expected_owners)
    errors = ['before:' + e for e in old['errors']] + ['after:' + e for e in new['errors']]
    if old['available'] != new['available']:
        errors.append('owner_header_availability_changed')
    if old['header'] and new['header']:
        for key in HEADER_CONFIG:
            if old['header'].get(key) != new['header'].get(key):
                errors.append('owner_configuration_changed:' + key)
    report = {'schema': 'native-pool-owner-cleanup-v1', 'expected_owners': expected_owners,
              'scope': 'per_owner' if expected_owners > 1 else 'legacy_single_owner',
              'header_before': old['header'], 'header_after': new['header'], 'owners': {},
              'shared_signature_executor': {'before': before.get(SHARED), 'after': after.get(SHARED)},
              'semantics': 'Each owner must independently finish canonical native cleanup. Header/identity gauges are asynchronous '
                           'snapshots; local mempool values and maxima are never summed. Generic mempool entries do not fail native cleanup.'}
    if expected_owners > 1 and new['header']:
        if new['header'].get('topology_ready') != 1:
            errors.append('owner_topology_not_ready')
    for index in range(expected_owners):
        if expected_owners == 1:
            prior, current, identity = before, after, None
        else:
            old_row = old['owner_rows'].get(str(index), {})
            new_row = new['owner_rows'].get(str(index), {})
            prior, current, identity = old_row.get('stats', {}), new_row.get('stats', {}), new_row.get('identity', {})
        reasons = []
        recon = current.get('total.ext_msg_native_reconciliation', {})
        pending = current.get('total.ext_msg_native_pending', {})
        for group, field, missing, dirty in (
            (recon, 'pending_sources', 'canonical_reconciliation_capture_missing', 'canonical_reconciliation_pending_sources'),
            (pending, 'messages', 'native_pending_capture_missing', 'native_pool_pending_messages')):
            if not number(group.get(field)):
                reasons.append(missing)
            elif group[field] != 0:
                reasons.append(dirty)
        if identity is not None:
            generation = new['header'].get('published_generation') if new['header'] else None
            applied = identity.get('applied_generation')
            if not number(generation) or not number(applied) or applied < generation:
                reasons.append('owner_applied_generation_behind_publication')
        report['owners'][str(index)] = {'before': prior, 'after': current, 'identity_after': identity,
                                        'cleanup_acceptance': {'valid': not reasons, 'invalid_reasons': reasons}}
        errors.extend(f'owner_{index}:' + reason for reason in reasons)
    report['cleanup_acceptance'] = {'valid': not errors, 'invalid_reasons': errors}
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', type=Path, required=True)
    parser.add_argument('--after', type=Path, required=True)
    parser.add_argument('--expected-owners', type=int, choices=(1, 2, 4), required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        result = cleanup(parse_stats(args.before.read_text(), last_exact_sample=True),
                         parse_stats(args.after.read_text(), last_exact_sample=True), args.expected_owners)
    except (OSError, ValueError) as exc:
        result = {'schema': 'native-pool-owner-cleanup-v1', 'expected_owners': args.expected_owners,
                  'cleanup_acceptance': {'valid': False, 'invalid_reasons': ['owner_capture_error:' + str(exc)]}}
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2, allow_nan=False)
        stream.write('\n')
    # Invalid cleanup is evidence, not a parser crash. The wrapper's original final gate rejects it.
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
