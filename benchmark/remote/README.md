# Native load from another server

Server A runs the prepared native validator and liteserver. Server B runs only the persistent ADNL/TCP generator. These three Bash scripts package the public config, selected funded test accounts, preset and prebuilt image so B does not need a validator or repository clone.

## Prepare and start A

Use the updated MyLocalTonDocker `native-payment-lanes-step6` checkout. For a fresh deployment, start from `.env.physical` and adjust `.env` for A's CPU layout, database path and public liteserver/dashboard bindings. Preserve an existing deployment's project name, database settings and native genesis configuration. Replace old `cycle-clients-*` image entries with:

```dotenv
TON_IMAGE=ghcr.io/corton-nommander/ton
TON_BRANCH=master
NATIVE_LOAD_IMAGE=mylocalton-native-load-generator:master
TON_BUILD_PULL=true
SESSION_STATS_IMAGE=ghcr.io/neodix42/ton-session-stats:side
```

Fresh `.env.physical` deployments now use **eight lanes**. Copy it to `.env` only for a fresh deployment, then customize the host bindings and database path. Its topology is:

```dotenv
NATIVE_PAYMENT_LANE_DEPTH=3
ACTUAL_MIN_SPLIT=3
MIN_SPLIT=3
MAX_SPLIT=3
NATIVE_LOAD_PAYMENT_LANE_DEPTH=3
NATIVE_PAYMENT_LANE_WALLET_RETRIES=256
```

The 24,576 source accounts remain evenly distributed: 3,072 per lane. Wallet generation uses 12 bounded workers; topology readiness allows 1,800 seconds for three split rounds. Eight lanes are a new configuration to benchmark, not a demonstrated TPS gain.

An existing four-lane chain must keep its depth-2 settings. Use separate state and matching freshly funded wallets for an eight-lane genesis; do not repoint an existing database or only edit B's lane depth. The exporter reads the actual genesis wallet manifest and sets both client lane-depth variables automatically, so two- and four-lane exports remain supported. An eight-lane bundle includes depth 3 and eight-lane readiness/proof checks.

After updating the checkout, `start-native-genesis.sh` rebuilds both derived wrappers from the published TON base. No new TON binary feature is required for depth 3. An old prebuilt wrapper image does not contain the new lane helpers: export/import a new bundle for B and keep its exact image fixed throughout measurements.

The Git branch selects MyLocalTonDocker's scripts; `TON_BRANCH` selects the published TON image tag. From this checkout, launch A with:

```sh
bash start-native-genesis.sh --env-file .env
```

The launcher pulls `ghcr.io/corton-nommander/ton:master` directly from GHCR, resolves its immutable digest and source revision, builds both local genesis and client wrappers from that digest, then starts only genesis. It writes `.native-images.json` with the base and derived image identities. It stops on pull/build/provenance failures. The wrappers do not compile TON, and no desktop image transfer is needed.

