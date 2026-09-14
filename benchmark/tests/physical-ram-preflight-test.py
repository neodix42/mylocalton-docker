#!/usr/bin/env python3
"""Offline admission tests: fixtures never mount, signal, or start Docker."""
import copy
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import tomllib
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
MODULE = Path(__file__).resolve().parents[1] / "physical-ram-preflight.py"
SPEC = importlib.util.spec_from_file_location("physical_ram_preflight", MODULE)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class PhysicalRamPreflightTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="physical-ram-preflight-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.root = self.directory / "ram"
        self.env = self.directory / ".env.physical"
        self.base = (f"NATIVE_RAM_ROOT={self.root}\n"
                     "NATIVE_RAM_SIZE_GIB=96\nNATIVE_RAM_RUNTIME_GIB=64\n"
                     "NATIVE_RAM_HOST_RESERVE_GIB=32\nNATIVE_RAM_MIN_AVAILABLE_GIB=192\n"
                     "NATIVE_RAM_MIN_FREE_GIB=16\n")
        self.env.write_text(self.base)
        self.config = CHECK.read_config(self.env)
        self.host = {"platform": "linux", "cgroup_v2": True,
                     "ipv4_forwarding": True,
                     "mem_available_bytes": 220 * CHECK.GIB,
                     "benchmark_port_listeners": [], "planned_bridge_exists": False,
                     "ipv4_routes": [{"dst": "default", "dev": "eno1"},
                                     {"dst": "192.0.2.0/24", "dev": "eno1"}]}
        self.host.update({name + "_path": "/usr/bin/" + name
                          for name in ("docker", "dockerd", "containerd", "mount", "findmnt", "ip", "iptables")})
        self.docker = {"os_type": "linux", "operating_system": "Ubuntu 24.04",
                       "cgroup_version": "2", "security_options": ["name=seccomp,profile=builtin"],
                       "networks": [{"name": "bridge", "subnets": ["172.17.0.0/16"]}],
                       "running_containers": [], "benchmark_port_publications": []}

    def errors(self, host=None, docker=None):
        return CHECK.evaluate(self.config, host or self.host, docker or self.docker, {"errors": []})

    def test_256_gib_host_with_220_available_admitted_but_capacity_not_reserved(self):
        self.assertEqual(self.errors(), [])
        self.assertEqual(self.config["required_available_gib"], 192)
        self.assertFalse(self.config["capacity_is_reserved"])

    def test_lower_configured_minimum_cannot_erase_actual_budgets(self):
        self.env.write_text(self.base.replace("MIN_AVAILABLE_GIB=192", "MIN_AVAILABLE_GIB=16"))
        self.assertEqual(CHECK.read_config(self.env)["required_available_gib"], 192)
        self.env.write_text(self.base.replace("MIN_AVAILABLE_GIB=192", "MIN_AVAILABLE_GIB=224"))
        self.assertEqual(CHECK.read_config(self.env)["required_available_gib"], 224)

    def test_available_not_total_ram_decides_and_exact_boundary_is_accepted(self):
        self.host["mem_total_bytes"] = 256 * CHECK.GIB
        for available in (21 * CHECK.GIB, 192 * CHECK.GIB - 1):
            self.host["mem_available_bytes"] = available
            self.assertTrue(any("MemAvailable" in reason for reason in self.errors()))
        self.host["mem_available_bytes"] = 192 * CHECK.GIB
        self.assertEqual(self.errors(), [])

    def test_ram_values_are_literals_and_other_env_lines_are_not_executed(self):
        sentinel = self.directory / "must-not-exist"
        self.env.write_text(self.base + f"OTHER=$(touch {sentinel})\n")
        CHECK.read_config(self.env)
        self.assertFalse(sentinel.exists())
        for value in ("$(touch /tmp/forbidden)", "${HOME}/ram", "`id`", "../ram", "/"):
            self.env.write_text(self.base.replace(str(self.root), value))
            with self.subTest(value=value), self.assertRaises(CHECK.CheckError):
                CHECK.read_config(self.env)

    def test_duplicate_missing_or_invalid_limits_fail(self):
        texts = [self.base + "NATIVE_RAM_SIZE_GIB=96\n",
                 self.base.replace("NATIVE_RAM_RUNTIME_GIB=64\n", ""),
                 self.base.replace("SIZE_GIB=96", "SIZE_GIB=0"),
                 self.base.replace("SIZE_GIB=96", "SIZE_GIB=-1"),
                 self.base.replace("MIN_FREE_GIB=16", "MIN_FREE_GIB=96")]
        for text in texts:
            self.env.write_text(text)
            with self.subTest(text=text), self.assertRaises(CHECK.CheckError):
                CHECK.read_config(self.env)

    def test_symlink_root_or_parent_fails(self):
        target = self.directory / "target"
        target.mkdir()
        self.root.symlink_to(target, target_is_directory=True)
        with self.assertRaisesRegex(CHECK.CheckError, "symlinks"):
            CHECK.read_config(self.env)
        self.env.write_text(self.base.replace(str(self.root), str(self.root / "child")))
        with self.assertRaisesRegex(CHECK.CheckError, "symlinks"):
            CHECK.read_config(self.env)

    def test_unrelated_original_daemon_activity_is_admitted(self):
        self.docker["running_containers"] = [{"id": "a" * 64, "name": "unrelated-service"}]
        self.assertEqual(self.errors(), [])

    def test_configured_ram_networks_drive_bridge_pool_and_admission(self):
        self.env.write_text(self.base + "MLT_NETWORK_PREFIX=10.203.1\n"
                            "NATIVE_RAM_BRIDGE_CIDR=10.203.2.1/24\n"
                            "NATIVE_RAM_ADDRESS_POOL=10.204.0.0/16\n")
        self.config = CHECK.read_config(self.env)
        self.assertEqual(self.config["network_prefix"], "10.203.1")
        self.assertEqual(self.config["planned_ipv4_networks"],
                         ["10.203.1.0/24", "10.203.2.0/24", "10.204.0.0/16"])
        plan = CHECK.daemon_plan(self.config)
        self.assertEqual(plan["bridge"], {"name": "tonram0", "address": "10.203.2.1/24"})
        self.assertEqual(plan["daemon_config"]["default-address-pools"],
                         [{"base": "10.204.0.0/16", "size": 24}])
        self.assertEqual(plan["compose_bridge"], {"name": "tonram1", "subnet": "10.203.1.0/24"})
        self.assertEqual(plan["planned_ipv4_networks"], self.config["planned_ipv4_networks"])
        for subnet in ("10.203.1.128/25", "10.203.2.1/32", "10.204.42.0/24"):
            docker = copy.deepcopy(self.docker)
            docker["networks"].append({"name": "conflict", "subnets": [subnet]})
            host = copy.deepcopy(self.host)
            host["ipv4_routes"].append({"dst": subnet, "dev": "vpn0"})
            with self.subTest(subnet=subnet):
                self.assertTrue(any("original Docker network conflict" in reason
                                    for reason in self.errors(docker=docker)))
                self.assertTrue(any("host route" in reason for reason in self.errors(host=host)))

    def test_five_services_and_existing_mylocalton_network_are_recorded_without_rejection(self):
        self.env.write_text(self.base + "MLT_NETWORK_PREFIX=10.203.1\n"
                            "NATIVE_RAM_BRIDGE_CIDR=10.203.2.1/24\n"
                            "NATIVE_RAM_ADDRESS_POOL=10.204.0.0/16\n")
        self.config = CHECK.read_config(self.env)
        names = ["maivlab-fin-nginx-1", "maivlab-fin", "solarisone-web-1",
                 "solarisone-contact-1", "maivlab-bot"]
        self.docker["running_containers"] = [{"id": str(index) * 64, "name": name}
                                             for index, name in enumerate(names)]
        self.docker["networks"].append({"name": "mylocalton-network", "subnets": ["172.28.1.0/24"]})
        self.host["ipv4_routes"].extend({"dst": destination, "dev": "br-6c6455c67014"}
                                          for destination in ("172.28.1.0/24", "172.28.1.1", "172.28.1.255"))
        self.assertEqual(self.errors(), [])
        with patch.object(CHECK, "host_snapshot", return_value=self.host), \
             patch.object(CHECK, "docker_snapshot", return_value=self.docker), \
             patch("sys.stdout", new_callable=io.StringIO) as output:
            self.assertEqual(CHECK.main(["--env-file", str(self.env)]), 0)
            receipt = json.loads(output.getvalue())
        self.assertTrue(receipt["valid"])
        self.assertEqual(receipt["original_docker"]["running_containers"], self.docker["running_containers"])
        self.docker["benchmark_port_publications"] = [{"protocol": "tcp", "port": 40004}]
        self.assertTrue(any("publishes" in reason for reason in self.errors()))
        self.docker["benchmark_port_publications"] = []
        self.host["benchmark_port_listeners"] = [{"protocol": "udp", "port": 40001}]
        self.assertTrue(any("host listener" in reason for reason in self.errors()))

    def test_network_settings_must_be_literal_private_ipv4_and_have_usable_ranges(self):
        invalid = {
            "MLT_NETWORK_PREFIX": ["10.203", "10.203.1.0", "10.203.256", "010.203.1",
                                   "8.8.8", "127.0.0", "169.254.1", "224.0.0", "${PREFIX}", "::1"],
            "NATIVE_RAM_BRIDGE_CIDR": ["10.203.2.0/24", "10.203.2.255/24", "10.203.2.1/31",
                                       "10.203.2.1", "8.8.8.1/24", "fc00::1/64", "$(id)"],
            "NATIVE_RAM_ADDRESS_POOL": ["10.204.1.0/16", "10.204.0.0/25", "10.204.0.0",
                                        "0.0.0.0/0", "8.0.0.0/8", "fc00::/48", "`id`"],
        }
        for key, values in invalid.items():
            for value in values:
                self.env.write_text(self.base + f"{key}={value}\n")
                with self.subTest(key=key, value=value), self.assertRaises(CHECK.CheckError):
                    CHECK.read_config(self.env)
        for key, value in CHECK.NETWORK_DEFAULTS.items():
            self.env.write_text(self.base + f"{key}={value}\nexport {key}={value}\n")
            with self.subTest(duplicate=key), self.assertRaisesRegex(CHECK.CheckError, "duplicate"):
                CHECK.read_config(self.env)

    def test_overlap_between_any_two_configured_networks_is_rejected(self):
        settings = ["MLT_NETWORK_PREFIX=172.29.0\n",
                    "MLT_NETWORK_PREFIX=172.30.1\n",
                    "NATIVE_RAM_BRIDGE_CIDR=172.30.42.1/24\n"]
        for setting in settings:
            self.env.write_text(self.base + setting)
            with self.subTest(setting=setting), self.assertRaisesRegex(CHECK.CheckError, "networks overlap"):
                CHECK.read_config(self.env)

    def test_docker_null_network_config_and_ports_are_valid_inspection_shapes(self):
        replies = [json.dumps([{"Endpoints": {"docker": {"Host": "unix:///var/run/docker.sock"}}}]),
                   json.dumps({"OSType": "linux", "OperatingSystem": "Ubuntu", "CgroupVersion": "2"}),
                   "networkid\n", json.dumps([{"Name": "host", "IPAM": {"Config": None}}]),
                   "containerid\n", json.dumps([{"Id": "containerid", "Name": "/host-service",
                                                  "NetworkSettings": {"Ports": None}}])]
        with patch.object(CHECK, "run_readonly", side_effect=replies) as command:
            result = CHECK.docker_snapshot("original")
        self.assertEqual(result["networks"][0]["subnets"], [])
        self.assertEqual(result["running_containers"][0]["name"], "host-service")
        for call in command.call_args_list:
            self.assertEqual(call.args[0][:3], ["docker", "--context", "original"])
            self.assertNotIn("run", call.args[0])
            self.assertNotIn("stop", call.args[0])

    def test_docker_desktop_rootless_and_cgroup_v1_rejected(self):
        for field, value, fragment in (("operating_system", "Docker Desktop", "Desktop"),
                                       ("security_options", ["name=rootless"], "rootful"),
                                       ("cgroup_version", "1", "cgroup v2")):
            docker = copy.deepcopy(self.docker)
            docker[field] = value
            with self.subTest(field=field):
                self.assertTrue(any(fragment in reason for reason in self.errors(docker=docker)))

    def test_nested_network_conflict_and_host_route_overlap_rejected(self):
        for subnet in ("172.28.0.0/16", "172.29.0.128/25", "172.30.42.0/24"):
            docker = copy.deepcopy(self.docker)
            docker["networks"] = [{"name": "other", "subnets": [subnet]}]
            with self.subTest(subnet=subnet):
                self.assertTrue(any("overlaps" in reason for reason in self.errors(docker=docker)))
        self.host["ipv4_routes"].append({"dst": "172.28.1.9/32", "dev": "vpn0"})
        self.assertTrue(any("host route" in reason for reason in self.errors()))

    def test_listener_publication_and_missing_tool_rejected(self):
        self.host["benchmark_port_listeners"] = [{"protocol": "tcp", "port": 40004}]
        self.host["dockerd_path"] = None
        self.docker["benchmark_port_publications"] = [{"protocol": "tcp", "port": 40004}]
        errors = self.errors()
        self.assertTrue(any("host listener" in error for error in errors))
        self.assertTrue(any("unavailable: dockerd" in error for error in errors))
        self.assertTrue(any("publishes" in error for error in errors))

    def test_coexistence_requires_forwarding_iptables_and_unclaimed_owned_bridges(self):
        for field, value, fragment in (("ipv4_forwarding", False, "IPv4 forwarding"),
                                       ("iptables_path", None, "unavailable: iptables"),
                                       ("planned_bridge_exists", True, "tonram0 already exists"),
                                       ("planned_compose_bridge_exists", True, "tonram1 already exists")):
            host = copy.deepcopy(self.host)
            host[field] = value
            with self.subTest(field=field):
                self.assertTrue(any(fragment in error for error in self.errors(host=host)))

    def test_empty_root_only_before_mount(self):
        self.assertEqual(CHECK.check_mount(self.config, False)["errors"], [])
        self.root.mkdir()
        (self.root / "existing-db").write_text("preserve")
        self.assertTrue(CHECK.check_mount(self.config, False)["errors"])
        self.assertEqual((self.root / "existing-db").read_text(), "preserve")

    def test_mounted_tmpfs_must_be_noswap_executable_and_large_enough(self):
        self.root.mkdir()
        row = {"target": str(self.root), "fstype": "tmpfs", "options": "rw,noswap,nodev,nosuid",
               "size": 96 * CHECK.GIB, "avail": 90 * CHECK.GIB}
        with patch.object(CHECK.os.path, "ismount", return_value=True), \
             patch.object(CHECK, "run_readonly") as command:
            command.return_value = json.dumps({"filesystems": [row]})
            self.assertEqual(CHECK.check_mount(self.config, True)["errors"], [])
            for field, value, fragment in (("fstype", "ext4", "must be tmpfs"),
                                           ("options", "rw", "noswap"),
                                           ("options", "rw,noswap,noexec", "noexec"),
                                           ("options", "ro,noswap", "writable"),
                                           ("size", 95 * CHECK.GIB, "size"),
                                           ("avail", 15 * CHECK.GIB, "MIN_FREE")):
                changed = dict(row, **{field: value})
                command.return_value = json.dumps({"filesystems": [changed]})
                with self.subTest(field=field):
                    errors = CHECK.check_mount(self.config, True)["errors"]
                    self.assertTrue(any(fragment in error for error in errors), errors)

    def test_low_capacity_does_not_block_cleanup_but_wrong_filesystem_still_does(self):
        self.root.mkdir()
        row = {"target": str(self.root), "fstype": "tmpfs", "options": "rw,noswap,nodev,nosuid",
               "size": 32 * CHECK.GIB, "avail": 0}
        with patch.object(CHECK.os.path, "ismount", return_value=True), \
             patch.object(CHECK, "run_readonly") as command:
            command.return_value = json.dumps({"filesystems": [row]})
            self.assertEqual(CHECK.check_mount(self.config, True, check_capacity=False)["errors"], [])
            self.assertTrue(CHECK.check_mount(self.config, True)["errors"])
            row["fstype"] = "ext4"
            command.return_value = json.dumps({"filesystems": [row]})
            self.assertTrue(CHECK.check_mount(self.config, True, check_capacity=False)["errors"])

    def test_daemon_plan_is_separate_complete_and_has_no_conflicting_bridge_flags(self):
        plan = CHECK.daemon_plan(self.config)
        for path in plan["paths"].values():
            self.assertTrue(Path(path).is_relative_to(self.root))
        daemon = plan["daemon_config"]
        self.assertEqual(daemon["storage-driver"], "vfs")
        self.assertFalse(daemon["features"]["containerd-snapshotter"])
        self.assertEqual(daemon["log-driver"], "json-file")
        self.assertEqual(daemon["bridge"], "tonram0")
        for option in ("iptables", "ip6tables", "ip-masq", "ip-forward"):
            self.assertIs(daemon[option], False)
        self.assertIs(daemon["userland-proxy"], True)
        self.assertNotIn("bip", daemon)
        self.assertEqual(plan["bridge"]["address"], "172.29.0.1/24")
        self.assertNotEqual(daemon["containerd-namespace"], "moby")
        self.assertIn("noswap", plan["mount_argv"][4])

    def test_explicit_containerd_prevents_system_daemon_storage_fallback(self):
        plan = CHECK.daemon_plan(self.config)
        containerd = tomllib.loads(plan["containerd_config"])
        self.assertEqual(containerd["version"], 2)
        self.assertEqual(containerd["grpc"]["address"], plan["daemon_config"]["containerd"])
        self.assertEqual(plan["containerd_argv"], ["containerd", "--config", plan["containerd_paths"]["config"]])
        for path in plan["containerd_paths"].values():
            self.assertTrue(Path(path).is_relative_to(self.root))
        self.assertNotIn("imports", containerd)
        self.assertIn("io.containerd.grpc.v1.cri", containerd["disabled_plugins"])
        self.assertIn("io.containerd.cri.v1.runtime", containerd["disabled_plugins"])
        self.host["containerd_path"] = None
        self.assertTrue(any("unavailable: containerd" in reason for reason in self.errors()))

    def test_cli_rejection_retains_evidence_and_cannot_overwrite_it(self):
        destination = self.directory / "receipt.json"
        self.host["mem_available_bytes"] = 21 * CHECK.GIB
        with patch.object(CHECK, "host_snapshot", return_value=self.host), \
             patch.object(CHECK, "docker_snapshot", return_value=self.docker), \
             patch("sys.stdout", new_callable=io.StringIO) as output:
            code = CHECK.main(["--env-file", str(self.env), "--output", str(destination)])
            self.assertEqual(code, 2)
            result = json.loads(output.getvalue())
            self.assertFalse(result["valid"])
            self.assertTrue(result["read_only"])
            self.assertEqual(json.loads(destination.read_text()), result)
            original = destination.read_bytes()
            output.seek(0)
            output.truncate(0)
            self.assertEqual(CHECK.main(["--env-file", str(self.env), "--output", str(destination)]), 2)
            self.assertEqual(destination.read_bytes(), original)
            self.assertTrue(any("new evidence file" in reason
                                for reason in json.loads(output.getvalue())["errors"]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
