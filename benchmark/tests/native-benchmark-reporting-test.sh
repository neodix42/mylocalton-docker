#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
jq_dir=$script_dir/../jq
wrapper=$script_dir/../../run-native-benchmark.sh

"$script_dir/native-transfer-runs-config-test.sh"
"$script_dir/native-payment-lanes-config-test.sh"
"$script_dir/native-payment-lanes-helper-test.sh"
bash "$script_dir/native-payment-lane-wallets-test.sh"

command -v jq >/dev/null 2>&1 || {
  echo "required command is not installed: jq" >&2
  exit 2
}

# Exercise the collector's container-state policy without Docker. Startup and
# transient states must wait, running samples, and only explicit terminal
# states stop collection.
"$wrapper" --self-test-actor-stats-container-state
"$wrapper" --self-test-actor-stats-sleep
"$wrapper" --self-test-ext-messages-broadcast
"$wrapper" --self-test-native-payment-lanes-manifest

jq -n -e -L "$jq_dir" '
  include "native-benchmark-lib";
  def external_wait_stats($multiplier; $calls):
    "external_wait_round_live_s=\(0.1 * $multiplier) " +
    "external_wait_round_live_calls=\($calls) " +
    "external_wait_round_native_coalescing_s=\(0.2 * $multiplier) " +
    "external_wait_round_native_coalescing_calls=\($calls) " +
    "external_wait_generic_try_pop_s=\(0.1 * $multiplier) " +
    "external_wait_generic_try_pop_calls=\($calls) " +
    "external_wait_generic_sync_snapshot_s=\(0.1 * $multiplier) " +
    "external_wait_generic_sync_snapshot_calls=\($calls) " +
    "external_wait_native_probe_s=\(0.1 * $multiplier) " +
    "external_wait_native_probe_calls=\($calls) " +
    "external_wait_native_first_work_s=\(0.1 * $multiplier) " +
    "external_wait_native_first_work_calls=\($calls) " +
    "external_wait_native_fragment_refill_s=\(0.1 * $multiplier) " +
    "external_wait_native_fragment_refill_calls=\($calls) " +
    "external_wait_native_post_commit_idle_s=\(0.05 * $multiplier) " +
    "external_wait_native_post_commit_idle_calls=\($calls) " +
    "external_wait_native_producer_drain_s=\(0.05 * $multiplier) " +
    "external_wait_native_producer_drain_calls=\($calls) " +
    "external_wait_native_sync_snapshot_s=\(0.1 * $multiplier) " +
    "external_wait_native_sync_snapshot_calls=\($calls) " +
    "external_wait_accounted_s=\($multiplier) external_wait_calls=\(10 * $calls)";
  def external_wait_single_category($seconds; $accounted):
    "external_wait_round_live_s=\($seconds) external_wait_round_live_calls=1 " +
    "external_wait_round_native_coalescing_s=0 external_wait_round_native_coalescing_calls=0 " +
    "external_wait_generic_try_pop_s=0 external_wait_generic_try_pop_calls=0 " +
    "external_wait_generic_sync_snapshot_s=0 external_wait_generic_sync_snapshot_calls=0 " +
    "external_wait_native_probe_s=0 external_wait_native_probe_calls=0 " +
    "external_wait_native_first_work_s=0 external_wait_native_first_work_calls=0 " +
    "external_wait_native_fragment_refill_s=0 external_wait_native_fragment_refill_calls=0 " +
    "external_wait_native_post_commit_idle_s=0 external_wait_native_post_commit_idle_calls=0 " +
    "external_wait_native_producer_drain_s=0 external_wait_native_producer_drain_calls=0 " +
    "external_wait_native_sync_snapshot_s=0 external_wait_native_sync_snapshot_calls=0 " +
    "external_wait_accounted_s=\($accounted) external_wait_calls=1";
  def native_deferral_stats($factor; $overrides; $drop_fields):
    ({
      native_deferral_intake_deadline_idle_entries:$factor,
      native_deferral_intake_deadline_fragment_entries:$factor,
      native_deferral_checkpoint_deadline_rollback_entries:$factor,
      native_deferral_checkpoint_hard_preflight_entries:$factor,
      native_deferral_checkpoint_size_preflight_entries:$factor,
      native_deferral_medium_timeout_entries:$factor,
      native_deferral_candidate_headroom_entries:$factor,
      native_deferral_candidate_size_guard_entries:$factor,
      native_deferral_protocol_account_capacity_entries:$factor,
      native_deferral_account_unavailable_entries:$factor,
      native_deferral_account_balance_unrepresentable_entries:$factor,
      native_deferral_state_invalid_fields_entries:$factor,
      native_deferral_state_invalid_signature_entries:$factor,
      native_deferral_state_nonce_mismatch_entries:$factor,
      native_deferral_state_nonce_overflow_entries:$factor,
      native_deferral_state_invalid_source_entries:$factor,
      native_deferral_state_invalid_destination_entries:$factor,
      native_deferral_state_insufficient_balance_entries:$factor,
      native_deferral_state_balance_overflow_entries:$factor,
      native_microbatch_delayed:(19 * $factor),
      native_checkpoint_rollback_entries:(3 * $factor),
      native_deadline_deferred:(2 * $factor),
      native_prebatch_protocol_capacity_requeue_works:$factor,
      native_prebatch_protocol_capacity_requeue_entries:(10 * $factor),
      native_prebatch_carryover_requeue_works:(2 * $factor),
      native_prebatch_carryover_requeue_entries:(20 * $factor),
      native_prebatch_scalar_decode_retry_works:(3 * $factor)
    } + $overrides) as $counters |
    (reduce $drop_fields[] as $field ($counters; del(.[$field]))) |
    to_entries |
    map("\(.key)=\(.value)") |
    join(" ");

  (field_or_null({present:false}; "present") == false) and
  (field_or_null({}; "missing") == null) and
  (["12.5", true, false, "invalid"] | map(stat_counter_value) ==
    [12.5, 1, 0, null]) and
  ([100, 130, 0, 7, 11] | monotonic_counter_delta == 41) and

  (native_checkpoint_coalescing_summary([
    {work_time_real_stats:(
      "native_checkpoint_groups=1 native_checkpoint_group_entries=1024 " +
      "native_checkpoint_group_fragments=2 native_checkpoint_group_max_entries=1024 " +
      "native_checkpoint_group_max_fragments=2 native_checkpoint_flush_capacity=1 " +
      "native_checkpoint_flush_ingress=0 native_checkpoint_flush_deadline=0 " +
      "native_checkpoint_flush_fanout=0 native_checkpoint_flush_headroom=0 " +
      "native_checkpoint_flush_latency=0 native_checkpoint_refill_continuations=2 " +
      "native_checkpoint_refill_expirations=1 native_checkpoint_ingress_retentions=3 " +
      "native_checkpoint_ingress_retention_max_dirty_accounts=900 native_checkpoint_rollbacks=0 " +
      "native_checkpoint_rollback_entries=0"
    )},
    {work_time_real_stats:(
      "native_checkpoint_groups=2 native_checkpoint_group_entries=1536 " +
      "native_checkpoint_group_fragments=3 native_checkpoint_group_max_entries=1536 " +
      "native_checkpoint_group_max_fragments=3 native_checkpoint_flush_capacity=0 " +
      "native_checkpoint_flush_ingress=1 native_checkpoint_flush_deadline=1 " +
      "native_checkpoint_flush_fanout=2 native_checkpoint_flush_headroom=1 " +
      "native_checkpoint_flush_latency=1 native_checkpoint_refill_continuations=4 " +
      "native_checkpoint_refill_expirations=2 native_checkpoint_ingress_retentions=5 " +
      "native_checkpoint_ingress_retention_max_dirty_accounts=1400 native_checkpoint_rollbacks=1 " +
      "native_checkpoint_rollback_entries=512"
    )}
  ])) as $checkpoint |
  ($checkpoint.capture_complete == true) and
  ($checkpoint.records_total == 2) and
  ($checkpoint.records_with_telemetry == 2) and
  ($checkpoint.native_checkpoint_groups == 3) and
  ($checkpoint.native_checkpoint_group_entries == 2560) and
  ($checkpoint.native_checkpoint_group_fragments == 5) and
  ($checkpoint.native_checkpoint_group_max_entries == 1536) and
  ($checkpoint.native_checkpoint_group_max_fragments == 3) and
  (($checkpoint.native_checkpoint_average_entries_per_group - (2560 / 3) | fabs) < 1e-12) and
  (($checkpoint.native_checkpoint_average_fragments_per_group - (5 / 3) | fabs) < 1e-12) and
  ($checkpoint.native_checkpoint_flush_capacity == 1) and
  ($checkpoint.native_checkpoint_flush_ingress == 1) and
  ($checkpoint.native_checkpoint_flush_deadline == 1) and
  ($checkpoint.native_checkpoint_flush_fanout == 2) and
  ($checkpoint.native_checkpoint_flush_headroom == 1) and
  ($checkpoint.native_checkpoint_flush_latency == 1) and
  ($checkpoint.native_checkpoint_refill_continuations == 6) and
  ($checkpoint.native_checkpoint_refill_expirations == 3) and
  ($checkpoint.native_checkpoint_ingress_retentions == 8) and
  ($checkpoint.native_checkpoint_ingress_retention_max_dirty_accounts == 1400) and
  ($checkpoint.native_checkpoint_rollbacks == 1) and
  ($checkpoint.native_checkpoint_rollback_entries == 512) and

  # Historic or mixed result bundles must not turn missing coalescing
  # telemetry into a superficially valid all-zero experiment.
  (native_checkpoint_coalescing_summary([
    {work_time_real_stats:"native_checkpoint_groups=1"}
  ])) as $partial_checkpoint |
  ($partial_checkpoint.capture_complete == false) and
  ($partial_checkpoint.records_with_telemetry == 1) and
  ($partial_checkpoint.native_checkpoint_groups == null) and
  ($partial_checkpoint.native_checkpoint_group_entries == null) and
  ($partial_checkpoint.native_checkpoint_refill_continuations == null) and
  ($partial_checkpoint.native_checkpoint_refill_expirations == null) and
  ($partial_checkpoint.native_checkpoint_ingress_retentions == null) and
  ($partial_checkpoint.native_checkpoint_ingress_retention_max_dirty_accounts == null) and

  # Deferral attribution is additive across candidates, while all three
  # entry-domain equations reconcile independently. Prebatch work and entry
  # units remain visible in their separate domain.
  (native_collator_deferral_summary([
    {work_time_real_stats:native_deferral_stats(1; {}; [])},
    {work_time_real_stats:native_deferral_stats(2; {}; [])}
  ])) as $deferrals |
  ($deferrals.capture_complete == true) and
  ($deferrals.records_total == 2) and
  ($deferrals.records_with_telemetry == 2) and
  ($deferrals.native_microbatch_delayed == 57) and
  ($deferrals.reason_entries_sum == 57) and
  ($deferrals.delayed_accounting_error == 0) and
  ($deferrals.native_checkpoint_rollback_entries == 9) and
  ($deferrals.checkpoint_reason_entries_sum == 9) and
  ($deferrals.checkpoint_accounting_error == 0) and
  ($deferrals.native_deadline_deferred == 6) and
  ($deferrals.deadline_reason_entries_sum == 6) and
  ($deferrals.deadline_accounting_error == 0) and
  ($deferrals.totals_reconcile == true) and
  ($deferrals.native_deferral_intake_deadline_idle_entries == 3) and
  ($deferrals.native_deferral_state_balance_overflow_entries == 3) and
  ($deferrals.prebatch.capture_complete == true) and
  ($deferrals.prebatch.records_with_telemetry == 2) and
  ($deferrals.prebatch.native_prebatch_protocol_capacity_requeue_works == 3) and
  ($deferrals.prebatch.native_prebatch_protocol_capacity_requeue_entries == 30) and
  ($deferrals.prebatch.native_prebatch_carryover_requeue_works == 6) and
  ($deferrals.prebatch.native_prebatch_carryover_requeue_entries == 60) and
  ($deferrals.prebatch.native_prebatch_scalar_decode_retry_works == 9) and

  # The total and each documented subset must fail independently rather than
  # letting one matching equation hide another mismatch.
  (native_collator_deferral_summary([
    {work_time_real_stats:native_deferral_stats(
      1; {native_microbatch_delayed:20}; []
    )}
  ])) as $delayed_mismatch |
  ($delayed_mismatch.capture_complete == true) and
  ($delayed_mismatch.delayed_accounting_error == 1) and
  ($delayed_mismatch.checkpoint_accounting_error == 0) and
  ($delayed_mismatch.deadline_accounting_error == 0) and
  ($delayed_mismatch.totals_reconcile == false) and
  (native_collator_deferral_summary([
    {work_time_real_stats:native_deferral_stats(
      1; {native_checkpoint_rollback_entries:4}; []
    )}
  ])) as $checkpoint_mismatch |
  ($checkpoint_mismatch.delayed_accounting_error == 0) and
  ($checkpoint_mismatch.checkpoint_accounting_error == 1) and
  ($checkpoint_mismatch.deadline_accounting_error == 0) and
  ($checkpoint_mismatch.totals_reconcile == false) and
  (native_collator_deferral_summary([
    {work_time_real_stats:native_deferral_stats(
      1; {native_deadline_deferred:3}; []
    )}
  ])) as $deadline_mismatch |
  ($deadline_mismatch.delayed_accounting_error == 0) and
  ($deadline_mismatch.checkpoint_accounting_error == 0) and
  ($deadline_mismatch.deadline_accounting_error == 1) and
  ($deadline_mismatch.totals_reconcile == false) and

  # A missing field in one row, including a mixed old/new result set, makes
  # every quantitative primary-domain value unavailable. The independent
  # prebatch contract fails closed on its own fields as well.
  (native_collator_deferral_summary([
    {work_time_real_stats:native_deferral_stats(
      1; {}; ["native_deferral_state_balance_overflow_entries"]
    )}
  ])) as $missing_deferral |
  ($missing_deferral.capture_complete == false) and
  ($missing_deferral.records_with_telemetry == 1) and
  ($missing_deferral.native_microbatch_delayed == null) and
  ($missing_deferral.reason_entries_sum == null) and
  ($missing_deferral.delayed_accounting_error == null) and
  ($missing_deferral.checkpoint_reason_entries_sum == null) and
  ($missing_deferral.deadline_reason_entries_sum == null) and
  ($missing_deferral.totals_reconcile == null) and
  ($missing_deferral.native_deferral_intake_deadline_idle_entries == null) and
  ($missing_deferral.native_deferral_state_balance_overflow_entries == null) and
  (native_collator_deferral_summary([
    {work_time_real_stats:native_deferral_stats(1; {}; [])},
    {work_time_real_stats:native_deferral_stats(
      1; {}; ["native_deferral_state_balance_overflow_entries"]
    )}
  ])) as $mixed_deferral |
  ($mixed_deferral.capture_complete == false) and
  ($mixed_deferral.records_total == 2) and
  ($mixed_deferral.records_with_telemetry == 2) and
  ($mixed_deferral.native_microbatch_delayed == null) and
  ($mixed_deferral.totals_reconcile == null) and
  (native_collator_deferral_summary([
    {work_time_real_stats:native_deferral_stats(
      1; {}; ["native_prebatch_scalar_decode_retry_works"]
    )}
  ])) as $missing_prebatch |
  ($missing_prebatch.capture_complete == true) and
  ($missing_prebatch.totals_reconcile == true) and
  ($missing_prebatch.prebatch.capture_complete == false) and
  ($missing_prebatch.prebatch.native_prebatch_protocol_capacity_requeue_works == null) and
  ($missing_prebatch.prebatch.native_prebatch_scalar_decode_retry_works == null) and

  ({
    required:true, valid:true, topology_complete:true, totals_reconcile:true,
    every_lane_active:true, within_tolerance:true,
    depth:2, tolerance_bps:500,
    expected_lanes:4, observed_lanes:4,
    measured_transfers:4000, lane_measured_transfers_sum:4000,
    lanes:[
      {shard:"0:2000000000000000", depth:2, measured_native_transfers:1000},
      {shard:"0:6000000000000000", depth:2, measured_native_transfers:1000},
      {shard:"0:a000000000000000", depth:2, measured_native_transfers:1000},
      {shard:"0:e000000000000000", depth:2, measured_native_transfers:1000}
    ]
  }) as $raw_lane_balance |
  (canonical_lane_balance_telemetry({
    canonical_lane_balance:$raw_lane_balance
  })) as $lane_telemetry |
  ($lane_telemetry.canonical_lane_balance == $raw_lane_balance) and
  ($lane_telemetry.canonical_lanes == $raw_lane_balance.lanes) and
  ((canonical_lane_balance_telemetry({})).canonical_lane_balance == null) and
  ((canonical_lane_balance_telemetry({})).canonical_lanes == null) and
  ([
    ($raw_lane_balance | .lanes[3] = null),
    ($raw_lane_balance | .lanes[3].shard = ""),
    ($raw_lane_balance | .lanes[3].measured_native_transfers = "1000"),
    ($raw_lane_balance | .lanes[3].measured_native_transfers = -1),
    ($raw_lane_balance | .lanes[3].measured_native_transfers = 0.5)
  ] | all(.[]; (canonical_depth2_lane_record_checks(.).records_valid == false))) and

  (capacity_acceptance({
    chain_correctness_valid:false,
    correctness_invalid_reasons:["proof_error"],
    run_incomplete_reasons:[],
    ingress_capacity_valid:false,
    ingress_capacity_invalid_reasons:["offer_target_not_attained"],
    chain_capacity_valid:true,
    chain_capacity_invalid_reasons:[]
  })) as $acceptance |
  ($acceptance.chain_correctness_valid == false) and
  ($acceptance.run_complete == true) and
  ($acceptance.ingress_capacity_valid == false) and
  ($acceptance.chain_capacity_valid == true) and
  ($acceptance.canonical_lane_balance_required == false) and
  ($acceptance.canonical_lane_balance_valid == null) and
  ($acceptance.canonical_lane_balance_invalid_reasons == []) and

  # A depth-2 chain-capacity pass additionally requires a complete, reconciled,
  # active, and balanced four-lane canonical observation.
  (capacity_acceptance({
    native_payment_lane_depth:2,
    chain_correctness_valid:true,
    correctness_invalid_reasons:[],
    run_incomplete_reasons:[],
    ingress_capacity_valid:true,
    ingress_capacity_invalid_reasons:[],
    chain_capacity_valid:true,
    chain_capacity_invalid_reasons:[],
    canonical_lane_balance:{
      required:true, valid:true, topology_complete:true, totals_reconcile:true,
      every_lane_active:true, within_tolerance:true,
      depth:2, tolerance_bps:500,
      expected_lanes:4, observed_lanes:4,
      measured_transfers:4000, lane_measured_transfers_sum:4000,
      lanes:[
        {shard:"0:2000000000000000", depth:2, measured_native_transfers:1000},
        {shard:"0:6000000000000000", depth:2, measured_native_transfers:1000},
        {shard:"0:a000000000000000", depth:2, measured_native_transfers:1000},
        {shard:"0:e000000000000000", depth:2, measured_native_transfers:1000}
      ]
    }
  })) as $balanced_lanes |
  ($balanced_lanes.canonical_lane_balance_required == true) and
  ($balanced_lanes.canonical_lane_balance_valid == true) and
  ($balanced_lanes.canonical_lane_balance_invalid_reasons == []) and
  ($balanced_lanes.chain_capacity_valid == true) and
  ($balanced_lanes.chain_capacity_invalid_reasons == []) and

  # Producer booleans cannot mask self-inconsistent counts, aggregate totals,
  # or a truncated per-lane record array.
  (capacity_acceptance({
    native_payment_lane_depth:2,
    chain_capacity_valid:true,
    chain_capacity_invalid_reasons:[],
    canonical_lane_balance:{
      required:true, valid:true, topology_complete:true, totals_reconcile:true,
      every_lane_active:true, within_tolerance:true,
      depth:2, tolerance_bps:500,
      expected_lanes:2, observed_lanes:3,
      measured_transfers:4000, lane_measured_transfers_sum:3999,
      lanes:[
        {shard:"a", depth:2, measured_native_transfers:1000},
        {shard:"b", depth:2, measured_native_transfers:1000},
        {shard:"c", depth:2, measured_native_transfers:1000},
        {shard:"d", depth:2, measured_native_transfers:1000}
      ]
    }
  })) as $inconsistent_lanes |
  ($inconsistent_lanes.canonical_lane_balance_valid == false) and
  ($inconsistent_lanes.canonical_lane_balance_invalid_reasons == [
    "canonical_lane_balance_expected_lanes_mismatch",
    "canonical_lane_balance_observed_lanes_mismatch",
    "canonical_lane_balance_record_sum_mismatch"
  ]) and
  ($inconsistent_lanes.chain_capacity_valid == false) and
  ($inconsistent_lanes.chain_capacity_invalid_reasons ==
    $inconsistent_lanes.canonical_lane_balance_invalid_reasons) and

  (capacity_acceptance({
    native_payment_lane_depth:2,
    chain_capacity_valid:true,
    chain_capacity_invalid_reasons:[],
    canonical_lane_balance:($raw_lane_balance |
      .lanes[3].shard = .lanes[2].shard)
  })) as $duplicate_lane |
  ($duplicate_lane.canonical_lane_balance_valid == false) and
  ($duplicate_lane.canonical_lane_balance_invalid_reasons == [
    "canonical_lane_balance_duplicate_shard"
  ]) and
  ($duplicate_lane.chain_capacity_valid == false) and

  (capacity_acceptance({
    native_payment_lane_depth:2,
    chain_capacity_valid:true,
    chain_capacity_invalid_reasons:[],
    canonical_lane_balance:($raw_lane_balance |
      .lanes[3].shard = "" |
      .lanes[3].measured_native_transfers = "1000")
  })) as $bad_lane_record |
  ($bad_lane_record.canonical_lane_balance_valid == false) and
  ($bad_lane_record.canonical_lane_balance_invalid_reasons == [
    "canonical_lane_balance_lane_record_invalid"
  ]) and
  ($bad_lane_record.chain_capacity_valid == false) and

  (capacity_acceptance({
    native_payment_lane_depth:2,
    chain_capacity_valid:true,
    chain_capacity_invalid_reasons:[],
    canonical_lane_balance:($raw_lane_balance |
      .lanes[3].measured_native_transfers = 999)
  })) as $record_sum_mismatch |
  ($record_sum_mismatch.canonical_lane_balance_valid == false) and
  ($record_sum_mismatch.canonical_lane_balance_invalid_reasons == [
    "canonical_lane_balance_record_sum_mismatch"
  ]) and
  ($record_sum_mismatch.chain_capacity_valid == false) and

  (capacity_acceptance({
    native_payment_lane_depth:2,
    chain_capacity_valid:true,
    chain_capacity_invalid_reasons:[],
    canonical_lane_balance:($raw_lane_balance |
      .lanes[0].measured_native_transfers = 950 |
      .lanes[3].measured_native_transfers = 1050)
  })) as $share_boundary |
  ($share_boundary.canonical_lane_balance_valid == true) and
  ($share_boundary.chain_capacity_valid == true) and
  (capacity_acceptance({
    native_payment_lane_depth:2,
    chain_capacity_valid:true,
    chain_capacity_invalid_reasons:[],
    canonical_lane_balance:($raw_lane_balance |
      .lanes[0].measured_native_transfers = 949 |
      .lanes[3].measured_native_transfers = 1051)
  })) as $share_outside |
  ($share_outside.canonical_lane_balance_valid == false) and
  ($share_outside.canonical_lane_balance_invalid_reasons == [
    "canonical_lane_balance_record_share_outside_tolerance"
  ]) and
  ($share_outside.chain_capacity_valid == false) and

  (capacity_acceptance({
    native_payment_lane_depth:2,
    chain_capacity_valid:true,
    chain_capacity_invalid_reasons:[],
    canonical_lane_balance:($raw_lane_balance |
      .depth = 1 |
      .tolerance_bps = 501)
  })) as $unpinned_policy |
  ($unpinned_policy.canonical_lane_balance_valid == false) and
  ($unpinned_policy.canonical_lane_balance_invalid_reasons == [
    "canonical_lane_balance_depth_mismatch",
    "canonical_lane_balance_tolerance_mismatch"
  ]) and
  ($unpinned_policy.chain_capacity_valid == false) and

  # One inactive/starved lane is an independent rejection and must turn an
  # otherwise generator-reported chain-capacity pass into a failure.
  (capacity_acceptance({
    native_payment_lane_depth:2,
    chain_capacity_valid:true,
    chain_capacity_invalid_reasons:["reported_capacity_context"],
    canonical_lane_balance:{
      required:true, valid:false, topology_complete:true, totals_reconcile:true,
      every_lane_active:false, within_tolerance:false,
      depth:2, tolerance_bps:500,
      expected_lanes:4, observed_lanes:4,
      measured_transfers:3000, lane_measured_transfers_sum:3000,
      lanes:[
        {shard:"0:2000000000000000", depth:2, measured_native_transfers:1000},
        {shard:"0:6000000000000000", depth:2, measured_native_transfers:1000},
        {shard:"0:a000000000000000", depth:2, measured_native_transfers:1000},
        {shard:"0:e000000000000000", depth:2, measured_native_transfers:0}
      ]
    }
  })) as $starved_lane |
  ($starved_lane.canonical_lane_balance_valid == false) and
  ($starved_lane.canonical_lane_balance_invalid_reasons == [
    "canonical_lane_inactive",
    "canonical_lane_imbalance",
    "canonical_lane_balance_invalid",
    "canonical_lane_balance_inactive_record",
    "canonical_lane_balance_record_share_outside_tolerance"
  ]) and
  ($starved_lane.chain_capacity_valid == false) and
  ($starved_lane.chain_capacity_invalid_reasons == [
    "reported_capacity_context",
    "canonical_lane_inactive",
    "canonical_lane_imbalance",
    "canonical_lane_balance_invalid",
    "canonical_lane_balance_inactive_record",
    "canonical_lane_balance_record_share_outside_tolerance"
  ]) and

  (capacity_acceptance({
    native_payment_lane_depth:2,
    chain_capacity_valid:true,
    chain_capacity_invalid_reasons:[]
  })) as $missing_lane_balance |
  ($missing_lane_balance.canonical_lane_balance_required == true) and
  ($missing_lane_balance.canonical_lane_balance_valid == false) and
  ($missing_lane_balance.canonical_lane_balance_invalid_reasons == [
    "canonical_lane_balance_missing"
  ]) and
  ($missing_lane_balance.chain_capacity_valid == false) and
  ($missing_lane_balance.chain_capacity_invalid_reasons == [
    "canonical_lane_balance_missing"
  ]) and

  # Historic non-lane and two-lane records do not acquire a new retroactive
  # requirement merely because the balance object did not exist yet.
  (capacity_acceptance({
    native_payment_lane_depth:1,
    chain_capacity_valid:true,
    chain_capacity_invalid_reasons:[]
  })) as $legacy_depth_one |
  ($legacy_depth_one.canonical_lane_balance_required == false) and
  ($legacy_depth_one.canonical_lane_balance_valid == null) and
  ($legacy_depth_one.chain_capacity_valid == true) and
  (capacity_acceptance({
    native_payment_lane_depth:0,
    chain_capacity_valid:false,
    chain_capacity_invalid_reasons:["existing_failure"]
  })) as $legacy_depth_zero |
  ($legacy_depth_zero.canonical_lane_balance_required == false) and
  ($legacy_depth_zero.canonical_lane_balance_valid == null) and
  ($legacy_depth_zero.chain_capacity_valid == false) and
  ($legacy_depth_zero.chain_capacity_invalid_reasons == ["existing_failure"]) and

  (capacity_acceptance(null)) as $missing |
  ($missing.run_complete == null) and
  ($missing.run_incomplete_reasons == ["missing_final_generator_record"]) and
  ($missing.canonical_lane_balance_required == null) and
  ($missing.canonical_lane_balance_valid == null) and
  ($missing.canonical_lane_balance_invalid_reasons == [
    "missing_final_generator_record"
  ]) and

  (validator_pool_cleanup_acceptance(
    {pending_sources:0,failures:3}; {accounts:0,messages:0,nonce_watermarks:4096}
  )) as $clean |
  ($clean.valid == true) and
  ($clean.invalid_reasons == []) and

  (validator_pool_cleanup_acceptance(
    {pending_sources:2}; {accounts:1,messages:7,nonce_watermarks:4096}
  )) as $dirty |
  ($dirty.valid == false) and
  ($dirty.invalid_reasons == [
    "canonical_reconciliation_pending_sources",
    "native_pool_pending_messages"
  ]) and

  (validator_pool_cleanup_acceptance({}; {})) as $missing_cleanup |
  ($missing_cleanup.valid == false) and
  ($missing_cleanup.invalid_reasons == [
    "canonical_reconciliation_capture_missing",
    "native_pending_capture_missing"
  ]) and

  (native_transport_summary(
    {
      selected:100, pushed:90, consumed:80, push_completed:90, push_reserved:0,
      pending:10, live_queued:10, live_unpushed:0,
      high_water:512, push_batches:1, push_batch_items:90, max_push_batch:512,
      pop_batches:1, pop_batch_items:80, max_pop_batch:512,
      producer_empty:4, consumer_empty:5
    };
    {
      selected:220, pushed:210, consumed:200, push_completed:210, push_reserved:0,
      pending:10, live_queued:10, live_unpushed:0,
      high_water:2048, push_batches:2, push_batch_items:210, max_push_batch:2048,
      pop_batches:3, pop_batch_items:200, max_pop_batch:512,
      producer_empty:9, consumer_empty:12
    }
  )) as $transport |
  ($transport.capture_complete == true) and
  ($transport.delta.selected == 120) and
  ($transport.delta.pushed == 120) and
  ($transport.delta.consumed == 120) and
  ($transport.delta.push_batch_items == 120) and
  ($transport.delta.pop_batch_items == 120) and
  ($transport.delta.producer_empty == 5) and
  ($transport.delta.consumer_empty == 7) and
  (($transport.delta | has("high_water")) | not) and
  (($transport.delta | has("max_push_batch")) | not) and
  (($transport.delta | has("max_pop_batch")) | not) and
  ($transport.observed_high_water == 2048) and
  ($transport.observed_max_push_batch == 2048) and
  ($transport.observed_max_pop_batch == 512) and

  (native_transport_summary({}; {})) as $missing_transport |
  ($missing_transport.capture_complete == false) and
  ($missing_transport.delta == {}) and
  ($missing_transport.observed_high_water == null) and

  (native_admission_shard_cache_summary(
    {
      shard_state_requests:100, shard_manager_waits:20, shard_fetches:20,
      shard_cache_hits:80, shard_cache_fills:10, shard_cache_fill_races:4,
      shard_cache_fill_conflicts:1, shard_cache_generation_resets:1,
      shard_cache_stale_generation_fill_skips:2, shard_cache_wrong_id:0,
      shard_cache_invalid_header:0, shard_miss_errors:4, shard_fetch_errors:4,
      shard_manager_wait_errors:3, shard_manager_wait_timeouts:1,
      shard_manager_wait_notready:1, shard_manager_wait_other_errors:1,
      shard_manager_wait_late_results:1,
      shard_cache_entries:4, shard_cache_peak_entries:8
    };
    {
      shard_state_requests:200, shard_manager_waits:30, shard_fetches:30,
      shard_cache_hits:170, shard_cache_fills:13, shard_cache_fill_races:6,
      shard_cache_fill_conflicts:2, shard_cache_generation_resets:3,
      shard_cache_stale_generation_fill_skips:3, shard_cache_wrong_id:2,
      shard_cache_invalid_header:3, shard_miss_errors:8, shard_fetch_errors:8,
      shard_manager_wait_errors:6, shard_manager_wait_timeouts:2,
      shard_manager_wait_notready:3, shard_manager_wait_other_errors:1,
      shard_manager_wait_late_results:2,
      shard_cache_entries:6, shard_cache_peak_entries:12
    }
  )) as $cache |
  ($cache.capture_complete == true) and
  ($cache.counter_source == "shard_manager_waits") and
  ($cache.manager_wait_outcomes_capture_complete == true) and
  ($cache.shard_state_requests == 100) and
  ($cache.shard_cache_hits == 90) and
  ($cache.shard_manager_waits == 10) and
  ($cache.shard_fetches == 10) and
  ($cache.hit_ratio == 0.9) and
  ($cache.manager_wait_ratio == 0.1) and
  ($cache.fetch_ratio == 0.1) and
  ($cache.request_accounting_error == 0) and
  ($cache.shard_cache_fills == 3) and
  ($cache.shard_cache_fill_races == 2) and
  ($cache.shard_cache_fill_conflicts == 1) and
  ($cache.shard_cache_generation_resets == 2) and
  ($cache.shard_cache_stale_generation_fill_skips == 1) and
  ($cache.shard_cache_wrong_id == 2) and
  ($cache.shard_cache_invalid_header == 3) and
  ($cache.shard_miss_errors == 4) and
  ($cache.shard_fetch_errors == 4) and
  ($cache.shard_manager_wait_errors == 3) and
  ($cache.shard_manager_wait_timeouts == 1) and
  ($cache.shard_manager_wait_notready == 2) and
  ($cache.shard_manager_wait_other_errors == 0) and
  ($cache.shard_manager_wait_late_results == 1) and
  ($cache.shard_validation_or_store_errors == 1) and
  ($cache.manager_wait_outcome_accounting_error == 0) and
  ($cache.manager_wait_error_accounting_error == 0) and
  ($cache.manager_wait_alias_consistent == true) and
  ($cache.miss_error_alias_consistent == true) and
  ($cache.shard_cache_entries_before == 4) and
  ($cache.shard_cache_entries_after == 6) and
  ($cache.shard_cache_peak_entries == 12) and

  # Cycle 12 predates the canonical manager-wait names, but its complete cache
  # contract used the deprecated aliases for the same logical events.
  (native_admission_shard_cache_summary(
    {
      shard_state_requests:100, shard_fetches:20, shard_cache_hits:80,
      shard_cache_fills:20, shard_cache_fill_races:2,
      shard_cache_fill_conflicts:0, shard_cache_generation_resets:1,
      shard_cache_stale_generation_fill_skips:0, shard_cache_wrong_id:0,
      shard_cache_invalid_header:0, shard_fetch_errors:0,
      shard_cache_entries:4, shard_cache_peak_entries:8
    };
    {
      shard_state_requests:200, shard_fetches:30, shard_cache_hits:170,
      shard_cache_fills:30, shard_cache_fill_races:4,
      shard_cache_fill_conflicts:1, shard_cache_generation_resets:3,
      shard_cache_stale_generation_fill_skips:1, shard_cache_wrong_id:2,
      shard_cache_invalid_header:3, shard_fetch_errors:4,
      shard_cache_entries:6, shard_cache_peak_entries:12
    }
  )) as $cycle12_cache |
  ($cycle12_cache.capture_complete == true) and
  ($cycle12_cache.counter_source == "shard_fetches") and
  ($cycle12_cache.manager_wait_outcomes_capture_complete == false) and
  ($cycle12_cache.shard_manager_waits == 10) and
  ($cycle12_cache.shard_fetches == 10) and
  ($cycle12_cache.shard_miss_errors == 4) and
  ($cycle12_cache.shard_fetch_errors == 4) and
  ($cycle12_cache.manager_wait_outcome_accounting_error == null) and
  ($cycle12_cache.manager_wait_alias_consistent == null) and

  (native_admission_shard_cache_summary(
    {shard_fetches:50}; {shard_fetches:75}
  )) as $legacy_cache |
  ($legacy_cache.capture_complete == false) and
  ($legacy_cache.shard_manager_waits == null) and
  ($legacy_cache.shard_fetches == null) and
  ($legacy_cache.hit_ratio == null) and
  ($legacy_cache.request_accounting_error == null) and

  (collation_external_wait_summary([
    {wait_externals_time:1, work_time_real_stats:external_wait_stats(1; 1)},
    {wait_externals_time:0.5, work_time_real_stats:external_wait_stats(0.5; 2)}
  ])) as $wait |
  ($wait.telemetry_available == true) and
  ($wait.capture_complete == true) and
  ($wait.records_total == 2) and
  ($wait.records_with_telemetry == 2) and
  (($wait.wait_externals_total_s - 1.5 | fabs) < 1e-12) and
  (($wait.reported_accounted_total_s - 1.5 | fabs) < 1e-12) and
  (($wait.category_total_s - 1.5 | fabs) < 1e-12) and
  (($wait.accounting_error_s | fabs) < 1e-12) and
  (($wait.reported_accounting_error_s | fabs) < 1e-12) and
  (($wait.category_vs_reported_accounted_error_s | fabs) < 1e-12) and
  (($wait.accounting_tolerance_envelope_s - 0.0015 | fabs) < 1e-12) and
  (($wait.max_per_record_absolute_accounting_error_s | fabs) < 1e-12) and
  ($wait.accounting_within_tolerance == true) and
  ($wait.external_wait_calls == 30) and
  ($wait.category_calls == 30) and
  ($wait.call_accounting_error == 0) and
  (($wait.categories.round_native_coalescing.seconds - 0.3 | fabs) < 1e-12) and
  ($wait.categories.round_native_coalescing.calls == 3) and

  # Equal and opposite category errors must not cancel into a passing aggregate.
  (collation_external_wait_summary([
    {wait_externals_time:0.01,
     work_time_real_stats:external_wait_single_category(0.01015; 0.01)},
    {wait_externals_time:0.01,
     work_time_real_stats:external_wait_single_category(0.00985; 0.01)}
  ])) as $cancelled_error |
  (($cancelled_error.accounting_error_s | fabs) < 1e-12) and
  (($cancelled_error.category_vs_reported_accounted_error_s | fabs) < 1e-12) and
  (($cancelled_error.accounting_tolerance_envelope_s - 0.0002 | fabs) < 1e-12) and
  (($cancelled_error.max_per_record_absolute_accounting_error_s - 0.00015 | fabs) < 1e-12) and
  ($cancelled_error.accounting_within_tolerance == false) and

  # The reported-accounted comparison is an independent per-record gate.
  (collation_external_wait_summary([
    {wait_externals_time:0.01,
     work_time_real_stats:external_wait_single_category(0.01; 0.01015)}
  ])) as $reported_error |
  (($reported_error.accounting_error_s | fabs) < 1e-12) and
  (($reported_error.reported_accounting_error_s - 0.00015 | fabs) < 1e-12) and
  (($reported_error.category_vs_reported_accounted_error_s + 0.00015 | fabs) < 1e-12) and
  ($reported_error.accounting_within_tolerance == false) and

  (collation_external_wait_summary([
    {wait_externals_time:2.5, work_time_real_stats:"preinit=0.1"}
  ])) as $legacy_wait |
  ($legacy_wait.telemetry_available == false) and
  ($legacy_wait.capture_complete == false) and
  ($legacy_wait.records_total == 1) and
  ($legacy_wait.records_with_telemetry == 0) and
  ($legacy_wait.wait_externals_total_s == null) and
  ($legacy_wait.accounting_error_s == null) and
  ($legacy_wait.accounting_tolerance_envelope_s == null) and
  ($legacy_wait.max_per_record_absolute_accounting_error_s == null) and
  ($legacy_wait.accounting_within_tolerance == null) and
  ($legacy_wait.categories.native_probe.seconds == null)
