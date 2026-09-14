#!/usr/bin/env python3
"""Fail-closed resource guard for one explicitly identified RAM Docker daemon.

The guard never stops a daemon, changes a mount, or uses the default Docker
endpoint. Its only container mutations target captured IDs with both the exact
Compose project and one of the three benchmark service labels.
"""

import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


GIB = 1024 ** 3
SERVICES = ("native-load-generator", "genesis", "session-stats")


class GuardError(RuntimeError):
    pass


class IdentityError(GuardError):
    pass


class MountError(GuardError):
    pass


def now():
    return datetime.now(timezone.utc).isoformat()


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("x") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
    temporary.replace(path)


def ram_mount(root, mountinfo=Path("/proc/self/mountinfo")):
    mounts = []
    for line in mountinfo.read_text().splitlines():
        fields = line.split()
        separator = fields.index("-")
        mountpoint = Path(re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), fields[4]))
        if root == mountpoint or mountpoint in root.parents:
            options = set(fields[5].split(",")) | set(fields[separator + 3].split(","))
            mounts.append((len(mountpoint.parts), mountpoint, fields[separator + 1], options))
    if not mounts:
        raise MountError(f"cannot identify mount for {root}")
    _, mountpoint, filesystem, options = max(mounts, key=lambda entry: entry[0])
    if filesystem != "tmpfs" or "noswap" not in options or "ro" in options or "noexec" in options:
        raise MountError(f"RAM mount must remain writable, executable tmpfs with noswap: {mountpoint}, {filesystem}, {sorted(options)}")
    return {"mountpoint": str(mountpoint), "filesystem": filesystem, "options": sorted(options)}


def memory_sample(meminfo=Path("/proc/meminfo"), vmstat=Path("/proc/vmstat")):
    values = {}
    for line in meminfo.read_text().splitlines():
        fields = line.split()
        values[fields[0].rstrip(":")] = int(fields[1]) * 1024
    paging = dict(line.split() for line in vmstat.read_text().splitlines())
    return {"host_mem_available_bytes": values["MemAvailable"],
            "host_mem_total_bytes": values["MemTotal"],
            "host_swap_total_bytes": values["SwapTotal"],
            "host_swap_used_bytes": values["SwapTotal"] - values["SwapFree"],
            "swap_in_pages_total": int(paging["pswpin"]),
            "swap_out_pages_total": int(paging["pswpout"])}


