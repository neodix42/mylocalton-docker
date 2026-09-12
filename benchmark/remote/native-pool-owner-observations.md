# Native pool owner observations

The separate prepared-admission prototype uses
`TON_NATIVE_ADMISSION_LANE_OWNERS=4`, passed to genesis by Compose with default
`0`. It requires a matching validator build, `TON_NATIVE_ADMISSION_PREPARE=1`,
`TON_NATIVE_ADMISSION_SNAPSHOT_REFRESH=0`, and an existing fixed four-lane
payment chain. Its four native admission owners share a separate generic-message
coordinator; `TON_NATIVE_LANE_SCHEDULERS` independently controls scheduler
placement. This is distinct from `TON_NATIVE_POOL_OWNERS` below. The legacy
owner observer described here does not validate the new prototype's metadata;
use its matching benchmark observer. Neither machine preset enables it.

`TON_NATIVE_POOL_OWNERS` accepts `1`, `2`, or `4`; Compose defaults to `1`.
Changing this flag is an experimental validator change. Compare frozen matching
validator and generator images, the same chain and account set, and the same
workload. Complete the existing proof, drain and source-reuse gates between runs.
This harness does not enable the experiment in either saved machine preset.

Single-owner validators retain their existing `total.ext_msg_*` counters. New
images also report `total.native_pool_owners`; older single-owner recordings
remain readable. A request for two or four owners requires the matching header
and every declared owner, so a binary that ignores the flag cannot pass cleanup.

With two or four owners, `native_pool.owner.<index>.ext_msg_*` and `.identity`
are independent populations. The profiler stores each owner separately and
reports `total.native_signature_executor` once. It does not create aggregate
admission counters, sum lifetime maxima or replace missing owners with zeros.
Each owner’s stage mean uses that owner’s matching samples and sum. Counter
resets, changed owner configuration, partial identities and missing schemas
invalidate attribution, including resets between apparently healthy endpoints.

The header’s topology, published generation and aggregate mempool fields are
current gauges. Each identity’s applied generation and local mempool are also
gauges. Statistics fanout is asynchronous, so summed local mempool counts need
not equal the separately observed aggregate gauge. Router decoding counters and
wall-time samples cover strict batch RPC parsing only, and remain associated
with their actual owner identity. Their mean is per batch RPC, not all ingress
parsing: single-message routing can increase routed messages without a decode
sample. The maximum is a lifetime endpoint, not an interval measurement or CPU time.

`native-pool-owners.json` retains before/after scoped evidence. For multiple
owners, `validator-pool-summary.json` uses this scoped schema rather than a
misleading root-only summary. Its existing `cleanup_acceptance.valid` path
requires complete consistent owner metadata, ready topology, every applied
generation at least the published generation, and **each** owner’s native
`pending_sources` and pending `messages` to be zero. Generic mempool entries
remain diagnostic and do not change the original native cleanup rule. Generator
canonical proofs and strict image/process reuse are separate mandatory gates.

`profile-native-validator.py` now loads the adjacent
`native_pool_owner_stats.py`; retain both files if copying the profiler alone.
The benchmark wrapper invokes the same module offline over saved exact-key
console captures. It performs no additional validator RPCs.

Focused offline validation (no Docker or traffic):

```sh
python3 benchmark/tests/native-pool-owner-profile-test.py
python3 benchmark/tests/native-container-runtime-env-test.py
python3 benchmark/tests/native-validator-profile-test.py
python3 benchmark/tests/native-dispatch-profile-test.py
bash -n run-native-benchmark.sh
```
