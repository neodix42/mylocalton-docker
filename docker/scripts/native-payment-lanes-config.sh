#!/usr/bin/env bash

# Resolve the native-payment-lane activation into the one GlobalVersion record
# written into the zero state.  A payment lane is deliberately an opt-in
# extension of source-signed NativeTransferRun (v5), not a second independent
# feature switch: a v16 lane chain must retain capNativeTransferRuns as well as
# advertise capNativePaymentLanes.
#
# The harness intentionally supports one fixed two-lane topology for now.  It
# gives the benchmark a reproducible split shape and prevents a misleading run
# that happens to start before the first split or that permits a later split to
# separate an otherwise lane-local source/destination pair.
resolve_native_payment_lanes_config() {
  local enabled=${NATIVE_PAYMENT_LANES_ENABLED:-0}
  local requested_version=${NATIVE_PAYMENT_LANES_GLOBAL_VERSION:-16}
  local requested_capability=${NATIVE_PAYMENT_LANES_CAPABILITY:-2048}
  local lane_depth=${NATIVE_PAYMENT_LANE_DEPTH:-1}
  local actual_min_split=${ACTUAL_MIN_SPLIT:-0}
  local min_split=${MIN_SPLIT:-0}
  local max_split=${MAX_SPLIT:-4}

  if ! resolve_native_transfer_runs_config; then
    return $?
  fi

  case "$enabled" in
    0)
      NATIVE_PAYMENT_LANES_EFFECTIVE_VERSION=$NATIVE_TRANSFER_RUNS_EFFECTIVE_VERSION
      NATIVE_PAYMENT_LANES_EFFECTIVE_CAPABILITIES=$NATIVE_TRANSFER_RUNS_EFFECTIVE_CAPABILITY
      ;;
    1)
      if [[ ${NATIVE_TRANSFER_RUNS_ENABLED:-0} != 1 ||
            $NATIVE_TRANSFER_RUNS_EFFECTIVE_VERSION != 15 ||
            $NATIVE_TRANSFER_RUNS_EFFECTIVE_CAPABILITY != 1024 ]]; then
        echo "NATIVE_PAYMENT_LANES_ENABLED=1 requires NATIVE_TRANSFER_RUNS_ENABLED=1 with GlobalVersion 15 and capability 1024" >&2
        return 2
      fi
      if [[ $requested_version != 16 ]]; then
        echo "NATIVE_PAYMENT_LANES_GLOBAL_VERSION must be 16 when NATIVE_PAYMENT_LANES_ENABLED=1, got '$requested_version'" >&2
        return 2
      fi
      if [[ $requested_capability != 2048 ]]; then
        echo "NATIVE_PAYMENT_LANES_CAPABILITY must be 2048 when NATIVE_PAYMENT_LANES_ENABLED=1, got '$requested_capability'" >&2
        return 2
      fi
      if [[ $lane_depth != 1 ]]; then
        echo "NATIVE_PAYMENT_LANE_DEPTH must be 1 for the supported two-lane benchmark topology, got '$lane_depth'" >&2
        return 2
      fi
      if [[ $actual_min_split != $lane_depth || $min_split != $lane_depth || $max_split != $lane_depth ]]; then
        echo "native payment lanes require ACTUAL_MIN_SPLIT, MIN_SPLIT, and MAX_SPLIT to equal NATIVE_PAYMENT_LANE_DEPTH=$lane_depth" >&2
        return 2
      fi
      NATIVE_PAYMENT_LANES_EFFECTIVE_VERSION=$requested_version
      # capNativeTransferRuns (1024) | capNativePaymentLanes (2048).
      NATIVE_PAYMENT_LANES_EFFECTIVE_CAPABILITIES=3072
      ;;
    *)
      echo "NATIVE_PAYMENT_LANES_ENABLED must be 0 or 1, got '$enabled'" >&2
      return 2
      ;;
  esac

  export NATIVE_PAYMENT_LANES_EFFECTIVE_VERSION NATIVE_PAYMENT_LANES_EFFECTIVE_CAPABILITIES
}
