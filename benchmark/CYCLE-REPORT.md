# Native benchmark cycle report

This ledger records destructive fresh-state benchmark cycles run from the
physical desktop profile. TPS is accepted only when the generator reports a
complete proof-checked run, clean drain, and valid ingress and chain capacity.

## Cycle 0 — diagnostic baseline (20260831T134111Z)

- TON revision: `6e11391c`
- Target: 4,000 offered TPS
- Result: invalid; generator exit 2 after the full 1,800-second measurement and
  600-second drain.
- Full-window offered/admitted/canonical: 313.78 / 291.43 / 295.81 TPS.
- Productive canonical slice: about 3,131 TPS before permanent admission stall.
- Proof correctness: valid, final catch-up complete, zero follower errors.
- Failure: a cancelled duplicate seqno-221 candidate incorrectly finalized
  2,257 native messages. The poisoned nonce watermark caused 1,944,427
  `not_ready` retries, 15,148 retry exhaustions, 65,536 active tasks, and a
  final backlog of 67,793.
- Secondary failure: one 10,585,196-byte candidate exceeded the 10,485,760-byte
  consensus maximum.
- Cadence: zero deadline timeouts; productive accepted-block interval averaged
  about 0.505s, with 2.307s p95.
- Artifact directory: `benchmark-results/20260831T134111Z`.

## Cycle 1 — valid fork/size/retry smoke (20260831T153959Z)

- TON image revision label: `6e11391c-dirty-7941c081dbe3`.
- Fresh profile: 4,096 source/destination pairs, 4,000 target TPS, 60-second
  ramp, 60-second warm-up, 700-second measurement, and 300-second maximum
  drain. The measured run crossed four basechain catchain boundaries.
- Result: valid; generator exit 0. Offered and admission throughput were both
  4,000.007 TPS. The exact proof-checked chain window produced 4,006.485 TPS
  (2,800,533 transfers in 699 complete `gen_utime` seconds). All 3,159,991
  messages offered over the complete run were admitted and canonically
  proof-matched; drain took 1.456 seconds.
- Correctness: final backlog, active tasks, nonce gaps, hash/nonce conflicts,
  follower lag/errors/reorgs, retry exhaustion, and canonical backpressure
  were all zero. Correctness, completion, ingress-capacity, and chain-capacity
  decisions were all valid.
- Fork regression: seqno 696 was collated twice across the cc2-to-cc3
  transition. The losing 11,871-transfer candidate was never accepted; the
  replacement 13,155-transfer candidate was accepted. No messages vanished
  from the canonical chain, directly exercising the cancelled-accept fix.
- Size regression: maximum actual candidate size was 3,519,072 bytes; maximum
  estimator undercount was 169,526 bytes. Hard-preflight failures, size-guard
  deferrals, and serialized oversize bytes were zero.
- Measured candidate cadence: accepted interval average 1.028 seconds,
  p95 4.834 seconds, max 5.137 seconds. Collation wall p95 was 4.657 seconds;
  validation p95 was 193 ms. There were no measured deadline seals, deferrals,
  validation rejects, or skip votes.
- Remaining bottleneck: native commit averaged 589 ms and reached 3.540 seconds
  p95; checkpoint rebuilding accounted for most of that long tail, followed by
  staged dictionary updates. Validator use averaged 5.37 and peaked at 7.35 of
  16 assigned CPUs; generator use averaged 0.79 and peaked at 1.01 of 6 CPUs.
  Host iowait averaged 0.79%, so CPU quotas, generator capacity, memory, disk,
  and serialized size were not the 4k limiter.
- The generator recovered 441,439 exact canonical-snapshot-lag responses and
  506 generic not-ready responses without exhausting a source. Its O(1)
  source scheduler handled 1,011,726 blocked-head notifications with zero
  legacy global scans or stale ready entries.
- Artifact directory: `benchmark-results/20260831T153959Z`. The original
  wrapper invocation stopped after `image-metadata.json` because installed
  Compose requires a service argument for `config --hash`; the benchmark data
  itself was complete. `run-metadata.json` and `benchmark-summary.json` were
  reconstructed with that limitation recorded in reproducibility reasons. The
  wrapper now enumerates and hashes each resolved service explicitly, with a
  reporting self-test regression assertion.

## Cycle 2 — checkpoint optimization / canonicalization failure (20260831T171053Z)

- TON image revision label: `6e11391c-dirty-e7113146bffe`. The guarded runner
  prebuilt both derived images, then recreated all four scoped volumes at
  17:10:55Z. The zero state contained 4,096 fresh source/destination pairs.
- Workload: 6,000 target TPS, 60-second ramp, 60-second warm-up, 700-second
  measurement, and 300-second maximum drain.
- Result: invalid; generator exit 2 after drain timeout. Measured-window
  offered/admitted/proof-chain throughput was 3,435.354 / 3,320.049 /
  3,314.964 TPS. Target attainment was 57.26%.
- The proof follower itself remained valid: it completed final catch-up with
  zero hash conflicts, reorgs, fatal errors, or final lag. The run nevertheless
  exposed a second irreversible-finalization bug. Four old-session candidates
  were locally `blockAccepted` and then replaced by the next catchain session:
  seqnos 567, 568, 734, and 735 carried 767, 406, 2,147, and 174 native
  transfers respectively. Their sum is 3,494, exactly the difference between
  2,865,046 transfers in locally accepted candidates and the final canonical
  proof total of 2,861,552. A successful local apply is therefore not a safe
  native nonce-finalization boundary; only the masterchain-referenced shard
  state is canonical.
- Completion failed with 83,182 offered-but-unproven hashes, an equal nonce-gap
  count, and incomplete measured and total cohorts. Of 2,090 elapsed-horizon
  source quarantines, 2,022 were exact canonical-state-lag exhaustions. The
  node returned 1,017,277 exact `canonical native account state has not caught
  up with finalized balance` responses.
- The checkpoint refactor itself passed. All 627 measured native collations
  reported exactly one fast-path invocation and one pre-native baseline.
  2,366,723 candidate inputs required 7,908 rebuilds, or 299.28 transfers per
  rebuild versus 25.53 in Cycle 1 (11.7x improvement). Native commit
  average/p95/max fell to 0.125/0.328/1.446 seconds; checkpoint rebuild
  average/p95/max fell to 0.045/0.164/0.704 seconds. Collated-block total p95
  was 2.251 seconds.
- Size/correctness safety remained clean: maximum actual/estimated candidate
  size was 3,635,251/4,703,539 bytes, maximum positive estimator gap was
  163,752 bytes, and hard-preflight failures, size deferrals, and serialized
  overshoots were zero.
- Primary failure: local block acceptance advanced irreversible pool watermarks
  for the four candidates that the masterchain later replaced. The resulting
  permanently impossible account-state catch-up accounts for most of the 2,022
  exact canonical-lag source quarantines, so this run is not a valid 6k capacity
  ceiling. A secondary amplification came from native admission pinning the
  manager's deliberately delayed liteserver masterchain snapshot. The generator
  averaged only 0.60 CPU cores; raising generator CPU is not a remedy. The next
  cycle must make the masterchain-referenced shard state the only authority for
  purging native nonces and also pin the freshest locally applied masterchain
  state for admission.
- Artifact directory: `benchmark-results/20260831T171053Z`.

## Cycle 3 — canonical cleanup / reconciliation feedback loop (20260831T184706Z)

- TON image revision label: `6e11391c-dirty-18fc7605c0cf`. This was a fresh
  4,096-source run at 6,000 target TPS, with a 60-second ramp, 60-second
  warm-up, 700-second measurement, 300-second maximum drain, and 90-second
  source-head retry horizon.
- Result: invalid; generator exit 2 after 1,120.015 seconds. Measured-window
  offered/admitted/proof-chain throughput was 1,283.984 / 1,282.507 /
  1,141.712 TPS, only 21.40% target attainment. Total offered/admitted/
  canonical messages were 1,438,782 / 1,437,748 / 1,437,157.
- Canonical correctness remained clean. The proof follower completed catch-up
  with zero fatal errors, hash conflicts, reorgs, or final lag; its maximum lag
  was five blocks. Exactly 340 positive-transfer accepted roots tracked
  1,437,157 messages, equal to both the accepted-root transfer sum and the
  proof-matched canonical total. The run crossed eight catchain sessions but
  had no duplicate seqno with two accepted roots, so it did not exercise the
  losing-accepted-root path covered by the focused scheduler regression test.
- Completion failed after 453.785 measured seconds of canonical backpressure.
  The final backlog and nonce-gap count were both 1,625; 45 sources exhausted
  the retry horizon, while exact canonical-state-lag exhaustion stayed zero.
  Validator cleanup also remained incomplete with 45 reconciliation sources
  and 691 messages in 45 native-pool accounts.
- Primary bottleneck: every applied masterchain state reconciled all pending
  sources even when it referenced the same unchanged basechain top. The run
  performed 1,964 reconciliation state fetches and 5,106,501 account lookups,
  6.54x the 780,654 admission account lookups. During the first major stall,
  573 scans had already performed 2,065,347 lookups while the referenced shard
  top remained at seqno 322. Masterchain-to-shard time lag eventually reached
  232 seconds: initially a consequence of stalled basechain finality, then the
  trigger for a CPU-consuming positive feedback loop of redundant scans.
- Candidate work was not intrinsically expensive. In the measured window,
  collation CPU work averaged 57 ms, while external wait averaged 400 ms and
  reached 10.539 seconds. Accepted-block intervals averaged 2.941 seconds,
  with 4.784-second p95, 24.857-second p99, and 225.573-second maximum; the
  largest later gaps were 234.957 and 145.815 seconds. The generator averaged
  only 0.246 and peaked at 1.887 CPU cores, while live validator use repeatedly
  approached its 16-vCPU allocation. Generator CPU was not the limiter.
- The checkpoint optimization remained effective: 814,030 measured native
  inputs required 2,932 rebuilds (277.64 inputs per rebuild). Measured native
  commit averaged 181 ms with 848 ms p95; hard-preflight failures, size
  deferrals, and serialized oversize bytes were zero.
- Artifact directory: `benchmark-results/20260831T184706Z`.

## Cycle 4 — canonical cleanup passes; cadence ceiling (20260831T200159Z)

- TON image revision label: `6e11391c-dirty-c9e6abade27d`. The source image
  built in 2m53s, both derived images were verified before teardown, and all
  four scoped volumes were recreated at 20:02:01Z. Genesis created all 8,192
  wallets with zero reuse. The profile assigned 18 logical CPUs to genesis,
  four to the generator, and one quota CPU to Session Stats.
- Workload: the same fresh 4,096 sources, 6,000 target TPS, 60-second ramp,
  60-second warm-up, 700-second measurement, 300-second maximum drain, and
  90-second source-head retry horizon.
- Result: proof-correct and complete, but not a 6k capacity pass. The generator
  and wrapper exited 0; `benchmark_result_valid`, `chain_correctness_valid`,
  and validator cleanup were true. Measured offered/admitted/proof throughput
  was 3,673.689 / 3,673.177 / 3,675.197 TPS (61.23% target attainment).
  Canonical backpressure occupied 60.978 seconds, or 8.711% of the measured
  window, so ingress and chain-capacity decisions were false.
- Every one of the 3,111,557 offered hashes was canonically proof-matched.
  Final catch-up completed in 6.340 seconds with zero backlog, nonce gaps,
  retry/horizon exhaustion, hash conflicts, follower errors, reorgs, or final
  lag. Validator cleanup ended with reconciliation pending sources zero and
  native-pool accounts/messages zero/zero.
- The hard cross-session race occurred four times. Seqnos 286, 415, 437, and
  438 each had two different locally accepted roots across catchain sessions;
  seqno 286's replacements were 9.466 seconds apart. The four losing roots
  carried 9,728, 2,832, 512, and 512 transfers: their 13,584 sum exactly equals
  `tracked_messages` 3,125,141 minus canonical/purged messages 3,111,557.
  Canonical reconciliation purged every canonical message and left no residue.
  This is direct runtime proof that local acceptance no longer irreversibly
  advances native nonce state.
- The unchanged-state gate reduced reconciliation work from Cycle 3's 1,964
  state fetches / 5,106,501 account lookups to 387 / 1,408,653 (-80.3% /
  -72.4%). There were 234 whole-state skips, zero reconciliation failures,
  zero scheduler head gaps of every typed class, and 2,545,105 safe revision
  rebases. Throughput increased 3.22x over Cycle 3 and all 45 exhausted sources
  disappeared.
- Native block work is no longer the long pole. Measured collation CPU work
  averaged 65 ms; total collation wall p95/max was 2.844/7.314 seconds, and
  validation p95/max was 259 ms/4.312 seconds. Native commit averaged 145 ms
  with 622 ms p95. Size guard failures, deferrals, and serialized overshoots
  were zero.
- Consensus cadence remained bursty: accepted-block interval p50/p95/p99/max
  was 0.353/6.931/16.740/42.180 seconds. The window had 450 basechain collate
  starts, 418 accepted blocks, and 56 skip votes. Long stalls were followed by
  sub-second block bursts; at least one stall ended with a candidate timeout.
  Genesis averaged 11.03 CPU cores and repeatedly reached its allocation,
  while the generator averaged 0.714 and peaked at 2.838 of four cores.
- Admission batching amplified that contention. A 2 ms coalescing window
  produced 3,416,891 wire attempts in 1,078,309 queries: only 3.17 messages per
  64-message batch. Median/p95/p99 admission RTT was 50/200/1,000 ms. Cycle 5
  should first increase coalescing to reduce liteserver queries, state pins,
  and actor wakeups before changing consensus timeouts or generator CPU.
- Artifact directory: `benchmark-results/20260831T200159Z`.

## Cycle 5 — 20 ms admission coalescing (20260831T211606Z)

- TON image revision label: `6e11391c-dirty-1e4abc7bd69d`. This was another
  destructive fresh-state run with 4,096 sources, 6,000 target TPS, a
  60-second ramp, 60-second warm-up, 700-second measurement, 300-second
  maximum drain, and the same 18/4/1 CPU split. The only workload-pressure
  change from Cycle 4 was submit coalescing from 2 ms to 20 ms; adaptive CWND
  remained uncapped.
- Result: proof-correct and complete, but still not a 6k capacity pass. The
  generator and wrapper exited 0; `benchmark_result_valid`, canonical
  correctness, run completion, and validator cleanup were true. Measured
  offered/admitted/proof throughput was 4,241.874 / 4,241.357 / 4,139.907 TPS
  (70.70% target attainment). The measured-offer cohort was observed at
  4,055.030 TPS.
- All 3,509,285 offered hashes were canonically proof-matched. Admission
  returned success for 3,508,923; the remaining 362 were recovered by exact
  canonical inference. Final catch-up completed with zero backlog, nonce gaps,
  retry exhaustion, follower errors, reorgs, final lag, or hash/nonce
  conflicts. Drain-to-anchor took 39.688 seconds.
- Canonical reconciliation remained correct across replaced local roots. It
  tracked 3,515,268 messages and purged exactly the 3,509,285 canonical
  messages, leaving zero pending sources and zero native-pool accounts or
  messages. The 5,983-message difference was retained only as reversible
  accepted-root history and did not contaminate the canonical nonce prefix.
- Coalescing worked as intended. Even while wire attempts increased to
  3,881,330 with the higher useful rate, liteserver queries fell from Cycle
  4's 1,078,309 to 445,942 (-58.6%). Average occupancy rose from 3.17 to 8.704
  messages per 64-message query. Proof TPS improved 12.6% and offered TPS
  improved 15.5% over Cycle 4 without additional generator CPU.
- The remaining failure was cadence rather than native block computation.
  Measured basechain accepted intervals averaged 1.296 seconds with
  0.314/5.003/12.867/64.718-second p50/p95/p99/max. Collation CPU work averaged
  only 50 ms and native commit averaged 76 ms with 308 ms p95; actual block
  size reached 3,668,161 bytes, with zero hard-preflight failures, size
  deferrals, or serialized overshoot.
- Measured canonical backpressure improved from Cycle 4's 8.711% to 44.666
  seconds / 6.381%, but remained well above the 1% capacity gate. The uncapped
  AIMD window peaked at 1,593.618 messages before falling to 821.124. The
  generator saw 360,409 `not_ready` retries and 3,279 timeouts without any
  exhausted source.
- Genesis averaged 9.92 CPU cores and the generator only 0.60; host iowait
  averaged 1.04%. The 64.718-second basechain gap, despite sub-second native
  commit work and spare aggregate compute, shifted the next experiment from
  batching and block construction to admission-pressure control and actor
  scheduling latency.
- Artifact directory: `benchmark-results/20260831T211606Z`.

## Cycle 6 — global adaptive-CWND cap (20260831T220650Z)

- TON image revision label: `6e11391c-dirty-24e59acdb83b`. The guarded runner
  recreated exactly the four scoped volumes at 22:06:52Z; genesis created all
  8,192 source/destination wallets with zero reuse. Workload, phase lengths,
  CPU allocation, and 20 ms coalescing were identical to Cycle 5. The isolated
  change was a global adaptive-CWND cap of 768 messages, one complete
  64-message batch for each of the 12 persistent connections.
- Result: proof-correct and complete, but not a 6k capacity pass. The generator
  and wrapper exited 0 after 837.787 seconds of generator runtime. Measured
  offered/admitted/proof throughput was 3,868.856 / 3,868.584 / 3,853.548 TPS
  (64.48% target attainment); the measured-offer cohort was observed at
  3,759.916 TPS.
- All 3,248,163 offered hashes were canonically proof-matched. Admission
  returned success for 3,247,973 and exact canonical inference recovered the
  other 190. Final catch-up completed with zero backlog, nonce gaps, retry
  exhaustion, follower errors, reorgs, final lag, or conflicts. Drain-to-anchor
  fell to 17.785 seconds.
- The accepted-root replacement regression was exercised eight times at
  seqnos 329, 516, 517, 686, 687, 688, 764, and 765. Their losing roots carried
  1,950 + 373 + 146 + 1,244 + 512 + 512 + 3,003 + 1,205 = 8,945 transfers,
  exactly `tracked_messages` 3,257,108 minus canonical/purged messages
  3,248,163. Cleanup ended with zero pending sources and zero native-pool
  accounts/messages.
- The cap achieved its narrow goal: measured canonical backpressure fell to
  2.700 seconds / 0.386%, basechain maximum accepted interval fell from 64.718
  to 23.192 seconds, and drain time fell 55.2%. The masterchain maximum
  interval remained 38.053 seconds. All 12 clients reached the cap; the
  initial/final/peak window was 300/768/768 and 1,012,639 acknowledgements were
  cap-limited.
- The cap was nevertheless overbinding. Versus Cycle 5, offered/admission TPS
  fell 8.79% and proof TPS fell 6.92%, while `not_ready` retries rose from
  360,409 to 627,919. Average measured transfers per collated basechain block
  fell from 5,509.8 to 4,792.5. Ingress capacity failed only because the offer
  target was not attained; chain capacity failed because offered load was not
  sufficiently above observed canonical throughput.
- Batching remained healthy at 3,878,884 attempts in 432,684 queries, or 8.965
  messages/query. Native block work again was not the long pole: collation CPU
  averaged 48 ms, native commit averaged 68 ms with 219 ms p95, and maximum
  actual block size was 3,503,959 bytes. Size/preflight counters were clean.
  Genesis averaged 10.41 CPU cores, the generator 0.60, and host iowait 1.02%,
  excluding generator CPU, disk, memory, and native execution throughput as
  the primary limiter.
