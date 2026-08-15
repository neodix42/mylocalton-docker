#!/bin/bash
set -euo pipefail

NATIVE_SPAM_SOURCES=${NATIVE_SPAM_SOURCES:-64}
NATIVE_SPAM_DURATION_SECONDS=${NATIVE_SPAM_DURATION_SECONDS:-60}
NATIVE_SPAM_ROUNDS=${NATIVE_SPAM_ROUNDS:-0}
NATIVE_SPAM_AMOUNT=${NATIVE_SPAM_AMOUNT:-0.000000001}
NATIVE_SPAM_FEE=${NATIVE_SPAM_FEE:-0}
NATIVE_SPAM_TOPUP_AMOUNT=${NATIVE_SPAM_TOPUP_AMOUNT:-1}
NATIVE_SPAM_PARALLELISM=${NATIVE_SPAM_PARALLELISM:-32}
NATIVE_SPAM_TRANSFER_TIMEOUT_SECONDS=${NATIVE_SPAM_TRANSFER_TIMEOUT_SECONDS:-120}
NATIVE_SPAM_CONFIRM_TIMEOUT_SECONDS=${NATIVE_SPAM_CONFIRM_TIMEOUT_SECONDS:-30}
NATIVE_SPAM_TOPUP_TIMEOUT_SECONDS=${NATIVE_SPAM_TOPUP_TIMEOUT_SECONDS:-180}
NATIVE_SPAM_FORCE_TOPUP=${NATIVE_SPAM_FORCE_TOPUP:-0}
NATIVE_SPAM_TOPUP_MODE=${NATIVE_SPAM_TOPUP_MODE:-genesis}
NATIVE_SPAM_REQUESTED_SOURCES=${NATIVE_SPAM_REQUESTED_SOURCES:-$NATIVE_SPAM_SOURCES}
NATIVE_SPAM_GENESIS_SOURCES=${NATIVE_SPAM_GENESIS_SOURCES:-0}
NATIVE_SPAM_GENESIS_DESTINATIONS=${NATIVE_SPAM_GENESIS_DESTINATIONS:-0}
NATIVE_SPAM_WORK_DIR=${NATIVE_SPAM_WORK_DIR:-/var/ton-work/db/native-spam}
NATIVE_SPAM_WALLET_DIR=${NATIVE_SPAM_WALLET_DIR:-$NATIVE_SPAM_WORK_DIR/wallets}
NATIVE_SPAM_LOCK_TIMEOUT_SECONDS=${NATIVE_SPAM_LOCK_TIMEOUT_SECONDS:-300}
NATIVE_SPAM_LITESERVER_ADDR=${NATIVE_SPAM_LITESERVER_ADDR:-127.0.0.1:40004}
NATIVE_SPAM_LITE_TIMEOUT_SECONDS=${NATIVE_SPAM_LITE_TIMEOUT_SECONDS:-10}
NATIVE_SPAM_MODE=${NATIVE_SPAM_MODE:-pipeline}
NATIVE_SPAM_KEEP_ARTIFACTS=${NATIVE_SPAM_KEEP_ARTIFACTS:-0}
NATIVE_SPAM_TMP_DIR=${NATIVE_SPAM_TMP_DIR:-/dev/shm/native-spam}
NATIVE_SPAM_CONFIRM_PARALLELISM=${NATIVE_SPAM_CONFIRM_PARALLELISM:-$NATIVE_SPAM_PARALLELISM}
NATIVE_SPAM_CONFIRM_POLL_SECONDS=${NATIVE_SPAM_CONFIRM_POLL_SECONDS:-0.2}
NATIVE_SPAM_PROGRESS_INTERVAL_SECONDS=${NATIVE_SPAM_PROGRESS_INTERVAL_SECONDS:-5}

export FIFTPATH=/usr/lib/fift:/usr/share/ton/smartcont:/scripts

LITE_CLIENT=/usr/local/bin/lite-client
FIFT=/usr/local/bin/fift
LITESERVER_PUB=/var/ton-work/db/liteserver.pub
MAIN_WALLET_BASE=/var/ton-work/db/main-wallet
MASTER_SUBWALLET_ID=42

validate_uint_range() {
  local name=$1
  local value=$2
  local min=$3
  local max=$4

  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "$name must be an integer, got '$value'" >&2
    exit 2
  fi
  if (( value < min || value > max )); then
    echo "$name must be between $min and $max, got '$value'" >&2
    exit 2
  fi
}

validate_bool() {
  local name=$1
  local value=$2

  if [[ "$value" != "0" && "$value" != "1" ]]; then
    echo "$name must be 0 or 1, got '$value'" >&2
    exit 2
  fi
}

validate_positive_decimal() {
  local name=$1
  local value=$2

  if [[ ! "$value" =~ ^([0-9]+)(\.[0-9]+)?$ ]]; then
    echo "$name must be a positive decimal number, got '$value'" >&2
    exit 2
  fi
  if ! awk -v value="$value" 'BEGIN { exit !(value > 0) }'; then
    echo "$name must be greater than zero, got '$value'" >&2
    exit 2
  fi
}

validate_mode() {
  local value=$1

  if [[ "$value" != "pipeline" && "$value" != "round" ]]; then
    echo "NATIVE_SPAM_MODE must be 'pipeline' or 'round', got '$value'" >&2
    exit 2
  fi
}

validate_topup_mode() {
  local value=$1

  if [[ "$value" != "genesis" && "$value" != "native" && "$value" != "wallet" ]]; then
    echo "NATIVE_SPAM_TOPUP_MODE must be 'genesis', 'native', or 'wallet', got '$value'" >&2
    exit 2
  fi
}

