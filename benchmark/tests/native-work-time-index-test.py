#!/usr/bin/env python3
"""Check indexed telemetry against the original parsers, including fallbacks."""

import json
from pathlib import Path
import subprocess
import unittest


JQ_DIR = Path(__file__).resolve().parents[1] / "jq"


class WorkTimeIndexTest(unittest.TestCase):
    def test_index_and_legacy_parsers_are_equivalent(self):
        canonical = [
            "", "stat=0", "stat=1", "stat=-1", "stat=+1", "stat=-0",
            "stat=1.25", "stat=1e3", "stat=1E-3", "stat=1e+3",
            "stat=true", "stat=false", "stat=1 prefix_stat=2 stat_suffix=3",
        ]
        fallback = [
            "stat=", "stat=bad", "stat=1garbage", "stat=truegarbage",
            "stat=falsegarbage", "stat=1.2.3", "stat=1e", "stat=+",
            "stat=01", "stat=.5", "stat=1.", "stat=nan", "stat=Infinity",
            "stat=1 stat=2", "stat=bad stat=2", "stat=1 stat=bad",
            "stat=1  other=2", " stat=1", "stat=1 ",
            "stat=1\nother=2", "other=2\nstat=1", "stat=1\n",
            "stat=1\tother=2", "other=2\tstat=1", "stat=1\r",
            "stat=1\vother=2", "stat=1\fother=2", "stat=1\u00a0other=2",
            "stat=1 extra", "stat=1=2", "stat=1 a.b=2",
            "stat=1 unrelated=2 unrelated=3",
        ]
        rows = ([{"work_time_real_stats": value} for value in canonical + fallback]
                + [{}, {"work_time_real_stats": None},
                   {"work_time_real_stats": False},
                   {"work_time_real_stats": True},
                   {"work_time_real_stats": 42},
                   {"work_time_real_stats": []},
                   {"work_time_real_stats": {"stat": 1}}])
        # Complete zero-valued snapshots cover the aggregate consumers and their
        # independent completeness contracts, then mutate one field at a time.
        fields = {
            "native_microbatches": 0,
            "native_checkpoint_groups": 0,
            "external_wait_accounted_s": 0,
            "external_wait_calls": 0,
        }
        for prefix in ("native_microbatch_accounts_", "native_staged_updates_"):
            for suffix in ("le8", "9_16", "17_32", "33_64", "le64",
                           "65_80", "81_128", "129_256", "257_511", "512", "gt512"):
                fields[prefix + suffix] = 0
        for suffix in ("1", "2", "4", "8", "other"):
            fields["native_staged_workers_" + suffix] = 0
        for category in ("round_live", "round_native_coalescing", "generic_try_pop",
                         "generic_sync_snapshot", "native_probe", "native_first_work",
                         "native_fragment_refill", "native_post_commit_idle",
                         "native_producer_drain", "native_sync_snapshot"):
            for suffix in ("_s", "_calls"):
                fields["external_wait_" + category + suffix] = 0
        for suffix in ("requests", "eager_requests", "manager_observed", "pool_observed",
                       "epoch_observed", "epoch_unobserved", "request_to_manager_s",
                       "manager_to_pool_s", "pool_to_epoch_s", "request_to_epoch_s"):
            fields["external_delivery_callback_install_" + suffix] = 0
        full = " ".join(f"{key}={value}" for key, value in fields.items())
        summary_rows = [{"work_time_real_stats": full, "wait_externals_time": 0}]
        for key in ("native_staged_updates_le8", "native_microbatch_accounts_le64",
                    "external_wait_calls", "external_delivery_callback_install_requests"):
            for value in ("bad", "1garbage", "true", "-1", "0.5", "01", "+0"):
                summary_rows.append({"work_time_real_stats": full.replace(f"{key}=0", f"{key}={value}"),
                                     "wait_externals_time": 0})
            summary_rows.extend([
                {"work_time_real_stats": full + f" {key}=0", "wait_externals_time": 0},
                {"work_time_real_stats": full.replace(f"{key}=0", ""), "wait_externals_time": 0},
            ])
        program = r'''
          include "native-benchmark-lib";
          def legacy_counter($rows; $name):
            [$rows[] | ((.work_time_real_stats? // "") |
              (capture("(?:^| )" + $name + "=(?<value>(?:[-+0-9.eE]+|true|false))")? | .value) |
              stat_counter_value) | select(. != null)];
          def legacy_stage($rows; $name):
            [$rows[] | ((.work_time_real_stats? // "") |
              (capture("(?:^| )" + $name + "=(?<value>[-+0-9.eE]+)")? | .value) |
              tonumber?) | select(. != null)];
          def legacy_space($row; $name):
            [($row.work_time_real_stats? // "" | split(" ")[] |
              select(startswith($name + "=")) | ltrimstr($name + "="))];
          def legacy_whitespace($row; $name):
            [(($row.work_time_real_stats? // null) | strings | splits("[[:space:]]+")) |
              select(startswith($name + "=")) | ltrimstr($name + "=")];
          def outcome(f): try {values:[f]} catch {error:.};
          def summaries($rows): {
            staged:native_staged_worker_histograms($rows),
            checkpoint:native_checkpoint_coalescing_summary($rows),
            deferral:native_collator_deferral_summary($rows),
            callback:collation_callback_install_summary($rows),
            wait:collation_external_wait_summary($rows)
          };
          . as $fixture |
          [
            $fixture.rows[] as $row |
            ($row | native_index_work_time_stats) as $indexed |
            ["stat", "missing", "prefix_stat", "stat_suffix"][] as $name |
            {row:$row, name:$name,
             counter:[outcome(legacy_counter([$row];$name)),
                      outcome(native_work_time_counter_values([$indexed];$name))],
             stage:[outcome(legacy_stage([$row];$name)),
                    outcome(native_work_time_stage_values([$indexed];$name))],
             space:[outcome(legacy_space($row;$name)),
                    outcome(native_work_time_space_tokens($indexed;$name))],
             whitespace:[outcome(legacy_whitespace($row;$name)),
                         outcome(native_work_time_whitespace_tokens($indexed;$name))]} |
            select(.counter[0] != .counter[1] or .stage[0] != .stage[1] or
                   .space[0] != .space[1] or .whitespace[0] != .whitespace[1])
          ] as $parser_errors |
          [
            $fixture.summary_rows[] as $row |
            ([$row] | map(native_index_work_time_stats)) as $indexed |
            select(outcome(summaries([$row])) != outcome(summaries($indexed))) |
            $row
          ] as $summary_errors |
          {
            parser_errors:$parser_errors,
            summary_errors:$summary_errors,
            mixed_equal:(summaries($fixture.summary_rows) ==
                         summaries($fixture.summary_rows | map(native_index_work_time_stats))),
            canonical_indexed:all($fixture.canonical[];
              {work_time_real_stats:.} | native_index_work_time_stats |
              ._native_work_time_stats_index != null),
            malformed_fallback:all($fixture.fallback[];
              {work_time_real_stats:.} | native_index_work_time_stats |
              ._native_work_time_stats_index == null),
            index_rebuilt:({work_time_real_stats:"stat=2",_native_work_time_stats_index:{stat:"9"}} |
              native_index_work_time_stats | ._native_work_time_stats_index.stat == "2")
          }
        '''
        result = subprocess.run(
            ["jq", "-c", "-L", str(JQ_DIR), program],
            input=json.dumps({"canonical": canonical, "fallback": fallback,
                              "rows": rows, "summary_rows": summary_rows}),
            text=True, capture_output=True, check=True,
        )
        self.assertEqual(json.loads(result.stdout), {
            "parser_errors": [], "summary_errors": [], "mixed_equal": True,
            "canonical_indexed": True, "malformed_fallback": True, "index_rebuilt": True,
        })


if __name__ == "__main__":
    unittest.main()
