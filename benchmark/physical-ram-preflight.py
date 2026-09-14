#!/usr/bin/env python3
"""Read-only admission check for a separate Docker daemon on nonswapping tmpfs.

This program never mounts a filesystem or starts/stops a daemon/container. A
successful pre-mount plan still requires the --require-mounted check after the
operator mounts tmpfs; neither check is a sustained benchmark resource guard.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
GIB = 1024 ** 3
RAM_KEYS = (
    "NATIVE_RAM_ROOT", "NATIVE_RAM_SIZE_GIB", "NATIVE_RAM_RUNTIME_GIB",
    "NATIVE_RAM_HOST_RESERVE_GIB", "NATIVE_RAM_MIN_AVAILABLE_GIB",
    "NATIVE_RAM_MIN_FREE_GIB",
)
BENCHMARK_PORTS = {"tcp": {40002, 40004, 8888, 18000},
                   "udp": {40001, 40003, 41001}}
PLANNED_NETWORKS = ("172.28.1.0/24", "172.29.0.0/24", "172.30.0.0/16")


class CheckError(ValueError):
    pass


def read_config(path):
    """Parse only the six literal RAM settings, without executing dotenv text."""
    raw = Path(path).read_bytes()
    settings = {}
    for number, line in enumerate(raw.decode("utf-8").splitlines(), 1):
        match = re.match(r"^\s*(?:export\s+)?(NATIVE_RAM_[A-Za-z0-9_]+)\s*=(.*)$", line)
        if not match or match[1] not in RAM_KEYS:
            continue
        key, value = match.groups()
        if key in settings:
            raise CheckError(f"duplicate {key} at line {number}")
        try:
            words = shlex.split(value, comments=True, posix=True)
        except ValueError as error:
            raise CheckError(f"invalid literal {key}: {error}") from error
        if len(words) != 1 or any(char in words[0] for char in "$`\n\r\x00"):
            raise CheckError(f"{key} must contain one literal value without shell expansion")
        settings[key] = words[0]
    missing = sorted(set(RAM_KEYS) - set(settings))
    if missing:
        raise CheckError("missing RAM settings: " + ", ".join(missing))
    root = Path(settings["NATIVE_RAM_ROOT"])
    if not root.is_absolute() or str(root) == "/" or ".." in root.parts:
        raise CheckError("NATIVE_RAM_ROOT must be a dedicated absolute path, excluding / and ..")
    if root.resolve() != root:
        raise CheckError("NATIVE_RAM_ROOT and its existing parent directories must not be symlinks")
    if len(os.fsencode(root / "containerd-debug.sock")) >= 104:
        raise CheckError("NATIVE_RAM_ROOT is too long for the private runtime Unix sockets")
    values = {"root": str(root)}
    for key in RAM_KEYS[1:]:
        if not re.fullmatch(r"[1-9][0-9]*", settings[key]):
            raise CheckError(f"{key} must be a positive integer number of GiB")
        values[key.removeprefix("NATIVE_RAM_").lower()] = int(settings[key])
    if values["min_free_gib"] >= values["size_gib"]:
        raise CheckError("NATIVE_RAM_MIN_FREE_GIB must be smaller than NATIVE_RAM_SIZE_GIB")
    minimum = values["size_gib"] + values["runtime_gib"] + values["host_reserve_gib"]
    values["required_available_gib"] = max(values["min_available_gib"], minimum)
    values["required_available_bytes"] = values["required_available_gib"] * GIB
    values["capacity_is_reserved"] = False
    values["env_sha256"] = hashlib.sha256(raw).hexdigest()
    return values


def run_readonly(argv):
    try:
        result = subprocess.run(argv, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=20, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise CheckError(f"read-only command failed: {argv[0]}: {error}") from error
    if result.returncode:
        raise CheckError(f"read-only command failed ({result.returncode}): " +
                         " ".join(argv[:5]) + ": " + result.stderr.strip()[:800])
    return result.stdout


def read_proc_numbers(path, suffix=""):
    result = {}
    for line in Path(path).read_text().splitlines():
        fields = line.replace(":", "").split()
        if len(fields) >= 2 and fields[1].isdigit():
            result[fields[0]] = int(fields[1]) * (1024 if suffix == "kB" else 1)
    return result


def listening_ports():
    found = []
    for protocol in ("tcp", "udp"):
        for version in ("", "6"):
            path = Path("/proc/net") / (protocol + version)
            if not path.exists():
                continue
            for line in path.read_text().splitlines()[1:]:
                fields = line.split()
                if len(fields) < 4 or (protocol == "tcp" and fields[3] != "0A"):
                    continue
                port = int(fields[1].rsplit(":", 1)[1], 16)
                if port in BENCHMARK_PORTS[protocol]:
                    found.append({"protocol": protocol, "port": port, "family": version or "4"})
    return found


def host_snapshot():
    memory = read_proc_numbers("/proc/meminfo", "kB")
    host = {
        "platform": sys.platform, "kernel": os.uname().release,
        "mem_total_bytes": memory.get("MemTotal", 0),
        "mem_available_bytes": memory.get("MemAvailable", 0),
        "swap_total_bytes": memory.get("SwapTotal", 0),
        "swap_free_bytes": memory.get("SwapFree", 0),
        "cgroup_v2": Path("/sys/fs/cgroup/cgroup.controllers").is_file(),
        "dockerd_path": shutil.which("dockerd"),
        "containerd_path": shutil.which("containerd"),
        "docker_path": shutil.which("docker"),
        "mount_path": shutil.which("mount"),
        "findmnt_path": shutil.which("findmnt"),
        "ip_path": shutil.which("ip"),
        "logical_cpus": os.cpu_count(),
        "memory_pressure": Path("/proc/pressure/memory").read_text().strip()
            if Path("/proc/pressure/memory").is_file() else None,
        "benchmark_port_listeners": listening_ports(),
        "planned_bridge_exists": Path("/sys/class/net/tonram0").exists(),
    }
    try:
        host["ipv4_routes"] = json.loads(run_readonly(["ip", "-json", "-4", "route", "show", "table", "all"]))
    except (CheckError, ValueError) as error:
        host["route_inspection_error"] = str(error)
    return host


def docker_snapshot(context):
    if not context:
        context = run_readonly(["docker", "context", "show"]).strip()
    if not context or "\n" in context:
        raise CheckError("cannot resolve one original Docker context")
    selected = ["docker", "--context", context]
    contexts = json.loads(run_readonly(selected + ["context", "inspect", context]))
    endpoint = contexts[0].get("Endpoints", {}).get("docker", {}).get("Host", "")
    if not endpoint.startswith("unix://"):
        raise CheckError("the original Docker context must use a local Unix socket")
    info = json.loads(run_readonly(selected + ["info", "--format", "{{json .}}"] ))
    networks = []
    ids = run_readonly(selected + ["network", "ls", "--quiet"]).split()
    if len(ids) > 512:
        raise CheckError("too many original Docker networks for the bounded preflight")
    if ids:
        for network in json.loads(run_readonly(selected + ["network", "inspect", *ids])):
            networks.append({"name": network.get("Name"), "id": network.get("Id"),
                             "subnets": [item["Subnet"] for item in
                                (network.get("IPAM", {}).get("Config") or []) if item.get("Subnet")]})
    publications = []
    running = []
    ids = run_readonly(selected + ["ps", "--quiet"]).split()
    if len(ids) > 512:
        raise CheckError("too many original Docker containers for the bounded preflight")
    if ids:
        for container in json.loads(run_readonly(selected + ["inspect", *ids])):
            running.append({"id": container.get("Id"), "name": container.get("Name", "").lstrip("/")})
            for private, bindings in (container.get("NetworkSettings", {}).get("Ports") or {}).items():
                protocol = private.rsplit("/", 1)[-1]
                for binding in bindings or []:
                    port = int(binding.get("HostPort") or 0)
                    if port in BENCHMARK_PORTS.get(protocol, set()):
                        publications.append({"container": container.get("Name", "").lstrip("/"),
                                             "protocol": protocol, "port": port,
                                             "host_ip": binding.get("HostIp")})
    return {"context": context, "endpoint": endpoint, "os_type": info.get("OSType"),
            "operating_system": info.get("OperatingSystem"),
            "cgroup_version": str(info.get("CgroupVersion", "")),
            "security_options": info.get("SecurityOptions") or [],
            "docker_version": info.get("ServerVersion"),
            "networks": networks, "running_containers": running,
            "benchmark_port_publications": publications}


def daemon_plan(config):
    root = Path(config["root"])
    paths = {name: str(root / relative) for name, relative in {
        "data_root": "data", "exec_root": "exec",
        "tmp_dir": "tmp", "socket": "docker.sock", "pid_file": "dockerd.pid",
        "log_file": "dockerd.log", "daemon_config": "daemon.json",
    }.items()}
    containerd_paths = {name: str(root / relative) for name, relative in {
        "root": "containerd-data", "state": "containerd-state", "socket": "containerd.sock",
        "config": "containerd.toml", "log": "containerd.log", "ttrpc_socket": "containerd.ttrpc",
        "debug_socket": "containerd-debug.sock",
    }.items()}
    # Docker otherwise auto-detects a system containerd even with private
    # data/exec roots. An explicit private endpoint avoids that disk fallback.
    containerd_config = "\n".join([
        "version = 2", "root = " + json.dumps(containerd_paths["root"]),
        "state = " + json.dumps(containerd_paths["state"]),
        "disabled_plugins = " + json.dumps(["io.containerd.grpc.v1.cri", "io.containerd.cri.v1.images",
                                             "io.containerd.cri.v1.runtime"]),
        "[grpc]", "address = " + json.dumps(containerd_paths["socket"]),
        "[ttrpc]", "address = " + json.dumps(containerd_paths["ttrpc_socket"]),
        "[debug]", "address = " + json.dumps(containerd_paths["debug_socket"]), "",
    ])
    daemon_config = {
        "data-root": paths["data_root"], "exec-root": paths["exec_root"],
        "pidfile": paths["pid_file"], "hosts": ["unix://" + paths["socket"]],
        "storage-driver": "vfs", "bridge": "tonram0",
        "default-address-pools": [{"base": "172.30.0.0/16", "size": 24}],
        "log-driver": "json-file", "live-restore": False,
        "features": {"containerd-snapshotter": False},
        "containerd-namespace": "mylocalton-ram",
        "containerd-plugins-namespace": "mylocalton-ram-plugins",
        "containerd": containerd_paths["socket"],
    }
    return {"paths": paths, "environment": {"TMPDIR": paths["tmp_dir"],
             "DOCKER_TMPDIR": paths["tmp_dir"]}, "daemon_config": daemon_config,
            "dockerd_argv": ["dockerd", "--config-file", paths["daemon_config"]],
            "containerd_paths": containerd_paths, "containerd_config": containerd_config,
            "containerd_argv": ["containerd", "--config", containerd_paths["config"]],
            "docker_host": "unix://" + paths["socket"],
            "bridge": {"name": "tonram0", "address": "172.29.0.1/24"},
            "mount_argv": ["mount", "-t", "tmpfs", "-o",
                f"size={config['size_gib']}G,noswap,nodev,nosuid,mode=0700", "tmpfs", str(root)],
            "planned_ipv4_networks": list(PLANNED_NETWORKS),
            "notes": ["All paths belong to the new tmpfs; never use the original daemon's data root.",
                      "vfs stores independent image/container filesystem copies; budget their full size.",
                      "Start the explicit private containerd first; automatic system containerd discovery would use host storage.",
                      "Keep json-file logs: the benchmark reads final generator proofs with docker logs.",
                      "Create/address the dedicated bridge before dockerd; custom bridge and bip are mutually exclusive.",
                      "Mount success and the --require-mounted check establish noswap support.",
                      "Readiness is a point-in-time check; the runner must guard RAM and tmpfs free space."]}


def check_mount(config, require_mounted, check_capacity=True):
    """Verify identity/type even during cleanup; admission alone needs capacity.

    A resource guard can trip because free space is low. Cleanup and evidence
    export must still be permitted on that same structurally valid RAM mount.
    """
    root = Path(config["root"])
    record = {"required": require_mounted, "root_exists": root.exists(), "errors": []}
    if not require_mounted:
        if root.exists() and (not root.is_dir() or any(root.iterdir())):
            record["errors"].append("pre-mount RAM root must be absent or an empty dedicated directory")
        if os.path.ismount(root):
            record["errors"].append("RAM root is already mounted; use --require-mounted to verify it")
        return record
    if not root.is_dir() or not os.path.ismount(root):
        record["errors"].append("RAM root is not a mounted directory")
        return record
    result = json.loads(run_readonly(["findmnt", "--json", "--bytes", "--mountpoint", str(root),
                                    "--output", "TARGET,FSTYPE,OPTIONS,SIZE,AVAIL"]))
    rows = result.get("filesystems", [])
    if len(rows) != 1:
        raise CheckError("cannot identify one filesystem at the RAM root")
    row = rows[0]
    record.update(row)
    options = set(str(row.get("options", "")).split(","))
    if row.get("fstype") != "tmpfs":
        record["errors"].append("RAM root must be tmpfs")
    if "noswap" not in options:
        record["errors"].append("RAM tmpfs must expose the noswap mount option; swappable tmpfs is not accepted")
    if "noexec" in options:
        record["errors"].append("RAM tmpfs cannot be noexec: container binaries execute from it")
    if "ro" in options:
        record["errors"].append("RAM tmpfs must be writable")
    if check_capacity and int(row.get("size") or 0) < config["size_gib"] * GIB:
        record["errors"].append("mounted tmpfs size is smaller than NATIVE_RAM_SIZE_GIB")
    if check_capacity and int(row.get("avail") or 0) < config["min_free_gib"] * GIB:
        record["errors"].append("RAM filesystem has less than NATIVE_RAM_MIN_FREE_GIB free")
    return record


def evaluate(config, host, docker, mount):
    errors = list(mount.get("errors", []))
    if host.get("platform") != "linux":
        errors.append("a native Linux host is required")
    if not host.get("cgroup_v2"):
        errors.append("the host must use cgroup v2")
    for tool in ("dockerd", "containerd", "docker", "mount", "findmnt", "ip"):
        if not host.get(tool + "_path"):
            errors.append(f"required host executable is unavailable: {tool}")
    if host.get("mem_available_bytes", 0) < config["required_available_bytes"]:
        errors.append("host MemAvailable is below the larger of configured minimum and "
                      "tmpfs capacity + runtime budget + host reserve "
                      f"({config['required_available_gib']} GiB)")
    if host.get("benchmark_port_listeners"):
        errors.append("a host listener already occupies a benchmark TCP/UDP port")
    if host.get("planned_bridge_exists"):
        errors.append("planned RAM Docker bridge tonram0 already exists")
    if host.get("route_inspection_error"):
        errors.append("host route inspection failed: " + host["route_inspection_error"])
    planned = [ipaddress.ip_network(value) for value in PLANNED_NETWORKS]
    for route in host.get("ipv4_routes", []):
        destination = route.get("dst", "default")
        if destination in ("default", "0.0.0.0/0"):
            continue
        try:
            existing = ipaddress.ip_network(destination, strict=False)
        except ValueError:
            errors.append("cannot parse host IPv4 route: " + destination)
            continue
        for wanted in planned:
            if existing.overlaps(wanted):
                errors.append(f"host route {destination} via {route.get('dev', '?')} "
                              f"overlaps planned RAM network {wanted}")
    if docker is not None:
        if docker.get("os_type") != "linux" or "desktop" in str(docker.get("operating_system", "")).lower():
            errors.append("Docker Desktop/VM and non-Linux daemons are unsupported; use native Linux Docker Engine")
        if docker.get("cgroup_version") != "2":
            errors.append("the original Docker daemon must report cgroup v2")
        if any("rootless" in item.lower() for item in docker.get("security_options", [])):
            errors.append("the original Docker daemon must be rootful")
        if docker.get("running_containers"):
            errors.append("the original Docker daemon has running containers; use a dedicated benchmark host maintenance window")
        if docker.get("benchmark_port_publications"):
            errors.append("the original Docker daemon publishes a benchmark TCP/UDP port")
        for network in docker.get("networks", []):
            for subnet in network.get("subnets", []):
                try:
                    existing = ipaddress.ip_network(subnet, strict=False)
                except ValueError:
                    errors.append("cannot parse original Docker subnet: " + subnet)
                    continue
                for wanted in planned:
                    if existing.version == wanted.version and existing.overlaps(wanted):
                        errors.append(f"original Docker network {network.get('name')} ({subnet}) "
                                      f"overlaps planned RAM network {wanted}")
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", default=str(Path(__file__).resolve().parents[1] / ".env.physical"))
    parser.add_argument("--docker-context", help="original native Docker context; default: docker context show")
    parser.add_argument("--require-mounted", action="store_true", help="verify the mounted noswap tmpfs")
    parser.add_argument("--output", help="also save JSON to a new evidence file; never overwrite")
    parser.add_argument("--self-test", action="store_true", help="run offline fixture tests; no host admission")
    args = parser.parse_args(argv)
    if args.self_test:
        test = Path(__file__).with_name("tests") / "physical-ram-preflight-test.py"
        return subprocess.run([sys.executable, "-B", str(test)], check=False).returncode
    report = {"schema": "native-physical-ram-preflight-v1",
              "checked_at": datetime.now(timezone.utc).isoformat(),
              "phase": "mounted" if args.require_mounted else "before_mount",
              "read_only": True, "valid": False, "errors": []}
    try:
        config = read_config(args.env_file)
        report.update(config=config, daemon_plan=daemon_plan(config))
        host = host_snapshot()
        report["host"] = host
        docker = None
        try:
            docker = docker_snapshot(args.docker_context)
            report["original_docker"] = docker
        except (CheckError, ValueError, KeyError, IndexError) as error:
            report["errors"].append("original Docker inspection failed: " + str(error))
        mount = check_mount(config, args.require_mounted)
        report["mount"] = mount
        report["errors"].extend(evaluate(config, host, docker, mount))
    except (CheckError, OSError, ValueError, KeyError, IndexError) as error:
        report["errors"].append(str(error))
    report["valid"] = not report["errors"]
    data = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        try:
            with open(args.output, "x", encoding="utf-8") as stream:
                stream.write(data)
        except OSError as error:
            report["valid"] = False
            report["errors"].append("cannot create new evidence file: " + str(error))
            data = json.dumps(report, indent=2, sort_keys=True) + "\n"
    print(data, end="")
    return 0 if report["valid"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
