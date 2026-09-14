#!/usr/bin/env python3

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[2] / "docker" / "scripts"


class NativeNodeShutdownTest(unittest.TestCase):
    def test_existing_state_hands_original_pid_and_sigterm_to_engine(self):
        for genesis in ("true", "false"):
            with self.subTest(genesis=genesis), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                scripts = root / "scripts"
                binaries = root / "bin"
                db = root / "db"
                shared = root / "shared"
                smartcont = root / "smartcont"
                for path in (scripts, binaries, db / "state", db / "static", shared / "static", smartcont):
                    path.mkdir(parents=True)
                # Relocate image paths only. Execute the full existing-state
                # startup flow with inert local service binaries; no Docker,
                # network services, real keys, or chain state are needed.
                replacements = {
                    "/scripts": str(scripts),
                    "/usr/local/bin": str(binaries),
                    "/var/ton-work/db": str(db),
                    "/usr/share/data": str(shared),
                    "/usr/share/ton/smartcont": str(smartcont),
                    "/etc/container_env": str(root / "container_env"),
                }
                for name in ("start-node.sh", "start-genesis.sh", "start-validator.sh"):
                    source = (SCRIPTS / name).read_text()
                    for old, new in replacements.items():
                        source = source.replace(old, new)
                    self.write_executable(scripts / name, source)
                for name in (
                    "native-transfer-runs-config.sh",
                    "native-payment-lanes-config.sh",
                    "native-payment-lane-wallets.sh",
                ):
                    shutil.copyfile(SCRIPTS / name, scripts / name)
                for path in (
                    db / "state" / "IDENTITY",
                    db / "global.config.json",
                    db / "localhost.global.config.json",
                    db / "config.json",
                    shared / "static" / "fixture",
                    smartcont / "validator.pk",
                    binaries / "libtonlibjson.so",
                    binaries / "libemulator.so",
                ):
                    path.write_text("fixture\n")
                for name in ("service", "dht-server"):
                    self.write_executable(binaries / name, "#!/bin/sh\nexit 0\n")
                self.write_executable(binaries / "hostname", "#!/bin/sh\necho 127.0.0.1\n")
                self.write_executable(
                    binaries / "validator-engine",
                    f"#!{sys.executable}\n"
                    "import json, os, signal, sys\n"
                    "from pathlib import Path\n"
                    "def stop(signum, frame):\n"
                    "    Path(os.environ['TEST_STOPPED']).write_text(str(signum))\n"
                    "    sys.exit(0)\n"
                    "signal.signal(signal.SIGTERM, stop)\n"
                    "receipt = Path(os.environ['TEST_STARTED'])\n"
                    "pending = receipt.with_suffix('.tmp')\n"
                    "pending.write_text(json.dumps({'pid': os.getpid(), 'args': sys.argv[1:]}))\n"
                    "pending.replace(receipt)\n"
                    "while True:\n"
                    "    signal.pause()\n",
                )
                started = root / "started.json"
                stopped = root / "stopped"
                env = {
                    "PATH": f"{binaries}:{os.environ['PATH']}",
                    "GENESIS": genesis,
                    "GENESIS_IP": "127.0.0.1",
                    "NAME": "validator",
                    "VERBOSITY": "3",
                    "CUSTOM_PARAMETERS": "--threads 7",
                    "TEST_STARTED": str(started),
                    "TEST_STOPPED": str(stopped),
                }
                with (root / "startup.log").open("w+") as log:
                    process = subprocess.Popen(
                        [str(scripts / "start-node.sh")],
                        cwd=root,
                        env=env,
                        stdout=log,
                        stderr=log,
                        start_new_session=True,
                    )
                    try:
                        deadline = time.monotonic() + 5
                        while not started.exists() and process.poll() is None and time.monotonic() < deadline:
                            time.sleep(0.01)
                        log.seek(0)
                        self.assertTrue(started.exists(), log.read())
                        receipt = json.loads(started.read_text())
                        self.assertEqual(receipt["pid"], process.pid, "startup retained a wrapper shell")
                        self.assertEqual(
                            receipt["args"],
                            [
                                "-C", str(db / "global.config.json"),
                                "-v", "3", "--db", str(db),
                                "--ip", "127.0.0.1:40001",
                                "--initial-sync-delay", "0.0", "--threads", "7",
                            ],
                        )
                        process.send_signal(signal.SIGTERM)
                        self.assertEqual(process.wait(timeout=3), 0)
                        self.assertEqual(stopped.read_text(), str(signal.SIGTERM))
                    finally:
                        # Also clean up child processes if a future regression
                        # leaves a wrapper between the launcher and the engine.
                        try:
                            os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        process.wait(timeout=3)

    @staticmethod
    def write_executable(path, content):
        path.write_text(content)
        path.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
