#!/usr/bin/env bash

# Resolve the native-payment-lane activation into the one GlobalVersion record
# written into the zero state.  A payment lane is deliberately an opt-in
# extension of source-signed NativeTransferRun (v5), not a second independent
# feature switch: a v16 lane chain must retain capNativeTransferRuns as well as
# advertise capNativePaymentLanes.
#
# The harness intentionally supports only the fixed depth-1 and depth-2
# topologies. They give the benchmark a reproducible split shape and prevent a
# misleading run that happens to start before every required split or that
# permits a later split to separate an otherwise lane-local pair.
native_payment_lanes_existing_genesis_marker_is_valid() {
  local marker_file=$1 expected_depth=${2:-1}
  local expected_lane_count

  if [[ $expected_depth != 1 && $expected_depth != 2 ]] || [[ ! -r $marker_file ]]; then
    return 2
  fi
  expected_lane_count=$((1 << expected_depth))

  # Parse the marker once. Every activation fact must occur exactly once and
  # match the requested topology. Depth-1 markers predate the lane-count fact,
  # so they may omit it; when present it is still unique and exact. Depth 2 has
  # no legacy representation and always requires one explicit count.
  awk -v expected_depth="$expected_depth" -v expected_lane_count="$expected_lane_count" '
    BEGIN {
      required["NATIVE_PAYMENT_LANES_ENABLED"] = "1"
      required["NATIVE_PAYMENT_LANE_DEPTH"] = expected_depth
      required["NATIVE_TRANSFER_RUNS_ENABLED"] = "1"
      required["NATIVE_PAYMENT_LANES_EFFECTIVE_VERSION"] = "16"
      required["NATIVE_PAYMENT_LANES_EFFECTIVE_CAPABILITIES"] = "3072"
      required["NATIVE_PAYMENT_LANE_ACTUAL_MIN_SPLIT"] = expected_depth
      required["NATIVE_PAYMENT_LANE_MIN_SPLIT"] = expected_depth
      required["NATIVE_PAYMENT_LANE_MAX_SPLIT"] = expected_depth
      lane_count_key = "NATIVE_PAYMENT_LANE_COUNT"
      valid = 1
    }
    {
      separator = index($0, "=")
      if (separator == 0) {
        next
      }
      key = substr($0, 1, separator - 1)
      if (key == lane_count_key) {
        ++lane_count_records
        if ($0 != lane_count_key "=" expected_lane_count) {
          valid = 0
        }
      } else if (key in required) {
        ++records[key]
        if ($0 != key "=" required[key]) {
          valid = 0
        }
      }
    }
    END {
      for (key in required) {
        if (records[key] != 1) {
          valid = 0
        }
      }
      if ((expected_depth == 2 && lane_count_records != 1) ||
          (expected_depth == 1 && lane_count_records > 1)) {
        valid = 0
      }
      exit valid ? 0 : 1
    }
  ' "$marker_file"
}

resolve_native_payment_lanes_config() {
  local enabled=${NATIVE_PAYMENT_LANES_ENABLED:-0}
  local requested_version=${NATIVE_PAYMENT_LANES_GLOBAL_VERSION:-16}
  local requested_capability=${NATIVE_PAYMENT_LANES_CAPABILITY:-2048}
  local lane_depth=${NATIVE_PAYMENT_LANE_DEPTH:-1}
  local actual_min_split=${ACTUAL_MIN_SPLIT:-0}
  local min_split=${MIN_SPLIT:-0}
  local max_split=${MAX_SPLIT:-4}

  resolve_native_transfer_runs_config || return $?

  case "$enabled" in
    0)
      NATIVE_PAYMENT_LANES_EFFECTIVE_VERSION=$NATIVE_TRANSFER_RUNS_EFFECTIVE_VERSION
      NATIVE_PAYMENT_LANES_EFFECTIVE_CAPABILITIES=$NATIVE_TRANSFER_RUNS_EFFECTIVE_CAPABILITY
      unset NATIVE_PAYMENT_LANE_COUNT
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
      if [[ $lane_depth != 1 && $lane_depth != 2 ]]; then
        echo "NATIVE_PAYMENT_LANE_DEPTH must be 1 or 2 for a supported fixed benchmark topology, got '$lane_depth'" >&2
        return 2
      fi
      if [[ $actual_min_split != $lane_depth || $min_split != $lane_depth || $max_split != $lane_depth ]]; then
        echo "native payment lanes require ACTUAL_MIN_SPLIT, MIN_SPLIT, and MAX_SPLIT to equal NATIVE_PAYMENT_LANE_DEPTH=$lane_depth" >&2
        return 2
      fi
      NATIVE_PAYMENT_LANES_EFFECTIVE_VERSION=$requested_version
      # capNativeTransferRuns (1024) | capNativePaymentLanes (2048).
      NATIVE_PAYMENT_LANES_EFFECTIVE_CAPABILITIES=3072
      NATIVE_PAYMENT_LANE_COUNT=$((1 << lane_depth))
      export NATIVE_PAYMENT_LANE_COUNT
      ;;
    *)
      echo "NATIVE_PAYMENT_LANES_ENABLED must be 0 or 1, got '$enabled'" >&2
      return 2
      ;;
  esac

  export NATIVE_PAYMENT_LANES_EFFECTIVE_VERSION NATIVE_PAYMENT_LANES_EFFECTIVE_CAPABILITIES
}