- A live `get-actor-stats` capture during the stall exposed the hidden
  scheduler bottleneck. `OverlayImpl` consumed 1.038 core over the last ten
  seconds, one mailbox execution reached 19.886 seconds over ten minutes and
  38.984 seconds lifetime, the ten-minute execution maximum covered 167,180
  messages, and the actor was observed executing continuously for 9.333
  seconds. Source tracing showed the actor executor drains a mailbox until it
  becomes empty, while overlay traffic accounting enqueues a closure for each
  packet/query/response. Under saturation these cheap updates can keep the
  mailbox permanently runnable and delay consensus alarms even though
  individual handlers and native block work are short.
- Artifact directory: `benchmark-results/20260831T220650Z`. The actor snapshot
  was an explicit live diagnostic outside that artifact directory; Cycle 7
  adds serialized actor-stat artifacts to the wrapper.

## Cycle 7 — traffic-update yields (invalid benchmark; chain-correct) (20260831T225856Z)

- TON image revision label: `6e11391c-dirty-1942c7bc5a44`. This retained
  Cycle 6's fresh 4,096-source, 6,000-TPS, 60/60/700/300-second workload,
  20 ms coalescing, 65,536 proof inflight, and 768-message global CWND cap.
  The isolated runtime treatment asked `OverlayImpl` to yield after every 64
  inbound/outbound traffic-accounting updates.
- Result: invalid and incomplete, but chain-correct. Recovered measured
  offered/admitted/proof throughput was 2,969.629 / 2,969.629 / 2,808.086
  TPS. Canonical backpressure consumed 226.377 seconds, or 32.340% of the
  measured window; drain timed out with 131,072 backlog entries and the same
  number of nonce gaps.
- Proof safety remained valid. The follower completed final catch-up with zero
  fatal errors, hash conflicts, reorgs, exhausted follower retries, or final
  lag. It matched 2,487,633 canonical hashes out of 2,618,705 offered; the
  missing 131,072 are the explicitly incomplete cohort, not a proof mismatch.
- The treatment did not address the dominant mailbox traffic. The final actor
  capture saw only about 0.12 traffic-fairness yields/s, while one
  `OverlayImpl` turn still processed 175,055 messages for 25.156 seconds; one
  handler reached 0.921 seconds. Validator cleanup was also incomplete with
  546 reconciliation sources and 131,072 native-pool messages remaining.
- The wrapper aborted during postprocessing and produced no usable periodic
  actor rows; the final generator, validator, pool, and manual actor artifacts
  were recovered and checksummed. This recovery limitation does not change the
  proof-correct/benchmark-invalid classification.
- Artifact directory: `benchmark-results/20260831T225856Z`.

## Cycle 8 — FEC callback yields (invalid benchmark; chain-correct) (20260831T233358Z)

- TON image revision label: `6e11391c-dirty-f410e0b6867b`. Workload and
  pressure controls were unchanged. In addition to Cycle 7's traffic-counter
  yield, generated and signed FEC callbacks shared a recurring 64-callback
  yield quantum.
- Result: invalid and incomplete, but chain-correct. Measured offered/admitted/
  proof throughput was 3,499.560 / 3,491.267 / 3,361.894 TPS (58.326% offered
  target attainment). Backpressure fell to 51.082 seconds / 7.297%, but the
  300-second drain still ended with 5,781 backlog entries and nonce gaps, and
  107 source heads exhausted their retry horizon.
- The new path was active: measured ten-minute FEC fairness yield rate reached
  53.532/s. `OverlayImpl`'s ten-minute maximum fell from Cycle 7's 175,055
  messages / 25.156 seconds to 18,269 / 4.431 seconds. This was a material
  reduction, but still far above the bounded-turn target.
- The proof follower completed final catch-up with zero fatal errors, hash
  conflicts, reorgs, or final lag. Validator cleanup was clean: zero pending
  reconciliation sources and zero native-pool accounts/messages. Thus the
  failure is completion/capacity, not chain correctness or validator residue.
- Artifact directory: `benchmark-results/20260831T233358Z`.

## Cycle 9 — Overlay mailbox quantum (invalid benchmark; chain-correct) (20260901T002710Z)

- TON image revision label: `6e11391c-dirty-429b81004eef`. The unchanged
  workload added an actor-executor opt-in quantum of 64 mailbox messages for
  `OverlayImpl`, while retaining both earlier yield policies.
- Result: invalid and incomplete, but chain-correct. Measured offered/admitted/
  proof throughput was 3,258.881 / 3,252.830 / 3,253.768 TPS (54.315% target
  attainment). Backpressure was 96.505 seconds / 13.786%; drain timed out with
  4,232 backlog entries/gaps and 88 retry-exhausted source heads.
- The executor treatment bounded mailbox monopolization as designed.
  `actor_mailbox_quantum_yield` reached 135.765/s over ten minutes and
  `OverlayImpl.max_execute_messages` stayed at 66. Its worst execution was
  0.773 seconds, almost entirely one 0.766-second handler, showing that a
  mailbox-count quantum cannot preempt expensive individual messages.
- Basechain and masterchain maximum accepted intervals were 27.539 and 27.020
  seconds, respectively. Proof correctness and final follower catch-up were
  clean, as was validator cleanup, but completion, ingress capacity, and chain
  capacity all remained invalid.
- Artifact directory: `benchmark-results/20260901T002710Z`.

## Cycle 10 — validator CPU/thread redistribution (invalid benchmark; chain-correct) (20260901T005833Z)

- This reused the exact Cycle 9 TON revision label
  `6e11391c-dirty-429b81004eef` and kept the same load/fairness settings, but
  deliberately changed the resource treatment: validator quota 18 to 20 CPUs,
  actor threads 16 to 18, and generator quota 4 to 2 CPUs on disjoint cpusets.
  It also reduced actor-stat observation to pre-load, measure-end, and
  post-drain only. Consequently this is a resource experiment with a
  low-perturbation observation schedule, not a one-variable sampling A/B.
- Result: invalid and incomplete, but chain-correct. Measured offered/admitted/
  proof throughput was 3,080.801 / 3,078.983 / 2,974.375 TPS (51.347% target
  attainment). Backpressure worsened to 260.995 seconds / 37.285%; drain timed
  out with 853 backlog entries/gaps and 30 retry-exhausted source heads.
- Removing nearly all observer perturbation did not restore cadence. Maximum
  accepted intervals reached 33.107 seconds on basechain and 61.467 seconds on
  masterchain. `OverlayImpl` remained turn-bounded at 66 messages, while a
  single handler still reached 0.545 seconds. Validator mean CPU rose to 14.760
  cores, 23.4% above Cycle 9, while proof TPS fell 8.6%; the extra workers
  increased host saturation/contention instead of curing the serialized tail.
  Generator throttling was negligible, so its two-CPU quota was not the cause.
- The follower again completed with zero fatal errors, conflicts, reorgs, or
  final lag, and validator cleanup ended with no pending native state. The run
  rejects the 20-CPU/18-thread validator treatment and independently shows
  that frequent actor-stat sampling was not required for the long cadence
  stalls; it is not a capacity result.
- Artifact directory: `benchmark-results/20260901T005833Z`.

## Cycle 11 — Decryptor mailbox quantum (invalid benchmark; chain-correct) (20260901T015101Z)

- TON image revision label: `6e11391c-dirty-958230e657d6`. The container
  resource model reverted to the Cycle 9 split (validator 18 CPUs / 16 actor
  threads and generator 4 CPUs), while retaining Cycle 10's sparse actor-stat
  cadence. The source treatment added the 64-message executor quantum to
  `DecryptorAsync`. Because Cycle 10 used 20/2 CPUs and 18 actor threads, it is
  not a direct one-variable throughput control; Cycle 9 has matching resources
  but materially more observer activity.
- Result: invalid and incomplete, but chain-correct. Measured offered/admitted/
  proof throughput was 3,693.691 / 3,692.944 / 3,630.901 TPS (61.562% target
  attainment). Backpressure was 122.422 seconds / 17.489%; the 300-second
  drain ended with 246 backlog entries/gaps and six exhausted source heads.
- The combined return to the 18/4 resource split plus Decryptor treatment was
  positive but insufficient. Versus Cycle 10, offered/admitted/proof TPS
  improved 19.9% / 19.9% / 22.1%, measured backpressure fell 53.1%, nonce gaps
  fell 71.2%, and retry exhaustion fell 80%. Versus the same-resource Cycle 9,
  proof TPS improved 11.6%, but Cycle 9's in-window actor sampling prevents a
  clean causal TPS attribution. Basechain/masterchain maximum accepted
  intervals improved to 22.961 / 25.973 seconds.
- Runtime telemetry confirmed the intended bound: `DecryptorAsync` processed
  at most 64 messages per turn, with 0.410-second maximum execution,
  0.401-second maximum individual handler, and 2.489-second maximum delay.
  Its turn-minus-single-message excess collapsed from Cycle 10's 12.230
  seconds to 9.699 ms, and the global mailbox-quantum rate increased by the
  expected Decryptor message-rate / 64. That mechanism result is causal even
  though the TPS comparison is not. `OverlayImpl` remained bounded at 66
  messages. The proof follower had zero fatal errors, conflicts, reorgs, or
  final lag, and validator cleanup was fully clean.
- Admission state reads were the next directly measured waste: 343,558 native
  batches handling 3,684,925 messages caused 343,382 physical shard-state
  fetches and MC-state pins, despite the pinned shard top advancing only over
  the hundreds of produced blocks (ending at shard seqno 896). This is a safe,
  highly cacheable source of work for Cycle 12, but it accounts for only about
  8.7% of CellDb loads and does not feed the dominant PackageReader path; it is
  not yet established as the explanation for the remaining capacity failure.
- Artifact directory: `benchmark-results/20260901T015101Z`.

## Cycle 12 — exact admission-state cache and external-wait decomposition (20260901T031540Z)

- TON image revision label: `6e11391c-dirty-64e3a6d5dce9`. The guarded run
  used a destructive fresh state and exactly restored Cycle 11's 4,096-source,
  6,000-TPS, 60/60/700/300-second workload, 20 ms submit coalescing, 768-message
  global CWND, and 18/4/1 CPU allocation. The generator and wrapper exited zero
  after 822 seconds without interruption. The source tree was dirty and the
  Session Stats image lacked a revision label, so the artifact is chain-proof
  valid but intentionally marked non-reproducible.
- Result: proof-correct, complete, and fully cleaned up, but not a capacity pass.
  Measured offered/admitted/proof-chain TPS was 4,140.443 / 4,140.409 /
  4,152.675, and the measured-offer cohort reached 4,133.204 TPS. All final
  backlog, nonce-gap, retry-exhaustion, proof-conflict, follower-error/lag, and
  validator native-pool residue counters were zero. Canonical backpressure was
  162.306 seconds / 23.187%; target attainment was 69.007%, so ingress and
  chain-capacity decisions remained false.
- The exact immutable shard-view cache was internally correct but operationally
  ineffective during an applied-state race. Its lookup identity was
  `316,348 requests = 165,281 hits + 151,067 manager/DB fetches`, and its full
  outcome identity was `151,067 fetches = 1,133 fills + 6,518 fill races + 277
  stale-generation fill skips + 143,139 errors`; conflicts, wrong IDs, invalid
  headers, and accounting error were all zero. Thus 94.752% of cache misses
  failed, successful current-generation misses produced 6.753 concurrent fetches
  per fill, and 1,175 generation resets saw 128.568 fetches each. Fetches fell
  56.006% from Cycle 11's 343,382, or 52.222% after normalization per batch,
  well short of the intended near-one-fetch-per-generation collapse.
- Admission batching improved despite that storm: 3,908,602 wire attempts used
  316,349 queries, averaging 12.355 messages/query. Versus Cycle 11, attempts
  rose 6.1%, queries fell 7.9%, occupancy rose 15.2%, `not_ready` responses fell
  14.1% to 470,058, and timeouts fell 88.2% to 301; retry exhaustion fell from
  six to zero. With zero cache validation/conflict failures, the 143,139 cache
  errors localize to manager state awaits and are overwhelmingly immediate
  not-ready results rather than expired admission deadlines.
- External-wait accounting was complete on every measured row. Basechain wait
  totaled 270.389 seconds across 1,340 collations: native first work 134.951
  seconds (49.910%), fragment refill 72.133 seconds (26.677%), post-commit idle
  48.955 seconds (18.105%), and native probe 14.350 seconds (5.307%); the other
  six categories were zero. Masterchain wait totaled 74.905 seconds across
  1,006 collations and was entirely generic sync-snapshot wait. Category calls
  reconciled exactly, maximum per-row time error was 2 microseconds, and all
  external-wait tokens were confined to wall rather than CPU telemetry.
- Average accepted cadence improved sharply while the long tail regressed.
  Basechain average/p95/p99/max intervals were 0.525/2.160/6.514/38.189 seconds;
  masterchain values were 0.748/2.544/7.860/48.115 seconds. The overlapping
  maxima were a global acceptance stall, not one blocking collation: basechain
  and masterchain scheduling maxima were 10.486 and 1.112 seconds. During the
  common gap host CPU averaged 95.86%, genesis averaged 17.95 of its 18 assigned
  CPUs, and host iowait averaged only 0.047%, pointing to consensus/CPU pressure
  rather than a storage-only pause.
- Genesis averaged/peaked at 9.347/22.134 CPU cores, the generator at
  0.609/2.441, host CPU averaged 73.237%, host iowait 1.088%, and genesis memory
  averaged/peaked at 4.264/7.434 GB. Relative to the complete Cycle 6 control,
  proof TPS rose 7.76% while genesis average CPU fell 10.25%, although device
  reads, writes, and maximum in-flight I/O rose materially. At measurement end,
  ten-minute Overlay/Decryptor load was 0.846/0.523 cores at 10,361.6/5,320.9
  messages per second, with 51/49 ms maximum delay. Approximate actor
  lifetime-window totals show only single-digit reductions in PackageReader,
  CellDb, and Manager messages despite the 56% admission-fetch reduction, while
  ExtMsgQueue traffic rose with the 2.18x increase in collations; Cycle 11's
  timed-out drain makes its raw actor-rate averages unsuitable for direct use.
- Cycle 13 should make each cache miss wait on the manager's existing exact
  full-`BlockIdExt` `wait_block_state_short` coalescer, retaining the pinned MC
  generation, outer absolute deadline, and ID/header/root validation. Telemetry
  distinguishes logical manager waits and their outcomes, but does not yet
  expose actual exact-ID worker starts versus joins. Consequently Cycle 13 can
  prove the availability/error and end-to-end effects, while any physical
  backend-collapse claim remains explicitly out of scope. A
  wider generator coalescing window already has lower leverage and changes the
  offered workload. Decryptor/ext-broadcast disable remains the cleaner next
  residual-contention A/B after the admission-state stampede is removed.
- Artifact directory: `benchmark-results/20260901T031540Z`.

## Cycle 13 — manager-coalesced admission-state waits (20260901T041349Z)

- TON image revision label: `6e11391c-dirty-6156ff68d3d6`. The guarded runner
  again destroyed and recreated exactly the four scoped volumes, and genesis
  created all 8,192 source/destination wallets with zero reuse. The run kept
  Cycle 12's 4,096-source, 6,000-TPS, 60/60/700/300-second workload, 20 ms
  coalescing, 768-message global CWND, 65,536 proof inflight, and disjoint
  18/4/1 CPU allocation. The isolated source treatment replaced admission
  cache-miss direct state reads with the manager's exact-full-`BlockIdExt`
  `wait_block_state_short` path while retaining the pinned MC generation,
  absolute deadline, and ID/header/root validation. Generator and wrapper
  exited zero after 831 seconds. The dirty source and unlabeled Session Stats
  image keep reproducibility false without affecting proof validity.
- Result: mechanism success, but capacity failure. The run was proof-correct,
  complete, and fully cleaned up. Offered/admitted/proof-chain TPS was
  4,196.000 / 4,196.000 / 4,038.268, and the measured-offer cohort reached
  4,026.334 TPS. Versus Cycle 12, offered/admitted rose 1.342%/1.343%, but
  proof and cohort TPS fell 2.755%/2.586%; proof remained 11.219% above Cycle
  11 and 4.793% above Cycle 6. Backpressure worsened to 225.728 seconds /
  32.247%, target attainment was 69.933%, and both capacity decisions were
  false. Final backlog, gaps, retry exhaustion, proof conflicts, follower
  errors/reorgs/lag, and native-pool residue were all zero; drain took 10.906
  seconds.
- The new admission telemetry reconciled exactly: `164,242 requests = 148,414
  hits + 15,828 manager waits`, and `15,828 waits = 1,309 fills + (13,935
  races - 0 conflicts) + 584 stale-generation skips + 0 miss errors + 0 late
  results`. Manager-wait errors also split exactly as `0 = 0 timeout + 0
  not-ready + 0 other`; wrong-ID, invalid-header, validation/store, request,
  outcome, and error-accounting counters were zero. Both compatibility aliases
  matched at both snapshots, the parser selected `shard_manager_waits`, and
  the generation-reset delta was correctly `1,370 - 9 = 1,361`. The zero final
  entry gauge reflects a last generation clear; the peak remained one.
- The admission mechanism eliminated Cycle 12's availability storm. Hit ratio
  rose from 52.247% to 90.363%, logical waits fell 89.523%, waits per reset fell
  from 128.568 to 11.630, and the miss-error fraction fell from 94.752% to zero.
  Generator `not_ready` responses fell 99.884% to 543 and timeouts fell from
  301 to zero. The remaining 575 retryable responses were 543 non-manager
  not-ready plus 32 canonical-state-lag responses and all resolved. The wire
  identities were also exact: 3,479,100 attempts equaled validator batch
  messages and 3,478,525 accepted statuses plus 575 rejects; accepted statuses
  were 3,477,178 unique admissions plus 1,347 repeat successes. Only 164,266
  queries were needed, down 48.074% from Cycle 12, while average occupancy rose
  71.421% to 21.180 messages/query.
- These counters prove logical admission waits and their successful outcomes,
  not physical manager worker starts, joins, database reads, or network reads.
  A manager wait can hit the manager's 30-second positive cache or join an
  existing exact-ID worker. The scheduled measure-end actor snapshot provides
  corroboration, not attribution: PackageReader ten-minute load/messages/
  creations fell to 1.372 cores / 3,639.3 per second / 1,819.7 per second from
  Cycle 12's 3.961 / 8,567.3 / 4,283.6, while aggregate WaitBlockState creation
  rose 28.6% to 4.388 per second across all consumers. A physical
  single-flight-collapse claim therefore remains out of scope until explicit
  manager worker-start/join/backend-read counters exist.
- External-wait accounting was complete on every row. Basechain wait totaled
  245.705 seconds over 1,749 collations, averaging 140.483 ms per row versus
  Cycle 12's 201.783 ms. Native first work contributed 181.965 seconds
  (74.058%), fragment refill 24.368 (9.918%), post-commit idle 37.576
  (15.293%), and probe 1.797 (0.731%); total calls fell 56.043%. Masterchain
  wait was 76.216 seconds over 1,004 rows, entirely generic sync-snapshot wait.
  Calls reconciled exactly, basechain maximum per-row error was 2 microseconds,
  and masterchain per-row error was zero.
