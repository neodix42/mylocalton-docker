#!/bin/bash
set -euo pipefail

NATIVE_TPS_INTERVAL_SECONDS=${NATIVE_TPS_INTERVAL_SECONDS:-5}
NATIVE_TPS_WORKCHAIN=${NATIVE_TPS_WORKCHAIN:-0}
NATIVE_TPS_PRINT_LIMIT=${NATIVE_TPS_PRINT_LIMIT:-1000000}
NATIVE_TPS_LITE_TIMEOUT_SECONDS=${NATIVE_TPS_LITE_TIMEOUT_SECONDS:-10}
NATIVE_TPS_LITESERVER_ADDR=${NATIVE_TPS_LITESERVER_ADDR:-127.0.0.1:40004}
NATIVE_TPS_VERBOSE_BLOCKS=${NATIVE_TPS_VERBOSE_BLOCKS:-1}
NATIVE_TPS_BACKFILL_BLOCKS=${NATIVE_TPS_BACKFILL_BLOCKS:-0}
NATIVE_TPS_MAX_BLOCKS_PER_INTERVAL=${NATIVE_TPS_MAX_BLOCKS_PER_INTERVAL:-1000}

LITE_CLIENT=/usr/local/bin/lite-client
LITESERVER_PUB=/var/ton-work/db/liteserver.pub
BLOCK_ID_ERE='[(]-?[0-9]+,[0-9A-Fa-f]+,[0-9]+[)]:[0-9A-Fa-f]{64}:[0-9A-Fa-f]{64}'

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

validate_int_range() {
  local name=$1
  local value=$2
  local min=$3
  local max=$4

  if [[ ! "$value" =~ ^-?[0-9]+$ ]]; then
    echo "$name must be an integer, got '$value'" >&2
    exit 2
  fi
  if (( value < min || value > max )); then
    echo "$name must be between $min and $max, got '$value'" >&2
    exit 2
  fi
}

validate_bool() {
  local name=$1
  local value=$2

  if [[ "$value" != "0" && "$value" != "1" ]]; then
    echo "$name must be 0 or 1, got '$value'" >&2
    exit 2
  fi
}

validate_uint_range NATIVE_TPS_INTERVAL_SECONDS "$NATIVE_TPS_INTERVAL_SECONDS" 1 3600
validate_int_range NATIVE_TPS_WORKCHAIN "$NATIVE_TPS_WORKCHAIN" -2147483648 2147483647
validate_uint_range NATIVE_TPS_PRINT_LIMIT "$NATIVE_TPS_PRINT_LIMIT" 1024 100000000
validate_uint_range NATIVE_TPS_LITE_TIMEOUT_SECONDS "$NATIVE_TPS_LITE_TIMEOUT_SECONDS" 1 3600
validate_bool NATIVE_TPS_VERBOSE_BLOCKS "$NATIVE_TPS_VERBOSE_BLOCKS"
validate_uint_range NATIVE_TPS_BACKFILL_BLOCKS "$NATIVE_TPS_BACKFILL_BLOCKS" 0 1000000
validate_uint_range NATIVE_TPS_MAX_BLOCKS_PER_INTERVAL "$NATIVE_TPS_MAX_BLOCKS_PER_INTERVAL" 1 1000000

run_lite_client() {
  local command=$1
  local print_limit=${2:-1024}

  "$LITE_CLIENT" \
    -a "$NATIVE_TPS_LITESERVER_ADDR" \
    -p "$LITESERVER_PUB" \
    -t "$NATIVE_TPS_LITE_TIMEOUT_SECONDS" \
    -L "$print_limit" \
    -c "$command"
}

extract_first_block_id() {
  grep -Eo "$BLOCK_ID_ERE" | head -n1
}

parse_block_id_fields() {
  local block_id=$1
  local simple
  local wc
  local shard
  local seqno

  simple=${block_id%%:*}
  simple=${simple#\(}
  simple=${simple%\)}
  IFS=, read -r wc shard seqno <<< "$simple"
  printf '%s\t%s\t%s\n' "$wc" "$shard" "$seqno"
}

get_last_masterchain_block() {
  local output
  local block_id

  output=$(run_lite_client "last" 1024 2>&1)
  block_id=$(printf '%s\n' "$output" | grep "last masterchain block is" | extract_first_block_id || true)
  if [ -z "$block_id" ]; then
    echo "Cannot read last masterchain block" >&2
    printf '%s\n' "$output" >&2
    return 1
  fi

  printf '%s\n' "$block_id"
}

list_top_shards() {
  local mc_block=$1
  local output
  local line
  local block_id
  local fields
  local wc
  local shard
  local seqno

  output=$(run_lite_client "allshards $mc_block" 100000 2>&1)
  while IFS= read -r line; do
    block_id=$(printf '%s\n' "$line" | extract_first_block_id || true)
    if [ -z "$block_id" ]; then
      continue
    fi
    fields=$(parse_block_id_fields "$block_id")
    IFS=$'\t' read -r wc shard seqno <<< "$fields"
    printf '%s\t%s\t%s\t%s\n' "$wc" "$shard" "$seqno" "$block_id"
  done < <(printf '%s\n' "$output" | grep -E "shard #[0-9]+ : $BLOCK_ID_ERE" || true)
}

