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
legacy_wallet_dir=$test_dir/legacy-wallets
wallet_dir=$test_dir/depth-2-wallets
eight_lane_wallet_dir=$test_dir/depth-3-wallets
mkdir -p "$legacy_wallet_dir" "$wallet_dir" "$eight_lane_wallet_dir" "$test_dir/bin" "$test_dir/attempts"

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
  local expected_depth=${NATIVE_PAYMENT_LANE_EXPECTED_DEPTH:?}
  local attempt_key attempt_file attempt=0 lane lane_count first_byte first_byte_octal
  local active max_active

  attempt_key=$(printf '%s' "$base" | sha256sum | awk '{print $1}')
  attempt_file="$NATIVE_PAYMENT_LANE_TEST_ATTEMPT_DIR/$attempt_key"
  if [ -r "$attempt_file" ]; then
    attempt=$(<"$attempt_file")
  fi
  attempt=$((attempt + 1))
  printf '%s\n' "$attempt" > "$attempt_file"
  lane_count=$((1 << expected_depth))
  if [ "$attempt" -eq 1 ]; then
    lane=$(((expected_lane + 1) % lane_count))
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
  first_byte=$(((lane << (8 - expected_depth)) + 1))
  printf -v first_byte_octal '%03o' "$first_byte"
  printf "\\$first_byte_octal" > "$base.addr"
  dd if=/dev/zero bs=31 count=1 status=none >> "$base.addr"
}

native_payment_lane_depth_is_valid 1
native_payment_lane_depth_is_valid 2
native_payment_lane_depth_is_valid 3
! native_payment_lane_depth_is_valid 0
! native_payment_lane_depth_is_valid 4
! native_payment_lane_depth_is_valid 03
! native_payment_lane_depth_is_valid invalid
[[ $(native_payment_lane_count) == 2 ]]
[[ $(native_payment_lane_count 1) == 2 ]]
[[ $(native_payment_lane_count 2) == 4 ]]
[[ $(native_payment_lane_count 3) == 8 ]]
! native_payment_lane_count 0 >/dev/null 2>&1
! native_payment_lane_count 4 >/dev/null 2>&1

# Every lower and upper depth-3 prefix boundary maps to the correct lane;
# corresponding depth-1/2 results remain backward compatible.
for first_byte in 0 31 32 63 64 95 96 127 128 159 160 191 192 223 224 255; do
  printf -v first_byte_octal '%03o' "$first_byte"
  printf "\\$first_byte_octal" > "$test_dir/boundary.addr"
  dd if=/dev/zero bs=31 count=1 status=none >> "$test_dir/boundary.addr"
  [[ $(native_payment_lane_for_address "$test_dir/boundary.addr" 1) == "$((first_byte / 128))" ]]
  [[ $(native_payment_lane_for_address "$test_dir/boundary.addr" 2) == "$((first_byte / 64))" ]]
  [[ $(native_payment_lane_for_address "$test_dir/boundary.addr" 3) == "$((first_byte / 32))" ]]
done
printf '\000' > "$test_dir/truncated.addr"
! native_payment_lane_for_address "$test_dir/truncated.addr" 3 >/dev/null 2>&1

native_payment_lane_wallet_parallelism_is_valid 1
native_payment_lane_wallet_parallelism_is_valid 32
! native_payment_lane_wallet_parallelism_is_valid 0
! native_payment_lane_wallet_parallelism_is_valid 33
! native_payment_lane_wallet_parallelism_is_valid invalid

# The historical four-argument API remains a depth-1 operation.
prepare_native_payment_lane_wallet_sets_parallel "$legacy_wallet_dir" 4 2 2
result_dir=$NATIVE_PAYMENT_LANE_WALLET_RESULTS_DIR
test -d "$result_dir"
for index in $(seq 0 3); do
  expected_lane=$((index % 2))
  IFS=' ' read -r result_index result_lane source_result destination_result source_hex destination_hex extra \
    < "$result_dir/$index"
  [[ $result_index == "$index" && $result_lane == "$expected_lane" ]]
  [[ $source_result == created && $destination_result == created && -z ${extra:-} ]]
  [[ $(native_payment_lane_for_address "$legacy_wallet_dir/source-$index.addr") == "$expected_lane" ]]
  [[ $(native_payment_lane_for_address "$legacy_wallet_dir/dest-$index.addr") == "$expected_lane" ]]
done
rm -rf -- "$result_dir"

# An appended depth selects four lanes. Source-index modulo four balances the
# set exactly, and the mock's first rejected address exercises every quadrant.
prepare_native_payment_lane_wallet_sets_parallel "$wallet_dir" 8 2 4 2
result_dir=$NATIVE_PAYMENT_LANE_WALLET_RESULTS_DIR
test -d "$result_dir"
for index in $(seq 0 7); do
  expected_lane=$((index % 4))
  IFS=' ' read -r result_index result_lane source_result destination_result source_hex destination_hex extra \
    < "$result_dir/$index"
  [[ $result_index == "$index" ]]
  [[ $result_lane == "$expected_lane" ]]
  [[ $source_result == created && $destination_result == created && -z ${extra:-} ]]
  [[ $(native_payment_lane_for_address "$wallet_dir/source-$index.addr" 2) == "$expected_lane" ]]
  [[ $(native_payment_lane_for_address "$wallet_dir/dest-$index.addr" 2) == "$expected_lane" ]]
  [[ $source_hex == "$(native_payment_lane_address_hex "$wallet_dir/source-$index.addr")" ]]
  [[ $destination_hex == "$(native_payment_lane_address_hex "$wallet_dir/dest-$index.addr")" ]]
  printf -v expected_first_byte '%02x' "$(((expected_lane << 6) + 1))"
  [[ $(xxd -p -l 1 "$wallet_dir/source-$index.addr") == "$expected_first_byte" ]]
  [[ $(xxd -p -l 1 "$wallet_dir/dest-$index.addr") == "$expected_first_byte" ]]
