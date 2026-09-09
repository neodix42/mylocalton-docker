# Admission and block-overhead tests on A/B

The physical preset enables the selected desktop improvements: strict candidate
metadata projection and local overlay signature reuse, with configuration caching
and reconciliation timing on. Production throughput must be measured separately.
Keep four lanes as the historical reference and retain the existing eight-lane
state. Compare settings on the **same topology** before another lane comparison.
Never change an existing eight-lane database's depth/split values to 2.

## Prepare once, before measurement

Update the `native-payment-lanes-step6` MyLocalTonDocker branch on A. Wait for the
[TON image workflow](https://github.com/corton-nommander/ton/actions/workflows/docker-ubuntu-branch-image.yml)
to finish successfully for the intended `master` revision containing the selected
features. A merged commit or running workflow is not a published image. Record
that successful run's full 40-character source SHA as `TON_EXPECTED_REVISION`.
The release submitted for this rollout is
[`8c97aa23f1e2859651f4a85c6f6609016b42b0da`](https://github.com/corton-nommander/ton/commit/8c97aa23f1e2859651f4a85c6f6609016b42b0da),
with [publication run 34357000846](https://github.com/corton-nommander/ton/actions/runs/34357000846).
Verify that run's successful completion before using this SHA; submission alone
does not confirm publication.
Apply these entries to A's existing `.env`; preserve its project name, mounted
database, eight-lane depth/split values, funded accounts, endpoints, resource
limits and TTL settings:

```dotenv
TON_BRANCH=master
TON_IMAGE=ghcr.io/corton-nommander/ton
NATIVE_LOAD_IMAGE=mylocalton-native-load-generator:master
TON_BUILD_PULL=true
TON_NATIVE_ADMISSION_CONFIG_CACHE=1
TON_NATIVE_CANDIDATE_METADATA_PROJECTION=1
TON_OVERLAY_LOCAL_SIGNATURE_REUSE=1
TON_NATIVE_RECONCILIATION_PROFILE=1
TON_KEYRING_PREPARED_SIGNING=0
TON_NATIVE_ADMISSION_SHARD_SHARING=0
TON_NATIVE_ADMISSION_SNAPSHOT_REFRESH=0
```

Stop and drain B's current test before maintenance. From the MyLocalTonDocker
directory on A, pull the latest published master and prepare both wrappers from
its immutable digest, requiring the verified workflow revision before startup:

```sh
export TON_EXPECTED_REVISION=PUT_FULL_SUCCESSFUL_WORKFLOW_HEAD_SHA_HERE
bash prepare-native-images.sh --env-file .env \
  --expected-revision "$TON_EXPECTED_REVISION"
docker compose --env-file .env \
  up -d --no-deps --no-build --pull never genesis
```

Preparation rebuilds both genesis and the generator from that same registry
digest, even when an older local `:master` generator exists. A revision mismatch
stops preparation; verify the newer successful workflow before selecting another
expected SHA. Compose preserves the existing database. Wait for healthy, advancing
blocks, then verify the receipt against the resolved services and running genesis:

```sh
python3 - <<'PYIMAGES'
import json, os, pathlib, re, subprocess
def docker_json(*args):
    return json.loads(subprocess.check_output(['docker', *args], text=True))
expected = os.environ['TON_EXPECTED_REVISION']
assert re.fullmatch(r'[0-9a-f]{40}', expected), 'Use the full successful workflow SHA'
receipt = json.loads(pathlib.Path('.native-images.json').read_text())
assert receipt['schema'] == 'native-images-v1'
assert receipt['base']['revision'] == expected
config = docker_json('compose', '--env-file', '.env', '--profile',
                     'native-load-generator', 'config', '--format', 'json')
genesis = docker_json('inspect', 'genesis')[0]
assert genesis['State']['Running'] and genesis['State']['Health']['Status'] == 'healthy'
for service in ('genesis', 'native-load-generator'):
    saved = receipt['services'][service]
    assert config['services'][service]['image'] == saved['reference'], service + ': configured image changed'
    image = docker_json('image', 'inspect', saved['reference'])[0]
    assert image['Id'] == saved['id'], service + ': prepared tag changed'
    assert saved['revision'] == image['Config']['Labels']['org.opencontainers.image.revision'] == expected
    if service == 'genesis':
        assert genesis['Image'] == image['Id'], 'Running genesis differs from the prepared image'
print('Verified matching prepared/running images at revision', expected)
PYIMAGES
```

Only after this check, export the prepared generator and import the bundle on B
using the normal private transfer procedure:

```sh
bash benchmark/remote/export-native-client.sh --env-file .env --no-build-image
```

`--no-build-image` freezes the existing configured generator. The updated exporter
requires full, matching TON revision labels on the generator and running genesis;
it rejects a stale or unlabeled generator without rebuilding. The receipt check
above additionally binds this rollout to its prepared image IDs and expected
workflow revision. Run B's importer in a new client directory
and use its newly pinned image, preserving old results and source-reuse checks.

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
| A configuration cache / metadata projection / overlay reuse | 1 / 1 / 1 |
| A reconciliation timing / prepared signing / sharing / refresh | 1 / 0 / 0 / 0 |
| Candidate timeout / finalize reserve | Retain 8000ms / 1000ms |
| Ingress checkpoint retention | 0 |

Keep 24,576 sources and the exported lane depth fixed. These are controlled
starting settings, not a measured optimum. Successful drain/proof checks remain
required before account reuse. An invalid arm must not be relabelled a capacity win.

## Measure the selected configuration

Wait for healthy, advancing blocks before each arm. In a separate terminal on A,
start the read-only sampler before starting B:

```sh
sudo python3 benchmark/remote/profile-native-validator.py \
  --container genesis --duration 1200 --interval 30 \
  --dashboard-url http://127.0.0.1:18000 --output "$HOME/profile-selected-01"
```

On B, from the newly imported client directory:

```sh
bash run-remote-load.sh --connections 10 --duration 600 --warmup 60 \
  --initial-cwnd 32768 --max-cwnd 65536 --submit-coalesce-ms 20
```

For an optional matched production comparison of metadata projection, stop and
drain B, then prepare the control without pulling or rebuilding either image:

```sh
TON_NATIVE_CANDIDATE_METADATA_PROJECTION=0 \
docker compose --env-file .env up -d --no-deps --no-build --pull never --force-recreate genesis
```

Wait for healthy, advancing blocks, use a new sampler output directory and run
the identical B command. Repeat with `TON_NATIVE_CANDIDATE_METADATA_PROJECTION=1`
for the treatment. Use **off/on/on/off**, recreating and settling A consistently
even between the two on arms. Recreation changes process identity; the image,
database, settings other than the metadata flag and workload stay fixed. The
shell override applies to that recreation only; restore the selected `.env`
configuration after the final arm has drained. Do not change flags during an arm.

The sampler starts no services and never stops the validator. Ctrl-C stops only
sampling and saves partial evidence. It requires a local Docker Unix socket and
host `/proc` access. Increase sampler duration if B's readiness takes longer;
match `samples.jsonl` timestamps to B's final measurement window. The sampler's
whole-window means can include readiness, warm-up and drain. Optional dashboard
files use basechain-only statistics; missing/empty dashboard data is not zero TPS
and cannot replace B's proof-checked final result.

## Read the evidence before selecting another treatment

### Optional reconciliation timing

With a validator image containing the reconciliation diagnostics, set
`TON_NATIVE_RECONCILIATION_PROFILE=1` in A's selected environment file before a
diagnostic restart. The physical rollout preset already sets it to `1`; the
Compose fallback remains `0`. Use the existing strict-reuse recreation command only after B has drained,
then wait for healthy, advancing blocks. Keep the setting identical for both
arms, and start the usual read-only sampler:

```sh
sudo python3 benchmark/remote/profile-native-validator.py \
  --container genesis --duration 1200 --interval 30 \
  --output "$HOME/profile-reconciliation-01"
```

The new `summary.json.reconciliation` section reports lookup/unpack/application
stage means and account-outcome fractions using only reconciliation's own
`apply_calls`. It verifies that first observations, nonce advances, balance-only
changes, unchanged accounts and errors sum to those calls. A reset, missing
counter, changed timing flag or unmatched outcomes suppresses derived attribution.
The new stats group is optional when reading older recordings.

Outcome/work counters remain available with timing disabled; missing stage
means do not mean zero work. Balance changes and mutation effects overlap the
exclusive outcomes. An unchanged account can still require expiry and reservation
processing. Do not divide the older `sources_advanced` counter by reconciliation
lookups: admission also increments that historical counter. The sampler excludes
the timing-enable gauge and lifetime maxima from counter differences, and records
the configured flag in `identity.json`.

### Existing admission and block evidence

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

The bounded snapshot-refresh implementation is available but remains off: its
desktop screen reduced not-ready retries without improving TPS. Request sharing
also remains off after its separate screen. Cache hits alone, more blocks, high CPU usage or high admission TPS do not
constitute a canonical TPS improvement. Keep the best repeatable valid result.

### Profile-led signing experiments (9 September)

The local CPU candidates are `TON_KEYRING_PREPARED_SIGNING=0|1` and
`TON_OVERLAY_LOCAL_SIGNATURE_REUSE=0|1`. Prepared signing remains off.
The completed September 9 overlay A/B/B/A comparison averaged 57,673 versus
60,040 canonical logical TPS (+4.10%), with full proof/drain and fixed images.
The physical rollout preset now also enables overlay reuse; its eight-lane
production result remains to be measured. The C++/Compose fallback stays off.
The first reuses an immutable prepared Ed25519 key inside its owning keyring
signer. The second targets only cryptographic evidence from a successful local
broadcast-signing callback; incoming messages retain signature verification.
Neither changes the client wire format. Check the built revision before testing:
Compose forwarding a variable does not prove an older image implements it.

Use a single prebuilt image, change one flag at a time, restart/settle genesis
before starting an arm, and retain canonical proof/drain and strict-reuse checks.
The profiler records both flags in the container identity. Keep topology, client
load, 20 ms coalescing and candidate timeouts fixed. A sampled CPU share is an
optimization opportunity, not an expected percentage TPS improvement.

### Strict candidate metadata projection

`TON_NATIVE_CANDIDATE_METADATA_PROJECTION=0|1` remains off in the C++/Compose
fallback; the measured desktop and authorized physical rollout presets enable it.
For direct native runs it extracts each checked parent hash and
source/nonce interval without building the flattened execution entries and
derived account table. It retains strict field, count, tree and canonical-root
validation; scalar versions use the original parser. It adds no cross-candidate
cache and changes no fork, nonce-floor or account-state validation policy.

The profiler and wrapper record the flag. Use a new image implementing it, and
compare 0/1 using that same prebuilt image with local signature reuse fixed at
the selected setting. Keep 600-second measurements and 20 ms coalescing. Do not
enable this candidate on production solely because Compose accepts its variable.

The four September 9 metadata runs observed control TPS 59,784.97 / 60,618.60
and candidate TPS 61,380.86 / 62,537.54: means **60,201.79→61,959.20 (+2.92%)**.
All proof, drain and image checks passed. Both candidates beat both controls;
mean sampled validator CPU was 4.59% lower. Rebuildable-cache cleanup preceded
the last control, so this is a disclosed desktop observation and selection,
not an uninterrupted identical-host experiment or a capacity claim.

`.env.desktop` pins the existing local `admission-local-7b73cdb1` images and keeps
overlay reuse 1, configuration cache 1, metadata projection 1, and prepared
signing/sharing/refresh 0. Use Compose `--no-build --pull never`; these native-CPU
images remain local desktop artifacts. Server A uses the separately published
portable master image and the preparation/receipt checks above. The complete record and maintenance
limitations are in the TON repository's
[metadata report](https://github.com/corton-nommander/ton/blob/master/doc/native-candidate-metadata-cycles-2026-09-09.md).
