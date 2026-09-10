#!/usr/bin/env python3
"""Offline fixtures for dispatch/freshness profile schemas; no Docker calls."""
import copy
import importlib.util
from pathlib import Path
import unittest

path=Path(__file__).resolve().parents[1]/'remote/profile-native-validator.py'
spec=importlib.util.spec_from_file_location('dispatch_profile',path)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
FLAGS=('TON_NATIVE_ADMISSION_VERIFIER_BATCH','TON_NATIVE_ADMISSION_DISPATCH_PROFILE',
       'TON_NATIVE_RECONCILIATION_COALESCE','TD_ACTOR_PROFILE_CPU')


def stats(n, profile=True, cpu=True):
    result={key:{} for key in m.REQUIRED_KEYS}
    result[m.REQUIRED_KEYS[0]]={'accepted':100*n,'rejected':0}
    result[m.REQUIRED_KEYS[1]]={'config_cache_hits':n,'config_cache_misses':0,'not_ready_total':0}
    for name in ('signature_dispatch','reconciliation_coalescing'):
        d=m.OPTIONAL_SCHEMAS[name];row=result.setdefault(d['group'],{})
        row.update(dict.fromkeys(d['counters'],0))
        row.update({key:1 for key in d['configuration']})
        row.update(dict.fromkeys(d.get('gauges',{}),0));row.update(dict.fromkeys(d.get('maxima',{}),0))
        row.update({stage+'_max_s':10-n for stage in d['stages']})
    dispatch=result[m.REQUIRED_KEYS[1]]
    dispatch.update(signature_dispatch_profile_enabled=int(profile),signature_dispatch_cpu_supported=int(cpu),
                    signature_dispatch_task_limit=16,signature_dispatch_rounds=n,signature_dispatch_tasks=2*n,
                    signature_dispatch_items=32*n,signature_dispatch_run_items=32*n,signature_dispatch_logical_transfers=512*n,
                    signature_dispatch_reply_tasks=n,signature_dispatch_reply_items=16*n,
                    signature_dispatch_failed_tasks=n,signature_dispatch_timeout_tasks=n,signature_dispatch_max_task_items=16)
    if profile:
        dispatch.update(signature_dispatch_profiled_reply_tasks=n,signature_dispatch_cache_hits=12*n,
                        signature_dispatch_cache_misses=4*n,signature_dispatch_crypto_attempts=4*n,
                        signature_dispatch_crypto_successes=4*n,signature_dispatch_cpu_unsupported_tasks=0 if cpu else n)
        for stage in m.SIGNATURE_DISPATCH_STAGES:
            if stage.endswith('worker_cpu') and not cpu:continue
            dispatch[stage+'_samples']=n;dispatch[stage+'_sum_s']=.002*n
    recon=result[m.RECONCILIATION_COALESCING_KEY]
    recon.update(profile_enabled=int(profile),notifications=4*n,registrations=n,registered_notifications=4*n,
                 folded_notifications=3*n,active_notifications=3*n,coalesced_notifications=3*n,
                 pass_sources=100*n,generation_lag_sum=n,generation_lag_max=10-n)
    if profile:
        for stage in m.RECONCILIATION_COALESCING_STAGES:
            recon[stage+'_samples']=n;recon[stage+'_sum_s']=.004*n
    return result


def summarize(rows):
    return m.summarize([{'stats':row,'stats_started_unix_s':i+1,'stats_finished_unix_s':i+1.1}
                        for i,row in enumerate(rows)])


