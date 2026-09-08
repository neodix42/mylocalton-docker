#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$script_dir/.." && pwd)
harness_git=(git -c "safe.directory=$repo_dir" -C "$repo_dir")

usage() {
  cat <<'EOF'
Usage: run-native-payment-lanes-cycle.sh [--depth 1|2|3] [ENV_FILE]

Create a fresh fixed-depth native payment-lane genesis and run its baseline.
Depth defaults to 1 (two lanes); depths 2 and 3 create four and eight lanes. This command
deletes only the benchmark Compose project's allowlisted state.
EOF
}

lane_depth=1
positional=()
while (( $# > 0 )); do
  case "$1" in
    --depth)
      if (( $# < 2 )); then
        echo "--depth requires 1, 2 or 3" >&2
        usage >&2
        exit 2
      fi
      lane_depth=$2
      shift 2
      continue
      ;;
    --depth=*)
      lane_depth=${1#*=}
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      positional+=("$@")
      break
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      positional+=("$1")
      ;;
  esac
  shift
done

case "$lane_depth" in
  1|2|3) ;;
  *)
    echo "--depth must be 1, 2 or 3, got '$lane_depth'" >&2
    usage >&2
    exit 2
    ;;
esac
if (( ${#positional[@]} > 1 )); then
  echo "expected at most one environment file" >&2
  usage >&2
  exit 2
fi

lane_count=$((1 << lane_depth))
if (( ${#positional[@]} == 0 )); then
  env_file=.env.physical
else
  env_file=${positional[0]}
  if [[ -z $env_file ]]; then
    echo "environment file must not be empty" >&2
    exit 2
  fi
fi

# shellcheck source=native-payment-lanes-profile.sh
source "$script_dir/native-payment-lanes-profile.sh"

if [[ $env_file != /* ]]; then
  env_file=$script_dir/../$env_file
fi
test -r "$env_file" || {
  echo "environment file is not readable: $env_file" >&2
  exit 2
}
if [[ -n $("${harness_git[@]}" status --porcelain=v1 --untracked-files=normal) ]]; then
  echo "native payment-lane cycle requires a clean harness worktree before deleting benchmark state" >&2
  exit 2
fi
harness_revision=$("${harness_git[@]}" rev-parse HEAD)
env_sha=$(sha256sum "$env_file" | awk '{print $1}')

printf 'Starting the fixed depth-%s native payment-lane profile (%s lanes).\n' \
  "$lane_depth" "$lane_count" >&2
cat >&2 <<'EOF'
The guarded fresh-cycle runner below deletes only the benchmark Compose
project's allowlisted containers, network, and volumes. Do not use this helper
against a state that must be retained.
EOF

run_id=$(date -u +%Y%m%dT%H%M%SZ)-native-payment-lanes-depth${lane_depth}-4000
result_dir=$repo_dir/benchmark-results/$run_id
native_payment_lanes_profile_env "$lane_depth" \
  env NATIVE_LOAD_TARGET_TPS=4000 \
  "$script_dir/run-fresh-native-cycle.sh" "$env_file" "$result_dir"

if ! jq -e -L "$script_dir/jq" --arg harness_revision "$harness_revision" \
    --arg env_sha "$env_sha" \
    --argjson expected_depth "$lane_depth" \
    --argjson expected_lane_count "$lane_count" '
    include "native-benchmark-lib";
  .run.benchmark_exit_code == 0 and
  (.run.interrupted // false) == false and
  .run.git_revision == $harness_revision and
  .run.git_dirty == false and
  .run.env_sha256 == $env_sha and
  .native_payment_lanes.enabled == true and
  .native_payment_lanes.manifest.depth == $expected_depth and
  .native_payment_lanes.manifest.lanes == $expected_lane_count and
  .native_payment_lanes.manifest.records >= $expected_lane_count and
  .native_payment_lanes.manifest.balanced == true and
  .native_payment_lanes.durable_activation_checks.fixed_split == true and
  .native_payment_lanes.durable_activation_checks.signed_runs == true and
  .native_payment_lanes.durable_activation_checks.payment_lanes == true and
  .native_payment_lanes.durable_activation_checks.lane_count == true and
  .native_payment_lanes.durable_activation_checks.effective_capabilities == true and
  .native_payment_lanes.durable_activation_checks.effective_global_version == true and
  .native_payment_lanes.topology_consistency_checks.header_lane_count == true and
  .native_payment_lanes.topology_consistency_checks.runtime_manifest_depth == true and
  .native_payment_lanes.topology_consistency_checks.durable_manifest_depth == true and
  .native_payment_lanes.topology_consistency_checks.durable_manifest_lane_count == true and
  .native_payment_lanes.topology_consistency_checks.runtime_durable_split == true and
  .generator.final.target_tps == 4000 and
  .generator.final.native_payment_lane_depth == $expected_depth and
  .generator.final.canonical_follower_basechain_leaf_shards == $expected_lane_count and
  ($expected_depth == 1 or .generator.final.canonical_lane_balance.valid == true) and
  ($expected_depth == 1 or canonical_lane_balance_acceptance(.generator.final).canonical_lane_balance_valid == true) and
  .generator.valid_canonical_run == true and
  .generator.native_signed_run_quantum.telemetry_contract_valid == true and
  .generator.native_signed_run_quantum.benchmark_profile_valid == true and
  .generator.native_signed_run_quantum.valid == true and
  .generator.ingress_capacity_valid == true and
  (native_benchmark_load_level_acceptance(.).valid == true) and
  .validator_pool.cleanup_acceptance.valid == true
' "$result_dir/benchmark-summary.json" >/dev/null; then
  echo "fresh depth-$lane_depth baseline did not satisfy every correctness, topology, signed-run quantum, offered-load, and cleanup gate: $result_dir/benchmark-summary.json" >&2
  exit 3
fi

echo "Accepted fresh depth-$lane_depth load-validation baseline (no capacity claim): $result_dir/benchmark-summary.json"
