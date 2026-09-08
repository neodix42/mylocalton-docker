#!/usr/bin/env bash

# Wallet preparation helpers for the fixed-depth native payment-lane profile.
# A source set is always generated and recorded as one unit: its source and
# destination have the same fixed-depth lane prefix, while source-index modulo
# the lane count keeps every supported topology balanced.  Workers only create
# independent wallet files.  The caller remains responsible for serializing
# the base-state Fift script and the manifest after every worker succeeds.

NATIVE_PAYMENT_LANE_WALLET_RESULTS_DIR=

native_payment_lane_address_hex() {
  local address_file=$1
  local address_hex

  test -r "$address_file" || return 1
  address_hex=$(xxd -p -l 32 -c 32 "$address_file")
  [[ ${#address_hex} -eq 64 && $address_hex =~ ^[0-9A-Fa-f]+$ ]] || return 1
  printf '%s\n' "$address_hex"
}

native_payment_lane_depth_is_valid() {
  [[ ${1:-} == 1 || ${1:-} == 2 || ${1:-} == 3 ]]
}

native_payment_lane_count() {
  local depth=${1:-1}

  native_payment_lane_depth_is_valid "$depth" || return 2
  printf '%s\n' "$((1 << depth))"
}

# The benchmark harness supports two, four, or eight fixed leaves. The lane
# is selected by the corresponding high account-id bits; textual user-friendly
# address encodings are never used for shard placement.
native_payment_lane_for_address() {
  local address_file=$1 depth=${2:-1}
  local address_hex

  native_payment_lane_depth_is_valid "$depth" || return 2
  address_hex=$(native_payment_lane_address_hex "$address_file") || return 1
  printf '%s\n' "$((16#${address_hex:0:2} >> (8 - depth)))"
}

native_payment_lane_wallet_state() {
  local base=$1
  local file_count=0
  local suffix

  for suffix in pk pub addr; do
    if [ -e "$base.$suffix" ]; then
      file_count=$((file_count + 1))
    fi
  done
  case "$file_count" in
    0) printf 'absent\n' ;;
    3) printf 'complete\n' ;;
    *) printf 'partial\n' ;;
  esac
}

native_payment_lane_wallet_parallelism_is_valid() {
  [[ $1 =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 32 ))
}

create_native_payment_lane_wallet() {
  local base=$1 expected_lane=$2 retries=$3
  local depth=${4:-1}
  local wallet_dir temp_dir temp_base attempt lane lane_count

  lane_count=$(native_payment_lane_count "$depth") || {
    genesis_log "Native payment lane depth must be 1, 2, or 3, got '$depth'"
    return 2
  }
  if ! [[ $expected_lane =~ ^[0-9]+$ ]] || ((10#$expected_lane >= lane_count)); then
    genesis_log "Native payment lane must be in [0,$((lane_count - 1))], got '$expected_lane'"
    return 2
  fi

  wallet_dir=$(dirname "$base")
  temp_dir=$(mktemp -d "$wallet_dir/.native-payment-lane.XXXXXX") || return 1
  temp_base="$temp_dir/wallet"
  for ((attempt = 1; attempt <= retries; ++attempt)); do
    if ! NATIVE_PAYMENT_LANE_EXPECTED_LANE="$expected_lane" \
      NATIVE_PAYMENT_LANE_EXPECTED_DEPTH="$depth" \
      fift -s /usr/share/ton/smartcont/new-native-wallet.fif 0 "$temp_base" > "$temp_dir/create.log" 2>&1; then
      genesis_log "Can't create native payment lane wallet; last log lines follow"
      tail -n 20 "$temp_dir/create.log" >&2
      rm -rf -- "$temp_dir"
      return 1
    fi
    lane=$(native_payment_lane_for_address "$temp_base.addr" "$depth") || {
      genesis_log "Native payment lane wallet generator produced an invalid address"
      rm -rf -- "$temp_dir"
      return 1
    }
    if [ "$lane" = "$expected_lane" ]; then
      mv "$temp_base.pk" "$base.pk"
      mv "$temp_base.pub" "$base.pub"
      mv "$temp_base.addr" "$base.addr"
      mv "$temp_dir/create.log" "$base.create.log"
      rmdir "$temp_dir"
      printf 'created\n'
      return 0
    fi
    rm -f -- "$temp_base.pk" "$temp_base.pub" "$temp_base.addr" "$temp_dir/create.log"
  done
  rm -rf -- "$temp_dir"
  genesis_log "Unable to generate lane $expected_lane wallet after $retries attempts"
  return 1
}

prepare_native_payment_lane_wallet() {
  local base=$1 expected_lane=$2 retries=$3
  local depth=${4:-1}
  local state lane

  state=$(native_payment_lane_wallet_state "$base")
  case "$state" in
    absent)
      create_native_payment_lane_wallet "$base" "$expected_lane" "$retries" "$depth"
      ;;
    complete)
      lane=$(native_payment_lane_for_address "$base.addr" "$depth") || {
        genesis_log "Existing native payment lane wallet has an invalid address: $base.addr"
        return 1
      }
      if [ "$lane" != "$expected_lane" ]; then
        genesis_log "Existing native payment lane wallet is assigned to lane $lane, expected $expected_lane: $base.addr"
        return 1
      fi
      printf 'reused\n'
      ;;
    *)
      genesis_log "Refusing to overwrite a partial native payment lane wallet: $base"
      return 1
      ;;
  esac
}

