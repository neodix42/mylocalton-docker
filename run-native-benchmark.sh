#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: ./run-native-benchmark.sh [ENV_FILE] [RESULT_DIR]

Runs session-stats and the native load generator, samples host/container
resources for the complete run, and writes a machine-readable summary.

Defaults:
  ENV_FILE    .env.physical
  RESULT_DIR  benchmark-results/<UTC timestamp>

Run this script itself with sudo when Docker requires root access. Optional:
  BENCHMARK_HOST_SAMPLE_SECONDS=1
  BENCHMARK_RECREATE_GENESIS=1   # otherwise reuse an already-healthy genesis
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

env_file=${1:-.env.physical}
run_id=$(date -u +%Y%m%dT%H%M%SZ)
result_dir=${2:-benchmark-results/$run_id}
host_sample_seconds=${BENCHMARK_HOST_SAMPLE_SECONDS:-1}
container_name=native-load-generator

for command_name in docker jq awk sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "required command is not installed: $command_name" >&2
    exit 2
  }
done

docker compose version >/dev/null 2>&1 || {
  echo "Docker Compose v2 is required" >&2
  exit 2
}
docker info >/dev/null 2>&1 || {
  echo "cannot access Docker; run this script with sudo or configure Docker access" >&2
  exit 2
}
test -r "$env_file" || { echo "environment file is not readable: $env_file" >&2; exit 2; }
case "$host_sample_seconds" in
  ''|*[!0-9.]*|.*|*.)
    echo "BENCHMARK_HOST_SAMPLE_SECONDS must be a positive number" >&2
    exit 2
    ;;
esac
awk -v seconds="$host_sample_seconds" 'BEGIN { exit !(seconds > 0) }' || {
  echo "BENCHMARK_HOST_SAMPLE_SECONDS must be greater than zero" >&2
  exit 2
}

if [[ -d "$result_dir" && -n $(find "$result_dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
  if [[ $# -lt 2 ]]; then
    result_dir=${result_dir}-$$
  else
    echo "result directory is not empty: $result_dir" >&2
    exit 2
  fi
fi
mkdir -p "$result_dir"
result_dir=$(cd "$result_dir" && pwd)
container_stats_file=$result_dir/container-resources.jsonl
host_stats_file=$result_dir/host-resources.jsonl
generator_log_file=$result_dir/native-load-generator.log
generator_summary_file=$result_dir/generator-summary.json
resource_summary_file=$result_dir/resource-summary.json
session_stats_summary_file=$result_dir/session-stats-summary.json
validator_session_stats_file=$result_dir/validator-session-stats.jsonl
validator_pipeline_summary_file=$result_dir/validator-pipeline-summary.json
runtime_file=$result_dir/container-runtime.json
metadata_file=$result_dir/run-metadata.json
summary_file=$result_dir/benchmark-summary.json
: >"$container_stats_file"
: >"$host_stats_file"

compose=(docker compose --env-file "$env_file")
collector_pids=()
interrupted=0

stop_collectors() {
  local pid
  for pid in "${collector_pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${collector_pids[@]:-}"; do
    wait "$pid" 2>/dev/null || true
  done
  collector_pids=()
}

handle_signal() {
  interrupted=1
  echo "interrupt received; stopping native load generator" >&2
  docker stop --timeout 10 "$container_name" >/dev/null 2>&1 || true
}

trap handle_signal INT TERM
trap stop_collectors EXIT

read_host_cpu() {
  awk '/^cpu / {
    total = 0
    for (i = 2; i <= NF; i++) total += $i
    idle = $5 + $6
    printf "%.0f %.0f\n", total, idle
    exit
  }' /proc/stat
}

collect_host_stats() {
  local previous_total previous_idle current_total current_idle
  local delta_total delta_idle cpu_percent mem_total_kib mem_available_kib
  read -r previous_total previous_idle < <(read_host_cpu)
  while docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -qx true; do
    sleep "$host_sample_seconds"
    read -r current_total current_idle < <(read_host_cpu)
    delta_total=$((current_total - previous_total))
    delta_idle=$((current_idle - previous_idle))
    cpu_percent=$(awk -v total="$delta_total" -v idle="$delta_idle" \
      'BEGIN { if (total > 0) printf "%.3f", 100 * (total - idle) / total; else print "0" }')
    mem_total_kib=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
    mem_available_kib=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)
    jq -cn \
      --arg sampled_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson sampled_at_epoch "$(date +%s)" \
      --argjson cpu_percent "$cpu_percent" \
      --argjson memory_used_bytes "$(((mem_total_kib - mem_available_kib) * 1024))" \
      --argjson memory_total_bytes "$((mem_total_kib * 1024))" \
      --arg load_average "$(cut -d' ' -f1-3 /proc/loadavg)" \
      '{schema:"native-benchmark-host-resource-v1",$sampled_at,$sampled_at_epoch,
        $cpu_percent,$memory_used_bytes,$memory_total_bytes,$load_average}' \
      >>"$host_stats_file"
    previous_total=$current_total
    previous_idle=$current_idle
  done
}

collect_container_stats() {
  local sampled_at_epoch
  # Do not add another sleep here: `docker stats --no-stream` already takes a
  # counter interval. Repeating it yields roughly two-second portable samples.
  while docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -qx true; do
    sampled_at_epoch=$(date +%s)
    docker stats --no-stream --format '{{json .}}' \
      genesis "$container_name" session-stats 2>>"$result_dir/docker-stats.stderr.log" |
      awk -v sampled_at_epoch="$sampled_at_epoch" '{
        sub(/}$/, ",\"schema\":\"native-benchmark-container-resource-v1\",\"sampled_at_epoch\":" sampled_at_epoch "}")
        print
      }' >>"$container_stats_file"
  done
}