' >/dev/null

jq -e -L "$jq_dir" -Rs '
  include "native-benchmark-lib";
  validator_actor_stats_overlay_impl as $actor |
  ($actor.actor_type == "ton::overlay::OverlayImpl") and
  ($actor.load_per_second.last_10s == 1.038) and
  ($actor.max_execute_messages.last_10m == 180) and
  ($actor.max_execute_seconds.last_10m == 19.886) and
  ($actor.max_message_seconds.last_10m == 0.2) and
  ($actor.max_delay_seconds.lifetime == 7.75) and
  ($actor.actor_mailbox_quantum_yield_qps.last_10s == 12.5) and
  ($actor.actor_mailbox_quantum_yield_qps.last_10m == 11.5) and
  ($actor.actor_mailbox_quantum_yield_qps.lifetime == 10.5) and
  ($actor.overlay_traffic_fairness_yield_qps.last_10s == 4.5) and
  ($actor.overlay_fec_generated_callback_qps.last_10s == 100.5) and
  ($actor.overlay_fec_generated_callback_qps.last_10m == 90.5) and
  ($actor.overlay_fec_generated_callback_qps.lifetime == 80.5) and
  ($actor.overlay_fec_signed_callback_qps.last_10s == 70.25) and
  ($actor.overlay_fec_signed_callback_qps.last_10m == 60.25) and
  ($actor.overlay_fec_signed_callback_qps.lifetime == 50.25) and
  ($actor.overlay_fec_fairness_yield_qps.last_10s == 7.5) and
  ($actor.overlay_fec_fairness_yield_qps.last_10m == 6.5) and
  ($actor.overlay_fec_fairness_yield_qps.lifetime == 5.5) and
  ($actor.alive == 6) and
  ($actor.executing == 1) and
  ($actor.max_executing_for_seconds == 9.333)
