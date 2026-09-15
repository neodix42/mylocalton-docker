#!/usr/bin/env python3
"""Run a fresh, isolated native Docker benchmark entirely on noswap tmpfs.

check and diagnose are read-only. start prepares images and a fresh genesis; run
measures the profile's workload. exec exposes the verified private Docker
endpoint. stop exports evidence and stops this launcher's processes, retaining
the RAM mount unless explicit discard-and-unmount is requested. recover-unmount
uses previously exported ownership after in-RAM metadata was accidentally lost.
No command uses, stops, or reconfigures containers on the original daemon.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.request
import uuid

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[1]
PREFLIGHT = REPO / "benchmark/physical-ram-preflight.py"
GUARD = REPO / "benchmark/physical-ram-guard.py"
FIREWALL = REPO / "benchmark/physical-ram-firewall.py"
MOUNT_DIAGNOSTIC = REPO / "benchmark/physical-ram-mount.py"
SPEC = importlib.util.spec_from_file_location("physical_ram_preflight", PREFLIGHT)
PREFLIGHT_MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREFLIGHT_MODULE)
FIREWALL_SPEC = importlib.util.spec_from_file_location("physical_ram_firewall", FIREWALL)
FIREWALL_MODULE = importlib.util.module_from_spec(FIREWALL_SPEC)
FIREWALL_SPEC.loader.exec_module(FIREWALL_MODULE)
MOUNT_SPEC = importlib.util.spec_from_file_location("physical_ram_mount", MOUNT_DIAGNOSTIC)
MOUNT_MODULE = importlib.util.module_from_spec(MOUNT_SPEC)
MOUNT_SPEC.loader.exec_module(MOUNT_MODULE)
SERVICES = ("native-load-generator", "genesis", "session-stats")
HEX_ID = re.compile(r"[0-9a-f]{64}")


class LauncherError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise LauncherError(message)


def utc():
    return datetime.now(timezone.utc).isoformat()


def write_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def profile_literal(path, key, default=None):
    rows = re.findall(r"^\s*(?:export\s+)?" + re.escape(key) + r"\s*=(.*)$", Path(path).read_text(), re.M)
    if not rows and default is not None:
        return str(default)
    require(len(rows) == 1, "profile must define exactly one literal " + key)
    values = shlex.split(rows[0], comments=True)
    require(len(values) == 1 and not any(char in values[0] for char in "$`\n\r\x00"), "profile " + key + " must be literal")
    return values[0]


def benchmark_time_budgets(env_file, settings):
    def seconds(value, name, minimum, maximum):
        require(re.fullmatch(r"[0-9]+", str(value)) is not None, name + " must be an integer number of seconds")
        result = int(value)
        require(minimum <= result <= maximum, f"{name} must be within {minimum}..{maximum} seconds")
        return result

    def setting(name, default, minimum, maximum):
        value = settings.get(name)
        return seconds(default if value is None or value == "" else value, name, minimum, maximum)

    def allowance(name, default, maximum):
        return seconds(profile_literal(env_file, name, default), name, 60, maximum)

    components = {
        "wrapper_setup": allowance("NATIVE_RAM_WRAPPER_SETUP_TIMEOUT_SECONDS", 600, 7200),
        "generator_setup": allowance("NATIVE_RAM_GENERATOR_SETUP_TIMEOUT_SECONDS", 1800, 14400),
        "lane_readiness": setting("NATIVE_LOAD_PAYMENT_LANE_READY_TIMEOUT_SECONDS", 900, 1, 86400),
        "ramp": setting("NATIVE_LOAD_RAMP_SECONDS", 0, 0, 3600),
        "warmup": setting("NATIVE_LOAD_WARMUP_SECONDS", 0, 0, 600),
        "measurement": setting("NATIVE_LOAD_DURATION_SECONDS", 0, 1, 3600),
        "drain": setting("NATIVE_LOAD_DRAIN_TIMEOUT_SECONDS", 0, 1, 1800),
        "reporting": allowance("NATIVE_RAM_REPORT_TIMEOUT_SECONDS", 1800, 7200),
    }
    phases = {"setup": components["wrapper_setup"],
              "generator": sum(components[key] for key in
                               ("generator_setup", "lane_readiness", "ramp", "warmup", "measurement", "drain")),
              "reporting": components["reporting"]}
    return {"schema": "native-physical-ram-time-budgets-v1", "components_seconds": components,
            "phase_seconds": phases, "total_seconds": sum(phases.values()),
            "semantics": "Separate bounded setup, generator (including preparation/readiness), and reporting budgets; measurement duration is unchanged."}


class BenchmarkDeadline:
    """Substage updates cannot renew a phase budget or authorize a valid result."""
    PHASES = ("setup", "generator", "reporting")

    def __init__(self, path, budgets, started):
        self.path, self.budgets = Path(path), budgets
        self.phase, self.detail, self.phase_started = "setup", "waiting_for_wrapper", started

    def refresh(self, now):
        # The wrapper replaces this small receipt atomically. Missing/invalid
        # progress cannot extend the deadline or turn a timeout into success.
        try:
            if self.path.is_symlink() or self.path.stat().st_size > 16384:
                return
            record = json.loads(self.path.read_text())
        except (OSError, ValueError):
            return
        if not isinstance(record, dict) or record.get("schema") != "native-benchmark-progress-v1":
            return
        phase = record.get("phase")
        if phase == "complete":
            phase = "reporting"
        if phase not in self.PHASES or self.PHASES.index(phase) < self.PHASES.index(self.phase):
            return
        if phase != self.phase:
            self.phase, self.phase_started = phase, now
        detail = record.get("detail")
        if isinstance(detail, str):
            self.detail = re.sub(r"[^A-Za-z0-9_.:-]", "_", detail)[:160]

    def describe(self, now):
        return f"phase={self.phase}/{self.detail}, phase elapsed={int(now - self.phase_started)}/{self.budgets[self.phase]}s"

    def check(self, now, log_name, destination):
        require(now - self.phase_started < self.budgets[self.phase],
                f"{log_name} timed out: {self.describe(now)}; see {destination} and {self.path}")


def private_environment(host, temporary, project):
    # Compose and Docker shell overrides must not redirect operations or change
    # the file-backed workload. Preserve credentials and the normal host PATH.
    result = {key: value for key, value in os.environ.items()
              if not key.startswith(("DOCKER_", "COMPOSE_", "BENCHMARK_", "BUILDX_", "BUILDKIT_"))}
    result.update(DOCKER_HOST=host, TMPDIR=str(temporary), DOCKER_TMPDIR=str(temporary),
                  DOCKER_CONFIG=str(Path(temporary).parent / "client"),
                  PYTHONDONTWRITEBYTECODE="1", XDG_CACHE_HOME=str(Path(temporary) / "cache"),
                  XDG_STATE_HOME=str(Path(temporary) / "state"),
                  COMPOSE_PROJECT_NAME=project, COMPOSE_PROFILES="")
    return result


def process_identity(pid):
    try:
        text = Path(f"/proc/{pid}/stat").read_text()
        # comm may contain spaces and parentheses; field 22 follows the final ).
        fields = text[text.rfind(")") + 2:].split()
        if fields[0] == "Z":
            return None
        return {"pid": int(pid), "start_ticks": fields[19],
                "cmdline": Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")[:-1]}
    except (OSError, IndexError, ValueError):
        return None


def capture_process(process):
    identity = process_identity(process.pid)
    require(identity is not None, "new process exited before ownership could be recorded")
    return {"pid": identity["pid"], "start_ticks": identity["start_ticks"]}


def socket_live(path):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(1)
        try:
            client.connect(str(path))
            return True
        except (FileNotFoundError, ConnectionRefusedError):
            return False


def process_owned(receipt, argument):
    identity = process_identity(receipt.get("pid", -1))
    return bool(identity and identity["start_ticks"] == receipt.get("start_ticks")
                and os.fsencode(argument) in identity["cmdline"])


def command(argv, env=None, timeout=30):
    completed = subprocess.run(argv, cwd=REPO, env=env, text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=timeout, check=False)
    require(completed.returncode == 0,
            f"{argv[0]} failed ({completed.returncode}): {completed.stderr.strip()[:1200]}")
    return completed.stdout.strip()


def recent_log(path):
    """Read a bounded command-log tail for failure diagnostics."""
    with Path(path).open("rb") as stream:
        stream.seek(0, os.SEEK_END)
        stream.seek(max(0, stream.tell() - 8192))
        return "\n".join(stream.read().decode("utf-8", errors="replace").splitlines()[-20:])


class Launcher:
    def __init__(self, args):
        self.args = args
        self.env_file = Path(args.env_file).expanduser().resolve(strict=True)
        self.config = PREFLIGHT_MODULE.read_config(self.env_file)
        self.root = Path(self.config["root"])
        self.plan = PREFLIGHT_MODULE.daemon_plan(self.config)
        self.state_path = self.root / "owner.json"
        self.state = None
        self.output = None
        self.env = None
        self.lock_fd = None
        self.cleanup_on_error = False

    def lock(self):
        require(os.geteuid() == 0, "start, run, exec, and stop require root")
        name = hashlib.sha256(os.fsencode(self.root)).hexdigest()[:24]
        path = Path("/run/lock") / ("mylocalton-ram-" + name + ".lock")
        self.lock_fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise LauncherError("another RAM launcher operation is active for this root") from error

    def prepare_output(self):
        require(self.args.output, "--output is required for start, run, and stop")
        target = Path(self.args.output).expanduser().absolute()
        require(target.resolve() == target, "output and its parents must not be symlinks")
        require(not target.is_relative_to(self.root), "persistent --output must be outside the RAM root")
        require(not target.exists(), "--output must be a new directory; existing evidence is never overwritten")
        target.mkdir(mode=0o700, parents=True, exist_ok=False)
        self.output = target
        filesystem = json.loads(command(["findmnt", "--json", "--target", str(target),
                                         "--output", "FSTYPE,TARGET"]))["filesystems"][0]
        require(filesystem.get("fstype") not in ("tmpfs", "ramfs"),
                "--output must be on a persistent filesystem")
        write_json(target / "invocation.json", {"schema": "native-physical-ram-invocation-v1",
            "at": utc(), "command": self.args.action, "env_file": str(self.env_file),
            "env_sha256": self.config["env_sha256"], "ram_root": str(self.root)})

    def preflight(self, mounted=False):
        argv = [sys.executable, "-B", str(PREFLIGHT), "--env-file", str(self.env_file)]
        if self.args.docker_context:
            argv += ["--docker-context", self.args.docker_context]
        if mounted:
            argv += ["--require-mounted"]
        result = subprocess.run(argv, cwd=REPO, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, check=False, timeout=150)
        report = json.loads(result.stdout)
        if self.output:
            write_json(self.output / ("preflight-mounted.json" if mounted else "preflight.json"), report)
        if self.args.action == "check":
            print(json.dumps(report, indent=2))
        require(result.returncode == 0 and report.get("valid") is True,
                "preflight rejected: " + "; ".join(report.get("errors", [])))
        return report

    def save_state(self):
        write_json(self.state_path, self.state)

    def restore_state_storage(self):
        """Recreate launcher metadata removed from an otherwise live mount."""
        receipts = self.root / "receipts"
        require(not receipts.is_symlink(), "RAM receipts path must not be a symlink")
        receipts.mkdir(mode=0o700, exist_ok=True)
        require(receipts.is_dir(), "RAM receipts path is not a directory")
        require(not self.state_path.is_symlink(), "RAM ownership path must not be a symlink")
        self.save_state()

    def mount_check(self):
        # Cleanup and evidence export remain possible after the free-space guard
        # trips. Live admission thresholds belong to preflight and the guard.
        record = PREFLIGHT_MODULE.check_mount(self.config, True, check_capacity=False)
        require(not record.get("errors"), "RAM mount verification failed: " + "; ".join(record.get("errors", [])))
        require(self.root.stat().st_uid == 0 and self.root.stat().st_mode & 0o777 == 0o700,
                "RAM root must be root-owned with mode 0700")
        if self.state:
            require(self.root.stat().st_dev == self.state["mount_device"], "RAM mount identity changed")

    def load_state(self, immutable=True, ready=False, owner_evidence=None):
        require(os.geteuid() == 0, "start, run, exec, and stop require root")
        self.mount_check()
        source = self.state_path
        if owner_evidence:
            require(not self.state_path.exists() and not self.state_path.is_symlink(),
                    "in-RAM ownership receipt exists; omit --owner-evidence and use the current receipt")
            source = Path(owner_evidence).expanduser().absolute()
            require(source.resolve() == source and not source.is_relative_to(self.root),
                    "external ownership evidence and its parents must not be symlinks or reside in the RAM root")
        require(source.is_file() and not source.is_symlink(), "launcher ownership receipt missing")
        self.state = json.loads(source.read_text())
        require(self.state.get("schema") == "native-physical-ram-owner-v1"
                and self.state.get("root") == str(self.root), "invalid launcher ownership receipt")
        self.mount_check()
        if ready:
            require(self.state.get("phase") in ("ready", "measured"),
                    f"RAM experiment is not ready (phase: {self.state.get('phase', 'unknown')}). "
                    "run/exec require a completed start. Inspect the original start output; "
                    "use stop with a new --output directory, then follow the fresh-start "
                    "recovery steps in benchmark/physical-ram.md.")
        if immutable:
            require(self.state["env_sha256"] == self.config["env_sha256"],
                    "environment changed since start; stop and prepare a separate experiment")
            for name, expected in self.state["harness_sha256"].items():
                require(digest(REPO / name) == expected, "harness changed since start: " + name)
        self.env = private_environment(self.plan["docker_host"], self.root / "tmp", self.state["project"])
        self.reject_profile_overrides()

    def reject_profile_overrides(self):
        # Compose lets the caller's shell override .env. Remove each explicitly
        # declared key so the selected, hashed profile is authoritative.
        keys = re.findall(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=", self.env_file.read_text(), re.M)
        compose_text = (REPO / "docker-compose.yaml").read_text()
        keys += re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)", compose_text)
        keys += re.findall(r"^\s+-\s+([A-Z_][A-Z0-9_]*)\s*(?:#.*)?$", compose_text, re.M)
        for key in set(keys):
            if key not in ("COMPOSE_PROJECT_NAME", "COMPOSE_PROFILES"):
                self.env.pop(key, None)

    def docker(self, *argv, timeout=30):
        return command(["docker", "--host", self.plan["docker_host"], *argv], self.env, timeout)

    def verify_daemon(self):
        require(process_owned(self.state["containerd"], self.plan["containerd_paths"]["config"]),
                "owned containerd process is unavailable or its identity changed")
        require(digest(self.plan["containerd_paths"]["config"]) == self.state["containerd_config_sha256"],
                "private containerd configuration changed")
        require(process_owned(self.state["dockerd"], self.plan["paths"]["daemon_config"]),
                "owned Docker daemon process is unavailable or its identity changed")
        require(digest(self.plan["paths"]["daemon_config"]) == self.state["daemon_config_sha256"],
                "private Docker daemon configuration changed")
        info = json.loads(self.docker("info", "--format", "{{json .}}"))
        require(info.get("ID") == self.state.get("daemon_id"), "private Docker daemon ID changed")
        require(info.get("DockerRootDir") == str(self.root / "data") and info.get("Driver") == "vfs",
                "private daemon no longer uses RAM data-root with vfs")
        self.mount_check()
        return info

    def guard_check(self):
        require(not (self.root / "guard-tripped.json").exists(),
                "RAM resource guard tripped; inspect guard-tripped.json and retained partial evidence")
        receipt = self.state.get("guard")
        if receipt:
            require(process_owned(receipt, str(GUARD)), "RAM guard exited; workload cannot continue unguarded")

    def monitored(self, argv, log_name, timeout, *, progress_path=None, phase_timeouts=None):
        self.guard_check()
        destination = self.root / "logs" / log_name
        started = time.monotonic()
        phase_deadline = BenchmarkDeadline(progress_path, phase_timeouts, started) if phase_timeouts else None
        next_progress = started + 30
        last_stage = None
        print(f"Running {log_name}; live log: {destination}", flush=True)
        with destination.open("ab", buffering=0) as log:
            child = subprocess.Popen(argv, cwd=REPO, env=self.env, stdout=log,
                                     stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + timeout
            try:
                while child.poll() is None:
                    self.guard_check()
                    now = time.monotonic()
                    if phase_deadline:
                        phase_deadline.refresh(now)
                        phase_deadline.check(now, log_name, destination)
                    require(now < deadline,
                            f"{log_name} timed out after {timeout} seconds; see {destination}")
                    stage = (phase_deadline.phase, phase_deadline.detail) if phase_deadline else None
                    if now >= next_progress or stage != last_stage:
                        progress = "; " + phase_deadline.describe(now) if phase_deadline else ""
                        print(f"{log_name}: running for {int(now - started)} seconds{progress}; resource guard active", flush=True)
                        next_progress, last_stage = now + 30, stage
                    time.sleep(2)
                self.guard_check()
                require(child.returncode == 0, f"command failed ({child.returncode}); see {destination}")
                print(f"Completed {log_name} in {int(time.monotonic() - started)} seconds", flush=True)
            except BaseException:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        child.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait(timeout=10)
                try:
                    tail = recent_log(destination)
                    if tail:
                        print(f"Last command output from {destination}:\n{tail}", file=sys.stderr, flush=True)
                except OSError:
                    pass
                raise

    def compose(self, *argv):
        return ["docker", "compose", "--project-directory", str(REPO),
                "-f", str(REPO / "docker-compose.yaml"), "--env-file", str(self.env_file),
                "--project-name", self.state["project"], "--profile", "native-load-generator",
                "--profile", "session-stats", *argv]

    def service_config(self):
        config = json.loads(command(self.compose("config", "--format", "json"), self.env))
        network = config.get("networks", {}).get("main", {})
        expected_subnet = self.config["network_prefix"] + ".0/24"
        require(network.get("driver") == "bridge" and not network.get("external")
                and network.get("driver_opts", {}).get("com.docker.network.bridge.name") == "tonram1"
                and network.get("ipam", {}).get("config") == [{"subnet": expected_subnet}],
                "RAM Compose network must match the checked subnet " + expected_subnet
                + " and use the owned MLT_NETWORK_BRIDGE=tonram1")
        require(config["services"]["genesis"].get("environment", {}).get("NATIVE_RAM_ENABLED") in ("1", 1),
                "genesis must enable NATIVE_RAM_ENABLED=1")
        for name in SERVICES:
            item = config["services"][name]
            require(set(item.get("networks", {})) == {"main"} and not item.get("network_mode"),
                    name + " must use only the checked RAM Compose network")
            memory = int(item.get("deploy", {}).get("resources", {}).get("limits", {}).get("memory") or 0)
            require(memory > 0 and int(item.get("memswap_limit") or 0) == memory,
                    name + " profile must configure equal positive memory and memswap_limit")
            for volume in item.get("volumes", []):
                if volume.get("type") == "bind":
                    source = Path(volume.get("source", "")).resolve()
                    allowed = {"/hostfs": self.root, "/docker-volumes": self.root / "data/volumes"}
                    require(name == "session-stats" and volume.get("read_only") is True
                            and source == allowed.get(volume.get("target")), name + " has an unexpected stats bind")
                    continue
                require(volume.get("type") == "volume", name + " has an unsupported mount")
                declared = config.get("volumes", {}).get(volume.get("source"), {})
                require(not declared.get("external") and not declared.get("driver_opts"),
                        name + " has an external or redirected volume")
        frozen = self.root / "receipts/compose-config.json"
        if self.state.get("phase") in ("ready", "measured"):
            require(json.loads(frozen.read_text()) == config, "rendered Compose configuration changed since startup")
        return config

    def start(self):
        require(os.geteuid() == 0, "start requires root; run with sudo")
        report = self.preflight()
        self.root.mkdir(mode=0o700, parents=False, exist_ok=True)
        require(not any(self.root.iterdir()) and not os.path.ismount(self.root), "RAM root is no longer an empty unmounted directory")
        os.chmod(self.root, 0o700)
        command(self.plan["mount_argv"], timeout=30)
        self.preflight(mounted=True)
        for child in ("data", "exec", "tmp", "logs", "results", "receipts", "client", "containerd-data", "containerd-state"):
            (self.root / child).mkdir(mode=0o700)
        project = profile_literal(self.env_file, "COMPOSE_PROJECT_NAME")
        require(re.fullmatch(r"[a-z0-9][a-z0-9_-]*", project), "invalid Compose project in profile")
        token = uuid.uuid4().hex
        harness = ["docker-compose.yaml", "prepare-native-images.sh", "run-native-benchmark.sh",
                   "benchmark/physical-ram-docker.py", "benchmark/physical-ram-preflight.py",
                   "benchmark/physical-ram-guard.py", "benchmark/physical-ram-firewall.py",
                   "benchmark/physical-ram-mount.py"]
        self.state = {"schema": "native-physical-ram-owner-v1", "at": utc(), "token": token,
                      "project": project, "root": str(self.root), "mount_device": self.root.stat().st_dev,
                      "env_sha256": self.config["env_sha256"], "env_file": str(self.env_file),
                      "harness_sha256": {name: digest(REPO / name) for name in harness},
                      "original_docker": report["original_docker"], "phase": "mounted"}
        self.cleanup_on_error = True
        self.save_state()
        shutil.copyfile(self.env_file, self.root / "receipts/profile.env")
        write_json(self.root / "receipts/preflight.json", report)
        write_json(self.plan["paths"]["daemon_config"], self.plan["daemon_config"])
        self.state["daemon_config_sha256"] = digest(self.plan["paths"]["daemon_config"])
        self.env = private_environment(self.plan["docker_host"], self.root / "tmp", project)
        self.reject_profile_overrides()
        bridge = self.plan["bridge"]
        command(["ip", "link", "add", bridge["name"], "type", "bridge"])
        self.state["bridge"] = {**bridge, "ifindex": int(Path("/sys/class/net", bridge["name"], "ifindex").read_text())}
        self.save_state()
        command(["ip", "addr", "add", bridge["address"], "dev", bridge["name"]])
        command(["ip", "link", "set", bridge["name"], "up"])
        self.state["firewall"] = FIREWALL_MODULE.plan(self.plan["compose_bridge"]["subnet"],
            self.config["planned_ipv4_networks"][1], token)
        self.save_state()
        # Persist ownership before the first rule and after each created chain
        # so a failed startup can remove exactly its partial firewall setup.
        FIREWALL_MODULE.install(self.state["firewall"], persist=self.save_state)
        daemon_environment = dict(self.env, **self.plan["environment"])
        containerd_config = Path(self.plan["containerd_paths"]["config"])
        containerd_config.write_text(self.plan["containerd_config"])
        containerd_config.chmod(0o600)
        self.state["containerd_config_sha256"] = digest(containerd_config)
        with open(self.plan["containerd_paths"]["log"], "ab", buffering=0) as log:
            containerd = subprocess.Popen(self.plan["containerd_argv"], env=daemon_environment, cwd=self.root,
                                          stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        self.state["containerd"] = capture_process(containerd)
        self.save_state()
        deadline = time.monotonic() + 45
        while not socket_live(self.plan["containerd_paths"]["socket"]):
            require(containerd.poll() is None, "private containerd exited; inspect retained containerd.log")
            require(time.monotonic() < deadline, "private containerd did not become ready within 45 seconds")
            time.sleep(1)
        with open(self.plan["paths"]["log_file"], "ab", buffering=0) as log:
            child = subprocess.Popen(self.plan["dockerd_argv"], env=daemon_environment, cwd=self.root,
                                     stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        self.state["dockerd"] = capture_process(child)
        self.save_state()
        deadline = time.monotonic() + 90
        while True:
            require(child.poll() is None, "private dockerd exited; inspect retained dockerd.log")
            try:
                info = json.loads(self.docker("info", "--format", "{{json .}}", timeout=3))
                break
            except (LauncherError, subprocess.TimeoutExpired):
                require(time.monotonic() < deadline, "private dockerd did not become ready within 90 seconds")
                time.sleep(2)
        require(info.get("ID"), "private daemon returned no immutable ID")
        self.state["daemon_id"] = info["ID"]
        self.save_state()
        self.verify_daemon()
        with (self.root / "logs/guard-process.log").open("ab", buffering=0) as log:
            guard = subprocess.Popen([sys.executable, "-B", str(GUARD), "--root", str(self.root),
                "--docker-host", self.plan["docker_host"], "--daemon-id", info["ID"],
                "--project", project, "--reserve-gib", str(self.config["host_reserve_gib"]),
                "--min-free-gib", str(self.config["min_free_gib"])],
                cwd=self.root, env=self.env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        self.state["guard"] = capture_process(guard)
        self.save_state()
        deadline = time.monotonic() + 30
        while not (self.root / "guard-ready.json").exists():
            self.guard_check()
            require(time.monotonic() < deadline, "RAM guard did not become ready within 30 seconds")
            time.sleep(1)
        config = self.service_config()
        write_json(self.root / "receipts/compose-config.json", config)
        self.monitored(["bash", str(REPO / "prepare-native-images.sh"), "--env-file", str(self.env_file),
                        "--receipt", str(self.root / "receipts/native-images.json")], "prepare-images.log", 7500)
        self.monitored(self.compose("pull", "session-stats"), "pull-stats.log", 1800)
        self.state["images"] = {}
        for service in SERVICES:
            image = json.loads(self.docker("image", "inspect", config["services"][service]["image"]))[0]
            self.state["images"][service] = {"reference": config["services"][service]["image"], "id": image["Id"]}
        self.save_state()
        write_json(self.root / "receipts/frozen-images.json", self.state["images"])
        self.smoke()
        self.start_services()
        self.state["phase"] = "ready"
        self.save_state()
        self.capture_runtime("startup")
        self.export()
        print(f"RAM genesis is healthy. Private Docker: {self.plan['docker_host']}. Guard remains active. Evidence: {self.output}")

    def start_services(self):
        bootstrap = int(profile_literal(self.env_file, "NATIVE_RAM_BOOTSTRAP_TIMEOUT_SECONDS"))
        require(60 <= bootstrap <= 10800, "NATIVE_RAM_BOOTSTRAP_TIMEOUT_SECONDS must be within 60..10800")
        self.state["phase"] = "starting_genesis"
        self.save_state()
        # --no-deps still retains health dependencies between explicitly named
        # services. Start genesis alone so Compose cannot wait for its health
        # inside the shorter container-start timeout on behalf of session-stats.
        self.monitored(self.compose("up", "-d", "--no-deps", "--no-build", "--pull", "never",
                                    "genesis"), "start-genesis.log", 300)
        self.state["phase"] = "bootstrapping"
        self.save_state()
        deadline = time.monotonic() + bootstrap
        bootstrap_started = time.monotonic()
        next_progress = bootstrap_started
        while True:
            self.guard_check()
            genesis = self.inspect_service("genesis")
            require(genesis["State"].get("Running") and not genesis["State"].get("OOMKilled"), "genesis stopped during bootstrap")
            if genesis["State"].get("Health", {}).get("Status") == "healthy":
                break
            if time.monotonic() >= next_progress:
                print(f"Genesis bootstrap: {int(time.monotonic() - bootstrap_started)} seconds; "
                      f"health={genesis['State'].get('Health', {}).get('Status', 'unknown')}; "
                      "fresh wallet/zero-state preparation may take tens of minutes", flush=True)
                next_progress = time.monotonic() + 30
            require(time.monotonic() < deadline, f"genesis did not become healthy within {bootstrap} seconds")
            time.sleep(5)
        self.state["genesis_id"] = genesis["Id"]
        self.state["genesis_started_at"] = genesis["State"]["StartedAt"]
        self.state["phase"] = "starting_session_stats"
        self.save_state()
        self.monitored(self.compose("up", "-d", "--no-deps", "--no-build", "--pull", "never",
                                    "session-stats"), "start-session-stats.log", 300)
        stats = self.inspect_service("session-stats")
        require(stats["State"].get("Running") and not stats["State"].get("OOMKilled"),
                "session-stats stopped during startup")
        current = self.inspect_service("genesis")
        require(current["Id"] == self.state["genesis_id"]
                and current["State"]["StartedAt"] == self.state["genesis_started_at"]
                and current["State"].get("Running") and not current["State"].get("OOMKilled")
                and current["State"].get("Health", {}).get("Status") == "healthy",
                "genesis identity, start time, or health changed while starting session-stats")

    def inspect_service(self, service):
        rows = json.loads(self.docker("inspect", service))
        require(len(rows) == 1, "expected one " + service)
        row = rows[0]
        labels = row.get("Config", {}).get("Labels") or {}
        require(labels.get("com.docker.compose.project") == self.state["project"]
                and labels.get("com.docker.compose.service") == service
                and HEX_ID.fullmatch(row.get("Id", "")), "container ownership mismatch: " + service)
        memory = row.get("HostConfig", {}).get("Memory", 0)
        require(memory > 0 and row["HostConfig"].get("MemorySwap") == memory,
                service + " must have positive equal Memory and MemorySwap limits to prohibit heap swap")
        require(row.get("Image") == self.state["images"][service]["id"], "container image changed: " + service)
        for mount in row.get("Mounts", []):
            source = Path(mount.get("Source", ""))
            require(source.is_absolute() and source.resolve().is_relative_to(self.root),
                    service + " has storage outside the RAM mount: " + str(source))
        return row

    def smoke(self):
        """Verify real rootfs+volume+tmpfs writes and TCP/UDP network forwarding."""
        token = self.state["token"]
        label = "org.mylocalton.ram-smoke=" + token
        volume = "ram-smoke-" + token
        image = self.state["images"]["genesis"]["id"]
        server = None
        proof = None
        self.docker("volume", "create", "--label", label, volume)
        script = '''import ctypes,http.server,json,os,socket,sys,threading
token=sys.argv[1]
libc=ctypes.CDLL(None,use_errno=True)
proof={"token":token,"filesystem_checks":[]}
for directory in ("/", "/probe", "/tmp"):
    buf=ctypes.create_string_buffer(256)
    assert libc.statfs(directory.encode(),buf)==0
    magic=ctypes.c_long.from_buffer(buf).value
    assert magic==0x01021994,(directory,magic)
    path=os.path.join(directory,"ram-smoke-"+token)
    with open(path,"wb") as f:
        f.write(token.encode()*1024); f.flush(); os.fsync(f.fileno())
    assert open(path,"rb").read()==token.encode()*1024
    os.unlink(path)
    proof["filesystem_checks"].append({"path":directory,"magic":magic,"write_fsync_read":True})
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data=json.dumps(proof).encode(); self.send_response(200); self.end_headers(); self.wfile.write(data)
    def log_message(self,*args): pass
def udp():
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(("0.0.0.0",18081))
    while True:
        data,address=s.recvfrom(1024);s.sendto(data,address)
threading.Thread(target=udp,daemon=True).start()
http.server.HTTPServer(("0.0.0.0",18080),Handler).serve_forever()
'''
        try:
            server = self.docker("run", "-d", "--label", label, "--network", "bridge", "--cpus", "0.5",
                "--memory", "256m", "--memory-swap", "256m", "--mount", f"type=volume,source={volume},target=/probe",
                "--publish", "127.0.0.1:8888:18080/tcp", "--publish", "127.0.0.1:41001:18081/udp",
                "--entrypoint", "python3", image, "-uc", script, token)
            require(HEX_ID.fullmatch(server), "smoke container returned an invalid ID")
            deadline = time.monotonic() + 30
            while proof is None:
                self.guard_check()
                try:
                    with urllib.request.urlopen("http://127.0.0.1:8888", timeout=2) as response:
                        proof = json.load(response)
                except OSError:
                    require(time.monotonic() < deadline, "RAM smoke HTTP publication failed")
                    time.sleep(1)
            require(proof.get("token") == token, "published HTTP port reached the wrong container")
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                client.settimeout(3)
                client.sendto(token.encode(), ("127.0.0.1", 41001))
                require(client.recv(1024) == token.encode(), "published UDP echo failed")
            inspect = json.loads(self.docker("inspect", server))[0]
            address = inspect["NetworkSettings"]["Networks"]["bridge"]["IPAddress"]
            client_script = '''import json,socket,sys,urllib.request
host,token=sys.argv[1:]
assert json.load(urllib.request.urlopen("http://"+host+":18080",timeout=5))["token"]==token
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(5)
s.sendto(token.encode(),(host,18081));assert s.recv(1024)==token.encode()
print("container TCP/UDP passed")
'''
            self.docker("run", "--rm", "--label", label, "--network", "bridge", "--cpus", "0.5",
                        "--memory", "128m", "--memory-swap", "128m", "--entrypoint", "python3", image,
                        "-c", client_script, address, token, timeout=30)
            proof.update(container_id=server, host_tcp=True, host_udp=True, container_tcp=True, container_udp=True,
                         image_id=image, at=utc())
            write_json(self.root / "receipts/storage-network-smoke.json", proof)
        finally:
            if server and HEX_ID.fullmatch(server):
                rows = json.loads(self.docker("inspect", server))
                require(rows[0]["Config"].get("Labels", {}).get("org.mylocalton.ram-smoke") == token,
                        "refusing smoke cleanup after ownership change")
                self.docker("rm", "--force", server, timeout=60)
            owned = json.loads(self.docker("volume", "inspect", volume))[0]
            require(owned.get("Labels", {}).get("org.mylocalton.ram-smoke") == token, "smoke volume ownership changed")
            self.docker("volume", "rm", volume)

    def capture_runtime(self, prefix):
        rows = []
        for service in SERVICES:
            try:
                row = self.inspect_service(service)
                rows.append(row)
                with (self.root / "logs" / (prefix + "-" + service + ".log")).open("wb") as log:
                    completed = subprocess.run(["docker", "--host", self.plan["docker_host"], "logs", "--timestamps", row["Id"]],
                        cwd=REPO, env=self.env, stdout=log, stderr=subprocess.STDOUT, timeout=60, check=False)
                    require(completed.returncode == 0, "log export failed: " + service)
            except LauncherError as error:
                rows.append({"service": service, "capture_error": str(error)})
        write_json(self.root / "receipts" / (prefix + "-containers.json"), rows)

    def verify_images(self):
        for service, receipt in self.state["images"].items():
            actual = json.loads(self.docker("image", "inspect", receipt["reference"]))[0]
            require(actual["Id"] == receipt["id"], "frozen image changed: " + service)

    def run(self):
        self.load_state(ready=True)
        self.verify_daemon()
        self.guard_check()
        self.verify_images()
        config = self.service_config()
        settings = config["services"]["native-load-generator"]["environment"]
        budgets = benchmark_time_budgets(self.env_file, settings)
        genesis = self.inspect_service("genesis")
        require(genesis["Id"] == self.state["genesis_id"]
                and genesis["State"]["StartedAt"] == self.state["genesis_started_at"]
                and genesis["State"].get("Health", {}).get("Status") == "healthy", "genesis identity, start time, or health changed")
        run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
        result = self.root / "results" / run_id
        write_json(self.root / "receipts" / (run_id + "-time-budgets.json"), budgets)
        print("Benchmark phase limits (seconds): " + json.dumps(budgets["phase_seconds"], sort_keys=True), flush=True)
        self.env.update(BENCHMARK_COMPOSE_PROJECT=self.state["project"], BENCHMARK_IMAGES_PREBUILT="1",
                        BENCHMARK_STRICT_IMAGE_REUSE="1", BENCHMARK_STRICT_GENESIS_REUSE="1")
        self.cleanup_on_error = True
        self.monitored(["bash", str(REPO / "run-native-benchmark.sh"), str(self.env_file), str(result)],
                       run_id + "-benchmark.log", budgets["total_seconds"],
                       progress_path=result / "benchmark-progress.json", phase_timeouts=budgets["phase_seconds"])
        self.verify_daemon()
        self.verify_images()
        self.inspect_service("native-load-generator")
        self.state.update(phase="measured", last_result=str(result))
        self.save_state()
        self.capture_runtime(run_id)
        self.export()
        print(f"Benchmark finished; inspect canonical acceptance in {self.output}. No TPS gain is inferred automatically.")

    def export(self):
        if not self.output or not self.state or not self.root.is_dir():
            return
        self.mount_check()
        target = self.output / "ram-evidence"
        require(not target.exists(), "RAM evidence export destination already exists")
        target.mkdir(mode=0o700)
        for name in ("owner.json", "daemon.json", "dockerd.log", "containerd.toml", "containerd.log", "guard.log", "guard-tripped.json",
                     "guard-ready.json", "guard-finished.json", "guard.stop", "logs", "receipts", "results"):
            source = self.root / name
            if source.is_dir():
                shutil.copytree(source, target / name, symlinks=True)
            elif source.is_file() and not source.is_symlink():
                shutil.copyfile(source, target / name)
        write_json(self.output / "export.json", {"at": utc(), "root": str(self.root), "phase": self.state.get("phase"),
            "private_daemon_id": self.state.get("daemon_id"), "database_exported": False,
            "mount_retained": True, "note": "Evidence only; database and images remain on volatile RAM mount."})

    def stop_containers(self):
        stopped = []
        ids = self.docker("ps", "--all", "--quiet", "--no-trunc", "--filter", "label=com.docker.compose.project=" + self.state["project"]).split()
        rows = json.loads(self.docker("inspect", *ids)) if ids else []
        for service in SERVICES:
            for row in rows:
                labels = row.get("Config", {}).get("Labels") or {}
                if labels.get("com.docker.compose.service") != service:
                    continue
                require(labels.get("com.docker.compose.project") == self.state["project"] and HEX_ID.fullmatch(row["Id"]),
                        "refusing container stop without exact ownership")
                current = json.loads(self.docker("inspect", row["Id"]))[0]
                require(current["Config"]["Labels"] == row["Config"]["Labels"], "container ownership changed before stop")
                if current["State"].get("Running"):
                    self.docker("stop", "--timeout", "30", row["Id"], timeout=40)
                stopped.append(json.loads(self.docker("inspect", row["Id"]))[0])
        write_json(self.root / "receipts/stopped-containers.json", stopped)

    def stop_runtime(self):
        if self.state.get("daemon_id") and process_owned(self.state.get("dockerd", {}), self.plan["paths"]["daemon_config"]):
            configs_available = (Path(self.plan["paths"]["daemon_config"]).is_file()
                                 and Path(self.plan["containerd_paths"]["config"]).is_file())
            if configs_available:
                self.verify_daemon()
                self.stop_containers()
                self.capture_runtime("stopped")
                self.remove_owned_containers_and_networks()
            else:
                print("RAM runtime metadata was deleted; stopping only processes whose recorded PID, start time, and command still match.",
                      flush=True)
        self.stop_processes()

    def mount_report(self):
        return MOUNT_MODULE.inspect_mount(self.root)

    @staticmethod
    def mount_blockers(report):
        parts = []
        if report.get("stacked_root_mounts"):
            parts.append(f"{len(report['stacked_root_mounts'])} stacked root mount(s)")
        if report.get("nested_mounts"):
            paths = [item["mountpoint"] for item in report["nested_mounts"][:3]]
            parts.append("nested mount(s): " + ", ".join(paths))
        if report.get("holders"):
            labels = [f"pid {item['pid']} ({item['name']})" for item in report["holders"][:5]]
            parts.append("process holder(s): " + ", ".join(labels))
        if report.get("errors"):
            parts.append("incomplete diagnostics: " + "; ".join(report["errors"][:3]))
        return "; ".join(parts) or "the kernel rejected the unmount without a visible holder"

    def discard_and_unmount(self, report):
        require(report.get("mounted") is True, "RAM root is not mounted")
        require(report.get("unmount_ready") is True,
                "RAM mount is still busy: " + self.mount_blockers(report))
        completed = subprocess.run(["umount", "--", str(self.root)], cwd=REPO, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=False)
        receipt = {"schema": "native-physical-ram-unmount-v1", "at": utc(),
                   "root": str(self.root), "discarded": completed.returncode == 0,
                   "returncode": completed.returncode, "stderr": completed.stderr.strip()[:1200],
                   "pre_unmount": report}
        write_json(self.output / "unmount.json", receipt)
        require(completed.returncode == 0,
                "umount failed after a clean holder scan: " + (receipt["stderr"] or "no diagnostic"))
        require(not os.path.ismount(self.root), "umount returned success but the RAM root remains mounted")
        export_path = self.output / "export.json"
        if export_path.is_file() and not export_path.is_symlink():
            exported = json.loads(export_path.read_text())
            exported.update(mount_retained=False, unmounted_at=utc(),
                            note="Evidence exported before the explicitly requested volatile RAM unmount.")
            write_json(export_path, exported)

    def stop(self):
        self.load_state(immutable=False, owner_evidence=self.args.owner_evidence)
        if self.args.owner_evidence:
            self.restore_state_storage()
        self.cleanup_on_error = True
        self.stop_runtime()
        self.state["phase"] = "stopped"
        self.save_state()
        report = self.mount_report()
        self.state["post_stop_unmount_ready"] = report["unmount_ready"]
        self.save_state()
        write_json(self.root / "receipts/post-stop-mount.json", report)
        self.export()
        if self.args.discard_and_unmount:
            self.cleanup_on_error = False
            self.discard_and_unmount(report)
            print(f"Owned RAM Docker stopped, evidence exported to {self.output}, and volatile RAM data unmounted.")
        else:
            status = "no unmount blockers detected" if report["unmount_ready"] else self.mount_blockers(report)
            print(f"Owned RAM Docker stopped; evidence exported to {self.output}. RAM data remains mounted at {self.root}; {status}.")

    def recover_unmount(self):
        require(self.args.owner_evidence, "recover-unmount requires --owner-evidence from a prior persistent RAM export")
        self.load_state(immutable=False, owner_evidence=self.args.owner_evidence)
        self.restore_state_storage()
        self.cleanup_on_error = False
        self.stop_runtime()
        self.state["phase"] = "recovered_stopped"
        self.save_state()
        report = self.mount_report()
        write_json(self.output / "mount-diagnostic.json", report)
        write_json(self.output / "recovery.json", {"schema": "native-physical-ram-recovery-v1",
                   "at": utc(), "root": str(self.root), "owner_evidence": str(Path(self.args.owner_evidence).absolute()),
                   "mount_device": self.state["mount_device"], "unmount_ready": report["unmount_ready"],
                   "next_action_if_busy": "Resolve only the reported holder, then run normal stop --discard-and-unmount with a new output; ownership is restored."})
        try:
            self.discard_and_unmount(report)
        except LauncherError as error:
            raise LauncherError(str(error) +
                "; ownership is restored; after resolving the reported blocker, run normal stop --discard-and-unmount with a new output") from error
        print(f"Recovered exact launcher ownership and unmounted discarded RAM data at {self.root}; evidence: {self.output}.")

    def diagnose(self):
        require(os.geteuid() == 0, "diagnose requires root to inspect every process holder")
        report = self.mount_report()
        print(json.dumps(report, indent=2, sort_keys=True))

    def remove_owned_containers_and_networks(self):
        removed = {"containers": [], "networks": [], "volumes_removed": False}
        ids = self.docker("ps", "--all", "--quiet", "--no-trunc", "--filter",
                          "label=com.docker.compose.project=" + self.state["project"]).split()
        for ident in ids:
            row = json.loads(self.docker("inspect", ident))[0]
            labels = row.get("Config", {}).get("Labels") or {}
            require(HEX_ID.fullmatch(ident) and labels.get("com.docker.compose.project") == self.state["project"]
                    and labels.get("com.docker.compose.service") in SERVICES and not row["State"].get("Running"),
                    "refusing removal of an unexpected or running project container")
            self.docker("rm", ident)
            removed["containers"].append(ident)
        ids = self.docker("network", "ls", "--quiet", "--no-trunc", "--filter",
                          "label=com.docker.compose.project=" + self.state["project"]).split()
        for ident in ids:
            row = json.loads(self.docker("network", "inspect", ident))[0]
            require(HEX_ID.fullmatch(ident) and row.get("Labels", {}).get("com.docker.compose.project") == self.state["project"]
                    and not row.get("Containers"), "refusing removal of an occupied or unowned network")
            self.docker("network", "rm", ident)
            removed["networks"].append(ident)
        write_json(self.root / "receipts/removed-runtime.json", removed)

    def stop_processes(self):
        (self.root / "guard.stop").touch(exist_ok=True)
        for name, argument in (("guard", str(GUARD)), ("dockerd", self.plan["paths"]["daemon_config"]),
                               ("containerd", self.plan["containerd_paths"]["config"])):
            receipt = self.state.get(name, {})
            if not process_owned(receipt, argument):
                continue
            if name in ("dockerd", "containerd"):
                os.kill(receipt["pid"], signal.SIGTERM)
            deadline = time.monotonic() + 60
            while process_owned(receipt, argument) and time.monotonic() < deadline:
                time.sleep(1)
            require(not process_owned(receipt, argument), name + " did not stop; RAM data retained, no force kill or unmount attempted")
        bridge = self.state.get("bridge")
        if bridge:
            require(not socket_live(self.plan["paths"]["socket"]),
                    "private Docker socket is still live; refusing to delete a bridge possibly used by a replacement daemon")
            require(not socket_live(self.plan["containerd_paths"]["socket"]),
                    "private containerd socket is still live; refusing bridge cleanup while its ownership is uncertain")
            path = Path("/sys/class/net", bridge["name"], "ifindex")
            if path.exists():
                require(int(path.read_text()) == bridge["ifindex"], "owned bridge identity changed; no bridge removed")
            if self.state.get("firewall"):
                FIREWALL_MODULE.remove(self.state["firewall"], persist=self.save_state)
            if path.exists():
                command(["ip", "link", "delete", bridge["name"], "type", "bridge"])

    def execute(self):
        self.load_state(ready=True)
        self.verify_daemon()
        self.guard_check()
        self.verify_images()
        argv = list(self.args.command)
        if argv and argv[0] == "--":
            argv.pop(0)
        require(argv, "exec requires a command after --")
        # Caller explicitly controls the command, but the selected Docker and
        # Compose defaults always point to the verified isolated daemon.
        return subprocess.run(argv, cwd=REPO, env=self.env, check=False).returncode

    def failure_cleanup(self):
        errors = []
        try:
            if self.state.get("daemon_id"):
                self.verify_daemon()
                self.stop_containers()
                if self.state.get("images"):
                    self.capture_runtime("failure")
                self.remove_owned_containers_and_networks()
        except Exception as error:
            errors.append("runtime cleanup: " + str(error))
        try:
            self.stop_processes()
        except Exception as error:
            errors.append("process cleanup: " + str(error))
        self.state["phase"] = "failed_cleanup_incomplete" if errors else "failed_stopped"
        self.save_state()
        write_json(self.output / "failure-cleanup.json", {"at": utc(), "errors": errors,
                   "phase": self.state["phase"], "mount_retained": True})
        if not (self.output / "ram-evidence").exists():
            self.export()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="action", required=True)
    for action in ("check", "diagnose", "start", "run", "exec", "stop", "recover-unmount"):
        child = subparsers.add_parser(action)
        child.add_argument("--env-file", default=str(REPO / ".env.physical"))
        child.add_argument("--docker-context", help="original native Docker context used only by preflight")
        child.add_argument("--output", help="new persistent evidence directory (required for start/run/stop/recover-unmount)")
        if action == "exec":
            child.add_argument("command", nargs=argparse.REMAINDER)
        if action in ("stop", "recover-unmount"):
            child.add_argument("--owner-evidence",
                               help="external owner.json from a prior persistent ram-evidence export")
        if action == "stop":
            child.add_argument("--discard-and-unmount", action="store_true",
                               help="after exporting evidence, verify no holders and unmount the volatile RAM filesystem")
    args = parser.parse_args(argv)
    launcher = None
    try:
        launcher = Launcher(args)
        if args.action not in ("check", "diagnose"):
            launcher.lock()
        if args.action == "check":
            if args.output:
                launcher.prepare_output()
            launcher.preflight()
        elif args.action == "diagnose":
            launcher.diagnose()
        elif args.action == "exec":
            return launcher.execute()
        elif args.action == "recover-unmount":
            launcher.prepare_output()
            launcher.recover_unmount()
        else:
            launcher.prepare_output()
            getattr(launcher, args.action)()
        return 0
    except (LauncherError, FIREWALL_MODULE.FirewallError, OSError, ValueError, KeyError,
            subprocess.SubprocessError, KeyboardInterrupt) as error:
        print("Error: " + str(error), file=sys.stderr)
        if launcher and launcher.output:
            write_json(launcher.output / "failure.json", {"at": utc(), "action": args.action,
                                                        "error": str(error), "complete": False,
                                                        "phase": (launcher.state or {}).get("phase")})
            if launcher.state and launcher.cleanup_on_error:
                try:
                    launcher.failure_cleanup()
                except Exception as export_error:
                    write_json(launcher.output / "failure-export.json", {"error": str(export_error)})
            print("Partial evidence: " + str(launcher.output), file=sys.stderr)
        return 2
    finally:
        if launcher and launcher.lock_fd is not None:
            os.close(launcher.lock_fd)


if __name__ == "__main__":
    raise SystemExit(main())
