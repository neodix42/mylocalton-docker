#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$script_dir/../.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT HUP INT TERM

# shellcheck source=../../docker/scripts/native-transfer-runs-config.sh
source "$repo_dir/docker/scripts/native-transfer-runs-config.sh"
# shellcheck source=../../docker/scripts/native-payment-lanes-config.sh
source "$repo_dir/docker/scripts/native-payment-lanes-config.sh"
# shellcheck source=../native-payment-lanes-profile.sh
source "$repo_dir/benchmark/native-payment-lanes-profile.sh"

assert_effective_config() {
  local expected_version=$1 expected_capabilities=$2 expected_lane_count=${3:-}
  resolve_native_payment_lanes_config
  [[ $NATIVE_PAYMENT_LANES_EFFECTIVE_VERSION == "$expected_version" ]]
  [[ $NATIVE_PAYMENT_LANES_EFFECTIVE_CAPABILITIES == "$expected_capabilities" ]]
  if [[ -n $expected_lane_count ]]; then
    [[ ${NATIVE_PAYMENT_LANE_COUNT:-} == "$expected_lane_count" ]]
    export -p | grep -q 'NATIVE_PAYMENT_LANE_COUNT'
  else
    [[ -z ${NATIVE_PAYMENT_LANE_COUNT+x} ]]
  fi
}

VERSION_CAPABILITIES=14
NATIVE_TRANSFER_RUNS_ENABLED=0
NATIVE_TRANSFER_RUNS_GLOBAL_VERSION=15
NATIVE_TRANSFER_RUNS_CAPABILITY=1024
NATIVE_PAYMENT_LANES_ENABLED=0
NATIVE_PAYMENT_LANES_GLOBAL_VERSION=16
NATIVE_PAYMENT_LANES_CAPABILITY=2048
NATIVE_PAYMENT_LANE_DEPTH=1
ACTUAL_MIN_SPLIT=0
MIN_SPLIT=0
MAX_SPLIT=4
assert_effective_config 14 0

NATIVE_TRANSFER_RUNS_ENABLED=1
assert_effective_config 15 1024

NATIVE_PAYMENT_LANES_ENABLED=1
ACTUAL_MIN_SPLIT=1
MIN_SPLIT=1
MAX_SPLIT=1
assert_effective_config 16 3072 2

NATIVE_PAYMENT_LANE_DEPTH=2
ACTUAL_MIN_SPLIT=2
MIN_SPLIT=2
MAX_SPLIT=2
assert_effective_config 16 3072 4

NATIVE_PAYMENT_LANE_DEPTH=0
ACTUAL_MIN_SPLIT=0
MIN_SPLIT=0
MAX_SPLIT=0
! resolve_native_payment_lanes_config >/dev/null 2>&1
NATIVE_PAYMENT_LANE_DEPTH=3
ACTUAL_MIN_SPLIT=3
MIN_SPLIT=3
MAX_SPLIT=3
! resolve_native_payment_lanes_config >/dev/null 2>&1
NATIVE_PAYMENT_LANE_DEPTH=2
ACTUAL_MIN_SPLIT=2
MIN_SPLIT=2
MAX_SPLIT=1
! resolve_native_payment_lanes_config >/dev/null 2>&1

NATIVE_PAYMENT_LANE_DEPTH=1
ACTUAL_MIN_SPLIT=1
MIN_SPLIT=1
MAX_SPLIT=1

NATIVE_TRANSFER_RUNS_ENABLED=0
! resolve_native_payment_lanes_config >/dev/null 2>&1
NATIVE_TRANSFER_RUNS_ENABLED=1
NATIVE_TRANSFER_RUNS_GLOBAL_VERSION=invalid
! resolve_native_payment_lanes_config >/dev/null 2>&1
NATIVE_TRANSFER_RUNS_GLOBAL_VERSION=15
MAX_SPLIT=2
! resolve_native_payment_lanes_config >/dev/null 2>&1
MAX_SPLIT=1
NATIVE_PAYMENT_LANES_GLOBAL_VERSION=15
! resolve_native_payment_lanes_config >/dev/null 2>&1
NATIVE_PAYMENT_LANES_GLOBAL_VERSION=16
NATIVE_PAYMENT_LANES_CAPABILITY=1024
! resolve_native_payment_lanes_config >/dev/null 2>&1
NATIVE_PAYMENT_LANES_CAPABILITY=2048