' >/dev/null <<'EOF'
================================= ACTORS STATS =================================
actor_mailbox_quantum_yield.qps	12.5 11.5 10.5
overlay_traffic_fairness_yield.qps	4.5 3.5 2.5
overlay_fec_generated_callback.qps	100.5 90.5 80.5
overlay_fec_signed_callback.qps	70.25 60.25 50.25
overlay_fec_fairness_yield.qps	7.5 6.5 5.5
All actors:
	td::actor::PackageReader
		load_per_second:	12.898 3.100 2.000
	ton::overlay::OverlayImpl
		load_per_second:	1.038 0.400 0.100
		messages_per_second:	1200 800 700
		max_execute_messages:	167 180 223
		max_execute_seconds:	9.333s 19.886s 38.984s
		max_message_seconds:	0.100 0.200 0.300
		max_delay:	0.250s 5.500s 7.750s
		alive: 6 executing: 1 max_executing_for: 9.333s
	ton::validator::Other
		load_per_second:	1 2 3
EOF

# Parse DecryptorAsync independently of neighbouring actor blocks and preserve
# every scheduler statistic needed to distinguish crypto work from Overlay load.
jq -e -L "$jq_dir" -Rs '
  include "native-benchmark-lib";
  validator_actor_stats_actor_types as $actors |
  ($actors.overlay_impl.actor_type == "ton::overlay::OverlayImpl") and
  ($actors.decryptor_async.actor_type == "ton::DecryptorAsync") and
  ($actors.decryptor_async.load_per_second.last_10s == 10.5) and
  ($actors.decryptor_async.messages_per_second.last_10m == 900) and
  ($actors.decryptor_async.max_execute_messages.lifetime == 66) and
  ($actors.decryptor_async.max_execute_seconds.last_10m == 0.25) and
  ($actors.decryptor_async.max_message_seconds.last_10s == 0.01) and
  ($actors.decryptor_async.max_delay_seconds.lifetime == 1.5) and
  ($actors.decryptor_async.alive == 12) and
  ($actors.decryptor_async.executing == 2) and
  ($actors.decryptor_async.max_executing_for_seconds == 0.75)
