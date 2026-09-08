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

    def test_invalid_or_duplicate_counters_rejected(self):
        for tail in ('calls:nan','calls:inf','calls:-1','calls:1 calls:2'):
            with self.subTest(tail=tail),self.assertRaises(ValueError):
                m.parse_stats(m.KEYS[2]+' '+tail)
        with self.assertRaises(ValueError):
            m.parse_stats(m.KEYS[2]+' calls:1\n'+m.KEYS[2]+' calls:2')

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
                'Config':{'Env':['TON_NATIVE_ADMISSION_CONFIG_CACHE=1','PRIVATE_KEY=secret','TOKEN=secret']}}
        with patch.object(m,'command',return_value=json.dumps([record])):
            value=m.identity('genesis')
        self.assertEqual(value['environment'],{'TON_NATIVE_ADMISSION_CONFIG_CACHE':'1'})
        self.assertNotIn('secret',json.dumps(value))

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