validate_uint_range NATIVE_SPAM_SOURCES "$NATIVE_SPAM_SOURCES" 1 100000
validate_uint_range NATIVE_SPAM_DURATION_SECONDS "$NATIVE_SPAM_DURATION_SECONDS" 1 31536000
validate_uint_range NATIVE_SPAM_ROUNDS "$NATIVE_SPAM_ROUNDS" 0 4294967295
validate_uint_range NATIVE_SPAM_PARALLELISM "$NATIVE_SPAM_PARALLELISM" 1 100000
validate_uint_range NATIVE_SPAM_TRANSFER_TIMEOUT_SECONDS "$NATIVE_SPAM_TRANSFER_TIMEOUT_SECONDS" 1 3600
validate_uint_range NATIVE_SPAM_CONFIRM_TIMEOUT_SECONDS "$NATIVE_SPAM_CONFIRM_TIMEOUT_SECONDS" 1 3600
validate_uint_range NATIVE_SPAM_TOPUP_TIMEOUT_SECONDS "$NATIVE_SPAM_TOPUP_TIMEOUT_SECONDS" 1 3600
validate_uint_range NATIVE_SPAM_LOCK_TIMEOUT_SECONDS "$NATIVE_SPAM_LOCK_TIMEOUT_SECONDS" 1 3600
validate_uint_range NATIVE_SPAM_LITE_TIMEOUT_SECONDS "$NATIVE_SPAM_LITE_TIMEOUT_SECONDS" 1 3600
validate_uint_range NATIVE_SPAM_CONFIRM_PARALLELISM "$NATIVE_SPAM_CONFIRM_PARALLELISM" 1 100000
validate_uint_range NATIVE_SPAM_PROGRESS_INTERVAL_SECONDS "$NATIVE_SPAM_PROGRESS_INTERVAL_SECONDS" 1 3600
validate_uint_range NATIVE_SPAM_GENESIS_SOURCES "$NATIVE_SPAM_GENESIS_SOURCES" 0 100000
validate_bool NATIVE_SPAM_GENESIS_DESTINATIONS "$NATIVE_SPAM_GENESIS_DESTINATIONS"
validate_bool NATIVE_SPAM_FORCE_TOPUP "$NATIVE_SPAM_FORCE_TOPUP"
validate_bool NATIVE_SPAM_KEEP_ARTIFACTS "$NATIVE_SPAM_KEEP_ARTIFACTS"
validate_positive_decimal NATIVE_SPAM_CONFIRM_POLL_SECONDS "$NATIVE_SPAM_CONFIRM_POLL_SECONDS"
validate_mode "$NATIVE_SPAM_MODE"
validate_topup_mode "$NATIVE_SPAM_TOPUP_MODE"

run_lite_client() {
  "$LITE_CLIENT" -a "$NATIVE_SPAM_LITESERVER_ADDR" -p "$LITESERVER_PUB" -t "$NATIVE_SPAM_LITE_TIMEOUT_SECONDS" -c "$1"
}

send_boc_file() {
  local boc_file=$1
  local log_file=$2
  local output

  output=$(run_lite_client "sendfile $boc_file" 2>&1)
  if [[ "$log_file" != "/dev/null" ]]; then
    printf '%s\n' "$output" > "$log_file"
  fi
  printf '%s\n' "$output" | grep -q "external message status is 1"
}

load_genesis_spam_env() {
  local env_file="$NATIVE_SPAM_WORK_DIR/genesis.env"

  if [ -f "$env_file" ]; then
    # This file is generated by start-genesis.sh and contains simple KEY=value pairs.
    . "$env_file"
  fi
  NATIVE_SPAM_REQUESTED_SOURCES=${NATIVE_SPAM_REQUESTED_SOURCES:-$NATIVE_SPAM_SOURCES}
  NATIVE_SPAM_GENESIS_SOURCES=${NATIVE_SPAM_GENESIS_SOURCES:-0}
  NATIVE_SPAM_GENESIS_DESTINATIONS=${NATIVE_SPAM_GENESIS_DESTINATIONS:-0}
  validate_uint_range NATIVE_SPAM_SOURCES "$NATIVE_SPAM_SOURCES" 1 100000
  validate_uint_range NATIVE_SPAM_REQUESTED_SOURCES "$NATIVE_SPAM_REQUESTED_SOURCES" 1 100000
  validate_uint_range NATIVE_SPAM_GENESIS_SOURCES "$NATIVE_SPAM_GENESIS_SOURCES" 0 100000
  validate_bool NATIVE_SPAM_GENESIS_DESTINATIONS "$NATIVE_SPAM_GENESIS_DESTINATIONS"
  validate_topup_mode "$NATIVE_SPAM_TOPUP_MODE"
}

get_account_state() {
  run_lite_client "getaccount $1" 2>&1 || true
}

account_is_present() {
  printf '%s\n' "$1" | grep -q "account state is (account"
}

extract_seqno() {
  sed -n 's/.*result:[[:space:]]*\[[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -n1
}

extract_last_lt() {
  sed -n 's/.*last transaction lt = \([0-9][0-9]*\).*/\1/p' | tail -n1
}

read_wallet_seqno() {
  local addr=$1
  local output
  local seqno

  output=$(run_lite_client "runmethod $addr seqno" 2>&1)
  seqno=$(printf '%s\n' "$output" | extract_seqno)
  if [ -z "$seqno" ]; then
    printf '%s\n' "$output" >&2
    return 1
  fi

  printf '%s\n' "$seqno"
}

read_native_nonce() {
  local addr=$1
  local output
  local nonce

  output=$(get_account_state "$addr")
  if ! account_is_present "$output"; then
    printf '%s\n' "$output" >&2
    return 1
  fi

  nonce=$(printf '%s\n' "$output" | extract_last_lt)
  if [ -z "$nonce" ]; then
    printf '%s\n' "$output" >&2
    return 1
  fi

  printf '%s\n' "$nonce"
}

wait_for_wallet_seqno_advance() {
  local addr=$1
  local previous_seqno=$2
  local timeout_seconds=$3
  local deadline
  local current_seqno

  deadline=$(($(date +%s) + timeout_seconds))
  while true; do
    current_seqno=$(read_wallet_seqno "$addr" 2>/dev/null || true)
    if [[ "$current_seqno" =~ ^[0-9]+$ ]] && (( current_seqno > previous_seqno )); then
      return 0
    fi
    if (( $(date +%s) >= deadline )); then
      echo "Master wallet seqno did not advance within ${timeout_seconds}s" >&2
      return 1
    fi
    sleep 2
  done
}