' >/dev/null <<'EOF'
All actors:
	ton::overlay::OverlayImpl
		load_per_second:	1 1 1
	ton::DecryptorAsync
		load_per_second:	10.5 9.5 8.5
		messages_per_second:	1000 900 800
		max_execute_messages:	64 65 66
		max_execute_seconds:	0.125s 0.250s 0.500s
		max_message_seconds:	0.010s 0.020s 0.030s
		max_delay:	0.500s 1.000s 1.500s
		alive: 12 executing: 2 max_executing_for: 0.750s
	ton::validator::Other
		load_per_second:	999 999 999
EOF

jq -n -e -L "$jq_dir" '
  include "native-benchmark-lib";
  validator_actor_stats_summary(
    [{sequence:1,phase:"measure_end",started_at:"a",finished_at:"b",command_exit_code:0,
      timed_out:false,command_duration_seconds:0.2,
      overlay_impl:{load_per_second:{last_10s:1,last_10m:2,lifetime:3},
        max_execute_messages:{last_10s:10,last_10m:20,lifetime:30},
        max_execute_seconds:{last_10s:4,last_10m:5,lifetime:6},
        max_message_seconds:{last_10s:0.1,last_10m:0.2,lifetime:0.3},
        max_delay_seconds:{last_10s:7,last_10m:8,lifetime:9},
        max_executing_for_seconds:10,alive:2,executing:1,
        actor_mailbox_quantum_yield_qps:{last_10s:17,last_10m:16,lifetime:15},
        overlay_traffic_fairness_yield_qps:{last_10s:4,last_10m:3,lifetime:2},
        overlay_fec_generated_callback_qps:{last_10s:14,last_10m:13,lifetime:12},
        overlay_fec_signed_callback_qps:{last_10s:11,last_10m:10,lifetime:9},
        overlay_fec_fairness_yield_qps:{last_10s:8,last_10m:7,lifetime:6}},
      decryptor_async:{actor_type:"ton::DecryptorAsync",
        load_per_second:{last_10s:21,last_10m:20,lifetime:19},
        messages_per_second:{last_10s:2100,last_10m:2000,lifetime:1900},
        max_execute_messages:{last_10s:61,last_10m:62,lifetime:63},
        max_execute_seconds:{last_10s:0.4,last_10m:0.5,lifetime:0.6},
        max_message_seconds:{last_10s:0.01,last_10m:0.02,lifetime:0.03},
        max_delay_seconds:{last_10s:0.7,last_10m:0.8,lifetime:0.9},
        max_executing_for_seconds:1.25,alive:12,executing:2}}];
    {command_exit_code:0,overlay_impl:null,
      decryptor_async:{actor_type:"ton::DecryptorAsync",alive:3}};
    {command_exit_code:0,overlay_impl:null,
      decryptor_async:{actor_type:"ton::DecryptorAsync",alive:4}};
    {sample_interval_seconds:5,command_timeout_seconds:2,host_guard_seconds:4,
     load_window_seconds:10,pre_load_raw_artifact:"validator-actor-stats-pre-load.txt",
     final_raw_artifact:"validator-actor-stats-final.txt"}
  ) as $summary |
  ($summary.periodic.samples == 1) and
  ($summary.periodic.parsed_decryptor_async_samples == 1) and
  ($summary.periodic.observed_load_window_query_wall_fraction == 0.02) and
  ($summary.perturbation_bound.serialized_no_overlap == true) and
  ($summary.perturbation_bound.configured_max_validator_query_wall_fraction == 0.4) and
  ($summary.overlay_impl.periodic_maxima.max_execute_seconds_10m == 5) and
  ($summary.overlay_impl.periodic_maxima.max_message_seconds_10m == 0.2) and
  ($summary.overlay_impl.periodic_maxima.actor_mailbox_quantum_yield_qps_10s == 17) and
  ($summary.overlay_impl.periodic_maxima.actor_mailbox_quantum_yield_qps_10m == 16) and
  ($summary.overlay_impl.periodic_maxima.actor_mailbox_quantum_yield_qps_lifetime == 15) and
  ($summary.overlay_impl.periodic_maxima.overlay_traffic_fairness_yield_qps_10s == 4) and
  ($summary.overlay_impl.periodic_maxima.overlay_traffic_fairness_yield_qps_lifetime == 2) and
  ($summary.overlay_impl.periodic_maxima.overlay_fec_generated_callback_qps_10s == 14) and
  ($summary.overlay_impl.periodic_maxima.overlay_fec_generated_callback_qps_10m == 13) and
  ($summary.overlay_impl.periodic_maxima.overlay_fec_generated_callback_qps_lifetime == 12) and
  ($summary.overlay_impl.periodic_maxima.overlay_fec_signed_callback_qps_10s == 11) and
  ($summary.overlay_impl.periodic_maxima.overlay_fec_signed_callback_qps_10m == 10) and
  ($summary.overlay_impl.periodic_maxima.overlay_fec_signed_callback_qps_lifetime == 9) and
  ($summary.overlay_impl.periodic_maxima.overlay_fec_fairness_yield_qps_10s == 8) and
  ($summary.overlay_impl.periodic_maxima.overlay_fec_fairness_yield_qps_10m == 7) and
  ($summary.overlay_impl.periodic_maxima.overlay_fec_fairness_yield_qps_lifetime == 6) and
  ($summary.decryptor_async.parsed_periodic_samples == 1) and
  ($summary.decryptor_async.periodic_maxima.load_per_second_10s == 21) and
  ($summary.decryptor_async.periodic_maxima.load_per_second_lifetime == 19) and
  ($summary.decryptor_async.periodic_maxima.messages_per_second_10m == 2000) and
  ($summary.decryptor_async.periodic_maxima.max_execute_messages_lifetime == 63) and
  ($summary.decryptor_async.periodic_maxima.max_execute_seconds_10m == 0.5) and
  ($summary.decryptor_async.periodic_maxima.max_message_seconds_10m == 0.02) and
  ($summary.decryptor_async.periodic_maxima.max_delay_seconds_lifetime == 0.9) and
  ($summary.decryptor_async.periodic_maxima.max_executing_for_seconds == 1.25) and
  ($summary.decryptor_async.periodic_maxima.max_alive == 12) and
  ($summary.decryptor_async.periodic_maxima.max_executing == 2) and
  ($summary.decryptor_async.peak_max_execute_seconds_10m_sample.decryptor_async.actor_type ==
    "ton::DecryptorAsync") and
  ($summary.pre_load_snapshot.raw_artifact == "validator-actor-stats-pre-load.txt") and
  ($summary.pre_load_snapshot.decryptor_async.alive == 3) and
  ($summary.measure_end_snapshot.phase == "measure_end") and
  ($summary.measure_end_snapshot.decryptor_async.max_execute_messages.lifetime == 63) and
  ($summary.final_snapshot.raw_artifact == "validator-actor-stats-final.txt") and
  ($summary.final_snapshot.decryptor_async.alive == 4)