- Basechain accepted interval average/p95/p99/max improved to
  0.401/1.945/4.621/19.813 seconds from Cycle 12's
  0.525/2.160/6.514/38.189. Masterchain was
  0.745/2.781/6.239/33.058 seconds: the maximum improved from 48.115 seconds
  but still breached the 30-second gate once. The generator's encompassing
  49.368-second sampled proof plateau was observer discovery/catch-up, not one
  global acceptance halt: it overlapped the 33.058-second MC gap and a separate
  19.813-second BC gap. The MC gap contained continued candidate, validation,
  and skip-vote activity without an accept; during the surrounding plateau
  host CPU averaged 94.18%, genesis used 17.18 cores, and iowait averaged only
  0.426%. This localizes the longest tail to per-chain consensus/CPU pressure,
  not a global, storage-only, or single-block-collation stop. Faster basechain
  cadence produced 1,730 measured native blocks, 30.8% more than Cycle 12, but
  packing fell 25.6% to 1,631.647 transfers/block and proof TPS regressed.
- Fixed-measure host CPU average/p95 was 62.080%/95.076%, genesis used
  6.207/18.427 cores, and host iowait averaged/p95ed 1.778%/2.987%. Lower CPU
  averages are confounded by 32.247% generator backpressure and lower proof
  throughput; iowait was 87%/56% above Cycle 12. Full-run genesis memory
  averaged/peaked at 4.248/12.541 GB. Underlying device write bytes were nearly
  flat, but write operations, busy time, and weighted I/O time rose about
  17%/24%/9%. At measurement end, Overlay/Decryptor ten-minute load was
  0.902/0.532 cores with the 66/64-message bounds intact. KeyValue load rose
  30.9% to 1.026 cores and its ten-minute maximum execution rose from 0.119 to
  5.895 seconds; ArchiveSlice and PackageWriter also reached about 5.9 seconds
  and StateDb 3.54 seconds. These storage-write tails are material, but they do
  not explain away the separately observed high-CPU MC consensus gap.
- Cleanup reconciled exactly: 3,485,370 uniquely tracked accepted-root messages
  minus 3,477,178 canonical/purged messages equals 8,192 losing messages. Seven
  basechain seqnos had two accepted candidates: 965, 966, 1462, 1766, 1767,
  1768, and 2003. The artifact proves that aggregate loss but does not directly
  encode which root won at each seqno, so per-root losing assignments remain
  inference rather than reported fact. Reconciliation ended with zero pending
  sources and the native pool with zero accounts/messages.
- Cycle 13 should remain enabled: it converts the cache from an error/retry
  storm into a correct, available, substantially cheaper admission path. The
  residual ceiling has moved downstream to consensus/overlay contention,
  block packing, and storage-write tails. Cycle 14 should isolate the
  configuration-supported external-message broadcast disable
  (`engine.validator.setExtMessagesBroadcastDisabled true`) on this
  one-validator topology while retaining every Cycle 13 setting. Local
  liteserver injection still enters the mempool, while outbound/rebroadcast
  work is suppressed; because this changes network semantics, it must be
  reported as a ceiling A/B rather than a production-equivalent optimization.
  It should gate on the same proof/capacity/cadence/cleanup checks and measure
  whether Overlay, Decryptor, and signature load fall without worsening the
  KeyValue/write tail. If not, block-cadence/packing and database-write work
  become the next isolated treatments.
- Artifact directory: `benchmark-results/20260901T041349Z`.

## Cycle 14 — explicit external-message rebroadcast control (20260901T053132Z)

- TON image revision label: `13335a11`; the TON and Docker source trees were
  clean at launch (`5c036b0` for the benchmark harness). This is the first
  fresh-state cycle with committed source provenance after the overnight work.
  Session Stats remains an externally supplied image without a revision label,
  so the harness correctly marks whole-image reproducibility false without
  weakening the proof, completion, or cleanup decisions.
- Workload: the Cycle 13 4,096-source, 6,000-TPS, 60/60/700/300-second
  profile, with 20 ms generator coalescing, 768 global CWND, 18 validator CPUs,
  4 generator CPUs, the 18,432-message logical candidate cap, and all prior
  admission/cache fixes retained. The guarded `BENCHMARK_EXT_MESSAGES_BROADCAST_DISABLED=0`
  control captured matching in-memory and on-disk settings before load, after
  the five-second settle, after load, and after restoring the normal setting.
- Result: proof-correct and complete, but capacity-invalid. Measured
  offered/admitted/proof-chain throughput was 4,648.461 / 4,648.461 /
  4,504.069 TPS. The exact canonical one-second peak was 23,040 TPS; it is a
  burst, not a sustained capacity number. Target attainment was 77.474% and
  canonical-backlog pressure stopped offers for 198.970 seconds (28.424% of
  the measured window), so both ingress and chain-capacity gates were false.
  The guard reached its 131,072-message maximum, but the final canonical
  backlog, pool residue, nonce gaps, retry exhaustion, follower errors, and
  reorgs were all zero; final proof catch-up completed and drain took 20.922
  seconds.
- Cadence and packing stayed inside the intended fast-path envelope. The
  proof window contained 2,998 native basechain blocks averaging 1,050.148
  transfers each (maximum 18,432). Session telemetry recorded 3,025 measured
  basechain collations averaging 173.5 ms, with 328.4 ms p95 and 594.1 ms p99;
  accepted-block interval averaged 232 ms with 379 ms p95 and 714 ms p99.
  Thus lowering the candidate cap to force sub-second blocks is not justified:
  construction is already sub-second while the blocks remain mostly underfilled.
- The no-op control supplies the paired baseline for the next single-validator
  ceiling experiment. External wait still dominated collation wall time:
  310.860 seconds first-work (74.1%), 48.383 seconds fragment-refill (11.5%),
  and 57.568 seconds post-commit idle (13.7%) across the measured basechain
  collations. Native CPU work averaged only 11.8 ms per collation. This keeps
  bounded transport prefill, not a block-size reduction, as the next code
  treatment if disabling rebroadcast does not remove the stalls.
- Artifact directory: `benchmark-results/20260901T053132Z`.

## Cycle 15 — external-message rebroadcast disabled (20260901T055222Z)

- TON image revision label: `13335a11`; Docker harness revision: `d299bdf`.
  Both source trees were clean. This is the paired fresh-state treatment for
  Cycle 14: every workload, CPU, queue, CWND, and proof control was identical,
  but the guarded one-validator control set
  `BENCHMARK_EXT_MESSAGES_BROADCAST_DISABLED=1`. The wrapper verified matching
  in-memory and persisted disabled state before load and post-load, then
  restored normal rebroadcast and verified the restoration before exit.
- Result: valid 6k capacity run. Offered/admitted/proof-chain TPS was
  5,999.979 / 5,999.979 / 6,000.571. Target attainment was 99.9996%; measured
  canonical backpressure was exactly zero; final proof catch-up, canonical
  cleanup, nonce/hash accounting, and drain were all clean. Drain to the
  anchored tip took 1.411 seconds. The maximum fully contained canonical
  one-second bucket was 19,702 TPS, a burst rather than the sustained result.
- This is a configuration-supported single-validator *ceiling* result, not a
  production-network claim: local liteserver injection still enters the pool,
  while outbound Overlay gossip is deliberately suppressed. The successful A/B
  therefore isolates the cost of needless rebroadcast on this one-validator
  desktop topology; it must not be enabled in a topology that needs other
  validators or nodes to receive the external messages.
- The treatment removed the Cycle 14 capacity failure rather than merely
  shifting it to drain. Its sampled canonical backlog peaked at 26,181 rather
  than the 131,072 guard, basechain packing rose 56.8% from 1,044.229 to
  1,637.116 transfers per collated block, and host/genesis average CPU fell
  from 64.16%/7.22 cores to 50.45%/4.45 cores. Canonical proof packing was
  1,639.718 transfers per block across 2,558 blocks.
- Sub-second behavior held under the valid load. Measured collation was
  209.0 ms average, 518.2 ms p95, and 682.2 ms p99 (971.1 ms maximum); accepted
  basechain interval was 272.5 ms average, 523.6 ms p95, and 841.2 ms p99.
  Thus there is still no evidence that reducing candidate size improves this
  desktop ceiling.
- Remaining work is now visible rather than masked by outbound gossip. Native
  external waits totalled 375.8 seconds: first work fell from Cycle 14's
  310.9 seconds to 57.3 seconds, but fragment refill and post-commit idle were
  208.8 and 109.0 seconds. Native compute was only 24.1 ms per collation.
  The next source treatment remains a bounded wider transport prefill, but the
  immediate safe capacity staircase is 8,000 TPS with rebroadcast disabled.
- Artifact directory: `benchmark-results/20260901T055222Z`.

## Cycle 16 — 8,000-TPS no-gossip staircase (20260901T061338Z)

- TON image revision label: `13335a11`; Docker harness revision: `b02835a`.
  Both source trees were clean. This fresh-state run keeps every valid Cycle 15
  control, including the verified-and-restored one-validator
  `BENCHMARK_EXT_MESSAGES_BROADCAST_DISABLED=1` setting, and changes only the
  offered target from 6,000 to 8,000 TPS. It remains a single-validator
  no-gossip ceiling measurement, not a production-network configuration.
- Result: valid 8k capacity run. Offered/admitted/proof-chain TPS was
  7,999.941 / 7,999.941 / 7,999.488. Target attainment was 99.9993% and
  measured canonical backpressure was zero. Proof correctness, completion,
  ingress and chain-capacity gates, canonical cleanup, final follower catch-up,
  and the broadcast setting lifecycle all passed. Drain to the anchored tip
  took 1.273 seconds and ended with zero canonical backlog. The fully
  contained canonical one-second maximum was 21,446 TPS; it is a burst rather
  than the sustained result.
- The higher offered rate improved useful packing without requiring a larger
  candidate: proof contained 2,450 native basechain blocks averaging 2,282.303
  transfers (maximum 12,054), while sampled collation recorded 2,465 blocks
  averaging 2,282.806 transfers. The maximum observed estimated candidate was
  2.93 MB, still far below the 8.5/9 MB soft/hard limits; no size-guard
  deferral or hard preflight failure occurred. Reducing the candidate cap would
  therefore add consensus work without solving the observed limiter.
- The explicit sub-second construction gate continues to hold at 8k: measured
  collator total time was 222.6 ms average, 505.4 ms p95, and 762.9 ms p99;
  CPU work was only 26.5 ms average. Accepted-block interval was 284.7 ms
  average, 540.5 ms p95, and 817.9 ms p99. A few absolute maxima exceeded one
  second, so the next rung must retain the p99 gate and investigate any tail
  regression rather than claim a hard all-sample bound.
- External transport timing is still the dominant opportunity: 381.0 seconds
  of measured queue wait split into 78.9 seconds first-work, 207.9 seconds
  fragment-refill, and 93.2 seconds post-commit idle. The safe immediate next
  experiment is the otherwise-identical 10,000-TPS staircase rung; if it
  becomes capacity-invalid, a bounded wider native transport prefill is the
  next source change, with proof, cancellation-accounting, clean-drain, and
  sub-second p99 regressions all gated.
- Artifact directory: `benchmark-results/20260901T061338Z`.

## Cycle 17 — 10,000-TPS no-gossip injector-limit probe (20260901T063654Z)

- TON image revision label: `13335a11`; Docker harness revision: `0be3132`.
  Both trees were clean. This fresh-state probe kept the Cycle 16 workload and
  one-validator no-gossip ceiling setting exactly: 4,096 sources, 60/60/700/300
  seconds, 18 validator and 4 generator CPUs, 18,432 logical candidate entries,
  20 ms submit coalescing, and 768 global adaptive CWND. It changed only the
  requested target from 8,000 to 10,000 TPS.
- Result: proof-correct, complete, cleanly drained, but deliberately
  capacity-invalid as an injector-limit result. Offered/admitted/proof-chain
  TPS was 9,329.920 / 9,329.920 / 9,454.299. The 94.54% canonical figure is
  not a 10k chain-capacity claim: measured-chain progress includes the
  bounded cohort already queued near the window boundary, while offered load
  missed the required 95% target-attainment gate. The only ingress invalid
  reason is `offer_target_not_attained`; the only chain-capacity invalid
  reason is insufficient offered load over observed canonical throughput.
  Canonical-backlog backpressure was exactly zero, final proof/cleanup was
  correct, and drain took 0.777 seconds to zero backlog.
- The artifact identifies the limiting injector condition directly. All 12
  clients reached the 768-message global CWND cap, and 7,342,137 successful
  ACK increases were cap-clipped. RTT was 20 ms p50, 200 ms p95, and 500 ms
  p99. Therefore this run cannot establish a 10k blockchain ceiling; the
  next paired configuration experiment must retain this committed source and
  profile while increasing only `NATIVE_LOAD_ADAPTIVE_MAX_CWND` from 768 to
  1,536.
- Despite the invalid capacity classification, the correct workload gives
  useful packing and cadence evidence. Proof contained 2,284 native blocks
  averaging 2,893.413 transfers (maximum 18,432), and sampled collations
  averaged 2,890.318 transfers across 2,293 blocks. The maximum canonical
  one-second bucket was 34,908 TPS, a burst rather than a sustained capacity
  result. Collation total time was 240.2 ms average, 540.8 ms p95, and
  816.4 ms p99; accepted-block interval was 305.6 ms average, 661.5 ms p95,
  and 954.6 ms p99. The p99 sub-second gates remain satisfied, although the
  recorded maxima (1.31-second collation and 1.53-second accepted interval)
  require continued tail monitoring.
- Native external waiting remains the central code opportunity: 351.8
  seconds split into 86.0 seconds first-work, 193.8 seconds fragment-refill,
  and 70.7 seconds post-commit idle. The following source commit introduces a
  bounded configurable transport prefill; its treatment must be compared on
  an otherwise-identical 10k/768-CWND control before widening the injector
  window.
- Artifact directory: `benchmark-results/20260901T063654Z`.

## Cycle 18 — bounded transport-prefill control, 1,024 window (20260901T070740Z)

- TON image revision label: `b1393d52`; Docker harness revision: `363525e`.
  Both trees were clean. This is the first fresh-state result for the committed
  bounded native transport-prefill implementation and its telemetry harness.
  It retains the Cycle 17 10,000-TPS one-validator no-gossip profile exactly:
  4,096 sources, 60/60/700/300 seconds, 18,432 candidate entries, 768 global
  CWND, and all proof/drain gates. The explicit control uses
  `TON_NATIVE_EXT_MSG_TRANSPORT_WINDOW=1024`.
- Result: valid 10k capacity run. Offered/admitted/proof-chain TPS was
  10,000.067 / 10,000.067 / 9,998.534, with zero canonical-backpressure
  seconds. Proof correctness, completion, ingress and chain capacity,
  canonical cleanup, final follower catch-up, and broadcast-setting lifecycle
  all passed; drain to the anchored tip took 0.728 seconds. The largest fully
  contained canonical one-second bucket was 23,259 TPS, a burst rather than a
  sustained capacity number.
- This corrects Cycle 17's injector starvation under the same 768-CWND
  setting: that prior run offered only 9,329.920 TPS while all clients were
  capped; this prefill control reaches the full 10k target without a guard
  pause. The source/cycle pair is the relevant evidence; it does not turn the
  one-validator no-gossip configuration into a production-network claim.
- Transport telemetry proves the intended bounded behavior. Across the run it
  selected 8,237,799 messages, pushed 8,225,973, and consumed 7,972,252;
  cancellation accounting recorded 265,547 discarded speculative messages
  (3.22% of selected) with no live residue. The configured 1,024-message
  transport window observed a 1,536-message high-water mark because the design
  permits exactly one additional 512-message producer look-ahead. Initial
  pushes reached 1,024 while consumer microbatches remained 512. This is a
  bounded resident hand-off, not a restored unbounded callback backlog.
- Packing and the requested fast cadence both improved while retaining the
  existing 18,432 entry safety cap. Proof contained 2,199 native blocks
  averaging 3,178.251 transfers (maximum 15,122); sampled collations averaged
  3,177.876 transfers across 2,210 blocks. Collation total time was 254.9 ms
  average, 576.9 ms p95, and 846.2 ms p99; accepted-block interval was 317.2
  ms average, 690.9 ms p95, and 951.8 ms p99. Those p99 values meet the
  sub-second gate, although the 1.47–1.55 second absolute tails remain
  explicitly visible.
- Fragment-refill waiting still dominates (218.9 of 358.3 seconds external
  wait), so the next isolated treatment changes only the configured transport
  window to 2,048 while keeping this committed source, 768 CWND, target,
  topology, and all capacity/cadence gates fixed. The observed high-water,
  cancellation ratio, max push batch, and p99 cadence are its key regression
  checks.
- Artifact directory: `benchmark-results/20260901T070740Z`.

## Cycle 19 — bounded transport-prefill treatment, 2,048 window (20260901T072845Z)

- TON image revision label: `b1393d52`; Docker harness revision: `1c5d927`.
  Both trees were clean. This is the direct fresh-state treatment for Cycle 18:
  its 4,096-source 10,000-TPS, 60/60/700/300-second, one-validator no-gossip,
  18,432-entry, and 768-CWND profile is unchanged. The sole runtime difference
  is `TON_NATIVE_EXT_MSG_TRANSPORT_WINDOW=2048` instead of 1,024.
- Result: valid 10k capacity run. Offered/admitted/proof-chain TPS was
  10,000.096 / 10,000.096 / 9,998.644, with zero canonical backpressure.
  All proof, completion, ingress/chain-capacity, cleanup, follower, and
  broadcast-lifecycle gates passed; drain took 0.781 seconds to zero backlog.
  The maximum complete canonical one-second bucket was 19,600 TPS, a burst
  rather than a sustained capacity result.
- The wider hand-off remains bounded and correct. It selected 8,229,346
  messages and accounted for 269,681 cancellation-discarded entries (3.28% of
  selected, only 0.06 percentage points above Cycle 18); no final validator
  residue or nonce/proof failure occurred. The observed high-water was 2,560
  messages, exactly the configured 2,048 window plus one 512-message producer
  look-ahead; max push batch was 2,048 and consumer microbatches remained 512.
  This confirms the treatment did not turn into an unbounded producer queue.
- At the fixed 10k target, sustained TPS is intentionally target-limited, so
  cadence and safety are the useful comparison. Total collation p99 improved
  from Cycle 18's 846.2 ms to 799.2 ms; accepted-block interval p99 improved
  from 951.8 ms to 901.9 ms; collation-wall p99 was 855.4 ms. All remain below
  the sub-second p99 gate. Packing was 2,981.677 proof transfers/block
  (sampled 2,973.666) across 2,344 proof blocks, with an observed maximum
  18,432-entry candidate. The few 1.06–1.45 second absolute tails remain
  reportable and are not obscured by the p99 pass.
- Fragment-refill time was statistically unchanged (219.3 seconds versus
  218.9 in the control), so the wider window is retained for its bounded
  telemetry and p99 improvement but not credited with a new target-limited TPS
  ceiling. The next clean staircase changes only offered target to 12,000 TPS
  at this 2,048 window and 768 CWND. If that becomes injector-window-limited,
  a 1,536-CWND A/B follows before altering candidate size or consensus logic.
- Artifact directory: `benchmark-results/20260901T072845Z`.

## Cycle 20 — valid 12,000-TPS staircase, cadence-policy boundary (20260901T074907Z)

