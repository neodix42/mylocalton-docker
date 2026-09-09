#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import json
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
                                 'TON_KEYRING_PREPARED_SIGNING=1','TON_OVERLAY_LOCAL_SIGNATURE_REUSE=0',
                                 'TON_NATIVE_CANDIDATE_METADATA_PROJECTION=1',
                                 'PRIVATE_KEY=secret','TOKEN=secret']}}
        with patch.object(m,'command',return_value=json.dumps([record])):
            value=m.identity('genesis')
        self.assertEqual(value['environment'],{'TON_NATIVE_ADMISSION_CONFIG_CACHE':'1',
                                              'TON_NATIVE_RECONCILIATION_PROFILE':'1',
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
