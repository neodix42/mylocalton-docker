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
bash run-remote-load.sh --connections 10 50 100
```

The default sequence is also 10/50/100. For an independent single-count run:

```sh
bash run-remote-load.sh --connections 50 --duration 300
```

`--help` lists directory, duration/warm-up/drain, CPU/memory, output and prebuilt-image overrides. The reference preset uses 60 seconds warm-up, 180 seconds measurement, up to 180 seconds drain, six workers/signers, 16 logical transfers per parent, and 4 CPU equivalents / 8 GiB memory. Connection counts must be at least the exported worker count and at most 256. Small source exports reduce workers/signers when needed; they are not the reference capacity workload.

Each run creates a new `remote-results/` directory with an overall `summary.json`, effective settings and per-arm logs, final counters and container inspection. Images are frozen by ID and exited containers are retained. SIGINT/SIGTERM stops only the runner-owned container and preserves partial evidence. Incorrect/incomplete runs stop the sequence; capacity-only failures remain `observation_only`. `generator_capacity_eligible` refers to the generator's gates: remote validator identity, resources and pool cleanup are not independently collected by this B-only runner.

Do not run independent generators against the same source keys. The directory lock prevents overlap within one installed client dataset; it cannot coordinate separately copied wallets or another server. Synchronize A/B clocks, keep unrelated native traffic off A, and require offered load above canonical throughput for a capacity claim.

For the deployed Session Stats image, use **Canonical transactions per second → Workchain**, window **1m**, refreshing after import delay. The separate native-specific chart has an NTRN counting bug; collation/validation service-rate charts are not chain TPS. Keep A's TCP liteserver port reachable from B and A's management/file-server endpoints private.

## Offline checks

```sh
python3 benchmark/tests/native-registry-images-test.py
python3 benchmark/tests/native-remote-client-test.py
```

The suites exercise registry preparation/startup, export/import and runner success/failure paths with simulated Docker and temporary synthetic keys. It submits no blockchain messages and does not establish a new TPS result. The public `native-remote-load.env` preset matches the recorded 2026-09-06 client run before export-specific path/range/image adjustments.
