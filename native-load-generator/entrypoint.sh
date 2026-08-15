#!/bin/sh
set -eu

config=${NATIVE_LOAD_GLOBAL_CONFIG:-/usr/share/data/global.config.json}
wallet_dir=${NATIVE_LOAD_WALLET_DIR:-/network/native-spam/wallets}
sources=${NATIVE_LOAD_SOURCES:-1000}
connections=${NATIVE_LOAD_CONNECTIONS:-4}
signers=${NATIVE_LOAD_SIGNERS:-4}
inflight=${NATIVE_LOAD_INFLIGHT:-8192}
duration=${NATIVE_LOAD_DURATION_SECONDS:-600}
amount=${NATIVE_LOAD_AMOUNT:-0.000000001}
fee=${NATIVE_LOAD_FEE:-0}
start_nonce=${NATIVE_LOAD_START_NONCE:-0}
query_timeout=${NATIVE_LOAD_QUERY_TIMEOUT_SECONDS:-10}
report_interval=${NATIVE_LOAD_REPORT_INTERVAL_SECONDS:-1}
target_tps=${NATIVE_LOAD_TARGET_TPS:-0}
ramp_seconds=${NATIVE_LOAD_RAMP_SECONDS:-0}
warmup_seconds=${NATIVE_LOAD_WARMUP_SECONDS:-0}
drain_timeout=${NATIVE_LOAD_DRAIN_TIMEOUT_SECONDS:-30}
valid_for_seconds=${NATIVE_LOAD_VALID_FOR_SECONDS:-120}
workers=${NATIVE_LOAD_WORKERS:-1}
max_retries=${NATIVE_LOAD_MAX_RETRIES:-3}
retry_backoff_ms=${NATIVE_LOAD_RETRY_BACKOFF_MS:-10}
auto_nonce=${NATIVE_LOAD_AUTO_NONCE:-1}
adaptive_inflight=${NATIVE_LOAD_ADAPTIVE_INFLIGHT:-1}
source_offset=${NATIVE_LOAD_SOURCE_OFFSET:-0}
finality_poll_seconds=${NATIVE_LOAD_FINALITY_POLL_SECONDS:-10}
finality_sample_sources=${NATIVE_LOAD_FINALITY_SAMPLE_SOURCES:-256}

if ! /usr/local/bin/native-load-generator --help 2>&1 | grep -q -- '--target-tps'; then
  echo "TON image does not contain the saturation-capable native-load-generator; rebuild/pull the updated TON image first" >&2
  exit 2
fi

test -r "$config" || { echo "global config is not readable: $config" >&2; exit 2; }
test -r "$wallet_dir/source-${source_offset}.pk" || {
  echo "native source key is not readable: $wallet_dir/source-${source_offset}.pk" >&2
  exit 2
}

set -- /usr/local/bin/native-load-generator \
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
  --report-interval "$report_interval" \
  --target-tps "$target_tps" \
  --ramp-seconds "$ramp_seconds" \
  --warmup-seconds "$warmup_seconds" \
  --drain-timeout "$drain_timeout" \
  --valid-for-seconds "$valid_for_seconds" \
  --workers "$workers" \
  --max-retries "$max_retries" \
  --retry-backoff-ms "$retry_backoff_ms" \
  --source-offset "$source_offset" \
  --finality-poll-seconds "$finality_poll_seconds" \
  --finality-sample-sources "$finality_sample_sources"

case "$auto_nonce" in
  1|true|TRUE|yes|YES) set -- "$@" --auto-nonce ;;
esac

case "$adaptive_inflight" in
  1|true|TRUE|yes|YES) set -- "$@" --adaptive-inflight ;;
esac

exec "$@"
