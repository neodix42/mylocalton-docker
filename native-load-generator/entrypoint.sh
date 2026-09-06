#!/bin/sh
set -eu

# Keep the expensive fixed-shard readiness check out of the historical scalar
# and v5-run paths. The helper is copied into this image alongside this script.
. /usr/local/lib/native-load-generator/payment-lanes.sh

config=${NATIVE_LOAD_GLOBAL_CONFIG:-/usr/share/data/global.config.json}
wallet_dir=${NATIVE_LOAD_WALLET_DIR:-/network/native-spam/wallets}
sources=${NATIVE_LOAD_SOURCES:-1000}
connections=${NATIVE_LOAD_CONNECTIONS:-4}
signers=${NATIVE_LOAD_SIGNERS:-4}
inflight=${NATIVE_LOAD_INFLIGHT:-8192}
submit_batch_size=${NATIVE_LOAD_SUBMIT_BATCH_SIZE:-1}
submit_source_run_size=${NATIVE_LOAD_SUBMIT_SOURCE_RUN_SIZE:-1}
native_transfer_runs=${NATIVE_LOAD_NATIVE_TRANSFER_RUNS:-0}
native_transfer_run_size=${NATIVE_LOAD_NATIVE_TRANSFER_RUN_SIZE:-16}
native_run_batching=${NATIVE_LOAD_NATIVE_RUN_BATCHING:-0}
native_payment_lanes=${NATIVE_PAYMENT_LANES_ENABLED:-0}
native_payment_lane_depth=${NATIVE_PAYMENT_LANE_DEPTH:-1}
native_load_payment_lane_depth=${NATIVE_LOAD_PAYMENT_LANE_DEPTH:-0}
native_payment_lane_ready_timeout=${NATIVE_LOAD_PAYMENT_LANE_READY_TIMEOUT_SECONDS:-360}
native_payment_lane_ready_poll=${NATIVE_LOAD_PAYMENT_LANE_READY_POLL_SECONDS:-2}
native_payment_lane_ready_stable_observations=${NATIVE_LOAD_PAYMENT_LANE_READY_STABLE_OBSERVATIONS:-2}
native_payment_lane_manifest=${NATIVE_LOAD_PAYMENT_LANE_MANIFEST:-$wallet_dir/native-payment-lanes.manifest}
submit_coalesce_ms=${NATIVE_LOAD_SUBMIT_COALESCE_MS:-2}
submit_max_queries_per_client=${NATIVE_LOAD_SUBMIT_MAX_QUERIES_PER_CLIENT:-0}
max_canonical_backlog=${NATIVE_LOAD_MAX_CANONICAL_BACKLOG:-262144}
max_source_canonical_backlog=${NATIVE_LOAD_MAX_SOURCE_CANONICAL_BACKLOG:-64}
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
retry_horizon_seconds=${NATIVE_LOAD_RETRY_HORIZON_SECONDS:-30}
canonical_state_lag_retry_backoff_ms=${NATIVE_LOAD_CANONICAL_STATE_LAG_RETRY_BACKOFF_MS:-250}
canonical_state_lag_retry_max_backoff_ms=${NATIVE_LOAD_CANONICAL_STATE_LAG_RETRY_MAX_BACKOFF_MS:-2000}
auto_nonce=${NATIVE_LOAD_AUTO_NONCE:-1}
adaptive_inflight=${NATIVE_LOAD_ADAPTIVE_INFLIGHT:-1}
adaptive_initial_rtt_seconds=${NATIVE_LOAD_ADAPTIVE_INITIAL_RTT_SECONDS:-1}
adaptive_max_cwnd=${NATIVE_LOAD_ADAPTIVE_MAX_CWND:-0}
adaptive_initial_cwnd=${NATIVE_LOAD_ADAPTIVE_INITIAL_CWND:-0}
source_offset=${NATIVE_LOAD_SOURCE_OFFSET:-0}
finality_poll_seconds=${NATIVE_LOAD_FINALITY_POLL_SECONDS:-10}
finality_sample_sources=${NATIVE_LOAD_FINALITY_SAMPLE_SOURCES:-256}
canonical_poll_seconds=${NATIVE_LOAD_CANONICAL_POLL_SECONDS:-0.25}
canonical_query_timeout=${NATIVE_LOAD_CANONICAL_QUERY_TIMEOUT_SECONDS:-30}
canonical_retry_limit=${NATIVE_LOAD_CANONICAL_RETRY_LIMIT:-5}
canonical_retry_backoff_seconds=${NATIVE_LOAD_CANONICAL_RETRY_BACKOFF_SECONDS:-0.25}
canonical_retry_max_backoff_seconds=${NATIVE_LOAD_CANONICAL_RETRY_MAX_BACKOFF_SECONDS:-5}
repair_cooldown_seconds=${NATIVE_LOAD_REPAIR_COOLDOWN_SECONDS:-10}
canonical_block_follower=${NATIVE_LOAD_CANONICAL_BLOCK_FOLLOWER:-1}

