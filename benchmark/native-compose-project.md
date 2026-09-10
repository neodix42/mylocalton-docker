# Explicit project for an existing benchmark chain

The non-destructive benchmark wrapper accepts `BENCHMARK_COMPOSE_PROJECT` as an
explicit environment variable. The default remains `mylocalton-desktop`.
Ordinary `COMPOSE_PROJECT_NAME` and `COMPOSE_FILE` variables do not redirect the
wrapper. This selector is not loaded from the validator `.env` file.

```bash
BENCHMARK_COMPOSE_PROJECT=mlt-native-20260910 \
  bash run-native-benchmark.sh /absolute/path/to/benchmark.env /absolute/path/to/results
```

The connection sweep accepts the same environment variable, or an overriding
`--compose-project` argument. It passes the selected project to both Compose
preflight and each wrapper invocation:

```bash
python3 benchmark/run-native-connections-sweep.py \
  --compose-project mlt-native-20260910 --env-file /absolute/path/to/benchmark.env \
  --connections 10 --duration 600 --coalesce-ms 20 --lane-depth 2 --plan-only
```

Remove `--plan-only` only after that project's genesis is prepared and healthy.
The project appears in sweep `plan.json` and in `run-metadata.json` under
`compose.project`. Project names must match `[a-z0-9][a-z0-9_-]*`; an explicitly
empty value is rejected. Workload, strict image reuse, proof and drain checks
are unchanged.

Each wrapper records a newly created generator's immutable container ID in its
unique result directory as `generator-owner.json`, after checking its project,
service, name and difference from the previous container. Signal cleanup and the
sweep's timeout fallback stop only this captured ID. A later container occupying
the same name is not a cleanup target. Missing or invalid ownership evidence
prevents a container stop; the sweep still reaps its own wrapper process group
and rejects the arm. Interruption before launch does not stop an old generator.

The Compose file still uses fixed container names, ports and the network name
`mylocalton-network`. This option selects fresh project-scoped volumes; it does
not enable two simultaneous copies of the stack. The wrapper refuses to use
`genesis`, `native-load-generator` or `session-stats` belonging to a different
project/service. Before switching projects, stop/remove only the old benchmark
containers while preserving their volumes. Resolve the old network separately:
an empty network verified to belong exclusively to the old benchmark can be
removed so the new project recreates it with matching Compose labels. Do not
remove a network that still has unrelated endpoints. A launch-only override
file is not sufficient: the wrapper and sweep deliberately use the repository's
explicit Compose file for identity checks.

An empty database bind directory and fresh `native-load-wallets`, `shared-data`
and `session-stats-data` project volumes are all needed for a new chain. Changing
only the database bind directory can retain old wallet keys. When the database
lives on the real host under Docker Desktop, share its parent in Desktop File
Sharing first. Set `TON_DB_VAL0_HOST_DIR`, `TON_WORK_HOST_DIR` and `HOST_FS_ROOT`
to the same absolute database directory and clear `TON_WORK_DOCKER_VOLUME`.
Session-stats then reads `/hostfs/log.session-stats` through the explicit bind,
without relying on the Desktop VM's `/` mount to represent the real host.

`benchmark/run-fresh-native-cycle.sh` remains destructive and fixed to
`mylocalton-desktop`. It rejects any other or empty `BENCHMARK_COMPOSE_PROJECT`
before invoking Docker, and explicitly pins that project when handing off to
the wrapper. It must not be used to prepare the custom project above.
