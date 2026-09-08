#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
jq -n -e -L "$script_dir/../jq" '
  include "native-benchmark-lib";
  def final_fixture:
    {native_payment_lane_depth:3, canonical_follower_basechain_leaf_shards:8,
     canonical_chain_measure_transfers:8000, chain_correctness_valid:true,
     run_incomplete_reasons:[], chain_capacity_valid:true, chain_capacity_invalid_reasons:[],
     steady_offered_avg_tps:110, canonical_chain_measure_avg_tps:100,
     canonical_lane_balance:{
       required:true, valid:true, topology_complete:true, totals_reconcile:true,
       every_lane_active:true, within_tolerance:true,
       depth:3, tolerance_bps:500, expected_lanes:8, observed_lanes:8,
       measured_transfers:8000, lane_measured_transfers_sum:8000,
       lanes:(["1","3","5","7","9","b","d","f"] |
         map({shard:("(0," + . + "000000000000000)"), depth:3, measured_native_transfers:1000}))}};
  def rejection($final; $reason):
    capacity_acceptance($final) |
    .canonical_lane_balance_required == true and .canonical_lane_balance_valid == false and
    .chain_capacity_valid == false and
    (.canonical_lane_balance_invalid_reasons | index($reason) != null);
  final_fixture as $good |
  (capacity_acceptance($good) | .canonical_lane_balance_required == true and
    .canonical_lane_balance_valid == true and .chain_capacity_valid == true) and
  # Record order and equivalent historical ShardIdFull rendering are harmless.
  (capacity_acceptance($good | .canonical_lane_balance.lanes |= reverse |
     .canonical_lane_balance.lanes[0].shard = "0:F000000000000000") |
     .canonical_lane_balance_valid == true) and
  (rejection(($good | del(.canonical_lane_balance)); "canonical_lane_balance_missing")) and
  (rejection(($good | .canonical_lane_balance = []); "canonical_lane_balance_missing")) and
  (rejection(($good | .canonical_lane_balance.lanes |= .[:7]); "canonical_lane_balance_lane_records_mismatch")) and
  (rejection(($good | .canonical_lane_balance.lanes += [.canonical_lane_balance.lanes[0]]);
    "canonical_lane_balance_lane_records_mismatch")) and
  (rejection(($good | .canonical_lane_balance.lanes[7] = .canonical_lane_balance.lanes[0]);
    "canonical_lane_balance_duplicate_shard")) and
  (rejection(($good | .canonical_lane_balance.lanes[7].shard = "0:1000000000000000");
    "canonical_lane_balance_duplicate_shard")) and
  (["(0,e000000000000000)", "(-1,f000000000000000)", "invented", ""] |
    all(.[]; . as $shard |
      capacity_acceptance($good | .canonical_lane_balance.lanes[7].shard = $shard) |
      .canonical_lane_balance_required == true and .canonical_lane_balance_valid == false and
      .chain_capacity_valid == false)) and
  (rejection(($good | .canonical_lane_balance.lanes[7].depth = 2);
    "canonical_lane_balance_lane_depth_mismatch")) and
  (rejection(($good | .canonical_lane_balance.depth = 2); "canonical_lane_balance_depth_mismatch")) and
  (rejection(($good | .canonical_lane_balance.expected_lanes = 4); "canonical_lane_balance_expected_lanes_mismatch")) and
  (rejection(($good | .canonical_lane_balance.observed_lanes = 7); "canonical_lane_balance_observed_lanes_mismatch")) and
  (rejection(($good | .canonical_follower_basechain_leaf_shards = 4); "canonical_lane_balance_follower_lanes_mismatch")) and
  (rejection(($good | .canonical_chain_measure_transfers = 7999); "canonical_lane_balance_chain_total_mismatch")) and
  (rejection(($good | del(.canonical_chain_measure_transfers)); "canonical_lane_balance_chain_total_mismatch")) and
  (rejection(($good | .canonical_lane_balance.tolerance_bps = 1000); "canonical_lane_balance_tolerance_mismatch")) and
  (rejection(($good | .canonical_lane_balance.lanes[7].measured_native_transfers = 999);
    "canonical_lane_balance_record_sum_mismatch")) and
  (rejection(($good | .canonical_lane_balance.lane_measured_transfers_sum = 7999);
    "canonical_lane_balance_record_sum_mismatch")) and
  # Summary flags remain true here: the rows must independently reject a
  # starved or imbalanced lane, including immediately outside the 5% boundary.
  (rejection(($good | .canonical_lane_balance.lanes[0].measured_native_transfers = 0 |
    .canonical_lane_balance.lanes[7].measured_native_transfers = 2000);
    "canonical_lane_balance_inactive_record")) and
  (capacity_acceptance($good | .canonical_lane_balance.lanes[0].measured_native_transfers = 950 |
    .canonical_lane_balance.lanes[7].measured_native_transfers = 1050) |
    .canonical_lane_balance_valid == true) and
  (rejection(($good | .canonical_lane_balance.lanes[0].measured_native_transfers = 949 |
    .canonical_lane_balance.lanes[7].measured_native_transfers = 1051);
    "canonical_lane_balance_record_share_outside_tolerance")) and
  ([null, "1000", true, -1, 0.5, infinite] | all(.[]; . as $bad |
    rejection(($good | .canonical_lane_balance.lanes[0].measured_native_transfers = $bad);
      "canonical_lane_balance_lane_record_invalid"))) and
  ([4, "3", true, -1] | all(.[]; . as $depth |
    rejection(($good | .native_payment_lane_depth = $depth); "native_payment_lane_depth_invalid"))) and
  (["required", "topology_complete", "totals_reconcile", "every_lane_active", "within_tolerance", "valid"] |
    all(.[]; . as $flag | capacity_acceptance($good | .canonical_lane_balance[$flag] = false) |
      .canonical_lane_balance_valid == false and .chain_capacity_valid == false)) and
  # Cached acceptance booleans cannot turn missing eight-lane telemetry into
  # an eligible load-validation/capacity result.
  ({run:{benchmark_exit_code:0,interrupted:false},
    generator:{final:$good, valid_canonical_run:true, ingress_capacity_valid:true,
      chain_capacity_valid:true, native_signed_run_quantum:{valid:true},
      capacity_acceptance:{canonical_lane_balance_required:false, canonical_lane_balance_valid:true,
        chain_capacity_invalid_reasons:[]}}, validator_pool:{cleanup_acceptance:{valid:true}}}) as $summary |
  (native_benchmark_load_level_acceptance($summary).valid == true) and
  (native_benchmark_load_level_acceptance($summary | del(.generator.final.canonical_lane_balance)).valid == false) and
  (native_benchmark_load_level_acceptance($summary |
    .generator.final.canonical_lane_balance.lanes[0].measured_native_transfers = 949 |
    .generator.final.canonical_lane_balance.lanes[7].measured_native_transfers = 1051).valid == false)
' >/dev/null

echo 'Eight-lane canonical reporting checks passed'
