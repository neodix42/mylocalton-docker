#!/bin/sh

# Helpers shared by the native-load entrypoint's opt-in, fixed two-lane
# benchmark path.  They deliberately operate on public .addr files only; the
# generator's private source keys are never logged or copied.

native_payment_lanes_is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

native_payment_lanes_is_positive_uint() {
  native_payment_lanes_is_uint "$1" && [ "$1" -gt 0 ]
}

native_payment_lanes_validate_mode() {
  local enabled=$1 native_runs_enabled=$2 lane_depth=$3 load_lane_depth=$4

  native_payment_lanes_is_uint "$load_lane_depth" || {
    echo "NATIVE_LOAD_PAYMENT_LANE_DEPTH must be a non-negative integer, got '$load_lane_depth'" >&2
    return 2
  }
  case "$enabled" in
    0)
      if [ "$load_lane_depth" != 0 ]; then
        echo "NATIVE_LOAD_PAYMENT_LANE_DEPTH requires NATIVE_PAYMENT_LANES_ENABLED=1" >&2
        return 2
      fi
      ;;
    1)
      if [ "$native_runs_enabled" != 1 ]; then
        echo "NATIVE_PAYMENT_LANES_ENABLED=1 requires NATIVE_LOAD_NATIVE_TRANSFER_RUNS=1" >&2
        return 2
      fi
      if [ "$lane_depth" != 1 ] || [ "$load_lane_depth" != 1 ]; then
        echo "the supported native payment lane benchmark requires NATIVE_PAYMENT_LANE_DEPTH=1 and NATIVE_LOAD_PAYMENT_LANE_DEPTH=1" >&2
        return 2
      fi
      ;;
    *)
      echo "NATIVE_PAYMENT_LANES_ENABLED must be 0 or 1, got '$enabled'" >&2
      return 2
      ;;
  esac
}

native_payment_lanes_address_hex() {
  local address_file=${1:?address file is required}
  local address_hex address_is_hex

  test -r "$address_file" || {
    echo "native payment lane address is not readable: $address_file" >&2
    return 2
  }
  address_hex=$(od -An -v -N 32 -tx1 "$address_file" | tr -d '[:space:]')
  case "$address_hex" in
    *[!0-9A-Fa-f]*|'') address_is_hex=0 ;;
    *) address_is_hex=1 ;;
  esac
  if [ "${#address_hex}" -ne 64 ] || [ "$address_is_hex" -ne 1 ]; then
    echo "native payment lane address must contain a 256-bit account id: $address_file" >&2
    return 2
  fi
  printf '%s\n' "$address_hex"
}

# The benchmark topology fixes depth=1, so the account hash's top bit is the
# lane. This avoids treating textual user-friendly address encodings as an
# authority for shard placement.
native_payment_lanes_address_lane() {
  local address_hex
  address_hex=$(native_payment_lanes_address_hex "$1") || return
  case "$address_hex" in
    [01234567]*) printf '0\n' ;;
    [89aAbBcCdDeEfF]*) printf '1\n' ;;
    *)
      echo "cannot determine a native payment lane from address: $1" >&2
      return 2
      ;;
  esac
}