generator_help=$(/usr/local/bin/native-load-generator --help 2>&1 || true)
if ! printf '%s\n' "$generator_help" | grep -q -- '--submit-batch-size' ||
   ! printf '%s\n' "$generator_help" | grep -q -- '--submit-source-run-size' ||
   ! printf '%s\n' "$generator_help" | grep -q -- '--submit-coalesce-ms' ||
   ! printf '%s\n' "$generator_help" | grep -q -- '--submit-max-queries-per-client' ||
   ! printf '%s\n' "$generator_help" | grep -q -- '--canonical-poll-seconds' ||
   ! printf '%s\n' "$generator_help" | grep -q -- '--canonical-query-timeout' ||
   ! printf '%s\n' "$generator_help" | grep -q -- '--adaptive-initial-rtt-seconds' ||
   ! printf '%s\n' "$generator_help" | grep -q -- '--adaptive-max-cwnd' ||
   ! printf '%s\n' "$generator_help" | grep -q -- '--retry-horizon-seconds' ||
   ! printf '%s\n' "$generator_help" | grep -q -- '--canonical-state-lag-retry-backoff-ms' ||
   ! printf '%s\n' "$generator_help" | grep -q -- '--canonical-state-lag-retry-max-backoff-ms'; then
  echo "TON image does not contain the batched, canonical-aware native-load-generator; rebuild/pull the updated TON image first" >&2
  exit 2
fi

test -r "$config" || { echo "global config is not readable: $config" >&2; exit 2; }
test -r "$wallet_dir/source-${source_offset}.pk" || {
  echo "native source key is not readable: $wallet_dir/source-${source_offset}.pk" >&2
  exit 2
}

case "$native_transfer_runs" in
  0|false|FALSE|no|NO) native_transfer_runs_enabled=0 ;;
  1|true|TRUE|yes|YES) native_transfer_runs_enabled=1 ;;
  *)
    echo "NATIVE_LOAD_NATIVE_TRANSFER_RUNS must be 0 or 1, got '$native_transfer_runs'" >&2
    exit 2
    ;;
esac

case "$native_run_batching" in
  0) ;;
  1)
    if [ "$native_transfer_runs_enabled" != 1 ]; then
      echo "NATIVE_LOAD_NATIVE_RUN_BATCHING=1 requires NATIVE_LOAD_NATIVE_TRANSFER_RUNS=1" >&2
      exit 2
    fi
    ;;
  *)
    echo "NATIVE_LOAD_NATIVE_RUN_BATCHING must be 0 or 1, got '$native_run_batching'" >&2
    exit 2
    ;;
esac

native_payment_lanes_validate_mode \
  "$native_payment_lanes" "$native_transfer_runs_enabled" \
  "$native_payment_lane_depth" "$native_load_payment_lane_depth" || exit $?
native_payment_lane_active_depth=$native_load_payment_lane_depth

set -- /usr/local/bin/native-load-generator \
  --global-config "$config" \
  --wallet-dir "$wallet_dir" \
  --sources "$sources" \
  --connections "$connections" \
  --signers "$signers" \
  --inflight "$inflight" \
  --submit-batch-size "$submit_batch_size" \
  --submit-source-run-size "$submit_source_run_size" \
  --submit-coalesce-ms "$submit_coalesce_ms" \
  --submit-max-queries-per-client "$submit_max_queries_per_client" \
  --max-canonical-backlog "$max_canonical_backlog" \
  --max-source-canonical-backlog "$max_source_canonical_backlog" \
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
  --retry-horizon-seconds "$retry_horizon_seconds" \
  --canonical-state-lag-retry-backoff-ms "$canonical_state_lag_retry_backoff_ms" \
  --canonical-state-lag-retry-max-backoff-ms "$canonical_state_lag_retry_max_backoff_ms" \
  --adaptive-initial-rtt-seconds "$adaptive_initial_rtt_seconds" \
  --adaptive-max-cwnd "$adaptive_max_cwnd" \
  --source-offset "$source_offset" \
  --finality-poll-seconds "$finality_poll_seconds" \
  --finality-sample-sources "$finality_sample_sources" \
  --canonical-poll-seconds "$canonical_poll_seconds" \
  --canonical-query-timeout "$canonical_query_timeout" \
  --canonical-retry-limit "$canonical_retry_limit" \
  --canonical-retry-backoff-seconds "$canonical_retry_backoff_seconds" \
  --canonical-retry-max-backoff-seconds "$canonical_retry_max_backoff_seconds" \
  --repair-cooldown-seconds "$repair_cooldown_seconds"

