# Native load from another server

Server A runs the prepared native validator and liteserver. Server B runs only the persistent ADNL/TCP generator. These three Bash scripts package the public config, selected funded test accounts, preset and prebuilt image so B does not need a validator or repository clone.

## Export on A

From the MyLocalTonDocker checkout:

```sh
bash benchmark/remote/export-native-client.sh
```

The prompts collect A's reachable IPv4/port, the existing validator container, source count/offset, a locally available generator image, a new output directory and whether to include the image archive. Defaults are genesis, port 40004, 24,576 sources starting at zero, and the tested `cycle-clients-ed666c9a-h2` generator. The image archive is included by default. The validator must already have native runs and its fixed-depth lane topology initialized.

For automation, replace the example IP:

```sh
bash benchmark/remote/export-native-client.sh \
  --non-interactive --server-ip 203.0.113.10 --port 40004 \
  --container genesis --sources 24576 --source-offset 0 \
  --image mylocalton-native-load-generator:cycle-clients-ed666c9a-h2 \
  --include-image --output "$HOME/native-client-export"
```

The private output directory contains `external.global.config.json`, `test-wallets.tar.gz`, `remote-load.env`, `import-native-client.sh`, **`run-remote-load.sh`**, `export-manifest.json`, and optionally `generator-image.tar`. Copy the entire directory, including both scripts:

```sh
scp -r "$HOME/native-client-export" user@SERVER_B:~/
```

`--no-image` omits the large image archive when B already has the exact image. A still needs that image locally so the exporter can pin its immutable ID. No image is built or pulled. Only the exported config's liteserver IP/port changes; its key and zero-state hashes are preserved. The wallet archive contains only the selected source signing keys, source/destination public keys and addresses, and the public lane manifest. It contains no destination signing keys or validator/control keys. The export directory contains private test-account keys; keep it outside Git and transfer it privately.

## Import on B

B needs Linux, Bash, Python 3 and local Docker. The runner also uses standard `flock` and `timeout` commands. Copy a generator image compatible with B's CPU architecture/instruction support.

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
python3 benchmark/tests/native-remote-client-test.py
```

The suite exercises export/import and runner success/failure paths with simulated Docker and temporary synthetic keys. It submits no blockchain messages and does not establish a new TPS result. The public `native-remote-load.env` preset matches the recorded 2026-09-06 client run before export-specific path/range/image adjustments.