native_payment_lanes_validate_manifest() {
  local manifest=$1 wallet_dir=$2 source_offset=$3 sources=$4 depth=$5
  local schema manifest_depth lane_count manifest_sources extra end
  local manifest_index lane source_hex destination_hex actual_source_hex actual_destination_hex
  local source_lane destination_lane expected_lane rows_file rows_status row_count=0

  if [ "$depth" != 1 ]; then
    echo "the native payment lane benchmark manifest supports only depth 1, got '$depth'" >&2
    return 2
  fi
  native_payment_lanes_is_uint "$source_offset" || {
    echo "NATIVE_LOAD_SOURCE_OFFSET must be a non-negative integer, got '$source_offset'" >&2
    return 2
  }
  native_payment_lanes_is_positive_uint "$sources" || {
    echo "NATIVE_LOAD_SOURCES must be a positive integer, got '$sources'" >&2
    return 2
  }
  test -r "$manifest" || {
    echo "native payment lane manifest is not readable: $manifest" >&2
    return 2
  }
  IFS=' ' read -r schema manifest_depth lane_count manifest_sources extra < "$manifest" || true
  if [ "$schema" != NATIVE_PAYMENT_LANES_MANIFEST_V1 ] || [ "$manifest_depth" != 1 ] ||
     [ "$lane_count" != 2 ] || ! native_payment_lanes_is_uint "$manifest_sources" || [ -n "${extra:-}" ]; then
    echo "native payment lane manifest has an invalid header: $manifest" >&2
    return 2
  fi
  end=$((source_offset + sources))
  if [ "$end" -gt "$manifest_sources" ]; then
    echo "native payment lane manifest covers $manifest_sources sources, but load requests [$source_offset,$end)" >&2
    return 2
  fi

  # Extract the requested range in one pass.  The former implementation
  # spawned an awk scan for every source, turning a 24k-source benchmark into
  # roughly 600 million manifest-row inspections before traffic could start.
  rows_file=$(mktemp "${TMPDIR:-/tmp}/native-payment-lane-manifest.XXXXXX") || {
    echo "can't create native payment lane manifest validation staging file" >&2
    return 1
  }
  if awk -v start="$source_offset" -v end="$end" '
    NR == 1 { next }
    /^[[:space:]]*#/ || NF == 0 { next }
    $1 ~ /^[0-9]+$/ && ($1 + 0) >= start && ($1 + 0) < end {
      if (NF != 4 || seen[$1]++) {
        invalid = 1
      } else {
        print
      }
    }
    END {
      if (invalid) exit 2
      for (row_index = start; row_index < end; ++row_index) {
        if (!(row_index in seen)) exit 1
      }
    }
  ' "$manifest" > "$rows_file"; then
    :
  else
    rows_status=$?
    rm -f -- "$rows_file"
    if [ "$rows_status" -eq 2 ]; then
      echo "native payment lane manifest has a duplicate or malformed requested row: $manifest" >&2
    else
      echo "native payment lane manifest must contain exactly one row for every requested source" >&2
    fi
    return 2
  fi

  while IFS=' ' read -r manifest_index lane source_hex destination_hex extra; do
    row_count=$((row_count + 1))
    if [ "$manifest_index" -lt "$source_offset" ] || [ "$manifest_index" -ge "$end" ] ||
       { [ "$lane" != 0 ] && [ "$lane" != 1 ]; } ||
       [ -z "${source_hex:-}" ] || [ -z "${destination_hex:-}" ] || [ -n "${extra:-}" ]; then
      rm -f -- "$rows_file"
      echo "native payment lane manifest row is invalid for source $manifest_index" >&2
      return 2
    fi
    expected_lane=$((manifest_index % 2))
    if [ "$lane" -ne "$expected_lane" ]; then
      rm -f -- "$rows_file"
      echo "native payment lane manifest is not balanced: source $manifest_index is lane $lane, expected $expected_lane" >&2
      return 2
    fi
    actual_source_hex=$(native_payment_lanes_address_hex "$wallet_dir/source-$manifest_index.addr") || {
      rm -f -- "$rows_file"
      return 2
    }
    actual_destination_hex=$(native_payment_lanes_address_hex "$wallet_dir/dest-$manifest_index.addr") || {
      rm -f -- "$rows_file"
      return 2
    }
    if [ "$source_hex" != "$actual_source_hex" ] || [ "$destination_hex" != "$actual_destination_hex" ]; then
      rm -f -- "$rows_file"
      echo "native payment lane manifest does not match wallet addresses for source $manifest_index" >&2
      return 2
    fi
    case "$actual_source_hex" in
      [01234567]*) source_lane=0 ;;
      [89aAbBcCdDeEfF]*) source_lane=1 ;;
      *)
        rm -f -- "$rows_file"
        echo "cannot determine a native payment lane from source address: $wallet_dir/source-$manifest_index.addr" >&2
        return 2
        ;;
    esac
    case "$actual_destination_hex" in
      [01234567]*) destination_lane=0 ;;
      [89aAbBcCdDeEfF]*) destination_lane=1 ;;
      *)
        rm -f -- "$rows_file"
        echo "cannot determine a native payment lane from destination address: $wallet_dir/dest-$manifest_index.addr" >&2
        return 2
        ;;
    esac
    if [ "$source_lane" != "$lane" ] || [ "$destination_lane" != "$lane" ]; then
      rm -f -- "$rows_file"
      echo "native payment lane source/destination pair is not same-lane for source $manifest_index" >&2
      return 2
    fi
    test -r "$wallet_dir/source-$manifest_index.pk" || {
      rm -f -- "$rows_file"
      echo "native payment lane source key is not readable: $wallet_dir/source-$manifest_index.pk" >&2
      return 2
    }
    test -r "$wallet_dir/dest-$manifest_index.pub" || {
      rm -f -- "$rows_file"
      echo "native payment lane destination public key is not readable: $wallet_dir/dest-$manifest_index.pub" >&2
      return 2
    }
  done < "$rows_file"
  rm -f -- "$rows_file"
  if [ "$row_count" -ne "$sources" ]; then
    echo "native payment lane manifest did not yield every requested source" >&2
    return 2
  fi
}

