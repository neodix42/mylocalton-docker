#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
env_file=${1:-.env.physical}

if [[ $env_file != /* ]]; then
  env_file=$script_dir/../$env_file
fi
test -r "$env_file" || {
  echo "environment file is not readable: $env_file" >&2
  exit 2
}

cat >&2 <<'EOF'
Starting the fixed two-lane Phase-A native payment-lane profile.
The guarded fresh-cycle runner below deletes only the benchmark Compose
project's allowlisted containers, network, and volumes. Do not use this helper
against a state that must be retained.
EOF

exec env \
  NATIVE_TRANSFER_RUNS_ENABLED=1 \
  NATIVE_TRANSFER_RUNS_GLOBAL_VERSION=15 \
  NATIVE_TRANSFER_RUNS_CAPABILITY=1024 \
  NATIVE_PAYMENT_LANES_ENABLED=1 \
  NATIVE_PAYMENT_LANES_GLOBAL_VERSION=16 \
  NATIVE_PAYMENT_LANES_CAPABILITY=2048 \
  NATIVE_PAYMENT_LANE_DEPTH=1 \
  NATIVE_PAYMENT_LANE_WALLET_RETRIES=128 \
  NATIVE_PAYMENT_LANE_WALLET_PARALLELISM=12 \
  GENESIS_HEALTHCHECK_START_PERIOD=60m \
  ACTUAL_MIN_SPLIT=1 \
  MIN_SPLIT=1 \
  MAX_SPLIT=1 \
  NATIVE_SPAM_GENESIS_DESTINATIONS=1 \
  NATIVE_LOAD_NATIVE_TRANSFER_RUNS=1 \
  NATIVE_LOAD_PAYMENT_LANE_DEPTH=1 \
  NATIVE_LOAD_PAYMENT_LANE_READY_TIMEOUT_SECONDS=360 \
  NATIVE_LOAD_PAYMENT_LANE_READY_POLL_SECONDS=2 \
  NATIVE_LOAD_PAYMENT_LANE_READY_STABLE_OBSERVATIONS=2 \
  "$script_dir/run-fresh-native-cycle.sh" "$env_file"
