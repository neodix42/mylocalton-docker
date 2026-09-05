#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$script_dir/.." && pwd)
harness_git=(git -c "safe.directory=$repo_dir" -C "$repo_dir")

usage() {
  cat <<'EOF'
Usage: run-native-payment-lanes-staircase.sh [--depth 1|2] [ENV_FILE] [TPS ...]

Reuse an accepted fixed-depth native payment-lane genesis for a throughput
ladder. Depth defaults to 1 (two lanes). With no TPS values, depth 1 runs
6000/10000/15000 TPS and depth 2 runs 30000/32000/34000 TPS. Depth-2 result
IDs include "depth2"; depth-1 IDs retain their historical form.
EOF
}

lane_depth=1
positional=()
while (( $# > 0 )); do
  case "$1" in
    --depth)
      if (( $# < 2 )); then
        echo "--depth requires 1 or 2" >&2
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
  1|2) ;;
  *)
    echo "--depth must be 1 or 2, got '$lane_depth'" >&2
    usage >&2
    exit 2
    ;;
esac

lane_count=$((1 << lane_depth))
set -- "${positional[@]}"
if (( $# == 0 )); then
  env_file=.env.physical
else
  env_file=$1
  if [[ -z $env_file ]]; then
    echo "environment file must not be empty" >&2
    exit 2
  fi
  shift
fi

# shellcheck source=native-payment-lanes-profile.sh
source "$script_dir/native-payment-lanes-profile.sh"

require_matching_accepted_baseline() {
  local expected_depth=$1 expected_lane_count=$2
  local genesis_health genesis_image_id manifest_sha genesis_env_sha
  local harness_revision env_sha desired_generator_environment summary matching_summary=

  if [[ -n $("${harness_git[@]}" status --porcelain=v1 --untracked-files=normal) ]]; then
    echo "native payment-lane staircase requires a clean harness worktree so only target TPS changes" >&2
    return 2
  fi
  harness_revision=$("${harness_git[@]}" rev-parse HEAD)
  env_sha=$(sha256sum "$env_file" | awk '{print $1}')
  if ! desired_generator_environment=$(native_payment_lanes_profile_env "$expected_depth" \
      env NATIVE_LOAD_TARGET_TPS=4000 \
      docker compose -f "$repo_dir/docker-compose.yaml" --project-directory "$repo_dir" \
      --project-name mylocalton-desktop --env-file "$env_file" \
      --profile native-load-generator config --format json | jq -ce '
        .services["native-load-generator"].environment |
        with_entries(select(.value != null)) | map_values(tostring) |
        del(.NATIVE_LOAD_TARGET_TPS)
      '); then
    echo "failed to resolve the fixed native payment-lane generator environment" >&2
    return 2
  fi

  genesis_health=$(docker inspect -f \
    '{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    genesis 2>/dev/null || true)
  if [[ $genesis_health != "true healthy" ]]; then
    echo "native payment-lane staircase requires the healthy depth-$expected_depth genesis created by the fresh 4k cycle" >&2
    return 2
  fi
  genesis_image_id=$(docker inspect -f '{{.Image}}' genesis 2>/dev/null || true)
  if [[ -z $genesis_image_id ]]; then
    echo "failed to identify the active native payment-lane genesis image" >&2
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
    echo "native payment-lane staircase requires a completed fresh 4k depth-$expected_depth result bundle" >&2
    return 2
  fi

  while IFS=' ' read -r _ summary; do
    if jq -e -L "$script_dir/jq" --arg manifest_sha "$manifest_sha" --arg genesis_env_sha "$genesis_env_sha" \
        --arg genesis_image_id "$genesis_image_id" \
        --arg harness_revision "$harness_revision" \
        --arg env_sha "$env_sha" \
        --argjson desired_generator_environment "$desired_generator_environment" \
        --argjson expected_depth "$expected_depth" \
        --argjson expected_lane_count "$expected_lane_count" '
    include "native-benchmark-lib";
      ($expected_depth == 1 and $expected_lane_count == 2) as $legacy_depth_one |
      ($legacy_depth_one and
       (.native_payment_lanes.manifest | has("balanced") | not) and
       (.native_payment_lanes.durable_activation_checks | has("lane_count") | not) and
       (.native_payment_lanes | has("topology_consistency_checks") | not)) as $legacy_summary |
      .run.benchmark_exit_code == 0 and
      (.run.interrupted // false) == false and
      ((.run.git_revision == $harness_revision and
        .run.git_dirty == false and
        .run.env_sha256 == $env_sha) or $legacy_summary) and
      ([.run.containers[] |
         select(.name == "native-load-generator") |
         .benchmark_environment[]? |
         capture("^(?<key>[^=]+)=(?<value>.*)$")
       ] | from_entries | del(.NATIVE_LOAD_TARGET_TPS)) == $desired_generator_environment and
      .generator.final.target_tps == 4000 and
      ((.run.containers // [] | map(select(.name == "genesis") | .image_id)) == [$genesis_image_id]) and
    .native_payment_lanes.enabled == true and
      .native_payment_lanes.manifest.sha256 == $manifest_sha and
      .native_payment_lanes.manifest.depth == $expected_depth and
      .native_payment_lanes.manifest.lanes == $expected_lane_count and
      (.native_payment_lanes.manifest.records | type) == "number" and
      .native_payment_lanes.manifest.records >= $expected_lane_count and
      (
        .native_payment_lanes.manifest.balanced == true or
        ($legacy_depth_one and
         (.native_payment_lanes.manifest | has("balanced") | not) and
         (.native_payment_lanes.manifest.lane_zero_records | type) == "number" and
         (.native_payment_lanes.manifest.lane_one_records | type) == "number" and
         (.native_payment_lanes.manifest.lane_zero_records +
          .native_payment_lanes.manifest.lane_one_records) ==
           .native_payment_lanes.manifest.records and
         ((.native_payment_lanes.manifest.lane_zero_records -
           .native_payment_lanes.manifest.lane_one_records) |
            if . < 0 then -. else . end) <= 1)
      ) and
      .native_payment_lanes.genesis_env.sha256 == $genesis_env_sha and
      .native_payment_lanes.durable_activation_checks.fixed_split == true and
      .native_payment_lanes.durable_activation_checks.signed_runs == true and
      .native_payment_lanes.durable_activation_checks.payment_lanes == true and
      (
        .native_payment_lanes.durable_activation_checks.lane_count == true or
        ($legacy_depth_one and
         (.native_payment_lanes.durable_activation_checks | has("lane_count") | not) and
         (.native_payment_lanes.genesis_environment | has("NATIVE_PAYMENT_LANE_COUNT") | not))
      ) and
      .native_payment_lanes.durable_activation_checks.effective_capabilities == true and
      .native_payment_lanes.durable_activation_checks.effective_global_version == true and
      (
        (.native_payment_lanes.topology_consistency_checks.header_lane_count == true and
         .native_payment_lanes.topology_consistency_checks.runtime_manifest_depth == true and
         .native_payment_lanes.topology_consistency_checks.durable_manifest_depth == true and
         .native_payment_lanes.topology_consistency_checks.durable_manifest_lane_count == true and
         .native_payment_lanes.topology_consistency_checks.runtime_durable_split == true) or
        ($legacy_depth_one and
         (.native_payment_lanes | has("topology_consistency_checks") | not) and
         .native_payment_lanes.container_environment.NATIVE_PAYMENT_LANE_DEPTH == "1" and
         .native_payment_lanes.container_environment.ACTUAL_MIN_SPLIT == "1" and
         .native_payment_lanes.container_environment.MIN_SPLIT == "1" and
         .native_payment_lanes.container_environment.MAX_SPLIT == "1" and
         .native_payment_lanes.genesis_environment.NATIVE_PAYMENT_LANE_DEPTH == "1" and
         .native_payment_lanes.genesis_environment.NATIVE_PAYMENT_LANE_ACTUAL_MIN_SPLIT == "1" and
         .native_payment_lanes.genesis_environment.NATIVE_PAYMENT_LANE_MIN_SPLIT == "1" and
         .native_payment_lanes.genesis_environment.NATIVE_PAYMENT_LANE_MAX_SPLIT == "1")
      ) and
      .generator.final.native_payment_lane_depth == $expected_depth and
      .generator.final.canonical_follower_basechain_leaf_shards == $expected_lane_count and
      ($expected_depth == 1 or .generator.final.canonical_lane_balance.valid == true) and
      .generator.valid_canonical_run == true and
      .generator.ingress_capacity_valid == true and
      (native_benchmark_load_level_acceptance(.).valid == true) and
      .validator_pool.cleanup_acceptance.valid == true
    ' "$summary" >/dev/null; then
      matching_summary=$summary
      break
    fi
  done < <(find "$repo_dir/benchmark-results" -mindepth 2 -maxdepth 2 -name benchmark-summary.json \
    -printf '%T@ %p\n' | sort -nr)

  if [[ -z $matching_summary ]]; then
    echo "native payment-lane staircase requires an accepted 4k depth-$expected_depth ($expected_lane_count-lane) result matching the active genesis" >&2
    return 2
  fi
  echo "Reusing genesis proven by accepted 4k load-validation baseline (no capacity claim): $matching_summary"
}

if [[ $env_file != /* ]]; then
  env_file=$repo_dir/$env_file
fi
test -r "$env_file" || {
  echo "environment file is not readable: $env_file" >&2
  exit 2
}
if (( $# == 0 )); then
  if [[ $lane_depth == 2 ]]; then
    set -- 30000 32000 34000
  else
    set -- 6000 10000 15000
  fi
fi
for target_tps in "$@"; do
  if ! [[ $target_tps =~ ^[1-9][0-9]*$ ]]; then
    echo "each TPS target must be a positive integer, got '$target_tps'" >&2
    exit 2
  fi
done

printf 'Reusing the matching fixed depth-%s genesis (%s lanes) for a controlled throughput ladder.\n' \
  "$lane_depth" "$lane_count" >&2
cat >&2 <<'EOF'
Only NATIVE_LOAD_TARGET_TPS changes between rungs. This helper refuses a
configuration/image mismatch instead of recreating or mutating the genesis.
It first requires an accepted fresh 4k result whose public manifest and
durable genesis marker match the active container.
EOF

require_matching_accepted_baseline "$lane_depth" "$lane_count"

for target_tps in "$@"; do
  run_name=native-payment-lanes-${target_tps}
  if [[ $lane_depth == 2 ]]; then
    run_name=native-payment-lanes-depth2-${target_tps}
  fi
  run_id=$(date -u +%Y%m%dT%H%M%SZ)-$run_name
  result_dir=$repo_dir/benchmark-results/$run_id
  echo "Starting native payment-lane rung: depth=$lane_depth lanes=$lane_count target_tps=$target_tps result_dir=$result_dir"
  native_payment_lanes_profile_env "$lane_depth" \
    env BENCHMARK_RECREATE_GENESIS=0 BENCHMARK_STRICT_GENESIS_REUSE=1 \
      BENCHMARK_IMAGES_PREBUILT=1 BENCHMARK_STRICT_IMAGE_REUSE=1 NATIVE_LOAD_TARGET_TPS="$target_tps" \
    "$repo_dir/run-native-benchmark.sh" "$env_file" "$result_dir"

  if ! jq -e -L "$script_dir/jq" --argjson expected_depth "$lane_depth" \
      --argjson expected_lane_count "$lane_count" \
      --argjson expected_target_tps "$target_tps" '
    include "native-benchmark-lib";
    .native_payment_lanes.enabled == true and
    .native_payment_lanes.manifest.depth == $expected_depth and
    .native_payment_lanes.manifest.lanes == $expected_lane_count and
    (.native_payment_lanes.manifest.records | type) == "number" and
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
    .generator.final.target_tps == $expected_target_tps and
    .generator.final.native_payment_lane_depth == $expected_depth and
    .generator.final.canonical_follower_basechain_leaf_shards == $expected_lane_count and
    ($expected_depth == 1 or .generator.final.canonical_lane_balance.valid == true) and
    .generator.valid_canonical_run == true and
    .generator.ingress_capacity_valid == true and
    (native_benchmark_load_level_acceptance(.).valid == true) and
    .validator_pool.cleanup_acceptance.valid == true
  ' "$result_dir/benchmark-summary.json" >/dev/null; then
    echo "Stopping ladder: rung $target_tps failed load-validation/capacity acceptance; inspect $result_dir/benchmark-summary.json" >&2
    exit 3
  fi
  jq -r -L "$script_dir/jq" '
    include "native-benchmark-lib";
    native_benchmark_load_level_acceptance(.) |
    if .capacity_claim_allowed then "Accepted capacity-eligible rung; assess sustained throughput separately"
    else "Accepted offered-load validation; no capacity claim" end
  ' "$result_dir/benchmark-summary.json"
done
