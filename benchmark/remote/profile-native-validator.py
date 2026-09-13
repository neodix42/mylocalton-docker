#!/usr/bin/env python3
"""Read-only server-A sampler. Never builds, restarts, or changes a validator."""
import argparse
import datetime
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import urllib.parse
import urllib.request

_owner_spec = importlib.util.spec_from_file_location('native_pool_owner_stats', Path(__file__).with_name('native_pool_owner_stats.py'))
OWNER_STATS = importlib.util.module_from_spec(_owner_spec)
_owner_spec.loader.exec_module(OWNER_STATS)

REQUIRED_KEYS = ('total.ext_msg_batch_admission', 'total.ext_msg_batch_diagnostics',
                 'total.native_signature_executor')
RECONCILIATION_KEY = 'total.ext_msg_native_reconciliation'
RECONCILIATION_DIAGNOSTIC_KEY = 'total.ext_msg_native_reconciliation_diagnostics'
PUBLICATION_KEY = 'total.ext_msg_native_publication'
BATCH_DISPATCH_KEY = 'total.ext_msg_batch_dispatch'
RECONCILIATION_COALESCING_KEY = 'total.ext_msg_native_reconciliation_coalescing'
VALIDATED_STATE_HANDOFF_KEY = 'total.native_validated_state_handoff'
KEYS = REQUIRED_KEYS + (RECONCILIATION_KEY, RECONCILIATION_DIAGNOSTIC_KEY, PUBLICATION_KEY, BATCH_DISPATCH_KEY,
                        RECONCILIATION_COALESCING_KEY, VALIDATED_STATE_HANDOFF_KEY)
PUBLICATION_COUNTERS = {
    'groups', 'ingress_wakes', 'alarm_wakes', 'target_releases', 'timeout_releases',
    'bypass_releases', 'cancelled_groups', 'wait_samples', 'wait_sum_s',
    'batches', 'messages', 'logical', 'live_batches', 'live_messages', 'live_logical',
    'live_lt512', 'live_512_2047', 'live_ge2048',
}
ADMISSION_COUNTERS = {
    'batches', 'messages', 'accepted', 'rejected', 'account_lookups',
    'shard_state_requests', 'shard_manager_waits', 'shard_fetches', 'shard_cache_hits',
    'shard_cache_fills', 'shard_cache_fill_races', 'shard_cache_fill_conflicts',
    'shard_cache_generation_resets', 'shard_cache_stale_generation_fill_skips',
    'shard_cache_wrong_id', 'shard_cache_invalid_header', 'shard_miss_errors',
    'shard_fetch_errors', 'shard_manager_wait_errors', 'shard_manager_wait_timeouts',
    'shard_manager_wait_notready', 'shard_manager_wait_other_errors',
    'shard_manager_wait_late_results',
}
RECONCILIATION_COUNTERS = {
    'runs', 'state_fetches', 'account_lookups', 'sources_advanced', 'messages_purged',
    'failures', 'unchanged_state_skips', 'unchanged_top_skips', 'unchanged_source_skips',
    'rebased_reservations', 'unaffordable_tail_pruned', 'stale_uncommitted_tail_pruned',
    'expiry_suffix_events', 'expiry_suffix_pruned', 'exact_retry_preserved_stale_revision',
}
RECONCILIATION_STAGE_PREFIXES = ('registration', 'grouping', 'manager_wait', 'lookup', 'unpack', 'apply', 'wake')
RECONCILIATION_APPLY_OUTCOMES = ('apply_errors', 'apply_first_observation', 'apply_nonce_advanced',
                                'apply_balance_only_changed', 'apply_unchanged')
RECONCILIATION_DIAGNOSTIC_COUNTERS = {
    'snapshot_finishes', 'snapshot_errors', 'register_source_visits', 'register_tracked_visits',
    'group_source_visits', 'group_shards', 'account_lookups', 'account_empty',
    'account_unpack_failures', 'account_kind_failures', 'account_balance_failures',
    'apply_calls', 'apply_stale_lt', 'apply_effects', 'apply_balance_increased', 'apply_balance_decreased',
    'pending_reservations_before_apply_sum', 'reservation_prefix_entries', 'messages_purged',
    'reservation_rebases', 'tail_prunes',
} | set(RECONCILIATION_APPLY_OUTCOMES) | {
    stage + suffix for stage in RECONCILIATION_STAGE_PREFIXES for suffix in ('_samples', '_sum_s')
}
# Keep the historical required reconciliation schema unchanged. Each extension
# is optional for old recordings, but complete and stable once observed.
RECONCILIATION_CHUNK_STAGES = ('grouping_slice', 'account_slice', 'yield_wait')
RECONCILIATION_CHUNK_COUNTERS = {'grouping_yields', 'account_yields'} | {
    stage + suffix for stage in RECONCILIATION_CHUNK_STAGES for suffix in ('_samples', '_sum_s')
}
BATCH_DISPATCH_COUNTERS = {'batches', 'messages', 'late_batches', 'wait_samples', 'wait_sum_s'}
LOCALITY_COUNTERS = {'locality_calls', 'locality_outputs', 'locality_destination_visits',
                     'locality_destination_queries', 'locality_dedup_hits', 'locality_shard_queries'}
RECONCILIATION_COALESCING_STAGES = ('state_pick_age', 'pass_residence')
RECONCILIATION_COALESCING_COUNTERS = set('notifications active_notifications coalesced_notifications registrations '
    'registered_notifications folded_notifications empty_registered_passes pass_sources superseded_passes '
    'generation_lag_sum'.split()) | {stage + suffix for stage in RECONCILIATION_COALESCING_STAGES
                                  for suffix in ('_samples', '_sum_s')}
VALIDATED_STATE_HANDOFF_COUNTERS = {'hits', 'misses', 'inserts', 'evictions', 'expirations'}
SIGNATURE_DISPATCH_STAGES = tuple('signature_dispatch_' + stage for stage in ('queue', 'worker_wall', 'worker_cpu', 'resume'))
SIGNATURE_DISPATCH_COUNTERS = {'signature_dispatch_' + key for key in (
    'rounds tasks items run_items logical_transfers reply_tasks reply_items failed_tasks timeout_tasks '
    'late_reply_tasks abandoned_tasks profiled_reply_tasks cpu_unsupported_tasks legacy_tasks legacy_results legacy_errors legacy_timeouts cache_unchecked cache_hits '
    'cache_misses crypto_attempts crypto_successes cache_inserts cache_duplicate_inserts cache_evictions').split()} | {
        stage + suffix for stage in SIGNATURE_DISPATCH_STAGES for suffix in ('_samples', '_sum_s')}
SIGNATURE_EXECUTOR_POOL_COUNTERS = {
    'pool_calls': 'counter', 'pool_tickets': 'counter', 'pool_threads_created': 'counter',
    'pool_contended_submits': 'counter', 'pool_queue_wait_sum_s': 'number',
    'pool_completion_wait_sum_s': 'number', 'pool_worker_cpu_sum_s': 'number',
}
SIGNATURE_EXECUTOR_POOL_CONFIGURATION = {
    'pool_queue_capacity': 'positive_integer',
}
SIGNATURE_EXECUTOR_POOL_GAUGES = {
    'pool_threads': 'gauge', 'pool_active': 'gauge', 'pool_queue': 'gauge',
}
SIGNATURE_EXECUTOR_POOL_MAXIMA = {
    'pool_active_peak': 'counter', 'pool_queue_peak': 'counter',
    'pool_queue_wait_max_s': 'number', 'pool_completion_wait_max_s': 'number',
}
SIGNATURE_EXECUTOR_POOL_FIELDS = (set(SIGNATURE_EXECUTOR_POOL_COUNTERS) |
                                  set(SIGNATURE_EXECUTOR_POOL_CONFIGURATION) |
                                  set(SIGNATURE_EXECUTOR_POOL_GAUGES) |
                                  set(SIGNATURE_EXECUTOR_POOL_MAXIMA))