# Optional global initial budget. Zero retains compatibility with older images.
case "$adaptive_initial_cwnd" in
  ''|*[!0-9]*)
    echo "NATIVE_LOAD_ADAPTIVE_INITIAL_CWND must be an integer in [0, 4294967295]" >&2
    exit 2 ;;
esac
if ! awk -v value="$adaptive_initial_cwnd" 'BEGIN {exit !(value >= 0 && value <= 4294967295)}'; then
  echo "NATIVE_LOAD_ADAPTIVE_INITIAL_CWND must be an integer in [0, 4294967295]" >&2
  exit 2
fi
if awk -v value="$adaptive_initial_cwnd" 'BEGIN {exit !(value > 0)}'; then
  if ! printf '%s\n' "$generator_help" |
       grep -Eq -- '(^|[[:space:]])--adaptive-initial-cwnd(<arg>)?([=[:space:]]|$)'; then
    echo "NATIVE_LOAD_ADAPTIVE_INITIAL_CWND requires a native-load-generator image with --adaptive-initial-cwnd" >&2
    exit 2
  fi
  set -- "$@" --adaptive-initial-cwnd "$adaptive_initial_cwnd"
fi

case "$auto_nonce" in
  1|true|TRUE|yes|YES) set -- "$@" --auto-nonce ;;
esac

case "$native_transfer_runs" in
  0|false|FALSE|no|NO)
    ;;
  1|true|TRUE|yes|YES)
    if ! printf '%s\n' "$generator_help" | grep -q -- '--native-signed-runs' ||
       ! printf '%s\n' "$generator_help" | grep -q -- '--native-signed-run-size'; then
      echo "NATIVE_LOAD_NATIVE_TRANSFER_RUNS=1 requires a v5-capable native-load-generator image" >&2
      exit 2
    fi
    set -- "$@" --native-signed-runs --native-signed-run-size "$native_transfer_run_size"
    ;;
  *)
    echo "NATIVE_LOAD_NATIVE_TRANSFER_RUNS must be 0 or 1, got '$native_transfer_runs'" >&2
    exit 2
    ;;
esac

if [ "$native_run_batching" = 1 ]; then
  if ! printf '%s\n' "$generator_help" |
       grep -Eq -- '(^|[[:space:]])--native-run-batching([=[:space:]]|$)'; then
    echo "NATIVE_LOAD_NATIVE_RUN_BATCHING=1 requires a native-load-generator image with --native-run-batching" >&2
    exit 2
  fi
  set -- "$@" --native-run-batching
fi

if [ "$native_payment_lanes" = 1 ]; then
  if ! printf '%s\n' "$generator_help" | grep -q -- '--native-payment-lane-depth'; then
    echo "NATIVE_PAYMENT_LANES_ENABLED=1 requires a native payment lane-capable native-load-generator image" >&2
    exit 2
  fi
  native_payment_lanes_validate_manifest \
    "$native_payment_lane_manifest" "$wallet_dir" "$source_offset" "$sources" \
    "$native_payment_lane_active_depth" || exit $?
  native_payment_lanes_wait_for_shards \
    "$config" "$native_payment_lane_ready_timeout" "$native_payment_lane_ready_poll" \
    "$native_payment_lane_ready_stable_observations" \
    "$native_payment_lane_active_depth" || exit $?
  set -- "$@" --native-payment-lane-depth "$native_payment_lane_active_depth"
fi

case "$adaptive_inflight" in
  1|true|TRUE|yes|YES) set -- "$@" --adaptive-inflight ;;
esac

case "$canonical_block_follower" in
  0|false|FALSE|no|NO) set -- "$@" --no-canonical-block-follower ;;
esac

exec "$@"
