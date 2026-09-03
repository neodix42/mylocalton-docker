#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$script_dir/../.." && pwd)

# shellcheck source=../../docker/scripts/native-payment-lane-wallets.sh
source "$repo_dir/docker/scripts/native-payment-lane-wallets.sh"

genesis_log() {
  printf '[test] %s\n' "$*" >&2
}

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT HUP INT TERM
wallet_dir=$test_dir/wallets
mkdir -p "$wallet_dir" "$test_dir/bin" "$test_dir/attempts"

# The production Fift program is nondeterministic. This mock makes the first
# attempt land in the wrong lane and the second land in the requested lane,
# exercising rejection sampling and the concurrent source-set assembly.
printf '0\n' > "$test_dir/active"
printf '0\n' > "$test_dir/max-active"
touch "$test_dir/concurrency.lock"
export NATIVE_PAYMENT_LANE_TEST_ATTEMPT_DIR="$test_dir/attempts"
export NATIVE_PAYMENT_LANE_TEST_ACTIVE_FILE="$test_dir/active"
export NATIVE_PAYMENT_LANE_TEST_MAX_ACTIVE_FILE="$test_dir/max-active"
export NATIVE_PAYMENT_LANE_TEST_CONCURRENCY_LOCK="$test_dir/concurrency.lock"

fift() {
  local base=${!#}
  local expected_lane=${NATIVE_PAYMENT_LANE_EXPECTED_LANE:?}
  local attempt_key attempt_file attempt=0 lane active max_active

  attempt_key=$(printf '%s' "$base" | sha256sum | awk '{print $1}')
  attempt_file="$NATIVE_PAYMENT_LANE_TEST_ATTEMPT_DIR/$attempt_key"
  if [ -r "$attempt_file" ]; then
    attempt=$(<"$attempt_file")
  fi
  attempt=$((attempt + 1))
  printf '%s\n' "$attempt" > "$attempt_file"
  if [ "$attempt" -eq 1 ]; then
    lane=$((1 - expected_lane))
  else
    lane=$expected_lane
  fi

  {
    flock 9
    active=$(<"$NATIVE_PAYMENT_LANE_TEST_ACTIVE_FILE")
    active=$((active + 1))
    printf '%s\n' "$active" > "$NATIVE_PAYMENT_LANE_TEST_ACTIVE_FILE"
    max_active=$(<"$NATIVE_PAYMENT_LANE_TEST_MAX_ACTIVE_FILE")
    if [ "$active" -gt "$max_active" ]; then
      printf '%s\n' "$active" > "$NATIVE_PAYMENT_LANE_TEST_MAX_ACTIVE_FILE"
    fi
  } 9>"$NATIVE_PAYMENT_LANE_TEST_CONCURRENCY_LOCK"
  sleep 0.02
  {
    flock 9
    active=$(<"$NATIVE_PAYMENT_LANE_TEST_ACTIVE_FILE")
    printf '%s\n' "$((active - 1))" > "$NATIVE_PAYMENT_LANE_TEST_ACTIVE_FILE"
  } 9>"$NATIVE_PAYMENT_LANE_TEST_CONCURRENCY_LOCK"

  printf 'private-%s\n' "$base" > "$base.pk"
  printf 'public-%s\n' "$base" > "$base.pub"
  case "$lane" in
    0) printf '\001' > "$base.addr" ;;
    1) printf '\201' > "$base.addr" ;;
  esac
  dd if=/dev/zero bs=31 count=1 status=none >> "$base.addr"
}

native_payment_lane_wallet_parallelism_is_valid 1
native_payment_lane_wallet_parallelism_is_valid 32
! native_payment_lane_wallet_parallelism_is_valid 0
! native_payment_lane_wallet_parallelism_is_valid 33
! native_payment_lane_wallet_parallelism_is_valid invalid

prepare_native_payment_lane_wallet_sets_parallel "$wallet_dir" 8 2 4
result_dir=$NATIVE_PAYMENT_LANE_WALLET_RESULTS_DIR
test -d "$result_dir"

for index in $(seq 0 7); do
  expected_lane=$((index % 2))
  IFS=' ' read -r result_index result_lane source_result destination_result source_hex destination_hex extra \
    < "$result_dir/$index"
  [[ $result_index == "$index" ]]
  [[ $result_lane == "$expected_lane" ]]
  [[ $source_result == created && $destination_result == created && -z ${extra:-} ]]
  [[ $(native_payment_lane_for_address "$wallet_dir/source-$index.addr") == "$expected_lane" ]]
  [[ $(native_payment_lane_for_address "$wallet_dir/dest-$index.addr") == "$expected_lane" ]]
  [[ $source_hex == "$(native_payment_lane_address_hex "$wallet_dir/source-$index.addr")" ]]
  [[ $destination_hex == "$(native_payment_lane_address_hex "$wallet_dir/dest-$index.addr")" ]]
done
[[ $(<"$test_dir/max-active") -ge 2 ]]
rm -rf -- "$result_dir"

# A restart does not regenerate already-complete, lane-correct files; it only
# produces fresh staging rows, preserving the original safe reuse behavior.
prepare_native_payment_lane_wallet_sets_parallel "$wallet_dir" 8 2 4
result_dir=$NATIVE_PAYMENT_LANE_WALLET_RESULTS_DIR
for index in $(seq 0 7); do
  IFS=' ' read -r result_index result_lane source_result destination_result source_hex destination_hex extra \
    < "$result_dir/$index"
  [[ $result_index == "$index" && $source_result == reused && $destination_result == reused ]]
done
rm -rf -- "$result_dir"