# This function is invoked in a background subshell by the bounded pool below.
# It publishes one row only after both wallet files have been successfully
# generated and checked, so a caller never serializes a half-complete pair.
prepare_native_payment_lane_wallet_set() {
  local wallet_dir=$1 index=$2 retries=$3 result_dir=$4
  local depth=${5:-1}
  local lane_count expected_lane
  local source_base="$wallet_dir/source-$index"
  local destination_base="$wallet_dir/dest-$index"
  local source_result destination_result source_address_hex destination_address_hex
  local result_file="$result_dir/$index"
  local result_tmp="$result_file.tmp.$$"

  lane_count=$(native_payment_lane_count "$depth") || {
    genesis_log "Native payment lane depth must be 1, 2, or 3, got '$depth'"
    return 2
  }
  expected_lane=$((index % lane_count))
  source_result=$(prepare_native_payment_lane_wallet "$source_base" "$expected_lane" "$retries" "$depth") || return 1
  destination_result=$(prepare_native_payment_lane_wallet "$destination_base" "$expected_lane" "$retries" "$depth") || return 1
  source_address_hex=$(native_payment_lane_address_hex "$source_base.addr") || return 1
  destination_address_hex=$(native_payment_lane_address_hex "$destination_base.addr") || return 1
  case "$source_result:$destination_result" in
    created:created|created:reused|reused:created|reused:reused) ;;
    *)
      genesis_log "Native payment lane wallet worker returned an invalid result for source set $index"
      return 1
      ;;
  esac

  printf '%s %s %s %s %s %s\n' \
    "$index" "$expected_lane" "$source_result" "$destination_result" \
    "$source_address_hex" "$destination_address_hex" > "$result_tmp" || return 1
  mv -f -- "$result_tmp" "$result_file"
}

# Generate independent source/destination wallet sets concurrently, with a
# hard upper bound that prevents a malformed environment from forking an
# unbounded number of Fift processes.  Result rows are intentionally left in
# a private staging directory for the caller to read in source-index order.
prepare_native_payment_lane_wallet_sets_parallel() {
  local wallet_dir=$1 source_count=$2 retries=$3 parallelism=$4
  local depth=${5:-1}
  local result_dir index active_workers=0 worker_failed=0

  NATIVE_PAYMENT_LANE_WALLET_RESULTS_DIR=
  if ! native_payment_lane_depth_is_valid "$depth"; then
    genesis_log "Native payment lane depth must be 1, 2, or 3, got '$depth'"
    return 2
  fi
  if ! native_payment_lane_wallet_parallelism_is_valid "$parallelism"; then
    genesis_log "NATIVE_PAYMENT_LANE_WALLET_PARALLELISM must be an integer from 1 through 32, got '$parallelism'"
    return 2
  fi
  result_dir=$(mktemp -d "$wallet_dir/.native-payment-lane-workers.XXXXXX") || return 1

  for ((index = 0; index < source_count; ++index)); do
    prepare_native_payment_lane_wallet_set "$wallet_dir" "$index" "$retries" "$result_dir" "$depth" &
    active_workers=$((active_workers + 1))
    if ((active_workers >= parallelism)); then
      if ! wait -n; then
        worker_failed=1
        active_workers=$((active_workers - 1))
        break
      fi
      active_workers=$((active_workers - 1))
    fi
  done

  while ((active_workers > 0)); do
    if ! wait -n; then
      worker_failed=1
    fi
    active_workers=$((active_workers - 1))
  done

  if ((worker_failed)); then
    rm -rf -- "$result_dir"
    return 1
  fi
  NATIVE_PAYMENT_LANE_WALLET_RESULTS_DIR=$result_dir
}
