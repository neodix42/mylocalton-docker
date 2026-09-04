#!/usr/bin/env bash

# Shared environment for the fixed-depth native payment-lane benchmark. Keep
# this in one place so a non-destructive throughput ladder cannot accidentally
# reuse a lane genesis with the default scalar configuration.
native_payment_lanes_profile_env() {
  local lane_depth=1

  # The runners always pass an explicit depth. Retain the original command-
  # first form as a depth-1 compatibility path for callers that source this
  # helper directly.
  case "${1:-}" in
    1|2)
      lane_depth=$1
      shift
      ;;
    ''|*[!0-9]*) ;;
    *)
      echo "native payment-lane depth must be 1 or 2, got '$1'" >&2
      return 2
      ;;
  esac

  env \
    NATIVE_TRANSFER_RUNS_ENABLED=1 \
    NATIVE_TRANSFER_RUNS_GLOBAL_VERSION=15 \
    NATIVE_TRANSFER_RUNS_CAPABILITY=1024 \
    NATIVE_PAYMENT_LANES_ENABLED=1 \
    NATIVE_PAYMENT_LANES_GLOBAL_VERSION=16 \
    NATIVE_PAYMENT_LANES_CAPABILITY=2048 \
    NATIVE_PAYMENT_LANE_DEPTH="$lane_depth" \
    NATIVE_PAYMENT_LANE_WALLET_RETRIES=128 \
    NATIVE_PAYMENT_LANE_WALLET_PARALLELISM=12 \
    GENESIS_HEALTHCHECK_START_PERIOD=60m \
    ACTUAL_MIN_SPLIT="$lane_depth" \
    MIN_SPLIT="$lane_depth" \
    MAX_SPLIT="$lane_depth" \
    NATIVE_SPAM_GENESIS_DESTINATIONS=1 \
    NATIVE_LOAD_NATIVE_TRANSFER_RUNS=1 \
    NATIVE_LOAD_PAYMENT_LANE_DEPTH="$lane_depth" \
    NATIVE_LOAD_PAYMENT_LANE_READY_TIMEOUT_SECONDS=360 \
    NATIVE_LOAD_PAYMENT_LANE_READY_POLL_SECONDS=2 \
    NATIVE_LOAD_PAYMENT_LANE_READY_STABLE_OBSERVATIONS=2 \
    "$@"
}