' >/dev/null

# Cycle 7 images predate the FEC counters. Missing global lines must preserve
# the parsed OverlayImpl block while exposing the new fields as null.
jq -e -L "$jq_dir" -Rs '
  include "native-benchmark-lib";
  validator_actor_stats_actor_types as $actors |
  ($actors.overlay_impl.actor_type == "OverlayImpl") and
  ($actors.overlay_impl.actor_mailbox_quantum_yield_qps == null) and
  ($actors.overlay_impl.overlay_traffic_fairness_yield_qps.last_10s == 2) and
  ($actors.overlay_impl.overlay_fec_generated_callback_qps == null) and
  ($actors.overlay_impl.overlay_fec_signed_callback_qps == null) and
  ($actors.overlay_impl.overlay_fec_fairness_yield_qps == null) and
  ($actors.decryptor_async == null)
' >/dev/null <<'EOF'
overlay_traffic_fairness_yield.qps	2 1 0.5
All actors:
	OverlayImpl
		load_per_second:	1 1 1
EOF

jq -n -e -L "$jq_dir" '
  include "native-benchmark-lib";
  validator_actor_stats_summary(
    [{sequence:1,phase:"periodic",started_at:"a",finished_at:"b",
      command_exit_code:0,timed_out:false,command_duration_seconds:0.1,
      overlay_impl:{actor_type:"OverlayImpl",
        overlay_traffic_fairness_yield_qps:{last_10s:2,last_10m:1,lifetime:0.5}}}];
    null;
    null;
    {sample_interval_seconds:30,command_timeout_seconds:2,load_window_seconds:30}
  ) as $legacy |
  ($legacy.overlay_impl.periodic_maxima.actor_mailbox_quantum_yield_qps_10s == null) and
  ($legacy.overlay_impl.periodic_maxima.actor_mailbox_quantum_yield_qps_10m == null) and
  ($legacy.overlay_impl.periodic_maxima.actor_mailbox_quantum_yield_qps_lifetime == null) and
  ($legacy.overlay_impl.periodic_maxima.overlay_traffic_fairness_yield_qps_lifetime == 0.5) and
  ($legacy.overlay_impl.periodic_maxima.overlay_fec_generated_callback_qps_10s == null) and
  ($legacy.overlay_impl.periodic_maxima.overlay_fec_generated_callback_qps_10m == null) and
  ($legacy.overlay_impl.periodic_maxima.overlay_fec_generated_callback_qps_lifetime == null) and
  ($legacy.overlay_impl.periodic_maxima.overlay_fec_signed_callback_qps_10s == null) and
  ($legacy.overlay_impl.periodic_maxima.overlay_fec_signed_callback_qps_10m == null) and
  ($legacy.overlay_impl.periodic_maxima.overlay_fec_signed_callback_qps_lifetime == null) and
  ($legacy.overlay_impl.periodic_maxima.overlay_fec_fairness_yield_qps_10s == null) and
  ($legacy.overlay_impl.periodic_maxima.overlay_fec_fairness_yield_qps_10m == null) and
  ($legacy.overlay_impl.periodic_maxima.overlay_fec_fairness_yield_qps_lifetime == null) and
  ($legacy.periodic.parsed_decryptor_async_samples == 0) and
  ($legacy.decryptor_async.parsed_periodic_samples == 0) and
  ($legacy.decryptor_async.periodic_maxima.load_per_second_10s == null) and
  ($legacy.decryptor_async.periodic_maxima.messages_per_second_lifetime == null) and
  ($legacy.decryptor_async.periodic_maxima.max_execute_messages_lifetime == null) and
  ($legacy.decryptor_async.periodic_maxima.max_execute_seconds_10m == null) and
  ($legacy.decryptor_async.periodic_maxima.max_message_seconds_10m == null) and
  ($legacy.decryptor_async.periodic_maxima.max_delay_seconds_lifetime == null) and
  ($legacy.decryptor_async.periodic_maxima.max_alive == null) and
  ($legacy.decryptor_async.periodic_maxima.max_executing == null) and
  ($legacy.decryptor_async.peak_max_execute_seconds_10m_sample == null) and
  ($legacy.pre_load_snapshot.decryptor_async == null) and
  ($legacy.measure_end_snapshot.decryptor_async == null) and
  ($legacy.final_snapshot.decryptor_async == null)
