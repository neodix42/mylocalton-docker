#!/usr/bin/env python3
"""Offline fixtures for real owner schema, profiler scoping and wrapper cleanup."""
import copy
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('owner_profile', ROOT/'benchmark/remote/profile-native-validator.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
o = m.OWNER_STATS


def rows(count=2, tick=1):
    result = {o.HEADER: dict(enabled=int(count > 1), owners=count, prefix_bits={1:0,2:1,4:2}[count],
              total_signature_workers=8, topology_ready=1, published_generation=10+tick,
              aggregate_mempool=100-tick), o.SHARED: {'verifies':100*tick}}
    for i in range(count):
        prefix = f'native_pool.owner.{i}.' if count > 1 else 'total.'
        if count > 1:
            result[prefix+'identity'] = dict(index=i, applied_generation=11+tick, signature_workers=8//count,
                local_mempool=20+i, routed_batches=tick, routed_messages=16*tick,
                fence_rejections=0, topology_rejections=0, router_decoded_messages=16*tick,
                router_decode_samples=tick, router_decode_sum_s=.002*tick, router_decode_max_s=10-tick)
        result[prefix+'ext_msg_batch_admission'] = {'accepted':100*tick*(i+1), 'rejected':0}
        result[prefix+'ext_msg_batch_diagnostics'] = {'config_cache_hits':tick, 'config_cache_misses':tick,
                                                    'not_ready_total':0, 'verify_samples':tick, 'verify_sum_s':.004*tick}
        result[prefix+'ext_msg_native_reconciliation'] = {'runs':tick, 'pending_sources':0, 'last_mc_seqno':tick}
        result[prefix+'ext_msg_native_pending'] = {'messages':0}
    return result


def summarize(values, **kwargs):
    return m.summarize([dict(stats=value, stats_started_unix_s=30*i, stats_finished_unix_s=30*i+.1)
                        for i,value in enumerate(values)], **kwargs)


def raw(values):
    return '\n'.join(key+'\t'+' '.join(name+':'+str(value) for name,value in fields.items())
                     for key,fields in values.items())+'\n'


class OwnerProfileTests(unittest.TestCase):
    def test_passthrough_defaults_one_and_identity_whitelist(self):
        self.assertIn('TON_NATIVE_POOL_OWNERS',m.ENV_KEYS)
        self.assertEqual((ROOT/'docker-compose.yaml').read_text().count(
            '- TON_NATIVE_POOL_OWNERS=${TON_NATIVE_POOL_OWNERS:-1}'),1)
        self.assertIn('native_pool_owners_expected', (ROOT/'run-native-benchmark.sh').read_text())

    def test_complete_two_and_four_owner_profiles_are_separate(self):
        for count in (2,4):
            result=summarize([rows(count,1),rows(count,3)],expected_owners=count)
            self.assertFalse(result['errors']);self.assertTrue(result['diagnostics_available'])
            self.assertEqual(len(result['owners']),count)
            self.assertNotIn('counter_deltas',result)
            self.assertEqual(result['shared_signature_executor']['counter_deltas']['verifies'],200)
            for index,owner in result['owners'].items():
                self.assertEqual(owner['counter_deltas']['total.ext_msg_batch_admission']['accepted'],200*(int(index)+1))
                self.assertNotIn(o.SHARED,owner['counter_deltas'])
                self.assertAlmostEqual(owner['stage_mean_ms']['verify'],4)
                self.assertAlmostEqual(owner['identity']['batch_router_decode_mean_ms'],2)
                self.assertEqual(owner['identity']['lifetime_maxima_at_endpoints']['router_decode_max_s'],[9,7])
                self.assertNotIn('applied_generation',owner['identity']['counter_deltas'])
            self.assertNotIn('aggregate_mempool',result.get('counter_deltas',{}))

    def test_legacy_single_owner_schema_is_preserved(self):
        old,new=rows(1,1),rows(1,2)
        result=summarize([old,new],expected_owners=1)
        self.assertFalse(result['errors']);self.assertEqual(result['schema'],'native-validator-profile-v1')
        self.assertNotIn('owners',result)
        del old[o.HEADER];del new[o.HEADER]
        self.assertFalse(summarize([old,new],expected_owners=1)['errors'])
        self.assertTrue(o.cleanup(old,new,1)['cleanup_acceptance']['valid'])
        self.assertTrue(summarize([old,new],expected_owners=2)['errors'])
        self.assertFalse(o.cleanup(old,new,2)['cleanup_acceptance']['valid'])

    def test_missing_extra_owner_and_partial_identity_fail(self):
        for mutate in (
            lambda x:x.pop('native_pool.owner.1.identity'),
            lambda x:x['native_pool.owner.1.identity'].pop('router_decode_max_s'),
            lambda x:x.update({'native_pool.owner.9.identity':dict(x['native_pool.owner.1.identity'])}),
            lambda x:x['native_pool.owner.0.identity'].update(index=1),
            lambda x:x['native_pool.owner.0.identity'].update(signature_workers=3),
            lambda x:x.update({'total.ext_msg_batch_admission':{'accepted':1}}),
        ):
            old,new=rows(),rows(tick=2);mutate(new)
            self.assertTrue(summarize([old,new])['errors'])
            self.assertFalse(o.cleanup(old,new,2)['cleanup_acceptance']['valid'])

    def test_intermediate_counter_reset_cannot_recover_into_valid_delta(self):
        for key,field in [('native_pool.owner.1.identity','routed_messages'),
                          ('native_pool.owner.0.ext_msg_batch_admission','accepted'),
                          (o.SHARED,'verifies')]:
            values=[rows(tick=i) for i in (1,2,3,4)]
            values[1][key][field]=values[2][key][field]+1
            result=summarize(values)
            self.assertTrue(any('reset' in x for x in result['errors']))
            self.assertFalse(result['diagnostics_available'])
            for owner in result['owners'].values():self.assertFalse(owner['stage_mean_ms'])

    def test_configuration_change_and_ignored_requested_flag_reject(self):
        old,new=rows(),rows(tick=2)
        new[o.HEADER]['total_signature_workers']=10
        new['native_pool.owner.0.identity']['signature_workers']=6
        self.assertTrue(any('configuration_changed' in x for x in summarize([old,new])['errors']))
        self.assertTrue(summarize([rows(1),rows(1,2)],expected_owners=2)['errors'])
        self.assertTrue(summarize([rows(),rows(tick=2)],expected_owners=4)['errors'])

    def test_cleanup_checks_each_owner_and_generation_but_not_generic_mempool(self):
        old,new=rows(),rows(tick=2)
        self.assertTrue(o.cleanup(old,new,2)['cleanup_acceptance']['valid'])
        for key,field,value,reason in (
            ('native_pool.owner.1.ext_msg_native_pending','messages',16,'native_pool_pending_messages'),
            ('native_pool.owner.0.ext_msg_native_reconciliation','pending_sources',1,'canonical_reconciliation_pending_sources'),
            ('native_pool.owner.1.identity','applied_generation',0,'owner_applied_generation_behind_publication'),
            (o.HEADER,'topology_ready',0,'owner_topology_not_ready')):
            bad=copy.deepcopy(new);bad[key][field]=value
            self.assertTrue(any(reason in x for x in o.cleanup(old,bad,2)['cleanup_acceptance']['invalid_reasons']))
        bad=copy.deepcopy(new);del bad['native_pool.owner.1.ext_msg_native_pending']
        self.assertFalse(o.cleanup(old,bad,2)['cleanup_acceptance']['valid'])

    def test_raw_key_parser_and_last_exact_snapshot_semantics(self):
        text=raw(rows())
        self.assertEqual(o.parse_stats(text),rows())
        parsed=m.parse_stats(text)
        self.assertIn('native_pool.owner.1.identity',parsed)
        self.assertNotIn('native_pool.owner.1.ext_msg_native_pending',m.KEYS)
        duplicate=text+'  total.native_pool_owners '+raw({o.HEADER:rows(tick=2)[o.HEADER]}).split(None,1)[1]
        with self.assertRaises(ValueError):o.parse_stats(duplicate)
        self.assertEqual(o.parse_stats(duplicate,last_exact_sample=True)[o.HEADER]['published_generation'],12)
        with self.assertRaises(ValueError):o.parse_stats(text+'native_pool.owner.0.identity index:0 index:0\n')
        with self.assertRaises(ValueError):o.parse_stats(text.replace('router_decode_sum_s:0.002','router_decode_sum_s:nan'))

    def test_wrapper_actual_jq_uses_scoped_cleanup_and_retains_legacy(self):
        source=(ROOT/'run-native-benchmark.sh').read_text()
        marker='  --slurpfile ownership "$validator_owner_summary_file"'
        block=source.split(marker,1)[1].split("' >\"$validator_pool_summary_file\"",1)[0]
        jq_program=block.split('"$pending_after" \'',1)[1]
        names=('scheduler','batch','batch_diagnostics','transport','reconciliation','pending')
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'owner.json'
            for count,pending in ((1,0),(2,0),(2,16),(4,0)):
                old,new=rows(count,1),rows(count,2)
                prefix='total.' if count==1 else f'native_pool.owner.{count-1}.'
                new[prefix+'ext_msg_native_pending']['messages']=pending
                path.write_text(json.dumps(o.cleanup(old,new,count)))
                command=['jq','-L',str(ROOT/'benchmark/jq'),'-n','--slurpfile','ownership',str(path)]
                for name in names:
                    suffix={'batch':'batch_admission','batch_diagnostics':'batch_diagnostics'}.get(name,'native_'+name)
                    for phase,value in [('before',old),('after',new)]:
                        command+=['--argjson',name+'_'+phase,json.dumps(value.get('total.ext_msg_'+suffix,{}))]
                result=json.loads(subprocess.run(command+[jq_program],text=True,capture_output=True,check=True).stdout)
                self.assertEqual(result['cleanup_acceptance']['valid'],pending==0)
                if count>1:
                    self.assertIn('owners',result);self.assertNotIn('batch_admission',result)
                else:self.assertIn('batch_admission',result)


if __name__=='__main__':unittest.main()