- TON image revision label: `b1393d52`; Docker harness revision: `96bfc3b`.
  Both trees were clean. This fresh-state staircase retains Cycle 19's
  2,048-message bounded transport window, 768 CWND, 4,096 sources,
  one-validator no-gossip topology, and 18,432-entry candidate cap. The sole
  requested-workload change is 12,000 TPS instead of 10,000.
- Result: benchmark-capacity valid 12k run. Offered/admitted/proof-chain TPS
  was 12,000.087 / 12,000.087 / 11,988.780, with zero canonical-backpressure
  seconds. Proof correctness, completion, ingress and chain capacity, cleanup,
  final follower catch-up, and broadcast lifecycle all passed; drain took
  1.328 seconds to zero backlog. The fully contained canonical one-second
  maximum was 31,809 TPS, a burst and not the sustained result.
- This is not yet a user-acceptable maximum under the explicit sub-second
  block-generation requirement. Although the benchmark's formal capacity gates
  pass, sampled collation total p99 was 1.026 seconds, collation-wall p99 was
  1.107 seconds, and accepted-block interval p99 was 1.196 seconds. Their
  1.60–1.69 second maxima make the tail visible rather than masked. The next
  experiment must restore all p99 values below one second before advancing the
  offered-rate staircase.
- The capacity/latency tradeoff is directly observable in packing. Proof had
  1,471 blocks averaging 5,696.912 transfers and reached the 18,432-entry
  candidate cap; sampled collations averaged 5,703.098 transfers across 1,483
  blocks. Native work p99 was only 127.3 ms, but total collation p95/p99 rose
  to 867.5/1,025.8 ms as larger candidates increased downstream/cadence tail.
  Transport remained bounded (2,560 observed high-water, 2,048 max push,
  512 max pop); cancellation waste improved to 217,644 / 9,784,555 selected
  messages (2.22%), so it is not the reason to reduce the candidate cap.
- The next isolated cycle therefore retains 12k, source, window, CWND, and
  topology but lowers `TON_NATIVE_COLLATOR_QUEUE_LIMIT` to 12,288 entries.
  It is a conservative whole-512-fragment cap intended to remove the full
  18,432-entry tail while preserving ample room for 12k at the observed
  cadence. It must pass proof/cleanup/zero-pressure plus total collation,
  collation-wall, and accepted-interval p99 <1 second; otherwise adaptive
  checkpoint coalescing is the next source-level treatment.
- Artifact directory: `benchmark-results/20260901T074907Z`.

## Cycle 21 — 12,288-entry cap treatment, near sub-second cadence (20260901T080919Z)

- TON image revision label: `b1393d52`; Docker harness revision: `1e83e1b`.
  Both trees were clean. This fresh-state treatment retains Cycle 20's 12k
  target, 2,048 transport window, 768 CWND, 4,096 sources, no-gossip topology,
  and timing. The sole change is the conservative 24-fragment
  `TON_NATIVE_COLLATOR_QUEUE_LIMIT=12288` instead of 18,432.
- Result: benchmark-capacity valid 12k run. Offered/admitted/proof-chain TPS
  was 11,999.974 / 11,999.974 / 11,992.004 with zero canonical backpressure;
  proof, completion, capacity, cleanup, follower, and broadcast-lifecycle
  gates passed. Drain took 0.897 seconds to zero backlog. The maximum complete
  canonical one-second bucket was 24,576 TPS, a burst rather than sustained
  capacity.
- The smaller candidate restored the collation-side sub-second target without
  sacrificing sustained throughput: total collation p99 fell from Cycle 20's
  1.026 seconds to 860.3 ms, and collation-wall p99 fell from 1.107 seconds to
  928.7 ms. It increased proof-block frequency to 1,911 blocks while lowering
  average packing to 4,386.400 transfers; the configured 12,288 cap was
  reached. Cancellation remained bounded at 220,099 / 9,744,327 selected
  messages (2.26%) with a 2,560-message transport high-water and no residue.
- It is still narrowly cadence-policy-invalid for the user's full
  sub-second-block-generation requirement: accepted-block interval p99 was
  1.040 seconds, despite total collation and collation-wall p99 passing. Its
  1.16-second accepted maximum remains explicit. Therefore do not advance the
  12k rate or call this the compliant maximum yet.
- The next isolated configuration rung retains all Cycle 21 conditions but
  lowers the logical candidate cap to 10,240 (20 fair 512-message fragments).
  It must retain the 12k proof/capacity result and bring *all three* p99
  measures—total collation, collation wall, and accepted-block interval—below
  one second. If that fails, simple cap sizing is insufficient and adaptive
  transactional checkpoint coalescing becomes the next source treatment.
- Artifact directory: `benchmark-results/20260901T080919Z`.

## Cycle 22 — 10,240-entry cap treatment, valid 12k sub-second-p99 baseline (20260901T082923Z)

- TON image revision label: `b1393d52`; Docker harness revision: `757512c`.
  Both trees were clean. This fresh-state cycle changes only Cycle 21's logical
  candidate allowance from 12,288 to 10,240 (20 fair 512-message fragments).
  The 12k target, 2,048 transport window, 768 CWND, 4,096 sources, timing,
  no-gossip topology, and proof controls remain fixed.
- Result: valid 12k capacity run and the first configuration in this sequence
  that satisfies every practical sub-second p99 gate. Offered/admitted/proof
  TPS was 11,967.324 / 11,967.324 / 11,966.682. It had six short
  canonical-backpressure events totaling 0.838 seconds (0.120% of the window,
  within the ≤1% gate), then cleanly drained in 1.047 seconds with zero
  residue. Proof correctness, completion, capacity, cleanup, follower, and
  broadcast-lifecycle decisions all passed. Its complete canonical one-second
  peak was 26,112 TPS, a burst rather than sustained capacity.
- Cadence is now inside the requested p99 envelope: total collation was
  805.8 ms p99, collation wall 871.7 ms p99, and accepted-block interval
  963.4 ms p99. Proof contained 1,856 native blocks averaging 4,506.849
  transfers and reached the 10,240-entry cap. This is therefore the current
  proof-checked ~12k single-validator no-gossip baseline that preserves
  sub-second *p99* block generation.
- The exact tail caveat remains material: total collation and wall maxima were
  1.016 and 1.092 seconds, and one accepted-block interval reached 6.107
  seconds. Those rare scheduling/consensus tails are not hidden by the p99
  pass. The sampled canonical backlog also reached 130,951, close to the
  131,072 guard, so a direct 15k configuration jump would not be a sound
  capacity claim even though the formal capacity gate passed.
- Transport remains bounded and clean (2,560 high-water, 2,048 max push,
  512 max pop); cancellation was 227,570 / 9,738,258 selected messages
  (2.34%) with no live residue. The next throughput step is consequently a
  source-level adaptive transactional checkpoint-coalescing treatment: retain
  512-message fairness and the 10,240 cap, but reduce redundant exact
  dictionary/storage checkpoints under dense ingress with strict deadline,
  rollback, size-preflight, proof, and sub-second-tail tests. Retest this
  12k baseline before lifting the offered-rate staircase.
- Artifact directory: `benchmark-results/20260901T082923Z`.

## Cycle 23 — transactional checkpoint-coalescing treatment, cadence regression (20260901T092140Z)

- TON image revision label: `bd57ea20`; Docker harness revision: `f96780b`.
  Both source trees were clean. This is the direct fresh-state source treatment
  for Cycle 22: 4,096 sources, 12,000 TPS, 60/60/700/300-second timing,
  one-validator no-gossip topology, 10,240-entry candidate allowance,
  2,048-message transport window, and 768 CWND are unchanged. The source
  retains 512-message execution fragments, but may transactionally coalesce up
  to four immediately available fragments before one exact
  ShardAccounts/storage preflight. The harness change is reporting-only.
- Formal result: proof correctness, completion, ingress capacity, chain
  capacity, canonical cleanup, follower catch-up, and the broadcast-control
  lifecycle all passed. Offered/admitted/proof-chain TPS was 11,999.910 /
  11,999.910 / 12,002.864. There was zero measured canonical-backpressure,
  sampled backlog peaked at 35,984, and the anchored drain reached zero
  residue in 1.446 seconds. The maximum fully contained canonical one-second
  bucket was 24,391 TPS, a burst rather than a sustained capacity result.
  As in prior cycles, `reproducible=false` is solely because the external
  Session Stats image does not carry a source-revision OCI label; it does not
  alter the proof or capacity verdict.
- This does **not** replace Cycle 22 as the user-compliant sub-second baseline.
  Total collation p99 remained below one second at 853.4 ms and collation-wall
  p99 at 917.3 ms, but accepted-block-interval p99 rose to 1.076 seconds
  (Cycle 22: 963.4 ms). Absolute total/wall/accepted maxima were 1.078 /
  1.133 / 1.232 seconds. Therefore the 12k capacity result is valid but fails
  the explicit all-three-p99 cadence policy.
- Packing became denser: proof had 1,405 native blocks averaging 5,971.532
  transfers per block, versus Cycle 22's 1,856 blocks at 4,506.849 transfers
  per block. That +32.5% packing shift removes the rare 6.107-second accepted
  tail seen in Cycle 22, but moves enough ordinary accepted intervals past one
  second to fail p99. It must not be presented as a net latency improvement.
- New complete checkpoint telemetry explains why the intended coalescing gain
  was modest. The measured window had 25,040 512-message fragments and 23,096
  checkpoint groups (1.084 fragments and 365.279 transfers per group). 22,689
  groups flushed at an ingress boundary, only 406 at the capacity bound, one
  at latency, and none at deadline/fanout/headroom; there were zero rollbacks.
  Exact checkpoint rebuilds fell from Cycle 22's 26,172 to 23,096 (-11.8%),
  but native-commit average rose from 55.056 to 79.729 ms and staged-dictionary
  work from 24.624 to 34.030 ms per candidate. Thus this profile is still
  hand-off/packing limited rather than benefiting enough from four-fragment
  grouping.
- The next isolated cadence treatment retains the committed source and 12k
  profile but lowers the fair logical candidate allowance from 10,240 to 8,192
  entries. This deliberately trades some packing for a safer sub-second block
  cadence before resuming the offered-rate ladder. It must retain all formal
  proof/cleanup gates and make total collation, collation wall, and accepted
  block interval p99 each less than one second.
- Artifact directory: `benchmark-results/20260901T092140Z`.

## Cycle 24 — 8,192-entry cadence recovery, valid 12k baseline (20260901T094506Z)

- TON image revision label: `bd57ea20`; Docker harness revision: `cbebb6f`.
  Both source trees were clean. This fresh-state treatment retains Cycle 23's
  checkpoint-coalescing source, 12,000 target, 4,096 sources, 60/60/700/300
  timing, no-gossip topology, 2,048 transport window, and 768 CWND. Its sole
  runtime change is the fair logical candidate allowance: 10,240 to 8,192
  entries (16 512-message fragments).
- Result: all formal proof correctness, completion, ingress/chain capacity,
  canonical cleanup, follower, and broadcast-lifecycle gates passed.
  Offered/admitted/proof-chain TPS was 12,000.006 / 12,000.006 /
  11,995.419, with zero canonical-backpressure, a 49,232 sampled backlog peak,
  and a 1.327-second clean drain to zero residue. The complete canonical
  one-second maximum was 23,125 TPS, a burst rather than a sustained result.
  `reproducible=false` remains solely the Session Stats image-label caveat.
- This restores every requested sub-second p99 gate while preserving the 12k
  proof result: total collation p99 was 678.7 ms, collation-wall p99 736.8 ms,
  and accepted-block interval p99 852.1 ms. Compared with Cycle 22's prior
  compliant 10,240-cap baseline, those are improvements from 805.8/871.7/
  963.4 ms. Total collation and wall maxima were also below one second at
  734.1/785.1 ms; the accepted-interval maximum was 1.417 seconds and remains
  visible as a rare scheduling tail.
