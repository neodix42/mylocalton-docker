# Full RAM storage TPS experiment on a physical server

`.env.physical` now describes a **volatile benchmark**, using a separate Docker
Engine whose entire data directory lives on a bounded `tmpfs,noswap` filesystem.
This puts the validator executable and libraries, image/container filesystems,
CellDb/RocksDB (including WAL and archives), wallets, shared files, Session Stats
SQLite, container temporary files and Docker logs in RAM. The normal generator
JSON log remains available for canonical proof; logging is not disabled.

This is prepared for a native Linux server. **No new RAM-storage TPS result was
measured locally**: the local machine had about 21–22 GiB available, while the
preserved seed database alone contains 33,402,800,611 bytes (31.11 GiB), before
the validator working set and reserve. The local read-only preflight also found
Docker Desktop rather than a host `dockerd`, active unrelated containers and
network conflicts. No local daemon, mount, or container was changed for this
experiment. The preceding in-memory-CellDb results still used persistent disk
storage and are a different treatment.

The [15 September server observation](physical-ram-server-20260915.md) records
the user-reported 56,711.80 canonical TPS measurement. Its generator completed
with proof checks passing, but the enclosing command timed out during finalization;
full wrapper acceptance and a matched disk comparison remain unavailable.

Unrelated containers on the original Docker daemon may remain running. The
launcher records them as background load and rejects actual benchmark port,
subnet and owned-bridge conflicts. It never stops the original daemon or its
containers. Existing production state is
not copied or modified: this workflow creates a fresh test chain. Do not replace
an existing production deployment's `.env` with this volatile profile.

The preset keeps the existing physical server topology: 48 logical CPUs,
44-CPU validator quota, 40 validator scheduler threads, eight payment lanes,
24,576 source accounts, in-memory CellDb and a 16 GiB CellDb cache. Its explicit
local generator uses four CPU quota cores, ten connections, six workers/signers,
16-output signed runs, batching of 64 and 20 ms coalescing. The admission window
starts at 32,768 and is capped at 65,536; canonical backlog is bounded at
2,097,120 outputs. Target zero means unpaced bounded load. Ordinary startup
starts no generator. The measured phases are 60 seconds warmup, 600 seconds load
and up to 180 seconds drain, plus initial nonce discovery/topology readiness.
Server B's remote generator retains its own settings; record which was used.

| RAM budget setting | Default | Meaning |
| --- | ---: | --- |
| `NATIVE_RAM_SIZE_GIB` | 96 GiB | Maximum private Docker filesystem size |
| `NATIVE_RAM_RUNTIME_GIB` | 64 GiB | Additional working-memory budget for planning |
| `NATIVE_RAM_HOST_RESERVE_GIB` | 32 GiB | Host reserve and live guard threshold |
| `NATIVE_RAM_MIN_AVAILABLE_GIB` | 192 GiB | Required available RAM before mounting |
| `NATIVE_RAM_MIN_FREE_GIB` | 16 GiB | Minimum free space inside the RAM filesystem |

A dedicated 256 GiB or larger host is the intended starting point. Installed RAM
alone is insufficient: preflight requires **currently available** RAM of at least
the larger of the configured minimum and `filesystem + runtime + host reserve`.
The filesystem size is a limit, not preallocated or reserved memory. VFS makes
full image/container copies, so image preparation consumes part of that budget.
The guard checks during preparation as well as the benchmark. Container memory
limits are 128 GiB for genesis and 8 GiB each for the local generator and stats;
equal memory-plus-swap limits disable their swap. These per-container ceilings
are not a reservation or permission to exceed the host guard.

Prerequisites are root access, native Linux Docker Engine with `dockerd`,
`containerd` and the Compose plugin, cgroup v2, Python 3.11+, Bash, `ip`, `iptables`,
`mount`, `findmnt`, and the existing benchmark tools including `jq`. IPv4
forwarding must already be enabled (`net.ipv4.ip_forward=1`); the launcher does
not change global forwarding policy. The kernel must accept and report tmpfs `noswap`;
the launcher checks this after mounting and fails if unsupported. Keep the
configured addresses `10.203.1.0/24`, `10.203.2.0/24` and `10.204.0.0/16` free.
Review the existing public port bindings and set the server address for remote
clients as in the normal remote guide.

The existing `mylocalton-network` on `172.28.1.0/24` can stay in place. The RAM
stack uses its own network; Docker networks are not shared across the two
daemons. For an older customized `.env.physical`, add these settings while
preserving your RAM budgets and server settings:

