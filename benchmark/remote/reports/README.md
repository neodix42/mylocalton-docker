# Native remote-client observations — 2026-09-07

The local screening below covers TON candidate [`9a587bc1`](https://github.com/corton-nommander/ton/commit/9a587bc1bee09158e4fa34cb5a877d933dae7841) and the remote runner changes in MyLocalTonDocker [`2cb6989`](https://github.com/neodix42/mylocalton-docker/commit/2cb6989). These results do **not** establish the capacity of the two 48-CPU remote servers.

The [latest remote 50-connection failure](native-remote-retry-followup-20260907.json) reported **50,753 canonical logical TPS** over 599 seconds but left **128 transfers / eight signed parents unresolved** after one source exhausted its retry horizon. It is invalid despite a complete follower catch-up and zero proof/hash errors. Its 1,466,011 not-ready retries and zero re-signings distinguish it from the earlier admission-timeout bug. The new worker keeps quarantined parents for reconciliation, charges retry time only while a task is the source head, and bounds explicit snapshot/revision retry delays; it does not erase exhaustion counters or relax proof/drain validity gates.

Both short screens used **4 client CPU equivalents / 8 GiB, 18 validator CPU equivalents, 4,096 source accounts, 10 workers, 32 signers, 15 seconds warm-up and 60 seconds measurement**. The canonical block-time denominator was 59 complete seconds. The existing validator process/image remained unchanged. The client images contained locally host-built native binaries bundled with their required runtime libraries, not the forthcoming published GHCR runtime. Baseline and candidate client images were prebuilt and reused by immutable ID; their IDs, commands' hashes and artifact paths are preserved in the JSON reports. The 40-CPU / 48-GiB `server48` client default was not measured here.

| Local setup | Canonical logical TPS | Outcome |
| --- | ---: | --- |
| Baseline, 10 connections, first arm | 67,022 | Clean, complete |
| Candidate, 10 connections, first arm | 69,079 | Clean, complete |
| Candidate, 10 connections, second arm | 67,746 | Clean, complete |
| Baseline, 10 connections, last arm | 67,442 | Clean, complete |
| Candidate, 300 connections | 56,495 | Clean, complete |
| Candidate, 500 connections | 54,223 | Clean, complete |

Every listed arm exited zero, resolved every offered cohort, finished with zero canonical backlog and retained the same validator identity. No listed arm hit the watchdog, OOM or retry exhaustion.

The [A/B/B/A report](native-remote-retry-local-abba-20260907.json) gives mean canonical TPS of **67,232 baseline and 68,412 candidate: +1.76% descriptively**. The paired changes were +3.07% and +0.45%; they do not demonstrate a repeatable 2% gain. Offered averages were below canonical averages in three of four arms, so this is not a qualified capacity improvement.

The [300/500-connection report](native-remote-retry-local-scale-20260907.json) confirms that both larger setups completed, but both were slower than either candidate 10-connection arm in this screen. More connections did not improve these local measurements. The settings retain a comparison-reference field of 10; actual scale-arm connection counts are recorded as 300 and 500 in `runs` and `connections_tested`.

The [600-second, 24,576-account, 10-connection follow-up](native-remote-retry-local-stable-20260907.json) completed cleanly at **53,740 canonical logical TPS**, with **53,805 offered/admitted TPS**. It counted 32,190,464 canonical transfers in 599 complete block-time seconds and proved all 2,253,654 signed parents across the full run. Final backlog and retry exhaustion were zero; the validator identity remained unchanged. There were 214 admission timeouts and 440,828 snapshot/revision not-ready responses, with zero generic not-ready responses, no re-signing and no canonical follower errors. The run used the same 4-CPU client / 18-CPU validator budgets, 60 seconds warm-up, initial/max windows 32,768/65,536 and 180 seconds allowed drain.

The [saved local Session Stats minute data](native-remote-retry-local-stable-dashboard-20260907.json) corroborates sustained minute-scale load: the **nine fully contained buckets starting at 19:22 through 19:30 UTC** averaged **54,012 workchain TPS**, with a minimum of **48,399** and maximum of **58,350**. These 60-second dashboard buckets cover 540 seconds and differ from the exact 599-second canonical measurement window used for the final generator TPS. This is the local desktop dashboard, not the remote server A dashboard.

The generator's internal ingress/chain capacity flags are true, but this is one valid local ten-minute observation, not evidence of maximum or remote-server capacity. Offered throughput exceeded canonical throughput by only **0.12%**, providing little excess offered load for a saturation claim. Its larger source population and longer duration differ from the short screens, so their TPS values are not directly comparable as a single-variable optimization result.

The [wider-window follow-up](native-remote-retry-local-wider-interrupted-20260907.json), planned for 600 seconds with 24,576 accounts and 10 connections, was **interrupted when the Docker daemon became unavailable**. It used the same 4-CPU client / 18-CPU validator budgets and initial/max admission windows **65,536/131,072**. Only launch configuration, image identities and 34 resource samples survived; the last resource sample was at 517.84 seconds of harness elapsed time. There is no saved final generator record, verified exit status or completed-cohort result. **Final TPS is unknown and the run is invalid.** Docker was not restarted by the reporting task; the cause of daemon loss is unknown. The artifact report preserves the available settings, last sample and source-file hashes. Keep the completed control's **32,768/65,536** default windows; this interrupted treatment provides no evidence to raise them.

Image publication **succeeded at 19:56:07 UTC**, and [anonymous registry plus CI verification](native-remote-retry-published-image-20260907.json) completed at 19:58:11 UTC. [Workflow 34154748668](https://github.com/corton-nommander/ton/actions/runs/34154748668) built and smoke-tested both AMD64 and ARM64 at TON `9a587bc1bee09158e4fa34cb5a877d933dae7841`; both generator help outputs explicitly advertise 1–1024 connections. `master`, `latest`, and the revision tag resolve to the same immutable image:

```text
ghcr.io/corton-nommander/ton@sha256:863bc4bd429a1ed8a92ed0417ace902bd4d9eb59212aed5043bd646c86ca9985
```

Platform config revision labels and current GitHub master match that source revision. The saved local throughput measurements used the separately described local runtime images; CI smoke checks verify the published runtime but do not constitute a remote TPS test.

Deploying the recovery and large-connection changes requires **TON `9a587bc1` or a descendant** and **MyLocalTonDocker `2cb6989` or later**. The earlier `a1e4c988` / `3288fa8d` revisions cover only the previous timeout-classification fix. With the published image revision now verified, stop load and perform a maintenance refresh on A with `bash start-native-genesis.sh --env-file .env`, retaining the existing project/database settings and volumes. Wait for healthy, advancing blocks, then create a fresh bundle with `bash benchmark/remote/export-native-client.sh`, copy it to B and import it into a new client directory. This updates the image as well as the runner; replacing only B's host script does not install the native fixes. Keep the imported immutable image fixed throughout each subsequent sweep.

The earlier remote ten-minute failure remains saved separately in [native-drain-failure-20260907.json](native-drain-failure-20260907.json). Its unresolved 32 transfers make that run invalid; it is not a clean throughput baseline.

For a future sweep that must attempt later setups despite an unresolved earlier arm, the runner supports explicit source isolation:

```sh
bash run-remote-load.sh --source-policy isolated \
  --connections 100 300 500 --duration 600
```

With 24,576 exported accounts, three setups receive 8,192 disjoint sources each, balanced across the four lanes. This changes the workload cardinality. An incomplete arm remains invalid and the whole sweep exits nonzero; later arms are observation-only because earlier admitted messages may still contribute to chain TPS. Isolation covers one sweep and does not reconcile a prior failed sweep's accounts. The default reuse policy requires clean, complete proof/cohort checks before another setup uses those sources. See the [runner guide](../README.md) for image capability checks and operating details.

## 8 September: native chart repair and connection scaling

The [current public-dashboard audit](native-chart-scaling-20260908.md) confirms the NTRN classifier bug and records five unlabelled sustained periods around 48.6k–51.7k canonical logical TPS. It explains the fixed global credit budget, reduced batch density at high connection counts, external-work waits and dormant staged-trie threshold. The audit is an observation, not a new validated benchmark or capacity claim.

Session Stats `97c4f771` fixes all native charts, adds native-only retained-history repair and a wait breakdown, and prevents subminute API rate inflation. All 16 tests and image publication passed; the report includes the verified image digest and commands to update only Session Stats while preserving its database.

## Eight-lane configuration — 2026-09-08

[Implementation and validation notes](native-eight-lanes-20260908.md) describe the new depth-3 physical-server default, manifest-derived exports, strict eight-lane readiness and acceptance checks, and the unmeasured live-TPS limitation. Historical four-lane results retain their original meaning.
