#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$script_dir/.." && pwd)
env_file=${1:-.env.physical}
shift || true

# shellcheck source=native-payment-lanes-profile.sh
source "$script_dir/native-payment-lanes-profile.sh"

require_matching_accepted_baseline() {
  local genesis_health manifest_sha genesis_env_sha summary matching_summary=

  genesis_health=$(docker inspect -f \
    '{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    genesis 2>/dev/null || true)
  if [[ $genesis_health != "true healthy" ]]; then
    echo "native payment-lane staircase requires the healthy genesis created by the fresh 4k cycle" >&2
    return 2
  fi
  if ! manifest_sha=$(docker exec genesis sha256sum \
      /var/ton-work/db/native-spam/wallets/native-payment-lanes.manifest 2>/dev/null | awk 'NR == 1 { print $1 }') ||
     ! genesis_env_sha=$(docker exec genesis sha256sum \
      /var/ton-work/db/native-spam/genesis.env 2>/dev/null | awk 'NR == 1 { print $1 }'); then
    echo "failed to fingerprint the active native payment-lane genesis" >&2
    return 2
  fi
  if ! [[ $manifest_sha =~ ^[[:xdigit:]]{64}$ && $genesis_env_sha =~ ^[[:xdigit:]]{64}$ ]]; then
    echo "active native payment-lane genesis fingerprint is invalid" >&2
    return 2
  fi
  if [[ ! -d $repo_dir/benchmark-results ]]; then
    echo "native payment-lane staircase requires a completed fresh 4k result bundle" >&2
    return 2
  fi

  while IFS=' ' read -r _ summary; do
    if jq -e --arg manifest_sha "$manifest_sha" --arg genesis_env_sha "$genesis_env_sha" '
      .run.benchmark_exit_code == 0 and
      (.run.interrupted // false) == false and
      .generator.final.target_tps == 4000 and
      .native_payment_lanes.enabled == true and
      .native_payment_lanes.manifest.sha256 == $manifest_sha and
      .native_payment_lanes.genesis_env.sha256 == $genesis_env_sha and
      .native_payment_lanes.durable_activation_checks.fixed_split == true and
      .native_payment_lanes.durable_activation_checks.signed_runs == true and
      .native_payment_lanes.durable_activation_checks.payment_lanes == true and
      .native_payment_lanes.durable_activation_checks.effective_capabilities == true and
      .native_payment_lanes.durable_activation_checks.effective_global_version == true and
      .generator.valid_canonical_run == true and
      .generator.ingress_capacity_valid == true and
      .generator.chain_capacity_valid == true and
      .validator_pool.cleanup_acceptance.valid == true
    ' "$summary" >/dev/null; then
      matching_summary=$summary
      break
    fi
  done < <(find "$repo_dir/benchmark-results" -mindepth 2 -maxdepth 2 -name benchmark-summary.json \
    -printf '%T@ %p\n' | sort -nr)

  if [[ -z $matching_summary ]]; then
    echo "native payment-lane staircase requires an accepted 4k result matching the active genesis" >&2
    return 2
  fi
  echo "Reusing genesis proven by accepted 4k baseline: $matching_summary"
}

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
It first requires an accepted fresh 4k result whose public manifest and
durable genesis marker match the active container.
EOF

require_matching_accepted_baseline

for target_tps in "$@"; do
  if ! [[ $target_tps =~ ^[1-9][0-9]*$ ]]; then
    echo "each TPS target must be a positive integer, got '$target_tps'" >&2
    exit 2
  fi
  run_id=$(date -u +%Y%m%dT%H%M%SZ)-native-payment-lanes-${target_tps}
  result_dir=$repo_dir/benchmark-results/$run_id
  echo "Starting native payment-lane rung: target_tps=$target_tps result_dir=$result_dir"
  native_payment_lanes_profile_env \
    env BENCHMARK_RECREATE_GENESIS=0 BENCHMARK_STRICT_GENESIS_REUSE=1 NATIVE_LOAD_TARGET_TPS="$target_tps" \
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