```dotenv
MLT_NETWORK_PREFIX=10.203.1
MLT_NETWORK_NAME=mylocalton-ram-network
MLT_NETWORK_BRIDGE=tonram1
NATIVE_RAM_BRIDGE_CIDR=10.203.2.1/24
NATIVE_RAM_ADDRESS_POOL=10.204.0.0/16
```

If these ranges overlap your host routes, choose three disjoint RFC1918 ranges
and rerun `check`. `MLT_NETWORK_PREFIX` supplies three octets for the Compose
/24; its service addresses and endpoints move together. Keep the bridge names
`tonram0` and `tonram1` reserved for this launcher. Profiles without these
settings retain the ordinary `172.28.1.0/24` Compose network.

From the `MyLocalTonDocker` checkout, use new persistent output directories for
each action. Output paths and their parents must not be symlinks. If your
`benchmark-results` directory is a symlink, substitute its actual absolute
directory (shown by `realpath benchmark-results`) in the commands below.

```bash
# Read-only: prints every rejected prerequisite, without mounting or starting.
sudo python3 benchmark/physical-ram-docker.py check --env-file .env.physical

# Mount RAM, start its private daemon, build/pin images, smoke-test storage and
# networking, then bootstrap fresh genesis and start stats. No load starts here.
sudo python3 benchmark/physical-ram-docker.py start --env-file .env.physical \
  --output benchmark-results/ram-start

# Run the configured ten-minute local TPS test; images and genesis are reused.
sudo python3 benchmark/physical-ram-docker.py run --env-file .env.physical \
  --output benchmark-results/ram-tps

# Save final evidence and stop the owned benchmark/daemon. Retain RAM volumes.
sudo python3 benchmark/physical-ram-docker.py stop --env-file .env.physical \
  --output benchmark-results/ram-stop

# For a fresh cycle, explicitly discard and atomically unmount after export.
sudo python3 benchmark/physical-ram-docker.py stop --env-file .env.physical \
  --discard-and-unmount --output benchmark-results/ram-stop-and-unmount
```

Fresh wallet/zero-state preparation can take tens of minutes. The launcher starts
genesis alone with `--no-deps`, waits for it to become healthy under the resource
guard, then starts Session Stats separately. `NATIVE_RAM_BOOTSTRAP_TIMEOUT_SECONDS`
controls that health wait (default 5,400 seconds, allowed range 60–10,800). Stats
startup does not share a short Compose deadline with genesis bootstrap.
Before declaring startup complete, the launcher also checks that genesis stayed
healthy with the same container and start time while Session Stats was starting.

The launcher prints the live log path and progress every 30 seconds during long
steps. Benchmark progress includes the phase and current operation, such as
`generator/generator_wait` or `reporting/validator_pipeline_report`.
Keep the terminal open and do not start a second setup. Run `run` only after
`start` reports success. `start` and `run` leave the guard active; use `stop` when
finished, including after a failed attempt with retained state.
The read-only `check` applies to a **new** start; after startup, use `exec` for
inspection of the verified private daemon. An ordinary `docker compose` command
can select the original Docker daemon and is not the RAM test. The new validator
wrapper also refuses the RAM profile when its root/image/data filesystem is on
disk, before bootstrap writes keys.

Benchmark execution has separate bounded time budgets, so preparation cannot
consume the reporting allowance. These are upper limits, not added sleeps;
the measurement remains 600 seconds for `.env.physical`.

| Execution phase | Default physical-profile limit | Included work |
| --- | ---: | --- |
| Wrapper setup | 600 s | Configuration, image and runtime checks |
| Generator | 4,440 s | 1,800 s preparation allowance, 1,800 s lane readiness, 60 s warmup, 600 s measurement, 180 s drain |
| Reporting | 1,800 s | Runtime checks, collector shutdown, proof extraction, validator/resource reports and Session Stats |

The launcher saves the exact components in `receipts/<run-id>-time-budgets.json`.
`NATIVE_RAM_WRAPPER_SETUP_TIMEOUT_SECONDS`,
`NATIVE_RAM_GENERATOR_SETUP_TIMEOUT_SECONDS` and
`NATIVE_RAM_REPORT_TIMEOUT_SECONDS` control the three extra allowances; older
customized profiles inherit the defaults if those settings are absent. The
generator limit also includes configured lane readiness, ramp, warmup,
measurement and drain durations. Progress within one phase never renews its
deadline, and the resource guard stays active throughout.