genesis_health=$(docker inspect -f \
  '{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
  genesis 2>/dev/null || true)
if [[ $genesis_health == "true healthy" && ${BENCHMARK_RECREATE_GENESIS:-0} != 1 ]]; then
  desired_genesis_hash=$("${compose[@]}" config --hash genesis | awk '$1 == "genesis" {print $2}')
  running_genesis_hash=$(docker inspect -f \
    '{{index .Config.Labels "com.docker.compose.config-hash"}}' genesis 2>/dev/null || true)
  desired_genesis_image=$("${compose[@]}" config --images genesis | tail -n 1)
  desired_genesis_image_id=$(docker image inspect -f '{{.Id}}' "$desired_genesis_image" 2>/dev/null || true)
  running_genesis_image_id=$(docker inspect -f '{{.Image}}' genesis 2>/dev/null || true)
  if [[ -z $desired_genesis_hash || $running_genesis_hash != "$desired_genesis_hash" ||
        -z $desired_genesis_image_id || $running_genesis_image_id != "$desired_genesis_image_id" ]]; then
    echo "healthy genesis does not match $env_file or the current local image" >&2
    echo "recreate it explicitly, or rerun with BENCHMARK_RECREATE_GENESIS=1" >&2
    exit 2
  fi
  echo "Reusing the matching, already-healthy genesis container; starting session-stats only"
  "${compose[@]}" --profile session-stats up -d --build --no-deps session-stats
else
  echo "Starting genesis and session-stats with $env_file"
  "${compose[@]}" --profile session-stats up -d --build genesis session-stats
fi

echo "Building the native-load-generator image before opening the benchmark window"
"${compose[@]}" --profile native-load-generator build "$container_name"

# The validator's session-stats log contains one structured record per
# collation and validation query. Remember the current end only after the image
# build, so pull/compile time cannot contaminate the benchmark distributions.
validator_session_stats_start_line=$(docker exec genesis sh -c \
  'if [ -f /var/ton-work/db/log.session-stats ]; then wc -l < /var/ton-work/db/log.session-stats; else echo 0; fi' \
  2>/dev/null || echo 0)
if ! [[ $validator_session_stats_start_line =~ ^[0-9]+$ ]]; then
  validator_session_stats_start_line=0
fi

echo "Starting a fresh native-load-generator container"
"${compose[@]}" --profile native-load-generator up -d --force-recreate --no-deps "$container_name"

started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
started_epoch=$(date +%s)