' >/dev/null

for field in \
  canonical_follower_transient_liteserver_timeouts \
  canonical_follower_transient_not_ready \
  canonical_lane_balance \
  canonical_lanes \
  canonical_lane_balance_required \
  canonical_lane_balance_valid \
  canonical_lane_balance_invalid_reasons \
  retry_horizon_exhausted \
  canonical_state_lag_retry_exhausted \
  adaptive_cwnd \
  admission_query_credit \
  adaptive_max_cwnd \
  effective_cwnd_cap \
  clients_at_cwnd_cap \
  clients_at_query_cap \
  clients_at_query_cap_sampled_peak \
  submit_max_queries_per_client \
  query_credit_stalls \
  max_per_client_admission_queries \
  cwnd_cap_limited_acks \
  ready_source_queue_max_depth \
  native_fast_path_invocations \
  native_fragment_refill_waits \
  native_fragment_refill_timeouts \
  native_fragment_refill_messages \
  native_post_commit_idle_waits \
  native_post_commit_idle_timeouts \
  native_fragment_capacity_fills \
  native_size_guard_deferrals \
  native_size_guard_reserve_bytes \
  native_size_guard_max_estimated_bytes \
  native_size_guard_estimator_gap_bytes \
  native_size_guard_serialized_margin_bytes \
  native_size_guard_serialized_oversize_bytes \
  native_stat_checkpoint_rebuilds \
  checkpoint_coalescing \
  deferrals \
  native_deadline_seals \
  native_deadline_deferred \
  native_deadline_first_fragment_commits \
  total.ext_msg_native_transport \
  native_transport \
  total.ext_msg_native_reconciliation \
  canonical_reconciliation \
  cleanup_acceptance \
  shard_state_cache \
  external_wait_breakdown \
  validator_cleanup_valid \
  validator_cleanup_invalid_reasons \
  BENCHMARK_ACTOR_STATS_SAMPLE_SECONDS \
  BENCHMARK_ACTOR_STATS_TIMEOUT_SECONDS \
  BENCHMARK_EXT_MESSAGES_BROADCAST_DISABLED \
  set-ext-messages-broadcast-disabled \
  validator-ext-messages-broadcast.json \
  validator-actor-stats-final.txt \
  decryptor_async \
  validator_actor_stats; do
  grep -q "$field" "$wrapper" || {
    echo "benchmark wrapper does not report $field" >&2
    exit 1
  }
