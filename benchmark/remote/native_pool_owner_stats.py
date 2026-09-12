#!/usr/bin/env python3
"""Offline validation of owner-scoped native pool snapshots; never calls Docker."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re

HEADER = 'total.native_pool_owners'
SHARED = 'total.native_signature_executor'
OWNER_KEY = re.compile(r'native_pool\.owner\.([0-9]+)\.(identity|ext_msg_[A-Za-z0-9_]+)\Z')
LANE_HEADER = 'total.native_admission_lane_owners'
LANE_OWNER_KEY = re.compile(r'native_pool\.owner\.([0-9]+)\.(identity|total\.[A-Za-z0-9_]+)\Z')
LANE_HEADER_CONFIG = ('enabled', 'owners', 'shared_signature_workers')
LANE_HEADER_GAUGES = ('topology_ready', 'topology_failed', 'published_generation', 'aggregate_mempool',
                      'coordinator_native_accounts', 'coordinator_native_watermarks')
LANE_HEADER_COUNTERS = ('routed_batches', 'routed_parents', 'inline_preparations', 'join_samples', 'join_sum_s')
LANE_IDENTITY_CONFIG = ('index', 'local_signature_workers', 'shared_signature_workers')
LANE_IDENTITY_COUNTERS = ('fence_rejections', 'admission_batches', 'admission_parents', 'queue_samples', 'queue_sum_s')
LANE_IDENTITY_GAUGES = ('generation',)
LANE_IDENTITY_MAXIMA = ('admission_max_parents', 'queue_max_s')
HEADER_CONFIG = ('enabled', 'owners', 'prefix_bits', 'total_signature_workers')
HEADER_GAUGES = ('topology_ready', 'published_generation', 'aggregate_mempool')
IDENTITY_CONFIG = ('index', 'signature_workers')
IDENTITY_GAUGES = ('applied_generation', 'local_mempool')
IDENTITY_COUNTERS = ('routed_batches', 'routed_messages', 'fence_rejections', 'topology_rejections',
                     'router_decoded_messages', 'router_decode_samples', 'router_decode_sum_s')
IDENTITY_MAXIMA = ('router_decode_max_s',)


# TD StringBuilder emits these topology flags as true/false. Keep the
# allowlist scoped to the exact statistics family: a boolean in a numeric
# cleanup gauge must never be silently interpreted as zero.
BOOLEAN_FIELDS = {
    HEADER: frozenset(('topology_ready',)),
    LANE_HEADER: frozenset(('topology_ready', 'topology_failed')),
}


def parse_stat_value(key, name, text_value):
    if name in BOOLEAN_FIELDS.get(key, ()):
        if text_value not in ('true', 'false', '0', '1'):
            raise ValueError('invalid boolean field:' + key + '.' + name)
        return int(text_value in ('true', '1'))
    if text_value in ('true', 'false'):
        raise ValueError('unexpected boolean field:' + key + '.' + name)
    value = int(text_value) if re.fullmatch(r'[0-9]+', text_value) else float(text_value)
    if (type(value) is float and not math.isfinite(value)) or value < 0:
        raise ValueError('invalid field:' + key + '.' + name)
    return value


def is_owner_key(key):
    return key in (HEADER, LANE_HEADER) or OWNER_KEY.fullmatch(key) is not None or LANE_OWNER_KEY.fullmatch(key) is not None


def lane_snapshot(stats, expected_lane_owners=4, expected_signature_workers=8):
    """Native children and generic coordinator are separate populations; executor is shared."""
    errors, rows = [], {}
    header = stats.get(LANE_HEADER, {})
    if expected_lane_owners != 4:
        errors.append('admission_lane_owners_not_requested')
    for key in LANE_HEADER_CONFIG + LANE_HEADER_GAUGES + LANE_HEADER_COUNTERS + ('join_max_s',):
        if not number(header.get(key), integer=not key.endswith('_s')):
            errors.append('lane_header_field_invalid:' + key)
    for key, wanted in {'enabled': 1, 'owners': 4, 'shared_signature_workers': expected_signature_workers,
                        'coordinator_native_accounts': 0, 'coordinator_native_watermarks': 0}.items():
        if header.get(key) != wanted:
            errors.append('lane_header_mismatch:' + key)
    if header.get('topology_ready') not in (0, 1) or header.get('topology_failed') not in (0, 1):
        errors.append('lane_topology_flags_invalid')
    if HEADER in stats:
        errors.append('legacy_owner_header_ambiguous_with_lane_owners')
    indices = set()
    for key in stats:
        match = LANE_OWNER_KEY.fullmatch(key)
        if match:
            indices.add(int(match.group(1)))
            if match.group(1) != str(int(match.group(1))):
                errors.append('noncanonical_lane_owner_index:' + key)
        if OWNER_KEY.fullmatch(key) and not key.endswith('.identity'):
            errors.append('legacy_owner_namespace_with_lane_owners:' + key)
    if indices != {0, 1, 2, 3}:
        errors.append('lane_owner_namespace_set_incomplete_or_extra')
    for index in range(4):
        prefix = f'native_pool.owner.{index}.'
        identity = stats.get(prefix + 'identity', {})
        for key in LANE_IDENTITY_CONFIG + LANE_IDENTITY_COUNTERS + LANE_IDENTITY_GAUGES + LANE_IDENTITY_MAXIMA:
            if not number(identity.get(key), integer=not key.endswith('_s')):
                errors.append(f'lane_{index}_identity_field_invalid:' + key)
        for key, wanted in {'index': index, 'local_signature_workers': 0,
                            'shared_signature_workers': expected_signature_workers}.items():
            if identity.get(key) != wanted:
                errors.append(f'lane_{index}_identity_mismatch:' + key)
        rows[str(index)] = {'identity': identity, 'stats': {
            key[len(prefix):]: value for key, value in stats.items()
            if key.startswith(prefix + 'total.') and key != prefix + SHARED}}
    coordinator = {key: value for key, value in stats.items() if key.startswith('total.ext_msg_')}
    return {'valid': not errors, 'available': bool(header), 'owners': 4, 'header': header,
            'owner_rows': rows, 'coordinator': coordinator, 'errors': errors}


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
            values[name] = parse_stat_value(key, name, text_value)
        result[key] = values
    return result


def number(value, integer=True):
    return (type(value) is int and value >= 0) if integer else (
        type(value) in (int, float) and value >= 0 and
        (type(value) is int or math.isfinite(value)))


def snapshot(stats, expected_owners=None):
    """Validate namespaces/configuration. Unready or lagging endpoints remain gauges."""
    errors = []
    if LANE_HEADER in stats or any('.total.' in key and LANE_OWNER_KEY.fullmatch(key) for key in stats):
        errors.append('admission_lane_owner_schema_requires_explicit_request')
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


PRODUCER_LIVE_FIELDS = ('owner_dirty_sources', 'owner_flush_scheduled', 'inbox_pending_sources',
                        'inbox_latest_sources', 'updates_inflight_sources', 'live_sources', 'live_physical_messages')


def live_cleanup(stats, persistent_producer=False, full=False):
    """Only live gauges authorize cleanup. Retained watermarks/actors and maxima are not debt."""
    groups = {'total.ext_msg_native_reconciliation': ('pending_sources',),
              'total.ext_msg_native_pending': ('messages',)}
    if full:
        groups.update({'total.ext_msg_mempool': ('messages', 'native', 'native_logical'),
                       'total.ext_msg_native_pending': ('accounts', 'messages', 'logical_messages'),
                       'total.ext_msg_batch_diagnostics': ('active_batches', 'prepare_active_parents',
                                                            'prepare_active_bytes', 'shard_shared_active'),
                       'total.ext_msg_native_transport': ('pending', 'live_queued', 'live_unpushed',
                           'logical_pending', 'logical_live_queued', 'logical_live_unpushed',
                           'push_reserved', 'logical_push_reserved')})
    if persistent_producer:
        groups['total.ext_msg_native_persistent_producer'] = PRODUCER_LIVE_FIELDS
    errors = []
    for group, fields in groups.items():
        values = stats.get(group, {})
        if group.endswith('_persistent_producer') and values.get('enabled') != 1:
            errors.append('producer_enabled_capture_missing')
        for field in fields:
            value = values.get(field)
            if not number(value):
                errors.append('cleanup_capture_missing:' + group + '.' + field)
            elif value != 0:
                errors.append('cleanup_pending:' + group + '.' + field)
    return errors


def lane_cleanup(before, after, confirmation, expected_owners, expected_lane_owners, expected_signature_workers,
                 persistent_producer=False):
    views = [lane_snapshot(value, expected_lane_owners, expected_signature_workers)
             for value in (before, after, confirmation or {})]
    errors = [f'snapshot_{index}:' + error for index, view in enumerate(views) for error in view['errors']]
    if expected_owners != 1:
        errors.append('legacy_pool_owners_must_remain_one')
    if confirmation is None:
        errors.append('second_cleanup_snapshot_missing')
    first = views[0]['header']
    report = {'schema': 'native-admission-lane-owner-cleanup-v1', 'expected_owners': expected_owners,
              'expected_admission_lane_owners': expected_lane_owners, 'expected_signature_workers': expected_signature_workers,
              'persistent_producer_expected': persistent_producer, 'scope': 'native_children_and_generic_coordinator',
              'header_before': first, 'header_after': views[1]['header'], 'header_confirmation': views[2]['header'],
              'owners': {}, 'coordinator': {}, 'shared_signature_executor': {'before': before.get(SHARED), 'after': after.get(SHARED)},
              'semantics': 'Two distinct post-drain RPC snapshots must independently be clean in every native child and generic coordinator. '
              'Root aggregate and child gauges are asynchronous and are never added together. Shared executor appears once; '
              'child shared-worker counts describe references to the same workers, not extra threads. Retained child nonce watermarks '
              'and idle producer actors are allowed. Generation >= earlier root publication is a fence, not a canonical nonce proof; '
              'the independent generator final canonical proof and cohort gates remain mandatory.'}
    for position, view in enumerate(views[1:], 1):
        header = view['header']
        for key in LANE_HEADER_CONFIG:
            if header.get(key) != first.get(key):
                errors.append(f'snapshot_{position}:lane_configuration_changed:' + key)
        if header.get('topology_ready') != 1 or header.get('topology_failed') != 0:
            errors.append(f'snapshot_{position}:lane_topology_not_ready')
        if header.get('aggregate_mempool') != 0:
            errors.append(f'snapshot_{position}:aggregate_mempool_not_empty')
        for scope in ['coordinator', '0', '1', '2', '3']:
            row = view['owner_rows'].get(scope, {})
            stats = view['coordinator'] if scope == 'coordinator' else row.get('stats', {})
            reasons = live_cleanup(stats, persistent_producer, full=True)
            if scope == 'coordinator':
                if stats.get('total.ext_msg_native_pending', {}).get('nonce_watermarks') != 0:
                    reasons.append('coordinator_native_watermarks_not_zero')
            else:
                identity = row.get('identity', {})
                generation = identity.get('generation')
                published = header.get('published_generation')
                if not number(generation) or not number(published) or generation < published:
                    reasons.append('owner_generation_behind_publication')
                if not number(stats.get('total.ext_msg_native_pending', {}).get('nonce_watermarks')):
                    reasons.append('retained_watermark_capture_missing')
            target = report['coordinator'] if scope == 'coordinator' else report['owners'].setdefault(scope, {})
            target['after' if position == 1 else 'confirmation'] = stats
            if scope != 'coordinator':
                target['identity_after' if position == 1 else 'identity_confirmation'] = row.get('identity', {})
            errors.extend(f'snapshot_{position}:{scope}:' + reason for reason in reasons)
    report['cleanup_acceptance'] = {'valid': not errors, 'invalid_reasons': errors}
    return report


def cleanup(before, after, expected_owners, *, expected_lane_owners=0, expected_signature_workers=8,
            persistent_producer=False, confirmation=None):
    if expected_lane_owners:
        return lane_cleanup(before, after, confirmation, expected_owners, expected_lane_owners,
                            expected_signature_workers, persistent_producer)
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
    if persistent_producer:
        report['persistent_producer_expected'] = True
        if confirmation is None:
            errors.append('second_cleanup_snapshot_missing')
        confirmed = snapshot(confirmation or {}, expected_owners)
        errors.extend('confirmation:' + reason for reason in confirmed['errors'])
        for label, view, raw in (('after', new, after), ('confirmation', confirmed, confirmation or {})):
            for index in range(expected_owners):
                values = raw if expected_owners == 1 else view['owner_rows'].get(str(index), {}).get('stats', {})
                errors.extend(f'{label}:owner_{index}:' + reason for reason in live_cleanup(values, True, full=True))
        report['confirmation'] = confirmation
        report['cleanup_acceptance']['valid'] = not errors
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', type=Path, required=True)
    parser.add_argument('--after', type=Path, required=True)
    parser.add_argument('--expected-owners', type=int, choices=(1, 2, 4), required=True)
    parser.add_argument('--expected-admission-lane-owners', type=int, choices=(0, 4), default=0)
    parser.add_argument('--expected-signature-workers', type=int, default=8)
    parser.add_argument('--persistent-producer', type=int, choices=(0, 1), default=0)
    parser.add_argument('--confirmation', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.expected_signature_workers <= 0:
            raise ValueError('expected signature worker budget must be positive')
        if args.confirmation and args.confirmation.resolve() == args.after.resolve():
            raise ValueError('cleanup confirmation must be a distinct RPC capture file')
        result = cleanup(parse_stats(args.before.read_text(), last_exact_sample=not bool(args.expected_admission_lane_owners or args.persistent_producer)),
                         parse_stats(args.after.read_text(), last_exact_sample=not bool(args.expected_admission_lane_owners or args.persistent_producer)), args.expected_owners,
                         expected_lane_owners=args.expected_admission_lane_owners,
                         expected_signature_workers=args.expected_signature_workers,
                         persistent_producer=bool(args.persistent_producer),
                         confirmation=parse_stats(args.confirmation.read_text()) if args.confirmation else None)
    except (OSError, ValueError) as exc:
        result = {'schema': 'native-pool-owner-cleanup-v1', 'expected_owners': args.expected_owners,
                  'cleanup_acceptance': {'valid': False, 'invalid_reasons': ['owner_capture_error:' + str(exc)]}}
    result['expected_configuration'] = {'TON_NATIVE_POOL_OWNERS': args.expected_owners,
        'TON_NATIVE_ADMISSION_LANE_OWNERS': args.expected_admission_lane_owners,
        'TON_NATIVE_EXECUTOR_THREADS': args.expected_signature_workers,
        'TON_NATIVE_PERSISTENT_PRODUCER': args.persistent_producer}
    result['captures'] = {}
    for name in ('before', 'after', 'confirmation'):
        path = getattr(args, name)
        if path is not None:
            result['captures'][name] = {'path': str(path),
                'sha256': hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None}
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2, allow_nan=False)
        stream.write('\n')
    # Invalid cleanup is evidence, not a parser crash. The wrapper's original final gate rejects it.
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