class DispatchProfileTests(unittest.TestCase):
    def test_flags_default_off_passthrough_and_identity_whitelist(self):
        compose=Path(__file__).resolve().parents[2]/'docker-compose.yaml'
        text=compose.read_text()
        for flag in FLAGS:
            self.assertIn(flag,m.ENV_KEYS)
            self.assertEqual(text.count(f'- {flag}=${{{flag}:-0}}'),1)

    def test_clock_units_and_physical_vs_logical_populations(self):
        result=summarize([stats(1),stats(3)])
        self.assertFalse(result['errors'])
        value=result['signature_dispatch'];self.assertTrue(value['valid'])
        self.assertEqual(value['physical_items_per_dispatched_task'],16)
        self.assertEqual(value['counter_deltas']['signature_dispatch_logical_transfers'],1024)
        self.assertTrue(all(abs(v-2)<1e-8 for v in value['stage_mean_ms'].values()))
        self.assertTrue(value['worker_cpu_available'])
        self.assertEqual(value['lifetime_maxima_at_endpoints']['signature_dispatch_max_task_items'],[16,16])
        recon=result['reconciliation_coalescing'];self.assertTrue(recon['valid'])
        self.assertTrue(all(abs(v-4)<1e-8 for v in recon['stage_mean_ms'].values()))
        self.assertTrue(all(v is True for k,v in recon['notification_accounting_diagnostics'].items() if k!='semantics'))
        for group,keys in [(m.REQUIRED_KEYS[1],['signature_dispatch_cpu_supported','signature_dispatch_task_limit','signature_dispatch_max_task_items']),
                           (m.RECONCILIATION_COALESCING_KEY,['enabled','profile_enabled','registration_pending','pending_notifications','generation_lag_max'])]:
            for key in keys:self.assertNotIn(key,result['counter_deltas'][group])

    def test_missing_old_schema_unavailable_partial_schema_invalid(self):
        self.assertFalse(summarize([{key:{} for key in m.REQUIRED_KEYS}]*2)['signature_dispatch']['available'])
        for name,key in [('signature_dispatch','signature_dispatch_cpu_supported'),('reconciliation_coalescing','pending_notifications')]:
            a,b=stats(1),stats(2);del b[m.OPTIONAL_SCHEMAS[name]['group']][key]
            result=summarize([a,b]);self.assertFalse(result[name]['valid']);self.assertTrue(result['errors'])

    def test_intermediate_reset_and_config_change_reject(self):
        for name,key in [('signature_dispatch','signature_dispatch_items'),('reconciliation_coalescing','notifications')]:
            rows=[stats(1),stats(5),stats(3)]
            result=summarize(rows);self.assertFalse(result[name]['valid'])
            self.assertTrue(any('optional_counter_reset' in e for e in result['errors']))
        a,b=stats(1),stats(2);b[m.REQUIRED_KEYS[1]]['signature_dispatch_task_limit']=32
        self.assertTrue(any('optional_configuration_changed' in e for e in summarize([a,b])['errors']))

    def test_profile_off_and_cpu_unsupported_are_not_zero_cpu_cost(self):
        off=summarize([stats(1,False),stats(3,False)])
        self.assertTrue(off['signature_dispatch']['valid']);self.assertFalse(off['signature_dispatch']['worker_cpu_available'])
        self.assertEqual(off['signature_dispatch']['stage_mean_ms'],{})
        unsupported=summarize([stats(1,True,False),stats(3,True,False)])
        self.assertTrue(unsupported['signature_dispatch']['valid']);self.assertFalse(unsupported['signature_dispatch']['worker_cpu_available'])
        self.assertNotIn('signature_dispatch_worker_cpu',unsupported['signature_dispatch']['stage_mean_ms'])
        self.assertEqual(unsupported['signature_dispatch']['counter_deltas']['signature_dispatch_cpu_unsupported_tasks'],2)
        a,b=stats(1,False),stats(2,False);b[m.REQUIRED_KEYS[1]]['signature_dispatch_queue_samples']=1
        self.assertTrue(any('timing_while_profile_disabled' in e for e in summarize([a,b])['errors']))

    def test_legacy_unit_path_keeps_helper_reply_completion_unobserved(self):
        a,b=stats(1,False),stats(3,False)
        for row,n in ((a,1),(b,3)):
            d=row[m.REQUIRED_KEYS[1]]
            d.update(signature_dispatch_reply_tasks=0,signature_dispatch_reply_items=0,
                     signature_dispatch_legacy_tasks=2*n,signature_dispatch_legacy_results=n,
                     signature_dispatch_legacy_errors=n,signature_dispatch_legacy_timeouts=n)
        value=summarize([a,b])['signature_dispatch']
        self.assertTrue(value['valid']);self.assertTrue(value['legacy_unit_path_observed'])
        self.assertFalse(value['helper_reply_population_observed'])
        self.assertIsNone(value['helper_completion_fraction'])
        self.assertEqual(value['stage_mean_ms'],{})

    def test_gauge_changes_and_nonpartition_diagnostics_do_not_reset_counters(self):
        a,b=stats(1),stats(3)
        a[m.RECONCILIATION_COALESCING_KEY]['pending_notifications']=8
        a[m.RECONCILIATION_COALESCING_KEY]['registration_pending']=1
        result=summarize([a,b]);self.assertTrue(result['reconciliation_coalescing']['valid'])
        self.assertEqual(result['reconciliation_coalescing']['gauges_at_endpoints']['pending_notifications'],[8,0])
        self.assertFalse(result['reconciliation_coalescing']['notification_accounting_diagnostics']['notifications_equal_registered_plus_pending_at_samples'])
        a,b=stats(1),stats(3);b[m.REQUIRED_KEYS[1]]['signature_dispatch_reply_items']=80
        result=summarize([a,b]);self.assertTrue(result['signature_dispatch']['valid'])
        self.assertFalse(result['signature_dispatch']['reply_trace_diagnostics']['reply_items_equal_classified_cache_items'])


if __name__=='__main__':unittest.main(verbosity=2)