done

for field in \
  native_collator_deferral_summary \
  native_microbatch_delayed \
  native_deferral_intake_deadline_idle_entries \
  native_deferral_intake_deadline_fragment_entries \
  native_deferral_checkpoint_deadline_rollback_entries \
  native_deferral_checkpoint_hard_preflight_entries \
  native_deferral_checkpoint_size_preflight_entries \
  native_deferral_medium_timeout_entries \
  native_deferral_candidate_headroom_entries \
  native_deferral_candidate_size_guard_entries \
  native_deferral_protocol_account_capacity_entries \
  native_deferral_account_unavailable_entries \
  native_deferral_account_balance_unrepresentable_entries \
  native_deferral_state_invalid_fields_entries \
  native_deferral_state_invalid_signature_entries \
  native_deferral_state_nonce_mismatch_entries \
  native_deferral_state_nonce_overflow_entries \
  native_deferral_state_invalid_source_entries \
  native_deferral_state_invalid_destination_entries \
  native_deferral_state_insufficient_balance_entries \
  native_deferral_state_balance_overflow_entries \
  native_checkpoint_rollback_entries \
  native_deadline_deferred \
  native_prebatch_protocol_capacity_requeue_works \
  native_prebatch_protocol_capacity_requeue_entries \
  native_prebatch_carryover_requeue_works \
  native_prebatch_carryover_requeue_entries \
  native_prebatch_scalar_decode_retry_works; do
  grep -q "$field" "$jq_dir/native-benchmark-lib.jq" || {
    echo "benchmark jq library does not report native deferral field $field" >&2
    exit 1
  }