`master` is the latest successfully published master revision, which can lag a running or failed [TON image workflow](https://github.com/corton-nommander/ton/actions/workflows/docker-ubuntu-branch-image.yml). Running the launcher again refreshes this registry version and may recreate genesis through normal Compose startup, preserving existing volumes. Complete startup before a benchmark; do not refresh images during the sweep. The portable CI image must be measured on A/B; historical desktop TPS is not a measurement of this deployment.

To prepare both images without starting containers, use `bash prepare-native-images.sh --env-file .env`. A plain `docker compose up --no-build --pull never genesis` only reuses images already local.

Once genesis is healthy and blocks advance, pull and start the dashboard:

```sh
docker compose --env-file .env --profile session-stats pull session-stats
docker compose --env-file .env --profile session-stats \
  up -d --no-deps --no-build --pull never session-stats
```

## Export on A

From the MyLocalTonDocker checkout:

```sh
bash benchmark/remote/export-native-client.sh
```

The prompts collect A's reachable IPv4/port, the existing validator container, source count/offset, a new output directory and whether to include the image archive. Defaults are genesis, port 40004 and 24,576 sources starting at zero. The image archive is included by default. The validator must already have native runs and its fixed-depth lane topology initialized.

The exporter selects Compose's resolved `native-load-generator` image from this checkout's `.env`: `NATIVE_LOAD_IMAGE`, falling back to `mylocalton-native-load-generator:${TON_BRANCH:-master}`. By default it invokes `prepare-native-images.sh` to pull the configured current TON base and build only the client from its immutable digest. The pulled revision must match the running genesis image; if master has advanced, export stops before building and directs you to run `start-native-genesis.sh`, wait for healthy/advancing blocks, then export again. Export never restarts genesis or starts traffic.

For automation, replace the example IP:

```sh
bash benchmark/remote/export-native-client.sh \
  --non-interactive --server-ip 203.0.113.10 --port 40004 \
  --container genesis --sources 24576 --source-offset 0 \
  --include-image --output "$HOME/native-client-export"
```

The private output directory contains `external.global.config.json`, `test-wallets.tar.gz`, `remote-load.env`, `import-native-client.sh`, **`run-remote-load.sh`**, `export-manifest.json`, and optionally `generator-image.tar`. Copy the entire directory, including both scripts:

```sh
scp -r "$HOME/native-client-export" user@SERVER_B:~/
```

Use `--env-file /path/to/deployment.env` for another Compose environment. `--build-image` explicitly selects the default registry preparation. For an already prepared benchmark, `--no-build-image` opts into strict reuse of the configured local image and skips pulls/builds; `--image PREBUILT_IMAGE` also bypasses preparation and requires that explicit image locally. Ordinary deployment/export refreshes from the registry. Complete preparation before timing, then keep the exported image frozen by immutable ID across B's entire sweep.

`--no-image` omits the large image archive when B already has the exact image. A still needs the selected image locally so the exporter can pin its immutable ID. Only the exported config's liteserver IP/port changes; its key and zero-state hashes are preserved. The wallet archive contains only the selected source signing keys, source/destination public keys and addresses, and the public lane manifest. It contains no destination signing keys or validator/control keys. The export directory contains private test-account keys; keep it outside Git and transfer it privately.

## Import on B

B needs Linux, Bash, Python 3 and local Docker. The runner also uses `flock` and `timeout` (typically from `util-linux` and `coreutils`). B may have **no images installed**: with the image archive included, the importer loads it without pulling, building, installing Compose or cloning this repository. Copy a generator image compatible with B's CPU architecture/instruction support.

```sh
bash "$HOME/native-client-export/import-native-client.sh"
```

The importer asks for the bundle and a new installation directory (default `~/native-remote-client`). It verifies the file inventory/checksums, safely extracts the selected wallets, verifies their lane addresses, and loads the pinned image if necessary and included. It refuses existing output directories and never starts load. Scripted alternative:

```sh
bash "$HOME/native-client-export/import-native-client.sh" \
  --non-interactive --bundle "$HOME/native-client-export" \
  --output "$HOME/native-remote-client" --load-image
```

Use `--no-load-image` to require a preloaded image. Neither importer nor runner uses a remote Docker context: Docker must address B's local Unix-socket daemon.

## Run on B

```sh
cd "$HOME/native-remote-client"
bash run-remote-load.sh --connections 10 50 100 --duration 600
```

The default sequence is also 10/50/100. Each setup defaults to **at least 600 measured seconds**, even if an older installed `remote-load.env` still specifies 180. A longer environment duration is preserved; an explicit `--duration` selects an exact duration, including shorter diagnostic runs. For one uninterrupted ten-minute measurement after resolving any previous failed arm:

```sh
bash run-remote-load.sh --connections 10 --duration 600
```

The default `server48` profile targets the confirmed dedicated **48-CPU / 256-GB server B**: **40 CPU equivalents, a 48 GiB memory limit, ten workers and 32 signing actors**. It also upgrades older installed six-worker presets without rewriting `remote-load.env`. The native scheduler has 43 threads with these counts. Ten workers divide 10/50/100/300/500 connections evenly; increasing connections alone does not add signing capacity. This is an unmeasured resource treatment, not a new TPS result.

`--help` lists profile, directory, timing, CPU/memory, worker/signer, window, output and prebuilt-image overrides. Explicit arguments always win over profile defaults. The reference preset retains 60 seconds warm-up, 600 seconds measurement, up to 180 seconds drain, 16 logical transfers per parent, initial/max admission windows 32,768/65,536, and the existing inflight/backlog limits. It already sends without a target-TPS rate limit. Connection counts must cover the effective worker count and remain at most 1024 in the updated native binary. Counts above 256 require a generator image containing that native change; a host-script update cannot extend an old binary. Before any setup in a sweep containing a count above 256, the runner checks the frozen image’s `--help` in a bounded, no-network container with no mounted accounts or config. It requires the connections option to advertise the requested range and saves `native-load-generator-help.txt` plus `connection-capability.json`; an old image fails before even an earlier 50-connection arm starts. The container open-file limit is 65,536 to leave descriptor headroom for large sweeps. Small source exports cap workers/signers to the selected source count; they are not the reference capacity workload.

On a smaller B, use `--profile preset`: it takes workers/signers from the imported environment and defaults to the earlier 4 CPUs/8g. To reproduce the six-worker resource control with either an old or new preset, use:

```sh
bash run-remote-load.sh --profile preset --workers 6 --signers 6 \
  --connections 10 50 100 --duration 600
```

Keep the same image, accounts, validator process, admission windows and measurement duration for the comparison. Use the successful treatment with the highest repeatable canonical TPS; do not classify an incomplete drain as a valid throughput result.

Each run creates a new `remote-results/` directory with an overall `summary.json`, effective settings, a copy of the actual runner and its SHA-256, and per-arm logs, final counters and container inspection. Progress appears every 30 seconds and is saved in `progress.jsonl`; live rates remain provisional. `canonical_chain_measure_planned_window_avg_tps` explicitly names the original native metric whose denominator is the entire planned canonical block-time window (normally 599 seconds), even early in measurement. Its rise during measurement is not evidence that actual production TPS is ramping. The observed transfer count and bucket duration accompany it; use the complete final result for measured canonical TPS. Each arm also saves `execution.json` with Docker exit/OOM/error and watchdog information. A final generator record, when present, is retained even on a nonzero exit so drain/proof failure reasons are visible. The compact failure summary also reports unresolved counts, retries, typed not-ready reasons, re-signing and repair counters without printing the full JSON semantics. The watchdog scales with the selected measurement duration and other time budgets. Images are frozen by ID and exited containers are retained. SIGINT/SIGTERM stops only the runner-owned container and preserves partial evidence. With the default `reuse` source policy, incorrect/incomplete runs stop the sequence; capacity-only failures remain `observation_only`. A source that exhausted its admission retry budget but recovered during drain may complete with an exact proof for every offered parent. Such a clean exit with zero final backlog and valid proof/cohort gates remains an observation and permits the next setup; retry exhaustion itself is not proof of an unresolved nonce. Exit 2 and incomplete cohorts still stop reuse. `generator_capacity_eligible` refers to the generator's gates: remote validator identity, resources and pool cleanup are not independently collected by this B-only runner.

Do not run independent generators against the same source keys. The directory lock prevents overlap within one installed client dataset; it cannot coordinate separately copied wallets or another server. Synchronize A/B clocks, keep unrelated native traffic off A, and require offered load above canonical throughput for a capacity claim.

A full default sweep has 30 measured minutes plus three warm-ups, readiness checks and drains. Expect separate load periods with gaps between setups. Ten minutes of measurement does not by itself certify stable throughput: inspect the final proof-checked result and the chart over that interval. The effective profile and resource budgets are printed before launch and recorded with each arm; an unexplained exit is not evidence that a resource limit was reached. Extra memory is a limit, not preallocated RAM or a reason to enlarge the backlog.

The earlier generic `container did not exit cleanly` can be diagnosed from the existing arm directory on B:

```sh
cd "$HOME/native-remote-client/remote-results/RUN/02-50-connections"
python3 -c 'import json; d=json.load(open("container.json"))[0]; print(json.dumps({"State":d.get("State"),"RestartCount":d.get("RestartCount")},indent=2))'
cat wait.log
tail -n 60 generator.stderr.log
```

Exit 2 can mean unsettled drain; exit 3 can mean canonical follower/proof/correctness failure. Read the final generator reasons and stderr for the actual cause. Exit 137 alone is not proof of OOM; inspect `State.OOMKilled`. A failed 50-connection arm stops before 100 so incomplete source nonces are not silently reused.

### Larger sweeps and isolated source accounts

After installing a generator image with the 1..1024 connection support, use:

```sh
bash run-remote-load.sh --connections 100 300 500 --duration 600
```

More connections share the same fixed global admission windows and signing workers. They may improve request distribution, or add overhead; their count alone does not establish higher CPU use or TPS. Measure before enlarging windows. Normal sweeps use all exported accounts in each setup and only reuse them after the full proof/completion gates pass.

If you need every setup attempted even when a cohort remains unresolved, explicitly isolate the accounts:

```sh
bash run-remote-load.sh --source-policy isolated \
  --connections 100 300 500 --duration 600
```

With 24,576 exported sources and three setups, each setup receives **8,192 distinct source accounts**, balanced across the exported lanes (eight for a fresh physical-server deployment). The same number of sources is used in every setup; unused remainder accounts are left unused. The runner verifies the manifest's balanced lane ordering and refuses insufficient or malformed partitions. Effective source offsets/counts are saved and printed with each result. This changes the workload cardinality, so compare it against another isolated run with the same number of setups, not a 24,576-source result.

An invalid arm remains invalid and the sweep exits nonzero, but an exited workload can be followed by a setup using the next disjoint partition. Every later arm becomes `observation_only` while an earlier arm's cohort is unresolved: earlier admitted messages might still appear in the canonical chain TPS metric. `all_setups_attempted` distinguishes attempting the whole sequence from a wholly valid sweep. Interruptions, unverified container identity, and a workload that is not confirmed stopped still abort.

Partition isolation applies within one sweep. It does not erase or reconcile an earlier failed sweep's nonces. Do not start another overlapping sweep until its failed source ranges are reconciled, or import a separate funded source range. Retain the failed artifacts; no flag ignores missing proofs or calls an incomplete run valid.

### Update an already imported runner on B

After the previous runner has exited, replace only the installed host script. Keep the original export directory unchanged: its manifest checksums describe the original bundle. The existing image ID, client configuration and wallets are reused. No A-side export, image rebuild/pull, or validator restart is needed for this host-script update.

Run on B (set `runner_ref` to a reviewed commit for a fixed update, or use the maintained branch shown):

```sh
bash -s <<'SH'
set -eu
umask 077
runner_ref=native-payment-lanes-step6
client_dir="$HOME/native-remote-client"
runner_download=$(mktemp)
trap 'rm -f "$runner_download"' EXIT
curl --fail --location "https://raw.githubusercontent.com/neodix42/mylocalton-docker/$runner_ref/benchmark/remote/run-remote-load.sh" --output "$runner_download"
bash -n "$runner_download"
cp -p "$client_dir/run-remote-load.sh" "$client_dir/run-remote-load.sh.before-update-$(date -u +%Y%m%dT%H%M%SZ)"
install -m 700 "$runner_download" "$client_dir/run-remote-load.sh"
SH
```

For the deployed Session Stats image, use **Canonical transactions per second → Workchain**, window **1m**, refreshing after import delay. The separate native-specific chart has an NTRN counting bug; collation/validation service-rate charts are not chain TPS. Keep A's TCP liteserver port reachable from B and A's management/file-server endpoints private.

## Offline checks

```sh
python3 benchmark/tests/native-registry-images-test.py
python3 benchmark/tests/native-remote-client-test.py
```

The suites exercise registry preparation/startup, export/import and runner success/failure paths with simulated Docker and temporary synthetic keys. It submits no blockchain messages and does not establish a new TPS result. The public `native-remote-load.env` preset extends measurement to 600 seconds and uses ten workers/32 signers for the 48-CPU client. It retains the recorded 2026-09-06 admission/backlog limits, before export-specific path/range/image adjustments. The standalone runner applies its selected resource profile to old and new exports and records the original and effective environment separately.

## September 7 drain failure

The [saved failure observation](reports/native-drain-failure-20260907.json) records a complete ten-minute measurement followed by an unresolved 32-transfer drain tail (exit 2, no OOM/watchdog kill). The native client fix is in TON commit `a1e4c988`: an admission deadline that says "expired" now retries the original signed parent instead of replacing its hash. This requires a new generator image; updating the host script only changes resource/progress defaults.

Use the [image upgrade procedure](https://github.com/corton-nommander/ton/blob/master/doc/native-remote-client-guide.md#upgrade-the-image-for-the-admission-timeout-drain-fix) after its image workflow publishes the fix. Preserve the existing chain and failed artifacts, import the new client into a new directory, then obtain one valid ten-minute arm before a sweep. The public dashboard's nine wholly contained minutes ranged from 59,649 to 65,739 canonical TPS; those observations do not make the incompletely drained run valid.