lookup_block_by_seqno() {
  local wc=$1
  local shard=$2
  local seqno=$3
  local output
  local block_id

  output=$(run_lite_client "byseqno ${wc}:${shard} ${seqno}" 1024 2>&1)
  block_id=$(printf '%s\n' "$output" | grep "block header of" | extract_first_block_id || true)
  if [ -z "$block_id" ]; then
    block_id=$(printf '%s\n' "$output" | grep "BLK#" | extract_first_block_id || true)
  fi
  if [ -z "$block_id" ]; then
    echo "Cannot look up block ${wc}:${shard}:${seqno}" >&2
    printf '%s\n' "$output" >&2
    return 1
  fi

  printf '%s\n' "$block_id"
}

count_native_transactions() {
  local block_id=$1
  local output
  local compact_transfers
  local debits
  local credits

  output=$(run_lite_client "dumpblock $block_id" "$NATIVE_TPS_PRINT_LIMIT" 2>&1)
  compact_transfers=$(
    printf '%s\n' "$output" | awk '
      /native_transfer_batch/ {
        for (i = 1; i <= NF; ++i) {
          if ($i ~ /^transfers=/) {
            split($i, kv, "=")
            if (kv[2] ~ /^[0-9]+$/) {
              print kv[2]
              exit
            }
          }
        }
      }'
  )
  if [ -n "$compact_transfers" ]; then
    debits=$compact_transfers
    credits=$compact_transfers
  else
    debits=$(printf '%s\n' "$output" | grep -c "trans_native_transfer_debit" || true)
    credits=$(printf '%s\n' "$output" | grep -c "trans_native_transfer_credit" || true)
  fi
  printf '%s\t%s\n' "$debits" "$credits"
}

if [ ! -x "$LITE_CLIENT" ]; then
  echo "lite-client is missing or not executable: $LITE_CLIENT" >&2
  exit 3
fi
if [ ! -f "$LITESERVER_PUB" ]; then
  echo "Lite-server public key is missing: $LITESERVER_PUB" >&2
  exit 3
fi

declare -A LAST_SEQNO_BY_SHARD

initialize_shards() {
  local mc_block
  local shards
  local wc
  local shard
  local seqno
  local block_id
  local start_seqno
  local initialized=0

  mc_block=$(get_last_masterchain_block)
  shards=$(list_top_shards "$mc_block")
  while IFS=$'\t' read -r wc shard seqno block_id; do
    if [ -z "${wc:-}" ] || [ "$wc" != "$NATIVE_TPS_WORKCHAIN" ]; then
      continue
    fi
    start_seqno=$seqno
    if (( NATIVE_TPS_BACKFILL_BLOCKS > 0 )); then
      if (( seqno > NATIVE_TPS_BACKFILL_BLOCKS )); then
        start_seqno=$((seqno - NATIVE_TPS_BACKFILL_BLOCKS))
      else
        start_seqno=0
      fi
    fi
    LAST_SEQNO_BY_SHARD["$wc:$shard"]=$start_seqno
    initialized=$((initialized + 1))
    echo "tracking shard ${wc}:${shard}, start_seqno=${start_seqno}, top_seqno=${seqno}"
  done <<< "$shards"

  if (( initialized == 0 )); then
    echo "No workchain ${NATIVE_TPS_WORKCHAIN} shard found yet; waiting for allshards to include it."
  fi
}

print_header() {
  echo "Native TPS monitor"
  echo "NATIVE_TPS_INTERVAL_SECONDS=$NATIVE_TPS_INTERVAL_SECONDS"
  echo "NATIVE_TPS_WORKCHAIN=$NATIVE_TPS_WORKCHAIN"
  echo "NATIVE_TPS_PRINT_LIMIT=$NATIVE_TPS_PRINT_LIMIT"
  echo "NATIVE_TPS_BACKFILL_BLOCKS=$NATIVE_TPS_BACKFILL_BLOCKS"
  echo "NATIVE_TPS_MAX_BLOCKS_PER_INTERVAL=$NATIVE_TPS_MAX_BLOCKS_PER_INTERVAL"
  echo "Counting compact native batches when present, otherwise debit+credit descriptors."
  echo "Native transfer TPS is counted by debit descriptors; account-transaction TPS is debit+credit."
}

print_header
initialize_shards

LAST_SAMPLE_TS=$(date +%s)