done
[[ $(<"$test_dir/max-active") -ge 2 ]]
rm -rf -- "$result_dir"

# Two complete source sets per lane cover all eight lanes through the real
# bounded preparation helper, including rejection sampling of each pair.
prepare_native_payment_lane_wallet_sets_parallel "$eight_lane_wallet_dir" 16 2 4 3
result_dir=$NATIVE_PAYMENT_LANE_WALLET_RESULTS_DIR
for index in $(seq 0 15); do
  expected_lane=$((index % 8))
  IFS=' ' read -r result_index result_lane source_result destination_result source_hex destination_hex extra \
    < "$result_dir/$index"
  [[ $result_index == "$index" && $result_lane == "$expected_lane" ]]
  [[ $source_result == created && $destination_result == created && -z ${extra:-} ]]
  [[ $(native_payment_lane_for_address "$eight_lane_wallet_dir/source-$index.addr" 3) == "$expected_lane" ]]
  [[ $(native_payment_lane_for_address "$eight_lane_wallet_dir/dest-$index.addr" 3) == "$expected_lane" ]]
  [[ $source_hex == "$(native_payment_lane_address_hex "$eight_lane_wallet_dir/source-$index.addr")" ]]
  [[ $destination_hex == "$(native_payment_lane_address_hex "$eight_lane_wallet_dir/dest-$index.addr")" ]]
done
rm -rf -- "$result_dir"

# Every newly created wallet rejected the deliberately wrong first attempt and
# accepted the second attempt in its requested depth-1/2/3 lane.
attempt_files_before_reuse=$(find "$test_dir/attempts" -type f | wc -l)
[[ $attempt_files_before_reuse -eq 56 ]]
while IFS= read -r attempt_file; do
  [[ $(<"$attempt_file") == 2 ]]
done < <(find "$test_dir/attempts" -type f -print)

# A restart does not regenerate already-complete, lane-correct files; it only
# produces fresh staging rows, preserving the original safe reuse behavior.
prepare_native_payment_lane_wallet_sets_parallel "$wallet_dir" 8 2 4 2
result_dir=$NATIVE_PAYMENT_LANE_WALLET_RESULTS_DIR
for index in $(seq 0 7); do
  IFS=' ' read -r result_index result_lane source_result destination_result source_hex destination_hex extra \
    < "$result_dir/$index"
  [[ $result_index == "$index" && $source_result == reused && $destination_result == reused ]]
done
rm -rf -- "$result_dir"
[[ $(find "$test_dir/attempts" -type f | wc -l) -eq $attempt_files_before_reuse ]]

prepare_native_payment_lane_wallet_sets_parallel "$eight_lane_wallet_dir" 16 2 4 3
result_dir=$NATIVE_PAYMENT_LANE_WALLET_RESULTS_DIR
for index in $(seq 0 15); do
  IFS=' ' read -r result_index result_lane source_result destination_result source_hex destination_hex extra \
    < "$result_dir/$index"
  [[ $result_index == "$index" && $result_lane == "$((index % 8))" ]]
  [[ $source_result == reused && $destination_result == reused ]]
done
rm -rf -- "$result_dir"
[[ $(find "$test_dir/attempts" -type f | wc -l) -eq $attempt_files_before_reuse ]]

# A complete depth-2 source in lane one has prefix 0x41 (depth-3 lane two).
# Reusing it as the depth-3 lane-one source must fail without touching any file.
old_wallet_hashes=$(sha256sum "$wallet_dir/source-1.pk" "$wallet_dir/source-1.pub" "$wallet_dir/source-1.addr")
! prepare_native_payment_lane_wallet "$wallet_dir/source-1" 1 2 3 >/dev/null 2>&1
[[ $(sha256sum "$wallet_dir/source-1.pk" "$wallet_dir/source-1.pub" "$wallet_dir/source-1.addr") == "$old_wallet_hashes" ]]

# Exhaustion cleans only staging material; no incomplete final wallet survives.
! create_native_payment_lane_wallet "$eight_lane_wallet_dir/exhausted" 7 1 3 >/dev/null 2>&1
[[ ! -e $eight_lane_wallet_dir/exhausted.pk && ! -e $eight_lane_wallet_dir/exhausted.pub && ! -e $eight_lane_wallet_dir/exhausted.addr ]]

# Complete wallets in another depth-2 quadrant and partial wallet files fail
# closed without being overwritten or completed.
source_zero_before=$(sha256sum "$wallet_dir/source-0.addr")
! prepare_native_payment_lane_wallet "$wallet_dir/source-0" 1 2 2 >/dev/null 2>&1
[[ $(sha256sum "$wallet_dir/source-0.addr") == "$source_zero_before" ]]

partial_base=$wallet_dir/partial
printf 'retain-me\n' > "$partial_base.pk"
! prepare_native_payment_lane_wallet "$partial_base" 0 2 2 >/dev/null 2>&1
grep -qx 'retain-me' "$partial_base.pk"
[[ ! -e $partial_base.pub && ! -e $partial_base.addr ]]

! native_payment_lane_for_address "$wallet_dir/source-0.addr" 0 >/dev/null 2>&1
! native_payment_lane_for_address "$wallet_dir/source-0.addr" 4 >/dev/null 2>&1
! prepare_native_payment_lane_wallet_sets_parallel "$wallet_dir" 1 2 1 4 >/dev/null 2>&1