write_existing_genesis_marker() {
  local marker_file=$1 depth=$2
  shift 2

  printf '%s\n' \
    'NATIVE_PAYMENT_LANES_ENABLED=1' \
    "NATIVE_PAYMENT_LANE_DEPTH=$depth" \
    'NATIVE_TRANSFER_RUNS_ENABLED=1' \
    'NATIVE_PAYMENT_LANES_EFFECTIVE_VERSION=16' \
    'NATIVE_PAYMENT_LANES_EFFECTIVE_CAPABILITIES=3072' \
    "NATIVE_PAYMENT_LANE_ACTUAL_MIN_SPLIT=$depth" \
    "NATIVE_PAYMENT_LANE_MIN_SPLIT=$depth" \
    "NATIVE_PAYMENT_LANE_MAX_SPLIT=$depth" > "$marker_file"
  if (( $# > 0 )); then
    printf '%s\n' "$@" >> "$marker_file"
  fi
}

depth1_legacy_marker=$test_dir/depth1-legacy.env
write_existing_genesis_marker "$depth1_legacy_marker" 1
native_payment_lanes_existing_genesis_marker_is_valid "$depth1_legacy_marker" 1

depth1_explicit_marker=$test_dir/depth1-explicit.env
write_existing_genesis_marker "$depth1_explicit_marker" 1 'NATIVE_PAYMENT_LANE_COUNT=2'
native_payment_lanes_existing_genesis_marker_is_valid "$depth1_explicit_marker" 1

depth2_explicit_marker=$test_dir/depth2-explicit.env
write_existing_genesis_marker "$depth2_explicit_marker" 2 'NATIVE_PAYMENT_LANE_COUNT=4'
native_payment_lanes_existing_genesis_marker_is_valid "$depth2_explicit_marker" 2

depth2_missing_count_marker=$test_dir/depth2-missing-count.env
write_existing_genesis_marker "$depth2_missing_count_marker" 2
! native_payment_lanes_existing_genesis_marker_is_valid "$depth2_missing_count_marker" 2

depth2_missing_split_marker=$test_dir/depth2-missing-split.env
sed '/^NATIVE_PAYMENT_LANE_MAX_SPLIT=/d' "$depth2_explicit_marker" > "$depth2_missing_split_marker"
! native_payment_lanes_existing_genesis_marker_is_valid "$depth2_missing_split_marker" 2

depth2_wrong_capability_marker=$test_dir/depth2-wrong-capability.env
sed 's/^NATIVE_PAYMENT_LANES_EFFECTIVE_CAPABILITIES=3072$/NATIVE_PAYMENT_LANES_EFFECTIVE_CAPABILITIES=2048/' \
  "$depth2_explicit_marker" > "$depth2_wrong_capability_marker"
! native_payment_lanes_existing_genesis_marker_is_valid "$depth2_wrong_capability_marker" 2

depth1_wrong_count_marker=$test_dir/depth1-wrong-count.env
write_existing_genesis_marker "$depth1_wrong_count_marker" 1 'NATIVE_PAYMENT_LANE_COUNT=4'
! native_payment_lanes_existing_genesis_marker_is_valid "$depth1_wrong_count_marker" 1

depth2_duplicate_enabled_marker=$test_dir/depth2-duplicate-enabled.env
cp "$depth2_explicit_marker" "$depth2_duplicate_enabled_marker"
printf '%s\n' 'NATIVE_PAYMENT_LANES_ENABLED=1' >> "$depth2_duplicate_enabled_marker"
! native_payment_lanes_existing_genesis_marker_is_valid "$depth2_duplicate_enabled_marker" 2

depth2_duplicate_count_marker=$test_dir/depth2-duplicate-count.env
write_existing_genesis_marker "$depth2_duplicate_count_marker" 2 \
  'NATIVE_PAYMENT_LANE_COUNT=4' 'NATIVE_PAYMENT_LANE_COUNT=4'
! native_payment_lanes_existing_genesis_marker_is_valid "$depth2_duplicate_count_marker" 2

for env_file in .env .env.desktop .env.devnet .env.laptop .env.physical; do
  grep -qx 'NATIVE_PAYMENT_LANES_ENABLED=0' "$repo_dir/$env_file"
  grep -qx 'NATIVE_PAYMENT_LANES_GLOBAL_VERSION=16' "$repo_dir/$env_file"
  grep -qx 'NATIVE_PAYMENT_LANES_CAPABILITY=2048' "$repo_dir/$env_file"
  grep -qx 'NATIVE_PAYMENT_LANE_DEPTH=1' "$repo_dir/$env_file"
  grep -qx 'NATIVE_PAYMENT_LANE_WALLET_RETRIES=128' "$repo_dir/$env_file"
  grep -qx 'NATIVE_PAYMENT_LANE_WALLET_PARALLELISM=1' "$repo_dir/$env_file"
  grep -qx 'NATIVE_LOAD_PAYMENT_LANE_DEPTH=0' "$repo_dir/$env_file"
done

grep -qx 'TON_NATIVE_CHECKPOINT_RETAIN_INGRESS=1' "$repo_dir/.env.physical"
[[ $(grep -Fc \
  'TON_NATIVE_CHECKPOINT_RETAIN_INGRESS=${TON_NATIVE_CHECKPOINT_RETAIN_INGRESS:-0}' \
  "$repo_dir/docker-compose.yaml") -eq 6 ]]
grep -qx 'TON_NATIVE_POST_COMMIT_PACK_GRACE_20MS=0' "$repo_dir/.env.physical"
[[ $(grep -Fc \
  'TON_NATIVE_POST_COMMIT_PACK_GRACE_20MS=${TON_NATIVE_POST_COMMIT_PACK_GRACE_20MS:-0}' \
  "$repo_dir/docker-compose.yaml") -eq 6 ]]
for env_file in .env .env.desktop .env.devnet .env.laptop; do
  ! grep -q '^TON_NATIVE_POST_COMMIT_PACK_GRACE_20MS=' "$repo_dir/$env_file"
done

grep -Fqx 'VERSION_CAPABILITIES capCreateStats capBounceMsgBody or capReportVersion or capShortDequeue or 64 or 128 or NATIVE_PROTOCOL_CAPABILITIES or config.version!' \
  "$repo_dir/docker/scripts/gen-zerostate.fif"
grep -Fq 'native payment lanes require ACTUAL_MIN_SPLIT, MIN_SPLIT, and MAX_SPLIT' \
  "$repo_dir/docker/scripts/native-payment-lanes-config.sh"
for field in \
  NATIVE_TRANSFER_RUNS_ENABLED \
  NATIVE_PAYMENT_LANES_EFFECTIVE_VERSION \
  NATIVE_PAYMENT_LANES_EFFECTIVE_CAPABILITIES \
  NATIVE_PAYMENT_LANE_COUNT \
  NATIVE_PAYMENT_LANE_ACTUAL_MIN_SPLIT \
  NATIVE_PAYMENT_LANE_MIN_SPLIT \
  NATIVE_PAYMENT_LANE_MAX_SPLIT; do
  grep -Fq "$field" "$repo_dir/docker/scripts/start-genesis.sh"
done
grep -Fq 'native_payment_lanes_existing_genesis_marker_is_valid' \
  "$repo_dir/docker/scripts/start-genesis.sh"
grep -Fq 'native_payment_lanes_wait_for_shards' "$repo_dir/native-load-generator/entrypoint.sh"
grep -Fq -- '--native-payment-lane-depth' "$repo_dir/native-load-generator/entrypoint.sh"
grep -Fq 'native-payment-lanes-config.sh' "$repo_dir/Dockerfile"
grep -Fq 'native-payment-lane-wallets.sh' "$repo_dir/Dockerfile"
grep -Fq 'payment-lanes.sh' "$repo_dir/native-load-generator/Dockerfile"
grep -Fq 'native-payment-lanes-profile.sh' "$repo_dir/benchmark/run-native-payment-lanes-cycle.sh"
grep -Fq 'NATIVE_LOAD_TARGET_TPS=4000' "$repo_dir/benchmark/run-native-payment-lanes-cycle.sh"
grep -Fq 'canonical_lane_balance.valid == true' "$repo_dir/benchmark/run-native-payment-lanes-cycle.sh"
grep -Fq 'chain_capacity_valid == true' "$repo_dir/benchmark/run-native-payment-lanes-cycle.sh"
grep -Fq 'BENCHMARK_STRICT_GENESIS_REUSE=1' "$repo_dir/benchmark/run-native-payment-lanes-staircase.sh"
grep -Fq 'BENCHMARK_RECREATE_GENESIS=0' "$repo_dir/benchmark/run-native-payment-lanes-staircase.sh"
grep -Fq 'require_matching_accepted_baseline' "$repo_dir/benchmark/run-native-payment-lanes-staircase.sh"
grep -Fq 'genesis_image_id' "$repo_dir/benchmark/run-native-payment-lanes-staircase.sh"
grep -Fq 'chain_capacity_valid == true' "$repo_dir/benchmark/run-native-payment-lanes-staircase.sh"
grep -Fq '.run.git_revision == $harness_revision' "$repo_dir/benchmark/run-native-payment-lanes-staircase.sh"
grep -Fq 'canonical_lane_balance.valid == true' "$repo_dir/benchmark/run-native-payment-lanes-staircase.sh"
grep -Fq 'strict_genesis_reuse_preflight' "$repo_dir/run-native-benchmark.sh"
grep -Fq 'strict_genesis_reuse_can_skip_genesis_build' "$repo_dir/run-native-benchmark.sh"
grep -Fq 'container_image_metadata_fallback' "$repo_dir/run-native-benchmark.sh"
grep -Fq 'desired_genesis_hash=' "$repo_dir/run-native-benchmark.sh"
grep -Fq 'BENCHMARK_RECREATE_GENESIS=0' "$repo_dir/benchmark/run-fresh-native-cycle.sh"

profile_environment=$(native_payment_lanes_profile_env env)
grep -qx 'NATIVE_PAYMENT_LANES_ENABLED=1' <<< "$profile_environment"
grep -qx 'NATIVE_PAYMENT_LANE_DEPTH=1' <<< "$profile_environment"
grep -qx 'NATIVE_TRANSFER_RUNS_ENABLED=1' <<< "$profile_environment"
grep -qx 'ACTUAL_MIN_SPLIT=1' <<< "$profile_environment"
grep -qx 'MAX_SPLIT=1' <<< "$profile_environment"
grep -qx 'NATIVE_LOAD_PAYMENT_LANE_READY_TIMEOUT_SECONDS=360' <<< "$profile_environment"

profile_environment=$(native_payment_lanes_profile_env 2 env)
grep -qx 'NATIVE_PAYMENT_LANE_DEPTH=2' <<< "$profile_environment"
grep -qx 'NATIVE_LOAD_PAYMENT_LANE_DEPTH=2' <<< "$profile_environment"
grep -qx 'ACTUAL_MIN_SPLIT=2' <<< "$profile_environment"
grep -qx 'MIN_SPLIT=2' <<< "$profile_environment"
grep -qx 'MAX_SPLIT=2' <<< "$profile_environment"
grep -qx 'NATIVE_LOAD_PAYMENT_LANE_READY_TIMEOUT_SECONDS=900' <<< "$profile_environment"

profile_environment=$(native_payment_lanes_profile_env 2 \
  env NATIVE_LOAD_PAYMENT_LANE_READY_TIMEOUT_SECONDS=1200 env)
grep -qx 'NATIVE_LOAD_PAYMENT_LANE_READY_TIMEOUT_SECONDS=1200' <<< "$profile_environment"
! grep -qx 'NATIVE_LOAD_PAYMENT_LANE_READY_TIMEOUT_SECONDS=900' <<< "$profile_environment"
! native_payment_lanes_profile_env 0 env >/dev/null 2>&1
! native_payment_lanes_profile_env 3 env >/dev/null 2>&1

"$repo_dir/benchmark/run-native-payment-lanes-cycle.sh" --help >/dev/null
"$repo_dir/benchmark/run-native-payment-lanes-staircase.sh" --help >/dev/null
! "$repo_dir/benchmark/run-native-payment-lanes-cycle.sh" --depth 0 >/dev/null 2>&1
! "$repo_dir/benchmark/run-native-payment-lanes-staircase.sh" --depth 3 >/dev/null 2>&1
! "$repo_dir/benchmark/run-native-payment-lanes-cycle.sh" '' >/dev/null 2>&1
! "$repo_dir/benchmark/run-native-payment-lanes-staircase.sh" '' >/dev/null 2>&1
! "$repo_dir/benchmark/run-fresh-native-cycle.sh" '' >/dev/null 2>&1
! "$repo_dir/benchmark/run-fresh-native-cycle.sh" .env.physical '' >/dev/null 2>&1
mkdir -p "$test_dir/nonempty-result"
touch "$test_dir/nonempty-result/existing"
! "$repo_dir/benchmark/run-fresh-native-cycle.sh" .env.physical \
  "$test_dir/nonempty-result" >/dev/null 2>&1
grep -Fq 'result_dir=$(cd "$result_dir" && pwd)' \
  "$repo_dir/benchmark/run-fresh-native-cycle.sh"

bash -n "$repo_dir/docker/scripts/start-genesis.sh"
bash -n "$repo_dir/docker/scripts/native-payment-lanes-config.sh"
bash -n "$repo_dir/docker/scripts/native-payment-lane-wallets.sh"
bash -n "$repo_dir/benchmark/native-payment-lanes-profile.sh"
bash -n "$repo_dir/benchmark/run-native-payment-lanes-cycle.sh"
bash -n "$repo_dir/benchmark/run-native-payment-lanes-staircase.sh"
bash -n "$repo_dir/benchmark/run-fresh-native-cycle.sh"
"$repo_dir/run-native-benchmark.sh" --self-test-strict-genesis-reuse
"$repo_dir/run-native-benchmark.sh" --self-test-container-image-metadata-fallback
sh -n "$repo_dir/native-load-generator/entrypoint.sh"
sh -n "$repo_dir/native-load-generator/payment-lanes.sh"