wait_for_native_nonce_advance() {
  local addr=$1
  local previous_nonce=$2
  local timeout_seconds=$3
  local deadline
  local current_nonce

  deadline=$(($(date +%s) + timeout_seconds))
  while true; do
    current_nonce=$(read_native_nonce "$addr" 2>/dev/null || true)
    if [[ "$current_nonce" =~ ^[0-9]+$ ]] && (( current_nonce > previous_nonce )); then
      printf '%s\n' "$current_nonce"
      return 0
    fi
    if (( $(date +%s) >= deadline )); then
      return 1
    fi
    sleep 1
  done
}

address_from_file() {
  local wc=$1
  local file=$2
  local hex

  if [ ! -f "$file" ]; then
    echo "Address file is missing: $file" >&2
    return 1
  fi
  hex=$(xxd -p -l 32 -c 32 "$file" | head -n1 | tr '[:lower:]' '[:upper:]')
  if [ "${#hex}" -ne 64 ]; then
    echo "Address file $file does not contain a 256-bit account id" >&2
    return 1
  fi
  printf '%s:%s\n' "$wc" "$hex"
}

cleanup_spam_lock() {
  if [ -n "${NATIVE_SPAM_LOCK_DIR:-}" ] && [ -d "$NATIVE_SPAM_LOCK_DIR" ]; then
    rm -f "$NATIVE_SPAM_LOCK_DIR/pid"
    rmdir "$NATIVE_SPAM_LOCK_DIR" 2>/dev/null || true
  fi
  if [[ "${NATIVE_SPAM_KEEP_ARTIFACTS:-1}" == "0" && -n "${QUERY_DIR:-}" && -d "$QUERY_DIR" ]]; then
    rm -rf "$QUERY_DIR"
  fi
}

release_spam_lock() {
  cleanup_spam_lock
  trap - EXIT
  unset NATIVE_SPAM_LOCK_DIR
  echo "Native spam launch lock released"
}

