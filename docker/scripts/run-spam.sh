#!/bin/bash
set -euo pipefail

SPAM_CHAINS=${SPAM_CHAINS:-10}
SPAM_HOPS=${SPAM_HOPS:-65535}
SPAM_SPLIT_HOPS=${SPAM_SPLIT_HOPS:-7}
SPAM_DURATION_MINUTES=${SPAM_DURATION_MINUTES:-300}
SPAM_TOPUP_TIMEOUT_SECONDS=${SPAM_TOPUP_TIMEOUT_SECONDS:-600}
SPAM_LOCK_TIMEOUT_SECONDS=900

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

validate_uint_range SPAM_CHAINS "$SPAM_CHAINS" 1 255
validate_uint_range SPAM_HOPS "$SPAM_HOPS" 1 65535
validate_uint_range SPAM_SPLIT_HOPS "$SPAM_SPLIT_HOPS" 0 255
validate_uint_range SPAM_DURATION_MINUTES "$SPAM_DURATION_MINUTES" 1 525600
validate_uint_range SPAM_TOPUP_TIMEOUT_SECONDS "$SPAM_TOPUP_TIMEOUT_SECONDS" 1 3600

export FIFTPATH=/usr/lib/fift:/usr/share/ton/smartcont:/scripts

LITE_CLIENT=/usr/local/bin/lite-client
FIFT=/usr/local/bin/fift
FUNC=/usr/local/bin/func
LITESERVER_PUB=/var/ton-work/db/liteserver.pub
LITESERVER_ADDR=127.0.0.1:40004
MAIN_WALLET_BASE=/var/ton-work/db/main-wallet
SPAM_WORK_DIR=${SPAM_WORK_DIR:-/var/ton-work/db/spam}

