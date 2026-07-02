#!/bin/bash
set -euo pipefail

SPAM_CHAINS=${SPAM_CHAINS:-10}
SPAM_HOPS=${SPAM_HOPS:-65535}
SPAM_SPLIT_HOPS=${SPAM_SPLIT_HOPS:-7}
SPAM_DURATION_MINUTES=${SPAM_DURATION_MINUTES:-300}
SPAM_TOPUP_TIMEOUT_SECONDS=${SPAM_TOPUP_TIMEOUT_SECONDS:-180}
SPAM_FORCE_RUN=${SPAM_FORCE_RUN:-0}

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
validate_uint_range SPAM_FORCE_RUN "$SPAM_FORCE_RUN" 0 1

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

account_is_active() {
  printf '%s\n' "$1" | grep -q "state:(account_active"
}

read_retranslator_addr() {
  local run_dir=$1
  local addr_hash

  [ -f "$run_dir/wallet-retranslator.addr" ] || return 1
  addr_hash=$(xxd -p -c 32 "$run_dir/wallet-retranslator.addr" | head -n1)
  [ -n "$addr_hash" ] || return 1
  printf '0:%s\n' "$addr_hash"
}

read_run_duration_minutes() {
  local run_dir=$1
  local duration

  if [ -f "$run_dir/spam.env" ]; then
    duration=$(sed -n 's/^SPAM_DURATION_MINUTES=\([0-9][0-9]*\)$/\1/p' "$run_dir/spam.env" | head -n1)
    if [ -n "$duration" ]; then
      printf '%s\n' "$duration"
      return 0
    fi
  fi

  if [ -f "$run_dir/create-msg.fif" ]; then
    sed -n 's/.*now 60 \([0-9][0-9]*\) \* + 32 u.*/\1/p' "$run_dir/create-msg.fif" | head -n1
  fi
}

read_run_started_at() {
  local run_dir=$1
  local started_at

  if [ -f "$run_dir/spam.env" ]; then
    started_at=$(sed -n 's/^SPAM_STARTED_AT=\([0-9][0-9]*\)$/\1/p' "$run_dir/spam.env" | head -n1)
    if [ -n "$started_at" ]; then
      printf '%s\n' "$started_at"
      return 0
    fi
  fi

  stat -c %Y "$run_dir/query-retranslator.boc" 2>/dev/null || stat -c %Y "$run_dir" 2>/dev/null
}

read_run_stop_at() {
  local run_dir=$1
  local duration_minutes
  local started_at

  duration_minutes=$(read_run_duration_minutes "$run_dir" | head -n1)
  started_at=$(read_run_started_at "$run_dir" | head -n1)

  if [[ "$duration_minutes" =~ ^[0-9]+$ ]] && [[ "$started_at" =~ ^[0-9]+$ ]]; then
    printf '%s\n' $((started_at + duration_minutes * 60))
  fi
}

find_running_spam() {
  local now
  local run_dir
  local addr
  local account_state
  local stop_at

  now=$(date +%s)
  for run_dir in "$SPAM_WORK_DIR"/run.*; do
    [ -d "$run_dir" ] || continue
    addr=$(read_retranslator_addr "$run_dir") || continue
    account_state=$(get_account_state "$addr")
    account_is_active "$account_state" || continue

    stop_at=$(read_run_stop_at "$run_dir" | head -n1)
    if [[ "$stop_at" =~ ^[0-9]+$ ]] && (( now >= stop_at )); then
      continue
    fi

    printf '%s\t%s\t%s\n' "$run_dir" "$addr" "$stop_at"
    return 0
  done

  return 1
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

if [ ! -f "$MAIN_WALLET_BASE.pk" ] || [ ! -f "$MAIN_WALLET_BASE.addr" ]; then
  echo "Main wallet files are missing in /var/ton-work/db; spam cannot be started" >&2
  exit 3
fi

if [ ! -f "$LITESERVER_PUB" ]; then
  echo "Lite-server public key is missing: $LITESERVER_PUB" >&2
  exit 3
fi

mkdir -p "$SPAM_WORK_DIR"

if [ "$SPAM_FORCE_RUN" != "1" ]; then
  running_spam=$(find_running_spam || true)
  if [ -n "$running_spam" ]; then
    IFS=$'\t' read -r RUN_DIR RETRANSLATOR_ADDR SPAM_STOP_AT <<< "$running_spam"
    echo "Spam already running"
    echo "SPAM_RUN_DIR=$RUN_DIR"
    echo "RETRANSLATOR_ADDR=$RETRANSLATOR_ADDR"
    if [ -n "${SPAM_STOP_AT:-}" ]; then
      echo "SPAM_STOP_AT=$SPAM_STOP_AT"
    fi
    exit 0
  fi
fi

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
  printf '%s\n' "$SEQNO_OUTPUT" |
    sed -n 's/.*result:[[:space:]]*\[[[:space:]]*\([0-9][0-9]*\).*/\1/p' |
    tail -n1
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

echo "Waiting for retranslator wallet top-up..."
wait_for_account_present "$RETRANSLATOR_ADDR" "$SPAM_TOPUP_TIMEOUT_SECONDS"
run_lite_client "sendfile $RUN_DIR/query-retranslator.boc"

echo "Spam started"
