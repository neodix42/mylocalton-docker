#!/usr/bin/env python3

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "extract-native-load-records.py"
ANSI_SHUTDOWN = (
    b"\x1b[1;33m[ 2][t13][2026-09-13 21:56:26.653105607]"
    b"[native-load-generator.cpp:3039][!native-load-coordinator]\t"
    b"native load generator stopped cleanly\x1b[0m\n"
)
ANSI_STARTUP = (
    b"\x1b[1;33m[ 2][t 5][2026-09-13 21:45:16.526951137]"
    b"[native-load-generator.cpp:2306][!native-load-coordinator]\t"
    b"native load generator ready\x1b[0m\n"
)


class NativeLoadRecordExtractorTest(unittest.TestCase):
    def run_extractor(self, raw: bytes):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            raw_path = root / "native-load-generator.log"
            records_path = root / "native-load-generator-records.jsonl"
            report_path = root / "native-load-generator-records.json"
            raw_path.write_bytes(raw)
            completed = subprocess.run(
                [sys.executable, str(SCRIPT), str(raw_path), str(records_path), str(report_path)],
                check=False,
                capture_output=True,
                text=True,
            )
            return (
                completed,
                raw_path.read_bytes(),
                records_path.read_bytes(),
                json.loads(report_path.read_text()),
            )

    def test_clean_record_is_retained_byte_for_byte(self):
        raw = b'{"schema":"native-load-v2","final":true,"value":17}\n'

        completed, raw_after, records, report = self.run_extractor(raw)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(raw_after, raw)
        self.assertEqual(records, raw)
        self.assertTrue(report["valid"])
        self.assertEqual(report["complete_records"], 1)
        self.assertEqual(report["final_records"], 1)
        self.assertEqual(report["ansi_log_records_removed"], 0)
        self.assertEqual(report["raw_sha256"], hashlib.sha256(raw).hexdigest())
        self.assertEqual(report["records_sha256"], hashlib.sha256(records).hexdigest())

    def test_complete_ansi_log_inside_json_string_is_removed_and_fragments_join(self):
        raw = (
            b'{"schema":"native-load-v2","final":true,"note":"left'
            + ANSI_SHUTDOWN
            + b'right","value":23}\n'
        )
        expected = (
            b'{"schema":"native-load-v2","final":true,'
            b'"note":"leftright","value":23}\n'
        )

        completed, raw_after, records, report = self.run_extractor(raw)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(raw_after, raw)
        self.assertEqual(records, expected)
        self.assertEqual(json.loads(records), json.loads(expected))
        self.assertTrue(report["valid"])
        self.assertEqual(report["complete_records"], 1)
        self.assertEqual(report["final_records"], 1)
        self.assertEqual(report["ansi_log_records_removed"], 1)
        self.assertEqual(report["interleaved_ansi_log_records_removed"], 1)
        self.assertEqual(report["rejected_candidate_records"], 0)
        self.assertEqual(
            report["removed_ansi_log_records"][0]["byte_offset_in_physical_line"],
            raw.index(ANSI_SHUTDOWN),
        )
        self.assertTrue(report["removed_ansi_log_records"][0]["interleaved"])

    def test_unrelated_log_noise_is_ignored(self):
        record = b'{"schema":"native-load-v2","final":true,"value":29}\n'
        raw = (
            b"plain startup noise\n"
            + ANSI_STARTUP
            + b'{"schema":"some-other-record","value":31}\n'
            + record
        )

        completed, raw_after, records, report = self.run_extractor(raw)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(raw_after, raw)
        self.assertEqual(records, record)
        self.assertTrue(report["valid"])
        self.assertEqual(report["complete_records"], 1)
        self.assertEqual(report["ignored_nonempty_lines"], 2)
        self.assertEqual(report["ansi_log_records_removed"], 1)
        self.assertEqual(report["interleaved_ansi_log_records_removed"], 0)

    def test_genuinely_truncated_final_record_remains_invalid(self):
        complete = b'{"schema":"native-load-v2","final":false,"value":37}\n'
        truncated = b'{"schema":"native-load-v2","final":true,"note":"unfinished'
        raw = complete + truncated

        completed, raw_after, records, report = self.run_extractor(raw)

        self.assertEqual(completed.returncode, 1)
        self.assertEqual(raw_after, raw)
        self.assertEqual(records, complete)
        self.assertFalse(report["valid"])
        self.assertEqual(report["complete_records"], 1)
        self.assertEqual(report["final_records"], 0)
        self.assertEqual(report["rejected_candidate_records"], 1)
        self.assertEqual(
            report["invalid_reasons"],
            [
                "incomplete_or_malformed_native_load_candidate",
                "missing_final_native_load_record",
            ],
        )


if __name__ == "__main__":
    unittest.main()