run_lite_client() {
  "$LITE_CLIENT" -a "$LITESERVER_ADDR" -p "$LITESERVER_PUB" -t 10 -c "$1"
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

wait_for_wallet_seqno_advance() {
  local addr=$1
  local previous_seqno=$2
  local timeout_seconds=$3
  local deadline
  local now
  local current_seqno

  deadline=$(($(date +%s) + timeout_seconds))
  while true; do
    current_seqno=$(read_wallet_seqno "$addr" 2>/dev/null || true)
    if [[ "$current_seqno" =~ ^[0-9]+$ ]] && (( current_seqno > previous_seqno )); then
      echo "Master wallet seqno advanced to $current_seqno"
      return 0
    fi

    now=$(date +%s)
    if (( now >= deadline )); then
      echo "Master wallet seqno did not advance within ${timeout_seconds}s" >&2
      return 1
    fi

    sleep 2
  done
}

wait_for_account_present() {
  local addr=$1
  local timeout_seconds=$2
  local deadline
  local now
  local account_state

  deadline=$(($(date +%s) + timeout_seconds))
  while true; do
    account_state=$(get_account_state "$addr")
    if account_is_present "$account_state"; then
      echo "Retranslator wallet is funded"
      printf '%s\n' "$account_state" |
        grep -E "account state is|last transaction|account balance is" |
        tail -5 || true
      return 0
    fi

    now=$(date +%s)
    if (( now >= deadline )); then
      echo "Retranslator wallet was not funded within ${timeout_seconds}s; not sending init query" >&2
      printf '%s\n' "$account_state" >&2
      return 1
    fi

    sleep 5
  done
}

cleanup_spam_lock() {
  if [ -n "${SPAM_LOCK_DIR:-}" ] && [ -d "$SPAM_LOCK_DIR" ]; then
    rm -f "$SPAM_LOCK_DIR/pid"
    rmdir "$SPAM_LOCK_DIR" 2>/dev/null || true
  fi
}

release_spam_lock() {
  cleanup_spam_lock
  trap - EXIT
  unset SPAM_LOCK_DIR
  echo "Spam launch lock released"
}

acquire_spam_lock() {
  local lock_dir="$SPAM_WORK_DIR/run.lock"
  local deadline
  local lock_pid
  local now
  local printed_waiting=0

  deadline=$(($(date +%s) + SPAM_LOCK_TIMEOUT_SECONDS))
  while ! mkdir "$lock_dir" 2>/dev/null; do
    if [ "$printed_waiting" -eq 0 ]; then
      echo "Waiting for spam launch lock..."
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

    now=$(date +%s)
    if (( now >= deadline )); then
      echo "Timed out waiting for spam launch lock" >&2
      exit 6
    fi

    sleep 1
  done

  SPAM_LOCK_DIR=$lock_dir
  echo "$$" > "$SPAM_LOCK_DIR/pid"
  echo "Spam launch lock acquired"
  trap cleanup_spam_lock EXIT
}

if [ ! -f "$MAIN_WALLET_BASE.pk" ] || [ ! -f "$MAIN_WALLET_BASE.addr" ]; then
  echo "Main wallet files are missing in /var/ton-work/db; spam cannot be started" >&2
  exit 3
fi

if [ ! -f "$LITESERVER_PUB" ]; then
  echo "Lite-server public key is missing: $LITESERVER_PUB" >&2
  exit 3
fi

mkdir -p "$SPAM_WORK_DIR"
acquire_spam_lock

RUN_DIR=$(mktemp -d "$SPAM_WORK_DIR/run.XXXXXX")

echo "Starting spam..."
echo "SPAM_CHAINS=$SPAM_CHAINS"
echo "SPAM_HOPS=$SPAM_HOPS"
echo "SPAM_SPLIT_HOPS=$SPAM_SPLIT_HOPS"
echo "SPAM_DURATION_MINUTES=$SPAM_DURATION_MINUTES"
echo "SPAM_TOPUP_TIMEOUT_SECONDS=$SPAM_TOPUP_TIMEOUT_SECONDS"
echo "SPAM_RUN_DIR=$RUN_DIR"

cp /scripts/create-msg.fif.template "$RUN_DIR/create-msg.fif"
cp /scripts/retranslator.fc "$RUN_DIR/retranslator.fc"

sed -i "s/SPAM_CHAINS/$SPAM_CHAINS/g" "$RUN_DIR/create-msg.fif"
sed -i "s/SPAM_HOPS/$SPAM_HOPS/g" "$RUN_DIR/create-msg.fif"
sed -i "s/SPAM_SPLIT_HOPS/$SPAM_SPLIT_HOPS/g" "$RUN_DIR/create-msg.fif"
sed -i "s/SPAM_DURATION_MINUTES/$SPAM_DURATION_MINUTES/g" "$RUN_DIR/create-msg.fif"

echo "Compiling retranslator.fc smart-contract..."
(
  cd "$RUN_DIR"
  "$FUNC" -o retranslator.fif -SPA /usr/share/ton/smartcont/stdlib.fc retranslator.fc
  "$FIFT" -s create-msg.fif
)

RETRANSLATOR_ADDR=0:$(xxd -p -c 32 "$RUN_DIR/wallet-retranslator.addr" | head -n1)
MASTER_ADDR=-1:$(xxd -p -c 32 "$MAIN_WALLET_BASE.addr" | head -n1)
SPAM_STARTED_AT=$(date +%s)
SPAM_STOP_AT=$((SPAM_STARTED_AT + SPAM_DURATION_MINUTES * 60))

{
  echo "SPAM_STARTED_AT=$SPAM_STARTED_AT"
  echo "SPAM_DURATION_MINUTES=$SPAM_DURATION_MINUTES"
  echo "SPAM_STOP_AT=$SPAM_STOP_AT"
  echo "SPAM_CHAINS=$SPAM_CHAINS"
  echo "SPAM_HOPS=$SPAM_HOPS"
  echo "SPAM_SPLIT_HOPS=$SPAM_SPLIT_HOPS"
  echo "RETRANSLATOR_ADDR=$RETRANSLATOR_ADDR"
} > "$RUN_DIR/spam.env"

echo "Retranslator address: $RETRANSLATOR_ADDR"
echo "Master wallet address: $MASTER_ADDR"

SEQNO_OUTPUT=$(
  run_lite_client "runmethod $MASTER_ADDR seqno" 2>&1
)
MASTER_SEQNO=$(
  printf '%s\n' "$SEQNO_OUTPUT" | extract_seqno
)

if [ -z "$MASTER_SEQNO" ]; then
  echo "Failed to read master wallet seqno" >&2
  echo "$SEQNO_OUTPUT" >&2
  exit 4
fi

echo "Master wallet seqno: $MASTER_SEQNO"
echo "Topping up retranslator wallet..."

(
  cd "$RUN_DIR"
  "$FIFT" -s /usr/share/ton/smartcont/wallet-v3.fif \
    "$MAIN_WALLET_BASE" "$RETRANSLATOR_ADDR" 42 "$MASTER_SEQNO" 33333333 -n wallet-query
)

run_lite_client "sendfile $RUN_DIR/wallet-query.boc"
wait_for_wallet_seqno_advance "$MASTER_ADDR" "$MASTER_SEQNO" 120
release_spam_lock

echo "Waiting for retranslator wallet top-up..."
wait_for_account_present "$RETRANSLATOR_ADDR" "$SPAM_TOPUP_TIMEOUT_SECONDS"
run_lite_client "sendfile $RUN_DIR/query-retranslator.boc"

echo "Spam started"