done

grep -Fq 'deferrals:native_collator_deferral_summary($rows)' "$wrapper" || {
  echo "benchmark wrapper does not publish native collator deferrals" >&2
  exit 1
}

for field in \
  native-payment-lanes-provenance.json \
  capture_native_payment_lanes_provenance \
  native_payment_lanes_canonical_awk_uint \
  native_payment_lanes_manifest_header_valid \
  native_payment_lanes_runtime_enabled_check \
  native_payment_lanes_configuration_checks \
  NATIVE_PAYMENT_LANES_ENABLED \
  NATIVE_PAYMENT_LANE_COUNT \
  NATIVE_PROTOCOL_CAPABILITIES=3072 \
  lane_record_counts \
  lane_records \
  lane_balance \
  lane_count_explicit \
  lane_count_legacy_inferred \
  runtime_enabled_check \
  runtime_activation_checks \
  topology_consistency_checks \
  durable_manifest_lane_count \
  manifest_topology \
  'balanced:$lane_balance.balanced' \
  contains_private_keys:false; do
  grep -Fq "$field" "$wrapper" || {
    echo "benchmark wrapper does not retain native payment-lane provenance: $field" >&2
    exit 1
  }
done

for field in \
  canonical_lane_balance_telemetry \
  canonical_lane_balance_acceptance \
  canonical_lane_balance_expected_lanes_mismatch \
  canonical_lane_balance_observed_lanes_mismatch \
  canonical_lane_balance_lane_records_mismatch \
  canonical_lane_balance_lane_record_invalid \
  canonical_lane_balance_duplicate_shard \
  canonical_lane_balance_inactive_record \
  canonical_lane_balance_record_sum_mismatch \
  canonical_lane_balance_record_share_outside_tolerance \
  shard_state_requests \
  shard_manager_waits \
  shard_fetches \
  shard_cache_hits \
  shard_cache_fills \
  shard_cache_fill_races \
  shard_cache_fill_conflicts \
  shard_cache_generation_resets \
  shard_cache_stale_generation_fill_skips \
  shard_cache_wrong_id \
  shard_cache_invalid_header \
  shard_miss_errors \
  shard_fetch_errors \
  shard_manager_wait_errors \
  shard_manager_wait_timeouts \
  shard_manager_wait_notready \
  shard_manager_wait_other_errors \
  shard_manager_wait_late_results \
  shard_cache_entries \
  shard_cache_peak_entries \
  observed_high_water \
  observed_max_push_batch \
  observed_max_pop_batch \
  external_wait_round_live_s \
  external_wait_round_live_calls \
  external_wait_round_native_coalescing_s \
  external_wait_round_native_coalescing_calls \
  external_wait_generic_try_pop_s \
  external_wait_generic_try_pop_calls \
  external_wait_generic_sync_snapshot_s \
  external_wait_generic_sync_snapshot_calls \
  external_wait_native_probe_s \
  external_wait_native_probe_calls \
  external_wait_native_first_work_s \
  external_wait_native_first_work_calls \
  external_wait_native_fragment_refill_s \
  external_wait_native_fragment_refill_calls \
  external_wait_native_post_commit_idle_s \
  external_wait_native_post_commit_idle_calls \
  external_wait_native_producer_drain_s \
  external_wait_native_producer_drain_calls \
  external_wait_native_sync_snapshot_s \
  external_wait_native_sync_snapshot_calls \
  external_wait_accounted_s \
  external_wait_calls; do
  grep -q "$field" "$jq_dir/native-benchmark-lib.jq" || {
    echo "benchmark jq library does not report $field" >&2
    exit 1
  }
done

for field in \
  native_checkpoint_groups \
  native_checkpoint_group_entries \
  native_checkpoint_group_fragments \
  native_checkpoint_group_max_entries \
  native_checkpoint_group_max_fragments \
  native_checkpoint_flush_capacity \
  native_checkpoint_flush_ingress \
  native_checkpoint_flush_deadline \
  native_checkpoint_flush_fanout \
  native_checkpoint_flush_headroom \
  native_checkpoint_flush_latency \
  native_checkpoint_refill_continuations \
  native_checkpoint_refill_expirations \
  native_checkpoint_ingress_retentions \
  native_checkpoint_ingress_retention_max_dirty_accounts \
  native_checkpoint_rollbacks \
  native_checkpoint_rollback_entries; do
  grep -q "$field" "$jq_dir/native-benchmark-lib.jq" || {
    echo "benchmark jq library does not report $field" >&2
    exit 1
  }
done

grep -Fq 'native_stat_checkpoint_rebuild:stage_distribution($rows; "native_stat_checkpoint_rebuild")' "$wrapper" || {
  echo "benchmark wrapper does not report native checkpoint-rebuild timing" >&2
  exit 1
}

grep -Fq 'actor_stats_sample_seconds=${BENCHMARK_ACTOR_STATS_SAMPLE_SECONDS:-30}' "$wrapper" || {
  echo "actor-stat sampling must default to the low-perturbation 30-second cadence" >&2
  exit 1
}

grep -Fq -- '--argjson decryptor_async "$decryptor_async"' "$wrapper" &&
  grep -Fq 'parsed_decryptor_async:($decryptor_async != null)' "$wrapper" || {
    echo "each actor-stat record must carry parsed DecryptorAsync telemetry" >&2
    exit 1
  }

apply_line=$(grep -n '^if ! apply_ext_messages_broadcast_setting; then$' "$wrapper" | cut -d: -f1)
health_gate_line=$(grep -n '^if \[\[ \$genesis_health != "true healthy" \]\]; then$' "$wrapper" | cut -d: -f1)
pre_load_line=$(grep -n '^if ! capture_validator_stats "$validator_stats_before_file"; then$' "$wrapper" | cut -d: -f1)
[[ -n $health_gate_line && -n $apply_line && -n $pre_load_line &&
   $health_gate_line -lt $apply_line && $apply_line -lt $pre_load_line ]] || {
  echo "external-message broadcast control must run before every pre-load snapshot" >&2
  exit 1
}

grep -Fq 'trap cleanup_benchmark_on_exit EXIT' "$wrapper" &&
  grep -Fq 'restore_ext_messages_broadcast_setting' "$wrapper" &&
  grep -Fq 'attempt_label=restore-attempt-$ext_messages_broadcast_restore_attempts' "$wrapper" &&
  grep -Fq 'set_ext_messages_broadcast_disabled 0 "$attempt_label"' "$wrapper" &&
  grep -Fq 'capture_ext_messages_broadcast_state "$attempt_label"' "$wrapper" &&
  grep -Fq 'ext_messages_broadcast_settle_seconds=5' "$wrapper" &&
  grep -Fq -- '--slurpfile ext_messages_broadcast "$ext_messages_broadcast_file"' "$wrapper" &&
  grep -Fq 'ext_messages_broadcast:$ext_messages_broadcast[0]' "$wrapper" || {
    echo "external-message broadcast lifecycle must retain retry evidence, restore, and be embedded in reports" >&2
    exit 1
  }

# Compose v2.39+ requires the service selector argument to `config --hash`.
# Keep provenance collection compatible by enumerating the resolved services
# and hashing them one at a time instead of relying on the old bare flag.
grep -Fq 'config --services' "$wrapper" &&
  grep -Fq 'config --hash "$service"' "$wrapper" || {
    echo "benchmark wrapper must hash each resolved Compose service explicitly" >&2
    exit 1
  }

echo "native benchmark reporting tests passed"
