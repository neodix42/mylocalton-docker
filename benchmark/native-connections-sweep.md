# Persistent connection sweep

`run-native-connections-sweep.py` runs the existing native load generator with 10, then 50, then 100 persistent ADNL/TCP submission connections to one prepared local liteserver. It saves measured offered logical TPS, admission logical TPS, canonical chain logical TPS, and the original acceptance decisions for every completed arm. It does not launch a CLI process per message.

Prepare the fixed-depth native chain and build all images **before** the sweep. The runner requires a healthy existing genesis, matching prebuilt validator/generator source revisions, an available session-stats image, and exactly one liteserver in the shared public config. It performs no builds, pulls, genesis recreation, state resets, or volume deletion. Generator containers are recreated between arms by the existing benchmark wrapper. The validator container, image, daemon PID/start ticks, mounts, resource limits, and public endpoint must remain unchanged for the entire sweep.

```sh
# Offline plan: no Docker calls or workload.
python3 benchmark/run-native-connections-sweep.py --plan-only > /tmp/connections-plan.json

# After the matching images and four-lane network have been prepared:
python3 benchmark/run-native-connections-sweep.py \
  --connections 10 50 100 --duration 180 \
  --env-file .env.physical --output benchmark-results/connections-first

# A single count or comma-separated list is also supported.
python3 benchmark/run-native-connections-sweep.py \
  --connections 100 --duration 300 --output benchmark-results/connections-100-repeat
```

Pin `TON_IMAGE`/`TON_BRANCH` to the already prepared images in the environment or env file. The runner freezes exact resolved service image IDs before the first arm; dependency order cannot select a different service image. `plan.json` lists the common environment and each arm's environment. The preparation owner can use the first arm's environment with `native_payment_lanes_profile_env 2` when preparing genesis; `NATIVE_LOAD_SOURCES` selects the genesis source count, and changing submission connections does not alter genesis configuration. Existing images lacking `--adaptive-initial-cwnd` fail before offering load when the explicit initial window is requested.

For a generator entrypoint-only rebuild, keep `TON_IMAGE` and `TON_BRANCH` pinned to the prepared validator and set `NATIVE_LOAD_IMAGE` to the **already built** replacement generator image before starting a new complete sweep:

```sh
NATIVE_LOAD_IMAGE=mylocalton-native-load-generator:generator-entrypoint-v2 \
  python3 benchmark/run-native-connections-sweep.py \
    --connections 10 50 100 --output benchmark-results/connections-retry
```

The default generator image remains `mylocalton-native-load-generator:${TON_BRANCH:-latest}`. This optional override changes only the generator service image; it does not retag, rebuild, or recreate genesis. The replacement must retain the same TON source revision label as the validator. Its immutable image ID is frozen for every arm of the new sweep, and a partial failed sweep remains a separate rejected bundle. Build the replacement before starting the sweep; builds are never part of its measurement path.

Default settings are:

| Setting | Value |
| --- | ---: |
| Submission connections | 10 → 50 → 100 |
| Sources | 24,576, partitioned into disjoint worker ranges |
| Workers / signers | 6 / 6 |
| Fixed payment lanes | 4 (depth 2) |
| Normal signed NTRN parent | 16 logical transfers |
| Global initial / maximum adaptive window | 32,768 / 65,536 logical transfers |
| Global hard inflight limit | 262,144 logical transfers |
| Global / source canonical backlog cap | 2,097,120 / 128 logical transfers |
| Outstanding query cap | 64 **per submission connection** |
| Batch size / coalescing deadline | 64 intact parents / 20 ms |
| Initial RTT estimate | 0.5 seconds |
| Target TPS / ramp | 0 / 0 seconds |
| Warmup / measurement / maximum drain | 60 / 180 / 180 seconds |

Target zero uses the existing `bounded_unpaced` behavior: token pacing is disabled, while finite backlog limits, whole-parent issue credit, query limits, AIMD, signatures, admission and canonical proof tracking remain enabled. It does not mean zero load or unlimited memory. Target attainment is reported as not applicable; no acceptance booleans or capacity gates are weakened. A positive `--target-tps` uses the existing paced mode.

The same global initial and maximum windows are distributed worker first, then connection, with remainder conservation. Every connection must fit at least one whole 16-transfer parent. For lists containing fewer than six connections, all arms use `min(requested workers, smallest connection count)` workers; the plan records that effective count. Source ranges remain disjoint within each run. This is not a one-source-per-connection workload. Canonical follower queries use additional connections, so the selected number means submission clients rather than the total socket count on the validator. Aggregate query capacity grows with connection count because its existing limit is per connection; the plan records this distinction.

The selected `--global-config` must be an existing file under the shared `/usr/share/data` mount. It must contain the same single IP, port and public key as the prepared `global.config.json`; multiple endpoints, remote aliases and routing ambiguity are rejected. No host port bindings are changed. These local connection measurements do not establish performance for 100 remote machines, WAN latency, many validators, or a different number of independently active source accounts.

Each output directory is exclusive and contains the predeclared plan, immutable preflight, launch commands, wrapper logs, raw benchmark bundles, and `sweep-summary.json`. The summary hashes each completed raw summary before extracting figures. Admission TPS is checked against `steady_mempool_accepted / measure_elapsed_s`; it is an acknowledgment of pending admission, not canonical inclusion. Canonical TPS retains the existing fully contained block-time window and original validity gates. Rates with different measurement windows are not silently mixed.

The sweep continues after a pure ingress/capacity rejection only if proof correctness, completion/drain, normal signed-run quantum, batching mode, lane checks, cleanup, and strict continuity all pass. Such an arm is `observation_only`, and its original rejected capacity decision remains visible. Missing or malformed evidence, incorrect effective connection/window metadata, cleanup failure, interrupted workload, or changed identity stops the sequence and retains collected evidence. The highest **capacity-eligible** arm is reported only after the whole sweep completes; an incomplete sweep has no selected winner. This is the highest observed result in that sweep, without a repeatability or statistical significance claim.

SIGINT/SIGTERM is forwarded to the existing wrapper, which stops the generator. A finite per-arm watchdog covers readiness, load, drain and reporting. If cleanup remains stuck, it retries a bounded generator stop and terminates the wrapper's process group. The validator and persistent volumes remain in place. A failed stop can require operator cleanup; the rejected result records the failure and no later arm starts.

The ascending sequence retains validator/database/cache history between arms. It is useful for finding connection pressure limits, but connection count is not randomized against chain age. Repeat the best setting or use an independently declared paired order before claiming a repeatable improvement. Existing per-run CPU, latency, resource and pipeline artifacts are retained for diagnosis; the sweep does not introduce extra online profiling.

Offline verification:

```sh
bash benchmark/tests/native-benchmark-reporting-test.sh
# Focused subsets:
python3 benchmark/tests/native-connections-sweep-test.py
bash benchmark/tests/native-initial-cwnd-config-test.sh
```
