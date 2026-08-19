#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: ./run-native-benchmark.sh [ENV_FILE] [RESULT_DIR]
       ./run-native-benchmark.sh --self-test

Runs session-stats and the native load generator, samples host/container
resources for the complete run, and writes a machine-readable summary.

Defaults:
  ENV_FILE    .env.physical
  RESULT_DIR  benchmark-results/<UTC timestamp>

Run this script itself with sudo when Docker requires root access. Optional:
  BENCHMARK_HOST_SAMPLE_SECONDS=1
  BENCHMARK_DETAIL_SAMPLE_SECONDS=5
  BENCHMARK_THREAD_SAMPLE_SECONDS=5
  BENCHMARK_MAX_THREADS_PER_CONTAINER=32
  BENCHMARK_RECREATE_GENESIS=1   # otherwise reuse an already-healthy genesis
EOF
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
benchmark_jq_dir=$script_dir/benchmark/jq

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --self-test) exec "$script_dir/benchmark/tests/native-benchmark-reporting-test.sh" ;;
esac

env_file=${1:-.env.physical}
run_id=$(date -u +%Y%m%dT%H%M%SZ)
result_dir=${2:-benchmark-results/$run_id}
host_sample_seconds=${BENCHMARK_HOST_SAMPLE_SECONDS:-1}
detail_sample_seconds=${BENCHMARK_DETAIL_SAMPLE_SECONDS:-5}
thread_sample_seconds=${BENCHMARK_THREAD_SAMPLE_SECONDS:-5}
max_threads_per_container=${BENCHMARK_MAX_THREADS_PER_CONTAINER:-32}
container_name=native-load-generator

for command_name in docker jq awk git getconf sed sort cut sha256sum timeout; do
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
case "$detail_sample_seconds" in
  ''|*[!0-9.]*|.*|*.)
    echo "BENCHMARK_DETAIL_SAMPLE_SECONDS must be a positive number" >&2
    exit 2
    ;;
esac
awk -v seconds="$detail_sample_seconds" 'BEGIN { exit !(seconds > 0) }' || {
  echo "BENCHMARK_DETAIL_SAMPLE_SECONDS must be greater than zero" >&2
  exit 2
}
case "$thread_sample_seconds" in
  ''|*[!0-9.]*|.*|*.)
    echo "BENCHMARK_THREAD_SAMPLE_SECONDS must be a positive number" >&2
    exit 2
    ;;
esac
awk -v seconds="$thread_sample_seconds" 'BEGIN { exit !(seconds > 0) }' || {
  echo "BENCHMARK_THREAD_SAMPLE_SECONDS must be greater than zero" >&2
  exit 2
}
case "$max_threads_per_container" in
  ''|*[!0-9]*)
    echo "BENCHMARK_MAX_THREADS_PER_CONTAINER must be a positive integer" >&2
    exit 2
    ;;
esac
if (( max_threads_per_container < 1 || max_threads_per_container > 256 )); then
  echo "BENCHMARK_MAX_THREADS_PER_CONTAINER must be between 1 and 256" >&2
  exit 2
fi
test -r "$benchmark_jq_dir/native-benchmark-lib.jq" || {
  echo "benchmark jq library is missing: $benchmark_jq_dir/native-benchmark-lib.jq" >&2
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
cgroup_stats_file=$result_dir/cgroup-resources.jsonl
thread_stats_file=$result_dir/thread-resources.jsonl
device_stats_file=$result_dir/device-resources.jsonl
generator_log_file=$result_dir/native-load-generator.log
generator_summary_file=$result_dir/generator-summary.json
resource_summary_file=$result_dir/resource-summary.json
session_stats_summary_file=$result_dir/session-stats-summary.json
validator_session_stats_file=$result_dir/validator-session-stats.jsonl
validator_pipeline_summary_file=$result_dir/validator-pipeline-summary.json
validator_stats_before_file=$result_dir/validator-stats-before.txt
validator_stats_after_file=$result_dir/validator-stats-after.txt
validator_pool_summary_file=$result_dir/validator-pool-summary.json
validator_scheduling_log_file=$result_dir/validator-scheduling.log
validator_scheduling_log_summary_file=$result_dir/validator-scheduling-log-summary.json
validator_scheduling_summary_file=$result_dir/validator-scheduling-summary.json
runtime_file=$result_dir/container-runtime.json
image_metadata_file=$result_dir/image-metadata.json
metadata_file=$result_dir/run-metadata.json
summary_file=$result_dir/benchmark-summary.json
: >"$container_stats_file"
: >"$host_stats_file"
: >"$cgroup_stats_file"
: >"$thread_stats_file"
: >"$device_stats_file"

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

capture_validator_stats() {
  local output_file=$1
  timeout 15s docker exec genesis sh -c '
    config=/var/ton-work/db/config.json
    internal_ip=$(hostname -I)
    internal_ip=${internal_ip%% *}
    control_port=$(jq -r ".control[0].port // empty" "$config")
    test -n "$internal_ip" && test -n "$control_port"
    exec validator-engine-console \
      -k /var/ton-work/db/client \
      -p /var/ton-work/db/server.pub \
      -a "$internal_ip:$control_port" \
      -c getstats
  ' >"$output_file" 2>>"$result_dir/validator-stats.stderr.log"
}

parse_validator_stat() {
  local input_file=$1 stat_name=$2 line
  line=$(grep -F "$stat_name" "$input_file" 2>/dev/null | tail -n 1 || true)
  if [[ -z $line ]]; then
    printf '{}\n'
    return
  fi
  awk '
    BEGIN { printf "{"; separator = "" }
    {
      for (i = 1; i <= NF; ++i) {
        token = $i
        gsub(/[,;]/, "", token)
        count = split(token, parts, ":")
        if (count == 2 && parts[1] ~ /^[A-Za-z_][A-Za-z0-9_]*$/ &&
            parts[2] ~ /^[0-9]+([.][0-9]+)?$/) {
          printf "%s\"%s\":%s", separator, parts[1], parts[2]
          separator = ","
        }
      }
    }
    END { print "}" }
  ' <<<"$line"
}

collect_host_stats() {
  local label total idle iowait delta_total delta_idle delta_iowait cpu_percent iowait_percent
  local mem_total_kib mem_available_kib per_cpu_file per_cpu_json
  declare -A previous_total=() previous_idle=() previous_iowait=()
  while read -r label total idle iowait; do
    previous_total[$label]=$total
    previous_idle[$label]=$idle
    previous_iowait[$label]=$iowait
  done < <(awk '/^cpu[0-9]* / {
    total = 0
    for (i = 2; i <= NF; i++) total += $i
    printf "%s %.0f %.0f %.0f\n", $1, total, $5 + $6, $6
  }' /proc/stat)
  while docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -qx true; do
    sleep "$host_sample_seconds"
    per_cpu_file=$(mktemp "${TMPDIR:-/tmp}/native-benchmark-cpu.XXXXXX")
    cpu_percent=0
    iowait_percent=0
    while read -r label total idle iowait; do
      delta_total=$((total - ${previous_total[$label]:-$total}))
      delta_idle=$((idle - ${previous_idle[$label]:-$idle}))
      delta_iowait=$((iowait - ${previous_iowait[$label]:-$iowait}))
      printf '%s\t%s\t%s\t%s\n' "$label" "$delta_total" "$delta_idle" "$delta_iowait" \
        >>"$per_cpu_file"
      previous_total[$label]=$total
      previous_idle[$label]=$idle
      previous_iowait[$label]=$iowait
    done < <(awk '/^cpu[0-9]* / {
      total = 0
      for (i = 2; i <= NF; i++) total += $i
      printf "%s %.0f %.0f %.0f\n", $1, total, $5 + $6, $6
    }' /proc/stat)
    read -r cpu_percent iowait_percent < <(awk -F '\t' '$1 == "cpu" {
      if ($2 > 0) printf "%.3f %.3f\n", 100 * ($2 - $3) / $2, 100 * $4 / $2;
      else print "0 0"; exit
    }' "$per_cpu_file")
    per_cpu_json=$(jq -Rsc '
      [split("\n")[] | select(length > 0) | split("\t") |
       select(.[0] != "cpu") |
       {cpu:(.[0] | ltrimstr("cpu") | tonumber),
        cpu_percent:(if (.[1] | tonumber) > 0
                     then 100 * ((.[1] | tonumber) - (.[2] | tonumber)) / (.[1] | tonumber)
                     else 0 end),
        iowait_percent:(if (.[1] | tonumber) > 0
                        then 100 * (.[3] | tonumber) / (.[1] | tonumber)
                        else 0 end)}]
    ' "$per_cpu_file")
    rm -f -- "$per_cpu_file"
    mem_total_kib=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
    mem_available_kib=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)
    jq -cn \
      --arg sampled_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson sampled_at_epoch "$(date +%s)" \
      --argjson cpu_percent "$cpu_percent" \
      --argjson iowait_percent "$iowait_percent" \
      --argjson memory_used_bytes "$(((mem_total_kib - mem_available_kib) * 1024))" \
      --argjson memory_total_bytes "$((mem_total_kib * 1024))" \
      --arg load_average "$(cut -d' ' -f1-3 /proc/loadavg)" \
      --arg cpu_pressure "$(read_flat_file /proc/pressure/cpu)" \
      --arg io_pressure "$(read_flat_file /proc/pressure/io)" \
      --arg memory_pressure "$(read_flat_file /proc/pressure/memory)" \
      --argjson per_cpu "$per_cpu_json" \
      '{schema:"native-benchmark-host-resource-v2",$sampled_at,$sampled_at_epoch,
        $cpu_percent,$iowait_percent,$memory_used_bytes,$memory_total_bytes,
        $load_average,$cpu_pressure,$io_pressure,$memory_pressure,$per_cpu}' \
      >>"$host_stats_file"
  done
}