Each benchmark result directory contains an atomic `benchmark-progress.json`
receipt and a `benchmark-progress.jsonl` history. After extracting the generator
log, the wrapper saves `native-load-generator-final.json` and prints its TPS
before the heavier validator/resource reports. That file preserves the generator's
own validity fields, including a false capacity assessment; it does not replace
`benchmark-summary.json` or the wrapper's successful exit and acceptance checks.

`stop` now records `receipts/post-stop-mount.json`. It lists any process whose
working directory, root, executable, open file descriptor or mapped file is
inside the RAM filesystem, as well as stacked or nested mounts. Run the
read-only diagnostic at any time, even if `owner.json` is missing:

```bash
sudo python3 benchmark/physical-ram-docker.py diagnose --env-file .env.physical
```

`--discard-and-unmount` exports evidence first, requires a complete clean holder
scan, then calls `umount` itself. It never kills a process merely because that
process has the mount open. This closes the gap where a successful `stop` could
be followed by an unexplained manual `umount: target is busy`.

If startup fails, its output path is a directory containing evidence, not a text
log. For the reported `start-services.log` timeout, inspect these files from the
original attempt:

```bash
cat benchmark-results/ram-start/failure.json
cat benchmark-results/ram-start/failure-cleanup.json
tail -n 160 benchmark-results/ram-start/ram-evidence/logs/start-services.log
# If genesis was created and its logs were captured:
tail -n 160 benchmark-results/ram-start/ram-evidence/logs/failure-genesis.log
```

`start-services.log` belongs to the earlier combined startup command. The timeout
alone does not establish why startup was slow; the command and genesis logs supply
that evidence. Updated runs use separate `start-genesis.log` and
`start-session-stats.log` in the same exported logs directory. Failure cleanup
attempts to stop the private Docker/containerd processes, so `run` cannot continue
a failed startup. The launcher now reports the failed startup phase before
checking daemon identity, and a rejected `run` preserves the original experiment
state instead of repeating failure cleanup. Command failures include a bounded
tail of the stage log in the terminal; `failure.json` records the failing phase.

After updating the launcher, a fresh retry can use the following sequence. Every
output directory must be new. Keep the original evidence; `stop` exports additional
evidence and stops only the owned RAM runtime. **Unmounting discards the retained
test database and images**; use this step only when choosing a fresh test chain.

```bash
ram_attempt=$(date -u +%Y%m%dT%H%M%S)-$$-$RANDOM
sudo python3 benchmark/physical-ram-docker.py stop --env-file .env.physical \
  --discard-and-unmount --output "benchmark-results/ram-stop-$ram_attempt" &&
sudo python3 benchmark/physical-ram-docker.py start --env-file .env.physical \
  --output "benchmark-results/ram-start-$ram_attempt" &&
sudo python3 benchmark/physical-ram-docker.py run --env-file .env.physical \
  --output "benchmark-results/ram-tps-$ram_attempt"
```

Use your configured `NATIVE_RAM_ROOT` if it differs from `/mnt/mylocalton-ram`.
The saved persistent output directories survive that unmount. Neither cleanup nor
this retry procedure stops unrelated containers on the original Docker daemon.

If an earlier `rm -rf /mnt/mylocalton-ram/` deleted the in-RAM ownership receipt,
the database, images and other files it removed cannot be recovered from the
mount. Do not repeat that command. `recover-unmount` can use the exact
`owner.json` saved by an earlier successful persistent export. It validates the
recorded root and mount device and only signals recorded processes whose PID,
start time and command still match; visible third-party holders cause a refusal.

```bash
ram_recovery=$(date -u +%Y%m%dT%H%M%S)-$$-$RANDOM
sudo python3 benchmark/physical-ram-docker.py recover-unmount \
  --env-file .env.physical \
  --owner-evidence "$(realpath benchmark-results/ram-stop-6/ram-evidence/owner.json)" \
  --output "benchmark-results/ram-recover-$ram_recovery"
```

If it refuses, inspect `mount-diagnostic.json` in that new persistent output.
It contains the precise PIDs/references or nested mount paths still blocking
release. The recovery command does not use or change the original Docker daemon.

For server A with load on B, use `start`, then export through the private daemon:

```bash
sudo python3 benchmark/physical-ram-docker.py exec --env-file .env.physical -- \
  bash benchmark/remote/export-native-client.sh --env-file .env.physical \
  --no-build-image --output /mnt/mylocalton-ram/client-export
```

Follow the [remote runner guide](remote/README.md) to copy/import the bundle and
run B. `--no-build-image` preserves A's already prepared image. Export/copy the
private client bundle before timing, and save B's result directory separately;
A's `stop` command does not fetch B's results. Use `exec -- docker ...` to inspect
the private daemon. Do not change the profile, images or harness while it runs.