acquire_spam_lock() {
  local lock_dir="$NATIVE_SPAM_WORK_DIR/run.lock"
  local deadline
  local lock_pid
  local printed_waiting=0

  mkdir -p "$NATIVE_SPAM_WORK_DIR"
  deadline=$(($(date +%s) + NATIVE_SPAM_LOCK_TIMEOUT_SECONDS))
  while ! mkdir "$lock_dir" 2>/dev/null; do
    if [ "$printed_waiting" -eq 0 ]; then
      echo "Waiting for native spam launch lock..."
      printed_waiting=1
    fi

    if [ -f "$lock_dir/pid" ]; then
      lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
      if [[ "$lock_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
        rm -f "$lock_dir/pid"
        rmdir "$lock_dir" 2>/dev/null || true
        continue
      fi
    else
      rmdir "$lock_dir" 2>/dev/null && continue
    fi

    if (( $(date +%s) >= deadline )); then
      echo "Timed out waiting for native spam launch lock" >&2
      exit 6
    fi
    sleep 1
  done

  NATIVE_SPAM_LOCK_DIR=$lock_dir
  echo "$$" > "$NATIVE_SPAM_LOCK_DIR/pid"
  trap cleanup_spam_lock EXIT
  echo "Native spam launch lock acquired"
}

throttle_background_jobs() {
  while (( $(jobs -rp | wc -l) >= NATIVE_SPAM_PARALLELISM )); do
    sleep 0.05
  done
}

ensure_native_wallet() {
  local base=$1

  if [ -f "$base.pk" ] && [ -f "$base.addr" ]; then
    return 0
  fi

  "$FIFT" -s /usr/share/ton/smartcont/new-native-wallet.fif 0 "$base" > "$base.create.log" 2>&1
}

send_topup() {
  local source_base=$1
  local source_addr=$2
  local query_base=$3
  local old_nonce
  local master_seqno
  local fift_log="/dev/null"
  local send_log="/dev/null"

  old_nonce=$(read_native_nonce "$source_addr" 2>/dev/null || true)
  if [[ "$NATIVE_SPAM_FORCE_TOPUP" == "0" && "$old_nonce" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$old_nonce"
    return 0
  fi
  if [[ ! "$old_nonce" =~ ^[0-9]+$ ]]; then
    old_nonce=0
  fi

  if [[ "$NATIVE_SPAM_TOPUP_MODE" == "genesis" ]]; then
    echo "Native spam source $source_addr is not a funded native balance-only account." >&2
    echo "Recreate the genesis state with NATIVE_SPAM_RUN=1 or NATIVE_SPAM_GENESIS_SOURCES >= NATIVE_SPAM_SOURCES." >&2
    echo "Keep NATIVE_SPAM_FORCE_TOPUP=0 for genesis-funded native spam sources." >&2
    return 1
  fi

  master_seqno=$(read_wallet_seqno "$MASTER_ADDR")
  if [[ "$NATIVE_SPAM_KEEP_ARTIFACTS" == "1" ]]; then
    fift_log="$query_base.fift.log"
    send_log="$query_base.send.log"
  fi
  "$FIFT" -s /usr/share/ton/smartcont/wallet-v3.fif \
    "$MAIN_WALLET_BASE" "$source_addr" "$MASTER_SUBWALLET_ID" "$master_seqno" "$NATIVE_SPAM_TOPUP_AMOUNT" \
    -n -t 120 "$query_base" > "$fift_log" 2>&1

  if ! send_boc_file "$query_base.boc" "$send_log"; then
    echo "Native spam wallet-contract top-up was rejected for $source_addr." >&2
    echo "The native fast path expects funded balance-only source accounts in zerostate; set NATIVE_SPAM_TOPUP_MODE=genesis." >&2
    return 1
  fi
  if [[ "$NATIVE_SPAM_KEEP_ARTIFACTS" == "0" ]]; then
    rm -f "$query_base.boc"
  fi
  wait_for_wallet_seqno_advance "$MASTER_ADDR" "$master_seqno" "$NATIVE_SPAM_TOPUP_TIMEOUT_SECONDS"
  if ! wait_for_native_nonce_advance "$source_addr" "$old_nonce" "$NATIVE_SPAM_TOPUP_TIMEOUT_SECONDS"; then
    echo "Native spam source $source_addr was not created by wallet-contract top-up within ${NATIVE_SPAM_TOPUP_TIMEOUT_SECONDS}s." >&2
    return 1
  fi
}

send_native_transfer_query() {
  local source_base=$1
  local dest_addr=$2
  local nonce=$3
  local amount=$4
  local fee=$5
  local timeout=$6
  local query_base=$7
  local status_file=$8
  local fift_log="/dev/null"
  local send_log="/dev/null"

  rm -f "$status_file" "$query_base.boc"
  if [[ "$NATIVE_SPAM_KEEP_ARTIFACTS" == "1" ]]; then
    fift_log="$query_base.fift.log"
    send_log="$query_base.send.log"
  fi

  if "$FIFT" -s /usr/share/ton/smartcont/native-wallet.fif \
      "$source_base" "$dest_addr" "$nonce" "$amount" \
      -f "$fee" -t "$timeout" "$query_base" \
      > "$fift_log" 2>&1 &&
     send_boc_file "$query_base.boc" "$send_log"; then
    echo ok > "$status_file"
  else
    echo fail > "$status_file"
  fi
  if [[ "$NATIVE_SPAM_KEEP_ARTIFACTS" == "0" ]]; then
    rm -f "$query_base.boc"
  fi
}

send_native_transfer_artifact() {
  local idx=$1
  local nonce=$2
  local query_base=$3
  local status_file=$4

  send_native_transfer_query \
    "${SOURCE_BASES[$idx]}" "${DEST_ADDRS[$idx]}" "$nonce" "$NATIVE_SPAM_AMOUNT" \
    "$NATIVE_SPAM_FEE" "$NATIVE_SPAM_TRANSFER_TIMEOUT_SECONDS" "$query_base" "$status_file"
}

send_native_transfer() {
  local idx=$1
  local round=$2
  local nonce=$3
  local query_base="$QUERY_DIR/native-${round}-${idx}"
  local status_file="$RUN_DIR/send-${round}-${idx}.status"

  send_native_transfer_artifact "$idx" "$nonce" "$query_base" "$status_file"
}

send_native_topup_artifact() {
  local funder_idx=$1
  local target_idx=$2
  local nonce=$3
  local batch=$4
  local query_base="$QUERY_DIR/topup-${batch}-${funder_idx}-${target_idx}"
  local status_file="$RUN_DIR/topup-${batch}-${funder_idx}-${target_idx}.status"

  send_native_transfer_query \
    "${SOURCE_BASES[$funder_idx]}" "${SOURCE_ADDRS[$target_idx]}" "$nonce" "$NATIVE_SPAM_TOPUP_AMOUNT" \
    "$NATIVE_SPAM_FEE" "$NATIVE_SPAM_TRANSFER_TIMEOUT_SECONDS" "$query_base" "$status_file"
}

refresh_source_nonce() {
  local idx=$1
  local nonce

  nonce=$(read_native_nonce "${SOURCE_ADDRS[$idx]}" 2>/dev/null || true)
  if [[ "$nonce" =~ ^[0-9]+$ ]]; then
    SOURCE_NONCES[$idx]=$nonce
    return 0
  fi
  return 1
}

wait_for_sources_present() {
  local timeout_seconds=$1
  shift
  local -a indexes=("$@")
  local deadline
  local pending
  local idx

  deadline=$(($(date +%s) + timeout_seconds))
  while true; do
    pending=0
    for idx in "${indexes[@]}"; do
      if [[ ! "${SOURCE_NONCES[$idx]:-}" =~ ^[0-9]+$ ]]; then
        if ! refresh_source_nonce "$idx"; then
          pending=$((pending + 1))
        fi
      fi
    done
    if (( pending == 0 )); then
      return 0
    fi
    if (( $(date +%s) >= deadline )); then
      echo "Timed out waiting for $pending native spam source accounts to appear" >&2
      return 1
    fi
    sleep 1
  done
}

prepare_native_topups() {
  local funded_count=$NATIVE_SPAM_GENESIS_SOURCES
  local idx
  local funder
  local batch=0
  local offset=0
  local started
  local target
  local status_file
  local status
  local -a missing=()
  local -a batch_targets=()
  local -a batch_funders=()

  if (( funded_count > NATIVE_SPAM_SOURCES )); then
    funded_count=$NATIVE_SPAM_SOURCES
  fi
  if (( funded_count <= 0 )); then
    echo "NATIVE_SPAM_TOPUP_MODE=native requires at least one genesis-funded native source" >&2
    return 1
  fi

  for ((idx = 0; idx < NATIVE_SPAM_SOURCES; ++idx)); do
    SOURCE_NONCES[$idx]=""
    refresh_source_nonce "$idx" || true
  done

  for ((idx = 0; idx < funded_count; ++idx)); do
    if [[ ! "${SOURCE_NONCES[$idx]}" =~ ^[0-9]+$ ]]; then
      echo "Genesis-funded native source $idx is missing: ${SOURCE_ADDRS[$idx]}" >&2
      return 1
    fi
    echo "Source $idx nonce=${SOURCE_NONCES[$idx]}"
  done

  for ((idx = funded_count; idx < NATIVE_SPAM_SOURCES; ++idx)); do
    if [[ "${SOURCE_NONCES[$idx]}" =~ ^[0-9]+$ && "$NATIVE_SPAM_FORCE_TOPUP" == "0" ]]; then
      echo "Source $idx nonce=${SOURCE_NONCES[$idx]}"
    else
      missing+=("$idx")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    return 0
  fi

  echo "Native top-up required for ${#missing[@]} source accounts using $funded_count genesis-funded sources"
  while (( offset < ${#missing[@]} )); do
    batch_targets=()
    batch_funders=()
    started=0
    for ((funder = 0; funder < funded_count && offset + started < ${#missing[@]}; ++funder)); do
      target=${missing[$((offset + started))]}
      batch_targets[$started]=$target
      batch_funders[$started]=$funder
      send_native_topup_artifact "$funder" "$target" "${SOURCE_NONCES[$funder]}" "$batch" &
      started=$((started + 1))
    done
    wait || true

    for ((idx = 0; idx < started; ++idx)); do
      funder=${batch_funders[$idx]}
      target=${batch_targets[$idx]}
      status_file="$RUN_DIR/topup-${batch}-${funder}-${target}.status"
      status=$(cat "$status_file" 2>/dev/null || true)
      if [[ "$status" != "ok" ]]; then
        echo "Native top-up failed: funder=$funder target=$target" >&2
        return 1
      fi
      SOURCE_NONCES[$target]=""
    done

    wait_for_sources_present "$NATIVE_SPAM_TOPUP_TIMEOUT_SECONDS" "${batch_targets[@]}" || return 1
    for ((idx = 0; idx < funded_count; ++idx)); do
      refresh_source_nonce "$idx" || {
        echo "Failed to refresh genesis-funded source nonce: $idx" >&2
        return 1
      }
    done
    for target in "${batch_targets[@]}"; do
      echo "Source $target nonce=${SOURCE_NONCES[$target]}"
    done

    offset=$((offset + started))
    batch=$((batch + 1))
  done
}

ensure_genesis_destinations_present() {
  local idx

  if [[ "$NATIVE_SPAM_GENESIS_DESTINATIONS" != "1" || "$NATIVE_SPAM_TOPUP_MODE" != "genesis" ]]; then
    return 0
  fi
  for ((idx = 0; idx < NATIVE_SPAM_SOURCES; ++idx)); do
    if ! read_native_nonce "${DEST_ADDRS[$idx]}" >/dev/null 2>&1; then
      echo "Genesis native destination $idx is missing: ${DEST_ADDRS[$idx]}" >&2
      echo "Recreate genesis with NATIVE_SPAM_GENESIS_DESTINATIONS=1 or enable NATIVE_SPAM_POST_GENESIS_TOPUPS=1." >&2
      return 1
    fi
  done
}

confirm_round() {
  local round=$1
  local deadline
  local pending=$NATIVE_SPAM_SOURCES
  local idx
  local nonce_file
  local current_nonce

  for ((idx = 0; idx < NATIVE_SPAM_SOURCES; ++idx)); do
    PENDING[$idx]=1
  done

  deadline=$(($(date +%s) + NATIVE_SPAM_CONFIRM_TIMEOUT_SECONDS))
  while (( pending > 0 )); do
    for ((idx = 0; idx < NATIVE_SPAM_SOURCES; ++idx)); do
      if (( PENDING[$idx] == 0 )); then
        continue
      fi
      nonce_file="$QUERY_DIR/nonce-${round}-${idx}"
      (
        read_native_nonce "${SOURCE_ADDRS[$idx]}" > "$nonce_file" 2>/dev/null || true
      ) &
      throttle_background_jobs
    done
    wait || true

    for ((idx = 0; idx < NATIVE_SPAM_SOURCES; ++idx)); do
      if (( PENDING[$idx] == 0 )); then
        continue
      fi
      nonce_file="$QUERY_DIR/nonce-${round}-${idx}"
      current_nonce=$(cat "$nonce_file" 2>/dev/null || true)
      if [[ "$NATIVE_SPAM_KEEP_ARTIFACTS" == "0" ]]; then
        rm -f "$nonce_file"
      fi
      if [[ "$current_nonce" =~ ^[0-9]+$ ]] && (( current_nonce > SOURCE_NONCES[$idx] )); then
        SOURCE_NONCES[$idx]=$current_nonce
        PENDING[$idx]=0
        pending=$((pending - 1))
        CONFIRMED_TRANSFERS=$((CONFIRMED_TRANSFERS + 1))
      fi
    done

    if (( pending == 0 )); then
      break
    fi
    if (( $(date +%s) >= deadline )); then
      UNCONFIRMED_TRANSFERS=$((UNCONFIRMED_TRANSFERS + pending))
      break
    fi
    sleep 1
  done
}

print_progress() {
  local label=$1
  local elapsed

  elapsed=$(( $(date +%s) - STARTED_AT ))
  if (( elapsed < 1 )); then
    elapsed=1
  fi
  awk \
    -v label="$label" \
    -v sent="$SENT_TRANSFERS" \
    -v confirmed="$CONFIRMED_TRANSFERS" \
    -v elapsed="$elapsed" \
    -v active="$ACTIVE_SENDS" \
    -v pending="$PENDING_TRANSFERS" \
    -v failed="$FAILED_SENDS" \
    -v unconfirmed="$UNCONFIRMED_TRANSFERS" \
    'BEGIN {
      printf "%s: submitted=%d confirmed=%d submitted_tps=%.2f confirmed_tps=%.2f account_tx_tps=%.2f active_sends=%d pending_confirms=%d failed_sends=%d unconfirmed=%d\n",
        label, sent, confirmed, sent / elapsed, confirmed / elapsed, (confirmed * 2) / elapsed, active, pending, failed, unconfirmed
    }'
}

can_submit_source() {
  local idx=$1
  local now=$2

  if [[ "${SOURCE_STATE[$idx]}" != "ready" ]]; then
    return 1
  fi
  if (( NATIVE_SPAM_ROUNDS > 0 && SOURCE_SUBMITTED[$idx] >= NATIVE_SPAM_ROUNDS )); then
    return 1
  fi
  if (( SOURCE_READY_AT[$idx] > now )); then
    return 1
  fi
  return 0
}

start_pipeline_send() {
  local idx=$1
  local status_file="$RUN_DIR/send-$idx.status"
  local query_base="$QUERY_DIR/native-$idx"

  rm -f "$status_file"
  SOURCE_STATE[$idx]="sending"
  SOURCE_STATUS_FILE[$idx]="$status_file"
  send_native_transfer_artifact "$idx" "${SOURCE_NONCES[$idx]}" "$query_base" "$status_file" &
  SOURCE_SEND_PID[$idx]=$!
  ACTIVE_SENDS=$((ACTIVE_SENDS + 1))
}

collect_completed_sends() {
  local idx
  local status_file
  local status
  local now

  now=$(date +%s)
  for ((idx = 0; idx < NATIVE_SPAM_SOURCES; ++idx)); do
    if [[ "${SOURCE_STATE[$idx]}" != "sending" ]]; then
      continue
    fi
    status_file=${SOURCE_STATUS_FILE[$idx]}
    if [ ! -f "$status_file" ]; then
      continue
    fi

    wait "${SOURCE_SEND_PID[$idx]}" 2>/dev/null || true
    SOURCE_SEND_PID[$idx]=0
    ACTIVE_SENDS=$((ACTIVE_SENDS - 1))
    status=$(cat "$status_file" 2>/dev/null || true)

    if [[ "$status" == "ok" ]]; then
      SENT_TRANSFERS=$((SENT_TRANSFERS + 1))
      SOURCE_SUBMITTED[$idx]=$((SOURCE_SUBMITTED[$idx] + 1))
      SOURCE_STATE[$idx]="pending"
      SOURCE_SENT_AT[$idx]=$now
      SOURCE_UNCONFIRMED_RECORDED[$idx]=0
      PENDING_TRANSFERS=$((PENDING_TRANSFERS + 1))
    else
      FAILED_SENDS=$((FAILED_SENDS + 1))
      SOURCE_STATE[$idx]="ready"
      SOURCE_READY_AT[$idx]=$((now + 1))
    fi
  done
}

dispatch_ready_sources() {
  local now=$1
  local attempts=0
  local idx

  while (( ACTIVE_SENDS < NATIVE_SPAM_PARALLELISM && attempts < NATIVE_SPAM_SOURCES )); do
    idx=$SEND_CURSOR
    SEND_CURSOR=$(((SEND_CURSOR + 1) % NATIVE_SPAM_SOURCES))
    attempts=$((attempts + 1))
    if can_submit_source "$idx" "$now"; then
      start_pipeline_send "$idx"
    fi
  done
}

poll_pending_batch() {
  local now
  local started=0
  local attempts=0
  local idx
  local nonce_file
  local current_nonce
  local -a polled=()
  local -a poll_pids=()

  if (( PENDING_TRANSFERS == 0 )); then
    return 0
  fi

  while (( started < NATIVE_SPAM_CONFIRM_PARALLELISM && attempts < NATIVE_SPAM_SOURCES )); do
    idx=$CONFIRM_CURSOR
    CONFIRM_CURSOR=$(((CONFIRM_CURSOR + 1) % NATIVE_SPAM_SOURCES))
    attempts=$((attempts + 1))
    if [[ "${SOURCE_STATE[$idx]}" != "pending" ]]; then
      continue
    fi

    nonce_file="$QUERY_DIR/nonce-$idx"
    (
      read_native_nonce "${SOURCE_ADDRS[$idx]}" > "$nonce_file" 2>/dev/null || true
    ) &
    polled[$started]=$idx
    poll_pids[$started]=$!
    started=$((started + 1))
  done

  if (( started == 0 )); then
    return 0
  fi

  for idx in "${poll_pids[@]}"; do
    wait "$idx" 2>/dev/null || true
  done
  now=$(date +%s)
  for idx in "${polled[@]}"; do
    nonce_file="$QUERY_DIR/nonce-$idx"
    current_nonce=$(cat "$nonce_file" 2>/dev/null || true)
    if [[ "$NATIVE_SPAM_KEEP_ARTIFACTS" == "0" ]]; then
      rm -f "$nonce_file"
    fi
    if [[ "$current_nonce" =~ ^[0-9]+$ ]] && (( current_nonce > SOURCE_NONCES[$idx] )); then
      SOURCE_NONCES[$idx]=$current_nonce
      SOURCE_STATE[$idx]="ready"
      SOURCE_READY_AT[$idx]=$now
      SOURCE_UNCONFIRMED_RECORDED[$idx]=0
      PENDING_TRANSFERS=$((PENDING_TRANSFERS - 1))
      CONFIRMED_TRANSFERS=$((CONFIRMED_TRANSFERS + 1))
    fi
  done
}

record_remaining_pending() {
  local idx

  for ((idx = 0; idx < NATIVE_SPAM_SOURCES; ++idx)); do
    if [[ "${SOURCE_STATE[$idx]}" == "pending" && "${SOURCE_UNCONFIRMED_RECORDED[$idx]}" == "0" ]]; then
      SOURCE_UNCONFIRMED_RECORDED[$idx]=1
      UNCONFIRMED_TRANSFERS=$((UNCONFIRMED_TRANSFERS + 1))
    fi
  done
}

pipeline_rounds_done() {
  local idx

  if (( NATIVE_SPAM_ROUNDS == 0 )); then
    return 1
  fi
  for ((idx = 0; idx < NATIVE_SPAM_SOURCES; ++idx)); do
    if (( SOURCE_SUBMITTED[$idx] < NATIVE_SPAM_ROUNDS )); then
      return 1
    fi
    if [[ "${SOURCE_STATE[$idx]}" != "ready" ]]; then
      return 1
    fi
  done
  return 0
}

run_pipeline_spam() {
  local now
  local drain_deadline=$((STOP_AT + NATIVE_SPAM_CONFIRM_TIMEOUT_SECONDS))
  local last_progress_at=$STARTED_AT
  local idx

  ACTIVE_SENDS=0
  PENDING_TRANSFERS=0
  SEND_CURSOR=0
  CONFIRM_CURSOR=0

  for ((idx = 0; idx < NATIVE_SPAM_SOURCES; ++idx)); do
    SOURCE_STATE[$idx]="ready"
    SOURCE_SUBMITTED[$idx]=0
    SOURCE_READY_AT[$idx]=0
    SOURCE_SENT_AT[$idx]=0
    SOURCE_UNCONFIRMED_RECORDED[$idx]=0
    SOURCE_STATUS_FILE[$idx]="$RUN_DIR/send-$idx.status"
    SOURCE_SEND_PID[$idx]=0
  done

  echo "Native spam pipeline started"
  while true; do
    now=$(date +%s)
    collect_completed_sends
    poll_pending_batch
    collect_completed_sends

    now=$(date +%s)
    if (( now < STOP_AT )); then
      dispatch_ready_sources "$now"
    fi

    now=$(date +%s)
    if (( now - last_progress_at >= NATIVE_SPAM_PROGRESS_INTERVAL_SECONDS )); then
      print_progress "Progress"
      last_progress_at=$now
    fi

    if pipeline_rounds_done; then
      break
    fi
    if (( now >= STOP_AT && ACTIVE_SENDS == 0 && PENDING_TRANSFERS == 0 )); then
      break
    fi
    if (( now >= drain_deadline && ACTIVE_SENDS == 0 )); then
      record_remaining_pending
      break
    fi

    sleep "$NATIVE_SPAM_CONFIRM_POLL_SECONDS"
  done
}

run_round_spam() {
  while (( $(date +%s) < STOP_AT )); do
    if (( NATIVE_SPAM_ROUNDS > 0 && ROUND >= NATIVE_SPAM_ROUNDS )); then
      break
    fi

    echo "Native spam round $ROUND"
    for ((i = 0; i < NATIVE_SPAM_SOURCES; ++i)); do
      send_native_transfer "$i" "$ROUND" "${SOURCE_NONCES[$i]}" &
      throttle_background_jobs
    done
    wait || true

    for ((i = 0; i < NATIVE_SPAM_SOURCES; ++i)); do
      if [ "$(cat "$RUN_DIR/send-${ROUND}-${i}.status" 2>/dev/null || true)" = "ok" ]; then
        SENT_TRANSFERS=$((SENT_TRANSFERS + 1))
      else
        FAILED_SENDS=$((FAILED_SENDS + 1))
      fi
    done

    confirm_round "$ROUND"
    print_progress "Progress"

    ROUND=$((ROUND + 1))
  done
}

if [ ! -f "$MAIN_WALLET_BASE.pk" ] || [ ! -f "$MAIN_WALLET_BASE.addr" ]; then
  echo "Main wallet files are missing in /var/ton-work/db; native spam cannot be started" >&2
  exit 3
fi
if [ ! -f "$LITESERVER_PUB" ]; then
  echo "Lite-server public key is missing: $LITESERVER_PUB" >&2
  exit 3
fi
if [ ! -f /usr/share/ton/smartcont/native-wallet.fif ] || [ ! -f /usr/share/ton/smartcont/new-native-wallet.fif ]; then
  echo "Native wallet Fift scripts are missing from /usr/share/ton/smartcont" >&2
  exit 3
fi

mkdir -p "$NATIVE_SPAM_WORK_DIR" "$NATIVE_SPAM_WALLET_DIR"
load_genesis_spam_env
mkdir -p "$NATIVE_SPAM_WALLET_DIR"
acquire_spam_lock

RUN_DIR=$(mktemp -d "$NATIVE_SPAM_WORK_DIR/run.XXXXXX")
if [[ "$NATIVE_SPAM_KEEP_ARTIFACTS" == "1" ]]; then
  QUERY_DIR="$RUN_DIR"
else
  mkdir -p "$NATIVE_SPAM_TMP_DIR"
  QUERY_DIR=$(mktemp -d "$NATIVE_SPAM_TMP_DIR/run.XXXXXX")
fi
MASTER_ADDR=-1:$(xxd -p -l 32 -c 32 "$MAIN_WALLET_BASE.addr" | head -n1 | tr '[:lower:]' '[:upper:]')

echo "Starting native transfer spam..."
echo "NATIVE_SPAM_MODE=$NATIVE_SPAM_MODE"
echo "NATIVE_SPAM_SOURCES=$NATIVE_SPAM_SOURCES"
if (( NATIVE_SPAM_REQUESTED_SOURCES != NATIVE_SPAM_SOURCES )); then
  echo "NATIVE_SPAM_REQUESTED_SOURCES=$NATIVE_SPAM_REQUESTED_SOURCES"
fi
echo "NATIVE_SPAM_DURATION_SECONDS=$NATIVE_SPAM_DURATION_SECONDS"
echo "NATIVE_SPAM_ROUNDS=$NATIVE_SPAM_ROUNDS"
echo "NATIVE_SPAM_AMOUNT=$NATIVE_SPAM_AMOUNT"
echo "NATIVE_SPAM_FEE=$NATIVE_SPAM_FEE"
echo "NATIVE_SPAM_TOPUP_AMOUNT=$NATIVE_SPAM_TOPUP_AMOUNT"
echo "NATIVE_SPAM_TOPUP_MODE=$NATIVE_SPAM_TOPUP_MODE"
echo "NATIVE_SPAM_GENESIS_SOURCES=$NATIVE_SPAM_GENESIS_SOURCES"
echo "NATIVE_SPAM_GENESIS_DESTINATIONS=$NATIVE_SPAM_GENESIS_DESTINATIONS"
echo "NATIVE_SPAM_PARALLELISM=$NATIVE_SPAM_PARALLELISM"
echo "NATIVE_SPAM_CONFIRM_PARALLELISM=$NATIVE_SPAM_CONFIRM_PARALLELISM"
echo "NATIVE_SPAM_CONFIRM_POLL_SECONDS=$NATIVE_SPAM_CONFIRM_POLL_SECONDS"
echo "NATIVE_SPAM_PROGRESS_INTERVAL_SECONDS=$NATIVE_SPAM_PROGRESS_INTERVAL_SECONDS"
echo "NATIVE_SPAM_FORCE_TOPUP=$NATIVE_SPAM_FORCE_TOPUP"
echo "NATIVE_SPAM_KEEP_ARTIFACTS=$NATIVE_SPAM_KEEP_ARTIFACTS"
echo "NATIVE_SPAM_RUN_DIR=$RUN_DIR"
echo "NATIVE_SPAM_QUERY_DIR=$QUERY_DIR"
echo "Native source wallet dir: $NATIVE_SPAM_WALLET_DIR"
echo "Funding wallet: $MASTER_ADDR"

declare -a SOURCE_BASES SOURCE_ADDRS DEST_ADDRS SOURCE_NONCES PENDING
declare -a SOURCE_STATE SOURCE_SUBMITTED SOURCE_READY_AT SOURCE_SENT_AT SOURCE_UNCONFIRMED_RECORDED
declare -a SOURCE_STATUS_FILE SOURCE_SEND_PID

for ((i = 0; i < NATIVE_SPAM_SOURCES; ++i)); do
  SOURCE_BASES[$i]="$NATIVE_SPAM_WALLET_DIR/source-$i"
  DEST_BASE="$NATIVE_SPAM_WALLET_DIR/dest-$i"
  ensure_native_wallet "${SOURCE_BASES[$i]}"
  ensure_native_wallet "$DEST_BASE"
  SOURCE_ADDRS[$i]=$(address_from_file 0 "${SOURCE_BASES[$i]}.addr")
  DEST_ADDRS[$i]=$(address_from_file 0 "$DEST_BASE.addr")
done

ensure_genesis_destinations_present

if [[ "$NATIVE_SPAM_TOPUP_MODE" == "native" ]]; then
  prepare_native_topups
else
  for ((i = 0; i < NATIVE_SPAM_SOURCES; ++i)); do
    echo "Preparing source $i: ${SOURCE_ADDRS[$i]} -> ${DEST_ADDRS[$i]}"
    SOURCE_NONCES[$i]=$(send_topup "${SOURCE_BASES[$i]}" "${SOURCE_ADDRS[$i]}" "$QUERY_DIR/topup-$i")
    echo "Source $i nonce=${SOURCE_NONCES[$i]}"
  done
fi

STARTED_AT=$(date +%s)
STOP_AT=$((STARTED_AT + NATIVE_SPAM_DURATION_SECONDS))
SENT_TRANSFERS=0
FAILED_SENDS=0
CONFIRMED_TRANSFERS=0
UNCONFIRMED_TRANSFERS=0
ROUND=0
ACTIVE_SENDS=0
PENDING_TRANSFERS=0

{
  echo "NATIVE_SPAM_STARTED_AT=$STARTED_AT"
  echo "NATIVE_SPAM_STOP_AT=$STOP_AT"
  echo "NATIVE_SPAM_MODE=$NATIVE_SPAM_MODE"
  echo "NATIVE_SPAM_REQUESTED_SOURCES=$NATIVE_SPAM_REQUESTED_SOURCES"
  echo "NATIVE_SPAM_SOURCES=$NATIVE_SPAM_SOURCES"
  echo "NATIVE_SPAM_AMOUNT=$NATIVE_SPAM_AMOUNT"
  echo "NATIVE_SPAM_FEE=$NATIVE_SPAM_FEE"
  echo "NATIVE_SPAM_TOPUP_AMOUNT=$NATIVE_SPAM_TOPUP_AMOUNT"
  echo "NATIVE_SPAM_TOPUP_MODE=$NATIVE_SPAM_TOPUP_MODE"
  echo "NATIVE_SPAM_GENESIS_SOURCES=$NATIVE_SPAM_GENESIS_SOURCES"
  echo "NATIVE_SPAM_GENESIS_DESTINATIONS=$NATIVE_SPAM_GENESIS_DESTINATIONS"
  echo "NATIVE_SPAM_PARALLELISM=$NATIVE_SPAM_PARALLELISM"
  echo "NATIVE_SPAM_CONFIRM_PARALLELISM=$NATIVE_SPAM_CONFIRM_PARALLELISM"
  echo "NATIVE_SPAM_KEEP_ARTIFACTS=$NATIVE_SPAM_KEEP_ARTIFACTS"
} > "$RUN_DIR/native-spam.env"

if [[ "$NATIVE_SPAM_MODE" == "pipeline" ]]; then
  run_pipeline_spam
else
  run_round_spam
fi

FINISHED_AT=$(date +%s)
ELAPSED=$((FINISHED_AT - STARTED_AT))
if (( ELAPSED < 1 )); then
  ELAPSED=1
fi

echo "Native spam finished"
echo "Elapsed seconds: $ELAPSED"
echo "Mode: $NATIVE_SPAM_MODE"
if [[ "$NATIVE_SPAM_MODE" == "round" ]]; then
  echo "Rounds: $ROUND"
else
  echo "Rounds: pipeline refill"
fi
echo "Submitted native transfers: $SENT_TRANSFERS"
echo "Confirmed native transfers: $CONFIRMED_TRANSFERS"
echo "Failed send attempts: $FAILED_SENDS"
echo "Unconfirmed transfers: $UNCONFIRMED_TRANSFERS"
awk -v sent="$SENT_TRANSFERS" -v confirmed="$CONFIRMED_TRANSFERS" -v elapsed="$ELAPSED" \
  'BEGIN { printf "Submitted native transfer TPS: %.2f\nConfirmed native transfer TPS: %.2f\nConfirmed account-transaction TPS: %.2f\n", sent / elapsed, confirmed / elapsed, (confirmed * 2) / elapsed }'

release_spam_lock