- Proof contained 1,594 native blocks averaging 5,260.225 transfers and
  reached the 8,192-entry cap. This is denser than Cycle 22's 4,506.849 average
  while avoiding Cycle 23's 5,971.532-transfer cadence regression. Measured
  exact checkpoint rebuilds fell to 21,939 (from Cycle 22's 26,172); native
  commit p99 was 144.9 ms versus Cycle 22's 191.3 ms. Grouping remains modest
  (1.103 fragments/group): 21,451 of 21,939 groups flushed at ingress, 488 at
  capacity, and no rollback/deadline/fanout/headroom event occurred. Therefore
  the result credits the smaller candidate cap and bounded source path as a
  combined valid configuration, not a claim that four-fragment coalescing is
  independently responsible for the latency gain.
- This is the new proof-checked ~12k single-validator no-gossip baseline for
  the offered-rate staircase. The next isolated run retains every Cycle 24
  control and increases only `NATIVE_LOAD_TARGET_TPS` to 13,500. It must retain
  proof/cleanup validity, <=1% canonical-backpressure, and all three p99 values
  below one second. If target attainment is injector-window-limited with all
  clients at the 768 CWND cap, a separate 1,536-CWND A/B follows; it must not
  be conflated with a chain-capacity claim.
- Artifact directory: `benchmark-results/20260901T094506Z`.

## Cycle 25 — 13.5k staircase rung, valid sub-second baseline (20260901T100645Z)

- TON image revision label: `bd57ea20`; Docker harness revision: `b001848`.
  Both source trees were clean. This is the direct fresh-state rate step from
  Cycle 24: 4,096 sources, 60/60/700/300-second timing, one-validator
  no-gossip topology, 8,192-entry candidate allowance, 2,048-message
  transport window, and 768 CWND are unchanged. The sole workload change is
  the offered target: 12,000 to 13,500 TPS.
- Result: all formal proof correctness, completion, ingress/chain capacity,
  canonical cleanup, follower, and broadcast-lifecycle gates passed.
  Offered/admitted/proof-chain TPS was 13,500.001 / 13,500.001 /
  13,461.536. There was zero measured canonical-backpressure, a 43,427
  sampled backlog peak, and a 3.188-second clean drain to zero residue. The
  complete canonical one-second maximum was 23,005 TPS, which is a burst and
  not a sustained-capacity result. `reproducible=false` remains solely the
  external Session Stats image-label caveat.
- This is the new user-compliant single-validator baseline. Total collation,
  collation wall, and accepted-block-interval p99 were 608.8 / 665.9 /
  785.5 ms, all below one second and improved from Cycle 24's 678.7 / 736.8 /
  852.1 ms despite the 12.2% proof-TPS increase. The corresponding absolute
  maxima were 711.5 / 789.1 / 1,293.6 ms; the accepted-interval maximum is a
  rare scheduling tail and is reported separately from the p99 policy.
- Proof contained 1,788 native blocks averaging 5,262.648 transfers and
  reached the 8,192-entry cap, effectively unchanged packing from Cycle 24
  (5,260.225). Measured native commit average fell from 64.838 to 58.102 ms;
  staged-dictionary and exact checkpoint work were 28.562 and 21.388 ms per
  collated candidate. Checkpoint grouping remained bounded and clean: 22,284
  groups, 1.117 fragments/group, 602 capacity and 21,681 ingress flushes, one
  latency flush, and zero rollback/deadline/fanout/headroom events.
- All 12 generator clients reached the intentionally conservative 768 CWND
  cap, with 10,659,372 additive increases clipped. That does not invalidate
  this run because it fully attained 13.5k; it means the next rate rung must
  retain the same cap first so a later injector limit is measured rather than
  hidden. The next isolated experiment therefore changes only
  `NATIVE_LOAD_TARGET_TPS` to 15,000 and retains all proof, cleanup,
  backpressure, and all-three-p99 sub-second gates. A 1,536-CWND A/B is only
  justified if that control cannot attain target while chain cadence remains
  healthy.
- Artifact directory: `benchmark-results/20260901T100645Z`.

## Cycle 26 — 15k 768-CWND control, valid but injector-window-limited (20260901T102814Z)

- TON image revision label: `bd57ea20`; Docker harness revision: `c34a77f`.
  Both source trees were clean. This fresh-state control retains Cycle 25's
  4,096 sources, 60/60/700/300-second timing, one-validator no-gossip
  topology, 8,192-entry candidate allowance, 2,048-message transport window,
  and 768 CWND. Its only workload change is the offered target: 13,500 to
  15,000 TPS.
- Result: all formal proof correctness, completion, ingress/chain capacity,
  canonical cleanup, follower, and broadcast-lifecycle gates passed.
  Offered/admitted/proof-chain TPS was 14,682.113 / 14,682.113 /
  14,592.386. That is 97.881% of the nominal 15k target and satisfies the
  documented >=95% capacity gate, but does not establish that the chain has
  been offered a full 15k. There was zero measured canonical-backpressure, a
  113,664 sampled backlog peak below the 131,072 guard, and a 5.317-second
  clean drain to zero residue. The maximum fully contained canonical
  one-second bucket was 24,736 TPS, a burst rather than a sustained result.
  `reproducible=false` remains solely the external Session Stats image-label
  caveat.
- Cadence remains strongly user-compliant: total collation, collation wall,
  and accepted-block-interval p99 were 581.9 / 636.7 / 766.7 ms, all below one
  second and better than Cycle 25's 608.8 / 665.9 / 785.5 ms. Absolute
  total/wall/accepted maxima were 657.4 / 720.7 / 1,007.0 ms. The 1.007-second
  accepted maximum is a rare tail and remains distinct from the all-three-p99
  requirement.
- Proof contained 1,745 native blocks averaging 5,845.317 transfers and
  reached the 8,192-entry cap. That density is +11.1% over Cycle 25, while
  native commit/staged-dictionary/exact-checkpoint averages improved to
  53.827 / 26.660 / 19.368 ms. Bounded checkpoint coalescing remained clean:
  20,570 groups, 1.160 fragments/group, 720 capacity and 19,847 ingress
  flushes, three latency flushes, and zero rollback/deadline/fanout/headroom
  events.
- Every one of the 12 generator clients reached the 768 CWND cap, clipping
  11,626,288 additive increases. This is the direct explanation for the
  2.119% offer shortfall; the proof chain stayed within 0.6% of actual offered
  load and did not backpressure. The next experiment is therefore a strict
  same-15k A/B with only `NATIVE_LOAD_ADAPTIVE_MAX_CWND=1536`. It must retain
  the proof, cleanup, backpressure, drain, and all-three-p99 sub-second gates
  before either raising target or changing block/candidate geometry.
- Artifact directory: `benchmark-results/20260901T102814Z`.

## Cycle 27 — 15k 1,536-CWND A/B, injector self-congestion (20260901T105048Z)

- TON image revision label: `bd57ea20`; Docker harness revision: `e15694d`.
  Both source trees were clean. This is the direct fresh-state A/B against
  Cycle 26: 15,000 target, 4,096 sources, 60/60/700/300-second timing,
  no-gossip topology, 8,192-entry candidate allowance, and 2,048-message
  transport window are unchanged. Its sole runtime change doubles adaptive
  CWND from 768 to 1,536 (two complete 64-message batches per client).
- Proof correctness, completion, canonical cleanup, follower completion, and
  broadcast-control lifecycle passed. It is **not** an ingress or chain
  capacity result: offered/admitted/proof-chain TPS was only 11,356.777 /
  11,356.777 / 11,339.049, or 75.7% of target. The formal invalid reasons are
  `offer_target_not_attained` and `insufficient_load_over_canonical_throughput`.
  This must not be interpreted as the validator ceiling. As in all cycles,
  `reproducible=false` is only the external Session Stats image-label caveat.
- The doubled window self-congested the injection/admission path. All 12
  clients hit their cap and 9,188,499 AIMD increases were clipped, while RTT
  p50/p95/p99 rose from Cycle 26's 50/200/500 ms to 200/500/500 ms. Source
  canonical-backlog caps activated, the global backlog reached 128,634, and
  20 brief global guard pauses consumed 0.266% of the measured interval.
  The proof drain stayed correct but lengthened to 7.151 seconds.
- Total collation, collation wall, and accepted-block-interval p99 were
  379.7 / 413.0 / 549.0 ms; their absolute maxima were 529.1 / 583.0 /
  960.9 ms. Those figures are not an improvement over Cycle 26 because they
  accompany a 22.3% proof-TPS regression and smaller blocks: 2,640 proof
  blocks at 3,002.271 transfers each, versus Cycle 26's 1,745 at 5,845.317.
  The lower work per candidate explains the superficially better tail values.
- This rejects a two-full-batch-per-client window. The next one-variable A/B
  remains at 15k but uses `NATIVE_LOAD_ADAPTIVE_MAX_CWND=864`: exactly 72
  permits per client (one complete 64-message batch plus an 8-message tail),
  a 12.5% increase over Cycle 26 rather than a 100% jump. It must retain all
  formal capacity gates and all three p99 values below one second. If 864
  remains capped with Cycle-26-like RTT/backlog, 960 is the next bounded
  fallback; any renewed 100/500-ms RTT regime reverts to 768.
- Artifact directory: `benchmark-results/20260901T105048Z`.

## Cycle 28 — 15k 864-CWND midpoint, valid but regressive (20260901T111218Z)

- TON image revision label: `bd57ea20`; Docker harness revision: `db8fa54`.
  Both source trees were clean. This fresh-state C26/C27 midpoint holds the
  15k target, 4,096 sources, timing, no-gossip topology, 8,192-entry
  candidate allowance, and 2,048-message transport window fixed. Its only
  change is CWND 768 to 864, distributed evenly as 72 permits per client: one
  complete 64-message batch plus an 8-message tail.
- All formal proof correctness, completion, ingress/chain capacity, canonical
  cleanup, follower, and broadcast-lifecycle gates passed. Offered/admitted/
  proof-chain TPS was 14,317.877 / 14,317.877 / 14,275.824, with zero
  measured canonical-backpressure, a 103,749 sampled backlog peak, and a
  5.302-second clean drain. This clears the formal 95% offer gate but is a
  regression from Cycle 26's 14,592.386 proof TPS at CWND 768. The complete
  canonical one-second maximum was 26,931 TPS, a burst rather than sustained
  capacity. `reproducible=false` remains only the external Session Stats
  image-label caveat.
- The user p99 policy remains satisfied: total collation, collation wall, and
  accepted-block interval p99 were 588.8 / 642.5 / 780.5 ms. However each is
  slightly worse than Cycle 26's 581.9 / 636.7 / 766.7 ms, and p95 admission
  RTT rose from 200 to 500 ms. Absolute total/wall/accepted maxima were
  720.9 / 771.1 / 1,291.9 ms; the accepted maximum is a rare tail reported
  separately from the p99 requirement.
- Proof had 1,800 blocks averaging 5,543.778 transfers, below Cycle 26's
  5,845.317. All 12 clients still hit their cap (11,364,801 clipped increases),
  but the extra eight permits each increased queue residence rather than useful
  parallelism. Native commit/staged-dictionary/checkpoint averages fell to
  46.944 / 23.908 / 16.456 ms only because blocks were less dense; that is not
  a throughput optimization. Coalescing remained correct (18,901 groups,
  1.195 fragments/group, zero rollbacks).
- This closes the global-CWND widening ladder: 768 is the retained 15k
  injector profile; 864 is valid but slower and 1,536 is self-congesting and
  capacity-invalid. The next improvement must seek independent one-batch
  connection parallelism or reduce the admission/collation cost, not increase
  permits per existing client. Any such change is a separate committed source
  treatment and will be retested first against the Cycle 26 15k/768 baseline.
- Artifact directory: `benchmark-results/20260901T111218Z`.

## Cycle 29 — 18 one-batch lanes, valid but liteserver-fragmented (20260901T113700Z)

- TON image revision label: `bd57ea20`; Docker harness revision: `169f949`.
  Both source trees were clean. This is a separate injection-topology treatment
  against Cycle 26: 15k target, 4,096 sources, timing, no-gossip topology,
  8,192-entry candidate allowance, 2,048-message transport window, 6 workers,
  6 signers, and all queue guards are unchanged. Connections increase 12 to
  18 and global CWND 768 to 1,152, preserving exactly 64 permits per client
  (three lanes per worker, not two batches per lane). The 0.0768-second
  initial RTT seed correspondingly starts each lane at approximately 64.
- All formal proof correctness, completion, ingress/chain capacity, canonical
  cleanup, follower, and broadcast-lifecycle gates passed. Offered/admitted/
  proof-chain TPS was 14,361.034 / 14,361.034 / 14,271.970 with zero measured
  canonical-backpressure, a 96,583 sampled backlog peak, and a 6.016-second
  clean drain. It is nevertheless below Cycle 26's 14,592.386 proof TPS at
  12 lanes/768 CWND. The complete canonical one-second maximum was 24,818 TPS,
  a burst rather than sustained capacity. `reproducible=false` remains solely
  the external Session Stats image-label caveat.
- All requested p99 gates remain below one second (total/wall/accepted
  523.0 / 573.3 / 729.9 ms), but those smaller tails are not a throughput win:
  proof packing fell from Cycle 26's 5,845.317 to 4,337.438 transfers/block,
  increasing proof blocks from 1,745 to 2,300. Absolute total/wall/accepted
  maxima were 634.1 / 694.6 / 1,137.3 ms; the rare accepted maximum remains
  separate from the p99 policy.
- The causal evidence rejects more independent streams into this one
  liteserver. Every one of 18 clients reached its 64-message cap, but p50/p95
  RTT rose from Cycle 26's 50/200 ms to 100/500 ms, while wire-batch density
  fell from 30.413 to 27.276 messages/query. All 411,182 dispatches were
  coalescing-deadline releases and none was a full batch, so 18 lanes created
  more fragmented admission work rather than usable parallelism. The lower
  native stage times reflect less dense blocks, not a faster chain.
- This rejects further connection/lane scaling and retains 12 connections,
  768 global CWND (one 64-message batch per client) as the generator baseline.
  The next isolated injection treatment changes only
  `NATIVE_LOAD_SUBMIT_COALESCE_MS` from 20 to 30 at that retained 15k profile.
  The 30-ms bounded leading-edge delay remains below the 50-ms median
  admission RTT and targets the observed deadline-dispatch/query-fragmentation
  cost; it must retain proof/cleanup validity and all three sub-second p99
  gates before any further source or target change.
- Artifact directory: `benchmark-results/20260901T113700Z`.

## Cycle 30 — 30-ms submit coalescing, valid 15k generator baseline (20260901T115801Z)

- TON image revision label: `bd57ea20`; Docker harness revision: `45110fd`.
  Both source trees were clean. This is a strict fresh-state A/B against the
  retained Cycle 26 12-lane/768-CWND profile: 15k target, 4,096 sources,
  12 connections, 6 workers/signers, 64-message batch, 16-message source run,
  timing, no-gossip topology, 8,192-entry candidate allowance, and 2,048
  transport window are unchanged. The sole runtime change is the bounded
  leading-edge submit coalescing deadline: 20 to 30 ms.
- All formal proof correctness, completion, ingress/chain capacity, canonical
  cleanup, follower, and broadcast-lifecycle gates passed. Offered/admitted/
  proof-chain TPS was 14,902.544 / 14,902.544 / 14,819.585, improving Cycle
  26's 14,682.113 / 14,592.386. There was zero measured
  canonical-backpressure, a 116,818 sampled backlog peak below the 131,072
  guard, and a 5.825-second clean drain. The complete canonical one-second
  maximum was 27,351 TPS, a burst rather than sustained capacity.
  `reproducible=false` remains solely the external Session Stats image-label
  caveat.
- This preserves every user sub-second p99 requirement: total collation,
  collation wall, and accepted-block interval p99 were 572.6 / 620.5 / 764.8
  ms (Cycle 26: 581.9 / 636.7 / 766.7 ms). Absolute total/wall/accepted maxima
  were 744.7 / 849.5 / 1,005.4 ms; the rare accepted maximum is separately
  visible and does not replace the p99 policy.
- The direct mechanism is query coalescing, not a block-size change. Wire
  batches grew from 30.413 to 35.648 messages on average (+17.2%), and
  admission queries fell from 382,316 to 330,507 (-13.6%) while preserving
  64-message maxima. All dispatches remained bounded deadline releases (zero
  full-batch releases), p50/p95 RTT stayed 50/200 ms, and all 12 clients
  remained at the known-good 768 cap. Proof packing was effectively unchanged
  (5,845.875 transfers/block), so the improvement is attributable to lower
  liteserver MC-pin/shard-state query amplification.
- This is the retained 15k injection baseline. The next isolated staircase
  step changes only `NATIVE_LOAD_TARGET_TPS` to 16,500, retaining 12
  connections, CWND 768, 30-ms coalescing, and all proof/cleanup/backpressure/
  all-three-p99 gates. A higher coalescing deadline is not tested at 15k
  because this profile already attains the target closely; changing it together
  with rate would confound the capacity result.
- Artifact directory: `benchmark-results/20260901T115801Z`.

## Cycle 31 — 16.5k staircase, injector-window limited (20260901T122050Z)

- TON image revision label: `bd57ea20`; Docker harness revision: `cf30ef8`.
  Both source trees were clean. This is the strict rate staircase from Cycle
  30: sources, 12 connections, six workers/signers, 768 global CWND, 0.05-s
  initial RTT, 30-ms leading-edge submit coalescing, 64-message batches,
  16-message source runs, timing, no-gossip topology, 8,192-entry candidate
  allowance, and 2,048-message transport window are unchanged. The sole
  runtime change is the offered target, 15,000 to 16,500 TPS.
- Proof correctness, completion, cleanup, follower, and broadcast-lifecycle
  gates passed, with zero canonical backpressure, a 101,503 sampled backlog
  peak below the 131,072 guard, and a 5.426-second clean drain. Offered/
  admitted/proof-chain TPS was 15,124.719 / 15,124.719 / 15,103.558. This is
  the highest observed proof-chain average so far, but it is not a valid
  16.5k capacity claim: only 91.67% of the target was offered, so the formal
  ingress gate reports `offer_target_not_attained` and the chain gate reports
  `insufficient_load_over_canonical_throughput`. The complete canonical
  one-second maximum was 27,648 TPS, a burst rather than sustained capacity.
  `reproducible=false` remains solely the external Session Stats image-label
  caveat.
- The user p99 policy remains satisfied: total collation, collation wall, and
  accepted-block interval p99 were 584.5 / 633.2 / 757.0 ms. Absolute
  total/wall/accepted maxima were 723.8 / 775.1 / 1,089.7 ms; the rare
  accepted maximum remains separate from the p99 policy. Proof packing was
  5,951.176 transfers/block over 1,774 proof blocks (maximum 8,192).
- This isolates the present limiter to the injector-window/admission path,
  not a canonical backlog guard or chain failure: proof tracks admitted work
  within 0.14%, no measured backpressure occurred, all 12 clients remained at
  their 768 cap (12,072,189 clipped additive ACKs), and RTT stayed 50/200/500
  ms. Compared with Cycle 30, denser arrival raised average wire batches from
  35.648 to 42.177 messages and reduced admission queries from 330,507 to
  286,224 (-13.4%), yet offer rose only 1.49%.
- The next isolated treatment holds this 16.5k geometry fixed and changes
  only bounded submit coalescing from 30 to 40 ms. It tests whether a modest
  additional leading-edge batching delay can improve the capped injector's
  query efficiency while retaining proof/cleanup validity, zero or <=1%
  canonical backpressure, and all three sub-second p99 gates. It is not
  combined with a block-size, CWND, lane-count, or source change.
- Artifact directory: `benchmark-results/20260901T122050Z`.

## Cycle 32 — 40-ms coalescing rejected (20260901T124204Z)

- TON image revision label: `bd57ea20`; Docker harness revision: `f96c6b0`.
  Both source trees were clean. This is the exact Cycle 31 16.5k injector
  geometry: 4,096 sources, 12 connections, six workers/signers, 768 global
  CWND, 0.05-s initial RTT, 64-message batches, 16-message source runs,
  timing, no-gossip topology, 8,192-entry candidate allowance, and
  2,048-message transport window are unchanged. The sole runtime change is
  bounded leading-edge submit coalescing, 30 to 40 ms.
- Proof correctness, completion, cleanup, follower, and broadcast-lifecycle
  gates passed, with zero measured canonical backpressure, a 109,633 sampled
  backlog peak, and a 6.758-second clean drain. Offered/admitted/proof-chain
  TPS was 14,400.797 / 14,400.797 / 14,399.681. The target-attainment gates
  correctly fail (`offer_target_not_attained` and
  `insufficient_load_over_canonical_throughput`), so this is neither a 16.5k
  capacity result nor a chain limit. The canonical one-second maximum was
  27,648 TPS, a burst rather than sustained capacity. `reproducible=false`
  remains solely the external Session Stats image-label caveat.
- The requested p99 values remain below one second—total collation, collation
  wall, and accepted-block interval were 621.7 / 672.3 / 776.1 ms—but all
  regress from Cycle 31. Absolute total/wall/accepted maxima were 763.4 /
  810.0 / 2,146.2 ms. Proof packing was 5,862.188 transfers/block over 1,717
  proof blocks (maximum 8,192).
- The 40-ms deadline is rejected. Relative to Cycle 31, offered TPS fell
  4.79% and proof TPS fell 4.66%; sampled backlog rose 8.0% and drain rose
  24.6%. Wire batches changed only 42.177 to 42.337 messages on average
  (+0.38%), while admission queries fell only 5.0%; therefore the extra
  wait added latency without material batching benefit. All 12 clients still
  hit their 768 cap and RTT remained 50/200/500 ms.
- Retain the 30-ms policy. The next committed source treatment adds a bounded
  per-client admission-query credit, so a wider message window cannot issue
  multiple concurrent lite-server RPCs on the same connection. It will be
  validated first at the known-good 15k workload before its separate 16.5k
  staircase; this is deliberately not combined with a candidate/block-size,
  lane-count, or consensus change.
- Artifact directory: `benchmark-results/20260901T124204Z`.

## Cycle 33 — one-RPC 96-message admission path, valid but packing-limited (20260901T132352Z)

- TON image revision label: `927e94f4`; Docker harness revision: `7c72c85`.
  Both source trees were clean. This is the first integrated treatment of the
  committed per-client admission-query credit: 12 connections, six
  workers/signers, 4,096 sources, 15k target, 30-ms coalescing, timing,
  no-gossip topology, 8,192-entry candidate allowance, and 2,048-message
  transport window are retained. A 1,152 global message CWND and 0.0768-s
  initial RTT seed provide exactly one 96-message capacity per client;
  96-message batches and `submit_max_queries_per_client=1` prevent a client
  from issuing two concurrent admission RPCs. This is a coherent injector
  architecture treatment, not a naked CWND increase.
- All proof correctness, completion, ingress/chain capacity, canonical
  cleanup, follower, and broadcast-lifecycle gates passed. Offered/admitted/
  proof-chain TPS was 14,363.719 / 14,363.719 / 14,250.388 (95.76% target).
  There was one 51.05-ms global-backlog pause (0.0000729 of the measurement),
  a 122,706 sampled backlog peak below the 131,072 guard, and a 7.773-second
  clean drain. The canonical one-second maximum was 23,840 TPS, a burst
  rather than sustained capacity. `reproducible=false` remains solely the
  external Session Stats image-label caveat.
- The user p99 policy is comfortably satisfied: total collation, collation
  wall, and accepted-block interval p99 were 537.8 / 579.7 / 662.6 ms.
  Absolute total/wall/accepted maxima were 643.7 / 687.4 / 1,183.3 ms; the
  rare accepted maximum is reported separately. Proof had 2,281 blocks
  averaging 4,366.954 transfers (maximum 8,192).
- The query-credit mechanism itself is proven. All 12 client credits reached
  the sampled cap, `max_per_client_admission_queries=1`, and 92,602 bounded
  query-credit stalls occurred. It issued 129,169 admission queries for
  11,404,543 messages: 88.292 messages/query on average (maximum 96), versus
  Cycle 30's 330,507 queries and 35.648 messages/query. This is a 60.9%
  query reduction and 147.7% density increase without concurrent-RPC fanout.
- It is nevertheless not the retained throughput profile: proof TPS is 3.84%
  below Cycle 30 and packing is 25.3% lower, producing 28.7% more blocks.
  The smaller p99 values reflect shorter, less-full blocks rather than higher
  capacity. Retain the 30-ms/64-message/768-CWND profile for injection
  throughput; preserve the query-credit design as a safe high-density control.
  The next source investigation targets bounded collator ready-window packing
  and staged-state work, with an explicit proof/cleanup/all-three-p99 A/B
  before any further rate claim.
- Artifact directory: `benchmark-results/20260901T132352Z`.

## Cycle 34 — 20-ms post-commit pack grace, valid source-only improvement (20260901T140340Z)

- TON image revision label: `ac05d8d3`; Docker harness revision: `c75d316`.
  This is a strict source-only A/B against Cycle 33's high-density injector:
  15k target, 4,096 sources, 12 connections, six workers/signers, 96-message
  batches, 16-message source runs, one admission RPC per client, 1,152 global
  CWND, 0.0768-s initial RTT, 30-ms submit coalescing, timing, no-gossip
  topology, 8,192-entry candidate allowance, and 2,048-message transport
  window are unchanged. The source changes only the already-committed
  checkpoint-safe post-commit empty-queue packing grace from 10 to 20 ms;
  partial-fragment grace remains 10 ms and the wait remains soft-timeout
  clamped.
- All proof correctness, completion, ingress/chain capacity, canonical
  cleanup, follower, and broadcast-lifecycle gates passed. Offered/admitted/
  proof-chain TPS was 14,619.196 / 14,619.196 / 14,534.811, improving Cycle
  33's 14,363.719 / 14,250.388. Six short backlog pauses totalled 0.140 s
  (0.0200% of measurement), the sampled peak was 121,293 below the 131,072
  guard, and drain was a clean 6.510 s. The complete canonical one-second
  maximum was 26,112 TPS, a burst rather than sustained capacity.
  `reproducible=false` remains solely the external Session Stats image-label
  caveat.
- The user p99 policy remains satisfied: total collation, collation wall, and
  accepted-block interval p99 were 615.9 / 667.4 / 819.3 ms. Absolute
  total/wall/accepted maxima were 708.4 / 805.0 / 2,338.0 ms; the rare
  accepted tail is reported separately and means the grace should not be
  lengthened blindly.
- The packing mechanism is directly confirmed. Proof blocks fell 2,281 to
  1,648 (-27.75%) while transfers/block rose 4,366.954 to 6,164.947 (+41.17%).
  Post-commit idle timeouts fell 2,284 to 1,639 despite more idle waits
  (8,174 to 11,019); query-credit behavior and batch density were effectively
  unchanged at all 12 credits and 88.335 messages/query. Thus the gain is not
  an injector artifact. Checkpoint rebuilds rose 15.0%, and native commit /
  staged-dictionary work rose with fuller candidates, identifying the next
  source bottleneck.
- Retain the 20-ms post-commit pack grace for the high-density profile. It is
  a source-only win over Cycle 33 but does not yet replace the distinct Cycle
  30 30-ms/64-message/768-CWND 15k baseline (14,819.585 proof TPS). The next
  committed source treatment targets bulk-safe staged ShardAccounts
  dictionary updates and exact checkpoint work; it will be tested first at
  this same high-density workload with proof/cleanup/backpressure and all
  three p99 gates unchanged.
- Artifact directory: `benchmark-results/20260901T140340Z`.

## Cycle 35 — bulk staged ShardAccounts update, valid source-only improvement (20260901T145219Z)

- TON image revision label: `e507ba00`; Docker harness revision: `064435b`.
  This is a strict source-only A/B against Cycle 34: the selected genesis and
  generator environment arrays are byte-identical (15k target, 4,096 sources,
  12 connections, six workers/signers, 96-message batches, 16-message source
  runs, one admission RPC per client, 1,152 global CWND, 0.0768-s initial RTT,
  30-ms submit coalescing, timing, no-gossip topology, 8,192-entry candidate
  allowance, and 2,048-message transport window). The only functional change
  is `e507ba00`: `AugmentedDictionary::set_many_sorted` builds and atomically
  merges the sorted staged ShardAccounts updates before the existing exact
  hard/size preflight. The harness tree was clean; its revision differs from
  Cycle 34 only because Cycle 34's report was committed after that run.
- All proof correctness, completion, ingress/chain capacity, canonical
  cleanup, follower, and broadcast-lifecycle gates passed. Offered/admitted/
  proof-chain TPS was 14,998.146 / 14,998.146 / 14,948.825, improving Cycle
  34's 14,619.196 / 14,619.196 / 14,534.811. Measured canonical backpressure
  fell from 0.0200% to zero, sampled backlog fell 121,293 to 84,705, and clean
  drain fell 6.510 to 4.233 seconds. The complete canonical one-second maximum
  was 26,521 TPS, a burst rather than sustained capacity.
  `reproducible=false` remains solely the external Session Stats image-label
  caveat.
- The user p99 policy remains satisfied and improves: total collation,
  collation wall, and accepted-block interval p99 were 597.9 / 651.0 / 800.4
  ms (Cycle 34: 615.9 / 667.4 / 819.3 ms). Absolute total/wall/accepted
  maxima were 719.9 / 768.1 / 1,096.0 ms; the rare accepted maximum is
  reported separately from the p99 policy. Proof packing rose slightly from
  6,164.947 to 6,238.350 transfers/block (maximum 8,192).
- The intended hot-path mechanism is confirmed without changing checkpoint
  geometry: native commit average fell 49.787 to 47.256 ms (-5.08%), staged
  dictionary set fell 23.732 to 22.226 ms (-6.35%), and exact checkpoint
  rebuild fell 18.942 to 17.928 ms (-5.35%). Checkpoint groups/rebuilds were
  20,634 versus 20,223, averaging 509.05 entries and 1.1585 fragments/group
  (Cycle 34: 505.41 and 1.1646); there were zero rollbacks. Thus the TPS gain
  comes from a faster equivalent staged-dictionary operation, not a hidden
  batch-size or cadence change.
- Query-credit behavior remained bounded and comparable: all 12 clients
  reached the one-query cap, the observed per-client maximum was one, wire
  batches averaged 89.166 messages (maximum 96), and no full-batch release
  bypassed the cap. Exact proof evidence matched 11,848,617 canonical
  source/nonce/external-cell hashes, with zero conflicts, duplicate nonces,
  nonce gaps, generator timeouts, or follower errors; final catch-up passed.
- Retain `e507ba00` as the best valid high-density source profile so far.
  It remains distinct from Cycle 30's 14,819.585 TPS 64-message injector
  baseline, but now exceeds it by 129.240 TPS while preserving all p99 gates.
  Do not immediately enlarge candidates or post-commit grace: the 8,192 cap
  is not the current size limit and the accepted-interval p99 has only about
  200 ms of margin. The next benchmark should be a controlled target staircase
  (15.5k first) with this exact profile, retaining proof/cleanup, <=1%
  backpressure, and all three sub-second p99 gates before any claim of a new
  capacity level.
- Artifact directory: `benchmark-results/20260901T145219Z`.

## Cycle 36 — 10-ms post-commit grace, three-block cadence mode (20260901T161728Z)

- TON image revision label: `2fbea2ea`; Docker harness revision: `650950b`.
  This is a strict source-only timing A/B against Cycle 35: sorted genesis and
  generator benchmark-environment arrays are identical (15k target, 4,096
  sources, 12 connections, six workers/signers, 96-message batches,
  16-message source runs, one admission RPC per client, 1,152 global CWND,
  0.0768-s initial RTT, 30-ms submit coalescing, timing, no-gossip topology,
  8,192-entry candidate allowance, and 2,048-message transport window). The
  sole functional source change restores the post-commit pack grace from 20
  to 10 ms. The partial-fragment grace remains 10 ms; the work-driven outer
  failure timeout and consensus timing model are unchanged.
- Proof correctness, completion, canonical cleanup, follower, and
  broadcast-lifecycle gates passed. The run is deliberately *not* a 15k
  capacity pass: offered/admitted/proof-chain TPS was 13,940.799 / 13,940.799
  / 13,852.770, only 92.94% of the offered target. The formal invalid reasons
  are `offer_target_not_attained` and
  `insufficient_load_over_canonical_throughput`; canonical backpressure was
  0.2867%, below the independent <=1% limit, and clean drain completed in
  6.613 seconds. `reproducible=false` remains solely the external Session
  Stats image-label caveat.
- The cadence objective is conclusively met. The proof cohort contains 2,370
  native basechain blocks in 700 seconds, or 3.386 blocks/s, versus Cycle 35's
  1,675 / 700 = 2.393 blocks/s. Total collation, collation wall, and
  accepted-block-interval p99 were 515.9 / 560.4 / 661.1 ms, all below one
  second and improved from Cycle 35's 597.9 / 651.0 / 800.4 ms. Absolute
  maxima were 697.0 / 749.3 / 917.7 ms, so this run has no observed
  accepted-interval sample above one second either.
- The cost is direct and material: proof TPS falls 7.33% from 14,948.825 to
  13,852.770, while blocks increase 41.49% and proof packing falls 34.51%
  from 6,238.346 to 4,085.690 transfers/block (maximum remains 8,192).
  This is the expected fixed per-block checkpoint/state/consensus overhead,
  not a block-size limit or proof failure. Native commit and checkpoint timing
  are lower per candidate because candidates are smaller; that must not be
  misattributed to a faster equivalent throughput path.
- Retain `2fbea2ea` only as an optional low-latency / >=3-blocks/s desktop
  cadence profile. Retain Cycle 35's `e507ba00` 20-ms grace as the maximum
  sustained-TPS profile. Do not change `SIMPLEX_TARGET_RATE_MS` or the 8-second
  candidate timeout to chase block frequency: in work-driven max-TPS mode they
  are failure/cancellation bounds rather than successful-block pacing. The
  next source treatment should remove repeated exact checkpoint storage-stat
  copying/rebuild work, with exact materialized-versus-overlay equivalence
  tests, before re-attempting the three-block cadence at a higher throughput.
- Artifact directory: `benchmark-results/20260901T161728Z`.

## Cycle 37 — exact storage-stat overlay, rejected performance treatment (20260901T170237Z)

- TON image revision label: `ace787c6`; Docker harness revision: `ad00353`.
  This is a strict source-only A/B against Cycle 36: the sorted genesis and
  generator benchmark-environment arrays are byte-identical. The source
  treatment keeps the native checkpoint baseline immutable, evaluates each
  tentative proof as an exact storage-stat overlay, and materializes the full
  statistic only at the final native root. The harness revision differs only
  because the Cycle 36 report was committed after that run.
- Proof correctness, completion, canonical cleanup, follower, and
  broadcast-lifecycle gates passed. Exact proof evidence matched 10,956,477
  canonical source/nonce/external-cell hashes, with zero conflicts, follower
  errors, or reorgs; final catch-up passed. The run is nevertheless not a 15k
  capacity pass: offered/admitted/proof-chain TPS was 13,723.586 / 13,723.586
  / 13,639.542 (91.49% of target). The formal invalid reasons are
  `offer_target_not_attained` and
  `insufficient_load_over_canonical_throughput`. Backpressure was 0.4965%,
  still within the independent <=1% limit, while sampled backlog was 129,500
  and clean drain took 7.572 seconds. `reproducible=false` remains solely the
  external Session Stats image-label caveat.
- The three-block cadence is retained but does not improve: 2,350 native
  basechain blocks in 700 seconds is 3.357 blocks/s, versus Cycle 36's 2,370
  / 700 = 3.386 blocks/s. Proof TPS fell 1.54% from 13,852.770 to 13,639.542,
  and proof packing fell from 4,085.690 to 4,057.038 transfers/block
  (maximum remains 8,192). This is also 8.76% below Cycle 35's valid
  14,948.825-TPS high-density result.
- The required p99 gates remain sub-second but all regress against Cycle 36:
  total collation, collation wall, and accepted-block interval p99 were
  534.1 / 585.2 / 744.5 ms, versus 515.9 / 560.4 / 661.1 ms. Absolute
  total/wall/accepted maxima were 1,264.8 / 1,366.1 / 2,399.9 ms; unlike
  Cycle 36, this treatment has observed samples above one second.
- The intended hot path regressed despite preserving exact proof semantics.
  Checkpoint rebuilds increased from 14,859 to 16,273, and the measured
  checkpoint stage average rose 55.8%, from 6.081 to 9.471 ms/candidate.
  The corresponding aggregate stage time rose from 14.526 to 22.466 seconds;
  normalized by rebuild, it is about 0.978 to 1.381 ms/rebuild. The overlay
  is therefore correct but slower under the identical C36 runtime profile.
- Reject and revert this storage-stat overlay on the performance branch rather
  than applying it to the Cycle 35 maximum-TPS profile. Retain Cycle 36's
  `2fbea2ea` path as the optional >=3-blocks/s cadence mode and Cycle 35's
  `e507ba00` path as the maximum valid sustained-TPS profile. A future
  checkpoint experiment should first instrument and eliminate the extra
  per-rebuild cost before another 10-ms-grace throughput attempt.
- Artifact directory: `benchmark-results/20260901T170237Z`.

## Cycle 38 — native immediate actor fast lane, valid three-block cadence recovery (20260901T173628Z)

- TON image revision label: `9cd0de4e`; Docker harness revision: `9938359`.
  This is a strict runtime-environment A/B against Cycle 36: the sorted
  genesis and native-load-generator environment arrays are byte-identical
  (15k target, 4,096 sources, 12 connections, six workers/signers,
  96-message batches, 16-message source runs, one admission RPC per client,
  1,152 global CWND, 0.0768-s initial RTT, 30-ms submit coalescing, timing,
  no-gossip topology, 8,192-entry candidate allowance, and 2,048-message
  transport window). The new source treatment is native-only immediate actor
  handoff at the Collator -> ValidatorManager -> ExtMessagePool seams; the
  generic path remains scheduled. Cycle 37 is the direct inherited-source
  behavioral comparator, while Cycle 36 supplies the exact runtime baseline.
- All proof correctness, completion, ingress/chain-capacity, canonical
  cleanup, follower, and broadcast-lifecycle gates passed. Exact proof
  evidence matched 11,690,572 canonical source/nonce/external-cell hashes,
  with zero conflicts, follower errors, or reorgs; final catch-up passed and
  the native pool/reconciliation state was clean. Offered/admitted/proof-chain
  TPS was 14,772.390 / 14,772.390 / 14,678.515: +5.97% / +5.96% proof over
  Cycle 36 and +7.64% / +7.62% over Cycle 37. This clears the formal 15k
  workload capacity gates. `reproducible=false` remains solely the external
  Session Stats image-label caveat.
- The cadence objective remains met: 2,270 proof blocks in 700 seconds is
  3.243 blocks/s. That is below Cycle 36's 3.386 blocks/s, but higher packing
  (4,519.948 versus 4,085.690 transfers/block, maximum 8,192) recovers the
  throughput. Canonical backpressure fell from 0.2867% to zero; sampled
  backlog fell 127,609 to 115,145 and clean drain fell 6.613 to 5.358 seconds.
  The 25,600 one-second maximum is a burst, not a sustained-capacity claim.
- All required p99 values remain sub-second: total collation, collation wall,
  and accepted-block interval were 525.244 / 576.667 / 709.828 ms. Relative
  to Cycle 36 these are +9.298 / +16.279 / +48.731 ms, so the throughput win
  does consume some ordinary cadence margin. Absolute total/wall/accepted
  maxima were 659.437 / 689.408 / 957.271 ms—still all below one second, and
  far below Cycle 37's 1,264.842 / 1,366.090 / 2,399.939-ms tail.
- The telemetry supports the fast lane rather than an injector artifact.
  Native first-work wait fell from 263.141 s across 2,392 calls in Cycle 36
  (110.009 ms/call; 69.01% of accounted external wait) to 193.965 s across
  2,308 calls (84.040 ms/call; 53.43%): -23.61% per call and -69.176 s in
  aggregate. Native fragment-refill and post-commit-idle averages also fell
  31.14% and 11.55%, respectively, while total reconciled external wait fell
  381.310 to 363.002 seconds. Against Cycle 37, first-work latency improved
  another 12.69% per call and all three absolute tail maxima improved.
- Retain the native immediate actor handoff as the first valid >=3-blocks/s
  cadence recovery, but do not yet raise the target or lengthen packing grace:
  accepted-interval p99 rose 7.37% from Cycle 36 and its 957.271-ms maximum
  leaves only 42.729 ms below one second. The checkpoint stage remains a
  material C36 regression (average 6.081 to 9.959 ms, p99 31.031 to
  44.705 ms, rebuilds +30.7%). Rebase/isolate the fast lane on the reverted
  Cycle 36 checkpoint path, then repeat this exact runtime A/B before a target
  staircase. Cycle 35 remains the higher proof-TPS profile (14,948.825) but
  does not provide this three-block cadence.
- Artifact directory: `benchmark-results/20260901T173628Z`.

## Cycle 39 — 15.5k target staircase, new valid >=3-blocks/s throughput high (20260901T180013Z)

- TON image revision label: `9cd0de4e`; Docker harness revision: `268257c`.
  This is an exact Cycle 38 runtime staircase: the sorted genesis and
  native-load-generator benchmark-environment arrays differ only in
  `NATIVE_LOAD_TARGET_TPS=15000 -> 15500`. The TON/generator source labels,
  4,096 sources, 12 connections, six workers/signers, 96-message batches,
  16-message source runs, one admission RPC per client, 1,152 global CWND,
  0.0768-s initial RTT,
  30-ms submit coalescing, timing, no-gossip topology, 8,192-entry candidate
  allowance, and 2,048-message transport window are unchanged. The harness
  tree was clean; its revision advances only because the Cycle 38 report was
  committed after that run.
- Every substantive acceptance dimension passed: proof correctness,
  completion, ingress capacity, chain capacity, canonical cleanup, follower,
  and broadcast lifecycle. Exact proof evidence matched 11,964,934 canonical
  source/nonce/external-cell hashes with zero conflicts, follower errors,
  reorgs, duplicate nonce conflicts, or nonce gaps; final catch-up completed
  and the native pool/reconciliation state was clean. `reproducible=false`
  remains solely the unchanged external Session Stats image-label caveat.
- Offered/admitted/proof-chain TPS was 15,100.004 / 15,100.004 / 15,002.319.
  Against Cycle 38 this is +327.614 / +327.614 / +323.804 TPS (+2.22% / +2.22%
  / +2.21%). It becomes the highest valid sustained proof result recorded in
  this campaign, narrowly exceeding Cycle 35's 14,948.825 TPS by 53.494 TPS
  while retaining the faster cadence. The 24,864 canonical one-second maximum
  is a burst, not a sustained-capacity claim.
- Cadence improves rather than trades away: 2,338 proof blocks in 700 seconds
  is 3.340 blocks/s (Cycle 38: 2,270 / 700 = 3.243 blocks/s). Proof packing is
  essentially flat at 4,485.296 transfers/block versus 4,519.948 (-0.77%),
  with the same 8,192 maximum. Measured canonical backpressure remains zero;
  sampled backlog falls 115,145 to 103,132 (-10.43%), and clean drain remains
  short at 5.899 seconds (Cycle 38: 5.358 seconds).
- The sub-second cadence policy has more margin at the higher target. Total
  collation, collation wall, and accepted-block interval p99 were 503.738 /
  546.905 / 672.765 ms, improving Cycle 38 by 21.506 / 29.762 / 37.063 ms.
  Absolute total/wall/accepted maxima were 664.734 / 721.029 / 947.704 ms,
  all below one second; collate-start p99/max were 718.023 / 901.886 ms. Thus
  the target increase did not produce a hidden long-tail cadence regression.
- Retain `9cd0de4e` and advance the clean staircase to a 16k target with this
  exact runtime profile before changing source again. This result has zero
  backpressure, lower p99 and backlog, and 3.34 blocks/s at a new sustained
  high, so it establishes real headroom. The first invalid capacity or cadence
  rung should become the source-optimization boundary; until then, changing
  the immediate actor fast lane would confound the capacity curve.
- Artifact directory: `benchmark-results/20260901T180013Z`.

## Cycle 40 — 16k target staircase, maximum valid sustained proof TPS (20260901T182252Z)

- TON image revision label: `9cd0de4e`; Docker harness revision: `41e320f`.
  This is an exact Cycle 39 runtime staircase: the sorted genesis and
  native-load-generator benchmark-environment arrays differ only in
  `NATIVE_LOAD_TARGET_TPS=15500 -> 16000`. The TON/generator source labels,
  4,096 sources, 12 connections, six workers/signers, 96-message batches,
  16-message source runs, one admission RPC per client, 1,152 global CWND,
  0.0768-s initial RTT, 30-ms submit coalescing, timing, no-gossip topology,
  8,192-entry candidate allowance, and 2,048-message transport window are
  unchanged. The clean harness revision differs only because the Cycle 39
  report was committed after that run.
- All formal proof correctness, completion, ingress/chain-capacity, canonical
  cleanup, follower, and broadcast-lifecycle gates passed. Exact proof evidence
  matched 12,109,834 canonical source/nonce/external-cell hashes with zero
  conflicts, follower errors, reorgs, duplicate nonce conflicts, or nonce
  gaps; final catch-up completed and native-pool cleanup passed.
  `reproducible=false` remains solely the unchanged external Session Stats
  image-label caveat.
- Offered/admitted/proof-chain TPS was 15,242.720 / 15,242.720 / 15,150.778.
  That is a new valid sustained proof maximum, +148.459 TPS (+0.99%) over
  Cycle 39, with a 28,544 canonical one-second burst maximum that must not be
  presented as sustained capacity. The formal 16k ingress pass is narrow:
  offered load is 95.267% of target, only 42.720 TPS above the 15,200-TPS
  95% threshold. The +500 target produces only +142.716 offered TPS, so the
  staircase is visibly flattening.
- The >=3-blocks/s requirement is retained: 2,348 proof blocks in 700 seconds
  is 3.354 blocks/s (Cycle 39: 3.340). Proof packing is 4,510.389
  transfers/block (+0.56%, maximum 8,192), canonical backpressure remains
  zero, sampled backlog rises modestly 103,132 to 114,472, and clean drain
  improves 5.899 to 5.342 seconds.
- Required p99 cadence gates remain safely sub-second: total collation,
  collation wall, and accepted-block interval were 503.894 / 554.649 /
  648.169 ms. Their corresponding maxima were 727.869 / 764.623 / 1,419.564
  ms; collate-start p99/max were 738.700 / 1,242.014 ms. Thus normal cadence
  improves or holds at 16k, but the two rare interval maxima above one second
  remove the all-samples sub-second margin Cycle 39 happened to show.
- Retain 16k as the current maximum valid runtime rung, but do not advance to
  16.5k without an isolated treatment: the formal ingress margin is only
  0.267 percentage points and the rare interval tail has crossed one second.
  The next work should separately diagnose a source or ingress bottleneck and
  then A/B one change at this 16k profile. All 12 clients reached both the
  observed CWND and query caps, yet prior wider-CWND/query-credit experiments
  regressed; do not bundle those knobs or source changes into another target
  step. A confirmation repeat at 16k is appropriate before promoting a new
  configuration, while a 16.5k staircase is expected to fail the current
  capacity margin rather than identify a useful new limit.
- Artifact directory: `benchmark-results/20260901T182252Z`.

## Cycle 41 — rejected initial native-pump immediate source A/B at 16k (20260901T190005Z)

- TON and native-generator image revision labels are `394a374a`; the clean
  Docker harness revision is `4ce6722`. This is a strict source A/B of Cycle
  40 (`9cd0de4e`): the `.env` SHA-256, Compose configuration and per-service
  hashes, CPU sets and resource limits, and sorted genesis/generator benchmark
  environment arrays are identical. It retains the 16,000-TPS target, 4,096
  sources, 12 connections, six workers/signers, 96-message batches, 16-message
  source runs, one admission RPC per client, 1,152 global CWND, 0.0768-s
  initial RTT, 30-ms coalescing, 8,192-entry candidate allowance, and
  2,048-message transport window. The only runtime image-label difference is
  `9cd0de4e -> 394a374a`.
- The source treatment is limited to the initial native callback producer:
  `ExtMessagePool` registers the live callback, then starts only that initial
  native pump with `start_immediate`; wake/refill and generic producers remain
  deferred. The patch also uses a private named start mode and requires native
  streaming for the immediate branch. It is therefore a source scheduling A/B,
  not an injector, Simplex, capacity, or topology change.
- Proof correctness, completion, cleanup, follower, and broadcast-lifecycle
  gates passed. The final proof matched 11,993,947 exact canonical
  source/nonce/external-cell hashes with zero hash conflicts, nonce gaps,
  duplicate nonce conflicts, follower errors, or reorgs; final follower
  catch-up and native-pool/reconciliation cleanup completed. As before,
  `reproducible=false` is solely the Session Stats image-label caveat.
  However, the run is not capacity-qualified: offered/admitted TPS was
  15,077.154, only 94.232% of the 16k target and 122.846 TPS below the
  15,200-TPS ingress threshold. The formal ingress gate consequently reports
  `offer_target_not_attained`, and the chain-capacity gate reports
  `insufficient_load_over_canonical_throughput`; those are the only acceptance
  failures.
- Proof-chain TPS is 14,991.529, down 159.249 TPS (-1.05%) from Cycle 40's
  valid 15,150.778. The >=3-blocks/s requirement still passes at 2,335 proof
  blocks / 700 seconds = 3.336 blocks/s (Cycle 40: 3.354). Packing falls from
  4,510.389 to 4,487.828 transfers/block, with the same 8,192 maximum; the
  one-second canonical burst maximum falls from 28,544 to 25,984.
- Required p99 cadence remains sub-second but regresses: total collation /
  collation wall / accepted interval are 540.561 / 583.552 / 667.778 ms,
  versus 503.894 / 554.649 / 648.169 ms in Cycle 40. Collate-start p99 is
  746.626 ms versus 738.700 ms. Some absolute tails improve (accepted-interval
  maximum 1,237.115 ms versus 1,419.564 ms), but that does not offset the
  capacity-gate failure; validated-block p99/max also rise from 85.921 / 200.534
  to 94.264 / 248.065 ms.
- Backpressure and backlog lose the Cycle 40 margin: 24 canonical-backpressure
  events pause the measured window for 1.532 seconds (0.219%; Cycle 40: zero),
  sampled backlog rises 114,472 to 130,038, and drain is essentially flat at
  5.353 seconds (Cycle 40: 5.342). Native transport remains bounded and clean:
  high-water is 2,561 (Cycle 40: 2,560), maximum push/pop batches remain
  2,048 / 512, and final reserved, pending, live-queued, and live-unpushed
  counts are all zero.
- The treatment achieved its narrow local aim but not an end-to-end gain.
  `native_first_work` falls from 216.752640 seconds across 2,369 calls
  (91.495 ms/call) to 204.880159 seconds across 2,368 calls (86.520 ms/call):
  -11.872481 seconds, or -4.975 ms/call (-5.44%). That saving is partly offset
  by native fragment-refill wait rising 78.876 to 85.134 seconds and
  post-commit-idle wait rising 54.097 to 55.552 seconds. With fewer accepted
  transfers, checkpoint groups also become smaller (560.624 versus 579.499
  entries/group) and delayed items rise 67,763 to 93,824. These are consistent
  with a changed scheduling balance, but one A/B run cannot prove that the
  source change rather than normal run variation caused every downstream tail.
- Reject `394a374a` as the capacity baseline and restore/retain `9cd0de4e` for
  the valid 16k profile; do not advance to 16.5k. The evidence supports keeping
  the initial-pump timing observation as diagnostic information, not retaining
  the treatment. Any future injector or source experiment must start from the
  restored baseline, alter one dimension, repeat the exact formal gates, and
  compare first-work/refill/idle timing separately from proof TPS.
- Artifact directory: `benchmark-results/20260901T190005Z`.

## Cycle 42 — restored-C40 16k control, repeatability boundary (20260901T193522Z)

- TON and native-generator image revision labels are `7d5f775a`; Docker
  harness revision is `33d34ae`. This is a true restoration control rather
  than another source treatment: `7d5f775a` has the same Git tree object as
  Cycle 40's `9cd0de4e` (`git diff --quiet 9cd0de4e 7d5f775a` succeeds). The
  `.env` SHA-256 (`b22279ae...`), Compose configuration and per-service
  hashes, and normalized sorted container benchmark environments, CPU sets,
  and resource limits are all byte-identical across Cycles 40, 41, and 42.
  It retains the 16,000-TPS target, 4,096 sources, 12 connections, six
  workers/signers, 96-message batches, 16-message source runs, one admission
  RPC per client, 1,152 global CWND, 0.0768-s initial RTT, 30-ms coalescing,
  8,192-entry candidate allowance, and 2,048-message transport window. The
  harness revision advances only because the Cycle 41 report was committed.
- Proof correctness, run completion, canonical cleanup, follower, and
  broadcast-lifecycle gates all pass. The final proof matches 11,831,292
  canonical source/nonce/external-cell hashes with zero hash conflicts, nonce
  gaps, duplicate or external nonce conflicts, follower errors, reorgs, or
  follower retry exhaustion; final catch-up, drain, native transport, and
  native pending-pool cleanup all complete. `reproducible=false` remains only
  the unchanged unlabeled external Session Stats image caveat.
- The restored control nevertheless fails both capacity dimensions. Offered
  and admitted TPS are 14,844.787 (92.780% of the 16k target), 355.213 TPS
  below the 15,200-TPS formal ingress threshold. The sole formal reasons are
  `offer_target_not_attained` and
  `insufficient_load_over_canonical_throughput`; correctness is not in
  question. Proof-chain TPS is 14,725.501: -425.278 (-2.807%) from the valid
  Cycle 40 result and -266.029 (-1.775%) from rejected Cycle 41. This makes
  Cycle 40's narrow 95.267% pass non-repeatable under the identical restored
  runtime, rather than establishing 16k as a stable capacity rung.
- Block production and normal cadence are not the limiting condition. Cycle
  42 produces 2,355 proof blocks in 700 seconds (3.364 blocks/s), higher than
  both Cycle 40's 3.354 and Cycle 41's 3.336. Total-collation, collation-wall,
  and accepted-block-interval p99 are still sub-second at 507.713 / 553.669 /
  639.459 ms (Cycle 40: 503.894 / 554.649 / 648.169 ms); collate-start p99 is
  741.845 ms and validated-block p99 is 93.396 ms. Their total/wall/accepted
  maxima are 688.978 / 730.015 / 1,361.194 ms, so rare acceptance-spacing
  tails remain above one second but the stated p99 cadence objective holds.
- The throughput loss follows lower packing and renewed ingress pressure, not
  a loss of block frequency. Proof packing is 4,370.754 transfers/block,
  -139.636 (-3.096%) from Cycle 40, with the same 8,192 maximum; the peak
  one-second canonical burst is 26,112. Canonical backpressure occurs in 22
  measured events for 1.005 seconds (0.1436%, formally below the 1% limit but
  no longer zero). Sampled backlog rises from Cycle 40's 114,472 / 84,766
  peak/end to 128,657 / 102,880, and clean drain lengthens 5.342 to 6.797
  seconds without timing out. The native transport remains bounded (2,560
  high-water; 2,048/512 max push/pop) and ends with zero reserved, pending,
  live-queued, and live-unpushed messages.
- This run also removes a causal basis for promoting the Cycle 41 initial-pump
  timing observation. On the source-equivalent restored path, first-work wait
  is 233.300 seconds over 2,378 calls (98.108 ms/call), versus 216.753 /
  2,369 (91.495 ms/call) in Cycle 40 and 204.880 / 2,368 (86.520 ms/call) in
  Cycle 41. Refill wait moves in the opposite direction (65.504 seconds here
  versus 78.876 / 85.134), while total reconciled external wait is 372.101
  seconds versus 370.219 / 366.044. The three runs therefore demonstrate
  meaningful run-to-run scheduling/load variance and do not isolate a stable
  throughput gain from the C41 source change.
- Do not run the proposed 128-message/1,536-CWND injector geometry at 16k:
  it would be measured against an invalid and non-repeatable control, while
  adding a larger outstanding window to the higher backlog state. Return to
  the 15.5k target as the provisional next rung and first repeat the restored
  source/profile there. Only after that control passes all capacity gates
  should a single coupled batch-128/CWND-1536/initial-RTT-0.096 (or 0.0961)
  A/B be
  considered, with unchanged qcap=1 and explicit proof that wire-batch density
  rises rather than merely adding deadline queueing.
- Artifact directory: `benchmark-results/20260901T193522Z`.

## Cycle 43 — restored-C39 15.5k confirmation, borderline backpressure rejection (20260901T200039Z)

- TON and native-generator image revision labels are `7d5f775a`; Docker
  harness revision is `3f3f0b8`. This is an exact restored-source
  confirmation of Cycle 39's content: `7d5f775a` and Cycle 39's
  `9cd0de4e` resolve to the same Git tree (`106654e...`). The `.env` SHA-256,
  Compose configuration/service hashes, and normalized sorted container
  benchmark environment, CPU, and resource hashes match the prior runtime
  profile. It retains 4,096 sources, 12 connections, six workers/signers,
  96-message batches, 16-message source runs, one admission RPC per client,
  1,152 global CWND, 0.0768-s initial RTT, 30-ms coalescing, 8,192 candidate
  entries, and a 2,048-message native transport window; the target is 15,500
  TPS.
- Proof correctness, run completion, canonical cleanup, follower, and
  broadcast-lifecycle gates pass. The final proof matches 11,715,622 exact
  canonical source/nonce/external-cell hashes with zero hash conflicts, nonce
  gaps, duplicate or external nonce conflicts, follower errors, reorgs, or
  retry exhaustion. Final catch-up, drain, and native transport/pool cleanup
  complete. `reproducible=false` remains solely the unchanged unlabeled
  Session Stats image caveat.
- The result is nevertheless not capacity-qualified. Offered/admitted TPS is
  14,743.853, or 95.1216% of target: it clears the 14,725-TPS offer floor by
  only 18.853 TPS. Canonical backpressure totals 111 events and 7.018791
  seconds, 1.002684% of the 700-second measurement window. This is 18.791 ms
  over the <=1% gate, so ingress and chain capacity both fail only
  `canonical_backpressure_above_one_percent`; correctness and completion do
  not fail.
- Proof-chain TPS is 14,635.263, down 367.056 TPS (-2.447%) from Cycle 39's
  valid 15,002.319 TPS. Packing falls 4,485.296 to 4,340.284 transfers/block
  (same 8,192 maximum), while block production rises 2,338 to 2,357 blocks:
  3.367 blocks/s. This demonstrates that the rejection is ingress/backlog
  pressure rather than failure to retain the >=3-blocks/s cadence objective.
  The 26,624 one-second canonical bucket is a transient burst, not sustained
  throughput.
- All p99 cadence measures remain sub-second: total collation / collation
  wall / accepted interval / collate start / validation are 512.723 / 559.172
  / 684.073 / 729.833 / 91.896 ms. Rare accepted and start maxima reach
  1,327.347 / 1,567.134 ms, so this run also has less absolute-tail margin
  than Cycle 39. Backpressure/backlog/drain regress from Cycle 39's zero BP,
  103,132 peak backlog, and 5.899-s drain to 7.019 s BP, 130,303 peak backlog,
  and 6.444-s drain.
- Injection and transport controls behaved as configured: CWND is capped at
  1,152 on all 12 clients, the per-client admission-query cap is one with
  observed peak one, wire batches average 90.290 messages (maximum 96), and
  no full-batch dispatch occurs. Transport stays bounded at 2,560 high-water
  with 2,048/512 maximum producer/consumer batches and ends with zero live,
  reserved, pending, or unpushed work.
- Do not promote 15.5k as a stable capacity rung and do not run the coupled
  batch-128/CWND-1536 injector treatment from this borderline control: it
  adds window pressure to exactly the failure mode observed here. Return to a
  strict 15k restored-source control before a larger-window A/B. If that
  control passes comfortably, use a separate one-RPC-per-client batch-128
  experiment with all other runtime dimensions fixed.
- Artifact directory: `benchmark-results/20260901T200039Z`.

## Cycle 44 — restored-C38 15k confirmation, valid control (20260901T202423Z)

- TON and native-generator image revision labels are `7d5f775a`; Docker
  harness revision is `ee93094`. This is an exact restored-source/runtime
  confirmation of Cycle 38: `7d5f775a` and Cycle 38's `9cd0de4e` have the
  same Git tree (`106654e...`). The `.env` SHA-256, Compose/service hashes,
  and normalized sorted runtime environment, CPU, and resource hashes match
  the 15k profile. It retains 4,096 sources, 12 connections, six
  workers/signers, 96-message batches, 16-message source runs, one admission
  RPC per client, 1,152 global CWND, 0.0768-s initial RTT, 30-ms coalescing,
  8,192 candidate entries, 2,048-message transport window, and no-gossip
  control.
- All formal proof correctness, completion, ingress/chain-capacity, and
  validator-cleanup gates pass. Exact proof matches 11,735,952 canonical
  source/nonce/external-cell hashes with zero hash conflicts, nonce gaps,
  duplicate or external nonce conflicts, follower errors, reorgs, or retry
  exhaustion. Final catch-up, drain, and native pending/transport cleanup all
  complete. `reproducible=false` remains solely the known unlabeled Session
  Stats image caveat.
- Offered/admitted/proof-chain TPS is 14,837.160 / 14,837.160 / 14,748.848:
  98.9144% of the 15k target and +64.770 / +70.333 TPS (+0.439% / +0.479%)
  over Cycle 38. Canonical backpressure is zero. The 26,752 canonical
  one-second bucket is a burst, not a sustained capacity claim.
- The >=3-blocks/s and subsecond-cadence objectives both hold: 2,288 proof
  blocks over 700 seconds is 3.269 blocks/s, packing is 4,505.876
  transfers/block (maximum 8,192), and total/wall/accepted/start/validated
  p99s are 525.791 / 568.039 / 676.195 / 747.184 / 101.538 ms. Reported
  total/wall/accepted/start maxima are 706.433 / 751.369 / 891.712 / 892.262
  ms, all below one second. Sampled backlog is 107,814 peak / 80,091 end and
  drain completes in 5.665 seconds without timeout.
- Bounded injection/transport behavior is verified: all 12 clients reach the
  1,152 global CWND cap; qcap remains one RPC per client with observed maximum
  one; batches average 86.878 messages (maximum 96) with no full-batch
  dispatches; native transport high-water is 2,560 with 2,048/512 maximum
  producer/consumer batches and zero final reserved, pending, or live work.
- This is the current repeatable 15k control and authorizes one narrowly
  coupled injector A/B only: retain qcap=1 and all other runtime controls,
  then change batch size 96->128, global CWND 1,152->1,536, and initial RTT
  to 0.1025 seconds so each of 12 persistent clients can carry at most one
  initially full 128-message admission RPC. Do not raise target, widen
  connections, lengthen coalescing, or allow two simultaneous RPCs per
  client in that experiment. Promote it only if proof TPS and wire density
  improve without backpressure, packing, drain, or cadence regressions.
- Artifact directory: `benchmark-results/20260901T202423Z`.

## Cycle 45 — rejected one-RPC 128-message injector geometry at 15k (20260901T204717Z)

- TON and native-generator image labels are `7d5f775a`, with clean source
  trees and identical 15k topology, resources, timing, candidate/transport
  limits, qcap=1, source-run=16, and 30-ms coalescing to Cycle 44. The sorted
  runtime environment differs only in the coupled geometry required to test
  one larger RPC per client: batch size 96->128, global CWND 1,152->1,536,
  and initial RTT 0.0768->0.1025 seconds. The initial window is 1,535.9995
  and effective cap is 1,536, so each of 12 persistent clients can carry at
  most one 128-message admission request.
- The mechanism is exercised exactly as designed: qcap is one, observed
  maximum admission RPCs per client is one, all 12 clients reach the query
  cap, final credit is zero, average wire batch density rises 86.878->112.536
  messages (+29.534%), and wire queries fall 135,086->94,920 (-29.734%). No
  full-batch dispatch occurs, so this density gain remains deadline-driven.
  It is therefore a valid one-RPC geometry test, not the earlier two-RPC
  per-client CWND-1536 failure mode.
- Correctness, completion, cleanup, follower, and broadcast-lifecycle gates
  pass: 10,681,698 exact canonical hashes match with zero hash/nonce/duplicate
  or external conflicts, follower errors, reorgs, or retry exhaustion; final
  catch-up and native queue cleanup complete. `reproducible=false` remains
  only the known unlabeled Session Stats image caveat.
- Capacity fails decisively on load attainment. Offered/admitted TPS falls
  14,837.160->13,331.099 (88.874% of target, 918.901 TPS below the 14,250
  floor), and proof TPS falls 14,748.848->13,172.461 (-10.688%). Formal
  reasons are only `offer_target_not_attained` and
  `insufficient_load_over_canonical_throughput`; this is not a proof failure.
  The 24,576 one-second canonical bucket is a transient burst, not capacity.
- Blocks rise 2,288->2,934 (3.269->4.191 blocks/s), but this is harmful
  under-packing rather than throughput: packing falls 4,505.876->3,138.224
  transfers/block (-30.353%, same 8,192 maximum). Backlog peak/end rises
  107,814/80,091->130,879/125,654 and drain lengthens 5.665->9.704 seconds.
  Backpressure is 5.164 seconds (0.7378%), formally below 1%, but it does not
  rescue the failed offer/proof rate. P99 cadence superficially improves with
  the smaller blocks (381.608 / 417.564 / 500.066 ms total/wall/accepted),
  while collate-start still reaches a 1.152-s maximum and external wait rises
  362.496->393.420 seconds; first-work worsens 86.040->108.800 ms/call.
- Reject and do not retune/retry the batch-128/CWND-1536 regime. Restore the
  Cycle 44 96-message / 1,152-CWND / 0.0768-s geometry for all subsequent
  source work. Do not compensate by lengthening coalescing, widening
  connections, raising qcap, or raising target: those would mask the causal
  result and recreate known backlog pressure. The next experiment should be a
  source-side scheduler/ingress optimization on the valid C44 profile.
- Artifact directory: `benchmark-results/20260901T204717Z`.

## Cycle 46 — rejected whole-set excluded-prefix source A/B at 15k (20260901T214547Z)

- This is a strict source-only A/B against Cycle 44. Runtime `.env` SHA-256,
  Compose/service hashes, normalized sorted genesis/generator environments,
  CPU/memory pinning, 4,096 sources, 12 connections, six workers/signers,
  96-message batches, 16-message source runs, qcap=1, 1,152 CWND, 0.0768-s
  RTT, 30-ms coalescing, 8,192 candidate cap, 2,048 transport window,
  no-gossip control, and 60/60/700/300 timing are unchanged. C46's OCI source
  label is `6959f4bf` (`1edac92d` production excluded-prefix shortcut plus
  test-only coverage); Cycle 44's is `7d5f775a`.
- All formal operational gates pass: correctness, completion, ingress and
  chain capacity, cleanup, catch-up, and drain. The proof contains no
  hash/nonce/duplicate/external conflicts, follower errors, reorgs, or queue
  leaks; final native transport/pending/reconciliation state is zero.
  `reproducible=false` remains solely the known unlabeled Session Stats image
  caveat. The treatment is rejected for performance/cadence, not correctness.
- The shortcut is demonstrably active, not a no-op: 929 index builds validate
  13,028,622 entries into 972,698 ranges and skip 13,026,581 messages
  (99.9843% coverage of successful indexes). However, 1,868 attempts fall
  back conservatively and the successful builds materialize about 14,024
  entries and 1,047 ranges each. The whole-set validation/sort/range work is
  therefore large relative to a 2,048-message prefill.
- C44->C46 proof TPS falls 14,748.848->14,347.000 (-401.848, -2.725%) and
  offered TPS falls 14,837.160->14,454.217 (-2.581%), although 96.3614%
  target attainment still passes. Block rate falls 3.2686->3.2414 blocks/s,
  packing 4,505.876->4,419.812 (-1.91%), and the 25,088 one-second canonical
  bucket is only a transient burst. Canonical backpressure rises 0->0.578593
  seconds (11 events), backlog rises 107,814->128,070, and drain extends
  5.665->6.844 seconds.
- The causal timing signal matches the regression: native first-work rises
  198.237 seconds/2,304 calls =86.040 ms/call to
  220.728/2,303 =95.844 ms/call (+9.804 ms, +11.39%). Native probe, fragment
  refill, and post-commit-idle waits also rise. While p99 total/wall/accepted
  interval remains sub-second at 517.283/563.959/662.595 ms, maxima regress:
  accepted interval 1,319.743 ms, collate start 1,662.697 ms, and validation
  343.907 ms versus Cycle 44's 891.712/892.262/265.014 ms.
- Reject and revert the whole-exclusion materialization path; do not raise
  target or retry 16k on this source. Restore the Cycle 44 source/runtime
  baseline. A successor must avoid validating/sorting every exclusion for a
  small prefill: it should either resolve source/nonce data upstream with
  candidate exclusions or lazily index only source/nonces actually reached at
  the prefill frontier. It must first match <=86-ms first-work, zero/low
  backpressure, and C44's worst-case cadence before claiming a TPS gain.
- Artifact directory: `benchmark-results/20260901T214547Z`.

## Cycle 47 — rejected callback-local excluded-membership cache at 15k (20260901T224322Z)

- This is a strict source-only A/B against Cycle 44. The `.env` SHA-256,
  Compose/service hashes, sorted genesis and native-generator environments,
  CPU/memory pinning, 4,096 sources, 12 connections, six workers/signers,
  96-message batches, 16-message source runs, qcap=1, 1,152 CWND, 0.0768-s
  RTT, 30-ms coalescing, 8,192 candidate cap, 2,048 transport window,
  no-gossip control, and 60/60/700/300 timing are unchanged. Cycle 47's OCI
  source label is `960e606d`; Cycle 44's is `7d5f775a`. The harness revision
  advances only because prior cycle reports were recorded.
- Runner and generator both exit zero. All proof correctness, completion,
  ingress-capacity, chain-capacity, validator-cleanup, catch-up, drain, and
  broadcast-control lifecycle gates pass, with zero proof hash/nonce/duplicate
  or external conflicts, follower errors, reorgs, retry exhaustion, or final
  native queue leaks. `reproducible=false` remains solely the known unlabeled
  Session Stats image caveat; it is not a source-result failure.
- The membership-cache treatment is exercised, not a no-op: scheduler telemetry
  reports 2,742 exclusion-membership builds containing 58,368,910 entries
  (21,286.984 entries/build), 87,744 slow hits, 11 below-threshold cases, and
  zero over-limit cases. It avoids Cycle 46's source/nonce range materialization
  and does recover relative to that rejected treatment, but still materializes
  a large whole-hash set for callback work.
- Against the valid Cycle 44 control, offered/admitted TPS falls
  14,837.160 -> 14,774.011 (-63.149, -0.426%) and proof TPS falls
  14,748.848 -> 14,676.293 (-72.555, -0.492%). The measured chain keeps the
  same 2,288 blocks over 700 seconds (3.2686 blocks/s), but packing falls
  4,505.876 -> 4,483.710 transfers/block (maximum remains 8,192). Thus the
  apparent same block rate does not establish a throughput win.
- Canonical backpressure regresses from zero to 1.225296 seconds across 24
  events (0.1750% of the measurement window). Sampled backlog peak rises
  107,814 -> 127,441 and measurement-end backlog 80,091 -> 80,194, although
  drain improves slightly from 5.665 -> 5.381 seconds and fully completes.
- Total/wall/accepted/start/validated p99 cadence is
  524.313/573.776/679.165/756.509/111.166 ms, versus Cycle 44's
  525.791/568.039/676.195/747.184/101.538 ms. Every p99 remains sub-second,
  but wall, accepted, start, and validation p99 regress. Total/wall maxima
  improve to 680.109/721.924 ms, while accepted/start/validated maxima are
  988.334/1,040.899/268.624 ms versus Cycle 44's
  891.712/892.262/265.014 ms: the collate-start maximum crosses one second,
  so the control's worst-case subsecond cadence is not retained.
- The causal timing signal also regresses: native first-work rises from
  198.237 seconds / 2,304 calls = 86.040 ms/call to
  211.696 seconds / 2,297 calls = 92.162 ms/call (+6.122 ms, +7.115%). The
  large per-callback membership builds above are inconsistent with the required
  first-work gate, despite being less costly than Cycle 46's 95.844 ms/call
  full-index result.
- Reject the callback-local membership-cache path and revert `960e606d`; do
  not tune its threshold or retry it at a higher target. Restore the Cycle 44
  tree. A successor must avoid whole-callback exclusion materialization,
  preferably by carrying validated source/nonce exclusion metadata upstream or
  by constructing an exact representation only at the reached prefill frontier.
  It must first beat Cycle 44 proof TPS while preserving <=86-ms first-work,
  zero/low backpressure, and subsecond worst-case cadence.
- Artifact directory: `benchmark-results/20260901T224322Z`.

## Cycle 48 — valid direct native-reservation-link source A/B at 15k (20260901T234107Z)

- This is a strict source-only A/B against the valid Cycle 44 control. Runtime
  `.env` SHA-256, Compose/service hashes, sorted genesis and native-generator
  environments, CPU/memory pinning, 4,096 sources, 12 connections, six
  workers/signers, 96-message batches, 16-message source runs, qcap=1,
  1,152 CWND, 0.0768-s RTT, 30-ms coalescing, 8,192 candidate cap, 2,048
  transport window, no-gossip control, and 60/60/700/300 timing are unchanged.
  The only performance-relevant difference is the validator/generator OCI
  source label `7d5f775a` -> `6838a2b2`, which adds a validated direct
  reservation-to-mempool-message link with the legacy indexed lookup retained
  as a guarded fallback.
- All formal gates pass: proof correctness, run completion, ingress capacity,
  chain capacity, validator cleanup, catch-up, drain, and broadcast lifecycle.
  The run exits cleanly and proof-checks 11,849,882 canonical hashes with zero
  hash/nonce/duplicate/external conflicts, follower errors, reorgs, retry
  exhaustion, drain timeout, or final native queue residue. `reproducible=false`
  remains solely the known unlabeled Session Stats image caveat.
- C44 -> C48 offered/admitted TPS rises 14,837.160 -> 14,999.956 (+1.097%) and
  proof TPS rises 14,748.848 -> 14,990.382 (+241.534, +1.638%). There is zero
  canonical backpressure in both runs. Measured packing rises
  4,505.876 -> 4,961.305 transfers/block (same 8,192 maximum), while the
  verified rate remains 2,112/700 = 3.0171 native blocks/s. The 26,624-TPS
  one-second bucket is a transient peak, not sustained capacity.
- Queueing and catch-up improve materially: sampled backlog peak/end falls
  107,814/80,091 -> 59,479/11,438 and drain falls 5.665 -> 1.261 seconds.
  Transport remains bounded at high-water 2,560 with maximum producer/consumer
  batches 2,048/512 and zero final reserved, pending, or live messages.
- The causal fast-path evidence is decisive: scheduler telemetry records
  49,936,299 direct-link hits and zero fallbacks. Native first-work falls
  198.237 seconds / 2,304 calls = 86.040 ms/call to
  130.602 / 2,138 = 61.086 ms/call (-29.0%); native probe wait also falls
  17.806 -> 13.616 seconds. This removes repeated hash/priority/treap lookup
  work without changing reservation, membership, nonce, expiry, or exclusion
  checks.
- P99 cadence remains sub-second, though slightly slower than C44:
  total/wall/accepted/start/validated is
  543.085/593.505/687.726/773.297/133.583 ms versus
  525.791/568.039/676.195/747.184/101.538 ms. Total and wall maxima improve
  to 672.283/717.290 ms, but rare accepted-block and collate-start maxima
  regress from C44's 891.712/892.262 ms to 2,152.742/1,512.030 ms. There are
  no skip votes or correctness symptoms, but this means the run satisfies the
  sub-second p99 and >=3-block/s policy, not a strict every-interval-subsecond
  policy.
- Promote `6838a2b2` as the new 15k TPS baseline, but do not raise target yet.
  First run an unchanged Cycle 49 confirmation to determine whether the rare
  start/accepted cadence tails are repeatable. Retain the direct-link path only
  if the repeat keeps all proof/cleanup gates green and clarifies the tail;
  do not tune previously rejected callback-local exclusion caches or widen the
  injector geometry as a response to this result.
- Artifact directory: `benchmark-results/20260901T234107Z`.

## Cycle 49 — valid direct-link repeat at 15k; cadence-rate limit confirmed (20260902T000652Z)

- This is a strict repeat of Cycle 48: the TON/generator OCI source label is
  `6838a2b2`, both source trees are clean, and runtime `.env` SHA-256,
  Compose/service hashes, sorted container environments, CPU/memory pinning,
  broadcast control, and the complete 15k workload geometry are identical.
  The Docker revision changes only because Cycle 48's report was recorded.
- All formal proof correctness, completion, ingress-capacity, chain-capacity,
  cleanup, catch-up, drain, and broadcast lifecycle gates pass. The run exits
  cleanly and matches 11,849,936 canonical hashes with zero conflicts, nonce
  gaps, reorgs, follower errors, retry exhaustion, or final pool/backlog
  residue. The sole `reproducible=false` reason remains the external unlabeled
  Session Stats image.
- The direct-link throughput gain repeats: offered/admitted TPS is
  14,999.943 and proof TPS is 15,001.561, +11.179 TPS (+0.075%) over Cycle 48
  and the new highest valid sustained 15k result. Canonical backpressure is
  zero, sampled backlog peak/end is 35,700/19,145, and drain is 1.321 seconds.
  Direct-link telemetry remains exact: 48,099,262 hits, zero fallbacks, and
  first-work improves slightly to 122.947 seconds / 2,044 calls =
  60.150 ms/call.
- The repeat separates TPS from cadence: measured blocks fall
  2,112 -> 2,002, or 3.0171 -> 2.8600 blocks/s, while packing rises
  4,961.305 -> 5,237.808 transfers/block (+5.57%, same 8,192 maximum).
  This is efficient packing, not a correctness or injector limitation, but it
  does not establish the requested >=3-block/s operating point.
- All basechain p99 timing remains sub-second: total/wall/accepted/start/
  validated is 555.189/600.992/682.911/803.713/109.022 ms. Actual collation
  maxima are 751.056/797.806 ms and the accepted-block maximum recovers below
  one second at 972.503 ms. One collate-start interval is still 1,027.800 ms;
  masterchain timing similarly has a 1,023.394-ms accepted maximum. This
  cross-chain tail is much smaller than Cycle 48's 2.153-s accepted outlier but
  means strict every-interval subsecond cadence is still unproven.
- Retain `6838a2b2` as the repeatable ~15k TPS baseline and do not raise target
  or widen the injector. The next isolated work must trade a small amount of
  post-commit packing grace for a reproducible >=3-block/s cadence, while
  retaining direct links and the existing proof/cleanup/p99 gates. It should
  measure both absolute start/accepted maxima and sustained blocks/s rather
  than treating a transient one-second TPS bucket as capacity.
- Artifact directory: `benchmark-results/20260902T000652Z`.

## Cycle 50 — rejected 5-ms post-commit packing grace at 15k (20260902T003541Z)

- This is a strict C49 source-only A/B. Runtime `.env` SHA-256, Compose/service
  hashes, CPU pinning, all genesis/generator benchmark environments, and the
  complete 15k workload geometry are identical. The only intended difference
  is validator/generator source `6838a2b2` -> `7c9237cd`, which halves the
  bounded native post-commit packing grace from 10 ms to 5 ms.
- The run is proof-correct, complete, and cleanly drained: 9,956,258 canonical
  hashes match with zero conflicts, nonce gaps, reorgs, follower errors,
  retry exhaustion, timeout, or final queue residue. Correctness, completion,
  cleanup, and broadcast-control gates pass. `reproducible=false` remains only
  the normal unlabeled Session Stats image caveat. It is rejected solely for
  capacity/cadence performance.
- Ingress and chain capacity fail on `canonical_backpressure_above_one_percent`
  and load shortfall. C49 -> C50 offered/admitted TPS falls
  14,999.943 -> 12,294.740 (-18.03%) and proof TPS falls
  15,001.561 -> 12,143.851 (-19.05%). Canonical backpressure rises from zero
  to 135.289 seconds (19.327% of the measured window), sampled backlog reaches
  the 131,072 cap and ends at 121,856, and drain extends 1.321 -> 8.332 seconds.
- The apparent block-rate gain is destructive under-packing: blocks/s rises
  2.860 -> 4.070, but packing collapses 5,237.808 -> 2,979.485 transfers/block
  (-43.12%, same 8,192 maximum). Measured basechain empty collations jump
  0 -> 972 and masterchain empty collations 483 -> 980. Native first-work also
  regresses 60.150 -> 95.998 ms/call. Thus this is not a usable way to obtain
  the requested cadence.
- P99 timing does not rescue the result. Base total/wall/accepted/start p99 is
  355.580/383.974/555.148/805.942 ms, but base accepted/start maxima reach
  1,133.784/1,364.326 ms. Masterchain accepted/start p99 rises to
  903.580/900.855 ms and maxima to 1,142.915/1,212.107 ms. All-run skip votes
  are not a correctness signal here; the capacity collapse is already decisive.
- Revert `7c9237cd` and retain the 10-ms direct-link baseline. Do not retune
  this grace further. The next cadence A/B should instead isolate the observed
  masterchain session timeout race by changing only
  `SIMPLEX_FIRST_BLOCK_TIMEOUT_MS` from 400 to 500 in fresh genesis, preserving
  the 10-ms packing grace, direct links, and C49 workload.
- Artifact directory: `benchmark-results/20260902T003541Z`.

## Cycle 51 — valid 500-ms Simplex first-block-timeout cadence A/B (20260902T010108Z)

- This is a strict fresh-genesis configuration A/B against Cycle 49. The
  direct-link source is content-identical (`6838a2b2` and the revert
  `85791a42` share Git tree `e6a080…`), both trees are clean, and resolved
  runtime environments differ only in genesis
  `SIMPLEX_FIRST_BLOCK_TIMEOUT_MS=400 -> 500`. The 300-ms target rate and all
  workload, injector, packing, resource, and broadcast controls are unchanged.
- All formal correctness, completion, ingress-capacity, chain-capacity,
  validator-cleanup, catch-up, drain, and broadcast lifecycle gates pass. The
  run exits cleanly and proof-matches 11,849,885 hashes with zero conflicts,
  nonce gaps, reorgs, follower errors, retry exhaustion, timeout, or final
  native residue. `reproducible=false` remains only the external unlabeled
  Session Stats image caveat.
- Throughput remains effectively flat and backpressure-free: offered/admitted
  is 14,999.999 TPS and proof is 14,995.286 TPS versus C49's 15,001.561
  (-0.042%). Backpressure is zero; sampled peak/end backlog is 62,003/17,889
  and drain is 1.465 seconds. Packing shifts 5,237.808 -> 5,007.981 and
  measured block rate improves 2.860 -> 2,093/700 = 2.990 blocks/s, seven
  blocks short of a strict 3.000 requirement.
- This is the first measured artifact in the campaign with every relevant
  basechain and masterchain maximum below one second. Base total/wall/accepted/
  start maxima are 686.670/730.628/947.607/944.360 ms; masterchain
  wall/accepted/start maxima are 295.684/921.565/966.883 ms. All p99s remain
  sub-second. This removes C49's 1,027.800-ms base-start and 1,023.394-ms
  masterchain-accepted tails without sacrificing normal 15k throughput.
- The causal interpretation is bounded: the additional 100 ms lets locally
  progressing masterchain candidate persistence/notarization avoid racing the
  first-slot alarm. Measured skip votes remain zero, as in C49, and unmapped
  events remain zero. C51 has 18 measured empty base collations (versus C49's
  zero), far below the destructive 972 in the rejected 5-ms packing test.
  All-run basechain start/collation maximum improves 3.844 -> 1.416 seconds,
  but only the measured-window all-chain maxima are promoted by this result.
- Promote the 500-ms timeout as the current cadence-safe 15k control. Do not
  raise target yet: repeat it once unchanged to establish both the subsecond
  absolute maxima and the near-3-block/s rate. If that repeat passes, retain
  500 ms and then explore a small, non-destructive cadence policy or a higher
  target separately; if it fails, revert the timeout config before changing
  candidate persistence.
- Artifact directory: `benchmark-results/20260902T010108Z`.