The private daemon uses a distinct socket, data/exec roots, its own containerd
process with RAM metadata, separate namespaces and an owned bridge. VFS avoids
assuming overlayfs support on tmpfs. Normal Docker
JSON logs stay on the same RAM filesystem, so the existing reporting/proof code
works. Startup must pass real container filesystem and networking smoke checks
before creating the validator. Host executables, kernel/network activity and
persistent result exports remain outside this RAM store; this does not claim
that every host I/O operation disappears.

The private daemon disables Docker's automatic firewall management and IP
masquerading. The launcher installs separately named, ownership-tagged IPv4
forwarding/NAT rules scoped to `tonram0` and `tonram1` and their configured
subnets. Published TCP/UDP ports use Docker's userland proxy. Cleanup removes
only the recorded RAM rules and chains; it does not flush the original daemon's
`DOCKER` chains or change the host's default firewall policy. Existing host
ingress rules still govern remote access. Shared host CPU/RAM use can influence
TPS, so keep the recorded background load with your results.

The guard records samples and stops only containers identified by the private
daemon ID and exact Compose ownership. Two samples below the host or filesystem
reserve trigger a stop; host memory below 8 GiB triggers an immediate stop.
A guard stop makes an interrupted run incomplete. Never treat a partial counter,
a nonfinal generator record, or a process exit alone as a valid TPS result.

Persistent output contains `ram-evidence/` with the benchmark `results/`, logs,
image/config/runtime receipts and guard evidence. Inspect each
`benchmark-summary.json`: canonical proof, completion, lane balance, cleanup,
capacity and reproducibility are separate assessments. Compare repeated complete
runs and report every rejected/interrupted arm. This eight-lane physical profile
is not a matched repeat of the four-lane desktop test. Demonstrating a storage
gain requires a disk control on the same server, same images, workload and
starting state; a new RAM result alone cannot establish that gain.

`stop` preserves RAM volumes/images and exports evidence, **not a durable full
chain backup**. The contents disappear on reboot or unmount. After saving what
you need and confirming the private daemon is stopped, `sudo umount
/mnt/mylocalton-ram` releases this experiment's memory. The launcher never
unmounts or deletes the RAM database automatically. Normal RocksDB sync options
remain enabled, but syncing tmpfs does not provide disk durability.

Implementation references: [Docker tmpfs and memory accounting](https://docs.docker.com/engine/storage/tmpfs/),
[Linux tmpfs](https://docs.kernel.org/filesystems/tmpfs.html), and
[Docker multiple-daemon configuration](https://docs.docker.com/reference/cli/dockerd/#run-multiple-daemons).
Docker labels multiple-daemon operation experimental; this workflow isolates
storage and firewall ownership while permitting unrelated original-daemon
workloads. It remains a volatile benchmark setup.

The original preparation validation is recorded in
[the 14 September receipt](physical-ram-preparation-20260914.json): 42 focused
tests and the existing benchmark self-test passed, including actual Compose
configuration rendering. Native daemon startup, the real storage/network smoke
and sustained TPS have not run here; those remain server validation steps. That
receipt describes the initial preset before the coexistence fix above.

Coexistence validation: 63 focused tests and the existing benchmark self-test
pass. Fixtures cover the five reported services plus the existing
`172.28.1.0/24` network/routes, real conflict rejection, Compose address remapping,
and preservation of original Docker rules during owned firewall cleanup. The
local read-only check records 24 running containers without an activity or
subnet rejection. Native daemon/firewall startup still needs server validation;
no live host firewall or container configuration was changed in these checks.

Startup regression validation: all 73 focused tests pass. These include a
simulated 620-second genesis bootstrap, guard/deadline failures, genesis restart
during stats startup, failed-phase recovery messages, and command-log diagnostics.
No live server startup or TPS measurement was performed for this fix.

Finalization regression validation: 90 focused RAM tests and six wrapper progress
tests pass, along with the full benchmark self-test. The simulated run completes
reporting beyond the former 2,040-second deadline; missing or stale progress and
repeated substage updates cannot extend a phase. Tests also preserve an achieved
TPS record whose chain-capacity assessment is false. These checks use mocks and
fixtures; they do not constitute another server TPS run.

Mount-release regression validation includes six offline mount-namespace and
process-reference tests plus four launcher recovery tests. They cover deleted
open files, working directories, memory mappings, nested and stacked mounts,
external ownership restoration, export-before-unmount ordering, and refusal to
terminate an unowned holder. No local mount, daemon, container or process was
changed by these tests.