SIGNATURE_CACHE_FAST_CONFIGURATION = {'cache_fast_enabled': 'flag'}
SIGNATURE_CACHE_FAST_COUNTERS = {
    'cache_fast_checks', 'cache_fast_hits', 'cache_fast_misses',
    'cache_fast_scanned_items', 'cache_fast_cached_items',
}
SIGNATURE_CACHE_FAST_FIELDS = set(SIGNATURE_CACHE_FAST_CONFIGURATION) | SIGNATURE_CACHE_FAST_COUNTERS
OPTIONAL_SCHEMAS = {
    'signature_dispatch': {
        'group': REQUIRED_KEYS[1],
        'configuration': {'signature_dispatch_batch_enabled': 'flag', 'signature_dispatch_profile_enabled': 'flag',
                          'signature_dispatch_cpu_supported': 'flag', 'signature_dispatch_task_limit': 'positive_integer'},
        'counters': SIGNATURE_DISPATCH_COUNTERS, 'stages': SIGNATURE_DISPATCH_STAGES,
        'maxima': {'signature_dispatch_max_task_items': 'counter'},
        'profile_flag': 'signature_dispatch_profile_enabled',
    },
    'batch_dispatch': {
        'group': BATCH_DISPATCH_KEY, 'whole_group': True,
        'configuration': {'profile_enabled': 'flag'},
        'counters': BATCH_DISPATCH_COUNTERS, 'stages': ('wait',),
    },
    'reconciliation_chunks': {
        'group': RECONCILIATION_DIAGNOSTIC_KEY,
        'configuration': {'profile_enabled': 'flag', 'chunks_enabled': 'flag',
                          'group_chunk_sources': 'positive_integer', 'account_chunk_sources': 'positive_integer',
                          'chunk_budget_s': 'positive_number'},
        'counters': RECONCILIATION_CHUNK_COUNTERS, 'stages': RECONCILIATION_CHUNK_STAGES,
    },
    'reconciliation_coalescing': {
        'group': RECONCILIATION_COALESCING_KEY, 'whole_group': True,
        'configuration': {'enabled': 'flag', 'profile_enabled': 'flag'},
        'counters': RECONCILIATION_COALESCING_COUNTERS, 'stages': RECONCILIATION_COALESCING_STAGES,
        'gauges': {'registration_pending': 'flag', 'pending_notifications': 'counter'},
        'maxima': {'generation_lag_max': 'counter'},
    },
    'locality': {
        'group': REQUIRED_KEYS[1], 'configuration': {'locality_fastpath_enabled': 'flag'},
        'counters': LOCALITY_COUNTERS, 'stages': (),
    },
    'validated_state_handoff': {
        'group': VALIDATED_STATE_HANDOFF_KEY, 'whole_group': True,
        'configuration': {'enabled': 'flag', 'capacity': 'positive_integer'},
        'counters': VALIDATED_STATE_HANDOFF_COUNTERS, 'stages': (),
        'gauges': {'entries': 'gauge'},
    },
}
ENV_KEYS = {'TON_NATIVE_ADMISSION_CONFIG_CACHE', 'TON_NATIVE_EXECUTOR_THREADS',
            'TON_NATIVE_PERSISTENT_PRODUCER', 'TON_NATIVE_ADMISSION_PREPARE',
            'TON_NATIVE_CANONICAL_JOURNAL', 'TON_NATIVE_LANE_SCHEDULERS', 'TON_NATIVE_ADMISSION_LANE_OWNERS',
            'TON_NATIVE_ADMISSION_SHARD_SHARING', 'TON_NATIVE_ADMISSION_SNAPSHOT_REFRESH',
            'TON_NATIVE_RECONCILIATION_PROFILE',
            'TON_NATIVE_RECONCILIATION_CHUNKS', 'TON_NATIVE_ADMISSION_LOCALITY_FASTPATH',
            'TON_NATIVE_ADMISSION_VERIFIER_BATCH', 'TON_NATIVE_ADMISSION_DISPATCH_PROFILE',
            'TON_NATIVE_RECONCILIATION_COALESCE', 'TD_ACTOR_PROFILE_CPU', 'TON_NATIVE_POOL_OWNERS',
            'TON_KEYRING_PREPARED_SIGNING', 'TON_OVERLAY_LOCAL_SIGNATURE_REUSE',
            'TON_NATIVE_CANDIDATE_METADATA_PROJECTION',
            'TON_NATIVE_STAGED_TRIE_DIRECT', 'TON_NATIVE_PUBLICATION_GROUPING',
            'TON_NATIVE_VALIDATION_SIGNATURE_THREADS', 'TON_NATIVE_VALIDATION_SIGNATURE_PERSISTENT_POOL',
            'TON_NATIVE_VALIDATION_SIGNATURE_CACHE_FASTPATH',
            'TON_NATIVE_EAGER_COLLATOR_CALLBACK', 'TON_NATIVE_CELLDB_DURABILITY_PROFILE',
            'TON_NATIVE_CELLDB_UNSAFE_SYNC_FALSE', 'TON_NATIVE_VALIDATED_STATE_HANDOFF',
            'TON_NATIVE_EXT_MESSAGE_POOL_MAILBOX_QUANTUM',
            'TON_NATIVE_COLLATOR_QUEUE_LIMIT', 'TON_SIMPLEX_MAX_TPS', 'SIMPLEX_TARGET_RATE_MS',
            'TON_SIMPLEX_MAX_TPS_CANDIDATE_TIMEOUT_MS', 'TON_SIMPLEX_MAX_TPS_FINALIZE_RESERVE_MS',
            'TON_NATIVE_CHECKPOINT_RETAIN_INGRESS', 'NATIVE_PAYMENT_LANE_DEPTH',
            'ACTUAL_MIN_SPLIT', 'MIN_SPLIT', 'MAX_SPLIT', 'CUSTOM_PARAMETERS'}
CONTROL = '''
config=/var/ton-work/db/config.json
internal_ip=$(hostname -I); internal_ip=${internal_ip%% *}
control_port=$(jq -r '.control[0].port // empty' "$config")
test -n "$internal_ip" && test -n "$control_port" || exit 2
exec timeout --signal=TERM --kill-after=1s 10s validator-engine-console \
  -k /var/ton-work/db/client -p /var/ton-work/db/server.pub \
  -a "$internal_ip:$control_port" -c getstats
'''


def command(args, timeout=15):
    return subprocess.run(args, text=True, capture_output=True, timeout=timeout, check=True).stdout


