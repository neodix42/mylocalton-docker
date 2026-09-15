#!/usr/bin/env python3
"""Offline mount-holder diagnostics; never mount or signal anything."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest


PATH = Path(__file__).resolve().parents[1] / "physical-ram-mount.py"
SPEC = importlib.util.spec_from_file_location("physical_ram_mount", PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MountDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "ram"
        self.root.mkdir()
        self.proc = self.base / "proc"
        (self.proc / "self").mkdir(parents=True)

    def mounts(self, *extra):
        rows = [f"31 20 0:77 / {self.root} rw,nosuid - tmpfs tmpfs rw,noswap"]
        rows.extend(extra)
        (self.proc / "self/mountinfo").write_text("\n".join(rows) + "\n")

    def process(self, pid, *, cwd="/", root="/", exe="/usr/bin/fixture", fds=(), maps=()):
        path = self.proc / str(pid)
        (path / "fd").mkdir(parents=True)
        # Fields after comm: state plus fields 4..22; index 19 is starttime.
        tail = ["S"] + ["0"] * 18 + [str(pid * 10)]
        (path / "stat").write_text(f"{pid} (fixture worker) " + " ".join(tail) + "\n")
        (path / "comm").write_text("fixture worker\n")
        os.symlink(cwd, path / "cwd")
        os.symlink(root, path / "root")
        os.symlink(exe, path / "exe")
        for number, target in enumerate(fds, 3):
            os.symlink(target, path / "fd" / str(number))
        (path / "maps").write_text("\n".join(
            f"1000-2000 r--p 00000000 00:77 1 {target}" for target in maps) + "\n")

    def test_clean_mount_is_ready(self):
        self.mounts()
        report = MODULE.inspect_mount(self.root, self.proc)
        self.assertTrue(report["mounted"])
        self.assertTrue(report["unmount_ready"])
        self.assertEqual(report["holders"], [])

    def test_reports_cwd_deleted_fd_and_mapping_without_command_line(self):
        self.mounts()
        self.process(42, cwd=str(self.root / "logs"),
                     fds=[str(self.root / "removed.log") + " (deleted)"],
                     maps=[str(self.root / "libfixture.so")])
        report = MODULE.inspect_mount(self.root, self.proc)
        self.assertFalse(report["unmount_ready"])
        holder = report["holders"][0]
        self.assertEqual((holder["pid"], holder["start_ticks"], holder["name"]),
                         (42, "420", "fixture worker"))
        self.assertEqual({item["type"] for item in holder["references"]},
                         {"cwd", "fd", "mmap"})
        self.assertNotIn("cmdline", json.dumps(holder))
        self.assertTrue(next(item for item in holder["references"]
                             if item["type"] == "fd")["deleted"])

    def test_nested_and_stacked_mounts_block_readiness(self):
        escaped = str(self.root).replace(" ", "\\040")
        self.mounts(f"32 31 0:78 / {escaped}/data/mount rw - ext4 /dev/fixture rw",
                    f"33 20 0:79 / {escaped} rw - tmpfs other rw,noswap")
        report = MODULE.inspect_mount(self.root, self.proc)
        self.assertFalse(report["unmount_ready"])
        self.assertEqual(len(report["stacked_root_mounts"]), 1)
        self.assertEqual(report["nested_mounts"][0]["mountpoint"], str(self.root / "data/mount"))

    def test_unmounted_root_is_already_ready(self):
        (self.proc / "self/mountinfo").write_text("1 0 0:1 / / rw - ext4 /dev/root rw\n")
        report = MODULE.inspect_mount(self.root, self.proc)
        self.assertFalse(report["mounted"])
        self.assertTrue(report["unmount_ready"])

    def test_incomplete_mountinfo_never_claims_readiness(self):
        (self.proc / "self/mountinfo").write_text("malformed\n")
        report = MODULE.inspect_mount(self.root, self.proc)
        self.assertFalse(report["diagnostics_complete"])
        self.assertFalse(report["unmount_ready"])

    def test_rejects_root_and_symlink(self):
        with self.assertRaises(ValueError):
            MODULE.inspect_mount("/", self.proc)
        link = self.base / "link"
        link.symlink_to(self.root)
        with self.assertRaises(ValueError):
            MODULE.inspect_mount(link, self.proc)


if __name__ == "__main__":
    unittest.main()
