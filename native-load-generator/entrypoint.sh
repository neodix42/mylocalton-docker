#!/bin/sh
set -eu

config=${NATIVE_LOAD_GLOBAL_CONFIG:-/usr/share/data/global.config.json}
wallet_dir=${NATIVE_LOAD_WALLET_DIR:-/network/native-spam/wallets}
sources=${NATIVE_LOAD_SOURCES:-1000}
connections=${NATIVE_LOAD_CONNECTIONS:-4}
signers=${NATIVE_LOAD_SIGNERS:-4}
inflight=${NATIVE_LOAD_INFLIGHT:-8192}
duration=${NATIVE_LOAD_DURATION_SECONDS:-60}
amount=${NATIVE_LOAD_AMOUNT:-0.000000001}
fee=${NATIVE_LOAD_FEE:-0}
start_nonce=${NATIVE_LOAD_START_NONCE:-0}
query_timeout=${NATIVE_LOAD_QUERY_TIMEOUT_SECONDS:-10}
report_interval=${NATIVE_LOAD_REPORT_INTERVAL_SECONDS:-1}

test -r "$config" || { echo "global config is not readable: $config" >&2; exit 2; }
test -r "$wallet_dir/source-0.pk" || { echo "native source keys are not readable: $wallet_dir" >&2; exit 2; }

exec /usr/local/bin/native-load-generator \
  --global-config "$config" \
  --wallet-dir "$wallet_dir" \
  --sources "$sources" \
  --connections "$connections" \
  --signers "$signers" \
  --inflight "$inflight" \
  --duration "$duration" \
  --amount "$amount" \
  --fee "$fee" \
  --start-nonce "$start_nonce" \
  --query-timeout "$query_timeout" \
  --report-interval "$report_interval"
