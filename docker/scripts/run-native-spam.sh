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
NATIVE_SPAM_WORK_DIR=${NATIVE_SPAM_WORK_DIR:-/var/ton-work/db/native-spam}
NATIVE_SPAM_WALLET_DIR=${NATIVE_SPAM_WALLET_DIR:-$NATIVE_SPAM_WORK_DIR/wallets}
NATIVE_SPAM_LOCK_TIMEOUT_SECONDS=${NATIVE_SPAM_LOCK_TIMEOUT_SECONDS:-300}
NATIVE_SPAM_LITESERVER_ADDR=${NATIVE_SPAM_LITESERVER_ADDR:-127.0.0.1:40004}
NATIVE_SPAM_LITE_TIMEOUT_SECONDS=${NATIVE_SPAM_LITE_TIMEOUT_SECONDS:-10}

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

validate_uint_range NATIVE_SPAM_SOURCES "$NATIVE_SPAM_SOURCES" 1 100000
validate_uint_range NATIVE_SPAM_DURATION_SECONDS "$NATIVE_SPAM_DURATION_SECONDS" 1 31536000
validate_uint_range NATIVE_SPAM_ROUNDS "$NATIVE_SPAM_ROUNDS" 0 4294967295
validate_uint_range NATIVE_SPAM_PARALLELISM "$NATIVE_SPAM_PARALLELISM" 1 100000
validate_uint_range NATIVE_SPAM_TRANSFER_TIMEOUT_SECONDS "$NATIVE_SPAM_TRANSFER_TIMEOUT_SECONDS" 1 3600
validate_uint_range NATIVE_SPAM_CONFIRM_TIMEOUT_SECONDS "$NATIVE_SPAM_CONFIRM_TIMEOUT_SECONDS" 1 3600
validate_uint_range NATIVE_SPAM_TOPUP_TIMEOUT_SECONDS "$NATIVE_SPAM_TOPUP_TIMEOUT_SECONDS" 1 3600
validate_uint_range NATIVE_SPAM_LOCK_TIMEOUT_SECONDS "$NATIVE_SPAM_LOCK_TIMEOUT_SECONDS" 1 3600
validate_uint_range NATIVE_SPAM_LITE_TIMEOUT_SECONDS "$NATIVE_SPAM_LITE_TIMEOUT_SECONDS" 1 3600
validate_bool NATIVE_SPAM_FORCE_TOPUP "$NATIVE_SPAM_FORCE_TOPUP"

