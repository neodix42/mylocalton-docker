#!/usr/bin/env python3
"""Extract complete native-load-v2 JSON records from a merged Docker log.

Docker keeps stdout and stderr as separate streams, then ``docker logs`` merges
them.  A large stdout write can therefore be split around a complete stderr
record.  The native generator writes its final JSON record to stdout and its
clean-shutdown message to stderr, so that shutdown line can appear in the
middle of an otherwise valid JSON string.

This extractor removes only complete ANSI-framed TON logger records.  It then
emits a source line only after a strict, complete JSON parse and an exact
``native-load-v2`` schema check.  It never supplies missing JSON delimiters or
keeps partial objects.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from pathlib import Path
from typing import Any


SCHEMA = "native-load-record-extraction-v1"
NATIVE_LOAD_SCHEMA = "native-load-v2"
NATIVE_CANDIDATE_PREFIX = b'{"schema":"native-load'

# A native logger record has five bracketed fields (severity, thread,
# timestamp, source location, actor), a tab-delimited message, and an ANSI
# reset.  Requiring the complete envelope prevents a partial or unrelated line
# from being deleted to make malformed JSON look valid.
ANSI_TON_LOG_RECORD = re.compile(
    rb"\x1b\[[0-9;]+m"
    rb"(?:\[[^\]\r\n]*\]){5}"
    rb"\t[^\r\n]*?"
    rb"\x1b\[0m(?:\r?\n)?"
)


class DuplicateKeyError(ValueError):
    pass


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKeyError(f"duplicate object key: {key}")
        result[key] = value
    return result


def _reject_non_finite(value: str) -> None:
    raise ValueError(f"non-finite JSON number: {value}")


def _strict_json_loads(record: bytes) -> Any:
    return json.loads(
        record,
        object_pairs_hook=_unique_object,
        parse_constant=_reject_non_finite,
    )


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_bytes(data)
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def extract(raw: bytes, raw_name: str, records_name: str) -> tuple[bytes, dict[str, Any]]:
    logger_matches = list(ANSI_TON_LOG_RECORD.finditer(raw))
    removed_logger_records: list[dict[str, Any]] = []
    for match in logger_matches:
        physical_line_start = raw.rfind(b"\n", 0, match.start()) + 1
        logger_record = match.group()
        removed_logger_records.append(
            {
                "raw_byte_offset": match.start(),
                "raw_physical_line": raw.count(b"\n", 0, match.start()) + 1,
                "byte_offset_in_physical_line": match.start() - physical_line_start,
                "bytes": len(logger_record),
                "sha256": _sha256(logger_record),
                "interleaved": match.start() != physical_line_start,
            }
        )

    cleaned = ANSI_TON_LOG_RECORD.sub(b"", raw)
    records: list[bytes] = []
    rejected: list[dict[str, Any]] = []
    ignored_nonempty_lines = 0
    final_records = 0

    for line_number, line in enumerate(cleaned.splitlines(), start=1):
        candidate = line.strip()
        if not candidate:
            continue
        try:
            value = _strict_json_loads(candidate)
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
            if candidate.startswith(NATIVE_CANDIDATE_PREFIX):
                rejected.append(
                    {
                        "sanitized_line": line_number,
                        "error_type": type(error).__name__,
                        "error": str(error),
                    }
                )
            else:
                ignored_nonempty_lines += 1
            continue

        if not isinstance(value, dict) or value.get("schema") != NATIVE_LOAD_SCHEMA:
            ignored_nonempty_lines += 1
            continue

        records.append(candidate + b"\n")
        if value.get("final") is True:
            final_records += 1

    records_data = b"".join(records)
    invalid_reasons: list[str] = []
    if not records:
        invalid_reasons.append("no_complete_native_load_records")
    if rejected:
        invalid_reasons.append("incomplete_or_malformed_native_load_candidate")
    if final_records == 0:
        invalid_reasons.append("missing_final_native_load_record")
    elif final_records > 1:
        invalid_reasons.append("multiple_final_native_load_records")

    report: dict[str, Any] = {
        "schema": SCHEMA,
        "raw_artifact": raw_name,
        "records_artifact": records_name,
        "raw_sha256": _sha256(raw),
        "records_sha256": _sha256(records_data),
        "raw_bytes": len(raw),
        "records_bytes": len(records_data),
        "raw_physical_lines": len(raw.splitlines()),
        "sanitized_physical_lines": len(cleaned.splitlines()),
        "complete_records": len(records),
        "final_records": final_records,
        "rejected_candidate_records": len(rejected),
        "rejected_candidates": rejected,
        "ignored_nonempty_lines": ignored_nonempty_lines,
        "ansi_log_records_removed": len(logger_matches),
        "interleaved_ansi_log_records_removed": sum(
            record["interleaved"] for record in removed_logger_records
        ),
        "ansi_log_bytes_removed": len(raw) - len(cleaned),
        "removed_ansi_log_records": removed_logger_records,
        "valid": not invalid_reasons,
        "invalid_reasons": invalid_reasons,
        "semantics": (
            "raw Docker stdout/stderr remains unchanged; the records artifact contains only "
            "source bytes that passed a complete strict JSON parse and exact native-load-v2 "
            "schema check after deleting complete ANSI-framed TON logger records; no partial "
            "object, delimiter, or field is synthesized"
        ),
    }
    return records_data, report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("raw_log", type=Path)
    parser.add_argument("records_jsonl", type=Path)
    parser.add_argument("report_json", type=Path)
    args = parser.parse_args()

    if args.raw_log.resolve() in {
        args.records_jsonl.resolve(),
        args.report_json.resolve(),
    }:
        parser.error("raw log must remain separate from derived artifacts")
    if args.records_jsonl.resolve() == args.report_json.resolve():
        parser.error("records and report artifacts must be separate")

    raw = args.raw_log.read_bytes()
    records, report = extract(raw, args.raw_log.name, args.records_jsonl.name)
    _atomic_write(args.records_jsonl, records)
    report_data = (json.dumps(report, indent=2, sort_keys=True) + "\n").encode("utf-8")
    _atomic_write(args.report_json, report_data)
    return 0 if report["valid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
