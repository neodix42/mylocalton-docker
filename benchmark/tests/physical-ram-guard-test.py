#!/usr/bin/env python3
"""Resource/ownership guard tests: no Docker daemon or root privileges needed."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("physical_ram_guard", Path(__file__).resolve().parents[1] / "physical-ram-guard.py")
GUARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)


def container(identifier, service, project="ram-test"):
    return {"Id": identifier, "Config": {"Labels": {"com.docker.compose.project": project,
                                                     "com.docker.compose.service": service}},
            "State": {"Running": True, "ExitCode": 0, "OOMKilled": False}}


class FakeDocker(GUARD.Docker):
    def __init__(self, root):
        super().__init__(f"unix://{root}/docker.sock", "private-daemon", root, "ram-test")
        self.actual_id = self.daemon_id
        self.calls = []
        self.containers = {}

    def command(self, *arguments, timeout=8):
        self.calls.append(arguments)
        if arguments[0] == "info":
            return json.dumps({"ID": self.actual_id, "DockerRootDir": str(self.root / "data")})
        if arguments[0] == "ps":
            return "\n".join(self.containers)
        if arguments[0] == "inspect":
            return json.dumps([self.containers[item] for item in arguments[1:]])
        if arguments[0] == "stop":
            self.containers[arguments[-1]]["State"]["Running"] = False
            return arguments[-1]
        raise AssertionError(arguments)


class PhysicalRamGuardTest(unittest.TestCase):
    def test_consecutive_thresholds_reset_and_emergency_is_immediate(self):
        thresholds = GUARD.Thresholds(32, 16)
        sample = lambda memory, free=20: {"host_mem_available_bytes": memory * GUARD.GIB,
                                        "ram_free_bytes": free * GUARD.GIB}
        self.assertIsNone(thresholds.check(sample(31)))
        self.assertIsNone(thresholds.check(sample(40)))
        self.assertIsNone(thresholds.check(sample(31)))
        self.assertIn("two consecutive", thresholds.check(sample(31)))
        self.assertIn("emergency", GUARD.Thresholds(32, 16).check(sample(7)))
        thresholds = GUARD.Thresholds(32, 16)
        self.assertIsNone(thresholds.check(sample(40, 15)))
        self.assertIn("filesystem free", thresholds.check(sample(40, 15)))

    def test_mount_requires_noswap_exec_and_checks_nested_mount(self):
        with tempfile.TemporaryDirectory() as directory:
            mountinfo = Path(directory) / "mountinfo"
            mountinfo.write_text("1 0 0:1 / / rw - ext4 /dev/root rw\n"
                                 "2 1 0:2 / /ram rw,nodev,nosuid - tmpfs tmpfs rw,noswap\n")
            self.assertEqual(GUARD.ram_mount(Path("/ram/data"), mountinfo)["filesystem"], "tmpfs")
            with mountinfo.open("a") as stream:
                stream.write("3 2 0:3 / /ram/data rw - ext4 /dev/disk rw\n")
            with self.assertRaises(GUARD.MountError):
                GUARD.ram_mount(Path("/ram/data"), mountinfo)
            mountinfo.write_text("2 1 0:2 / /ram rw,noexec - tmpfs tmpfs rw,noswap\n")
            with self.assertRaises(GUARD.MountError):
                GUARD.ram_mount(Path("/ram"), mountinfo)
            mountinfo.write_text("2 1 0:2 / /ram rw - tmpfs tmpfs rw\n")
            with self.assertRaises(GUARD.MountError):
                GUARD.ram_mount(Path("/ram"), mountinfo)

    def test_refuses_default_endpoint_and_wrong_daemon_before_container_queries(self):
        root = Path("/ram")
        with self.assertRaises(GUARD.IdentityError):
            GUARD.Docker("unix:///var/run/docker.sock", "private-daemon", root, "ram-test")
        docker = FakeDocker(root)
        docker.actual_id = "some-other-daemon"
        with self.assertRaises(GUARD.IdentityError):
            docker.stop_owned()
        self.assertEqual([call[0] for call in docker.calls], ["info"])

    def test_stops_only_exact_project_services_in_producer_first_order(self):
        docker = FakeDocker(Path("/ram"))
        for digit, service, project in (("a", "session-stats", "ram-test"),
                                         ("b", "genesis", "ram-test"),
                                         ("c", "native-load-generator", "ram-test"),
                                         ("d", "genesis", "production"),
                                         ("e", "postgres", "ram-test")):
            docker.containers[digit * 64] = container(digit * 64, service, project)
        result = docker.stop_owned()
        stopped = [call[-1] for call in docker.calls if call[0] == "stop"]
        self.assertEqual(stopped, ["c" * 64, "b" * 64, "a" * 64])
        self.assertTrue(all(item["stopped"] for item in result))
        self.assertTrue(docker.containers["d" * 64]["State"]["Running"])
        self.assertTrue(docker.containers["e" * 64]["State"]["Running"])
        self.assertEqual(sum(call[0] == "info" for call in docker.calls), 4)

    def test_rechecks_ownership_after_capture_before_stop(self):
        docker = FakeDocker(Path("/ram"))
        identifier = "a" * 64
        docker.containers[identifier] = container(identifier, "genesis")
        original_inspect = docker.inspect
        calls = 0

        def changed_owner(*identifiers):
            nonlocal calls
            calls += 1
            if calls == 2:
                docker.containers[identifier]["Config"]["Labels"]["com.docker.compose.project"] = "production"
            return original_inspect(*identifiers)

        with patch.object(docker, "inspect", changed_owner):
            result = docker.stop_owned()
        self.assertIn("ownership changed", result[0]["error"])
        self.assertFalse(any(call[0] == "stop" for call in docker.calls))

    def test_trip_marker_exists_before_stops_and_incomplete_stop_is_recorded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            docker = FakeDocker(root)
            sample = {"host_mem_available_bytes": 7 * GUARD.GIB, "ram_free_bytes": 100 * GUARD.GIB}

            def failing_stop():
                self.assertTrue((root / "guard-tripped.json").exists())
                raise GUARD.IdentityError("daemon identity changed")

            with patch.object(GUARD, "ram_mount", return_value={}), patch.object(GUARD, "collect", return_value=sample), \
                    patch.object(docker, "stop_owned", failing_stop):
                self.assertEqual(GUARD.monitor(root, docker, 32, 16, 0.001), 1)
            finished = json.loads((root / "guard-finished.json").read_text())
            self.assertTrue(finished["tripped"])
            self.assertIn("identity changed", finished["cleanup_error"])
            self.assertFalse((root / "guard-ready.json").exists())

    def test_healthy_ready_then_marker_stops_guard_without_stopping_containers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            docker = FakeDocker(root)
            calls = 0

            def sample(*_arguments):
                nonlocal calls
                calls += 1
                if calls == 2:
                    self.assertTrue((root / "guard-ready.json").exists())
                    (root / "guard.stop").touch()
                return {"host_mem_available_bytes": 40 * GUARD.GIB, "ram_free_bytes": 100 * GUARD.GIB}

            with patch.object(GUARD, "ram_mount", return_value={}), patch.object(GUARD, "collect", side_effect=sample):
                self.assertEqual(GUARD.monitor(root, docker, 32, 16, 0.001), 0)
            finished = json.loads((root / "guard-finished.json").read_text())
            self.assertFalse(finished["tripped"])
            self.assertTrue(finished["stop_marker"])
            self.assertFalse((root / "guard-tripped.json").exists())
            self.assertFalse(any(call[0] == "stop" for call in docker.calls))

    def test_repeated_monitoring_errors_trip_even_when_no_memory_sample_available(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            docker = FakeDocker(root)
            with patch.object(GUARD, "ram_mount", return_value={}), \
                    patch.object(GUARD, "collect", side_effect=GUARD.GuardError("private Docker timeout")):
                self.assertEqual(GUARD.monitor(root, docker, 32, 16, 0.001), 1)
            trip = json.loads((root / "guard-tripped.json").read_text())
            self.assertEqual(trip["last_sample"]["consecutive_errors"], 2)
            self.assertIn("monitoring failed", trip["reason"])


if __name__ == "__main__":
    unittest.main()
