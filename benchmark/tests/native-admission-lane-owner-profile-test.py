#!/usr/bin/env python3
"""Strict new-owner population, retained watermark and live drain fixtures."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('legacy_fixtures', Path(__file__).with_name('native-pool-owner-profile-test.py'))
f = importlib.util.module_from_spec(spec); spec.loader.exec_module(f)
m, o = f.m, f.o


def local(tick=1, producer=False):
    value = {key: row for key, row in f.rows(1, tick).items() if key not in (o.HEADER, o.SHARED)}
    value['total.ext_msg_mempool'] = dict(messages=0, native=0, native_logical=0)
    value['total.ext_msg_native_pending'] = dict(accounts=0, messages=0, logical_messages=0, nonce_watermarks=6144)
    value['total.ext_msg_batch_diagnostics'].update(active_batches=0, prepare_active_parents=0, prepare_active_bytes=0, shard_shared_active=0)
    value['total.ext_msg_native_transport'] = dict.fromkeys(('pending', 'live_queued', 'live_unpushed', 'logical_pending',
        'logical_live_queued', 'logical_live_unpushed', 'push_reserved', 'logical_push_reserved'), 0)
    if producer:
        value['total.ext_msg_native_persistent_producer'] = dict(enabled=1, lanes=1, publications=100*tick,
            published_sources=200*tick, published_messages=2000*tick, **dict.fromkeys(o.PRODUCER_LIVE_FIELDS, 0))
    return value


def rows(tick=1, producer=False):
    value = local(tick, producer)
    value['total.ext_msg_native_pending']['nonce_watermarks'] = 0
    value[o.SHARED] = dict(verifies=100*tick, helper_thread_launch_max_s=10-tick)
    value[o.LANE_HEADER] = dict(enabled=1, owners=4, topology_ready=1, topology_failed=0,
        published_generation=10+tick, shared_signature_workers=8, aggregate_mempool=0,
        coordinator_native_accounts=0, coordinator_native_watermarks=0, routed_batches=tick, routed_parents=64*tick,
        inline_preparations=0, join_samples=tick, join_sum_s=.04*tick, join_max_s=10-tick)
    for index in range(4):
        prefix = f'native_pool.owner.{index}.'
        value[prefix+'identity'] = dict(index=index, generation=11+tick+index, local_signature_workers=0,
            shared_signature_workers=8, fence_rejections=0, admission_batches=tick, admission_parents=16*tick,
            admission_max_parents=64-index, queue_samples=tick, queue_sum_s=.002*tick, queue_max_s=9-tick)
        value.update({prefix+key: row for key,row in local(tick, producer).items()})
        # Each child currently emits the same process-global executor family.
        # A scoped observer must retain it raw but count the root only once.
        value[prefix+o.SHARED] = dict(verifies=100*tick, helper_thread_launch_max_s=10-tick)
    return value


def clean(old, after, confirm, producer=False):
    return o.cleanup(old, after, 1, expected_lane_owners=4, expected_signature_workers=8,
                     persistent_producer=producer, confirmation=confirm)


class LaneOwnerTests(unittest.TestCase):
    def test_real_boolean_owner_snapshots_parse_and_cleanup(self):
        fixture_root = Path(__file__).with_name('fixtures')
        manifest = json.loads((fixture_root/'native-lane-owner-52a20df0-manifest.json').read_text())
        samples = {}
        for label, capture in manifest['captures'].items():
            raw = (fixture_root/capture['fixture']).read_bytes()
            self.assertEqual(hashlib.sha256(raw).hexdigest(), capture['fixture_sha256'])
            text = raw.decode()
            self.assertIn('topology_ready:true topology_failed:false', text)
            parsed = o.parse_stats(text)
            self.assertEqual(parsed[o.LANE_HEADER]['topology_ready'], 1)
            self.assertEqual(parsed[o.LANE_HEADER]['topology_failed'], 0)
            self.assertIs(type(parsed[o.LANE_HEADER]['topology_ready']), int)
            self.assertEqual(m.parse_stats(text)[o.LANE_HEADER], parsed[o.LANE_HEADER])
            self.assertTrue(o.lane_snapshot(parsed)['valid'])
            samples[label] = parsed
        result = clean(samples['before'], samples['after'], samples['confirmation'], True)
        self.assertTrue(result['cleanup_acceptance']['valid'], result['cleanup_acceptance'])
        self.assertEqual(set(result['owners']), {'0', '1', '2', '3'})

    def test_only_declared_topology_fields_accept_wire_booleans(self):
        for key, names in o.BOOLEAN_FIELDS.items():
            for name in names:
                for raw, expected in [('true', 1), ('false', 0), ('1', 1), ('0', 0)]:
                    self.assertEqual(o.parse_stat_value(key, name, raw), expected)
                for raw in ('True', 'False', 'yes', 'no', '2', '-1', '1.0', 'nan', ''):
                    with self.assertRaises(ValueError): o.parse_stat_value(key, name, raw)
        # Every numeric live cleanup field remains numeric, even if a false
        # token might otherwise compare equal to zero in Python.
        fields = {
            'total.ext_msg_native_reconciliation': ('pending_sources',),
            'total.ext_msg_native_pending': ('accounts', 'messages', 'logical_messages', 'nonce_watermarks'),
            'total.ext_msg_mempool': ('messages', 'native', 'native_logical'),
            'total.ext_msg_batch_diagnostics': ('active_batches', 'prepare_active_parents', 'prepare_active_bytes', 'shard_shared_active'),
            'total.ext_msg_native_transport': ('pending', 'live_queued', 'live_unpushed', 'logical_pending',
                'logical_live_queued', 'logical_live_unpushed', 'push_reserved', 'logical_push_reserved'),
            'total.ext_msg_native_persistent_producer': o.PRODUCER_LIVE_FIELDS,
        }
        for prefix in [''] + [f'native_pool.owner.{i}.' for i in range(4)]:
            for key, names in fields.items():
                for name in names:
                    for token in ('false', 'true'):
                        raw = prefix + key + ' ' + name + ':' + token + '\n'
                        parsers = [o.parse_stats]
                        if prefix + key in m.KEYS or o.is_owner_key(prefix + key):
                            parsers.append(m.parse_stats)
                        for parser in parsers:
                            with self.subTest(key=prefix + key, field=name, token=token, parser=parser.__module__):
                                with self.assertRaises(ValueError): parser(raw)
        for key, name in [(o.LANE_HEADER, 'aggregate_mempool'), (o.LANE_HEADER, 'published_generation'),
                          (o.LANE_HEADER, 'coordinator_native_accounts'), (o.LANE_HEADER, 'owners'),
                          (o.LANE_HEADER, 'unknown_boolean'), ('native_pool.owner.0.identity', 'generation'),
                          ('native_pool.owner.0.identity', 'local_signature_workers')]:
            with self.assertRaises(ValueError): o.parse_stats(key + ' ' + name + ':false\n')
        self.assertFalse(o.number(False))
        # Legitimate boolean flags still participate in strict topology gates.
        for change in ({'topology_ready': 0}, {'topology_failed': 1}):
            bad = rows(3, True); bad[o.LANE_HEADER].update(change)
            raw = f.raw(bad).replace('topology_ready:0', 'topology_ready:false').replace('topology_failed:1', 'topology_failed:true')
            self.assertFalse(clean(rows(1, True), rows(2, True), o.parse_stats(raw), True)['cleanup_acceptance']['valid'])

    def test_explicit_identity_shared_budget_and_retained_watermarks(self):
        result = clean(rows(1), rows(2), rows(3))
        self.assertTrue(result['cleanup_acceptance']['valid'], result)
        self.assertEqual(set(result['owners']), {'0','1','2','3'})
        self.assertEqual(result['owners']['0']['after']['total.ext_msg_native_pending']['nonce_watermarks'],6144)
        self.assertFalse(o.cleanup(rows(), rows(2), 1)['cleanup_acceptance']['valid'])
        self.assertFalse(clean(f.rows(1), f.rows(1,2), f.rows(1,3))['cleanup_acceptance']['valid'])
        self.assertFalse(clean(rows(), rows(2), None)['cleanup_acceptance']['valid'])

    def test_missing_zero_lane_extra_lane_local_threads_root_native_and_generation_fail(self):
        for mutate in (
            lambda value:value.pop('native_pool.owner.0.identity'),
            lambda value:value.update({'native_pool.owner.4.identity':dict(value['native_pool.owner.0.identity'])}),
            lambda value:value['native_pool.owner.0.identity'].update(local_signature_workers=8),
            lambda value:value['native_pool.owner.1.identity'].update(shared_signature_workers=2),
            lambda value:value[o.LANE_HEADER].update(shared_signature_workers=32),
            lambda value:value[o.LANE_HEADER].update(coordinator_native_accounts=1),
            lambda value:value['total.ext_msg_native_pending'].update(nonce_watermarks=1),
            lambda value:value['native_pool.owner.3.identity'].update(generation=0),
            lambda value:value[o.LANE_HEADER].update(topology_failed=1),
        ):
            bad=rows(3); mutate(bad)
            self.assertFalse(clean(rows(), rows(2), bad)['cleanup_acceptance']['valid'])

    def test_two_clean_snapshots_every_live_gauge_and_no_double_count(self):
        for scope in ['']+[f'native_pool.owner.{i}.' for i in range(4)]:
            for group, field in [('total.ext_msg_native_pending','messages'), ('total.ext_msg_mempool','native'),
                                 ('total.ext_msg_native_reconciliation','pending_sources'),
                                 ('total.ext_msg_batch_diagnostics','prepare_active_bytes'),
                                 ('total.ext_msg_native_transport','logical_push_reserved')]:
                bad=rows(2);bad[scope+group][field]=1
                self.assertFalse(clean(rows(),bad,rows(3))['cleanup_acceptance']['valid'])
                self.assertFalse(clean(rows(),rows(2),bad)['cleanup_acceptance']['valid'])
        bad=rows(3);bad[o.LANE_HEADER]['aggregate_mempool']=1
        self.assertFalse(clean(rows(),rows(2),bad)['cleanup_acceptance']['valid'])

    def test_producer_missing_or_nonzero_live_evidence_fails_but_retained_actor_allowed(self):
        self.assertTrue(clean(rows(1,True),rows(2,True),rows(3,True),True)['cleanup_acceptance']['valid'])
        self.assertFalse(clean(rows(),rows(2),rows(3),True)['cleanup_acceptance']['valid'])
        for field in o.PRODUCER_LIVE_FIELDS:
            for change in ('pending','missing'):
                bad=rows(3,True); group=bad['native_pool.owner.0.total.ext_msg_native_persistent_producer']
                if change=='missing':group.pop(field)
                else:group[field]=1
                self.assertFalse(clean(rows(1,True),rows(2,True),bad,True)['cleanup_acceptance']['valid'])
        old,new,confirmation=(local(i,True) for i in (1,2,3))
        self.assertTrue(o.cleanup(old,new,1,persistent_producer=True,confirmation=confirmation)['cleanup_acceptance']['valid'])
        confirmation['total.ext_msg_native_persistent_producer']['inbox_latest_sources']=1
        self.assertFalse(o.cleanup(old,new,1,persistent_producer=True,confirmation=confirmation)['cleanup_acceptance']['valid'])

    def test_profile_keeps_five_populations_and_one_executor(self):
        result=f.summarize([rows(1),rows(3)],expected_owners=1,expected_lane_owners=4)
        self.assertFalse(result['errors'], result)
        self.assertTrue(result['diagnostics_available'])
        self.assertEqual(result['shared_signature_executor']['counter_deltas']['verifies'],200)
        self.assertNotIn('helper_thread_launch_max_s', result['shared_signature_executor']['counter_deltas'])
        self.assertNotIn('counter_deltas', result)
        for owner in result['owners'].values():
            self.assertNotIn(o.SHARED,owner['counter_deltas'])
            self.assertEqual(owner['identity']['queue_mean_ms'],2)
            self.assertNotIn('generation',owner['identity']['counter_deltas'])
            self.assertNotIn('prepare_active_bytes',owner['counter_deltas']['total.ext_msg_batch_diagnostics'])
        self.assertFalse(f.summarize([rows(),rows(2)],expected_owners=1)['diagnostics_available'])

    def test_intermediate_counter_reset_rejects_attribution(self):
        for key,field in [(o.LANE_HEADER,'routed_parents'), ('native_pool.owner.0.identity','admission_batches'),
                          ('native_pool.owner.3.total.ext_msg_batch_admission','accepted'),(o.SHARED,'verifies')]:
            samples=[rows(i) for i in (1,2,3,4)];samples[1][key][field]=samples[2][key][field]+1
            result=f.summarize(samples,expected_owners=1,expected_lane_owners=4)
            self.assertFalse(result['diagnostics_available']);self.assertTrue(result['errors'])

    def test_parser_distinct_confirmation_and_provenance(self):
        raw=f.raw(rows())
        self.assertEqual(o.parse_stats(raw),rows())
        self.assertEqual(m.parse_stats(raw)['native_pool.owner.0.identity']['local_signature_workers'],0)
        with self.assertRaises(ValueError):o.parse_stats(raw+raw)
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary);before=path/'before';after=path/'after';confirm=path/'confirm';out=path/'out'
            for file,tick in [(before,1),(after,2),(confirm,3)]:file.write_text(f.raw(rows(tick)))
            command=['python3',str(ROOT/'benchmark/remote/native_pool_owner_stats.py'),'--before',str(before),
                     '--after',str(after),'--confirmation',str(confirm),'--expected-owners','1',
                     '--expected-admission-lane-owners','4','--output',str(out)]
            subprocess.run(command,check=True)
            result=json.loads(out.read_text());self.assertTrue(result['cleanup_acceptance']['valid'])
            self.assertEqual(len(result['captures']['confirmation']['sha256']),64)
            out.unlink();command[command.index('--confirmation')+1]=str(after);subprocess.run(command,check=True)
            self.assertFalse(json.loads(out.read_text())['cleanup_acceptance']['valid'])

    def test_wrapper_actual_jq_uses_new_scoped_receipt(self):
        source=(ROOT/'run-native-benchmark.sh').read_text()
        block=source.split('  --slurpfile ownership "$validator_owner_summary_file"',1)[1].split("' >\"$validator_pool_summary_file\"",1)[0]
        program=block.split('"$pending_after" \'',1)[1]
        names=('scheduler','batch','batch_diagnostics','transport','reconciliation','pending')
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary)/'owner.json'
            for dirty in (False,True):
                old,after,confirmation=rows(1,True),rows(2,True),rows(3,True)
                if dirty:confirmation['native_pool.owner.0.total.ext_msg_native_pending']['messages']=16
                path.write_text(json.dumps(clean(old,after,confirmation,True)))
                command=['jq','-L',str(ROOT/'benchmark/jq'),'-n','--slurpfile','ownership',str(path)]
                for name in names:
                    for phase in ('before','after'):command+=['--argjson',name+'_'+phase,'{}']
                result=json.loads(subprocess.run(command+[program],text=True,capture_output=True,check=True).stdout)
                self.assertEqual(result['cleanup_acceptance']['valid'],not dirty)
                self.assertEqual(result['expected_admission_lane_owners'],4)
                self.assertIn('coordinator',result);self.assertNotIn('batch_admission',result)

    def test_environment_identity_includes_all_features(self):
        for key in ['TON_NATIVE_ADMISSION_LANE_OWNERS','TON_NATIVE_PERSISTENT_PRODUCER',
                    'TON_NATIVE_ADMISSION_PREPARE','TON_NATIVE_CANONICAL_JOURNAL','TON_NATIVE_LANE_SCHEDULERS']:
            self.assertIn(key,m.ENV_KEYS)

if __name__=='__main__':unittest.main()