def save(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')


def parse_stats(text):
    result = {}
    for line in text.splitlines():
        fields = line.split(None, 1)
        if len(fields) != 2 or fields[0] not in KEYS and not OWNER_STATS.is_owner_key(fields[0]):
            continue
        if fields[0] in result:
            raise ValueError('duplicate statistics key')
        values = {}
        for item in fields[1].split():
            name, sep, value = item.partition(':')
            if not sep or name in values:
                raise ValueError('invalid or duplicate counter')
            values[name] = OWNER_STATS.parse_stat_value(fields[0], name, value)
        result[fields[0]] = values
    return result


def deltas(before, after, required_keys=REQUIRED_KEYS):
    """Compare counters, never subtract lifetime maxima or current gauges."""
    changes, errors = {}, []
    for group in KEYS:
        if group not in required_keys and group not in before and group not in after:
            continue  # Older recordings need not contain optional attribution.
        if group not in before or group not in after:
            errors.append('missing:' + group)
            continue
        values = {}
        for key, old in before[group].items():
            if key in ('active_batches', 'config_cache_enabled') or key.endswith('_enabled') or \
                    'peak' in key or 'max_' in key or key.endswith('_max_s') or key.endswith('_active') or \
                    (group == REQUIRED_KEYS[2] and key in (SIGNATURE_EXECUTOR_POOL_CONFIGURATION |
                                                           SIGNATURE_EXECUTOR_POOL_GAUGES)) or \
                    key in ('shard_shared_waiters', 'shard_shared_table_limit', 'shard_shared_waiters_per_key_limit',
                            'prepare_active_parents', 'prepare_active_bytes', 'prepare_parent_limit', 'prepare_byte_limit'):
                continue
            # Only documented admission/executor counters, not sequence numbers
            # or gauges in the broader pool-admission statistics key.
            if group == KEYS[0] and key not in ADMISSION_COUNTERS:
                continue
            if group == RECONCILIATION_KEY and key not in RECONCILIATION_COUNTERS:
                continue
            if group == RECONCILIATION_DIAGNOSTIC_KEY and key not in \
                    RECONCILIATION_DIAGNOSTIC_COUNTERS | RECONCILIATION_CHUNK_COUNTERS:
                continue
            if group == PUBLICATION_KEY and key not in PUBLICATION_COUNTERS:
                continue
            if group == BATCH_DISPATCH_KEY and key not in BATCH_DISPATCH_COUNTERS:
                continue
            if group == RECONCILIATION_COALESCING_KEY and key not in RECONCILIATION_COALESCING_COUNTERS:
                continue
            if group == VALIDATED_STATE_HANDOFF_KEY and key not in VALIDATED_STATE_HANDOFF_COUNTERS:
                continue
            if group == REQUIRED_KEYS[1] and key.startswith('signature_dispatch_') and key not in SIGNATURE_DISPATCH_COUNTERS:
                continue
            new = after[group].get(key)
            if new is None or new < old:
                errors.append('counter_reset_or_missing:' + group + '.' + key)
            else:
                values[key] = new - old
        changes[group] = values
    return changes, errors


def valid_schema_value(value, kind):
    if kind in ('counter', 'positive_integer', 'flag', 'gauge'):
        return type(value) is int and (value in (0, 1) if kind == 'flag' else
                                      value > 0 if kind == 'positive_integer' else value >= 0)
    return type(value) in (int, float) and (type(value) is int or math.isfinite(value)) and \
        (value > 0 if kind == 'positive_number' else value >= 0)


def summarize_signature_executor(samples, changes):
    """Keep reusable-pool counters separate from current gauges and lifetime maxima."""
    rows = [sample['stats'].get(REQUIRED_KEYS[2], {}) for sample in samples]
    present = [bool(SIGNATURE_EXECUTOR_POOL_FIELDS & set(row)) for row in rows]
    cache_fast_present = [bool(SIGNATURE_CACHE_FAST_FIELDS & set(row)) for row in rows]
    result = {
        'available': all(REQUIRED_KEYS[2] in sample['stats'] for sample in samples),
        'valid': False,
        'pool_telemetry_available': any(present),
        'counter_deltas': changes.get(REQUIRED_KEYS[2], {}),
        'configuration': {},
        'gauges_at_endpoints': {},
        'lifetime_maxima_at_endpoints': {},
        'cache_fastpath_available': any(cache_fast_present),
        'cache_fastpath_valid': False,
        'cache_fastpath_configuration': {},
        'cache_fastpath_counter_deltas': {},
        'cache_fastpath_accounting_diagnostics': {},
        'errors': [],
        'semantics': ('Pool calls/tickets/created threads and wait/CPU sums are monotonic process-lifetime counters. '
                      'Pool threads, active workers and queued tickets are current endpoint gauges. Peaks are '
                      'process-lifetime maxima; queue capacity is fixed configuration. Worker CPU is summed '
                      'across tickets and can exceed wall time. A zero worker-CPU sum is unavailable on platforms '
                      'where ThreadCpuTimer has no thread CPU clock, not evidence of zero CPU cost. Cache fast-path '
                      'checks classify whole helper calls; cached items count only complete all-hit calls.'),
    }
    errors = result['errors']
    if not result['available']:
        errors.append('signature_executor_capture_missing')
        return result
    if not any(present) and not any(cache_fast_present):
        # Recordings from validators predating the persistent-pool telemetry remain valid.
        result['valid'] = True
        return result
    if any(present):
        for index, (row, exists) in enumerate(zip(rows, present)):
            if not exists:
                errors.append(f'missing_signature_executor_pool_schema:sample_{index}')
                continue
            for key, kind in (SIGNATURE_EXECUTOR_POOL_COUNTERS | SIGNATURE_EXECUTOR_POOL_CONFIGURATION |
                              SIGNATURE_EXECUTOR_POOL_GAUGES |
                              SIGNATURE_EXECUTOR_POOL_MAXIMA).items():
                if key not in row:
                    errors.append(f'missing_signature_executor_pool_field:{key}:sample_{index}')
                elif not valid_schema_value(row[key], kind):
                    errors.append(f'invalid_signature_executor_pool_field:{key}:sample_{index}')
    if any(cache_fast_present):
        for index, (row, exists) in enumerate(zip(rows, cache_fast_present)):
            if not exists:
                errors.append(f'missing_signature_cache_fast_schema:sample_{index}')
                continue
            for key in sorted(SIGNATURE_CACHE_FAST_FIELDS):
                kind = SIGNATURE_CACHE_FAST_CONFIGURATION.get(key, 'counter')
                if key not in row:
                    errors.append(f'missing_signature_cache_fast_field:{key}:sample_{index}')
                elif not valid_schema_value(row[key], kind):
                    errors.append(f'invalid_signature_cache_fast_field:{key}:sample_{index}')
    for index, (old, new) in enumerate(zip(rows, rows[1:]), 1):
        for key in SIGNATURE_EXECUTOR_POOL_CONFIGURATION:
            if key in old and key in new and new[key] != old[key]:
                errors.append(f'signature_executor_pool_configuration_changed:{key}:sample_{index}')
        for key in SIGNATURE_EXECUTOR_POOL_COUNTERS:
            if key in old and key in new and new[key] < old[key]:
                errors.append(f'signature_executor_pool_counter_reset:{key}:sample_{index}')
        for key in SIGNATURE_EXECUTOR_POOL_MAXIMA:
            if key in old and key in new and new[key] < old[key]:
                errors.append(f'signature_executor_pool_maximum_reset:{key}:sample_{index}')
        for key in SIGNATURE_CACHE_FAST_CONFIGURATION:
            if key in old and key in new and new[key] != old[key]:
                errors.append(f'signature_cache_fast_configuration_changed:{key}:sample_{index}')
        for key in SIGNATURE_CACHE_FAST_COUNTERS:
            if key in old and key in new and new[key] < old[key]:
                errors.append(f'signature_cache_fast_counter_reset:{key}:sample_{index}')
    first, last = rows[0], rows[-1]
    result['configuration'] = {
        key: first[key] for key in SIGNATURE_EXECUTOR_POOL_CONFIGURATION if key in first
    }
    result['gauges_at_endpoints'] = {
        key: [first[key], last[key]] for key in SIGNATURE_EXECUTOR_POOL_GAUGES
        if key in first and key in last
    }
    result['lifetime_maxima_at_endpoints'] = {
        key: [first[key], last[key]] for key in SIGNATURE_EXECUTOR_POOL_MAXIMA
        if key in first and key in last
    }
    if all(cache_fast_present):
        result['cache_fastpath_configuration'] = {
            key: first[key] for key in SIGNATURE_CACHE_FAST_CONFIGURATION if key in first
        }
        cache_changes = changes.get(REQUIRED_KEYS[2], {})
        result['cache_fastpath_counter_deltas'] = {
            key: cache_changes[key] for key in SIGNATURE_CACHE_FAST_COUNTERS if key in cache_changes
        }
        values = result['cache_fastpath_counter_deltas']
        if SIGNATURE_CACHE_FAST_COUNTERS <= values.keys():
            result['cache_fastpath_accounting_diagnostics'] = {
                'checks_equal_completed_outcomes':
                    values['cache_fast_checks'] == values['cache_fast_hits'] + values['cache_fast_misses'],
                'cached_items_do_not_exceed_scanned_items':
                    values['cache_fast_cached_items'] <= values['cache_fast_scanned_items'],
                'semantics': ('Diagnostic only: each field is a relaxed atomic snapshot. Calls already in flight at '
                              'the first sample, or entering during either sample, can make interval identities '
                              'temporarily false without a counter reset or implementation error.'),
            }
        result['cache_fastpath_valid'] = not any(error.startswith('signature_cache_fast') or
                                                 error.startswith('missing_signature_cache_fast') or
                                                 error.startswith('invalid_signature_cache_fast')
                                                 for error in errors)
    result['valid'] = not errors
    return result


def summarize_optional_schema(samples, name, counter_errors):
    """Validate every observed sample, including intermediate resets/config changes."""
    definition = OPTIONAL_SCHEMAS[name]
    group, configuration = definition['group'], definition['configuration']
    stages, counters = definition['stages'], definition['counters']
    gauges, maxima = definition.get('gauges', {}), definition.get('maxima', {})
    required = set(configuration) | counters | {stage + '_max_s' for stage in stages} | set(gauges) | set(maxima)
    markers = required - {'profile_enabled'}
    rows = [sample['stats'].get(group, {}) for sample in samples]
    present = [group in sample['stats'] if definition.get('whole_group') else bool(markers & row.keys())
               for sample, row in zip(samples, rows)]
    result = {'available': any(present), 'valid': False, 'configuration': {},
              'counter_deltas': {}, 'stage_mean_ms': {}, 'errors': []}
    if not result['available']:
        return result
    errors = result['errors']
    for index, (row, exists) in enumerate(zip(rows, present)):
        if not exists:
            errors.append(f'missing_optional_schema:{name}:sample_{index}')
            continue
        for key in sorted(required):
            if key not in row:
                errors.append(f'missing_optional_field:{name}.{key}:sample_{index}')
                continue
            kind = (configuration | gauges | maxima).get(key, 'number' if key.endswith(('_sum_s', '_max_s')) else 'counter')
            if not valid_schema_value(row[key], kind):
                errors.append(f'invalid_optional_field:{name}.{key}:sample_{index}')
    for index, (old, new) in enumerate(zip(rows, rows[1:]), 1):
        for key in configuration:
            if key in old and key in new and old[key] != new[key]:
                errors.append(f'optional_configuration_changed:{name}.{key}:sample_{index}')
        for key in sorted(counters):
            if key in old and key in new and valid_schema_value(old[key], 'number') and \
                    valid_schema_value(new[key], 'number') and new[key] < old[key]:
                errors.append(f'optional_counter_reset:{name}.{key}:sample_{index}')
    if errors:
        return result
    result['configuration'] = {key: rows[0][key] for key in configuration}
    result['gauges_at_endpoints'] = {key: [rows[0][key], rows[-1][key]] for key in gauges}
    result['lifetime_maxima_at_endpoints'] = {key: [rows[0][key], rows[-1][key]]
        for key in set(maxima) | {stage + '_max_s' for stage in stages}}
    values = {key: rows[-1][key] - rows[0][key] for key in counters}
    result['counter_deltas'] = values
    for stage in stages:
        count, seconds = values[stage + '_samples'], values[stage + '_sum_s']
        if not count and seconds:
            errors.append(f'timing_sum_without_samples:{name}.{stage}')
        if result['configuration'].get(definition.get('profile_flag', 'profile_enabled')) == 0 and (count or seconds):
            errors.append(f'timing_while_profile_disabled:{name}.{stage}')
    if name == 'batch_dispatch':
        if values['late_batches'] > values['batches'] or values['wait_samples'] > values['batches']:
            errors.append('dispatch_outcomes_exceed_entered_batches')
    if name == 'reconciliation_chunks' and result['configuration']['chunks_enabled'] == 0:
        if values['grouping_yields'] or values['account_yields'] or values['yield_wait_samples'] or values['yield_wait_sum_s']:
            errors.append('reconciliation_yields_while_chunks_disabled')
    if name == 'locality':
        if values['locality_destination_visits'] != values['locality_destination_queries'] + values['locality_dedup_hits']:
            errors.append('locality_visits_do_not_match_queries_and_hits')
        if values['locality_outputs'] < values['locality_destination_visits']:
            errors.append('locality_visits_exceed_presented_outputs')
        source_queries = values['locality_shard_queries'] - values['locality_destination_queries']
        if not 0 <= source_queries <= values['locality_calls']:
            errors.append('locality_source_queries_outside_call_population')
        if result['configuration']['locality_fastpath_enabled'] == 0 and values['locality_dedup_hits']:
            errors.append('locality_hits_while_fastpath_disabled')
    if name == 'validated_state_handoff':
        attempts = values['hits'] + values['misses']
        result['hit_fraction'] = values['hits'] / attempts if attempts else None
        if result['configuration']['enabled'] == 0 and any(values.values()):
            errors.append('validated_state_handoff_activity_while_disabled')
    if errors or counter_errors:
        return result
    result['valid'] = True
    result['stage_mean_ms'] = {
        stage: values[stage + '_sum_s'] * 1000 / values[stage + '_samples']
        for stage in stages if values[stage + '_samples'] > 0
    }
    if name == 'signature_dispatch':
        replies, profiled = values['signature_dispatch_reply_tasks'], values['signature_dispatch_profiled_reply_tasks']
        traced = sum(values['signature_dispatch_' + key] for key in ('cache_unchecked', 'cache_hits', 'cache_misses'))
        result['reply_trace_diagnostics'] = {
            'all_reply_tasks_profiled': replies == profiled,
            'reply_items_equal_classified_cache_items': values['signature_dispatch_reply_items'] == traced,
            'semantics': 'Diagnostic only; late replies overlap failed tasks. Missing/abandoned replies have no worker samples.'}
        tasks, items = values['signature_dispatch_tasks'], values['signature_dispatch_items']
        result['physical_items_per_dispatched_task'] = items / tasks if tasks else None
        result['legacy_unit_path_observed'] = values['signature_dispatch_legacy_tasks'] > 0
        result['helper_reply_population_observed'] = replies > 0
        result['helper_completion_fraction'] = None  # Replies/errors/legacy results are overlapping or different populations.
        result['worker_cpu_available'] = result['configuration']['signature_dispatch_profile_enabled'] == 1 and result['configuration']['signature_dispatch_cpu_supported'] == 1
    if name == 'reconciliation_coalescing':
        result['notification_accounting_diagnostics'] = {
            'notifications_equal_registered_plus_pending_at_samples': all(
                row['notifications'] == row['registered_notifications'] + row['pending_notifications'] for row in rows),
            'registered_equals_registrations_plus_folded_delta':
                values['registered_notifications'] == values['registrations'] + values['folded_notifications'],
            'semantics': 'Diagnostic identities only; registration test hooks can bypass notification accounting. '
                         'Do not compare notification counters to canonical transactions or apply effects.'}
    if name == 'batch_dispatch':
        result['late_batch_fraction'] = values['late_batches'] / values['batches'] if values['batches'] else None
    if name == 'locality':
        visits, calls = values['locality_destination_visits'], values['locality_calls']
        result['destination_hit_fraction'] = values['locality_dedup_hits'] / visits if visits else None
        result['destination_queries_per_call'] = values['locality_destination_queries'] / calls if calls else None
        result['shard_queries_per_call'] = values['locality_shard_queries'] / calls if calls else None
    return result


def summarize_reconciliation(before, after, changes, counter_errors):
    """Use only the reconciliation-local apply denominator, never legacy admission progress."""
    group = RECONCILIATION_DIAGNOSTIC_KEY
    result = {'available': group in before and group in after, 'valid': False,
              'profile_enabled': None, 'stage_mean_ms': {}, 'apply_outcome_counts': {},
              'apply_outcome_fractions': {}, 'apply_outcomes_match_calls': None,
              'apply_effects_fraction': None, 'errors': [],
              'semantics': 'Reconciliation calls only. Outcomes partition apply_calls; balance changes '
                           'and effects overlap these outcomes. Unchanged account facts can still require '
                           'expiry/prefix work. Legacy sources_advanced includes admission progress. '
                           'Manager waiting is wall time, not CPU time. Missing timings are not zero work.'}
    if not result['available']:
        return result
    errors = result['errors']
    first, last = before[group], after[group]
    for key in sorted(RECONCILIATION_DIAGNOSTIC_COUNTERS - (first.keys() & last.keys())):
        errors.append('missing_reconciliation_counter:' + key)
    flags = (first.get('profile_enabled'), last.get('profile_enabled'))
    if any(flag not in (0, 1) for flag in flags):
        errors.append('invalid_reconciliation_profile_flag')
    elif flags[0] != flags[1]:
        errors.append('reconciliation_profile_changed')
    else:
        result['profile_enabled'] = bool(flags[0])
    values = changes.get(group, {})
    outcome_keys = set(RECONCILIATION_APPLY_OUTCOMES) | {'apply_calls'}
    if outcome_keys <= values.keys():
        outcomes = {key: values[key] for key in RECONCILIATION_APPLY_OUTCOMES}
        result['apply_outcome_counts'] = outcomes
        result['apply_outcomes_match_calls'] = sum(outcomes.values()) == values['apply_calls']
        if not result['apply_outcomes_match_calls']:
            errors.append('reconciliation_apply_outcomes_do_not_match_calls')
    if values.get('apply_stale_lt', 0) > values.get('apply_errors', 0):
        errors.append('reconciliation_stale_lt_exceeds_errors')
    if values.get('apply_effects', 0) > values.get('apply_calls', 0) - values.get('apply_errors', 0):
        errors.append('reconciliation_effects_exceed_successful_calls')
    if result['profile_enabled'] is False and any(values.get(stage + '_samples', 0)
                                                 for stage in RECONCILIATION_STAGE_PREFIXES):
        errors.append('reconciliation_timing_samples_while_profile_disabled')
    if counter_errors or errors:
        return result
    result['valid'] = True
    result['stage_mean_ms'] = {
        stage: values[stage + '_sum_s'] * 1000 / values[stage + '_samples']
        for stage in RECONCILIATION_STAGE_PREFIXES if values[stage + '_samples'] > 0
    }
    calls = values['apply_calls']
    if calls:
        result['apply_outcome_fractions'] = {key: count / calls
                                             for key, count in result['apply_outcome_counts'].items()}
        result['apply_effects_fraction'] = values['apply_effects'] / calls
    return result


def summarize_owners(samples, expected_owners=None):
    """Keep independent owner populations and one shared executor; never forge root totals."""
    usable = [row for row in samples if row.get('stats')]
    views = [OWNER_STATS.snapshot(row['stats'], expected_owners) for row in usable]
    errors = [error for row in samples for error in row.get('errors', [])]
    errors += [f'sample_{i}:' + error for i, view in enumerate(views) for error in view['errors']]
    count = views[0]['owners'] if views else expected_owners
    configuration = {}
    if views and views[0]['header']:
        configuration = {key: views[0]['header'].get(key) for key in OWNER_STATS.HEADER_CONFIG}
    for i, view in enumerate(views):
        if view['owners'] != count:
            errors.append(f'owner_count_changed:sample_{i}')
        if view['available'] != views[0]['available']:
            errors.append(f'owner_header_availability_changed:sample_{i}')
        for key, value in configuration.items():
            if not view['header'] or view['header'].get(key) != value:
                errors.append(f'owner_configuration_changed:{key}:sample_{i}')
    if count == 1:
        result = summarize(samples, _owner_dispatch=False)
        result['owner_configuration'] = {'available': bool(configuration), 'configuration': configuration,
                                         'valid': not errors, 'errors': errors}
        result['errors'].extend(errors)
        return result
    result = {'schema': 'native-validator-owner-profile-v1', 'scope': 'per_owner',
              'samples': len(samples), 'statistics_samples': len(usable),
              'diagnostics_available': False, 'configuration': configuration, 'owners': {},
              'errors': errors, 'semantics': 'Owner counters are separate populations. Shared signature executor appears once. '
              'Fanout snapshots are asynchronous; no summed owner maxima or fabricated root admission totals. '
              'Missing owners and counter resets invalidate attribution; configured topology/identity gauges are endpoints.'}
    if len(usable) < 2:
        errors.append('fewer_than_two_statistics_samples')
    if errors or count not in (2, 4):
        return result
    result['header_gauges_at_endpoints'] = {key: [views[0]['header'][key], views[-1]['header'][key]]
                                            for key in OWNER_STATS.HEADER_GAUGES}
    for index in range(count):
        identities = [view['owner_rows'][str(index)]['identity'] for view in views]
        local = [dict(row, stats=view['owner_rows'][str(index)]['stats']) for row, view in zip(usable, views)]
        summary = summarize(local, _required_keys=REQUIRED_KEYS[:2], _owner_dispatch=False)
        # Ordinary admission counters also need every adjacent sample checked; a
        # reset must not be hidden by recovery above the first endpoint.
        for position, (old, new) in enumerate(zip(local, local[1:])):
            _, failures = deltas(old['stats'], new['stats'], REQUIRED_KEYS[:2])
            summary['errors'].extend(f'interval_{position}:' + failure for failure in failures)
        identity_delta = {}
        for key in OWNER_STATS.IDENTITY_CONFIG:
            if any(row[key] != identities[0][key] for row in identities):
                summary['errors'].append('owner_identity_configuration_changed:' + key)
        for key in OWNER_STATS.IDENTITY_COUNTERS:
            if any(new[key] < old[key] for old, new in zip(identities, identities[1:])):
                summary['errors'].append('owner_identity_counter_reset:' + key)
            else:
                identity_delta[key] = identities[-1][key] - identities[0][key]
        summary['identity'] = {
            'configuration': {key: identities[0][key] for key in OWNER_STATS.IDENTITY_CONFIG},
            'counter_deltas': identity_delta,
            'gauges_at_endpoints': {key: [identities[0][key], identities[-1][key]] for key in OWNER_STATS.IDENTITY_GAUGES},
            'lifetime_maxima_at_endpoints': {key: [identities[0][key], identities[-1][key]] for key in OWNER_STATS.IDENTITY_MAXIMA},
            'semantics': 'Router decode samples/time cover strict batch RPC parsing only. Single-message routing can increment routed_messages without a decode sample.',
            'batch_router_decode_mean_ms': (identity_delta.get('router_decode_sum_s', 0) * 1000 /
                                      identity_delta['router_decode_samples']) if identity_delta.get('router_decode_samples') else None}
        result['owners'][str(index)] = summary
        errors.extend(f'owner_{index}:' + failure for failure in summary['errors'])
    shared = [dict(row, stats={OWNER_STATS.SHARED: row['stats'][OWNER_STATS.SHARED]}
                   if OWNER_STATS.SHARED in row['stats'] else {}) for row in usable]
    shared_delta, shared_errors = deltas(shared[0]['stats'], shared[-1]['stats'], (OWNER_STATS.SHARED,))
    for position, (old, new) in enumerate(zip(shared, shared[1:])):
        _, failures = deltas(old['stats'], new['stats'], (OWNER_STATS.SHARED,))
        shared_errors.extend(f'interval_{position}:' + failure for failure in failures)
    shared_summary = summarize_signature_executor(shared, shared_delta)
    shared_errors.extend(error for error in shared_summary['errors'] if error not in shared_errors)
    shared_summary['errors'] = shared_errors
    shared_summary['valid'] = not shared_errors
    result['shared_signature_executor'] = shared_summary
    errors.extend(shared_errors)
    if errors:
        # Preserve raw deltas as invalid evidence, but publish no usable stage means.
        for owner in result['owners'].values():
            owner['diagnostics_available'] = False
            owner['stage_mean_ms'] = {}
            owner['config_cache_hit_fraction'] = None
            owner['snapshot_changed_fraction_of_not_ready'] = None
            owner['snapshot_changed_fraction_of_completed_inputs'] = None
            owner['reconciliation']['apply_outcome_fractions'] = {}
            owner['reconciliation']['apply_effects_fraction'] = None
            owner['identity']['batch_router_decode_mean_ms'] = None
            for key in ('reconciliation',) + tuple(OPTIONAL_SCHEMAS):
                owner[key]['valid'] = False
                owner[key]['stage_mean_ms'] = {}
    result['diagnostics_available'] = not errors and all(owner['diagnostics_available'] for owner in result['owners'].values())
    return result


def scoped_fields(rows, configuration, counters, gauges=(), maxima=()):
    errors, changes = [], {}
    for key in configuration:
        if any(row.get(key) != rows[0].get(key) for row in rows):
            errors.append('configuration_changed:' + key)
    for key in counters:
        values = [row.get(key) for row in rows]
        if not all(OWNER_STATS.number(value, integer=not key.endswith('_s')) for value in values):
            errors.append('counter_missing:' + key)
        elif any(new < old for old, new in zip(values, values[1:])):
            errors.append('counter_reset:' + key)
        else:
            changes[key] = values[-1] - values[0]
    return {'configuration': {key: rows[0].get(key) for key in configuration}, 'counter_deltas': changes,
            'gauges_at_endpoints': {key: [rows[0].get(key), rows[-1].get(key)] for key in gauges},
            'lifetime_maxima_at_endpoints': {key: [rows[0].get(key), rows[-1].get(key)] for key in maxima},
            'errors': errors}


def summarize_lane_owners(samples, expected_owners, expected_lane_owners, expected_signature_workers):
    usable = [row for row in samples if row.get('stats')]
    views = [OWNER_STATS.lane_snapshot(row['stats'], expected_lane_owners, expected_signature_workers) for row in usable]
    errors = [error for row in samples for error in row.get('errors', [])]
    errors.extend(f'sample_{i}:' + error for i, view in enumerate(views) for error in view['errors'])
    if expected_owners not in (None, 1):
        errors.append('legacy_pool_owners_must_remain_one')
    if len(usable) < 2:
        errors.append('fewer_than_two_statistics_samples')
    result = {'schema': 'native-validator-admission-lane-profile-v1', 'scope': 'native_children_and_generic_coordinator',
              'expected_admission_lane_owners': expected_lane_owners, 'expected_signature_workers': expected_signature_workers,
              'samples': len(samples), 'statistics_samples': len(usable), 'owners': {}, 'errors': errors,
              'diagnostics_available': False, 'semantics': 'Four native child populations, including lane zero, and one generic '
              'coordinator. Shared executor counters appear once. Header aggregate and child gauges are asynchronous; they '
              'are not added or subtracted as counters. Router join time includes child service and sibling wait, not exclusive CPU.'}
    if errors:
        return result
    headers = [view['header'] for view in views]
    result['router'] = scoped_fields(headers, OWNER_STATS.LANE_HEADER_CONFIG, OWNER_STATS.LANE_HEADER_COUNTERS,
                                    OWNER_STATS.LANE_HEADER_GAUGES, ('join_max_s',))
    errors.extend('router:' + value for value in result['router']['errors'])
    for scope in ['coordinator', '0', '1', '2', '3']:
        local = [dict(row, stats=view['coordinator'] if scope == 'coordinator' else view['owner_rows'][scope]['stats'])
                 for row, view in zip(usable, views)]
        summary = summarize(local, _required_keys=REQUIRED_KEYS[:2], _owner_dispatch=False)
        for position, (old, new) in enumerate(zip(local, local[1:])):
            _, failures = deltas(old['stats'], new['stats'], REQUIRED_KEYS[:2])
            summary['errors'].extend(f'interval_{position}:' + failure for failure in failures)
        if scope == 'coordinator':
            result['coordinator'] = summary
        else:
            identities = [view['owner_rows'][scope]['identity'] for view in views]
            identity = scoped_fields(identities, OWNER_STATS.LANE_IDENTITY_CONFIG, OWNER_STATS.LANE_IDENTITY_COUNTERS,
                                     OWNER_STATS.LANE_IDENTITY_GAUGES, OWNER_STATS.LANE_IDENTITY_MAXIMA)
            identity['queue_mean_ms'] = (identity['counter_deltas']['queue_sum_s'] * 1000 /
                identity['counter_deltas']['queue_samples']) if identity['counter_deltas'].get('queue_samples') else None
            summary['identity'] = identity
            summary['errors'].extend(identity['errors'])
            result['owners'][scope] = summary
        errors.extend(scope + ':' + value for value in summary['errors'])
    shared = [dict(row, stats={OWNER_STATS.SHARED: row['stats'][OWNER_STATS.SHARED]}
                   if OWNER_STATS.SHARED in row['stats'] else {}) for row in usable]
    shared_rows = [row['stats'].get(OWNER_STATS.SHARED, {}) for row in shared]
    shared_deltas, shared_errors = deltas({OWNER_STATS.SHARED: shared_rows[0]},
                                         {OWNER_STATS.SHARED: shared_rows[-1]}, (OWNER_STATS.SHARED,))
    for index, (old, new) in enumerate(zip(shared_rows, shared_rows[1:])):
        _, failures = deltas({OWNER_STATS.SHARED: old}, {OWNER_STATS.SHARED: new}, (OWNER_STATS.SHARED,))
        shared_errors.extend(f'interval_{index}:' + value for value in failures)
    shared_summary = summarize_signature_executor(shared, shared_deltas)
    shared_errors.extend(error for error in shared_summary['errors'] if error not in shared_errors)
    if not shared_rows[0] or any(not row for row in shared_rows):
        shared_errors.append('shared_executor_capture_missing')
    shared_summary['errors'] = shared_errors
    shared_summary['valid'] = not shared_errors
    result['shared_signature_executor'] = shared_summary
    errors.extend('shared_executor:' + value for value in result['shared_signature_executor']['errors'])
    if errors:
        for summary in [result['coordinator']] + list(result['owners'].values()):
            summary['diagnostics_available'] = False
            summary['stage_mean_ms'] = {}
            if 'identity' in summary:
                summary['identity']['queue_mean_ms'] = None
    result['diagnostics_available'] = not errors and all(value['diagnostics_available'] for value in
        [result['coordinator']] + list(result['owners'].values()))
    return result


def summarize(samples, *, expected_owners=None, expected_lane_owners=0, expected_signature_workers=8,
              _required_keys=REQUIRED_KEYS, _owner_dispatch=True):
    if _owner_dispatch and (expected_lane_owners or any(OWNER_STATS.LANE_HEADER in row.get('stats', {}) for row in samples)):
        return summarize_lane_owners(samples, expected_owners, expected_lane_owners, expected_signature_workers)
    if _owner_dispatch and (expected_owners not in (None, 1) or any(
            any(OWNER_STATS.is_owner_key(key) for key in row.get('stats', {})) for row in samples)):
        return summarize_owners(samples, expected_owners)
    usable = [x for x in samples if x.get('stats')]
    result = {'schema': 'native-validator-profile-v1', 'samples': len(samples),
              'statistics_samples': len(usable), 'diagnostics_available': False,
              'errors': [e for x in samples for e in x.get('errors', [])],
              'semantics': 'Observation only. Match timestamps to B measurement; startup/drain may be included. '
                           'Stage wall times overlap. Maxima are lifetime values. Executor counters are concurrent snapshots. '
                           'Thread CPU excludes vanished threads; network counters cover the network namespace.'}
    if len(usable) < 2:
        result['errors'].append('fewer_than_two_statistics_samples')
        return result
    changes, errors = deltas(usable[0]['stats'], usable[-1]['stats'], _required_keys)
    result.update(start_unix_s=usable[0]['stats_started_unix_s'],
                  end_unix_s=usable[-1]['stats_finished_unix_s'], counter_deltas=changes)
    result['errors'].extend(errors)
    diagnostic = changes.get(KEYS[1], {})
    result['diagnostics_available'] = all(k in usable[0]['stats'] and k in usable[-1]['stats'] for k in _required_keys)
    result['stage_mean_ms'] = {k[:-8]: diagnostic[k[:-8] + '_sum_s'] * 1000 / n
                               for k, n in diagnostic.items() if k.endswith('_samples') and n > 0
                               and k[:-8] + '_sum_s' in diagnostic}
    hits, misses = diagnostic.get('config_cache_hits', 0), diagnostic.get('config_cache_misses', 0)
    result['config_cache_hit_fraction'] = hits / (hits + misses) if hits + misses else None
    not_ready = diagnostic.get('not_ready_total', 0)
    result['snapshot_changed_fraction_of_not_ready'] = (
        diagnostic.get('not_ready_snapshot_changed', 0) / not_ready if not_ready else None)
    admissions = changes.get(KEYS[0], {})
    completed = admissions.get('accepted', 0) + admissions.get('rejected', 0)
    result['snapshot_changed_fraction_of_completed_inputs'] = (
        diagnostic.get('not_ready_snapshot_changed', 0) / completed if completed else None)
    if REQUIRED_KEYS[2] in _required_keys:
        result['signature_executor'] = summarize_signature_executor(usable, changes)
        result['errors'].extend(result['signature_executor']['errors'])
    result['reconciliation'] = summarize_reconciliation(usable[0]['stats'], usable[-1]['stats'], changes, errors)
    result['errors'].extend(result['reconciliation']['errors'])
    for name in OPTIONAL_SCHEMAS:
        result[name] = summarize_optional_schema(usable, name, errors)
        result['errors'].extend(result[name]['errors'])
    result['signature_dispatch']['semantics'] = (
        'Tasks and items count verifier dispatches and physical parents within one RPC; logical_transfers counts represented children. '
        'Reply tasks/items include late replies, which also count as failed; invalid signatures are replies, not task failures. '
        'Legacy scalar/profile-off uses original Unit tasks: legacy errors cannot distinguish bad signatures from transport errors; helper reply/cache/clock counters remain unobserved there. '
        'Timeout/abandonment can lack worker samples. Queue is pool dispatch to worker start; resume ends at that task pool continuation '
        'before group join. Worker CPU/cache tracing is profile-gated; unsupported CPU is unavailable, not zero cost. '
        'Use each stage sample denominator; clocks and task completion can cross interval boundaries.')
    result['batch_dispatch']['semantics'] = (
        'Manager dispatch to first pool entry; separate from pool-entry residence and not total liteserver queue latency. '
        'Wall-time means use only completed wait_samples with their matching wait_sum_s; late_batches counts entry after the original deadline.')
    result['reconciliation_chunks']['semantics'] = (
        'grouping_sum_s is active grouping slices excluding explicit yield waits; grouping_samples still counts whole passes. '
        'grouping_slice and account_slice use their own completed-slice sample counts; yield_wait counts resumed yields. '
        'Yield starts and resumed samples may cross interval boundaries. Slice clocks include OS preemption and are not exclusive CPU. '
        'The budget is cooperative and checked between complete source operations, not a hard scheduling deadline.')
    result['reconciliation_coalescing']['semantics'] = (
        'Actionable notifications exclude exact successful-fingerprint skips. Coalesced notifications avoid '
        'immediate registration while active; folded notifications are extras consumed by a registration. '
        'State-pick age is receipt to selected pass capture; pass residence spans captured pass through coroutine return. '
        'Clocks are wall time, not CPU. Pending state and lifetime maxima are endpoints, not counter deltas; '
        'registration and pass completion can cross the interval boundaries.')
    result['locality']['semantics'] = (
        'Calls include repeated checks before/after awaits or snapshot refresh, not unique messages or admitted transfers. '
        'Presented output slots can remain unvisited after early failure. Visits equal destination queries plus same-call reuse hits; '
        'shard queries also include source lookups. Ratios use this locality-call population only.')
    result['validated_state_handoff']['semantics'] = (
        'Inserts are fully validated speculative states acknowledged before validation succeeds. Hits and misses '
        'classify exact acceptance lookups; a hit is consumed once. Entries is an endpoint gauge. Evictions are '
        'capacity removals and expirations are TTL removals; neither implies a validation or acceptance failure.')
    if result['errors']:
        # A reset/partial schema must never appear to be a valid attribution.
        result['diagnostics_available'] = False
        result['stage_mean_ms'] = {}
        result['config_cache_hit_fraction'] = None
        result['snapshot_changed_fraction_of_not_ready'] = None
        result['snapshot_changed_fraction_of_completed_inputs'] = None
        result['reconciliation']['valid'] = False
        result['reconciliation']['stage_mean_ms'] = {}
        result['reconciliation']['apply_outcome_fractions'] = {}
        result['reconciliation']['apply_effects_fraction'] = None
        for name in OPTIONAL_SCHEMAS:
            result[name]['valid'] = False
            result[name]['stage_mean_ms'] = {}
            for key in ('late_batch_fraction', 'destination_hit_fraction', 'destination_queries_per_call',
                        'shard_queries_per_call', 'hit_fraction'):
                result[name].pop(key, None)
    return result


def thread_intervals(samples, hz):
    result = []
    for old, new in zip(samples, samples[1:]):
        if 'resources' not in old or 'resources' not in new:
            continue
        elapsed = new['observed_unix_s'] - old['observed_unix_s']
        if elapsed <= 0:
            continue
        rows = []
        for tid, current in new['resources']['threads'].items():
            previous = old['resources']['threads'].get(tid)
            if not previous or previous['start_ticks'] != current['start_ticks']:
                continue
            cpu = current['cpu_ticks'] - previous['cpu_ticks']
            wait = current['schedstat'][1] - previous['schedstat'][1]
            if cpu < 0 or wait < 0:
                continue
            rows.append({'tid': tid, 'comm': current['comm'], 'cpu_cores': cpu / hz / elapsed,
                         'runqueue_wait_s': wait / 1e9})
        result.append({'start_unix_s': old['observed_unix_s'], 'end_unix_s': new['observed_unix_s'],
                       'sampled_cpu_cores': sum(x['cpu_cores'] for x in rows),
                       'sampled_runqueue_wait_s': sum(x['runqueue_wait_s'] for x in rows),
                       'top_threads': sorted(rows, key=lambda x: x['cpu_cores'], reverse=True)[:20]})
    return result


def capture_dashboard(base, start, end, output):
    groups = {
        'canonical': ('rate', ['BLOCK_APPLIED_native_transfers', 'BLOCK_APPLIED_transactions', 'BLOCK_APPLIED_blocks']),
        'packing': ('avg', ['BLOCK_native_transfers', 'BLOCK_size', 'BLOCK_native_bytes_per_transfer']),
        'collation': ('avg', ['BLOCK_collate_work_time_real_' + x for x in
                              ('native_execute', 'native_commit', 'create_state_merkle_update')]),
        'validation': ('avg', ['BLOCK_validate_work_time_real_' + x for x in
                               ('native_signature_verify', 'native_state_replay', 'native_account_load',
                                'native_account_materialize', 'native_state_dictionary_check', 'state_merkle_update')])}
    errors = []
    for name, (mode, stats) in groups.items():
        query = urllib.parse.urlencode({'wc': 0, 'stats': ','.join(stats), 'mode': mode, 'window_size': 60,
            'start': datetime.datetime.fromtimestamp(start, datetime.timezone.utc).isoformat(),
            'end': datetime.datetime.fromtimestamp(end, datetime.timezone.utc).isoformat()})
        try:
            with urllib.request.urlopen(base.rstrip('/') + '/api/stats?' + query, timeout=5) as response:
                data = json.load(response)
            save(output / ('dashboard-' + name + '.json'), data)
        except (OSError, ValueError) as exc:
            errors.append(name + ':' + type(exc).__name__)
    return errors


def identity(container):
    records = json.loads(command(['docker', 'inspect', container]))
    if len(records) != 1 or not records[0]['State']['Running']:
        raise ValueError('expected one running validator container')
    c = records[0]
    return {'container_id': c['Id'], 'image_id': c['Image'], 'started_at': c['State']['StartedAt'],
            'restart_count': c['RestartCount'], 'init_pid': c['State']['Pid'],
            'limits': {k: c['HostConfig'].get(k) for k in ('NanoCpus', 'CpuQuota', 'CpuPeriod', 'CpusetCpus', 'Memory')},
            'environment': {k: v for entry in c['Config'].get('Env', [])
                            for k, sep, v in [entry.partition('=')] if sep and k in ENV_KEYS}}


def engine_pid(container, container_id):
    found = []
    for line in command(['docker', 'top', container, '-eo', 'pid,comm']).splitlines()[1:]:
        fields = line.split()
        if fields and fields[0].isdigit():
            pid = int(fields[0])
            try:
                if (Path(os.readlink(f'/proc/{pid}/exe')).name == 'validator-engine'
                        and container_id in Path(f'/proc/{pid}/cgroup').read_text()):
                    found.append(pid)
            except OSError:
                pass
    if len(found) != 1:
        raise ValueError('cannot identify one host validator-engine PID in the container cgroup; run sampler on the Docker host with /proc access')
    return found[0]


def proc_stat(path):
    text = path.read_text()
    # comm may contain spaces and parentheses; numeric fields follow its last ).
    fields = text[text.rfind(')') + 2:].split()
    return {'cpu_ticks': int(fields[11]) + int(fields[12]), 'start_ticks': int(fields[19]),
            'state': fields[0], 'comm': text[text.find('(')+1:text.rfind(')')]}


def resources(pid):
    root = Path('/proc') / str(pid)
    result = {'process': proc_stat(root / 'stat'), 'threads': {}, 'errors': []}
    for task in (root / 'task').iterdir():
        try:
            record = proc_stat(task / 'stat')
            record['schedstat'] = [int(x) for x in (task / 'schedstat').read_text().split()]
            result['threads'][task.name] = record
        except (OSError, ValueError):
            result['errors'].append('thread_disappeared_or_unreadable:' + task.name)
    for name in ('io', 'status', 'net/dev'):
        try:
            result[name] = (root / name).read_text()
        except OSError:
            result['errors'].append('unreadable:' + name)
    try:
        cgroup = next(line[3:] for line in (root / 'cgroup').read_text().splitlines() if line.startswith('0::'))
        base = Path('/sys/fs/cgroup') / cgroup.lstrip('/')
        for name in ('cpu.stat', 'cpu.pressure', 'memory.current', 'memory.pressure', 'io.pressure'):
            try:
                result[name] = (base / name).read_text()
            except OSError:
                result['errors'].append('unreadable_cgroup:' + name)
    except (OSError, StopIteration):
        result['errors'].append('cgroup_v2_unavailable')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', default='genesis')
    parser.add_argument('--duration', type=int, default=1200)
    parser.add_argument('--interval', type=int, default=30)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--dashboard-url', default='', help='optional Session Stats URL, e.g. http://127.0.0.1:18000')
    a = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', a.container) or not 1 <= a.duration <= 86400 or not 15 <= a.interval <= 600:
        parser.error('invalid container, duration (1..86400), or interval (15..600)')
    if a.dashboard_url:
        url = urllib.parse.urlsplit(a.dashboard_url)
        if url.scheme not in ('http', 'https') or not url.netloc or url.username or url.password:
            parser.error('dashboard URL must be HTTP(S) without credentials')
    # /proc sampling is valid only for a local Docker daemon, never an SSH/TCP context.
    context = json.loads(command(['docker', 'context', 'inspect']))
    endpoints = [context[0]['Endpoints']['docker']['Host']]
    if os.environ.get('DOCKER_HOST'):
        endpoints.append(os.environ['DOCKER_HOST'])
    if any(not x.startswith('unix://') for x in endpoints):
        parser.error('local Unix-socket Docker context required for host /proc sampling')
    os.umask(0o077)
    output = a.output or Path('validator-profiles') / datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    output.mkdir(parents=True, exist_ok=False)
    samples = []
    stopped = False
    def stop(*_):
        nonlocal stopped
        stopped = True
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    initial = identity(a.container)
    pid = engine_pid(a.container, initial['container_id'])
    start_ticks = proc_stat(Path(f'/proc/{pid}/stat'))['start_ticks']
    save(output / 'identity.json', dict(initial, engine_pid=pid, engine_start_ticks=start_ticks,
                                       cpu_tick_hz=os.sysconf('SC_CLK_TCK'), interval_s=a.interval))
    started = time.monotonic()
    try:
        while not stopped:
            row = {'observed_unix_s': time.time(), 'errors': []}
            if identity(a.container) != initial or proc_stat(Path(f'/proc/{pid}/stat'))['start_ticks'] != start_ticks:
                raise ValueError('validator identity/configuration changed during profiling')
            row['resources'] = resources(pid)
            row['stats_started_unix_s'] = time.time()
            try:
                raw = command(['docker', 'exec', a.container, 'sh', '-c', CONTROL])
                (output / f'stats-{len(samples):04}.txt').write_text(raw)
                row['stats'] = parse_stats(raw)
                if not row['stats']:
                    row['errors'].append('no_recognized_statistics')
            except (subprocess.SubprocessError, OSError, ValueError) as exc:
                row['errors'].append('statistics_query_failed:' + type(exc).__name__)
            row['stats_finished_unix_s'] = time.time()
            samples.append(row)
            with (output / 'samples.jsonl').open('a') as f:
                f.write(json.dumps(row, allow_nan=False) + '\n')
            print(json.dumps({'event': 'validator_profile', 'samples': len(samples),
                              'elapsed_s': round(time.monotonic()-started), 'errors': row['errors']}), flush=True)
            if time.monotonic() - started >= a.duration:
                break
            next_sample = min(started + a.duration, time.monotonic() + a.interval)
            while not stopped and time.monotonic() < next_sample:
                time.sleep(min(1, max(0, next_sample - time.monotonic())))
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        samples.append({'errors': [str(exc)]})
    finally:
        observed_env = initial.get('environment', {})
        summary = summarize(samples, expected_owners=int(observed_env.get('TON_NATIVE_POOL_OWNERS', '1')),
                            expected_lane_owners=int(observed_env.get('TON_NATIVE_ADMISSION_LANE_OWNERS', '0')),
                            expected_signature_workers=int(observed_env.get('TON_NATIVE_EXECUTOR_THREADS', '8')))
        summary['thread_cpu_intervals'] = thread_intervals(samples, os.sysconf('SC_CLK_TCK'))
        summary['interrupted'] = stopped
        if a.dashboard_url and samples and 'observed_unix_s' in samples[0]:
            summary['dashboard_errors'] = capture_dashboard(a.dashboard_url, samples[0]['observed_unix_s'], time.time(), output)
        save(output / 'summary.json', summary)
        print('Profile saved: ' + str(output), flush=True)
    return 0 if summary['diagnostics_available'] and not summary['errors'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