while true; do
  sleep "$NATIVE_TPS_INTERVAL_SECONDS"

  INTERVAL_BLOCKS=0
  INTERVAL_NATIVE_DEBITS=0
  INTERVAL_NATIVE_CREDITS=0
  INTERVAL_FAILED_BLOCKS=0
  INTERVAL_SKIPPED_BLOCKS=0

  MC_BLOCK=$(get_last_masterchain_block)
  SHARDS=$(list_top_shards "$MC_BLOCK")

  while IFS=$'\t' read -r WC SHARD TOP_SEQNO TOP_BLOCK_ID; do
    if [ -z "${WC:-}" ] || [ "$WC" != "$NATIVE_TPS_WORKCHAIN" ]; then
      continue
    fi

    KEY="$WC:$SHARD"
    if [ -z "${LAST_SEQNO_BY_SHARD[$KEY]+set}" ]; then
      LAST_SEQNO_BY_SHARD[$KEY]=$TOP_SEQNO
      echo "tracking new shard ${KEY}, top_seqno=${TOP_SEQNO}"
      continue
    fi

    LAST_SEQNO=${LAST_SEQNO_BY_SHARD[$KEY]}
    if (( TOP_SEQNO <= LAST_SEQNO )); then
      continue
    fi

    FROM_SEQNO=$((LAST_SEQNO + 1))
    TO_SEQNO=$TOP_SEQNO
    BLOCK_COUNT=$((TO_SEQNO - FROM_SEQNO + 1))
    if (( BLOCK_COUNT > NATIVE_TPS_MAX_BLOCKS_PER_INTERVAL )); then
      INTERVAL_SKIPPED_BLOCKS=$((INTERVAL_SKIPPED_BLOCKS + BLOCK_COUNT - NATIVE_TPS_MAX_BLOCKS_PER_INTERVAL))
      FROM_SEQNO=$((TO_SEQNO - NATIVE_TPS_MAX_BLOCKS_PER_INTERVAL + 1))
      echo "shard ${KEY} advanced by ${BLOCK_COUNT} blocks; scanning only latest ${NATIVE_TPS_MAX_BLOCKS_PER_INTERVAL}"
    fi

    for ((SEQNO = FROM_SEQNO; SEQNO <= TO_SEQNO; ++SEQNO)); do
      BLOCK_ID=$(lookup_block_by_seqno "$WC" "$SHARD" "$SEQNO" || true)
      if [ -z "$BLOCK_ID" ]; then
        INTERVAL_FAILED_BLOCKS=$((INTERVAL_FAILED_BLOCKS + 1))
        continue
      fi

      COUNTS=$(count_native_transactions "$BLOCK_ID" || true)
      if [ -z "$COUNTS" ]; then
        DEBITS=0
        CREDITS=0
        INTERVAL_FAILED_BLOCKS=$((INTERVAL_FAILED_BLOCKS + 1))
      else
        IFS=$'\t' read -r DEBITS CREDITS <<< "$COUNTS"
      fi

      NATIVE_ACCOUNT_TX=$((DEBITS + CREDITS))
      INTERVAL_BLOCKS=$((INTERVAL_BLOCKS + 1))
      INTERVAL_NATIVE_DEBITS=$((INTERVAL_NATIVE_DEBITS + DEBITS))
      INTERVAL_NATIVE_CREDITS=$((INTERVAL_NATIVE_CREDITS + CREDITS))

      if [ "$NATIVE_TPS_VERBOSE_BLOCKS" = "1" ]; then
        printf '[%s] block=%s native_account_tx=%d native_transfers=%d debits=%d credits=%d\n' \
          "$(date '+%Y-%m-%d %H:%M:%S')" "$BLOCK_ID" "$NATIVE_ACCOUNT_TX" "$DEBITS" "$DEBITS" "$CREDITS"
      fi
    done

    LAST_SEQNO_BY_SHARD[$KEY]=$TOP_SEQNO
  done <<< "$SHARDS"

  NOW_TS=$(date +%s)
  ELAPSED=$((NOW_TS - LAST_SAMPLE_TS))
  LAST_SAMPLE_TS=$NOW_TS
  if (( ELAPSED < 1 )); then
    ELAPSED=1
  fi

  INTERVAL_NATIVE_ACCOUNT_TX=$((INTERVAL_NATIVE_DEBITS + INTERVAL_NATIVE_CREDITS))
  awk \
    -v ts="$(date '+%Y-%m-%d %H:%M:%S')" \
    -v elapsed="$ELAPSED" \
    -v blocks="$INTERVAL_BLOCKS" \
    -v debits="$INTERVAL_NATIVE_DEBITS" \
    -v credits="$INTERVAL_NATIVE_CREDITS" \
    -v account_tx="$INTERVAL_NATIVE_ACCOUNT_TX" \
    -v failed="$INTERVAL_FAILED_BLOCKS" \
    -v skipped="$INTERVAL_SKIPPED_BLOCKS" \
    'BEGIN {
      printf "[%s] interval=%ds blocks=%d blocks_per_sec=%.2f native_transfers=%d native_transfer_tps=%.2f native_account_tx=%d native_account_tx_tps=%.2f debits=%d credits=%d failed_blocks=%d skipped_blocks=%d\n",
        ts, elapsed, blocks, blocks / elapsed, debits, debits / elapsed, account_tx, account_tx / elapsed, debits, credits, failed, skipped
    }'
done