read_cgroup_value() {
  local file=$1 key=$2
  if [[ -r $file ]]; then
    awk -v key="$key" '$1 == key {print $2; found=1; exit} END {if (!found) print 0}' "$file"
  else
    echo 0
  fi
}

read_numeric_file() {
  local file=$1 value
  if [[ -r $file ]]; then
    read -r value <"$file" || value=0
    [[ $value =~ ^[0-9]+$ ]] || value=0
    echo "$value"
  else
    echo 0
  fi
}

read_flat_file() {
  local file=$1 value
  if [[ -r $file ]]; then
    value=$(<"$file")
    printf '%s' "${value//$'\n'/;}"
  fi
}

collect_cgroup_and_device_stats() {
  local sampled_at sampled_at_epoch name pid relative cgroup_dir cpu_stat memory_events
  local io_values device stat_file sector_size
  while docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -qx true; do
    sampled_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    sampled_at_epoch=$(date +%s)
    for name in genesis "$container_name" session-stats; do
      pid=$(docker inspect -f '{{.State.Pid}}' "$name" 2>/dev/null || echo 0)
      [[ $pid =~ ^[0-9]+$ ]] || pid=0
      if (( pid <= 0 )) || [[ ! -r /proc/$pid/cgroup ]]; then
        continue
      fi
      relative=$(awk -F: '$1 == "0" {print $3; exit}' "/proc/$pid/cgroup")
      cgroup_dir=/sys/fs/cgroup$relative
      [[ -r $cgroup_dir/cpu.stat ]] || continue
      cpu_stat=$cgroup_dir/cpu.stat
      memory_events=$cgroup_dir/memory.events
      io_values=$(awk '
        { for (i = 2; i <= NF; ++i) {
            split($i, pair, "=")
            if (pair[1] == "rbytes") read_bytes += pair[2]
            else if (pair[1] == "wbytes") write_bytes += pair[2]
            else if (pair[1] == "rios") read_ios += pair[2]
            else if (pair[1] == "wios") write_ios += pair[2]
          }
        }
        END {printf "%.0f %.0f %.0f %.0f\n", read_bytes, write_bytes, read_ios, write_ios}
      ' "$cgroup_dir/io.stat" 2>/dev/null || echo '0 0 0 0')
      read -r cgroup_read_bytes cgroup_write_bytes cgroup_read_ios cgroup_write_ios <<<"$io_values"
      jq -cn \
        --arg schema native-benchmark-cgroup-resource-v1 \
        --arg sampled_at "$sampled_at" \
        --argjson sampled_at_epoch "$sampled_at_epoch" \
        --arg container "$name" \
        --arg cgroup_path "$relative" \
        --arg cpuset_cpus_effective "$(read_flat_file "$cgroup_dir/cpuset.cpus.effective")" \
        --arg cpu_max "$(read_flat_file "$cgroup_dir/cpu.max")" \
        --arg memory_max "$(read_flat_file "$cgroup_dir/memory.max")" \
        --argjson pid "$pid" \
        --argjson cpu_usage_usec "$(read_cgroup_value "$cpu_stat" usage_usec)" \
        --argjson cpu_user_usec "$(read_cgroup_value "$cpu_stat" user_usec)" \
        --argjson cpu_system_usec "$(read_cgroup_value "$cpu_stat" system_usec)" \
        --argjson cpu_nr_periods "$(read_cgroup_value "$cpu_stat" nr_periods)" \
        --argjson cpu_nr_throttled "$(read_cgroup_value "$cpu_stat" nr_throttled)" \
        --argjson cpu_throttled_usec "$(read_cgroup_value "$cpu_stat" throttled_usec)" \
        --argjson memory_current "$(read_numeric_file "$cgroup_dir/memory.current")" \
        --argjson memory_peak "$(read_numeric_file "$cgroup_dir/memory.peak")" \
        --argjson memory_oom "$(read_cgroup_value "$memory_events" oom)" \
        --argjson memory_oom_kill "$(read_cgroup_value "$memory_events" oom_kill)" \
        --argjson io_read_bytes "$cgroup_read_bytes" \
        --argjson io_write_bytes "$cgroup_write_bytes" \
        --argjson io_read_operations "$cgroup_read_ios" \
        --argjson io_write_operations "$cgroup_write_ios" \
        --arg cpu_pressure "$(read_flat_file "$cgroup_dir/cpu.pressure")" \
        --arg io_pressure "$(read_flat_file "$cgroup_dir/io.pressure")" \
        --arg memory_pressure "$(read_flat_file "$cgroup_dir/memory.pressure")" \
        '{$schema,$sampled_at,$sampled_at_epoch,$container,$pid,$cgroup_path,
          $cpuset_cpus_effective,$cpu_max,$memory_max,
          $cpu_usage_usec,$cpu_user_usec,$cpu_system_usec,$cpu_nr_periods,
          $cpu_nr_throttled,$cpu_throttled_usec,$memory_current,$memory_peak,
          $memory_oom,$memory_oom_kill,$io_read_bytes,$io_write_bytes,
          $io_read_operations,$io_write_operations,$cpu_pressure,$io_pressure,
          $memory_pressure}' >>"$cgroup_stats_file"
    done
    if command -v lsblk >/dev/null 2>&1; then
      while read -r device; do
        stat_file=/sys/block/$device/stat
        [[ -r $stat_file ]] || continue
        sector_size=$(cat "/sys/block/$device/queue/hw_sector_size" 2>/dev/null || echo 512)
        read -r read_ios read_merges read_sectors read_ticks write_ios write_merges \
          write_sectors write_ticks in_flight io_ticks weighted_io_ticks _ <"$stat_file"
        jq -cn \
          --arg schema native-benchmark-device-resource-v1 \
          --arg sampled_at "$sampled_at" \
          --argjson sampled_at_epoch "$sampled_at_epoch" \
          --arg device "$device" \
          --argjson sector_size_bytes "$sector_size" \
          --argjson read_operations "$read_ios" \
          --argjson read_bytes "$((read_sectors * sector_size))" \
          --argjson read_time_ms "$read_ticks" \
          --argjson write_operations "$write_ios" \
          --argjson write_bytes "$((write_sectors * sector_size))" \
          --argjson write_time_ms "$write_ticks" \
          --argjson in_flight "$in_flight" \
          --argjson io_time_ms "$io_ticks" \
          --argjson weighted_io_time_ms "$weighted_io_ticks" \
          '{$schema,$sampled_at,$sampled_at_epoch,$device,$sector_size_bytes,
            $read_operations,$read_bytes,$read_time_ms,$write_operations,
            $write_bytes,$write_time_ms,$in_flight,$io_time_ms,
            $weighted_io_time_ms}' >>"$device_stats_file"
      done < <(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2 == "disk" {print $1}')
    fi
    sleep "$detail_sample_seconds"
  done
}

