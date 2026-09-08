# Admission and block-overhead tests on A/B

This treatment adds exact-masterchain-state configuration caching and diagnostics.
It does not establish a new optimal TPS setting. Keep four lanes as the historical
reference and retain the existing eight-lane state for diagnosis. Compare cache
and thread settings on the **same topology** before another lane comparison.
Never change an existing eight-lane database's depth/split values to 2.

## Prepare once, before measurement

Pull the updated `native-payment-lanes-step6` MyLocalTonDocker branch on A.
The TON code is currently in [draft PR #4](https://github.com/corton-nommander/ton/pull/4);
the existing `master` image does not contain this treatment yet. Wait for the
[isolated image build](https://github.com/corton-nommander/ton/actions/runs/34231105092)
to succeed, then select these two image variables in A's existing `.env`:

```dotenv
TON_BRANCH=native-admission-profile-20260908
NATIVE_LOAD_IMAGE=mylocalton-native-load-generator:native-admission-profile-20260908
```

Keep all database, lane, account and endpoint settings unchanged. After the PR
is merged and the corresponding master image passes its checks, the normal
`TON_BRANCH=master` setup can select this implementation. Stop/drain B's current
test before upgrading A with:

```sh
bash start-native-genesis.sh --env-file .env
```

The launcher refreshes the published TON base and builds both derived wrappers.
It preserves the database; keep `.env` pointed at the existing eight-lane state.
Wait for healthy, advancing blocks. Export a new client bundle from the prepared
image and import it on B using the normal private transfer procedure:

```sh
bash benchmark/remote/export-native-client.sh --env-file .env --no-build-image
```

The updated binary is necessary for A's new counters/cache/thread control.
The updated host runner supplies B's new diagnostics and coalescing override.
Its default is now one 10-connection arm; explicit connection sweeps still work.
Do not build or pull again between paired measurements. Preserve the exported
immutable client image and record A's image/process identity with the sampler.

## Initial settings

| Control | Value |
| --- | --- |
| B connections / workers / signers | 10 / 10 / 32 |
| B CPU / memory ceiling | 40 CPUs / 48g (`server48`) |
| Measurement / warm-up | 600s / 60s |
| Initial / maximum logical admission window | 32,768 / 65,536 |
| Hard in-flight / total canonical backlog limits | 262,144 / 2,097,120 |
| Per-source canonical backlog | 128 |
| Signed-run quantum / physical batch cap | 16 / 64 |
| Maximum admission queries per client / coalescing | 64 / 20ms |
| A admission/state executor threads | 8 |
| A NTRN block-signature threads | 8 initially; independent 1/2/4/8 screen later |
| Candidate timeout / finalize reserve | Retain 8000ms / 1000ms |
| Ingress checkpoint retention | 0 |

Keep 24,576 sources and the exported lane depth fixed. These are controlled
starting settings, not a measured optimum. Successful drain/proof checks remain
required before account reuse. An invalid arm must not be relabelled a capacity win.

## Compare the cache using one prebuilt image

For the uncached control on A, after B has stopped cleanly:

```sh
TON_NATIVE_ADMISSION_CONFIG_CACHE=0 TON_NATIVE_VALIDATION_SIGNATURE_THREADS=8 \
docker compose --env-file .env up -d --no-deps --no-build --pull never --force-recreate genesis
```

Wait for healthy, advancing blocks before each arm. In a separate terminal on A,
start the read-only sampler before starting B:

```sh
sudo python3 benchmark/remote/profile-native-validator.py \
  --container genesis --duration 1200 --interval 30 \
  --dashboard-url http://127.0.0.1:18000 --output "$HOME/profile-cache-off-01"
```

On B, from the newly imported client directory:

```sh
bash run-remote-load.sh --connections 10 --duration 600 --warmup 60 \
  --initial-cwnd 32768 --max-cwnd 65536 --submit-coalesce-ms 20
```

For the cached treatment, repeat the A recreation with
`TON_NATIVE_ADMISSION_CONFIG_CACHE=1`, use a new sampler output directory and run
the identical B command. Repeat **off/on/on/off**, recreating and settling A
consistently even between the two on arms. Recreation changes process identity;
the image, database, settings other than the cache flag and workload stay fixed.
Do not change flags while a measured arm is running.

The sampler starts no services and never stops the validator. Ctrl-C stops only
sampling and saves partial evidence. It requires a local Docker Unix socket and
host `/proc` access. Increase sampler duration if B's readiness takes longer;
match `samples.jsonl` timestamps to B's final measurement window. The sampler's
whole-window means can include readiness, warm-up and drain. Optional dashboard
files use basechain-only statistics; missing/empty dashboard data is not zero TPS
and cannot replace B's proof-checked final result.

## Read the evidence before selecting another treatment

A writes `identity.json`, `samples.jsonl`, raw `stats-*.txt`, `summary.json`, and
optional dashboard canonical/packing/collation/validation files. The summary
includes cache hit rate, configuration/stage wall times, snapshot-change fractions
of both not-ready and all completed inputs, and sampled per-thread CPU/runqueue
cost. Thread samples exclude threads that vanished between polls; cgroup CPU
counters and signature thread-creation counters help expose that missing work.
Network counters cover the network namespace, not exclusively the validator.
Signature statistics include rejected validation attempts, not only canonical blocks.

B writes `client-limits.json` for each arm, including successful arms. It preserves
offered/admitted/canonical rates, window/cap counters, RTT, retry subtype, batching
and backlog evidence. `progress.jsonl` now includes those live gauges. Final
congestion window may reflect drain; examine measurement-phase samples. Lifetime
retry/cap counters include warm-up/drain. Diagnostic signals never override the
existing proof, completion, capacity or source-reuse rules.

Choose only one next treatment:

- If signature thread creation and scheduler delay are material, compare A's
  `TON_NATIVE_VALIDATION_SIGNATURE_THREADS=1`, `2`, `4`, `8` with the cache flag
  fixed and the same B command. This changes NTRN block-signature fanout, not the
  admission verifier actor count or state/trie executor setting. Blocks with fewer
  than 64 signed parents still run signatures serially.
- If fresh-work gaps are material, compare B's `--submit-coalesce-ms 10` with `20`
  at fixed credits. The runner requires the generator to confirm an explicitly
  requested coalescing interval; small batches and more RPCs may outweigh shorter waits.
- Only if actual window/cap counters demonstrate useful work is credit-limited,
  compare `--initial-cwnd 65536 --max-cwnd 131072` at 10 connections, leaving the
  hard in-flight and proof/backlog caps fixed. More sockets alone do not increase
  global credit.

If snapshot-change rejection is a material fraction of completed input attempts,
use its residence/stage timings to justify a subsequent bounded refresh and full
revalidation under the original deadline. That behavioral change remains deferred
until these runs establish the cause; the current image preserves the exact-state
guard. Cache hits alone, more blocks, high CPU usage or high admission TPS do not
constitute a canonical TPS improvement. Keep the best repeatable valid result.
