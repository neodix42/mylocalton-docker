#!/usr/bin/env bash

# Resolve the future v5 NativeTransferRun config-parameter values before Fift
# writes the zero state. Keeping this in a sourceable helper lets the static
# test cover the safety boundary without creating a network.
resolve_native_transfer_runs_config() {
  local enabled=${NATIVE_TRANSFER_RUNS_ENABLED:-0}
  local legacy_version=${VERSION_CAPABILITIES:-14}
  local requested_version=${NATIVE_TRANSFER_RUNS_GLOBAL_VERSION:-15}
  local requested_capability=${NATIVE_TRANSFER_RUNS_CAPABILITY:-1024}

  case "$enabled" in
    0)
      NATIVE_TRANSFER_RUNS_EFFECTIVE_VERSION=$legacy_version
      NATIVE_TRANSFER_RUNS_EFFECTIVE_CAPABILITY=0
      ;;
    1)
      if [[ $requested_version != 15 ]]; then
        echo "NATIVE_TRANSFER_RUNS_GLOBAL_VERSION must be 15 when NATIVE_TRANSFER_RUNS_ENABLED=1, got '$requested_version'" >&2
        return 2
      fi
      if [[ $requested_capability != 1024 ]]; then
        echo "NATIVE_TRANSFER_RUNS_CAPABILITY must be 1024 when NATIVE_TRANSFER_RUNS_ENABLED=1, got '$requested_capability'" >&2
        return 2
      fi
      NATIVE_TRANSFER_RUNS_EFFECTIVE_VERSION=$requested_version
      NATIVE_TRANSFER_RUNS_EFFECTIVE_CAPABILITY=$requested_capability
      ;;
    *)
      echo "NATIVE_TRANSFER_RUNS_ENABLED must be 0 or 1, got '$enabled'" >&2
      return 2
      ;;
  esac

  export NATIVE_TRANSFER_RUNS_EFFECTIVE_VERSION NATIVE_TRANSFER_RUNS_EFFECTIVE_CAPABILITY
}
