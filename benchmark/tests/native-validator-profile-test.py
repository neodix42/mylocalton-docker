#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import json
import copy
import io
import sys
sys.dont_write_bytecode = True

path = Path(__file__).resolve().parents[1] / 'remote/profile-native-validator.py'
spec = importlib.util.spec_from_file_location('profile_native', path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class ProfileTests(unittest.TestCase):
    def stats(self, n):
        return m.parse_stats('preamble\n' + '\n'.join([
            f'{m.KEYS[0]}\t\t\taccepted:{n*100} rejected:{n*10}',
            f'{m.KEYS[1]} config_cache_hits:{n*9} config_cache_misses:{n} config_cache_enabled:1 '
            f'not_ready_total:{n*10} not_ready_snapshot_changed:{n*8} residence_samples:{n} residence_sum_s:{n*0.25} '
            f'residence_max_s:{n} active_batches:{10-n} peak_active_batches:10',
            f'{m.KEYS[2]} calls:{n} threads_created:{n*8} residence_sum_s:{n*0.001}']))

    def pool_stats(self, n, active, queued):
        stats = self.stats(n)
        stats[m.KEYS[2]].update(
            pool_calls=10*n, pool_tickets=80*n, pool_threads=8,
            pool_threads_created=8, pool_contended_submits=n,
            pool_queue_wait_sum_s=0.01*n, pool_completion_wait_sum_s=0.2*n,
            pool_worker_cpu_sum_s=0.4*n, pool_active=active,
            pool_active_peak=4*n, pool_queue=queued, pool_queue_peak=8*n,
            pool_queue_wait_max_s=0.01*n, pool_completion_wait_max_s=0.02*n,
            pool_queue_capacity=128)
        return stats

    def reconciliation_stats(self, n, profiling=True):
        stats = self.stats(n)
        counters = dict.fromkeys(m.RECONCILIATION_DIAGNOSTIC_COUNTERS, 0)
        counters.update(profile_enabled=int(profiling), account_lookups=150*n,
                        account_kind_failures=50*n, apply_calls=100*n, apply_errors=n,
                        apply_stale_lt=n, apply_first_observation=n, apply_nonce_advanced=20*n,
                        apply_balance_only_changed=5*n, apply_unchanged=73*n, apply_effects=26*n,
                        apply_balance_increased=5*n, apply_balance_decreased=20*n,
                        pending_reservations_before_apply_sum=500*n, reservation_prefix_entries=400*n,
                        lookup_max_s=10-n, apply_max_s=10-n)
        if profiling:
            counters.update(lookup_samples=150*n, lookup_sum_s=0.03*n,
                            apply_samples=100*n, apply_sum_s=0.1*n)
        encoded = m.RECONCILIATION_DIAGNOSTIC_KEY + ' ' + ' '.join(f'{k}:{v}' for k,v in counters.items())
        stats.update(m.parse_stats(encoded))
        # The historical counter has mixed origins; this must never enter the
        # new account-outcome fractions or a supposed useful-read ratio.
        stats[m.RECONCILIATION_KEY] = dict(account_lookups=150*n, sources_advanced=100000*n)
        return stats

    def summary_between(self, before, after):
        return m.summarize([{'stats':before, 'stats_started_unix_s':1},
                            {'stats':after, 'stats_finished_unix_s':3}])

    def dispatch_stats(self, n, profiling=True):
        stats = self.stats(n)
        stats[m.BATCH_DISPATCH_KEY] = dict(profile_enabled=int(profiling), batches=4*n, messages=64*n,
            late_batches=n, wait_samples=3*n if profiling else 0, wait_sum_s=0.006*n if profiling else 0,
            wait_max_s=10-n)
        return stats

    def chunk_stats(self, n, profiling=True, enabled=True):
        stats = self.reconciliation_stats(n, profiling)
        row = stats[m.RECONCILIATION_DIAGNOSTIC_KEY]
        row.update(dict.fromkeys(m.RECONCILIATION_CHUNK_COUNTERS, 0))
        row.update(chunks_enabled=int(enabled), group_chunk_sources=256, account_chunk_sources=64,
                   chunk_budget_s=0.0005, grouping_yields=2*n if enabled else 0,
                   account_yields=4*n if enabled else 0)
        for stage in m.RECONCILIATION_CHUNK_STAGES:
            row[stage + '_max_s'] = 10-n
        if profiling:
            row.update(grouping_samples=n, grouping_sum_s=0.006*n,
                       grouping_slice_samples=3*n, grouping_slice_sum_s=0.006*n,
                       account_slice_samples=5*n, account_slice_sum_s=0.015*n,
                       yield_wait_samples=6*n if enabled else 0, yield_wait_sum_s=0.024*n if enabled else 0)
        return stats

    def locality_stats(self, n, enabled=True):
        stats = self.stats(n)
        queries, hits = (5*n, 15*n) if enabled else (20*n, 0)
        stats[m.KEYS[1]].update(locality_fastpath_enabled=int(enabled), locality_calls=2*n,
            locality_outputs=32*n, locality_destination_visits=20*n,
            locality_destination_queries=queries, locality_dedup_hits=hits, locality_shard_queries=queries+2*n)
        return stats

    def test_deltas_have_correct_units_and_exclude_gauges(self):
        first, last = self.stats(1), self.stats(3)
        d, errors = m.deltas(first, last)
        self.assertFalse(errors)
        self.assertEqual(d[m.KEYS[1]]['config_cache_hits'],18)
        for key in ('active_batches','peak_active_batches','residence_max_s','config_cache_enabled'):
            self.assertNotIn(key,d[m.KEYS[1]])
        summary=m.summarize([{'stats':first,'stats_started_unix_s':1},
                             {'stats':last,'stats_finished_unix_s':3}])
        self.assertEqual(summary['stage_mean_ms']['residence'],250)
        self.assertEqual(summary['config_cache_hit_fraction'],0.9)
        self.assertEqual(summary['snapshot_changed_fraction_of_not_ready'],0.8)

    def test_persistent_signature_pool_counters_gauges_and_legacy_schema(self):
        before, after = self.pool_stats(1, 2, 8), self.pool_stats(2, 0, 0)
        summary = self.summary_between(before, after)
        self.assertFalse(summary['errors'])
        executor = summary['signature_executor']
        self.assertTrue(executor['valid'])
        self.assertTrue(executor['pool_telemetry_available'])
        self.assertEqual(executor['counter_deltas']['pool_calls'], 10)
        self.assertEqual(executor['counter_deltas']['pool_tickets'], 80)
        self.assertEqual(executor['gauges_at_endpoints']['pool_queue'], [8, 0])
        self.assertEqual(executor['gauges_at_endpoints']['pool_active'], [2, 0])
        self.assertEqual(executor['lifetime_maxima_at_endpoints']['pool_queue_peak'], [8, 16])
        self.assertEqual(executor['lifetime_maxima_at_endpoints']['pool_completion_wait_max_s'], [0.02, 0.04])
        self.assertEqual(executor['configuration']['pool_queue_capacity'], 128)
        for key in (m.SIGNATURE_EXECUTOR_POOL_CONFIGURATION | m.SIGNATURE_EXECUTOR_POOL_GAUGES |
                    m.SIGNATURE_EXECUTOR_POOL_MAXIMA):
            self.assertNotIn(key, executor['counter_deltas'])

        legacy = self.summary_between(self.stats(1), self.stats(2))['signature_executor']
        self.assertTrue(legacy['valid'])
        self.assertFalse(legacy['pool_telemetry_available'])
        self.assertEqual(legacy['gauges_at_endpoints'], {})

    def test_relaxed_pool_snapshot_does_not_require_cross_field_consistency(self):
        # The validator emits these fields with independent relaxed loads. A
        # transition can therefore expose a new gauge beside an older peak or
        # thread count without corrupting either field's reporting semantics.
        before, after = self.pool_stats(1, 9, 9), self.pool_stats(2, 0, 0)
        summary = self.summary_between(before, after)
        self.assertFalse(summary['errors'])
        self.assertTrue(summary['signature_executor']['valid'])
        self.assertEqual(summary['signature_executor']['gauges_at_endpoints']['pool_active'], [9, 0])

    def test_partial_or_reset_persistent_signature_pool_schema_is_invalid(self):
        before, after = self.pool_stats(1, 0, 0), self.pool_stats(2, 0, 0)
        del before[m.KEYS[2]]['pool_tickets']
        summary = self.summary_between(before, after)
        self.assertIn('missing_signature_executor_pool_field:pool_tickets:sample_0', summary['errors'])
        self.assertFalse(summary['signature_executor']['valid'])
        self.assertFalse(summary['diagnostics_available'])
        self.assertEqual(summary['stage_mean_ms'], {})
        self.assertIsNone(summary['config_cache_hit_fraction'])

        before, after = self.pool_stats(2, 0, 0), self.pool_stats(1, 0, 0)
        summary = self.summary_between(before, after)
        self.assertTrue(any(error.startswith('signature_executor_pool_counter_reset:')
                            for error in summary['errors']))
        self.assertFalse(summary['diagnostics_available'])

    def test_persistent_signature_pool_environment_passthrough_is_default_off(self):
        flag = 'TON_NATIVE_VALIDATION_SIGNATURE_PERSISTENT_POOL'
        compose = path.resolve().parents[2] / 'docker-compose.yaml'
        self.assertIn(flag, m.ENV_KEYS)
        self.assertEqual(compose.read_text().count(f'- {flag}=${{{flag}:-0}}'), 1)

    def test_callback_and_durability_probe_environment_passthrough_is_default_off(self):
        compose = path.resolve().parents[2] / 'docker-compose.yaml'
        physical_env = path.resolve().parents[2] / '.env.physical'
        for flag in ('TON_NATIVE_EAGER_COLLATOR_CALLBACK',
                     'TON_NATIVE_CELLDB_DURABILITY_PROFILE',
                     'TON_NATIVE_CELLDB_UNSAFE_SYNC_FALSE'):
            with self.subTest(flag=flag):
                self.assertIn(flag, m.ENV_KEYS)
                self.assertEqual(compose.read_text().count(f'- {flag}=${{{flag}:-0}}'), 1)
                self.assertEqual(physical_env.read_text().splitlines().count(f'{flag}=0'), 1)

    def test_reset_or_missing_schema_cannot_produce_attribution(self):
        a,b=self.stats(3),self.stats(1)
        summary=m.summarize([{'stats':a,'stats_started_unix_s':1},
                             {'stats':b,'stats_finished_unix_s':3}])
        self.assertTrue(summary['errors'])
        self.assertEqual(summary['stage_mean_ms'],{})
        self.assertIsNone(summary['config_cache_hit_fraction'])
        del b[m.KEYS[2]]
        _,errors=m.deltas(a,b)
        self.assertIn('missing:'+m.KEYS[2],errors)

    def test_shard_fetch_and_reconciliation_deltas_exclude_current_state(self):
        before, after = self.stats(1), self.stats(2)
        for sample, n in [(before, 1), (after, 2)]:
            sample[m.KEYS[0]].update(shard_fetches=100*n, shard_cache_fill_races=94*n,
                                     shard_cache_entries=10-n, pinned_mc_seqno=500-n)
            sample[m.RECONCILIATION_KEY] = dict(account_lookups=200*n, sources_advanced=30*n,
                                               pending_sources=10-n, tracked_messages=20-n,
                                               last_mc_seqno=500-n)
            sample[m.KEYS[1]].update(shared_fetch_active=10-n, shared_fetch_enabled=1)
        delta, errors = m.deltas(before, after)
        self.assertFalse(errors)
        self.assertEqual(delta[m.KEYS[0]]['shard_fetches'], 100)
        self.assertEqual(delta[m.KEYS[0]]['shard_cache_fill_races'], 94)
        self.assertEqual(delta[m.RECONCILIATION_KEY], dict(account_lookups=200, sources_advanced=30))
        self.assertNotIn('shard_cache_entries', delta[m.KEYS[0]])
        self.assertNotIn('pinned_mc_seqno', delta[m.KEYS[0]])
        self.assertNotIn('shared_fetch_active', delta[m.KEYS[1]])
        self.assertNotIn('shared_fetch_enabled', delta[m.KEYS[1]])
        del after[m.RECONCILIATION_KEY]
        self.assertIn('missing:'+m.RECONCILIATION_KEY, m.deltas(before, after)[1])

    def test_invalid_or_duplicate_counters_rejected(self):
        for tail in ('calls:nan','calls:inf','calls:-1','calls:1 calls:2'):
            with self.subTest(tail=tail),self.assertRaises(ValueError):
                m.parse_stats(m.KEYS[2]+' '+tail)
        with self.assertRaises(ValueError):
            m.parse_stats(m.KEYS[2]+' calls:1\n'+m.KEYS[2]+' calls:2')

    def test_publication_deltas_exclude_configuration_and_lifetime_maximum(self):
        before, after = self.stats(1), self.stats(2)
        for sample, n in ((before, 1), (after, 2)):
            sample.update(m.parse_stats(
                f'{m.PUBLICATION_KEY} enabled:1 target_logical:2048 max_delay_s:0.001 '
                f'groups:{n*10} wait_samples:{n*10} wait_sum_s:{n*0.01} wait_max_s:{10-n} '
                f'live_batches:{n*20} live_logical:{n*20480}'))
        delta, errors = m.deltas(before, after)
        self.assertFalse(errors)
        self.assertEqual(delta[m.PUBLICATION_KEY], dict(groups=10, wait_samples=10,
                         wait_sum_s=0.01, live_batches=20, live_logical=20480))
        del after[m.PUBLICATION_KEY]
        self.assertIn('missing:' + m.PUBLICATION_KEY, m.deltas(before, after)[1])

    def test_reconciliation_group_is_optional_for_older_recordings(self):
        summary = self.summary_between(self.stats(1), self.stats(2))
        self.assertFalse(summary['errors'])
        self.assertFalse(summary['reconciliation']['available'])
        self.assertFalse(summary['reconciliation']['valid'])
        self.assertEqual(summary['reconciliation']['stage_mean_ms'], {})
        self.assertEqual(summary['reconciliation']['apply_outcome_fractions'], {})

    def test_reconciliation_stage_means_and_outcomes_use_matching_scope(self):
        before, after = self.reconciliation_stats(1), self.reconciliation_stats(2)
        summary = self.summary_between(before, after)
        self.assertFalse(summary['errors'])
        result = summary['reconciliation']
        self.assertTrue(result['available'])
        self.assertTrue(result['valid'])
        self.assertTrue(result['profile_enabled'])
        self.assertTrue(result['apply_outcomes_match_calls'])
        self.assertAlmostEqual(result['stage_mean_ms']['lookup'], 0.2)
        self.assertAlmostEqual(result['stage_mean_ms']['apply'], 1)
        self.assertAlmostEqual(result['apply_outcome_fractions']['apply_nonce_advanced'], 0.2)
        self.assertAlmostEqual(result['apply_outcome_fractions']['apply_unchanged'], 0.73)
        self.assertAlmostEqual(result['apply_effects_fraction'], 0.26)
        delta = summary['counter_deltas'][m.RECONCILIATION_DIAGNOSTIC_KEY]
        self.assertEqual(delta['reservation_prefix_entries'], 400)
        for gauge in ('profile_enabled', 'lookup_max_s', 'apply_max_s'):
            self.assertNotIn(gauge, delta)

    def test_reconciliation_timing_off_preserves_outcomes_and_detects_flag_change(self):
        before, after = self.reconciliation_stats(1, False), self.reconciliation_stats(2, False)
        summary = self.summary_between(before, after)
        self.assertFalse(summary['errors'])
        self.assertTrue(summary['reconciliation']['valid'])
        self.assertFalse(summary['reconciliation']['profile_enabled'])
        self.assertEqual(summary['reconciliation']['stage_mean_ms'], {})
        self.assertAlmostEqual(summary['reconciliation']['apply_outcome_fractions']['apply_nonce_advanced'], 0.2)
        after[m.RECONCILIATION_DIAGNOSTIC_KEY]['profile_enabled'] = 1
        summary = self.summary_between(before, after)
        self.assertIn('reconciliation_profile_changed', summary['errors'])
        self.assertFalse(summary['reconciliation']['valid'])
        self.assertEqual(summary['reconciliation']['apply_outcome_fractions'], {})

    def test_reconciliation_partial_reset_or_unmatched_outcomes_clear_attribution(self):
        group = m.RECONCILIATION_DIAGNOSTIC_KEY
        for fault in ('missing_group', 'missing_counter', 'reset', 'outcome_mismatch', 'stale_lt_subset'):
            with self.subTest(fault=fault):
                before, after = self.reconciliation_stats(1), self.reconciliation_stats(2)
                if fault == 'missing_group':
                    del after[group]
                elif fault == 'missing_counter':
                    del before[group]['apply_unchanged']
                elif fault == 'reset':
                    after[group]['lookup_sum_s'] = 0
                elif fault == 'outcome_mismatch':
                    after[group]['apply_unchanged'] -= 1
                else:
                    after[group]['apply_stale_lt'] += 1
                summary = self.summary_between(before, after)
                self.assertTrue(summary['errors'])
                self.assertFalse(summary['reconciliation']['valid'])
                self.assertEqual(summary['reconciliation']['stage_mean_ms'], {})
                self.assertEqual(summary['reconciliation']['apply_outcome_fractions'], {})
                self.assertIsNone(summary['reconciliation']['apply_effects_fraction'])

    def test_reconciliation_zero_calls_is_not_zero_percent_useful_work(self):
        same = self.reconciliation_stats(1)
        summary = self.summary_between(same, same)
        self.assertFalse(summary['errors'])
        self.assertTrue(summary['reconciliation']['valid'])
        self.assertTrue(summary['reconciliation']['apply_outcomes_match_calls'])
        self.assertEqual(summary['reconciliation']['apply_outcome_fractions'], {})
        self.assertIsNone(summary['reconciliation']['apply_effects_fraction'])

    def test_old_recordings_do_not_require_dispatch_chunks_or_locality(self):
        for factory in (self.stats, self.reconciliation_stats):
            summary = self.summary_between(factory(1), factory(2))
            self.assertFalse(summary['errors'])
            for name in m.OPTIONAL_SCHEMAS:
                self.assertFalse(summary[name]['available'])
                self.assertFalse(summary[name]['valid'])
                self.assertEqual(summary[name]['stage_mean_ms'], {})
        self.assertNotIn('account_yields', m.RECONCILIATION_DIAGNOSTIC_COUNTERS)
        self.assertNotIn('grouping_slice_samples', m.RECONCILIATION_DIAGNOSTIC_COUNTERS)

    def test_dispatch_wait_has_own_population_and_seconds_to_ms_units(self):
        summary = self.summary_between(self.dispatch_stats(1), self.dispatch_stats(2))
        self.assertFalse(summary['errors'])
        queue = summary['batch_dispatch']
        self.assertTrue(queue['valid'])
        self.assertAlmostEqual(queue['stage_mean_ms']['wait'], 2)
        self.assertEqual(queue['late_batch_fraction'], 0.25)
        self.assertEqual(summary['stage_mean_ms']['residence'], 250)
        self.assertEqual(queue['counter_deltas']['messages'], 64)
        self.assertNotIn('profile_enabled', summary['counter_deltas'][m.BATCH_DISPATCH_KEY])
        self.assertNotIn('wait_max_s', summary['counter_deltas'][m.BATCH_DISPATCH_KEY])

    def test_zero_or_disabled_dispatch_timings_are_unavailable_not_zero_latency(self):
        same = self.dispatch_stats(1)
        result = self.summary_between(same, same)['batch_dispatch']
        self.assertTrue(result['valid'])
        self.assertEqual(result['stage_mean_ms'], {})
        self.assertIsNone(result['late_batch_fraction'])
        result = self.summary_between(self.dispatch_stats(1, False), self.dispatch_stats(2, False))
        self.assertFalse(result['errors'])
        self.assertTrue(result['batch_dispatch']['valid'])
        self.assertEqual(result['batch_dispatch']['stage_mean_ms'], {})
        before, after = self.dispatch_stats(1), self.dispatch_stats(2)
        after[m.BATCH_DISPATCH_KEY]['wait_samples'] = before[m.BATCH_DISPATCH_KEY]['wait_samples']
        result = self.summary_between(before, after)
        self.assertIn('timing_sum_without_samples:batch_dispatch.wait', result['errors'])
        self.assertFalse(result['batch_dispatch']['valid'])

    def test_chunk_means_use_slice_counts_and_whole_pass_grouping_stays_separate(self):
        summary = self.summary_between(self.chunk_stats(1), self.chunk_stats(2))
        self.assertFalse(summary['errors'])
        chunks = summary['reconciliation_chunks']
        self.assertTrue(chunks['valid'])
        self.assertEqual(chunks['configuration']['chunk_budget_s'], 0.0005)
        self.assertAlmostEqual(summary['reconciliation']['stage_mean_ms']['grouping'], 6)
        for name, expected in [('grouping_slice', 2), ('account_slice', 3), ('yield_wait', 4)]:
            self.assertAlmostEqual(chunks['stage_mean_ms'][name], expected)
        delta = summary['counter_deltas'][m.RECONCILIATION_DIAGNOSTIC_KEY]
        self.assertEqual(delta['grouping_yields'], 2)
        for excluded in ('chunks_enabled', 'group_chunk_sources', 'account_chunk_sources',
                         'chunk_budget_s', 'grouping_slice_max_s', 'account_slice_max_s', 'yield_wait_max_s'):
            self.assertNotIn(excluded, delta)

    def test_chunks_profile_off_still_counts_yields_and_disabled_mode_never_yields(self):
        for profiling, enabled in ((False, True), (True, False), (False, False)):
            with self.subTest(profiling=profiling, enabled=enabled):
                summary = self.summary_between(self.chunk_stats(1, profiling, enabled),
                                               self.chunk_stats(2, profiling, enabled))
                self.assertFalse(summary['errors'])
                self.assertTrue(summary['reconciliation_chunks']['valid'])
                if not profiling:
                    self.assertEqual(summary['reconciliation_chunks']['stage_mean_ms'], {})
        before, after = self.chunk_stats(1, True, False), self.chunk_stats(2, True, False)
        after[m.RECONCILIATION_DIAGNOSTIC_KEY]['account_yields'] = 1
        summary = self.summary_between(before, after)
        self.assertIn('reconciliation_yields_while_chunks_disabled', summary['errors'])

    def test_optional_partial_schemas_and_flag_changes_cannot_make_attribution(self):
        factories = {'batch_dispatch': self.dispatch_stats, 'reconciliation_chunks': self.chunk_stats,
                     'locality': self.locality_stats}
        for name, factory in factories.items():
            definition = m.OPTIONAL_SCHEMAS[name]
            group = definition['group']
            field = sorted(definition['counters'])[0]
            flag = next(key for key, kind in definition['configuration'].items() if kind == 'flag')
            for fault in ('both_missing_field', 'new_schema', 'missing_schema', 'reset', 'flag_change'):
                with self.subTest(name=name, fault=fault):
                    before, after = factory(1), factory(2)
                    if fault == 'both_missing_field':
                        del before[group][field]; del after[group][field]
                    elif fault in ('new_schema', 'missing_schema'):
                        endpoint = before if fault == 'new_schema' else after
                        for key in definition['counters'] | set(definition['configuration']) | {
                                stage + '_max_s' for stage in definition['stages']}:
                            endpoint[group].pop(key, None)
                        if definition.get('whole_group'):
                            del endpoint[group]
                    elif fault == 'reset':
                        # Choose a known nonzero counter to make reset observable.
                        key = next(key for key in definition['counters'] if before[group][key] > 0)
                        after[group][key] = 0
                    else:
                        after[group][flag] = 1-before[group][flag]
                    summary = self.summary_between(before, after)
                    self.assertTrue(summary['errors'])
                    self.assertFalse(summary[name]['valid'])
                    self.assertEqual(summary[name]['stage_mean_ms'], {})
                    self.assertEqual(summary['stage_mean_ms'], {})

    def test_optional_intermediate_reset_missing_schema_or_config_change_is_visible(self):
        for name, factory in [('batch_dispatch', self.dispatch_stats),
                              ('reconciliation_chunks', self.chunk_stats), ('locality', self.locality_stats)]:
            definition = m.OPTIONAL_SCHEMAS[name]; group = definition['group']
            for fault in ('reset_then_recover', 'missing_middle', 'changed_then_restored'):
                with self.subTest(name=name, fault=fault):
                    first, middle, last = factory(1), factory(2), factory(3)
                    if fault == 'reset_then_recover':
                        key = next(key for key in definition['counters'] if first[group][key] > 0)
                        middle[group][key] = 0
                    elif fault == 'missing_middle':
                        del middle[group]
                    else:
                        key = next(iter(definition['configuration']))
                        middle[group][key] = 1-first[group][key]
                    summary = m.summarize([{'stats': row, 'stats_started_unix_s': i,
                                            'stats_finished_unix_s': i+0.1}
                                           for i, row in enumerate((first, middle, last), 1)])
                    self.assertTrue(summary['errors'])
                    self.assertFalse(summary[name]['valid'])
                    self.assertEqual(summary[name]['stage_mean_ms'], {})

    def test_chunk_budget_must_be_positive_and_stable_without_being_subtracted(self):
        for key, value in [('chunk_budget_s', 0), ('chunk_budget_s', 0.001),
                           ('group_chunk_sources', 0), ('account_chunk_sources', 63),
                           ('account_chunk_sources', 64.5)]:
            with self.subTest(key=key, value=value):
                before, after = self.chunk_stats(1), self.chunk_stats(2)
                after[m.RECONCILIATION_DIAGNOSTIC_KEY][key] = value
                summary = self.summary_between(before, after)
                self.assertTrue(summary['errors'])
                self.assertFalse(summary['reconciliation_chunks']['valid'])
                self.assertNotIn(key, summary['counter_deltas'][m.RECONCILIATION_DIAGNOSTIC_KEY])

    def test_locality_ratios_use_repeated_check_population_and_enforce_partition(self):
        before, after = self.locality_stats(1), self.locality_stats(2)
        summary = self.summary_between(before, after)
        self.assertFalse(summary['errors'])
        locality = summary['locality']
        self.assertTrue(locality['valid'])
        self.assertEqual(locality['destination_hit_fraction'], 0.75)
        self.assertEqual(locality['destination_queries_per_call'], 2.5)
        self.assertEqual(locality['shard_queries_per_call'], 3.5)
        for field, value in [('locality_destination_visits', 41), ('locality_outputs', 1),
                             ('locality_shard_queries', 30), ('locality_calls', 3.5)]:
            with self.subTest(field=field):
                broken = copy.deepcopy(after); broken[m.KEYS[1]][field] = value
                invalid = self.summary_between(before, broken)
                self.assertTrue(invalid['errors'])
                self.assertFalse(invalid['locality']['valid'])
                self.assertNotIn('destination_hit_fraction', invalid['locality'])
        summary = self.summary_between(self.locality_stats(1, False), self.locality_stats(2, False))
        self.assertFalse(summary['errors'])
        self.assertEqual(summary['locality']['destination_hit_fraction'], 0)
        same = self.locality_stats(1)
        self.assertIsNone(self.summary_between(same, same)['locality']['destination_hit_fraction'])

    def test_missing_stage_sum_does_not_fabricate_zero_mean(self):
        before, after = self.stats(1), self.stats(2)
        del before[m.KEYS[1]]['residence_sum_s']; del after[m.KEYS[1]]['residence_sum_s']
        self.assertNotIn('residence', self.summary_between(before, after)['stage_mean_ms'])

    def test_dashboard_uses_distinct_collation_and_validation_merkle_names(self):
        urls = []
        def response(url, **kwargs):
            urls.append(url)
            return io.StringIO('[]')
        with tempfile.TemporaryDirectory() as directory, patch.object(m.urllib.request, 'urlopen', side_effect=response):
            self.assertFalse(m.capture_dashboard('http://example.invalid', 100, 200, Path(directory)))
        requested = [m.urllib.parse.parse_qs(m.urllib.parse.urlsplit(url).query)['stats'][0].split(',') for url in urls]
        collation = next(row for row in requested if any('BLOCK_collate_' in item for item in row))
        validation = next(row for row in requested if any('BLOCK_validate_' in item for item in row))
        self.assertIn('BLOCK_collate_work_time_real_create_state_merkle_update', collation)
        self.assertNotIn('BLOCK_collate_work_time_real_state_merkle_update', collation)
        self.assertIn('BLOCK_validate_work_time_real_state_merkle_update', validation)
        self.assertNotIn('BLOCK_validate_work_time_real_create_state_merkle_update', validation)

    def test_thread_pid_reuse_and_counter_reset_are_not_cpu_work(self):
        def sample(t, cpu, start=1):
            return {'observed_unix_s':t,'resources':{'threads':{'123':{
                'start_ticks':start,'cpu_ticks':cpu,'schedstat':[0,1000000000,0],'comm':'actor'}}}}
        self.assertEqual(m.thread_intervals([sample(0,100),sample(1,200)],100)[0]['sampled_cpu_cores'],1)
        self.assertEqual(m.thread_intervals([sample(0,100),sample(1,200,2)],100)[0]['sampled_cpu_cores'],0)
        self.assertEqual(m.thread_intervals([sample(0,100),sample(1,10)],100)[0]['sampled_cpu_cores'],0)

    def test_proc_stat_accepts_spaces_parentheses_in_comm(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'stat'
            fields=['S']+['0']*19
            fields[11]='100';fields[12]='20';fields[19]='300'
            p.write_text('42 (actor (worker)) '+' '.join(fields))
            value=m.proc_stat(p)
            self.assertEqual(value['cpu_ticks'],120)
            self.assertEqual(value['start_ticks'],300)

    def test_identity_whitelists_configuration_without_exporting_secrets(self):
        record={'Id':'id','Image':'sha256:image','RestartCount':0,
                'State':{'Running':True,'StartedAt':'start','Pid':7},'HostConfig':{},
                'Config':{'Env':['TON_NATIVE_ADMISSION_CONFIG_CACHE=1','TON_NATIVE_RECONCILIATION_PROFILE=1',
                                 'TON_NATIVE_RECONCILIATION_CHUNKS=1','TON_NATIVE_ADMISSION_LOCALITY_FASTPATH=0',
                                 'TON_KEYRING_PREPARED_SIGNING=1','TON_OVERLAY_LOCAL_SIGNATURE_REUSE=0',
                                 'TON_NATIVE_CANDIDATE_METADATA_PROJECTION=1',
                                 'PRIVATE_KEY=secret','TOKEN=secret']}}
        with patch.object(m,'command',return_value=json.dumps([record])):
            value=m.identity('genesis')
        self.assertEqual(value['environment'],{'TON_NATIVE_ADMISSION_CONFIG_CACHE':'1',
                                              'TON_NATIVE_RECONCILIATION_PROFILE':'1',
                                              'TON_NATIVE_RECONCILIATION_CHUNKS':'1',
                                              'TON_NATIVE_ADMISSION_LOCALITY_FASTPATH':'0',
                                              'TON_KEYRING_PREPARED_SIGNING':'1',
                                              'TON_OVERLAY_LOCAL_SIGNATURE_REUSE':'0',
                                              'TON_NATIVE_CANDIDATE_METADATA_PROJECTION':'1'})
        self.assertNotIn('secret',json.dumps(value))

    def test_engine_pid_must_belong_to_inspected_container(self):
        with patch.object(m,'command',return_value='PID COMMAND\n123 validator-engin\n'), \
             patch.object(m.os,'readlink',return_value='/usr/bin/validator-engine'), \
             patch.object(Path,'read_text',return_value='0::/system.slice/docker-exact-id.scope'):
            self.assertEqual(m.engine_pid('genesis','exact-id'),123)
            with self.assertRaises(ValueError):
                m.engine_pid('genesis','different-container')

    def test_sampler_writes_evidence_and_only_requests_read_operations(self):
        calls=[]
        def command(args, **kwargs):
            calls.append(args)
            if args[:3]==['docker','context','inspect']:
                return json.dumps([{'Endpoints':{'docker':{'Host':'unix:///var/run/docker.sock'}}}])
            self.assertEqual(args[:4],['docker','exec','genesis','sh'])
            return '\n'.join(k+' '+ ' '.join(f'{n}:{v}' for n,v in fields.items())
                             for k,fields in self.stats(len(calls)).items())
        with tempfile.TemporaryDirectory() as d:
            output=Path(d)/'profile'
            with patch.object(sys,'argv',['profile','--duration','1','--output',str(output)]), \
                 patch.object(m,'command',side_effect=command), \
                 patch.object(m,'identity',return_value={'container_id':'stable'}), \
                 patch.object(m,'engine_pid',return_value=7), \
                 patch.object(m,'proc_stat',return_value={'start_ticks':42}), \
                 patch.object(m,'resources',return_value={'threads':{}}), \
                 patch.dict(m.os.environ,{'DOCKER_HOST':''}):
                self.assertEqual(m.main(),0)
            summary=json.loads((output/'summary.json').read_text())
            self.assertTrue(summary['diagnostics_available'])
            self.assertGreaterEqual(summary['statistics_samples'],2)
            self.assertTrue((output/'samples.jsonl').is_file())
            self.assertEqual(summary['config_cache_hit_fraction'],0.9)


if __name__ == '__main__':
    unittest.main()
