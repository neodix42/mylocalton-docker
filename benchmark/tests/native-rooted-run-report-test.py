#!/usr/bin/env python3
"""Check complete, per-candidate rooted NTRN representation reporting."""

import json
from pathlib import Path
import subprocess
import unittest


JQ_DIR = Path(__file__).resolve().parents[1] / "jq"
PARENTS = "native_rooted_run_parents"
OUTPUTS = "native_rooted_run_outputs"
EXPANDED = "native_expanded_entries"
REPLAYED = "native_replayed_outputs"


def row(parents=0, outputs=0, expanded=0, replayed=None):
    fields = {PARENTS: parents, OUTPUTS: outputs, EXPANDED: expanded}
    if replayed is not None:
        fields[REPLAYED] = replayed
    return {"valid": True, "work_time_real_stats": " ".join(
        f"{key}={str(value).lower()}" for key, value in fields.items())}


class RootedRunReportTest(unittest.TestCase):
    def summary(self, rows, validation=False):
        # Every fixture exercises both normal indexed reports and the legacy
        # token path, including duplicate keys that disable the index.
        program = '''
          include "native-benchmark-lib";
          [native_run_representation_summary(.rows; .validation),
           native_run_representation_summary(
             .rows | map(native_index_work_time_stats); .validation)]
        '''
        result = subprocess.run(
            ["jq", "-c", "-L", str(JQ_DIR), program],
            input=json.dumps({"rows": rows, "validation": validation}),
            text=True, capture_output=True, check=True,
        )
        plain, indexed = json.loads(result.stdout)
        self.assertEqual(plain, indexed)
        return plain

    def assert_unavailable(self, result):
        self.assertFalse(result["telemetry_available"])
        self.assertFalse(result["capture_complete"])
        self.assertFalse(result["reconciliation"]["valid"])
        self.assertTrue(all(value is None for value in result["totals"].values()))
        self.assertTrue(all(value is None for value in result["raw_totals"].values()))

    def test_complete_control_and_treatment(self):
        for validation in (False, True):
            for rows, expected in (
                ([row(expanded=16, replayed=16), row(expanded=31, replayed=31)],
                 {PARENTS: 0, OUTPUTS: 0, EXPANDED: 47}),
                ([row(2, 32, replayed=32), row(3, 33, replayed=33)],
                 {PARENTS: 5, OUTPUTS: 65, EXPANDED: 0}),
            ):
                with self.subTest(validation=validation, expected=expected):
                    result = self.summary(rows, validation)
                    if validation:
                        expected[REPLAYED] = expected[OUTPUTS] + expected[EXPANDED]
                    self.assertTrue(result["capture_complete"])
                    self.assertTrue(result["reconciliation"]["valid"])
                    self.assertEqual(result["totals"], expected)
                    self.assertEqual(result["raw_totals"], expected)
                    self.assertEqual(result["records_total"], 2)
                    self.assertEqual(result["records_with_telemetry"], 2)

    def test_zero_native_candidates_and_boolean_counters(self):
        result = self.summary([row(False, False, False, False),
                               row(True, True, False, True)], True)
        self.assertTrue(result["reconciliation"]["valid"])
        self.assertEqual(result["totals"],
                         {PARENTS: 1, OUTPUTS: 1, EXPANDED: 0, REPLAYED: 1})

    def test_complete_rows_can_use_different_representations(self):
        result = self.summary([row(1, 16, replayed=16),
                               row(expanded=16, replayed=16)], True)
        self.assertTrue(result["reconciliation"]["valid"])
        self.assertEqual(result["totals"][OUTPUTS], 16)
        self.assertEqual(result["totals"][EXPANDED], 16)

    def test_empty_old_and_mixed_images_are_unavailable(self):
        for rows in ([], [{}], [{"work_time_real_stats": "other=9"}],
                     [row(), {}], [row(), {"work_time_real_stats": PARENTS + "=0"}]):
            with self.subTest(rows=rows):
                self.assert_unavailable(self.summary(rows))

    def test_each_field_is_required(self):
        full = row(1, 16, replayed=16)
        for field in (PARENTS, OUTPUTS, EXPANDED, REPLAYED):
            broken = dict(full)
            broken["work_time_real_stats"] = " ".join(
                token for token in full["work_time_real_stats"].split()
                if not token.startswith(field + "="))
            with self.subTest(field=field):
                self.assert_unavailable(self.summary([broken], True))

    def test_malformed_and_noninteger_counters_are_unavailable(self):
        for field in (PARENTS, OUTPUTS, EXPANDED, REPLAYED):
            for value in ("-1", "0.5", "bad", "1tail", "truebad", "NaN",
                          "Infinity", "1e9999", "", "1=2"):
                full = row(1, 16, replayed=16)
                full["work_time_real_stats"] = " ".join(
                    field + "=" + value if token.startswith(field + "=") else token
                    for token in full["work_time_real_stats"].split())
                with self.subTest(field=field, value=value):
                    self.assert_unavailable(self.summary([full], True))

    def test_duplicate_fields_are_unavailable(self):
        for whitespace in (" ", "\t", "\n"):
            for field in (PARENTS, OUTPUTS, EXPANDED, REPLAYED):
                full = row(1, 16, replayed=16)
                full["work_time_real_stats"] += whitespace + field + "=0"
                with self.subTest(whitespace=whitespace, field=field):
                    self.assert_unavailable(self.summary([full], True))

    def test_nonstring_telemetry_is_unavailable(self):
        for value in (None, False, True, 1, [], {}):
            with self.subTest(value=value):
                self.assert_unavailable(self.summary([{"work_time_real_stats": value}]))

    def test_exclusivity_and_parent_bounds_reconcile_per_candidate(self):
        for rows, reason in (
            ([row(1, 1, 1)], "representation_exclusive"),
            ([row(0, 1)], "rooted_output_bounds"),
            ([row(1, 0)], "rooted_output_bounds"),
            ([row(1, 17), row(1, 15)], "rooted_output_bounds"),
            ([row(2, 1), row(0, 1)], "rooted_output_bounds"),
        ):
            with self.subTest(rows=rows):
                result = self.summary(rows)
                self.assertTrue(result["capture_complete"])
                self.assertFalse(result["reconciliation"]["valid"])
                self.assertFalse(result["reconciliation"][reason])
                self.assertTrue(all(value is None for value in result["totals"].values()))
                self.assertTrue(all(value is not None for value in result["raw_totals"].values()))

    def test_validation_replay_reconciles_per_candidate(self):
        result = self.summary([row(1, 16, replayed=15),
                               row(expanded=16, replayed=17)], True)
        self.assertTrue(result["capture_complete"])
        self.assertFalse(result["reconciliation"]["valid"])
        self.assertFalse(result["reconciliation"]["replay_complete"])
        self.assertTrue(all(value is None for value in result["totals"].values()))
        self.assertEqual(result["raw_totals"][REPLAYED], 32)


if __name__ == "__main__":
    unittest.main()
