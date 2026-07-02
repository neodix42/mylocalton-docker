#!/bin/bash
set -euo pipefail

SPAM_CHAINS=${SPAM_CHAINS:-10}
SPAM_HOPS=${SPAM_HOPS:-65535}
SPAM_SPLIT_HOPS=${SPAM_SPLIT_HOPS:-7}
SPAM_DURATION_MINUTES=${SPAM_DURATION_MINUTES:-300}

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

export FIFTPATH=/usr/lib/fift:/usr/share/ton/smartcont:/scripts

LITE_CLIENT=/usr/local/bin/lite-client
FIFT=/usr/local/bin/fift
FUNC=/usr/local/bin/func
LITESERVER_PUB=/var/ton-work/db/liteserver.pub
LITESERVER_ADDR=127.0.0.1:40004
MAIN_WALLET_BASE=/var/ton-work/db/main-wallet
SPAM_WORK_DIR=${SPAM_WORK_DIR:-/var/ton-work/db/spam}

if [ ! -f "$MAIN_WALLET_BASE.pk" ] || [ ! -f "$MAIN_WALLET_BASE.addr" ]; then
  echo "Main wallet files are missing in /var/ton-work/db; spam cannot be started" >&2
  exit 3
fi

if [ ! -f "$LITESERVER_PUB" ]; then
  echo "Lite-server public key is missing: $LITESERVER_PUB" >&2
  exit 3
fi

mkdir -p "$SPAM_WORK_DIR"
RUN_DIR=$(mktemp -d "$SPAM_WORK_DIR/run.XXXXXX")

echo "Starting spam..."
echo "SPAM_CHAINS=$SPAM_CHAINS"
echo "SPAM_HOPS=$SPAM_HOPS"
echo "SPAM_SPLIT_HOPS=$SPAM_SPLIT_HOPS"
echo "SPAM_DURATION_MINUTES=$SPAM_DURATION_MINUTES"
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

echo "Retranslator address: $RETRANSLATOR_ADDR"
echo "Master wallet address: $MASTER_ADDR"

SEQNO_OUTPUT=$(
  "$LITE_CLIENT" -a "$LITESERVER_ADDR" -p "$LITESERVER_PUB" -t 10 -c "runmethod $MASTER_ADDR seqno" 2>&1
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
  "$FIFT" -s /usr/share/ton/smartcont/wallet.fif \
    "$MAIN_WALLET_BASE" "$RETRANSLATOR_ADDR" "$MASTER_SEQNO" 33333333 -n wallet-query
)

"$LITE_CLIENT" -a "$LITESERVER_ADDR" -p "$LITESERVER_PUB" -t 10 -c "sendfile $RUN_DIR/wallet-query.boc"
sleep 15

"$LITE_CLIENT" -a "$LITESERVER_ADDR" -p "$LITESERVER_PUB" -t 10 -c "getaccount $RETRANSLATOR_ADDR"
"$LITE_CLIENT" -a "$LITESERVER_ADDR" -p "$LITESERVER_PUB" -t 10 -c "sendfile $RUN_DIR/query-retranslator.boc"

echo "Spam started"
