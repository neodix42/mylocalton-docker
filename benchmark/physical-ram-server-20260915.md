# Physical RAM server observation — 2026-09-15

The generator reported **56,711.80 canonical transfers per second** and a
completed, proof-consistent run. The enclosing RAM benchmark command then timed
out, leaving its reporting and final acceptance incomplete. This is an achieved
throughput observation, not a validated maximum-capacity result.

Source: the user-pasted console from `testnet-val-01-new` and its
`native-load-v2` final record. The full raw server artifacts have not been
retrieved or independently checked. The exported evidence directory shown in
the console is `benchmark-results/ram-tps-retry-3`; the wrapper log is
`20260915T044237Z-43e017d4-benchmark.log`.

## Timing

All times below are UTC on 2026-09-15. The wrapper start is inferred from its
timestamped log name; generator window timestamps are taken directly from the
final record.

| Event | Time | Elapsed since wrapper start |
|---|---|---:|
| Wrapper starts | 04:42:37 | 0 s |
| Generator load starts | 05:01:45.277921 | 1,148.278 s |
| Measurement starts | 05:02:45.277921 | 1,208.278 s |
| Measurement ends | 05:12:45.277921 | 1,808.278 s |
| Generator logs clean stop | 05:12:49.819199 | 1,812.819 s |
| Wrapper's 2,040-second deadline | approximately 05:16:37 | 2,040 s |

The generator reported `elapsed_s=664.54062798665836`, comprising 60 seconds
of warmup, 600 seconds of measurement and approximately 4.54 seconds of drain.
The wrapper's deadline came approximately **227 seconds after the clean
generator stop**. Its later `Terminated` message does not establish that the
load measurement was interrupted: the supplied final record explicitly reports
`interrupted=false` and `drain_timed_out=false`.

The approximately 19 minutes before load cannot be attributed to a particular
operation from this excerpt. Generator entrypoint setup includes wallet-manifest
validation and a separate fixed-lane readiness wait before starting the binary;
the binary also performs initialization before recording `load_start`.
The excerpt likewise does not identify the operation still running after the
generator's final record.

## Reported throughput and correctness

| Metric | Reported value |
|---|---:|
| Canonical transfers in complete measurement seconds | 33,970,368 |
| Complete block-timestamp measurement seconds | 599 |
| Canonical average TPS | 56,711.799666110186 |
| Maximum one-second canonical TPS | 85,104 |
| Measured offered transfers | 34,052,688 |
| Offering-window seconds | 600 |
| Measured offered average TPS | 56,754.48 |
| All-run offered / admitted / canonical hash-matched transfers | 38,312,144 each |
| Measured-offer transfers observed after drain | 34,052,688 |
| Backlog after drain | 0 |

Canonical TPS uses only the fully contained integer `gen_utime` seconds:
`1789448566 <= gen_utime < 1789449165`, or 05:02:46 through 05:12:45 exclusive.
This explains the 599-second denominator despite a 600-second offering window.
Counts and TPS describe logical transfers; signed-run messages carried 16
logical transfers each.

The final record reports `benchmark_result_valid`, `chain_correctness_valid`,
`ingress_capacity_valid`, final canonical catch-up and lane balance as true.
All eight lanes were active; their measured transfer counts ranged from
4,244,560 to 4,247,280. No correctness or run-incomplete reasons were reported.
These are generator-reported checks, not a substitute for the unfinished
wrapper's final evidence and acceptance checks.

`chain_capacity_valid=false`, with the sole reason
`insufficient_load_over_canonical_throughput`. This bounded, unpaced run used
`target_tps=0`; its offered/canonical throughput ratio was
`1.0007525829570054`, below the 1.05 overdrive required to establish capacity.
The record therefore supports approximately 56.7k achieved TPS, but does not
show that the chain reached its maximum throughput.

## Reported retries

| Retry classification | Count |
|---|---:|
| Snapshot revision / not-ready response | 782,107 |
| Admission timeout | 171 |
| Explicit canonical-state lag | 1 |
| Total | 782,279 |

There were no exhausted retries, signing errors, transport errors, canonical
hash conflicts or fatal canonical-follower errors. The retry counts alone do
not establish the source of the throughput limit.

## Interpretation limits

The RAM wrapper's timeout budget in the reported version was
`warmup + duration + drain + 1200`, totaling 2,040 seconds for this profile.
It did not separately budget the profile's 1,800-second lane-readiness
allowance or distinguish setup, active load and report finalization. This
budget mismatch is confirmed in the launcher source; it does not by itself
explain the operation pending after the generator stopped.

No matched disk-backed control, independently retrieved RAM-storage proof or
completed wrapper acceptance is available with this pasted excerpt. No RAM
speedup, regression against the historical 61k result, or comparison between
validator builds is inferred from this observation.