native_payment_lanes_shard_prefixes() {
  # allshards is anchored at one masterchain block. Retain only basechain
  # leaf prefixes; the rest of the verbose lite-client output is diagnostic.
  printf '%s\n' "$1" |
    sed -n 's/^shard #[0-9][0-9]* : (0,\([0-9A-Fa-f]\{16\}\),[0-9][0-9]*):.*/\1/p' |
    tr '[:lower:]' '[:upper:]' |
    sort -u
}

native_payment_lanes_shards_are_ready() {
  local prefixes expected
  prefixes=$(native_payment_lanes_shard_prefixes "$1")
  expected='4000000000000000
C000000000000000'
  [ "$prefixes" = "$expected" ]
}

native_payment_lanes_wait_for_shards() {
  local config=$1 timeout_seconds=$2 poll_seconds=$3 stable_observations=$4
  local query_timeout=${NATIVE_LOAD_PAYMENT_LANE_LITESERVER_TIMEOUT_SECONDS:-5}
  local lite_client=${NATIVE_LOAD_LITE_CLIENT_BIN:-lite-client}
  local started_at now attempt=0 stable=0 output prefixes

  native_payment_lanes_is_positive_uint "$timeout_seconds" || {
    echo "NATIVE_LOAD_PAYMENT_LANE_READY_TIMEOUT_SECONDS must be a positive integer, got '$timeout_seconds'" >&2
    return 2
  }
  native_payment_lanes_is_positive_uint "$poll_seconds" || {
    echo "NATIVE_LOAD_PAYMENT_LANE_READY_POLL_SECONDS must be a positive integer, got '$poll_seconds'" >&2
    return 2
  }
  native_payment_lanes_is_positive_uint "$stable_observations" || {
    echo "NATIVE_LOAD_PAYMENT_LANE_READY_STABLE_OBSERVATIONS must be a positive integer, got '$stable_observations'" >&2
    return 2
  }
  native_payment_lanes_is_positive_uint "$query_timeout" || {
    echo "NATIVE_LOAD_PAYMENT_LANE_LITESERVER_TIMEOUT_SECONDS must be a positive integer, got '$query_timeout'" >&2
    return 2
  }
  test -r "$config" || {
    echo "global config is not readable for native payment lane readiness: $config" >&2
    return 2
  }
  command -v "$lite_client" >/dev/null 2>&1 || {
    echo "lite-client is not available for native payment lane readiness: $lite_client" >&2
    return 2
  }

  started_at=$(date +%s)
  while :; do
    attempt=$((attempt + 1))
    if output=$(timeout --signal=TERM --kill-after=1s "${query_timeout}s" \
        "$lite_client" -C "$config" -t "$query_timeout" -c allshards 2>&1); then
      prefixes=$(native_payment_lanes_shard_prefixes "$output" | tr '\n' ',')
      if native_payment_lanes_shards_are_ready "$output"; then
        stable=$((stable + 1))
        printf '{"schema":"native-payment-lane-readiness-v1","event":"ready_observation","attempt":%s,"stable_observations":%s,"required_stable_observations":%s,"basechain_prefixes":"%s"}\n' \
          "$attempt" "$stable" "$stable_observations" "${prefixes%,}"
        if [ "$stable" -ge "$stable_observations" ]; then
          return 0
        fi
      else
        stable=0
        printf '{"schema":"native-payment-lane-readiness-v1","event":"waiting_for_two_lanes","attempt":%s,"basechain_prefixes":"%s"}\n' \
          "$attempt" "${prefixes%,}" >&2
      fi
    else
      stable=0
      printf '{"schema":"native-payment-lane-readiness-v1","event":"liteserver_query_failed","attempt":%s}\n' \
        "$attempt" >&2
    fi
    now=$(date +%s)
    if [ $((now - started_at)) -ge "$timeout_seconds" ]; then
      echo "timed out waiting for two masterchain-anchored native payment lanes after ${timeout_seconds}s" >&2
      return 1
    fi
    sleep "$poll_seconds"
  done
}
