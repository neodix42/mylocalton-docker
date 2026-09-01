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
