#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$script_dir/.." && pwd)
env_file=${1:-.env.physical}
shift || true

# shellcheck source=native-payment-lanes-profile.sh
source "$script_dir/native-payment-lanes-profile.sh"

if [[ $env_file != /* ]]; then
  env_file=$repo_dir/$env_file
fi
test -r "$env_file" || {
  echo "environment file is not readable: $env_file" >&2
  exit 2
}
if (( $# == 0 )); then
  set -- 6000 10000 15000
fi

cat >&2 <<'EOF'
Reusing the matching fixed two-lane genesis for a controlled throughput ladder.
Only NATIVE_LOAD_TARGET_TPS changes between rungs. This helper refuses a
configuration/image mismatch instead of recreating or mutating the genesis.
Run benchmark/run-native-payment-lanes-cycle.sh first to create the fresh P6
state and establish the 4k correctness baseline.
EOF

for target_tps in "$@"; do
  if ! [[ $target_tps =~ ^[1-9][0-9]*$ ]]; then
    echo "each TPS target must be a positive integer, got '$target_tps'" >&2
    exit 2
  fi
  run_id=$(date -u +%Y%m%dT%H%M%SZ)-native-payment-lanes-${target_tps}
  result_dir=$repo_dir/benchmark-results/$run_id
  echo "Starting native payment-lane rung: target_tps=$target_tps result_dir=$result_dir"
  native_payment_lanes_profile_env \
    env BENCHMARK_STRICT_GENESIS_REUSE=1 NATIVE_LOAD_TARGET_TPS="$target_tps" \
    "$repo_dir/run-native-benchmark.sh" "$env_file" "$result_dir"

  if ! jq -e '
    .native_payment_lanes.enabled == true and
    .native_payment_lanes.durable_activation_checks.fixed_split == true and
    .native_payment_lanes.durable_activation_checks.signed_runs == true and
    .native_payment_lanes.durable_activation_checks.payment_lanes == true and
    .native_payment_lanes.durable_activation_checks.effective_capabilities == true and
    .native_payment_lanes.durable_activation_checks.effective_global_version == true and
    .generator.valid_canonical_run == true and
    .generator.ingress_capacity_valid == true and
    .generator.chain_capacity_valid == true and
    .validator_pool.cleanup_acceptance.valid == true
  ' "$result_dir/benchmark-summary.json" >/dev/null; then
    echo "Stopping ladder: rung $target_tps was not a valid capacity result; inspect $result_dir/benchmark-summary.json" >&2
    exit 3
  fi
done
