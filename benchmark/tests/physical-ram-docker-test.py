#!/usr/bin/env python3
"""Offline launcher safety/ownership tests; never mount or contact a daemon."""
import argparse
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

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
        self.launcher.cleanup_on_error = False
        self.launcher.lock_fd = None
        self.launcher.config = {"network_prefix": "10.203.1"}
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
            "networks": {"main": {}},
            "deploy": {"resources": {"limits": {"memory": "1024"}}},
            "volumes": [{"type": "volume", "source": "db", "target": "/data"}]}
            for name in MODULE.SERVICES}}
        data["networks"] = {"main": {"driver": "bridge", "ipam": {"config": [{"subnet": "10.203.1.0/24"}]},
                                      "driver_opts": {"com.docker.network.bridge.name": "tonram1"}}}
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

    def test_compose_cannot_escape_the_checked_network(self):
        for mutation in ("subnet", "bridge", "external", "host", "extra_network"):
            with self.subTest(mutation=mutation):
                config = self.config()
                main = config["networks"]["main"]
                if mutation == "subnet":
                    main["ipam"]["config"] = [{"subnet": "172.28.1.0/24"}]
                elif mutation == "bridge":
                    main["driver_opts"]["com.docker.network.bridge.name"] = "br-existing"
                elif mutation == "external":
                    main["external"] = True
                elif mutation == "host":
                    config["services"]["genesis"]["network_mode"] = "host"
                else:
                    config["services"]["genesis"]["networks"]["other"] = {}
                with self.assertRaisesRegex(MODULE.LauncherError, "network"):
                    self.resolve_config(config)

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

    def simulate_bootstrap(self, ready_after=620, bootstrap=5400, stopped=False,
                           guard_trip_at=None, stats_running=True, restart_after_stats=False):
        self.launcher.env_file.write_text(f"NATIVE_RAM_BOOTSTRAP_TIMEOUT_SECONDS={bootstrap}\n")
        self.startup_clock = 0
        self.startup_commands = []
        self.startup_guard_samples = []

        def advance(seconds):
            self.startup_clock += seconds

        def guard():
            self.startup_guard_samples.append(self.startup_clock)
            if guard_trip_at is not None and self.startup_clock >= guard_trip_at:
                raise MODULE.LauncherError("RAM resource guard tripped")

        def inspect(service):
            if service == "session-stats":
                self.assertGreaterEqual(self.startup_clock, ready_after)
                return {"State": {"Running": stats_running}}
            self.assertEqual(service, "genesis")
            health = "healthy" if self.startup_clock >= ready_after else "unhealthy"
            started = "fixture-restarted" if restart_after_stats and len(self.startup_commands) == 2 else "fixture-start"
            return {"Id": "a" * 64, "State": {"Running": not stopped, "OOMKilled": False,
                    "StartedAt": started, "Health": {"Status": health}}}

        def monitored(argv, log_name, timeout):
            self.startup_commands.append((argv, log_name, timeout, self.startup_clock))

        with patch.object(MODULE.time, "monotonic", side_effect=lambda: self.startup_clock), \
                patch.object(MODULE.time, "sleep", side_effect=advance), \
                patch.object(self.launcher, "guard_check", side_effect=guard), \
                patch.object(self.launcher, "monitored", side_effect=monitored), \
                patch.object(self.launcher, "inspect_service", side_effect=inspect), \
                patch.object(self.launcher, "save_state"), patch("sys.stdout", new_callable=io.StringIO):
            self.launcher.start_services()

    def test_slow_genesis_gets_bootstrap_budget_before_stats_starts(self):
        # Simulated unhealthy genesis takes over ten minutes, exceeding the old
        # combined Compose deadline without any real sleeps or Docker calls.
        self.simulate_bootstrap(ready_after=620)
        self.assertEqual(len(self.startup_commands), 2)
        first, second = self.startup_commands
        self.assertEqual(first[1:], ("start-genesis.log", 300, 0))
        self.assertEqual(second[1:], ("start-session-stats.log", 300, 620))
        for command, service in ((first[0], "genesis"), (second[0], "session-stats")):
            up = command[command.index("up"):]
            self.assertEqual(up, ["up", "-d", "--no-deps", "--no-build", "--pull", "never", service])
        self.assertGreater(len(self.startup_guard_samples), 100)
        self.assertEqual(self.launcher.state["genesis_id"], "a" * 64)
        self.assertEqual(self.launcher.state["genesis_started_at"], "fixture-start")

    def test_failed_or_guarded_bootstrap_never_starts_stats(self):
        for options, error in (({"bootstrap": 60}, "within 60 seconds"),
                               ({"stopped": True}, "genesis stopped"),
                               ({"guard_trip_at": 150}, "guard tripped")):
            with self.subTest(options=options):
                with self.assertRaisesRegex(MODULE.LauncherError, error):
                    self.simulate_bootstrap(**options)
                self.assertEqual(len(self.startup_commands), 1)
                self.assertEqual(self.launcher.state["phase"], "bootstrapping")

    def test_stats_must_be_running_before_startup_can_complete(self):
        with self.assertRaisesRegex(MODULE.LauncherError, "session-stats stopped"):
            self.simulate_bootstrap(ready_after=0, stats_running=False)
        self.assertEqual(self.launcher.state["phase"], "starting_session_stats")

    def test_genesis_restart_during_stats_startup_cannot_be_declared_ready(self):
        with self.assertRaisesRegex(MODULE.LauncherError, "changed while starting session-stats"):
            self.simulate_bootstrap(ready_after=0, restart_after_stats=True)
        self.assertEqual(self.launcher.state["phase"], "starting_session_stats")

    def test_invalid_bootstrap_budget_rejected_before_service_creation(self):
        with self.assertRaisesRegex(MODULE.LauncherError, "60..10800"):
            self.simulate_bootstrap(bootstrap=0)
        self.assertEqual(self.startup_commands, [])

    def write_existing_state(self, phase):
        self.launcher.state_path = self.root / "owner.json"
        self.launcher.state.update(schema="native-physical-ram-owner-v1", root=str(self.root),
                                   phase=phase, env_sha256="original-profile",
                                   harness_sha256={"benchmark/physical-ram-docker.py": "old-harness"})
        self.launcher.config["env_sha256"] = "updated-profile"
        self.launcher.state_path.write_text(json.dumps(self.launcher.state))

    def test_inactive_phase_precedes_changed_profile_and_missing_daemon(self):
        for phase in ("mounted", "starting_genesis", "bootstrapping", "starting_session_stats",
                      "failed_stopped", "failed_cleanup_incomplete", "stopped"):
            self.write_existing_state(phase)
            with self.subTest(phase=phase), patch.object(MODULE.os, "geteuid", return_value=0), \
                    patch.object(self.launcher, "mount_check"), \
                    patch.object(self.launcher, "verify_daemon") as verify:
                with self.assertRaisesRegex(MODULE.LauncherError, "not ready.*" + phase):
                    self.launcher.run()
                verify.assert_not_called()
                self.assertFalse(self.launcher.cleanup_on_error)

    def test_rejected_run_preserves_existing_state_without_cleanup(self):
        for phase in ("failed_stopped", "ready"):
            self.write_existing_state(phase)
            original = self.launcher.state_path.read_bytes()
            self.launcher.output = self.root / (phase + "-attempt")
            self.launcher.output.mkdir()
            with self.subTest(phase=phase), patch.object(MODULE, "Launcher", return_value=self.launcher), \
                    patch.object(MODULE.os, "geteuid", return_value=0), \
                    patch.object(self.launcher, "mount_check"), patch.object(self.launcher, "lock"), \
                    patch.object(self.launcher, "prepare_output"), \
                    patch.object(self.launcher, "failure_cleanup") as cleanup, \
                    patch.object(self.launcher, "verify_daemon") as verify, \
                    patch("sys.stdout", new_callable=io.StringIO), patch("sys.stderr", new_callable=io.StringIO):
                self.assertEqual(MODULE.main(["run", "--output", str(self.launcher.output)]), 2)
                cleanup.assert_not_called()
                verify.assert_not_called()
            self.assertEqual(self.launcher.state_path.read_bytes(), original)
            failure = json.loads((self.launcher.output / "failure.json").read_text())
            self.assertEqual(failure["phase"], phase)
            expected = "not ready" if phase == "failed_stopped" else "environment changed"
            self.assertIn(expected, failure["error"])

    def test_command_timeout_reports_log_and_recent_output(self):
        (self.root / "logs").mkdir()
        clock = [0]
        child = Mock(pid=123)
        child.poll.return_value = None

        def spawn(*args, **kwargs):
            kwargs["stdout"].write(b"fixture service is waiting\n")
            return child

        def advance(seconds):
            clock[0] += seconds

        with patch.object(MODULE.time, "monotonic", side_effect=lambda: clock[0]), \
                patch.object(MODULE.time, "sleep", side_effect=advance), \
                patch.object(MODULE.subprocess, "Popen", side_effect=spawn), \
                patch.object(MODULE.os, "killpg") as kill, \
                patch.object(self.launcher, "guard_check"), \
                patch("sys.stdout", new_callable=io.StringIO), patch("sys.stderr", new_callable=io.StringIO) as stderr:
            with self.assertRaisesRegex(MODULE.LauncherError, "start-genesis.log timed out after 3 seconds"):
                self.launcher.monitored(["never-execute"], "start-genesis.log", 3)
            kill.assert_called_once_with(123, MODULE.signal.SIGTERM)
            self.assertIn("fixture service is waiting", stderr.getvalue())
            self.assertIn(str(self.root / "logs/start-genesis.log"), stderr.getvalue())

    def test_started_work_still_triggers_failure_cleanup(self):
        self.launcher.output = self.root / "active-attempt"
        self.launcher.output.mkdir()
        self.launcher.state["phase"] = "bootstrapping"

        def fail_after_starting_work():
            self.launcher.cleanup_on_error = True
            raise MODULE.LauncherError("genesis did not become healthy")

        with patch.object(MODULE, "Launcher", return_value=self.launcher), \
                patch.object(self.launcher, "lock"), patch.object(self.launcher, "prepare_output"), \
                patch.object(self.launcher, "start", side_effect=fail_after_starting_work), \
                patch.object(self.launcher, "failure_cleanup") as cleanup, \
                patch("sys.stdout", new_callable=io.StringIO), patch("sys.stderr", new_callable=io.StringIO):
            self.assertEqual(MODULE.main(["start", "--output", str(self.launcher.output)]), 2)
            cleanup.assert_called_once()
        failure = json.loads((self.launcher.output / "failure.json").read_text())
        self.assertEqual(failure["phase"], "bootstrapping")

    def test_failure_log_tail_is_bounded(self):
        path = self.root / "large.log"
        path.write_text("x" * 100000 + "\n" + "\n".join(f"line {n}" for n in range(50)))
        tail = MODULE.recent_log(path)
        self.assertEqual(tail.splitlines(), [f"line {n}" for n in range(30, 50)])

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
        self.launcher.state["firewall"] = {"owned": "fixture"}
        with patch.object(MODULE, "process_owned", return_value=False), \
                patch.object(MODULE, "socket_live", return_value=True), \
                patch.object(MODULE.FIREWALL_MODULE, "remove") as firewall_remove, \
                patch.object(MODULE, "command") as run, patch.object(MODULE.os, "kill") as kill:
            with self.assertRaises(MODULE.LauncherError):
                self.launcher.stop_processes()
            run.assert_not_called()
            kill.assert_not_called()
            firewall_remove.assert_not_called()

    def test_stopped_private_daemons_allow_owned_firewall_cleanup(self):
        self.launcher.plan = {"paths": {"daemon_config": str(self.root / "daemon.json"),
                                       "socket": str(self.root / "docker.sock")},
                              "containerd_paths": {"config": str(self.root / "containerd.toml"),
                                                   "socket": str(self.root / "containerd.sock")}}
        self.launcher.state["bridge"] = {"name": "tonram0", "ifindex": 123}
        self.launcher.state["firewall"] = {"owned": "fixture"}
        with patch.object(MODULE, "process_owned", return_value=False), \
                patch.object(MODULE, "socket_live", return_value=False), \
                patch.object(MODULE.Path, "exists", return_value=False), \
                patch.object(MODULE.FIREWALL_MODULE, "remove") as firewall_remove, \
                patch.object(MODULE, "command") as run, patch.object(MODULE.os, "kill") as kill:
            self.launcher.stop_processes()
            firewall_remove.assert_called_once_with(self.launcher.state["firewall"], persist=self.launcher.save_state)
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