class Docker:
    def __init__(self, host, daemon_id, root, project):
        if not host.startswith("unix:///") or "\n" in host:
            raise IdentityError("guard requires an explicit local unix:/// Docker endpoint")
        socket = Path(host[len("unix://"):]).resolve()
        if root not in socket.parents:
            raise IdentityError("Docker socket must be inside the dedicated RAM root")
        if not daemon_id or any(char.isspace() for char in daemon_id):
            raise IdentityError("an explicit Docker daemon ID is required")
        if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", project):
            raise IdentityError("invalid Compose project name")
        self.host, self.daemon_id, self.root, self.project = host, daemon_id, root, project

    def command(self, *arguments, timeout=8):
        environment = os.environ.copy()
        for name in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH"):
            environment.pop(name, None)
        try:
            result = subprocess.run(["docker", "--host", self.host, *arguments],
                                    env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    text=True, timeout=timeout, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise GuardError(f"private Docker command failed: {error}") from error
        if result.returncode:
            raise GuardError(f"private Docker command failed ({result.returncode}): {result.stderr.strip()}")
        return result.stdout

    def verify(self):
        info = json.loads(self.command("info", "--format", "{{json .}}"))
        if info.get("ID") != self.daemon_id or info.get("DockerRootDir") != str(self.root / "data"):
            raise IdentityError("Docker daemon ID or DockerRootDir changed; container stops are forbidden")
        if (self.root / "data").is_symlink():
            raise IdentityError("Docker data root must not become a symlink")
        return {"id": info["ID"], "data_root": info["DockerRootDir"]}

    def inspect(self, *identifiers):
        result = json.loads(self.command("inspect", *identifiers))
        if not isinstance(result, list) or len(result) != len(identifiers) or not all(isinstance(item, dict) for item in result):
            raise IdentityError("Docker inspect returned an unexpected object set")
        return result

    def owned_service(self, item):
        labels = (item.get("Config") or {}).get("Labels") or {}
        service = labels.get("com.docker.compose.service")
        if labels.get("com.docker.compose.project") == self.project and service in SERVICES:
            return service
        return None

    def stop_owned(self):
        # Do not trust a cached identity when making a mutation.
        self.verify()
        identifiers = self.command("ps", "--quiet", "--no-trunc", "--filter",
                                   f"label=com.docker.compose.project={self.project}").split()
        if any(not re.fullmatch(r"[0-9a-f]{64}", identifier) for identifier in identifiers):
            raise IdentityError("Docker returned a non-canonical container ID")
        if not identifiers:
            return []
        captured = self.inspect(*identifiers)
        allowed_ids = set(identifiers)
        selected = []
        for item in captured:
            service = self.owned_service(item)
            if item.get("Id") not in allowed_ids:
                raise IdentityError("Docker inspect returned an uncaptured container ID")
            if service:
                selected.append((SERVICES.index(service), item["Id"], service))
        result = []
        for _, identifier, service in sorted(selected):
            receipt = {"id": identifier, "service": service, "requested_at": now()}
            try:
                self.verify()
                current = self.inspect(identifier)
                if len(current) != 1 or current[0].get("Id") != identifier or self.owned_service(current[0]) != service:
                    raise IdentityError("container ownership changed before stop")
                receipt["before"] = current[0].get("State")
                if current[0].get("State", {}).get("Running"):
                    timeout = 25 if service == "native-load-generator" else 15
                    self.command("stop", "--time", str(timeout), identifier, timeout=timeout + 8)
                receipt["after"] = self.inspect(identifier)[0].get("State")
                receipt["stopped"] = not receipt["after"].get("Running", False)
            except (GuardError, OSError, ValueError, KeyError, IndexError) as error:
                receipt["error"] = str(error)
                receipt["stopped"] = False
            result.append(receipt)
        return result


class Thresholds:
    def __init__(self, reserve_gib, min_free_gib):
        self.reserve = reserve_gib * GIB
        self.minimum = min_free_gib * GIB
        self.memory_low = 0
        self.free_low = 0

    def check(self, sample):
        available = sample["host_mem_available_bytes"]
        free = sample["ram_free_bytes"]
        self.memory_low = self.memory_low + 1 if available < self.reserve else 0
        self.free_low = self.free_low + 1 if free < self.minimum else 0
        sample["consecutive_low_samples"] = {"host_memory": self.memory_low, "ram_free": self.free_low}
        if available < 8 * GIB:
            return "host memory below the 8 GiB emergency floor"
        if self.memory_low >= 2:
            return "host memory below the configured reserve in two consecutive samples"
        if self.free_low >= 2:
            return "RAM filesystem free space below the configured reserve in two consecutive samples"
        return None


def collect(root, docker):
    sample = {"time": now(), "epoch": time.time(), "mount": ram_mount(root)}
    sample["data_mount"] = ram_mount(root / "data")
    sample.update(memory_sample())
    filesystem = os.statvfs(root)
    sample["ram_free_bytes"] = filesystem.f_bavail * filesystem.f_frsize
    sample["ram_size_bytes"] = filesystem.f_blocks * filesystem.f_frsize
    sample["daemon"] = docker.verify()
    return sample


def monitor(root, docker, reserve_gib, min_free_gib, interval):
    ram_mount(root)
    docker.verify()
    log_path = root / "guard.log"
    for name in ("guard.stop", "guard-ready.json", "guard-tripped.json", "guard-finished.json"):
        if (root / name).exists():
            raise GuardError(f"refusing to overwrite an existing guard lifecycle: {name}")
    thresholds = Thresholds(reserve_gib, min_free_gib)
    errors = 0
    reason = None
    last_sample = None
    stopped_by_signal = []
    previous_handlers = {}

    def signal_stop(number, _frame):
        stopped_by_signal.append(number)

    for number in (signal.SIGTERM, signal.SIGINT):
        previous_handlers[number] = signal.signal(number, signal_stop)
    try:
        with log_path.open("x", buffering=1) as log:
            log.write(json.dumps({"event": "started", "time": now(), "pid": os.getpid(),
                                  "docker_host": docker.host, "daemon_id": docker.daemon_id,
                                  "project": docker.project, "reserve_gib": reserve_gib,
                                  "min_free_gib": min_free_gib, "emergency_gib": 8}) + "\n")
            while not (root / "guard.stop").exists() and not stopped_by_signal:
                started = time.monotonic()
                try:
                    last_sample = collect(root, docker)
                    errors = 0
                    reason = thresholds.check(last_sample)
                    log.write(json.dumps(last_sample) + "\n")
                    if not reason and not thresholds.memory_low and not thresholds.free_low and not (root / "guard-ready.json").exists():
                        write_json(root / "guard-ready.json", {"time": now(), "pid": os.getpid(),
                                                               "daemon_id": docker.daemon_id,
                                                               "project": docker.project,
                                                               "first_healthy_sample": last_sample})
                except (GuardError, OSError, ValueError, KeyError) as error:
                    errors += 1
                    last_sample = {"time": now(), "event": "sample_error", "consecutive_errors": errors,
                                   "error": str(error), "error_type": type(error).__name__}
                    log.write(json.dumps(last_sample) + "\n")
                    if isinstance(error, (IdentityError, MountError)) or errors >= 2:
                        reason = "resource monitoring failed: " + str(error)
                if reason:
                    break
                # Short chunks allow marker-based shutdown without a full interval delay.
                deadline = started + interval
                while time.monotonic() < deadline and not (root / "guard.stop").exists() and not stopped_by_signal:
                    time.sleep(min(0.2, max(0, deadline - time.monotonic())))
            if stopped_by_signal and not (root / "guard.stop").exists():
                reason = f"resource guard interrupted by signal {stopped_by_signal[-1]}"
            finished = {"time": now(), "tripped": bool(reason), "reason": reason,
                        "stop_marker": (root / "guard.stop").exists(), "signals": stopped_by_signal}
            if reason:
                trip = {"time": now(), "reason": reason, "last_sample": last_sample,
                        "docker_host": docker.host, "daemon_id": docker.daemon_id, "project": docker.project}
                # Publish before attempting potentially slow graceful stops.
                write_json(root / "guard-tripped.json", trip)
                try:
                    finished["containers"] = docker.stop_owned()
                except (GuardError, OSError, ValueError, KeyError, IndexError) as error:
                    finished["cleanup_error"] = str(error)
                log.write(json.dumps({"event": "tripped", **finished}) + "\n")
            else:
                log.write(json.dumps({"event": "stopped", **finished}) + "\n")
            write_json(root / "guard-finished.json", finished)
            return 1 if reason else 0
    finally:
        for number, handler in previous_handlers.items():
            signal.signal(number, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--docker-host", required=True)
    parser.add_argument("--daemon-id", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--reserve-gib", type=float, default=32)
    parser.add_argument("--min-free-gib", type=float, default=16)
    parser.add_argument("--interval", type=float, default=5)
    args = parser.parse_args()
    if not all(math.isfinite(value) for value in (args.reserve_gib, args.min_free_gib, args.interval)) or not (
            args.reserve_gib >= 8 and args.min_free_gib > 0 and 0 < args.interval <= 60):
        parser.error("reserve must be at least 8 GiB, free space positive, interval in (0, 60] seconds")
    if not args.root.is_absolute() or args.root.is_symlink() or not args.root.is_dir():
        parser.error("root must be an existing absolute non-symlink directory")
    root = args.root.resolve()
    try:
        docker = Docker(args.docker_host, args.daemon_id, root, args.project)
        return monitor(root, docker, args.reserve_gib, args.min_free_gib, args.interval)
    except (GuardError, OSError, ValueError, KeyError) as error:
        print(f"RAM resource guard refused: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
