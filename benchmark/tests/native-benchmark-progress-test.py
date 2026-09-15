#!/usr/bin/env python3
"""Exercise wrapper progress and early proof receipts without Docker or load."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


WRAPPER = Path(__file__).resolve().parents[2] / "run-native-benchmark.sh"
SOURCE = WRAPPER.read_text()
HELPERS = SOURCE.split("benchmark_project_name_valid() {", 1)[0]


class NativeBenchmarkProgressTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="native progress ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def shell(self, body, *args):
        return subprocess.run(
            ["bash", "-c", HELPERS + '\nresult_dir=$1\nshift\n' + body,
             "progress-test", str(self.root), *args],
            capture_output=True, text=True, timeout=10,
        )

    def journal(self):
        return [json.loads(line) for line in
                (self.root / "benchmark-progress.jsonl").read_text().splitlines()]

    def test_updates_latest_receipt_and_retains_every_stage(self):
        message = 'long report with "quotes", newline\nand $literal'
        result = self.shell('''
benchmark_progress setup configuration "initial setup"
benchmark_progress generator generator_wait "$1"
benchmark_progress reporting validator_pipeline_report "$1"
''', message)
        self.assertEqual(result.returncode, 0, result.stderr)
        journal = self.journal()
        self.assertEqual([row["phase"] for row in journal],
                         ["setup", "generator", "reporting"])
        self.assertEqual(json.loads((self.root / "benchmark-progress.json").read_text()),
                         journal[-1])
        self.assertEqual(journal[-1]["message"], message)
        self.assertEqual(journal[-1]["schema"], "native-benchmark-progress-v1")
        self.assertIsInstance(journal[-1]["updated_at_epoch_s"], int)
        self.assertTrue(journal[-1]["updated_at"].endswith("Z"))
        self.assertEqual(list(self.root.glob(".benchmark-progress.json.*")), [])
        self.assertIn("reporting/validator_pipeline_report", result.stdout)

    def test_rejects_unknown_group_without_changing_prior_progress(self):
        result = self.shell('''
benchmark_progress generator generator_wait
benchmark_progress typo accidental
''')
        self.assertEqual(result.returncode, 2)
        self.assertEqual(len(self.journal()), 1)
        self.assertEqual(self.journal()[0]["phase"], "generator")

    def test_actual_wait_boundary_switches_to_reporting_before_identity_checks(self):
        start = SOURCE.index('benchmark_progress generator generator_wait ')
        finish = SOURCE.index('strict_image_reuse_valid=null', start)
        segment = SOURCE[start:finish]
        for docker_stdout, docker_status, expected_exit in [("0", "0", 0), ("", "1", 125), ("bad", "0", 125)]:
            with self.subTest(docker_stdout=docker_stdout, docker_status=docker_status):
                for path in self.root.glob("benchmark-progress.json*"):
                    path.unlink()
                result = self.shell('''
generator_cleanup_id=owned-fixture
docker() {
  [[ $1 == wait && $2 == owned-fixture ]]
  printf '%s' "$MOCK_DOCKER_OUTPUT"
  return "$MOCK_DOCKER_STATUS"
}
MOCK_DOCKER_OUTPUT=$1
MOCK_DOCKER_STATUS=$2
''' + segment + '\nprintf "wrapper-exit=%s\\n" "$benchmark_exit_code"\n',
                                    docker_stdout, docker_status)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([r["phase"] for r in self.journal()], ["generator", "reporting"])
                self.assertEqual(self.journal()[-1]["detail"], "generator_exited")
                self.assertIn(f"wrapper-exit={expected_exit}", result.stdout)

    def test_final_receipt_keeps_capacity_failure_and_entire_original_record(self):
        final = {
            "schema": "native-load-v2", "final": True,
            "canonical_chain_measure_avg_tps": 56711.799666110186,
            "canonical_chain_measure_peak_1s_tps": 85104,
            "benchmark_result_valid": True, "chain_capacity_valid": False,
            "chain_capacity_invalid_reasons": ["insufficient_load_over_canonical_throughput"],
            "canonical_lane_balance": {"valid": True, "expected_lanes": 8},
        }
        records = self.root / "records.jsonl"
        records.write_text(json.dumps({"schema": "native-load-v2", "final": False}) +
                           "\n" + json.dumps(final) + "\n")
        result = self.shell('generator_records_file=$1\npreserve_generator_final_record\n', str(records))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.root / "native-load-generator-final.json").read_text()), final)
        self.assertIn("chain capacity valid=false", result.stdout)
        self.assertIn("Validator/resource reports follow", result.stdout)
        self.assertFalse((self.root / "benchmark-summary.json").exists())

    def test_final_receipt_requires_exactly_one_valid_final_record(self):
        final = json.dumps({"schema": "native-load-v2", "final": True})
        for text in ["", '{"schema":"native-load-v2","final":false}\n',
                     final + "\n" + final + "\n", "malformed\n"]:
            with self.subTest(text=text):
                records = self.root / "records.jsonl"
                records.write_text(text)
                result = self.shell('generator_records_file=$1\npreserve_generator_final_record\n', str(records))
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "native-load-generator-final.json").exists())
                self.assertFalse((self.root / "native-load-generator-final.json.tmp").exists())

    def test_phase_boundaries_enclose_start_and_reporting(self):
        # These integration boundaries drive a shared per-group deadline in
        # the RAM launcher; detailed progress must never reset that deadline.
        start = SOURCE.index('benchmark_progress generator generator_start ')
        launch = SOURCE.index('generator_launch_attempted=1', start)
        exited = SOURCE.index('benchmark_progress reporting generator_exited ', launch)
        identity = SOURCE.index('strict_genesis_after=$(capture_genesis_identity', exited)
        capture = SOURCE.index('elif ! preserve_generator_final_record;', identity)
        pipeline = SOURCE.index('benchmark_progress reporting validator_pipeline_report ', capture)
        summary = SOURCE.index('>"$summary_file"', pipeline)
        complete = SOURCE.index('benchmark_progress complete reports_complete ', summary)
        self.assertLess(start, launch)
        self.assertLess(exited, identity)
        self.assertLess(capture, pipeline)
        self.assertLess(summary, complete)
        self.assertNotIn('benchmark_progress complete ', SOURCE[exited:summary])


if __name__ == "__main__":
    unittest.main()