collect_container_stats &
collector_pids+=("$!")
collect_host_stats &
collector_pids+=("$!")
docker logs --follow "$container_name" &
collector_pids+=("$!")

echo "Native load is running; live generator JSON follows"

set +e
generator_container_exit_code=$(docker wait "$container_name" 2>"$result_dir/docker-wait.stderr.log")
wait_status=$?
set -e
if [[ $wait_status -ne 0 || ! $generator_container_exit_code =~ ^[0-9]+$ ]]; then
  generator_container_exit_code=125
fi
benchmark_exit_code=$generator_container_exit_code
if [[ $interrupted -eq 1 ]]; then
  benchmark_exit_code=130
fi

finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
finished_epoch=$(date +%s)
stop_collectors
docker logs "$container_name" >"$generator_log_file" 2>&1 || true

generator_measure_start=$(jq -Rs \
  '[split("\n")[] | fromjson? | select(.schema == "native-load-v2" and .final == true)] |
   (last.measure_start_unix_s // null)' "$generator_log_file")
generator_measure_end=$(jq -Rs \
  '[split("\n")[] | fromjson? | select(.schema == "native-load-v2" and .final == true)] |
   (last.measure_end_unix_s // null)' "$generator_log_file")

validator_session_stats_first_line=$((validator_session_stats_start_line + 1))
if ! docker exec genesis sh -c \
  'file=/var/ton-work/db/log.session-stats; first=$1; old=$2
   if [ ! -f "$file" ]; then exit 0; fi
   current=$(wc -l < "$file")
   if [ "$current" -lt "$old" ]; then first=1; fi
   tail -n "+$first" "$file"' sh "$validator_session_stats_first_line" \
  "$validator_session_stats_start_line" >"$validator_session_stats_file" 2>/dev/null; then
  : >"$validator_session_stats_file"
fi

# Keep the raw JSONL for detailed inspection and publish robust distributions
# for the fields needed to classify the limiting stage.  The file is parsed as
# text so one partial final line cannot invalidate an otherwise complete run.
jq -Rsc \
  --argjson measure_start "$generator_measure_start" \
  --argjson measure_end "$generator_measure_end" '
  def numeric:
    if type == "number" then .
    elif type == "string" then (tonumber? // null)
    else null end;
  def distribution:
    map(numeric) | map(select(. != null)) | sort as $v |
    if ($v | length) == 0 then
      {samples:0,avg:null,p50:null,p95:null,p99:null,max:null}
    else
      ($v | length) as $n |
      {samples:$n,
       avg:($v | add / $n),
       p50:$v[((($n - 1) * 0.50) | floor)],
       p95:$v[((($n - 1) * 0.95) | floor)],
       p99:$v[((($n - 1) * 0.99) | floor)],
       max:$v[-1]}
    end;
  def stage_distribution($rows; $name):
    [$rows[] |
      ((.work_time_real_stats? // "") |
       (capture("(?:^| )" + $name + "=(?<value>[-+0-9.eE]+)")? | .value) |
       tonumber?) |
      select(. != null)] |
    distribution;
  def collated_summary($rows):
    ($rows | map(.block_stats.transactions? // 0) | add // 0) as $transfers |
    ($rows | map(.bytes? // 0) | add // 0) as $block_bytes |
    ($rows | map(.collated_data_bytes? // 0) | add // 0) as $collated_bytes |
    ($rows | map(.block_limits.bytes? // 0) | add // 0) as $estimated_bytes |
    {
      blocks:($rows | length),
      transfers:$transfers,
      avg_transfers_per_block:(if ($rows | length) > 0 then $transfers / ($rows | length) else null end),
      max_transfers_per_block:($rows | map(.block_stats.transactions? // 0) | max // null),
      total_actual_block_bytes:$block_bytes,
      total_collated_data_bytes:$collated_bytes,
      total_estimated_block_bytes:$estimated_bytes,
      actual_block_bytes_per_transfer:(if $transfers > 0 then $block_bytes / $transfers else null end),
      collated_data_bytes_per_transfer:(if $transfers > 0 then $collated_bytes / $transfers else null end),
      estimated_block_bytes_per_transfer:(if $transfers > 0 then $estimated_bytes / $transfers else null end),
      actual_block_bytes:($rows | map(.bytes?) | distribution),
      collated_data_bytes:($rows | map(.collated_data_bytes?) | distribution),
      estimated_block_bytes:($rows | map(.block_limits.bytes?) | distribution),
      total_time_s:($rows | map(.total_time?) | distribution),
      work_time_s:($rows | map(.work_time?) | distribution),
      cpu_work_time_s:($rows | map(.cpu_work_time?) | distribution),
      wait_externals_time_s:($rows | map(.wait_externals_time?) | distribution),
      stages_real_s:{
        preinit:stage_distribution($rows; "preinit"),
        native_prepare:stage_distribution($rows; "native_prepare"),
        native_execute:stage_distribution($rows; "native_execute"),
        native_commit:stage_distribution($rows; "native_commit"),
        native_batch_serialize:stage_distribution($rows; "native_batch_serialize"),
        final_storage_stat:stage_distribution($rows; "final_storage_stat"),
        combine_account_transactions:stage_distribution($rows; "combine_account_transactions"),
        create_shard_state:stage_distribution($rows; "create_shard_state"),
        create_block:stage_distribution($rows; "create_block"),
        create_collated_data:stage_distribution($rows; "create_collated_data"),
        create_block_candidate:stage_distribution($rows; "create_block_candidate")
      }
    };
  def validated_summary($rows):
    {
      blocks:($rows | length),
      accepted:($rows | map(select(.valid? == true)) | length),
      rejected:($rows | map(select(.valid? == false)) | length),
      total_time_s:($rows | map(.total_time?) | distribution),
      work_time_s:($rows | map(.work_time?) | distribution),
      actual_time_s:($rows | map(.actual_time?) | distribution),
      cpu_work_time_s:($rows | map(.cpu_work_time?) | distribution),
      actual_block_bytes:($rows | map(.bytes?) | distribution),
      collated_data_bytes:($rows | map(.collated_data_bytes?) | distribution),
      stages_real_s:{
        unpack_block_candidate:stage_distribution($rows; "unpack_block_candidate"),
        process_mc_state:stage_distribution($rows; "process_mc_state"),
        native_batch_replay:stage_distribution($rows; "native_batch_replay"),
        unpack_state:stage_distribution($rows; "unpack_state"),
        validate_block_tlb:stage_distribution($rows; "validate_block_tlb"),
        unpack_block_data:stage_distribution($rows; "unpack_block_data"),
        precheck_account_updates:stage_distribution($rows; "precheck_account_updates"),
        precheck_account_transactions:stage_distribution($rows; "precheck_account_transactions"),
        check_new_state:stage_distribution($rows; "check_new_state")
      }
    };
  [split("\n")[] | fromjson?] as $records |
  [$records[] | select(.block_stats? != null)] as $collated |
  [$records[] | select(.validated_at? != null)] as $validated |
  [$collated[] | select((.block_id.workchain? // .block_id.workchain_id? // -1) == 0)] as $wc_collated |
  [$validated[] | select((.block_id.workchain? // .block_id.workchain_id? // -1) == 0)] as $wc_validated |
  [$wc_collated[] |
    select($measure_start != null and $measure_end != null and
           (.collated_at? // -1) >= $measure_start and (.collated_at? // -1) < $measure_end)] as $measured_collated |
  [$wc_validated[] |
    select($measure_start != null and $measure_end != null and
           (.validated_at? // -1) >= $measure_start and (.validated_at? // -1) < $measure_end)] as $measured_validated |
  {
    semantics:"validator candidate session records captured directly from genesis; basechain transaction counts are native transfers for this isolated single-validator benchmark; proof-checked generator metrics remain authoritative for canonical selection",
    raw_records:($records | length),
    measured_window_unix_s:{start:$measure_start,end:$measure_end},
    all_run:{
      collated_basechain:collated_summary($wc_collated),
      validated_basechain:validated_summary($wc_validated)
    },
    measured:{
      collated_basechain:collated_summary($measured_collated),
      validated_basechain:validated_summary($measured_validated)
    }
  }
' "$validator_session_stats_file" >"$validator_pipeline_summary_file"

# Let Session Stats import the tail of the validator log before querying the
# independent canonical summary.  Its importer deliberately ignores the most
# recent lag window, so querying immediately would undercount the run tail.
session_stats_settle_seconds=$(docker inspect session-stats |
  jq -r '.[0].Config.Env as $env |
    (($env[] | select(startswith("SESSION_STATS_IMPORT_INTERVAL_SECONDS=")) |
      split("=")[1] | tonumber) // 60) +
    (($env[] | select(startswith("SESSION_STATS_IMPORT_LAG_SECONDS=")) |
      split("=")[1] | tonumber) // 15) + 2' 2>/dev/null || echo 77)
if ! [[ $session_stats_settle_seconds =~ ^[0-9]+$ ]]; then
  session_stats_settle_seconds=77
fi
echo "Waiting ${session_stats_settle_seconds}s for Session Stats to import the run tail"
sleep "$session_stats_settle_seconds"

elapsed_seconds=$((finished_epoch - started_epoch))
if [[ $elapsed_seconds -lt 1 ]]; then
  elapsed_seconds=1
fi
session_stats_base='http://127.0.0.1:18000/api/stats_single?stat=BLOCK_APPLIED_native_transfers'
# Session Stats persists imported validator samples in minute buckets. Query
# whole source buckets so a run that starts or finishes mid-minute is not
# silently undercounted. The generator's proof-checked follower remains the
# authoritative source for exact run boundaries and one-second TPS; this API
# independently corroborates canonical totals and per-block packing.
session_stats_query_start_epoch=$((started_epoch / 60 * 60))
session_stats_query_end_epoch=$(((finished_epoch / 60 + 1) * 60))
session_stats_query_start=$(date -u -d "@$session_stats_query_start_epoch" +%Y-%m-%dT%H:%M:%SZ)
session_stats_query_end=$(date -u -d "@$session_stats_query_end_epoch" +%Y-%m-%dT%H:%M:%SZ)
session_stats_range="start=$session_stats_query_start&end=$session_stats_query_end&window_size=60&total_range=1"
session_stats_window_seconds=60
session_stats_query_elapsed_seconds=$((session_stats_query_end_epoch - session_stats_query_start_epoch))
session_stats_rate_file=$result_dir/session-stats-canonical-rate.json
session_stats_sum_file=$result_dir/session-stats-canonical-sum.json
if ! docker exec session-stats python -c \
  'import sys, urllib.request; sys.stdout.buffer.write(urllib.request.urlopen(sys.argv[1], timeout=30).read())' \
  "$session_stats_base&mode=rate&$session_stats_range" >"$session_stats_rate_file" \
  2>>"$result_dir/session-stats-api.stderr.log"; then
  printf '[]\n' >"$session_stats_rate_file"
fi
if ! docker exec session-stats python -c \
  'import sys, urllib.request; sys.stdout.buffer.write(urllib.request.urlopen(sys.argv[1], timeout=30).read())' \
  "$session_stats_base&mode=sum&$session_stats_range" >"$session_stats_sum_file" \
  2>>"$result_dir/session-stats-api.stderr.log"; then
  printf '[]\n' >"$session_stats_sum_file"
fi
jq -n \
  --arg start "$started_at" \
  --arg end "$finished_at" \
  --arg query_start "$session_stats_query_start" \
  --arg query_end "$session_stats_query_end" \
  --argjson elapsed_seconds "$elapsed_seconds" \
  --argjson query_elapsed_seconds "$session_stats_query_elapsed_seconds" \
  --argjson rate_window_seconds "$session_stats_window_seconds" \
  --slurpfile rates "$session_stats_rate_file" \
  --slurpfile sums "$session_stats_sum_file" '
    ($rates[0] | if type == "array" then . else [] end) as $rate_rows |
    ($sums[0] | if type == "array" then . else [] end) as $sum_rows |
    ($sum_rows | map(.wc // 0) | add // 0) as $canonical |
    {
      semantics: "Session Stats minute-bucketed consensus-selected native transfers in basechain blocks anchored by masterchain; use the generator follower for exact run-boundary and one-second TPS",
      requested_run_range: {$start,$end,$elapsed_seconds},
      database_query_range: {
        start:$query_start,
        end:$query_end,
        elapsed_seconds:$query_elapsed_seconds,
        source_resolution_seconds:$rate_window_seconds
      },
      rate_samples: ($rate_rows | length),
      max_minute_average_canonical_tps: ($rate_rows | map(.wc // 0) | max),
      max_native_transfers_per_block: ($rate_rows | map(.wc_max // 0) | max),
      canonical_transfers: $canonical,
      padded_range_average_canonical_tps: ($canonical / $query_elapsed_seconds)
    }
  ' >"$session_stats_summary_file"

jq -Rs '
  [split("\n")[] | fromjson? | select(.schema == "native-load-v2")] as $records |
  ($records | map(select(.final == true)) | last) as $final |
  {
    records: ($records | length),
    max_offered_tps: ($records | map(.offered_tps // 0) | max),
    max_sign_tps: ($records | map(.sign_tps // 0) | max),
    max_wire_tps: ($records | map(.wire_tps // 0) | max),
    max_wire_query_tps: ($records | map(.wire_query_tps // 0) | max),
    max_wire_batch_size: ($records | map(.wire_batch_max_size // 0) | max),
    max_wire_batch_source_run: ($records | map(.wire_batch_source_run_max_size // 0) | max),
    max_mempool_accept_tps: ($records | map(.mempool_accept_tps // 0) | max),
    max_canonical_tps: ($records | map(
      .canonical_chain_measure_peak_1s_tps // .canonical_tps // .measured_canonical_tps // 0
    ) | max),
    max_canonical_tps_semantics: "maximum transfers assigned to one canonical block gen_utime second in the measurement window",
    max_canonical_follower_discovery_tps: ($records | map(
      .canonical_follower_discovery_tps // 0
    ) | max),
    canonical_follower_discovery_tps_semantics: "observer catch-up speed; not blockchain production TPS",
    max_canonical_follower_block_discovery_rate: ($records | map(
      .canonical_follower_block_discovery_rate // 0
    ) | max),
    max_canonical_backlog: ($records | map(.canonical_backlog // 0) | max),
    max_canonical_follower_lag_blocks: (
      $final.canonical_follower_max_lag_blocks //
      ($records | map(.canonical_follower_lag_blocks // 0) | max)
    ),
    canonical_backpressure_seconds: ($final.canonical_backpressure_s // null),
    canonical_backpressure_engaged: (($final.canonical_backpressure_s // 0) > 0),
    canonical_observer_invalid_or_lagging_at_end: (
      (($final.canonical_follower_errors // 0) > 0) or
      (($final.canonical_follower_retry_exhausted // 0) > 0) or
      (($final.canonical_follower_reorgs // 0) > 0) or
      (($final.canonical_follower_lag_blocks // 0) > 0) or
      ($final != null and
       ($final | has("canonical_follower_final_catchup_complete")) and
       $final.canonical_follower_final_catchup_complete != true)
    ),
    canonical_follower_transient_timeouts: ($final.canonical_follower_transient_timeouts // 0),
    canonical_follower_transient_cancellations: ($final.canonical_follower_transient_cancellations // 0),
    canonical_follower_transient_retries: ($final.canonical_follower_transient_retries // 0),
    canonical_follower_transient_recoveries: ($final.canonical_follower_transient_recoveries // 0),
    canonical_follower_reconnects: ($final.canonical_follower_reconnects // 0),
    canonical_follower_fatal_errors: ($final.canonical_follower_fatal_errors // 0),
    canonical_follower_retry_exhausted: ($final.canonical_follower_retry_exhausted // 0),
    measured_offered_avg_tps: ($final.steady_offered_avg_tps // null),
    measured_admission_avg_tps: ($final.steady_mempool_accept_avg_tps // null),
    measured_canonical_chain_avg_tps: ($final.canonical_chain_measure_avg_tps // null),
    measured_offer_cohort_observed_avg_tps: (
      $final.canonical_measured_offer_cohort_observed_avg_tps // null
    ),
    generator_benchmark_result_valid: (
      if $final == null then null else $final.benchmark_result_valid end
    ),
    valid_canonical_run: (
      $final != null and
      ($final.benchmark_result_valid == true) and
      ($final.canonical_result_valid == true) and
      ($final.interrupted == false) and
      ($final.drain_timed_out == false) and
      (($final.canonical_follower_errors // 0) == 0) and
      (($final.canonical_follower_retry_exhausted // 0) == 0) and
      (($final.canonical_follower_final_catchup_complete // false) == true) and
      (($final.canonical_follower_reorgs // 0) == 0) and
      (($final.canonical_follower_lag_blocks // -1) == 0) and
      (($final.canonical_hash_conflicts // 0) == 0) and
      (($final.duplicate_nonce_conflicts // 0) == 0) and
      (($final.external_nonce_conflicts // 0) == 0) and
      (($final.nonce_gaps // -1) == 0) and
      (($final.canonical_backlog_after_drain // -1) == 0) and
      (($final.canonical_total_backlog_after_drain // -1) == 0) and
      ($final.canonical_measured_offers_after_drain == $final.steady_offered)
    ),
    final: $final
  }
' "$generator_log_file" >"$generator_summary_file"

if [[ $generator_container_exit_code -eq 0 ]] &&
   ! jq -e '.final != null' "$generator_summary_file" >/dev/null; then
  echo "generator exited successfully without a final native-load-v2 record" >&2
  benchmark_exit_code=125
elif [[ $generator_container_exit_code -eq 0 ]] &&
     ! jq -e '.valid_canonical_run == true' "$generator_summary_file" >/dev/null; then
  echo "generator exited successfully but canonical benchmark validation failed" >&2
  benchmark_exit_code=3
fi
if jq -e '.canonical_observer_invalid_or_lagging_at_end == true' "$generator_summary_file" >/dev/null; then
  echo "warning: canonical follower ended invalid or behind the anchored shard tip; do not use this run as a chain ceiling" >&2
elif jq -e '.canonical_backpressure_engaged == true' "$generator_summary_file" >/dev/null; then
  echo "notice: the canonical backlog guard throttled offers; this can indicate chain saturation or transient observer lag, so compare follower lag, block rate, and canonical backlog before classifying the ceiling" >&2
fi

jq -s \
  --argjson host_vcpus "$(getconf _NPROCESSORS_ONLN)" \
  --argjson host_memory_bytes "$(awk '/^MemTotal:/ {print $2 * 1024; exit}' /proc/meminfo)" '
  def percent: sub("%$"; "") | tonumber;
  def bytes:
    capture("^(?<value>[0-9.]+)(?<unit>[A-Za-z]+)$") as $m |
    ($m.value | tonumber) *
    ({B:1,kB:1000,KB:1000,KiB:1024,MB:1000000,MiB:1048576,
      GB:1000000000,GiB:1073741824,TB:1000000000000,TiB:1099511627776}[$m.unit]);
  group_by(.Name) |
  map(
    (map(.CPUPerc | percent)) as $cpu |
    (map((.MemUsage | split(" / ")[0]) | bytes)) as $memory |
    {
      name: .[0].Name,
      samples: length,
      avg_cpu_percent: (($cpu | add) / ($cpu | length)),
      max_cpu_percent: ($cpu | max),
      avg_cpu_cores: ((($cpu | add) / ($cpu | length)) / 100),
      max_cpu_cores: (($cpu | max) / 100),
      avg_cpu_host_percent: ((($cpu | add) / ($cpu | length)) / $host_vcpus),
      max_cpu_host_percent: (($cpu | max) / $host_vcpus),
      avg_memory_bytes: (($memory | add) / ($memory | length)),
      max_memory_bytes: ($memory | max),
      avg_memory_host_percent: (
        (($memory | add) / ($memory | length)) * 100 / $host_memory_bytes
      ),
      max_memory_host_percent: (($memory | max) * 100 / $host_memory_bytes)
    }
  )
' "$container_stats_file" >"$result_dir/container-resource-summary.json"

jq -s '
  if length == 0 then
    {samples:0,avg_cpu_percent:null,max_cpu_percent:null,
     avg_memory_used_bytes:null,max_memory_used_bytes:null}
  else
    {
      samples: length,
      avg_cpu_percent: (map(.cpu_percent) | add / length),
      max_cpu_percent: (map(.cpu_percent) | max),
      avg_memory_used_bytes: (map(.memory_used_bytes) | add / length),
      max_memory_used_bytes: (map(.memory_used_bytes) | max),
      memory_total_bytes: (last.memory_total_bytes)
    }
  end
' "$host_stats_file" >"$result_dir/host-resource-summary.json"

jq -n \
  --slurpfile containers "$result_dir/container-resource-summary.json" \
  --slurpfile host "$result_dir/host-resource-summary.json" \
  '{containers: $containers[0], host: $host[0]}' >"$resource_summary_file"

docker inspect genesis "$container_name" session-stats |
  jq '[.[] | {
    name: (.Name | ltrimstr("/")),
    image: .Config.Image,
    image_id: .Image,
    state: .State.Status,
    health: (.State.Health.Status // null),
    cpuset: .HostConfig.CpusetCpus,
    nano_cpus: .HostConfig.NanoCpus,
    memory_limit_bytes: .HostConfig.Memory,
    benchmark_environment: [.Config.Env[] | select(test(
      "^(TON_SIMPLEX_[^=]+|TON_NATIVE_[^=]+|NATIVE_LOAD_[^=]+|SIMPLEX_[^=]+|BLOCK_(SIZE|GAS|LIMIT)[^=]*)="
    ))]
  }]' >"$runtime_file"

env_sha256=$(sha256sum "$env_file" | awk '{print $1}')
git_revision=$(git rev-parse HEAD 2>/dev/null || true)
git_dirty=$(if [[ -z $(git status --porcelain --untracked-files=normal 2>/dev/null) ]]; then echo false; else echo true; fi)
jq -n \
  --arg schema native-benchmark-run-v1 \
  --arg run_id "$run_id" \
  --arg started_at "$started_at" \
  --arg finished_at "$finished_at" \
  --arg env_file "$env_file" \
  --arg env_sha256 "$env_sha256" \
  --arg git_revision "$git_revision" \
  --argjson git_dirty "$git_dirty" \
  --arg kernel "$(uname -srmo)" \
  --arg cpu_model "$(awk -F: '/model name/ {sub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo)" \
  --argjson host_vcpus "$(getconf _NPROCESSORS_ONLN)" \
  --argjson host_memory_bytes "$(awk '/^MemTotal:/ {print $2 * 1024; exit}' /proc/meminfo)" \
  --argjson elapsed_seconds "$((finished_epoch - started_epoch))" \
  --argjson generator_container_exit_code "$generator_container_exit_code" \
  --argjson benchmark_exit_code "$benchmark_exit_code" \
  --argjson interrupted "$interrupted" \
  --slurpfile containers "$runtime_file" \
  '{$schema,$run_id,$started_at,$finished_at,$elapsed_seconds,$env_file,$env_sha256,
    $git_revision,$git_dirty,$kernel,$cpu_model,$host_vcpus,$host_memory_bytes,
    $generator_container_exit_code,$benchmark_exit_code,
    interrupted:($interrupted == 1),containers:$containers[0]}' >"$metadata_file"

jq -n \
  --slurpfile run "$metadata_file" \
  --slurpfile generator "$generator_summary_file" \
  --slurpfile resources "$resource_summary_file" \
  --slurpfile session_stats "$session_stats_summary_file" \
  --slurpfile validator_pipeline "$validator_pipeline_summary_file" \
  '{run:$run[0],generator:$generator[0],session_stats:$session_stats[0],
    validator_pipeline:$validator_pipeline[0],resources:$resources[0]}' \
  >"$summary_file"

echo "Benchmark summary: $summary_file"
jq . "$summary_file"

if [[ $interrupted -eq 1 ]]; then
  exit 130
fi
exit "$benchmark_exit_code"