collect_thread_stats() {
  local clock_ticks sample_ns previous_sample_ns=0 interval_ns name pid task_dir tid stat_line stat_tail ticks processor comm
  local key delta_ticks thread_file threads_json total_threads
  local -a stat_fields
  declare -A previous_ticks=()
  clock_ticks=$(getconf CLK_TCK)
  while docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -qx true; do
    sample_ns=$(date +%s%N)
    interval_ns=$((previous_sample_ns > 0 ? sample_ns - previous_sample_ns : 0))
    for name in genesis "$container_name" session-stats; do
      pid=$(docker inspect -f '{{.State.Pid}}' "$name" 2>/dev/null || echo 0)
      [[ $pid =~ ^[0-9]+$ ]] || pid=0
      (( pid > 0 )) || continue
      thread_file=$(mktemp "${TMPDIR:-/tmp}/native-benchmark-threads.XXXXXX")
      total_threads=0
      for task_dir in /proc/$pid/task/[0-9]*; do
        [[ -r $task_dir/stat ]] || continue
        tid=${task_dir##*/}
        read -r stat_line <"$task_dir/stat" || stat_line=
        stat_tail=${stat_line##*) }
        [[ -n $stat_tail ]] || continue
        read -ra stat_fields <<<"$stat_tail"
        ((${#stat_fields[@]} >= 37)) || continue
        ticks=$((${stat_fields[11]} + ${stat_fields[12]}))
        processor=${stat_fields[36]}
        key=$pid:$tid
        ((total_threads += 1))
        if [[ -n ${previous_ticks[$key]+present} && $previous_sample_ns -gt 0 ]]; then
          delta_ticks=$((ticks - previous_ticks[$key]))
          read -r comm <"$task_dir/comm" || comm=unknown
          comm=${comm//$'\t'/ }
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$delta_ticks" "$name" "$pid" "$tid" \
            "${processor:-0}" "$comm" >>"$thread_file"
        fi
        previous_ticks[$key]=$ticks
      done
      threads_json=$(sort -t $'\t' -k1,1nr "$thread_file" | sed -n "1,${max_threads_per_container}p" |
        jq -Rsc --argjson clock_ticks "$clock_ticks" --argjson interval_ns "$interval_ns" '
          [split("\n")[] | select(length > 0) | split("\t") |
           {container:.[1],pid:(.[2] | tonumber),tid:(.[3] | tonumber),
            thread_name:.[5],processor:(.[4] | tonumber),
            cpu_percent:(if $interval_ns > 0 and (.[0] | tonumber) >= 0
                         then 100 * (.[0] | tonumber) * 1000000000 /
                              ($clock_ticks * $interval_ns)
                         else 0 end)}]
        ')
      rm -f -- "$thread_file"
      jq -cn \
        --arg schema native-benchmark-thread-resource-v1 \
        --arg sampled_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson sampled_at_epoch "$(date +%s)" \
        --arg container "$name" --argjson pid "$pid" \
        --argjson total_threads "$total_threads" \
        --argjson retained_threads "$max_threads_per_container" \
        --argjson interval_ns "$interval_ns" \
        --argjson threads "$threads_json" \
        '{$schema,$sampled_at,$sampled_at_epoch,$container,$pid,$total_threads,
          retained_thread_limit:$retained_threads,
          sample_interval_seconds:($interval_ns / 1000000000),$threads}' \
        >>"$thread_stats_file"
    done
    previous_sample_ns=$sample_ns
    sleep "$thread_sample_seconds"
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

# Snapshot cumulative ExtMessagePool counters immediately around the load.
# The delta exposes whether the pool scanned non-executable messages, formed
# the intended per-source runs, or repeatedly delayed/reactivated nonce heads.
if ! capture_validator_stats "$validator_stats_before_file"; then
  : >"$validator_stats_before_file"
fi

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
collect_cgroup_and_device_stats &
collector_pids+=("$!")
collect_thread_stats &
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
if ! capture_validator_stats "$validator_stats_after_file"; then
  : >"$validator_stats_after_file"
fi
docker logs --since "$started_at" genesis 2>&1 |
  awk '/consensus_schedule_summary/' >"$validator_scheduling_log_file" || true
jq -Rsc '
  def kv_fields:
    [split(" ")[] | select(contains("=")) | split("=") |
      select(length == 2) |
      .[0] as $key | .[1] as $value |
      {($key): (($value | tonumber?) // $value)}] | add // {};
  [split("\n")[] | select(contains("consensus_schedule_summary")) | kv_fields] as $rows |
  {
    semantics:"cumulative BlockProducer/Simplex scheduling snapshots filtered from genesis logs; zero records means the configured validator verbosity suppressed INFO scheduling summaries, while validator-pipeline-summary still contains structured consensus events",
    records:($rows | length),
    last_by_component:($rows | sort_by(.chain,.component) | group_by(.chain,.component) |
      map({chain:.[0].chain,component:.[0].component,last:.[-1]}))
  }
' "$validator_scheduling_log_file" >"$validator_scheduling_log_summary_file"

scheduler_before=$(parse_validator_stat "$validator_stats_before_file" "total.ext_msg_native_scheduler")
scheduler_after=$(parse_validator_stat "$validator_stats_after_file" "total.ext_msg_native_scheduler")
batch_before=$(parse_validator_stat "$validator_stats_before_file" "total.ext_msg_batch_admission")
batch_after=$(parse_validator_stat "$validator_stats_after_file" "total.ext_msg_batch_admission")
pending_before=$(parse_validator_stat "$validator_stats_before_file" "total.ext_msg_native_pending")
pending_after=$(parse_validator_stat "$validator_stats_after_file" "total.ext_msg_native_pending")
jq -n \
  --argjson scheduler_before "$scheduler_before" \
  --argjson scheduler_after "$scheduler_after" \
  --argjson batch_before "$batch_before" \
  --argjson batch_after "$batch_after" \
  --argjson pending_before "$pending_before" \
  --argjson pending_after "$pending_after" '
  def delta($before; $after; $exclude):
    reduce ($after | keys_unsorted[]) as $key ({};
      if ($exclude | index($key)) != null then .
      else .[$key] = (($after[$key] // 0) - ($before[$key] // 0))
      end);
  {
    semantics:"validator-engine cumulative ExtMessagePool counters sampled immediately before and after generator execution; scheduler delta should show near one scanned message per selected message and source runs approaching the configured run target",
    scheduler:{
      capture_complete:(($scheduler_before | length) > 0 and ($scheduler_after | length) > 0),
      before:$scheduler_before,
      after:$scheduler_after,
      delta:delta($scheduler_before; $scheduler_after; ["max_run_size"]),
      observed_max_run_size:($scheduler_after.max_run_size // null)
    },
    batch_admission:{
      capture_complete:(($batch_before | length) > 0 and ($batch_after | length) > 0),
      before:$batch_before,
      after:$batch_after,
      delta:delta($batch_before; $batch_after; [])
    },
    native_pending:{before:$pending_before,after:$pending_after}
  }
' >"$validator_pool_summary_file"

generator_measure_start=$(jq -Rs \
  '[split("\n")[] | fromjson? | select(.schema == "native-load-v2" and .final == true)] |
   (last as $final |
    if ($final.measure_start_unix_ms // null) != null
    then ($final.measure_start_unix_ms / 1000)
    else ($final.measure_start_unix_s // null)
    end)' "$generator_log_file")
generator_measure_end=$(jq -Rs \
  '[split("\n")[] | fromjson? | select(.schema == "native-load-v2" and .final == true)] |
   (last as $final |
    if ($final.measure_end_unix_ms // null) != null
    then ($final.measure_end_unix_ms / 1000)
    else ($final.measure_end_unix_s // null)
    end)' "$generator_log_file")

if ! jq -en --argjson start "$generator_measure_start" --argjson end "$generator_measure_end" \
  '$start != null and $end != null and $start < $end' >/dev/null; then
  echo "generator did not publish a valid measured-window boundary" >&2
  benchmark_exit_code=125
fi

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
jq -L "$benchmark_jq_dir" -Rsc \
  --argjson measure_start "$generator_measure_start" \
  --argjson measure_end "$generator_measure_end" '
  include "native-benchmark-lib";
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
  def native_work_counter_values($rows; $name):
    [$rows[] |
      ((.work_time_real_stats? // "") |
       (capture("(?:^| )" + $name + "=(?<value>(?:[-+0-9.eE]+|true|false))")? | .value) |
       stat_counter_value) |
      select(. != null)];
  def native_work_counter_sum($rows; $name):
    native_work_counter_values($rows; $name) | add // 0;
  def native_work_counter_max($rows; $name):
    native_work_counter_values($rows; $name) | max // 0;
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
      native_fast_path_counters:{
        microbatches:native_work_counter_sum($rows; "native_microbatches"),
        input:native_work_counter_sum($rows; "native_microbatch_input"),
        accepted:native_work_counter_sum($rows; "native_microbatch_accepted"),
        delayed:native_work_counter_sum($rows; "native_microbatch_delayed"),
        permanent:native_work_counter_sum($rows; "native_microbatch_permanent"),
        unique_accounts:native_work_counter_sum($rows; "native_microbatch_unique_accounts"),
        max_microbatch_input:native_work_counter_max($rows; "native_microbatch_max_input"),
        max_microbatch_unique_accounts:native_work_counter_max($rows; "native_microbatch_max_unique_accounts"),
        account_cells:native_work_counter_sum($rows; "native_account_cells_built"),
        staged_dict_sets:native_work_counter_sum($rows; "native_staged_dict_sets"),
        hard_preflight_failures:native_work_counter_sum($rows; "native_hard_preflight_failures"),
        canonical_roots_reused:native_work_counter_sum($rows; "native_canonical_root_reused"),
        canonical_accounts_reused:native_work_counter_sum($rows; "native_canonical_accounts_reused")
      },
      total_time_s:($rows | map(.total_time?) | distribution),
      work_time_s:($rows | map(.work_time?) | distribution),
      cpu_work_time_s:($rows | map(.cpu_work_time?) | distribution),
      wait_externals_time_s:($rows | map(.wait_externals_time?) | distribution),
      stages_real_s:{
        preinit:stage_distribution($rows; "preinit"),
        native_prepare:stage_distribution($rows; "native_prepare"),
        native_execute:stage_distribution($rows; "native_execute"),
        native_commit:stage_distribution($rows; "native_commit"),
        native_account_cell_build:stage_distribution($rows; "native_account_cell_build"),
        native_staged_dict_set:stage_distribution($rows; "native_staged_dict_set"),
        native_proof_preflight:stage_distribution($rows; "native_proof_preflight"),
        native_state_install:stage_distribution($rows; "native_state_install"),
        native_canonical_dict_install:stage_distribution($rows; "native_canonical_dict_install"),
        native_batch_serialize:stage_distribution($rows; "native_batch_serialize"),
        final_storage_stat:stage_distribution($rows; "final_storage_stat"),
        combine_account_transactions:stage_distribution($rows; "combine_account_transactions"),
        create_shard_state:stage_distribution($rows; "create_shard_state"),
        create_state_merkle_update:stage_distribution($rows; "create_state_merkle_update"),
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
  def consensus_summary($rows):
    ($rows | map(.ts) | map(select(. != null)) | sort) as $timestamps |
    {
      events:($rows | length),
      first_event_unix_s:($timestamps[0] // null),
      last_event_unix_s:($timestamps[-1] // null),
      collate_started:([$rows[] | select(.event["@type"] == "consensus.stats.collateStarted")] | length),
      collate_finished:([$rows[] | select(.event["@type"] == "consensus.stats.collateFinished")] | length),
      collated_empty:([$rows[] | select(.event["@type"] == "consensus.stats.collatedEmpty")] | length),
      candidate_received:([$rows[] | select(.event["@type"] == "consensus.stats.candidateReceived")] | length),
      local_candidates:([$rows[] |
        select(.event["@type"] == "consensus.stats.candidateReceived" and .event.is_collator == true)] | length),
      validation_started:([$rows[] | select(.event["@type"] == "consensus.stats.validationStarted")] | length),
      validation_finished:([$rows[] | select(.event["@type"] == "consensus.stats.validationFinished")] | length),
      skip_votes:([$rows[] |
        select(.event["@type"] == "consensus.simplex.stats.voted" and
               .event.vote["@type"] == "consensus.simplex.skipVote")] | length),
      skip_certificates:([$rows[] |
        select(.event["@type"] == "consensus.simplex.stats.certObserved" and
               .event.vote["@type"] == "consensus.simplex.skipVote")] | length),
      notarize_votes:([$rows[] |
        select(.event["@type"] == "consensus.simplex.stats.voted" and
               .event.vote["@type"] == "consensus.simplex.notarizeVote")] | length),
      finalize_votes:([$rows[] |
        select(.event["@type"] == "consensus.simplex.stats.voted" and
               .event.vote["@type"] == "consensus.simplex.finalizeVote")] | length)
    };
  [split("\n")[] | fromjson?] as $records |
  [$records[] | select(.block_stats? != null)] as $collated |
  [$records[] | select(.validated_at? != null)] as $validated |
  [$collated[] | select((.block_id.workchain? // .block_id.workchain_id? // -1) == 0)] as $wc_collated |
  [$collated[] | select((.block_id.workchain? // .block_id.workchain_id? // 0) == -1)] as $mc_collated |
  [$validated[] | select((.block_id.workchain? // .block_id.workchain_id? // -1) == 0)] as $wc_validated |
  [$validated[] | select((.block_id.workchain? // .block_id.workchain_id? // 0) == -1)] as $mc_validated |
  [$wc_collated[] |
    select($measure_start != null and $measure_end != null and
           (.collated_at? // -1) >= $measure_start and (.collated_at? // -1) < $measure_end)] as $measured_collated |
  [$wc_validated[] |
    select($measure_start != null and $measure_end != null and
           (.validated_at? // -1) >= $measure_start and (.validated_at? // -1) < $measure_end)] as $measured_validated |
  [$mc_collated[] |
    select($measure_start != null and $measure_end != null and
           (.collated_at? // -1) >= $measure_start and (.collated_at? // -1) < $measure_end)] as $measured_mc_collated |
  [$mc_validated[] |
    select($measure_start != null and $measure_end != null and
           (.validated_at? // -1) >= $measure_start and (.validated_at? // -1) < $measure_end)] as $measured_mc_validated |
  [$records[] | select(.["@type"] == "consensus.stats.events")] as $consensus_records |
  (reduce $consensus_records[] as $record ({};
    (($record.events | map(select(.event["@type"] == "consensus.stats.id")) | first? |
       .event.workchain?) //
     ($record.events |
       map(select(.event["@type"] == "consensus.stats.candidateReceived" and
                  .event.block["@type"] == "consensus.stats.block")) |
       first? | .event.block.id.workchain?)) as $workchain |
    if $workchain != null then .[$record.id] = $workchain else . end)) as $session_workchains |
  [$consensus_records[] as $record |
    $record.events[] |
    {session_id:$record.id,workchain:($session_workchains[$record.id] // null),ts:.ts,event:.event}] as $events |
  [$events[] | select(.workchain == 0)] as $bc_events |
  [$events[] | select(.workchain == -1)] as $mc_events |
  [$bc_events[] | select($measure_start != null and $measure_end != null and
                         .ts >= $measure_start and .ts < $measure_end)] as $measured_bc_events |
  [$mc_events[] | select($measure_start != null and $measure_end != null and
                         .ts >= $measure_start and .ts < $measure_end)] as $measured_mc_events |
  {
    semantics:"validator candidate session records captured directly from genesis; basechain transaction counts are native transfers for this isolated single-validator benchmark; proof-checked generator metrics remain authoritative for canonical selection",
    raw_records:($records | length),
    consensus_unmapped_events:([$events[] | select(.workchain == null)] | length),
    measured_window_unix_s:{start:$measure_start,end:$measure_end},
    all_run:{
      collated_basechain:collated_summary($wc_collated),
      validated_basechain:validated_summary($wc_validated),
      collated_masterchain:collated_summary($mc_collated),
      validated_masterchain:validated_summary($mc_validated),
      consensus_basechain:consensus_summary($bc_events),
      consensus_masterchain:consensus_summary($mc_events)
    },
    measured:{
      collated_basechain:collated_summary($measured_collated),
      validated_basechain:validated_summary($measured_validated),
      collated_masterchain:collated_summary($measured_mc_collated),
      validated_masterchain:validated_summary($measured_mc_validated),
      consensus_basechain:consensus_summary($measured_bc_events),
      consensus_masterchain:consensus_summary($measured_mc_events)
    }
  }
' "$validator_session_stats_file" >"$validator_pipeline_summary_file"

# INFO scheduling summaries are optional at normal validator verbosity. The
# structured consensus event stream is always captured by log.session-stats,
# so derive cadence and wall-time telemetry from it without enabling noisy
# global logging. This does not claim to expose internal wake/timer reasons.
jq -Rsc \
  --argjson measure_start "$generator_measure_start" \
  --argjson measure_end "$generator_measure_end" \
  --slurpfile info "$validator_scheduling_log_summary_file" '
  def distribution:
    map(select(type == "number")) | sort as $values |
    if ($values | length) == 0 then
      {samples:0,avg:null,p50:null,p95:null,p99:null,max:null}
    else
      ($values | length) as $count |
      {samples:$count,avg:($values | add / $count),
       p50:$values[((($count - 1) * 0.50) | floor)],
       p95:$values[((($count - 1) * 0.95) | floor)],
       p99:$values[((($count - 1) * 0.99) | floor)],max:$values[-1]}
    end;
  def intervals($timestamps):
    ($timestamps | sort) as $values |
    [range(1; $values | length) | $values[.] - $values[. - 1]] | distribution;
  def event_duration($rows; $start_type; $finish_type; $id_field):
    [$rows[] |
      select(.event["@type"] == $start_type or .event["@type"] == $finish_type) |
      {key:(.session_id + ":" + ((.event[$id_field].slot? // .event.target_slot? // -1) | tostring)),
       type:.event["@type"],ts:.ts}] |
    sort_by(.key,.ts) | group_by(.key) |
    map((map(select(.type == $start_type)) | first? | .ts) as $start |
        (map(select(.type == $finish_type)) | last? | .ts) as $finish |
        select($start != null and $finish != null and $finish >= $start) |
        $finish - $start) | distribution;
  def summarize($rows):
    [$rows[] | select(.event["@type"] == "consensus.stats.collateStarted") | .ts] as $collate |
    [$rows[] | select(.event["@type"] == "consensus.stats.blockAccepted") | .ts] as $accepted |
    {
      events:($rows | length),
      first_event_unix_s:($rows | map(.ts) | min // null),
      last_event_unix_s:($rows | map(.ts) | max // null),
      collate_started:($collate | length),
      collate_finished:([$rows[] | select(.event["@type"] == "consensus.stats.collateFinished")] | length),
      collated_empty:([$rows[] | select(.event["@type"] == "consensus.stats.collatedEmpty")] | length),
      candidates_received:([$rows[] | select(.event["@type"] == "consensus.stats.candidateReceived")] | length),
      blocks_accepted:($accepted | length),
      skip_votes:([$rows[] | select(.event["@type"] == "consensus.simplex.stats.voted" and
                                     .event.vote["@type"] == "consensus.simplex.skipVote")] | length),
      notarize_votes:([$rows[] | select(.event["@type"] == "consensus.simplex.stats.voted" and
                                         .event.vote["@type"] == "consensus.simplex.notarizeVote")] | length),
      finalize_votes:([$rows[] | select(.event["@type"] == "consensus.simplex.stats.voted" and
                                         .event.vote["@type"] == "consensus.simplex.finalizeVote")] | length),
      collate_start_interval_s:intervals($collate),
      accepted_block_interval_s:intervals($accepted),
      collation_wall_s:event_duration($rows; "consensus.stats.collateStarted";
                                      "consensus.stats.collateFinished"; "id"),
      validation_wall_s:event_duration($rows; "consensus.stats.validationStarted";
                                       "consensus.stats.validationFinished"; "id")
    };
  [split("\n")[] | fromjson? | select(.["@type"] == "consensus.stats.events")] as $sessions |
  (reduce $sessions[] as $record ({};
    (($record.events |
      map(select(.event["@type"] == "consensus.stats.candidateReceived" and
                 .event.block["@type"] == "consensus.stats.block")) |
      first? | .event.block.id.workchain?) // null) as $workchain |
    if $workchain != null then .[$record.id] = $workchain else . end)) as $workchains |
  [$sessions[] as $session | $session.events[] |
    {session_id:$session.id,workchain:($workchains[$session.id] // null),ts:.ts,event:.event}] as $events |
  [$events[] | select($measure_start != null and $measure_end != null and
                       .ts >= $measure_start and .ts < $measure_end)] as $measured |
  {
    provenance:{
      primary_source:"validator /var/ton-work/db/log.session-stats consensus.stats.events",
      source_is_structured:true,
      timestamp_precision:"floating-point Unix seconds emitted by validator consensus instrumentation",
      workchain_assignment:"inferred from candidateReceived block id for each consensus session",
      limitations:[
        "does not expose internal actor wake reasons, timer deadlines, or pending-work gauges",
        "events from sessions without a candidateReceived record remain unmapped",
        "measured window uses event timestamp >= start and < end"
      ],
      optional_info_log_records:($info[0].records // 0)
    },
    measured_window_unix_s:{start:$measure_start,end:$measure_end},
    unmapped_events:([$events[] | select(.workchain == null)] | length),
    all_run:{
      basechain:summarize([$events[] | select(.workchain == 0)]),
      masterchain:summarize([$events[] | select(.workchain == -1)])
    },
    measured:{
      basechain:summarize([$measured[] | select(.workchain == 0)]),
      masterchain:summarize([$measured[] | select(.workchain == -1)])
    },
    info_log_last_by_component:($info[0].last_by_component // [])
  }
' "$validator_session_stats_file" >"$validator_scheduling_summary_file"

if jq -e '
  (.measured_window_unix_s.start != null) and
  (.measured_window_unix_s.end != null) and
  (.measured_window_unix_s.start < .measured_window_unix_s.end) and
  (.all_run.collated_basechain.blocks > 0) and
  (.measured.collated_basechain.blocks == 0)
' "$validator_pipeline_summary_file" >/dev/null; then
  echo "validator telemetry contained basechain candidates but the measured slice was empty" >&2
  benchmark_exit_code=125
fi

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
        source_resolution_seconds:$rate_window_seconds,
        left_padding_seconds:(($start | fromdateiso8601) - ($query_start | fromdateiso8601)),
        right_padding_seconds:(($query_end | fromdateiso8601) - ($end | fromdateiso8601)),
        boundary_rule:"whole persisted minute buckets intersecting the run; padded totals are corroboration only"
      },
      rate_samples: ($rate_rows | length),
      max_minute_average_canonical_tps: ($rate_rows | map(.wc // 0) | max),
      max_native_transfers_per_block: ($rate_rows | map(.wc_max // 0) | max),
      canonical_transfers: $canonical,
      padded_range_average_canonical_tps: ($canonical / $query_elapsed_seconds)
    }
  ' >"$session_stats_summary_file"

jq -L "$benchmark_jq_dir" -Rs '
  include "native-benchmark-lib";
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
    max_source_issue_burst:($records | map(.source_issue_burst_max_size // 0) | max),
    max_active_tasks_per_source:($records | map(.max_active_tasks_per_source // 0) | max),
    max_sources_at_canonical_backlog_cap:($records |
      map(.sources_at_canonical_backlog_cap // 0) | max),
    max_mempool_accept_tps: ($records | map(.mempool_accept_tps // 0) | max),
    max_canonical_tps: ($records | map(
      .canonical_chain_measure_peak_1s_tps // .canonical_tps // .measured_canonical_tps // 0
    ) | max),
    max_canonical_tps_semantics: "maximum transfers assigned to one fully contained canonical block gen_utime second; final canonical_gen_utime_bucket_* fields define exact integer boundaries",
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
    measured_canonical_backpressure_seconds: ($final.measure_canonical_backpressure_s // null),
    measured_canonical_backpressure_fraction: ($final.measure_canonical_backpressure_fraction // null),
    ingress_capacity_valid: (
      if $final == null then null else ($final.ingress_capacity_valid // false) end
    ),
    chain_capacity_valid: (
      if $final == null then null else ($final.chain_capacity_valid // false) end
    ),
    chain_correctness_valid: (
      if $final == null then null else ($final.chain_correctness_valid // false) end
    ),
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
    offer_target_attainment_ratio: ($final.offer_target_attainment_ratio // null),
    offer_target_attained: field_or_null($final; "offer_target_attained"),
    canonical_overdrive_ratio: ($final.canonical_overdrive_ratio // null),
    measured_admission_avg_tps: ($final.steady_mempool_accept_avg_tps // null),
    measured_canonical_chain_avg_tps: ($final.canonical_chain_measure_avg_tps // null),
    measured_offer_cohort_observed_avg_tps: (
      $final.canonical_measured_offer_cohort_observed_avg_tps // null
    ),
    canonical_gen_utime_window:(if $final == null then null else {
      start_unix_s:($final.canonical_gen_utime_bucket_start_unix_s // null),
      end_unix_s:($final.canonical_gen_utime_bucket_end_unix_s // null),
      duration_s:($final.canonical_gen_utime_bucket_duration_s // null),
      boundary_rule:"whole [gen_utime,gen_utime+1) buckets fully contained in the millisecond measurement window"
    } end),
    task_errors_by_reason:($final.task_errors_by_reason // null),
    retries_by_reason:($final.retries_by_reason // null),
    histogram_overflow:{
      rtt:($final.rtt_ms | if . == null then null else
        {overflow:(.overflow // null),lower_bound_ms:(.overflow_lower_bound_ms // null),
         p50_in_overflow:field_or_null(.; "p50_in_overflow"),
         p95_in_overflow:field_or_null(.; "p95_in_overflow"),
         p99_in_overflow:field_or_null(.; "p99_in_overflow")} end),
      signing:($final.sign_ms | if . == null then null else
        {overflow:(.overflow // null),lower_bound_ms:(.overflow_lower_bound_ms // null),
         p50_in_overflow:field_or_null(.; "p50_in_overflow"),
         p95_in_overflow:field_or_null(.; "p95_in_overflow"),
         p99_in_overflow:field_or_null(.; "p99_in_overflow")} end),
      anchor:($final.anchor_latency_sample_ms | if . == null then null else
        {overflow:(.overflow // null),lower_bound_ms:(.overflow_lower_bound_ms // null),
         p50_in_overflow:field_or_null(.; "p50_in_overflow"),
         p95_in_overflow:field_or_null(.; "p95_in_overflow"),
         p99_in_overflow:field_or_null(.; "p99_in_overflow")} end)
    },
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
    capacity_acceptance:capacity_acceptance($final),
    generator_reported_invalid_reasons:(if $final == null then null else {
      correctness:($final.correctness_invalid_reasons // []),
      run_completion:($final.run_incomplete_reasons // []),
      ingress_capacity:($final.ingress_capacity_invalid_reasons // []),
      chain_capacity:($final.chain_capacity_invalid_reasons // [])
    } end),
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
if jq -e '.valid_canonical_run == true and .chain_capacity_valid != true' \
  "$generator_summary_file" >/dev/null; then
  echo "notice: the run is canonically correct but not a valid chain-capacity result; do not claim a TPS ceiling from it" >&2
fi

jq -L "$benchmark_jq_dir" -s \
  --argjson host_vcpus "$(getconf _NPROCESSORS_ONLN)" \
  --argjson host_memory_bytes "$(awk '/^MemTotal:/ {print $2 * 1024; exit}' /proc/meminfo)" '
  include "native-benchmark-lib";
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
    (map((.NetIO | split(" / ")[0]) | bytes)) as $net_rx |
    (map((.NetIO | split(" / ")[1]) | bytes)) as $net_tx |
    (map((.BlockIO | split(" / ")[0]) | bytes)) as $block_read |
    (map((.BlockIO | split(" / ")[1]) | bytes)) as $block_write |
    (map(.sampled_at_epoch) | sort) as $sample_times |
    (($sample_times[-1] // 0) - ($sample_times[0] // 0)) as $sample_span |
    ($net_rx | monotonic_counter_delta) as $net_rx_delta |
    ($net_tx | monotonic_counter_delta) as $net_tx_delta |
    ($block_read | monotonic_counter_delta) as $block_read_delta |
    ($block_write | monotonic_counter_delta) as $block_write_delta |
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
      max_memory_host_percent: (($memory | max) * 100 / $host_memory_bytes),
      io_sample_span_seconds:$sample_span,
      net_rx_bytes_delta:$net_rx_delta,
      net_tx_bytes_delta:$net_tx_delta,
      block_read_bytes_delta:$block_read_delta,
      block_write_bytes_delta:$block_write_delta,
      avg_net_rx_bytes_per_second:(if $sample_span > 0 then $net_rx_delta / $sample_span else null end),
      avg_net_tx_bytes_per_second:(if $sample_span > 0 then $net_tx_delta / $sample_span else null end),
      avg_block_read_bytes_per_second:(if $sample_span > 0 then $block_read_delta / $sample_span else null end),
      avg_block_write_bytes_per_second:(if $sample_span > 0 then $block_write_delta / $sample_span else null end)
    }
  )
' "$container_stats_file" >"$result_dir/container-resource-summary.json"

jq -s '
  if length == 0 then
    {samples:0,avg_cpu_percent:null,max_cpu_percent:null,
     avg_iowait_percent:null,max_iowait_percent:null,
     avg_memory_used_bytes:null,max_memory_used_bytes:null,per_cpu:[]}
  else
    {
      samples: length,
      avg_cpu_percent: (map(.cpu_percent) | add / length),
      max_cpu_percent: (map(.cpu_percent) | max),
      avg_iowait_percent: (map(.iowait_percent // 0) | add / length),
      max_iowait_percent: (map(.iowait_percent // 0) | max),
      avg_memory_used_bytes: (map(.memory_used_bytes) | add / length),
      max_memory_used_bytes: (map(.memory_used_bytes) | max),
      memory_total_bytes: (last.memory_total_bytes),
      per_cpu:([.[] | .per_cpu[]?] | sort_by(.cpu) | group_by(.cpu) |
        map({cpu:.[0].cpu,samples:length,
             avg_cpu_percent:(map(.cpu_percent) | add / length),
             max_cpu_percent:(map(.cpu_percent) | max),
             avg_iowait_percent:(map(.iowait_percent) | add / length),
             max_iowait_percent:(map(.iowait_percent) | max)}))
    }
  end
' "$host_stats_file" >"$result_dir/host-resource-summary.json"

jq -L "$benchmark_jq_dir" -s '
  include "native-benchmark-lib";
  def pressure_avg10($text; $kind):
    (($text // "") | capture("(?:^|;)" + $kind + " avg10=(?<value>[0-9.]+)")? |
      .value | tonumber?) // 0;
  sort_by(.container,.sampled_at_epoch) | group_by(.container) |
  map(
    (map(.sampled_at_epoch) | sort) as $times |
    (($times[-1] // 0) - ($times[0] // 0)) as $span |
    (map(.cpu_usage_usec) | monotonic_counter_delta) as $cpu_usage |
    (map(.cpu_nr_periods) | monotonic_counter_delta) as $periods |
    (map(.cpu_nr_throttled) | monotonic_counter_delta) as $throttled_periods |
    (map(.cpu_throttled_usec) | monotonic_counter_delta) as $throttled_usec |
    {
      name:.[0].container,samples:length,sample_span_seconds:$span,
      cgroup_path:.[-1].cgroup_path,
      cpuset_cpus_effective:.[-1].cpuset_cpus_effective,
      cpu_max:.[-1].cpu_max,memory_max:.[-1].memory_max,
      avg_cpu_cores:(if $span > 0 then $cpu_usage / 1000000 / $span else null end),
      cpu_usage_seconds:($cpu_usage / 1000000),
      cpu_periods:$periods,cpu_throttled_periods:$throttled_periods,
      cpu_throttled_period_fraction:(if $periods > 0 then $throttled_periods / $periods else 0 end),
      cpu_throttled_seconds:($throttled_usec / 1000000),
      max_memory_current_bytes:(map(.memory_current) | max // null),
      max_memory_peak_bytes:(map(.memory_peak) | max // null),
      oom_events_delta:(map(.memory_oom) | monotonic_counter_delta),
      oom_kill_events_delta:(map(.memory_oom_kill) | monotonic_counter_delta),
      io_read_bytes_delta:(map(.io_read_bytes) | monotonic_counter_delta),
      io_write_bytes_delta:(map(.io_write_bytes) | monotonic_counter_delta),
      io_read_operations_delta:(map(.io_read_operations) | monotonic_counter_delta),
      io_write_operations_delta:(map(.io_write_operations) | monotonic_counter_delta),
      max_cpu_pressure_some_avg10:(map(pressure_avg10(.cpu_pressure; "some")) | max // null),
      max_io_pressure_some_avg10:(map(pressure_avg10(.io_pressure; "some")) | max // null),
      max_io_pressure_full_avg10:(map(pressure_avg10(.io_pressure; "full")) | max // null),
      max_memory_pressure_some_avg10:(map(pressure_avg10(.memory_pressure; "some")) | max // null)
    }
  )
' "$cgroup_stats_file" >"$result_dir/cgroup-resource-summary.json"

jq -L "$benchmark_jq_dir" -s '
  include "native-benchmark-lib";
  sort_by(.device,.sampled_at_epoch) | group_by(.device) |
  map(
    (map(.sampled_at_epoch) | sort) as $times |
    (($times[-1] // 0) - ($times[0] // 0)) as $span |
    (map(.read_bytes) | monotonic_counter_delta) as $read_bytes |
    (map(.write_bytes) | monotonic_counter_delta) as $write_bytes |
    {
      device:.[0].device,samples:length,sample_span_seconds:$span,
      read_bytes_delta:$read_bytes,write_bytes_delta:$write_bytes,
      read_operations_delta:(map(.read_operations) | monotonic_counter_delta),
      write_operations_delta:(map(.write_operations) | monotonic_counter_delta),
      io_busy_seconds:((map(.io_time_ms) | monotonic_counter_delta) / 1000),
      weighted_io_seconds:((map(.weighted_io_time_ms) | monotonic_counter_delta) / 1000),
      max_in_flight:(map(.in_flight) | max // null),
      avg_read_bytes_per_second:(if $span > 0 then $read_bytes / $span else null end),
      avg_write_bytes_per_second:(if $span > 0 then $write_bytes / $span else null end)
    }
  )
' "$device_stats_file" >"$result_dir/device-resource-summary.json"

jq -s '
  [.[].threads[]?] | sort_by(.container,.thread_name,.tid) |
  group_by([.container,.thread_name,.tid]) |
  map({container:.[0].container,thread_name:.[0].thread_name,tid:.[0].tid,
       samples:length,avg_cpu_percent:(map(.cpu_percent) | add / length),
       max_cpu_percent:(map(.cpu_percent) | max),
       last_processor:.[-1].processor}) |
  sort_by(-.max_cpu_percent) | .[:64]
' "$thread_stats_file" >"$result_dir/thread-resource-summary.json"

jq -n \
  --slurpfile containers "$result_dir/container-resource-summary.json" \
  --slurpfile host "$result_dir/host-resource-summary.json" \
  --slurpfile cgroups "$result_dir/cgroup-resource-summary.json" \
  --slurpfile devices "$result_dir/device-resource-summary.json" \
  --slurpfile threads "$result_dir/thread-resource-summary.json" \
  '{containers:$containers[0],host:$host[0],cgroups:$cgroups[0],
    devices:$devices[0],thread_hotspots:$threads[0]}' >"$resource_summary_file"

docker inspect genesis "$container_name" session-stats |
  jq '[.[] | {
    name: (.Name | ltrimstr("/")),
    image: .Config.Image,
    image_id: .Image,
    state: .State.Status,
    health: (.State.Health.Status // null),
    oom_killed: (.State.OOMKilled // false),
    restart_count: (.RestartCount // 0),
    exit_code: (.State.ExitCode // null),
    started_at: (.State.StartedAt // null),
    finished_at: (.State.FinishedAt // null),
    cpuset: .HostConfig.CpusetCpus,
    nano_cpus: .HostConfig.NanoCpus,
    memory_limit_bytes: .HostConfig.Memory,
    mounts:[.Mounts[]? | {type:.Type,source:.Source,destination:.Destination,rw:.RW}],
    benchmark_environment: [.Config.Env[] | select(test(
      "^(GENESIS_VERBOSITY|TON_SIMPLEX_[^=]+|TON_NATIVE_[^=]+|NATIVE_LOAD_[^=]+|SIMPLEX_[^=]+|BLOCK_(SIZE|GAS|LIMIT)[^=]*)="
    ))]
  }]' >"$runtime_file"

image_metadata_jsonl=$result_dir/image-metadata.jsonl
: >"$image_metadata_jsonl"
while read -r image_id; do
  [[ -n $image_id ]] || continue
  docker image inspect "$image_id" 2>/dev/null | jq '.[] | {
    image_id:.Id,
    repo_tags:(.RepoTags // []),
    repo_digests:(.RepoDigests // []),
    created:(.Created // null),
    architecture:(.Architecture // null),
    os:(.Os // null),
    size_bytes:(.Size // null),
    oci_labels:{
      created:(.Config.Labels["org.opencontainers.image.created"] // null),
      revision:(.Config.Labels["org.opencontainers.image.revision"] // null),
      source:(.Config.Labels["org.opencontainers.image.source"] // null),
      version:(.Config.Labels["org.opencontainers.image.version"] // null)
    }
  }' >>"$image_metadata_jsonl"
done < <(jq -r 'map(.image_id) | unique[]' "$runtime_file")
jq -s '.' "$image_metadata_jsonl" >"$image_metadata_file"

env_sha256=$(sha256sum "$env_file" | awk '{print $1}')
git_revision=$(git rev-parse HEAD 2>/dev/null || true)
git_dirty=$(if [[ -z $(git status --porcelain --untracked-files=normal 2>/dev/null) ]]; then echo false; else echo true; fi)
git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
git_branch=$(git branch --show-current 2>/dev/null || true)
git_describe=$(git describe --always --dirty --tags 2>/dev/null || true)
git_status_sha256=$(git status --porcelain=v1 --untracked-files=normal 2>/dev/null | sha256sum | awk '{print $1}')
git_diff_sha256=$(git diff --binary HEAD 2>/dev/null | sha256sum | awk '{print $1}')
compose_config_sha256=$("${compose[@]}" --profile session-stats --profile native-load-generator config |
  sha256sum | awk '{print $1}')
compose_service_hashes=$("${compose[@]}" --profile session-stats --profile native-load-generator \
  config --hash 2>/dev/null |
  jq -Rsc '[split("\n")[] | select(length > 0) | split(" ") |
    select(length >= 2) | {service:.[0],config_hash:.[1]}]')
docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)
compose_version=$(docker compose version --short 2>/dev/null || true)
docker_cgroup_driver=$(docker info --format '{{.CgroupDriver}}' 2>/dev/null || true)
docker_cgroup_version=$(docker info --format '{{.CgroupVersion}}' 2>/dev/null || true)
if command -v lscpu >/dev/null 2>&1; then
  cpu_topology=$(lscpu -J 2>/dev/null || echo '{}')
else
  cpu_topology='{}'
fi
smt_active=$(read_numeric_file /sys/devices/system/cpu/smt/active)
numa_nodes=$(find /sys/devices/system/node -maxdepth 1 -type d -name 'node[0-9]*' 2>/dev/null | wc -l)
if [[ $git_dirty == true ]]; then
  reproducibility_reasons='["source_tree_dirty"]'
else
  reproducibility_reasons='[]'
fi
if ! jq -e 'length > 0 and all(.[]; (.repo_digests | length) > 0)' "$image_metadata_file" >/dev/null; then
  reproducibility_reasons=$(jq -cn --argjson reasons "$reproducibility_reasons" \
    '$reasons + ["one_or_more_images_lack_registry_digest"]')
fi
if ! jq -e 'length > 0 and all(.[];
  .oci_labels.revision != null and .oci_labels.revision != "unknown" and
  (.oci_labels.revision | length) > 0)' "$image_metadata_file" >/dev/null; then
  reproducibility_reasons=$(jq -cn --argjson reasons "$reproducibility_reasons" \
    '$reasons + ["one_or_more_images_lack_source_revision_label"]')
fi
jq -n \
  --arg schema native-benchmark-run-v2 \
  --arg run_id "$run_id" \
  --arg started_at "$started_at" \
  --arg finished_at "$finished_at" \
  --arg env_file "$env_file" \
  --arg env_sha256 "$env_sha256" \
  --arg git_revision "$git_revision" \
  --arg git_root "$git_root" \
  --arg git_branch "$git_branch" \
  --arg git_describe "$git_describe" \
  --arg git_status_sha256 "$git_status_sha256" \
  --arg git_diff_sha256 "$git_diff_sha256" \
  --argjson git_dirty "$git_dirty" \
  --arg compose_config_sha256 "$compose_config_sha256" \
  --argjson compose_service_hashes "$compose_service_hashes" \
  --arg docker_version "$docker_version" \
  --arg compose_version "$compose_version" \
  --arg docker_cgroup_driver "$docker_cgroup_driver" \
  --arg docker_cgroup_version "$docker_cgroup_version" \
  --arg kernel "$(uname -srmo)" \
  --arg cpu_model "$(awk -F: '/model name/ {sub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo)" \
  --argjson host_vcpus "$(getconf _NPROCESSORS_ONLN)" \
  --argjson host_memory_bytes "$(awk '/^MemTotal:/ {print $2 * 1024; exit}' /proc/meminfo)" \
  --argjson cpu_topology "$cpu_topology" \
  --argjson smt_active "$smt_active" \
  --argjson numa_nodes "$numa_nodes" \
  --argjson elapsed_seconds "$((finished_epoch - started_epoch))" \
  --argjson generator_container_exit_code "$generator_container_exit_code" \
  --argjson benchmark_exit_code "$benchmark_exit_code" \
  --argjson interrupted "$interrupted" \
  --slurpfile containers "$runtime_file" \
  --slurpfile images "$image_metadata_file" \
  --argjson reproducibility_reasons "$reproducibility_reasons" \
  '{$schema,$run_id,$started_at,$finished_at,$elapsed_seconds,$env_file,$env_sha256,
    $git_revision,$git_dirty,
    source:{root:$git_root,revision:$git_revision,branch:$git_branch,describe:$git_describe,
            dirty:$git_dirty,status_sha256:$git_status_sha256,diff_sha256:$git_diff_sha256},
    compose:{config_sha256:$compose_config_sha256,service_hashes:$compose_service_hashes,
             version:$compose_version},
    docker:{version:$docker_version,cgroup_driver:$docker_cgroup_driver,
            cgroup_version:$docker_cgroup_version},
    $kernel,$cpu_model,$host_vcpus,$host_memory_bytes,
    host_topology:{smt_active:($smt_active == 1),numa_nodes:$numa_nodes,lscpu:$cpu_topology},
    $generator_container_exit_code,$benchmark_exit_code,
    interrupted:($interrupted == 1),containers:$containers[0],images:$images[0],
    reproducibility:{valid:($reproducibility_reasons | length == 0),
                     reasons:$reproducibility_reasons,
                     semantics:"separate from proof correctness and capacity validity; dirty source or unpinned images make the run difficult to reproduce but do not alter canonical proof results"}}' >"$metadata_file"

jq -n \
  --slurpfile run "$metadata_file" \
  --slurpfile generator "$generator_summary_file" \
  --slurpfile resources "$resource_summary_file" \
  --slurpfile session_stats "$session_stats_summary_file" \
  --slurpfile validator_pipeline "$validator_pipeline_summary_file" \
  --slurpfile validator_pool "$validator_pool_summary_file" \
  --slurpfile validator_scheduling "$validator_scheduling_summary_file" \
  '{run:$run[0],generator:$generator[0],session_stats:$session_stats[0],
    validator_pipeline:$validator_pipeline[0],validator_pool:$validator_pool[0],
    validator_scheduling:$validator_scheduling[0],
    resources:$resources[0],
    acceptance:($generator[0].capacity_acceptance + {
      reproducible:$run[0].reproducibility.valid,
      reproducibility_reasons:$run[0].reproducibility.reasons,
      semantics:"proof correctness, run completion, ingress capacity, chain capacity, and reproducibility are independent acceptance dimensions"
    })}' \
  >"$summary_file"

echo "Benchmark summary: $summary_file"
jq . "$summary_file"

if [[ $interrupted -eq 1 ]]; then
  exit 130
fi
exit "$benchmark_exit_code"
