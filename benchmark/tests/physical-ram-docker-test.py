#!/usr/bin/env python3
"""Offline launcher safety/ownership tests; never mount or contact a daemon."""
import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[1] / "physical-ram-docker.py"
SPEC = importlib.util.spec_from_file_location("ram_launcher", PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.launcher = MODULE.Launcher.__new__(MODULE.Launcher)
        self.launcher.root = self.root
        self.launcher.env = {}
        self.launcher.env_file = self.root / "profile.env"
        self.launcher.env_file.write_text("COMPOSE_PROJECT_NAME=mylocalton-desktop\nNATIVE_RAM_ENABLED=1\n")
        self.launcher.state = {"project": "mylocalton-desktop", "images": {
            service: {"id": "sha256:" + "b" * 64, "reference": "fixture:" + service}
            for service in MODULE.SERVICES}}

    def service(self, service="genesis"):
        return {"Id": "a" * 64, "Image": "sha256:" + "b" * 64,
                "Config": {"Labels": {"com.docker.compose.project": "mylocalton-desktop",
                                       "com.docker.compose.service": service}},
                "State": {"Running": False}, "HostConfig": {"Memory": 1024, "MemorySwap": 1024},
                "Mounts": [{"Source": str(self.root / "data/volumes/db/_data")}]}

    def config(self):
        data = {"volumes": {"db": {}}, "services": {name: {
            "environment": {"NATIVE_RAM_ENABLED": "1"}, "memswap_limit": "1024",
            "deploy": {"resources": {"limits": {"memory": "1024"}}},
            "volumes": [{"type": "volume", "source": "db", "target": "/data"}]}
            for name in MODULE.SERVICES}}
        data["services"]["session-stats"]["volumes"].extend([
            {"type": "bind", "source": str(self.root), "target": "/hostfs", "read_only": True},
            {"type": "bind", "source": str(self.root / "data/volumes"),
             "target": "/docker-volumes", "read_only": True}])
        return data

    def resolve_config(self, value):
        with patch.object(self.launcher, "compose", return_value=["never-execute"]), \
                patch.object(MODULE, "command", return_value=json.dumps(value)):
            return self.launcher.service_config()

    def test_private_selectors_and_client_metadata(self):
        injected = {key: "wrong" for key in ("DOCKER_CONTEXT", "DOCKER_HOST", "DOCKER_TLS_VERIFY",
            "DOCKER_CERT_PATH", "DOCKER_CONFIG", "DOCKER_DEFAULT_PLATFORM", "COMPOSE_FILE",
            "COMPOSE_PROJECT_NAME", "BUILDX_BUILDER", "BUILDKIT_HOST", "BENCHMARK_IMAGES_PREBUILT")}
        with patch.dict(os.environ, injected, clear=True):
            actual = MODULE.private_environment("unix:///ram/docker.sock", "/ram/tmp", "expected")
        self.assertEqual(actual["DOCKER_HOST"], "unix:///ram/docker.sock")
        self.assertEqual(actual["DOCKER_CONFIG"], "/ram/client")
        self.assertEqual(actual["COMPOSE_PROJECT_NAME"], "expected")
        self.assertEqual(actual["TMPDIR"], "/ram/tmp")
        for name in injected.keys() - {"DOCKER_HOST", "DOCKER_CONFIG", "COMPOSE_PROJECT_NAME"}:
            self.assertNotIn(name, actual)

    def test_profile_project_and_no_shell_evaluation(self):
        self.assertEqual(MODULE.profile_literal(self.launcher.env_file, "COMPOSE_PROJECT_NAME"), "mylocalton-desktop")
        self.launcher.env_file.write_text("COMPOSE_PROJECT_NAME=$(touch /never)\n")
        with self.assertRaises(MODULE.LauncherError):
            MODULE.profile_literal(self.launcher.env_file, "COMPOSE_PROJECT_NAME")

    def test_profile_overrides_removed(self):
        self.launcher.env = {"NATIVE_RAM_ENABLED": "0", "COMPOSE_PROJECT_NAME": "mylocalton-desktop", "PATH": "/bin"}
        self.launcher.reject_profile_overrides()
        self.assertNotIn("NATIVE_RAM_ENABLED", self.launcher.env)
        self.assertEqual(self.launcher.env["COMPOSE_PROJECT_NAME"], "mylocalton-desktop")

    def test_expected_named_and_read_only_ram_mounts_accepted(self):
        self.resolve_config(self.config())

    def test_reject_redirected_storage(self):
        for mutation in ("external", "driver", "host_root", "writable", "wrong_target", "wrong_service"):
            with self.subTest(mutation=mutation):
                config = self.config()
                if mutation == "external":
                    config["volumes"]["db"]["external"] = True
                elif mutation == "driver":
                    config["volumes"]["db"]["driver_opts"] = {"device": "/disk"}
                else:
                    bind = config["services"]["session-stats"]["volumes"][1]
                    if mutation == "host_root":
                        bind["source"] = "/"
                    elif mutation == "writable":
                        bind["read_only"] = False
                    elif mutation == "wrong_target":
                        bind["target"] = "/different"
                    else:
                        config["services"]["genesis"]["volumes"].append(bind)
                with self.assertRaises(MODULE.LauncherError):
                    self.resolve_config(config)

    def test_heap_swap_rejected_before_start(self):
        for limit in ("0", "2048", "-1"):
            config = self.config()
            config["services"]["native-load-generator"]["memswap_limit"] = limit
            with self.assertRaises(MODULE.LauncherError):
                self.resolve_config(config)

    def test_runtime_identity_storage_swap_verification(self):
        good = self.service()
        with patch.object(self.launcher, "docker", return_value=json.dumps([good])):
            self.assertEqual(self.launcher.inspect_service("genesis")["Id"], good["Id"])
        for mutation in ("project", "service", "image", "swap", "mount"):
            bad = copy.deepcopy(good)
            if mutation in ("project", "service"):
                bad["Config"]["Labels"]["com.docker.compose." + mutation] = "unrelated"
            elif mutation == "image":
                bad["Image"] = "sha256:" + "c" * 64
            elif mutation == "swap":
                bad["HostConfig"]["MemorySwap"] = 2048
            else:
                bad["Mounts"][0]["Source"] = "/disk/database"
            with self.subTest(mutation=mutation), patch.object(self.launcher, "docker", return_value=json.dumps([bad])):
                with self.assertRaises(MODULE.LauncherError):
                    self.launcher.inspect_service("genesis")

    def test_process_reuse_cannot_signal_replacement(self):
        receipt = {"pid": 123, "start_ticks": "100"}
        with patch.object(MODULE, "process_identity", return_value={"pid": 123, "start_ticks": "101", "cmdline": [b"/ram/daemon.json"]}):
            self.assertFalse(MODULE.process_owned(receipt, "/ram/daemon.json"))
        with patch.object(MODULE, "process_identity", return_value={"pid": 123, "start_ticks": "100", "cmdline": [b"/unrelated/daemon.json"]}):
            self.assertFalse(MODULE.process_owned(receipt, "/ram/daemon.json"))

    def test_failed_preflight_never_mounts_or_starts(self):
        with patch.object(MODULE.os, "geteuid", return_value=0), \
                patch.object(self.launcher, "preflight", side_effect=MODULE.LauncherError("insufficient RAM")), \
                patch.object(MODULE, "command") as run, patch.object(MODULE.subprocess, "Popen") as spawn:
            with self.assertRaises(MODULE.LauncherError):
                self.launcher.start()
            run.assert_not_called()
            spawn.assert_not_called()

    def test_low_ram_guard_blocks_new_work(self):
        (self.root / "guard-tripped.json").write_text("{}")
        with self.assertRaises(MODULE.LauncherError):
            self.launcher.guard_check()

    def test_removal_never_removes_volumes(self):
        (self.root / "receipts").mkdir()
        container = self.service()
        network = {"Id": "c" * 64, "Labels": {"com.docker.compose.project": "mylocalton-desktop"}, "Containers": {}}
        calls = []

        def docker(*args, **kwargs):
            calls.append(args)
            if args[0] == "ps":
                return container["Id"]
            if args[0] == "inspect":
                return json.dumps([container])
            if args[:2] == ("network", "ls"):
                return network["Id"]
            if args[:2] == ("network", "inspect"):
                return json.dumps([network])
            return ""

        with patch.object(self.launcher, "docker", side_effect=docker):
            self.launcher.remove_owned_containers_and_networks()
        self.assertIn(("rm", container["Id"]), calls)
        self.assertIn(("network", "rm", network["Id"]), calls)
        self.assertFalse(any("volume" in call or "-v" in call for call in calls))

    def test_live_replacement_daemon_prevents_bridge_removal(self):
        self.launcher.plan = {"paths": {"daemon_config": str(self.root / "daemon.json"),
                                       "socket": str(self.root / "docker.sock")},
                              "containerd_paths": {"config": str(self.root / "containerd.toml"),
                                                   "socket": str(self.root / "containerd.sock")}}
        self.launcher.state["bridge"] = {"name": "tonram0", "ifindex": 123}
        with patch.object(MODULE, "process_owned", return_value=False), \
                patch.object(MODULE, "socket_live", return_value=True), \
                patch.object(MODULE, "command") as run, patch.object(MODULE.os, "kill") as kill:
            with self.assertRaises(MODULE.LauncherError):
                self.launcher.stop_processes()
            run.assert_not_called()
            kill.assert_not_called()

    def test_failed_work_stops_daemons_even_if_container_cleanup_fails(self):
        self.launcher.output = self.root / "persistent-output-fixture"
        self.launcher.output.mkdir()
        self.launcher.state["daemon_id"] = "owned"
        with patch.object(self.launcher, "verify_daemon", side_effect=MODULE.LauncherError("daemon API unavailable")), \
                patch.object(self.launcher, "stop_processes") as stop, \
                patch.object(self.launcher, "save_state"), patch.object(self.launcher, "export") as export:
            self.launcher.failure_cleanup()
        stop.assert_called_once()
        export.assert_called_once()
        self.assertEqual(self.launcher.state["phase"], "failed_cleanup_incomplete")


if __name__ == "__main__":
    unittest.main()