run_lite_client() {
  "$LITE_CLIENT" -a "$NATIVE_SPAM_LITESERVER_ADDR" -p "$LITESERVER_PUB" -t "$NATIVE_SPAM_LITE_TIMEOUT_SECONDS" -c "$1"
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

  old_nonce=$(read_native_nonce "$source_addr" 2>/dev/null || true)
  if [[ "$NATIVE_SPAM_FORCE_TOPUP" == "0" && "$old_nonce" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$old_nonce"
    return 0
  fi
  if [[ ! "$old_nonce" =~ ^[0-9]+$ ]]; then
    old_nonce=0
  fi

  master_seqno=$(read_wallet_seqno "$MASTER_ADDR")
  "$FIFT" -s /usr/share/ton/smartcont/wallet-v3.fif \
    "$MAIN_WALLET_BASE" "$source_addr" "$MASTER_SUBWALLET_ID" "$master_seqno" "$NATIVE_SPAM_TOPUP_AMOUNT" \
    -n -t 120 "$query_base" > "$query_base.fift.log" 2>&1

  run_lite_client "sendfile $query_base.boc" > "$query_base.send.log" 2>&1
  wait_for_wallet_seqno_advance "$MASTER_ADDR" "$master_seqno" "$NATIVE_SPAM_TOPUP_TIMEOUT_SECONDS"
  wait_for_native_nonce_advance "$source_addr" "$old_nonce" "$NATIVE_SPAM_TOPUP_TIMEOUT_SECONDS"
}

send_native_transfer() {
  local idx=$1
  local round=$2
  local nonce=$3
  local query_base="$RUN_DIR/native-${round}-${idx}"
  local status_file="$RUN_DIR/send-${round}-${idx}.status"

  if "$FIFT" -s /usr/share/ton/smartcont/native-wallet.fif \
      "${SOURCE_BASES[$idx]}" "${DEST_ADDRS[$idx]}" "$nonce" "$NATIVE_SPAM_AMOUNT" \
      -f "$NATIVE_SPAM_FEE" -t "$NATIVE_SPAM_TRANSFER_TIMEOUT_SECONDS" "$query_base" \
      > "$query_base.fift.log" 2>&1 &&
     run_lite_client "sendfile $query_base.boc" > "$query_base.send.log" 2>&1; then
    echo ok > "$status_file"
  else
    echo fail > "$status_file"
  fi
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
      nonce_file="$RUN_DIR/nonce-${round}-${idx}"
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
      nonce_file="$RUN_DIR/nonce-${round}-${idx}"
      current_nonce=$(cat "$nonce_file" 2>/dev/null || true)
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
acquire_spam_lock

RUN_DIR=$(mktemp -d "$NATIVE_SPAM_WORK_DIR/run.XXXXXX")
MASTER_ADDR=-1:$(xxd -p -l 32 -c 32 "$MAIN_WALLET_BASE.addr" | head -n1 | tr '[:lower:]' '[:upper:]')

echo "Starting native transfer spam..."
echo "NATIVE_SPAM_SOURCES=$NATIVE_SPAM_SOURCES"
echo "NATIVE_SPAM_DURATION_SECONDS=$NATIVE_SPAM_DURATION_SECONDS"
echo "NATIVE_SPAM_ROUNDS=$NATIVE_SPAM_ROUNDS"
echo "NATIVE_SPAM_AMOUNT=$NATIVE_SPAM_AMOUNT"
echo "NATIVE_SPAM_FEE=$NATIVE_SPAM_FEE"
echo "NATIVE_SPAM_TOPUP_AMOUNT=$NATIVE_SPAM_TOPUP_AMOUNT"
echo "NATIVE_SPAM_PARALLELISM=$NATIVE_SPAM_PARALLELISM"
echo "NATIVE_SPAM_FORCE_TOPUP=$NATIVE_SPAM_FORCE_TOPUP"
echo "NATIVE_SPAM_RUN_DIR=$RUN_DIR"
echo "Native source wallet dir: $NATIVE_SPAM_WALLET_DIR"
echo "Funding wallet: $MASTER_ADDR"

declare -a SOURCE_BASES SOURCE_ADDRS DEST_ADDRS SOURCE_NONCES PENDING

for ((i = 0; i < NATIVE_SPAM_SOURCES; ++i)); do
  SOURCE_BASES[$i]="$NATIVE_SPAM_WALLET_DIR/source-$i"
  DEST_BASE="$NATIVE_SPAM_WALLET_DIR/dest-$i"
  ensure_native_wallet "${SOURCE_BASES[$i]}"
  ensure_native_wallet "$DEST_BASE"
  SOURCE_ADDRS[$i]=$(address_from_file 0 "${SOURCE_BASES[$i]}.addr")
  DEST_ADDRS[$i]=$(address_from_file 0 "$DEST_BASE.addr")

  echo "Preparing source $i: ${SOURCE_ADDRS[$i]} -> ${DEST_ADDRS[$i]}"
  SOURCE_NONCES[$i]=$(send_topup "${SOURCE_BASES[$i]}" "${SOURCE_ADDRS[$i]}" "$RUN_DIR/topup-$i")
  echo "Source $i nonce=${SOURCE_NONCES[$i]}"
done

STARTED_AT=$(date +%s)
STOP_AT=$((STARTED_AT + NATIVE_SPAM_DURATION_SECONDS))
SENT_TRANSFERS=0
FAILED_SENDS=0
CONFIRMED_TRANSFERS=0
UNCONFIRMED_TRANSFERS=0
ROUND=0

{
  echo "NATIVE_SPAM_STARTED_AT=$STARTED_AT"
  echo "NATIVE_SPAM_STOP_AT=$STOP_AT"
  echo "NATIVE_SPAM_SOURCES=$NATIVE_SPAM_SOURCES"
  echo "NATIVE_SPAM_AMOUNT=$NATIVE_SPAM_AMOUNT"
  echo "NATIVE_SPAM_FEE=$NATIVE_SPAM_FEE"
  echo "NATIVE_SPAM_TOPUP_AMOUNT=$NATIVE_SPAM_TOPUP_AMOUNT"
} > "$RUN_DIR/native-spam.env"

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
  ELAPSED=$(( $(date +%s) - STARTED_AT ))
  if (( ELAPSED < 1 )); then
    ELAPSED=1
  fi
  awk -v sent="$SENT_TRANSFERS" -v confirmed="$CONFIRMED_TRANSFERS" -v elapsed="$ELAPSED" \
    'BEGIN { printf "Progress: submitted=%d confirmed=%d submitted_tps=%.2f confirmed_tps=%.2f account_tx_tps=%.2f\n", sent, confirmed, sent / elapsed, confirmed / elapsed, (confirmed * 2) / elapsed }'

  ROUND=$((ROUND + 1))
done

FINISHED_AT=$(date +%s)
ELAPSED=$((FINISHED_AT - STARTED_AT))
if (( ELAPSED < 1 )); then
  ELAPSED=1
fi

echo "Native spam finished"
echo "Elapsed seconds: $ELAPSED"
echo "Rounds: $ROUND"
echo "Submitted native transfers: $SENT_TRANSFERS"
echo "Confirmed native transfers: $CONFIRMED_TRANSFERS"
echo "Failed send attempts: $FAILED_SENDS"
echo "Unconfirmed transfers: $UNCONFIRMED_TRANSFERS"
awk -v sent="$SENT_TRANSFERS" -v confirmed="$CONFIRMED_TRANSFERS" -v elapsed="$ELAPSED" \
  'BEGIN { printf "Submitted native transfer TPS: %.2f\nConfirmed native transfer TPS: %.2f\nConfirmed account-transaction TPS: %.2f\n", sent / elapsed, confirmed / elapsed, (confirmed * 2) / elapsed }'

release_spam_lock
